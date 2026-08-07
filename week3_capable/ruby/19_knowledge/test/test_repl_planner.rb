require_relative "helper"
require "socket"
require "json"

# Serves a queue of canned Ollama-shaped JSON responses in order, capturing
# every request body — same pattern as test_session.rb's SessionScriptedServer,
# reused here since Repl's plan-seeding (docs/plans/agent_loop/
# repl_planner_integration.md) is a second, independent integration of the
# same Boukensha.run_planner call site Boukensha::Session already uses.
class ReplScriptedServer
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

# Repl's default plan-seeding — docs/plans/agent_loop/
# repl_planner_integration.md. This is the real `boukensha`/`bin/play_players`
# path (both funnel through Boukensha.repl -> Repl#run_turn), unlike
# Boukensha::Session which is a separate, still-opt-in multi-turn driver.
class TestReplPlanner < Minitest::Test
  def ollama_text_response(text)
    JSON.generate(message: { content: text })
  end

  def build_repl(player_server, planner_server, planner_enabled: true)
    ctx      = Boukensha::Context.new(system: "You are the Player.")
    registry = Boukensha::Registry.new(ctx)
    backend  = Boukensha::Backends::Ollama.new(host: player_server.host, model: "qwen3:8b")
    builder  = Boukensha::PromptBuilder.new(ctx, backend)
    client   = Boukensha::Client.new(builder)
    logger   = Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "repl-planner-test")

    repl = Boukensha::Repl.new(
      context: ctx, registry: registry, builder: builder, client: client, logger: logger,
      task_name: "player",
      planner_enabled: planner_enabled, planner_backend: :ollama, planner_model: "qwen3:8b",
      planner_ollama_host: planner_server.host
    )
    repl.on_output { |_str| } # silence REPL output during the test
    [repl, ctx]
  end

  def test_first_turn_seeds_the_plan_and_it_reaches_the_players_request
    planner_server = ReplScriptedServer.new([ollama_text_response("1. Find the temple entrance.\n2. Speak to the priest.")])
    player_server  = ReplScriptedServer.new([ollama_text_response("Done! I found the temple.")])

    repl, ctx = build_repl(player_server, planner_server)
    repl.run_turn("explore the temple square")

    planner_server.stop
    player_server.stop

    assert_equal 1, planner_server.captured_bodies.size
    assert_includes ctx.plan, "Find the temple entrance"

    sent = JSON.parse(player_server.captured_bodies.first)
    system_message = sent["messages"].find { |m| m["role"] == "system" }["content"]
    assert_includes system_message, "## Current Plan"
    assert_includes system_message, "Find the temple entrance"
  end

  def test_second_turn_does_not_reseed_the_plan
    planner_server = ReplScriptedServer.new([ollama_text_response("1. Look around.")])
    player_server  = ReplScriptedServer.new([
      ollama_text_response("Done with turn 1."),
      ollama_text_response("Done with turn 2.")
    ])

    repl, = build_repl(player_server, planner_server)
    repl.run_turn("explore the temple square")
    repl.run_turn("keep exploring")

    planner_server.stop
    player_server.stop

    assert_equal 1, planner_server.captured_bodies.size, "the Planner must only run once per session, not once per turn"
    assert_equal 2, player_server.captured_bodies.size
  end

  def test_clear_command_allows_a_fresh_plan_on_the_next_turn
    planner_server = ReplScriptedServer.new([
      ollama_text_response("1. Look around."),
      ollama_text_response("1. Start over.")
    ])
    player_server = ReplScriptedServer.new([
      ollama_text_response("Done with turn 1."),
      ollama_text_response("Done with turn 2.")
    ])

    repl, ctx = build_repl(player_server, planner_server)
    repl.run_turn("explore the temple square")
    repl.handle_command("/clear")
    repl.run_turn("a completely different quest")

    planner_server.stop
    player_server.stop

    assert_equal 2, planner_server.captured_bodies.size, "/clear resets the seeded-plan flag so the next turn plans again"
    assert_includes ctx.plan, "Start over"
  end

  def test_planner_disabled_skips_seeding_entirely
    planner_server = ReplScriptedServer.new([])
    player_server  = ReplScriptedServer.new([ollama_text_response("Done!")])

    repl, ctx = build_repl(player_server, planner_server, planner_enabled: false)
    repl.run_turn("explore the temple square")

    player_server.stop
    planner_server.stop

    assert_nil ctx.plan
    assert_equal 0, planner_server.captured_bodies.size

    sent = JSON.parse(player_server.captured_bodies.first)
    system_message = sent["messages"].find { |m| m["role"] == "system" }["content"]
    refute_includes system_message, "## Current Plan"
  end
end
