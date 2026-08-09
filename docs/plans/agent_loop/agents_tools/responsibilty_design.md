## Goal

I want to re-design the Agent and their assigned tool/delegate abilities to help drive the game more like a real player:
- A real player can open map (or memories map in MUD since there is no UI) to find an area and navigate to get to a destination
- A planner is technically the "brain" of the player. It helps with reasonings the goal. It will utilize knowledge of the game world (like how player learn and use game knowledge) to make plans and to achieve tasks and quests in game. 
- A judge is like mentor, guiding and keeping the players in touch with the game, the goals/quests
- A navigator is more like a tool that could be utilized by the player and planner (players in general). In games with UI I often open map, pin a location and there will be a line or a path that I can follow to get there. In this project, it is built as a tool because I'd like to add more to it:
    - Sometimes a destination could be an unseen or unwalked area, but it might have connections with the nearby areas. For Example: The sewer might locate the The Dump. Even if the Sewer is never seen and The Dump is unwalked (logged from exits logs but never entered), the navigator (the part of the player that is good with directional reasonings) could argue that: "The Sewer might be near the Dump, let's check"


I need to refactor the tools to:
- The scope of tools are suitable and useful to each agent/subtask
- Scope of tools should be efficient so that we don't waste context and token usage on passing the tools to request to LLM every call
- The scope of tools should stay true to real gaming scenario. For example: The player should have access to commands in MUD

I also need to design the flow and the agent loop so that each agent can best utilize and can decide on the correct tools called, as I see sometimes agent do not call the most useful tools, leading to wrong actions


### Notes
- Judge cannot call any tools, can only judge on Planner's plan and Player's journey
- Navigator can be called by planner and player.

---

## Evaluation (2026-08-08)

