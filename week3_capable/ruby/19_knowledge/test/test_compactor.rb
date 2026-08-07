require_relative "helper"
require "socket"
require "json"

# A minimal HTTP stand-in for whatever provider a Tier 2 backend talks to:
# accepts requests one at a time, counts them (so tests can assert the
# gate/cache actually avoided a call), and always replies with a canned
# `reply_text`. Mirrors test_client.rb's echo-server pattern — no gems, no
# real network.
class FakeChatServer
  attr_reader :request_count

  def initialize(reply_text: "compacted")
    @reply_text     = reply_text
    @request_count  = 0
    @mutex          = Mutex.new
    @server         = TCPServer.new("127.0.0.1", 0)
    @thread         = Thread.new { accept_loop }
    @thread.report_on_exception = false
  end

  def url = "http://127.0.0.1:#{@server.addr[1]}/"

  def stop
    @server.close
  rescue StandardError
    nil
  ensure
    @thread.join(1)
  end

  private

  def accept_loop
    loop do
      conn = @server.accept
      handle(conn)
    end
  rescue IOError, Errno::EBADF
    nil # server socket closed — normal shutdown
  end

  def handle(conn)
    conn.gets # request line
    headers = {}
    while (line = conn.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.downcase] = value.strip if key && value
    end
    conn.read(headers["content-length"].to_i) # drain the request body, unused
    @mutex.synchronize { @request_count += 1 }

    body = JSON.generate(reply: @reply_text)
    conn.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
  ensure
    conn.close rescue nil
  end
end

# A minimal Backends::* stand-in — just the interface Boukensha::Client /
# Boukensha::PromptBuilder / Compactor#call_model actually use
# (to_payload/parse_response/headers/url/context_window) — pointed at a
# FakeChatServer instead of a real provider. This exercises the exact same
# Context/PromptBuilder/Client path Compactor drives a real backend through,
# without depending on live network or any one provider's wire format —
# Compactor is meant to work with "any backend provided by boukensha".
class FakeBackend
  def initialize(url:)
    @url = url
  end

  def context_window = 128_000
  def headers = { "Content-Type" => "application/json" }
  def url = @url
  def provider_name = "fake"
  def model = "fake-model"
  def estimate_cost(input_tokens:, output_tokens:) = nil

  def to_payload(context, max_output_tokens: 1024, tools: nil)
    { prompt: context.messages.last.content, max_output_tokens: max_output_tokens }
  end

  def parse_response(response)
    { stop_reason: "end_turn", content: [{ "type" => "text", "text" => response["reply"] }] }
  end
end

