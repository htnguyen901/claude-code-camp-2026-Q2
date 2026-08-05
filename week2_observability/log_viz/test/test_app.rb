require_relative "helper"
require "rack"
require "log_viz/app"
require "log_viz/world_map"
require "json"
require "time"

# Covers routes with a plain request/response (or full-page-render)
# contract worth locking down with a real Sinatra request instead of just
# unit-testing the underlying WorldMap/Session objects: world_map_
# visualization.md §3's click-to-inspect panel data source, the injected-
# panel template, and (added for docs/plans/observability/players/
# multiple_concurrent_players.md) the /players roster/detail pages and the
# session page's per-session time-lapse panel. `map_svg`/the box-node
# rendering itself is exercised visually (browser), not here.
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

  # Exercises the real Sinatra route + session.erb rendering (not just
  # LogViz::Session#entries in isolation) for the "injected into next
  # request" panel — catches template-level bugs a pure parsing test can't.
  def test_session_page_renders_the_injected_panel_with_compacted_text
    path = File.join(@sessions_dir, "s1.jsonl")
    File.write(path, [
      event(phase: "session_start", provider: "openai", model: "gpt-5.4-mini", task: "player"),
      event(phase: "turn", n: 1),
      event(phase: "iteration", n: 1),
      event(phase: "tool_call", name: "tbamud__look", args: {}),
      event(phase: "tool_result", name: "tbamud__look", result: "The full raw room description text.",
            ok: true, compacted: "Short room summary."),
      event(phase: "iteration", n: 2),
      event(phase: "request", iteration: 2, payload: { model: "gpt-5.4-mini", input: [] },
            message_count: 1, tool_count: 0)
    ].join("\n") + "\n")

    res = @request.get("/sessions/s1")

    assert_equal 200, res.status
    assert_includes res.body, "Injected into next request"
    # The compacted text appears in the new panel; the raw text still
    # appears too, in the existing (untouched) tool-result block above it —
    # this feature is purely additive visibility, not a replacement.
    assert_includes res.body, "Short room summary."
    assert_includes res.body, "The full raw room description text."
  end

  def seed_player_session(player:, session_id: "s1", title: "The General Store", exits: %w[s])
    path = File.join(@sessions_dir, "#{session_id}.jsonl")
    File.write(path, [
      event(phase: "session_start", provider: "anthropic", model: "claude-haiku-4-5", task: "player", player: player),
      event(phase: "turn", n: 1),
      event(phase: "iteration", n: 1),
      event(phase: "tool_call", name: "tbamud__look", args: {}),
      event(phase: "tool_result", name: "tbamud__look", result: room_echo(title, exits))
    ].join("\n") + "\n")

    LogViz::WorldMap.instance(sessions_dir: @sessions_dir, db_path: @db_path).refresh!
  end

  def test_players_index_lists_a_tagged_player
    seed_player_session(player: "noir")

    res = @request.get("/players")

    assert_equal 200, res.status
    assert_includes res.body, "noir"
  end

  def test_players_index_omits_untagged_sessions
    seed_room # untagged session, no `player:` field

    res = @request.get("/players")

    assert_equal 200, res.status
    assert_includes res.body, "No tagged players yet"
  end

  def test_player_detail_renders_kpi_and_session_list
    seed_player_session(player: "noir")

    res = @request.get("/players/noir")

    assert_equal 200, res.status
    assert_includes res.body, "Rooms discovered"
    assert_includes res.body, "s1"
  end

  def test_player_detail_404s_for_a_player_with_no_sessions
    res = @request.get("/players/nobody")

    assert_equal 404, res.status
  end

  def test_session_page_renders_the_time_lapse_panel_when_visits_exist
    seed_player_session(player: "noir")

    res = @request.get("/sessions/s1")

    assert_equal 200, res.status
    assert_includes res.body, "Path taken this session"
    assert_includes res.body, "The General Store"
  end

  # ---------- Rooms/Discoveries split onto their own pages
  # (world_map_enhancer.md §4) ------------------------------------------

  def test_map_rooms_page_lists_rooms
    seed_room

    res = @request.get("/map/rooms")

    assert_equal 200, res.status
    assert_includes res.body, "The General Store"
  end

  def test_map_discoveries_page_lists_discoveries
    seed_room

    res = @request.get("/map/discoveries")

    assert_equal 200, res.status
    assert_includes res.body, "A grocer stands at the counter."
  end

  def test_map_page_links_out_to_the_standalone_rooms_and_discoveries_pages
    seed_room

    res = @request.get("/map")

    assert_equal 200, res.status
    assert_includes res.body, "/map/rooms"
    assert_includes res.body, "/map/discoveries"
  end

  # ---------- Player-scoped Knowledge (world_map_enhancer.md §5) ---------

  def test_players_rooms_and_discoveries_pages_are_scoped_to_that_player
    seed_player_session(player: "noir", session_id: "noir-s1", title: "Noir Hideout", exits: %w[s])
    seed_player_session(player: "dina", session_id: "dina-s1", title: "Dina Hideout", exits: %w[s])

    rooms_res = @request.get("/players/noir/rooms")
    assert_equal 200, rooms_res.status
    assert_includes rooms_res.body, "Noir Hideout"
    refute_includes rooms_res.body, "Dina Hideout"

    discoveries_res = @request.get("/players/noir/discoveries")
    assert_equal 200, discoveries_res.status
  end

  def test_players_knowledge_map_is_scoped_to_that_players_own_rooms
    seed_player_session(player: "noir", session_id: "noir-s1", title: "Noir Hideout", exits: %w[s])
    seed_player_session(player: "dina", session_id: "dina-s1", title: "Dina Hideout", exits: %w[s])

    res = @request.get("/players/noir")

    assert_equal 200, res.status
    assert_includes res.body, "Noir Hideout"
    refute_includes res.body, "Dina Hideout"
  end

  def test_players_sessions_table_renders_a_path_glyph_when_visits_exist
    seed_player_session(player: "noir")

    res = @request.get("/players/noir")

    assert_equal 200, res.status
    assert_includes res.body, "path-glyph"
  end

  # ---------- Unexplored-neighbor stubs (world_map_enhancer.md §2) -------

  def test_map_renders_an_unexplored_stub_for_an_unvisited_exit
    seed_room(title: "The General Store", exits: %w[n s])

    res = @request.get("/map")

    assert_equal 200, res.status
    assert_includes res.body, "map-node-unexplored"
    assert_includes res.body, "not yet visited"
  end

  def test_map_does_not_render_a_stub_for_an_exit_that_leads_to_an_already_visited_room
    path = File.join(@sessions_dir, "s1.jsonl")
    File.write(path, [
      event(phase: "session_start", provider: "anthropic", model: "claude-haiku-4-5", task: "player"),
      event(phase: "tool_call", name: "tbamud__move", args: { "direction" => "east" }),
      event(phase: "tool_result", name: "tbamud__move", result: room_echo("Room A", %w[e])),
      event(phase: "tool_call", name: "tbamud__move", args: { "direction" => "east" }),
      event(phase: "tool_result", name: "tbamud__move", result: room_echo("Room B", %w[w]))
    ].join("\n") + "\n")
    LogViz::WorldMap.instance(sessions_dir: @sessions_dir, db_path: @db_path).refresh!

    res = @request.get("/map")

    assert_equal 200, res.status
    refute_includes res.body, "map-node-unexplored"
  end
end
