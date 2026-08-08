# Navigator — `Tasks::Navigator`

Implements [`v2_plan.md`](v2_plan.md) item 2 ("`Tasks::Navigator` — evidence
gate already met"). Same family as [`orchestrator.md`](orchestrator.md)
(Planner), [`evaluator.md`](evaluator.md) (Judge), and
[`worker.md`](worker.md) (Player) — this is that fourth component's own
file, the one those three docs' "Deferred / out of scope" sections all
pointed at.

**Scope note:** `v2_plan.md` item 1 ("Phase 5 — write up the validation
run") is deliberately **not** part of this doc or its acceptance criteria —
running sessions and reading the `log_viz` dashboard is being kept as a
manual, human step for later, not something this plan builds or automates.
This doc's own "Acceptance criteria" section below is the normal
per-component verification every sibling doc has (fixture tests, isolation
tests) — that is not the same thing as item 1's cross-session validation
write-up, and doesn't require it as a prerequisite.

**Depends on:**
- `tool_roles.navigator` already defined in `.boukensha/settings.yaml`
  (`[tbamud__move, world__room_knowledge, world__route_to]`) — zero new
  `ToolPolicy` code, same reuse [`evaluator.md`](evaluator.md) §1 did for
  `inspector`.
- [`orchestrator.md`](orchestrator.md) §1's task-scoped prompt resolution
  (`Tasks::Base.read_default_prompt` → `prompts/<task_name>/system.md`) —
  already generic, just needs a new `prompts/navigator/system.md` file.
- [`docs/plans/tools_policy/mcp_connection_sharing.md`](../tools_policy/mcp_connection_sharing.md)'s
  `Boukensha::McpConnections` — Navigator reuses the session's already-
  connected `mud`/`log-viz` servers exactly the way `run_judge`/`run_planner`
  already do, not a second MUD login.
- `world__room_knowledge` / `world__route_to` (`docs/plans/world_knowledge/world_knowledge.md`),
  hosted by `log_viz --mcp` — Navigator's pathfinding is a thin wrapper
  around `world__route_to`'s existing BFS, not new pathfinding logic.

**Blocks:** nothing yet. [`v2_plan.md`](v2_plan.md) item 4 (player-initiated
early replan) is sequenced right after this one but is independently
buildable — it doesn't read anything Navigator produces.

## 0. What problem this actually solves (and what it doesn't)

The evidence gate quoted in `v2_plan.md` — *"Agents can't finish a simple
task mostly because they can't find the destination"* — is a **Player-side,
mid-play** failure: the Player is already acting, burning iterations on
`look`/`move` round trips without making progress toward a room it has
already discovered.

This is a different failure from the one seen in the `dina` /
`20260808T030820Z-a9ca3b6f` session (goal: "find and examine the corridor in
the beginning of the passage"): there, the **Planner** had `world__route_to`
available and simply never called it, producing a generic "explore from
scratch" plan up front. That's a prompt/behavior gap in
`prompts/planner/system.md`, not something `Tasks::Navigator` fixes — a
Navigator only helps once the Player is already playing and asks for help.
Worth calling out because it's tempting to treat this build as "the fix" for
that session; it isn't, though it does provide a second, independent
mitigation: even if the Planner's up-front plan is generic, a Player that
notices it's circling can still reach the exact same already-discovered room
by asking the Navigator directly.

## 1. `Tasks::Navigator`

Mirrors `Tasks::Judge` (`lib/boukensha/tasks/judge.rb`) exactly in shape:

```ruby
module Boukensha
  module Tasks
    # Read/move-only route executor: given a destination room title and the
    # Player's own current room title, walks there over already-discovered
    # edges (world__route_to) and reports what happened. Never given
    # tbamud__look — deliberately fed "where am I" by its caller instead of
    # re-observing it itself, see §3. tools: { role: navigator } in
    # settings.yaml — tbamud__move + world__room_knowledge/route_to, nothing
    # else (no attack/examine/give — a router, not a second Player).
    class Navigator < Base
      def self.task_name = "navigator"

      # A bounded walk (a handful of hops, at most), not open-ended play —
      # same posture as Judge's small ceiling (evaluator.md §1), just sized
      # for "issue N moves" instead of "check a couple of facts."
      # tasks.navigator.max_iterations in settings.yaml still overrides this.
      DEFAULT_MAX_ITERATIONS = 10

      def self.max_iterations(settings)
        value = fetch(settings, :max_iterations)
        value.nil? ? DEFAULT_MAX_ITERATIONS : Integer(value)
      end
    end
  end
end
```

`settings.yaml` addition (the `tool_roles.navigator` glob already exists —
this is purely the new `tasks.navigator:` block, same shape as
`tasks.judge:`):

```yaml
tasks:
  navigator:
    provider: openai
    model: gpt-5.4-mini     # cheap/fast — bounded moves, not open-ended play
    max_output_tokens: 300
    max_iterations: 10
    tools:
      role: navigator
```

## 2. `prompts/navigator/system.md`

New file, resolved automatically once `Tasks::Navigator.task_name ==
"navigator"` exists (`orchestrator.md` §1's path-scoping already handles any
new task name generically — no code change needed beyond adding the file).
Sketch:

```
You are the Navigator: a movement specialist. You are given the room you're
currently in and a destination room, both by exact title. Your only job is
to get from one to the other using rooms and exits the player has already
discovered — never make up an exit, never explore blindly.

1. Call world__route_to with the given `from`/`to` titles.
2. If it returns a hop sequence, call tbamud__move once per hop, in order.
   Stop and report immediately if a move's result doesn't match what you
   expected (blocked, a different room than the route predicted, a fight
   started) — do not improvise past a broken route.
3. If it returns no route, say so plainly and stop — do not fall back to
   wandering with tbamud__move; an unreachable/unroutable destination is a
   fact to report, not a puzzle to solve by trial and error.

Output plain text only: one or two sentences on what happened (arrived /
how far it got / why it couldn't), not a plan, not prose, not a tool-call
transcript. This text is returned directly to the player as a tool result.
```

## 3. What it's fed, and the "where am I" decision

**Correction to `v2_plan.md`'s own sketch:** that doc says Navigator is fed
"the current room (from the Player's last look/move result — already in
`ctx.messages`, no new 'where am I' tracking needed, same posture
`world_knowledge.rb`'s header comment already takes)". `lib/boukensha/
world_knowledge.rb` no longer exists in this codebase — `world_knowledge.md`
§3 already migrated `room_knowledge`/`route_to` to be MCP-hosted by
`log_viz` instead of a hand-written boukensha module, and nothing on the
boukensha side parses room titles out of raw MUD text today (that parsing —
`LogViz::RoomEcho`/`Session#current_room`, `week3_capable/log_viz/lib/
log_viz/room_echo.rb` + `session.rb:519-524` — exists exactly once, in
`log_viz`, as an *offline consumer* of already-written session logs, not as
something `boukensha` can call in-process during a live turn). Duplicating
that parser inside `boukensha` just to auto-fill "current room" would be the
same kind of duplication `world_knowledge.md` §3 already fixed once by
moving `room_knowledge` to MCP instead of hand-rolling it twice.

**Decision: trust the calling model, same as every other room-title
argument this system already uses.** `world__room_knowledge(room_title:)`
and `world__route_to(from:, to:)` already ask the *Player* to supply exact
room titles as tool arguments, and that trust model works (the Player has
just seen its own current room's title verbatim in the tool result a moment
earlier). `consult_navigator` does the same:

```ruby
registry.tool(
  "consult_navigator",
  description: "Ask a movement specialist to walk you toward a room you've " \
               "already discovered, using only exits you've actually " \
               "walked. Give your current room and the destination, both " \
               "by exact title (as they appeared in a look/move result or " \
               "an exit list) — it will not explore blindly, and reports " \
               "back what happened rather than a plan.",
  parameters: {
    from: { type: "string", description: "Your current room title, exactly as your last look/move result showed it." },
    to:   { type: "string", description: "The destination room title, exactly as you've seen it (e.g. in an exit list)." }
  }
) do |from:, to:|
  Boukensha.run_navigator(from: from, to: to, mcp: connections, logger: logger,
                           model: navigator_model, backend: navigator_backend,
                           api_key: navigator_api_key, ollama_host: navigator_ollama_host)
end
```

This is why `tool_roles.navigator` deliberately excludes `tbamud__look`
(already true in today's `settings.yaml`, not a change this doc makes): the
Navigator isn't meant to re-observe its own position, it's meant to be told
it, same division of labor `world__route_to`'s own `from:`/`to:` params
already assume.

## 4. `Boukensha.run_navigator` — mirrors `run_judge` exactly

Same shape as `Boukensha.run_judge`/`run_planner`
(`lib/boukensha.rb:297-334`, `:404-453`): a throwaway `Context`/`Registry`
built from `tasks.navigator.tools` via `Tasks::Base.tool_policy`, registered
against the session's already-connected `McpConnections` (no second MUD
login — same "Player, Judge, Planner are siblings, not a hierarchy"
property `orchestrator.md` §3's third correction established, extended to a
fourth sibling here), run through a real `Agent#run` loop (it has tools to
dispatch, unlike a bare `Client#call`).

```ruby
def self.run_navigator(
  from:, to:,
  mcp:               nil,
  logger:,
  model:             nil,
  backend:           nil,
  api_key:           nil,
  ollama_host:       "http://localhost:11434",
  max_output_tokens: nil,
  max_iterations:    nil
)
  cfg           = config
  task_class    = Tasks::Navigator
  task_settings = cfg.tasks(task_class.task_name)
  system        = task_class.system_prompt(task_settings, user_prompts_dir: cfg.user_prompts_dir, default_prompts_dir: Config::PROMPTS_DIR)
  model       ||= task_class.model(task_settings)
  backend     ||= task_class.provider(task_settings).to_sym
  api_key     ||= resolve_api_key(backend)
  max_output_tokens ||= task_class.max_output_tokens(task_settings)
  max_iterations    ||= task_class.max_iterations(task_settings)

  ctx      = Context.new(system: system)
  policy   = task_class.tool_policy(task_settings, tool_roles: cfg.tool_roles)
  registry = Registry.new(ctx, policy: policy)
  mcp&.register(registry)

  ctx.add_message(:user, "Current room: #{from}\nDestination: #{to}")

  be      = build_backend(backend, model: model, api_key: api_key, ollama_host: ollama_host)
  builder = PromptBuilder.new(ctx, be)
  client  = Client.new(builder)

  agent = Agent.new(context: ctx, registry: registry, builder: builder, client: client, logger: logger,
                     task_name: task_class.task_name, max_iterations: max_iterations, max_output_tokens: max_output_tokens)
  agent.run.strip
end
```

No verdict-style parsing (unlike Judge's `VERDICT:` convention) — like the
Planner, Navigator's return value is consumed only as the `consult_navigator`
tool's result text, never branched on by driver code. Give it `task_name:
"navigator"` (already threaded through above) for free `log_viz`/OTel
per-task separation — `implementation_plan.md` Phase 4.5 already confirmed
this needs zero `log_viz`-side changes for a new task name.

**Isolation, same as Judge/Planner:** Navigator's `tbamud__move` calls run
over the *shared* live `mud`-server connection (same character, same login —
that's the whole point, it must actually relocate the Player's character),
but its `Context`/`Registry` is its own throwaway pair, never the Player's
live `ctx`. Concretely: the Player's `ctx.messages` gains exactly one
`tool_call`/`tool_result` pair for `consult_navigator`, never the
intermediate per-hop `tbamud__move` calls/results the Navigator made
internally — those only appear in the log under `task: "navigator"`. The
Player finds out where it ended up only from the Navigator's own summary
text (and can always confirm with its own `tbamud__look` next turn, same as
after any other event that moves it).

## 5. Registration point: `consult_navigator` on the Player's own registry

Not an MCP tool (no external server involved) — a native
`registry.tool(...)` block, same mechanism `Tools::Mcp.register_client`
already uses for MCP-derived tools (`lib/boukensha/tools/mcp.rb:65-71`), just
called directly instead of driven by a server's catalog. Registered
alongside the Player's own registry construction, at every call site that
builds one:

- `Boukensha.run` (`lib/boukensha.rb:96-101`, right after
  `connections.register(registry)`)
- `Boukensha::Session.play` (`lib/boukensha/session.rb:85-90`, same spot)
- `Boukensha.repl` → `Repl`'s construction (wherever `Boukensha.run`'s
  twin sets up the Player's registry for the interactive path — same
  pattern, not sketched twice here)

Gated by `tasks.player.tools`, same as any other tool name — `role:
gameplay` (`tbamud__*`) doesn't match `consult_navigator`, so it needs an
explicit `allow:` entry:

```yaml
tasks:
  player:
    tools:
      role: gameplay
      allow: [consult_navigator]
      deny: [tbamud__create_character, tbamud__delete_character]
```

`Registry#tool` already no-ops (denies, doesn't raise) for a name outside
policy (`registry.rb:22-33`) — a session that doesn't add the `allow:` entry
above simply never sees `consult_navigator` in its tool list, same
fail-safe-by-default posture every other tool grant in this codebase has.

## Acceptance criteria

- `Tasks::Navigator.tool_policy` allows only `tbamud__move`,
  `world__room_knowledge`, `world__route_to` — deny everything else,
  including `tbamud__look` — same assertion style as
  `test_tasks_judge.rb`'s role-check test.
- A fixture test (mirrors `test_run_judge.rb`'s `JudgeScriptedServer` /
  `FakeMcpConnections` pattern): given a scripted `world__route_to` response
  with a 2-3 hop sequence, `run_navigator` issues exactly that many
  `tbamud__move` calls in order and returns a short (1-2 sentence) summary,
  not a numbered plan.
- A fixture test for `hops: nil` (no known route): `run_navigator` makes
  zero `tbamud__move` calls and its returned text says so.
- A fixture test for a move result that doesn't match the expected hop
  (e.g., a scripted "you can't go that way"): Navigator stops issuing
  further moves rather than continuing to guess.
- Isolation test: after a Player turn that calls `consult_navigator`, the
  Player's own `ctx.messages` contains exactly one `tool_call`/`tool_result`
  pair for it — no leaked Navigator-internal messages, same assertion shape
  `evaluator.md`'s isolation test uses for the Judge.
- With no `allow: [consult_navigator]` entry under `tasks.player.tools`,
  `consult_navigator` does not appear in the Player's tool list — a direct
  regression test the same way Phase 1's `effective_system` acceptance
  criterion checks a byte-identical payload when a feature isn't opted into.
- A before/after run (same harness style as `v2_plan.md` item 1, but scoped
  to this component, not that item's full write-up) on a quest specifically
  chosen for its pathfinding difficulty — e.g. the `dina` session's actual
  goal, "reach The Beginning Of The Passage from The Temple Of Midgaard" —
  comparing turns/iterations to reach the destination with `consult_navigator`
  available vs. not. This is a spot-check to confirm the tool does what it
  claims before shipping it, not the cross-session validation write-up
  `v2_plan.md` item 1 covers (still explicitly out of scope here).

## Deferred / out of scope here

- **How the Player is told to use it** (prompt tuning in
  `prompts/player/system.md` — "if you're repeating the same room/action,
  try `consult_navigator`") — worth doing once the tool exists and is
  observed in real sessions, not fixed in advance here.
- **Judge-triggered invocation** (`v2_plan.md` item 2's alternative (b): a
  `replan` verdict that routes through Navigator instead of Planner for one
  step) — this doc builds only alternative (a), agent-as-tool, per
  `v2_plan.md`'s own recommendation ("cheaper to build, doesn't require
  Judge to be right about *why* the Player is stuck"). Revisit only if (a)
  proves insufficient.
- **`v2_plan.md` item 1** (validation write-up) — explicitly out of scope
  per this doc's header; left for manual, later observation.
- **`v2_plan.md` items 3 and 4** (room-surveyor/persona, player-initiated
  early replan) — unrelated components, sequenced independently; not
  re-litigated here.
- **Fixing the Planner's own tool-avoidance behavior** (§0) — a
  `prompts/planner/system.md` prompt-engineering fix, not a Navigator
  concern; tracked separately.
