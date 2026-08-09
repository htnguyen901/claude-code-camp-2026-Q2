## Goal

`run_judge`/`run_planner` (`lib/boukensha.rb`) currently get their tools by
copying whatever `Tool` objects already exist on the *Player's* live
`Context` (`reuse_registered_tools`, née `reuse_inspector_tools`). That
means a task's effective tool set is bounded by `intersection(tasks.<name>.
tools, tasks.player.tools)`, not just `tasks.<name>.tools` — the Judge or
Planner can never reach a tool the Player's own policy didn't already
register, no matter what their own `settings.yaml` grants them. Concretely:
`role: inspector` includes `world__room_knowledge`/`world__route_to`
(`.boukensha/settings.yaml`), but `tasks.player.tools` is `role: gameplay`
(`tbamud__*` only) — so today, neither the Judge nor the Planner can
actually dispatch `world__room_knowledge`, even though their own config
says they can.

There is no legitimate hierarchy here — Player, Judge, Planner (and
whatever `Tasks::Navigator`/inspector/room-surveyor role comes next, per
`docs/journal/3_capable.md`'s roster) are siblings, each configured
independently under `tasks.<name>.tools`. None of them should have to ask
another task's registry for permission. This plan fixes the architecture so
that's actually true, while preserving the one real constraint that made
the current hack exist in the first place: the `mud` MCP server is
stateful (a login tied to a character), so two independent connections to
it within one session would mean two logins, not one — probably breaking
gameplay or fighting over the same character. Any fix has to keep that at
exactly one connection per server per session, just without making tool
*permission* ride along on tool *connection sharing*.

---

## Current state (grounded in the actual code path)

Two things are conflated today that shouldn't be:

1. **Connecting** to an MCP server — spawning the subprocess, doing the
   `initialize` handshake, logging in if the server requires it
   (`Boukensha::Mcp::Client.spawn`, `lib/boukensha/mcp/client.rb:24-34`).
   Expensive-ish and, for `mud`, stateful: a second `mud-manager --mcp`
   spawn with the same `MUD_NAME` is a second login.
2. **Registering** a subset of that connection's tools onto one task's
   `Registry`, filtered by that task's `ToolPolicy`
   (`Tools::Mcp.register_client`, `lib/boukensha/tools/mcp.rb:39-65`, which
   calls `Registry#tool` — `lib/boukensha/registry.rb:22-33` — the one
   choke point `docs/plans/tools_policy/permission.md` already identified
   as where policy belongs). Cheap, and inherently per-task: two tasks with
   different policies need two independent filter passes over the same
   underlying catalog.

`Tools::Mcp.register` (`tools/mcp.rb:30-36`) already exists as *both*
steps glued together: `client = Boukensha::Mcp::Client.spawn(...)` then
`register_client(registry, client, prefix:)`. Every real call site uses
this combined form exactly once, always against the Player's own registry:

