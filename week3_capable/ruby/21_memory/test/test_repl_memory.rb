require_relative "helper"
require "socket"
require "json"

# Serves a queue of canned Ollama-shaped JSON responses in order, capturing
# every request body — same pattern as test_repl_judge.rb's
# ReplJudgeScriptedServer.
class ReplMemoryScriptedServer
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

ReplFakePlayer = Struct.new(:name)

# Repl's memory retrofit — docs/plans/memory/player_memory.md's own
# "Deferred: retrofitting Repl" note, now built. Every Judge checkpoint
# (:continue included, per the "flush on every checkpoint" revision) flushes
# live via maybe_check_judge; /clear and /exit (or EOF) remain a catch-all
# for a :flag (which doesn't itself stop the REPL) or any trailing
# checkpoint, since a human-driven REPL has no other natural session end.
class TestReplMemory < Minitest::Test
  def with_temp_boukensha_dir(yaml)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "settings.yaml"), yaml)
      old_dir = ENV["BOUKENSHA_DIR"]
      old_cfg = Boukensha.instance_variable_get(:@config)
      ENV["BOUKENSHA_DIR"] = dir
      Boukensha.instance_variable_set(:@config, nil)
      yield dir
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

  def build_repl(player_server, judge_server: nil, planner_server: nil, chronicler_server: nil, player: nil, planner_enabled: false, max_iterations: nil)
    ctx      = Boukensha::Context.new(system: "You are the Player.")
    registry = Boukensha::Registry.new(ctx)
    backend  = Boukensha::Backends::Ollama.new(host: player_server.host, model: "qwen3:8b")
    builder  = Boukensha::PromptBuilder.new(ctx, backend)
    client   = Boukensha::Client.new(builder)
    logger   = Boukensha::Logger.new(dir: Dir.mktmpdir, session_id: "repl-memory-test-#{rand(1_000_000)}")

    repl = Boukensha::Repl.new(
      context: ctx, registry: registry, builder: builder, client: client, logger: logger,
      task_name: "player", max_iterations: max_iterations,
      planner_enabled: planner_enabled, planner_backend: :ollama, planner_model: "qwen3:8b",
      planner_ollama_host: planner_server&.host,
      judge_enabled: !judge_server.nil?, judge_backend: :ollama, judge_model: "qwen3:8b",
      judge_ollama_host: judge_server&.host,
      player: player,
      chronicler_backend: :ollama, chronicler_model: "qwen3:8b", chronicler_ollama_host: chronicler_server&.host
    )
    output = []
    repl.on_output { |str| output << str }
    [repl, ctx, output]
  end

  MEMORY_ENABLED_YAML = "memory:\n  enabled: true\n"

  # A turn that hits a :flag checkpoint, then /clear: the raw record and the
  # scripted digest both land, same "notable checkpoint" gate Session.play
  # uses.
  def test_clear_after_a_flagged_turn_flushes_memory
    with_temp_boukensha_dir(MEMORY_ENABLED_YAML) do |dir|
      player_server = ReplMemoryScriptedServer.new([
        ollama_tool_use_response(name: "look"),
        ollama_text_response("(wrap up) something seems very wrong here")
      ])
      judge_server = ReplMemoryScriptedServer.new([
        ollama_text_response("The Player is repeating the same failed action.\nVERDICT: flag")
      ])
      chronicler_server = ReplMemoryScriptedServer.new([ollama_text_response("Mistakes\n- Looking around repeatedly did not help.")])

      repl, = build_repl(player_server, judge_server: judge_server, chronicler_server: chronicler_server,
                          player: ReplFakePlayer.new("noir"), max_iterations: 1)
      repl.run_turn("explore the temple square")
      repl.handle_command("/clear")

      player_server.stop
      judge_server.stop
      chronicler_server.stop

      memory  = Boukensha::PlayerMemory.load("noir", memory_dir: File.join(dir, "memory"))
      records = memory.session_records
      assert_equal 1, records.size
      assert_equal "explore the temple square", records.first["goal"]
      assert_equal "cleared", records.first["stop_reason"]
      assert_equal "Mistakes\n- Looking around repeatedly did not help.", memory.digest_text
    end
  end

  # The fix for "the Judge keeps saying continue, so memory never updates":
  # a :continue verdict must flush live inside maybe_check_judge, without
  # waiting for a /clear or /exit boundary — see docs/plans/memory/
  # player_memory.md's "flush on every checkpoint" revision.
  def test_a_continue_checkpoint_flushes_memory_without_clear_or_exit
    with_temp_boukensha_dir(MEMORY_ENABLED_YAML) do |dir|
      player_server = ReplMemoryScriptedServer.new([
        ollama_tool_use_response(name: "look"),
        ollama_text_response("(wrap up) still exploring, low on gold")
      ])
      judge_server = ReplMemoryScriptedServer.new([
        ollama_text_response(
          "Player keeps browsing shops it can't afford anything in, but is still making progress overall.\nVERDICT: continue"
        )
      ])
      chronicler_server = ReplMemoryScriptedServer.new([ollama_text_response("Mistakes\n- Broke; stop browsing shops until gold is earned.")])

      repl, = build_repl(player_server, judge_server: judge_server, chronicler_server: chronicler_server,
                          player: ReplFakePlayer.new("noir"), max_iterations: 1)
      repl.run_turn("explore the temple square")

      player_server.stop
      judge_server.stop
      chronicler_server.stop

      memory  = Boukensha::PlayerMemory.load("noir", memory_dir: File.join(dir, "memory"))
      records = memory.session_records
      assert_equal 1, records.size, "the :continue checkpoint's live flush — no /clear or /exit needed"
      assert_equal "continue", records.first["stop_reason"]
      assert_equal 1, records.first["checkpoints"].size
      assert_equal "continue", records.first["checkpoints"].first["verdict"]
      assert_equal "Mistakes\n- Broke; stop browsing shops until gold is earned.", memory.digest_text
    end
  end

  # /clear with no checkpoint at all (Judge disabled here) writes nothing —
  # there is nothing pending to flush.
  def test_clear_with_no_notable_checkpoint_writes_nothing
    with_temp_boukensha_dir(MEMORY_ENABLED_YAML) do |dir|
      player_server = ReplMemoryScriptedServer.new([ollama_text_response("Done!")])

      repl, = build_repl(player_server, player: ReplFakePlayer.new("noir"))
      repl.run_turn("explore the temple square")
      repl.handle_command("/clear")

      player_server.stop

      memory = Boukensha::PlayerMemory.load("noir", memory_dir: File.join(dir, "memory"))
      assert_equal [], memory.session_records
      assert_nil memory.digest_text
    end
  end

  # /exit is a session boundary too, same as /clear.
  def test_exit_after_a_flagged_turn_flushes_memory
    with_temp_boukensha_dir(MEMORY_ENABLED_YAML) do |dir|
      player_server = ReplMemoryScriptedServer.new([
        ollama_tool_use_response(name: "look"),
        ollama_text_response("(wrap up) something seems very wrong here")
      ])
      judge_server = ReplMemoryScriptedServer.new([
        ollama_text_response("The Player is repeating the same failed action.\nVERDICT: flag")
      ])
      chronicler_server = ReplMemoryScriptedServer.new([ollama_text_response("Mistakes\n- Do not repeat look.")])

      repl, = build_repl(player_server, judge_server: judge_server, chronicler_server: chronicler_server,
                          player: ReplFakePlayer.new("noir"), max_iterations: 1)
      repl.run_turn("explore the temple square")
      repl.handle_command("/exit")

      player_server.stop
      judge_server.stop
      chronicler_server.stop

      memory = Boukensha::PlayerMemory.load("noir", memory_dir: File.join(dir, "memory"))
      assert_equal 1, memory.session_records.size
      assert_equal "exit", memory.session_records.first["stop_reason"]
      assert_equal "Mistakes\n- Do not repeat look.", memory.digest_text
    end
  end

  # Checkpoint-triggered memory (docs/plans/memory/player_memory.md's
  # revision): a :replan verdict must chronicle and save the digest BEFORE
  # that replan's own run_planner call — the replanned plan's request
  # payload should already carry the freshly chronicled digest, not saved up
  # for a later /clear or /exit.
  def test_a_replan_flushes_memory_before_the_replanned_planner_call
    with_temp_boukensha_dir(MEMORY_ENABLED_YAML) do |dir|
      planner_server = ReplMemoryScriptedServer.new([
        ollama_text_response("1. Look around."),
        ollama_text_response("1. Try something else.")
      ])
      player_server = ReplMemoryScriptedServer.new([
        ollama_tool_use_response(name: "look"),
        ollama_text_response("(wrap up) trying a different approach")
      ])
      judge_server = ReplMemoryScriptedServer.new([
        ollama_text_response("The plan isn't working, try a different approach.\nVERDICT: replan")
      ])
      chronicler_server = ReplMemoryScriptedServer.new([ollama_text_response("Discoveries\n- Something learned mid-session.")])

      repl, = build_repl(player_server, judge_server: judge_server, planner_server: planner_server, chronicler_server: chronicler_server,
                          player: ReplFakePlayer.new("noir"), planner_enabled: true, max_iterations: 1)
      repl.run_turn("explore the temple square")

      planner_server.stop
      player_server.stop
      judge_server.stop
      chronicler_server.stop

      memory  = Boukensha::PlayerMemory.load("noir", memory_dir: File.join(dir, "memory"))
      records = memory.session_records
      assert_equal 1, records.size, "the replan's live flush is the only write — nothing left for /exit or /clear later"
      assert_equal "replan", records.first["stop_reason"]
      assert_equal "Discoveries\n- Something learned mid-session.", memory.digest_text

      assert_equal 2, planner_server.captured_bodies.size
      replan_request = JSON.parse(planner_server.captured_bodies[1])
      replan_user_text = replan_request["messages"].find { |m| m["role"] == "user" }["content"]
      assert_includes replan_user_text, "What you've learned about this character from past sessions"
      assert_includes replan_user_text, "Something learned mid-session"
    end
  end

  # A digest already on disk before this Repl was constructed: the Planner's
  # first-turn request payload must include the "What you've learned" block.
  def test_a_prior_digest_reaches_the_planners_request_payload
    with_temp_boukensha_dir(MEMORY_ENABLED_YAML) do |dir|
      memory = Boukensha::PlayerMemory.load("noir", memory_dir: File.join(dir, "memory"))
      memory.save_digest("Discoveries\n- The blacksmith haggles if you mention the guild.")

      planner_server = ReplMemoryScriptedServer.new([ollama_text_response("1. Visit the blacksmith.")])
      player_server  = ReplMemoryScriptedServer.new([ollama_text_response("Done! Visited the blacksmith.")])

      repl, = build_repl(player_server, planner_server: planner_server, planner_enabled: true, player: ReplFakePlayer.new("noir"))
      repl.run_turn("buy a sword")

      planner_server.stop
      player_server.stop

      sent = JSON.parse(planner_server.captured_bodies.first)
      user_text = sent["messages"].find { |m| m["role"] == "user" }["content"]
      assert_includes user_text, "What you've learned about this character from past sessions"
      assert_includes user_text, "haggles if you mention the guild"
    end
  end

  # Regression: memory.enabled: false (the default) or no player: given
  # never constructs memory, even across /clear and /exit.
  def test_memory_disabled_by_default_writes_nothing
    with_temp_boukensha_dir("") do |dir|
      player_server = ReplMemoryScriptedServer.new([
        ollama_tool_use_response(name: "look"),
        ollama_text_response("(wrap up) something seems very wrong here")
      ])
      judge_server = ReplMemoryScriptedServer.new([
        ollama_text_response("The Player is repeating the same failed action.\nVERDICT: flag")
      ])

      repl, = build_repl(player_server, judge_server: judge_server, player: ReplFakePlayer.new("noir"), max_iterations: 1)
      repl.run_turn("explore the temple square")
      repl.handle_command("/exit")

      player_server.stop
      judge_server.stop

      refute Dir.exist?(File.join(dir, "memory"))
    end
  end

  def test_no_player_never_constructs_memory_even_with_memory_enabled
    with_temp_boukensha_dir(MEMORY_ENABLED_YAML) do |dir|
      player_server = ReplMemoryScriptedServer.new([
        ollama_tool_use_response(name: "look"),
        ollama_text_response("(wrap up) something seems very wrong here")
      ])
      judge_server = ReplMemoryScriptedServer.new([
        ollama_text_response("The Player is repeating the same failed action.\nVERDICT: flag")
      ])

      repl, = build_repl(player_server, judge_server: judge_server, player: nil, max_iterations: 1)
      repl.run_turn("explore the temple square")
      repl.handle_command("/exit")

      player_server.stop
      judge_server.stop

      refute Dir.exist?(File.join(dir, "memory"))
    end
  end
end