Checked this against what's actually in the repo: `docs/plans/agent_loop/
navigator.md`, `v2_plan.md`, `high_level_agentic_loop_design.md`,
`docs/journal/3_capable.md`, and the code in `week3_capable/ruby/
20_navigator` (the untracked dir — `Tasks::Navigator` is already
implemented there, not just planned). Bottom line: the overall shape here
(Planner = brain/reasoning, Judge = mentor/checkpoint, Navigator = a
scoped tool available to whoever needs it) is the right direction and
already matches the architecture that's built — `tool_roles:` +
`ToolPolicy` in `.boukensha/settings.yaml` gives every task (`planner`,
`judge`, `player`, `navigator`) its own glob-scoped allow/deny list, and
each task already runs its own throwaway `Context`/`Registry`, so the
"scope tools per agent, don't waste tokens on tools an agent won't use"
goal is already solved as a mechanism. The gaps are more specific than
"wrong direction" — two of your notes conflict with behavior that was
already tried and fixed, and one is a real capability jump past a gate
this project already set for itself.

### 1. Planner as the "brain" — matches what's built, but the known gap is prompts, not scope

`Tasks::Planner` already gets `role: inspector` (read-only `look`/
`examine`/`room_knowledge`/`route_to`) so it *can* ground a plan in world
knowledge before committing. The journal (`3_capable.md`) already shows
this isn't enough on its own: in the "corridor in The Beginning of the
Passage" session, the Planner had `world__route_to` available and simply
never called it, producing a generic plan anyway. That's a prompt/
behavior problem (`prompts/planner/system.md` needs to *push* the model
toward using the tools it already has), not a tool-scope problem —
re-carving what tools the Planner can see won't fix a Planner that
ignores the tools it's already given. Worth keeping this distinction
explicit as you redesign: "which tools an agent can call" and "does the
agent reliably call the right one" are two different problems, and this
doc is squarely about the first.

### 2. Judge as "mentor" — the "no tools" note contradicts an already-validated fix

This is the one worth resolving before you act on it. The journal
records exactly this experiment: a tool-less Judge kept rubber-stamping
`continue` verdicts ("Judge kept giving the green light... Without World
Knowledge, Judge does not have significant leverage than the player").
The fix that's actually in `.boukensha/settings.yaml` today is to give
Judge `role: inspector` — the same read-only look/examine/room_knowledge
tools as above, explicitly *not* move/attack/quit/give. `prompts/judge/
system.md` states the boundary as "you never act in the world... only
look/examine/consider/diagnose... never move/attack/quit/give."

So "Judge cannot call any tools" is either:
- shorthand for "no *action* tools" — already true, nothing to change, or
- a literal zero-tools Judge — which is the version the journal already
  tried and found too weak (no leverage to fact-check the Player's
  claims, e.g. "I already examined the fountain").

If it's the second reading, I'd push back: that's a regression against
observed evidence, not a simplification. Recommend tightening the note
itself to "Judge gets read-only/inspection tools only, never anything
that acts" so it can't be misread later as "strip its tools entirely."

Feedback: 
- Judge should get inspection and world knowledge. Jude doesn't need to use look/examine since it is the player's responsibility and those info doesn't help Judge much in 'judging the plan and the execution'
- If Judge needs sepcialized info like navigation/path between rooms. Judge should retrieve info from sub-agent responsible for this specialized task if the path has already been reasoning, or call the agent to delegate the specilized task
- Despite saying Mentor, Judge is not a Gameplay mentor, but an overall mentor, keep the player staying on track with the Plan

### 3. Navigator with speculative "might be near the Dump" reasoning — real scope creep past a stated gate

This is the biggest gap between the doc and what's built. The Navigator
that's actually implemented (`navigator.md`, `Tasks::Navigator` in
`week3_capable/ruby/20_navigator`) is deliberately conservative: it calls
`world__route_to` (BFS over *already-discovered* edges only), walks the
returned hops, and if there's no route, "say so plainly and stop — do
not fall back to wandering... an unreachable/unroutable destination is a
fact to report, not a puzzle to solve by trial and error." The system
prompt is explicit: "never make up an exit, never explore blindly."

Your example — inferring that the Sewer might connect to The Dump even
though neither edge has been walked — is a genuinely different, harder
capability: probabilistic inference over *unconfirmed* topology, not
execution over confirmed topology. A few things worth weighing before
building it:
- **Nothing in the current schema supports it.** `world__room_knowledge`/
  `world__route_to` only know about rooms/exits that have actually been
  visited or logged; there's no proximity/clustering heuristic to infer
  from today. This would be new data modeling, not a tool-scope change.
- **It works against the safety invariant that makes Navigator cheap and
  predictable.** The whole reason Navigator is a small, bounded,
  `gpt-5.4-mini`-class task (`DEFAULT_MAX_ITERATIONS = 10`, narrow tool
  role) is that it only ever executes *known* routes. Letting it guess
  at unconfirmed connections turns it into a second explorer with all
  the same getting-lost risk the Player already has — the risk this
  whole redesign is trying to reduce.
- **This is explicitly the deferred "room-surveyor" idea.** `v2_plan.md`
  §3 already names this shape of capability (recommend-a-direction
  reasoning) and explicitly defers it: "Trigger to actually build
  either: item 1's written comparison showing the base loop works, plus
  (for room-surveyor specifically) a concrete case where Navigator's own
  room-reading proves insufficient." That gate hasn't been hit — the
  validation write-up in `v2_plan.md` item 1 (before/after comparison
  with Planner/Judge on vs. off) hasn't been run at all yet, and the
  conservative Navigator itself has no before/after numbers yet either
  (`navigator.md`'s own acceptance criteria include that spot-check and
  it isn't done).

Advice: don't fold speculative reasoning into Navigator v1. Ship and
validate the conservative version that's already built first; treat
"infer a likely-but-unconfirmed connection" as a separate, later
capability (a `suggest_unexplored_direction`-shaped tool, or folded into
the deferred room-surveyor) gated on evidence the conservative Navigator
actually falls short — which is exactly the order `v2_plan.md` already
lays out.

Feedback:
- Okay please leave the speculative reasoning out

### 4. "Navigator can be called by planner and player" — check what "called by Planner" would mean

Today, `consult_navigator` (the tool that actually issues `tbamud__move`
calls and relocates the character) is wired only onto the Player's
registry (`navigator.md` §5, three call sites — `Boukensha.run`,
`Session.play`, the REPL's Player construction). The Planner already has
direct, read-only access to `world__route_to`/`room_knowledge` via its
`inspector` role — enough to check "is there a known path?" while
planning, without moving anyone.

If "Navigator can be called by planner" means giving the Planner
`consult_navigator` itself, that's worth a second look: it would let a
*planning* step actually relocate the character mid-plan, which cuts
against a property `high_level_agentic_loop_design.md` calls out as a
deliberate pro — "Judge has no tools that let it act, and Planner has
none at all — clean separation of 'decide' from 'do,' and neither can
accidentally play the game on the character's behalf." Blurring that
means a replan could silently walk the character somewhere before a plan
is even finalized, and it stops being true that only the Player acts.
If what you actually want is just "Planner can sanity-check a route
exists before committing to a plan," that's already solved by the
read-only `route_to` it has today — no new wiring needed. Worth being
precise in the doc about which of these two you mean, since they have
very different blast radii.

Feedback:
- No. The Navigator should be a tool that answer: "is there a known path? If yes show the known path".
This tool should not execute any movement, should not relocate player.
- For example: Planner or Player called/delegated to Navigator to find a path. Navigator should returns with a minimal message (to save token but do not compromise comprehensiveness) describe exactly how the player can get their. Player will use this to call tbdmud_move tools to get there. 

### 5. Tool-scope efficiency / stay-true-to-MUD-commands goals

Both already achieved as a mechanism, not just a goal: `role: gameplay`
(`tbamud__*` minus account-management) keeps the Player honest to real
MUD commands, and the per-task `Registry`/`ToolPolicy` split (with its
own throwaway `Context` per task) is exactly what fixed the earlier bug
the journal recorded — "Planner and Judge's tools are bound by Player's
tool => FIXED by implementing separate Registry for each Task." Extending
this pattern to any new agent (give it a narrow `tool_roles:` entry, its
own `tasks.<name>:` block) is cheap and already idiomatic here — nothing
new to design, just keep following the existing pattern.

### 6. "Each agent should best utilize and decide on correct tools called"

This is real (journal: Planner ignoring `route_to`, Player wandering into
a teleporter it didn't understand, Judge rubber-stamping a bad strategy
because it lacked prior-turn memory) but it's a different lever from tool
*scoping*. `navigator.md` §0 already draws this line for the Navigator
case specifically: "that's a prompt/behavior gap in `prompts/planner/
system.md`, not something `Tasks::Navigator` fixes." Worth keeping that
separation explicit in this doc too — a tool-responsibility redesign can
make the *right* tool reachable and cheap to call, but closing "the agent
had the tool and didn't use it" gaps is prompt iteration (and ideally
before/after evals per task, which `v2_plan.md` item 1 already proposes
and which still hasn't been run).

### Summary / suggested next steps

1. **Resolve the Judge "no tools" note** — decide if you mean "no action
   tools" (already true, just reword) or a literal zero-tools Judge
   (a regression against journal evidence). Recommend the former.
2. **Don't add speculative/unconfirmed-connection reasoning to Navigator
   v1.** Validate the conservative version that's already built in
   `week3_capable/ruby/20_navigator` first (it hasn't shipped a
   before/after comparison yet); treat inference-over-unexplored-map as a
   separate, later, evidence-gated capability, consistent with
   `v2_plan.md` §3's own sequencing.
3. **Be precise about what "Navigator called by Planner" means.** If it's
   read-only route checking, that already exists via the Planner's
   `inspector` role. If it's the actual mover (`consult_navigator`),
   think through what it does to the decide/do separation before wiring
   it in.
4. **Treat "agents don't call the best tool" as its own workstream**
   (prompt engineering + before/after evals), separate from this
   tool-responsibility redesign — the two are easy to conflate but need
   different fixes.
   A: Please make a separate plan for prompt engineering on every tasks/subtasks in boukensha
5. Everything else in the doc's direction — role-scoped tools per agent,
   staying true to real MUD commands, keeping context/token cost down —
   is already the architecture in place; this redesign can extend that
   pattern rather than rethink it.
  A: Please evaluate and re-work the tool scope/tool roles and tool sets based on my feedbacks.
