# Plan: Real Observability (Traces + Metrics) on Top of the Existing Log Layer

## Goal

Implement observability — traces, logs, and monitoring, together — for the
`boukensha` agent (`week2_observability/ruby/15_observability`), with a tool
stack that ports cleanly to a Python agent later.

## Verifying the core concepts

The definitions in the original ask are correct and standard (they're the
CNCF/OpenTelemetry framing):

- **Observability** — how well you can answer new questions about a
  system's internal state from its external outputs, without shipping new
  code to answer each one.
- **Telemetry** — the raw signals: logs, traces, metrics (sometimes a
  fourth, profiles).
- **APM** — tooling that consumes telemetry to show transaction health and
  bottlenecks.

One addition worth having explicitly in view: **traces** and **logs** are
usually the same underlying events, differently shaped. A trace is a tree of
timed spans (`request → llm_call, tool_call, tool_call`) that shows *how
long* and *what called what*; a log is a flat, timestamped list of facts.
This project already has excellent logs. It has no traces at all — no span
started/ended anywhere, so there's no answer today to "how long did that
tool call take" or "was the 8-second turn dominated by the LLM call or the
MUD round-trip" without eyeballing timestamp gaps by hand.

## Current state (verified by reading the code, not assumed)

This is not a green field. `week2_observability/ruby/15_observability`
already has a real, working logs pillar:

- **`Boukensha::Logger`** (`lib/boukensha/logger.rb`) — writes one
  structured JSON line per event (`session_start`, `turn`, `iteration`,
  `request`, `response`, `tool_call`, `tool_result`, `compaction`,
  `reasoning`, `plan`, `turn_end`, `limit_reached`) to
  `.boukensha/sessions/<session_id>.jsonl`. Every event carries
  `session_id` + an ISO8601 `at` timestamp, but no span/parent id and no
  duration — durations are only reconstructable by diffing two events'
  timestamps by hand.
- **`log_viz`** (`week2_observability/log_viz`, Sinatra + SQLite) — a
  purpose-built viewer over those `.jsonl` files: per-session transcript
  with token/cost composition bars, a cross-session world map (SQLite-backed
  incremental index, `WorldMap`), a room inspector, live-session markers.
  This is a genuinely good bespoke "logs + a bit of monitoring" UI, and nine
  prior plan docs in this directory (`player_journey_map.md`,
  `room_world_inspector.md`, `world_map_visualization.md`,
  `token_composition_observability.md`, etc.) went into building it well.
  **Nothing here is being thrown away.**
- **What's genuinely missing**: traces (no span concept, no per-phase
  duration, no parent/child call tree), metrics (no counters/histograms —
  every number in `log_viz` today is recomputed from the full `.jsonl` on
  every page load, not a live aggregate), and any standard export format —
  everything is bespoke to this one Ruby codebase, so none of it is
  reusable if a Python agent joins later.

### This supersedes a prior "not now" decision — on purpose

`docs/plans/observability/scaling_and_telemetry_evaluation.md` (§Q3, still
in this directory) already asked "should this adopt OpenTelemetry?" and
concluded **not now** — reasoning that nothing at the time needed per-phase
latency, the project was single-machine/single-person, and log_viz's
room/world graph doesn't map onto OTel's span model anyway (still true —
see "What log_viz keeps owning," below). It listed explicit revisit
triggers: *"precise per-phase latency becomes something worth measuring"*
and needing to *"query traces without custom UI."* Today's ask — explicit
traces, plus a stack that ports to Python — satisfies both, so this plan
treats that evaluation as superseded rather than re-litigating it. The
"cheap hedge" it proposed (name fields loosely after OTel's `gen_ai.*`
conventions) is picked up directly in the design below.

## Recommended tool stack

**OpenTelemetry (OTel), hybrid with the existing bespoke layer — not a
replacement for it.**

