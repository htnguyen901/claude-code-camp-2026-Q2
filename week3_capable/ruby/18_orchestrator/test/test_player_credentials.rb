require_relative "helper"
require "boukensha/player_profile"

# Boukensha.overlay_player_credentials (lib/boukensha.rb) — the mechanism
# that lets `boukensha --player NAME` log in as a different character than
# whatever settings.yaml's mcp_servers.*.env declares, without either
# hardcoding a server name or inventing env keys a server never asked for.
# See docs/plans/observability/players/multiple_concurrent_players.md §1.
class TestPlayerCredentials < Minitest::Test
  def player(name: "noir", password: "shadowveil")
    Boukensha::PlayerProfile.new({ "name" => name, "password" => password })
  end

  def test_overlays_name_and_password_onto_a_server_that_declares_those_keys
    servers = {
      "mud" => { command: "mud-manager", args: [], prefix: nil, required: true,
                 env: { "MUD_HOST" => "localhost", "MUD_PORT" => "4000",
                        "MUD_NAME" => "", "MUD_PASSWORD" => "" } }
    }

    Boukensha.send(:overlay_player_credentials, servers, player)

    assert_equal "noir", servers["mud"][:env]["MUD_NAME"]
    assert_equal "shadowveil", servers["mud"][:env]["MUD_PASSWORD"]
    assert_equal "localhost", servers["mud"][:env]["MUD_HOST"], "unrelated keys are untouched"
  end

  def test_does_not_invent_keys_a_server_never_declared
    servers = { "filesystem" => { command: "npx", args: [], prefix: nil, required: false, env: {} } }

    Boukensha.send(:overlay_player_credentials, servers, player)

    assert_equal({}, servers["filesystem"][:env])
  end

  def test_overlays_every_matching_server_not_just_one_named_mud
    servers = {
      "mud_a" => { command: "a", args: [], prefix: nil, required: true, env: { "MUD_NAME" => "", "MUD_PASSWORD" => "" } },
      "mud_b" => { command: "b", args: [], prefix: nil, required: true, env: { "MUD_NAME" => "", "MUD_PASSWORD" => "" } }
    }

    Boukensha.send(:overlay_player_credentials, servers, player(name: "dina", password: "hex"))

    assert_equal "dina", servers["mud_a"][:env]["MUD_NAME"]
    assert_equal "dina", servers["mud_b"][:env]["MUD_NAME"]
  end

  def test_nil_player_changes_nothing
    servers = { "mud" => { command: "mud-manager", args: [], prefix: nil, required: true,
                            env: { "MUD_NAME" => "dummy", "MUD_PASSWORD" => "helloworld" } } }

    Boukensha.send(:overlay_player_credentials, servers, nil)

    assert_equal "dummy", servers["mud"][:env]["MUD_NAME"]
    assert_equal "helloworld", servers["mud"][:env]["MUD_PASSWORD"]
  end
end
