require_relative "helper"
require "socket"
require "json"

# Serves a queue of canned Ollama-shaped JSON responses in order, capturing
# every request body — same pattern as test_repl_judge.rb's
# ReplJudgeScriptedServer.
class SelfManageScriptedServer
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

# Repl's self-managed continuation loop — docs/plans/agent_loop/
# self_management.md §2/§3. self_manage: true is process-global config (read
# straight off Boukensha.config, not a Repl constructor kwarg), so these
# tests point BOUKENSHA_DIR at a temp settings.yaml and clear the memo first
# — same with_temp_boukensha_dir pattern test_run_judge.rb/test_session.rb
# already use for the same reason.
class TestReplSelfManage < Minitest::Test
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

  def ollama_tool_use_response(name: "look", args: {})
    JSON.generate(message: { content: "", tool_calls: [{ function: { name: name, arguments: args } }] })
  end

  # A Repl with no real servers wired in, for tests that only exercise the
  # pause/resume/stop primitives and slash-command plumbing — never calls
  # run_turn, so the backend/logger never actually make a request.
  def minimal_repl
    ctx      = Boukensha::Context.new(system: "You are the Player.")
    registry = Boukensha::Registry.new(ctx)
    backend  = Boukensha::Backends::Ollama.new(host: "http://127.0.0.1:1", model: "qwen3:8b")
    builder  = Boukensha::PromptBuilder.new(ctx, backend)
    client   = Boukensha::Client.new(builder)
    logger   = Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "self-manage-test-#{rand(1_000_000)}")

    repl = Boukensha::Repl.new(context: ctx, registry: registry, builder: builder, client: client, logger: logger,
                                task_name: "player", judge_enabled: false)
    output = []
    repl.on_output { |str| output << str }
    [repl, output]
  end

  def build_repl(player_server, judge_server:, max_iterations: 1)
    ctx      = Boukensha::Context.new(system: "You are the Player.")
    registry = Boukensha::Registry.new(ctx)
    backend  = Boukensha::Backends::Ollama.new(host: player_server.host, model: "qwen3:8b")
    builder  = Boukensha::PromptBuilder.new(ctx, backend)
    client   = Boukensha::Client.new(builder)
    logger   = Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "self-manage-test-#{rand(1_000_000)}")

    repl = Boukensha::Repl.new(
      context: ctx, registry: registry, builder: builder, client: client, logger: logger,
      task_name: "player", max_iterations: max_iterations, planner_enabled: false,
      judge_enabled: true, judge_backend: :ollama, judge_model: "qwen3:8b", judge_ollama_host: judge_server.host
    )
    output = []
    repl.on_output { |str| output << str }
    [repl, logger, output]
  end

  # ---------- pause/resume/stop primitives (§2) --------------------------

  def test_primitives_are_no_ops_from_manual
    repl, = minimal_repl
    assert_equal :manual, repl.autonomy_state

    repl.pause_autonomy!
    assert_equal :manual, repl.autonomy_state
    repl.resume_autonomy!
    assert_equal :manual, repl.autonomy_state
    repl.stop_autonomy!
    assert_equal :manual, repl.autonomy_state
  end

  def test_pause_then_resume_round_trips_and_is_idempotent
    repl, = minimal_repl
    repl.instance_variable_set(:@autonomy_state, :running)

    repl.pause_autonomy!
    assert_equal :paused, repl.autonomy_state
    repl.pause_autonomy! # idempotent — already paused
    assert_equal :paused, repl.autonomy_state

    repl.resume_autonomy!
    assert_equal :running, repl.autonomy_state
    repl.resume_autonomy! # idempotent — not paused, no-op
    assert_equal :running, repl.autonomy_state
  end

  def test_stop_falls_back_to_manual_from_either_running_or_paused
    repl, = minimal_repl

    repl.instance_variable_set(:@autonomy_state, :running)
    repl.stop_autonomy!
    assert_equal :stopped, repl.autonomy_state

    repl.instance_variable_set(:@autonomy_state, :paused)
    repl.stop_autonomy!
    assert_equal :stopped, repl.autonomy_state
  end

  def test_pause_command_reports_when_no_run_is_in_progress
    repl, output = minimal_repl
    repl.handle_command("/pause")
    assert_includes output.last, "no self-managed run in progress"
  end

  def test_pause_and_continue_commands_drive_the_state_machine
    repl, output = minimal_repl
    repl.instance_variable_set(:@autonomy_state, :running)

    repl.handle_command("/pause")
    assert_equal :paused, repl.autonomy_state
    assert_includes output.last, "paused"

    repl.handle_command("/continue")
    assert_equal :running, repl.autonomy_state
    assert_includes output.last, "resumed"
  end

  def test_continue_command_reports_when_nothing_is_paused
    repl, output = minimal_repl
    repl.handle_command("/continue")
    assert_equal :manual, repl.autonomy_state
    assert_includes output.last, "no paused self-managed run"
  end

  def test_stop_command_falls_back_to_manual
    repl, output = minimal_repl
    repl.instance_variable_set(:@autonomy_state, :running)

    repl.handle_command("/stop")
    assert_equal :stopped, repl.autonomy_state
    assert_includes output.last, "stopped"
  end

  def test_help_only_mentions_self_manage_commands_when_enabled
    repl, output = minimal_repl
    repl.handle_command("/help")
    refute_includes output.last, "/pause"

    with_temp_boukensha_dir("session:\n  self_manage: true\n") do
      repl.handle_command("/help")
      assert_includes output.last, "/pause"
    end
  end

  # ---------- the self-managed loop itself (§3) ---------------------------

  def test_self_manage_disabled_by_default_leaves_autonomy_state_manual
    player_server = SelfManageScriptedServer.new([ollama_text_response("Done!")])
    judge_server  = SelfManageScriptedServer.new([])

    repl, = build_repl(player_server, judge_server: judge_server)
    repl.run_turn("explore")

    player_server.stop
    judge_server.stop

    assert_equal :manual, repl.autonomy_state
    assert_equal 0, judge_server.captured_bodies.size
  end

  # Judge :continue at a checkpoint -> the loop issues one more turn on its
  # own with Session::CONTINUE_INSTRUCTION. That turn completes naturally
  # (agent.stop_reason == :completed), but a naturally-completed turn is
  # deliberately NOT itself a stopping condition while self-managing — with
  # no human present to decide what a plain text reply means, the Judge is
  # forced to check in again regardless of Session.checkpoint?, and only
  # its verdict (here :flag) actually stops the loop.
  def test_judge_continue_auto_issues_one_more_turn_then_judge_flag_stops_it
    player_server = SelfManageScriptedServer.new([
      ollama_tool_use_response(name: "look"),          # iteration 1: forces a wrap-up
      ollama_text_response("(wrap up) still exploring"),
      ollama_text_response("Done! Found the temple.")  # the auto-issued "continue" turn
    ])
    judge_server = SelfManageScriptedServer.new([
      ollama_text_response("Still making progress.\nVERDICT: continue"),
      ollama_text_response("Goal reached.\nVERDICT: flag")
    ])

    with_temp_boukensha_dir("session:\n  self_manage: true\n") do
      repl, _logger, output = build_repl(player_server, judge_server: judge_server)
      repl.run_turn("explore the temple square")

      player_server.stop
      judge_server.stop

      assert_equal 3, player_server.captured_bodies.size
      assert_equal 2, judge_server.captured_bodies.size, "the naturally-completed continuation turn still gets a forced Judge check-in"
      assert_equal :manual, repl.autonomy_state

      continue_body = JSON.parse(player_server.captured_bodies.last)
      last_user = continue_body["messages"].reverse.find { |m| m["role"] == "user" }
      assert_equal Boukensha::Session::CONTINUE_INSTRUCTION, last_user["content"]

      assert(output.any? { |line| line.include?("Done! Found the temple.") })
    end
  end

  # A :flag verdict is a stopping condition the same as the human-driven
  # path — the loop never even starts.
  def test_judge_flag_stops_before_any_auto_continuation
    player_server = SelfManageScriptedServer.new([
      ollama_tool_use_response(name: "look"),
      ollama_text_response("(wrap up) something's off")
    ])
    judge_server = SelfManageScriptedServer.new([
      ollama_text_response("Repeating the same failed action.\nVERDICT: flag")
    ])

    with_temp_boukensha_dir("session:\n  self_manage: true\n") do
      repl, = build_repl(player_server, judge_server: judge_server)
      repl.run_turn("explore the temple square")

      player_server.stop
      judge_server.stop

      assert_equal 2, player_server.captured_bodies.size, "no auto-continuation turn after a :flag"
      assert_equal :manual, repl.autonomy_state
    end
  end

  # Session cost budget exhausted -> the loop stops before starting another
  # turn at all, not even a wind-down call.
  def test_budget_exhausted_stops_before_another_turn
    player_server = SelfManageScriptedServer.new([
      ollama_tool_use_response(name: "look"),
      ollama_text_response("(wrap up) still exploring")
    ])
    judge_server = SelfManageScriptedServer.new([
      ollama_text_response("Still making progress.\nVERDICT: continue")
    ])

    with_temp_boukensha_dir("session:\n  self_manage: true\n  max_cost_usd: 1.0\n") do
      repl, logger, output = build_repl(player_server, judge_server: judge_server)
      logger.define_singleton_method(:total_cost_usd) { 1.0 } # already at budget
      repl.run_turn("explore the temple square")

      player_server.stop
      judge_server.stop

      assert_equal 2, player_server.captured_bodies.size, "no further player call once exhausted"
      assert_equal :manual, repl.autonomy_state
      assert(output.any? { |line| line.include?("cost budget exhausted") })
    end
  end

  # Crossing the warn threshold gets exactly one more turn (a wind-down
  # call, not a plain "continue") before the loop stops for good —
  # unconditionally, regardless of what the Judge says about that turn (the
  # budget, not the Judge, is what ends a wind-down).
  def test_budget_warn_issues_exactly_one_wind_down_turn_then_stops
    player_server = SelfManageScriptedServer.new([
      ollama_tool_use_response(name: "look"),
      ollama_text_response("(wrap up) still exploring"),
      ollama_text_response("Wrapping up as asked.") # the wind-down call
    ])
    judge_server = SelfManageScriptedServer.new([
      ollama_text_response("Still making progress.\nVERDICT: continue"),
      ollama_text_response("Wrapping up.\nVERDICT: continue")
    ])

    with_temp_boukensha_dir("session:\n  self_manage: true\n  max_cost_usd: 1.0\n  cost_warn_pct: 0.5\n") do
      repl, logger, = build_repl(player_server, judge_server: judge_server)
      logger.define_singleton_method(:total_cost_usd) { 0.6 } # >= warn threshold, < budget
      repl.run_turn("explore the temple square")

      player_server.stop
      judge_server.stop

      assert_equal 3, player_server.captured_bodies.size
      assert_equal 2, judge_server.captured_bodies.size, "the wind-down turn completes naturally, but self-managing still forces a Judge check-in on it"
      assert_equal :manual, repl.autonomy_state

      wind_down_body = JSON.parse(player_server.captured_bodies.last)
      last_user = wind_down_body["messages"].reverse.find { |m| m["role"] == "user" }
      assert_equal Boukensha::Repl::WIND_DOWN_INSTRUCTION, last_user["content"]
    end
  end

  # wait_while_paused is the mechanism that makes /pause actually block
  # further auto-continuation without aborting anything already in flight —
  # exercised directly (rather than through a full networked run_turn) so
  # the test is deterministic: no risk of a stray "continue" request racing
  # a real scripted server that has no more canned responses to give it.
  def test_wait_while_paused_blocks_then_resumes_once_resume_autonomy_lands
    repl, = minimal_repl
    repl.instance_variable_set(:@autonomy_state, :paused)

    result = nil
    t = Thread.new { result = repl.send(:wait_while_paused) }
    sleep 0.05
    assert_equal :paused, repl.autonomy_state, "still blocked until resumed"

    repl.resume_autonomy!
    t.join(2)

    assert_equal :running, result
  end

  # A /stop that lands while paused must unblock the loop too — pause is
  # resumable, but stop always wins and ends the run for good.
  def test_wait_while_paused_unblocks_as_stopped_once_stop_autonomy_lands
    repl, = minimal_repl
    repl.instance_variable_set(:@autonomy_state, :paused)

    result = nil
    t = Thread.new { result = repl.send(:wait_while_paused) }
    sleep 0.05

    repl.stop_autonomy!
    t.join(2)

    assert_equal :stopped, result
  end
end
