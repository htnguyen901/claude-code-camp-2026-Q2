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
    connections = McpConnections.connect(cfg, servers: servers)
    connections.register(registry)
    at_exit { connections.close }
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
      ctx.plan = run_planner(goal: task, logger: logger, mcp: connections, model: planner_model, backend: planner_backend,
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
    connections = McpConnections.connect(cfg, servers: mcp_servers)
    connections.register(registry)
    at_exit { connections.close }
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
      servers:    connections.summary,
      mcp:        connections,
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

  # A small Agent#run loop producing a plan — mirrors .run_judge exactly: a
  # throwaway Context/Registry built from `tasks.planner.tools` in
  # settings.yaml via Tasks::Base.tool_policy (deny-by-default only when
  # that block is omitted — nothing about "planner" is special-cased here),
  # optionally registered against the session's shared MCP connections (see
  # Boukensha::McpConnections) so the Planner can dispatch whatever read-only
  # tools it's been granted (e.g. room_knowledge) while it reasons, without
  # a second MCP login/connection. Returns plain plan text; the caller is
  # responsible for assigning it to whatever Context#plan should hold — see
  # docs/plans/agent_loop/orchestrator.md §3.
  #
  # goal:            the current objective, as given to the Player.
  # transcript_tail: on a replan, a tail of the Player's recent transcript so
  #                  the Planner can say what changed rather than restating
  #                  from scratch. nil for the initial plan.
  # prior_plan:      the plan being replaced, on a replan. nil otherwise.
  # mcp:             the session's Boukensha::McpConnections — already-
  #                   connected MCP servers, registered here onto the
  #                   Planner's own throwaway Registry and filtered by the
  #                   Planner's own ToolPolicy (`tasks.planner.tools`),
  #                   independent of what any other task's policy allows.
  #                   nil (e.g. a standalone Planner call with no MCP servers
  #                   connected yet) just means the Planner reasons against
  #                   an empty registry — zero tools, regardless of what
  #                   `tasks.planner.tools` says, not an error.
  # logger:          required, like .run_judge's — every real call site
  #                  (Boukensha.run/Session/Repl) already has one to hand it.
  # replan_reason: on a replan, the Judge's own reasoning for why the prior
  #                plan needed to change (plus, when the replan was
  #                mechanically forced, the repeated-action evidence) — see
  #                docs/plans/agent_loop/evaluator_judge_redesign.md §7. nil
  #                (the default) omits the "why" line entirely, byte-
  #                identical to this method's pre-§7 behavior.
  def self.run_planner(
    goal:,
    transcript_tail:   nil,
    prior_plan:        nil,
    replan_reason:     nil,
    mcp:               nil,
    logger:,
    model:             nil,
    backend:           nil,
    api_key:           nil,
    ollama_host:       "http://localhost:11434",
    max_output_tokens: nil
  )
    cfg           = config
    task_class    = Tasks::Planner
    task_settings = cfg.tasks(task_class.task_name)
    system        = task_class.system_prompt(task_settings, user_prompts_dir: cfg.user_prompts_dir, default_prompts_dir: Config::PROMPTS_DIR)
    model       ||= task_class.model(task_settings)
    backend     ||= task_class.provider(task_settings).to_sym
    api_key     ||= resolve_api_key(backend)
    max_output_tokens ||= task_class.max_output_tokens(task_settings)
    max_iterations      = task_class.max_iterations(task_settings)

    ctx      = Context.new(system: system)
    policy   = task_class.tool_policy(task_settings, tool_roles: cfg.tool_roles)
    registry = Registry.new(ctx, policy: policy)
    mcp&.register(registry)

    ctx.add_message(:user, planner_input(goal: goal, transcript_tail: transcript_tail, prior_plan: prior_plan, replan_reason: replan_reason))

    be      = build_backend(backend, model: model, api_key: api_key, ollama_host: ollama_host)
    builder = PromptBuilder.new(ctx, be)
    client  = Client.new(builder)

    agent = Agent.new(context: ctx, registry: registry, builder: builder, client: client, logger: logger,
                       task_name: task_class.task_name, max_iterations: max_iterations, max_output_tokens: max_output_tokens)
    agent.run.strip
  end

  # goal/prior_plan/replan_reason/transcript_tail assembled into the one
  # user message the Planner sees — plain text is enough here (unlike the
  # Judge's verdict contract), since this output is consumed only by a
  # human-readable prompt block, never branched on programmatically.
  def self.planner_input(goal:, transcript_tail: nil, prior_plan: nil, replan_reason: nil)
    parts = ["Goal: #{goal}"]
    parts << "Prior plan:\n#{prior_plan}" if prior_plan && !prior_plan.to_s.strip.empty?
    parts << "Why the prior plan is being replaced:\n#{replan_reason}" if replan_reason && !replan_reason.to_s.strip.empty?
    parts << "Recent transcript:\n#{transcript_tail}" if transcript_tail && !transcript_tail.to_s.strip.empty?
    parts.join("\n\n")
  end
  private_class_method :planner_input

  # Checks the Player's transcript + current plan and returns a
  # continue/replan/flag verdict — docs/plans/agent_loop/evaluator.md.
  # Same shape as run_planner: a small Agent#run loop (Tasks::Judge.
  # max_iterations defaults to 5, tighter than Base's 25, since this is
  # "check a couple of facts, then decide" — evaluator.md §2) over a
  # throwaway Context/Registry built from `tasks.judge.tools`.
  #
  # plan:            the Player's current Context#plan.
  # transcript_tail: recent Player transcript text — see
  #                  Boukensha.transcript_tail.
  # mcp:             the session's Boukensha::McpConnections — already-
  #                   connected MCP servers, registered here onto the
  #                   Judge's own throwaway Registry and filtered by the
  #                   Judge's own ToolPolicy (`tasks.judge.tools`),
  #                   independent of what any other task's policy allows.
  #                   Lets the Judge dispatch the same look/examine/
  #                   room_knowledge tools over the same live MCP
  #                   connections (no second login), while still running its
  #                   own reasoning in a throwaway Context/Registry that
  #                   never touches the Player's Context. nil means the
  #                   Judge reasons against an empty registry — zero tools.
  # logger:          required (unlike run_planner's optional logger) —
  #                  Agent#run always logs through one; every real call site
  #                  (Boukensha::Session) already has the Player's logger to
  #                  hand it, so defaulting to a fresh Logger here would
  #                  silently create an unrelated session file.
  # history:         a Boukensha::JudgeMemory of this session's prior
  #                   verdicts, or nil — see docs/plans/agent_loop/
  #                   evaluator_judge_redesign.md §3-§4. nil (the default)
  #                   reproduces pre-redesign behavior exactly: no history
  #                   block in judge_input, and the mechanical override
  #                   below never has a prior verdict to check, so it can
  #                   only ever step :continue up to :replan, never :flag.
  # repeated_actions: a { "tool(args)" => count } Hash from
  #                   Boukensha.repeated_tool_calls (computed by the driver
  #                   against the Player's live Context, once per
  #                   checkpoint), or nil/empty — see §5-§6 of the doc
  #                   above. Fed into judge_input as a signal for the LLM,
  #                   and also drives the deterministic override below,
  #                   independently of whether the LLM's own reasoning
  #                   noticed it.
  #
  # Returns { verdict: :continue | :replan | :flag, text: <full response
  # text>, overridden: true|false }. A response that doesn't end with the
  # "VERDICT: ..." convention falls back to :flag, not :continue — a
  # checkpoint the Judge couldn't even be parsed for should stop and
  # surface to a human, not sail through silently (see evaluator.md §3).
  #
  # Mechanical override (evaluator_judge_redesign.md §6): if the parsed
  # verdict is :continue but repeated_actions shows the same action firing
  # at least the configured threshold, the driver receives :replan instead
  # — deterministic, not another LLM call grading the first one. If the
  # most recent history entry already shows a :replan verdict and the
  # pattern is *still* repeating against the new plan, escalate to :flag
  # instead of looping on silent replans forever.
  def self.run_judge(
    plan:,
    transcript_tail:,
    mcp:               nil,
    logger:,
    model:             nil,
    backend:           nil,
    api_key:           nil,
    ollama_host:       "http://localhost:11434",
    max_output_tokens: nil,
    max_iterations:    nil,
    history:           nil,
    repeated_actions:  nil
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
    mcp&.register(registry)

    ctx.add_message(:user, judge_input(plan: plan, transcript_tail: transcript_tail, history: history, repeated_actions: repeated_actions))

    be      = build_backend(backend, model: model, api_key: api_key, ollama_host: ollama_host)
    builder = PromptBuilder.new(ctx, be)
    client  = Client.new(builder)

    agent = Agent.new(context: ctx, registry: registry, builder: builder, client: client, logger: logger,
                       task_name: task_class.task_name, max_iterations: max_iterations, max_output_tokens: max_output_tokens)
    text       = agent.run
    verdict    = parse_verdict(text)
    overridden = false

    if verdict == :continue && repeated_actions && !repeated_actions.empty?
      last_verdict = history&.entries&.last&.verdict
      verdict      = last_verdict == :replan ? :flag : :replan
      overridden   = true
    end

    logger.judge_verdict(verdict: verdict, text: text, task: task_class.task_name, overridden: overridden)
    { verdict: verdict, text: text, overridden: overridden }
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

  # Scans the Player's live Context (structured tool_use blocks, not the
  # text-joined transcript_tail above — that's already lost the args needed
  # to tell two calls apart) for the same tool+args combination repeated at
  # least min_count times within the last window assistant tool_use blocks.
  # Returns { "name(args)" => count } for every combination at or above the
  # threshold — deterministic, not another model call. See
  # docs/plans/agent_loop/evaluator_judge_redesign.md §5.
  #
  # Tool-use blocks (Agent#handle_tool_calls) carry string keys
  # ("type"/"name"/"input"), the shape the Anthropic-style backend produces
  # — this reads player_context.messages directly, so it must match that,
  # not the symbol-keyed shape a hand-built fixture might guess at.
  def self.repeated_tool_calls(player_context, window: 20, min_count: 3)
    calls = player_context.messages.last(window).flat_map do |m|
      next [] unless m.role == :assistant && m.content.is_a?(Array)

      m.content.select { |b| b["type"] == "tool_use" }
       .map { |b| "#{b["name"]}(#{b["input"].to_a.sort.map { |k, v| "#{k}: #{v}" }.join(", ")})" }
    end
    calls.tally.select { |_, count| count >= min_count }
  end

  # plan/transcript_tail assembled the same as before; history/
  # repeated_actions are additive (see run_judge's doc comment) — with both
  # nil (the default), this is byte-identical to pre-redesign judge_input.
  def self.judge_input(plan:, transcript_tail:, history: nil, repeated_actions: nil)
    plan_text = plan.to_s.strip.empty? ? "(no plan set)" : plan
    parts = ["Current plan:\n#{plan_text}"]
    parts << "Recent transcript:\n#{transcript_tail}" if transcript_tail && !transcript_tail.to_s.strip.empty?
    if history
      history_text = history.to_prompt_text
      parts << "Your previous judgements this session (most recent last):\n#{history_text}" if history_text
    end
    if repeated_actions && !repeated_actions.empty?
      parts << "Repeated actions detected in the recent transcript (name×count): #{repeated_actions.map { |k, v| "#{k}×#{v}" }.join(", ")}"
    end
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

  # Overlays a player's MUD_NAME/MUD_PASSWORD, and (docs/plans/
  # world_knowledge/world_knowledge.md decision 4) WORLD_MAP_PLAYER, onto
  # every mcp_servers entry that already declares those keys in its env:
  # block — matched by key name, not a hardcoded "mud"/"log-viz" server
  # name, so this stays generic the way Config#mcp_servers already is.
  # No-op when player is nil (settings.yaml's own env: wins, unchanged) or
  # when a given server's env: doesn't declare a given key at all (nothing
  # to overlay there). Mutates `servers` in place — see
  # docs/plans/observability/players/multiple_concurrent_players.md §1.
  #
  # WORLD_MAP_PLAYER is read by LogViz::McpServer once, at its own
  # spawn/startup — never a tool-call argument `world__room_knowledge`/
  # `world__route_to` accept, so the model can't fill it in or spoof
  # another character's discoveries. This overlay is what actually gets a
  # player's identity there: the same env-at-spawn-time convention
  # MUD_NAME/MUD_PASSWORD already use, not a new mechanism.
  def self.overlay_player_credentials(servers, player)
    return unless player

    servers.each_value do |entry|
      env = entry[:env]
      next unless env

      env["MUD_NAME"]         = player.name     if env.key?("MUD_NAME")
      env["MUD_PASSWORD"]     = player.password if env.key?("MUD_PASSWORD")
      env["WORLD_MAP_PLAYER"] = player.name     if env.key?("WORLD_MAP_PLAYER")
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
require_relative "boukensha/judge_memory"
require_relative "boukensha/repl"
require_relative "boukensha/session"
require_relative "boukensha/tools/mcp"
require_relative "boukensha/mcp_connections"
require_relative "boukensha/tui"
