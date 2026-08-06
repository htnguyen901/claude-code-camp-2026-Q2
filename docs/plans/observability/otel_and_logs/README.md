## OTel and Logs

Execution/implementation plan for
[`docs/plans/observability/observability.md`](../observability.md), broken
into per-phase files for standalone execution:

- [`00_overview.md`](00_overview.md) — shared context: goal, tool stack,
  design (span tree, attributes, metrics), risk, and what's out of scope.
  Read this first; each phase file below leans on it rather than repeating
  it.
- [`phase0_infra.md`](phase0_infra.md) — docker-compose stack (Collector,
  Jaeger, Prometheus, Grafana).
- [`phase1_ruby_sdk.md`](phase1_ruby_sdk.md) — Ruby OTel SDK setup,
  fail-open guarantee.
- [`phase2_instrumentation.md`](phase2_instrumentation.md) — wrap the
  actual agent code in spans/metrics.
- [`phase3_log_viz_bridge.md`](phase3_log_viz_bridge.md) — "View trace"
  link from `log_viz` into Jaeger.
- [`phase4_tests.md`](phase4_tests.md) — Minitest coverage, including the
  fail-open guarantee.
- [`phase5_docs.md`](phase5_docs.md) — README updates for the step.

Execute in order (0 → 5); each phase file states its own dependency on the
one(s) before it.
