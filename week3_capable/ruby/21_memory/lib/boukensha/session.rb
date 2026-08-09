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
    # planner_*/judge_*/navigator_*/chronicler_*: independent overrides for
    #                 those tasks' own calls, mirroring model:/backend:/
    #                 api_key:/ollama_host: above but for Tasks::Planner/
    #                 Tasks::Judge/Tasks::Navigator/Tasks::Chronicler instead
    #                 of Tasks::Player — see Boukensha.run_planner/.run_judge/
    #                 .run_navigator/.run_chronicler. nil (the default) falls
    #                 back to `tasks.planner:`/`tasks.judge:`/
    #                 `tasks.navigator:`/`tasks.chronicler:` in settings.yaml.
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
      navigator_model:       nil,
      navigator_backend:     nil,
      navigator_api_key:     nil,
      navigator_ollama_host: "http://localhost:11434",
      chronicler_model:       nil,
      chronicler_backend:     nil,
      chronicler_api_key:     nil,
      chronicler_ollama_host: "http://localhost:11434",
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
      connections = Boukensha::McpConnections.connect(cfg, servers: servers)
      connections.register(registry)
      at_exit { connections.close }
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
      Boukensha.register_navigator_tool(registry, connections, logger: logger, model: navigator_model, backend: navigator_backend,
                                         api_key: navigator_api_key, ollama_host: navigator_ollama_host)

      # This player's cross-session memory — see docs/plans/memory/
      # player_memory.md decision 6. No player, no memory: never constructed
      # without a name to key it by, regardless of memory.enabled?.
      memory       = (player && cfg.memory_enabled?) ? PlayerMemory.load(player.name, memory_dir: cfg.memory_dir) : nil
      prior_digest = memory&.digest_text

      # Session start: seed the plan before the Player's first turn.
      # Boukensha.run_planner tags its own request/response `task: "planner"`
      # on this same logger, so log_viz/OTEL separate it from the Player
      # turns that follow automatically — see orchestrator.md §5.
      ctx.plan = Boukensha.run_planner(
        goal: goal, player_memory: prior_digest, logger: logger, mcp: connections,
        model: planner_model, backend: planner_backend, api_key: planner_api_key, ollama_host: planner_ollama_host
      )
      warn "[boukensha] Planner plan:\n#{ctx.plan}\n"

      # Judge-facing memory of this session's own past verdicts — see
      # docs/plans/agent_loop/evaluator_judge_redesign.md §3. Session-scoped,
      # same lifetime as ctx/logger; never touches the Player's Context.
      judge_memory    = JudgeMemory.new
      judge_settings  = cfg.tasks(Tasks::Judge.task_name)
      repeated_window    = Tasks::Judge.repeated_action_window(judge_settings)
      repeated_threshold = Tasks::Judge.repeated_action_threshold(judge_settings)

      text          = nil
      agent         = nil
      turn  = 0
      turns_since_checkpoint = 0

      # Checkpoints recorded since the last Chronicler flush — a separate,
      # shorter-lived accumulator from judge_memory above. judge_memory
      # itself must stay cumulative for the whole session and is never
      # reset here: it's what gives the Judge cross-checkpoint continuity
      # (evaluator_judge_redesign.md §3, "Judge were not carrying previous
      # judgments into memory => FIXED") and resetting it on every replan
      # would undo that fix. pending_checkpoints exists only so
      # flush_memory below knows what's new since it last ran.
      pending_checkpoints = []

      # Chronicles whatever Judge checkpoints have accumulated since the
      # last flush, updates this player's saved digest, and folds the
      # result back into prior_digest so the very next Planner call sees
      # the freshest notes. Called live at every checkpoint — :replan
      # (before that replan's own run_planner call, so the new plan is
      # informed by what was just learned), :flag, and (see the case
      # statement below) :continue too — not just once at the very end, and
      # not gated on the verdict having escalated. See docs/plans/memory/
      # player_memory.md's checkpoint-triggered revision and its
      # "flush on every checkpoint" follow-up: a long run that never
      # escalates past :continue is exactly the case where a player quietly
      # repeating a doomed approach (e.g. broke and still shopping) has
      # real lessons in the Judge's reasoning, and previously that
      # reasoning was accumulated in pending_checkpoints only to be
      # silently dropped at loop exit, since nothing ever called
      # flush_memory. No-ops only when nothing has landed in
      # pending_checkpoints since the last flush (or memory is off).
      flush_memory = lambda do |reason:, outcome:|
        next unless memory
        next if pending_checkpoints.empty?

        checkpoints          = pending_checkpoints
        pending_checkpoints  = []

        memory.append_session_record(
          goal: goal, stop_reason: reason.to_s, turns: turn,
          checkpoints: checkpoints.map { |e| { turn: e.turn, verdict: e.verdict, reasoning: e.reasoning, overridden: e.overridden } },
          outcome: outcome
        )

        begin
          digest = Boukensha.run_chronicler(
            goal: goal, outcome: outcome, checkpoints: checkpoints, prior_digest: prior_digest,
            logger: logger, model: chronicler_model, backend: chronicler_backend, api_key: chronicler_api_key, ollama_host: chronicler_ollama_host
          )
          memory.save_digest(digest)
          prior_digest = digest
        rescue StandardError => e
          warn "[boukensha] Chronicler failed (#{e.message}) — memory digest left unchanged for #{player.name}"
        end
      end

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

          judged_plan      = ctx.plan
          repeated_actions = Boukensha.repeated_tool_calls(ctx, window: repeated_window, min_count: repeated_threshold)

          verdict = Boukensha.run_judge(
            plan: judged_plan, transcript_tail: Boukensha.transcript_tail(ctx.messages), mcp: connections,
            logger: logger, model: judge_model, backend: judge_backend, api_key: judge_api_key, ollama_host: judge_ollama_host,
            history: judge_memory, repeated_actions: repeated_actions
          )
          warn "[boukensha] Session checkpoint at turn #{turn} (stop_reason=#{agent.stop_reason}): " \
               "Judge verdict=#{verdict[:verdict]}#{" [mechanically overridden]" if verdict[:overridden]} — #{verdict[:text]}"

          entry = JudgeMemory::Entry.new(
            turn: turn, stop_reason: agent.stop_reason, plan: judged_plan,
            verdict: verdict[:verdict], reasoning: Boukensha.verdict_reasoning(verdict[:text]),
            repeated_actions: repeated_actions, overridden: verdict[:overridden]
          )
          judge_memory.record(entry)
          pending_checkpoints << entry

          case verdict[:verdict]
          when :replan
            reason = Boukensha.verdict_reasoning(verdict[:text])
            reason += "\n\nRepeated actions that triggered this replan: #{repeated_actions.map { |k, v| "#{k}×#{v}" }.join(", ")}" if verdict[:overridden]

            # Update memory before replanning, not after the session ends —
            # the whole point of a replan is that something notable just
            # happened, and this replan's own Planner call should already
            # see it via prior_digest (updated in place by flush_memory).
            flush_memory.call(reason: :replan, outcome: "Judge requested a replan at turn #{turn}: #{reason}")

            ctx.plan = Boukensha.run_planner(
              goal: goal, prior_plan: ctx.plan, transcript_tail: Boukensha.transcript_tail(ctx.messages), replan_reason: reason,
              player_memory: prior_digest, logger: logger, mcp: connections,
              model: planner_model, backend: planner_backend, api_key: planner_api_key, ollama_host: planner_ollama_host
            )
            warn "[boukensha] Session replanned at turn #{turn}:\n#{ctx.plan}\n"

            # Whatever led to this checkpoint has already been captured
            # elsewhere (the fresh plan above, this replan's memory flush) —
            # the raw transcript that produced it no longer needs to ride
            # along in full on every subsequent request. See
            # docs/plans/memory/context_lifecycle.md §3b. ctx.plan/ctx.route
            # live outside @messages (Context#effective_system), so this
            # can't lose either one.
            ctx.checkpoint_trim!
          when :flag
            flag_reasoning = judge_memory.entries.last.reasoning
            flush_memory.call(reason: :flag, outcome: "Stopped: Judge flagged a risk — #{flag_reasoning}")
            ctx.checkpoint_trim!
            warn "[boukensha] Session stopped: Judge flagged a risk at turn #{turn} — #{verdict[:text]}. " \
                 "v1 has no automatic recovery from a flag; a human should review this session's log."
            break
          else
            # :continue -> loop back around to the next Player turn, but
            # still flush whatever this checkpoint's Judge reasoning has to
            # offer. This is what makes "learn along the way" real for a
            # session that never escalates: the flush cadence here is
            # already throttled by the same checkpoint? gate (every_n_turns
            # / a limit wrap-up), so this costs exactly one Chronicler call
            # per checkpoint, same as :replan/:flag above.
            flush_memory.call(reason: :continue, outcome: "Judge checkpoint at turn #{turn}: continuing — #{Boukensha.verdict_reasoning(verdict[:text])}")
          end
        end

        if turn >= max_turns
          warn "[boukensha] Session stopped: reached max_turns (#{max_turns}) at turn #{turn} " \
               "(stop_reason=#{agent.stop_reason}) without the Player completing."
          break
        end
      end

      # Catch-all safety net, not the primary mechanism: every checkpoint
      # (:replan/:flag/:continue) now flushes live, above, so
      # pending_checkpoints is normally already empty by the time the loop
      # exits. This just guarantees nothing accumulated is ever silently
      # lost regardless of how the loop ended — mirrors Repl's own
      # /clear, /exit, EOF catch-all flush. flush_memory itself no-ops when
      # pending_checkpoints is empty, so this is a no-op on the common path.
      if pending_checkpoints.any?
        outcome = if agent.stop_reason == :completed
                    "Completed: #{text}"
                  elsif turn >= max_turns
                    "Stopped: reached max_turns (#{max_turns}) at turn #{turn} without completing."
                  else
                    "Session ended at turn #{turn} (stop_reason=#{agent.stop_reason})."
                  end
        flush_memory.call(reason: agent.stop_reason, outcome: outcome)
      end

      text
    ensure
      logger&.close
    end
  end
end