| Pillar | Owner | Why |
|---|---|---|
| Domain-specific logs/UI (transcript, world map, room inspector, cost breakdown) | **Keep `Boukensha::Logger` + `log_viz`, unchanged in shape** | This is MUD-domain reconstruction (room graphs, discoveries, compaction diffing) that has no OTel equivalent — forcing it into spans would be a strictly worse rebuild of something that already works well. |
| Traces (per-turn/iteration/request/tool-call latency, call trees) | **New: OpenTelemetry Ruby SDK → OTLP → Jaeger** | Answers "what took the time" — the actual gap. Standard wire format (OTLP) means a Python port only rewrites the ~150-line SDK-setup module; the collector/backend/dashboards are untouched. |
| Metrics (request/tool counters, latency histograms, token/cost counters, live-agent gauge) | **New: OTel Ruby Metrics SDK → OTLP → Prometheus** | Turns "recompute from the whole file on every page load" into real aggregates, and replaces `WorldMap`'s file-mtime "is this session live" heuristic with an actual `UpDownCounter`. |
| Dashboards / cross-signal view | **New: Grafana**, reading Jaeger (traces) + Prometheus (metrics) | One pane of glass across both signals; `log_viz` stays linked from it for the domain drill-down Grafana can't do. |
| Backend hosting | **Self-hosted, `docker-compose`**, local only | Matches this project's offline/WSL2 local-dev posture (no account, no network dependency) — consistent with `token_composition_observability.md`'s explicit framing of this whole area as local dev tooling. |

Why an OTel **Collector** sits in front of Jaeger/Prometheus rather than the
Ruby SDK exporting straight to each backend: it's the one piece of this
stack that's specifically about the *Python port*. The Ruby (and later
Python) SDK only ever needs to know one thing — an OTLP endpoint — never
"Jaeger's API" or "Prometheus's remote-write format." Swapping Jaeger for
Tempo, or adding a second backend, becomes a collector-config change with
zero application code touched, in either language.

**Why push (OTLP), not Prometheus's usual pull/scrape model**: `boukensha`
is a one-shot CLI process or a REPL session, not a long-lived server — it
often exits before a scraper's next interval would ever hit it. The
collector receives OTLP pushes from the (possibly short-lived) Ruby process
and is itself the thing Prometheus scrapes, which sidesteps this entirely.

### What was deliberately not chosen

- **Cloud SaaS backend (e.g. Honeycomb)** — the user's own answer to the
  clarifying question was self-hosted; also keeps this offline-capable and
  consistent with the project's local-dev posture.
- **Routing logs through the OTel stack too (e.g. Loki)** — would duplicate
  the `.jsonl`/`log_viz` pipeline for no gain: nothing in Loki can show a
  room graph, and Ruby's OTel Logs SDK is the least mature of the three
  signals. `session_id` is the join key between the two systems (below);
  that's enough correlation without merging the pipelines.
- **MCP-daemon (mud-manager) trace propagation** — would need injecting
  `traceparent` into MCP's JSON-RPC params and instrumenting a separate
  codebase. Out of scope; noted as a natural extension point once this
  ships (see "Not doing," below).

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
conventions is exactly the "cheap hedge" the prior evaluation flagged as
worth doing for free — and it's also what makes a Python port idiomatic
rather than a reinvention, since `gen_ai.*` is language-agnostic by design.

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

