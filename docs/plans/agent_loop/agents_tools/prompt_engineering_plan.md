# Prompt engineering plan — Planner / Judge / Player / Navigator

Requested in [`responsibilty_design.md`](responsibilty_design.md) item 4A:
*"Please make a separate plan for prompt engineering on every tasks/subtasks
in boukensha"* — split out from
[`tool_scope_rework.md`](tool_scope_rework.md) on purpose. That doc changes
*which* tools each task can see; this one is about a different, already
-named failure mode: **an agent has the right tool and still doesn't call
it, or calls it and misuses the result.** `navigator.md` §0 drew this line
for the Navigator case specifically ("that's a prompt/behavior gap in
`prompts/planner/system.md`, not something `Tasks::Navigator` fixes") and
the evaluation in `responsibilty_design.md` §1/§6 generalizes it to every
task. Re-scoping tools can make the *right* tool reachable and cheap; it
can't make a model reliably choose it.

**Scope: the four agent-loop tasks with their own `prompts/<task>/system.md`**
— Planner, Judge, Player, Navigator. `content_fact` and `compactor`
(`.boukensha/settings.yaml`'s other two `tasks.*` entries) are out of
scope: they're one-shot Ollama classification/rewrite subtasks with no
agentic tool-choice behavior to tune, not part of the Planner→Player→Judge
loop this plan is about.

**Depends on:** [`tool_scope_rework.md`](tool_scope_rework.md) for the
Navigator prompt specifically — item 4 below can't be evaluated until that
doc's `prompts/navigator/system.md` rewrite has landed, since it's a
different prompt job (describe a path vs. walk it), not a tuning pass on
the current one. Items 1-3 (Planner, Player, Judge) don't depend on it and
can proceed independently.

**Blocks:** nothing — this is the last item in the sequence
`v2_plan.md` §"Suggested order" leaves open (validation write-up, then
Navigator, then "fixing the Judge's prompt first" as the item-1 write-up's
own stated fallback if replan verdicts turn out noisy).

---

## 0. Why this needs its own methodology, not just "edit the prompt and see"

Every prompt gap already on record in `docs/journal/3_capable.md` was found
by running a session and reading the transcript after the fact, one
anecdote at a time — real evidence, but never compared against a baseline
or re-checked after the fix. `v2_plan.md` item 1 already named the fix
("same quest goal, same character, same model, run twice... record turns,
tokens, latency, and whether verdicts matched a human's read") and marked
it as the prerequisite before tuning Judge/Planner behavior further — and,
per that doc's own header, **it still hasn't been run.** Any prompt change
made without it is exactly the failure mode `responsibilty_design.md` §1
already flagged once: "re-carving what tools/prompts an agent gets won't
fix a gap you haven't actually confirmed the size of."

This plan therefore treats the baseline write-up as a hard prerequisite for
the Judge and Planner items below (§6), not an optional nice-to-have —
Player and Navigator prompt work can start without it since their evidence
(teleporter confusion, repeated NPC begging, `tool_scope_rework.md`'s own
new "does the Player correctly walk a described path" question) is already
concrete and doesn't need a Planner/Judge on/off comparison to see.

**Process for every item below, once its evidence bar is met:**
1. State the hypothesis as a specific, falsifiable claim ("Planner will call
   `world__route_to` before finalizing a plan when the goal names a room
   title it hasn't visited" — not "Planner should use its tools better").
2. Change exactly one prompt file. Resist bundling two hypotheses into one
   edit — `log_viz`'s per-task dashboard (Phase 4.5, already built) can only
   attribute an outcome to a prompt change if there's exactly one change to
   attribute it to.
3. Re-run the same fixed scenario(s) used for the "before" read (§6 defines
   the shared scenario set; task-specific scenarios are named per item
   below).
4. Compare via `log_viz`'s Iteration view + `Cost by Task`: turns to
   completion, tokens, and — for Judge specifically — whether verdicts
   still match a human's read of the same transcript (`v2_plan.md` item 1's
   own acceptance bar, reused rather than re-invented).
5. Record the result as a `docs/journal/` entry (this plan's own output
   contract, same as `v2_plan.md` item 1's), not folded silently into this
   plan doc — this doc stops at "here's the backlog and how to test each
   item," matching `v2_plan.md`'s explicit split between "plan" and
   "written comparison."

---

## 1. Planner

**Known gaps (all from `docs/journal/3_capable.md` / `responsibilty_design.md` §1):**
- Had `world__route_to`/`room_knowledge` available and never called it,
  producing a generic "explore from scratch" plan for a room the character
  had already walked (`dina` session, corridor-in-the-Passage goal).
- Made a 5-step plan without accounting for the Player's actual conditions
  (level, skills, inventory) — "the plan was made without acknowledging
  player's condition... seems like a generic system prompt at this stage."
- Given a second, different goal in the same session, didn't produce a new
  plan (stale-plan carryover).
- After a Judge-triggered replan, still didn't pin the exact room location
  via world tools — gave "another general plan again."

**Hypotheses to test (one at a time, per §0's process):**
- H1: an explicit imperative in `prompts/planner/system.md` — "if the goal
  or a replan reason names a specific room, call `world__room_knowledge`
  and/or `consult_navigator` before writing the plan, not after" — increases
  the rate of a grounded (tool-call-backed) plan vs. a generic one, on a
  fixed set of "goal names a known room" scenarios.
- H2: feeding the Player's actual state (level/skills/key inventory —
  already gatherable via `tbamud__info_self`/`diagnose`, though Planner no
  longer holds those tools per `tool_scope_rework.md` — so this is really
  "should `planner_input` include a Player-state summary the driver
  fetches once, rather than the Planner fetching it live") changes plan
  quality. Scope note: this may turn out to be a driver/data-plumbing
  change (`Boukensha.planner_input`), not a pure prompt change — worth
  confirming which before committing to a prompt-only fix.
- H3: explicit "if this goal differs from the prior plan's goal, don't
  reuse the prior plan's steps" language fixes the stale-plan-carryover
  case.

**Scenario set:** the `dina` session's own goal ("find and examine the
corridor in The Beginning of the Passage") is already a known repro for H1;
reuse it verbatim rather than inventing a new one.

## 2. Player

**Known gaps:**
- Wandered into a teleporter, didn't understand it, attempted to use it
  based on a guess ("I'll teleport to SANCTUS, since it's a likely source
  for a named passage or corridor") rather than examining it first or
  asking for help.
- Kept asking an NPC for free food/water on repeat instead of considering
  an alternative (fighting mobs for food) when the direct approach kept
  failing — a case Judge itself couldn't catch because the repeated ask
  "does not negate the plan," per the journal.
- **New, from `tool_scope_rework.md`:** once Navigator stops walking and
  only describes a path, the Player must reliably parse that description
  and issue the right sequence of `tbamud__move` calls itself — a failure
  mode that doesn't exist yet because the tool doesn't exist yet in its new
  form.

**Hypotheses to test:**
- H4: explicit guidance — "examine an unfamiliar object/device before using
  it, especially anything that changes your location" — reduces
  blind-teleport-style guesses. Scenario: reproduce a room with an unfamiliar
  interactable and see whether Player examines before acting.
- H5: explicit guidance to escalate strategy (not just tool) after N failed
  identical attempts at the same NPC/action, mirroring Judge's own
  `repeated_action_threshold` logic but as *Player* self-awareness rather
  than waiting for Judge to catch it externally. Open design question: does
  this belong in the Player's prompt at all, or is "Judge catches repetition"
  (already built, `evaluator_judge_redesign.md` §5-§6) sufficient and this
  would be redundant? Test H5 only if a session shows Judge's mechanical
  override (§5-§6) firing too late to matter in practice.
- H6 (blocked on `tool_scope_rework.md` landing): after the Navigator
  rewrite, does the Player reliably translate a `consult_navigator` text
  description into the correct `tbamud__move` sequence? If not, the fix is
  likely on the Navigator's output format (make the described path more
  mechanically parseable, e.g. one direction per line) rather than the
  Player's prompt — worth checking which side needs the change before
  editing either.

## 3. Judge

**Known gaps and existing partial fixes:**
- Rubber-stamped `continue` with no leverage before it had `room_knowledge`
  access — **already fixed** by the `role: inspector` grant
  (`evaluator.md` §1) and the repeated-action mechanical override
  (`evaluator_judge_redesign.md` §5-§6). Not a live gap; listed here only so
  this plan's backlog doesn't re-propose a fix that already shipped.
- Lacked prior-iteration memory, so it kept giving green lights to a
  strategy that "does not negate the plan" even when clearly unproductive
  (repeated NPC begging) — **already fixed** by `JudgeMemory`
  (`evaluator_judge_redesign.md` §3-§4).
- **Live gap:** none currently on record with concrete evidence — this is
  exactly why §0 makes the baseline write-up (`v2_plan.md` item 1) a hard
  prerequisite here rather than optional. Editing `prompts/judge/system.md`
  further without first confirming the existing fixes actually resolved
  the rubber-stamping problem in a real before/after run risks tuning
  against a problem that's already solved, or missing whatever gap
  replaced it.

**What changes regardless of the baseline write-up (mechanical, not a
hypothesis):** `prompts/judge/system.md` needs updating to match
`tool_scope_rework.md` §2 — drop the "look/examine/consider/diagnose"
language (those tools are gone), add "use `consult_navigator` to check a
path claim, not `world__route_to` directly" and the "you are not a
gameplay mentor, you keep the Player on track with the Plan, not with
moment-to-moment tactics" framing from feedback §2. This is a required
edit to keep the prompt truthful about the Judge's actual tool set, not an
experiment — do it as part of landing `tool_scope_rework.md`, before any
of the hypothesis-testing above.

**Hypothesis to test (after the baseline write-up exists):**
- H7: does the reframed "overall mentor, not gameplay mentor" language
  measurably change which verdicts the Judge produces (e.g. fewer `replan`
  verdicts driven by tactical disagreement, more driven by actual plan
  drift)? Only testable against the baseline `v2_plan.md` item 1 produces,
  since "measurably change" requires something to compare against.

## 4. Navigator

Not a tuning pass on the current prompt — `tool_scope_rework.md` §4
replaces it wholesale (path description, not path execution). Once that
lands, this plan's process (§0) still applies for iterating further:

- H8: does the "north, then east, then north — 3 hops" phrasing actually
  parse reliably for the Player/Judge/Planner callers, or does a different
  format (numbered list, one direction per line) reduce Player mis-walks
  (Player item H6 above)? These two hypotheses are coupled — resolve H6's
  "which side needs the change" question first, since it determines whether
  H8 is even the right lever.
- `navigator.md`'s own deferred acceptance criterion — a before/after spot
  check on a pathfinding-heavy quest — doubles as this item's baseline; no
  separate one needed.

---

## 5. Sequencing

1. **Mechanical Judge prompt update** (§3's "what changes regardless") —
   lands together with `tool_scope_rework.md`, not gated on anything here.
2. **Baseline write-up** (`v2_plan.md` item 1) — do this before H1-H3
   (Planner) or H7 (Judge). Player (H4-H5) and the Navigator rewrite itself
   don't need it and can proceed in parallel.
3. **Player hypotheses H4-H5** — independent evidence already exists;
   proceed any time.
4. **Navigator rewrite lands** (`tool_scope_rework.md`) → **H6/H8** — the
   Player-side and Navigator-side halves of "does the described path get
   walked correctly," tested together since they're coupled.
5. **Planner H1-H3, Judge H7** — after the baseline write-up (step 2)
   exists to compare against.

## Acceptance criteria (per hypothesis, not per this whole doc)

- A stated, falsifiable hypothesis (§0.1).
- Exactly one prompt file changed per test run.
- A before/after comparison on the named scenario(s), read via `log_viz`'s
  existing Iteration/Cost views — no new instrumentation required.
- A written result in `docs/journal/`, explicitly confirming or refuting
  the hypothesis — "refuted" is an acceptable, useful outcome, not a
  failure to close this out; reverting a prompt change that didn't help is
  itself the point of testing one hypothesis at a time.

## Deferred / out of scope here

- **Tool scope/role changes** — `tool_scope_rework.md`, not this doc; the
  two are easy to conflate (a "Planner ignores its tools" symptom can look
  like either a scope problem or a prompt problem) but this doc's whole
  premise is that they need different fixes.
- **`content_fact`/`compactor` prompts** — not agentic tool-choice tasks,
  out of scope per this doc's own scope note above.
- **Model/temperature/provider swaps** — a different lever than prompt
  wording; not addressed here.
- **Persona / risk-mode** (`v2_plan.md` §3) — explicitly sequenced *after*
  the base loop is confirmed good (item 1's gate), same gate this plan
  inherits for its own Planner/Judge items.
