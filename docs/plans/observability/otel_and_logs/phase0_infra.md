# Phase 0 — Infra

**Depends on:** nothing. **Blocks:** Phase 1 (SDK needs somewhere to export to).

Context: see [`00_overview.md`](00_overview.md) for the full tool-stack
rationale (why a Collector, why push/OTLP, why self-hosted). This file is
the actionable checklist for standing up the backend stack.

## What to build

`week2_observability/otel/docker-compose.yml` — sits alongside `log_viz`,
**not** inside `15_observability`, because it's shared infrastructure, not
step-specific code (and stays reusable once a Python agent joins).

Services:

- **`otel-collector`** (`otel/opentelemetry-collector-contrib`)
  - OTLP receiver: gRPC `4317` / HTTP `4318`.
  - Exports traces via OTLP to Jaeger.
  - Exposes a `/metrics` endpoint for Prometheus to scrape (`prometheus`
    exporter in the collector config).
  - Needs a `collector-config.yaml` (receivers: otlp; exporters: otlp to
    jaeger, prometheus; pipelines: traces → jaeger, metrics → prometheus).
- **`jaeger`** (`jaegertracing/all-in-one`)
  - UI on `16686`.
  - Native OTLP ingestion from the collector (no separate Jaeger-specific
    exporter config needed on the collector side beyond the OTLP exporter
    pointed at Jaeger's OTLP port).
- **`prometheus`**
  - Scrapes the collector's `/metrics` endpoint — needs a
    `prometheus.yml` scrape config targeting `otel-collector:<port>`.
- **`grafana`**
  - Provisioned with Jaeger + Prometheus datasources via Grafana's
    provisioning YAML (`provisioning/datasources/*.yaml`).
  - One starter dashboard, also provisioned (`provisioning/dashboards/*`),
    with: request latency p50/p95, tokens/cost over time, tool error rate,
    active sessions.
  - Goal: `docker compose up` produces a working dashboard with **no
    manual clicking**.

## Acceptance criteria

- `cd week2_observability/otel && docker compose up` brings up all four
  services with no manual configuration steps.
- Jaeger UI reachable at `http://localhost:16686` (empty — no traces yet,
  that's Phase 1/2).
- Prometheus UI reachable, collector's `/metrics` target shows as `UP`.
- Grafana reachable, Jaeger + Prometheus datasources already wired, starter
  dashboard already present (panels will be empty until Phase 1/2 ship
  data — that's expected at this point).
- Sending a manual OTLP test span/metric (e.g. via `otel-cli` or a curl to
  the collector's HTTP receiver) shows up in Jaeger / Prometheus — proves
  the pipeline end-to-end before any Ruby code depends on it.

## Notes

- Keep collector config permissive about missing metrics initially (traces
  are the low-risk path per the overview's risk note) so Phase 1 can ship
  traces-only if the metrics gems turn out rough.
- No auth/TLS needed — local-only, loopback-bound ports are sufficient for
  this project's offline/local-dev posture.
