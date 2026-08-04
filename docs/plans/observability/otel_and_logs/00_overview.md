# Overview: Real Observability (Traces + Metrics) on Top of the Existing Log Layer

Shared context for all phase files in this directory. Each phase file
(`phase0_*.md` … `phase5_*.md`) is meant to be executed (and reviewed) on its
own, but all of them lean on the decisions recorded here rather than
re-deriving them. If a phase file and this overview ever disagree, this
overview wins — update the phase file.

Full original plan (superseded by this breakdown, kept for the historical
narrative/reasoning): `docs/plans/observability/observability.md`.

## Goal

Implement observability — traces, logs, and monitoring, together — for the
`boukensha` agent (`week2_observability/ruby/15_observability`), with a tool
stack that ports cleanly to a Python agent later.

## Core concepts (verified, standard CNCF/OpenTelemetry framing)

- **Observability** — how well you can answer new questions about a
  system's internal state from its external outputs, without shipping new
  code to answer each one.
- **Telemetry** — the raw signals: logs, traces, metrics (sometimes a
  fourth, profiles).
- **APM** — tooling that consumes telemetry to show transaction health and
  bottlenecks.
- **Traces vs. logs** — usually the same underlying events, differently
  shaped. A trace is a tree of timed spans (`request → llm_call, tool_call,
  tool_call`) showing *how long* and *what called what*; a log is a flat,
  timestamped list of facts. This project has excellent logs and zero
  traces — no span started/ended anywhere, so there's no way today to
  answer "how long did that tool call take" without eyeballing timestamp
  gaps by hand.

## Current state (verified by reading the code)

Not a green field. `week2_observability/ruby/15_observability` already has
a real, working logs pillar:

- **`Boukensha::Logger`** (`lib/boukensha/logger.rb`) — one structured JSON
  line per event (`session_start`, `turn`, `iteration`, `request`,
  `response`, `tool_call`, `tool_result`, `compaction`, `reasoning`, `plan`,
  `turn_end`, `limit_reached`) to `.boukensha/sessions/<session_id>.jsonl`.
  Every event carries `session_id` + an ISO8601 `at` timestamp, but no
  span/parent id and no duration.
- **`log_viz`** (`week2_observability/log_viz`, Sinatra + SQLite) — a
  purpose-built viewer: per-session transcript with token/cost bars, a
  cross-session world map (SQLite-backed `WorldMap`), a room inspector,
  live-session markers. Nothing here is being thrown away.
- **What's genuinely missing**: traces (no span concept, no per-phase
  duration, no parent/child call tree), metrics (no counters/histograms —
  every number in `log_viz` is recomputed from the full `.jsonl` on every
  page load), and any standard export format — everything today is bespoke
  to this one Ruby codebase, not reusable if a Python agent joins later.

### This supersedes a prior "not now" decision — on purpose