class TestCompactor < Minitest::Test
  include TelemetryTestHelper

  # A CircleMUD-shaped room echo: ANSI-colored title, a multi-line prose
  # description, a bracketed Exits line, and two itemized "is here"/
  # "standing here" content lines, ending in the HP/Mana/Move status prompt
  # a real reply carries. Same grounded shape LogViz::RoomEcho parses.
  ROOM_ECHO = "\e[0;33mThe Temple Square\e[0m\r\n   You are standing on the temple square.  Huge marble " \
              "steps lead up to the\r\ntemple gate.  The entrance to the Clerics' Guild is to the west, " \
              "and the old\r\nGrunting Boar Inn, is to the east.  Just south of here you see the market\r\n" \
              "square, the center of Midgaard.\r\n\e[0;36m[ Exits: n e s w ]\e[0m\r\n" \
              "\e[0;32mA large fountain carved from blue-streaked marble is here, bubbling merrily.\e[0m\r\n" \
              "\e[0;33mA Peacekeeper is standing here, ready to jump in at the first sign of trouble.\e[0m\r\n" \
              "\r\n22H 100M 81V (news) (motd) > "

  # No Exits line at all — combat spam, the other kind of reply Tier 2 is
  # meant to shrink. Exercises Tier 0 with nothing for Tier 1 to structure.
  COMBAT_RAW = "\e[1;31mYou hit the goblin for 12 damage!\e[0m\r\n\r\n\r\n" \
               "\e[1;31mThe goblin hits you for 3 damage!\e[0m\r\n\r\n21H 100M 79V (news) (motd) > "

  # A real captured shape: a plain `look` reply carries no HP/Mana/Move
  # status (that only appears after an action like move/attack) — just the
  # channel-subscription list before the prompt sentinel. Regression fixture
  # for a bug where PROMPT_LINE_RE's predecessor only matched the bare "> "
  # sentinel when no HP/Mana/Move prefix was present, leaving "(news)
  # (motd)" stuck onto the end of every plain-look result.
  ROOM_ECHO_NO_STATUS_LINE = "\e[0;33mThe Dark Alley\e[0m\r\n   The dark alley, to the west is the common " \
                             "square.\r\n\e[0;36m[ Exits: e s w ]\e[0m\r\n\e[0;33mA mercenary is waiting " \
                             "for a job here.\e[0m\r\n\r\n(news) (motd) > "

  # ---------- gating: ok / prefix scope -------------------------------------

  def test_error_results_pass_through_unchanged
    c   = Boukensha::Compactor.new
    raw = "ERROR: RuntimeError: connection reset"

    assert_equal raw, c.compact(name: "tbamud__look", result: raw, ok: false)
  end

  def test_results_from_tools_outside_the_hardcoded_tbamud_prefix_pass_through_unchanged
    c = Boukensha::Compactor.new

    assert_equal ROOM_ECHO, c.compact(name: "fs__read_file", result: ROOM_ECHO, ok: true)
  end

  # ---------- Tier 0: deterministic normalization ---------------------------

  def test_strips_ansi_the_trailing_prompt_and_collapses_blank_lines
    c        = Boukensha::Compactor.new
    expected = "You hit the goblin for 12 damage!\n\nThe goblin hits you for 3 damage!"

    assert_equal expected, c.compact(name: "tbamud__hit", result: COMBAT_RAW, ok: true)
  end

  def test_strips_the_trailing_prompt_line_when_no_hp_mana_move_status_is_present
    c   = Boukensha::Compactor.new
    out = c.compact(name: "tbamud__look", result: ROOM_ECHO_NO_STATUS_LINE, ok: true)

    refute_includes out, "(news)"
    refute_includes out, "(motd)"
    refute_includes out, ">"
    assert_includes out.split("\n"), "A mercenary is waiting for a job here."
  end

  # ---------- Tier 1: structure-aware split ---------------------------------

  def test_preserves_title_exits_and_content_lines_verbatim
    c     = Boukensha::Compactor.new
    out   = c.compact(name: "tbamud__look", result: ROOM_ECHO, ok: true)
    lines = out.split("\n")

    assert_equal "The Temple Square", lines.first
    assert_includes lines, "[ Exits: n e s w ]"
    assert_includes lines, "A large fountain carved from blue-streaked marble is here, bubbling merrily."
    assert_includes lines, "A Peacekeeper is standing here, ready to jump in at the first sign of trouble."
    refute_includes out, "\e["
  end

  def test_tier2_disabled_by_default_leaves_prose_untouched
    c   = Boukensha::Compactor.new # enabled: false by default
    out = c.compact(name: "tbamud__look", result: ROOM_ECHO, ok: true)

    assert_includes out, "Huge marble steps"
  end

  # ---------- Tier 2: opt-in LLM prose compaction ---------------------------

  def test_tier2_compacts_prose_when_enabled_and_over_min_chars
    server  = FakeChatServer.new(reply_text: "A grand old temple square, fountain, and guard.")
    backend = FakeBackend.new(url: server.url)
    c       = Boukensha::Compactor.new(enabled: true, backend: backend, min_chars: 10)

    out = c.compact(name: "tbamud__look", result: ROOM_ECHO, ok: true)

    assert_includes out, "A grand old temple square, fountain, and guard."
    refute_includes out, "Huge marble steps"
    assert_equal "The Temple Square", out.split("\n").first
    assert_includes out.split("\n"), "[ Exits: n e s w ]"
  ensure
    server&.stop
  end

  def test_tier2_skips_prose_below_min_chars_without_calling_the_model
    server  = FakeChatServer.new
    backend = FakeBackend.new(url: server.url)
    c       = Boukensha::Compactor.new(enabled: true, backend: backend, min_chars: 100_000)

    c.compact(name: "tbamud__look", result: ROOM_ECHO, ok: true)

    assert_equal 0, server.request_count
  ensure
    server&.stop
  end

  def test_tier2_caches_identical_prose_by_content_hash
    server  = FakeChatServer.new(reply_text: "cached summary")
    backend = FakeBackend.new(url: server.url)
    c       = Boukensha::Compactor.new(enabled: true, backend: backend, min_chars: 10)

    2.times { c.compact(name: "tbamud__look", result: ROOM_ECHO, ok: true) }

    assert_equal 1, server.request_count
  ensure
    server&.stop
  end

  def test_tier2_fails_open_when_the_model_is_unreachable
    closed_server = TCPServer.new("127.0.0.1", 0)
    port          = closed_server.addr[1]
    closed_server.close # nothing listening on this port anymore

    backend = FakeBackend.new(url: "http://127.0.0.1:#{port}/")
    c       = Boukensha::Compactor.new(enabled: true, backend: backend, min_chars: 10)
    out     = c.compact(name: "tbamud__look", result: ROOM_ECHO, ok: true)

    assert_includes out, "Huge marble steps"
    assert_equal "The Temple Square", out.split("\n").first
  end

  # Phase 2 instruments Client#call exactly once and relies on Ruby's current-
  # span context nesting to place a caller's llm_request correctly (see
  # Client#call's header comment and the overview's span-tree diagram, where
  # `compaction` is a child of the `tool_call` span it fired from). This
  # confirms that actually holds for the compaction path — a real Agent
  # dispatch is `tracer.in_span("boukensha.tool_call") { ...; compactor.compact }`
  # (agent.rb#handle_tool_calls), so the ambient span at compact-time is
  # exactly what's simulated here.
  def test_tier2_compaction_span_nests_under_the_calling_tool_call_span
    with_span_exporter do |exporter|
      server  = FakeChatServer.new(reply_text: "A grand old temple square, fountain, and guard.")
      backend = FakeBackend.new(url: server.url)
      c       = Boukensha::Compactor.new(enabled: true, backend: backend, min_chars: 10)

      Boukensha.tracer.in_span("boukensha.tool_call", attributes: { "boukensha.tool.name" => "tbamud__look" }) do
        c.compact(name: "tbamud__look", result: ROOM_ECHO, ok: true)
      end

      spans       = exporter.finished_spans
      tool_call   = spans.find { |s| s.name == "boukensha.tool_call" }
      compaction  = spans.find { |s| s.name == "boukensha.compaction" }
      llm_request = spans.find { |s| s.name == "boukensha.llm_request" }

      refute_nil tool_call
      refute_nil compaction, "Tier 2 firing must produce a boukensha.compaction span"
      assert_equal tool_call.span_id, compaction.parent_span_id,
                   "compaction must nest under the tool_call span it was triggered from, not be its sibling"

      refute_nil llm_request, "Compactor#call_model must produce its own llm_request span, via Client#call"
      assert_equal compaction.span_id, llm_request.parent_span_id,
                   "the nested llm_request must itself nest under compaction (not directly under tool_call)"
    ensure
      server&.stop
    end
  end
end
