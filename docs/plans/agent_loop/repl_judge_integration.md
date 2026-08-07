# Judge-by-default in the real CLI path (Repl integration)

**Status: implemented (2026-08-07).** Extends
[`repl_planner_integration.md`](repl_planner_integration.md)'s reversal to
the Judge: `Tasks::Judge` (Phase 3, [`evaluator.md`](evaluator.md)) shipped
usable from `Boukensha::Session`, but nobody using the actual
`boukensha --player NAME` command could see it run, because `Repl#run_turn`
never called it — the same gap `repl_planner_integration.md` closed for the
Planner. This does the equivalent for the Judge: on by default, no new CLI
flag, `Agent#run`'s loop itself untouched.

**Depends on:** [`evaluator.md`](evaluator.md) (`Tasks::Judge`/
`Boukensha.run_judge`, unchanged by this doc) and
[`repl_planner_integration.md`](repl_planner_integration.md) (the
`Repl#maybe_seed_plan`/`Config#planner_enabled?` pattern this doc mirrors,
plus the `## Current Plan` block a replan verdict updates).
**Relationship to `Boukensha::Session`:** this is a *second*, independent
integration of `Boukensha.run_judge` and `Session.checkpoint?` — not a
replacement for `Session`. `Session.play` remains the separate, opt-in
*autonomous* multi-turn driver (its own checkpoint loop, `max_turns:`, etc.
are unchanged). This doc is about the *human-driven* `boukensha`/
`bin/play_players` path, which goes through `Boukensha.repl` →
`Repl#run_turn` and never called `Session.play`.

## Why the reversal, concretely

