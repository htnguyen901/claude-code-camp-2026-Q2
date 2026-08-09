## Goal

To design a setup where a central agent dynamically delegates to subagents and synthesizes their output, and another patterns to name the assist/evaluate loop

e.g. orchestrator (routes/delegates), evaluator/critic (reviews/scores), worker (executes)

**Thought Process and Notes**
- need Agents cooperation => orchestor
    + a planner: what to do with the task on hand, the big picture plan
    + judge: judge whether the plan is moving toward tasked goal
    + player: play the game
    + inspector: inpsect the room?
    + navigator: navigate directions => do I need to open map?
        + for modern games, player can open map and view explored section, but unlike those MUD is different as it is texted-based. Concerns: how much of the map can the player remember or see?
    + room surveyor: survey the room, decide exit to go based on navigator output path?

**Orchestrator**
- Planner

**Evaluator**
- Judge

**Worker**
- Player

### Questions and Concerns

- We need to build up and not overkill to avoid over-engineering and overuse tokens
- We need to stay consistent and true to 'real player thought process and gaming behavior'

---

## Recommendation

### TL;DR

**Plan-and-Execute**, not a dynamic per-step orchestrator-router. A `Planner`
sets a short-lived plan infrequently (session start, or when the `Judge`
flags "stuck"); the existing `Player` `Agent` loop runs unchanged, turn after
turn, executing that plan; a `Judge` checks in only at natural checkpoints
(iteration/token-limit wrap-up, or every N turns) and decides "keep going" /
"replan" / "flag risk." Orchestrator and Evaluator are cheap, occasional
calls layered *around* the existing hot loop — they never sit on the
per-tool-call critical path.

### Why this fits this codebase specifically

1. **One process = one character.** `bin/play_players` and
   `Boukensha.repl`/`.run` both hardcode `task_class = Tasks::Player` and spin
   up one `Context`/`Agent`/`Registry` per character. There is no shared
   process across players to route through — so "orchestrator" here means
   *one character's own cognitive loop* (plan → act → reflect), not a
   hive-mind dispatching between characters. That framing also happens to
   match "stay true to real player thought process": a human player forms a
   rough goal, plays a bunch of turns, then pauses to reassess — they don't
   consult a coach before every keypress.

2. **`Agent#run` is a tight, already-tuned ReAct loop.** `max_iterations`,
   `max_turn_tokens`, and the wrap-up call (`week3_capable/ruby/18_orchestrator/lib/boukensha/agent.rb:36-147`)
   already implement exactly the "stop and summarize" behavior a
   checkpoint-based Judge wants to hook into. Rerouting every tool call
   through an orchestrator LLM call would duplicate and fight this existing
   machinery instead of reusing it.

3. **The journal's own stated risks point away from per-step routing.**
   `docs/journal/3_capable.md` flags "latency on tool call and iteration will
   significantly increase" as a hypothesis to watch for, and the design doc
   itself warns against over-engineering/token overuse. A router that makes
   an extra LLM decision before *every* game action multiplies both latency
   and spend by roughly the number of specialists it's choosing between.
   Plan-and-Execute keeps the extra LLM calls proportional to *plan
   checkpoints*, not to *actions*.

4. **The tool-policy machinery already anticipates specialist roles, cheaply.**
   `.boukensha/settings.yaml`'s `tool_roles` already defines `navigator`
   (`tbamud__move` only) and `inspector` (look/examine/consider/diagnose +
   `room_knowledge`, all read-only) — see `week3_capable/ruby/18_orchestrator/README.md:83-118`
   from the tool-permission step. `Tasks::Base.tool_policy` and
   `Registry.new(ctx, policy:)` already do the enforcement. Adding
   `Tasks::Planner` and `Tasks::Judge` subclasses of `Tasks::Base` is a
   small, idiomatic extension of a pattern that already exists — not new
   plumbing.

5. **`WorldKnowledge` is already a read-only, cross-session memory surface.**
   `lib/boukensha/world_knowledge.rb`'s `room_knowledge(room_title:, player:)`
   gives a Judge (or Planner) a way to sanity-check the Player's claims
   ("have I actually examined this?") against `log_viz`'s SQLite view without
   granting it any ability to act — a natural, already-built fit for an
   evaluator role that should observe, not play.

### Architecture

