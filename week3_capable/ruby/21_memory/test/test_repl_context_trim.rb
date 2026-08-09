require_relative "helper"
require "socket"
require "json"

# Serves a queue of canned Ollama-shaped JSON responses in order — same
# pattern as test_repl_judge.rb/test_repl_memory.rb's own scripted servers.
class ReplContextTrimScriptedServer
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

# Repl's mirror of Boukensha::Session's checkpoint-triggered trim —
# docs/plans/memory/context_lifecycle.md §3b, wired into
# Repl#maybe_check_judge's :replan branch only (not :flag — see that
# branch's own comment in repl.rb for why). Unlike Session.play, Repl
# exposes its Context directly (attr_reader :context), so this checks
# ctx.messages itself rather than reconstructing state from request bodies.
class TestReplContextTrim < Minitest::Test
  def ollama_text_response(text)
    JSON.generate(message: { content: text })
  end

  def ollama_tool_use_response(name:, args: {})
    JSON.generate(message: { content: "", tool_calls: [{ function: { name: name, arguments: args } }] })
  end

  def build_repl(player_server, judge_server:, max_iterations: 1)
    ctx      = Boukensha::Context.new(system: "You are the Player.")
    registry = Boukensha::Registry.new(ctx)
    registry.tool("look", description: "look", parameters: { marker: { type: "string" } }) { |marker:| marker }

    backend = Boukensha::Backends::Ollama.new(host: player_server.host, model: "qwen3:8b")
    builder = Boukensha::PromptBuilder.new(ctx, backend)
    client  = Boukensha::Client.new(builder)
    logger  = Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "repl-context-trim-test-#{rand(1_000_000)}")

    repl = Boukensha::Repl.new(
      context: ctx, registry: registry, builder: builder, client: client, logger: logger,
      task_name: "player", max_iterations: max_iterations,
      planner_enabled: false,
      judge_enabled: true, judge_backend: :ollama, judge_model: "qwen3:8b", judge_ollama_host: judge_server.host
    )
    repl.on_output { |_str| nil }
    [repl, ctx]
  end

  def marker_tool_calls(ctx)
    ctx.messages.flat_map do |m|
      next [] unless m.content.is_a?(Array)

      m.content.select { |b| b["type"] == "tool_use" }.map { |b| b["input"]["marker"] }
    end.compact
  end

  # Six turns (agent:max_iterations: 1 forces every turn's own wrap-up, so
  # every turn hits a checkpoint): five :continue verdicts growing
  # ctx.messages every time with no drop, then a :replan on the sixth that
  # trims it back down — old turns' tool-call markers gone, recent ones kept.
  def test_a_replan_checkpoint_trims_earlier_turns_out_of_the_context
    n_turns = 6
    player_bodies = []
    judge_bodies  = []
    n_turns.times do |i|
      player_bodies << ollama_tool_use_response(name: "look", args: { marker: "turn#{i + 1}-clue" })
      player_bodies << ollama_text_response("(wrap up) turn#{i + 1}")
      judge_bodies << ollama_text_response("checking turn #{i + 1}.\nVERDICT: #{i == n_turns - 1 ? "replan" : "continue"}")
    end

    player_server = ReplContextTrimScriptedServer.new(player_bodies)
    judge_server  = ReplContextTrimScriptedServer.new(judge_bodies)
    repl, ctx = build_repl(player_server, judge_server: judge_server)

    sizes = []
    n_turns.times { |i| repl.run_turn(i.zero? ? "explore the temple square" : "continue"); sizes << ctx.messages.size }

    player_server.stop
    judge_server.stop

    assert_equal [5, 10, 15, 20, 25, 20], sizes,
                 "turns 1-5 (:continue) each grow ctx.messages by 5 with no drop; turn 6's :replan trims it back down"

    markers = marker_tool_calls(ctx)
    refute_includes markers, "turn1-clue"
    refute_includes markers, "turn2-clue"
    (3..n_turns).each { |i| assert_includes markers, "turn#{i}-clue" }
  end

  # The :continue-only path is a direct no-op regression: with a Judge that
  # only ever says :continue, ctx.messages must never shrink.
  def test_a_continue_verdict_never_trims_the_context
    player_bodies = 3.times.flat_map do |i|
      [ollama_tool_use_response(name: "look", args: { marker: "turn#{i + 1}-clue" }), ollama_text_response("(wrap up) turn#{i + 1}")]
    end
    judge_bodies = 3.times.map { |i| ollama_text_response("checking turn #{i + 1}.\nVERDICT: continue") }

    player_server = ReplContextTrimScriptedServer.new(player_bodies)
    judge_server  = ReplContextTrimScriptedServer.new(judge_bodies)
    repl, ctx = build_repl(player_server, judge_server: judge_server)

    sizes = []
    3.times { |i| repl.run_turn(i.zero? ? "explore the temple square" : "continue"); sizes << ctx.messages.size }

    player_server.stop
    judge_server.stop

    assert_equal [5, 10, 15], sizes
    markers = marker_tool_calls(ctx)
    (1..3).each { |i| assert_includes markers, "turn#{i}-clue" }
  end
end
