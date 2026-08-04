require_relative "helper"
require "log_viz/world_map"
require "minitest/mock"
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

  # content_fact_worker defaults off — a real background thread hitting a
  # (likely-unreachable-in-CI) Ollama daemon has no place in tests that
  # don't specifically exercise it. Tests that do (content-fact
  # classification, examine matching) pass an injected
  # content_fact_extractor instead of hitting the network — see
  # `test_content_facts_are_classified_lazily_in_the_background` and
  # `build_map_with_facts` below.
  # content_fact_retry_cooldown defaults to 0 — tests calling
  # `backfill_content_facts!` more than once need immediate retry of
  # `fallback` rows to be deterministic, not gated behind the production
  # cooldown (see DEFAULT_CONTENT_FACT_RETRY_COOLDOWN).
  def build_map(content_fact_worker: false, content_fact_extractor: nil, description_mention_extractor: nil,
                content_fact_retry_cooldown: 0)
    LogViz::WorldMap.new(sessions_dir: @sessions_dir, db_path: @db_path,
                          content_fact_worker: content_fact_worker,
                          content_fact_extractor: content_fact_extractor,
                          description_mention_extractor: description_mention_extractor,
                          content_fact_retry_cooldown: content_fact_retry_cooldown)
  end

  def event(overrides)
    JSON.generate({ session_id: "test-session", at: Time.now.iso8601 }.merge(overrides))
  end

  def room_echo(title, exits, contents_lines = [], description: "A plain room.")
    body = contents_lines.map { |l| "#{l}\r\n" }.join
    "\e[0;33m#{title}\e[0m\r\n#{description}\r\n\e[0;36m[ Exits: #{exits.join(' ')} ]\e[0m\r\n#{body}\r\n" \
      "21H 100M 83V (news) (motd) > "
  end

  def write_lines(path, lines, mode: "w")
    File.open(path, mode) { |f| lines.each { |l| f.puts l } }
  end

  def move_lines(direction:, title:, exits:, contents: [], description: "A plain room.", at: nil)
    [
      event({ phase: "tool_call", name: "tbamud__move", args: { "direction" => direction } }.merge(at ? { at: at } : {})),
      event({ phase: "tool_result", name: "tbamud__move",
              result: room_echo(title, exits, contents, description: description) }.merge(at ? { at: at } : {}))
    ]
  end

  def examine_lines(target:, result:, name: "tbamud__examine", at: nil)
    [
      event({ phase: "tool_call", name: name, args: { "target" => target } }.merge(at ? { at: at } : {})),
      event({ phase: "tool_result", name: name, result: result }.merge(at ? { at: at } : {}))
    ]
  end

  def wait_until(timeout: 5)
    deadline = Time.now + timeout
    until yield
      raise "timed out waiting for condition" if Time.now > deadline

      sleep 0.05
    end
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

  # ---------- ContentFact integration (room_world_inspector.md §1) ----------

  def test_content_facts_are_classified_lazily_in_the_background
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "Room A", exits: %w[s], contents: ["A rusty lever is here."]))

    extractor = ->(_raw) { { subject: "lever", kind: "item", clause: "rusty", source: "llm" } }
    wm = build_map(content_fact_worker: true, content_fact_extractor: extractor)
    wm.refresh!

    wait_until { wm.discoveries.first && wm.discoveries.first[:kind] == "item" }

    fact = wm.discoveries.find { |d| d[:content] == "A rusty lever is here." }
    assert_equal "lever", fact[:subject]
    assert_equal "item", fact[:kind]
  ensure
    wm&.shutdown!
  end

  def test_content_fact_extraction_runs_once_per_unique_content_not_per_sighting
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, [
      *move_lines(direction: "north", title: "Room A", exits: %w[s], contents: ["A rusty lever is here."]),
      *move_lines(direction: "east", title: "Room B", exits: %w[w], contents: ["A rusty lever is here."])
    ])

    calls = 0
    extractor = ->(_raw) { calls += 1; { subject: "lever", kind: "item", clause: nil, source: "llm" } }
    wm = build_map(content_fact_extractor: extractor)
    wm.refresh!

    wm.backfill_content_facts!
    wm.backfill_content_facts! # nothing left unclassified — extractor must not be called again

    assert_equal 1, calls
  end

  def test_content_fact_extraction_failure_falls_back_to_unknown_without_blocking
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "Room A", exits: %w[s], contents: ["A cityguard stands here."]))

    extractor = ->(_raw) { raise "ollama unreachable" }
    wm = build_map(content_fact_extractor: extractor)
    wm.refresh!
    wm.backfill_content_facts!

    fact = wm.discoveries.find { |d| d[:content] == "A cityguard stands here." }
    refute_nil fact
    assert_equal "unknown", fact[:kind]
  end

  def test_fallback_classifications_are_retried_on_a_later_pass_once_the_extractor_recovers
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "Room A", exits: %w[s], contents: ["A cityguard stands here."]))

    attempts = 0
    extractor = lambda do |_raw|
      attempts += 1
      raise "ollama unreachable" if attempts == 1

      { subject: "cityguard", kind: "npc", clause: nil, source: "llm" }
    end
    wm = build_map(content_fact_extractor: extractor)
    wm.refresh!

    wm.backfill_content_facts! # first pass: extractor raises, row stored as fallback/unknown
    first_pass = wm.discoveries.find { |d| d[:content] == "A cityguard stands here." }
    assert_equal "unknown", first_pass[:kind]
    assert_equal 1, attempts

    wm.backfill_content_facts! # second pass: extractor now succeeds — must retry, not skip
    second_pass = wm.discoveries.find { |d| d[:content] == "A cityguard stands here." }
    assert_equal "npc", second_pass[:kind]
    assert_equal "cityguard", second_pass[:subject]
    assert_equal 2, attempts
  end

  def test_successful_llm_classifications_are_never_retried_even_when_kind_is_unknown
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "Room A", exits: %w[s], contents: ["A strange glyph is here."]))

    attempts = 0
    # The model was reached and gave a real (if unhelpful) answer — this is
    # NOT the same as never having reached it, and must not be retried.
    extractor = lambda do |_raw|
      attempts += 1
      { subject: "glyph", kind: "unknown", clause: nil, source: "llm" }
    end
    wm = build_map(content_fact_extractor: extractor)
    wm.refresh!

    wm.backfill_content_facts!
    wm.backfill_content_facts!

    assert_equal 1, attempts
  end

  def test_a_persistently_failing_row_does_not_starve_other_unclassified_content
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, [
      *move_lines(direction: "north", title: "Room A", exits: %w[s], contents: ["Always fails."]),
      *move_lines(direction: "east", title: "Room B", exits: %w[w], contents: ["Always succeeds."])
    ])

    extractor = lambda do |raw|
      raise "nope" if raw == "Always fails."

      { subject: "thing", kind: "item", clause: nil, source: "llm" }
    end
    wm = build_map(content_fact_extractor: extractor)
    wm.refresh!

    # Two unclassified rows total; both must get a turn even though one of
    # them fails every time (previously: LIMIT 1 with no ordering could
    # keep re-picking the same failing row forever).
    2.times { wm.backfill_content_facts! }

    succeeded = wm.discoveries.find { |d| d[:content] == "Always succeeds." }
    failed = wm.discoveries.find { |d| d[:content] == "Always fails." }
    assert_equal "item", succeeded[:kind]
    assert_equal "unknown", failed[:kind]
  end

  # ---------- Description-embedded mentions (room_world_inspector.md,
  # "Follow-up: description-embedded mentions") ---------------------------
  #
  # Reproduces the reported bug directly: a room whose free-form
  # description narrates a "note" and "items on shelves" in prose — never
  # itemized as their own "X is here" line — so they never became
  # discoveries at all, only the two NPCs after `[ Exits: ]` did.
  # Single-spaced deliberately — RoomEcho.parse's `description` field runs
  # through `.squeeze(" ")`, so this must match its *post*-squeeze form for
  # the extractor stub's exact-string comparison below to actually fire.
  GENERAL_STORE_DESCRIPTION =
    "You are inside the general store. All sorts of items are stacked on shelves " \
    "behind the counter, safely out of your reach. A small note hangs on the wall."

  def general_store_mention_extractor
    lambda do |description|
      next { mentions: [], source: "llm" } unless description == GENERAL_STORE_DESCRIPTION

      {
        mentions: [
          { quote: "All sorts of items are stacked on shelves behind the counter, safely out of your reach.",
            subject: "shelves", kind: "scenery", clause: nil },
          { quote: "A small note hangs on the wall.", subject: "note", kind: "item", clause: "hangs on the wall" }
        ],
        source: "llm"
      }
    end
  end

  def test_description_mentions_are_backfilled_into_discoveries
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, [
      *move_lines(direction: "north", title: "The General Store", exits: %w[s],
                  description: GENERAL_STORE_DESCRIPTION,
                  contents: ["A Peacekeeper is standing here, ready to jump in at the first sign of trouble.",
                             "A grocer stands at the counter, with a slightly impatient look on his face."])
    ])

    wm = build_map(description_mention_extractor: general_store_mention_extractor)
    wm.refresh!
    wm.backfill_content_facts!
    wm.backfill_description_mentions!

    contents = wm.discoveries.map { |d| d[:content] }
    assert_includes contents, "A small note hangs on the wall."
    assert_includes contents, "All sorts of items are stacked on shelves behind the counter, safely out of your reach."
    assert_includes contents, "A Peacekeeper is standing here, ready to jump in at the first sign of trouble."
    assert_includes contents, "A grocer stands at the counter, with a slightly impatient look on his face."

    note = wm.discoveries.find { |d| d[:content] == "A small note hangs on the wall." }
    assert_equal "note", note[:subject]
    assert_equal "item", note[:kind]
    assert_equal ["The General Store"], note[:rooms]
  end

  def test_description_mentions_are_reachable_via_the_background_worker
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "The General Store", exits: %w[s],
                                  description: GENERAL_STORE_DESCRIPTION))

    extractor = ->(_raw) { { subject: "x", kind: "unknown", clause: nil, source: "llm" } } # no content lines to classify here
    wm = build_map(content_fact_worker: true, content_fact_extractor: extractor,
                    description_mention_extractor: general_store_mention_extractor)
    wm.refresh!

    wait_until { wm.discoveries.any? { |d| d[:content] == "A small note hangs on the wall." } }
  ensure
    wm&.shutdown!
  end

  def test_a_room_is_not_rescanned_once_successfully_scanned_even_with_zero_mentions
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "Empty Room", exits: %w[s], description: "Nothing here."))

    scans = 0
    extractor = lambda do |_desc|
      scans += 1
      { mentions: [], source: "llm" }
    end
    wm = build_map(description_mention_extractor: extractor)
    wm.refresh!

    wm.backfill_description_mentions!
    wm.backfill_description_mentions!

    assert_equal 1, scans
  end

  def test_a_failed_description_scan_is_retried_on_a_later_pass
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "The General Store", exits: %w[s],
                                  description: GENERAL_STORE_DESCRIPTION))

    attempts = 0
    extractor = lambda do |_desc|
      attempts += 1
      raise "ollama unreachable" if attempts == 1

      { mentions: [{ quote: "A small note hangs on the wall.", subject: "note", kind: "item", clause: nil }], source: "llm" }
    end
    wm = build_map(description_mention_extractor: extractor)
    wm.refresh!

    wm.backfill_description_mentions!
    refute_includes wm.discoveries.map { |d| d[:content] }, "A small note hangs on the wall."

    wm.backfill_description_mentions!
    assert_includes wm.discoveries.map { |d| d[:content] }, "A small note hangs on the wall."
    assert_equal 2, attempts
  end

  def test_rooms_with_a_blank_description_are_never_scanned
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "Room A", exits: %w[s], description: ""))

    scanned = false
    extractor = ->(_desc) { scanned = true; { mentions: [], source: "llm" } }
    wm = build_map(description_mention_extractor: extractor)
    wm.refresh!
    wm.backfill_description_mentions!

    refute scanned
  end

  # ---------- Examined-coverage tracking (room_world_inspector.md §2) ------

  def test_examine_marks_the_matching_content_fact_as_examined
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, [
      *move_lines(direction: "north", title: "Room A", exits: %w[s],
                  contents: ["A rusty lever is here.", "A cityguard stands here."]),
      *examine_lines(target: "lever", result: "It's a rusty iron lever.\r\n\r\n21H 100M 83V (news) (motd) > ")
    ])

    extractor = lambda do |raw|
      raw.include?("lever") ? { subject: "lever", kind: "item", clause: nil, source: "llm" }
                             : { subject: "cityguard", kind: "npc", clause: nil, source: "llm" }
    end
    wm = build_map(content_fact_extractor: extractor)
    wm.refresh!
    wm.backfill_content_facts!

    assert_equal ["lever"], wm.examined_in("Room A")
    assert_equal ["cityguard"], wm.unexamined_in("Room A")

    lever = wm.discoveries.find { |d| d[:content] == "A rusty lever is here." }
    cityguard = wm.discoveries.find { |d| d[:content] == "A cityguard stands here." }
    assert lever[:examined]
    refute cityguard[:examined]

    # The examine result itself must be recoverable, not just a yes/no flag
    # — otherwise a real clue in the reply text (an item's fine print, an
    # NPC's dialogue) is captured in `examinations.result_text` but never
    # surfaced anywhere. The trailing MUD status-prompt line must not leak
    # into it either (see RoomEcho.clean_reply).
    assert_equal "It's a rusty iron lever.", lever[:examination_result]
    assert_nil cityguard[:examination_result]
  end

  def test_examine_target_matches_a_content_fact_subject_by_substring_not_only_verbatim
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, [
      *move_lines(direction: "north", title: "Room A", exits: %w[s],
                  contents: ["A large fountain carved from blue-streaked marble is here, bubbling merrily."]),
      *examine_lines(target: "fountain", result: "A grand marble fountain.\r\n\r\n21H 100M 83V (news) (motd) > ")
    ])

    extractor = ->(_raw) { { subject: "large stone fountain", kind: "scenery", clause: nil, source: "llm" } }
    wm = build_map(content_fact_extractor: extractor)
    wm.refresh!
    wm.backfill_content_facts!

    assert_equal ["large stone fountain"], wm.examined_in("Room A"),
                 "typed target 'fountain' should substring-match extracted subject 'large stone fountain'"
  end

  def test_look_at_a_target_is_recorded_as_an_examination_not_a_room_revisit
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, [
      *move_lines(direction: "north", title: "Room A", exits: %w[s], contents: ["A cityguard stands here."]),
      *examine_lines(name: "tbamud__look", target: "cityguard", result: "A gruff-looking cityguard.\r\n\r\n21H 100M 83V (news) (motd) > ")
    ])

    extractor = ->(_raw) { { subject: "cityguard", kind: "npc", clause: nil, source: "llm" } }
    wm = build_map(content_fact_extractor: extractor)
    wm.refresh!
    wm.backfill_content_facts!

    assert_equal 1, wm.rooms.length, "a targeted look must not create/revisit a room"
    assert_equal ["cityguard"], wm.examined_in("Room A")
  end

  def test_examine_before_any_location_is_known_is_a_safe_no_op
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, examine_lines(target: "lever", result: "It's a rusty lever.\r\n\r\n21H 100M 83V (news) (motd) > "))

    wm = build_map
    wm.refresh! # must not raise despite no prior visit establishing a current room

    assert_empty wm.sessions.first[:last_room].to_s
  end

  # ---------- Settings.yaml-driven content_fact config ---------------------

  def test_default_extractor_reads_model_and_host_from_settings_yaml
    File.write(File.join(@tmp_dir, "settings.yaml"), <<~YAML)
      tasks:
        content_fact:
          provider: ollama
          model: qwen3:8b
          host: http://ollama.local:11434
    YAML

    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "Room A", exits: %w[s], contents: ["A rusty lever is here."]))

    # No content_fact_extractor injected — WorldMap must build its own from
    # LogViz::Settings, then call the real LogViz::ContentFact.extract.
    wm = build_map
    wm.refresh!

    captured = nil
    LogViz::ContentFact.stub(:extract, lambda { |raw, host:, model:| captured = { raw: raw, host: host, model: model }; { subject: "lever", kind: "item", clause: nil, source: "llm" } }) do
      wm.backfill_content_facts!
    end

    refute_nil captured
    assert_equal "qwen3:8b", captured[:model]
    assert_equal "http://ollama.local:11434", captured[:host]
    assert_equal "A rusty lever is here.", captured[:raw]
  end

  def test_default_extractor_falls_back_to_ollama_defaults_without_settings_yaml
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "Room A", exits: %w[s], contents: ["A rusty lever is here."]))

    wm = build_map
    wm.refresh!

    captured = nil
    LogViz::ContentFact.stub(:extract, lambda { |raw, host:, model:| captured = { host: host, model: model }; { subject: "lever", kind: "item", clause: nil, source: "llm" } }) do
      wm.backfill_content_facts!
    end

    assert_equal "gemma4", captured[:model]
    assert_equal "http://localhost:11434", captured[:host]
  end

  # ---------- Search/filter + pagination (room_world_inspector.md §4) ------

  def test_discoveries_filter_by_kind_q_and_room
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, move_lines(direction: "north", title: "Room A", exits: %w[s],
                                  contents: ["A rusty lever is here.", "A cityguard stands here."]))

    extractor = lambda do |raw|
      raw.include?("lever") ? { subject: "lever", kind: "item", clause: nil, source: "llm" }
                             : { subject: "cityguard", kind: "npc", clause: nil, source: "llm" }
    end
    wm = build_map(content_fact_extractor: extractor)
    wm.refresh!
    wm.backfill_content_facts!

    assert_equal ["A rusty lever is here."], wm.discoveries(kind: "item").map { |d| d[:content] }
    assert_equal ["A cityguard stands here."], wm.discoveries(q: "guard").map { |d| d[:content] }
    assert_equal 2, wm.discoveries(room: "Room A").length
    assert_empty wm.discoveries(room: "Room B")
    assert_equal ["A rusty lever is here."], wm.discoveries(examined: false, kind: "item").map { |d| d[:content] }
  end

  def test_discoveries_keyset_pagination_via_before_cursor
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, [
      *move_lines(direction: "north", title: "Room A", exits: %w[s], contents: ["Thing one is here."], at: "2026-01-01T00:00:01Z"),
      *move_lines(direction: "east", title: "Room B", exits: %w[w], contents: ["Thing two is here."], at: "2026-01-01T00:00:02Z"),
      *move_lines(direction: "south", title: "Room C", exits: %w[n], contents: ["Thing three is here."], at: "2026-01-01T00:00:03Z")
    ])

    wm = build_map
    wm.refresh!

    first_page = wm.discoveries(limit: 2)
    assert_equal ["Thing three is here.", "Thing two is here."], first_page.map { |d| d[:content] }

    second_page = wm.discoveries(limit: 2, before: first_page.last[:first_seen_at])
    assert_equal ["Thing one is here."], second_page.map { |d| d[:content] }
  end

  def test_rooms_matching_filters_by_title_or_description_substring
    path = File.join(@sessions_dir, "s1.jsonl")
    write_lines(path, [
      *move_lines(direction: "north", title: "The Temple Square", exits: %w[s]),
      *move_lines(direction: "east", title: "Dark Alley", exits: %w[w])
    ])

    wm = build_map
    wm.refresh!

    assert_equal ["The Temple Square"], wm.rooms_matching(q: "temple").map { |r| r[:title] }
    assert_equal 2, wm.rooms_matching.length
  end
end
