# Step 15 - Observability

Branched from `14_response_compactor` (which stays the source of truth for
the MUD tool-result compaction it introduced — unchanged here). This step
adds a second, standard-format telemetry pillar **alongside** the existing
`Boukensha::Logger` JSON-lines logs and `log_viz` — not instead of them. Full
rationale for why both exist, the span-tree design, and the metrics table:
`docs/plans/observability/otel_and_logs/00_overview.md`.

This step ships all five phases of that plan:

| Phase | What it added | Status |
|---|---|---|
| 0 — Infra | `week2_observability/otel/` (Collector → Jaeger + Prometheus → Grafana, `docker compose up`) | shipped |
| 1 — Ruby SDK plumbing | `Boukensha::Telemetry` — `Boukensha.tracer`/`Boukensha.meter`, fail-open | shipped |
| 2 — Instrumentation | Spans + metrics wired into `Agent`/`Client`/`Compactor` | shipped, **traces and metrics both** — see "Risk note," below |
| 3 — `log_viz` bridge | Per-turn "View trace ↗" link in `log_viz`'s session viewer | shipped |
| 4 — Tests | `test/test_telemetry.rb` + fail-open/nesting coverage in `test_client.rb`/`test_compactor.rb` | shipped |

## Build

```sh
gem build boukensha.gemspec
gem install boukensha-0.15.0.gem
```

## Quickstart: see a real turn in Jaeger and Grafana

1. Bring up the backend (nothing but Docker needed — see
   `week2_observability/otel/README.md` for the full breakdown):

   ```sh
   cd week2_observability/otel
   docker compose up -d
   ```

2. Run a turn. Either the REPL:

   ```sh
   cd week2_observability/ruby/15_observability
   bundle exec bin/boukensha
   ```

   or a one-shot script:

   ```sh
   bundle exec ruby -e 'require "boukensha"; puts Boukensha.run(task: "say hello")'
   ```

   No extra env vars needed — `Boukensha::Telemetry` exports to
   `http://localhost:4318` by default, which is exactly where the compose
   stack above listens.

