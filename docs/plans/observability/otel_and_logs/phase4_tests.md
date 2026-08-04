# Phase 4 — Tests

**Depends on:** Phase 2 (spans/metrics must exist to assert on). Can run
before or independent of Phase 3 (the `log_viz` bridge isn't Ruby-SDK test
surface).

Context: see [`00_overview.md`](00_overview.md) and
[`phase1_ruby_sdk.md`](phase1_ruby_sdk.md)'s "Fail-open — hard requirement"
section — the fail-open test below is the load-bearing one.

## What to build

Ruby OTel ships
`OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter` specifically for
this — no live collector needed for unit tests, matching this project's
existing Minitest conventions (`test/test_logger.rb`, `test/test_client.rb`).

- **`test/test_telemetry.rb`** (new) — spans get created with the right
  parent/child nesting and `gen_ai.*` attributes for a scripted
  request/tool-call sequence, using the in-memory exporter. Should assert
  the full tree shape from the overview's span-tree diagram, not just that
  spans exist.
- **Extend `test/test_client.rb`** — a request still succeeds and returns
  the same value when the configured OTLP endpoint is unreachable (the
  fail-open requirement from Phase 1, actually verified — e.g. point
  `OTEL_EXPORTER_OTLP_ENDPOINT` at a closed port and confirm no exception
  and no meaningful latency added, not just asserted in a comment).
- **Extend `test/test_compactor.rb`** — Tier 2's nested span appears as a
  child of the `tool_call` span it was triggered from (confirms the
  "instrument `Client#call` once, nesting falls out naturally" claim from
  Phase 2 actually holds for the compaction path specifically).

## Acceptance criteria

- All three test files pass under the existing Minitest runner
  (`rake test` or equivalent — check this step's existing test invocation).
- The fail-open test in `test_client.rb` fails loudly if someone
  accidentally swaps `BatchSpanProcessor` for `SimpleSpanProcessor` later
  (i.e. it should actually exercise the unreachable-endpoint path, not just
  check config).
- `test_telemetry.rb`'s nesting assertions fail if a future change breaks
  parent/child span relationships — i.e. they check `parent_span_id`
  linkage, not just span *count*.
