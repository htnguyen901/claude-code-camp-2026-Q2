# v2 plan — what's still absent from the high-level design

**Status: planning only (2026-08-07) — nothing in this doc is built yet.**

The Planner→Player→Judge loop itself
([`high_level_agentic_loop_design.md`](high_level_agentic_loop_design.md)'s
TL;DR) is fully built and wired into both entry points — `Boukensha::
Session` (autonomous) and `Repl`/`boukensha --player` (default-on, see
[`repl_planner_integration.md`](repl_planner_integration.md)/
[`repl_judge_integration.md`](repl_judge_integration.md)). What's left is
exactly the high-level doc's own "Deferred to v2" list
([`high_level_agentic_loop_design.md`](high_level_agentic_loop_design.md)'s
"Deferred to v2" section), plus the two items its "Cons/risks" and
"Notes/Concerns" sections flagged as evidence-gated. This doc sequences and
sketches all of them together — each one still gets built in its own
component's file ([`orchestrator.md`](orchestrator.md), `worker.md`, a new
`navigator.md`, etc.) when the time comes; this is the "what order, why,
roughly what shape" layer, the same relationship
[`implementation_plan.md`](implementation_plan.md) has to the v1 build.

**Depends on:** nothing blocks *planning* this. Building most of it should
still wait on item 1 below — see "Suggested order."
**Blocks:** nothing yet — no downstream doc depends on this one until an
item here actually gets picked up.

## 1. Phase 5 — write up the validation run (do this first)