`docs/plans/observability/scaling_and_telemetry_evaluation.md` (§Q3)
already asked "should this adopt OpenTelemetry?" and concluded **not now**.
It listed explicit revisit triggers: *"precise per-phase latency becomes
something worth measuring"* and needing to *"query traces without custom
UI."* Today's ask satisfies both, so this plan treats that evaluation as
superseded rather than re-litigating it. Its "cheap hedge" (name fields
loosely after OTel's `gen_ai.*` conventions) is picked up directly below.

## Tool stack

**OpenTelemetry (OTel), hybrid with the existing bespoke layer — not a
replacement for it.**

| Pillar | Owner | Why |
|---|---|---|
| Domain-specific logs/UI (transcript, world map, room inspector, cost breakdown) | **Keep `Boukensha::Logger` + `log_viz`, unchanged in shape** | MUD-domain reconstruction (room graphs, discoveries, compaction diffing) has no OTel equivalent — forcing it into spans would be a strictly worse rebuild of something that already works. |
| Traces (per-turn/iteration/request/tool-call latency, call trees) | **New: OpenTelemetry Ruby SDK → OTLP → Jaeger** | Answers "what took the time." Standard wire format (OTLP) means a Python port only rewrites the ~150-line SDK-setup module. |
| Metrics (request/tool counters, latency histograms, token/cost counters, live-agent gauge) | **New: OTel Ruby Metrics SDK → OTLP → Prometheus** | Turns "recompute from the whole file on every page load" into real aggregates; replaces `WorldMap`'s file-mtime heuristic with a real `UpDownCounter`. |
| Dashboards / cross-signal view | **New: Grafana**, reading Jaeger + Prometheus | One pane of glass across both signals; `log_viz` stays linked from it for domain drill-down. |
| Backend hosting | **Self-hosted, `docker-compose`**, local only | Matches this project's offline/WSL2 local-dev posture — no account, no network dependency. |

**Why a Collector sits in front of Jaeger/Prometheus**: it's the piece
specifically about the *Python port*. The SDK only ever needs to know one
thing — an OTLP endpoint — never "Jaeger's API" or "Prometheus's
remote-write format." Swapping backends becomes a collector-config change,
zero application code touched, in either language.

**Why push (OTLP), not Prometheus's usual pull/scrape model**: `boukensha`
is a one-shot CLI process or REPL session, not a long-lived server — it
often exits before a scraper's next interval would hit it. The collector
receives OTLP pushes and is itself what Prometheus scrapes.

### What was deliberately not chosen

- **Cloud SaaS backend (e.g. Honeycomb)** — self-hosted was the explicit
  answer to the clarifying question; keeps this offline-capable.
- **Routing logs through the OTel stack too (e.g. Loki)** — would duplicate
  the `.jsonl`/`log_viz` pipeline for no gain: nothing in Loki can show a
  room graph, and Ruby's OTel Logs SDK is the least mature of the three
  signals. `session_id` is the join key between the two systems — that's
  enough correlation without merging the pipelines.
- **MCP-daemon (mud-manager) trace propagation** — would need injecting
  `traceparent` into MCP's JSON-RPC params and instrumenting a separate
  codebase. Out of scope; see "Not doing" below.

## Design

### Span tree

One trace per **turn** (`Agent#run` call), matching the granularity
`Boukensha::Logger#turn`/`#turn_end` already use — not per-session, since a
REPL session is many turns and collapsing them into one trace would make
the waterfall unreadable.

```
turn (root span, name: "boukensha.turn")
├─ iteration (one per loop pass in Agent#run)
│  ├─ llm_request (wraps Client#call — the network round trip + retries)
│  └─ tool_call (one per dispatched tool, wraps Registry#dispatch)
│     └─ compaction (child of tool_call, when Compactor Tier 2 fires — this
│        one is itself a full LLM round trip via Compactor#call_model, so it
│        gets its own nested llm_request span for free once Client is
│        instrumented once, generically)
└─ wrap_up (Agent#wrap_up's terminal call, when a limit trips)
```

`compact_if_needed` (context-window compaction, distinct from the
`Compactor` class above — confusing name collision already in the codebase,
not introduced by this plan) gets its own sibling span on the turn when it
fires.

### Attributes — aligned to OTel's `gen_ai.*` semantic conventions

Naming spans/attributes after the existing (if still-evolving) `gen_ai.*`
conventions is the "cheap hedge" the prior evaluation flagged as worth
doing for free — and it's also what makes a Python port idiomatic rather
than a reinvention, since `gen_ai.*` is language-agnostic by design.

- `llm_request` span: `gen_ai.system` (provider), `gen_ai.request.model`,
  `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`,
  `gen_ai.response.finish_reason` (stop_reason), plus
  `boukensha.cost_usd`, `boukensha.iteration` (no standard convention for
  cost/iteration; project-prefixed).
- `tool_call` span: `boukensha.tool.name`, `boukensha.tool.ok`,
  `boukensha.tool.error` (when present).
- `turn` (root) span: `boukensha.session_id`, `boukensha.task`,
  `boukensha.provider`, `boukensha.model` — this is the join key back to
  `log_viz` (below).

### Metrics

| Name | Type | Labels |
|---|---|---|
| `boukensha.llm.requests` | Counter | provider, model, task |
| `boukensha.llm.request.duration` | Histogram (ms) | provider, model |
| `boukensha.llm.tokens` | Counter | provider, model, direction (input/output/cache_read) |
| `boukensha.llm.cost` | Counter (USD) | provider, model, task |
| `boukensha.tool.calls` | Counter | tool_name, ok |
| `boukensha.tool.duration` | Histogram (ms) | tool_name |
| `boukensha.errors` | Counter | kind (api_error, tool_error) |
| `boukensha.sessions.active` | UpDownCounter | task |

`boukensha.sessions.active` (+1 at `Logger#initialize`, −1 at
`Logger#close`, already called from an `ensure` in both `Boukensha.run` and
`Boukensha.repl`) ships "how many agents are playing right now" as a real
gauge — exactly what `scaling_and_telemetry_evaluation.md` Q2 built as a
file-mtime heuristic over `WorldMap` instead. Both can coexist — Grafana
gets the gauge, `log_viz`'s map keeps its richer per-session detail
(current room, task, model) that a bare counter can't carry.

### Bridging the two systems: `session_id` as the join key

`Logger#initialize` already generates `session_id` before anything else.
The turn root span's `boukensha.session_id` attribute is set to the same
value, and (new) `Logger#turn` additionally records the active
`trace_id`/`span_id` (`OpenTelemetry::Trace.current_span.context`) on that
event. `log_viz`'s session page then renders a "View trace in Jaeger" link
per turn, built from that `trace_id` and the configured Jaeger UI base URL
— one click from a familiar transcript view into the new latency waterfall,
without merging the two rendering pipelines.

## Portability to Python — what actually carries over

Everything in Phase 0 (docker-compose, collector config, Jaeger,
Prometheus, Grafana dashboards) is untouched by language. A Python port
only rewrites Phase 1's ~150-line SDK-setup module using
`opentelemetry-sdk` + `opentelemetry-exporter-otlp` (same OTLP wire format,
same env vars) and re-applies Phase 2's wrapping at the equivalent call
sites. Phases 3/5 (the `log_viz` bridge, README) are Ruby/this-repo-specific
either way and wouldn't port regardless of stack choice.

## Risk: Ruby metrics SDK maturity

Verified live against rubygems.org while writing the original plan:
`opentelemetry-metrics-sdk` is at **0.15.0** and
`opentelemetry-exporter-otlp-metrics` at **0.10.0** — both still pre-1.0,
unlike `opentelemetry-sdk` (traces) at a stable **1.13.0**. Traces are
low-risk; metrics may have rough edges (API churn, gaps vs. the spec).
**Mitigation, not a blocker**: build traces first (Phases 0-2's
`llm_request`/`tool_call` spans), confirm the metrics gems work as expected
in a spike before committing Phase 2's metric-emitting code, and if they
don't, ship traces alone for this step with metrics as a fast-follow once
the gems mature.

## Not doing (explicitly out of scope)

- **MCP/mud-manager trace propagation** — would need instrumenting a
  separate codebase and threading `traceparent` through MCP's stdio
  JSON-RPC. A `tool_call` span still shows total dispatch latency
  (agent-side wait time) without this; just not a breakdown of what
  mud-manager itself spent time on. Natural extension once this ships.
- **Alerting** (Grafana alert rules, paging) — no on-call for a local dev
  tool; dashboards are for looking at, not paging on.
- **Moving logs into the OTel pipeline (Loki, etc.)** — see "What was
  deliberately not chosen," above.
- **Multi-agent live dashboard redesign** — `scaling_and_telemetry_
  evaluation.md` Q2's map-based live view stays as-is;
  `boukensha.sessions.active` is an additive signal for Grafana, not a
  replacement.

## Phase index

| Phase | File | Depends on |
|---|---|---|
| 0 — Infra | [`phase0_infra.md`](phase0_infra.md) | — |
| 1 — Ruby SDK plumbing | [`phase1_ruby_sdk.md`](phase1_ruby_sdk.md) | Phase 0 |
| 2 — Instrumentation | [`phase2_instrumentation.md`](phase2_instrumentation.md) | Phase 1 |
| 3 — `log_viz` bridge | [`phase3_log_viz_bridge.md`](phase3_log_viz_bridge.md) | Phase 2 |
| 4 — Tests | [`phase4_tests.md`](phase4_tests.md) | Phase 2 (Phase 3 optional) |
| 5 — Docs | [`phase5_docs.md`](phase5_docs.md) | Phases 0-4 |
