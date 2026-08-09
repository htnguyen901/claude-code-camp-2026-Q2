# Planner-by-default in the real CLI path (Repl integration)

**Status: implemented (2026-08-07).** Reverses
[`high_level_agentic_loop_design.md`](high_level_agentic_loop_design.md)'s
"Alternative B" (Planner/Judge disabled by default, `Boukensha.run`/`.repl`
untouched, kept as the fallback baseline). That was the original call;
explicit instruction superseded it: ship the Planner enabled by default now,
before Judge exists, and add the rest of the loop (Judge, then Judge-driven
checkpoints) incrementally, observing real agent behavior at each step
rather than waiting to ship the whole Planner→Player→Judge loop at once.

**Depends on:** [`orchestrator.md`](orchestrator.md) §3
(`Tasks::Planner`/`Boukensha.run_planner`, unchanged by this doc) and
[`log_viz_visibility.md`](log_viz_visibility.md) (so the plan this seeds is
actually visible once it runs).
**Relationship to `Boukensha::Session`:** this is a *second*, independent
integration of `Boukensha.run_planner` — not a replacement for `Session`.
`Session.play` remains the separate, still-opt-in autonomous multi-turn
driver (its own checkpoint-loop stub, `max_turns:`, etc. — see
`implementation_plan.md`'s Phase 4 — are unchanged). This doc is about the
*actual* `boukensha`/`bin/play_players` path, which goes through
`Boukensha.repl` → `Repl#run_turn`, a human- (or `play_players`-goal-)
driven turn loop that never called `Session.play` and still doesn't.

## Why the reversal, concretely

The Planner already worked (`Boukensha.run_planner`, tested in isolation,
and exercised by `Boukensha::Session`) — but nobody using the actual
`boukensha --player NAME` command could ever see it run, because
`bin/boukensha` only ever calls `Boukensha.repl`, and `.repl` never called
the Planner. Two options: (1) keep Planner opt-in, ship a `--planned` flag
or point people at `examples/session_demo.rb`, revisit defaults once Judge
exists and the Phase 5 validation run has real numbers; (2) make it the
default now, accept that checkpoints are still a no-op without Judge, and
learn from real usage while building the rest incrementally. Option 2 was
chosen — it directly serves "observe the agent behavior for each step,"
and the downside is small: with no Judge, the only behavior change from
today's Player-only baseline is that the Player's system prompt now
includes a `## Current Plan` block it didn't have before
(`Context#effective_system`, Phase 1) — the ReAct loop itself, its limits,
and its wrap-up behavior are all still byte-for-byte unchanged.

## What changed

- **`Config#planner_enabled?`** (`lib/boukensha/config.rb`) — reads
  `tasks.planner.enabled`, defaults **true** (the opposite default from
  `compactor_enabled?`/`observability_enabled?`, both of which default
  off/on for their own unrelated reasons). Same "config is the toggle"
  convention as those two — no Ruby-level kwarg on `.run`/`.repl` to flip
  this; set `tasks.planner.enabled: false` in `settings.yaml` to opt out.
- **`Repl#maybe_seed_plan`** (`lib/boukensha/repl.rb`) — called from the top
  of `run_turn`, once per session: on the first turn, calls
  `Boukensha.run_planner(goal: <that turn's input>, logger: @logger, ...)`
  and sets `@context.plan`. Every turn after the first is a no-op (`@planned`
  guards it) — **deliberately does not re-plan per turn**. There's no Judge
  yet to decide "this turn's input is actually a new quest, not a follow-up
  on the current one," so re-running the Planner on every single REPL line
  would just be wasted calls, not a real replan trigger.
- **`/clear` also resets the seeded-plan flag** (and `ctx.plan` itself) —
  the one manual escape hatch for "I finished a quest, I'm giving this REPL
  session a completely different one now, I don't want to wait for Judge to
  exist to get a fresh plan." Existing behavior (wipes conversation
  history, resets the turn counter) already matched "start fresh"; this
  just extends that to the plan too.
