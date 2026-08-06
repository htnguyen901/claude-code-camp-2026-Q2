require_relative "boukensha/version"
require_relative "boukensha/config"
require_relative "boukensha/tasks/player"

module Boukensha
  @quiet  = false
  @debug  = false
  @config = nil

  def self.config
    @config ||= Config.new
  end

  # OpenTelemetry tracer/meter — see Boukensha::Telemetry for setup and the
  # fail-open guarantee. Safe to call unconditionally from any call site:
  # with the collector down, `observability.enabled: false`, or a broken
  # metrics gem, these still return a usable (no-op) instance.
  def self.tracer
    Telemetry.tracer
  end

  def self.meter
    Telemetry.meter
  end

  def self.quiet!
    @quiet = true
  end

  def self.loud!
    @quiet = false
  end

  def self.quiet?
    @quiet
  end

  def self.debug!
    @debug = true
  end

  def self.debug?
    @debug
  end

  # One-shot run: send a single task, get a response, return.
  #
  # The agent ships with NO tools of its own. Every tool it can call arrives
  # over an MCP connection, declared in settings.yaml's `mcp_servers:` block
  # (see Boukensha::Config#mcp_servers). Want file access? Point at a
  # filesystem MCP server. Want to play a MUD? Point at `mud-manager --mcp`.
  # Boukensha is the host; the servers own the tools.
  #
  # working_dir:      Recorded on the Context as the agent's notion of "where
  #                   it is". It registers nothing — an MCP server that touches
  #                   the filesystem is rooted by its own spawn args.
  # player:           A Boukensha::PlayerProfile (see boukensha_loader.rb's
  #                   --player flag), or nil. When given, its name/password
  #                   overlay any mcp_servers entry whose env: block already
  #                   declares MUD_NAME/MUD_PASSWORD, before servers spawn —
  #                   see docs/plans/observability/players/
  #                   multiple_concurrent_players.md §1. nil (the default)
  #                   changes nothing: settings.yaml's own env: wins, exactly
  #                   as before this kwarg existed.
  def self.run(
    task:,
    system:           nil,
    model:            nil,
    backend:          nil,
    api_key:          nil,
    ollama_host:      "http://localhost:11434",
    log:              nil,
    context_window:   nil,
    max_output_tokens: nil,
    working_dir:      Dir.pwd,
    player:           nil,
    &block
  )
    cfg           = config                           # loads .env; populates ENV
    task_class    = Tasks::Player
    task_settings = cfg.tasks(task_class.task_name)
    system      ||= task_class.system_prompt(task_settings, user_prompts_dir: cfg.user_prompts_dir, default_prompts_dir: Config::PROMPTS_DIR)
    model       ||= task_class.model(task_settings)
    backend     ||= task_class.provider(task_settings).to_sym
    context_window ||= Models.context_window(model)
    api_key ||= resolve_api_key(backend)

    ctx      = Context.new(system: system, context_window: context_window, working_dir: working_dir, compaction_threshold: cfg.agent_compaction_threshold)
    policy   = task_class.tool_policy(task_settings, tool_roles: cfg.tool_roles)
    registry = Registry.new(ctx, policy: policy)

    servers = cfg.mcp_servers
    overlay_player_credentials(servers, player)
    register_mcp_servers(registry, cfg, servers: servers)
    compactor = build_compactor(cfg)

    RunDSL.new(registry).instance_eval(&block) if block

    be      = build_backend(backend, model: model, api_key: api_key, ollama_host: ollama_host)
    builder = PromptBuilder.new(ctx, be)
    client  = Client.new(builder)
    # Construct the tracer/meter providers once, up front, so the rest of the
    # run reuses the same (memoized) configured providers — see
    # Boukensha::Telemetry — and so their config is known before it's read
    # into the snapshot below.
    tracer
    meter
    logger  = Logger.new(log: log, snapshot: {
      max_iterations:         cfg.agent_max_iterations,
      max_turn_tokens:        cfg.agent_max_turn_tokens,
      max_output_tokens:      (max_output_tokens || cfg.agent_max_output_tokens),
      context_window:         context_window,
      model:                  model,
      provider:               backend,
      task:                   task_class.task_name,
      player:                 player&.name,
      observability_enabled:  cfg.observability_enabled?,
      otel_service_name:      ENV["OTEL_SERVICE_NAME"],
      otel_endpoint:          ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]
    })
    agent   = Agent.new(context: ctx, registry: registry, builder: builder, client: client, logger: logger,
                        compactor: compactor, task_name: task_class.task_name,
                        max_iterations: cfg.agent_max_iterations,
                        max_turn_tokens: cfg.agent_max_turn_tokens,
                        max_output_tokens: (max_output_tokens || cfg.agent_max_output_tokens))

    ctx.add_message(:user, task)
    agent.run
  ensure
    logger&.close
  end

  # Interactive REPL — see Boukensha.run for full option documentation
  # (including player:).
  #
  # tui: true (default) wraps the REPL in a charm-ruby TUI.  Pass tui: false or
  # use the --no-tui CLI flag to fall back to the plain terminal REPL.
  def self.repl(
    system:           nil,
    model:            nil,
    backend:          nil,
    api_key:          nil,
    ollama_host:      "http://localhost:11434",
    log:              nil,
    context_window:   nil,
    max_output_tokens: nil,
    working_dir:      Dir.pwd,
    tui:              true,
    player:           nil,
    &block
  )
    cfg           = config                           # loads .env; populates ENV
    task_class    = Tasks::Player
    task_settings = cfg.tasks(task_class.task_name)
    system      ||= task_class.system_prompt(task_settings, user_prompts_dir: cfg.user_prompts_dir, default_prompts_dir: Config::PROMPTS_DIR)
    model       ||= task_class.model(task_settings)
    backend     ||= task_class.provider(task_settings).to_sym
    context_window ||= Models.context_window(model)
    api_key ||= resolve_api_key(backend)

    ctx      = Context.new(system: system, context_window: context_window, working_dir: working_dir, compaction_threshold: cfg.agent_compaction_threshold)
    policy   = task_class.tool_policy(task_settings, tool_roles: cfg.tool_roles)
    registry = Registry.new(ctx, policy: policy)

    mcp_servers = cfg.mcp_servers
    overlay_player_credentials(mcp_servers, player)
    servers   = register_mcp_servers(registry, cfg, servers: mcp_servers)
    compactor = build_compactor(cfg)

    RunDSL.new(registry).instance_eval(&block) if block

    be      = build_backend(backend, model: model, api_key: api_key, ollama_host: ollama_host)
    builder = PromptBuilder.new(ctx, be)
    client  = Client.new(builder)
    # See Boukensha.run for why tracer/meter are constructed here, up front.
    tracer
    meter
    logger  = Logger.new(log: log, snapshot: {
      max_iterations:         cfg.agent_max_iterations,
      max_turn_tokens:        cfg.agent_max_turn_tokens,
      max_output_tokens:      (max_output_tokens || cfg.agent_max_output_tokens),
      context_window:         context_window,
      model:                  model,
      provider:               backend,
      task:                   task_class.task_name,
      player:                 player&.name,
      observability_enabled:  cfg.observability_enabled?,
      otel_service_name:      ENV["OTEL_SERVICE_NAME"],
      otel_endpoint:          ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]
    })

    repl = Repl.new(
      context:    ctx,
      registry:   registry,
      builder:    builder,
      client:     client,
      logger:     logger,
      compactor:  compactor,
      task_name:  task_class.task_name,
      max_iterations:    cfg.agent_max_iterations,
      max_turn_tokens:   cfg.agent_max_turn_tokens,
      max_output_tokens: (max_output_tokens || cfg.agent_max_output_tokens),
      config_dir: cfg.dir,
      provider:   backend,
      model:      model,
      version:    VERSION,
      api_key:    api_key,
      servers:    servers
    )

    if tui && defined?(Tui)
      Tui.new(repl).start
    else
      repl.start
    end
  rescue Interrupt
    puts "\nInterrupted."
  ensure
    logger&.close
  end

  # Register every server in settings.yaml's `mcp_servers:` block. This is the
  # agent's ONLY source of tools — boukensha ships none of its own. Nothing
  # here knows what any particular server does; a MUD daemon and a filesystem
  # server are registered by the identical code path.
  #
  # A server marked `required: false` that fails to spawn is a warning, not a
  # fatal error — the agent runs without its tools. A name collision is never
  # excused that way: it means the config asks for two tools with one name, and
  # answering by dropping one of them silently is the worst option available.
  #
  # Returns { server_name => tool_count } for the servers that came up.
  # servers: defaults to cfg.mcp_servers, but callers that need to overlay
  # player credentials first (see #overlay_player_credentials) pass their
  # already-overlaid copy through instead.
  def self.register_mcp_servers(registry, cfg, servers: nil)
    (servers || cfg.mcp_servers).each_with_object({}) do |(name, entry), summary|
      begin
        client = Tools::Mcp.register(registry, command: entry[:command], args: entry[:args],
                                               env: entry[:env], prefix: entry[:prefix])
        summary[name] = client.tools.size
      rescue Tools::Mcp::CollisionError
        raise
      rescue StandardError => e
        raise "boukensha: MCP server '#{name}' failed to start: #{e.message}" if entry[:required]
        warn "[boukensha] optional MCP server '#{name}' failed to start: #{e.message} — continuing without its tools"
      end
    end
  end
  private_class_method :register_mcp_servers

  # Overlays a player's MUD_NAME/MUD_PASSWORD onto every mcp_servers entry
  # that already declares those keys in its env: block — matched by key
  # name, not a hardcoded "mud" server name, so this stays generic the way
  # Config#mcp_servers already is. No-op when player is nil (settings.yaml's
  # own env: wins, unchanged) or when a given server's env: doesn't declare
  # those keys at all (nothing to overlay there). Mutates `servers` in
  # place — see docs/plans/observability/players/
  # multiple_concurrent_players.md §1.
  def self.overlay_player_credentials(servers, player)
    return unless player

    servers.each_value do |entry|
      env = entry[:env]
      next unless env

      env["MUD_NAME"]     = player.name     if env.key?("MUD_NAME")
      env["MUD_PASSWORD"] = player.password if env.key?("MUD_PASSWORD")
    end
  end
  private_class_method :overlay_player_credentials

  # Cloud providers' credentials travel by env var, same convention `.run`/
  # `.repl` already used inline before this was extracted — shared here so
  # `build_compactor` can resolve credentials for whichever provider the
  # compactor's own `tasks.compactor.provider` names, independently of the
  # main agent's backend.
  def self.resolve_api_key(backend_type)
    case backend_type.to_sym
    when :anthropic    then ENV["ANTHROPIC_API_KEY"]
    when :openai       then ENV["OPENAI_API_KEY"]
    when :gemini       then ENV["GEMINI_API_KEY"]
    when :ollama_cloud then ENV["OLLAMA_API_KEY"]
    end
  end
  private_class_method :resolve_api_key

  # The same backend_type -> Backends::* selection `.run`/`.repl` need for
  # the main agent loop; extracted here so `build_compactor` can construct a
  # backend for Tier 2's model call the identical way, for any provider
  # boukensha supports — not just Ollama.
  def self.build_backend(backend_type, model:, api_key: nil, ollama_host: "http://localhost:11434")
    case backend_type.to_sym
    when :anthropic    then Backends::Anthropic.new(api_key: api_key, model: model)
    when :openai       then Backends::OpenAI.new(api_key: api_key, model: model)
    when :gemini       then Backends::Gemini.new(api_key: api_key, model: model)
    when :ollama       then Backends::Ollama.new(host: ollama_host, model: model)
    when :ollama_cloud then Backends::OllamaCloud.new(api_key: api_key, model: model)
    else raise ArgumentError, "Unknown backend #{backend_type.inspect}. Use :anthropic, :openai, :gemini, :ollama, or :ollama_cloud."
    end
  end
  private_class_method :build_backend

  # Tier 2 (the opt-in LLM prose rewrite) can run against any backend
  # boukensha supports, not just Ollama — see docs/plans/token_optimization/
  # mud_response_compaction.md Open Questions #2. Only constructs a backend
  # (and resolves its credentials) when Tier 2 is actually enabled; a
  # misconfigured provider/model degrades to Tier 2 disabled for this
  # session rather than failing boot — Tiers 0/1 never depend on this and
  # must still run.
  def self.build_compactor(cfg)
    return Compactor.new(enabled: false) unless cfg.compactor_enabled?

    provider = cfg.compactor_provider.to_sym
    backend  = build_backend(provider, model: cfg.compactor_model, api_key: resolve_api_key(provider), ollama_host: cfg.compactor_host)

    Compactor.new(enabled: true, backend: backend, min_chars: cfg.compactor_min_chars)
  rescue StandardError => e
    warn "[boukensha] compactor backend '#{cfg.compactor_provider}' failed to initialize (#{e.message}) — Tier 2 disabled for this session"
    Compactor.new(enabled: false)
  end
  private_class_method :build_compactor
end

require_relative "boukensha/tool"
require_relative "boukensha/message"
require_relative "boukensha/models"
require_relative "boukensha/context"
require_relative "boukensha/errors"
require_relative "boukensha/tool_policy"
require_relative "boukensha/registry"
require_relative "boukensha/prompt_builder"
require_relative "boukensha/logger"
require_relative "boukensha/telemetry"
require_relative "boukensha/metrics"
require_relative "boukensha/backends/base"
require_relative "boukensha/backends/anthropic"
require_relative "boukensha/backends/gemini"
require_relative "boukensha/backends/ollama"
require_relative "boukensha/backends/ollama_cloud"
require_relative "boukensha/backends/openai"
require_relative "boukensha/client"
require_relative "boukensha/compactor"
require_relative "boukensha/agent"
require_relative "boukensha/run_dsl"
require_relative "boukensha/repl"
require_relative "boukensha/tools/mcp"
require_relative "boukensha/tui"
