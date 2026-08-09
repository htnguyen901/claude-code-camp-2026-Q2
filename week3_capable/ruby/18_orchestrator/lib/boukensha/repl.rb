module Boukensha
  # Repl is the interactive session loop.
  #
  # It wraps the same primitives as a single Boukensha.run call, but instead of
  # running once it stays alive: it reads a task from the user, runs the agent,
  # prints the reply, and loops back to the prompt.
  #
  # The Context is shared across every turn so conversation history accumulates
  # naturally — the agent sees the full transcript each time it is called.
  #
  # By default (see planner_enabled:/judge_enabled: below) this also runs the
  # Planner once at session start and checks in with the Judge at every
  # checkpoint a turn reaches — docs/plans/agent_loop/
  # repl_planner_integration.md and repl_judge_integration.md.
  #
  # Built-in commands (not sent to the agent):
  #   /help    print the command list
  #   /quiet   suppress detailed logging
  #   /loud    re-enable logging
  #   /clear   wipe conversation history (tools stay registered)
  #   /compact drop oldest 40% of messages to free context
  #   /exit    leave the REPL
  #   /quit    alias for /exit
  class Repl
    PROMPT = "boukensha> "

    HELP = <<~HELP
      Commands:
        /quiet    suppress logging output
        /loud     re-enable logging output
        /clear    wipe conversation history (tools stay)
        /compact  drop oldest 40% of messages to free context
        /exit     leave the REPL
        /help     show this message
    HELP

    attr_reader :logger, :context, :model, :version

    # planner_enabled: — see docs/plans/agent_loop/repl_planner_integration.md.
    # Default true: as of that doc, Planner-seeding is the default for the
    # real `boukensha`/`bin/play_players` path, not opt-in (supersedes
    # high_level_agentic_loop_design.md's "Alternative B"). Boukensha.repl
    # resolves this from Config#planner_enabled? before constructing a Repl;
    # the default here only matters for a Repl built directly (tests, or a
    # caller that bypasses Boukensha.repl).
    #
    # planner_model:/planner_backend:/planner_api_key:/planner_ollama_host: —
    # independent overrides for the Planner's own call, mirroring
    # Boukensha::Session's identically-named kwargs. nil (the default) falls
    # back to `tasks.planner:` in settings.yaml.
    #
    # judge_enabled: — see docs/plans/agent_loop/repl_judge_integration.md.
    # Default true, same reversed-default convention as planner_enabled:
    # above: Judge-driven checkpoints are on by default for the real
    # `boukensha`/`bin/play_players` path, not opt-in. Boukensha.repl
    # resolves this from Config#judge_enabled? before constructing a Repl;
    # the default here only matters for a Repl built directly.
    #
    # judge_model:/judge_backend:/judge_api_key:/judge_ollama_host: —
    # independent overrides for the Judge's own call, mirroring the
    # planner_*: kwargs above but for Tasks::Judge. judge_every_n_turns: is
    # the optional fallback checkpoint cadence (see Session.checkpoint?) —
    # nil (default) means checkpoints only fire on a limit-triggered
    # wrap-up, same default as Boukensha::Session's every_n_turns:.
    def initialize(context:, registry:, builder:, client:, logger:, compactor: Compactor.new, config_dir: nil, provider: nil, model: nil, task_name: nil, version: nil, api_key: nil, servers: nil, max_iterations: nil, max_turn_tokens: nil, max_output_tokens: nil,
                   planner_enabled: true, planner_model: nil, planner_backend: nil, planner_api_key: nil, planner_ollama_host: "http://localhost:11434",
                   judge_enabled: true, judge_model: nil, judge_backend: nil, judge_api_key: nil, judge_ollama_host: "http://localhost:11434", judge_every_n_turns: nil)
      @context    = context
      @registry   = registry
      @builder    = builder
      @client     = client
      @logger     = logger
      @compactor  = compactor
      @config_dir = config_dir
      @provider   = provider
      @model      = model
      @task_name  = task_name
      @version    = version
      @api_key    = api_key
      @servers    = servers
      @max_iterations    = max_iterations
      @max_turn_tokens   = max_turn_tokens
      @max_output_tokens = max_output_tokens
      @planner_enabled     = planner_enabled
      @planner_model       = planner_model
      @planner_backend     = planner_backend
      @planner_api_key     = planner_api_key
      @planner_ollama_host = planner_ollama_host
      @judge_enabled       = judge_enabled
      @judge_model         = judge_model
      @judge_backend       = judge_backend
      @judge_api_key       = judge_api_key
      @judge_ollama_host   = judge_ollama_host
      @judge_every_n_turns = judge_every_n_turns
      @planned    = false
      @goal       = nil
      @turns_since_checkpoint = 0
      @turn       = 0
      @output_cb  = nil
    end

    # Register a callback that receives every string the REPL would otherwise
    # print to stdout.  When set, puts/print are suppressed entirely and all
    # output is routed through the callback instead.  Used by Tui.
    def on_output(&block)
      @output_cb = block
    end

    def banner
      key_status    = (@api_key.nil? || @api_key.strip.empty?) ? "✗ API key not set" : "✓ API key set"
      provider_line = "#{@provider || "default"} (#{@model || "default"})  #{key_status}"
      config_exists = @config_dir && Dir.exist?(@config_dir)
      config_line   = config_exists ? @config_dir : "#{@config_dir || "(default)"}  ✗ directory not found"
      ver           = @version || "?.?.?"
      servers_stat  = servers_status_string

      <<~BANNER

        ╔══════════════════════════════════════╗
        ║  BOUKENSHA MUD Assistant (v#{ver})#{" " * (9 - ver.length)}║
        ╚══════════════════════════════════════╝
          config:    #{config_line}
          provider:  #{provider_line}
          servers:   #{servers_stat}

          /quiet or /loud   toggle logging
          /clear           reset conversation history
          /compact         free context (drop oldest messages)
          /exit or /quit    leave the REPL

      BANNER
    end

    # Handle a slash command.  Returns :quit, :command, or nil (not a command).
    # Output is routed through the registered on_output callback if present.
    def handle_command(input)
      case input
      when "/exit", "/quit"
        output("Goodbye.")
        :quit
      when "/help"
        output(HELP)
        :command
      when "/quiet"
        Boukensha.quiet!
        output("(logging suppressed — type /loud to re-enable)")
        :command
      when "/loud"
        Boukensha.loud!
        output("(logging enabled)")
        :command
      when "/clear"
        @context.clear_messages!
        @context.plan = nil
        @planned = false
        @goal = nil
        @turns_since_checkpoint = 0
        @turn = 0
        output("(conversation history cleared)")
        :command
      when "/compact"
        dropped = @context.compact_messages!
        output("(compacted context — #{dropped} messages dropped)")
        :command
      end
    end

    def run_turn(input)
      @turn += 1
      # Tracked unconditionally (not just when the Planner actually seeds a
      # plan) so a later Judge-requested replan still has an objective to
      # hand Boukensha.run_planner even if tasks.planner.enabled was false
      # for this turn — see maybe_check_judge below.
      @goal ||= input

      maybe_seed_plan(input)

      @context.add_message(:user, input)

      # turn: is passed through rather than logged here so Logger#turn fires
      # from inside Agent#run's boukensha.turn span (see Agent#run) — logged
      # this early, it would run before that span exists and its trace_id
      # would always come back nil.
      agent  = Agent.new(
        context:  @context,
        registry: @registry,
        builder:  @builder,
        client:   @client,
        logger:   @logger,
        compactor: @compactor,
        task_name: @task_name,
        turn:      @turn,
        max_iterations:    @max_iterations,
        max_turn_tokens:   @max_turn_tokens,
        max_output_tokens: @max_output_tokens
      )
      result = agent.run

      output("")
      output(result)

      maybe_check_judge(agent)
    rescue LoopError => e
      output("\n[error] #{e.message}")
    rescue ApiError => e
      output("\n[error] API call failed: #{e.message}")
    end

    def start
      output(banner)
      loop do
        unless @output_cb
          print PROMPT
          $stdout.flush
        end

        input = $stdin.gets
        break unless input  # EOF / Ctrl-D

        input = input.chomp.strip
        next if input.empty?

        result = handle_command(input)
        break if result == :quit
        next  if result

        run_turn(input)
      end
    end

    private

    # Seeds ctx.plan from Tasks::Planner exactly once per session (the first
    # turn after construction, or after /clear resets @planned) — matches
    # Boukensha::Session's "plan at session start" seeding, adapted to a
    # human-driven REPL where there's no synthetic "continue" loop. See
    # docs/plans/agent_loop/repl_planner_integration.md for why this runs by
    # default now, and why it deliberately does NOT re-plan on every turn —
    # the Judge (maybe_check_judge below) decides continue/replan/flag at a
    # checkpoint, not "is this turn's input a new quest" on every turn, so
    # re-running the Planner per turn would still just be waste. Errors here
    # (a real Client#call) propagate to run_turn's own rescue ApiError.
    def maybe_seed_plan(goal)
      return unless @planner_enabled
      return if @planned

      @planned = true
      output("(planning...)")
      plan = Boukensha.run_planner(
        goal: goal, logger: @logger,
        model: @planner_model, backend: @planner_backend,
        api_key: @planner_api_key, ollama_host: @planner_ollama_host
      )
      @context.plan = plan
      output("Plan:\n#{plan}\n")
    end

    # Checks in with the Judge after a turn that hit a checkpoint (a
    # limit-triggered wrap-up, or the judge_every_n_turns: fallback — same
    # predicate Boukensha::Session uses, see Session.checkpoint?). A
    # naturally-completed turn (agent.stop_reason == :completed) is not a
    # checkpoint by itself; with judge_every_n_turns: left at its default
    # nil, that means the Judge only ever runs when the Player actually hit
    # a limit, exactly mirroring Session's own checkpoint cadence — see
    # docs/plans/agent_loop/repl_judge_integration.md.
    #
    # Unlike Session, there is no autonomous loop here for a :flag verdict
    # to "stop" — a human already decides what to type next after every
    # turn, so :flag just prints a prominent note instead of halting
    # anything. A :replan verdict re-runs the Planner only if
    # planner_enabled: is still true; a Judge asking for a replan should not
    # reintroduce Planner activity a session has explicitly opted out of.
    def maybe_check_judge(agent)
      return unless @judge_enabled

      @turns_since_checkpoint += 1
      return unless Session.checkpoint?(agent, @turns_since_checkpoint, every_n_turns: @judge_every_n_turns)

      @turns_since_checkpoint = 0
      output("(checking in with the Judge...)")
      verdict = Boukensha.run_judge(
        plan: @context.plan, transcript_tail: Boukensha.transcript_tail(@context.messages), player_context: @context,
        logger: @logger, model: @judge_model, backend: @judge_backend, api_key: @judge_api_key, ollama_host: @judge_ollama_host
      )
      reasoning = Boukensha.verdict_reasoning(verdict[:text])
      output("Judge: #{verdict[:verdict]}#{reasoning.empty? ? "" : " — #{reasoning}"}\n")

      case verdict[:verdict]
      when :replan
        unless @planner_enabled
          output("(Judge suggested a replan, but tasks.planner.enabled is false — skipping)\n")
          return
        end

        plan = Boukensha.run_planner(
          goal: @goal, prior_plan: @context.plan, transcript_tail: Boukensha.transcript_tail(@context.messages), logger: @logger,
          model: @planner_model, backend: @planner_backend, api_key: @planner_api_key, ollama_host: @planner_ollama_host
        )
        @context.plan = plan
        output("Replanned:\n#{plan}\n")
      when :flag
        output("⚠ The Judge flagged a possible problem with this session — you may want to review the transcript above before continuing.\n")
      end
    end

    def output(str)
      if @output_cb
        @output_cb.call(str.to_s)
      else
        puts str
      end
    end

    # Build the MCP servers line shown in the banner. Every tool the agent has
    # came from one of these, so this doubles as "what can I actually do?".
    # No probing needed: a server that answers tools/list is already connected,
    # and one that didn't is either absent here or took the agent down at boot.
    def servers_status_string
      return "(none configured — the agent has no tools)" if @servers.nil? || @servers.empty?

      @servers.map { |name, count| "#{name} (#{count})" }.join("  ")
    end
  end
end
