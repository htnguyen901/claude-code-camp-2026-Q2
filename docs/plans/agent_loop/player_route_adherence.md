# Player route adherence — why the Player ignores the Navigator's exact route, and how to fix it without hardcoding

Debugging note prompted by a real session: `consult_navigator` returned an
exact route ("From Market Square, go north, then east, then up to reach The
Reception"), but the Player didn't execute it — it moved on its own accord
instead, the Judge flagged "didn't follow instruction," and the pattern
repeated across multiple checkpoints in the same session. This doc traces
why, and proposes a fix that stays entirely in prompts/tool design/state
plumbing — no code that intercepts or validates `tbamud__move` calls against
a route (see §2 for why that would be the wrong fix).

**Depends on:** [`navigator.md`](navigator.md) (the tool this bug lives in),
[`worker.md`](worker.md) (the Player's own unchanged-ReAct-loop framing this
doc respects). **Related:** [`../memory/context_lifecycle.md`](../memory/context_lifecycle.md) —
that doc's checkpoint-triggered trimming should land *after* this one, since
§3b below (`ctx.route`) is what makes trimming `@messages` safe without also
losing an in-progress route.

## 0. What's actually implemented today (differs from `navigator.md`'s original sketch)

`navigator.md`'s original design had the Navigator itself call `tbamud__move`
to walk the route. The codebase as it exists today deliberately moved away
from that — `.boukensha/settings.yaml`'s `tool_roles.navigator` comment says
so explicitly: *"it answers whether a path exists, it doesn't walk it"*
(`tool_roles.navigator: [world__room_knowledge, world__route_to]`, no
`tbamud__move`). `prompts/navigator/system.md` matches: step 2 says
*"describe it back as a short, concrete direction-by-direction path (e.g.
'north, then east, then north — 3 hops to \<destination\>')"* and closes with
*"You never move anyone and you have no tool that could."*

So `consult_navigator` is advisory-only prose. All execution — parsing the
route and issuing the right `tbamud__move` calls, hop by hop, over however
many of the Player's own turns/iterations it takes — is the Player's job.
That handoff is where this bug lives.

## 1. Root cause: three compounding gaps, not one bug

**1a. The only instruction to actually follow the route lives inside one
tool's `description:` field.** `register_navigator_tool` in `lib/boukensha.rb`
does say the right thing — *"it does not move you — it returns a short
description of the path... If you want to actually get there, call
tbamud__move yourself, direction by direction, using the path it describes"*
— but that text is a tool *description*, competing for the model's attention
with every other tool's description, not a system-prompt-level instruction.
The Player runs on `gpt-5.4-mini` (`.boukensha/settings.yaml` `tasks.player.model`)
— a small/cheap model is exactly the case where instructions buried in tool
metadata are least reliably followed. This was a known-deferred gap:
`navigator.md`'s own "Deferred / out of scope" section flagged it up front —
*"How the Player is told to use it... worth doing once the tool exists and is
observed in real sessions, not fixed in advance here."* It's now been
observed; this doc is that follow-up.

**1b. `prompts/player/system.md` never mentions `consult_navigator`, routes,
or hop-by-hop execution at all.** The whole file is four short paragraphs:
tool-call rationale, examining unfamiliar objects, and not repeating a failed
action 3×. Nothing tells the Player that a route it explicitly asked for is a
commitment to execute mechanically rather than context to keep loosely in
mind alongside everything else it's doing.

**1c. The route text is not durable — it can be silently forgotten.** It
lands as a single `tool_result` message inside `ctx.messages`
(`Agent#handle_tool_calls` → `@context.add_message(:tool_result, ...)`,
`lib/boukensha/agent.rb`), the same array `Context#compact_messages!`
blindly truncates (drops the oldest 40%, `lib/boukensha/context.rb:75-81`)
whenever usage crosses 85% of the context window. That check knows nothing
about "there's an in-progress route in here" — if compaction fires between
"got the route" and "finished walking it" (a realistic gap: each hop costs a
Player iteration, and multi-hop routes are the ones worth asking for), the
route is not merely deprioritized, it is *gone* from the Player's context.
From the model's point of view, at that point, it never received the
instruction it's being judged against. See
[`../memory/context_lifecycle.md`](../memory/context_lifecycle.md) for the
broader version of this problem — that doc's fix makes trimming happen
*more* often, which would make this specific failure mode worse, not better,
unless §3b below ships first.

**Also worth naming:** nothing checks, after a move, whether the Player
actually landed where the route said it would. There's no structural
self-verification — a Player that starts out following the route correctly
has no built-in way to notice a divergence has started; only the Judge
catches it, several turns later, at its next checkpoint, by which point the
damage (repeated flags, wasted turns) is already done.

