# Resource bootstrap capability — why the Player couldn't resolve hunger while broke, and how to fix it without hardcoding

## Goal

A `dina` session (`.boukensha/sessions/20260809T034414Z-24bea505.jsonl`) spent
most of its turns broke, hungry, and unable to resolve either — not because
the game has no answer, but because every layer of the loop (Planner, Judge,
Player prompt, memory) independently steered away from the one action that
would have worked (combat/looting) and toward one that structurally can't
work in this MUD (`ask`-ing NPCs for charity). This doc is not "teach the
agent that hunger = fight a rat" — that's overfitting to one MUD's one
quirk. The actual capability gap is more general: **when the Player is stuck
on a sub-goal despite trying several different approaches, nothing in the
loop notices "several different things all failed the same way" and nothing
gives the Player permission to consider the loop's one enabled-but-avoided
action.** Fix that shape of gap and it should generalize past hunger to any
"I have zero of a resource I need" situation this or a future MUD throws at
the agent.

## Incident: what actually happened

Character `dina`, level 1, 0 gold, empty inventory, confirmed repeatedly via
`tbamud__info_self`. Over the session:

- `shop(op: buy, args: ale)` → `"Are you drunk or what?? - NO CREDIT!"` (the
  bartender then pukes on the player) — tried twice.
- `give(obj: coin, target: beggar, count: 1)` → `"You don't have that many
  coins!"` — the player tried to give away a coin it didn't have.
- ~22 `say_targeted(mode: "ask", ...)` calls to a dozen different NPCs
  (grocer, mercenary, cityguard, bartender, postmaster, a fido...) — every
  single result was the game's bare echo of the player's own line, never an
  NPC reply. `ask` (`week0_explore/mud_manager/lib/mud_manager/primitives.rb:117`,
  `TARGETED_SAY` at line 22) is a plain say/emote verb in this MUD, not a
  dialogue-tree trigger — the Player never had a way to learn this from the
  tool result itself, since a silent non-reply looks identical to "the NPC
  has nothing to say right now."
- `consume(mode: drink, obj: fountain)` → thirst resolved instantly. Hunger
  was never resolved by any means.
- Zero `attack` calls the entire session (tool-call histogram: 67 `move`, 35
  `look`, 21 `say_targeted`, 6 `shop`, 1 `give`, **0 `attack`, 0 `steal`, 0
  `get`-on-visible-gold**), despite `world_map.sqlite3`'s `room_contents`
  table already logging free gold piles in rooms the player had walked
  through (`"A little pile of gold coins is lying here."` in both `A
  Crossing Of Corridors` and `A Passage`) and `content_facts` logging a fido
  mob "mucking through the garbage looking for food" as a discovered fact —
  neither ever resurfaced as an actionable option.
- The Planner, across multiple replans, explicitly told the Player: *"Avoid
  combat while hungry or unsafe... otherwise keep searching for free food,
  charity, or a small safe source of gold"* and *"do not attack fidos,
  janitors, guards, blobs, or unknown mobs while broke, empty-handed,
  hungry, or hurt."* — ruling out the standard CircleMUD/TBAMUD bootstrap
  (kill something weak, loot/sell, buy food) precisely while broke, which is
  exactly when that bootstrap is meant to run.
- The Judge repeatedly praised "avoided combat" as evidence of a healthy
  session and returned `continue`, since each individual attempt was a
  *different* action/target and never tripped `repeated_tool_calls`
  (`lib/boukensha.rb:597-605`, keyed on identical tool name + args).
- The Chronicler wrote this into `.boukensha/memory/dina.md` as a
  **Strategy**: *"Prefer free food, charity, or safe income over paid
  services when broke"* — an approach that, per the transcript above, never
  once worked — and mischaracterized the bartender's explicit refusal as
  *"approachable by inquiry, but not yet a guaranteed solution."* This
  digest is fed verbatim into the next session's Planner call
  (`player_memory:` in `planner_input`, `lib/boukensha.rb:380-397`), so the
  next `dina` session starts already primed to repeat the same loop.

