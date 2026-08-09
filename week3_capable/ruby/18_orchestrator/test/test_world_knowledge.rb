require_relative "helper"
require "sqlite3"
require "boukensha/world_knowledge"

# Exercises WorldKnowledge.room_knowledge against a throwaway sqlite3 file
# built with the slice of log_viz's world_map.sqlite3 schema
# (log_viz/lib/log_viz/world_map.rb's SCHEMA) this module depends on:
# room_contents/content_facts/examinations (the original coupling, see
# docs/plans/observability/room_world_inspector.md §3) plus sessions/visits
# (added for per-player scoping, docs/plans/observability/players/
# multiple_concurrent_players.md §2).
class TestWorldKnowledge < Minitest::Test
  def setup
    @tmp_dir = Dir.mktmpdir
    @db_path = File.join(@tmp_dir, "world_map.sqlite3")
    @old_env = ENV["LOG_VIZ_WORLD_MAP_DB"]
    ENV["LOG_VIZ_WORLD_MAP_DB"] = @db_path

    db = SQLite3::Database.new(@db_path)
    db.execute_batch(<<~SQL)
      CREATE TABLE room_contents (room_title TEXT, content TEXT, first_seen_at TEXT);
      CREATE TABLE content_facts (content_hash TEXT PRIMARY KEY, raw TEXT, subject TEXT, kind TEXT, clause TEXT, source TEXT, extracted_at TEXT);
      CREATE TABLE examinations (room_title TEXT, subject TEXT, session_id TEXT, turn INTEGER, iteration INTEGER, at TEXT, result_text TEXT, PRIMARY KEY (room_title, subject));
      CREATE TABLE sessions (session_id TEXT PRIMARY KEY, player TEXT);
      CREATE TABLE visits (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, room_title TEXT);
    SQL
    @db = db
  end

  def teardown
    @db.close
    ENV["LOG_VIZ_WORLD_MAP_DB"] = @old_env
    FileUtils.remove_entry(@tmp_dir)
  end

  def add_content(room_title, content, subject:, kind: "item")
    @db.execute("INSERT INTO room_contents(room_title, content, first_seen_at) VALUES (?, ?, ?)",
                [room_title, content, "2026-01-01T00:00:00Z"])
    @db.execute(
      "INSERT INTO content_facts(content_hash, raw, subject, kind, clause, source, extracted_at) VALUES (?,?,?,?,?,?,?)",
      [content, content, subject, kind, nil, "llm", "2026-01-01T00:00:00Z"]
    )
  end

  def add_examination(room_title, subject, result_text, session_id: "s1")
    @db.execute(
      "INSERT INTO examinations(room_title, subject, session_id, turn, iteration, at, result_text) VALUES (?,?,?,?,?,?,?)",
      [room_title, subject, session_id, 1, 1, "2026-01-01T00:00:00Z", result_text]
    )
  end

  # Tags a session with a player and records it having visited room_title —
  # the two facts WorldKnowledge's player-scoped queries join through.
  def add_visit(session_id, room_title, player:)
    @db.execute("INSERT OR REPLACE INTO sessions(session_id, player) VALUES (?, ?)", [session_id, player])
    @db.execute("INSERT INTO visits(session_id, room_title) VALUES (?, ?)", [session_id, room_title])
  end

  def test_examined_entries_carry_the_actual_examine_result_text
    add_content("Room A", "A rusty lever is here.", subject: "lever")
    add_content("Room A", "A cityguard stands here.", subject: "cityguard", kind: "npc")
    add_examination("Room A", "lever", "It's a rusty iron lever.")

    result = Boukensha::WorldKnowledge.room_knowledge(room_title: "Room A", player: nil)

    assert_equal [{ subject: "lever", result: "It's a rusty iron lever." }], result[:examined]
    assert_equal ["cityguard"], result[:unexamined]
  end

  def test_examine_target_matches_a_content_fact_subject_by_substring
    add_content("Room A", "A large fountain carved from marble is here.", subject: "large stone fountain", kind: "scenery")
    add_examination("Room A", "fountain", "A grand marble fountain, cool to the touch.")

    result = Boukensha::WorldKnowledge.room_knowledge(room_title: "Room A", player: nil)

    assert_equal 1, result[:examined].length
    assert_equal "large stone fountain", result[:examined].first[:subject]
    assert_equal "A grand marble fountain, cool to the touch.", result[:examined].first[:result]
    assert_empty result[:unexamined]
  end

  def test_missing_database_degrades_to_an_empty_result
    ENV["LOG_VIZ_WORLD_MAP_DB"] = File.join(@tmp_dir, "does-not-exist.sqlite3")

    result = Boukensha::WorldKnowledge.room_knowledge(room_title: "Room A", player: nil)

    assert_equal({ room_title: "Room A", examined: [], unexamined: [] }, result)
  end

  # ---- per-player scoping (multiple_concurrent_players.md §2) ----

  def test_a_player_who_has_never_visited_the_room_gets_a_have_not_been_here_note
    add_content("Room A", "A rusty lever is here.", subject: "lever")
    add_examination("Room A", "lever", "It's a rusty iron lever.", session_id: "noir-s1")
    add_visit("noir-s1", "Room A", player: "noir")

    result = Boukensha::WorldKnowledge.room_knowledge(room_title: "Room A", player: "dina")

    assert_equal({ room_title: "Room A", examined: [], unexamined: [], note: "you have not been here" }, result)
  end

  def test_a_player_who_visited_the_room_sees_only_their_own_examinations
    add_content("Room A", "A rusty lever is here.", subject: "lever")
    add_content("Room A", "A cityguard stands here.", subject: "cityguard", kind: "npc")
    add_visit("noir-s1", "Room A", player: "noir")
    add_visit("dina-s1", "Room A", player: "dina")
    # Noir examined the lever; Dina examined the cityguard. Different
    # characters, different knowledge, even of the identical room.
    add_examination("Room A", "lever", "It's a rusty iron lever.", session_id: "noir-s1")
    add_examination("Room A", "cityguard", "A stern-looking guard.", session_id: "dina-s1")

    noir_result = Boukensha::WorldKnowledge.room_knowledge(room_title: "Room A", player: "noir")
    assert_equal [{ subject: "lever", result: "It's a rusty iron lever." }], noir_result[:examined]
    assert_equal ["cityguard"], noir_result[:unexamined]

    dina_result = Boukensha::WorldKnowledge.room_knowledge(room_title: "Room A", player: "dina")
    assert_equal [{ subject: "cityguard", result: "A stern-looking guard." }], dina_result[:examined]
    assert_equal ["lever"], dina_result[:unexamined]
  end

  def test_nil_player_keeps_the_historical_unscoped_whole_map_behavior
    add_content("Room A", "A rusty lever is here.", subject: "lever")
    add_examination("Room A", "lever", "It's a rusty iron lever.", session_id: "noir-s1")
    add_visit("noir-s1", "Room A", player: "noir")
    # No visit row at all for a nil-player caller — the whole point is that
    # this mode never checks visit history.

    result = Boukensha::WorldKnowledge.room_knowledge(room_title: "Room A", player: nil)

    assert_equal [{ subject: "lever", result: "It's a rusty iron lever." }], result[:examined]
    refute result.key?(:note)
  end
end
