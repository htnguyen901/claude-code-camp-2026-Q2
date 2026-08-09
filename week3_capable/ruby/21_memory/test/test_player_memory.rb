require_relative "helper"

# Boukensha::PlayerMemory — docs/plans/memory/player_memory.md §2. A per-
# player, cross-session store: an append-only raw record (<name>.jsonl) and
# a bounded digest (<name>.md), never shared between two players' names.
class TestPlayerMemory < Minitest::Test
  def test_digest_text_is_nil_when_no_digest_file_exists_yet
    Dir.mktmpdir do |dir|
      memory = Boukensha::PlayerMemory.load("noir", memory_dir: dir)
      assert_nil memory.digest_text
    end
  end

  def test_save_digest_then_digest_text_round_trips_verbatim
    Dir.mktmpdir do |dir|
      memory = Boukensha::PlayerMemory.load("noir", memory_dir: dir)
      memory.save_digest("Discoveries\n- The blacksmith sells cheap daggers.")

      assert_equal "Discoveries\n- The blacksmith sells cheap daggers.", memory.digest_text
    end
  end

  def test_digest_text_is_nil_for_a_digest_file_that_is_only_whitespace
    Dir.mktmpdir do |dir|
      memory = Boukensha::PlayerMemory.load("noir", memory_dir: dir)
      memory.save_digest("   \n  ")

      assert_nil memory.digest_text
    end
  end

  def test_save_digest_creates_the_memory_dir_if_missing
    Dir.mktmpdir do |dir|
      nested = File.join(dir, "does", "not", "exist", "yet")
      memory = Boukensha::PlayerMemory.load("noir", memory_dir: nested)
      memory.save_digest("notes")

      assert Dir.exist?(nested)
      assert_equal "notes", memory.digest_text
    end
  end

  def test_append_session_record_then_session_records_round_trips_a_hash_through_json
    Dir.mktmpdir do |dir|
      memory = Boukensha::PlayerMemory.load("noir", memory_dir: dir)
      memory.append_session_record(goal: "explore the temple square", stop_reason: "completed", turns: 3, checkpoints: [], outcome: "Completed: done")

      records = memory.session_records
      assert_equal 1, records.size
      assert_equal "explore the temple square", records.first["goal"]
      assert_equal "completed", records.first["stop_reason"]
      assert_equal 3, records.first["turns"]
      assert_equal "Completed: done", records.first["outcome"]
      assert records.first.key?("at"), "each record is stamped with a timestamp"
    end
  end

  def test_session_records_returns_empty_array_when_no_raw_file_exists_yet
    Dir.mktmpdir do |dir|
      memory = Boukensha::PlayerMemory.load("noir", memory_dir: dir)
      assert_equal [], memory.session_records
    end
  end

  def test_session_records_appends_one_line_per_call_and_honors_last
    Dir.mktmpdir do |dir|
      memory = Boukensha::PlayerMemory.load("noir", memory_dir: dir)
      memory.append_session_record(goal: "first", stop_reason: "completed", turns: 1, checkpoints: [], outcome: "Completed: first")
      memory.append_session_record(goal: "second", stop_reason: "completed", turns: 2, checkpoints: [], outcome: "Completed: second")

      assert_equal 2, memory.session_records.size
      assert_equal ["second"], memory.session_records(last: 1).map { |r| r["goal"] }
    end
  end

  # decision 6's isolation guarantee: two different player names, same
  # memory_dir:, never read or write each other's files.
  def test_two_different_players_never_cross_contaminate
    Dir.mktmpdir do |dir|
      noir = Boukensha::PlayerMemory.load("noir", memory_dir: dir)
      luca = Boukensha::PlayerMemory.load("luca", memory_dir: dir)

      noir.save_digest("Noir's notes")
      noir.append_session_record(goal: "noir's goal", stop_reason: "completed", turns: 1, checkpoints: [], outcome: "Completed: noir")

      assert_nil luca.digest_text, "luca must not see noir's digest"
      assert_equal [], luca.session_records, "luca must not see noir's raw records"

      luca.save_digest("Luca's notes")
      assert_equal "Noir's notes", noir.digest_text, "writing luca's digest must not affect noir's"
    end
  end
end
