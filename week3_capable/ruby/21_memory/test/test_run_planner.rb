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

# Serves a queue of canned responses in order — needed once a scripted run
# can involve a tool_use round trip before the final plan text, same reason
# test_run_judge.rb's JudgeScriptedServer exists instead of the one-shot
# PlannerScriptedServer above.
class PlannerMultiScriptedServer
  def initialize(bodies)
    @bodies          = bodies.dup
    @captured_bodies = []
    @server          = TCPServer.new("127.0.0.1", 0)
    @thread          = Thread.new { accept_loop }
    @thread.report_on_exception = false
  end

  def host = "http://127.0.0.1:#{@server.addr[1]}"
  def captured_bodies = @captured_bodies

  def stop
    @thread.join(1)
    @server.close
  rescue StandardError
    nil
  end

  private

  def accept_loop
    @bodies.each do |body|
      conn = @server.accept
      conn.gets
      headers = {}
      while (line = conn.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.downcase] = value.strip if key && value
      end
      @captured_bodies << conn.read(headers["content-length"].to_i)
      conn.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
    ensure
      conn&.close
    end
  rescue IOError, Errno::EBADF
    nil
  end
end

# A stand-in for Boukensha::McpConnections — see test_run_judge.rb's
# FakeMcpConnections for the full rationale (no fake Player/Context
# involved; the Planner gets its own look at the full catalog, filtered
# only by its own policy).
class FakeMcpConnections
  def initialize(&block) = @block = block
  def register(registry) = @block&.call(registry)
end

