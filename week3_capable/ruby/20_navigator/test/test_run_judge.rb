require_relative "helper"
require "socket"
require "json"

# Serves a queue of canned Ollama-shaped JSON responses in order, capturing
# every request body sent to it — the Judge's own Agent#run loop can need
# more than one round trip (a tool_use call, then a final VERDICT-carrying
# response), so this mirrors test_session.rb's SessionScriptedServer rather
# than test_run_planner.rb's one-shot PlannerScriptedServer.
class JudgeScriptedServer
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

# A stand-in for Boukensha::McpConnections — responds to #register(registry)
# by registering canned fake tools directly, exactly the surface run_judge/
# run_planner actually call. No fake Player/Context involved: there is no
# more "reuse another task's already-filtered tools" step (see
# docs/plans/tools_policy/mcp_connection_sharing.md) — the Judge/Planner
# gets its own look at the full catalog, filtered only by its own policy.
class FakeMcpConnections
  def initialize(&block) = @block = block
  def register(registry) = @block&.call(registry)
end

# Boukensha.run_judge — docs/plans/agent_loop/evaluator.md, reworked by
# agents_tools/tool_scope_rework.md §0/§2 into an overall mentor rather than
# a gameplay coach. Unlike run_planner (a bare Client#call), the Judge has
# read-only tools it may dispatch, so it runs a small Agent#run loop against
# its own throwaway Context/Registry, registered from the session's shared
# MCP connections and filtered through the Judge's own role: world_knowledge
# policy.
class TestRunJudge < Minitest::Test
  # run_judge reads tasks.judge/tool_roles through the process-global
  # Boukensha.config (memoized), the same way Boukensha.run/.repl/Session do
  # — so a test that needs the Judge to actually be *able* to dispatch a
  # tool has to point BOUKENSHA_DIR at a temp settings.yaml declaring
  # role: world_knowledge, and clear the memo first. Mirrors test_session.rb's
  # with_temp_boukensha_dir exactly.
  JUDGE_SETTINGS_YAML = <<~YAML
    tool_roles:
      world_knowledge: [room_knowledge]
    tasks:
      judge:
        tools:
          role: world_knowledge
  YAML

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

  def test_logger
    Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "judge-test-#{rand(1_000_000)}")
  end

  # A stand-in for the session's shared MCP connections: canned fake tools
  # registered directly onto whatever registry run_judge builds — no fake
  # Player/Context involved.
  def fake_mcp
    FakeMcpConnections.new { |registry| yield registry if block_given? }
  end

  def run_judge(server, mcp:, **overrides)
    Boukensha.run_judge(
      plan: overrides.delete(:plan) || "1. Find the temple entrance.\n2. Speak to the priest.",
      transcript_tail: overrides.delete(:transcript_tail) || "You entered the temple square and looked around.",
      mcp: mcp,
      logger: overrides.delete(:logger) || test_logger,
      backend: :ollama, model: "qwen3:8b", ollama_host: server.host,
      **overrides
    )
  end

  # No tool config needed — these responses never call a tool, so the
  # Judge's tool_policy is never exercised.
  def test_a_clearly_on_track_transcript_parses_as_continue
    server = JudgeScriptedServer.new([
      ollama_text_response("The Player is following the plan and made real progress this turn.\nVERDICT: continue")
    ])

    result = run_judge(server, mcp: fake_mcp)
    server.stop

    assert_equal :continue, result[:verdict]
    assert_includes result[:text], "VERDICT: continue"
  end

  # "Same room repeated many times" — evaluator.md's acceptance criteria's
  # own example of a clearly-stuck transcript.
  def test_a_clearly_stuck_transcript_parses_as_flag
    server = JudgeScriptedServer.new([
      ollama_text_response("The Player has re-entered the same room five times without making progress.\nVERDICT: flag")
    ])

    result = run_judge(server, mcp: fake_mcp, transcript_tail: "look -> Temple Square. move north -> Temple Square. look -> Temple Square.")
    server.stop

    assert_equal :flag, result[:verdict]
  end

  def test_a_stale_plan_parses_as_replan
    server = JudgeScriptedServer.new([
      ollama_text_response("The north door the plan assumed is locked; the plan needs to change.\nVERDICT: replan")
    ])

    result = run_judge(server, mcp: fake_mcp)
    server.stop

    assert_equal :replan, result[:verdict]
  end

  # evaluator.md §3: an unparseable response should not silently sail
  # through as :continue — it falls back to :flag, the "stop, a human
  # should look" verdict.
  def test_a_response_with_no_verdict_line_falls_back_to_flag
    server = JudgeScriptedServer.new([ollama_text_response("I think things are fine, generally speaking.")])

    result = run_judge(server, mcp: fake_mcp)
    server.stop

    assert_equal :flag, result[:verdict]
  end

  # The case evaluator.md's acceptance criteria calls out explicitly: a
  # transcript claim contradicted by room_knowledge. The Judge dispatches
  # the tool itself (a real Agent#run tool_use round trip), then reaches a
  # verdict from what it found. Needs role: world_knowledge actually
  # configured — see JUDGE_SETTINGS_YAML.
  def test_room_knowledge_contradicts_the_transcripts_claim_and_the_judge_flags_it
    with_temp_boukensha_dir(JUDGE_SETTINGS_YAML) do
      called_with = nil
      mcp = fake_mcp do |registry|
        registry.tool("room_knowledge", description: "check examination history", parameters: { room_title: { type: "string" } }) do |room_title:|
          called_with = room_title
          { room_title: room_title, examined: [], unexamined: ["fountain"] }
        end
      end

      server = JudgeScriptedServer.new([
        ollama_tool_use_response(name: "room_knowledge", args: { room_title: "The Temple Square" }),
        ollama_text_response("The transcript claims the fountain was examined, but room_knowledge shows it was not.\nVERDICT: flag")
      ])

      result = run_judge(server, mcp: mcp, transcript_tail: "You examined the fountain closely.")
      server.stop

      assert_equal "The Temple Square", called_with
      assert_equal :flag, result[:verdict]
      assert_equal 2, server.captured_bodies.size
    end
  end

  # The Judge's own ToolPolicy (role: world_knowledge) must win even when
  # the shared MCP connections would offer a broader catalog — Registry#tool
  # still silently drops anything not on the world_knowledge list, so a
  # scripted attempt to call a denied tool comes back denied rather than
  # actually running the block.
  def test_a_tool_outside_the_configured_role_is_never_dispatchable_by_the_judge
    with_temp_boukensha_dir(JUDGE_SETTINGS_YAML) do
      attacked = false
      mcp = fake_mcp do |registry|
        registry.tool("tbamud__attack", description: "attack", parameters: { target: { type: "string" } }) do |target:|
          attacked = true
          "you attack #{target}"
        end
      end

      server = JudgeScriptedServer.new([
        ollama_tool_use_response(name: "tbamud__attack", args: { target: "a rat" }),
        ollama_text_response("Could not verify — that tool was denied.\nVERDICT: flag")
      ])

      result = run_judge(server, mcp: mcp)
      server.stop

      refute attacked, "the Judge's role: world_knowledge policy must deny tbamud__attack even though the shared connections offer it"
      assert_equal :flag, result[:verdict]
    end
  end

  # docs/plans/agent_loop/evaluator_judge_redesign.md §4/acceptance
  # criteria: with history:/repeated_actions: both nil (the default), the
  # request payload must be byte-identical to pre-redesign run_judge — a
  # direct regression test.
  def test_with_no_history_or_repeated_actions_the_request_is_unchanged
    server = JudgeScriptedServer.new([ollama_text_response("Fine.\nVERDICT: continue")])

    run_judge(server, mcp: fake_mcp)
    server.stop

    sent = JSON.parse(server.captured_bodies.first)
    user_text = sent["messages"].find { |m| m["role"] == "user" }["content"]
    refute_includes user_text, "previous judgements"
    refute_includes user_text, "Repeated actions detected"
  end

  def test_history_is_rendered_into_the_request_when_passed
    history = Boukensha::JudgeMemory.new
    history.record(Boukensha::JudgeMemory::Entry.new(
      turn: 1, stop_reason: :max_iterations, plan: "1. Find food.",
      verdict: :continue, reasoning: "still looking for food", repeated_actions: {}, overridden: false
    ))

    server = JudgeScriptedServer.new([ollama_text_response("Fine.\nVERDICT: continue")])
    run_judge(server, mcp: fake_mcp, history: history)
    server.stop

    sent = JSON.parse(server.captured_bodies.first)
    user_text = sent["messages"].find { |m| m["role"] == "user" }["content"]
    assert_includes user_text, "Your previous judgements this session"
    assert_includes user_text, "still looking for food"
  end

  def test_repeated_actions_are_rendered_into_the_request_when_passed
    server = JudgeScriptedServer.new([ollama_text_response("Fine.\nVERDICT: continue")])
    run_judge(server, mcp: fake_mcp, repeated_actions: { "tbamud__ask(target: beggar)" => 4 })
    server.stop

    sent = JSON.parse(server.captured_bodies.first)
    user_text = sent["messages"].find { |m| m["role"] == "user" }["content"]
    assert_includes user_text, "Repeated actions detected"
    assert_includes user_text, "tbamud__ask(target: beggar)×4"
  end

  # The mechanical backstop, evaluator_judge_redesign.md §6: an LLM verdict
  # of :continue is forced to :replan when repeated_actions is non-empty,
  # deterministically — independent of the LLM's own reasoning. overridden:
  # true is returned and logged.
  def test_a_continue_verdict_is_mechanically_overridden_to_replan_when_actions_repeat
    server = JudgeScriptedServer.new([ollama_text_response("Looks fine to me.\nVERDICT: continue")])
    logger = test_logger

    result = run_judge(server, mcp: fake_mcp, logger: logger, repeated_actions: { "tbamud__ask(target: beggar)" => 4 })
    server.stop

    assert_equal :replan, result[:verdict]
    assert_equal true, result[:overridden]

    logger.close
    event = File.readlines(logger.path).map { |l| JSON.parse(l) }.find { |e| e["phase"] == "judge_verdict" }
    assert_equal "replan", event["verdict"]
    assert_equal true, event["overridden"]
  end

  # A non-:continue LLM verdict is never touched by the override, even with
  # repeated actions present — the mechanical guard only ever steps
  # :continue up, it never downgrades a :replan/:flag the LLM already chose.
  def test_the_override_never_fires_on_a_non_continue_verdict
    server = JudgeScriptedServer.new([ollama_text_response("The plan is stale.\nVERDICT: replan")])

    result = run_judge(server, mcp: fake_mcp, repeated_actions: { "tbamud__ask(target: beggar)" => 4 })
    server.stop

    assert_equal :replan, result[:verdict]
    assert_equal false, result[:overridden]
  end

  # Second-order escalation (§6): if the most recent history entry already
  # shows a mechanically-forced :replan and the same repeated-action signal
  # fires again, the override escalates straight to :flag instead of
  # looping on silent replans forever.
  def test_the_override_escalates_to_flag_when_the_last_history_entry_was_already_a_replan
    history = Boukensha::JudgeMemory.new
    history.record(Boukensha::JudgeMemory::Entry.new(
      turn: 1, stop_reason: :max_iterations, plan: "1. Find food.",
      verdict: :replan, reasoning: "repeated begging forced a replan", repeated_actions: { "ask" => 3 }, overridden: true
    ))

    server = JudgeScriptedServer.new([ollama_text_response("Looks fine to me.\nVERDICT: continue")])
    result = run_judge(server, mcp: fake_mcp, history: history, repeated_actions: { "tbamud__ask(target: beggar)" => 5 })
    server.stop

    assert_equal :flag, result[:verdict]
    assert_equal true, result[:overridden]
  end
end