## 2. Why a hardcoded enforcer is the wrong fix

It's tempting to intercept `tbamud__move` calls in code and mechanically
check them against the last `consult_navigator` route. Two reasons not to:

- It re-introduces the exact "something other than the Player walks the
  route" design the codebase deliberately moved away from (§0's settings.yaml
  comment) — just relocated into the Player's tool-dispatch path instead of
  a Navigator agent, with none of the benefit (a narrowly-scoped specialist)
  and all of the rigidity.
- It can't distinguish "ignoring guidance" from "reasonably adapting to
  something the guidance didn't anticipate" — a wandering monster interrupts
  the walk, an exit turns out blocked, the Player notices something worth
  examining first. This system already delegates exactly that judgment call
  to an LLM elsewhere (the Judge, deciding `continue`/`replan`/`flag`); a
  hardcoded move-checker would be a second, cruder, code-level version of a
  call this architecture already trusts a model to make well.

The fix instead makes route-following the model's own well-supported
default — reliable prompting plus state that survives long enough to be
followed — while leaving the judgment call about deviating where it already
lives.

## 3. Proposed fix

### 3a. Structured, checkable route output from the Navigator

Change `prompts/navigator/system.md` step 2's output shape from one prose
sentence to a short numbered list, one hop per line:

```
Route (3 hops) to The Reception:
1. north
2. east
3. up
```

Still plain text — no schema/JSON; the Navigator has no tools of its own to
feed structured output to, and every other agent-to-agent channel in this
system (the Planner's plan, the Judge's verdict) is already plain text by
design. Numbered, one-hop-per-line output is what already makes the
Planner's own "a handful of numbered steps" (`prompts/planner/system.md`)
mechanically followable; the same shape change here removes the need for a
small model to parse comma/"then"-separated prose into discrete actions.

### 3b. Give the active route the same durability as the plan — and fold the enforcement instruction into it, instead of a static system-prompt paragraph

**Revision note:** an earlier draft of this doc put the enforcement wording
in a permanent new paragraph in `prompts/player/system.md` (a former §3c).
Dropped in favor of the design below after review: this codebase has no
prompt caching (`lib/boukensha/backends/*.rb`, `prompt_builder.rb` — no
`cache_control`/ephemeral markers anywhere), so anything added to the static
system prompt is billed in full on *every* Player API call for the entire
session, whether or not a route is ever requested. A session that never
calls `consult_navigator` would pay for that paragraph on every turn for
nothing. Conditioning it on "there's actually a route active" is both
cheaper and more targeted — the reminder appears exactly when it's relevant,
right next to the content it's reinforcing, rather than as boilerplate
sitting in the static prompt disconnected from the situation it's about.

Add a `route` field to `Context`, alongside the existing `plan`
(`lib/boukensha/context.rb:8`, `:30-34`), folded into `effective_system` as
its own block whenever non-blank — the block carries both the route itself
*and* the follow-it instruction, so the instruction only enters the payload
when there's a route to follow:

```
## Active Route
You asked for and received this route — treat it as a committed sequence,
not a suggestion: execute each hop in order via tbamud__move before doing
anything else, and check the result of each move against what you expected
before issuing the next hop. If a move doesn't take you where this says it
would, stop and consult_navigator again with your new current room rather
than improvising the rest of the way.

<route text>

(Cleared automatically once you ask consult_navigator again, or you can
treat it as done once you've reached the destination.)
```

This is the load-bearing part of this fix, not a nice-to-have, for two
independent reasons:

- **Durability.** Because `effective_system` is built from `@system`, never
  `@messages`, `compact_messages!` structurally cannot touch it — this is
  already the documented reason `ctx.plan` survives compaction
  ([`orchestrator.md`](orchestrator.md) §2, [`worker.md`](worker.md) §1).
  Once the route lives here too, it can no longer be silently dropped by a
  compaction pass the way today's tool-result-only route can be (§1c).
- **Cost.** Exactly mirrors `effective_system`'s existing "nil/blank plan is
  a no-op, byte-identical payload" posture (`context.rb:30-34`) — a session
  that never calls `consult_navigator` sees zero bytes of this addition,
  ever. Only a session with an actual in-flight route pays for the reminder,
  and only for as long as that route is active.

Mechanism: the `consult_navigator` tool wrapper (`register_navigator_tool`,
`lib/boukensha.rb`) sets `ctx.route` to the Navigator's reply (wrapped in the
fixed instruction text above) on every call, overwriting whatever was there
before (a fresh consult always supersedes a stale one). The instruction
wording itself is a static constant in code (or `Context#route=`'s own
template), not something parsed from or checked against the route text —
nothing here inspects `tbamud__move` calls; durability plus a
well-timed reminder is the only job of this layer. The judgment call about
whether to keep following a route stays entirely with the model, exactly per
§2.

