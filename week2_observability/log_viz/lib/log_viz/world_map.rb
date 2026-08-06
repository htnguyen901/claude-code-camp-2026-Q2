require "sqlite3"
require "json"
require "fileutils"
require "time"

require_relative "room_echo"
require_relative "self_state"
require_relative "content_fact"
require_relative "settings"

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

    # How often the background content-fact worker (see below) checks for
    # newly-discovered, still-unclassified room-content strings when it has
    # nothing to do. Latency here is explicitly accepted — see
    # docs/plans/observability/room_world_inspector.md §1 feedback #1.
    CONTENT_FACT_POLL_INTERVAL = 3

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

    # Tool names (post `__` prefix strip) whose result is a targeted
    # inspection rather than a room-wide look — `examine <target>` always,
    # `look` only when called with a `target` (a bare `look` is handled by
    # `RoomEcho.location_tool?` instead). See #handle_tool_result.
    EXAMINE_VERBS = %w[examine look].freeze

    # Minimum time a `source: "fallback"` content_fact must sit before
    # `next_unclassified_content` will offer it for retry again. Without
    # this, a persistently-failing row (Ollama still down, or one
    # malformed reply after another) would be re-selected on literally
    # every loop iteration with zero delay — turning
    # `#backfill_content_facts!` into an infinite loop that never returns,
    # and the background worker into a busy-spin hammering Ollama with no
    # `sleep` between attempts (the `if raw.nil?` branch that sleeps never
    # triggers if a row is always available). 5 minutes roughly matches
    # Ollama's own default model keep-alive window — not hammering a
    # daemon that just isn't warmed up yet, while still self-healing
    # automatically once it is.
    DEFAULT_CONTENT_FACT_RETRY_COOLDOWN = 300

    # A player-typed examine/look-at target (e.g. "fountain") rarely matches
    # a `content_facts.subject` (LLM-extracted head noun, e.g. "large stone
    # fountain") verbatim, so "was this examined" is a case-insensitive
    # substring match in either direction, scoped to the room — a known,
    # stated imprecision (room_world_inspector.md "Known tradeoffs"), not
    # silently hidden. Shared by `#discoveries`' `examined` flag and
    # `#unexamined_in`/`#examined_in`.
    EXAMINED_EXISTS_SQL = <<~SQL.strip.freeze
      EXISTS (
        SELECT 1 FROM examinations ex
        WHERE ex.room_title = rc.room_title
          AND (LOWER(COALESCE(cf.subject, rc.content)) LIKE '%' || LOWER(ex.subject) || '%'
               OR LOWER(ex.subject) LIKE '%' || LOWER(COALESCE(cf.subject, rc.content)) || '%')
      )
    SQL

    # Companion to EXAMINED_EXISTS_SQL — same fuzzy match, but returns the
    # actual `examinations.result_text` (what `examine`/`look at` printed,
    # captured by #record_examination) instead of a boolean. This is the
    # "keeper" for examination results: the whole reason to track "was this
    # examined" is that the answer the room gave back can be a real clue
    # (an item description, an NPC's dialogue) worth surfacing later, not
    # just a checkbox. A subject can, in principle, fuzzy-match more than
    # one distinct typed target in the same room ("grocer" examined once as
    # "grocer", once as "the grocer") — ORDER BY ... LIMIT 1 picks the most
    # recent deterministically rather than concatenating; a discoveries row
    # answers "what did I last learn examining this," not "list every
    # phrasing that ever hit it."
    EXAMINATION_RESULT_SQL = <<~SQL.strip.freeze
      (
        SELECT ex.result_text FROM examinations ex
        WHERE ex.room_title = rc.room_title
          AND (LOWER(COALESCE(cf.subject, rc.content)) LIKE '%' || LOWER(ex.subject) || '%'
               OR LOWER(ex.subject) LIKE '%' || LOWER(COALESCE(cf.subject, rc.content)) || '%')
        ORDER BY ex.at DESC LIMIT 1
      )
    SQL

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
      CREATE INDEX IF NOT EXISTS idx_rooms_first_seen ON rooms(first_seen_at);

      CREATE TABLE IF NOT EXISTS room_contents (
        room_title TEXT NOT NULL,
        content TEXT NOT NULL,
        first_seen_at TEXT,
        PRIMARY KEY (room_title, content)
      );
      CREATE INDEX IF NOT EXISTS idx_room_contents_content ON room_contents(content);

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

      -- `player` (Boukensha::PlayerProfile#name, from the session_start
      -- event's `player` field — see docs/plans/observability/players/
      -- multiple_concurrent_players.md §1) is nullable: a run launched
      -- without --player, or any session logged before this feature
      -- existed, stays player: NULL — an explicit, visible gap rather than
      -- a guess (see the plan's "Known tradeoffs"). New databases get the
      -- column via this CREATE TABLE; existing ones get it via the guarded
      -- ALTER TABLE in #migrate_sessions_player_column! (CREATE TABLE IF
      -- NOT EXISTS doesn't retrofit columns onto an already-existing
      -- table).
      CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY, path TEXT,
        task TEXT, provider TEXT, model TEXT, started_at TEXT,
        last_room TEXT, last_seen_at TEXT,
        turn INTEGER NOT NULL DEFAULT 0, iteration INTEGER NOT NULL DEFAULT 0,
        player TEXT
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

      -- Structured, LLM-extracted (see ContentFact) reading of one unique
      -- raw `room_contents.content` string — cached by content, never a
      -- second source of truth over `room_contents.content` itself (see
      -- room_world_inspector.md §1). `source` is "llm" or "fallback"
      -- (Ollama unreachable/malformed reply — kind stays "unknown").
      CREATE TABLE IF NOT EXISTS content_facts (
        content_hash TEXT PRIMARY KEY,
        raw TEXT NOT NULL,
        subject TEXT,
        kind TEXT,
        clause TEXT,
        source TEXT,
        extracted_at TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_content_facts_raw ON content_facts(raw);
      CREATE INDEX IF NOT EXISTS idx_content_facts_subject ON content_facts(subject);
      CREATE INDEX IF NOT EXISTS idx_content_facts_kind ON content_facts(kind);

      -- First-ever `examine`/`look at <target>` per (room, typed target) —
      -- turns "did the player really inspect it?" into a queryable fact
      -- (room_world_inspector.md §2). `subject` is the player-typed target
      -- text, lowercased, NOT a resolved content_facts.subject (that
      -- resolution happens at read time via EXAMINED_EXISTS_SQL, since
      -- content-fact classification runs asynchronously and may not exist
      -- yet at the moment of the examine call).
      CREATE TABLE IF NOT EXISTS examinations (
        room_title TEXT NOT NULL,
        subject TEXT NOT NULL,
        session_id TEXT,
        turn INTEGER, iteration INTEGER, at TEXT, result_text TEXT,
        PRIMARY KEY (room_title, subject)
      );

      -- Tracks whether a room's free-form `rooms.description` paragraph has
      -- been scanned for embedded mentions (ContentFact.extract_mentions) —
      -- things narrated in prose ("A small note hangs on the wall.") that
      -- never get their own itemized room_contents line, since CircleMUD
      -- only itemizes trailing "X is here" lines after `[ Exits: ... ]`.
      -- One row per room (unlike content_facts, keyed by unique string —
      -- a description belongs to exactly one room, no cross-room reuse to
      -- dedupe). `source` is "llm" (scanned, possibly zero mentions found)
      -- or "fallback" (the scan itself failed — retry-eligible, same
      -- shape as content_facts).
      CREATE TABLE IF NOT EXISTS room_description_scans (
        room_title TEXT PRIMARY KEY,
        source TEXT,
        scanned_at TEXT
      );
    SQL

    def self.instance(sessions_dir:, db_path: nil)
      @instances ||= {}
      key = [sessions_dir, db_path]
      @instances[key] ||= new(sessions_dir: sessions_dir, db_path: db_path)
    end

    def self.reset_instances!
      @instances.each_value(&:shutdown!) if @instances
      @instances = {}
    end

    # content_fact_worker: set false to disable the background LLM
    # extraction thread entirely (tests, or a one-off script like
    # bin/backfill_content_facts that does its own synchronous pass).
    # content_fact_extractor / description_mention_extractor: injectable
    # for tests — default to real Ollama calls via ContentFact.extract /
    # ContentFact.extract_mentions, configured from `.boukensha/settings
    # .yaml`'s `tasks.content_fact` block (see `Settings`), same "task"
    # shape as `tasks.player`. Both are used by the same background worker
    # (see #content_fact_worker_loop) and the same one-off backfill script.
    # content_fact_retry_cooldown: seconds a `fallback` row/scan must sit
    # before being retried (see DEFAULT_CONTENT_FACT_RETRY_COOLDOWN). Pass
    # 0 for "always retry immediately" — deterministic tests, or a one-off
    # script where a human explicitly asked to try again right now.
    def initialize(sessions_dir:, db_path: nil, content_fact_worker: true, content_fact_extractor: nil,
                   description_mention_extractor: nil,
                   content_fact_retry_cooldown: DEFAULT_CONTENT_FACT_RETRY_COOLDOWN)
      @sessions_dir = sessions_dir
      @db_path      = db_path || File.join(File.dirname(sessions_dir), "world_map.sqlite3")
      @mutex        = Mutex.new
      @content_fact_extractor         = content_fact_extractor || default_content_fact_extractor
      @description_mention_extractor  = description_mention_extractor || default_description_mention_extractor
      @content_fact_retry_cooldown    = content_fact_retry_cooldown
      @content_fact_stop              = true
      FileUtils.mkdir_p(File.dirname(@db_path))
      open_db!
      start_content_fact_worker! if content_fact_worker
    end

    def refresh!
      @mutex.synchronize do
        Dir.glob(File.join(@sessions_dir, "*.jsonl")).sort.each { |path| ingest_new_lines(path) }
      end
      self
    end

    # Stops the background content-fact worker thread, if running. Safe to
    # call more than once. Tests that enable the worker should call this in
    # teardown so a leaked thread doesn't keep hitting a since-removed tmp
    # database.
    def shutdown!
      @content_fact_stop = true
    end

    # Synchronously classifies every currently-unclassified-or-`fallback`
    # room_contents row — the one-off migration path
    # (bin/backfill_content_facts) for getting existing history classified
    # immediately rather than waiting for the background worker to catch up
    # organically (see room_world_inspector.md "Schema migration"). Yields
    # (count, raw) after each classification if a block is given, for
    # progress reporting. Don't call this on an instance whose background
    # worker is also running against the same db_path — construct with
    # `content_fact_worker: false` for backfill use.
    #
    # Fetches the candidate list ONCE and processes each exactly once —
    # deliberately NOT the "keep asking for the next unclassified row until
    # there isn't one" loop `next_unclassified_content`/the background
    # worker use. That pattern only terminates if every row eventually
    # succeeds; a row that always fails would make it either loop forever
    # (each retry immediately re-qualifies) or never retry within one call
    # depending on exactly where a wall-clock second boundary falls —
    # neither of which is what "classify the backlog once" should mean.
    # Also, unlike the background worker's `next_unclassified_content`,
    # this ignores `@content_fact_retry_cooldown` entirely: running this
    # script IS the human explicitly asking to retry every stuck `fallback`
    # row right now, not something that should wait out a rate limit meant
    # for the *unattended* background worker.
    def backfill_content_facts!
      candidates = pending_content_facts(@db)
      candidates.each_with_index do |raw, i|
        store_content_fact(@db, raw, safe_extract(raw))
        yield(i + 1, raw) if block_given?
      end
      candidates.length
    end

    # Synchronously scans every currently-unscanned-or-`fallback` room
    # description for embedded mentions — the companion one-off migration
    # path to #backfill_content_facts! (see room_world_inspector.md
    # "Follow-up: description-embedded mentions"). Same "fetch the
    # candidate list once, process each exactly once, ignore the retry
    # cooldown" shape, for the same reason. Yields (count, room_title)
    # after each scan if a block is given.
    def backfill_description_mentions!
      candidates = pending_description_scans(@db)
      candidates.each_with_index do |(title, description), i|
        scan_description_for_mentions(@db, title, description)
        yield(i + 1, title) if block_given?
      end
      candidates.length
    end

    # ---------- read accessors for the view layer ----------

    # All rooms, unfiltered — used by the map SVG (needs every coordinate
    # regardless of what the Rooms table below it is currently filtered to)
    # and the header room count.
    def rooms
      @db.execute(
        "SELECT title, description, exits, coord_x, coord_y, visit_count, " \
        "first_seen_session, first_seen_turn, first_seen_iteration, first_seen_at FROM rooms"
      ).map { |row| room_row_to_h(row) }
    end

    # Search/filter + keyset-paginated room listing for the Rooms table
    # (room_world_inspector.md §4) — `q` matches title/description
    # substring, `before` is a first_seen_at cursor for "older than this
    # page's last row." `limit: nil` returns everything (used internally,
    # e.g. by /map/live.json's "new since" count). `room_titles:` is an
    # optional allowlist (world_map_enhancer.md §5) — scopes the listing to
    # one player's own `rooms_visited_by(name)` set for the /players/:name/
    # rooms route; nil (default) is a no-op, today's unfiltered behavior.
    def rooms_matching(q: nil, before: nil, limit: 50, room_titles: nil)
      where, params = [], []

      if present?(q)
        where << "(LOWER(title) LIKE ? OR LOWER(COALESCE(description, '')) LIKE ?)"
        like = "%#{q.strip.downcase}%"
        params.push(like, like)
      end
      if present?(before)
        where << "first_seen_at < ?"
        params << before
      end
      if room_titles
        return [] if room_titles.empty?

        where << "title IN (#{room_titles.map { '?' }.join(',')})"
        params.concat(room_titles)
      end

      sql = "SELECT title, description, exits, coord_x, coord_y, visit_count, " \
            "first_seen_session, first_seen_turn, first_seen_iteration, first_seen_at FROM rooms"
      sql += " WHERE #{where.join(' AND ')}" unless where.empty?
      sql += " ORDER BY first_seen_at DESC"
      if limit
        sql += " LIMIT ?"
        params << limit
      end

      @db.execute(sql, params).map { |row| room_row_to_h(row) }
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
    # with the room(s) it was seen in, when first seen, its content-fact
    # classification (subject/kind/clause — nil/"unknown" if not yet
    # classified by the background worker), and whether it's ever been the
    # target of an examine/look-at anywhere it appears — the "discoveries"
    # panel's data source (player_journey_map.md §4,
    # room_world_inspector.md §1/§2/§4).
    #
    # `q` matches substring on the raw content OR the extracted subject;
    # `kind` filters on content_facts.kind ("unknown" for unclassified);
    # `room`/`before` scope to a room / page cursor, same shape as
    # `rooms_matching`. `examined` (true/false/nil) filters on the
    # examined flag; nil means "don't filter." `limit: nil` returns
    # everything. `examination_result` is the actual text the room printed
    # back for the examine/look-at that set the `examined` flag (nil when
    # not examined, or — rarely — when a fuzzy-matched `examinations` row
    # predates result_text being captured) — see EXAMINATION_RESULT_SQL.
    # `room_titles:` is the same optional allowlist as `rooms_matching`
    # (world_map_enhancer.md §5) — scopes to one player's own visited rooms.
    def discoveries(q: nil, kind: nil, room: nil, examined: nil, before: nil, limit: 50, room_titles: nil)
      where, params = discoveries_where(q: q, kind: kind, room: room, examined: examined, before: before,
                                         room_titles: room_titles)
      return [] if where == "0=1"

      sql = <<~SQL
        SELECT rc.content, MIN(rc.first_seen_at) AS earliest,
               MAX(cf.subject) AS subject, MAX(COALESCE(cf.kind, 'unknown')) AS kind,
               MAX(cf.clause) AS clause, GROUP_CONCAT(DISTINCT rc.room_title) AS rooms,
               MAX(#{EXAMINED_EXISTS_SQL}) AS examined,
               MAX(#{EXAMINATION_RESULT_SQL}) AS examination_result
        FROM room_contents rc
        LEFT JOIN content_facts cf ON cf.raw = rc.content
        WHERE #{where}
        GROUP BY rc.content
        ORDER BY earliest DESC
      SQL
      if limit
        sql += " LIMIT ?"
        params += [limit]
      end

      @db.execute(sql, params).map do |content, earliest, subject, kind_val, clause, rooms, examined_val, examination_result|
        {
          content: content, first_seen_at: earliest, subject: subject,
          kind: kind_val, clause: clause, rooms: rooms.to_s.split(","),
          examined: examined_val.to_i == 1,
          examination_result: examination_result
        }
      end
    end

    # Subjects (content_facts.subject) seen in `room_title` that have never
    # been the target of an examine/look-at in that room — the queryable
    # answer to "did the player really inspect it?" (room_world_inspector
    # .md §2). Companion `examined_in` returns the complement. Both back
    # the `room_knowledge` agent tool (§3) and the UI's per-room markers.
    def unexamined_in(room_title)
      subjects_in_room(room_title, examined: false)
    end

    def examined_in(room_title)
      subjects_in_room(room_title, examined: true)
    end

    def sessions
      @db.execute(
        "SELECT session_id, path, task, provider, model, started_at, " \
        "last_room, last_seen_at, turn, iteration, player FROM sessions"
      ).map { |row| session_row_to_h(row) }
    end

    # Every room `player`'s own sessions have ever visited — the backbone of
    # both per-player knowledge isolation (Boukensha::WorldKnowledge#
    # room_knowledge, agent-side) and the discovered-vs-discoverable KPI
    # (#player_summary) — see docs/plans/observability/players/
    # multiple_concurrent_players.md §2/§3.
    def rooms_visited_by(player)
      @db.execute(
        "SELECT DISTINCT room_title FROM visits WHERE session_id IN " \
        "(SELECT session_id FROM sessions WHERE player = ?)", [player]
      ).map { |r| r[0] }
    end

    # One row per distinct tagged player — session count, total turns/
    # iterations across every session, first/last-seen timestamps, and
    # whether any of their sessions is currently live (same LIVE_WINDOW_
    # SECONDS heuristic /map already uses) with its current room. Backs
    # the /players index page.
    def players
      live_by_player = live_sessions.each_with_object({}) { |s, h| h[s[:player]] ||= s }

      @db.execute(
        "SELECT player, COUNT(*), SUM(turn), SUM(iteration), MIN(started_at), MAX(last_seen_at) " \
        "FROM sessions WHERE player IS NOT NULL AND player != '' GROUP BY player " \
        "ORDER BY MAX(last_seen_at) DESC"
      ).map do |player, session_count, turns, iterations, first_seen, last_seen|
        live = live_by_player[player]
        {
          player: player, session_count: session_count.to_i,
          total_turns: turns.to_i, total_iterations: iterations.to_i,
          first_seen_at: first_seen, last_seen_at: last_seen,
          live: !live.nil?, current_room: live && live[:last_room]
        }
      end
    end

    # This player's own session list plus the "discovered vs. discoverable"
    # numbers for the KPI card (§4) — discoverable is "what's been found by
    # anyone so far" (the engineer's current global totals), not a claim
    # about the MUD's true size (nothing in this stack knows that). Token/
    # cost totals aren't computed here — the caller (log_viz's /players/:name
    # route) sums those per session via LogViz::Session, the same "cost math
    # lives in Session" boundary player_journey_map.md already established.
    def player_summary(name)
      player_sessions = sessions.select { |s| s[:player] == name }
      visited_rooms    = rooms_visited_by(name)

      {
        player: name,
        sessions: player_sessions,
        rooms_discovered: visited_rooms.length,
        rooms_discoverable: rooms.length,
        subjects_discovered: subjects_in_rooms(visited_rooms).length,
        subjects_discoverable: all_subjects.length
      }
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

    def present?(value)
      !value.to_s.strip.empty?
    end

    def room_row_to_h(row)
      {
        title: row[0], description: row[1], exits: JSON.parse(row[2] || "[]"),
        coord: (row[3] && row[4]) ? [row[3], row[4]] : nil,
        visit_count: row[5].to_i,
        first_seen: { session_id: row[6], turn: row[7], iteration: row[8], at: row[9] }
      }
    end

    def discoveries_where(q:, kind:, room:, examined:, before:, room_titles: nil)
      return ["0=1", []] if room_titles&.empty?

      where, params = ["1=1"], []

      if room_titles
        where << "rc.room_title IN (#{room_titles.map { '?' }.join(',')})"
        params.concat(room_titles)
      end
      if present?(q)
        where << "(LOWER(rc.content) LIKE ? OR LOWER(COALESCE(cf.subject, '')) LIKE ?)"
        like = "%#{q.strip.downcase}%"
        params.push(like, like)
      end
      if present?(kind)
        where << "COALESCE(cf.kind, 'unknown') = ?"
        params << kind
      end
      if present?(room)
        where << "rc.room_title = ?"
        params << room
      end
      if present?(before)
        where << "rc.first_seen_at < ?"
        params << before
      end
      unless examined.nil?
        where << "#{examined ? '' : 'NOT '}#{EXAMINED_EXISTS_SQL}"
      end

      [where.join(" AND "), params]
    end

    def subjects_in_room(room_title, examined:)
      sql = <<~SQL
        SELECT DISTINCT cf.subject
        FROM room_contents rc
        JOIN content_facts cf ON cf.raw = rc.content
        WHERE rc.room_title = ? AND cf.subject IS NOT NULL
          AND #{examined ? '' : 'NOT '}#{EXAMINED_EXISTS_SQL}
      SQL
      @db.execute(sql, [room_title]).map { |r| r[0] }
    end

    # Distinct content_facts.subject across a given set of rooms — the
    # "discovered" half of #player_summary's KPI numerator. Empty input ->
    # empty output without a query (an empty IN (...) is invalid SQL).
    def subjects_in_rooms(room_titles)
      return [] if room_titles.empty?

      placeholders = room_titles.map { "?" }.join(",")
      @db.execute(
        "SELECT DISTINCT cf.subject FROM room_contents rc " \
        "JOIN content_facts cf ON cf.raw = rc.content " \
        "WHERE rc.room_title IN (#{placeholders}) AND cf.subject IS NOT NULL",
        room_titles
      ).map { |r| r[0] }
    end

    # Distinct content_facts.subject across the whole map — the
    # "discoverable" (denominator) half of #player_summary's KPI.
    def all_subjects
      @db.execute("SELECT DISTINCT subject FROM content_facts WHERE subject IS NOT NULL").map { |r| r[0] }
    end

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
      migrate_sessions_player_column!
      @db.execute_batch("CREATE INDEX IF NOT EXISTS idx_sessions_player ON sessions(player);")
    end

    # Retrofits `sessions.player` onto a database created before this
    # column existed — CREATE TABLE IF NOT EXISTS (in SCHEMA, above) only
    # creates the table from scratch, it never alters an existing one.
    # Existing rows come back player: NULL, same as any other untagged
    # session (see the SCHEMA comment on this column).
    def migrate_sessions_player_column!
      columns = @db.execute("PRAGMA table_info(sessions)").map { |row| row[1] }
      return if columns.include?("player")

      @db.execute_batch("ALTER TABLE sessions ADD COLUMN player TEXT;")
    end

    # ---------- background content-fact extraction (room_world_inspector.md §1) ----------
    #
    # Reads `tasks.content_fact.{provider,model,host}` from
    # `.boukensha/settings.yaml` once, at construction time (see
    # `Settings`) — the same "task" configuration shape as `tasks.player`,
    # per the plan's follow-up. Only "ollama" is actually implemented
    # today; a different configured provider degrades to using Ollama
    # anyway (with a warning) rather than raising or silently ignoring the
    # setting — `provider:` exists for forward-compatibility (settings.yaml
    # is the one place to look, whether or not the backend exists yet), not
    # because a second backend is wired up.
    def default_content_fact_extractor
      provider = LogViz::Settings.content_fact_provider(@sessions_dir)
      model    = LogViz::Settings.content_fact_model(@sessions_dir)
      host     = LogViz::Settings.content_fact_host(@sessions_dir)

      unless provider == "ollama"
        warn "[LogViz::WorldMap] tasks.content_fact.provider=#{provider.inspect} isn't implemented yet — using ollama"
      end

      ->(raw) { ContentFact.extract(raw, host: host, model: model) }
    end

    # Same config source as #default_content_fact_extractor — one
    # `tasks.content_fact` block drives both the per-line classifier and
    # the description-mention scanner, since it's the same model doing two
    # kinds of extraction, not two separate subtasks.
    def default_description_mention_extractor
      model = LogViz::Settings.content_fact_model(@sessions_dir)
      host  = LogViz::Settings.content_fact_host(@sessions_dir)
      ->(description) { ContentFact.extract_mentions(description, host: host, model: model) }
    end

    # Runs on its own SQLite connection (not @db) so a slow/unreachable
    # Ollama call never contends with the main thread's request-handling
    # reads/writes — WAL mode (already turned on in #connect!) is exactly
    # what makes two independent connections to the same file safe. Feedback
    # on the plan explicitly accepted extraction latency in exchange for
    # this running "in parallel" rather than blocking ingestion — see
    # room_world_inspector.md §1 feedback #1.
    #
    # Two kinds of pending work share one loop/one thread: classifying a
    # content line takes priority (it's the smaller, faster unit of work),
    # then scanning a room description for embedded mentions, then sleep
    # once both queues are empty. Not two separate threads — one slow
    # unreachable-Ollama daemon already explains why either queue would be
    # empty-slash-stuck; a second thread wouldn't change that, just double
    # the idle polling.
    def start_content_fact_worker!
      return if @content_fact_thread&.alive?

      @content_fact_stop = false
      @content_fact_thread = Thread.new { content_fact_worker_loop }
    end

    def content_fact_worker_loop
      worker_db = SQLite3::Database.new(@db_path)
      worker_db.busy_timeout = 5000

      until @content_fact_stop
        if (raw = next_unclassified_content(worker_db))
          store_content_fact(worker_db, raw, safe_extract(raw))
        elsif (room = next_unscanned_room(worker_db))
          scan_description_for_mentions(worker_db, room[0], room[1])
        else
          sleep CONTENT_FACT_POLL_INTERVAL
        end
      end
    rescue StandardError => e
      warn "[LogViz::WorldMap] content-fact worker stopped unexpectedly: #{e.message}"
    ensure
      worker_db&.close
    end

    # A misbehaving injected extractor (or any bug in ContentFact.extract's
    # own rescue) must not be allowed to either wedge on one bad row forever
    # (the item just gets marked "unknown"/"fallback" like a real
    # unreachable-Ollama case) or kill the whole background worker thread —
    # same "never let an observability feature break ingestion" posture as
    # everywhere else in this class.
    def safe_extract(raw)
      @content_fact_extractor.call(raw)
    rescue StandardError => e
      warn "[LogViz::WorldMap] content-fact extractor raised for #{raw.to_s[0, 60].inspect}: #{e.message}"
      { subject: raw.to_s, kind: "unknown", clause: nil, source: "fallback" }
    end

    # Same defensive wrapper as #safe_extract, for the mention extractor —
    # ContentFact.extract_mentions already fails soft internally
    # (`source: "fallback"`), this only matters if an *injected* test
    # double misbehaves.
    def safe_extract_mentions(description)
      @description_mention_extractor.call(description)
    rescue StandardError => e
      warn "[LogViz::WorldMap] description-mention extractor raised for #{description.to_s[0, 60].inspect}: #{e.message}"
      { mentions: [], source: "fallback" }
    end

    # Never-attempted content always comes first (content_hash IS NULL);
    # `source = 'fallback'` rows (we tried and the extractor itself
    # failed — daemon unreachable, timed out, malformed reply) are
    # retry-eligible too, once at least `@content_fact_retry_cooldown`
    # seconds old — see DEFAULT_CONTENT_FACT_RETRY_COOLDOWN for why a
    # cooldown is required here, not optional. Ordered oldest-attempted-
    # first so, once several rows are past cooldown, persistent failure of
    # one doesn't starve retries of the others — each retry (successful or
    # not) bumps `extracted_at`, pushing it to the back of the queue.
    #
    # `source = 'llm'` rows are NOT retried, even when `kind: "unknown"` —
    # that means the model *was* reached and gave its real answer (a
    # genuinely ambiguous line), which is different from "we never
    # actually got to ask." Retrying those forever would just be wasted
    # calls for the same answer.
    def next_unclassified_content(db)
      cutoff = (Time.now.utc - @content_fact_retry_cooldown).iso8601
      db.get_first_value(
        "SELECT rc.content FROM room_contents rc " \
        "LEFT JOIN content_facts cf ON cf.raw = rc.content " \
        "WHERE cf.content_hash IS NULL " \
        "   OR (cf.source = 'fallback' AND cf.extracted_at < ?) " \
        "ORDER BY CASE WHEN cf.content_hash IS NULL THEN 0 ELSE 1 END, cf.extracted_at ASC " \
        "LIMIT 1",
        [cutoff]
      )
    end

    # The full backlog for #backfill_content_facts! — same eligibility as
    # `next_unclassified_content` (never-classified OR `fallback`), but
    # fetched as one bounded list with no cooldown check at all, since a
    # one-shot backfill run is itself the "please retry now" signal.
    def pending_content_facts(db)
      db.execute(
        "SELECT rc.content FROM room_contents rc " \
        "LEFT JOIN content_facts cf ON cf.raw = rc.content " \
        "WHERE cf.content_hash IS NULL OR cf.source = 'fallback' " \
        "GROUP BY rc.content " \
        "ORDER BY CASE WHEN MAX(cf.content_hash) IS NULL THEN 0 ELSE 1 END, MAX(cf.extracted_at) ASC"
      ).map { |r| r[0] }
    end

    # UPSERT, not INSERT OR IGNORE — a retry of a previously-`fallback`
    # row must be able to overwrite it once Ollama is actually reachable,
    # or (if it fails again) at least bump `extracted_at` so
    # `next_unclassified_content`'s ordering makes progress across
    # different failing rows instead of looping on the same one.
    def store_content_fact(db, raw, result)
      db.execute(
        "INSERT INTO content_facts(content_hash, raw, subject, kind, clause, source, extracted_at) " \
        "VALUES (?, ?, ?, ?, ?, ?, ?) " \
        "ON CONFLICT(content_hash) DO UPDATE SET " \
        "subject = excluded.subject, kind = excluded.kind, clause = excluded.clause, " \
        "source = excluded.source, extracted_at = excluded.extracted_at",
        [ContentFact.content_hash(raw), raw, result[:subject], result[:kind], result[:clause],
         result[:source], Time.now.utc.iso8601]
      )
    end

    # Same eligibility/ordering/cooldown shape as #next_unclassified_content
    # — see that method's comment; the only difference is the candidate is
    # a room (title + description), not a room_contents string, and a room
    # with no/blank description never qualifies (nothing to scan).
    def next_unscanned_room(db)
      cutoff = (Time.now.utc - @content_fact_retry_cooldown).iso8601
      db.get_first_row(
        "SELECT r.title, r.description FROM rooms r " \
        "LEFT JOIN room_description_scans s ON s.room_title = r.title " \
        "WHERE r.description IS NOT NULL AND r.description != '' " \
        "  AND (s.room_title IS NULL OR (s.source = 'fallback' AND s.scanned_at < ?)) " \
        "ORDER BY CASE WHEN s.room_title IS NULL THEN 0 ELSE 1 END, s.scanned_at ASC " \
        "LIMIT 1",
        [cutoff]
      )
    end

    # The full backlog for #backfill_description_mentions! — mirrors
    # #pending_content_facts (bounded, one fetch, no cooldown check).
    def pending_description_scans(db)
      db.execute(
        "SELECT r.title, r.description FROM rooms r " \
        "LEFT JOIN room_description_scans s ON s.room_title = r.title " \
        "WHERE r.description IS NOT NULL AND r.description != '' " \
        "  AND (s.room_title IS NULL OR s.source = 'fallback') " \
        "ORDER BY CASE WHEN s.room_title IS NULL THEN 0 ELSE 1 END, s.scanned_at ASC"
      )
    end

    # Extracts mentions from one room's description, stores each as its own
    # room_contents row (same table/shape a real itemized "X is here" line
    # would produce — the rest of the pipeline, discoveries/examined-
    # tracking/room_knowledge, doesn't need to know where a row came from)
    # plus its content_fact (already classified by this same call — no
    # second round-trip through #safe_extract), then records the scan
    # itself so it isn't repeated on every future visit to the room.
    def scan_description_for_mentions(db, room_title, description)
      result = safe_extract_mentions(description)
      result[:mentions].each do |m|
        db.execute("INSERT OR IGNORE INTO room_contents(room_title, content, first_seen_at) VALUES (?, ?, ?)",
                    [room_title, m[:quote], room_first_seen_at(db, room_title)])
        store_content_fact(db, m[:quote], { subject: m[:subject], kind: m[:kind], clause: m[:clause], source: "llm" })
      end
      store_description_scan(db, room_title, result[:source])
    end

    def room_first_seen_at(db, room_title)
      db.get_first_value("SELECT first_seen_at FROM rooms WHERE title = ?", [room_title]) || Time.now.utc.iso8601
    end

    def store_description_scan(db, room_title, source)
      db.execute(
        "INSERT INTO room_description_scans(room_title, source, scanned_at) VALUES (?, ?, ?) " \
        "ON CONFLICT(room_title) DO UPDATE SET source = excluded.source, scanned_at = excluded.scanned_at",
        [room_title, source, Time.now.utc.iso8601]
      )
    end

    def session_row_to_h(row)
      {
        session_id: row[0], path: row[1], task: row[2], provider: row[3], model: row[4],
        started_at: row[5], last_room: row[6], last_seen_at: row[7],
        turn: row[8].to_i, iteration: row[9].to_i, player: row[10]
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
        @db.execute("UPDATE sessions SET task = ?, provider = ?, model = ?, started_at = ?, player = ? WHERE session_id = ?",
                    [event["task"], event["provider"], event["model"], event["at"], event["player"], session_id])
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
      target = examine_target(call[:args])

      if RoomEcho.location_tool?(name) && target.nil?
        parsed = RoomEcho.parse(event["result"])
        record_visit(session_id, call, parsed, event, turn, iteration) if parsed
      elsif target && EXAMINE_VERBS.include?(name.to_s.split("__").last)
        record_examination(session_id, target, event, turn, iteration)
      elsif SelfState.info_self?(name)
        kind = call[:args] && (call[:args]["kind"] || call[:args][:kind])
        record_self_state(session_id, kind, event, turn, iteration) if kind
      end
    end

    def examine_target(args)
      return nil unless args

      target = args["target"] || args[:target]
      present?(target) ? target.to_s.strip : nil
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

    # First-ever examine/look-at of `target` in the player's current room
    # (`sessions.last_room` — set by the most recent recorded visit). No-op
    # if the player's current room isn't known yet (e.g. the very first
    # tool call of a session is an examine, before any `look`/`move`).
    def record_examination(session_id, target, event, turn, iteration)
      room_title = @db.get_first_value("SELECT last_room FROM sessions WHERE session_id = ?", [session_id])
      return unless room_title

      @db.execute(
        "INSERT OR IGNORE INTO examinations(room_title, subject, session_id, turn, iteration, at, result_text) " \
        "VALUES (?,?,?,?,?,?,?)",
        [room_title, target.downcase, session_id, turn, iteration, event["at"], RoomEcho.clean_reply(event["result"])]
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
