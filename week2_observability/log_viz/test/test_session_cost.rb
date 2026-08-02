require_relative "helper"

# Covers per-request cost and its breakdown across the same system/tools/
# messages/other composition buckets used for tokens. The buckets are priced
# independently off Session::MODEL_PRICES (not the logged `cost_usd`, which
# conflates input and output into one number), so the invariant under test is
# construction-based: system + tools + messages + other + output must always
# equal the reported total, for any priced model.
class TestSessionCost < Minitest::Test
  include SessionTestHelper

  def test_bucket_costs_sum_to_the_total_for_a_priced_model
    payload = {
      model: "gpt-5.4-mini",
      instructions: "You are a terse test agent with a fairly long system prompt.",
      input: [{ role: "user", content: "hi there, please look around the room" }],
      tools: [
        { type: "function", name: "look", description: "look around", parameters: { type: "object", properties: {} } },
        { type: "function", name: "move", description: "move somewhere", parameters: { type: "object", properties: {} } }
      ]
    }

    path = write_session([
      session_start_event(provider: "openai"),
      request_event(payload: payload, tool_count: 2),
      response_event(usage: { "input_tokens" => 4059, "output_tokens" => 31 })
    ])

    entry = request_entry_for(path)

    refute_nil entry.comp_cost_usd
    sum = entry.comp_system_cost + entry.comp_tools_cost + entry.comp_messages_cost +
          entry.comp_other_cost + entry.comp_output_cost
    assert_in_delta entry.comp_cost_usd, sum, 1e-9

    # gpt-5.4-mini: $0.75 / MTok input, $4.5 / MTok output (mirrors
    # backends/openai.rb) — sanity-check the absolute numbers, not just
    # internal consistency.
    expected_input  = 4059 * (0.75 / 1_000_000.0)
    expected_output = 31 * (4.5 / 1_000_000.0)
    assert_in_delta expected_input + expected_output, entry.comp_cost_usd, 1e-9
  end

  def test_tools_heavy_request_attributes_most_cost_to_the_tools_bucket
    # Regression guard for the exact shape tool_token_optimization.md flagged
    # by hand: a request whose tool schemas dwarf the rest of the payload
    # should show most of the dollar cost landing in the tools bucket, not
    # spread evenly — that's the number a schema-trim's savings should be
    # read off of.
    payload = {
      model: "gpt-5.4-mini",
      instructions: "sys",
      input: [{ role: "user", content: "hi" }],
      tools: Array.new(50) { |n| { type: "function", name: "tool#{n}", description: "d" * 200, parameters: { type: "object" } } }
    }

    path = write_session([
      session_start_event(provider: "openai"),
      request_event(payload: payload, tool_count: 50),
      response_event(usage: { "input_tokens" => 4000, "output_tokens" => 20 })
    ])

    entry = request_entry_for(path)

    assert entry.comp_tools_cost > entry.comp_system_cost
    assert entry.comp_tools_cost > entry.comp_messages_cost
  end

  def test_unpriced_model_leaves_costs_nil_rather_than_guessing
    payload = { model: "some-unreleased-model", instructions: "sys", input: [], tools: [] }
    path = write_session([
      session_start_event(provider: "openai", model: "some-unreleased-model"),
      request_event(payload: payload),
      response_event(usage: { "input_tokens" => 50, "output_tokens" => 5 })
    ])

    entry = request_entry_for(path)

    assert_nil entry.comp_cost_usd
    assert_nil entry.comp_system_cost
    assert_nil entry.comp_tools_cost
    assert_nil entry.comp_messages_cost
    assert_nil entry.comp_other_cost
    assert_nil entry.comp_output_cost
  end

  def test_free_ollama_model_costs_exactly_zero_not_nil
    payload = {
      model: "gemma4:12b", stream: false,
      messages: [{ role: "system", content: "sys" }, { role: "user", content: "hi" }],
      tools: [], think: false
    }
    path = write_session([
      session_start_event(provider: "ollama", model: "gemma4:12b"),
      request_event(payload: payload),
      response_event(usage: { "input_tokens" => 300, "output_tokens" => 20 })
    ])

    entry = request_entry_for(path)

    assert_equal 0.0, entry.comp_cost_usd
  end
end
