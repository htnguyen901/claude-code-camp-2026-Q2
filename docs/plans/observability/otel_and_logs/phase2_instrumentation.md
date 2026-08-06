# Phase 2 — Instrumentation

**Depends on:** Phase 1 (`Boukensha.tracer` / `Boukensha.meter` must exist).
**Blocks:** Phase 3 (bridge needs `trace_id` on `turn` events), Phase 4
(tests need spans to assert on).

Context: see [`00_overview.md`](00_overview.md) for the span tree diagram
and the full attribute/metric tables — this file only lists *where in the
code* each wraps in.

## Guiding constraint

Each touch point is a thin wrap around code that already exists — no new
business logic, matching this codebase's "add a field, don't restructure"
style seen across the last four steps.

## Touch points

- **`Agent#run`** (`lib/boukensha/agent.rb:31`) — wrap the method body in
  the `turn` span (root). The `@iteration` loop body gets the `iteration`
  span.
- **`Client#call`** (`lib/boukensha/client.rb:25`) — wrap in an
  `llm_request` span. Instrumenting here (rather than at each call site)
  covers, for free, via Ruby's current-span context nesting:
  - `Agent#run`'s `@client.call` (`agent.rb:54`)
  - `Agent#wrap_up`'s call (`agent.rb:114`)
  - `Compactor`'s Tier 2 call (`compactor.rb:192`)

  One instrumentation point, three callers benefit, correct nesting falls
  out naturally.
- **`Agent#handle_tool_calls`'s per-call loop** (`agent.rb:167-191`) — wrap
  `@registry.dispatch` in the `tool_call` span.
- **`Compactor#compact_prose`** (`compactor.rb:173`) — wrap the
  cache-miss path in the `compaction` span. No new metric needed here — its
  `call_model` already inherits an `llm_request` span from the `Client#call`
  instrumentation above.
- **`Boukensha.run` / `Boukensha.repl`** (`lib/boukensha.rb:45`, `:102`) —
  construct the tracer/meter providers once per process; pass them (or read
  them off the `Boukensha` module) into `Logger.new`'s existing `snapshot:`
  hash so `session_start` carries trace-provider info for debugging.
- **`Logger#turn`** (`logger.rb:21`) — add `trace_id`/`span_id` fields
  (`OpenTelemetry::Trace.current_span.context`) for the Phase 3 `log_viz`
  bridge.

## Attributes to attach (from the overview's convention table)

- `llm_request` span: `gen_ai.system`, `gen_ai.request.model`,
  `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`,
  `gen_ai.response.finish_reason`, `boukensha.cost_usd`,
  `boukensha.iteration`.
- `tool_call` span: `boukensha.tool.name`, `boukensha.tool.ok`,
  `boukensha.tool.error` (when present).
- `turn` (root) span: `boukensha.session_id`, `boukensha.task`,
  `boukensha.provider`, `boukensha.model`.

## Metrics to emit (skip if the Phase 1 risk checkpoint failed)

`boukensha.llm.requests`, `boukensha.llm.request.duration`,
`boukensha.llm.tokens`, `boukensha.llm.cost`, `boukensha.tool.calls`,
`boukensha.tool.duration`, `boukensha.errors`, `boukensha.sessions.active`
— full labels in the overview's metrics table.
`boukensha.sessions.active`: +1 at `Logger#initialize`, −1 at
`Logger#close` (already called from an `ensure` in both `Boukensha.run` and
`Boukensha.repl`).

## Acceptance criteria

- Running a real `boukensha` turn against the Phase 0 stack produces, in
  Jaeger, a `boukensha.turn` root span with the expected
  `iteration → llm_request` / `tool_call → compaction → llm_request` tree
  shape matching the overview's diagram.
- All attributes listed above are present and correctly populated (spot
  check values against the corresponding `.jsonl` log line for the same
  turn — they should agree).
- With `observability.enabled: false`, running the same turn produces zero
  spans/metrics and no behavior change vs. today.
- If metrics shipped: Prometheus shows non-zero values for at least
  `boukensha.llm.requests` and `boukensha.tool.calls` after a session with
  both an LLM call and a tool call.
