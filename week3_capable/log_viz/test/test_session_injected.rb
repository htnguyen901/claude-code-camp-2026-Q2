require_relative "helper"

# Covers the ":injected" transcript entry — a panel session.erb renders right
# before each `request` entry, summarizing exactly what post-compaction text
# (Boukensha::Compactor's output, logged as `tool_result`'s `compacted:`
# field — week2_observability/ruby/14_response_compactor) is about to enter
# that request's payload, so a viewer doesn't have to expand the request's
# full JSON to see it.
class TestSessionInjected < Minitest::Test
  include SessionTestHelper

  def tool_call_event(name:, args: {})
    { phase: "tool_call", name: name, args: args, session_id: "test-session", at: Time.now.iso8601 }
  end

  def tool_result_event(name:, result:, compacted: nil, ok: true)
    { phase: "tool_result", name: name, result: result, ok: ok, compacted: compacted,
      session_id: "test-session", at: Time.now.iso8601 }
  end

  def test_injected_entry_is_inserted_right_before_the_following_request
    path = write_session([
      session_start_event(provider: "openai"),
      tool_call_event(name: "tbamud__look"),
      tool_result_event(name: "tbamud__look", result: "The full raw room description.", compacted: "Short summary."),
      request_event(payload: { model: "m", input: [] })
    ])

    types = LogViz::Session.load(path).entries.map(&:type)
    injected_idx = types.index(:injected)
    request_idx  = types.index(:request)

    refute_nil injected_idx, "expected an :injected entry to be parsed"
    assert_equal injected_idx + 1, request_idx, ":injected must sit immediately before the :request it feeds"
  end

  def test_injected_entry_carries_the_compacted_text_and_char_delta
    path = write_session([
      session_start_event(provider: "openai"),
      tool_call_event(name: "tbamud__look"),
      tool_result_event(name: "tbamud__look", result: "x" * 500, compacted: "y" * 120),
      request_event(payload: { model: "m", input: [] })
    ])

    entry = LogViz::Session.load(path).entries.find { |e| e.type == :injected }
    call  = entry.injected_calls.first

    assert_equal "tbamud__look", call[:name]
    assert_equal "y" * 120, call[:compacted]
    assert_equal 500, call[:raw_len]
    assert_equal 120, call[:compacted_len]
  end

  def test_multiple_tool_calls_in_one_iteration_all_appear_in_the_same_injected_entry
    path = write_session([
      session_start_event(provider: "openai"),
      tool_call_event(name: "tbamud__look"),
      tool_result_event(name: "tbamud__look", result: "raw look", compacted: "compacted look"),
      tool_call_event(name: "tbamud__examine"),
      tool_result_event(name: "tbamud__examine", result: "raw examine", compacted: "compacted examine"),
      request_event(payload: { model: "m", input: [] })
    ])

    entry = LogViz::Session.load(path).entries.find { |e| e.type == :injected }

    assert_equal %w[tbamud__look tbamud__examine], entry.injected_calls.map { |c| c[:name] }
  end

  def test_no_injected_entry_when_no_tool_calls_preceded_the_request
    path = write_session([
      session_start_event(provider: "openai"),
      request_event(payload: { model: "m", input: [] })
    ])

    refute LogViz::Session.load(path).entries.any? { |e| e.type == :injected },
           "a request with nothing buffered ahead of it must not get an empty panel"
  end

  def test_older_logs_without_a_compacted_field_produce_no_injected_entry
    path = write_session([
      session_start_event(provider: "openai"),
      tool_call_event(name: "tbamud__look"),
      # No `compacted:` key at all — the shape every session.jsonl had before
      # this feature shipped.
      { phase: "tool_result", name: "tbamud__look", result: "raw text", ok: true,
        session_id: "test-session", at: Time.now.iso8601 },
      request_event(payload: { model: "m", input: [] })
    ])

    refute LogViz::Session.load(path).entries.any? { |e| e.type == :injected },
           "older logs must keep rendering exactly as before — no compacted field, no panel"
  end

  def test_buffer_is_cleared_after_flushing_so_a_second_request_does_not_repeat_it
    path = write_session([
      session_start_event(provider: "openai"),
      tool_call_event(name: "tbamud__look"),
      tool_result_event(name: "tbamud__look", result: "raw", compacted: "compacted"),
      request_event(payload: { model: "m", input: [] }),
      response_event(usage: { "input_tokens" => 10, "output_tokens" => 5 }),
      request_event(payload: { model: "m", input: [] })
    ])

    injected_entries = LogViz::Session.load(path).entries.select { |e| e.type == :injected }
    assert_equal 1, injected_entries.length
  end
end