One trade-off worth naming: this version only reinforces *following* a
route once the Player already has one — unlike a standalone system-prompt
paragraph, it does nothing to nudge the Player toward *calling*
`consult_navigator` in the first place. That's fine for the failure mode
this doc is fixing (§0: a route was requested and then not followed, not "a
route was never requested"); if evidence later shows the Player under-uses
`consult_navigator` to begin with, that's a separate, smaller prompt
addition to weigh against the same always-on-cost question raised here.

## 4. Alternative considered and rejected for now: Navigator executes the moves

Reverting to `navigator.md`'s original design (Navigator calls `tbamud__move`
itself) would sidestep this whole class of problem — a narrowly-scoped
specialist with nothing else to decide is inherently more reliable at
"execute this route" than a Player juggling many concerns per turn. Not
recommended as the v1 fix here because: (a) it reverses a design decision
this codebase already made deliberately and recently (§0), and (b) it
removes the Player's ability to reasonably deviate mid-route (fight off a
monster, stop to examine something) — the read-only advisory design is
exactly what keeps the Player "the only role in this design that's allowed
to act on the world" (`worker.md`'s own framing) rather than splitting that
role. Worth revisiting only if §3a-3b, evaluated against real sessions, turn
out insufficient — same evidence-gated posture `navigator.md` and this
doc set already use throughout.

## Acceptance criteria

- `prompts/navigator/system.md`'s route description is numbered, one hop per
  line — a fixture test (mirrors `test_run_navigator.rb`'s scripted-response
  pattern) asserting a 3-hop `world__route_to` result produces a 3-line
  numbered route text.
- `Context#route` exists, defaults to `nil`, and is folded into
  `effective_system` as a `## Active Route` block (instruction text + route)
  only when non-blank — byte-identical `effective_system` when `route` is
  `nil`, same posture `Context#plan` already has (test mirrors
  `test_context_plan.rb`); this is also the direct regression test for the
  "zero token cost when navigation is unused" property §3b's revision note
  is built on.
- `Context#route`, like `Context#plan`, is never touched by
  `compact_messages!` — a regression test that sets `ctx.route`, forces
  compaction, and asserts the route text is unchanged and still present in
  `effective_system` afterward.
- `consult_navigator`'s tool wrapper sets `ctx.route` on every call
  (overwriting any prior value), wrapped in the fixed instruction text — an
  isolation test extending `test_consult_navigator.rb`'s existing assertion
  style, asserting both the route content and the instruction wording appear
  in `effective_system` after a call, and neither appears before one.
- A before/after session-log comparison on a quest requiring a multi-hop
  route (same manual spot-check style as `navigator.md`'s own last
  acceptance criterion), confirming route-following turns/deviations drop
  after §3a-3b ship — a human-read validation, not a hard pass/fail unit
  test, consistent with how this doc set already treats this class of
  behavioral claim.

## Deferred / out of scope

- §4 (Navigator executes the moves) — revisit only if §3a-3b prove
  insufficient in practice.
- A standalone, always-on `prompts/player/system.md` paragraph nudging the
  Player to *call* `consult_navigator` more (as opposed to reinforcing
  following a route it already has) — deliberately not built here, since it
  reintroduces the same always-billed-every-turn cost §3b's revision note
  moved away from; only worth it if evidence shows the Player under-uses the
  tool in the first place, a different problem from the one this doc fixes.
- Any hardcoded/code-level enforcement intercepting or validating
  `tbamud__move` calls against the last route — deliberately rejected, §2.
- Judge-side improvements (e.g., the Judge explicitly diffing `ctx.route`
  against recent moves instead of inferring drift from the transcript) — the
  Judge already catches this via its existing plan-mismatch/repeated-action
  reasoning; a route-specific check is a plausible follow-up but risks the
  same over-fitting §2 warns against, and isn't required for this fix to
  work.
- [`../memory/context_lifecycle.md`](../memory/context_lifecycle.md)'s
  checkpoint-triggered trimming — sequenced to land *after* this doc
  specifically because §3b here is what makes trimming `@messages` safe
  without also losing in-flight route state.

## Files touched

- `prompts/navigator/system.md`
- `lib/boukensha/context.rb` — `route` field (instruction text + route,
  templated), `effective_system`
- `lib/boukensha.rb` — `register_navigator_tool`'s block also sets `ctx.route`
- `test/test_context_plan.rb` (or a new `test_context_route.rb`)
- `test/test_run_navigator.rb` — numbered-route fixture
- `test/test_consult_navigator.rb` — `ctx.route` assertion

`prompts/player/system.md` is **not** touched by this doc — that was the
earlier, rejected design (§3b's revision note).
