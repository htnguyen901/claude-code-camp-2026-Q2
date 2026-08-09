require "yaml"

module Boukensha
  # Loads one `.boukensha/players/*.yaml` profile — the runtime counterpart
  # to docs/plans/observability/players/players_seeding.md's character
  # creation. Read-only: this never writes a player file, it just resolves
  # "--player noir" to the credentials/persona already seeded there.
  class PlayerProfile
    attr_reader :name, :password, :sex, :player_class, :admin, :persona

    def self.load(name, players_dir:)
      path = File.join(players_dir, "#{name}.yaml")
      abort "boukensha: no player profile at #{path} (run seed_players, or check the name)" unless File.exist?(path)

      raw = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
      new(raw)
    rescue Psych::SyntaxError => e
      abort "boukensha: invalid YAML in #{path}: #{e.message}"
    end

    def initialize(raw)
      @name         = raw["name"]
      @password     = raw["password"]
      @sex          = raw["sex"]
      @player_class = raw["class"]
      @admin        = !!raw["admin"]
      @persona      = raw["persona"] || {}
    end

    def to_s
      "#<Boukensha::PlayerProfile name=#{@name}>"
    end

    def inspect = to_s
  end
end
