# Tool scope / role rework — Judge, Navigator, Planner

Implements the feedback recorded in [`responsibilty_design.md`](responsibilty_design.md)
(2026-08-08) on top of that doc's own evaluation. Three items read as separate
asks but collapse to one root change: **`Tasks::Navigator` stops acting.**
Today it's the one non-Player task that calls `tbamud__move`, which is
exactly why `consult_navigator` could only ever be wired onto the Player's
registry — handing a mover to Judge or Planner would break the "Judge/
Planner never act" property `high_level_agentic_loop_design.md` calls out as
a deliberate invariant. Make Navigator read-only and that restriction
disappears on its own; Judge gets to delegate path-reasoning to it for free.

**Depends on:** `Tasks::Navigator` / `consult_navigator` as built in
`week3_capable/ruby/20_navigator` ([`navigator.md`](../navigator.md)),
`role: inspector` as built for Judge/Planner
([`evaluator.md`](../evaluator.md) §1, [`orchestrator.md`](../orchestrator.md) §3).

**Blocks:** [`prompt_engineering_plan.md`](prompt_engineering_plan.md) item 4
(the Navigator prompt) — that prompt can't be iterated on until this rewrite
lands, since it's rewriting the same file for a different job (path
*description*, not path *execution*).

---

## 0. What's changing, and why (one paragraph per feedback item)