The Judge already worked (`Boukensha.run_judge`, tested in isolation, and
exercised by `Boukensha::Session`'s real checkpoint branch) — but the only
way to ever see it run was `examples/session_demo.rb` or a direct
`Session.play` call. Same two options `repl_planner_integration.md` weighed
for the Planner, applied to the Judge: (1) keep it opt-in behind a flag,
revisit once there's a written Phase 5 comparison; (2) make it the default
now and keep learning from real usage. Option 2 again — consistent with the
same reasoning, and there is no longer a "wait for Judge to exist" reason to
hold it back, since Judge already exists.

## What changed

- **`Config#judge_enabled?`** (`lib/boukensha/config.rb`) — reads
  `tasks.judge.enabled`, defaults **true**, same convention as
  `Config#planner_enabled?`. Set `tasks.judge.enabled: false` in
  `settings.yaml` to opt out.
- **`Repl#maybe_check_judge`** (`lib/boukensha/repl.rb`) — called from the
  end of `run_turn`, after `agent.run` returns and its text has been
  printed. Reuses `Session.checkpoint?` (the same predicate
  `Boukensha::Session` already uses — evaluator.md §4) against a per-`Repl`
  `@turns_since_checkpoint` counter: a checkpoint fires when the turn just
  hit `:max_iterations`/`:max_tokens`, or (only if `judge_every_n_turns:` is
  set — default `nil`, matching `Session`'s own default) every N turns
  regardless of how they ended. A naturally-completed turn is *not* a
  checkpoint by itself, so with the default config the Judge only runs when
  the Player actually hit a limit — the same cadence `Session` uses.
- **Verdict handling, adapted for a human-driven REPL (not an autonomous
  loop):**
  - `continue` — prints the Judge's verdict and reasoning
    (`Judge: continue — ...`), nothing else changes.
  - `replan` — re-runs `Boukensha.run_planner` (prior plan + a fresh
    transcript tail) and updates `ctx.plan`, printing the new plan, *unless*
    `planner_enabled:` is false for this session — a Judge asking for a
    replan must not reintroduce Planner activity a session explicitly
    opted out of; that case prints a note and skips instead.
  - `flag` — prints a prominent warning. Unlike `Boukensha::Session`
    (whose autonomous loop stops on `:flag`, since nothing else would), a
    REPL turn has a human typing the next line regardless — there is no
    loop to stop. The verdict is surfaced, not enforced.
- **`@goal` tracking** — `Repl` now remembers the first turn's input as the
  session's objective (`@goal ||= input`), independent of whether the
  Planner ever ran, so a Judge-requested replan has something to hand
  `Boukensha.run_planner` even when `planner_enabled:` was false for the
  turn that seeded it (only relevant if it later flips true mid-session, or
  is force-run — the guard above still applies in the common case).
- **`/clear` also resets `@turns_since_checkpoint`** (alongside the existing
  seeded-plan flag / plan / turn-counter reset from
  `repl_planner_integration.md`) — a fresh session shouldn't inherit a
  stale checkpoint countdown from before the clear.
- **`Boukensha.repl`** gained `judge_model:`/`judge_backend:`/
  `judge_api_key:`/`judge_ollama_host:`/`judge_every_n_turns:` passthrough
  kwargs (mirroring the `planner_*:` ones already there) and resolves
  `cfg.judge_enabled?`, threading it into `Repl.new`. Session snapshots
  (`Logger.new(snapshot: {...})`) now include `judge_enabled:` alongside
  the existing `planner_enabled:`, for the same "why don't I see it"
  self-documentation reason.
- **`Boukensha.verdict_reasoning(text)`** (`lib/boukensha.rb`) — small
  display helper: the Judge's response text with the trailing
  `VERDICT: ...` line stripped, since `Repl` already prints the parsed
  verdict symbol separately and repeating the raw line would be redundant.
  `Boukensha.run_judge`'s own return value is unaffected — still the full,
  unmodified text.

## What did NOT change

- `Agent#run`'s loop body — still literally untouched.
- `Boukensha::Session` — its own checkpoint → Judge → verdict branch
  ([`implementation_plan.md`](implementation_plan.md) Phase 4) is
  unaffected; this doc adds a second, independent call site, not a shared
  code path beyond `Session.checkpoint?`/`Boukensha.run_judge` themselves.
- `Boukensha.run` (the one-shot path — used by `examples/example.rb` and
  tests, not by `bin/boukensha`) — deliberately **not** touched. A one-shot
  call has exactly one turn and no further turn to hand a replanned plan to
  or to skip after a flag, so there is nowhere for a Judge verdict to do
  anything useful there; adding a checkpoint check that can only ever print
  something would be checkpoint theater, not real behavior. Revisit only if
  a concrete one-shot use case needs it.
- `bin/play_players`/`bin/boukensha` themselves — zero changes, same as
  `repl_planner_integration.md`. Both already funnel through
  `Boukensha.repl`, so the default flip reaches them automatically.

## Deferred / natural next increments (not built here)

- A manual `/replan` REPL command, and Player-initiated early replan — both
  already deferred by `repl_planner_integration.md`/
  [`worker.md`](worker.md) §3; unchanged by this doc.
- Any richer reaction to `:flag` than a printed warning (e.g. refusing
  further turns until acknowledged) — the high-level doc's Cons section
  treats "flag risk" as surface-to-a-human, not auto-remediate; a human
  driving the REPL already *is* that human, so v1 stops at surfacing.
- `judge_every_n_turns:`/`planner_*`/`judge_*` overrides are Ruby kwargs
  only, same as `Boukensha::Session`'s identically-named ones — no
  `settings.yaml` key for the cadence itself (only for
  provider/model/enabled). Revisit if a config-driven default proves
  useful.

## Acceptance criteria

- `Config#judge_enabled?` defaults `true` with no `tasks.judge` block, or an
  explicit `enabled: true`; `false` only when explicitly set
  (`test_config_judge.rb`).
- A turn that hits `:max_iterations`/`:max_tokens` calls the Judge exactly
  once and prints its verdict; a turn that completes naturally does not
  call the Judge at all (`test_repl_judge.rb`).
- `judge_enabled: false` skips the Judge entirely, even at a checkpoint —
  zero requests to the Judge backend.
- A `:replan` verdict re-runs the Planner (prior plan + transcript tail)
  and the new plan reaches `ctx.plan`; the same verdict is a no-op (with a
  printed note) when `planner_enabled:` is false.
- A `:flag` verdict prints a warning and does not raise or otherwise halt
  the REPL — the next `run_turn` call still works normally.
- `judge_every_n_turns:` checkpoints even a naturally-completed turn once
  the configured number of turns has passed; `/clear` resets the counter.