- **`Boukensha.repl`/`Boukensha.run`** both resolve `cfg.planner_enabled?`
  and thread it through — `.repl` passes `planner_enabled:` into
  `Repl.new`; `.run` (the one-shot path used by `examples/example.rb` and
  tests, not by `bin/boukensha` — see `worker.md`/`orchestrator.md`'s prior
  notes on `bin/boukensha` only ever calling `.repl`) seeds `ctx.plan`
  directly before its single `agent.run` call, since a one-shot run only
  ever has one turn to seed on anyway.
- Both also gained `planner_model:`/`planner_backend:`/`planner_api_key:`/
  `planner_ollama_host:` passthrough kwargs, mirroring `Session.play`'s
  identically-named ones — lets the Planner run on a different
  provider/model than the Player without touching `settings.yaml`.
- Session snapshots (`Logger.new(snapshot: {...})`) now include
  `planner_enabled:` for both `.run` and `.repl`, so a session's own JSONL
  self-documents whether the Planner was even supposed to have run —
  useful for exactly the "why don't I see it" debugging this doc exists
  because of.

## What did NOT change

- `Agent#run`'s loop body — still literally untouched (`worker.md`'s
  invariant holds).
- No auto-continue-past-a-checkpoint loop was added to `Repl` — still true.
  A human (or `play_players`'s piped goal) still drives each turn
  explicitly; `Boukensha::Session` remains the separate, opt-in entry point
  for anyone who wants the fully *autonomous* multi-turn loop (no human
  typing between turns) today.
- No Judge, no `continue`/`replan`/`flag` verdict, anywhere in `Repl` — true
  **as of this doc (Phase 4.6)**. Superseded by
  [`repl_judge_integration.md`](repl_judge_integration.md) (2026-08-07),
  once `Tasks::Judge` (Phase 3) existed: `Repl` now does read
  `agent.stop_reason` (via `Session.checkpoint?`) and does call the Judge
  by default at a checkpoint, adapted for a human-driven REPL rather than
  Session's autonomous loop. This doc's own scope — plan-seeding only, no
  checkpoint logic — is unchanged; see the linked doc for what was added on
  top of it.
- `bin/play_players`/`bin/boukensha` themselves needed **zero** changes —
  both already funnel through `Boukensha.repl`, so the default flip reaches
  them automatically.

## Deferred / natural next increments (not built here)

- A manual `/replan` command (re-run the Planner mid-session without
  needing `/clear` to wipe conversation history too) — flagged as a real
  gap for a REPL session spanning multiple quests, deliberately not built
  now to keep this change to exactly "make the Planner run by default."
  Revisit if `/clear`-as-reset proves too blunt in practice.
- ~~Judge-driven checkpoints inside `Repl`~~ — **done**, see
  [`repl_judge_integration.md`](repl_judge_integration.md) (2026-08-07):
  `Tasks::Judge` (Phase 3) now exists, `Boukensha::Session`'s checkpoint
  branch is real (not a `warn` stub — see
  [`implementation_plan.md`](implementation_plan.md) Phase 4), and `Repl`
  gets the same checkpoint → Judge → continue/replan/flag handling by
  default, adapted for a human-driven REPL (a `:flag` verdict surfaces a
  warning rather than stopping anything, since there's no autonomous loop
  to stop).

## Acceptance criteria

- `Config#planner_enabled?` defaults `true` with no `tasks.planner` block,
  or an explicit `enabled: true`; `false` only when explicitly set.
- A `Repl`'s first `run_turn` call seeds `ctx.plan` via a real (scripted in
  tests) `Boukensha.run_planner` call, and that text shows up in the
  Player's next request payload's system field (`## Current Plan`); a
  second `run_turn` call does not re-invoke the Planner.
- `/clear` resets the seeded-plan flag — a turn after `/clear` re-plans.
- `planner_enabled: false` (i.e. `tasks.planner.enabled: false`) skips
  Planner entirely — zero requests to the Planner backend, `ctx.plan` stays
  `nil`, and the Player's request payload is byte-identical to before this
  doc (mirrors Phase 1's own "byte-identical when `ctx.plan` is never set"
  acceptance criterion).
- No change to `Agent#run`'s control flow, and no new checkpoint/Judge
  logic anywhere in `Repl`.
