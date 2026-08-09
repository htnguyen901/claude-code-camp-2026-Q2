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

# Boukensha.run_judge — docs/plans/agent_loop/evaluator.md. Unlike
# run_planner (a bare Client#call), the Judge has read-only tools it may
# dispatch, so it runs a small Agent#run loop against its own throwaway
# Context/Registry, built by reusing the Player's already-registered Tool
# objects filtered through the Judge's own role: inspector policy.
class TestRunJudge < Minitest::Test
  # run_judge reads tasks.judge/tool_roles through the process-global
  # Boukensha.config (memoized), the same way Boukensha.run/.repl/Session do
  # — so a test that needs the Judge to actually be *able* to dispatch a
  # tool has to point BOUKENSHA_DIR at a temp settings.yaml declaring
  # role: inspector, and clear the memo first. Mirrors test_session.rb's
  # with_temp_boukensha_dir exactly.
  JUDGE_SETTINGS_YAML = <<~YAML
    tool_roles:
      inspector: [tbamud__look, tbamud__examine, room_knowledge]
    tasks:
      judge:
        tools:
          role: inspector
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

  # A stand-in for the Player's live Context: some tools already registered
  # on it (via a permissive Registry, the way Boukensha.run/.repl/Session do
  # before Session ever calls the Judge), never itself run through Agent#run.
  def player_context_with_tools
    ctx = Boukensha::Context.new(system: "You are the Player.")
    registry = Boukensha::Registry.new(ctx)
    yield registry if block_given?
    ctx
  end

  def run_judge(server, player_context:, **overrides)
    Boukensha.run_judge(
      plan: overrides.delete(:plan) || "1. Find the temple entrance.\n2. Speak to the priest.",
      transcript_tail: overrides.delete(:transcript_tail) || "You entered the temple square and looked around.",
      player_context: player_context,
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
    ctx = player_context_with_tools

    result = run_judge(server, player_context: ctx)
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
    ctx = player_context_with_tools

    result = run_judge(server, player_context: ctx, transcript_tail: "look -> Temple Square. move north -> Temple Square. look -> Temple Square.")
    server.stop

    assert_equal :flag, result[:verdict]
  end

  def test_a_stale_plan_parses_as_replan
    server = JudgeScriptedServer.new([
      ollama_text_response("The north door the plan assumed is locked; the plan needs to change.\nVERDICT: replan")
    ])
    ctx = player_context_with_tools

    result = run_judge(server, player_context: ctx)
    server.stop

    assert_equal :replan, result[:verdict]
  end

  # evaluator.md §3: an unparseable response should not silently sail
  # through as :continue — it falls back to :flag, the "stop, a human
  # should look" verdict.
  def test_a_response_with_no_verdict_line_falls_back_to_flag
    server = JudgeScriptedServer.new([ollama_text_response("I think things are fine, generally speaking.")])
    ctx = player_context_with_tools

    result = run_judge(server, player_context: ctx)
    server.stop

    assert_equal :flag, result[:verdict]
  end

  # The case evaluator.md's acceptance criteria calls out explicitly: a
  # transcript claim contradicted by room_knowledge. The Judge dispatches
  # the tool itself (a real Agent#run tool_use round trip), then reaches a
  # verdict from what it found. Needs role: inspector actually configured —
  # see JUDGE_SETTINGS_YAML.
  def test_room_knowledge_contradicts_the_transcripts_claim_and_the_judge_flags_it
    with_temp_boukensha_dir(JUDGE_SETTINGS_YAML) do
      called_with = nil
      ctx = player_context_with_tools do |registry|
        registry.tool("room_knowledge", description: "check examination history", parameters: { room_title: { type: "string" } }) do |room_title:|
          called_with = room_title
          { room_title: room_title, examined: [], unexamined: ["fountain"] }
        end
      end

      server = JudgeScriptedServer.new([
        ollama_tool_use_response(name: "room_knowledge", args: { room_title: "The Temple Square" }),
        ollama_text_response("The transcript claims the fountain was examined, but room_knowledge shows it was not.\nVERDICT: flag")
      ])

      result = run_judge(server, player_context: ctx, transcript_tail: "You examined the fountain closely.")
      server.stop

      assert_equal "The Temple Square", called_with
      assert_equal :flag, result[:verdict]
      assert_equal 2, server.captured_bodies.size
    end
  end

  # docs/plans/agent_loop/evaluator.md's acceptance criteria: a Judge run
  # that dispatches tools must never mutate the Player's live Context.
  def test_judge_run_never_mutates_the_players_live_context
    with_temp_boukensha_dir(JUDGE_SETTINGS_YAML) do
      ctx = player_context_with_tools do |registry|
        registry.tool("room_knowledge", description: "check", parameters: { room_title: { type: "string" } }) do |room_title:|
          { room_title: room_title, examined: [], unexamined: [] }
        end
      end
      ctx.plan = "1. Original plan."
      ctx.add_message(:user, "explore the temple square")
      messages_before = ctx.messages.dup

      server = JudgeScriptedServer.new([
        ollama_tool_use_response(name: "room_knowledge", args: { room_title: "The Temple Square" }),
        ollama_text_response("Looks fine.\nVERDICT: continue")
      ])
      run_judge(server, player_context: ctx)
      server.stop

      assert_equal "1. Original plan.", ctx.plan
      assert_equal messages_before, ctx.messages
    end
  end

  # The Judge's own ToolPolicy (role: inspector) must win even when the
  # Player's live context has a broader tool registered — reuse_inspector_
  # tools re-registers every Player tool onto the Judge's throwaway
  # Registry, but that Registry's own policy still silently drops anything
  # not on the inspector list, so a scripted attempt to call it comes back
  # denied rather than actually running the block.
  def test_a_denied_tool_present_on_the_player_context_is_never_dispatchable_by_the_judge
    with_temp_boukensha_dir(JUDGE_SETTINGS_YAML) do
      attacked = false
      ctx = player_context_with_tools do |registry|
        registry.tool("tbamud__look", description: "look", parameters: {}) { "a quiet room" }
        registry.tool("tbamud__attack", description: "attack", parameters: { target: { type: "string" } }) do |target:|
          attacked = true
          "you attack #{target}"
        end
      end

      server = JudgeScriptedServer.new([
        ollama_tool_use_response(name: "tbamud__attack", args: { target: "a rat" }),
        ollama_text_response("Could not verify — that tool was denied.\nVERDICT: flag")
      ])

      result = run_judge(server, player_context: ctx)
      server.stop

      refute attacked, "the Judge's role: inspector policy must deny tbamud__attack even though the Player's context has it registered"
      assert_equal :flag, result[:verdict]
    end
  end
end
