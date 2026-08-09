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
  # With a player: given and memory.enabled: true (docs/plans/memory/
  # player_memory.md), memory is chronicled live, at every checkpoint,
  # rather than saved up for one write at the end of a session: a :replan
  # verdict flushes whatever's accumulated since the last flush and updates
  # the saved digest *before* that replan's own Planner call, so the new
  # plan sees the freshest notes, and a :continue verdict flushes too (not
  # just :replan/:flag — see maybe_check_judge), so a long conversation that
  # never escalates still learns along the way instead of losing every
  # checkpoint's reasoning at whatever boundary /clear or /exit eventually
  # is. /clear and /exit (or EOF) still flush too, as a catch-all for a
  # :flag (which doesn't itself stop the REPL) or any trailing checkpoint
  # that hasn't been flushed yet — see flush_memory! below.
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

    # Only shown by /help when Config#self_manage? is on — see
    # docs/plans/agent_loop/self_management.md §2.
    SELF_MANAGE_HELP = <<~HELP
        /pause    pause self-managed continuation after the current turn finishes
        /continue resume a paused self-managed run
        /stop     stop self-managed continuation (falls back to manual, session stays open)
    HELP

    # The self-managed loop's wind-down instruction, issued once when the
    # session cost budget crosses Config#session_cost_warn_pct — the
    # session-level analogue of Agent::WRAP_UP_DIRECTIVE. See
    # docs/plans/agent_loop/self_management.md §1.
    WIND_DOWN_INSTRUCTION = <<~MSG.strip
      You're nearing this session's cost budget. Do not start any new
      multi-step subtask. Finish or abandon whatever you're doing now,
      briefly say what's left undone, and stop.
    MSG

    attr_reader :logger, :context, :model, :version

    # :manual | :running | :paused | :stopped — see
    # docs/plans/agent_loop/self_management.md §2. Only ever leaves :manual
    # while a self-managed run (§3) is actually in flight; resets to
    # :manual when that run exits for any reason, so a stale paused/stopped
    # state can never leak into the next goal.
    attr_reader :autonomy_state

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
    #
    # player: — this Repl's logged-in character (a Boukensha::PlayerProfile,
    # or anything responding to #name), or nil — see docs/plans/memory/
    # player_memory.md. Retrofits that plan's Deferred "Repl has no single
    # well-defined session end" gap by treating /clear and /exit (or EOF) as
    # the REPL's own session boundaries — see flush_memory! below. nil (no
    # player) never constructs a PlayerMemory, matching Session.play's own
    # "no player, no memory" guarantee regardless of memory.enabled?.
    #
    # chronicler_model:/chronicler_backend:/chronicler_api_key:/
    # chronicler_ollama_host: — independent overrides for the Chronicler's
    # own call, mirroring the planner_*/judge_*: kwargs above but for
    # Tasks::Chronicler.
    def initialize(context:, registry:, builder:, client:, logger:, compactor: Compactor.new, config_dir: nil, provider: nil, model: nil, task_name: nil, version: nil, api_key: nil, servers: nil, mcp: nil, max_iterations: nil, max_turn_tokens: nil, max_output_tokens: nil,
                   planner_enabled: true, planner_model: nil, planner_backend: nil, planner_api_key: nil, planner_ollama_host: "http://localhost:11434",
                   judge_enabled: true, judge_model: nil, judge_backend: nil, judge_api_key: nil, judge_ollama_host: "http://localhost:11434", judge_every_n_turns: nil,
                   player: nil, chronicler_model: nil, chronicler_backend: nil, chronicler_api_key: nil, chronicler_ollama_host: "http://localhost:11434")
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
      @mcp        = mcp
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
      @player                 = player
      @chronicler_model       = chronicler_model
      @chronicler_backend     = chronicler_backend
      @chronicler_api_key     = chronicler_api_key
      @chronicler_ollama_host = chronicler_ollama_host
      @planned    = false
      @goal       = nil
      @turns_since_checkpoint = 0
      @turn       = 0
      @output_cb  = nil
      @autonomy_state = :manual
      @last_verdict   = nil
      @last_result    = nil
      # Judge-facing memory of this session's own past verdicts — see
      # docs/plans/agent_loop/evaluator_judge_redesign.md §3. Reset
      # alongside @turns_since_checkpoint/@planned on /clear. Never reset by
      # flush_memory! itself — it must stay cumulative for the whole
      # conversation to give the Judge cross-checkpoint continuity.
      @judge_memory = JudgeMemory.new
      # Checkpoints recorded since the last Chronicler flush — a separate,
      # shorter-lived accumulator from @judge_memory above, so flush_memory!
      # knows what's new without disturbing @judge_memory's own lifetime.
      @pending_checkpoints = []
      # This player's cross-session memory — see docs/plans/memory/
      # player_memory.md decision 6. No player, no memory: never
      # constructed without a name to key it by, regardless of
      # memory.enabled?. Read once at construction time (matching every
      # other Boukensha.config read in this class) — a mid-process
      # settings.yaml edit only takes effect on the next Repl.
      @memory       = (@player && Boukensha.config.memory_enabled?) ? PlayerMemory.load(@player.name, memory_dir: Boukensha.config.memory_dir) : nil
      @prior_digest = @memory&.digest_text
    end

    # Register a callback that receives every string the REPL would otherwise
    # print to stdout.  When set, puts/print are suppressed entirely and all
    # output is routed through the callback instead.  Used by Tui.
    def on_output(&block)
      @output_cb = block
    end

    # Pause/resume/stop primitives for the self-managed continuation loop
    # (§3) — callable safely from another thread (Tui's turn thread runs
    # the loop; these are called from the main event-loop thread). Plain
    # ivar flips, cooperative and idempotent: checked only between turns,
    # never preempting an in-flight Agent#run. See
    # docs/plans/agent_loop/self_management.md §2.
    def pause_autonomy!
      @autonomy_state = :paused if @autonomy_state == :running
    end

    def resume_autonomy!
      @autonomy_state = :running if @autonomy_state == :paused
    end

    def stop_autonomy!
      @autonomy_state = :stopped if %i[running paused].include?(@autonomy_state)
    end

    # Public (not private, unlike most of Repl's turn-driving internals)
    # because Boukensha.repl calls it directly as a safety net around
    # whatever exits the REPL loop (see its own `ensure`) — /exit and EOF
    # inside #start already call it themselves, and maybe_check_judge calls
    # it live on every :replan verdict (see there) — this method is also the
    # catch-all for any exit path outside Repl's own control, e.g. an
    # Interrupt.
    #
    # Originally the REPL retrofit of docs/plans/memory/player_memory.md's
    # deferred "Repl has no single well-defined session end" gap; now one of
    # several call sites (see maybe_check_judge's :replan branch) rather than
    # the only one, per that doc's checkpoint-triggered revision — a human
    # can keep one process going indefinitely, so /clear and /exit (or EOF)
    # remain a catch-all boundary for a :flag (which doesn't itself stop the
    # REPL — a human keeps deciding what to do next, same as
    # repl_judge_integration.md's existing "print a note, don't halt" posture)
    # or any trailing checkpoint that never triggered a replan of its own.
    #
    # No-op unless @memory exists (player + memory.enabled?) and at least
    # one checkpoint has landed since the last flush — any verdict, not
    # just :replan/:flag (see maybe_check_judge's :continue branch below,
    # and Boukensha::Session's identical "flush on every checkpoint"
    # revision in docs/plans/memory/player_memory.md). reason: :cleared,
    # :exit, :replan, or :continue, purely for the raw record's
    # stop_reason: field and (for :cleared/:exit) the outcome text below —
    # :replan/:continue's own outcome text is passed in directly by
    # maybe_check_judge, which already has the Judge's reasoning to hand.
    def flush_memory!(reason, outcome: nil)
      return unless @memory
      return if @pending_checkpoints.empty?

      outcome ||= case reason
                  when :cleared then "Session cleared by the player after turn #{@turn}. Last result: #{@last_result}"
                  when :exit    then "Session ended (player exited) after turn #{@turn}. Last result: #{@last_result}"
                  end
      checkpoints = @pending_checkpoints
      # Reset immediately (not after the Chronicler call below) so a second
      # flush_memory! for the same boundary — e.g. Boukensha.repl's own
      # Interrupt/ensure safety net after an /exit that already flushed —
      # sees no notable entries left and no-ops instead of double-writing.
      # @judge_memory itself is untouched — see its own comment in
      # #initialize for why it must outlive any single flush.
      @pending_checkpoints = []

      @memory.append_session_record(
        goal: @goal, stop_reason: reason.to_s, turns: @turn,
        checkpoints: checkpoints.map { |e| { turn: e.turn, verdict: e.verdict, reasoning: e.reasoning, overridden: e.overridden } },
        outcome: outcome
      )

      begin
        digest = Boukensha.run_chronicler(
          goal: @goal, outcome: outcome, checkpoints: checkpoints, prior_digest: @prior_digest,
          logger: @logger, model: @chronicler_model, backend: @chronicler_backend,
          api_key: @chronicler_api_key, ollama_host: @chronicler_ollama_host
        )
        @memory.save_digest(digest)
        @prior_digest = digest
      rescue StandardError => e
        warn "[boukensha] Chronicler failed (#{e.message}) — memory digest left unchanged for #{@player.name}"
      end
    end

    def banner
      key_status    = (@api_key.nil? || @api_key.strip.empty?) ? "✗ API key not set" : "✓ API key set"
      provider_line = "#{@provider || "default"} (#{@model || "default"})  #{key_status}"
      config_exists = @config_dir && Dir.exist?(@config_dir)
      config_line   = config_exists ? @config_dir : "#{@config_dir || "(default)"}  ✗ directory not found"
      ver           = @version || "?.?.?"
      servers_stat  = servers_status_string
      self_manage_line = Boukensha.config.self_manage? ? "  /pause, /continue, /stop   control the self-managed run\n" : ""
      memory_line   = @memory ? "\n  memory:    on for #{@player.name}#{@prior_digest ? "" : " (no notes yet)"}" : ""

      <<~BANNER

        ╔══════════════════════════════════════╗
        ║  BOUKENSHA MUD Assistant (v#{ver})#{" " * (9 - ver.length)}║
        ╚══════════════════════════════════════╝
          config:    #{config_line}
          provider:  #{provider_line}
          servers:   #{servers_stat}#{memory_line}

          /quiet or /loud   toggle logging
          /clear           reset conversation history
          /compact         free context (drop oldest messages)
          /exit or /quit    leave the REPL
        #{self_manage_line}
      BANNER
    end

    # Handle a slash command.  Returns :quit, :command, or nil (not a command).
    # Output is routed through the registered on_output callback if present.
    def handle_command(input)
      case input
      when "/exit", "/quit"
        flush_memory!(:exit)
        output("Goodbye.")
        :quit
      when "/help"
        output(Boukensha.config.self_manage? ? HELP + SELF_MANAGE_HELP : HELP)
        :command
      when "/pause"
        pause_autonomy!
        output(@autonomy_state == :paused ? "(self-managed run paused — /continue to resume, /stop to end)" : "(no self-managed run in progress)")
        :command
      when "/continue"
        resume_autonomy!
        output(@autonomy_state == :running ? "(resumed self-managed run)" : "(no paused self-managed run to resume)")
        :command
      when "/stop"
        stop_autonomy!
        output("(self-managed run stopped — back to manual)")
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
        flush_memory!(:cleared)
        @context.clear_messages!
        @context.plan = nil
        @planned = false
        @goal = nil
        @turns_since_checkpoint = 0
        @turn = 0
        @judge_memory = JudgeMemory.new
        @pending_checkpoints = []
        @last_result = nil
        output("(conversation history cleared)")
        :command
      when "/compact"
        dropped = @context.compact_messages!
        output("(compacted context — #{dropped} messages dropped)")
        :command
      end
    end

    # Runs one turn; when Config#self_manage? is on and that turn ends at a
    # Judge checkpoint that isn't a stopping condition, keeps issuing
    # Session::CONTINUE_INSTRUCTION turns on its own instead of returning
    # control to the prompt — see docs/plans/agent_loop/self_management.md
    # §3. With self_manage: false (the default), behavior is unchanged: one
    # call to perform_turn, then maybe_continue_self_managed is a no-op.
    def run_turn(input)
      agent = perform_turn(input)
      maybe_continue_self_managed if agent
    end

    def start
      output(banner)
      loop do
        unless @output_cb
          print PROMPT
          $stdout.flush
        end

        input = $stdin.gets
        unless input  # EOF / Ctrl-D
          flush_memory!(:exit)
          break
        end

        input = input.chomp.strip
        next if input.empty?

        result = handle_command(input)
        break if result == :quit
        next  if result

        run_turn(input)
      end
    end

    private

    # The single reusable unit of work: seed the plan once, add the user
    # message, run the Agent, print the result, check in with the Judge if
    # a checkpoint fired. This is exactly what run_turn did before
    # self-management existed — calling it again with
    # Session::CONTINUE_INSTRUCTION is already exactly what
    # Boukensha::Session.play's own loop does, so no new turn machinery is
    # needed here, only the driver in maybe_continue_self_managed below that
    # decides whether to call it again. Returns the Agent (so the caller can
    # read its stop_reason), or nil on a rescued error.
    def perform_turn(input)
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
      @last_result = result

      output("")
      output(result)

      @last_verdict = maybe_check_judge(agent)
      agent
    rescue LoopError => e
      output("\n[error] #{e.message}")
      nil
    rescue ApiError => e
      output("\n[error] API call failed: #{e.message}")
      nil
    end

    # Keeps calling perform_turn with Session::CONTINUE_INSTRUCTION,
    # unattended, until one of the stopping conditions in
    # docs/plans/agent_loop/self_management.md §3 fires: a Judge :flag
    # verdict, the session cost budget being exhausted (or crossing the warn
    # threshold, which gets exactly one more wind-down turn before
    # stopping), or a human /stop. A turn completing naturally
    # (agent.stop_reason == :completed) is NOT by itself a stopping
    # condition — with self_manage on, maybe_check_judge forces a Judge
    # check-in after every turn regardless of Session.checkpoint? (which
    # only fires on a limit hit or the every_n_turns cadence), precisely so
    # a routine "the model finished replying" doesn't get mistaken for "the
    # journey is over"; only the Judge gets to make that call.
    # :replan is not a stopping condition, same as Session.play — a replan
    # just updates ctx.plan (already handled inside maybe_check_judge) and
    # the loop continues to the next "continue" turn.
    def maybe_continue_self_managed
      return unless Boukensha.config.self_manage?
      return if @last_verdict.nil? || @last_verdict == :flag

      @autonomy_state = :running
      loop do
        break if wait_while_paused == :stopped

        case Boukensha.session_budget_status(@logger, Boukensha.config)
        when :exhausted
          output("(session cost budget exhausted — stopping self-managed run)")
          break
        when :warn
          perform_turn(WIND_DOWN_INSTRUCTION)
          break
        else
          agent = perform_turn(Session::CONTINUE_INSTRUCTION)
          break if agent.nil? || @last_verdict.nil? || @last_verdict == :flag
        end
      end
    ensure
      @autonomy_state = :manual
    end

    # Blocks (cooperatively — only checked between turns) while paused.
    # Returns :stopped if a /stop landed either before or during the pause,
    # :running otherwise.
    def wait_while_paused
      return :stopped if @autonomy_state == :stopped

      sleep 0.2 while @autonomy_state == :paused
      @autonomy_state == :stopped ? :stopped : :running
    end

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
        goal: goal, player_memory: @prior_digest, logger: @logger, mcp: @mcp,
        model: @planner_model, backend: @planner_backend,
        api_key: @planner_api_key, ollama_host: @planner_ollama_host
      )
      @context.plan = plan
      output("Plan:\n#{plan}\n")
    end

    # Checks in with the Judge after a turn that hit a checkpoint (a
    # limit-triggered wrap-up, or the judge_every_n_turns: fallback — same
    # predicate Boukensha::Session uses, see Session.checkpoint?), OR,
    # regardless of that predicate, whenever Config#self_manage? is on.
    # With a human at the keyboard, a naturally-completed turn
    # (agent.stop_reason == :completed) is deliberately not a checkpoint by
    # itself — the human decides what happens next either way, so there's no
    # point spending a Judge call on every reply. But a self-managed run has
    # no human to make that call: every turn's end needs a verdict, or
    # maybe_continue_self_managed (§3) has nothing to decide "keep going" on
    # — see docs/plans/agent_loop/self_management.md §3 and
    # docs/plans/agent_loop/repl_judge_integration.md for the human-driven
    # cadence this extends.
    #
    # Unlike Session, there is no autonomous loop here for a :flag verdict
    # to "stop" — a human already decides what to type next after every
    # turn, so :flag just prints a prominent note instead of halting
    # anything. (When self-managing, maybe_continue_self_managed is the
    # thing that actually stops on :flag — this method's own behavior is
    # unchanged.) A :replan verdict re-runs the Planner only if
    # planner_enabled: is still true; a Judge asking for a replan should not
    # reintroduce Planner activity a session has explicitly opted out of.
    #
    # Returns the parsed verdict symbol (:continue/:replan/:flag), or nil
    # when @judge_enabled is false or no checkpoint fired this turn — the
    # one piece of information maybe_continue_self_managed (§3) needs from
    # this method. No change to its existing printed output or side effects.
    def maybe_check_judge(agent)
      return unless @judge_enabled

      @turns_since_checkpoint += 1
      checkpoint = Session.checkpoint?(agent, @turns_since_checkpoint, every_n_turns: @judge_every_n_turns)
      checkpoint ||= Boukensha.config.self_manage?
      return unless checkpoint

      @turns_since_checkpoint = 0
      output("(checking in with the Judge...)")

      judge_settings    = Boukensha.config.tasks(Tasks::Judge.task_name)
      repeated_actions  = Boukensha.repeated_tool_calls(
        @context, window: Tasks::Judge.repeated_action_window(judge_settings), min_count: Tasks::Judge.repeated_action_threshold(judge_settings)
      )
      judged_plan = @context.plan

      verdict = Boukensha.run_judge(
        plan: judged_plan, transcript_tail: Boukensha.transcript_tail(@context.messages), mcp: @mcp,
        logger: @logger, model: @judge_model, backend: @judge_backend, api_key: @judge_api_key, ollama_host: @judge_ollama_host,
        history: @judge_memory, repeated_actions: repeated_actions
      )
      reasoning = Boukensha.verdict_reasoning(verdict[:text])
      output("Judge: #{verdict[:verdict]}#{reasoning.empty? ? "" : " — #{reasoning}"}\n")

      entry = JudgeMemory::Entry.new(
        turn: @turn, stop_reason: agent.stop_reason, plan: judged_plan,
        verdict: verdict[:verdict], reasoning: reasoning,
        repeated_actions: repeated_actions, overridden: verdict[:overridden]
      )
      @judge_memory.record(entry)
      @pending_checkpoints << entry

      case verdict[:verdict]
      when :replan
        reason = reasoning.dup
        reason += "\n\nRepeated actions that triggered this replan: #{repeated_actions.map { |k, v| "#{k}×#{v}" }.join(", ")}" if verdict[:overridden]

        # Update memory before replanning, not saved up for a later /clear
        # or /exit — the replanned plan below should already see it via
        # @prior_digest (updated in place by flush_memory!).
        flush_memory!(:replan, outcome: "Judge requested a replan at turn #{@turn}: #{reason}")

        if @planner_enabled
          plan = Boukensha.run_planner(
            goal: @goal, prior_plan: @context.plan, transcript_tail: Boukensha.transcript_tail(@context.messages), replan_reason: reason,
            player_memory: @prior_digest, logger: @logger, mcp: @mcp,
            model: @planner_model, backend: @planner_backend, api_key: @planner_api_key, ollama_host: @planner_ollama_host
          )
          @context.plan = plan
          output("Replanned:\n#{plan}\n")
        else
          output("(Judge suggested a replan, but tasks.planner.enabled is false — skipping)\n")
        end

        # See Boukensha::Session's identical call for why — docs/plans/memory/
        # context_lifecycle.md §3b. Fires regardless of whether
        # planner_enabled: actually produced a fresh plan above: the Judge's
        # own reasoning plus this checkpoint's memory flush have already
        # captured what mattered from the transcript being trimmed.
        @context.checkpoint_trim!
      when :flag
        # No trim here, deliberately: unlike Session.play (which breaks the
        # loop right after), a :flag doesn't stop the REPL and doesn't call
        # flush_memory! yet either (that happens later, at /clear or /exit) —
        # nothing has captured this transcript elsewhere yet, and the
        # human's next move may well be to keep reading it. See
        # docs/plans/memory/context_lifecycle.md's open question on trimming
        # before memory has actually been captured.
        output("⚠ The Judge flagged a possible problem with this session — you may want to review the transcript above before continuing.\n")
      else
        # :continue — flush whatever this checkpoint's Judge reasoning has
        # to offer instead of saving it up for a /clear or /exit that might
        # be much later (or, for a self-managed run, might not come until
        # the whole goal is done). See Boukensha::Session's identical
        # addition and docs/plans/memory/player_memory.md's "flush on every
        # checkpoint" revision.
        flush_memory!(:continue, outcome: "Judge checkpoint at turn #{@turn}: continuing — #{reasoning}")
      end

      verdict[:verdict]
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
