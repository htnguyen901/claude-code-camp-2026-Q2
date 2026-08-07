module Boukensha
  # The Planner -> Player -> Judge driver — docs/plans/agent_loop/
  # orchestrator.md §4, docs/plans/agent_loop/evaluator.md §4-§5,
  # docs/plans/agent_loop/phase0_decision.md (this class's name and
  # "continue" as the literal next instruction were decided there).
  #
  # Boukensha.run/.repl/Repl are all untouched by this — they stay the
  # one-shot/interactive baseline (high_level_agentic_loop_design.md's
  # Alternative B: "Planner/Judge disabled == today's behavior"). Session is
  # a new, additive entry point: it builds the same ctx/registry/backend/
  # logger scaffolding .run does, calls the Planner once up front to seed
  # Context#plan, then keeps calling Agent#run — one call per "turn" —
  # checking in with the Judge at each checkpoint (an iteration/token-limit
  # wrap-up, or the every_n_turns: fallback) until the Player naturally
  # completes, the Judge flags a risk, or max_turns: is hit.
  class Session
    DEFAULT_MAX_TURNS    = 10
    CONTINUE_INSTRUCTION = "continue"

    # See docs/plans/agent_loop/evaluator.md §4. agent.stop_reason ==
    # :completed never reaches this — Session's loop already breaks before
    # calling it in that case (see .play below).
    def self.checkpoint?(agent, turns_since_checkpoint, every_n_turns:)
      return true if %i[max_iterations max_tokens].include?(agent.stop_reason)

      every_n_turns && every_n_turns.positive? && turns_since_checkpoint >= every_n_turns
    end

    # See Boukensha.run for full documentation of every kwarg shared with
    # it (system:/model:/backend:/api_key:/ollama_host:/log:/
    # context_window:/max_output_tokens:/working_dir:/player:/&block).
    #
    # goal:           the objective the Planner seeds a plan for, and the
    #                 text the Player's first turn is given verbatim
    #                 (mirrors what Boukensha.run's task: is today).
    # max_turns:      outer safety cap on Player turns regardless of what
    #                 the Judge decides — a backstop against a Judge that
    #                 keeps saying :continue forever, not the primary stop
    #                 mechanism now that one exists.
    # every_n_turns:  optional fallback checkpoint cadence for long runs that
    #                 never hit an iteration/token limit — see
    #                 evaluator.md §4. nil (default) means checkpoints only
    #                 fire on a limit-triggered wrap-up.
    # planner_*/judge_*: independent overrides for the Planner's/Judge's own
    #                 calls, mirroring model:/backend:/api_key:/ollama_host:
    #                 above but for Tasks::Planner/Tasks::Judge instead of
    #                 Tasks::Player — see Boukensha.run_planner/.run_judge.
    #                 nil (the default) falls back to `tasks.planner:`/
    #                 `tasks.judge:` in settings.yaml.
    def self.play(
      goal:,
      system:            nil,
      model:             nil,
      backend:           nil,
      api_key:           nil,
      ollama_host:       "http://localhost:11434",
      log:               nil,
      context_window:    nil,
      max_output_tokens: nil,
      working_dir:       Dir.pwd,
      player:            nil,
      max_turns:         DEFAULT_MAX_TURNS,
      every_n_turns:       nil,
      planner_model:       nil,
      planner_backend:     nil,
      planner_api_key:     nil,
      planner_ollama_host: "http://localhost:11434",
      judge_model:         nil,
      judge_backend:       nil,
      judge_api_key:       nil,
      judge_ollama_host:   "http://localhost:11434",
      &block
    )
      cfg           = Boukensha.config
      task_class    = Tasks::Player
      task_settings = cfg.tasks(task_class.task_name)
      system      ||= task_class.system_prompt(task_settings, user_prompts_dir: cfg.user_prompts_dir, default_prompts_dir: Config::PROMPTS_DIR)
      model       ||= task_class.model(task_settings)
      backend     ||= task_class.provider(task_settings).to_sym
      context_window ||= Models.context_window(model)
      api_key     ||= Boukensha.resolve_api_key(backend)

      ctx      = Context.new(system: system, context_window: context_window, working_dir: working_dir, compaction_threshold: cfg.agent_compaction_threshold)
      policy   = task_class.tool_policy(task_settings, tool_roles: cfg.tool_roles)
      registry = Registry.new(ctx, policy: policy)

      servers = cfg.mcp_servers
      Boukensha.overlay_player_credentials(servers, player)
      Boukensha.register_mcp_servers(registry, cfg, servers: servers)
      compactor = Boukensha.build_compactor(cfg)

      RunDSL.new(registry).instance_eval(&block) if block

      be      = Boukensha.build_backend(backend, model: model, api_key: api_key, ollama_host: ollama_host)
      builder = PromptBuilder.new(ctx, be)
      client  = Client.new(builder)
      # See Boukensha.run for why tracer/meter are constructed here, up front.
      Boukensha.tracer
      Boukensha.meter
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
        otel_endpoint:          ENV["OTEL_EXPORTER_OTLP_ENDPOINT"],
        driver:                 "session",
        max_turns:              max_turns,
        every_n_turns:          every_n_turns
      })

      # Session start: seed the plan before the Player's first turn.
      # Boukensha.run_planner tags its own request/response `task: "planner"`
      # on this same logger, so log_viz/OTEL separate it from the Player
      # turns that follow automatically — see orchestrator.md §5.
      ctx.plan = Boukensha.run_planner(
        goal: goal, logger: logger,
        model: planner_model, backend: planner_backend, api_key: planner_api_key, ollama_host: planner_ollama_host
      )
      warn "[boukensha] Planner plan:\n#{ctx.plan}\n"

      text = nil
      turn = 0
      turns_since_checkpoint = 0

      loop do
        turn += 1
        turns_since_checkpoint += 1
        # Phase 0 decision: the literal instruction "continue" after the
        # first turn, not a parse of the Player's own wrap-up text.
        instruction = turn == 1 ? goal : CONTINUE_INSTRUCTION
        ctx.add_message(:user, instruction)

        agent = Agent.new(
          context: ctx, registry: registry, builder: builder, client: client, logger: logger,
          compactor: compactor, task_name: task_class.task_name, turn: turn,
          max_iterations: cfg.agent_max_iterations, max_turn_tokens: cfg.agent_max_turn_tokens,
          max_output_tokens: (max_output_tokens || cfg.agent_max_output_tokens)
        )
        text = agent.run

        break if agent.stop_reason == :completed

        if checkpoint?(agent, turns_since_checkpoint, every_n_turns: every_n_turns)
          turns_since_checkpoint = 0

          verdict = Boukensha.run_judge(
            plan: ctx.plan, transcript_tail: Boukensha.transcript_tail(ctx.messages), player_context: ctx,
            logger: logger, model: judge_model, backend: judge_backend, api_key: judge_api_key, ollama_host: judge_ollama_host
          )
          warn "[boukensha] Session checkpoint at turn #{turn} (stop_reason=#{agent.stop_reason}): " \
               "Judge verdict=#{verdict[:verdict]} — #{verdict[:text]}"

          case verdict[:verdict]
          when :replan
            ctx.plan = Boukensha.run_planner(
              goal: goal, prior_plan: ctx.plan, transcript_tail: Boukensha.transcript_tail(ctx.messages), logger: logger,
              model: planner_model, backend: planner_backend, api_key: planner_api_key, ollama_host: planner_ollama_host
            )
            warn "[boukensha] Session replanned at turn #{turn}:\n#{ctx.plan}\n"
          when :flag
            warn "[boukensha] Session stopped: Judge flagged a risk at turn #{turn} — #{verdict[:text]}. " \
                 "v1 has no automatic recovery from a flag; a human should review this session's log."
            break
          end
          # :continue -> no-op, loop back around to the next Player turn.
        end

        if turn >= max_turns
          warn "[boukensha] Session stopped: reached max_turns (#{max_turns}) at turn #{turn} " \
               "(stop_reason=#{agent.stop_reason}) without the Player completing."
          break
        end
      end

      text
    ensure
      logger&.close
    end
  end
end
