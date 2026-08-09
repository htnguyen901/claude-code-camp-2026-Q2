require_relative "helper"
require "minitest/mock"
require "log_viz/content_fact"

# Tier B (LLM) extraction only — Tier A regex was scoped out per explicit
# feedback on docs/plans/observability/room_world_inspector.md §1: real
# CircleMUD long-descriptions don't reliably put the head noun first, so
# every line goes to the local Ollama model. These tests stub the HTTP call
# (`LogViz::ContentFact.call_ollama`) — no live Ollama daemon required to run them.
#
# Fixtures are the real captured lines cited in room_world_inspector.md /
# player_journey_map.md §1.
class TestContentFact < Minitest::Test
  FOUNTAIN  = "A large fountain carved from blue-streaked marble is here, bubbling merrily."
  ODIF      = "An odif yltsaeb is here, walking backwards."
  CITYGUARD = "A cityguard stands here."
  BLOB      = "An oozing green gelatinous blob is here, sucking in bits of debris."

  def stub_ollama_reply(json_text)
    LogViz::ContentFact.stub(:call_ollama, json_text) { yield }
  end

  def test_content_hash_is_a_stable_sha256_of_the_raw_string
    hash1 = LogViz::ContentFact.content_hash(FOUNTAIN)
    hash2 = LogViz::ContentFact.content_hash(FOUNTAIN)

    assert_equal hash1, hash2
    assert_equal 64, hash1.length
    refute_equal hash1, LogViz::ContentFact.content_hash(CITYGUARD)
  end

  def test_extract_parses_a_well_formed_llm_reply
    reply = JSON.generate(subject: "fountain", kind: "scenery", clause: "bubbling merrily")
    result = nil
    stub_ollama_reply(reply) { result = LogViz::ContentFact.extract(FOUNTAIN) }

    assert_equal "fountain", result[:subject]
    assert_equal "scenery", result[:kind]
    assert_equal "bubbling merrily", result[:clause]
    assert_equal "llm", result[:source]
  end

  def test_extract_normalizes_an_llm_kind_outside_the_allowed_set
    reply = JSON.generate(subject: "odif yltsaeb", kind: "monster", clause: "walking backwards")
    result = nil
    stub_ollama_reply(reply) { result = LogViz::ContentFact.extract(ODIF) }

    assert_equal "unknown", result[:kind]
    assert_equal "llm", result[:source], "a malformed kind value is still a successful extraction"
  end

  def test_extract_falls_back_to_the_raw_string_when_llm_subject_is_blank
    reply = JSON.generate(subject: "", kind: "npc", clause: nil)
    result = nil
    stub_ollama_reply(reply) { result = LogViz::ContentFact.extract(CITYGUARD) }

    assert_equal CITYGUARD, result[:subject]
    assert_equal "npc", result[:kind]
  end

  def test_extract_fails_soft_when_ollama_is_unreachable
    LogViz::ContentFact.stub(:call_ollama, ->(*) { raise Errno::ECONNREFUSED }) do
      result = LogViz::ContentFact.extract(BLOB)
      assert_equal "unknown", result[:kind]
      assert_equal "fallback", result[:source]
      assert_equal BLOB, result[:subject]
    end
  end

  def test_extract_fails_soft_on_malformed_json_reply
    stub_ollama_reply("not json at all") do
      result = LogViz::ContentFact.extract(BLOB)
      assert_equal "unknown", result[:kind]
      assert_equal "fallback", result[:source]
    end
  end

  # ---------- .extract_mentions (description-embedded mentions) ----------
  #
  # The exact scenario reported as a bug: a room's free-form description
  # narrates a "note" and "items on shelves" in prose rather than as their
  # own itemized "X is here" line, and both are things a player would
  # reasonably want to `examine`.
  GENERAL_STORE_DESCRIPTION =
    "You are inside the general store. All sorts of items are stacked on shelves " \
    "behind the counter, safely out of your reach. A small note hangs on the wall."

  def test_extract_mentions_parses_a_bare_json_array_reply
    reply = JSON.generate([
      { quote: "All sorts of items are stacked on shelves behind the counter, safely out of your reach.",
        subject: "shelves", kind: "scenery", clause: nil },
      { quote: "A small note hangs on the wall.", subject: "note", kind: "item", clause: "hangs on the wall" }
    ])

    result = nil
    LogViz::ContentFact.stub(:call_ollama, reply) { result = LogViz::ContentFact.extract_mentions(GENERAL_STORE_DESCRIPTION) }

    assert_equal "llm", result[:source]
    assert_equal 2, result[:mentions].length
    assert_equal "shelves", result[:mentions][0][:subject]
    assert_equal "note", result[:mentions][1][:subject]
    assert_equal "item", result[:mentions][1][:kind]
  end

  def test_extract_mentions_unwraps_a_hash_wrapped_array_reply
    reply = JSON.generate(mentions: [{ quote: "A small note hangs on the wall.", subject: "note", kind: "item", clause: nil }])

    result = nil
    LogViz::ContentFact.stub(:call_ollama, reply) { result = LogViz::ContentFact.extract_mentions(GENERAL_STORE_DESCRIPTION) }

    assert_equal "llm", result[:source]
    assert_equal ["note"], result[:mentions].map { |m| m[:subject] }
  end

  # The dominant real-world failure mode against gemma4: despite the
  # prompt explicitly requiring an array (even for one match), the model
  # very often still collapses straight to the one bare mention object.
  # Observed happening for nearly every room tested against a real Ollama
  # daemon during development of this feature — not a rare edge case.
  def test_extract_mentions_treats_a_single_bare_object_reply_as_one_mention
    reply = JSON.generate(quote: "A small note hangs on the wall.", subject: "note", kind: "item", clause: nil)

    result = nil
    LogViz::ContentFact.stub(:call_ollama, reply) { result = LogViz::ContentFact.extract_mentions(GENERAL_STORE_DESCRIPTION) }

    assert_equal "llm", result[:source]
    assert_equal ["note"], result[:mentions].map { |m| m[:subject] }
  end

  def test_extract_mentions_empty_array_is_a_successful_scan_not_a_failure
    result = nil
    LogViz::ContentFact.stub(:call_ollama, "[]") { result = LogViz::ContentFact.extract_mentions("A plain, empty room.") }

    assert_equal "llm", result[:source], "genuinely finding nothing is a success, not a fallback"
    assert_empty result[:mentions]
  end

  def test_extract_mentions_drops_entries_with_a_blank_quote
    reply = JSON.generate([{ quote: "", subject: "ghost", kind: "item" }])

    result = nil
    LogViz::ContentFact.stub(:call_ollama, reply) { result = LogViz::ContentFact.extract_mentions("desc") }

    assert_empty result[:mentions]
  end

  def test_extract_mentions_fails_soft_when_reply_is_not_array_shaped
    result = nil
    LogViz::ContentFact.stub(:call_ollama, JSON.generate(subject: "not an array")) { result = LogViz::ContentFact.extract_mentions("desc") }

    assert_equal "fallback", result[:source]
    assert_empty result[:mentions]
  end

  # Real-world failure mode caught by running the backfill against the
  # actual 45-room world_map.sqlite3: gemma4 invented a mention that never
  # appeared in the given description at all (apparently bled in from a
  # different room it had seen). The prompt demands a verbatim quote, so a
  # reply that fails that same verbatim-substring test is dropped rather
  # than trusted.
  def test_extract_mentions_drops_a_quote_that_does_not_actually_appear_in_the_description
    reply = JSON.generate([{ quote: "A small note hangs on the wall.", subject: "note", kind: "item" }])

    result = nil
    LogViz::ContentFact.stub(:call_ollama, reply) do
      result = LogViz::ContentFact.extract_mentions("This trail slopes up and away from the main road.")
    end

    assert_equal "llm", result[:source], "a hallucinated quote is dropped, not treated as an extraction failure"
    assert_empty result[:mentions]
  end

  def test_extract_mentions_tolerates_whitespace_differences_between_quote_and_description
    reply = JSON.generate([{ quote: "A small note   hangs on the wall.", subject: "note", kind: "item" }])

    result = nil
    LogViz::ContentFact.stub(:call_ollama, reply) { result = LogViz::ContentFact.extract_mentions(GENERAL_STORE_DESCRIPTION) }

    assert_equal ["note"], result[:mentions].map { |m| m[:subject] }
  end

  def test_extract_mentions_fails_soft_when_ollama_is_unreachable
    LogViz::ContentFact.stub(:call_ollama, ->(*) { raise Errno::ECONNREFUSED }) do
      result = LogViz::ContentFact.extract_mentions(GENERAL_STORE_DESCRIPTION)
      assert_equal "fallback", result[:source]
      assert_empty result[:mentions]
    end
  end
end
