require "opentelemetry-api"
require "opentelemetry-sdk"
require "opentelemetry-exporter-otlp"

begin
  require "opentelemetry-metrics-sdk"
  require "opentelemetry-exporter-otlp-metrics"
rescue LoadError
  # See docs/plans/observability/otel_and_logs/00_overview.md "Risk: Ruby
  # metrics SDK maturity" — these gems are still pre-1.0/experimental,
  # unlike the stable traces SDK required above. A load failure here
  # degrades to traces-only rather than taking Telemetry (and therefore the
  # whole agent) down with it.
end

module Boukensha
  # Owns TracerProvider/MeterProvider setup — the one place in the codebase
  # that talks to the OpenTelemetry SDK directly, so a Python port only ever
  # has to rewrite this file (see the overview's "Portability to Python").
  # Configuration is entirely standard OTel env vars — nothing boukensha-
  # specific to learn:
  #
  #   OTEL_EXPORTER_OTLP_ENDPOINT   default: http://localhost:4318 (Ruby's
  #                                 OTLP exporter is HTTP/protobuf, not gRPC
  #                                 — port 4318, not 4317)
  #   OTEL_SERVICE_NAME             default: "boukensha" (set below if unset)
  #   OTEL_TRACES_EXPORTER          default: otlp
  #   OTEL_METRICS_EXPORTER         default: otlp
  #
  # Fail-open, always — same posture as Compactor (see its header comment:
  # "a compaction bug must never be the reason a turn breaks"). `.tracer`/
  # `.meter` always return a usable instance; nothing downstream needs to
  # check whether telemetry is "really" configured:
  #
  #   - No collector running: OpenTelemetry::SDK.configure itself never
  #     talks to the network — it only constructs exporters. Spans/metrics
  #     get queued into a BatchSpanProcessor / PeriodicMetricReader and
  #     silently dropped when a background export attempt fails. Never
  #     SimpleSpanProcessor, which would export synchronously on the hot
  #     path — see phase1_ruby_sdk.md.
  #   - `observability.enabled: false` in settings.yaml: .configure is never
  #     called at all, so the global providers stay at opentelemetry-api's
  #     own default no-op ProxyTracerProvider/ProxyMeterProvider — zero SDK
  #     overhead, not just "exports nowhere".
  #   - Anything else going wrong during setup (bad endpoint URL, a metrics
  #     gem bug, ...): caught below and logged once; same no-op fallback.
  module Telemetry
    DEFAULT_SERVICE_NAME = "boukensha"

    class << self
      def tracer
        setup!
        OpenTelemetry.tracer_provider.tracer(DEFAULT_SERVICE_NAME, Boukensha::VERSION)
      end

      def meter
        setup!
        OpenTelemetry.meter_provider.meter(DEFAULT_SERVICE_NAME, version: Boukensha::VERSION)
      end

      # Test-only: undoes the setup! memoization so the next .tracer/.meter
      # call re-reads Boukensha.config / ENV from scratch.
      def reset!
        @configured = false
      end

      private

      def setup!
        return if @configured

        @configured = true
        return unless Boukensha.config.observability_enabled?

        ENV["OTEL_SERVICE_NAME"] ||= DEFAULT_SERVICE_NAME
        OpenTelemetry::SDK.configure
      rescue StandardError => e
        warn "[boukensha] telemetry setup failed (#{e.message}) — continuing without telemetry"
      end
    end
  end
end
