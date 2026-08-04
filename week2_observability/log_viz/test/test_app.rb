require_relative "helper"
require "rack"
require "log_viz/app"
require "log_viz/world_map"
require "json"
require "time"

# Covers the one route this plan adds — world_map_visualization.md §3's
# click-to-inspect panel data source. `map_svg`/the box-node rendering (§1,
# §2) is exercised visually (browser), not here — this is the one part of
# that plan with a plain request/response contract worth locking down.
class TestApp < Minitest::Test
  def setup
    @tmp_dir      = Dir.mktmpdir
    @sessions_dir = File.join(@tmp_dir, "sessions")
    FileUtils.mkdir_p(@sessions_dir)
    @db_path = File.join(@tmp_dir, "world_map.sqlite3")

    LogViz::App.set(:sessions_dir, @sessions_dir)
    LogViz::App.set(:world_map_db, @db_path)
    @request = Rack::MockRequest.new(LogViz::App)
  end

  def teardown
    LogViz::WorldMap.reset_instances!
    FileUtils.remove_entry(@tmp_dir)
  end

  def event(overrides)
    JSON.generate({ session_id: "test-session", at: Time.now.iso8601 }.merge(overrides))
  end

  def room_echo(title, exits, contents_lines = [], description: "A plain room.")
    body = contents_lines.map { |l| "#{l}\r\n" }.join
    "\e[0;33m#{title}\e[0m\r\n#{description}\r\n\e[0;36m[ Exits: #{exits.join(' ')} ]\e[0m\r\n#{body}\r\n" \
      "21H 100M 83V (news) (motd) > "
  end

  # Writes a session log with one room reachable by a `look`, plus one
  # examine call against it, then forces WorldMap to ingest it — the same
  # ingestion path `/map`'s helpers already read from, just driven directly
  # instead of through a live session for test determinism.
  def seed_room(title: "The General Store", exits: %w[s], contents: ["A grocer stands at the counter."])
    path = File.join(@sessions_dir, "s1.jsonl")
    File.write(path, [
      event(phase: "session_start", provider: "anthropic", model: "claude-haiku-4-5", task: "player"),
      event(phase: "turn", n: 1),
      event(phase: "iteration", n: 1),
      event(phase: "tool_call", name: "tbamud__look", args: {}),
      event(phase: "tool_result", name: "tbamud__look", result: room_echo(title, exits, contents)),
      event(phase: "tool_call", name: "tbamud__examine", args: { "target" => "grocer" }),
      event(phase: "tool_result", name: "tbamud__examine", result: "A tall grocer.\r\n\r\n21H 100M 83V (news) (motd) > ")
    ].join("\n") + "\n")

    LogViz::WorldMap.instance(sessions_dir: @sessions_dir, db_path: @db_path).refresh!
  end

  def test_room_detail_json_returns_room_fields_and_discoveries
    seed_room

    res = @request.get("/map/rooms/#{Rack::Utils.escape_path('The General Store')}.json")

    assert_equal 200, res.status
    assert_equal "application/json", res.content_type
    body = JSON.parse(res.body)

    assert_equal "The General Store", body["title"]
    assert_equal %w[s], body["exits"]
    assert_equal 1, body["visit_count"]

    # `subject`/`kind` depend on ContentFact's background LLM classification
    # (async, and not injectable through the App/WorldMap.instance memoized
    # path this route uses — see WorldMap.instance) — asserting on
    # `content`/`examined`/`examination_result` instead keeps this
    # deterministic regardless of whether that background worker (or a
    # reachable Ollama daemon) has run yet.
    discovery = body["discoveries"].find { |d| d["content"] == "A grocer stands at the counter." }
    refute_nil discovery
    assert discovery["examined"]
    assert_equal "A tall grocer.", discovery["examination_result"]
  end

  def test_room_detail_json_404s_for_an_unknown_title
    seed_room

    res = @request.get("/map/rooms/#{Rack::Utils.escape_path('Nowhere at all')}.json")

    assert_equal 404, res.status
    assert_equal "application/json", res.content_type
    assert JSON.parse(res.body)["error"]
  end
end
