require "json"
require "fileutils"
require "securerandom"
require "time"
require "opentelemetry-api"

module Boukensha
  class Logger
    DEFAULT_SESSION_DIR = "sessions".freeze

    attr_reader :session_id, :path

    def initialize(session_id: nil, dir: nil, log: nil, snapshot: {})
      @session_id   = session_id || generate_session_id
      @path         = log || File.join(dir || default_dir, "#{@session_id}.jsonl")
      @session_task = snapshot[:task] || snapshot["task"]

      FileUtils.mkdir_p(File.dirname(@path))
      @log_io = File.open(@path, "a")
      write_log({ phase: "session_start" }.merge(snapshot))
      Metrics.sessions_active.add(1, attributes: { "task" => @session_task&.to_s }.compact)
    end

    # trace_id/span_id let the Phase 3 log_viz bridge link this line back to
    # the matching Jaeger trace — see docs/plans/observability/otel_and_logs/
    # 00_overview.md "Bridging the two systems". nil (not an all-zero id)
    # when called outside any span, so a viewer can tell "no trace" apart
    # from a real one.
    def turn(n:)
      span_context = OpenTelemetry::Trace.current_span.context
      write_log(
        phase: "turn", n: n,
        trace_id: (span_context.hex_trace_id if span_context.valid?),
        span_id: (span_context.hex_span_id if span_context.valid?)
      )
    end

    def iteration(n:, max:)
      write_log(phase: "iteration", n: n, max: max)
    end

    def limit_reached(kind:, n:, max:)
      write_log(phase: "limit_reached", kind: kind, n: n, max: max)
    end

    def turn_end(reason:, iterations:, tokens: nil)
      write_log(phase: "turn_end", reason: reason, iterations: iterations, tokens: tokens)
    end

    # `messages`/`tools` are the backend-agnostic Context collections actually
    # used to build `payload` (not the wire payload itself) — every backend
    # serializes them under a different key/shape (see backends/*.rb), so
    # summary stats and the last-user-text must come from here, not from
    # digging into `payload`.
    def request(payload:, messages:, tools:, iteration:, wrap_up: false)
      write_log(
        phase:          "request",
        iteration:      iteration,
        wrap_up:        wrap_up,
        model:          payload[:model] || payload["model"],
        payload:        payload,
        bytes:          JSON.generate(payload).bytesize,
        message_count:  messages.size,
        tool_count:     tools.size,
        last_user_text: messages.reverse.find { |m| m.role == :user }&.content
      )
    end

    def compaction(before:, dropped:, context_window:)
      write_log(phase: "compaction", before: before, dropped: dropped, context_window: context_window)
    end

    def tool_call(name:, args:)
      write_log(phase: "tool_call", name: name, args: args)
    end

    # `compacted:` is purely additive observability — the raw `result:` field
    # is always the untouched tool reply (see Boukensha::Compactor's header
    # comment for why that must never change); `compacted` records what
    # Agent actually injected into @context.messages for this call, when it
    # differs, so a viewer can show "what's about to be sent" without having
    # to expand a request payload. nil for callers that don't compact.
    def tool_result(name:, result:, ok: true, error: nil, compacted: nil)
      write_log(phase: "tool_result", name: name, result: result.to_s, ok: ok, error: error,
                compacted: compacted&.to_s)
    end

    def response(text:, usage: nil, stop_reason: nil, task: nil, backend: nil)
      write_log(
        {
          phase: "response",
          text: text.to_s.strip,
          usage: usage,
          stop_reason: stop_reason
        }.merge(execution_metadata(task: task, backend: backend, usage: usage))
      )
    end

    def reasoning(text:, redacted: false)
      write_log(phase: "reasoning", text: text.to_s, redacted: redacted)
    end

    def plan(text:)
      write_log(phase: "plan", text: text.to_s.strip)
    end

    def raw(data:)
      return unless Boukensha.debug?

      write_log(phase: "raw", data: data)
    end

    def subscribe(&block)
      @subscribers ||= []
      @subscribers << block
    end

    def close
      if @log_io
        Metrics.sessions_active.add(-1, attributes: { "task" => @session_task&.to_s }.compact)
        @log_io.close
        @log_io = nil
      end
    end

    private

    def default_dir
      File.join(Boukensha.config.dir, DEFAULT_SESSION_DIR)
    end

    def write_log(event)
      @log_io.puts JSON.generate(event.merge(session_id: @session_id, at: Time.now.iso8601))
      @log_io.flush
      @subscribers&.each { |s| s.call(event) }
    end

    def generate_session_id
      "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{SecureRandom.hex(4)}"
    end

    def execution_metadata(task:, backend:, usage:)
      return {} unless task || backend || usage

      tokens = usage_tokens(usage)
      metadata = {
        task: task_name(task),
        provider: provider_name(backend),
        model: backend&.model,
        usage_unit: backend&.respond_to?(:usage_unit) ? backend.usage_unit : nil,
        usage_level: backend&.respond_to?(:usage_level) ? backend.usage_level : nil,
        input_tokens: tokens[:input],
        output_tokens: tokens[:output],
        cost_usd: estimate_cost(backend, tokens)
      }
      metadata.compact
    end

    def task_name(task)
      task&.respond_to?(:task_name) ? task.task_name : task&.to_s
    end

    def provider_name(backend)
      backend&.provider_name
    end

    def usage_tokens(usage)
      usage ||= {}
      {
        input: first_integer(usage, "input_tokens", "prompt_tokens", "promptTokenCount", "prompt_eval_count"),
        output: first_integer(usage, "output_tokens", "completion_tokens", "candidatesTokenCount", "eval_count")
      }
    end

    def first_integer(hash, *keys)
      keys.each do |key|
        value = hash[key] || hash[key.to_sym]
        return Integer(value) unless value.nil?
      end
      nil
    rescue ArgumentError, TypeError
      nil
    end

    def estimate_cost(backend, tokens)
      return nil unless backend&.respond_to?(:estimate_cost)
      return nil unless tokens[:input] && tokens[:output]

      backend.estimate_cost(input_tokens: tokens[:input], output_tokens: tokens[:output])
    end
  end
end
