require_relative "lib/boukensha/version"

Gem::Specification.new do |spec|
  spec.name        = "boukensha"
  spec.version     = Boukensha::VERSION
  spec.summary     = "BOUKENSHA — a tiny teaching framework for coding harnesses"
  spec.description = "Step-by-step coding harness framework. " \
                     "Set BOUKENSHA_PATH to load a specific lesson step, " \
                     "or run with defaults to use the bundled release."
  spec.authors     = ["Andrew Brown"]
  spec.email       = ["andrew@exampro.co"]
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.0"

  # All files tracked in git, plus the bin/ executable.
  spec.files = Dir["lib/**/*.rb"] + ["bin/boukensha"]

  spec.bindir      = "bin"
  spec.executables = ["boukensha"]

  # MCP servers bring their own dependencies; boukensha itself needs only
  # `charm`, for the TUI (bubbletea + lipgloss + bubbles bindings), plus
  # OpenTelemetry for Boukensha::Telemetry (lib/boukensha/telemetry.rb) —
  # unconditionally required by lib/boukensha.rb, so these must be real gem
  # dependencies, not just Gemfile entries, for `gem install` (see README's
  # Build section) to work outside this repo's bundle.
  spec.add_dependency "charm"
  spec.add_dependency "opentelemetry-api", "~> 1.11"
  spec.add_dependency "opentelemetry-sdk", "~> 1.13"
  spec.add_dependency "opentelemetry-exporter-otlp", "~> 0.34"
  spec.add_dependency "opentelemetry-metrics-sdk", "~> 0.15"
  spec.add_dependency "opentelemetry-exporter-otlp-metrics", "~> 0.10"

  # open3, net/http, and json are stdlib. Users supply their own ANTHROPIC_API_KEY.
end
