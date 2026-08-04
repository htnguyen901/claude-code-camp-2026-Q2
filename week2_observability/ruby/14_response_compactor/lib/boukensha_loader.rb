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
# Examples:
#   boukensha                                                              # uses bundled lib + ~/.boukensha
#   BOUKENSHA_PATH=~/Sites/boukensha/04_api_client boukensha              # loads step 4
#   BOUKENSHA_DIR=~/projects/mybot/.boukensha boukensha                   # custom config dir
#   boukensha --no-tui                                                     # plain REPL, no TUI
require "yaml"
require_relative "boukensha/world_knowledge"

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

    # Everything else the agent can do still comes from settings.yaml's
    # `mcp_servers:` block — the MUD is still just a server, unchanged.
    # `room_knowledge` is the one exception (docs/plans/observability/
    # room_world_inspector.md §3): a small, local, read-only tool over
    # log_viz's own world_map.sqlite3 (content_facts/examinations),
    # registered here via the same RunDSL block every other `Boukensha.run`/
    # `.repl` caller can use — it doesn't talk to the MUD, so it doesn't
    # belong in settings.yaml's mcp_servers list. The agent decides on its
    # own whether calling it is useful; nothing injects its result
    # automatically.
    #
    # Note this drops the old MUD_* env override. A spawned server inherits
    # this process's environment, so exporting MUD_HOST still reaches the
    # daemon, but only for keys its `env:` block doesn't set: config now wins
    # over the environment, where it used to lose.
    Boukensha.repl(tui: !no_tui) do
      tool "room_knowledge",
           description: "Check which items/mobs/NPCs/scenery in a room you've already " \
                         "examined (via examine/look at) versus not yet, based on your own " \
                         "past exploration history. Each examined entry includes the actual " \
                         "text the room printed back — reuse that as a remembered clue " \
                         "instead of spending a turn re-examining it. This is a passive " \
                         "record, not a live scan — use the unexamined list to decide " \
                         "whether it's worth going back to inspect something you noticed but " \
                         "never looked at closely.",
           parameters: {
             room_title: { type: "string",
                           description: "The exact room title, as it appeared in your most recent look/move result (e.g. 'The Temple Square')." }
           } do |room_title:|
        Boukensha::WorldKnowledge.room_knowledge(room_title: room_title)
      end
    end
  end
end
