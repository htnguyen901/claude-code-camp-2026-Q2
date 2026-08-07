require_relative "helper"
require "log_viz/mcp_server"
require "json"
require "stringio"

# LogViz::McpServer — the JSON-RPC 2.0 / MCP stdio transport for
# room_knowledge/route_to (docs/plans/world_knowledge/world_knowledge.md §4).
# Feeds newline-delimited JSON-RPC requests through a real McpServer#run
# against a throwaway world_map.sqlite3, same "black-box over stdin/stdout"
# posture MudManager::McpServer would be tested with.
class TestMcpServer < Minitest::Test
  def setup
    @tmp_dir = Dir.mktmpdir
    @db_path = File.join(@tmp_dir, "world_map.sqlite3")
    @old_db_env     = ENV["LOG_VIZ_WORLD_MAP_DB"]
    @old_player_env = ENV["WORLD_MAP_PLAYER"]
    ENV["LOG_VIZ_WORLD_MAP_DB"] = @db_path
    ENV.delete("WORLD_MAP_PLAYER")

    build_fixture_db
  end

  def teardown
    ENV["LOG_VIZ_WORLD_MAP_DB"] = @old_db_env
    ENV["WORLD_MAP_PLAYER"] = @old_player_env
    FileUtils.remove_entry(@tmp_dir)
  end

  def build_fixture_db
    db = SQLite3::Database.new(@db_path)
    db.execute_batch(<<~SQL)
      CREATE TABLE rooms (title TEXT PRIMARY KEY, exits TEXT, first_seen_at TEXT);
      CREATE TABLE edges (from_title TEXT, via TEXT, to_title TEXT, PRIMARY KEY (from_title, via));
      CREATE TABLE room_contents (room_title TEXT, content TEXT, first_seen_at TEXT);
      CREATE TABLE content_facts (content_hash TEXT PRIMARY KEY, raw TEXT, subject TEXT, kind TEXT, clause TEXT, source TEXT, extracted_at TEXT);
      CREATE TABLE examinations (room_title TEXT, subject TEXT, session_id TEXT, turn INTEGER, iteration INTEGER, at TEXT, result_text TEXT, PRIMARY KEY (room_title, subject));
      CREATE TABLE sessions (session_id TEXT PRIMARY KEY, player TEXT);
      CREATE TABLE visits (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, room_title TEXT);
    SQL

    db.execute("INSERT INTO rooms(title, exits, first_seen_at) VALUES (?, ?, ?)",
               ["Market Square", '["n"]', "2026-01-01T00:00:00Z"])
    db.execute("INSERT INTO rooms(title, exits, first_seen_at) VALUES (?, ?, ?)",
               ["Temple Square", '["s"]', "2026-01-01T00:00:00Z"])
    db.execute("INSERT INTO edges(from_title, via, to_title) VALUES (?, ?, ?)",
               ["Market Square", "north", "Temple Square"])
    db.execute("INSERT INTO room_contents(room_title, content, first_seen_at) VALUES (?, ?, ?)",
               ["Market Square", "A rusty lever is here.", "2026-01-01T00:00:00Z"])
    db.execute(
      "INSERT INTO content_facts(content_hash, raw, subject, kind, clause, source, extracted_at) VALUES (?,?,?,?,?,?,?)",
      ["A rusty lever is here.", "A rusty lever is here.", "lever", "item", nil, "llm", "2026-01-01T00:00:00Z"]
    )
    db.execute("INSERT INTO sessions(session_id, player) VALUES (?, ?)", ["noir-s1", "noir"])
    db.execute("INSERT INTO visits(session_id, room_title) VALUES (?, ?)", ["noir-s1", "Market Square"])
    db.close
  end

  def rpc(*requests)
    input  = StringIO.new(requests.map { |r| JSON.generate(r) }.join("\n") + "\n")
    output = StringIO.new
    LogViz::McpServer.new(input: input, output: output).run
    output.string.each_line.map { |line| JSON.parse(line) }
  end

  def call(name, arguments, id: 1)
    { "jsonrpc" => "2.0", "id" => id, "method" => "tools/call",
      "params" => { "name" => name, "arguments" => arguments } }
  end

  def result_of(response)
    JSON.parse(response.dig("result", "content", 0, "text"))
  end

  def test_initialize_reports_protocol_version_and_server_info
    responses = rpc({ "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => {} })
    result = responses.first["result"]
    assert_equal "2025-06-18", result["protocolVersion"]
    assert_equal "log-viz", result["serverInfo"]["name"]
  end

  def test_tools_list_advertises_room_knowledge_and_route_to
    responses = rpc({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => {} })
    names = responses.first["result"]["tools"].map { |t| t["name"] }
    assert_equal %w[room_knowledge route_to], names
  end

  def test_room_knowledge_call_returns_examined_unexamined_and_connections
    response = rpc(call("room_knowledge", { "room_title" => "Market Square" })).first
    refute response["result"]["isError"]

    payload = result_of(response)
    assert_equal "Market Square", payload["room_title"]
    assert_equal ["lever"], payload["unexamined"]
    assert_equal [{ "direction" => "north", "to" => "Temple Square", "via" => ["north"] }], payload["connections"]
  end

  def test_route_to_call_returns_hops
    response = rpc(call("route_to", { "from" => "Market Square", "to" => "Temple Square" })).first
    payload = result_of(response)

    assert_equal [{ "direction" => "north", "to" => "Temple Square" }], payload["hops"]
  end

  def test_unknown_tool_name_is_reported_as_an_error
    response = rpc(call("no_such_tool", {})).first
    assert response["result"]["isError"]
    assert_match(/unknown tool/, response["result"]["content"].first["text"])
  end

  # WORLD_MAP_PLAYER (decision 4): read once from ENV at startup, never a
  # tool-call argument — the model can't spoof another character's
  # discoveries by just passing a different `player` string, because
  # there's no such parameter to pass.
  def test_world_map_player_env_scopes_room_knowledge_to_that_players_visits
    ENV["WORLD_MAP_PLAYER"] = "noir"
    response = rpc(call("room_knowledge", { "room_title" => "Market Square" })).first
    payload = result_of(response)
    refute payload.key?("note"), "noir has visited Market Square"

    ENV["WORLD_MAP_PLAYER"] = "someone-else"
    response = rpc(call("room_knowledge", { "room_title" => "Market Square" })).first
    payload = result_of(response)
    assert_equal "you have not been here", payload["note"]
  end

  def test_blank_world_map_player_env_behaves_like_unset
    ENV["WORLD_MAP_PLAYER"] = ""
    response = rpc(call("room_knowledge", { "room_title" => "Market Square" })).first
    refute result_of(response).key?("note")
  end

  def test_missing_database_degrades_to_empty_results_instead_of_raising
    ENV["LOG_VIZ_WORLD_MAP_DB"] = File.join(@tmp_dir, "does-not-exist.sqlite3")
    response = rpc(call("room_knowledge", { "room_title" => "Anywhere" })).first
    refute response["result"]["isError"]

    payload = result_of(response)
    assert_equal({ "room_title" => "Anywhere", "examined" => [], "unexamined" => [], "connections" => [] }, payload)
  end
end
