require_relative "boukensha/version"
require_relative "boukensha/config"
require_relative "boukensha/tasks/player"
require_relative "boukensha/tasks/planner"
require_relative "boukensha/tasks/judge"

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
    planner_model:       nil,
    planner_backend:     nil,
    planner_api_key:     nil,
    planner_ollama_host: "http://localhost:11434",
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
      planner_enabled:        cfg.planner_enabled?,
      otel_service_name:      ENV["OTEL_SERVICE_NAME"],
      otel_endpoint:          ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]
    })
    agent   = Agent.new(context: ctx, registry: registry, builder: builder, client: client, logger: logger,
                        compactor: compactor, task_name: task_class.task_name,
                        max_iterations: cfg.agent_max_iterations,
                        max_turn_tokens: cfg.agent_max_turn_tokens,
                        max_output_tokens: (max_output_tokens || cfg.agent_max_output_tokens))

    # Default on — see Config#planner_enabled?/
    # docs/plans/agent_loop/repl_planner_integration.md. One turn here, one
    # Agent#run call, so "seed once" is simply "seed before the only turn."
    if cfg.planner_enabled?
      ctx.plan = run_planner(goal: task, logger: logger, model: planner_model, backend: planner_backend,
                              api_key: planner_api_key, ollama_host: planner_ollama_host)
    end

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
    planner_model:       nil,
    planner_backend:     nil,
    planner_api_key:     nil,
    planner_ollama_host: "http://localhost:11434",
    judge_model:         nil,
    judge_backend:       nil,
    judge_api_key:       nil,
    judge_ollama_host:   "http://localhost:11434",
    judge_every_n_turns: nil,
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
      planner_enabled:        cfg.planner_enabled?,
      judge_enabled:          cfg.judge_enabled?,
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
      servers:    servers,
      planner_enabled:     cfg.planner_enabled?,
      planner_model:       planner_model,
      planner_backend:     planner_backend,
      planner_api_key:     planner_api_key,
      planner_ollama_host: planner_ollama_host,
      judge_enabled:       cfg.judge_enabled?,
      judge_model:         judge_model,
      judge_backend:       judge_backend,
      judge_api_key:       judge_api_key,
      judge_ollama_host:   judge_ollama_host,
      judge_every_n_turns: judge_every_n_turns
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

  # One bare model call producing a plan — no Agent#run loop, since
  # Tasks::Planner has no tools to dispatch (deny-by-default, per
  # Tasks::Base.tool_policy). Returns plain plan text; the caller is
  # responsible for assigning it to whatever Context#plan should hold — see
  # docs/plans/agent_loop/orchestrator.md §3. This is that call site for now
  # (Phase 2); Phase 4's session driver will call this from inside its loop
  # instead of duplicating the request-building logic.
  #
  # goal:            the current objective, as given to the Player.
  # transcript_tail: on a replan, a tail of the Player's recent transcript so
  #                  the Planner can say what changed rather than restating
  #                  from scratch. nil for the initial plan.
  # prior_plan:      the plan being replaced, on a replan. nil otherwise.
  # logger:          optional — when given, the request/response are written
  #                  to it the same way Agent#run's are, under this task's
  #                  own task_name ("planner") so log_viz/OTEL separate this
  #                  call from Player activity automatically.
  def self.run_planner(
    goal:,
    transcript_tail:   nil,
    prior_plan:        nil,
    model:             nil,
    backend:           nil,
    api_key:           nil,
    ollama_host:       "http://localhost:11434",
    max_output_tokens: nil,
    logger:            nil
  )
    cfg           = config
    task_class    = Tasks::Planner
    task_settings = cfg.tasks(task_class.task_name)
    system        = task_class.system_prompt(task_settings, user_prompts_dir: cfg.user_prompts_dir, default_prompts_dir: Config::PROMPTS_DIR)
    model       ||= task_class.model(task_settings)
    backend     ||= task_class.provider(task_settings).to_sym
    api_key     ||= resolve_api_key(backend)
    max_output_tokens ||= task_class.max_output_tokens(task_settings)

    ctx = Context.new(system: system)
    ctx.add_message(:user, planner_input(goal: goal, transcript_tail: transcript_tail, prior_plan: prior_plan))

    be      = build_backend(backend, model: model, api_key: api_key, ollama_host: ollama_host)
    builder = PromptBuilder.new(ctx, be)
    client  = Client.new(builder)

    payload  = builder.to_api_payload(max_output_tokens: max_output_tokens, tools: [])
    logger&.request(payload: payload, messages: ctx.messages, tools: {}, iteration: 1, task: task_class.task_name)
    response = client.call(payload: payload, tools: [], max_output_tokens: max_output_tokens, task: task_class.task_name)
    parsed   = builder.parse_response(response)
    text     = extract_plan_text(parsed[:content])
    logger&.response(text: text, usage: response["usage"], stop_reason: parsed[:stop_reason], task: task_class.task_name, backend: be)
    text
  end

  # goal/prior_plan/transcript_tail assembled into the one user message the
  # Planner sees — plain text is enough here (unlike the Judge's verdict
  # contract), since this output is consumed only by a human-readable prompt
  # block, never branched on programmatically.
  def self.planner_input(goal:, transcript_tail: nil, prior_plan: nil)
    parts = ["Goal: #{goal}"]
    parts << "Prior plan:\n#{prior_plan}" if prior_plan && !prior_plan.to_s.strip.empty?
    parts << "Recent transcript:\n#{transcript_tail}" if transcript_tail && !transcript_tail.to_s.strip.empty?
    parts.join("\n\n")
  end
  private_class_method :planner_input

  def self.extract_plan_text(content)
    content.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("\n").strip
  end
  private_class_method :extract_plan_text

  # Checks the Player's transcript + current plan and returns a
  # continue/replan/flag verdict — docs/plans/agent_loop/evaluator.md.
  # Unlike run_planner (a single bare Client#call), the Judge has read-only
  # tools it may dispatch to fact-check a claim (room_knowledge, the
  # inspector-role MUD tools), so it needs Agent#run's iteration loop —
  # just a small one (Tasks::Judge.max_iterations defaults to 5).
  #
  # plan:            the Player's current Context#plan.
  # transcript_tail: recent Player transcript text — see
  #                  Boukensha.transcript_tail.
  # player_context:  the Player's LIVE Context — read only, for its already-
  #                  registered Tool objects. Lets the Judge dispatch the
  #                  same look/examine/room_knowledge tools over the same
  #                  live MCP connection (no second login), while still
  #                  running its own reasoning in a throwaway Context/
  #                  Registry that never touches player_context.messages/
  #                  .plan — see #reuse_inspector_tools. player_context is
  #                  never passed to Agent#run itself.
  # logger:          required (unlike run_planner's optional logger) —
  #                  Agent#run always logs through one; every real call site
  #                  (Boukensha::Session) already has the Player's logger to
  #                  hand it, so defaulting to a fresh Logger here would
  #                  silently create an unrelated session file.
  #
  # Returns { verdict: :continue | :replan | :flag, text: <full response
  # text> }. A response that doesn't end with the "VERDICT: ..." convention
  # falls back to :flag, not :continue — a checkpoint the Judge couldn't
  # even be parsed for should stop and surface to a human, not sail through
  # silently (see evaluator.md §3).
  def self.run_judge(
    plan:,
    transcript_tail:,
    player_context:,
    logger:,
    model:             nil,
    backend:           nil,
    api_key:           nil,
    ollama_host:       "http://localhost:11434",
    max_output_tokens: nil,
    max_iterations:    nil
  )
    cfg           = config
    task_class    = Tasks::Judge
    task_settings = cfg.tasks(task_class.task_name)
    system        = task_class.system_prompt(task_settings, user_prompts_dir: cfg.user_prompts_dir, default_prompts_dir: Config::PROMPTS_DIR)
    model       ||= task_class.model(task_settings)
    backend     ||= task_class.provider(task_settings).to_sym
    api_key     ||= resolve_api_key(backend)
    max_output_tokens ||= task_class.max_output_tokens(task_settings)
    max_iterations    ||= task_class.max_iterations(task_settings)

    ctx      = Context.new(system: system)
    policy   = task_class.tool_policy(task_settings, tool_roles: cfg.tool_roles)
    registry = Registry.new(ctx, policy: policy)
    reuse_inspector_tools(registry, player_context)

    ctx.add_message(:user, judge_input(plan: plan, transcript_tail: transcript_tail))

    be      = build_backend(backend, model: model, api_key: api_key, ollama_host: ollama_host)
    builder = PromptBuilder.new(ctx, be)
    client  = Client.new(builder)

    agent = Agent.new(context: ctx, registry: registry, builder: builder, client: client, logger: logger,
                       task_name: task_class.task_name, max_iterations: max_iterations, max_output_tokens: max_output_tokens)
    text    = agent.run
    verdict = parse_verdict(text)
    logger.judge_verdict(verdict: verdict, text: text, task: task_class.task_name)
    { verdict: verdict, text: text }
  end

  # A readable text rendering of the most recent Context#messages — what the
  # Judge (and, on a replan, the Planner) are shown instead of the full
  # session history, keeping both calls cheap (evaluator.md §2). Content
  # that's already a String (ordinary :user/:assistant turns) is used
  # verbatim; anything else (assistant tool_use blocks, tool_result content)
  # falls back to #inspect — good enough for a human/LLM-readable tail, not
  # meant to be re-parsed programmatically.
  def self.transcript_tail(messages, last: 20)
    messages.last(last).map { |m| "#{m.role}: #{m.content.is_a?(String) ? m.content : m.content.inspect}" }.join("\n")
  end

  def self.judge_input(plan:, transcript_tail:)
    plan_text = plan.to_s.strip.empty? ? "(no plan set)" : plan
    parts = ["Current plan:\n#{plan_text}"]
    parts << "Recent transcript:\n#{transcript_tail}" if transcript_tail && !transcript_tail.to_s.strip.empty?
    parts.join("\n\n")
  end
  private_class_method :judge_input

  VERDICT_PATTERN = /VERDICT:\s*(continue|replan|flag)\s*\z/i.freeze

  def self.parse_verdict(text)
    match = VERDICT_PATTERN.match(text.to_s.strip)
    match ? match[1].downcase.to_sym : :flag
  end
  private_class_method :parse_verdict

  # The Judge's reasoning with the trailing "VERDICT: ..." line stripped off
  # — for display (e.g. Repl's checkpoint output), where the parsed verdict
  # symbol is already shown separately and repeating the raw line would be
  # redundant. run_judge itself still returns the full, unmodified text.
  def self.verdict_reasoning(text)
    text.to_s.strip.sub(VERDICT_PATTERN, "").strip
  end

  # Re-registers the Player's already-connected Tool objects (same MCP
  # session — never a second login) onto the Judge's own throwaway registry,
  # filtered by the Judge's own ToolPolicy (role: inspector by convention).
  # Registry#tool silently drops anything the policy denies, so this needs
  # no separate allow-list logic — the policy alone is what keeps
  # move/attack/quit/give out of the Judge's reach. player_context is only
  # ever read here, never mutated.
  def self.reuse_inspector_tools(judge_registry, player_context)
    player_context.tools.each_value do |tool|
      judge_registry.tool(tool.name, description: tool.description, parameters: tool.parameters, &tool.block)
    end
  end
  private_class_method :reuse_inspector_tools

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
  #
  # Not private: Boukensha::Session (docs/plans/agent_loop/orchestrator.md
  # §4) is a third construction site alongside .run/.repl that needs this
  # exact setup sequence — see lib/boukensha/session.rb.
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
require_relative "boukensha/session"
require_relative "boukensha/tools/mcp"
require_relative "boukensha/tui"