## Root cause: six compounding gaps, not one bug

1. **The Planner's self-generated risk heuristic bans the one action that
   would work**, and nothing checks that heuristic against whether the
   *alternative* it's steering toward (charity/inquiry) has any actual
   chance of succeeding in this MUD.
2. **The Player's system prompt (`prompts/player/system.md`) has zero
   resource-acquisition guidance.** It covers examine-before-use and
   stop-after-3-identical-failures, but nothing about what to do when a
   resource is at zero — the model invented a strategy from scratch, and
   invented the wrong one.
3. **`ask` is a dead-end the Player can't self-diagnose.** A failed `attack`
   or a failed `shop buy` returns an explicit rejection message; a failed
   `ask` returns nothing distinguishable from a successful one, so the
   Player's own "3 identical failures → switch approach" rule
   (`prompts/player/system.md` ¶4) never fires — from the Player's
   perspective, it never *failed*, it just never got a reply.
4. **No economic knowledge layer.** `world__room_knowledge`
   (`week3_capable/log_viz/lib/log_viz/mcp_server.rb:24-41`,
   `world_map.rb:754-770`) is explicitly geography-only — exits and
   examined objects, "a passive record of your own past exploration." Gold
   piles and shop prices the Player already discovered and that are already
   sitting in `world_map.sqlite3`'s `room_contents`/`content_facts` tables
   never resurface as "here's a known resource you haven't used."
5. **The Judge's stuck-detection is syntactic, not semantic.**
   `repeated_tool_calls` (`lib/boukensha.rb:597-605`) only catches the exact
   same tool + args repeated ≥3 times in the transcript window. "22 `ask`
   calls to 12 different NPCs, all failing the same way" and "6 different
   shops, all refusing the same purchase for the same reason" are both
   invisible to it — the failure pattern is real but the actions are all
   nominally distinct.
6. **The Chronicler writes stated intent as proven strategy.** Its prompt
   (`prompts/chronicler/system.md`) asks it to summarize "approaches that
   worked, worth repeating" under Strategies, but nothing tells it to check
   *whether the checkpoint reasoning it's reading actually reported success*
   before writing that header — it took the Planner's own risk-averse
   framing and the Judge's "no danger" framing at face value.

## Proposed fixes

Ordered to match the root-cause list; §7 covers sequencing/priority across
all of them.

### §1. Soften the Planner's blanket combat-avoidance framing

Not a code change — a nudge to `prompts/planner/system.md`. Today's prompt
gives the Planner no guidance at all on risk framing, so it invents its own
(and invented a self-defeating one). Add a paragraph roughly:

> When writing a plan around a scarce resource (no gold, no food, low HP,
> missing equipment), don't rule out an entire category of action (e.g. all
> combat) as a blanket precaution — that can remove the only realistic way
> to acquire the resource in the first place. Prefer conditional guidance
> ("avoid unfamiliar or clearly dangerous targets; a weak, familiar
> low-level mob is a reasonable way to get started") over an absolute
> prohibition.

This keeps the Planner's actual judgment call — it should still be
cautious — but stops it from foreclosing the one path that resolves the
scarcity it's worried about.

**Feedback**
- This seems to be very specific but not enough. What if there are more mechanics in the game (that we haven't discovered yet), do we have to keep on adding more and more to the prompt? If so then that defeats the purpose of having Agents playing the game 'by itself'

### §2. Give the Player prompt general resource-acquisition literacy

Add a paragraph to `prompts/player/system.md`, deliberately generic rather
than hunger-specific, so it transfers to any "I have zero of X" situation:

> If you're blocked because you have none of a resource you need (gold,
> food, a required item, health), don't limit yourself to asking for it or
> buying it — earning, looting, or taking it (fighting a weak/familiar
> target, picking up an item already sitting in a room, selling something
> you're carrying) is often the actual way this kind of game expects you to
> get started. Weigh the options, but don't treat "acquire by force or
> effort" as off the table just because "acquire by request or purchase"
> hasn't worked yet.

**Feedback**
- The same feedback above. The prompt snippet here itself is good but what if there are more then would it just keep growing? We can't keep guiding and interfering

### §3. Make a silent non-reply a self-diagnosable failure

Two complementary options, not mutually exclusive:

- **Prompt-level (cheap, do first):** extend the existing "3 identical
  failures" rule in `prompts/player/system.md` ¶4 to explicitly cover *no
  response* as a failure signal, not just an explicit rejection: "a tool
  result that doesn't answer what you asked — including no reply at all
  from an NPC you spoke to — counts as a failed attempt toward that
  three-strikes rule, the same as an explicit refusal."
- **Tool-level (bigger lift, consider only if §3's prompt fix proves
  insufficient in practice):** have the `ask`/`tell`/`whisper` primitive's
  MCP wrapper distinguish "NPC produced dialogue" from "bare echo, no
  reply" in its returned text, so the Player doesn't have to infer this
  from prose pattern-matching. Touches `mud_manager`, outside this repo's
  `week3_capable` scope — flagged here, not designed here.

**Feedback**
- Please implement this is in this phase also.

### §4. Surface already-discovered economic facts, not a new subsystem

Don't build a second knowledge system parallel to `world_map.sqlite3` — this
data is largely already being captured (`room_contents`, `content_facts`),
it just never resurfaces as actionable. Two small, additive changes:

- Extend `world__room_knowledge`'s response shape
  (`world_map.rb:761-766`, today `{room_title, examined, unexamined,
  connections}`) with a `resources:` field that surfaces anything already
  logged in `room_contents`/`content_facts` matching known resource-ish
  patterns (currency mentions, "lying here", shop listings) for that room —
  still a passive record of what's already been discovered, same posture as
  the rest of the tool, not a live scan or a new fact-extraction pipeline.
- When a `shop(op: list)` call succeeds, persist the returned price list
  against that room the same way an `examine` result already becomes a
  `content_fact` — so "I already know the pet shop is 300+ gold and can't
  afford it" survives a compaction/replan instead of needing to be
  rediscovered by calling `shop list` again.

### §5. Give the Judge a semantic stuck signal, not just a syntactic one

Extend `judge_input` (`lib/boukensha.rb:610-622`) with a second, LLM-facing
question rather than a second deterministic detector — this kind of pattern
("many different actions, one persistently unresolved sub-goal") is exactly
the kind of judgment call `repeated_tool_calls`'s deterministic tally can't
make but the Judge's own reasoning already could, if asked. Add to
`prompts/judge/system.md`, alongside the existing repeated-action guidance:

> Also watch for a sub-goal that stays unresolved across several *different*
> attempts — e.g. multiple different shops all refusing a purchase for the
> same reason, or several different NPCs all failing to help with the same
> request. That's the same kind of stuck as a literally repeated action,
> even though `repeated_actions` won't show it — treat it as a `replan`
> reason too.

This is deliberately not a new deterministic counter (unlike
`repeated_tool_calls`) — "these N attempts were all trying to solve the same
sub-goal" requires the kind of judgment a mechanical tally over tool
name+args can't make; that's what the Judge's own transcript-reading pass is
for.

### §6. Make the Chronicler check outcomes before calling something a Strategy

Add a line to `prompts/chronicler/system.md`'s existing Strategies
paragraph:

> Strategies — approaches that **actually succeeded this session**, worth
> repeating. Don't promote a checkpoint's stated intent or plan ("the plan
> says to prefer charity") to a Strategy unless the transcript/outcome you
> were given shows it actually worked; an approach that was merely *tried*
> without success belongs under Mistakes instead, even if the reasoning
> behind trying it sounded sensible at the time.

This directly targets the `dina.md` digest's actual error: it promoted an
untested, then-repeatedly-failing approach to Strategies because the
Planner's own reasoning sounded sensible, not because it worked.

## §7. Sequencing / priority

1. **§2 and §1 first** (prompt-only, no code, smallest blast radius, and
   they're the most direct fix for the incident: the Player was never told
   "fighting/looting is an option" and the Planner was actively told the
   opposite).
2. **§6 next.** The current `dina.md` is actively priming the next session
   toward the same failure right now — this is the highest-leverage single
   change relative to effort, and worth landing before the next real play
   session regardless of what else ships.
3. **§3's prompt half** alongside §1/§2 (same file, same review pass); defer
   §3's tool-level half unless the prompt fix turns out insufficient.
4. **§5** next — still prompt-only (Judge system prompt), no new
   deterministic code path, moderate risk of over-firing (see Known
   tradeoffs) so worth a few real sessions of observation before relying on
   it.
5. **§4 last** — the only one that touches `world_map.rb`'s schema/response
   shape and a new persistence path for `shop list` results; biggest lift,
   least urgent, since §1-§3 already remove the two hard blockers (no
   permission to fight, no way to notice `ask` was a dead end) without it.

## Acceptance criteria

Prompt-level fixes (§1, §2, §3's prompt half, §5, §6) are behavioral, not
mechanical, so most of their acceptance is "read a few real sessions/digests
after the change and confirm the pattern is gone," not a unit test. Where a
test *can* pin down something concrete:

- `test_tasks_planner.rb`/prompt-resolution tests: the new paragraphs are
  actually present in the resolved system prompt (a string-inclusion
  assertion, same style existing prompt tests already use for e.g. the
  wrap-up directive).
- A fixture `Session.play` run scripting a Judge response that reports the
  same-sub-goal-different-attempts pattern in prose (no `VERDICT:` line
  forcing `:continue`) still parses to `:replan` — confirms §5's prompt
  addition is being read, not that the LLM will actually apply it (that
  part needs real-session observation).
- A fixture `Boukensha.run_chronicler` call where the scripted checkpoint
  history shows a `:continue`/`:flag` reasoning describing a *failed*
  attempt: the chronicler_input assembly (`lib/boukensha.rb:454-478`) still
  passes that reasoning through unfiltered — the fix lives entirely in the
  Chronicler's own prompt discipline, not in what data reaches it, so there
  is no mechanical assertion possible here beyond "the input is what it
  always was"; real acceptance is manual: after the prompt change, rerun
  the actual `dina` session's checkpoint history through
  `Boukensha.run_chronicler` and confirm the regenerated digest no longer
  lists an unproven approach under Strategies. (`chronicler_input` itself is
  `lib/boukensha.rb:454-465`.)
- §4's `resources:` field: a `PlayerMemory`/`world_map` fixture test
  asserting a room with a logged gold-coin `room_contents` row surfaces it
  in `world__room_knowledge`'s response.

## Known tradeoffs / risks

- **§1/§2 could overcorrect into recklessness** if the wording leans too far
  toward "fight things" — both are written as "don't blanket-ban," not
  "always fight," specifically to avoid this; still worth a few sessions'
  observation before considering it settled.
- **§5's semantic stuck-detector is judgment-based, not deterministic**,
  unlike `repeated_tool_calls` — it can both over-fire (replanning a
  sub-goal that was about to resolve on the next try) and under-fire (an LLM
  Judge simply not noticing the pattern). Accepted for now as strictly
  better than not detecting this class of stuck at all; a future
  deterministic layer (e.g. tracking "turns since a named sub-goal last
  advanced") is a plausible follow-up if prompt-only proves too noisy.
- **§6 depends on the Chronicler correctly reading success/failure out of
  checkpoint reasoning it didn't generate itself** — same fundamental
  "trusting an LLM summary" risk `player_memory.md`'s own "Known
  tradeoffs" section already flags for the Chronicler generally, not new
  here, just newly *visible* via this incident's digest.
- **§4 is scope-limited on purpose** — surfacing already-discovered facts,
  not building live economic simulation/pricing awareness. A room whose
  gold pile has since been picked up by someone else, or a shop whose prices
  changed, will still report stale data — acceptable since
  `world__room_knowledge` already has this same staleness property for
  room layout today.

## Deferred / out of scope

- **A dedicated economic/quest subsystem** (tracking quest givers, reward
  tables, NPC dialogue trees) — real feature, much bigger than this
  incident's fix, not designed here.
- **`mud_manager` changes** (distinguishing a real NPC reply from a bare
  echo at the primitive/tool-result level, §3's tool-level option) — lives
  outside `week3_capable`, flagged as a possible follow-up only.
- **Retroactively correcting `.boukensha/memory/dina.md`** — this doc's
  fixes affect what gets written *going forward*; the existing digest still
  has the wrong strategy in it. Regenerating it (rerun `dina`'s actual
  checkpoint history through a fixed Chronicler prompt, or hand-edit) is a
  manual follow-up step, not something this plan automates — no automatic
  digest re-derivation tool exists yet (`player_memory.md`'s own "Deferred"
  section already flags this as unbuilt).
- **A general "stuck on any sub-goal" deterministic tracker** beyond the
  Judge's own semantic read (§5) — e.g. explicitly modeling sub-goals as
  first-class state the Judge/Planner both update — bigger redesign, not
  needed to fix this incident.

## Open questions

- Should §1/§2's resource-acquisition guidance stay fully generic (as
  drafted above), or is a short, explicitly-labeled "this MUD's economy
  works like X" domain-knowledge block (fed to the Planner alongside
  `player_memory:`, refreshed as more is learned) actually more useful than
  prompt-level generic advice? The generic version risks being too vague to
  change behavior; a domain block risks being exactly the kind of
  hardcoding this doc's Goal says to avoid. Leaning generic-first, revisit
  if real sessions show it wasn't enough.
  A: It will stay true to how a newbie player is playing the game now. Leaning generic-first, revisit if shown wasn't enough. Learn as you play
- Where should §4's surfaced economic facts actually live — folded into
  `world__room_knowledge`'s existing response (as drafted) so callers don't
  need a second tool, or a new `world__economic_knowledge` tool mirroring
  `world__room_knowledge`'s own shape? Folding in is simpler for callers;
  a separate tool keeps `room_knowledge`'s contract (`{room_title, examined,
  unexamined, connections}`) from growing indefinitely as more fact
  categories get added later. Leaning toward folding in for now since this
  is one field, revisit if more categories accumulate.
  A: folding in
- Is `.boukensha/memory/dina.md` worth manually fixing now (see Deferred),
  given the next `dina` session will read it verbatim regardless of how
  good §1/§2/§5 get? A stale bad digest can still out-argue a good live
  Planner nudge if the Planner weighs "past character experience" heavily.
  A: We should clear all dina's memory and start at 0 again when things are fixed

## Files touched (once actually implemented — not done by this plan doc)

- `week3_capable/ruby/21_memory/prompts/planner/system.md` — §1.
- `week3_capable/ruby/21_memory/prompts/player/system.md` — §2, §3.
- `week3_capable/ruby/21_memory/prompts/judge/system.md` — §5.
- `week3_capable/ruby/21_memory/prompts/chronicler/system.md` — §6.
- `week3_capable/log_viz/lib/log_viz/world_map.rb`,
  `week3_capable/log_viz/lib/log_viz/mcp_server.rb` — §4
  (`world__room_knowledge` response shape, `shop list` persistence path).
- `week3_capable/ruby/21_memory/test/test_tasks_planner.rb`,
  `test_tasks_player.rb`/equivalent, `test_tasks_judge.rb`,
  `test_tasks_chronicler.rb` — prompt-resolution assertions for §1/§2/§3/§5/§6.
- `week3_capable/log_viz/test/test_world_map.rb` — §4's `resources:` field
  fixture.
- `.boukensha/memory/dina.md` — manual regeneration, not a code change (see
  Deferred).