- `Boukensha.run` (`boukensha.rb:100`), `Boukensha.repl` (`boukensha.rb:191`),
  `Session.play` (`session.rb:89`) each call `Boukensha.register_mcp_servers
  (registry, cfg, servers:)` (`boukensha.rb:476-486`), which walks every
  `mcp_servers:` entry and calls `Tools::Mcp.register` once per entry,
  **always onto the one `registry` that call built for `Tasks::Player`**.
  The return value is just a `{name => tool_count}` summary
  (`boukensha.rb:481`, used for `Repl`'s banner) — the actual `client`
  objects aren't retained anywhere the caller can reach again. They stay
  alive only because each registered `Tool`'s dispatch block closes over
  `client` (`tools/mcp.rb:56-62`) — so the *only* way anything gets at a
  live connection a second time is by holding one of the `Tool` wrapper
  objects a registry already built from it.
- `run_judge`/`run_planner` (`boukensha.rb`) don't call
  `register_mcp_servers` at all. Instead they take a `player_context:`,
  build their own throwaway `Context`/`Registry` with their *own*
  `tool_policy`, and — this is the hack — call `reuse_registered_tools`
  (`boukensha.rb`, formerly `reuse_inspector_tools`), which loops
  `player_context.tools.each_value` and re-registers each already-built
  `Tool` wrapper onto the new registry. That re-registration does go
  through `Registry#tool` again, so it correctly re-applies the Judge's/
  Planner's *own* policy on top — a tool Player has that Judge doesn't want
  is correctly re-denied. What it can't do is *grant* a tool Player's
  registry never had in the first place, because by the time
  `reuse_registered_tools` runs, that tool's `Tool` wrapper was never built
  at all (`Registry#tool` returns `nil` and discards the block for
  anything Player's own policy denies — `registry.rb:25-28`). The
  underlying MCP catalog (`client.tools`, still sitting on the live
  connection) is richer than what got exposed this way; nothing before
  today's design ever asks it again.

So "reuse the Player's connection" and "reuse the Player's *permissions*"
happen to be the same line of code today, and that's the bug. The fix is
to make step 1 (connect once, per server, per session) genuinely shared
and step 2 (register, filtered by policy) genuinely per-task — which,
notably, `tools/mcp.rb` already has the primitives for
(`Client.spawn` / `register_client` are already two separate methods);
nothing that low-level needs to change.

---

## Design options

**Option A — leave it, just widen `tasks.player.tools` to a superset.**
Make `role: gameplay` include `world__*` too, so Player's registry has
everything any other task might need to borrow.
_Cons:_ doesn't fix the architecture, just papers over today's specific
symptom — the Player would now carry read-only world-knowledge tools it
never calls, purely so something else can scavenge them later, and the
next task with a need Player doesn't share (a hypothetical write-capable
tool nothing else should get) reintroduces the exact same bug. Rejected —
this is the "father and son" shape the user explicitly asked to remove,
just with a bigger father.

**Option B — every task connects to MCP servers independently.**
`run_judge`/`run_planner` (and any future task) each call
`register_mcp_servers` themselves, spawning their own `Client` per server.
_Pros:_ trivially decouples permission from connection — genuinely no
hierarchy, every task is symmetric.
_Cons:_ breaks the one real constraint above — `mud-manager --mcp` spawned
a second time with the same `MUD_NAME`/`MUD_PASSWORD` is a second login to
the same character, which is either rejected by the MUD or silently boots
the first session. This is exactly the failure mode `reuse_registered_tools`
existed to avoid; Option B throws that away instead of fixing it.

**Option C (recommended) — connect once per session, register per task.**
Split what `register_mcp_servers`/`Tools::Mcp.register` already conflate
into two explicit phases, and make the *connect* phase's result — the live
`client` objects, not a tool-count summary — a first-class, reusable
value:

```ruby
# Phase 1: once per session, independent of any task/policy.
connections = Boukensha::McpConnections.connect(cfg, servers: mcp_servers)

# Phase 2: once per task, filtered by that task's own policy.
registry = Registry.new(ctx, policy: task_class.tool_policy(task_settings, tool_roles: cfg.tool_roles))
connections.register(registry)
```

`McpConnections#register(registry)` is just today's `Tools::Mcp.
register_client(registry, client, prefix:)` called once per already-spawned
client — no new spawn, no new handshake, no new login, and (because
`client.tools` is the *full* remote catalog, fetched once at handshake time
and cached — `mcp/client.rb:33`, `attr_reader :tools`) every task sees the
same complete catalog and applies its own `ToolPolicy` to it independently.
Calling `#register` twice (once for Player, once for Judge) is cheap and
side-effect-free on the connection itself; it just runs `Registry#tool`
twice against two different `Registry`/`ToolPolicy` pairs.
_Pros:_ genuinely no hierarchy — every task, including Player, becomes "a
registry filtered from the shared connections," symmetric with the others,
not a special case others borrow from. Preserves the one-login-per-server
guarantee by construction (connect happens exactly once, wherever the
session sets up `McpConnections`). Small, mechanical change — the pieces
(`Client.spawn`, `register_client`) already exist; this is re-plumbing
call sites, not new protocol work.
_Cons:_ every real entry point (`Boukensha.run`, `Boukensha.repl`,
`Session.play`, `Repl`) needs to build `McpConnections` once and thread it
into every `run_judge`/`run_planner` call instead of passing
`player_context:` — see "Call sites" below. `close`/`at_exit` lifecycle
moves from "one `at_exit` per `Client.spawn` call" to "one `close` for the
whole `McpConnections`," which needs to happen once per session, not
per-task.

### Recommendation

**C.** It's the only option that removes the hierarchy (per the actual
ask) without regressing the one genuine constraint (`mud`'s stateful
login) that Option B ignores and Option A just relocates.

---

## Concrete design

### `Boukensha::McpConnections` (new, `lib/boukensha/mcp_connections.rb`)

