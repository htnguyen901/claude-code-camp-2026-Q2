module Boukensha
  # Owns the named metric instruments from the overview's metrics table
  # (docs/plans/observability/otel_and_logs/00_overview.md). Mirrors
  # Boukensha::Telemetry's role for the tracer: a single place that talks to
  # Boukensha.meter directly, with instruments memoized so a hot-path request
  # or tool call reuses the same Counter/Histogram/UpDownCounter object
  # instead of re-registering one on every call.
  module Metrics
    class << self
      def llm_requests
        instrument(:llm_requests) { Boukensha.meter.create_counter("boukensha.llm.requests", unit: "1", description: "LLM API requests") }
      end

      def llm_request_duration
        instrument(:llm_request_duration) { Boukensha.meter.create_histogram("boukensha.llm.request.duration", unit: "ms", description: "LLM API request duration") }
      end

      def llm_tokens
        instrument(:llm_tokens) { Boukensha.meter.create_counter("boukensha.llm.tokens", unit: "1", description: "LLM tokens by direction") }
      end

      def llm_cost
        instrument(:llm_cost) { Boukensha.meter.create_counter("boukensha.llm.cost", unit: "USD", description: "Estimated LLM spend") }
      end

      def tool_calls
        instrument(:tool_calls) { Boukensha.meter.create_counter("boukensha.tool.calls", unit: "1", description: "Tool dispatches") }
      end

      def tool_duration
        instrument(:tool_duration) { Boukensha.meter.create_histogram("boukensha.tool.duration", unit: "ms", description: "Tool dispatch duration") }
      end

      def errors
        instrument(:errors) { Boukensha.meter.create_counter("boukensha.errors", unit: "1", description: "Errors by kind") }
      end

      def sessions_active
        instrument(:sessions_active) { Boukensha.meter.create_up_down_counter("boukensha.sessions.active", unit: "1", description: "Currently active sessions") }
      end

      # Test-only: forces the next call to re-fetch instruments from
      # Boukensha.meter (paired with Telemetry.reset!).
      def reset!
        @instruments = nil
      end

      private

      def instrument(key)
        @instruments ||= {}
        @instruments[key] ||= yield
      end
    end
  end
end