3. **Jaeger** (<http://localhost:16686>) — pick service `boukensha`, click
   *Find Traces*. Each trace is one turn: a `boukensha.turn` root span
   containing one `boukensha.iteration` span per loop pass, each with a
   nested `boukensha.llm_request` child (and a `boukensha.tool_call` child
   per tool the model invoked that iteration, itself containing a
   `boukensha.compaction` child on any iteration where `Boukensha::Compactor`
   Tier 2 fired). Click a `llm_request` span to see its `gen_ai.*`
   attributes — model, input/output token counts, finish reason,
   `boukensha.cost_usd`.

4. **Grafana** (<http://localhost:3000>, `admin`/`admin`) — the
   "Boukensha Overview" dashboard is already provisioned (no manual
   clicking): LLM request latency (p50/p95) as a timeseries, tool error rate
   as a timeseries, token usage over time split by input/output,
   cost over time, and active-session count as a stat panel. One turn isn't
   much to look at on a 6-hour window — the panels are built for a
   longer-running REPL session or several turns back to back.

5. **`log_viz`** (`week2_observability/log_viz`, `bundle exec ruby
   bin/log_viz`, then <http://localhost:4567>) — open the session you just
   ran (REPL sessions only — see "The `log_viz` bridge," below) and each
   turn's summary strip carries a **"View trace ↗"** link straight into the
   Jaeger waterfall above. `session_id` is the join key between the two
   systems; `log_viz` never talks to Jaeger's API, it just builds a URL.

## What's new in this step

### `Boukensha::Telemetry` — OpenTelemetry SDK setup

`lib/boukensha/telemetry.rb` is the one place in the codebase that talks to
the OpenTelemetry SDK directly — a future Python port only has to rewrite
this file (`opentelemetry-sdk` + `opentelemetry-exporter-otlp` read the
identical env vars). `Boukensha.tracer` / `Boukensha.meter` (in
`lib/boukensha.rb`) and `Boukensha::Metrics` (`lib/boukensha/metrics.rb`,
the memoized instrument registry for the named counters/histograms below)
are the only entry points anything else in the codebase needs.

Configuration is entirely standard OTel environment variables — nothing
boukensha-specific to set:

| Env var | Default | Notes |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` | **Ruby's OTLP exporter is HTTP/protobuf, not gRPC** — port `4318`, not the `4317` gRPC port some other languages default to. `week2_observability/otel`'s collector listens on both, so either works for other future SDKs, but Ruby specifically needs `4318` if you ever override this. |
| `OTEL_SERVICE_NAME` | `boukensha` | Set by `Telemetry` if the env var is unset — doesn't override an explicit value. |
| `OTEL_TRACES_EXPORTER` | `otlp` | SDK default; `none` disables trace export. |
| `OTEL_METRICS_EXPORTER` | `otlp` | SDK default; `none` disables metric export. |

**Why a Collector sits in front of Jaeger/Prometheus, instead of the Ruby
process exporting straight to each, or Prometheus scraping Ruby directly**:
the SDK only ever needs to know one thing — an OTLP endpoint — never
"Jaeger's API" or "Prometheus's remote-write format," so swapping either
backend later is a collector-config change, zero application code touched.
And `boukensha` is a one-shot CLI process or REPL session, not a long-lived
server — it often exits before a scraper's next interval would ever reach
it, which rules out Prometheus's usual pull/scrape model for this process
directly; the Collector receives pushed OTLP data and is itself what
Prometheus scrapes instead. Full rationale: the overview's "Why a Collector
sits in front..." / "Why push (OTLP)..." sections.

### Turning it off: `observability.enabled: false`

```yaml
observability:
  enabled: false   # default: true
```

Observability defaults **on** — it's inert instrumentation, not a behavior
change, and fail-open (below) means "nothing is listening" already costs
nothing. `enabled: false` goes one step further: `OpenTelemetry::SDK.configure`
is never called at all, so `Boukensha.tracer`/`.meter` return OpenTelemetry
API's own no-op `ProxyTracer`/`ProxyMeter` — zero SDK overhead, not just
"exports nowhere."

### Fail-open guarantee

Same posture as `Compactor` (see its header comment: *"a compaction bug
must never be the reason a turn breaks"*):

- **No collector running** — `OpenTelemetry::SDK.configure` never touches
  the network, it only builds exporters. Spans/metrics queue into a
  `BatchSpanProcessor` / `PeriodicMetricReader` and are dropped when a
  background export attempt fails — logged once to stderr, never raised,
  never added latency on the calling thread. `SimpleSpanProcessor`
  (synchronous, hot-path latency) is never used.
- **`observability.enabled: false`** — no-op providers, per above.
- **Anything else during setup** (bad endpoint URL, a metrics-gem bug) —
  caught in `Telemetry.setup!`, logged once, same no-op fallback.
- This isn't just asserted in a comment: `test/test_client.rb`'s
  `test_call_is_fail_open_when_the_otlp_collector_is_unreachable` actually
  points `OTEL_EXPORTER_OTLP_ENDPOINT` at a closed port and asserts a real
  request still completes in well under a second. Swapping
  `BatchSpanProcessor` for `SimpleSpanProcessor` makes that same test hang
  (verified directly while writing it — a naive synchronous exporter blocks
  indefinitely trying to connect to the closed port).

### The span tree

One trace per **turn** (`Agent#run`), matching the granularity
`Boukensha::Logger`'s own `turn`/`turn_end` events already use:

```
boukensha.turn (root)
├─ boukensha.iteration               (one per loop pass)
│  ├─ boukensha.llm_request          (Client#call — the network round trip + retries)
│  └─ boukensha.tool_call            (one per dispatched tool, wraps Registry#dispatch)
│     └─ boukensha.compaction        (child of tool_call, only when Compactor Tier 2 fires)
│        └─ boukensha.llm_request    (Tier 2's own model call — nests for free, see below)
└─ boukensha.llm_request             (Agent#wrap_up's terminal call, direct child of turn,
                                       only when a limit trips — not wrapped in its own
                                       iteration since it's outside the counted loop)
```

`Client#call` is instrumented exactly once. Every caller — the main loop,
`Agent#wrap_up`, `Compactor#call_model`'s Tier 2 round trip — gets correct
nesting for free from Ruby's current-span context propagation, without
`Client` knowing anything about who called it. `test/test_telemetry.rb` and
`test/test_compactor.rb` assert this tree shape by `parent_span_id`/`span_id`
linkage (not just "N spans exist somewhere") for exactly this reason — it's
an emergent property of instrumenting one shared call path, not something
manually wired at every call site, and worth pinning down.

Span attributes, aligned to OTel's `gen_ai.*` semantic conventions where one
exists:

| Span | Attributes |
|---|---|
| `boukensha.turn` | `boukensha.session_id`, `boukensha.task`, `boukensha.provider`, `boukensha.model` |
| `boukensha.llm_request` | `gen_ai.system`, `gen_ai.request.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.response.finish_reason`, `boukensha.cost_usd`, `boukensha.iteration` |
| `boukensha.tool_call` | `boukensha.tool.name`, `boukensha.tool.ok`, `boukensha.tool.error` (only when present) |

### Metrics

`Boukensha::Metrics` (a small memoized-instrument registry, mirroring
`Telemetry`'s role for the tracer) emits one counter/histogram/gauge per row
below. The Collector's Prometheus exporter renames on the way out — dots
become underscores, a unit gets folded into the name, and counters get a
`_total` suffix — the right-hand column is the name you'll actually query in
Prometheus/Grafana, confirmed against a live scrape while writing this:

| OTel instrument | Type | Prometheus name |
|---|---|---|
| `boukensha.llm.requests` | Counter | `boukensha_llm_requests_total` |
| `boukensha.llm.request.duration` (ms) | Histogram | `boukensha_llm_request_duration_milliseconds_{bucket,sum,count}` |
| `boukensha.llm.tokens` | Counter | `boukensha_llm_tokens_total` (labeled `direction: input\|output` — the overview's table also lists a `cache_read` direction; not implemented here, since `Client` doesn't currently extract cache-token counts from the raw response) |
| `boukensha.llm.cost` (USD) | Counter | `boukensha_llm_cost_USD_total` |
| `boukensha.tool.calls` | Counter | `boukensha_tool_calls_total` |
| `boukensha.tool.duration` (ms) | Histogram | `boukensha_tool_duration_milliseconds_{bucket,sum,count}` |
| `boukensha.errors` | Counter | `boukensha_errors_total` |
| `boukensha.sessions.active` | UpDownCounter | `boukensha_sessions_active` |

(The Collector folds an instrument's declared `unit:` into its Prometheus
name — `ms` becomes `_milliseconds` on the two histograms above, `USD`
becomes `_USD` on cost. The Phase 0 dashboard was written before Phase 2's
instruments existed and originally queried `boukensha_llm_cost_total`
(guessing the naming convention); its "Cost over time" panel was corrected
to `boukensha_llm_cost_USD_total` once the real emitted name was confirmed
live, per `week2_observability/otel/README.md`'s own note that the
dashboard's query strings — not the stack — are what to fix if real names
differ. The other four panels' queries already matched.)

`boukensha.sessions.active` is `+1` in `Logger#initialize`, `-1` in
`Logger#close` (already called from an `ensure` in both `Boukensha.run` and
`Boukensha.repl`) — a real gauge for "how many agents are playing right
now," labeled by `task`.

`boukensha.tool.duration` is measured around `Registry#dispatch` only, not
around `Compactor#compact` — Tier 2's own latency (a separate, opt-in LLM
round trip) shows up in its own `boukensha.compaction` → `boukensha.llm_request`
spans and that call's own `boukensha.llm.request.duration` sample instead,
so "how long did the tool itself take" never gets inflated by an unrelated
post-processing step.

### The `log_viz` bridge

`Boukensha::Logger#turn` (fired once per REPL turn — see `Repl#run_turn`;
the one-shot `Boukensha.run` path has exactly one turn and, same as before
this step, never logs a `turn` event at all) now additionally records the
active `trace_id`/`span_id`
(`OpenTelemetry::Trace.current_span.context`) on that log line. It fires
from *inside* `Agent#run`'s `boukensha.turn` span, not before it — logging
it earlier (where `Repl#run_turn` used to call it, before constructing the
`Agent`) would run before that span exists and `trace_id` would always come
back `nil`; `turn:` is now threaded into `Agent.new` instead so the log call
can move inside the span while keeping the `.jsonl` line in the same
position in the file (still before that turn's `request`/`tool_call`
events, which is what `log_viz`'s own turn-boundary parsing needs).

`log_viz` (`week2_observability/log_viz/lib/log_viz/session.rb`) reads that
field the same way it already reads any other optional/new log field, and
`session.erb` renders a small **"View trace ↗"** link per turn, pointing at
`<jaeger_ui_base>/trace/<trace_id>` — base URL from `LOG_VIZ_JAEGER_UI_BASE`
(default `http://localhost:16686`), see `log_viz/README.md`. A turn with no
`trace_id` (pre-this-step logs, `observability.enabled: false`, or any
one-shot `Boukensha.run` session, which has no `turn` event to carry one)
simply renders with no link and no error — the same graceful-degradation
posture the `compacted`/"Injected into next request" panel already has for
older logs.

### Risk note: metrics SDK maturity — resolved, not a fast-follow

`opentelemetry-metrics-sdk` (0.15.0) and `opentelemetry-exporter-otlp-metrics`
(0.10.0) are still pre-1.0/experimental, unlike the stable traces SDK
(1.13.0) — see the overview's "Risk: Ruby metrics SDK maturity". Both are
required in the Gemfile behind a `begin`/`rescue LoadError` in
`telemetry.rb` so a load failure would degrade to traces-only rather than
breaking `Telemetry` entirely — but in practice, that fallback has never had
to engage: the Phase 1 spike (a counter reaching Prometheus through the
Collector) passed with no issues, and every metric in the table above is
confirmed live in Prometheus as of this step. **Metrics shipped in the same
pass as traces, not as a fast-follow.**

## Tests

```sh
bundle exec rake test
```

`test/test_telemetry.rb` drives a real `Agent#run` against a scripted
request/tool-call sequence and asserts the span tree above by
`parent_span_id` linkage and `gen_ai.*` attribute values, using the SDK's
`InMemorySpanExporter` — no live collector needed. `test/test_client.rb`
and `test/test_compactor.rb` each gained one targeted addition (the
fail-open guarantee, and the compaction-nests-under-tool_call claim,
respectively) — see their own comments for what each specifically pins
down and why.

## Not doing (explicitly out of scope)

Carried over from the overview's own "Not doing" section — filing a bug for
any of these is filing it against a known, deliberate gap, not an oversight:

- **MCP/`mud-manager` trace propagation** — a `tool_call` span shows total
  dispatch latency (agent-side wait time) but not a breakdown of what
  `mud-manager` itself spent time on, since that would mean instrumenting a
  separate codebase and threading `traceparent` through MCP's stdio
  JSON-RPC. Natural extension once this ships, not part of it.
- **Alerting** — no Grafana alert rules, no paging. There's no on-call for a
  local dev tool; the dashboard is for looking at, not paging on.
- **Moving logs into the OTel pipeline** (e.g. a Loki backend) — would
  duplicate the `.jsonl`/`log_viz` pipeline for no gain: nothing in Loki can
  show a room graph, and Ruby's OTel Logs SDK is the least mature of the
  three signals. `session_id` (and now `trace_id`, via the bridge above) is
  enough correlation between the two systems without merging them.
- **Multi-agent live dashboard redesign** — `log_viz`'s existing map-based
  live view (`scaling_and_telemetry_evaluation.md` Q2) stays as-is;
  `boukensha.sessions.active` is an additive signal for Grafana, not a
  replacement for it.
