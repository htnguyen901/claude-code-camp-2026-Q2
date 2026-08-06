require_relative "helper"
require "log_viz/room_echo"

# Fixtures below are the real captured strings cited in
# docs/plans/observability/player_journey_map.md §1 — pulled from actual
# `.boukensha/sessions/*.jsonl` tool_result text, not synthesized.
class TestRoomEcho < Minitest::Test
  MOVE_RESULT = "\e[0;33mBehind The Temple Altar\e[0m\r\n   You are on a dirt " \
                "path leading away from the Temple Altar which is south\r\n" \
                "of here.  To the north, the path continues through the lush\r\n" \
                "contryside of Midgaard towards the Dragonhelm Mountains far\r\n" \
                "off to the north.\r\n\e[0;36m[ Exits: n s ]\e[0m\r\n\r\n" \
                "22H 100M 84V (news) (motd) > "

  ROOM_WITH_CONTENTS = "\e[0;33mThe Temple Square\e[0m\r\n   You are standing on the temple square.  Huge marble " \
                       "steps lead up to the\r\ntemple gate.  The entrance to the Clerics' Guild is to the west, " \
                       "and the old\r\nGrunting Boar Inn, is to the east.  Just south of here you see the market\r\n" \
                       "square, the center of Midgaard.\r\n\e[0;36m[ Exits: n e s w ]\e[0m\r\n" \
                       "\x1b[0;32m\x1b[0;32mA large fountain carved from blue-streaked marble is here, bubbling merrily.\r\n" \
                       "\x1b[0m\x1b[0;33mA Peacekeeper is standing here, ready to jump in at the first sign of trouble.\r\n" \
                       "\x1b[0m\r\n22H 100M 81V (news) (motd) > "

  FAILED_MOVE = "Alas, you cannot go that way...\r\n\r\n21H 100M 83V (news) (motd) > "

  MISATTRIBUTED_RESULT = "Look at what?\r\n\r\n500H 100M 82V (news) (motd) > "

  DARK_ROOM = "It is pitch black...\r\n\r\n21H 100M 79V (news) (motd) > "

  # Real logged example: CircleMUD prepends an uncolored zone-warning
  # banner directly in front of the actual room echo, no blank line
  # separating them. The title must still resolve to the real room name,
  # not "This zone is above your recommended level."
  ZONE_WARNING_PREFIXED = "This zone is above your recommended level.\r\n\e[0;33mThe City Entrance\e[0m\r\n" \
                          "   You stand on the outskirts of a large city - Midgaard; the capital of\r\n" \
                          "this land.  The road leads east into the peace and quiet - and dangers -\r\n" \
                          "of the forest; and to the west it becomes the main street of the town;\r\n" \
                          "surrounded by a confusion of shops, bars, and market places.\r\n" \
                          "\e[0;36m[ Exits: e w ]\e[0m\r\n\r\n(news) (motd) > "

  def test_parses_title_description_and_exits
    parsed = LogViz::RoomEcho.parse(MOVE_RESULT)

    refute_nil parsed
    assert_equal "Behind The Temple Altar", parsed[:title]
    assert_equal %w[n s], parsed[:exits]
    assert_includes parsed[:description], "dirt path leading away"
    assert_empty parsed[:contents]
  end

  def test_parses_room_contents_lines
    parsed = LogViz::RoomEcho.parse(ROOM_WITH_CONTENTS)

    refute_nil parsed
    assert_equal "The Temple Square", parsed[:title]
    assert_equal %w[n e s w], parsed[:exits]
    assert_equal [
      "A large fountain carved from blue-streaked marble is here, bubbling merrily.",
      "A Peacekeeper is standing here, ready to jump in at the first sign of trouble."
    ], parsed[:contents]
  end

  def test_failed_move_parses_to_nil
    assert_nil LogViz::RoomEcho.parse(FAILED_MOVE)
  end

  def test_misattributed_non_room_result_parses_to_nil
    # Real logged example of a tool_call/tool_result pairing that doesn't
    # match its own call's intent (see player_journey_map.md Background) —
    # the parser must fail closed rather than guess.
    assert_nil LogViz::RoomEcho.parse(MISATTRIBUTED_RESULT)
  end

  def test_dark_room_parses_to_nil
    assert_nil LogViz::RoomEcho.parse(DARK_ROOM)
  end

  def test_zone_warning_banner_is_not_mistaken_for_the_title
    parsed = LogViz::RoomEcho.parse(ZONE_WARNING_PREFIXED)

    refute_nil parsed
    assert_equal "The City Entrance", parsed[:title]
    assert_equal %w[e w], parsed[:exits]
    refute_includes parsed[:description], "recommended level"
  end

  def test_location_tool_matches_allowlist_regardless_of_mcp_prefix
    %w[tbamud__look tbamud__move tbamud__enter tbamud__leave tbamud__flee].each do |name|
      assert LogViz::RoomEcho.location_tool?(name), "expected #{name} to be location-revealing"
    end
  end

  def test_location_tool_excludes_everything_else
    %w[tbamud__info_self tbamud__consider tbamud__examine tbamud__cast tbamud__track].each do |name|
      refute LogViz::RoomEcho.location_tool?(name), "expected #{name} to NOT be location-revealing"
    end
  end

  def test_clean_reply_strips_ansi_blank_lines_and_the_status_prompt
    raw = "\e[0;32mIt's a rusty iron lever.\e[0m\r\n\r\n21H 100M 83V (news) (motd) > "

    assert_equal "It's a rusty iron lever.", LogViz::RoomEcho.clean_reply(raw)
  end

  def test_clean_reply_joins_a_multi_line_reply_with_spaces
    raw = "A grocer stands at the counter,\r\nwith a slightly impatient look on his face.\r\n\r\n" \
          "22H 100M 84V (news) (motd) > "

    assert_equal "A grocer stands at the counter, with a slightly impatient look on his face.",
                 LogViz::RoomEcho.clean_reply(raw)
  end
end
