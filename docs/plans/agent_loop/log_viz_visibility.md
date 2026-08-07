# log_viz visibility — every task, not just Player

**Status: implemented (2026-08-06).** All five "Required changes" below are
done — see `implementation_plan.md`'s Phase 4.5 for the verification
summary. The rest of this doc is left as-written (the design record), not
rewritten in past tense.

Added after checking `log_viz` against a real session
(`.boukensha/sessions/20260806T080658Z-af6b1cd6.jsonl`, a
`Boukensha::Session`-driven run with genuine `Tasks::Planner` activity) and
finding two separate gaps, not one: the user's *last* session simply never
called the Planner (expected — it went through the untouched
`boukensha`/`play_players` path), but even the sessions that **did** call it
don't show Planner activity distinctly in `log_viz`'s UI. This doc is the
second gap: what `log_viz` needs so any task — `player`, `planner`, `judge`,
and any future subagent (`Tasks::Navigator`, a room-surveyor, ...) — is
actually visible as itself, not folded into a generic "Assistant" entry or
silently absent.

**Depends on:** [`orchestrator.md`](orchestrator.md) §5 (Observability) and
[`evaluator.md`](evaluator.md), both of which currently claim per-task_name
separation is "no new plumbing needed" for `log_viz`/OTEL. That claim is
correct for OTel (span attributes already carry `boukensha.task`) and for
one `log_viz` view (`cost_breakdown`, see below) but **not** for the
Iteration view or a model-usage breakdown — this doc corrects and narrows
that claim; see the "Correction" notes in each of those two files.
**Blocks:** nothing code-wise, but is a real prerequisite for
[Phase 5](implementation_plan.md#phase-5--validation-against-the-journals-hypotheses)'s
before/after comparison — you can't judge whether Planner/Judge measurably
help if a human reviewer can't see their activity distinctly in the tool
used to inspect a session.

## Current state (verified against real logs + `log_viz` source, 2026-08-06)

- **The JSONL/OTel data layer is already fully generic.** `log_viz` never
  enumerates or switches on a `task` string anywhere (`app.rb`, every
  `views/*.erb`) — a new task name shows up wherever `task`/`task_names` is
  read with zero code changes. This part of orchestrator.md §5's claim
  holds.
- **Cost by Task already works, unmodified.** `Session#cost_breakdown`
  (`week3_capable/log_viz/lib/log_viz/session.rb:390-409`) groups
  `@usage_series` by the 3-tuple `[task, provider, model]`, rendered as a
  table at `views/session.erb:55-83`. Nothing to build here — Planner/Judge
  calls already appear as their own rows today, *when* they carry a `task`
  field (see the gap below).
- **The Iteration view does not distinguish tasks — this is the actual
  gap the user hit.** `views/session.erb:244-396` renders one flat,
  chronological `@session.entries` array with an `Iteration N` divider
  whenever the shared `entry.iteration` counter changes
  (`session.rb:156-182` tracks `current_turn`/`current_iteration` as single
  counters, stamped onto *every* entry regardless of which task produced
  it). Confirmed against the real log: a `task:"planner"` response at line 3
  arrives *before* the first `phase:"turn"`/`"iteration"` event, so it
  inherits the pre-turn defaults (`turn: 0, iteration: 0`) and renders
  indistinguishable from Player activity under whatever iteration marker is
  current.
- **`task` isn't even present on most entry types today.** Only
  `response`/`:assistant` entries carry `task` (`session.rb:256, 288`, via
  `Logger#response`'s `execution_metadata`). `:request`, `:tool`, `:plan`,
  `:reasoning` entries — the bulk of what the Iteration view renders — never
  get a `task` field at all, because `Logger#request`/`#tool_call`/
  `#tool_result`/`#reasoning`/`#plan` don't accept or write one. A
  task-aware Iteration view can't be built on top of this without fixing the
  logging side first.
- **No standalone Model usage breakdown exists.** `Session#model_summary`
  (`session.rb:343-347`) is a short joined string ("provider / model, ...")
  used only in list/header contexts (`views/index.erb:40`,
  `views/player.erb:82`, `views/session.erb:22-24`) — not a breakdown table.
  `Session#response_models`/`#response_providers` (`session.rb:339-340`)
  exist but have zero callers anywhere. This has to be built, not extended.

## Required changes

### 1. Stamp `task` onto every event, not just `response`

`lib/boukensha/logger.rb`'s `request`/`tool_call`/`tool_result`/
`reasoning`/`plan` methods need a `task:` parameter, written into every
event they log. `Agent#run`/`#handle_tool_calls` already has `@task_name`
in scope at every one of these call sites (`agent.rb:69, 74, 132, 163, 170,
180, 191, 229`) — this is threading an argument that already exists through
already-existing call sites, not new data.

Naming reminder from [`orchestrator.md`](orchestrator.md) §2: `Logger#plan`
is the pre-existing tool-call-preamble event (the model's inline reasoning
*before* a tool call), unrelated to `Tasks::Planner`'s output, which already
correctly travels as a normal `response` event under `task: "planner"`.
Adding `task:` to `Logger#plan` events (so a *Judge's* preamble text, say,
is attributable) does not change or revisit that naming decision.

### 2. `log_viz`: carry `task` on every `Entry`, without changing counter semantics

`Session#parse!` (`session.rb:155-323`) should read the new `task` field
off every phase and stamp it onto the corresponding `Entry`, additively —
`current_turn`/`current_iteration` stay single global counters (least
risky: no behavior change for existing single-task sessions, and "iteration
N" still means what it always meant for the Player's own loop). The fix is
making every `Entry`, not just `:assistant`, carry `entry.task` so the view
layer (§3) can group or badge by it.

### 3. Iteration view: make task visually distinct

`views/session.erb:244-396`. Two ways to get there, pick when implementing
(not decided here):
- **Badge**: a small task label/color chip next to each entry (or each
  contiguous run of same-task entries), so a Planner/Judge chunk reads as
  clearly separate from the Player's ReAct loop even while interleaved
  chronologically.
- **Grouping**: visually cluster consecutive same-task entries under a
  sub-heading (e.g. "Planner" / "Player — Iteration 3" / "Judge") instead of
  a single flat `Iteration N` marker stream.

Either way, the pre-turn case (`turn: 0, iteration: 0` — a Planner call
before the first real Player turn) needs its own treatment, e.g. a "Session
start (Planner)" section, instead of silently folding into whatever
"Iteration 0" currently renders as.

### 4. Build the missing Model usage breakdown

The data already exists (`UsagePoint`, `response_models`/
`response_providers`) — this is wiring it into an actual view, not new
collection logic. Minimum: a table grouped by `[task, provider, model]`
(same grouping `cost_breakdown` already uses) showing call count, token
totals, and cost, clearly labeled and reachable from the session page —
either promote/rename `cost_breakdown`'s existing table (it already has
every needed column) or add a sibling table if "cost" and "usage volume"
turn out to want different sort/emphasis once real multi-task sessions
exist to look at.

### 5. Stay subagent-agnostic — no hardcoded task list, ever

None of the above should enumerate `"player"`/`"planner"`/`"judge"` by
name anywhere in `log_viz` — confirmed today nothing does, and it must stay
that way. `Tasks::Navigator`, a room-surveyor, or anything else
[`high_level_agentic_loop_design.md`](high_level_agentic_loop_design.md)'s
"Deferred to v2" section eventually adds gets this for free the moment its
events carry `task: "navigator"` (or whatever), same as Planner/Judge do
now — this doc's job is only "make `task` travel everywhere and render
generically," never "teach `log_viz` about a specific new task name."

## Acceptance criteria

- A session log containing Player + Planner + (fixture) Judge activity,
  viewed in `log_viz`'s Iteration view, visually separates each task's
  entries — a human can tell "this is Planner reasoning" from "this is the
  Player's turn 2" without reading raw JSON.
- `Session#cost_breakdown` continues to pass its existing behavior
  unmodified (regression coverage, not a rebuild) once `task` starts
  arriving on more event types.
- A Model usage breakdown table exists, grouped by task/provider/model,
  reachable from the session page.
- Grep-able regression: no `log_viz` file contains a literal `"player"`,
  `"planner"`, or `"judge"` string used for branching/display logic (config
  reads like `tasks.player`/`tasks.content_fact` in `settings.rb` are the
  one pre-existing, allowed exception — those are config keys, not display
  branching).

## Deferred / out of scope here

- **Cross-session / global rollups** (total spend per task/model across
  every file in `.boukensha/sessions/`, not just one session) — `log_viz`
  is per-session/per-player today; a global rollup is a natural v2, not
  needed to unblock Phase 5's before/after comparison (which is already
  scoped to "same goal, same character, same model," i.e. individual
  sessions).
- **OTel/Jaeger trace-view task-awareness** — spans already carry
  `boukensha.task` (see
  [`otel_and_logs/00_overview.md`](../observability/otel_and_logs/00_overview.md)),
  so this is arguably already fine on that side; not re-litigated here,
  since this doc is scoped to the JSONL-backed views (`Iteration`, `Cost by
  Task`, `Model usage`) the user specifically named.
