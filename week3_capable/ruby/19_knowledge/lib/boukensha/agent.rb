module Boukensha
  class Agent
    # Why Agent#run stopped: :completed (natural end-of-turn text response),
    # or :max_iterations / :max_tokens (a limit-triggered wrap_up call). Set
    # at each of the three return points, never re-derived from text — see
    # docs/plans/agent_loop/worker.md §2.
    attr_reader :stop_reason

    # Default iteration ceiling. The *enforced* value comes from the
    # max_iterations: constructor arg (sourced from Config at the run/repl path),
    # which falls back to this constant. 0 (or nil) disables the ceiling.
    MAX_ITERATIONS = 25

    # The wind-down call is deliberately short and cheap.
    WRAP_UP_OUTPUT_TOKENS = 400
    WRAP_UP_DIRECTIVE = <<~MSG.strip
      You have reached your action limit for this turn. Do not call any more tools.
      Briefly summarize what you accomplished, what is still unfinished, and the
      single next action you would take.
    MSG

    # turn: is the REPL's own conversation-turn counter (Repl#run_turn) — a
    # different axis than @iteration (this turn's tool-call loop count).
    # Boukensha.run's one-shot path never passes it, and correspondingly
    # never gets a Logger#turn line — same as before this parameter existed.
    def initialize(context:, registry:, builder:, client:, logger: Logger.new, compactor: Compactor.new, task_name: nil, turn: nil,
                   max_iterations: MAX_ITERATIONS, max_turn_tokens: nil, max_output_tokens: nil)
      @context           = context
      @registry          = registry
      @builder           = builder
      @client            = client
      @logger            = logger
      @compactor         = compactor
      @task_name         = task_name
      @turn              = turn
      @max_iterations    = (max_iterations || MAX_ITERATIONS).to_i
      @max_turn_tokens   = max_turn_tokens.to_i      # 0 = disabled
      @max_output_tokens = max_output_tokens
      @iteration         = 0
    end

    def run
      Boukensha.tracer.in_span("boukensha.turn", attributes: {
        "boukensha.session_id" => @logger.session_id,
        "boukensha.task"       => @task_name.to_s,
        "boukensha.provider"   => @builder.backend.provider_name,
        "boukensha.model"      => @builder.backend.model
      }) do
        # Logged from inside the span (rather than by Repl before calling
        # run) so Logger#turn's trace_id — the Phase 3 log_viz bridge's join
        # key — actually resolves to this turn's real span.
        @logger.turn(n: @turn) if @turn
        @context.reset_turn_tokens
        compact_if_needed

        loop do
          # Two independent ceilings; stop at whichever trips first. Limits are
          # *trigger thresholds*, not hard caps: when one is reached we stop
          # starting new work iterations and make exactly one terminal wind-down
          # call (counted in tokens, but not as another iteration).
          if iteration_limit_reached?
            @logger.limit_reached(kind: "max_iterations", n: @iteration, max: @max_iterations)
            return wrap_up("max_iterations")
          end
          if token_limit_reached?
            @logger.limit_reached(kind: "max_tokens", n: @context.turn_tokens, max: @max_turn_tokens)
            return wrap_up("max_tokens")
          end

          @iteration += 1

          Boukensha.tracer.in_span("boukensha.iteration", attributes: { "boukensha.iteration" => @iteration }) do
            @logger.iteration(n: @iteration, max: @max_iterations)
            payload = @builder.to_api_payload(**call_opts)
            @logger.request(payload: payload, messages: @context.messages, tools: @context.tools, iteration: @iteration, task: @task_name)

            response = @client.call(payload: payload, iteration: @iteration, task: @task_name, **call_opts)
            @logger.raw(data: response)
            parsed   = @builder.parse_response(response)
            record_usage(response)
            log_reasoning(parsed[:content])

            if parsed[:stop_reason] == "tool_use"
              handle_tool_calls(parsed[:content], response)
            else
              text = extract_text(parsed[:content])
              @logger.response(text: text, usage: response["usage"], stop_reason: parsed[:stop_reason], task: @task_name, backend: @builder.backend)
              @logger.turn_end(reason: "completed", iterations: @iteration, tokens: @context.turn_tokens)
              @context.add_message(:assistant, text)
              @stop_reason = :completed
              return text
            end
          end
        end
      end
    end

    private

    def iteration_limit_reached?
      @max_iterations.positive? && @iteration >= @max_iterations
    end

    def token_limit_reached?
      @max_turn_tokens.positive? && @context.turn_tokens >= @max_turn_tokens
    end

    # Per-call options shared by every model round-trip of the turn.
    def call_opts
      @max_output_tokens ? { max_output_tokens: @max_output_tokens } : {}
    end

    # Add this call's input+output to the cumulative turn total (the spend
    # budget) and refresh the known context size from input_tokens (compaction
    # pressure). The trigger is evaluated on pre-wrap-up spend; the reported
    # total includes the wind-down call too.
    def record_usage(response)
      usage = response["usage"] || {}
      @context.add_turn_tokens(usage["input_tokens"], usage["output_tokens"])
      @context.update_tokens(usage["input_tokens"].to_i)
    end

    def compact_if_needed
      return unless @context.needs_compaction?

      before  = @context.current_tokens
      dropped = @context.compact_messages!
      @logger.compaction(before: before, dropped: dropped, context_window: @context.context_window)
    end

    # One final, tools-disabled model call so the agent ends the turn in
    # character rather than aborting. Runs *outside* the counted loop: it never
    # re-checks the limits (so it cannot re-trigger) and does not increment
    # @iteration, though its tokens still count toward the reported turn total.
    # Falls back to a deterministic message if the call fails.
    def wrap_up(reason)
      @context.add_message(:user, WRAP_UP_DIRECTIVE)
      payload     = @builder.to_api_payload(tools: [], max_output_tokens: WRAP_UP_OUTPUT_TOKENS)
      @logger.request(payload: payload, messages: @context.messages, tools: [], iteration: @iteration, wrap_up: true, task: @task_name)
      response    = @client.call(payload: payload, tools: [], max_output_tokens: WRAP_UP_OUTPUT_TOKENS, task: @task_name)
      parsed_wrap = @builder.parse_response(response)
      text        = extract_text(parsed_wrap[:content])
      text        = fallback_message(reason) if text.strip.empty?
      record_usage(response)
      @logger.response(text: text, usage: response["usage"], stop_reason: parsed_wrap[:stop_reason], task: @task_name, backend: @builder.backend)
      @logger.turn_end(reason: reason, iterations: @iteration, tokens: @context.turn_tokens)
      @context.add_message(:assistant, text)
      @stop_reason = reason.to_sym
      text
    rescue ApiError
      msg = fallback_message(reason)
      @logger.turn_end(reason: reason, iterations: @iteration, tokens: @context.turn_tokens)
      @context.add_message(:assistant, msg)
      @stop_reason = reason.to_sym
      msg
    end

    def fallback_message(reason)
      "I reached my #{@max_iterations}-action limit for this turn before finishing " \
      "(#{reason}). Ask me to continue and I'll pick up from here."
    end

    def extract_text(content)
      content.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("\n")
    end

    # Emit one `reasoning` event per reasoning block so the viewer can show the
    # model's thinking as a first-class step. Empty, non-redacted blocks are
    # skipped to avoid noise (a redacted/omitted block still renders, since it
    # tells the viewer "the model thought here").
    def log_reasoning(content)
      content.each do |block|
        next unless block["type"] == "reasoning"

        redacted = block["redacted"] == true
        text     = block["text"].to_s
        next if text.strip.empty? && !redacted

        @logger.reasoning(text: text, redacted: redacted, task: @task_name)
      end
    end

    def handle_tool_calls(content, response)
      tool_calls = content.select { |b| b["type"] == "tool_use" }

      # Log any preamble text that accompanied the tool call (carries no usage —
      # the placeholder below owns the turn's usage chip), then the placeholder.
      preamble = extract_text(content)
      @logger.plan(text: preamble, task: @task_name) unless preamble.strip.empty?
      @logger.response(text: "(tool use — #{tool_calls.size} call#{'s' if tool_calls.size != 1})", usage: response["usage"],
                       stop_reason: "tool_use", task: @task_name, backend: @builder.backend)

      @context.add_message(:assistant, content)

      tool_calls.each do |block|
        name   = block["name"]
        args   = block["input"]
        use_id = block["id"]

        @logger.tool_call(name: name, args: args, task: @task_name)
        ok = true
        error_message = nil
        result = nil
        compacted = nil

        Boukensha.tracer.in_span("boukensha.tool_call", attributes: { "boukensha.tool.name" => name }) do |span|
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            result = @registry.dispatch(name, args)
          rescue StandardError => e
            result = "ERROR: #{e.class}: #{e.message}"
            ok = false
            error_message = e.message
          end
          dispatch_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000

          span.set_attribute("boukensha.tool.ok", ok)
          span.set_attribute("boukensha.tool.error", error_message) if error_message

          Metrics.tool_calls.add(1, attributes: { "tool_name" => name, "ok" => ok })
          Metrics.tool_duration.record(dispatch_ms, attributes: { "tool_name" => name })
          Metrics.errors.add(1, attributes: { "kind" => "tool_error" }) unless ok

          # Compacted here, still inside the span, so Compactor's own
          # boukensha.compaction span (Tier 2, when it fires) nests under
          # this tool_call span — matching the overview's span tree. The
          # tool.duration metric above is measured before this, so Tier 2's
          # latency (a separate, opt-in LLM round trip) never inflates the
          # "how long did the tool dispatch itself take" figure.
          compacted = @compactor.compact(name: name, result: result, ok: ok)
        end

        # The observability record always carries the raw, uncompacted
        # `result` (see Boukensha::Compactor's header comment for why that
        # must never change) plus, additively, `compacted` — exactly what's
        # about to go into @context.messages — so a viewer can show what was
        # actually injected without reconstructing it from a request payload.
        @logger.tool_result(name: name, result: result, ok: ok, error: error_message, compacted: compacted, task: @task_name)
        @context.add_message(:tool_result, compacted, tool_use_id: use_id)
      end
    end
  end
end