`boukensha.sessions.active` (+1 at `Logger#initialize`, −1 at `Logger#close`,
which is already called from an `ensure` in both `Boukensha.run` and
`Boukensha.repl` — ships "how many agents are playing right now" as a real
gauge, which is exactly what `scaling_and_telemetry_evaluation.md` Q2 built
as a file-mtime heuristic over `WorldMap` instead. Both can coexist —
Grafana gets the gauge, `log_viz`'s map keeps its richer per-session detail
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

## Implementation plan

### Phase 0 — Infra

`week2_observability/otel/docker-compose.yml` (sits alongside `log_viz`,
not inside `15_observability` — it's shared infrastructure, not
step-specific code):

- `otel-collector` (`otel/opentelemetry-collector-contrib`) — OTLP
  receiver (gRPC 4317 / HTTP 4318), exports traces via OTLP to Jaeger,
  exposes a `/metrics` endpoint for Prometheus to scrape (`prometheus`
  exporter in the collector config).
- `jaeger` (`jaegertracing/all-in-one`) — UI on 16686, native OTLP ingestion
  from the collector.
- `prometheus` — scrapes the collector's `/metrics`.
- `grafana` — provisioned with Jaeger + Prometheus datasources and one
  starter dashboard (request latency p50/p95, tokens/cost over time, tool
  error rate, active sessions) via Grafana's provisioning YAML, so `docker
  compose up` produces a working dashboard with no manual clicking.

### Phase 1 — Ruby SDK plumbing

Add to `Gemfile` (versions confirmed live against rubygems.org, not
guessed):

```ruby
gem "opentelemetry-api", "~> 1.11"
gem "opentelemetry-sdk", "~> 1.13"
gem "opentelemetry-exporter-otlp", "~> 0.34"
gem "opentelemetry-metrics-sdk", "~> 0.15"       # still 0.x/experimental — see risk note
gem "opentelemetry-exporter-otlp-metrics", "~> 0.10"  # still 0.x/experimental
```

New `lib/boukensha/telemetry.rb`: one module owning `TracerProvider` +
`MeterProvider` setup, configured entirely from standard OTel env vars
(`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME=boukensha`,
`OTEL_TRACES_EXPORTER`, `OTEL_METRICS_EXPORTER`) — the same variables a
Python SDK reads, so a `.env` written for this step needs zero changes when
a Python agent joins. Exposes `Boukensha.tracer` / `Boukensha.meter`
alongside the existing `Boukensha.config`/`Boukensha.debug?` module
accessors in `lib/boukensha.rb`.

**Fail-open is a hard requirement, matching this codebase's existing
convention** (`Compactor#compact`'s header comment: *"a compaction bug must
never be the reason a turn breaks"*). If the collector isn't running —
which will be the common case for anyone who hasn't run `docker compose
up` — span/metric export must degrade to dropped-on-the-floor, never a
raised exception or added latency on the agent's hot path. This is
`BatchSpanProcessor`'s default behavior (async, bounded queue, drops on
export failure) — the setup module must use it, never
`SimpleSpanProcessor`, and this is worth an explicit test (Phase 4).
`observability.enabled: false` in `settings.yaml` (new `Config` reader,
same pattern as `compactor_enabled?`) additionally makes the whole thing a
no-op provider — zero SDK overhead — for anyone who doesn't want it at all.

### Phase 2 — Instrumentation

Touch points, each a thin wrap around code that already exists (no new
business logic, matching this codebase's "add a field, don't restructure"
style seen across the last four steps):

- `Agent#run` (`lib/boukensha/agent.rb:31`) — wrap the method body in the
  turn span. `@iteration` loop body gets the iteration span.
- `Agent#run`'s `@client.call` (`agent.rb:54`) and `Agent#wrap_up`'s
  (`agent.rb:114`) — both wrap in an `llm_request` span; since both already
  go through `Client#call`, instrumenting `Client#call` itself
  (`lib/boukensha/client.rb:25`) covers both call sites plus `Compactor`'s
  Tier 2 call (`compactor.rb:192`) for free — one instrumentation point,
  three callers benefit, and nested spans fall out naturally from Ruby's
  current-span context.
- `Agent#handle_tool_calls`'s per-call loop (`agent.rb:167-191`) — wrap
  `@registry.dispatch` in the `tool_call` span.
- `Compactor#compact_prose` (`compactor.rb:173`) — increments no new
  metric itself (its own `call_model` already inherits an `llm_request`
  span from the `Client#call` instrumentation above); only needs the
  `compaction` span wrapping the cache-miss path.
- `Boukensha.run`/`Boukensha.repl` (`lib/boukensha.rb:45`, `:102`) —
  construct the tracer/meter providers once per process and pass them (or
  read them off the `Boukensha` module) into `Logger.new`'s existing
  `snapshot:` hash so `session_start` carries `trace_provider` info for
  debugging.
- `Logger#turn` (`logger.rb:21`) — add the `trace_id`/`span_id` fields for
  the `log_viz` bridge described above.

### Phase 3 — `log_viz` bridge

- `Session::Entry`/parsing (`log_viz/lib/log_viz/session.rb`) — read the
  new `trace_id` field off `turn` events.
- `session.erb` — one small "View trace ↗" link per turn header, pointing
  at `<jaeger_ui_base>/trace/<trace_id>` (base URL from an env var/setting,
  defaulting to `http://localhost:16686`, blank/hidden if unset — same
  graceful-degradation posture as the existing `compacted` field rendering
  only when present).

### Phase 4 — Tests

Ruby OTel ships `OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter`
specifically for this — no live collector needed for unit tests, matching
this project's existing Minitest conventions (`test/test_logger.rb`,
`test/test_client.rb`).

