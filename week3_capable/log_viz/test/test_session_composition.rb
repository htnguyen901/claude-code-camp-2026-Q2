require_relative "helper"

# Covers the token-composition-observability plan's §6 trustworthiness
# invariant: the system/tools/messages/other buckets a request's payload
# bytes are split into must always sum to exactly that request's real,
# provider-billed usage.input_tokens — no matter how the byte-proportional
# apportionment guesses at the split. Also covers §3's cache-field fix
# (provider-keyed lookup instead of assuming Anthropic's shape everywhere).
class TestSessionComposition < Minitest::Test
  include SessionTestHelper

  def test_openai_shaped_payload_composition_sums_to_real_input_tokens_and_cache_reads_correctly
    payload = {
      model: "gpt-5.4-mini",
      instructions: "You are a terse test agent with a fairly long system prompt to give it real byte weight.",
      input: [
        { role: "user", content: "hi there, please look around the room" },
        { role: "assistant", content: "looking now" }
      ],
      tools: [
        { type: "function", name: "look", description: "look around", parameters: { type: "object", properties: {} } },
        { type: "function", name: "move", description: "move somewhere", parameters: { type: "object", properties: {} } }
      ],
      max_output_tokens: 1024
    }

    path = write_session([
      session_start_event(provider: "openai"),
      request_event(payload: payload, message_count: 2, tool_count: 2),
      # Real shape confirmed from a logged session (not Anthropic's
      # cache_read_input_tokens, which OpenAI never sends).
      response_event(usage: {
        "input_tokens" => 4059,
        "input_tokens_details" => { "cached_tokens" => 3584, "cache_write_tokens" => 0 },
        "output_tokens" => 31
      })
    ])

    entry = request_entry_for(path)
    total = entry.comp_system_tokens + entry.comp_tools_tokens + entry.comp_messages_tokens + entry.comp_other_tokens

    assert_equal 4059, total
    assert_equal 3584, entry.comp_cache_read
    assert entry.comp_tools_tokens.positive?, "tools bucket should capture the tool schema bytes"
    assert entry.comp_system_tokens.positive?, "system bucket should capture the instructions bytes"
  end

  def test_anthropic_shaped_payload_composition_sums_to_real_input_tokens
    payload = {
      model: "claude-sonnet-4-6",
      system: "You are a terse test agent.",
      max_tokens: 1024,
      tools: [{ name: "look", description: "look around", input_schema: { type: "object", properties: {} } }],
      messages: [{ role: "user", content: "hi" }]
    }

    path = write_session([
      session_start_event(provider: "anthropic"),
      request_event(payload: payload, tool_count: 1),
      response_event(usage: {
        "input_tokens" => 512, "cache_read_input_tokens" => 100,
        "cache_creation_input_tokens" => 0, "output_tokens" => 10
      })
    ])

    entry = request_entry_for(path)
    total = entry.comp_system_tokens + entry.comp_tools_tokens + entry.comp_messages_tokens + entry.comp_other_tokens

    assert_equal 512, total
    assert_equal 100, entry.comp_cache_read
  end

  def test_ollama_shaped_payload_splits_folded_system_message_and_has_no_cache
    payload = {
      model: "gemma4:12b",
      stream: false,
      messages: [
        { role: "system", content: "You are a terse test agent." },
        { role: "user", content: "hi" }
      ],
      tools: [{ type: "function", function: { name: "look", parameters: { type: "object", properties: {} } } }],
      think: false
    }

    path = write_session([
      session_start_event(provider: "ollama"),
      request_event(payload: payload, tool_count: 1),
      response_event(usage: { "input_tokens" => 300, "output_tokens" => 20 })
    ])

    entry = request_entry_for(path)
    total = entry.comp_system_tokens + entry.comp_tools_tokens + entry.comp_messages_tokens + entry.comp_other_tokens

    assert_equal 300, total
    assert_equal 0, entry.comp_cache_read
    assert entry.comp_system_tokens.positive?, "the leading role=='system' message should be split into the system bucket"
  end

  def test_composition_invariant_holds_across_varied_byte_proportions_and_token_counts
    [
      { system: "s" * 10,   tools_n: 1,  messages_n: 1,  input_tokens: 7 },
      { system: "s" * 5000, tools_n: 20, messages_n: 2,  input_tokens: 3891 },
      { system: "",         tools_n: 0,  messages_n: 5,  input_tokens: 123 },
      { system: "s" * 200,  tools_n: 3,  messages_n: 50, input_tokens: 99_999 }
    ].each_with_index do |c, i|
      payload = {
        model: "gpt-5.4-mini",
        instructions: c[:system],
        input: Array.new(c[:messages_n]) { |n| { role: "user", content: "message #{n}" } },
        tools: Array.new(c[:tools_n]) { |n| { type: "function", name: "tool#{n}", parameters: { type: "object" } } }
      }

      path = write_session([
        session_start_event(provider: "openai"),
        request_event(payload: payload, message_count: c[:messages_n], tool_count: c[:tools_n]),
        response_event(usage: { "input_tokens" => c[:input_tokens], "output_tokens" => 5 })
      ])

      entry = request_entry_for(path)
      total = entry.comp_system_tokens + entry.comp_tools_tokens + entry.comp_messages_tokens + entry.comp_other_tokens
      assert_equal c[:input_tokens], total, "case #{i}: buckets must sum to the real input_tokens"
    end
  end

  def test_request_series_carries_the_same_token_buckets_as_the_entry
    payload = {
      model: "gpt-5.4-mini", instructions: "sys",
      input: [{ role: "user", content: "hi" }],
      tools: [{ type: "function", name: "look", parameters: { type: "object" } }]
    }

    path = write_session([
      session_start_event(provider: "openai"),
      request_event(payload: payload, tool_count: 1),
      response_event(usage: { "input_tokens" => 200, "output_tokens" => 5 })
    ])

    session = LogViz::Session.load(path)
    entry   = session.entries.find { |e| e.type == :request }
    point   = session.request_series.first

    assert_equal entry.comp_system_tokens, point.system_tokens
    assert_equal entry.comp_tools_tokens, point.tools_tokens
    assert_equal entry.comp_messages_tokens, point.messages_tokens
  end

  def test_unmatched_trailing_request_has_no_composition
    # A request with no matching response yet (truncated/live-tailed log)
    # must not raise and must leave composition fields nil so the view can
    # skip rendering the composition line, not show a bogus zeroed one.
    payload = { model: "gpt-5.4-mini", instructions: "sys", input: [], tools: [] }
    path    = write_session([session_start_event(provider: "openai"), request_event(payload: payload)])

    entry = request_entry_for(path)
    assert_nil entry.comp_input_tokens
  end
end