```ruby
module Boukensha
  class McpConnections
    def self.connect(cfg, servers: nil)
      new((servers || cfg.mcp_servers))
    end

    def initialize(server_entries)
      @entries = {}
      server_entries.each do |name, entry|
        client = Tools::Mcp.connect(command: entry[:command], args: entry[:args], env: entry[:env])
        @entries[name] = { client: client, prefix: entry[:prefix] }
      rescue StandardError => e
        raise "boukensha: MCP server '#{name}' failed to start: #{e.message}" if entry[:required]
        warn "[boukensha] optional MCP server '#{name}' failed to start: #{e.message} — continuing without its tools"
      end
    end

    # Registers every connected server's tools onto `registry`, filtered by
    # whatever policy `registry` was built with. Safe to call more than
    # once (once per task) against the same connections — no new spawn, no
    # new handshake, no new login; each call is just a fresh pass of
    # Registry#tool (and therefore that task's own ToolPolicy) over the
    # already-fetched catalog.
    def register(registry)
      @entries.each_value { |e| Tools::Mcp.register_client(registry, e[:client], prefix: e[:prefix]) }
    end

    # {name => tool_count} — replaces register_mcp_servers's old return
    # value for Repl's servers_status_string banner.
    def summary
      @entries.transform_values { |e| e[:client].tools.size }
    end

    def close
      @entries.each_value { |e| e[:client].close rescue nil }
    end
  end
end
```

`Tools::Mcp.register` (the combined spawn+register convenience method) can
either stay as a thin wrapper (`connect` a single entry, then
`register_client` — useful for the handful of ad hoc/test call sites that
really do only ever need one registry) or be deprecated in favor of always
going through `McpConnections` even for the one-registry case, so there's
only one code path to reason about. Lean toward the latter — one path,
used everywhere, per the user's actual complaint about inconsistent
hardcoded behavior.

`at_exit { client.close rescue nil }` moves from per-`Client.spawn` (today,
`tools/mcp.rb:33`) to a single `at_exit { connections.close }` registered
once by whichever call site builds the `McpConnections` — `Boukensha.run`/
`.repl`/`Session.play`.

### Call sites

- **`Boukensha.run`** (`boukensha.rb:67-146`): replace
  `register_mcp_servers(registry, cfg, servers: servers)` with
  `connections = McpConnections.connect(cfg, servers: servers)` +
  `connections.register(registry)`. Pass `mcp: connections` (not
  `player_context: ctx`) into the `run_planner` call.
- **`Boukensha.repl`** (`boukensha.rb:153-257`): same swap; also pass
  `connections` (or its `.summary`) into `Repl.new` in place of today's
  `servers:` summary hash, and `mcp: connections` for `Repl` to hand to its
  own `run_planner`/`run_judge` calls.
- **`Session.play`** (`session.rb:50-180`): same swap at construction;
  `mcp: connections` on both the seed-time and replan-time `run_planner`
  calls and on `run_judge`.
- **`Repl`** (`repl.rb`): store `@mcp = connections` at construction
  (alongside `@registry`, which is now just `Registry.new(ctx, policy:
  ...)` + `@mcp.register(@registry)`, done once by whichever caller
  constructs the `Repl`); `maybe_seed_plan`/`maybe_check_judge` pass
  `mcp: @mcp` instead of `player_context: @context`.
- **`run_judge`/`run_planner`** (`boukensha.rb`): replace `player_context:`
  with `mcp: nil`. Body becomes:

  ```ruby
  registry = Registry.new(ctx, policy: policy)
  mcp&.register(registry)
  ```

  `mcp: nil` (the default) means "no shared connections available — reason
  with zero tools," same fallback behavior `player_context: nil` had
  today, just renamed to describe what's actually optional (a connections
  handle, not another task's context). `reuse_registered_tools` /
  `reuse_inspector_tools` is deleted entirely — there is no more "reuse
  another task's already-filtered tools" step, because there's no longer
  a reason for one task's policy to have filtered anything before another
  task gets a look at the same catalog.

### Testing

`test_run_judge.rb`/`test_run_planner.rb`'s current `player_context_with_
tools` fixture (build a fake Player `Context`/`Registry`, register a fake
tool on it, hand the whole `Context` to `run_judge`/`run_planner`) is
itself a symptom of the hierarchy — it only makes sense if tools are
borrowed from a Player. Replace it with a fake `McpConnections`-shaped
double that responds to `#register(registry)` by registering canned fake
tools directly (no fake Player involved at all):

```ruby
class FakeMcpConnections
  def initialize(&block) = @block = block
  def register(registry) = @block&.call(registry)
end
```

so a test reads as "the Judge/Planner has these tools available, filtered
by its own configured policy" — no Player fixture standing in for
anything. `test_tools_mcp.rb`/`test_mcp_servers_config.rb` gain a
same-connection-twice test: register the same live (or fake) `client`
onto two independently-policied registries and assert each sees only what
its own policy allows, independent of the other's.

