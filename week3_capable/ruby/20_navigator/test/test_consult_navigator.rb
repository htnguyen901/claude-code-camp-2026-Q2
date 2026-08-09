require_relative "helper"
require "socket"
require "json"

# Boukensha.register_navigator_tool / consult_navigator — docs/plans/
# agent_loop/navigator.md §5 and agents_tools/tool_scope_rework.md §5. Two
# things under test:
#   1. Gating: `consult_navigator` only appears on a registry whose policy
#      grants it (same fail-safe-by-default posture as every other tool).
#   2. Isolation: dispatched through a real Player turn, the Navigator's own
#      internal tool calls never leak into the Player's Context — only the
#      one consult_navigator tool_call/tool_result pair does. See
#      TestConsultNavigatorIsolationJudgeAndPlanner below for the same
#      isolation property exercised through run_judge/run_planner instead.
class TestConsultNavigator < Minitest::Test
  def test_logger
    Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "consult-navigator-test-#{rand(1_000_000)}")
  end

  def noop_mcp
    Class.new { def register(_registry) = nil }.new
  end

  def test_without_an_allow_entry_consult_navigator_is_not_registered
    policy   = Boukensha::Tasks::Player.tool_policy({ "tools" => { "role" => "gameplay" } }, tool_roles: { "gameplay" => ["tbamud__look"] })
    ctx      = Boukensha::Context.new(system: "test")
    registry = Boukensha::Registry.new(ctx, policy: policy)

    Boukensha.register_navigator_tool(registry, noop_mcp, logger: test_logger)

    refute_includes registry.tool_names, "consult_navigator"
  end

  def test_with_an_allow_entry_consult_navigator_is_registered
    policy   = Boukensha::Tasks::Player.tool_policy({ "tools" => { "allow" => ["consult_navigator"] } }, tool_roles: {})
    ctx      = Boukensha::Context.new(system: "test")
    registry = Boukensha::Registry.new(ctx, policy: policy)

    Boukensha.register_navigator_tool(registry, noop_mcp, logger: test_logger)

    assert_includes registry.tool_names, "consult_navigator"
  end
end

# Serves a queue of canned Ollama-shaped JSON responses in order — same
# shape as test_run_navigator.rb's NavigatorScriptedServer, defined again
# here (rather than shared) per this test suite's existing convention of
# each file owning its own scripted-server fixture (see JudgeScriptedServer/
# SessionScriptedServer).
class ConsultNavigatorScriptedServer
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

# Full-path isolation test: a real Boukensha.run Player turn that calls
# consult_navigator, with the Navigator's own model call pointed at a
# separate scripted server (navigator_ollama_host:) — the same seam
# test_session.rb uses to give Planner/Player/Judge independent canned
# backends. Asserts the Player's own request payload (the ground truth for
# what's actually in its Context#messages) carries exactly one tool_call/
# tool_result pair for consult_navigator and nothing from the Navigator's
# internal turn.
class TestConsultNavigatorIsolation < Minitest::Test
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
    tasks:
      planner:
        enabled: false
      player:
        tools:
          allow: [consult_navigator]
  YAML

  def test_a_player_turn_that_consults_the_navigator_leaks_no_internal_messages
    with_temp_boukensha_dir(SETTINGS_YAML) do
      navigator_server = ConsultNavigatorScriptedServer.new([
        ollama_text_response("North, then east — 2 hops to The Beginning Of The Passage.")
      ])
      player_server = ConsultNavigatorScriptedServer.new([
        ollama_tool_use_response(name: "consult_navigator", args: { from: "The Temple Square", to: "The Beginning Of The Passage" }),
        ollama_text_response("Done — I walked there using the Navigator's directions.")
      ])

      result = Boukensha.run(
        task: "reach The Beginning Of The Passage",
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        navigator_backend: :ollama, navigator_model: "qwen3:8b", navigator_ollama_host: navigator_server.host
      )
      navigator_server.stop
      player_server.stop

      assert_equal "Done — I walked there using the Navigator's directions.", result
      assert_equal 1, navigator_server.captured_bodies.size, "the Navigator's own turn made exactly one model call"
      assert_equal 2, player_server.captured_bodies.size, "the tool_use round trip + the final completion"

      final_request = JSON.parse(player_server.captured_bodies.last)
      tool_messages = final_request["messages"].select { |m| m["role"] == "tool" }
      assistant_tool_calls = final_request["messages"].select { |m| m["role"] == "assistant" && m["tool_calls"] }

      assert_equal 1, tool_messages.size, "exactly one tool_result reached the Player's Context"
      assert_equal "consult_navigator", tool_messages.first["tool_name"]
      assert_equal "North, then east — 2 hops to The Beginning Of The Passage.", tool_messages.first["content"]

      assert_equal 1, assistant_tool_calls.size, "exactly one tool_call reached the Player's Context"
      assert_equal "consult_navigator", assistant_tool_calls.first["tool_calls"].first["function"]["name"]
    end
  end
end

