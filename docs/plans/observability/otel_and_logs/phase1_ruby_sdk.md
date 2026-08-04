# Phase 1 — Ruby SDK plumbing

**Depends on:** Phase 0 (an OTLP endpoint to point at). **Blocks:** Phase 2
(instrumentation needs a tracer/meter to instrument with).

Context: see [`00_overview.md`](00_overview.md) for the span tree,
attribute conventions, and metrics table this SDK setup needs to support,
and the "Risk: Ruby metrics SDK maturity" section — read that before
starting the metrics half of this phase.

## What to build

### Gemfile additions

Versions below were confirmed live against rubygems.org when the parent
plan was written — re-check before pinning if this phase starts much later:

```ruby
gem "opentelemetry-api", "~> 1.11"
gem "opentelemetry-sdk", "~> 1.13"
gem "opentelemetry-exporter-otlp", "~> 0.34"
gem "opentelemetry-metrics-sdk", "~> 0.15"       # still 0.x/experimental — see risk note
gem "opentelemetry-exporter-otlp-metrics", "~> 0.10"  # still 0.x/experimental
```

### New `lib/boukensha/telemetry.rb`

One module owning `TracerProvider` + `MeterProvider` setup, configured
entirely from standard OTel env vars:

- `OTEL_EXPORTER_OTLP_ENDPOINT`
- `OTEL_SERVICE_NAME=boukensha`
- `OTEL_TRACES_EXPORTER`
- `OTEL_METRICS_EXPORTER`

These are the same variables a Python SDK reads, so a `.env` written for
this step needs zero changes when a Python agent joins.

Exposes `Boukensha.tracer` / `Boukensha.meter` alongside the existing
`Boukensha.config`/`Boukensha.debug?` module accessors in
`lib/boukensha.rb`.

### Fail-open — hard requirement

Matches this codebase's existing convention (`Compactor#compact`'s header
comment: *"a compaction bug must never be the reason a turn breaks"*).

- If the collector isn't running (the common case for anyone who hasn't
  run `docker compose up`), span/metric export must degrade to
  dropped-on-the-floor — never a raised exception, never added latency on
  the agent's hot path.
- This is `BatchSpanProcessor`'s default behavior (async, bounded queue,
  drops on export failure). The setup module **must** use it — never
  `SimpleSpanProcessor`. Worth an explicit test — see
  [`phase4_tests.md`](phase4_tests.md).
- `observability.enabled: false` in `settings.yaml` (new `Config` reader,
  same pattern as `compactor_enabled?`) additionally makes the whole thing
  a no-op provider — zero SDK overhead — for anyone who doesn't want it at
  all.

## Acceptance criteria

- `Boukensha.tracer` / `Boukensha.meter` are available module-wide after
  `Telemetry` setup runs.
- With the Phase 0 collector up and `OTEL_EXPORTER_OTLP_ENDPOINT` pointed
  at it, a manually-created test span/metric from a Ruby console shows up
  in Jaeger/Prometheus.
- With the collector down (or endpoint unset), the same manual test causes
  no exception and no added latency — confirms fail-open before Phase 2
  wires this into the hot path.
- `observability.enabled: false` in `settings.yaml` produces a no-op
  provider (verify via a quick manual check or spike test — full coverage
  lands in Phase 4).

## Risk checkpoint (do this before Phase 2)

Per the overview's risk note: spike the metrics gems
(`opentelemetry-metrics-sdk` 0.15, `opentelemetry-exporter-otlp-metrics`
0.10) end-to-end (a counter increment reaching Prometheus through the
collector) before committing to Phase 2's metric-emitting instrumentation.
If they don't work as expected, ship Phase 1/2 traces-only and treat
metrics as a fast-follow once the gems mature — don't block the rest of
this plan on the least-stable piece.
