require_relative "lib/log_viz/version"

Gem::Specification.new do |spec|
  spec.name        = "log_viz"
  spec.version     = LogViz::VERSION
  spec.summary     = "LogViz — session-log viewer and accumulated world-map MCP server for boukensha"
  spec.description = "Turns Boukensha::Logger's .jsonl session logs into a browsable transcript " \
                     "and an accumulated, cross-session world map (a Sinatra app, `bin/log_viz`), " \
                     "and hosts that same world map as an MCP server (`log_viz --mcp`) exposing " \
                     "room_knowledge/route_to — read-only, per-player-scoped room-knowledge and " \
                     "pathfinding tools any MCP host, in any language, can call without " \
                     "reimplementing the world_map.sqlite3 schema."
  spec.authors     = ["Andrew Brown"]
  spec.email       = ["andrew@exampro.co"]
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.0"

  spec.files       = Dir["lib/**/*.rb"] + Dir["views/**/*"] + Dir["public/**/*"] + ["bin/log_viz"]
  spec.bindir      = "bin"
  spec.executables = ["log_viz"]

  # sqlite3 is needed by both entry points (WorldMap). sinatra/rackup/puma
  # are only exercised by the web-app path (`log_viz`, no --mcp) — declared
  # here anyway so `gem install`-ing this package leaves both entry points
  # usable, not just the one `mcp_servers:` cares about.
  spec.add_dependency "sqlite3"
  spec.add_dependency "sinatra"
  spec.add_dependency "rackup"
  spec.add_dependency "puma"
end