# Same isolation property as TestConsultNavigatorIsolation above, exercised
# through run_judge/run_planner instead of a real Player turn — see
# agents_tools/tool_scope_rework.md §2/§5: consult_navigator is safe to hand
# to Judge/Planner too because Tasks::Navigator never mutates world state.
#
# Unlike the Player version, this stubs Boukensha.run_navigator rather than
# round-tripping through a second scripted server: run_judge/run_planner
# deliberately don't expose a navigator_ollama_host-style override
# (tool_scope_rework.md §5 — "no new kwargs... not speculatively now"), so
# there's no seam to point the Navigator's own model call at a fake host
# without binding to Ollama's real default port. Stubbing the one method
# boundary between "register_navigator_tool's block ran for real" (what
# this test cares about) and "the Navigator's own Agent#run loop hit a
# network backend" (already covered by test_run_navigator.rb) keeps this
# deterministic.
class TestConsultNavigatorIsolationForJudgeAndPlanner < Minitest::Test
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

  def stub_run_navigator(text)
    original = Boukensha.method(:run_navigator)
    Boukensha.define_singleton_method(:run_navigator) { |**_| text }
    yield
  ensure
    Boukensha.define_singleton_method(:run_navigator, original)
  end

  def ollama_text_response(text)
    JSON.generate(message: { content: text })
  end

  def ollama_tool_use_response(name:, args: {})
    JSON.generate(message: { content: "", tool_calls: [{ function: { name: name, arguments: args } }] })
  end

  def test_logger
    Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "consult-navigator-judge-planner-test-#{rand(1_000_000)}")
  end

  JUDGE_SETTINGS_YAML = <<~YAML
    tasks:
      judge:
        tools:
          allow: [consult_navigator]
  YAML

  PLANNER_SETTINGS_YAML = <<~YAML
    tasks:
      planner:
        tools:
          allow: [consult_navigator]
  YAML

  def test_a_judge_turn_that_consults_the_navigator_leaks_no_internal_messages
    with_temp_boukensha_dir(JUDGE_SETTINGS_YAML) do
      stub_run_navigator("North, then east — 2 hops to The Beginning Of The Passage.") do
        server = ConsultNavigatorScriptedServer.new([
          ollama_tool_use_response(name: "consult_navigator", args: { from: "The Temple Square", to: "The Beginning Of The Passage" }),
          ollama_text_response("The plan's next step is reachable via a known route.\nVERDICT: continue")
        ])

        result = Boukensha.run_judge(
          plan: "1. Reach The Beginning Of The Passage.",
          transcript_tail: "You are standing in The Temple Square.",
          mcp: nil, logger: test_logger,
          backend: :ollama, model: "qwen3:8b", ollama_host: server.host
        )
        server.stop

        assert_equal :continue, result[:verdict]
        assert_equal 2, server.captured_bodies.size, "the tool_use round trip + the final verdict"

        final_request = JSON.parse(server.captured_bodies.last)
        tool_messages = final_request["messages"].select { |m| m["role"] == "tool" }
        assistant_tool_calls = final_request["messages"].select { |m| m["role"] == "assistant" && m["tool_calls"] }

        assert_equal 1, tool_messages.size, "exactly one tool_result reached the Judge's own Context"
        assert_equal "consult_navigator", tool_messages.first["tool_name"]
        assert_equal "North, then east — 2 hops to The Beginning Of The Passage.", tool_messages.first["content"]

        assert_equal 1, assistant_tool_calls.size, "exactly one tool_call reached the Judge's own Context"
        assert_equal "consult_navigator", assistant_tool_calls.first["tool_calls"].first["function"]["name"]
      end
    end
  end

  def test_a_planner_turn_that_consults_the_navigator_leaks_no_internal_messages
    with_temp_boukensha_dir(PLANNER_SETTINGS_YAML) do
      stub_run_navigator("North, then east — 2 hops to The Beginning Of The Passage.") do
        server = ConsultNavigatorScriptedServer.new([
          ollama_tool_use_response(name: "consult_navigator", args: { from: "The Temple Square", to: "The Beginning Of The Passage" }),
          ollama_text_response("1. Walk north, then east, to The Beginning Of The Passage.")
        ])

        text = Boukensha.run_planner(
          goal: "reach The Beginning Of The Passage",
          mcp: nil, logger: test_logger,
          backend: :ollama, model: "qwen3:8b", ollama_host: server.host
        )
        server.stop

        assert_equal "1. Walk north, then east, to The Beginning Of The Passage.", text
        assert_equal 2, server.captured_bodies.size, "the tool_use round trip + the final plan"

        final_request = JSON.parse(server.captured_bodies.last)
        tool_messages = final_request["messages"].select { |m| m["role"] == "tool" }
        assistant_tool_calls = final_request["messages"].select { |m| m["role"] == "assistant" && m["tool_calls"] }

        assert_equal 1, tool_messages.size, "exactly one tool_result reached the Planner's own Context"
        assert_equal "consult_navigator", tool_messages.first["tool_name"]
        assert_equal "North, then east — 2 hops to The Beginning Of The Passage.", tool_messages.first["content"]

        assert_equal 1, assistant_tool_calls.size, "exactly one tool_call reached the Planner's own Context"
        assert_equal "consult_navigator", assistant_tool_calls.first["tool_calls"].first["function"]["name"]
      end
    end
  end
end