- `test/test_telemetry.rb` (new) — spans get created with the right
  parent/child nesting and `gen_ai.*` attributes for a scripted
  request/tool-call sequence, using the in-memory exporter.
- Extend `test/test_client.rb` — a request still succeeds and returns the
  same value when the configured OTLP endpoint is unreachable (the
  fail-open requirement from Phase 1, actually verified, not just asserted
  in a comment).
- Extend `test/test_compactor.rb` — Tier 2's nested span appears as a child
  of the `tool_call` span it was triggered from.

### Phase 5 — Docs

- `README.md`'s "What's new in this step" — same format as
  `14_response_compactor/README.md`: what shipped, how to run the stack
  (`docker compose up` from `week2_observability/otel`), how to point
  `boukensha` at it, a screenshot-shaped description of a Jaeger trace and
  a Grafana dashboard.
- Note the Phase-0 collector rationale inline (why not scrape Ruby
  directly) so it isn't re-derived later, matching this directory's
  existing habit of writing "why," not just "what."

## Portability to Python — what actually carries over

Explicit, since it was a stated requirement: everything in Phase 0
(docker-compose, collector config, Jaeger, Prometheus, Grafana dashboards)
is untouched by language. A Python port only rewrites Phase 1's ~150-line
SDK-setup module using `opentelemetry-sdk` + `opentelemetry-exporter-otlp`
(the Python packages of the identical project, same OTLP wire format, same
env vars) and re-applies Phase 2's wrapping at the equivalent call sites.
Phases 3/5 (the `log_viz` bridge, README) are Ruby/this-repo-specific either
way and wouldn't port regardless of stack choice.

## Risk: Ruby metrics SDK maturity

Verified live against rubygems.org while writing this plan (not assumed):
`opentelemetry-metrics-sdk` is at **0.15.0** and
`opentelemetry-exporter-otlp-metrics` at **0.10.0** — both still pre-1.0,
unlike `opentelemetry-sdk` (traces) at a stable **1.13.0**. Traces are
low-risk; metrics may have rough edges (API churn, gaps vs. the spec).
**Mitigation, not a blocker**: build traces first (Phases 0-2's `llm_request`
/`tool_call` spans), confirm the metrics gems work as expected in a spike
before committing Phase 2's metric-emitting code, and if they don't, ship
traces alone for this step with metrics as a fast-follow once the gems
mature — better than blocking the whole plan on the least-stable piece.

## Not doing (explicitly out of scope)

- **MCP/mud-manager trace propagation** — would need instrumenting a
  separate codebase and threading `traceparent` through MCP's stdio
  JSON-RPC. A tool_call span still shows total dispatch latency (agent-side
  wait time) without this; just not a breakdown of what mud-manager itself
  spent time on. Natural extension once this ships.
- **Alerting** (Grafana alert rules, paging) — no on-call for a local dev
  tool; dashboards are for looking at, not paging on.
- **Moving logs into the OTel pipeline (Loki, etc.)** — see "What was
  deliberately not chosen," above.
- **Multi-agent live dashboard redesign** — `scaling_and_telemetry_
  evaluation.md` Q2's map-based live view stays as-is;
  `boukensha.sessions.active` is an additive signal for Grafana, not a
  replacement.
