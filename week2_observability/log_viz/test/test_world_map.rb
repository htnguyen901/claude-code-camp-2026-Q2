require_relative "helper"
require "log_viz/world_map"
require "json"
require "time"

# Covers player_journey_map.md §2's actual scalability claim: a refresh only
# costs work proportional to *new* log data, never to total history — plus
# the coordinate-assignment, cross-session-discovery, and self-healing
# properties that claim depends on.
class TestWorldMap < Minitest::Test
  def setup
    @tmp_dir      = Dir.mktmpdir
    @sessions_dir = File.join(@tmp_dir, "sessions")
    FileUtils.mkdir_p(@sessions_dir)
    @db_path = File.join(@tmp_dir, "world_map.sqlite3")
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir)
  end

  def build_map
    LogViz::WorldMap.new(sessions_dir: @sessions_dir, db_path: @db_path)
  end

  def event(overrides)
    JSON.generate({ session_id: "test-session", at: Time.now.iso8601 }.merge(overrides))
  end

  def room_echo(title, exits, contents_lines = [])
    body = contents_lines.map { |l| "#{l}\r\n" }.join
    "\e[0;33m#{title}\e[0m\r\nA plain room.\r\n\e[0;36m[ Exits: #{exits.join(' ')} ]\e[0m\r\n#{body}\r\n" \
      "21H 100M 83V (news) (motd) > "
  end

  def write_lines(path, lines, mode: "w")
    File.open(path, mode) { |f| lines.each { |l| f.puts l } }
  end

  def move_lines(direction:, title:, exits:, contents: [])
    [
      event(phase: "tool_call", name: "tbamud__move", args: { "direction" => direction }),
      event(phase: "tool_result", name: "tbamud__move", result: room_echo(title, exits, contents))
    ]
  end

  def test_ingests_rooms_edges_and_assigns_direction_based_coordinates
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, [
      event(phase: "session_start", provider: "anthropic", model: "claude-haiku-4-5", task: "player"),
      event(phase: "turn", n: 1),
      event(phase: "iteration", n: 1),
      *move_lines(direction: "north", title: "Room A", exits: %w[s e])
    ])
    write_lines(path, [
      event(phase: "iteration", n: 2),
      *move_lines(direction: "east", title: "Room B", exits: %w[w])
    ], mode: "a")

    wm = build_map
    wm.refresh!

    rooms = wm.rooms.each_with_object({}) { |r, h| h[r[:title]] = r }
    assert_equal [0.0, 0.0], rooms["Room A"][:coord]
    assert_equal [1.0, 0.0], rooms["Room B"][:coord], "east of Room A should be +1 on x"
    assert_equal [{ from: "Room A", via: "east", to: "Room B" }], wm.edges
  end

  def test_failed_move_does_not_update_location_or_create_a_room
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, [
      *move_lines(direction: "north", title: "Room A", exits: %w[s]),
      event(phase: "tool_call", name: "tbamud__move", args: { "direction" => "east" }),
      event(phase: "tool_result", name: "tbamud__move", result: "Alas, you cannot go that way...\r\n\r\n21H 100M 83V (news) (motd) > ")
    ])

    wm = build_map
    wm.refresh!

    assert_equal 1, wm.rooms.length
    assert_equal "Room A", wm.sessions.first[:last_room]
  end

  def test_refresh_only_processes_newly_appended_bytes
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "Room A", exits: %w[s]))

    wm = build_map
    wm.refresh!
    assert_equal 1, wm.rooms.length

    # Second refresh with no new bytes must not reprocess anything (no
    # duplicate visit rows, no changed visit_count).
    wm.refresh!
    assert_equal 1, wm.visits_for("s1").length

    write_lines(path, move_lines(direction: "south", title: "Room A", exits: %w[s]), mode: "a")
    wm.refresh!
    assert_equal 2, wm.visits_for("s1").length, "only the newly appended visit should be added"
    assert_equal 2, wm.rooms.first[:visit_count]
  end

  def test_room_coordinate_never_moves_once_assigned
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, [
      *move_lines(direction: "north", title: "Room A", exits: %w[s e]),
      *move_lines(direction: "east", title: "Room B", exits: %w[w])
    ])

    wm = build_map
    wm.refresh!
    first_coord = wm.rooms.find { |r| r[:title] == "Room B" }[:coord]

    # A second session reaches Room B from a different room/direction —
    # Room B's coordinate must not be overwritten, only the edge is added.
    path2 = File.join(@sessions_dir, "s2.jsonl")
    File.write(path2, [
      event(session_id: "s2", phase: "tool_call", name: "tbamud__move", args: { "direction" => "north" }),
      event(session_id: "s2", phase: "tool_result", name: "tbamud__move", result: room_echo("Room C", %w[s]))
    ].join("\n") + "\n")
    write_lines(path2, [
      event(session_id: "s2", phase: "tool_call", name: "tbamud__move", args: { "direction" => "south" }),
      event(session_id: "s2", phase: "tool_result", name: "tbamud__move", result: room_echo("Room B", %w[w]))
    ], mode: "a")
    wm.refresh!

    second_coord = wm.rooms.find { |r| r[:title] == "Room B" }[:coord]
    assert_equal first_coord, second_coord
  end

  def test_discoveries_dedupe_the_same_content_across_rooms
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, [
      *move_lines(direction: "north", title: "Room A", exits: %w[s], contents: ["A rusty lever is here."]),
      *move_lines(direction: "east", title: "Room B", exits: %w[w], contents: ["A rusty lever is here."])
    ])

    wm = build_map
    wm.refresh!

    discoveries = wm.discoveries
    lever = discoveries.find { |d| d[:content] == "A rusty lever is here." }
    refute_nil lever
    assert_equal %w[Room\ A Room\ B], lever[:rooms].sort
  end

  def test_self_state_upserts_last_known_snapshot_per_kind
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, [
      event(phase: "tool_call", name: "tbamud__info_self", args: { "kind" => "equipment" }),
      event(phase: "tool_result", name: "tbamud__info_self", result: "You are carrying:\r\n  Nothing.\r\n\r\n21H 100M 83V (news) (motd) > ")
    ])

    wm = build_map
    wm.refresh!

    state = wm.self_state_for("s1")
    assert_equal "You are carrying:\n  Nothing.", state["equipment"][:text]
  end

  def test_state_survives_reopening_the_database
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "Room A", exits: %w[s]))

    build_map.refresh!

    reopened = build_map
    reopened.refresh!
    assert_equal 1, reopened.rooms.length
    assert_equal "Room A", reopened.rooms.first[:title]
  end

  def test_corrupt_database_self_heals_and_rebuilds_from_logs
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "Room A", exits: %w[s]))

    build_map.refresh!
    File.write(@db_path, "not a sqlite file at all")
    Dir.glob("#{@db_path}-*").each { |f| File.delete(f) }

    recovered = build_map
    recovered.refresh!

    assert_equal 1, recovered.rooms.length
    assert_equal "Room A", recovered.rooms.first[:title]
    assert Dir.glob("#{@db_path}.corrupt-*").any?, "expected the corrupt file to be backed up"
  end

  def test_live_sessions_reflects_recent_activity_only
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "Room A", exits: %w[s]))

    wm = build_map
    wm.refresh!
    assert_equal 1, wm.live_sessions.length

    stale_path = File.join(@sessions_dir, "s2.jsonl")
    File.write(stale_path, [
      event(session_id: "s2", phase: "tool_call", name: "tbamud__move", args: { "direction" => "north" }, at: (Time.now - 3600).iso8601),
      event(session_id: "s2", phase: "tool_result", name: "tbamud__move", result: room_echo("Room Z", %w[s]), at: (Time.now - 3600).iso8601)
    ].join("\n") + "\n")
    wm.refresh!

    live_ids = wm.live_sessions.map { |s| s[:session_id] }
    assert_includes live_ids, "s1"
    refute_includes live_ids, "s2"
  end
end
