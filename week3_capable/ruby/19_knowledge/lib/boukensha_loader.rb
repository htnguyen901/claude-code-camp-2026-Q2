# BoukenshaLoader resolves which step folder and config directory to use, then
# boots the REPL.
#
# Each setting is resolved independently in this order:
#   1. BOUKENSHA_PATH / BOUKENSHA_DIR environment variable
#   2. boukensha_path / boukensha_dir in ~/.boukensharc
#   3. The bundled lib / ~/.boukensha default
#
# ~/.boukensharc is YAML:
#   boukensha_path: ~/Sites/boukensha/09_global_executable
#   boukensha_dir: ~/projects/mybot/.boukensha
# A bare single-line path (the pre-step-9 format) is still accepted and is
# treated as boukensha_path.
#
# --no-tui falls back to the plain terminal REPL (no charm-ruby).
#
# --player NAME (or BOUKENSHA_PLAYER=NAME, CLI wins if both given) logs in
# as that .boukensha/players/NAME.yaml profile instead of settings.yaml's
# static mcp_servers.mud.env credentials — see docs/plans/observability/
# players/multiple_concurrent_players.md §1. Omit it and nothing changes:
# no player-specific credentials are overlaid, and world__room_knowledge/
# world__route_to fall back to their historical un-scoped behavior.
#
# Examples:
#   boukensha                                                              # uses bundled lib + ~/.boukensha
#   BOUKENSHA_PATH=~/Sites/boukensha/04_api_client boukensha              # loads step 4
#   BOUKENSHA_DIR=~/projects/mybot/.boukensha boukensha                   # custom config dir
#   boukensha --no-tui                                                     # plain REPL, no TUI
#   boukensha --player noir                                                # log in as noir.yaml
require "yaml"
require_relative "boukensha/player_profile"

module BoukenshaLoader
  # Absolute path to this gem's own bundled boukensha lib.
  BUNDLED_LIB = File.expand_path("../boukensha.rb", __FILE__)

  def self.rc_file
    File.expand_path("~/.boukensharc")
  end

  def self.load_rc
    return {} unless File.exist?(rc_file)

    parsed = YAML.safe_load(
      File.read(rc_file),
      permitted_classes: [],
      aliases: false
    )

    case parsed
    when Hash
      parsed
    when String
      # Backward compatibility with the original single-path format.
      { "boukensha_path" => parsed }
    when nil
      {}
    else
      abort "boukensha: #{rc_file} must contain a YAML mapping"
    end
  rescue Psych::SyntaxError => e
    abort "boukensha: invalid YAML in #{rc_file}: #{e.message}"
  end

  def self.expand_rc_path(path)
    return nil unless path.is_a?(String)
    return nil if path.strip.empty?

    File.expand_path(path, File.dirname(rc_file))
  end

  def self.resolve
    rc = load_rc

    # Apply this before requiring the selected implementation. An explicit
    # environment variable always wins over the rc file.
    rc_config_dir = expand_rc_path(rc["boukensha_dir"])
    ENV["BOUKENSHA_DIR"] = rc_config_dir if !ENV["BOUKENSHA_DIR"] && rc_config_dir

    source = ENV["BOUKENSHA_PATH"] || expand_rc_path(rc["boukensha_path"])
    return BUNDLED_LIB unless source

    dir = File.expand_path(source)
    main = File.join(dir, "lib", "boukensha.rb")
    return main if File.exist?(main)

    abort <<~MSG
      boukensha: no lib/boukensha.rb found at:
             #{dir}
             Check BOUKENSHA_PATH or #{rc_file}.
    MSG
  end

  def self.load_and_start_repl
    main = resolve
    step_dir = File.dirname(File.dirname(main))

    puts "[boukensha] loading from: #{step_dir}" if ENV["BOUKENSHA_DEBUG"]

    require main

    player = resolve_player

    unless Boukensha.respond_to?(:repl)
      abort <<~MSG
        boukensha: the step at #{step_dir}
               does not support the interactive REPL (added in step 7).
               Run its examples directly, e.g.:
                 ruby #{step_dir}/examples/*.rb
               Or point BOUKENSHA_PATH at step 7 or later.
      MSG
    end

    # --no-tui falls back to the plain terminal REPL (no charm-ruby).
    no_tui = ARGV.delete("--no-tui")

    # Everything the agent can do comes from settings.yaml's `mcp_servers:`
    # block — the MUD is one server, `log_viz --mcp` (world__room_knowledge/
    # world__route_to) is another, boukensha itself ships no tools of its
    # own. Before this step, `room_knowledge` was a local exception —
    # hand-registered here because it "doesn't talk to the MUD" — but a
    # small, local, read-only Ruby method was never the actual reason: it's
    # now `log_viz`'s own MCP server (docs/plans/world_knowledge/
    # world_knowledge.md), same as `mud`, so it needs no special-casing
    # here at all.
    #
    # Note this drops the old MUD_* env override. A spawned server inherits
    # this process's environment, so exporting MUD_HOST still reaches the
    # daemon, but only for keys its `env:` block doesn't set: config now wins
    # over the environment, where it used to lose.
    Boukensha.repl(tui: !no_tui, player: player)
  end

  # CLI wins over BOUKENSHA_PLAYER if both are given — same precedence
  # convention as BOUKENSHA_PATH/BOUKENSHA_DIR above. Returns nil (not an
  # error) when neither is set: an omitted --player is a supported mode,
  # just one that prints a notice so it's never ambiguous which character
  # (if any) a given run is logged in as.
  def self.resolve_player
    name = extract_player_flag || ENV["BOUKENSHA_PLAYER"]

    unless name
      puts "[boukensha] no --player given — running without player-specific MUD credentials"
      return nil
    end

    players_dir = File.join(Boukensha.config.dir, "players")
    Boukensha::PlayerProfile.load(name, players_dir: players_dir)
  end

  def self.extract_player_flag
    idx = ARGV.index("--player")
    return nil unless idx

    ARGV.delete_at(idx)
    ARGV.delete_at(idx) # the value right after the flag
  end
end