```
Session start / Judge says "replan"
        │
        ▼
   ┌───────────┐   writes   ┌───────────────────┐
   │  Planner   │──────────▶│ Context#plan       │◀── read every turn
   │ (Tasks::   │            │ (new mutable field,│    by PromptBuilder
   │  Planner)  │            │  same category as   │
   └───────────┘            │  Context#system)     │
                             └─────────┬───────────┘
                                       │ rendered into
                                       ▼
                        ┌────────────────────────────┐
                        │   Player Agent#run loop      │◀─ UNCHANGED:
                        │   (Tasks::Player, existing)   │   same tool_use
                        │   turn 1, 2, 3, ... N          │   ReAct loop,
                        └───────────────┬────────────────┘  same limits
                                        │
                    every N turns, OR on Agent
                    limit_reached/wrap_up ("stop and
                    summarize" — Agent already emits this)
                                        │
                                        ▼
                              ┌────────────────┐   reads transcript +
                              │     Judge       │   WorldKnowledge
                              │ (Tasks::Judge)  │   (read-only tools)
                              └───────┬────────┘
                                      │ verdict: continue / replan / flag
                                      ▼
                              back to Planner (if replan) or Player (continue)
```

**Where the plan lives:** add a mutable `plan` field to `Context`
(`lib/boukensha/context.rb`), the same category of "agent's notion of
current state" that `working_dir`/`system` already occupy — except mutable,
since `system` is fixed at construction. `PromptBuilder` renders it into
every request alongside the system prompt, so the Player sees "current goal:
…" on every iteration without needing a pinned message that compaction could
silently drop.

**Cadence trigger:** don't invent a new counter. `Agent#run` already emits
`@logger.limit_reached(kind:, n:, max:)` right before `wrap_up` — exactly the
moment a human player would pause and reassess. Hook the Judge check there,
plus an optional `every_n_turns:` config fallback for long uninterrupted
sessions that never hit a limit.

**Tool policies for the new roles** (extends the existing `tool_roles:`
block):
- `planner`: no tools — pure reasoning over the transcript + current plan.
  Keeps it cheap and removes any temptation to let it act.
- `judge`: `role: inspector` (already defined) — can `look`/`examine`/query
  `room_knowledge` to fact-check the Player's transcript, but can't
  `move`/`attack`/`quit`. An evaluator that can act on the world isn't an
  evaluator.

**New `Tasks::*` classes**: `Tasks::Planner < Tasks::Base`,
`Tasks::Judge < Tasks::Base`, mirroring `Tasks::Player` (`lib/boukensha/tasks/player.rb`)
exactly — each just needs `self.task_name`, plus a `tasks.planner:` /
`tasks.judge:` block in `settings.yaml` (provider/model — likely a cheaper/
faster model than the Player's, since these are short structured outputs,
not open-ended play) and a `prompts/planner/system.md` / `prompts/judge/system.md`.
Each gets logged with its own `task_name` exactly like `content_fact` and
`compactor` already are, so `log_viz` and OTEL traces separate Planner/Judge/
Player activity for free — no new observability plumbing needed.

### Pros

- Reuses `Agent`, `Tasks::Base`, `ToolPolicy`, `Registry`, `Logger`,
  `Telemetry` as-is — the new roles are configuration + two small classes,
  not a new execution engine.
- LLM-call overhead scales with plan checkpoints, not with actions — bounded,
  predictable cost and latency impact, directly answering the journal's own
  stated uncertainty.
- Judge has no tools that let it act, and Planner has none at all — clean
  separation of "decide" from "do," and neither can accidentally play the
  game on the character's behalf.
- Matches "real player thought process": infrequent deliberate planning,
  continuous instinctive play, occasional self-reflection — not a
  committee vote before every keypress.
- Naturally observable via existing per-`task_name` logging/OTEL — the data
  layer needed nothing new (OTel spans, `log_viz`'s `Cost by Task` table),
  though `log_viz`'s Iteration view and a model-usage breakdown turned out
  to need real work to actually *show* it to a human, not just carry it in
  the JSONL — see `docs/plans/agent_loop/log_viz_visibility.md` (added
  2026-08-06, after checking Phase 2 against a real session). Still
  materially cheaper than building a new visualization system from scratch,
  and still the thing that makes testing the journal's hypotheses (does
  this measurably improve goal completion vs. latency/token cost) possible
  at all.

### Cons / risks

- Plan can go stale between Judge checkpoints — if something in the room
  changes drastically mid-plan (e.g. the Player nearly dies), the Player has
  no way to force an early replan other than the existing turn-limit/token-limit
  triggers. Worth a cheap heuristic escape hatch later (e.g. Player's own
  wrap-up text could request a replan) if this proves to matter in practice.
- Two more moving parts than the pure single-agent baseline (below) — still
  more surface area to prompt-engineer and evaluate than "just the Player."
- `Context#plan` as one mutable field means only one active plan at a time;
  fine for a single character with one goal, would need rethinking if a
  future feature wants concurrent sub-goals.

### Alternatives considered