**Judge (feedback §2).** Judge stops getting `tbamud__look` / `examine` /
`shop` / `consume` / `info_self` / `info_world` / `consider` / `diagnose` —
those are, in the feedback's own words, "the player's responsibility" and
don't help judging the plan/execution. Judge keeps direct access to
`world__room_knowledge` (a fact lookup, not an action, and useful for
exactly the fact-checking `evaluator.md` already documents — "check
world__room_knowledge for that room instead of trusting the transcript's
prose"). For path-specific reasoning specifically, Judge no longer calls
`world__route_to` itself either — it delegates to the same `consult_navigator`
tool the Player uses, per the feedback: *"If Judge needs specialized info
like navigation/path between rooms... call the agent to delegate the
specialized task."* And Judge's framing changes from "gameplay mentor" to
"overall mentor" — it isn't there to coach tactics, only to keep the Player
honest against the Plan.

**Navigator speculative reasoning (feedback §3).** No architecture change —
confirming what was already the conservative default. Nothing in this doc
adds inference over unconfirmed/unwalked connections.

**Navigator execution (feedback §4).** `Tasks::Navigator` stops executing
movement. It answers exactly one question — *"is there a known path, and
what is it?"* — and returns a short description. `tbamud__move` is removed
from the `navigator` tool role and from its system prompt's job description.
The Player is the only task left holding `tbamud__move`; it's responsible
for actually walking, using the path Navigator described.

**Consequence, not separately requested.** Because Navigator no longer
mutates world state, it's safe to hand `consult_navigator` to Judge *and*
Planner too — calling it costs a read-only round trip, same as calling
`world__room_knowledge` directly. This is what makes feedback §2's "delegate
to the sub-agent" instruction actually implementable without contradicting
the decide/do separation.

---

## 1. `tool_roles` (`.boukensha/settings.yaml`)

Current:
```yaml
tool_roles:
  full: ["*"]
  gameplay: ["tbamud__*"]
  navigator: [tbamud__move, world__room_knowledge, world__route_to]
  inspector: [tbamud__look, tbamud__shop, tbamud__consume, tbamud__examine, tbamud__info_self,
             tbamud__info_world, tbamud__consider, tbamud__diagnose,
             world__room_knowledge, world__route_to]
```

Proposed:
```yaml
tool_roles:
  full: ["*"]
  gameplay: ["tbamud__*"]
  # tbamud__move removed — Navigator never acts (see §0). Route-finding only.
  navigator: [world__room_knowledge, world__route_to]
  # Direct grant for tasks that need room facts but not path-finding
  # (Judge, Planner). Path-finding for both now goes through
  # consult_navigator instead of a direct world__route_to grant — see §2.
  world_knowledge: [world__room_knowledge]
```

`inspector` is **deleted**, not deprecated-in-place. After this change
nothing references it: Judge and Planner move off it below, and the Player
already gets every `tbamud__*` command via `gameplay`, so `inspector`'s
`tbamud__*` subset was always redundant there. An unreferenced role sitting
in config is exactly the kind of dead surface this redesign's own
efficiency goal (`responsibilty_design.md`'s "scope of tools should be
efficient") argues against — unlike `full`, which stays as a documented
manual debugging escape hatch, `inspector` has no such standing use once
this lands. Grep `role: inspector` across `tasks.*` and `test/` before
deleting (§5 lists the exact test files that reference it today).

## 2. Per-task tool grants

```yaml
tasks:
  planner:
    tools:
      role: world_knowledge
      allow: [consult_navigator]

  judge:
    tools:
      role: world_knowledge
      allow: [consult_navigator]

  player:
    tools:
      role: gameplay
      allow: [consult_navigator]
      deny: [tbamud__create_character, tbamud__delete_character]
    # unchanged — Player already had exactly this grant.

  navigator:
    tools:
      role: navigator   # world__room_knowledge + world__route_to, no tbamud__move
```

**Open question, flagged rather than settled:** moving Planner off
`inspector` onto `world_knowledge` + `consult_navigator` is an *inferred*
extension of the Judge feedback, not something feedback §2/§4 states about
Planner directly. The inference: the doc's own Goal section frames the
Planner as working from "knowledge of the game world" the way a player
consults a memorized map, not by personally issuing live `look`/`examine`
commands mid-plan over the Player's shared MUD connection — the same
"observing is the Player's job" logic feedback §2 applies to Judge. If
that's wrong and Planner should keep live perception tools, the fix is a
one-line revert (`role: inspector` back in `tasks.planner.tools`) — flagging
it here rather than silently deciding it, same as the evaluation doc's own
style of surfacing calls it made without hard evidence.

## 3. `Tasks::Navigator` code changes (`lib/boukensha/tasks/navigator.rb`)

- Doc comment: "Read/move-only route executor... Never given `tbamud__look`"
  → "Read-only route finder... never given `tbamud__move` or `tbamud__look` —
  it answers whether a path exists, it doesn't walk it."
- `DEFAULT_MAX_ITERATIONS`: currently `10`, sized for "issue N moves." A
  Navigator that only calls `world__route_to` (and, occasionally,
  `world__room_knowledge` to resolve an exit's direction name) needs at most
  a handful of tool calls before it can answer — propose lowering to `4`.
  Not load-bearing (still overridable via `tasks.navigator.max_iterations`),
  but the smaller ceiling documents the new, smaller job the same way
  Judge's `5` documents "check a couple of facts, then decide"
  (`evaluator.md` §2).

## 4. `prompts/navigator/system.md` rewrite

Current prompt tells the model to walk hops with `tbamud__move`. New job is
purely descriptive:

```
You are the Navigator: a route-finding specialist. You are given the room
the caller is currently in and a destination room, both by exact title.
Your only job is to say whether there is a known path between them, using
rooms and exits that have already been discovered — never invent an exit,
never guess.

1. Call world__route_to with the given `from`/`to` titles.
2. If it returns a hop sequence, describe it back as a short, concrete
   direction-by-direction path (e.g. "north, then east, then north — 3 hops
   to <destination>"). Use world__room_knowledge only if you need an exit's
   direction name that route_to's own result didn't already give you.
3. If it returns no route, say so plainly — an unreachable/unroutable
   destination is a fact to report, not a puzzle to solve.

You never move anyone and you have no tool that could. Output plain text
only: a short (one to two sentence) description of the path, or the fact
that none is known — not a plan, not prose, not a tool-call transcript.
This text is returned directly to whoever asked (Planner, Player, or Judge)
as a tool result; the caller decides what to do with it, including whether
and how to actually move.
```

The "caller decides... including whether and how to actually move" line
matters: this is the one place the prompt has to explicitly tell the model
its output feeds three different kinds of callers now, not one.

## 5. `consult_navigator` tool + registration (`lib/boukensha.rb`)

**Description string** (`register_navigator_tool`, `lib/boukensha.rb:607-618`)
needs to stop promising movement:

```ruby
registry.tool(
  "consult_navigator",
  description: "Ask a route-finding specialist whether there's a known " \
               "path between two rooms you've already discovered, using " \
               "only exits you've actually walked. Give the current room " \
               "and the destination, both by exact title (as they " \
               "appeared in a look/move result or an exit list). It will " \
               "not explore blindly, and it does not move you — it " \
               "returns a short description of the path (or says none is " \
               "known). If you want to actually get there, call " \
               "tbamud__move yourself, direction by direction, using the " \
               "path it describes.",
  parameters: { ... }  # unchanged: from:/to:, both exact room titles
) do |from:, to:|
  run_navigator(from: from, to: to, mcp: connections, logger: logger, ...)
end
```

**Registration sites.** Today `register_navigator_tool` is called only
where the Player's registry is built — `Boukensha.run` (`lib/boukensha.rb:135-136`),
`Session.play`, and the REPL's Player construction (`navigator.md` §5's three
sites). `Boukensha.run_judge` (`lib/boukensha.rb:417-466`) and
`Boukensha.run_planner` (`lib/boukensha.rb:310-347`) build their own
throwaway `registry` via `task_class.tool_policy` + `mcp&.register(registry)`
but never call `register_navigator_tool` — that's the actual reason Judge/
Planner can't reach `consult_navigator` today, independent of the
`tools.allow` policy check. Both need one added line, right after their
`registry` is built and before the `Agent.new(...)` call:

```ruby
# run_planner, after `mcp&.register(registry)`:
register_navigator_tool(registry, mcp, logger: logger)

# run_judge, same spot:
register_navigator_tool(registry, mcp, logger: logger)
```

`model:`/`backend:`/`api_key:`/`ollama_host:` are left at their `nil`
defaults here deliberately — `run_navigator` already falls back to
`Tasks::Navigator`'s own configured model when the caller doesn't override
(`lib/boukensha.rb:566-568`), the same fallback the Player's call site
relies on when its own `navigator_model` kwargs are left unset. No new
kwargs on `run_planner`/`run_judge` needed for this; if per-caller Navigator
model overrides turn out to matter later, add `navigator_model:` etc. to
both signatures then, mirroring `Boukensha.run`'s existing kwargs — not
speculatively now.

Gating stays exactly the fail-safe-by-default mechanism already in place:
`registry.tool(...)` no-ops for a name outside the policy
(`registry.rb:22-33`), so `consult_navigator` only actually appears for
Judge/Planner once `allow: [consult_navigator]` is added to their
`tasks.*.tools` blocks (§2) — the two changes must land together, since
either one alone is a no-op (code change without the config grant: never
registered as usable; config grant without the code change: nothing calls
`register_navigator_tool` at all for that task, so the `allow:` entry is
inert).

## 6. Tests to update

- `test/test_tasks_navigator.rb` — `NAVIGATOR_ROLE` drops `tbamud__move`;
  flip its assertion to `refute policy.allowed?("tbamud__move")` alongside
  the existing `look`/`attack`/`give` refutations.
- `test/test_consult_navigator.rb` / `test/test_run_navigator.rb` — the
  `NavigatorScriptedServer`/`ConsultNavigatorScriptedServer` fixtures
  currently script a `world__route_to` response *followed by* a sequence of
  `tbamud__move` tool calls; rewrite the scripted flow so the only tool call
  is `world__route_to` (plus, optionally, one `world__room_knowledge` call),
  and assert the returned text describes a path rather than confirming
  arrival. Add a case for "no route" that behaves the same as today (Navigator
  says so, makes zero further tool calls) — that part of the contract is
  unchanged.
- `test/test_config_judge.rb`, `test/test_config_planner.rb`,
  `test/test_tool_roles_config.rb` — currently assert `role: inspector`;
  update to `role: world_knowledge` plus an `allow: [consult_navigator]`
  check, mirroring `test_consult_navigator.rb`'s existing "no allow entry →
  not registered" / "with allow entry → registered" pair, but exercised
  against `run_judge`/`run_planner` instead of the Player's registry.
- New: an isolation test for Judge and Planner analogous to
  `test_consult_navigator.rb`'s Player version — after a Judge/Planner turn
  that calls `consult_navigator`, its own throwaway `ctx.messages` contains
  exactly one `tool_call`/`tool_result` pair for it, no leaked
  Navigator-internal messages (same assertion shape `evaluator.md`'s
  isolation test already uses).

## 7. Rollout order

1. Land the `Tasks::Navigator` + prompt + `tool_policy`/`tool_roles` change
   first (§1, §3, §4) with its own updated tests (§6, first two bullets) —
   this is a self-contained behavior change to an already-shipped component
   and should be verified in isolation before anything depends on it.
2. Land the `register_navigator_tool` call sites in `run_judge`/`run_planner`
   plus their config grants (§2, §5) together — as noted in §5, splitting
   these across two commits leaves one of them inert.
3. Re-run the navigator.md acceptance criterion this doc doesn't repeat: a
   before/after spot-check on a pathfinding-heavy quest, this time comparing
   "Player calls consult_navigator and walks itself" against the old
   "Navigator walks for it" behavior — confirm the Player reliably follows
   through on a described path (a new failure mode this rework introduces:
   the Player could get the path text and still walk it wrong). This is the
   one part of this rollout that's an empirical check, not a config/code
   change, and belongs to the prompt-engineering plan's evaluation loop
   (`prompt_engineering_plan.md` item 4) rather than being re-litigated here.

## Deferred / out of scope here

- **Prompt tuning beyond the mechanical rewrite in §4** (e.g. how directive
  vs. terse the path description should be, whether the Player's own prompt
  needs a nudge to actually use `consult_navigator`'s output) —
  `prompt_engineering_plan.md` item 4, not this doc.
- **Speculative/unconfirmed-connection reasoning** (the "might be near The
  Dump" idea) — explicitly left out per feedback §3; still gated behind the
  same evidence bar `v2_plan.md` §3 already sets, unchanged by this doc.
- **Whether Planner should keep `consult_navigator` at all vs. relying only
  on the Player to path-find during play** — no evidence either way yet;
  keeping the grant (§2) is the cheaper reversible default (an unused
  `allow:` costs nothing beyond one extra tool-list entry token-wise; a
  missing one would require a second doc/PR to add back if a session shows
  Planner needed it).
