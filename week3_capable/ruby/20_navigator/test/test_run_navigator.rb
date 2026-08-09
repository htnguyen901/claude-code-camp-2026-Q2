require_relative "helper"
require "socket"
require "json"

# Serves a queue of canned Ollama-shaped JSON responses in order, capturing
# every request body sent to it — mirrors test_run_judge.rb's
# JudgeScriptedServer: the Navigator's own Agent#run loop can take a couple
# of round trips (world__route_to, optionally world__room_knowledge, then a
# final text description).
class NavigatorScriptedServer
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
# by registering canned fake tools directly, the same surface run_judge/
# run_navigator actually call.
class NavigatorFakeMcpConnections
  def initialize(&block) = @block = block
  def register(registry) = @block&.call(registry)
end

# Boukensha.run_navigator — docs/plans/agent_loop/navigator.md §4, reworked
# by agents_tools/tool_scope_rework.md §0/§3/§4 into a pure route *finder*:
# a small Agent#run loop against its own throwaway Context/Registry,
# registered from the session's shared MCP connections and filtered through
# the Navigator's own role: navigator policy (world__room_knowledge/
# route_to only — no tbamud__move). Unlike run_judge, there's no
# VERDICT-style parsing — the plain text response is the whole return
# value, and it describes a path rather than confirming arrival.
class TestRunNavigator < Minitest::Test
  NAVIGATOR_SETTINGS_YAML = <<~YAML
    tool_roles:
      navigator: [world__room_knowledge, world__route_to]
    tasks:
      navigator:
        tools:
          role: navigator
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
    Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "navigator-test-#{rand(1_000_000)}")
  end

  def fake_mcp
    NavigatorFakeMcpConnections.new { |registry| yield registry if block_given? }
  end

  def run_navigator(server, mcp:, **overrides)
    Boukensha.run_navigator(
      from: overrides.delete(:from) || "The Temple Square",
      to:   overrides.delete(:to)   || "The Beginning Of The Passage",
      mcp: mcp,
      logger: overrides.delete(:logger) || test_logger,
      backend: :ollama, model: "qwen3:8b", ollama_host: server.host,
      **overrides
    )
  end

  # A scripted 2-hop route: world__route_to returns a hop sequence and the
  # Navigator describes it back as a short path description — it never
  # calls tbamud__move (the tool isn't even registered here — there's
  # nothing for it to call).
  def test_a_known_route_is_described_without_moving
    with_temp_boukensha_dir(NAVIGATOR_SETTINGS_YAML) do
      mcp = fake_mcp do |registry|
        registry.tool("world__route_to", description: "route", parameters: { from: { type: "string" }, to: { type: "string" } }) do |from:, to:|
          JSON.generate(hops: ["north", "east"])
        end
      end

      server = NavigatorScriptedServer.new([
        ollama_tool_use_response(name: "world__route_to", args: { from: "The Temple Square", to: "The Beginning Of The Passage" }),
        ollama_text_response("North, then east — 2 hops to The Beginning Of The Passage.")
      ])

      result = run_navigator(server, mcp: mcp)
      server.stop

      assert_equal "North, then east — 2 hops to The Beginning Of The Passage.", result
      assert_equal 2, server.captured_bodies.size, "world__route_to, then the final description — no move round trips"
    end
  end

  # world__route_to reports no known route: the Navigator's returned text
  # must say so plainly rather than inventing a path.
  def test_no_known_route_is_reported_plainly
    with_temp_boukensha_dir(NAVIGATOR_SETTINGS_YAML) do
      mcp = fake_mcp do |registry|
        registry.tool("world__route_to", description: "route", parameters: { from: { type: "string" }, to: { type: "string" } }) do |from:, to:|
          JSON.generate(hops: nil)
        end
      end

      server = NavigatorScriptedServer.new([
        ollama_tool_use_response(name: "world__route_to", args: { from: "The Temple Square", to: "Nowhere" }),
        ollama_text_response("No known route to Nowhere — I can't get there from what's been discovered so far.")
      ])

      result = run_navigator(server, mcp: mcp, to: "Nowhere")
      server.stop

      assert_includes result, "No known route"
    end
  end

  # world__route_to's hop sequence sometimes leaves an exit's direction
  # ambiguous; the Navigator may fall back to world__room_knowledge to
  # resolve it before describing the path — still zero tbamud__move calls.
  def test_room_knowledge_may_be_consulted_to_resolve_a_direction
    with_temp_boukensha_dir(NAVIGATOR_SETTINGS_YAML) do
      mcp = fake_mcp do |registry|
        registry.tool("world__route_to", description: "route", parameters: { from: { type: "string" }, to: { type: "string" } }) do |from:, to:|
          JSON.generate(hops: ["unknown"])
        end
        registry.tool("world__room_knowledge", description: "room facts", parameters: { room_title: { type: "string" } }) do |room_title:|
          JSON.generate(exits: { north: "The Beginning Of The Passage" })
        end
      end

      server = NavigatorScriptedServer.new([
        ollama_tool_use_response(name: "world__route_to", args: { from: "The Temple Square", to: "The Beginning Of The Passage" }),
        ollama_tool_use_response(name: "world__room_knowledge", args: { room_title: "The Temple Square" }),
        ollama_text_response("North — 1 hop to The Beginning Of The Passage.")
      ])

      result = run_navigator(server, mcp: mcp)
      server.stop

      assert_equal "North — 1 hop to The Beginning Of The Passage.", result
      assert_equal 3, server.captured_bodies.size
    end
  end

  # The Navigator's own ToolPolicy (role: navigator) must win even when the
  # shared MCP connections would offer a broader catalog — tbamud__move is
  # deliberately excluded (tool_scope_rework.md §0/§3: the Navigator answers
  # whether a path exists, it doesn't walk it), so a scripted attempt to
  # call it comes back denied rather than actually running the block.
  def test_tbamud_move_is_never_dispatchable
    with_temp_boukensha_dir(NAVIGATOR_SETTINGS_YAML) do
      moved = false
      mcp = fake_mcp do |registry|
        registry.tool("tbamud__move", description: "move", parameters: { direction: { type: "string" } }) do |direction:|
          moved = true
          "You walk #{direction}."
        end
      end

      server = NavigatorScriptedServer.new([
        ollama_tool_use_response(name: "tbamud__move", args: { direction: "north" }),
        ollama_text_response("Could not move — that tool was denied.")
      ])

      run_navigator(server, mcp: mcp)
      server.stop

      refute moved, "the Navigator's role: navigator policy must deny tbamud__move — it answers whether a path exists, it doesn't walk it"
    end
  end

  # tbamud__look stays excluded too, same as before this rework — the
  # Navigator is told its position by its caller rather than re-observing
  # it itself (navigator.md §3).
  def test_a_tool_outside_the_configured_role_is_never_dispatchable
    with_temp_boukensha_dir(NAVIGATOR_SETTINGS_YAML) do
      looked = false
      mcp = fake_mcp do |registry|
        registry.tool("tbamud__look", description: "look", parameters: {}) do
          looked = true
          "a quiet room"
        end
      end

      server = NavigatorScriptedServer.new([
        ollama_tool_use_response(name: "tbamud__look"),
        ollama_text_response("Could not check — that tool was denied.")
      ])

      run_navigator(server, mcp: mcp)
      server.stop

      refute looked, "the Navigator's role: navigator policy must deny tbamud__look even though the shared connections offer it"
    end
  end
end
