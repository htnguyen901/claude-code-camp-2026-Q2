# Implementation plan — agentic loop (Planner / Player / Judge)

Sequences the actual build across the three component plans
([`orchestrator.md`](orchestrator.md), [`worker.md`](worker.md),
[`evaluator.md`](evaluator.md)) into phases with a dependency order, so this
file is the "what order, what's a checkpoint, what's deferred" layer — it
does not restate those docs' content, it references specific sections.
Source of truth for the overall shape is still
[`high_level_agentic_loop_design.md`](high_level_agentic_loop_design.md).

## Dependency graph

```
Phase 0: Decide driver architecture (blocks Phase 4 only)
Phase 1: Shared plumbing (Context#plan, effective_system, stop_reason,
         task-scoped default prompts)          <- no dependents block this
      │
      ├──> Phase 2: Tasks::Planner              (needs Phase 1 §prompts)
      │         │
      │         ├──> Phase 4.5: log_viz task visibility (needs any 2nd
      │         │    task_name producing real logs — Planner alone is
      │         │    enough to start; not gated on Phase 3/4)
      │         │
      │         └──> Phase 4.6: Planner-by-default in Boukensha.run/.repl
      │              (Repl integration — independent of Session/Judge;
      │              needs Phase 4.5 to actually observe it)
      │                    │
      ├──> Phase 3: Tasks::Judge                (needs Phase 1 §prompts, §stop_reason)
      │         │                                │
      │         └──────────────┬─────────────────┘
      │                        ▼
      │              Phase 4.7: Judge-by-default in Repl
      │              (needs Phase 3 + the Phase 4.6 Repl-integration pattern)
      │
      └──> Phase 4: Session driver              (needs Phase 0, 2, 3 all done)
                  │
                  └──> Phase 5: Validation against journal hypotheses
                       (needs Phase 4.5 too — see that phase's "Blocks")
```

