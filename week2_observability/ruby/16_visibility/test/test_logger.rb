require_relative "helper"

class TestLogger < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def new_logger
    Boukensha::Logger.new(dir: @dir, session_id: "test-session")
  end

  def read_events(logger)
    logger.close
    File.readlines(logger.path).map { |line| JSON.parse(line) }
  end

  def sample_messages
    [Boukensha::Message.new(:user, "hi"), Boukensha::Message.new(:assistant, "hello")]
  end

  def sample_tools
    { "look" => Object.new }
  end

  def sample_payload
    {
      model: "claude-sonnet-4-6",
      system: "you are a test",
      max_tokens: 512,
      tools: [{ name: "look", description: "look around", input_schema: { type: "object" } }],
      messages: [{ role: "user", content: "hi" }, { role: "assistant", content: "hello" }]
    }
  end

  def test_request_logs_the_exact_payload_plus_cheap_summary_fields
    logger  = new_logger
    payload = sample_payload

    logger.request(payload: payload, messages: sample_messages, tools: sample_tools, iteration: 3)

    event = read_events(logger).find { |e| e["phase"] == "request" }

    assert_equal 3, event["iteration"]
    assert_equal false, event["wrap_up"]
    assert_equal "claude-sonnet-4-6", event["model"]
    assert_equal 2, event["message_count"]
    assert_equal 1, event["tool_count"]
    assert_equal "hi", event["last_user_text"]
    assert_equal JSON.generate(payload).bytesize, event["bytes"]
    # The logged payload must round-trip to exactly what was passed in — this
    # is the literal body about to be sent over the wire.
    assert_equal JSON.parse(JSON.generate(payload)), event["payload"]
  end

  def test_request_marks_wrap_up_calls_distinctly
    logger = new_logger

    logger.request(payload: { model: "m", messages: [] }, messages: [], tools: {}, iteration: 5, wrap_up: true)

    event = read_events(logger).find { |e| e["phase"] == "request" }
    assert_equal true, event["wrap_up"]
  end

  # Regression test for the bug found in testing: OpenAI's payload puts
  # messages under `input` (not `messages`) and has no top-level `system`
  # key, so summary stats must never be derived by reading the payload back
  # out — they have to come from the Context collections the caller already
  # has, which look the same for every backend.
  def test_request_summary_fields_are_backend_agnostic
    logger = new_logger
    openai_shaped_payload = {
      model: "gpt-5.5",
      instructions: "you are a test",
      input: [{ type: "function_call", call_id: "1", name: "look", arguments: "{}" }],
      tools: (1..57).map { |n| { type: "function", name: "tool#{n}" } }
    }

    logger.request(payload: openai_shaped_payload, messages: sample_messages, tools: sample_tools, iteration: 1)

    event = read_events(logger).find { |e| e["phase"] == "request" }
    assert_equal 2, event["message_count"], "message_count must come from the passed messages:, not payload[\"input\"]"
    assert_equal 1, event["tool_count"], "tool_count must come from the passed tools:, not payload[\"tools\"].size (57)"
    assert_equal "hi", event["last_user_text"]
  end

  def test_prompt_is_no_longer_defined
    refute_respond_to new_logger, :prompt
  end

  # `compacted:` is purely additive: `result:` must stay the raw, untouched
  # tool reply (Boukensha::Compactor's header comment's invariant) while
  # `compacted:` separately records what Agent actually injected into
  # context — so a viewer can show both without either overwriting the other.
  def test_tool_result_logs_raw_result_and_compacted_text_separately
    logger = new_logger
    raw    = "\e[0;33mThe Temple Square\e[0m\r\nA long room description.\r\n> "

    logger.tool_result(name: "tbamud__look", result: raw, ok: true, compacted: "The Temple Square\nA short summary.")

    event = read_events(logger).find { |e| e["phase"] == "tool_result" }
    assert_equal raw, event["result"]
    assert_equal "The Temple Square\nA short summary.", event["compacted"]
    assert_equal true, event["ok"]
  end

  def test_tool_result_compacted_defaults_to_nil_when_omitted
    logger = new_logger

    logger.tool_result(name: "tbamud__look", result: "raw text", ok: true)

    event = read_events(logger).find { |e| e["phase"] == "tool_result" }
    assert_nil event["compacted"]
  end
end
