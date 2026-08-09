require_relative "helper"
require "socket"
require "json"

# Serves one canned Ollama-shaped JSON response, capturing the request body
# actually sent — same ScriptedServer pattern test_run_planner.rb's
# PlannerScriptedServer uses, pointed at via Backends::Ollama's `host:`
# constructor kwarg so Boukensha.run_chronicler can be exercised through a
# real backend without a live provider.
class ChroniclerScriptedServer
  def initialize(body)
    @body          = body
    @captured_body = nil
    @server        = TCPServer.new("127.0.0.1", 0)
    @thread        = Thread.new { accept_once }
    @thread.report_on_exception = false
  end

  def host = "http://127.0.0.1:#{@server.addr[1]}"
  def captured_body = @captured_body

  def stop
    @thread.join(1)
    @server.close
  rescue StandardError
    nil
  end

  private

  def accept_once
    conn = @server.accept
    conn.gets
    headers = {}
    while (line = conn.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.downcase] = value.strip if key && value
    end
    @captured_body = conn.read(headers["content-length"].to_i)
    conn.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{@body.bytesize}\r\n\r\n#{@body}")
  ensure
    conn&.close
  end
end

# A stand-in for a checkpoint entry — anything responding to
# turn/verdict/reasoning/overridden is enough for chronicler_input, same
# contract Boukensha::JudgeMemory::Entry already fulfills.
FakeCheckpoint = Struct.new(:turn, :verdict, :reasoning, :overridden, keyword_init: true)

# Boukensha.run_chronicler — docs/plans/memory/player_memory.md §3. A small
# Agent#run loop over a throwaway Context/Registry built from
# `tasks.chronicler.tools` (deny-by-default with no such block configured),
# with no mcp: parameter at all — unlike every other run_* sibling, the
# Chronicler is never handed the session's live MCP connections.
class TestRunChronicler < Minitest::Test
  RESPONSE_BODY = JSON.generate(message: { content: "Strategies\n- Asking the priest first unlocks the temple quest." })

  def test_logger
    Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "chronicler-test-#{rand(1_000_000)}")
  end

  def test_run_chronicler_returns_the_models_digest_text
    server = ChroniclerScriptedServer.new(RESPONSE_BODY)

    text = Boukensha.run_chronicler(
      goal: "explore the temple square", outcome: "Completed: found the temple.", checkpoints: [],
      logger: test_logger, backend: :ollama, model: "qwen3:8b", ollama_host: server.host
    )
    server.stop

    assert_equal "Strategies\n- Asking the priest first unlocks the temple quest.", text
  end

  def test_request_includes_goal_outcome_and_checkpoints
    server = ChroniclerScriptedServer.new(RESPONSE_BODY)
    checkpoints = [FakeCheckpoint.new(turn: 2, verdict: :replan, reasoning: "The north door was locked.", overridden: false)]

    Boukensha.run_chronicler(
      goal: "explore the temple square", outcome: "Stopped: reached max_turns (3) without completing.", checkpoints: checkpoints,
      logger: test_logger, backend: :ollama, model: "qwen3:8b", ollama_host: server.host
    )
    server.stop

    sent = JSON.parse(server.captured_body)
    user_text = sent["messages"].find { |m| m["role"] == "user" }["content"]
    assert_includes user_text, "explore the temple square"
    assert_includes user_text, "reached max_turns"
    assert_includes user_text, "The north door was locked."
  end

  def test_prior_digest_is_included_when_given
    server = ChroniclerScriptedServer.new(RESPONSE_BODY)

    Boukensha.run_chronicler(
      goal: "explore the temple square", outcome: "Completed: found the temple.", checkpoints: [],
      prior_digest: "Strategies\n- Bring a torch underground.",
      logger: test_logger, backend: :ollama, model: "qwen3:8b", ollama_host: server.host
    )
    server.stop

    sent = JSON.parse(server.captured_body)
    user_text = sent["messages"].find { |m| m["role"] == "user" }["content"]
    assert_includes user_text, "existing notes"
    assert_includes user_text, "Bring a torch underground."
  end

  # decision 3: the Chronicler has no mcp: parameter at all, so even a
  # `tasks.chronicler.tools` grant would have nothing to dispatch against —
  # the request payload it sends carries zero tools, proving the deny-by-
  # default policy actually took effect on this task's own registry.
  def test_request_payload_carries_zero_tools
    server = ChroniclerScriptedServer.new(RESPONSE_BODY)

    Boukensha.run_chronicler(
      goal: "explore the temple square", outcome: "Completed: done.", checkpoints: [],
      logger: test_logger, backend: :ollama, model: "qwen3:8b", ollama_host: server.host
    )
    server.stop

    sent = JSON.parse(server.captured_body)
    assert_equal [], sent["tools"]
  end
end