# Boukensha.run_planner — docs/plans/agent_loop/orchestrator.md §3's call
# site: a small Agent#run loop over a throwaway Context/Registry built from
# `tasks.planner.tools`, exactly like Boukensha.run_judge (see
# test_run_judge.rb's header). With no `tools:` block configured and no
# mcp: passed, that resolves to zero tools and the loop still only ever
# makes one round trip — the tests below that don't configure tools cover
# exactly that default-deny case. Exercised end to end through
# Backends::Ollama (its `ollama_host:` kwarg is the one seam that lets a
# test point a real backend at a local server instead of a live provider).
class TestRunPlanner < Minitest::Test
  RESPONSE_BODY = JSON.generate(message: { content: "1. Find the temple entrance.\n2. Speak to the priest." })

  # run_planner logs through Agent#run now (like run_judge), so `logger:` is
  # a required kwarg, not optional — mirrors test_run_judge.rb's test_logger.
  def test_logger
    Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "planner-test-#{rand(1_000_000)}")
  end

  def with_temp_boukensha_dir(yaml)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "settings.yaml"), yaml)
      old_dir = ENV["BOUKENSHA_DIR"]
      old_cfg = Boukensha.instance_variable_get(:@config)
      ENV["BOUKENSHA_DIR"] = dir
      Boukensha.instance_variable_set(:@config, nil)
      yield
    ensure
      old_dir.nil? ? ENV.delete("BOUKENSHA_DIR") : ENV["BOUKENSHA_DIR"] = old_dir
      Boukensha.instance_variable_set(:@config, old_cfg)
    end
  end

  def ollama_text_response(text)
    JSON.generate(message: { content: text })
  end

  def ollama_tool_use_response(name:, args: {})
    JSON.generate(message: { content: "", tool_calls: [{ function: { name: name, arguments: args } }] })
  end

  def test_run_planner_returns_the_models_plan_text
    server = PlannerScriptedServer.new(RESPONSE_BODY)

    text = Boukensha.run_planner(goal: "explore the temple square", logger: test_logger, backend: :ollama, model: "qwen3:8b", ollama_host: server.host)
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
    plan_text = Boukensha.run_planner(goal: "explore the temple square", logger: test_logger, backend: :ollama, model: "qwen3:8b", ollama_host: server.host)
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
      logger: test_logger, backend: :ollama, model: "qwen3:8b", ollama_host: server.host
    )
    server.stop

    sent = JSON.parse(server.captured_body)
    user_text = sent["messages"].find { |m| m["role"] == "user" }["content"]
    assert_includes user_text, "explore the temple square"
    assert_includes user_text, "Find the temple entrance"
    assert_includes user_text, "locked"
  end

  # docs/plans/agent_loop/evaluator_judge_redesign.md §7: a replan carries
  # forward *why* the prior plan is being replaced, so the new plan has a
  # chance of actually avoiding the pattern that triggered it.
  def test_replan_reason_appears_in_the_request_when_passed
    server = PlannerScriptedServer.new(RESPONSE_BODY)

    Boukensha.run_planner(
      goal: "explore the temple square",
      prior_plan: "1. Ask beggars for food.",
      replan_reason: "Repeated actions that triggered this replan: tbamud__ask(target: beggar)×4",
      logger: test_logger, backend: :ollama, model: "qwen3:8b", ollama_host: server.host
    )
    server.stop

    sent = JSON.parse(server.captured_body)
    user_text = sent["messages"].find { |m| m["role"] == "user" }["content"]
    assert_includes user_text, "Why the prior plan is being replaced"
    assert_includes user_text, "tbamud__ask(target: beggar)×4"
  end

  # nil (the default) omits the line entirely — regression coverage
  # alongside the existing prior_plan/transcript_tail-only test above.
  def test_replan_reason_is_omitted_entirely_when_nil
    server = PlannerScriptedServer.new(RESPONSE_BODY)

    Boukensha.run_planner(goal: "explore the temple square", logger: test_logger, backend: :ollama, model: "qwen3:8b", ollama_host: server.host)
    server.stop

    sent = JSON.parse(server.captured_body)
    user_text = sent["messages"].find { |m| m["role"] == "user" }["content"]
    refute_includes user_text, "Why the prior plan is being replaced"
  end

  # The actual bug this settings.yaml block was written to fix: a
  # `tasks.planner.tools:` grant used to be silently ignored (run_planner
  # hardcoded `tools: []` regardless of config). Now it's read through
  # Tasks::Base.tool_policy exactly like every other task, and the Planner
  # can really dispatch a granted tool — reusing the Player's already-
  # connected Tool objects, same as run_judge's equivalent test.
  PLANNER_SETTINGS_YAML = <<~YAML
    tool_roles:
      world_knowledge: [room_knowledge]
    tasks:
      planner:
        tools:
          role: world_knowledge
  YAML

  def fake_mcp
    FakeMcpConnections.new { |registry| yield registry if block_given? }
  end

  def test_a_configured_role_lets_the_planner_actually_dispatch_a_tool
    with_temp_boukensha_dir(PLANNER_SETTINGS_YAML) do
      called_with = nil
      mcp = fake_mcp do |registry|
        registry.tool("room_knowledge", description: "check examination history", parameters: { room_title: { type: "string" } }) do |room_title:|
          called_with = room_title
          { room_title: room_title, examined: [], unexamined: ["fountain"] }
        end
      end

      server = PlannerMultiScriptedServer.new([
        ollama_tool_use_response(name: "room_knowledge", args: { room_title: "The Temple Square" }),
        ollama_text_response("1. Examine the fountain, since room_knowledge shows it's unexamined.")
      ])

      text = Boukensha.run_planner(goal: "explore the temple square", logger: test_logger, mcp: mcp, backend: :ollama, model: "qwen3:8b", ollama_host: server.host)
      server.stop

      assert_equal "The Temple Square", called_with
      assert_includes text, "Examine the fountain"
      assert_equal 2, server.captured_bodies.size
    end
  end

  # The Planner's own ToolPolicy must still win even when the shared MCP
  # connections would offer a broader catalog — mirrors test_run_judge.rb's
  # equivalent denial test.
  def test_a_tool_outside_the_configured_role_is_never_dispatchable_by_the_planner
    with_temp_boukensha_dir(PLANNER_SETTINGS_YAML) do
      attacked = false
      mcp = fake_mcp do |registry|
        registry.tool("tbamud__attack", description: "attack", parameters: { target: { type: "string" } }) do |target:|
          attacked = true
          "you attack #{target}"
        end
      end

      server = PlannerMultiScriptedServer.new([
        ollama_tool_use_response(name: "tbamud__attack", args: { target: "a rat" }),
        ollama_text_response("1. That tool was denied — planning without it.")
      ])

      Boukensha.run_planner(goal: "explore the temple square", logger: test_logger, mcp: mcp, backend: :ollama, model: "qwen3:8b", ollama_host: server.host)
      server.stop

      refute attacked, "the Planner's configured role must deny tbamud__attack even though the shared connections offer it"
    end
  end

  # With no `tools:` block for tasks.planner (the default in this suite's
  # ambient config), shared connections with tools registered still yield
  # zero tools for the Planner — deny-by-default, per Tasks::Base.tool_policy,
  # not because mcp: was omitted.
  def test_no_tools_block_denies_everything_even_with_shared_connections
    dispatched = false
    mcp = fake_mcp do |registry|
      registry.tool("tbamud__look", description: "look", parameters: {}) do
        dispatched = true
        "a quiet room"
      end
    end

    server = PlannerScriptedServer.new(RESPONSE_BODY)
    Boukensha.run_planner(goal: "explore the temple square", logger: test_logger, mcp: mcp, backend: :ollama, model: "qwen3:8b", ollama_host: server.host)
    server.stop

    refute dispatched, "no tasks.planner.tools block means deny-by-default, regardless of what the shared connections offer"
  end
end
