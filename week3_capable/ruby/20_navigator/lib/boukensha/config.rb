require "yaml"
require "dotenv"
require "pathname"

module Boukensha
  class Config
    # The .boukensha config directory is resolved in this order:
    #   1. BOUKENSHA_DIR environment variable (set before loading .env)
    #   2. ~/.boukensha  (default)
    DEFAULT_DIR = File.join(Dir.home, ".boukensha").freeze

    # Default prompts shipped alongside this step.
    PROMPTS_DIR = File.expand_path("../../prompts", __dir__).freeze

    attr_reader :dir, :settings

    def initialize
      @dir = resolve_dir
      load_env
      @settings = load_settings
    end

    # ---------- tasks -----------------------------------------------------

    # With no argument: returns the full tasks hash from settings.yaml.
    # With a name: returns that task's settings hash, e.g. tasks(:player).
    def tasks(name = nil)
      all = dig(:tasks) || {}
      name ? (all[name.to_s] || all[name.to_sym]) : all
    end

    # The user's prompts directory for task prompt overrides.
    def user_prompts_dir
      File.join(@dir, "prompts")
    end

    # ---------- provider --------------------------------------------------

    def provider_type
      dig(:tasks, :player, :provider) || "anthropic"
    end

    def model
      dig(:tasks, :player, :model) || "claude-haiku-4-5"
    end

    # ---------- MCP servers ------------------------------------------------

    # MCP servers to plug into the agent, keyed by name. This is where ALL of
    # the agent's tools come from — boukensha ships none of its own:
    #
    #   mcp_servers:
    #     mud:
    #       command: mud-manager
    #       args:    [--mcp]
    #       prefix:  tbamud
    #       env:
    #         MUD_HOST: your.mud.host      # a stdio server's credentials
    #         MUD_NAME: Gandalf            # travel by environment
    #
    # Returns { "mud" => { command:, args:, env:, prefix:, required: } } with
    # defaults applied. `required: false` lets a server fail to spawn without
    # taking the agent down with it.
    def mcp_servers
      (dig(:mcp_servers) || {}).each_with_object({}) do |(name, raw), out|
        entry = raw.is_a?(Hash) ? raw : {}
        get   = ->(k) { entry[k.to_s].nil? ? entry[k.to_sym] : entry[k.to_s] }
        req   = get.call(:required)

        out[name.to_s] = {
          command:  get.call(:command).to_s,
          args:     Array(get.call(:args)).map(&:to_s),
          env:      (get.call(:env) || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s },
          prefix:   get.call(:prefix)&.to_s,
          required: req.nil? ? true : !!req
        }
      end
    end

    # ---------- tool policy -------------------------------------------------
    # Named, reusable glob sets a task can pull in via `tasks.<name>.tools:
    # { role: <name> }` (see Tasks::Base.tool_policy and Boukensha::ToolPolicy)
    # instead of every task's settings.yaml block repeating similar glob
    # lists — see docs/plans/tools_policy/permission.md, Option C.
    #
    #   tool_roles:
    #     readonly: [tbamud__look, tbamud__examine, room_knowledge]
    #     full:     ["*"]
    #
    # Returns { "readonly" => ["tbamud__look", ...], "full" => ["*"] }.
    # Absent block / a role's value that isn't an array both come back as [].
    def tool_roles
      (dig(:tool_roles) || {}).each_with_object({}) do |(name, globs), out|
        out[name.to_s] = Array(globs).map(&:to_s)
      end
    end

    # ---------- agent limits ----------------------------------------------
    # Static per-turn circuit breakers, read where the agent is constructed.
    # A value of 0 or nil means "disabled" (no ceiling) — useful for debugging.

    def agent_max_iterations
      v = dig(:agent, :max_iterations)
      v.nil? ? 25 : Integer(v)
    end

    def agent_max_output_tokens
      v = dig(:agent, :max_output_tokens)
      v.nil? ? 1024 : Integer(v)
    end

    def agent_max_turn_tokens
      v = dig(:agent, :max_turn_tokens)
      v.nil? ? 60_000 : Integer(v)
    end

    def agent_compaction_threshold
      v = dig(:agent, :compaction_threshold)
      v.nil? ? 0.85 : Float(v)
    end

    # ---------- Planner ------------------------------------------------------
    # Reads `tasks.planner.enabled`. Unlike compactor_enabled? below, this
    # defaults ON: docs/plans/agent_loop/high_level_agentic_loop_design.md's
    # "Alternative B" (Planner/Judge disabled by default) was the original
    # call, explicitly reversed — see that doc's "Decision reversal" note and
    # docs/plans/agent_loop/repl_planner_integration.md. Set
    # `tasks.planner.enabled: false` to opt back out (no Ruby-level kwarg for
    # this — same "config is the toggle" convention compactor_enabled?/
    # observability_enabled? already use).
    def planner_enabled?
      v = dig(:tasks, :planner, :enabled)
      v.nil? ? true : !!v
    end

    # ---------- Judge -------------------------------------------------------
    # Reads `tasks.judge.enabled`. Defaults ON, same reasoning and same
    # convention as planner_enabled? above — see
    # docs/plans/agent_loop/repl_judge_integration.md. Set
    # `tasks.judge.enabled: false` to opt back out.
    def judge_enabled?
      v = dig(:tasks, :judge, :enabled)
      v.nil? ? true : !!v
    end

    # ---------- MUD tool-result compactor ----------------------------------
    # Reads `tasks.compactor` (see Boukensha::Compactor). Tiers 0/1 (noise
    # stripping, structure-aware trim) always run; `compactor_enabled?` gates
    # only Tier 2, the opt-in LLM-based prose rewrite — default off until
    # evaluated, per the plan.

    def compactor_enabled?
      v = dig(:tasks, :compactor, :enabled)
      v.nil? ? false : !!v
    end

    def compactor_provider
      dig(:tasks, :compactor, :provider) || "ollama"
    end

    def compactor_model
      dig(:tasks, :compactor, :model) || Compactor::DEFAULT_MODEL
    end

    def compactor_host
      dig(:tasks, :compactor, :host) || Compactor::DEFAULT_HOST
    end

    def compactor_min_chars
      v = dig(:tasks, :compactor, :min_chars)
      v.nil? ? Compactor::DEFAULT_MIN_CHARS : Integer(v)
    end

    # ---------- observability (OpenTelemetry traces/metrics) --------------
    # Reads `observability.enabled` (see Boukensha::Telemetry). Default is
    # ON — this is a fail-open, zero-config-needed feature (no collector
    # running just means spans/metrics are dropped, per Telemetry's header
    # comment), unlike compactor_enabled? above which defaults OFF because
    # Tier 2 is an unevaluated behavior change, not inert instrumentation.
    def observability_enabled?
      v = dig(:observability, :enabled)
      v.nil? ? true : !!v
    end

    # ---------- low-level helpers -----------------------------------------

    # Fetch a nested key path from settings, e.g. dig(:provider, :model).
    # Checks presence with `key?`, not `||` — an explicit `false` value (e.g.
    # `observability.enabled: false`) is itself falsy, so `node[k] ||
    # node[k.to_sym]` would wrongly fall through and read back as "unset".
    def dig(*keys)
      keys.reduce(@settings) do |node, key|
        case node
        when Hash then node.key?(key.to_s) ? node[key.to_s] : node[key.to_sym]
        else nil
        end
      end
    end

    def to_s
      "#<Boukensha::Config dir=#{@dir} provider=#{provider_type} model=#{model}>"
    end

    def inspect = to_s

    private

    def resolve_dir
      raw = ENV.fetch("BOUKENSHA_DIR", nil) || DEFAULT_DIR
      Pathname.new(raw).expand_path.to_s
    end

    def load_env
      env_file = File.join(@dir, ".env")
      if File.exist?(env_file)
        Dotenv.load(env_file)
      end
    end

    def load_settings
      settings_file = File.join(@dir, "settings.yaml")
      if File.exist?(settings_file)
        YAML.safe_load(File.read(settings_file)) || {}
      else
        {}
      end
    end
  end
end
