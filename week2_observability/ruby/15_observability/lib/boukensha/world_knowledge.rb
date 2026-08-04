require "sqlite3"

module Boukensha
  # Read-only view into log_viz's `world_map.sqlite3` — the one deliberate
  # two-way coupling this step (13_room_inspector) introduces between the
  # agent and a schema `log_viz` owns (content_facts/examinations/rooms).
  # See docs/plans/observability/room_world_inspector.md §3: `log_viz`
  # depends one-way on the agent's `.jsonl` log format; this is the
  # opposite direction. Keep the query surface here small and self-
  # contained so a schema change is a one-place update on each side.
  #
  # boukensha itself still has no concept of a MUD or a "room" beyond this
  # one module — nothing else in the framework changes. The Player agent
  # decides, on its own, whether calling this tool is useful; nothing
  # injects this into its context automatically (see the plan's "Not
  # doing" section).
  module WorldKnowledge
    DEFAULT_DB_PATH = File.expand_path("../../../../../.boukensha/world_map.sqlite3", __dir__)

    # A player-typed examine/look-at target rarely matches a
    # content_facts.subject (LLM-extracted head noun) verbatim, so "was
    # this examined" is a case-insensitive substring match in either
    # direction, scoped to the room — mirrors log_viz's WorldMap exactly
    # (log_viz/lib/log_viz/world_map.rb's EXAMINED_EXISTS_SQL). Duplicated
    # rather than shared because the two live in different Ruby load
    # paths/processes; if this drifts from log_viz's copy, fix both.
    EXAMINED_EXISTS_SQL = <<~SQL.strip.freeze
      EXISTS (
        SELECT 1 FROM examinations ex
        WHERE ex.room_title = rc.room_title
          AND (LOWER(COALESCE(cf.subject, rc.content)) LIKE '%' || LOWER(ex.subject) || '%'
               OR LOWER(ex.subject) LIKE '%' || LOWER(COALESCE(cf.subject, rc.content)) || '%')
      )
    SQL

    # Same fuzzy match as EXAMINED_EXISTS_SQL, but returns the actual
    # `examinations.result_text` — what `examine`/`look at` printed back —
    # instead of a boolean. Without this, "examined" was a checkbox with no
    # memory of *what* was learned, which defeats the point: an examine
    # result can hold a real clue (an NPC's dialogue, an item's fine print)
    # the agent may want to recall several turns later instead of re-issuing
    # the same `examine` call. Mirrors log_viz's WorldMap#EXAMINATION_RESULT_SQL
    # (log_viz/lib/log_viz/world_map.rb) — duplicated for the same
    # different-load-path reason as EXAMINED_EXISTS_SQL above; keep both in
    # sync if this drifts.
    EXAMINATION_RESULT_SQL = <<~SQL.strip.freeze
      (
        SELECT ex.result_text FROM examinations ex
        WHERE ex.room_title = rc.room_title
          AND (LOWER(COALESCE(cf.subject, rc.content)) LIKE '%' || LOWER(ex.subject) || '%'
               OR LOWER(ex.subject) LIKE '%' || LOWER(COALESCE(cf.subject, rc.content)) || '%')
        ORDER BY ex.at DESC LIMIT 1
      )
    SQL

    def self.db_path
      ENV["LOG_VIZ_WORLD_MAP_DB"] || DEFAULT_DB_PATH
    end

    # room_knowledge(room_title:) ->
    #   { room_title:, examined: [{subject:, result:}, ...], unexamined: [...subjects] }
    #
    # `subjects`/`examined[].subject` are content_facts.subject strings
    # (LLM-extracted head nouns — "fountain", "cityguard" — not raw
    # room-content lines). `examined[].result` is the actual text the room
    # printed back for that examine/look-at (see EXAMINATION_RESULT_SQL) —
    # the point of tracking "examined" at all is that the answer can be a
    # real clue (an NPC's dialogue, an item's fine print) worth recalling
    # later without spending a turn re-examining it; a bare yes/no would
    # have thrown that away. `unexamined` stays a plain subject list — there
    # is by definition no result to report yet.
    #
    # `room_title` must be the exact room title, e.g. as it appeared in the
    # agent's own last `look`/`move` result — already in its own context,
    # so no cross-process "what room am I in" tracking is needed on this
    # end (the plan flags this as a possible future addition; this pass
    # keeps it simple and explicit instead of guessing).
    #
    # Opens the database read-only; WAL mode (already enabled by
    # `LogViz::WorldMap#connect!`) is exactly what makes this safe to run
    # concurrently with log_viz's own reads/writes and its background
    # content-fact worker thread. Never raises: a missing database (log_viz
    # has never run), a missing room, or any SQLite error all degrade to an
    # empty-but-valid result — an observability signal must never break the
    # player's turn.
    def self.room_knowledge(room_title:)
      return { room_title: room_title, examined: [], unexamined: [] } unless File.exist?(db_path)

      db = SQLite3::Database.new(db_path, readonly: true)
      db.busy_timeout = 5000
      {
        room_title: room_title,
        examined: examined_subjects(db, room_title),
        unexamined: subjects(db, room_title, examined: false)
      }
    rescue SQLite3::Exception => e
      warn "[Boukensha::WorldKnowledge] room_knowledge query failed: #{e.message}"
      { room_title: room_title, examined: [], unexamined: [] }
    ensure
      db&.close
    end

    def self.subjects(db, room_title, examined:)
      sql = <<~SQL
        SELECT DISTINCT cf.subject
        FROM room_contents rc
        JOIN content_facts cf ON cf.raw = rc.content
        WHERE rc.room_title = ? AND cf.subject IS NOT NULL
          AND #{examined ? '' : 'NOT '}#{EXAMINED_EXISTS_SQL}
      SQL
      db.execute(sql, [room_title]).map { |r| r[0] }
    end
    private_class_method :subjects

    def self.examined_subjects(db, room_title)
      sql = <<~SQL
        SELECT DISTINCT cf.subject, #{EXAMINATION_RESULT_SQL}
        FROM room_contents rc
        JOIN content_facts cf ON cf.raw = rc.content
        WHERE rc.room_title = ? AND cf.subject IS NOT NULL
          AND #{EXAMINED_EXISTS_SQL}
      SQL
      db.execute(sql, [room_title]).map { |subject, result| { subject: subject, result: result } }
    end
    private_class_method :examined_subjects
  end
end
