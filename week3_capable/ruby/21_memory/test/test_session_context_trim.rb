require_relative "helper"
require "socket"
require "json"

# Serves a queue of canned Ollama-shaped JSON responses in order, capturing
# every request body — same pattern as test_session.rb's SessionScriptedServer.
class SessionContextTrimScriptedServer
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

# Boukensha::Session.play's checkpoint-triggered trim — docs/plans/memory/
# context_lifecycle.md §3b. Session.play never exposes its internal Context,
# so this drives the property through what's externally observable: each
# turn's own request payload, which already reflects whatever trimming
# happened at the *previous* checkpoint.
class TestSessionContextTrim < Minitest::Test
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

  SETTINGS_YAML = <<~YAML
    agent:
      max_iterations: 1
    tasks:
      player:
        tools:
          allow: [look]
  YAML

  # Six checkpoints (agent:max_iterations: 1 forces every turn to end with a
  # limit-triggered wrap-up, which Session.checkpoint? always treats as a
  # checkpoint): five :continue verdicts, then a :replan on the sixth. Each
  # turn's single tool call (a "look" tool registered via the block DSL,
  # explicitly allowed so it actually dispatches) returns a distinct marker
  # as its *tool_result* content, so a turn's presence in a later request —
  # the "raw tool_result content" docs/plans/memory/context_lifecycle.md's
  # acceptance criteria asks about — is verifiable by substring search,
  # independent of Context internals.
  def test_a_replan_checkpoint_trims_earlier_turns_from_the_next_request_payload
    with_temp_boukensha_dir(SETTINGS_YAML) do
      n_turns = 6
      planner_bodies = [ollama_text_response("1. Explore.")]
      player_bodies  = []
      judge_bodies   = []
      n_turns.times do |i|
        player_bodies << ollama_tool_use_response(name: "look", args: { marker: "turn#{i + 1}-clue" })
        player_bodies << ollama_text_response("(wrap up) turn#{i + 1}")
        judge_bodies << ollama_text_response("checking turn #{i + 1}.\nVERDICT: #{i == n_turns - 1 ? "replan" : "continue"}")
      end
      planner_bodies << ollama_text_response("1. Replanned.")
      player_bodies  << ollama_text_response("Done! Completed after replan.")

      planner_server = SessionContextTrimScriptedServer.new(planner_bodies)
      player_server  = SessionContextTrimScriptedServer.new(player_bodies)
      judge_server   = SessionContextTrimScriptedServer.new(judge_bodies)

      result = Boukensha::Session.play(
        goal: "explore the temple square",
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        judge_backend: :ollama, judge_model: "qwen3:8b", judge_ollama_host: judge_server.host,
        max_turns: n_turns + 2
      ) do
        tool("look", description: "look", parameters: { marker: { type: "string" } }) { |marker:| marker }
      end
      planner_server.stop
      player_server.stop
      judge_server.stop

      assert_equal "Done! Completed after replan.", result
      assert_equal 13, player_server.captured_bodies.size, "6 turns x (1 tool-call iteration + 1 forced wrap-up) + 1 final completing turn"

      # The request immediately preceding the replan (turn 6's own forced
      # wrap-up call) — nothing has been trimmed yet, so every turn's marker
      # is still present, and the payload has grown monotonically turn over
      # turn (no earlier checkpoint ever dropped anything on :continue).
      sizes = player_server.captured_bodies[0..10].map { |b| JSON.parse(b)["messages"].size }
      assert_equal sizes.sort, sizes, "a :continue verdict must never shrink the next request payload"

      pre_trim_request = JSON.parse(player_server.captured_bodies[11])
      assert_equal 30, pre_trim_request["messages"].size
      (1..n_turns).each { |i| assert_includes player_server.captured_bodies[11], "turn#{i}-clue" }

      # The very next request — sent after the replan's checkpoint_trim! —
      # is smaller despite the session having done more work since, and no
      # longer carries turn 1/2's tool-call content at all.
      post_trim_request = JSON.parse(player_server.captured_bodies[12])
      assert_equal 22, post_trim_request["messages"].size
      assert_operator post_trim_request["messages"].size, :<, pre_trim_request["messages"].size

      refute_includes player_server.captured_bodies[12], "turn1-clue"
      refute_includes player_server.captured_bodies[12], "turn2-clue"
      (3..n_turns).each { |i| assert_includes player_server.captured_bodies[12], "turn#{i}-clue" }
    end
  end

  # docs/plans/memory/context_lifecycle.md's own acceptance criteria: a
  # session that never reaches a checkpoint at all (completes naturally on
  # its first turn, same fixture shape as test_session.rb's own
  # test_play_seeds_the_plan_and_completes_on_the_first_turn) never calls
  # Boukensha.run_judge and so never calls checkpoint_trim! either — message
  # growth and the final payload are byte-for-byte what they were before
  # this doc's change.
  def test_a_session_that_never_checkpoints_is_unaffected
    with_temp_boukensha_dir("") do
      planner_server = SessionContextTrimScriptedServer.new([ollama_text_response("1. Find the temple entrance.")])
      player_server  = SessionContextTrimScriptedServer.new([ollama_text_response("Done! I found the temple.")])

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
      assert_equal 2, JSON.parse(player_server.captured_bodies.last)["messages"].size
    end
  end
end