Not a new capability — the one the high-level doc's own "How to validate"
section and [`implementation_plan.md`](implementation_plan.md)'s Phase 5
already call for, and that has never actually been run. Promoted to the top
of this list because it's the cheapest item here (no code) and its answer
should inform whether items 2-4 below are worth building at all — e.g. if
real sessions show the Judge's `replan` verdicts are usually right, that's
a green light for leaning on it more (item 3's persona/risk-mode); if
they're mostly noise, item 4 (Player-initiated early replan) matters less
than fixing the Judge's prompt first.

- **What:** same quest goal, same character, same model, run twice —
  `tasks.planner.enabled: false` + `tasks.judge.enabled: false` vs. both
  `true`. Record: (1) turns/iterations to completion, (2) total tokens
  spent, (3) wall-clock latency, (4) for each `replan`/`flag` verdict the
  Judge produced, whether a human reviewing the same transcript in
  `log_viz` would also call that turn "stuck."
- **How:** `log_viz`'s Iteration view already renders Planner/Judge/Player
  as distinct sections (Phase 4.5) and `Cost by Task` already has the
  token/cost numbers — no new instrumentation needed, this is a "run it and
  read the dashboard" task, not a build task.
- **Output:** a written comparison (a follow-up `docs/journal/` entry, not
  a plan doc — this file's job stops at "the numbers exist and were
  checked," not at reporting them).
- **Acceptance:** at least one full before/after pair run and written up,
  with an explicit yes/no on "did the Judge's stuck-detections match a
  human's."

## 2. `Tasks::Navigator` — evidence gate already met

The high-level doc's "Deferred to v2" section said build this "only if
evidence shows pathfinding/getting-lost is a real iteration sink" — its own
"Notes/Concerns" section (added after that recommendation) already answers
this: *"Evidence and testing have shown that pathfinding/getting-lost is a
real problem. Agents can't finish a simple task mostly because they can't
find the destination."* The gate is met; this is no longer speculative.

- **Shape:** `Tasks::Navigator < Tasks::Base`, mirroring
  `Tasks::Planner`/`Tasks::Judge`. `tool_roles.navigator` already exists in
  `.boukensha/settings.yaml` (`["tbamud__move"]`) — zero new `ToolPolicy`
  code, same as Judge's `role: inspector` reuse.
- **What it's fed:** the current room (from the Player's last `look`/`move`
  result — already in `ctx.messages`, no new "where am I" tracking needed,
  same posture `world_knowledge.rb`'s header comment already takes), the
  navigation goal (a room title/direction, from the Planner's current step
  or the Player's own request — see "how it's invoked" below), and
  `room_knowledge`/`WorldKnowledge` for what's already been explored.
  Whether a Navigator needs *more* map structure than `WorldKnowledge`
  already exposes (`log_viz`'s `rooms`/`visits` tables) is an open
  question to resolve during design, not fixed here — start with what
  exists and see if it's enough before adding a new schema.
- **How it's invoked — the important design decision:** *not* a router
  called before every action (that's Alternative A/C in the high-level doc,
  already rejected for the same latency/token reasons it gives). Two shapes
  to choose between when building this:
  - **(a) Agent-as-tool:** the Player gets a `consult_navigator(goal:)` tool
    it can call when it notices it's going in circles — costs one extra LLM
    round trip only on the turns the Player actually asks for help, same
    "the agent decides whether it's useful" posture `room_knowledge`
    already uses.
  - **(b) Judge-triggered:** a `replan` verdict whose reasoning specifically
    diagnoses "lost/circling" routes the new plan through Navigator instead
    of Planner for that one step. More automatic, but couples Navigator to
    Judge's verdict quality — worth revisiting once item 1's numbers exist.
  Recommend starting with (a) — cheaper to build, doesn't require Judge to
  be right about *why* the Player is stuck, and is a strict opt-in cost
  addition (a session that never calls it pays nothing extra).
- **Acceptance criteria (sketch):** `Tasks::Navigator.tool_policy` allows
  only `tbamud__move` (deny everything else, same assertion style as
  `test_tasks_judge.rb`'s role check); a fixture test where the Player
  calls `consult_navigator` and gets back a single move direction, not a
  full plan or prose; a before/after comparison (reuse item 1's harness) on
  a quest specifically chosen for its pathfinding difficulty, since that's
  the concrete failure mode motivating this item.

## 3. Room-surveyor / persona / risk-mode — after item 1, not before

The high-level doc calls these "optional" and explicitly a layer on top of
the *already-validated* base loop, not a day-one component. Two genuinely
different ideas bundled under one heading in the original notes — worth
separating when scoping the actual work:

- **Room-surveyor:** survey a room's exits/contents and recommend which
  exit to try. Overlaps heavily with item 2 — likely folds into
  `Tasks::Navigator`'s own reasoning (a Navigator that can't see the room's
  exits can't recommend a direction) rather than becoming a fourth
  `Tasks::*` class. Revisit once Navigator exists and it's clear whether
  its own room-reading is sufficient or a separate surveyor step earns its
  keep.
- **Persona / risk-mode:** a play-style knob (cautious vs. aggressive)
  that shifts Planner/Judge behavior — e.g. a `tasks.planner.persona:`
  config value folded into the Planner's prompt, or a lower bar for the
  Judge to `flag` in a "cautious" session. Pure prompt-engineering on top
  of existing plumbing — no new `Tasks::*` class, no new tool policy,
  genuinely a v2-only concern since it's tuning behavior on a loop that
  needs to already be known-good (item 1) before "make it more cautious"
  is even a meaningful question to ask.
- **Trigger to actually build either:** item 1's written comparison showing
  the base loop works, plus (for room-surveyor specifically) a concrete
  case where Navigator's own room-reading proves insufficient.

## 4. Player-initiated early replan (`worker.md` §3)

The high-level doc's own Cons/risks section flags this: a plan can go
stale between Judge checkpoints (e.g. the Player nearly dies) with no way
to force an early replan besides hitting a turn/token limit.
[`worker.md`](worker.md) §3 already named this and deferred it pending
evidence "the Player getting stuck badly enough, well before a natural
checkpoint, that this matters." Not yet formally evidenced the way item 2
is, but worth sequencing right after Navigator since a Player that's lost
(item 2's problem) is a plausible source of exactly this kind of
mid-plan distress.

- **Design sketch — deliberately cheap, no extra LLM call by default:** a
  `request_replan` tool the Player can call, registered like any other
  tool (`role: full` already covers it, or an explicit `allow:` entry) —
  calling it just sets a flag the driver (`Session`/`Repl`) checks
  alongside `Session.checkpoint?` after the turn returns. This is *not* a
  second Judge-shaped LLM call — it's a deterministic signal the Player
  emits inline with its normal tool use, so a session that never calls it
  pays zero extra cost, matching the existing bias toward "extra LLM calls
  scale with checkpoints, not actions."
  - Whether the driver honors it by going straight to `replan` or still
    routes it through the Judge first (so a Judge can veto a Player's own
    "I'm stuck" claim, the same self-evaluation-bias concern the high-level
    doc's Alternative B raised) is the open design question — leaning
    toward routing through the Judge, since a Player calling this tool is
    itself a claim worth fact-checking, not an automatic trigger.
- **Acceptance criteria (sketch):** calling `request_replan` mid-turn causes
  the *next* checkpoint check (not `Agent#run`'s own loop, which stays
  unchanged per `worker.md`'s invariant) to fire even though
  `stop_reason` isn't `:max_iterations`/`:max_tokens`; a test asserting a
  session with `request_replan` never called behaves byte-identically to
  today.

## 5. Multi-goal / concurrent plans

Still the lowest priority here — `Context#plan` as one field is sufficient
for one character with one active goal, and no concrete use case has
forced the question yet. Worth separating two things the high-level doc's
"Notes/Concerns" bundles together:

- **Goal decomposition** ("we might have to break a huge goal into smaller
  ones") is *already* partly handled — the Planner's output is already a
  numbered multi-step plan (see `prompts/planner/system.md`), which is
  sequential decomposition within one active goal, not concurrency.
  If a goal proves too large for one plan's worth of steps, the more
  likely fix is a `replan` verdict once a step completes (already built),
  not a new data structure — try that first.
- **True concurrency** (e.g. tracking a main quest and a side quest as two
  independently-progressing plans at once) is the part with no design yet
  and no evidence it's needed. If it comes up: `Context#plan` (single
  field) → `Context#plans` (a small ordered collection, "active" one
  rendered into `effective_system`, same compaction-immunity property) is
  the shape sketched here, deliberately not built until a concrete session
  needs two goals live at once.
- **Trigger:** a real quest/session that actually needs two concurrent
  goals — don't build ahead of that.

## Suggested order

1. Validation write-up (item 1) — cheapest, and its answer shapes priority
   for everything else.
2. `Tasks::Navigator` (item 2) — evidence gate already met, most concrete
   payoff.
3. Player-initiated early replan (item 4) — cheap (no extra LLM call by
   default), complements Navigator if a lost Player is also a distressed
   one.
4. Room-surveyor / persona / risk-mode (item 3) — only after item 1
   confirms the base loop is worth tuning.
5. Multi-goal/concurrent plans (item 5) — only if a concrete session
   forces it; no work until then.
