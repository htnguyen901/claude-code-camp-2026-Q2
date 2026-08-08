# Step 20 - Navigator

Branched from `19_knowledge` (stays the source of truth for everything
carried forward unchanged: context/token management, the TUI, the MCP-host
tool model, multi-player support, MUD response compaction, OpenTelemetry
traces/metrics, per-task tool policy, the Planner/Player/Judge agentic loop,
and `world__room_knowledge`/`world__route_to` — see that step's README).
This step adds a fourth agent-as-tool sibling to Planner/Player/Judge: a
`Tasks::Navigator` the Player can call mid-turn to walk toward a room it's
already discovered, instead of burning its own iterations on `look`/`move`
round trips. Full design/rationale:
[`docs/plans/agent_loop/navigator.md`](../../../docs/plans/agent_loop/navigator.md).

## What's new in this step

### `Tasks::Navigator` — a bounded, read-only route finder

`lib/boukensha/tasks/navigator.rb` mirrors `Tasks::Judge`'s shape exactly:
`task_name == "navigator"`, and `max_iterations` defaults to a small ceiling
(4 — a handful of tool calls to answer one question, not open-ended play)
that `tasks.navigator.max_iterations` in `settings.yaml` can still override.
`tool_roles.navigator` (`[world__room_knowledge, world__route_to]`) already
existed in `settings.yaml`, reserved for this — no new `ToolPolicy` code.
Deliberately **not** given `tbamud__move` or `tbamud__look`: the Navigator
answers whether a path exists, it doesn't walk it, and it's told its current
room by its caller rather than re-observing it itself (see
`prompts/navigator/system.md`). Because it never mutates world state, it's
safe to hand `consult_navigator` to Judge and Planner too, not just Player —
see [`docs/plans/agent_loop/agents_tools/tool_scope_rework.md`](../../../docs/plans/agent_loop/agents_tools/tool_scope_rework.md),
which reworked this step's original move-and-report design into the
read-only route finder shipped here.

### `consult_navigator` — a native tool on Player, Judge, and Planner's registries

Not an MCP tool (no external server involved) — `Boukensha.
register_navigator_tool` registers it directly via `Registry#tool`, at every
call site that builds a registry it should reach: Player (`Boukensha.run`,
`Boukensha.repl`, `Boukensha::Session.play`) and, since the rework, Judge
(`Boukensha.run_judge`) and Planner (`Boukensha.run_planner`) too. Takes
`from:`/`to:` room titles (trusted from the calling model, same posture
`world__room_knowledge`/`world__route_to` already use) and runs `Boukensha.
run_navigator` — a throwaway Context/Registry, registered against the
session's already-connected MCP servers (no second MUD login), driven by a
real `Agent#run` loop. Gated by each caller's own `tasks.<name>.tools`
exactly like any other tool name; `settings.yaml`'s `tasks.player/judge/
planner.tools.allow` all include `consult_navigator`. A session that omits
that `allow:` entry never sees the tool at all — `Registry#tool` silently
denies unknown names, same fail-safe-by-default posture every other tool
grant already has.

```ruby
consult_navigator(from: "The Temple Square", to: "The Beginning Of The Passage")
# -> "North, then east — 2 hops to The Beginning Of The Passage."
```

### Isolation: the Navigator's own tool calls never reach the caller's Context

`Boukensha.run_navigator`'s `Context`/`Registry` are its own throwaway pair,
never the caller's live one — its internal `world__route_to`/
`world__room_knowledge` calls are logged only under `task: "navigator"`. The
caller's own `ctx.messages` (Player, Judge, or Planner) gains exactly one
`tool_call`/`tool_result` pair for `consult_navigator`, the same isolation
property `run_judge`/`run_planner` already have relative to the Player.

### `prompts/navigator/system.md` — rewritten for a route *finder*, not a route *executor*

Resolved automatically once `Tasks::Navigator.task_name == "navigator"`
exists (`Tasks::Base.read_default_prompt`'s task-scoped path resolution is
already generic). Three rules: call `world__route_to` first; describe the
returned hops back as a short direction-by-direction path (using
`world__room_knowledge` only to resolve a direction name `route_to` didn't
already give); report plainly (not wander) when no route is known. Output
is one or two plain-text sentences describing the path — a tool result, not
a plan, and never a `tbamud__move` call.

## Install

```sh
cd week3_capable/ruby/20_navigator
bundle install
```

Prerequisites: unchanged from `19_knowledge` — a `mud-manager` MCP server on
`PATH`, `.boukensha/players/*.yaml` character profiles, `log_viz` on `PATH`
for `world__room_knowledge`/`world__route_to`, and optionally a local Ollama
daemon.

## Build

```sh
gem build boukensha.gemspec
gem install boukensha-0.20.0.gem
```

Installs the `boukensha` executable. `~/.boukensharc`'s `boukensha_path`
must point at this step's directory for it to run this step's code — see
`lib/boukensha_loader.rb`'s header comment.

## Run

```sh
boukensha --player noir
```

`consult_navigator` shows up in the Player's tool list alongside every
`tbamud__*` command and `world__room_knowledge`/`world__route_to` — same
REPL, nothing new to invoke by hand.

## Tests

```sh
rake test
```

New coverage for this step: `test_tasks_navigator.rb` (task name, prompt
resolution, `role: navigator` tool policy, `max_iterations` default/
override — mirrors `test_tasks_judge.rb`); `test_run_navigator.rb`
(`Boukensha.run_navigator` — a known route is described without moving,
`hops: nil` is reported plainly, `world__room_knowledge` may be consulted to
resolve a direction, and the Navigator's own `role: navigator` policy denies
both `tbamud__move` and `tbamud__look` even when the shared MCP connections
offer them — mirrors `test_run_judge.rb`'s `JudgeScriptedServer`/
`FakeMcpConnections` pattern); `test_consult_navigator.rb`
(`consult_navigator` is absent without an `allow:` entry and present with
one; a full `Boukensha.run` Player turn that calls it leaves exactly one
tool_call/tool_result pair in the Player's own request payload — no leaked
Navigator-internal messages; and the same isolation property exercised
through `Boukensha.run_judge`/`run_planner` instead, with
`Boukensha.run_navigator` stubbed since those two entry points don't expose
a `navigator_ollama_host`-style override).

## Not doing (this step)

Carried over from `navigator.md`'s "Deferred / out of scope" section —
flagged, not designed:

- **How the Player is told to use it** — prompting `prompts/player/
  system.md` to actually reach for `consult_navigator` (e.g. "if you're
  repeating the same room/action, try it") is left for once the tool is
  observed in real sessions.
- **Judge-triggered invocation beyond `consult_navigator` itself** — the
  Judge can now call `consult_navigator` directly (see
  `tool_scope_rework.md`) to check a path claim, but a `replan` verdict that
  routes through the Navigator instead of the Planner for one step is still
  out of scope; revisit only if that proves insufficient.
- **The cross-session validation write-up** (`v2_plan.md` item 1) — running
  sessions and reading the `log_viz` dashboard stays a manual, human step.
- **Fixing the Planner's own tool-avoidance behavior** — the Navigator helps
  a Player that's already playing and asks for help; it doesn't fix a
  Planner that never calls `world__route_to` up front. That's a
  `prompts/planner/system.md` prompt-engineering fix, tracked separately.
