require "sqlite3"
require "json"
require "fileutils"
require "time"

require_relative "room_echo"
require_relative "self_state"

module LogViz
  # Persisted, incrementally-updated, cross-session world model. Unlike
  # `Session` (one in-memory object per `.jsonl` file per request), this
  # accumulates across every session ever logged, so its cost can't be
  # allowed to grow with total history on every refresh — see
  # docs/plans/observability/player_journey_map.md §2 for the full design
  # and the reasoning behind choosing SQLite over a JSON blob.
  #
  # Every write is a targeted INSERT/UPDATE derived from newly-ingested log
  # lines, never a full rewrite of the accumulated state; every read of a
  # session file is bounded by a per-file byte offset, so a refresh only
  # costs work proportional to what's new since the last one.
  class WorldMap
    LIVE_WINDOW_SECONDS = 60

    # Real compass directions get real 2D deltas — the map is laid out from
    # actual `move` directions, not a generic force-directed guess. up/down
    # have no natural 2D slot; nudged diagonally purely for visual
    # separation, not claimed as real geometry (documented simplification).
    DIRECTION_DELTA = {
      "north" => [0.0, -1.0], "south" => [0.0, 1.0],
      "east"  => [1.0, 0.0],  "west"  => [-1.0, 0.0],
      "up"    => [0.4, -0.4], "down"  => [-0.4, 0.4]
    }.freeze

    # Offsets tried, in order, for a direction-less arrival (enter/leave/
    # flee — no compass data to place it by).
    FREE_SLOT_RING = [
      [0.6, 0.0], [-0.6, 0.0], [0.0, 0.6], [0.0, -0.6],
      [0.6, 0.6], [-0.6, -0.6], [0.6, -0.6], [-0.6, 0.6]
    ].freeze

    SCHEMA = <<~SQL
      CREATE TABLE IF NOT EXISTS file_offsets (
        path TEXT PRIMARY KEY, byte_offset INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS rooms (
        title TEXT PRIMARY KEY,
        description TEXT,
        exits TEXT,
        coord_x REAL, coord_y REAL,
        visit_count INTEGER NOT NULL DEFAULT 0,
        first_seen_session TEXT, first_seen_turn INTEGER,
        first_seen_iteration INTEGER, first_seen_at TEXT
      );

      CREATE TABLE IF NOT EXISTS room_contents (
        room_title TEXT NOT NULL,
        content TEXT NOT NULL,
        first_seen_at TEXT,
        PRIMARY KEY (room_title, content)
      );

      CREATE TABLE IF NOT EXISTS edges (
        from_title TEXT NOT NULL, via TEXT NOT NULL, to_title TEXT NOT NULL,
        PRIMARY KEY (from_title, via)
      );

      CREATE TABLE IF NOT EXISTS visits (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL, room_title TEXT NOT NULL,
        turn INTEGER, iteration INTEGER, at TEXT, arrived_via TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_visits_session ON visits(session_id);

      CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY, path TEXT,
        task TEXT, provider TEXT, model TEXT, started_at TEXT,
        last_room TEXT, last_seen_at TEXT,
        turn INTEGER NOT NULL DEFAULT 0, iteration INTEGER NOT NULL DEFAULT 0
      );

      CREATE TABLE IF NOT EXISTS self_state (
        session_id TEXT NOT NULL, kind TEXT NOT NULL, text TEXT,
        turn INTEGER, iteration INTEGER, at TEXT,
        PRIMARY KEY (session_id, kind)
      );

      CREATE TABLE IF NOT EXISTS pending_calls (
        session_id TEXT NOT NULL, seq INTEGER NOT NULL,
        name TEXT, args TEXT,
        PRIMARY KEY (session_id, seq)
      );
    SQL

    def self.instance(sessions_dir:, db_path: nil)
      @instances ||= {}
      key = [sessions_dir, db_path]
      @instances[key] ||= new(sessions_dir: sessions_dir, db_path: db_path)
    end

    def self.reset_instances!
      @instances = {}
    end

    def initialize(sessions_dir:, db_path: nil)
      @sessions_dir = sessions_dir
      @db_path      = db_path || File.join(File.dirname(sessions_dir), "world_map.sqlite3")
      @mutex        = Mutex.new
      FileUtils.mkdir_p(File.dirname(@db_path))
      open_db!
    end

    def refresh!
      @mutex.synchronize do
        Dir.glob(File.join(@sessions_dir, "*.jsonl")).sort.each { |path| ingest_new_lines(path) }
      end
      self
    end

    # ---------- read accessors for the view layer ----------

    def rooms
      @db.execute(
        "SELECT title, description, exits, coord_x, coord_y, visit_count, " \
        "first_seen_session, first_seen_turn, first_seen_iteration, first_seen_at FROM rooms"
      ).map do |row|
        {
          title: row[0], description: row[1], exits: JSON.parse(row[2] || "[]"),
          coord: (row[3] && row[4]) ? [row[3], row[4]] : nil,
          visit_count: row[5].to_i,
          first_seen: { session_id: row[6], turn: row[7], iteration: row[8], at: row[9] }
        }
      end
    end

    def edges
      @db.execute("SELECT from_title, via, to_title FROM edges").map do |row|
        { from: row[0], via: row[1], to: row[2] }
      end
    end

    def room_contents(title)
      @db.execute("SELECT content FROM room_contents WHERE room_title = ? ORDER BY content", [title]).map { |r| r[0] }
    end

    # Every unique room-content string across the whole map, deduplicated,
    # with the room(s) it was seen in and when first seen — the
    # "discoveries" panel's data source (player_journey_map.md §4).
    def discoveries
      rows = @db.execute("SELECT content, room_title, first_seen_at FROM room_contents ORDER BY first_seen_at")
      grouped = {}
      rows.each do |content, room_title, at|
        entry = (grouped[content] ||= { rooms: [], first_seen_at: at })
        entry[:rooms] << room_title unless entry[:rooms].include?(room_title)
      end
      grouped.map { |content, v| { content: content, rooms: v[:rooms], first_seen_at: v[:first_seen_at] } }
    end

    def sessions
      @db.execute(
        "SELECT session_id, path, task, provider, model, started_at, " \
        "last_room, last_seen_at, turn, iteration FROM sessions"
      ).map { |row| session_row_to_h(row) }
    end

    def live_sessions
      now = Time.now
      sessions.select do |s|
        next false unless s[:last_seen_at]

        (now - Time.parse(s[:last_seen_at])) < LIVE_WINDOW_SECONDS
      end
    rescue ArgumentError
      []
    end

    def visits_for(session_id)
      @db.execute(
        "SELECT room_title, turn, iteration, at, arrived_via FROM visits WHERE session_id = ? ORDER BY id",
        [session_id]
      ).map { |row| { room_title: row[0], turn: row[1], iteration: row[2], at: row[3], arrived_via: row[4] } }
    end

    def self_state_for(session_id)
      @db.execute(
        "SELECT kind, text, turn, iteration, at FROM self_state WHERE session_id = ?", [session_id]
      ).each_with_object({}) do |row, h|
        h[row[0]] = { text: row[1], turn: row[2], iteration: row[3], at: row[4] }
      end
    end

    private

    def open_db!
      connect!
    rescue SQLite3::Exception => e
      # The database is a cache over the durable .jsonl logs, never a
      # second source of truth — if it's unreadable, set it aside and
      # rebuild from scratch. `file_offsets` starts empty again, so the
      # next refresh replays every session file once and reconstructs the
      # merged model exactly.
      warn "[LogViz::WorldMap] #{@db_path} unreadable (#{e.message}) — rebuilding from session logs"
      backup = "#{@db_path}.corrupt-#{Time.now.to_i}"
      File.rename(@db_path, backup) if File.exist?(@db_path)
      connect!
    end

    def connect!
      @db = SQLite3::Database.new(@db_path)
      @db.busy_timeout = 5000
      @db.execute_batch("PRAGMA journal_mode = WAL;")
      @db.execute_batch(SCHEMA)
    end

    def session_row_to_h(row)
      {
        session_id: row[0], path: row[1], task: row[2], provider: row[3], model: row[4],
        started_at: row[5], last_room: row[6], last_seen_at: row[7],
        turn: row[8].to_i, iteration: row[9].to_i
      }
    end

    def ingest_new_lines(path)
      size   = File.size(path)
      offset = stored_offset(path)
      return if size <= offset

      chunk = File.open(path, "rb") { |f| f.seek(offset); f.read(size - offset) }
      return if chunk.nil? || chunk.empty?

      session_id = File.basename(path, ".jsonl")
      consumed   = 0

      @db.transaction do
        chunk.each_line do |line|
          break unless line.end_with?("\n") # partial line — wait for the next refresh

          process_line(session_id, path, line)
          consumed += line.bytesize
        end

        if consumed.positive?
          @db.execute(
            "INSERT INTO file_offsets(path, byte_offset) VALUES (?, ?) " \
            "ON CONFLICT(path) DO UPDATE SET byte_offset = excluded.byte_offset",
            [path, offset + consumed]
          )
        end
      end
    end

    def stored_offset(path)
      row = @db.get_first_row("SELECT byte_offset FROM file_offsets WHERE path = ?", [path])
      row ? row[0].to_i : 0
    end

    def process_line(session_id, path, line)
      event = JSON.parse(line)
      ensure_session_row(session_id, path)

      case event["phase"]
      when "session_start"
        @db.execute("UPDATE sessions SET task = ?, provider = ?, model = ?, started_at = ? WHERE session_id = ?",
                    [event["task"], event["provider"], event["model"], event["at"], session_id])
      when "turn"
        @db.execute("UPDATE sessions SET turn = ? WHERE session_id = ?", [event["n"], session_id])
      when "iteration"
        @db.execute("UPDATE sessions SET iteration = ? WHERE session_id = ?", [event["n"], session_id])
      when "tool_call"
        push_pending_call(session_id, event["name"], event["args"])
      when "tool_result"
        handle_tool_result(session_id, pop_pending_call(session_id), event)
      end

      touch_last_seen(session_id, event["at"])
    rescue JSON::ParserError
      nil # tolerate a torn line defensively; the byte range is still consumed
    end

    def ensure_session_row(session_id, path)
      @db.execute("INSERT OR IGNORE INTO sessions(session_id, path) VALUES (?, ?)", [session_id, path])
    end

    def touch_last_seen(session_id, at)
      return unless at

      @db.execute("UPDATE sessions SET last_seen_at = ? WHERE session_id = ?", [at, session_id])
    end

    def push_pending_call(session_id, name, args)
      seq = @db.get_first_value("SELECT COALESCE(MAX(seq), 0) + 1 FROM pending_calls WHERE session_id = ?", [session_id])
      @db.execute("INSERT INTO pending_calls(session_id, seq, name, args) VALUES (?, ?, ?, ?)",
                  [session_id, seq, name, JSON.generate(args || {})])
    end

    # FIFO pop, matching Session#parse!'s own pending_calls pairing — see
    # player_journey_map.md Background on why this pairing can (rarely) be
    # wrong for reasons unrelated to this feature.
    def pop_pending_call(session_id)
      row = @db.get_first_row(
        "SELECT seq, name, args FROM pending_calls WHERE session_id = ? ORDER BY seq LIMIT 1", [session_id]
      )
      return {} unless row

      @db.execute("DELETE FROM pending_calls WHERE session_id = ? AND seq = ?", [session_id, row[0]])
      { name: row[1], args: JSON.parse(row[2] || "{}") }
    end

    def handle_tool_result(session_id, call, event)
      name = event["name"] || call[:name]
      return unless name

      turn, iteration = current_turn_iteration(session_id)

      if RoomEcho.location_tool?(name)
        parsed = RoomEcho.parse(event["result"])
        record_visit(session_id, call, parsed, event, turn, iteration) if parsed
      elsif SelfState.info_self?(name)
        kind = call[:args] && (call[:args]["kind"] || call[:args][:kind])
        record_self_state(session_id, kind, event, turn, iteration) if kind
      end
    end

    def current_turn_iteration(session_id)
      row = @db.get_first_row("SELECT turn, iteration FROM sessions WHERE session_id = ?", [session_id])
      row ? [row[0].to_i, row[1].to_i] : [0, 0]
    end

    def record_self_state(session_id, kind, event, turn, iteration)
      text = SelfState.summarize(event["result"])
      @db.execute(
        "INSERT INTO self_state(session_id, kind, text, turn, iteration, at) VALUES (?,?,?,?,?,?) " \
        "ON CONFLICT(session_id, kind) DO UPDATE SET " \
        "text = excluded.text, turn = excluded.turn, iteration = excluded.iteration, at = excluded.at",
        [session_id, kind, text, turn, iteration, event["at"]]
      )
    end

    def record_visit(session_id, call, parsed, event, turn, iteration)
      title = parsed[:title]
      upsert_room(title, parsed, session_id, turn, iteration, event["at"])

      direction  = call[:args] && (call[:args]["direction"] || call[:args][:direction])
      via        = direction || call[:name].to_s.split("__").last
      from_title = @db.get_first_value("SELECT last_room FROM sessions WHERE session_id = ?", [session_id])

      assign_coordinate(title, from_title, direction)

      if from_title && from_title != title
        @db.execute("INSERT OR IGNORE INTO edges(from_title, via, to_title) VALUES (?, ?, ?)",
                    [from_title, via, title])
      end

      @db.execute("UPDATE sessions SET last_room = ?, last_seen_at = ? WHERE session_id = ?",
                  [title, event["at"], session_id])
      @db.execute(
        "INSERT INTO visits(session_id, room_title, turn, iteration, at, arrived_via) VALUES (?,?,?,?,?,?)",
        [session_id, title, turn, iteration, event["at"], via]
      )
    end

    def upsert_room(title, parsed, session_id, turn, iteration, at)
      existing = @db.get_first_value("SELECT 1 FROM rooms WHERE title = ?", [title])
      if existing
        @db.execute("UPDATE rooms SET visit_count = visit_count + 1 WHERE title = ?", [title])
      else
        @db.execute(
          "INSERT INTO rooms(title, description, exits, visit_count, " \
          "first_seen_session, first_seen_turn, first_seen_iteration, first_seen_at) " \
          "VALUES (?, ?, ?, 1, ?, ?, ?, ?)",
          [title, parsed[:description], JSON.generate(parsed[:exits]), session_id, turn, iteration, at]
        )
      end

      parsed[:contents].each do |content|
        @db.execute("INSERT OR IGNORE INTO room_contents(room_title, content, first_seen_at) VALUES (?, ?, ?)",
                    [title, content, at])
      end
    end

    def room_coord(title)
      row = @db.get_first_row("SELECT coord_x, coord_y FROM rooms WHERE title = ?", [title])
      return nil unless row && row[0] && row[1]

      [row[0], row[1]]
    end

    # Placed once, ever — a room's coordinate never moves after that, so
    # the map doesn't reshuffle every time it's refreshed.
    def assign_coordinate(title, from_title, direction)
      return if room_coord(title)

      from_coord = from_title && room_coord(from_title)
      x, y =
        if from_coord.nil?
          [0.0, 0.0]
        else
          delta = DIRECTION_DELTA[direction.to_s]
          delta ? [from_coord[0] + delta[0], from_coord[1] + delta[1]] : next_free_slot_near(*from_coord)
        end

      @db.execute("UPDATE rooms SET coord_x = ?, coord_y = ? WHERE title = ?", [x, y, title])
    end

    def next_free_slot_near(ox, oy)
      FREE_SLOT_RING.each do |dx, dy|
        cx, cy = ox + dx, oy + dy
        occupied = @db.get_first_value("SELECT 1 FROM rooms WHERE coord_x = ? AND coord_y = ?", [cx, cy])
        return [cx, cy] unless occupied
      end
      [ox + rand, oy + rand] # exceedingly unlikely fallback
    end
  end
end