**A. Dynamic orchestrator-as-router (agent-as-tool, decide-then-delegate
every step)** — the Planner is called before *every* action and picks which
specialist (Navigator/Inspector/Player) handles it, the way the original
notes' "orchestrator dynamically delegates to subagents" phrasing suggests.
_Rejected for v1_: doubles-to-triples LLM round trips per game action (one
call to route, one to execute), which is precisely the latency/token blowup
the journal worries about, for a domain (look/move/attack/examine) that
doesn't obviously need per-action specialist routing. Revisit only if
evidence shows the Player genuinely picks the wrong tool/strategy often
enough that a router would pay for itself.

**B. Single-agent self-planning (no separate Planner/Judge; just prompt the
Player to keep an internal scratchpad and "think step by step")** — zero
extra LLM calls, simplest possible change. _Rejected as the sole mechanism_:
no separation of concerns, self-evaluation bias (the same model grading its
own work tends to rubber-stamp it), the "plan" isn't independently
observable/loggable (can't tell, from the transcript, "was there a plan and
was it followed" vs. reconstructing it after the fact), and a plan folded
into ordinary messages is exactly what `compact_messages!` can silently
drop. Good as the *fallback default* (Planner/Judge disabled == today's
behavior) and worth keeping cheap enough to compare against as a baseline.

> **Decision reversal (2026-08-07):** "Planner/Judge disabled == today's
> behavior" stopped being the default the moment `Tasks::Planner` actually
> shipped and nobody using the real `boukensha --player` command could see
> it run. Explicit call: ship the Planner on by default now, ahead of Judge,
> and build the rest of the loop incrementally while observing real agent
> behavior at each step — not "wait until the whole
> Planner→Player→Judge loop exists, then flip one switch." See
> [`repl_planner_integration.md`](repl_planner_integration.md) for what
> actually changed (`Config#planner_enabled?` defaults `true`) and exactly
> what was still deliberately absent at that point (no Judge, no
> auto-continue-past-a-checkpoint loop in the real REPL path). The
> comparability point above still holds — `tasks.planner.enabled: false` is
> the same "self-planning only" baseline this option always described, now
> reached by opting out instead of in.
>
> **Second reversal (2026-08-07, same day, once `Tasks::Judge` existed):**
> the "no Judge... in the real REPL path" half of the line above didn't
> survive the day it was written — the same "don't wait for the whole loop,
> observe incrementally" reasoning was applied again: `Repl` now also
> checks in with the Judge by default at a checkpoint, adapted for a
> human-driven REPL (a `:flag` verdict surfaces a warning rather than
> stopping anything, since there's no auto-continue loop here to stop). See
> [`repl_judge_integration.md`](repl_judge_integration.md). What's still
> genuinely absent from the real REPL path: an auto-continue-past-a-
> checkpoint loop — that remains exclusive to `Boukensha::Session`'s
> opt-in autonomous driver.

**C. Full specialist bench dispatched per action (Navigator/Inspector/Player
all live, orchestrator picks one per turn)** — same shape as A but with more
specialists. _Rejected for v1_ for the same reason as A, plus it front-loads
build cost (three prompts, three tool policies, three eval loops) before
there's evidence the Player's single-role ReAct loop is actually the
bottleneck. The `tool_roles.navigator`/`inspector` config already exists
cheaply as glob lists — promoting either to a real dispatched `Tasks::*`
subagent is a natural v2 if a concrete failure mode shows up (e.g. the
Player wastes many iterations getting lost, which would argue for a
cheap, move-only Navigator called only when explicitly needed).

### Deferred to v2 (not in this recommendation's scope)

- **`Tasks::Navigator`** (move-only, cheap/fast model) — only worth building
  if evidence shows pathfinding/getting-lost is a real iteration sink for
  the Player. `tool_roles.navigator` already exists in config for exactly
  this if/when it's needed.
- **Room-surveyor / persona / risk-mode** — explicitly called "optional" in
  the journal; layer on top of the Planner's prompt once the base
  Plan-and-Execute loop is validated, rather than building it in from day one.
- **Multi-goal/concurrent plans** — `Context#plan` as a single field is
  sufficient for one character with one active goal; don't generalize until
  a concrete use case needs it.

### How to validate against the journal's hypotheses

Before/after comparison on the same quest goal, same character, same model:
(1) turns/iterations to completion, (2) total tokens spent, (3) wall-clock
latency, (4) whether the Judge's "stuck" detections correspond to cases a
human reviewer would also call stuck. This directly tests the journal's
"exponential capability vs. complexity" uncertainty and "latency will
increase" hypothesis with real numbers instead of intuition.

## Notes/Concerns

- Evidence and testing have shown that pathfinding/getting-lost is a real problem. Agents can't finish a simple task mostly because they can't find the destination
- Goal decomposition is a future intended implementation. We might have to break a huge goal into smaller ones. For this phase we don't need it yet but worth noting down for future development