Phases 2 and 3 have no dependency on each other and can be built/tested in
either order (or in parallel) once Phase 1 lands. Phase 4 is the integration
point for the *autonomous* driver — it's the first phase where Planner,
Judge, and Player run together in one session with no human in the loop.
Phase 4.5 and 4.6 are both side branches off Phase 2, not part of the main
Planner→Player→Judge critical path — they can be built in parallel with
Phase 3/4, but Phase 5 needs 4.5 done first (see that phase's "Blocks"),
and 4.6 reverses a default this plan's own high-level doc originally set
(see 4.6 below for why). Phase 4.7 is the same reversal applied to the
Judge specifically, and could only land once both its inputs existed:
Phase 3 (`Tasks::Judge` itself) and the `Repl`-integration pattern Phase 4.6
established (`Config#<task>_enabled?` default-true, a `maybe_seed_plan`-
shaped hook called from `run_turn`).

## Phase 0 — Decide driver architecture

**Not code.** [`orchestrator.md`](orchestrator.md)'s "Open question" section
flags that `bin/play_players` currently pipes one goal in as one line of
stdin, so a real play session is *one* `Agent#run` call — there is no
existing multi-turn loop for the driver to wrap. Before Phase 4 starts,
confirm:

1. Is a new driver (proposed: `Boukensha::Session`,
   [`orchestrator.md`](orchestrator.md) §4) the right shape, or is there a
   different intended multi-turn entry point this plan is missing?
2. What does the driver feed the Player as the next instruction after a
   `continue` verdict — a literal `"continue"`, the Player's own wrap-up
   "next action" text, or something else?

Blocks only Phase 4 — Phases 1-3 are independently buildable/testable
without this decision (each has its own acceptance criteria that don't
require a running driver; Planner and Judge can be exercised with direct,
manual calls in tests).

## Phase 1 — Shared plumbing

No user-visible behavior change when nothing downstream uses it yet; this
phase is safe to ship on its own.

- [`orchestrator.md`](orchestrator.md) §1: task-scope `Tasks::Base`'s
  `read_default_prompt` (mirror `read_user_prompt`'s
  `File.join(dir, task_name, "#{name}.md")` shape); move
  `prompts/system.md` → `prompts/player/system.md`; update the two
  `default_prompts_dir:` call sites in `lib/boukensha.rb`.
- [`orchestrator.md`](orchestrator.md) §2: add `Context#plan`
  (`attr_accessor`) and `Context#effective_system` to
  `lib/boukensha/context.rb`.
- [`worker.md`](worker.md) §1: update the four backends
  (`anthropic.rb:81`, `openai.rb:73`, `gemini.rb:89`,
  `ollama.rb`/`ollama_cloud.rb`'s `to_messages(context.system, ...)`
  call) to read `context.effective_system` instead of `context.system`.
- [`worker.md`](worker.md) §2: add `Agent#stop_reason`
  (`:completed` / `:max_iterations` / `:max_tokens`), set at the three
  existing return points in `agent.rb` (natural completion, and each
  `wrap_up` branch) — no change to control flow.

**Acceptance (from `worker.md`):** existing test suite passes unmodified;
a new regression test confirms a request payload's `system`/`instructions`
field is byte-identical before/after this phase when `ctx.plan` is never
set; a new unit test asserts `stop_reason` for all three cases (mirror
`test_logger.rb`'s existing setup for the two wrap-up paths).

## Phase 2 — `Tasks::Planner`

- [`orchestrator.md`](orchestrator.md) §3: add `Tasks::Planner`
  (`lib/boukensha/tasks/planner.rb`), no `tools:` block.
- Add `prompts/planner/system.md`.
- Add the `tasks.planner:` documented block (provider/model/
  max_output_tokens) — this is user-side `.boukensha/settings.yaml`
  config, not shipped in-repo; document the expected shape in this step's
  README the way `17_tool_permission`'s README documents `tool_roles:`.
- Wire one call site that constructs a `Tasks::Planner` request (a bare
  `Client#call` + `PromptBuilder`, `task_name: "planner"` — no `Agent#run`
  loop needed, per [`orchestrator.md`](orchestrator.md) §3's note, since it
  has no tools to dispatch). This can be a standalone method for now
  (e.g. `Boukensha.run_planner(goal:, ...)` returning plan text) — Phase 4
  wires it into the driver's loop.

**Acceptance:** `Tasks::Planner.tool_policy` denies every tool name (test
mirrors `test_tasks_base_tool_policy.rb`'s deny-by-default case); a call
against a sample goal produces plan text; that text, assigned to
`ctx.plan`, shows up in a subsequent Player request's `system` field
(spot-check a logged payload) and never appears in `ctx.messages`.

**Correction (2026-08-07):** the "no `Agent#run` loop, bare `Client#call`"
wiring above shipped as a hardcoded `tools: []`, ignoring
`tasks.planner.tools` entirely rather than deny-by-default falling out of
`tool_policy` the way it was supposed to — see
[`orchestrator.md`](orchestrator.md) §3's correction for the fix
(`run_planner` now mirrors `run_judge`: `tool_policy` + `Agent#run`).

## Phase 3 — `Tasks::Judge`

- [`evaluator.md`](evaluator.md) §1: add `Tasks::Judge`
  (`lib/boukensha/tasks/judge.rb`), `tools: { role: inspector }`.
- Add `prompts/judge/system.md`, including the verdict-format instruction
  (§3's recommended prompt-enforced convention: response ends with
  `VERDICT: continue|replan|flag`).
- Add the `tasks.judge:` documented config block, same treatment as
  Planner's.
- Implement the verdict parser (anchored regex on the final response
  text) and a `run_judge(plan:, transcript_tail:, ...)` helper that builds
  a **throwaway** `Context`/`Registry` (never the Player's live `ctx`),
  seeds it with the plan + transcript tail, registers `room_knowledge` +
  the `inspector`-role MUD tools, and runs it through `Agent#run` with a
  small `max_iterations`.

**Acceptance (from `evaluator.md`):** fixture-driven tests for the three
verdicts, including one where the transcript's claim is contradicted by
`room_knowledge`; tool-policy test asserting `move`/`attack`/`quit`/`give`
are denied; isolation test proving a Judge run that dispatches tools does
not mutate the Player's live `ctx.messages`/`ctx.plan`.

## Phase 4 — Session driver

Gated on Phase 0's decision. Implements
[`orchestrator.md`](orchestrator.md) §4 and
[`evaluator.md`](evaluator.md) §4-§5:

**Status: partially implemented, ahead of Phase 3.** `Boukensha::Session`
(`week3_capable/ruby/18_orchestrator/lib/boukensha/session.rb`) exists and
does the Planner-seed + turn loop below, but the checkpoint → Judge →
verdict branch does not — Phase 3's `Tasks::Judge` doesn't exist yet, so a
checkpoint currently just `warn`s and continues, bounded by `max_turns:` as
a stand-in safety valve. This was pulled ahead of Phase 3 specifically so
the Planner could be exercised inside a real multi-turn session (not just
called standalone) while Judge is still being built — see this step's
README ("Phase 4 (partial)") for what's actually shipped vs. still a
`warn`. The dependency graph above is otherwise unchanged: finishing this
phase for real still needs Phase 3 first.

- New driver (naming per Phase 0) that: builds context/registry/backend/
  logger as `Boukensha.run` does today → calls Phase 2's Planner helper to
  seed `ctx.plan` → loops `Agent#run` calls, feeding the next instruction
  per Phase 0's answer → after each call, checks
  `checkpoint?(agent, ...)` (`stop_reason` in `[:max_iterations,
  :max_tokens]`, or the `every_n_turns:` fallback, default off) →
  on checkpoint, runs Phase 3's Judge helper → branches on verdict per
  [`evaluator.md`](evaluator.md) §5's table (`continue`: loop; `replan`:
  re-run Planner, update `ctx.plan`; `flag`: log distinctly and stop) →
  exits the loop when `stop_reason == :completed`.
- New opt-in entry point wiring this into `bin/play_players` (a
  `--planned`/`--orchestrated` flag or sibling script) — the existing
  one-shot path (`boukensha --no-tui` piped a single goal) is untouched.
- Observability: tag the Planner/Judge calls with their own `task_name`
  (`"planner"`/`"judge"`) so OTel spans/metrics separate them from
  `"player"` activity automatically — no new plumbing needed for OTel.
  **Correction (2026-08-06):** this is *not* true yet for `log_viz`'s own
  views beyond `Cost by Task` (which already groups by `task` and needs
  nothing further) — the Iteration view doesn't visually distinguish tasks,
  and a Model usage breakdown doesn't exist at all. See
  [Phase 4.5](#phase-45--log_viz-task-visibility) below and
  [`log_viz_visibility.md`](log_viz_visibility.md) for what that actually
  takes.

**Acceptance:** an end-to-end run against the offline fake-MUD path
(`examples/mcp_mud_demo.rb --dry`-style setup) exercises at least one full
Planner → Player → Judge(`continue`) → Player → `:completed` cycle and one
forced-limit cycle that reaches a checkpoint and gets a real verdict;
disabling orchestration (not passing the new flag) reproduces today's
`bin/play_players` behavior exactly.

## Phase 4.5 — `log_viz` task visibility

**Status: implemented (2026-08-06).** Added after checking a real
`Boukensha::Session`-driven log in `log_viz` and finding Planner activity
present in the data but not distinctly visible in the UI. Full design:
[`log_viz_visibility.md`](log_viz_visibility.md). Summary:

- `Logger#request`/`#tool_call`/`#tool_result`/`#reasoning`/`#plan` now take
  a `task:` field — previously only `#response` did, via
  `execution_metadata`. `Agent#run`/`#handle_tool_calls` had `@task_name`
  in scope at every one of these call sites already; `Boukensha.run_planner`'s
  own `#request` call needed the same fix.
- `log_viz`'s `Session#parse!` stamps `task` onto every `Entry` (not just
  `:assistant`) now, additively — `current_turn`/`current_iteration`
  counter semantics unchanged. `task_names` now scans all `entries`, not
  just `@usage_series`.
- The Iteration view (`views/session.erb`) inserts a colored `task-marker`
  divider (`app.rb#task_marker`/`#task_color`) whenever the task changes —
  color index-cycled from `session.task_names`, same pattern
  `LIVE_MARKER_COLORS` already uses for map markers, so a Planner call
  before the Player's first turn now renders under its own clearly labeled
  section instead of folding into whatever iteration marker was current.
- `Cost by Task` (`Session#cost_breakdown`) needed no changes — confirmed it
  already grouped by `[task, provider, model]`; its table heading was
  retitled "Usage & cost by task / provider / model" so it's unambiguous it
  also serves as the model-usage breakdown, rather than building a
  redundant second table with identical numbers.

Any future subagent (`Tasks::Navigator`, a room-surveyor, ...) gets all of
this for free once its events carry a `task` string — `log_viz` has zero
hardcoded task-name lists anywhere, confirmed still true after this phase.

**Blocks:** [Phase 5](#phase-5--validation-against-the-journals-hypotheses)
— its before/after comparison needs a human reviewer to actually see
Planner/Judge activity distinctly per session, not just know it's present
in the raw JSONL. Unblocked now.

**Verified:** `rake test` in `18_orchestrator` (120 runs) and every
`week3_capable/log_viz/test/test_*.rb` file (107 runs across both suites'
new coverage) pass; a hand-built session log with Planner + Player activity,
rendered through `log_viz`'s real Sinatra app, shows a red "planner" marker
followed by a blue "player" marker in that order, and the retitled cost
table.

## Phase 4.6 — Planner-by-default in `Boukensha.run`/`.repl`

**Status: implemented (2026-08-07).** Reverses
[`high_level_agentic_loop_design.md`](high_level_agentic_loop_design.md)'s
Alternative-B default (Planner/Judge disabled == today's behavior) for the
real CLI path specifically. Full design:
[`repl_planner_integration.md`](repl_planner_integration.md). Summary:

- `Config#planner_enabled?` (`tasks.planner.enabled`, default **true**) —
  the toggle; no Ruby kwarg, same convention as `compactor_enabled?`/
  `observability_enabled?`.
- `Repl#maybe_seed_plan`, called from `run_turn`, seeds `ctx.plan` from
  `Boukensha.run_planner` once per session (first turn only — `@planned`
  guards it) — not once per turn, since there's no Judge yet to decide a
  given turn is actually a new quest rather than a follow-up.
  `/clear` resets the guard too.
- `Boukensha.run`/`.repl` both resolve the config and thread it through;
  `bin/boukensha`/`bin/play_players` needed **zero** changes — both already
  funnel through `Boukensha.repl`.
- Does **not** touch `Agent#run`'s loop body, and does **not** add any
  checkpoint/Judge/auto-continue logic to `Repl` — that stayed exclusive to
  `Boukensha::Session` (Phase 4 above) **as of this phase**. Superseded by
  Phase 4.7 below, once `Tasks::Judge` existed.

**Relationship to Phase 4:** independent, parallel integration of the same
`Boukensha.run_planner` call site `Session` already uses — not a
replacement for it. `Session.play` remains the separate, still-opt-in
autonomous driver; this phase is what makes the Planner visible in the
*ordinary*, human-driven `boukensha --player` command Phase 4's own driver
was never going to reach on its own.

**Verified:** `rake test` in `18_orchestrator`, 128 runs, 0 failures —
including new coverage proving a `Repl`'s first turn seeds the plan (via a
scripted Planner backend) and it reaches the Player's actual request
payload, a second turn does not re-invoke the Planner, `/clear` allows a
fresh plan, and `planner_enabled: false` skips seeding with a byte-identical
request payload (mirrors Phase 1's own no-plan-set acceptance criterion).

## Phase 4.7 — Judge-by-default in `Repl`

**Status: implemented (2026-08-07).** Applies the same Phase 4.6 reversal to
the Judge, once Phase 3 made `Tasks::Judge` real. Full design:
[`repl_judge_integration.md`](repl_judge_integration.md). Summary:

- `Config#judge_enabled?` (`tasks.judge.enabled`, default **true**) — same
  convention as `planner_enabled?`.
- `Repl#maybe_check_judge`, called from `run_turn` after `agent.run`
  returns, reuses `Session.checkpoint?` (the same predicate `Boukensha::
  Session` uses) against a per-`Repl` `@turns_since_checkpoint` counter —
  fires on a limit-triggered wrap-up, or the optional `judge_every_n_turns:`
  fallback (default `nil`, off). A naturally-completed turn is not a
  checkpoint by itself.
- Verdict handling adapted for a human-driven REPL rather than an
  autonomous loop: `continue` prints the verdict; `replan` re-runs the
  Planner and updates `ctx.plan` (skipped with a note if
  `planner_enabled:` is false, so a Judge verdict can't reintroduce Planner
  activity a session opted out of); `flag` prints a warning but does not
  stop anything — there's no auto-continue loop here for it to stop, unlike
  `Boukensha::Session`.
- `Boukensha.repl` resolves the config and threads through
  `judge_model:`/`judge_backend:`/`judge_api_key:`/`judge_ollama_host:`/
  `judge_every_n_turns:`, mirroring the `planner_*:` kwargs already there;
  `bin/boukensha`/`bin/play_players` needed **zero** changes.
- `Boukensha.run` (the one-shot path) deliberately **not** touched — a
  single call has no further turn for a replan/flag verdict to act on.

**Relationship to Phase 4:** independent, parallel integration of the same
`Boukensha.run_judge`/`Session.checkpoint?` `Session` already uses — not a
replacement. `Session.play` remains the separate, opt-in *autonomous*
multi-turn driver; this phase makes the Judge visible in the *ordinary*,
human-driven `boukensha --player` command, the same relationship Phase 4.6
has to Phase 4 for the Planner.

**Verified:** `rake test` in `18_orchestrator`, 158 runs, 0 failures —
including new coverage proving a limit-triggered checkpoint calls the Judge
and prints its verdict, a naturally-completed turn does not, `judge_enabled:
false` skips it entirely, a `:replan` verdict updates `ctx.plan` (and is
skipped with a note when `planner_enabled:` is false), a `:flag` verdict
prints a warning without raising, `judge_every_n_turns:` checkpoints a
naturally-completed turn once the count is reached, and `/clear` resets the
checkpoint counter.

## Phase 5 — Validation against the journal's hypotheses

Needs [Phase 4.5](#phase-45--log_viz-task-visibility) done first — reading
"whether Judge verdicts line up with what a human reviewer would also call
stuck" (below) means a human reviewer, so Planner/Judge activity has to be
distinguishable in `log_viz`, not just present in the raw JSONL.

Per [`high_level_agentic_loop_design.md`](high_level_agentic_loop_design.md)'s
"How to validate" section and [`evaluator.md`](evaluator.md)'s acceptance
criteria: run the same quest goal, same character, same model, with
orchestration off vs. on, and record (1) turns/iterations to completion,
(2) total tokens spent, (3) wall-clock latency, (4) whether Judge
`replan`/`flag` verdicts line up with what a human reviewer would also call
"stuck." Note Planner-on and Judge-on are both already the default as of
Phase 4.6/4.7 — this validation isn't the go/no-go for *those* defaults any
more (both decisions were made explicitly, ahead of having the numbers, per
[`repl_planner_integration.md`](repl_planner_integration.md)'s reasoning,
extended to the Judge by
[`repl_judge_integration.md`](repl_judge_integration.md)). It's now about
*evaluating* whether the Judge's verdicts are actually good — not a formal
code phase, but should be run and its results written up (e.g. a follow-up
journal entry) now that both `Boukensha::Session` and `Repl` make real
verdicts to compare against a human reviewer's own judgment, instead of the
old warn-and-continue stub this whole plan started from.

## Out of scope / explicitly deferred

Carried over unchanged from the high-level doc's "Deferred to v2" and
each component doc's own deferred sections — not re-litigated per phase:
`Tasks::Navigator`, room-surveyor/persona layering, multi-goal/concurrent
plans, Player-initiated early replan ([`worker.md`](worker.md) §3),
auto-recovery from a `flag` verdict ([`evaluator.md`](evaluator.md)'s
Deferred section), and the forced-tool-call verdict contract
([`evaluator.md`](evaluator.md) §3's alternative) unless Phase 3's testing
shows the prompt-enforced convention gets missed often enough to matter.
