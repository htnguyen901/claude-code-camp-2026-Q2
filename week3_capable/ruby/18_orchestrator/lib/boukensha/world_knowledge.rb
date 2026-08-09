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
    #
    # Two variants: GLOBAL ignores who examined it (today's behavior, used
    # when `player:` is nil — see #room_knowledge); PLAYER additionally
    # requires the examinations row to have come from one of that player's
    # own sessions (docs/plans/observability/players/
    # multiple_concurrent_players.md §2) — different characters have
    # different knowledge, even of the same room.
    GLOBAL_EXAMINED_EXISTS_SQL = <<~SQL.strip.freeze
      EXISTS (
        SELECT 1 FROM examinations ex
        WHERE ex.room_title = rc.room_title
          AND (LOWER(COALESCE(cf.subject, rc.content)) LIKE '%' || LOWER(ex.subject) || '%'
               OR LOWER(ex.subject) LIKE '%' || LOWER(COALESCE(cf.subject, rc.content)) || '%')
      )
    SQL

    PLAYER_EXAMINED_EXISTS_SQL = <<~SQL.strip.freeze
      EXISTS (
        SELECT 1 FROM examinations ex
        JOIN sessions s ON s.session_id = ex.session_id
        WHERE ex.room_title = rc.room_title
          AND s.player = ?
          AND (LOWER(COALESCE(cf.subject, rc.content)) LIKE '%' || LOWER(ex.subject) || '%'
               OR LOWER(ex.subject) LIKE '%' || LOWER(COALESCE(cf.subject, rc.content)) || '%')
      )
    SQL

    # Same fuzzy match as *_EXAMINED_EXISTS_SQL, but returns the actual
    # `examinations.result_text` — what `examine`/`look at` printed back —
    # instead of a boolean. Mirrors log_viz's WorldMap#EXAMINATION_RESULT_SQL
    # for the same different-load-path reason; keep both in sync if this
    # drifts.
    GLOBAL_EXAMINATION_RESULT_SQL = <<~SQL.strip.freeze
      (
        SELECT ex.result_text FROM examinations ex
        WHERE ex.room_title = rc.room_title
          AND (LOWER(COALESCE(cf.subject, rc.content)) LIKE '%' || LOWER(ex.subject) || '%'
               OR LOWER(ex.subject) LIKE '%' || LOWER(COALESCE(cf.subject, rc.content)) || '%')
        ORDER BY ex.at DESC LIMIT 1
      )
    SQL

    PLAYER_EXAMINATION_RESULT_SQL = <<~SQL.strip.freeze
      (
        SELECT ex.result_text FROM examinations ex
        JOIN sessions s ON s.session_id = ex.session_id
        WHERE ex.room_title = rc.room_title
          AND s.player = ?
          AND (LOWER(COALESCE(cf.subject, rc.content)) LIKE '%' || LOWER(ex.subject) || '%'
               OR LOWER(ex.subject) LIKE '%' || LOWER(COALESCE(cf.subject, rc.content)) || '%')
        ORDER BY ex.at DESC LIMIT 1
      )
    SQL

    def self.db_path
      ENV["LOG_VIZ_WORLD_MAP_DB"] || DEFAULT_DB_PATH
    end

    # room_knowledge(room_title:, player:) ->
    #   { room_title:, examined: [{subject:, result:}, ...], unexamined: [...subjects] }
    #   or, if `player` has never visited this room:
    #   { room_title:, examined: [], unexamined: [], note: "you have not been here" }
    #
    # `player` is the calling character's name (Boukensha::PlayerProfile#name,
    # threaded from boukensha_loader.rb's `--player` flag), or nil.
    # nil means "no player identity for this run" — the historical,
    # un-scoped, whole-map-visible behavior (backward compatible: a run
    # launched without --player, or a session logged before this feature
    # existed, per multiple_concurrent_players.md's "Known tradeoffs").
    # A non-nil player is scoped two ways: (1) a room that player's own
    # sessions have never visited answers "you have not been here" instead
    # of leaking what other characters found there; (2) within a visited
    # room, "examined" only counts examinations from that player's own
    # sessions — a different character examining the same subject in the
    # same room doesn't count as this player already knowing it.
    #
    # `subjects`/`examined[].subject` are content_facts.subject strings
    # (LLM-extracted head nouns — "fountain", "cityguard" — not raw
    # room-content lines). `examined[].result` is the actual text the room
    # printed back for that examine/look-at (see *_EXAMINATION_RESULT_SQL) —
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
    def self.room_knowledge(room_title:, player:)
      return { room_title: room_title, examined: [], unexamined: [] } unless File.exist?(db_path)

      db = SQLite3::Database.new(db_path, readonly: true)
      db.busy_timeout = 5000

      if player && !player_visited_room?(db, room_title, player)
        return { room_title: room_title, examined: [], unexamined: [],
                 note: "you have not been here" }
      end

      {
        room_title: room_title,
        examined: examined_subjects(db, room_title, player),
        unexamined: subjects(db, room_title, examined: false, player: player)
      }
    rescue SQLite3::Exception => e
      warn "[Boukensha::WorldKnowledge] room_knowledge query failed: #{e.message}"
      { room_title: room_title, examined: [], unexamined: [] }
    ensure
      db&.close
    end

    def self.player_visited_room?(db, room_title, player)
      !!db.get_first_value(
        "SELECT 1 FROM visits v JOIN sessions s ON s.session_id = v.session_id " \
        "WHERE v.room_title = ? AND s.player = ? LIMIT 1",
        [room_title, player]
      )
    end
    private_class_method :player_visited_room?

    def self.examined_exists_sql(player)
      player ? [PLAYER_EXAMINED_EXISTS_SQL, [player]] : [GLOBAL_EXAMINED_EXISTS_SQL, []]
    end
    private_class_method :examined_exists_sql

    def self.examination_result_sql(player)
      player ? [PLAYER_EXAMINATION_RESULT_SQL, [player]] : [GLOBAL_EXAMINATION_RESULT_SQL, []]
    end
    private_class_method :examination_result_sql

    def self.subjects(db, room_title, examined:, player:)
      exists_sql, exists_params = examined_exists_sql(player)
      sql = <<~SQL
        SELECT DISTINCT cf.subject
        FROM room_contents rc
        JOIN content_facts cf ON cf.raw = rc.content
        WHERE rc.room_title = ? AND cf.subject IS NOT NULL
          AND #{examined ? '' : 'NOT '}#{exists_sql}
      SQL
      db.execute(sql, [room_title] + exists_params).map { |r| r[0] }
    end
    private_class_method :subjects

    def self.examined_subjects(db, room_title, player)
      result_sql, result_params = examination_result_sql(player)
      exists_sql, exists_params = examined_exists_sql(player)
      sql = <<~SQL
        SELECT DISTINCT cf.subject, #{result_sql}
        FROM room_contents rc
        JOIN content_facts cf ON cf.raw = rc.content
        WHERE rc.room_title = ? AND cf.subject IS NOT NULL
          AND #{exists_sql}
      SQL
      params = result_params + [room_title] + exists_params
      db.execute(sql, params).map { |subject, result| { subject: subject, result: result } }
    end
    private_class_method :examined_subjects
  end
end
