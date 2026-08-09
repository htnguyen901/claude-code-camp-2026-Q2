require_relative "helper"
require "socket"
require "json"

# Serves a queue of canned Ollama-shaped JSON responses in order, capturing
# every request body sent — same pattern as test_session.rb's
# SessionScriptedServer, duplicated here (rather than shared) the same way
# every other run_*/task test file in this suite keeps its own copy.
class SessionMemoryScriptedServer
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

FakePlayer = Struct.new(:name)

# Answers every request with a non-retryable HTTP error (400) so
# Boukensha::Client raises Boukensha::ApiError immediately, with none of
# Client's built-in retry/backoff delay a connection-refused error would
# trigger — exercises Session.play's fail-open `rescue StandardError` around
# the Chronicler call without slowing the test suite down.
class ChroniclerErrorServer
  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { accept_loop }
    @thread.report_on_exception = false
  end

  def host = "http://127.0.0.1:#{@server.addr[1]}"

  def stop
    @thread.join(1)
    @server.close
  rescue StandardError
    nil
  end

  private

  def accept_loop
    conn = @server.accept
    conn.gets
    while (line = conn.gets) && line != "\r\n"; end
    body = "bad request"
    conn.write("HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
  ensure
    conn&.close
  end
end

# Boukensha::Session.play's memory integration — docs/plans/memory/
# player_memory.md §5. memory.enabled:/player: gate everything. Every
# session now writes at least one memory record when memory is on: either
# a live checkpoint (:replan/:flag/:continue, per the "flush on every
# checkpoint" revision) or, if none of those ever fired, the forced
# checkpoint a natural :completed now also triggers (the "checkpoint the
# ending turn too" revision) — see
# test_a_session_that_completes_on_the_first_turn_still_flushes_memory.
class TestSessionMemory < Minitest::Test
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

  MEMORY_ENABLED_YAML = <<~YAML
    agent:
      max_iterations: 1
    memory:
      enabled: true
  YAML

  # A session that hits a :flag checkpoint: exactly one new raw record is
  # appended (goal/outcome/checkpoint history) and the digest file is
  # overwritten with the Chronicler's scripted response.
  def test_a_flagged_session_writes_a_raw_record_and_the_scripted_digest
    with_temp_boukensha_dir(MEMORY_ENABLED_YAML) do |dir|
      planner_server    = SessionMemoryScriptedServer.new([ollama_text_response("1. Look around.")])
      player_server     = SessionMemoryScriptedServer.new([
        ollama_tool_use_response(name: "look"),
        ollama_text_response("(wrap up) something seems very wrong here")
      ])
      judge_server      = SessionMemoryScriptedServer.new([
        ollama_text_response("The Player is repeating the same failed action and may be in danger.\nVERDICT: flag")
      ])
      chronicler_server = SessionMemoryScriptedServer.new([ollama_text_response("Mistakes\n- Looking around repeatedly did not help.")])

      Boukensha::Session.play(
        goal: "explore the temple square",
        player: FakePlayer.new("noir"),
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        judge_backend: :ollama, judge_model: "qwen3:8b", judge_ollama_host: judge_server.host,
        chronicler_backend: :ollama, chronicler_model: "qwen3:8b", chronicler_ollama_host: chronicler_server.host,
        max_turns: 5
      )
      planner_server.stop
      player_server.stop
      judge_server.stop
      chronicler_server.stop

      memory = Boukensha::PlayerMemory.load("noir", memory_dir: File.join(dir, "memory"))
      records = memory.session_records
      assert_equal 1, records.size
      assert_equal "explore the temple square", records.first["goal"]
      assert_includes records.first["outcome"], "Judge flagged a risk"
      assert_equal 1, records.first["checkpoints"].size

      assert_equal "Mistakes\n- Looking around repeatedly did not help.", memory.digest_text
    end
  end

  # The fix for "the Judge keeps saying continue, so memory never updates":
  # a checkpoint whose verdict is :continue must still flush, not just
  # :replan/:flag — see docs/plans/memory/player_memory.md's "flush on
  # every checkpoint" revision. Before this, a session that never escalates
  # (e.g. a player quietly repeating a doomed approach — broke, still
  # browsing shops it can't buy anything in) accumulated Judge reasoning in
  # pending_checkpoints and then silently discarded it at loop exit, since
  # nothing ever called flush_memory.
  def test_a_continue_only_checkpoint_still_flushes_memory
    with_temp_boukensha_dir(MEMORY_ENABLED_YAML) do |dir|
      planner_server = SessionMemoryScriptedServer.new([ollama_text_response("1. Look around.")])
      player_server  = SessionMemoryScriptedServer.new([
        ollama_tool_use_response(name: "look"),                          # turn 1, iteration 1: a tool call...
        ollama_text_response("(wrap up) still exploring, low on gold"),  # ...forces a wrap_up call at max_iterations
        ollama_text_response("Done! Completed.")                         # turn 2: completes naturally
      ])
      judge_server = SessionMemoryScriptedServer.new([
        ollama_text_response(
          "Player keeps visiting shops it can't afford anything in, but is still making progress overall.\nVERDICT: continue"
        ),
        # Turn 2 completes naturally, which (with memory on) forces a
        # second, final checkpoint of its own — see
        # test_a_session_that_completes_on_the_first_turn_still_flushes_memory.
        ollama_text_response("The Player recovered and finished the goal.\nVERDICT: continue")
      ])
      chronicler_server = SessionMemoryScriptedServer.new([
        ollama_text_response("Mistakes\n- Broke; stop browsing shops until gold is earned."),
        ollama_text_response("Mistakes\n- Broke; stop browsing shops until gold is earned.\n\nStrategies\n- Recovered and finished the goal anyway.")
      ])

      result = Boukensha::Session.play(
        goal: "explore the temple square",
        player: FakePlayer.new("noir"),
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        judge_backend: :ollama, judge_model: "qwen3:8b", judge_ollama_host: judge_server.host,
        chronicler_backend: :ollama, chronicler_model: "qwen3:8b", chronicler_ollama_host: chronicler_server.host,
        max_turns: 5
      )
      planner_server.stop
      player_server.stop
      judge_server.stop
      chronicler_server.stop

      assert_equal "Done! Completed.", result

      memory  = Boukensha::PlayerMemory.load("noir", memory_dir: File.join(dir, "memory"))
      records = memory.session_records
      assert_equal 2, records.size, "the :continue checkpoint's live flush, plus the forced flush on the completing turn"
      assert_equal "continue", records.first["stop_reason"]
      assert_includes records.first["outcome"], "Judge checkpoint at turn"
      assert_equal 1, records.first["checkpoints"].size
      assert_equal "continue", records.first["checkpoints"].first["verdict"]
      assert_equal "completed", records.last["stop_reason"]
      assert_includes records.last["outcome"], "Completed: Done! Completed."
      assert_equal "Mistakes\n- Broke; stop browsing shops until gold is earned.\n\nStrategies\n- Recovered and finished the goal anyway.",
                   memory.digest_text
    end
  end

  # Checkpoint-triggered memory (docs/plans/memory/player_memory.md's
  # revision): a :replan verdict must chronicle and save the digest BEFORE
  # that replan's own run_planner call, not saved up for session end — so
  # the replanned plan's request payload already carries the freshly
  # chronicled digest, not just whatever prior_digest existed at session
  # start.
  def test_a_replan_flushes_memory_before_the_replanned_planner_call
    with_temp_boukensha_dir(MEMORY_ENABLED_YAML) do |dir|
      planner_server = SessionMemoryScriptedServer.new([
        ollama_text_response("1. Look around."),
        ollama_text_response("1. Try something else.")
      ])
      player_server = SessionMemoryScriptedServer.new([
        ollama_tool_use_response(name: "look"),                      # turn 1, iteration 1: a tool call...
        ollama_text_response("(wrap up) trying a different approach"), # ...forces a wrap_up call at max_iterations
        ollama_text_response("Done! Completed.")                      # turn 2 (after replanning): completes naturally
      ])
      judge_server = SessionMemoryScriptedServer.new([
        ollama_text_response("The plan isn't working, try a different approach.\nVERDICT: replan"),
        # Turn 2 (after replanning) completes naturally, which (with memory
        # on) forces a second, final checkpoint of its own — see
        # test_a_session_that_completes_on_the_first_turn_still_flushes_memory.
        ollama_text_response("The new approach worked.\nVERDICT: continue")
      ])
      chronicler_server = SessionMemoryScriptedServer.new([
        ollama_text_response("Discoveries\n- Something learned mid-session."),
        ollama_text_response("Discoveries\n- Something learned mid-session.\n\nStrategies\n- The replanned approach worked.")
      ])

      result = Boukensha::Session.play(
        goal: "explore the temple square",
        player: FakePlayer.new("noir"),
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        judge_backend: :ollama, judge_model: "qwen3:8b", judge_ollama_host: judge_server.host,
        chronicler_backend: :ollama, chronicler_model: "qwen3:8b", chronicler_ollama_host: chronicler_server.host,
        max_turns: 5
      )
      planner_server.stop
      player_server.stop
      judge_server.stop
      chronicler_server.stop

      assert_equal "Done! Completed.", result

      memory  = Boukensha::PlayerMemory.load("noir", memory_dir: File.join(dir, "memory"))
      records = memory.session_records
      assert_equal 2, records.size, "the replan's live flush, plus the forced flush on the completing turn"
      assert_equal "replan", records.first["stop_reason"]
      assert_equal 1, records.first["checkpoints"].size
      assert_equal "completed", records.last["stop_reason"]
      assert_equal "Discoveries\n- Something learned mid-session.\n\nStrategies\n- The replanned approach worked.", memory.digest_text

      assert_equal 2, planner_server.captured_bodies.size
      replan_request = JSON.parse(planner_server.captured_bodies[1])
      replan_user_text = replan_request["messages"].find { |m| m["role"] == "user" }["content"]
      assert_includes replan_user_text, "What you've learned about this character from past sessions"
      assert_includes replan_user_text, "Something learned mid-session"
    end
  end

  # A session that completes on its very first turn used to reach no
  # checkpoint at all (agent.stop_reason == :completed broke the loop
  # before Session.checkpoint? was ever consulted) and wrote nothing —
  # which meant a session that ended abruptly for an important reason (the
  # Player died and got disconnected from the MUD, and its last reply just
  # narrates that instead of calling another tool) was just as silent as
  # one that ended because the goal was trivially done. See
  # docs/plans/memory/player_memory.md's "checkpoint the ending turn too"
  # revision: a natural completion now always gets one forced Judge
  # checkpoint of its own when memory is on, so how/why the session ended
  # is never lost purely because nothing escalated beforehand.
  def test_a_session_that_completes_on_the_first_turn_still_flushes_memory
    with_temp_boukensha_dir(MEMORY_ENABLED_YAML) do |dir|
      planner_server = SessionMemoryScriptedServer.new([ollama_text_response("1. Find the temple entrance.")])
      player_server  = SessionMemoryScriptedServer.new([ollama_text_response("Done! I found the temple.")])
      judge_server = SessionMemoryScriptedServer.new([
        ollama_text_response("The Player reached the goal without incident.\nVERDICT: continue")
      ])
      chronicler_server = SessionMemoryScriptedServer.new([ollama_text_response("Strategies\n- Exploring directly reached the goal quickly.")])

      result = Boukensha::Session.play(
        goal: "explore the temple square",
        player: FakePlayer.new("noir"),
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        judge_backend: :ollama, judge_model: "qwen3:8b", judge_ollama_host: judge_server.host,
        chronicler_backend: :ollama, chronicler_model: "qwen3:8b", chronicler_ollama_host: chronicler_server.host,
        max_turns: 3
      )
      planner_server.stop
      player_server.stop
      judge_server.stop
      chronicler_server.stop

      assert_equal "Done! I found the temple.", result
      assert_equal 1, judge_server.captured_bodies.size, "the natural completion itself is the forced checkpoint"

      memory  = Boukensha::PlayerMemory.load("noir", memory_dir: File.join(dir, "memory"))
      records = memory.session_records
      assert_equal 1, records.size
      assert_equal "completed", records.first["stop_reason"]
      assert_includes records.first["outcome"], "Completed: Done! I found the temple."
      assert_equal 1, records.first["checkpoints"].size

      assert_equal "Strategies\n- Exploring directly reached the goal quickly.", memory.digest_text
    end
  end

  # Without memory on (or without a player), the forced completion
  # checkpoint above must not fire at all — a plain one-shot goal costs
  # exactly what it always did, and there is no live judge_server here to
  # answer it if it tried.
  def test_a_session_that_completes_with_memory_disabled_never_checks_the_judge
    with_temp_boukensha_dir("") do |dir|
      planner_server = SessionMemoryScriptedServer.new([ollama_text_response("1. Find the temple entrance.")])
      player_server  = SessionMemoryScriptedServer.new([ollama_text_response("Done! I found the temple.")])

      result = Boukensha::Session.play(
        goal: "explore the temple square",
        player: FakePlayer.new("noir"),
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        max_turns: 3
      )
      planner_server.stop
      player_server.stop

      assert_equal "Done! I found the temple.", result
      refute Dir.exist?(File.join(dir, "memory"))
    end
  end

  # A digest already on disk before the run: the Planner's request payload
  # must include a "What you've learned" block containing that prior text.
  def test_a_prior_digest_reaches_the_planners_request_payload
    with_temp_boukensha_dir(MEMORY_ENABLED_YAML) do |dir|
      memory = Boukensha::PlayerMemory.load("noir", memory_dir: File.join(dir, "memory"))
      memory.save_digest("Discoveries\n- The blacksmith haggles if you mention the guild.")

      planner_server = SessionMemoryScriptedServer.new([ollama_text_response("1. Visit the blacksmith.")])
      player_server  = SessionMemoryScriptedServer.new([ollama_text_response("Done! Visited the blacksmith.")])
      # This session completes naturally on turn 1, which (memory being on)
      # now forces its own checkpoint — see
      # test_a_session_that_completes_on_the_first_turn_still_flushes_memory.
      # Neither response's content matters to this test's own assertions.
      judge_server      = SessionMemoryScriptedServer.new([ollama_text_response("No issues.\nVERDICT: continue")])
      chronicler_server = SessionMemoryScriptedServer.new([ollama_text_response("Discoveries\n- The blacksmith haggles if you mention the guild.")])

      Boukensha::Session.play(
        goal: "buy a sword",
        player: FakePlayer.new("noir"),
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        judge_backend: :ollama, judge_model: "qwen3:8b", judge_ollama_host: judge_server.host,
        chronicler_backend: :ollama, chronicler_model: "qwen3:8b", chronicler_ollama_host: chronicler_server.host,
        max_turns: 3
      )
      planner_server.stop
      player_server.stop
      judge_server.stop
      chronicler_server.stop

      sent = JSON.parse(planner_server.captured_bodies.first)
      user_text = sent["messages"].find { |m| m["role"] == "user" }["content"]
      assert_includes user_text, "What you've learned about this character from past sessions"
      assert_includes user_text, "haggles if you mention the guild"
    end
  end

  # Fail-open: a Chronicler backend that errors must not affect the
  # session's own return value, and must leave the digest file exactly as
  # it was before the run (not truncated, not partially written).
  def test_a_failing_chronicler_leaves_the_digest_unchanged_and_does_not_break_the_session
    with_temp_boukensha_dir(MEMORY_ENABLED_YAML) do |dir|
      memory = Boukensha::PlayerMemory.load("noir", memory_dir: File.join(dir, "memory"))
      memory.save_digest("Strategies\n- Bring a torch underground.")

      planner_server = SessionMemoryScriptedServer.new([ollama_text_response("1. Look around.")])
      player_server  = SessionMemoryScriptedServer.new([
        ollama_tool_use_response(name: "look"),
        ollama_text_response("(wrap up) something seems very wrong here")
      ])
      judge_server = SessionMemoryScriptedServer.new([
        ollama_text_response("The Player is repeating the same failed action and may be in danger.\nVERDICT: flag")
      ])
      chronicler_server = ChroniclerErrorServer.new

      result = Boukensha::Session.play(
        goal: "explore the temple square",
        player: FakePlayer.new("noir"),
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        judge_backend: :ollama, judge_model: "qwen3:8b", judge_ollama_host: judge_server.host,
        chronicler_backend: :ollama, chronicler_model: "qwen3:8b", chronicler_ollama_host: chronicler_server.host,
        max_turns: 5
      )
      planner_server.stop
      player_server.stop
      judge_server.stop
      chronicler_server.stop

      assert_equal "(wrap up) something seems very wrong here", result
      assert_equal "Strategies\n- Bring a torch underground.", memory.digest_text
      assert_equal 1, memory.session_records.size, "the raw record itself is plain file I/O and still gets written"
    end
  end

  # Regression: memory.enabled: false (the default) or no player at all
  # produces byte-identical behavior to pre-memory Session.play — no
  # .boukensha/memory/ file, and player_memory: nil at the Planner.
  def test_memory_disabled_by_default_writes_nothing_and_omits_player_memory_from_the_planner
    with_temp_boukensha_dir("") do |dir|
      planner_server = SessionMemoryScriptedServer.new([ollama_text_response("1. Find the temple entrance.")])
      player_server  = SessionMemoryScriptedServer.new([ollama_text_response("Done! I found the temple.")])

      Boukensha::Session.play(
        goal: "explore the temple square",
        player: FakePlayer.new("noir"),
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        max_turns: 3
      )
      planner_server.stop
      player_server.stop

      refute Dir.exist?(File.join(dir, "memory"))
      sent = JSON.parse(planner_server.captured_bodies.first)
      user_text = sent["messages"].find { |m| m["role"] == "user" }["content"]
      refute_includes user_text, "What you've learned about this character from past sessions"
    end
  end

  def test_no_player_never_constructs_memory_even_with_memory_enabled
    with_temp_boukensha_dir(MEMORY_ENABLED_YAML) do |dir|
      planner_server = SessionMemoryScriptedServer.new([ollama_text_response("1. Find the temple entrance.")])
      player_server  = SessionMemoryScriptedServer.new([ollama_text_response("Done! I found the temple.")])

      Boukensha::Session.play(
        goal: "explore the temple square",
        player: nil,
        backend: :ollama, model: "qwen3:8b", ollama_host: player_server.host,
        planner_backend: :ollama, planner_model: "qwen3:8b", planner_ollama_host: planner_server.host,
        max_turns: 3
      )
      planner_server.stop
      player_server.stop

      refute Dir.exist?(File.join(dir, "memory"))
    end
  end
end
