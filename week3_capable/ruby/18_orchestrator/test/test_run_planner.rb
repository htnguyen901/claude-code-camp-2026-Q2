require_relative "helper"
require "socket"
require "json"

# Serves one canned Ollama-shaped JSON response — reuses the ScriptedServer
# pattern from test_telemetry.rb/test_agent_stop_reason.rb, pointed at via
# Backends::Ollama's `host:` constructor kwarg so Boukensha.run_planner can
# be exercised through a real backend without a live provider.
class PlannerScriptedServer
  def initialize(body)
    @body          = body
    @captured_body = nil
    @server        = TCPServer.new("127.0.0.1", 0)
    @thread        = Thread.new { accept_once }
    @thread.report_on_exception = false
  end

  def host = "http://127.0.0.1:#{@server.addr[1]}"

  # The raw JSON request body the one request actually sent — captured only
  # after #stop has joined the server thread.
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

# Boukensha.run_planner — docs/plans/agent_loop/orchestrator.md §3's call
# site: a bare Client#call + PromptBuilder, no Agent#run loop (Planner has
# no tools to dispatch). Exercised end to end through Backends::Ollama
# (its `ollama_host:` kwarg is the one seam that lets a test point a real
# backend at a local server instead of a live provider).
class TestRunPlanner < Minitest::Test
  RESPONSE_BODY = JSON.generate(message: { content: "1. Find the temple entrance.\n2. Speak to the priest." })

  def test_run_planner_returns_the_models_plan_text
    server = PlannerScriptedServer.new(RESPONSE_BODY)

    text = Boukensha.run_planner(goal: "explore the temple square", backend: :ollama, model: "qwen3:8b", ollama_host: server.host)
    server.stop

    assert_equal "1. Find the temple entrance.\n2. Speak to the priest.", text
  end

  # The full loop this exists for: Planner's text, assigned to a Player
  # Context's #plan, must show up in that Player's effective_system (what
  # the model actually sees) and never as a Context#messages entry — the
  # same invariant test_context_plan.rb/test_backends_effective_system.rb
  # already cover for a hand-set plan, proven here end to end with a real
  # (scripted) Planner call as the plan's source.
  def test_planner_output_reaches_effective_system_and_never_messages
    server = PlannerScriptedServer.new(RESPONSE_BODY)
    plan_text = Boukensha.run_planner(goal: "explore the temple square", backend: :ollama, model: "qwen3:8b", ollama_host: server.host)
    server.stop

    player_ctx = Boukensha::Context.new(system: "You are the Player.")
    player_ctx.add_message(:user, "explore the temple square")
    player_ctx.plan = plan_text

    assert_includes player_ctx.effective_system, "Find the temple entrance"
    refute player_ctx.messages.any? { |m| m.content.to_s.include?("Find the temple entrance") },
           "the plan must never leak into Context#messages, where compact_messages! could drop it"
  end

  # orchestrator.md §3: on a replan, the Planner call also carries the prior
  # plan and a transcript tail, so it can say what changed instead of
  # restating from scratch.
  def test_replan_call_includes_prior_plan_and_transcript_tail_in_the_request
    server = PlannerScriptedServer.new(RESPONSE_BODY)

    Boukensha.run_planner(
      goal: "explore the temple square",
      prior_plan: "1. Find the temple entrance.",
      transcript_tail: "You tried the north door; it was locked.",
      backend: :ollama, model: "qwen3:8b", ollama_host: server.host
    )
    server.stop

    sent = JSON.parse(server.captured_body)
    user_text = sent["messages"].find { |m| m["role"] == "user" }["content"]
    assert_includes user_text, "explore the temple square"
    assert_includes user_text, "Find the temple entrance"
    assert_includes user_text, "locked"
  end
end
