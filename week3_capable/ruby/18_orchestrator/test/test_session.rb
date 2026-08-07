require_relative "helper"
require "socket"
require "json"

# Serves a queue of canned Ollama-shaped JSON responses in order, capturing
# every request body sent to it — lets a test script a whole multi-request
# sequence (one Planner call, several Player iterations across several
# turns, one or more Judge checkpoints) against Boukensha::Session.play with
# no live provider. Backends::Ollama's `host:` constructor kwarg is the seam
# that lets each of Session's three independent calls (Planner, Player,
# Judge) be pointed at its own server.
class SessionScriptedServer
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
    nil # server socket closed after the last scripted response was served
  end
end

# Boukensha::Session.play — docs/plans/agent_loop/orchestrator.md §4 /
# phase0_decision.md / evaluator.md §4-§5. Judge (Phase 3) is real now: a
# checkpoint (an iteration/token-limit wrap-up) calls Boukensha.run_judge
# and branches on its verdict per evaluator.md §5's table, instead of the
# old warn-and-continue stand-in.
class TestSession < Minitest::Test
  # Session.play reads settings through the memoized Boukensha.config
  # singleton (matching .run/.repl's real behavior), so — unlike
  # helper.rb's config_from, which builds a Config directly — a test that
  # needs specific settings.yaml content has to point BOUKENSHA_DIR at a
  # temp dir *and* clear the memo before Session.play's first read, then
  # restore both after.
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

  def test_play_seeds_the_plan_and_completes_on_the_first_turn
    with_temp_boukensha_dir("") do
      planner_server = SessionScriptedServer.new([ollama_text_response("1. Find the temple entrance.\n2. Speak to the priest.")])
      player_server  = SessionScriptedServer.new([ollama_text_response("Done! I found the temple.")])

      result = Boukensha::Session.play(
        goal: "explore the temple square",
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        max_turns: 3
      )
      planner_server.stop
      player_server.stop

      assert_equal "Done! I found the temple.", result
      assert_equal 1, player_server.captured_bodies.size

      sent = JSON.parse(player_server.captured_bodies.first)
      system_message = sent["messages"].find { |m| m["role"] == "system" }["content"]
      assert_includes system_message, "## Current Plan"
      assert_includes system_message, "Find the temple entrance"

      user_message = sent["messages"].find { |m| m["role"] == "user" }["content"]
      assert_equal "explore the temple square", user_message
    end
  end

  # The multi-turn value Session adds over a bare Agent#run call: a
  # checkpoint (here, an iteration-limit wrap-up) does not end the session
  # by itself — the Judge is consulted, and on :continue the Player gets a
  # fresh turn, fed the literal "continue" per the Phase 0 decision, and
  # picks up where it left off.
  def test_play_continues_past_a_checkpoint_when_the_judge_says_continue
    with_temp_boukensha_dir("agent:\n  max_iterations: 1\n") do
      planner_server = SessionScriptedServer.new([ollama_text_response("1. Look around.\n2. Move north.")])
      player_server  = SessionScriptedServer.new([
        ollama_tool_use_response(name: "look"),             # turn 1, iteration 1: forces a 2nd iteration
        ollama_text_response("(wrap up) still exploring"),  # turn 1: max_iterations wrap-up call
        ollama_text_response("Done! Reached the temple.")   # turn 2, iteration 1: completes naturally
      ])
      judge_server = SessionScriptedServer.new([
        ollama_text_response("The Player is still making progress toward the plan.\nVERDICT: continue")
      ])

      result = Boukensha::Session.play(
        goal: "explore the temple square",
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        judge_backend: :ollama, judge_model: "qwen3:8b", judge_ollama_host: judge_server.host,
        max_turns: 3
      )
      planner_server.stop
      player_server.stop
      judge_server.stop

      assert_equal "Done! Reached the temple.", result
      assert_equal 3, player_server.captured_bodies.size, "turn 1 (2 calls: iteration + wrap-up) + turn 2 (1 call)"
      assert_equal 1, judge_server.captured_bodies.size, "exactly one checkpoint was reached"

      final_request  = JSON.parse(player_server.captured_bodies.last)
      user_messages  = final_request["messages"].select { |m| m["role"] == "user" }
      assert_equal "continue", user_messages.last["content"]
    end
  end

  # evaluator.md §5: a :replan verdict re-runs the Planner (with the prior
  # plan + a fresh transcript tail) instead of just continuing, and the new
  # plan text reaches the next turn's request payload.
  def test_play_replans_when_the_judge_says_replan
    with_temp_boukensha_dir("agent:\n  max_iterations: 1\n") do
      planner_server = SessionScriptedServer.new([
        ollama_text_response("1. Look around.\n2. Move north."),        # initial plan
        ollama_text_response("1. The north door is locked; go east instead.") # replan
      ])
      player_server = SessionScriptedServer.new([
        ollama_tool_use_response(name: "look"),           # turn 1, iteration 1
        ollama_text_response("(wrap up) door was locked"), # turn 1 wrap-up -> checkpoint
        ollama_text_response("Done! Found another way in.") # turn 2 -> completes naturally
      ])
      judge_server = SessionScriptedServer.new([
        ollama_text_response("The plan's assumption (north door open) no longer holds.\nVERDICT: replan")
      ])

      result = Boukensha::Session.play(
        goal: "explore the temple square",
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        judge_backend: :ollama, judge_model: "qwen3:8b", judge_ollama_host: judge_server.host,
        max_turns: 3
      )
      planner_server.stop
      player_server.stop
      judge_server.stop

      assert_equal "Done! Found another way in.", result
      assert_equal 2, planner_server.captured_bodies.size, "initial seed + one replan"

      final_request   = JSON.parse(player_server.captured_bodies.last)
      system_message  = final_request["messages"].find { |m| m["role"] == "system" }["content"]
      assert_includes system_message, "go east instead"
      refute_includes system_message, "Move north", "the stale plan should no longer be what the Player sees after a replan"
    end
  end

  # evaluator.md §5: a :flag verdict stops the driver immediately —
  # v1 has no automatic recovery, a human reviews the log. The session must
  # not reach a second turn at all.
  def test_play_stops_immediately_on_a_flag_verdict
    with_temp_boukensha_dir("agent:\n  max_iterations: 1\n") do
      planner_server = SessionScriptedServer.new([ollama_text_response("1. Look around.")])
      player_server  = SessionScriptedServer.new([
        ollama_tool_use_response(name: "look"),
        ollama_text_response("(wrap up) something seems very wrong here")
      ])
      judge_server = SessionScriptedServer.new([
        ollama_text_response("The Player is repeating the same failed action and may be in danger.\nVERDICT: flag")
      ])

      result = Boukensha::Session.play(
        goal: "explore the temple square",
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        judge_backend: :ollama, judge_model: "qwen3:8b", judge_ollama_host: judge_server.host,
        max_turns: 5
      )
      planner_server.stop
      player_server.stop
      judge_server.stop

      assert_equal "(wrap up) something seems very wrong here", result
      assert_equal 2, player_server.captured_bodies.size, "only turn 1's iteration + wrap-up — no turn 2 after a flag"
    end
  end

  # Without a Judge that keeps saying anything but :continue, max_turns: is
  # still the outer safety valve — the session must stop rather than loop
  # forever even though a real Judge now runs at every checkpoint.
  def test_play_stops_at_max_turns_when_the_judge_keeps_saying_continue
    with_temp_boukensha_dir("agent:\n  max_iterations: 1\n") do
      planner_server = SessionScriptedServer.new([ollama_text_response("1. Look around.")])
      # Every turn hits the checkpoint (tool_use, then wrap-up) — 2 requests
      # per turn, max_turns: 2 -> 4 requests, never a natural completion.
      player_server = SessionScriptedServer.new(
        Array.new(2) { [ollama_tool_use_response, ollama_text_response("(wrap up)")] }.flatten
      )
      judge_server = SessionScriptedServer.new(
        Array.new(2) { ollama_text_response("Still exploring, no concerns.\nVERDICT: continue") }
      )

      result = Boukensha::Session.play(
        goal: "explore the temple square",
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        judge_backend: :ollama, judge_model: "qwen3:8b", judge_ollama_host: judge_server.host,
        max_turns: 2
      )
      planner_server.stop
      player_server.stop
      judge_server.stop

      assert_equal "(wrap up)", result
      assert_equal 4, player_server.captured_bodies.size
      assert_equal 2, judge_server.captured_bodies.size, "one checkpoint per turn, both :continue"
    end
  end

  def test_checkpoint_predicate_fires_on_limit_triggered_stop_reasons_only
    fake_agent = Struct.new(:stop_reason).new(:max_iterations)
    assert Boukensha::Session.checkpoint?(fake_agent, 1, every_n_turns: nil)

    fake_agent = Struct.new(:stop_reason).new(:max_tokens)
    assert Boukensha::Session.checkpoint?(fake_agent, 1, every_n_turns: nil)

    fake_agent = Struct.new(:stop_reason).new(:completed)
    refute Boukensha::Session.checkpoint?(fake_agent, 1, every_n_turns: nil)
  end

  def test_checkpoint_predicate_honors_the_every_n_turns_fallback
    fake_agent = Struct.new(:stop_reason).new(:completed)
    refute Boukensha::Session.checkpoint?(fake_agent, 2, every_n_turns: 3)
    assert Boukensha::Session.checkpoint?(fake_agent, 3, every_n_turns: 3)
  end
end
