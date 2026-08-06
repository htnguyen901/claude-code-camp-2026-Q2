# Step 17 - Tool Permission and Policy

Branched from `16_visibility` (stays the source of truth for everything
carried forward unchanged: context/token management, the TUI, the
MCP-host tool model, multi-player support, MUD response compaction, and
OpenTelemetry traces/metrics — see that step's README). This step's addition
is a **per-task tool policy**: which of an MCP server's advertised tools a
given task's model is even allowed to see and call, declared in
`settings.yaml`, enforced at the one place every tool registration path
already funnels through. Full design/rationale (options considered, why this
one): `docs/plans/tools_policy/permission.md`.

## Install

```sh
cd week2_observability/ruby/17_tool_permission
bundle install
```

Prerequisites beyond the Ruby gems: same as `16_visibility` — a `mud-manager`
MCP server on `PATH`, `.boukensha/players/*.yaml` character profiles (see
`week2_observability/bin/seed_players`), and optionally a local Ollama
daemon for `log_viz`'s classification features.

## Build

```sh
gem build boukensha.gemspec
gem install boukensha-0.17.0.gem
```

Installs the `boukensha` executable. `~/.boukensharc`'s `boukensha_path`
must point at this step's directory for it to run this step's code — see
`lib/boukensha_loader.rb`'s header comment.

## What's new in this step

### The problem: every task got every tool, for free

Before this step, `Registry#tool` — the single choke point both `mcp_servers:`
discovery and the ad hoc `room_knowledge` registration already funnel
through — registered whatever it was handed, no questions asked. Fine with
one task (`Tasks::Player`). Not fine the moment a second task (a judge,
navigator, or room-surveyor agent — see `docs/journal/3_capable.md`) shares
the process: it would get `attack`/`quit`/`give` for free the instant it
called `Boukensha.run`/`.repl`, with no way to say "this agent should only
ever look and examine."

### `Boukensha::ToolPolicy` — a static allow/deny glob matcher

```ruby
policy = Boukensha::ToolPolicy.new(allow: ["tbamud__say_*"], deny: ["tbamud__say_quest"])
policy.allowed?("tbamud__say_local")  # => true
policy.allowed?("tbamud__say_quest")  # => false, deny always wins on overlap
```

Patterns are matched with `File.fnmatch?`, so `tbamud__say_*` covers every
`say_*` variant the daemon advertises in one line instead of five. A bare
`Boukensha::Registry.new(ctx)` (tests, `examples/mcp_mud_demo.rb --dry`, any
caller that isn't a config-driven task) still defaults to allow-everything —
nothing changes for code that doesn't opt into a policy.

### Enforcement lives in `Registry#tool`, not bolted on after

```ruby
Registry.new(context, policy: policy)
```

A denied tool is never built — its `Tool` struct is never constructed, its
schema never reaches `@context.tools`, and it's never sent to the model.
Both existing registration paths (MCP discovery in `Tools::Mcp`, and the ad
hoc `RunDSL#tool` `room_knowledge` uses) already route through
`Registry#tool`, so neither needed to change. Calling `registry.tool` for a
denied name just returns `nil` — a task legitimately shouldn't crash because
its policy is narrower than a server's full catalog.

If the model somehow still asks for a denied tool (a stale prompt/cache),
`Registry#dispatch` raises a new `Boukensha::PermissionDeniedError` — distinct
from `UnknownToolError` (a name nothing ever advertised), so "the model tried
something it wasn't allowed to have" is visibly different from "the model
hallucinated a tool name" in the transcript and in logs.

### Config: `tool_roles:` + `tasks.<name>.tools:`

```yaml
tool_roles:
  readonly: [tbamud__look, tbamud__examine, tbamud__info_self,
             tbamud__info_world, tbamud__consider, tbamud__diagnose,
             room_knowledge]
  full:     ["*"]

tasks:
  player:
    tools:
      role: full          # unrestricted — same behavior as before this step
  navigator:
    tools:
      role: readonly       # read-only — no attack/quit/give
  inspector:
    tools:
      role:  readonly
      allow: [tbamud__list_commands]   # + one ad hoc extra on top of the role
```

`role:` expands to that role's glob list from `tool_roles:` before `allow:`/
`deny:` are applied on top, so a new task can reuse an existing role and
still add or remove a handful of one-offs without inventing a brand-new role.
Resolved by `Tasks::Base.tool_policy(settings, tool_roles:)`, alongside the
existing `.provider`/`.model`/`.prompt_override?` readers.

### Deny-by-default

A task with **no** `tools:` block configured gets **zero tools** — least
privilege by construction, not "secure only if every future task remembers
to configure itself." This is why `.boukensha/settings.yaml`'s `tasks.player`
now carries an explicit `tools: { role: full }` — without it, `player` would
silently lose every tool the moment this step's code runs. `tool_roles.full:
["*"]` is what makes that grant a one-liner instead of enumerating ~59 names.

## Run

Offline smoke test, no live MUD needed (built-in fake MUD):

```sh
ruby examples/mcp_mud_demo.rb --dry
ruby examples/example.rb
```

A quick way to see the policy actually filtering a live daemon's full
catalog (used by `test_tools_mcp.rb`'s own coverage of this):

```ruby
policy = Boukensha::ToolPolicy.new(allow: %w[look examine])
ctx, registry = Boukensha::Context.new(system: "demo"), nil
registry = Boukensha::Registry.new(ctx, policy: policy)
Boukensha::Tools::Mcp.register(registry, command: "mud-manager", args: ["--mcp"], env: {...})
ctx.tools.keys # => ["examine", "look"] — not the other ~57 tools the daemon advertised
```

## Tests

```sh
rake test
```

New coverage for this step: `test_tool_policy.rb` (glob matching, deny beats
allow, symbol/string name handling), `test_registry.rb` (a denied tool is
never registered, `dispatch` raises `PermissionDeniedError` vs.
`UnknownToolError`), `test_tasks_base_tool_policy.rb` (role resolution,
role+allow composition, deny-by-default with no `tools:` block),
`test_tool_roles_config.rb` (`tool_roles:` parsing), and a new case in
`test_tools_mcp.rb` proving a restrictive policy filters the live daemon's
full tool catalog down to just what's allowed.

## Not doing (explicitly out of scope)

Carried over from the plan's own scope decisions — filing a bug for any of
these is filing it against a known, deliberate gap, not an oversight:

- **Interactive `ask` tier / mid-turn human confirmation** for a destructive
  call, the way Claude Code's own permission model works. Needs new
  plumbing (`Agent#handle_tool_calls` would need a callback out to
  `Repl`/`Tui` before dispatching a specific call) that doesn't exist yet.
  Revisit if static allow/deny turns out insufficient in practice.
- **Sandboxing the MCP server subprocesses themselves** (e.g. a filesystem
  server actually being unable to write outside `/tmp`). Orthogonal to which
  of a server's advertised tools a task is allowed to call.
- **Composable multi-role tasks** (`roles: [readonly, social]`). One role
  per task, plus ad hoc `allow:`/`deny:` overrides, is the v1 shape; multi-role
  composition is a natural v2 if roles start overlapping in ways ad hoc
  overrides make awkward.
- **Wiring `Tasks::Base.max_iterations`/`.max_output_tokens` into
  `boukensha.rb`.** Same family of "per-task, not global" idea, unrelated
  change, still dead code as of this step.
- **Fixing the `filesystem:` indentation bug** in `.boukensha/settings.yaml`
  (it's nested inside `mud:` instead of being its own top-level
  `mcp_servers:` entry, so it's silently never registered). Flagged by the
  plan as a one-line fix worth doing, deliberately not bundled into this
  step.