A dedicated integration test worth adding: spawn a real `mud-manager --mcp`
via `McpConnections`, register it onto two registries with different
policies (mirroring Player's `gameplay` and Judge's `inspector`), and
assert only one `mud-manager` subprocess/login happened (e.g. count
spawned PIDs, or that a fake MUD only sees one login) — the regression
this whole design exists to prevent.

---

## Staged implementation

1. `lib/boukensha/mcp_connections.rb`: new `McpConnections` class as
   sketched above. `Tools::Mcp.connect` (rename/extract from
   `Tools::Mcp.register`'s spawn half) so `McpConnections` doesn't
   duplicate `Client.spawn` call handling. Pure addition — nothing calls
   it yet, no behavior change.
2. Swap `Boukensha.run`/`.repl`/`Session.play` to build a `McpConnections`
   and call `#register` instead of `register_mcp_servers`. `Repl` stores
   `@mcp`. `register_mcp_servers` itself can be deleted once nothing calls
   it. No policy/behavior change yet — Player's own tool set is identical
   before and after, since it's still "connect once, register once,
   filtered by Player's policy," just re-plumbed.
3. `run_judge`/`run_planner`: replace `player_context:` with `mcp:`,
   delete `reuse_registered_tools`. Update the three real call sites
   (`Boukensha.run`, `Session.play`, `Repl`) to pass `mcp:` instead of
   `player_context:`. **This is the one step where behavior actually
   changes** — a Judge/Planner with `tools: { role: inspector }` (or any
   role including something outside `tasks.player.tools`) starts actually
   getting those tools. Land it as its own commit, separately reviewable
   from step 2's pure refactor.
4. Tests: `FakeMcpConnections` double replaces `player_context_with_tools`
   in `test_run_judge.rb`/`test_run_planner.rb`; add the "same connection,
   two policies, two independent results" test; add the "one login even
   though two tasks use the tool" integration test against a real/fake MUD.
5. `docs/plans/agent_loop/orchestrator.md`/`evaluator.md`: correct the
   "reuse the Player's already-connected Tool objects" language (both the
   original text and this week's 2026-08-07 corrections that documented
   the hack as the fix) to describe `McpConnections` instead. This
   supersedes the `reuse_registered_tools` correction landed alongside the
   `run_planner` tool-policy fix earlier the same day.

Steps 1-2 are pure re-plumbing with no observable behavior change
(verifiable: existing test suite passes unmodified after each). Step 3 is
the actual fix and should ship with the new tests from step 4 in the same
commit, not after.

---

## Acceptance criteria

- A `Client`, once spawned via `McpConnections`, is registered onto every
  task's registry that needs it without spawning or handshaking again —
  verifiable by asserting `client.tools` (the cached catalog) is read, not
  re-fetched, and (for `mud`) that only one login occurs per session
  regardless of how many of Player/Judge/Planner end up using tools from
  it.
- A task's effective tool set is determined **solely** by its own
  `tasks.<name>.tools` in `settings.yaml`, resolved against the *full*
  remote catalog each connected server advertises — never bounded by what
  any other task's policy happens to allow. Concretely: `tasks.judge.tools:
  { role: inspector }` (or `tasks.planner.tools:` the same) must actually
  let that task dispatch `world__room_knowledge`, independent of what
  `tasks.player.tools` grants.
- `reuse_registered_tools`/`reuse_inspector_tools` no longer exists
  anywhere in the codebase — there is no code path where one task's
  `Registry`/`Context` is read by another task's construction.
- Existing behavior for `Boukensha.run`/`.repl`/`Session.play`'s Player
  registry is unchanged (same tools, same policy, same one-connection
  guarantee) — the full existing test suite passes unmodified through
  steps 1-2.

## Not doing (out of scope for this pass)

- **Lazy/on-demand connection** (only spawn a server the first task that
  actually needs it asks for). `McpConnections.connect` stays eager, same
  as today's `register_mcp_servers` — every configured server is spawned
  up front regardless of whether any task's policy ends up using it. Worth
  revisiting only if server spawn cost becomes a measured problem; not
  today's ask.
- **Per-task MCP server scoping** (Option A from `permission.md`,
  `tasks.<name>.mcp_servers: [...]`) — orthogonal to this plan. Still a
  reasonable future complement (skip connecting a task to a server its
  policy would deny every tool from anyway), not a replacement for
  per-task tool filtering.
- **Changing anything about `ToolPolicy`/glob matching/`tool_roles:`
  itself** — this plan is entirely about *which catalog* a policy gets
  applied to, not how the policy itself is expressed or evaluated
  (`permission.md` already covers that ground).
