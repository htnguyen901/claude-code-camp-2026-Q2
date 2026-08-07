require_relative "helper"
require "socket"
require "json"

# Serves a queue of canned Ollama-shaped JSON responses in order, capturing
# every request body — same pattern as test_repl_planner.rb's
# ReplScriptedServer, reused here since Repl's Judge checkpoints
# (docs/plans/agent_loop/repl_judge_integration.md) are a second,
# independent integration of the same Boukensha.run_judge call site
# Boukensha::Session already uses.
class ReplJudgeScriptedServer
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

# Repl's default Judge checkpoints — docs/plans/agent_loop/
# repl_judge_integration.md. This is the real `boukensha`/`bin/play_players`
# path (both funnel through Boukensha.repl -> Repl#run_turn), the same way
# repl_planner_integration.md made the Planner visible there.
class TestReplJudge < Minitest::Test
  def ollama_text_response(text)
    JSON.generate(message: { content: text })
  end

  def ollama_tool_use_response(name: "look", args: {})
    JSON.generate(message: { content: "", tool_calls: [{ function: { name: name, arguments: args } }] })
  end

  def build_repl(player_server, planner_server: nil, judge_server: nil, planner_enabled: false, judge_enabled: true, judge_every_n_turns: nil, max_iterations: nil)
    ctx      = Boukensha::Context.new(system: "You are the Player.")
    registry = Boukensha::Registry.new(ctx)
    backend  = Boukensha::Backends::Ollama.new(host: player_server.host, model: "qwen3:8b")
    builder  = Boukensha::PromptBuilder.new(ctx, backend)
    client   = Boukensha::Client.new(builder)
    logger   = Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "repl-judge-test-#{rand(1_000_000)}")

    repl = Boukensha::Repl.new(
      context: ctx, registry: registry, builder: builder, client: client, logger: logger,
      task_name: "player", max_iterations: max_iterations,
      planner_enabled: planner_enabled, planner_backend: :ollama, planner_model: "qwen3:8b",
      planner_ollama_host: planner_server&.host,
      judge_enabled: judge_enabled, judge_backend: :ollama, judge_model: "qwen3:8b",
      judge_ollama_host: judge_server&.host, judge_every_n_turns: judge_every_n_turns
    )
    output = []
    repl.on_output { |str| output << str }
    [repl, ctx, output]
  end

  def test_a_limit_triggered_checkpoint_calls_the_judge_and_prints_its_verdict
    player_server = ReplJudgeScriptedServer.new([
      ollama_tool_use_response(name: "look"),            # iteration 1: forces a wrap-up
      ollama_text_response("(wrap up) still exploring")  # max_iterations wrap-up call
    ])
    judge_server = ReplJudgeScriptedServer.new([
      ollama_text_response("The Player is still making progress.\nVERDICT: continue")
    ])

    repl, _ctx, output = build_repl(player_server, judge_server: judge_server, max_iterations: 1)
    repl.run_turn("explore the temple square")

    player_server.stop
    judge_server.stop

    assert_equal 1, judge_server.captured_bodies.size
    assert(output.any? { |line| line.include?("Judge: continue") && line.include?("still making progress") })
  end

  def test_a_naturally_completed_turn_does_not_call_the_judge
    player_server = ReplJudgeScriptedServer.new([ollama_text_response("Done! Found the temple.")])
    judge_server  = ReplJudgeScriptedServer.new([])

    repl, = build_repl(player_server, judge_server: judge_server)
    repl.run_turn("explore the temple square")

    player_server.stop
    judge_server.stop

    assert_equal 0, judge_server.captured_bodies.size
  end

  def test_judge_disabled_skips_it_entirely_even_at_a_checkpoint
    player_server = ReplJudgeScriptedServer.new([
      ollama_tool_use_response(name: "look"),
      ollama_text_response("(wrap up)")
    ])
    judge_server = ReplJudgeScriptedServer.new([])

    repl, = build_repl(player_server, judge_server: judge_server, judge_enabled: false, max_iterations: 1)
    repl.run_turn("explore the temple square")

    player_server.stop
    judge_server.stop

    assert_equal 0, judge_server.captured_bodies.size
  end

  def test_replan_verdict_reruns_the_planner_and_updates_the_plan
    planner_server = ReplJudgeScriptedServer.new([
      ollama_text_response("1. Look around.\n2. Move north."),               # initial seed
      ollama_text_response("1. The north door is locked; go east instead.")  # replan
    ])
    player_server = ReplJudgeScriptedServer.new([
      ollama_tool_use_response(name: "look"),
      ollama_text_response("(wrap up) door was locked")
    ])
    judge_server = ReplJudgeScriptedServer.new([
      ollama_text_response("The plan's assumption no longer holds.\nVERDICT: replan")
    ])

    repl, ctx, output = build_repl(player_server, planner_server: planner_server, judge_server: judge_server,
                                    planner_enabled: true, max_iterations: 1)
    repl.run_turn("explore the temple square")

    planner_server.stop
    player_server.stop
    judge_server.stop

    assert_equal 2, planner_server.captured_bodies.size, "initial seed + one replan"
    assert_includes ctx.plan, "go east instead"
    assert(output.any? { |line| line.include?("Replanned:") })
  end

  # A Judge-requested replan must not reintroduce Planner activity a session
  # has explicitly opted out of.
  def test_replan_verdict_is_skipped_when_the_planner_is_disabled
    planner_server = ReplJudgeScriptedServer.new([])
    player_server  = ReplJudgeScriptedServer.new([
      ollama_tool_use_response(name: "look"),
      ollama_text_response("(wrap up)")
    ])
    judge_server = ReplJudgeScriptedServer.new([
      ollama_text_response("Stale plan.\nVERDICT: replan")
    ])

    repl, ctx, output = build_repl(player_server, planner_server: planner_server, judge_server: judge_server,
                                    planner_enabled: false, max_iterations: 1)
    repl.run_turn("explore the temple square")

    planner_server.stop
    player_server.stop
    judge_server.stop

    assert_equal 0, planner_server.captured_bodies.size
    assert_nil ctx.plan
    assert(output.any? { |line| line.include?("skipping") })
  end

  def test_flag_verdict_prints_a_warning_and_does_not_raise
    player_server = ReplJudgeScriptedServer.new([
      ollama_tool_use_response(name: "look"),
      ollama_text_response("(wrap up) something seems wrong")
    ])
    judge_server = ReplJudgeScriptedServer.new([
      ollama_text_response("The Player is repeating the same failed action.\nVERDICT: flag")
    ])

    repl, _ctx, output = build_repl(player_server, judge_server: judge_server, max_iterations: 1)
    repl.run_turn("explore the temple square")

    player_server.stop
    judge_server.stop

    assert(output.any? { |line| line.include?("flagged") })
  end

  # docs/plans/agent_loop/evaluator.md §4's every_n_turns: fallback,
  # exercised through Repl this time — Session.checkpoint? is the same
  # predicate both callers share.
  def test_every_n_turns_fallback_checkpoints_naturally_completed_turns_too
    player_server = ReplJudgeScriptedServer.new([
      ollama_text_response("Turn 1 done."),
      ollama_text_response("Turn 2 done.")
    ])
    judge_server = ReplJudgeScriptedServer.new([
      ollama_text_response("Looks fine.\nVERDICT: continue"),
      ollama_text_response("Looks fine.\nVERDICT: continue")
    ])

    repl, = build_repl(player_server, judge_server: judge_server, judge_every_n_turns: 1)
    repl.run_turn("look around")
    repl.run_turn("keep going")

    player_server.stop
    judge_server.stop

    assert_equal 2, judge_server.captured_bodies.size, "every_n_turns: 1 checkpoints after every turn, even a natural completion"
  end

  def test_clear_resets_the_turns_since_checkpoint_counter
    player_server = ReplJudgeScriptedServer.new(Array.new(3) { ollama_text_response("done") })
    judge_server  = ReplJudgeScriptedServer.new([ollama_text_response("Looks fine.\nVERDICT: continue")])

    repl, = build_repl(player_server, judge_server: judge_server, judge_every_n_turns: 2)
    repl.run_turn("turn one")     # turns_since_checkpoint -> 1, < 2, no checkpoint
    repl.handle_command("/clear") # resets the counter back to 0
    repl.run_turn("turn two")     # turns_since_checkpoint -> 1 again (not 2), no checkpoint
    repl.run_turn("turn three")   # turns_since_checkpoint -> 2, checkpoint fires

    player_server.stop
    judge_server.stop

    assert_equal 1, judge_server.captured_bodies.size,
                 "without the /clear reset this would have fired after turn two instead of turn three"
  end
end
