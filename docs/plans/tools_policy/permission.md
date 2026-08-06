## Goal

I need to implement tool and policy permissions as the list of tasks are growing and I expect to later add more agent to the loop as well.
Right now I can't hard tell which tools as well as permissions each task (in settings.yaml) posesses. Each of them do not need to have all tools and permission inthe MUD. Based on their role and purpose, they'll on be assigned the set/list of tools/permissions that they need

I need help evaluating and explain my options and why I should go for what

---

## Plan: per-task tool/permission policy

### Current state (grounded in the actual code path)

Today there is exactly one agentic task, `Tasks::Player`
(`lib/boukensha/tasks/player.rb`), and `Boukensha.run`/`.repl`
(`lib/boukensha.rb:65-218`) hard-code `task_class = Tasks::Player` — there is
no second call site to compare against yet. Every tool that task can see
comes from two registration paths, and **both already funnel through one
choke point**:

1. `register_mcp_servers` (`boukensha.rb:234-247`) walks *every* entry in
   `mcp_servers:` unconditionally and calls `Tools::Mcp.register(registry,
   ...)` for each, which calls `registry.tool(...)` once per tool the
   server advertises (`tools/mcp.rb:56-63`).
2. `boukensha_loader.rb:133-149` registers one more ad hoc tool,
   `room_knowledge`, via the same `RunDSL#tool` → `Registry#tool`
   (`run_dsl.rb:9-11`, `registry.rb:9-13`) call.

`Registry#tool` (`registry.rb:9-13`) is the *only* place a `Tool` struct
gets created and handed to `Context#register_tool`. Nothing between "an MCP
server advertised this tool" and "the model's next request lists it in its
schema" asks whether the current task is allowed to have it — every tool
that exists is registered, and every registered tool is sent to the model
and dispatchable by `Registry#dispatch` (`registry.rb:19-23`). That's fine
with one task. It stops being fine the moment a second task shares the
process, because there is currently no notion of "this task's tools" at
all — only "the process's tools."

The actual tool surface this matters for is large: `mud-manager`'s
`ToolCatalog` (`mud_manager` gem, reflected from `Primitives`) turns ~57
methods into tools automatically, spanning read-only info (`look`,
`examine`, `info_self`, `info_world`, `consider`, `diagnose`,
`list_commands`), movement, combat (`attack`, `skill_strike`, `flee`,
`track`, `steal`), economy (`shop`, `bank`, `mail`, `split_gold`, `give`),
and account-level actions (`quit`, `save_char`, `rent`, `house_admin`).
`room_knowledge` adds a 58th, read-only, tool. A `judge` or `navigator`
agent (see the "Notes" in `docs/journal/3_capable.md` — the orchestrator
roster you're planning: judge, player, inspector, navigator, room surveyor)
has no legitimate reason to ever call `attack` or `quit`, but under today's
code it would get them for free the instant it called `Boukensha.run`/
`.repl` the same way `Tasks::Player` does.

This isn't a new realization — `docs/plans/observability/
room_world_inspector.md`'s follow-up section (lines 353-395) already
anticipated it. Moving `ContentFact`'s config into `tasks.content_fact:`
was explicitly done *"so we can set provider, model, or even scope of
permissions or tools allowed for this task,"* and that doc says plainly:
*"the settings block is nested under `tasks.<name>`, the same family as
`tasks.player`, specifically so a future task that does need a tool/
permission allowlist has an obvious, consistent place to add one — not
designed in speculatively here."* This plan is that follow-through.

One more piece of prior art worth knowing about before designing further:
`Tasks::Base` (`lib/boukensha/tasks/base.rb`) already defines
`.max_iterations(settings)` / `.max_output_tokens(settings)` as *per-task*
settings readers, but nothing calls them — `boukensha.rb` sources those two
limits from `cfg.agent_max_iterations` / `cfg.agent_max_output_tokens`
instead, a single **global** `agent:` block (`config.rb:84-97`). So
`Tasks::Base` already models "per-task settings that aren't wired up yet"
once (iteration/token limits); this plan adds a second (tools), in the same
place, using the same pattern (`.provider` / `.model` /
`.prompt_override?`).

**Aside, found while reading `settings.yaml`, not part of this plan:**
`filesystem:` (`.boukensha/settings.yaml:95-99`) is indented four spaces —
nested *inside* `mud:`'s hash, as a sibling of `env:`, not as its own
top-level `mcp_servers:` entry (which needs two-space indent like `mud:`
does). `Config#mcp_servers` only walks top-level keys
(`config.rb:64-78`), so today `filesystem` is silently never registered —
it's dead YAML, not a live server. Worth a one-line fix independent of this
plan; flagging it here because a tool-policy system is exactly the kind of
thing that should make a mistake like this loud (a server nobody
configured a policy for) rather than silent.

### What "permissions" means here, concretely

Two related but separable questions:

- **Tools** — which of the ~58 available tool names can this task's model
  even see and call this turn? (allowlist/denylist over tool names)
- **Policy** beyond tool identity — e.g. should a destructive call
  (`attack`, `give`, `quit`) ever require a human to confirm it, the way
  Claude Code's own `ask` permission tier works? This only makes sense
  where a human is actually in the loop. `Repl` (`repl.rb`) *is*
  interactive — a person sits at `boukensha>` between turns — but within a
  turn, `Agent#handle_tool_calls` (`agent.rb:174-231`) dispatches tool
  calls autonomously in a loop; there's no existing hook for "pause and ask
  a human before this specific call." Building one is a real, separate
  feature (see Open Questions). This plan's scope is the first
  question — static, config-declared tool scoping — and treats the second
  as a documented extension point, not something to build speculatively.

### Prior art worth knowing (brief — you asked for the "why")

- **RBAC (role-based access control).** Define named roles once
  (`readonly`, `combat`, ...), assign each principal (here: each task) one
  or more roles. Its whole value is *de-duplication* once you have more
  than a couple of principals with overlapping needs — exactly your
  situation once judge/inspector/navigator/room-surveyor all plausibly want
  the same "can look and examine, can't fight or spend gold" set.
- **Capability-based security / principle of least authority.** Instead of
  "can this principal do X" being answered by checking a name against a
  policy at call time, the principal is *structurally* never given a
  reference to the ability to do X at all — there's no gate to bypass
  because there's nothing to bypass it with. Applied here: a task that
  never received the `attack` tool object can't call `attack`, independent
  of whether some policy-check function got skipped somewhere. This is a
  stronger guarantee than a runtime allow/deny check, and — this is the
  useful bit — it's nearly free in this codebase, because `Registry#tool`
  is already the one choke point everything passes through (see above).
- **Claude Code's own permission model** (`allow` / `ask` / `deny`, glob
  patterns like `Bash(git diff:*)`, `mcp__server__*`) — the model you
  already have hands-on intuition for. Two ideas worth borrowing: (1) glob
  patterns over tool names rather than exact-match lists, so
  `tbamud__say_*` covers `say_local`/`say_targeted`/`say_channel`/
  `say_group`/`say_quest` in one line; (2) a three-state model
  (allow/ask/deny), which maps onto this project's "ask" idea above but —
  per the previous section — needs a mid-turn human hook that doesn't
  exist yet, so it's not a v1 requirement.
- **MCP server-level scoping.** The coarsest possible tool boundary: don't
  connect a task to a server at all. You're already halfway using this
  idiom (`prefix:` per server, `required:` per server) — it's a real
  option, just too coarse on its own (see Option A below).

### Design options

**Option A — server-level allowlist per task.**
`tasks.<name>.mcp_servers: [mud]` — a task only gets whichever whole
`mcp_servers:` entries are named; unlisted servers aren't connected for it
at all.
_Pros:_ trivial (filter the servers hash before calling
`register_mcp_servers`, one `Hash#slice`); reuses a boundary that already
exists (`prefix:`).
_Cons:_ too coarse for the actual risk shape here — `mud` alone contains
both `look` and `attack`. Can't give a navigator "read-only MUD access"
without also solving the fine-grained problem. Useful only as a
*complement* (e.g. "inspector never even connects to a hypothetical
write-capable filesystem server"), not as the primary mechanism.

**Option B — per-task tool-name allow/deny list, with glob patterns.**
`tasks.<name>.tools: { allow: [...], deny: [...] }`, matched against each
tool's already-prefixed local name (`tbamud__look`, `room_knowledge`, ...)
at registration time. `deny` wins over `allow` on overlap (explicit refusal
should never be shadowed by a broader allow glob).
_Pros:_ fine-grained enough to express the real distinctions that matter
(`tbamud__look`, `tbamud__examine`, `tbamud__info_world`, `room_knowledge`
for a read-only agent; not `tbamud__attack`/`tbamud__quit`/`tbamud__give`).
Filtering at *registration* time (skip ever building the `Tool`, rather
than building it and hiding it later) means a denied tool's schema is
never sent to the model at all — direct synergy with the token-budget
concern already raised in `docs/plans/observability/
tool_token_optimization.md` (57 tools × full JSON schema, sent every
call): a scoped task pays schema-token cost only for tools it can actually
use.
_Cons:_ every task's `settings.yaml` block ends up repeating similar glob
lists once you have 4-5 agents with overlapping "mostly read-only" needs —
solved by Option C, not a reason to avoid B.

**Option C — reusable named roles on top of B.**
A new top-level `tool_roles:` block defines named, reusable glob sets once:

```yaml
tool_roles:
  readonly: [tbamud__look, tbamud__examine, tbamud__info_self,
             tbamud__info_world, tbamud__consider, tbamud__diagnose,
             room_knowledge]
  full:     ["*"]

tasks:
  player:
    tools: { role: full }
  navigator:
    tools: { role: readonly }
  inspector:
    tools: { role: readonly, allow: [tbamud__list_commands] }  # + one extra
```

`role:` expands to that role's allow-list before `allow`/`deny` are
applied, so a task can take a role and still add/remove a handful of
one-offs rather than needing a brand-new role per task. This is RBAC
layered on Option B's matcher — not a separate enforcement mechanism, a
config-ergonomics layer that stops the roster in
`docs/journal/3_capable.md` from meaning 5 near-duplicate glob lists.
_Cons:_ one more concept to hold in your head; not worth it if you only
ever have 2 tasks. You're planning 5+, so worth it here.

**Option D — structural enforcement: policy lives on the `Registry`, not
bolted on after.**
Give `Registry.new` an optional `policy:` (a small object/lambda answering
`allowed?(tool_name)`), checked once, inside `Registry#tool`
(`registry.rb:9-13`), before `@context.register_tool(tool)` is ever
called. Both existing registration call sites (`Tools::Mcp.register_client`
and the `RunDSL#tool` used by `room_knowledge`) already route through
`Registry#tool`, so **this needs no change to either of them** — the one
choke point identified above is already exactly where policy belongs. A
denied tool is simply never added to `@context.tools`; it never reaches
the model's schema, never appears in `tool_names`, and — as a second,
cheap layer of defense — `Registry#dispatch` (`registry.rb:19-23`) can
additionally raise a new `PermissionDeniedError` (parallel to the existing
`UnknownToolError`) if it's ever asked to run a name that isn't in
`@context.tools`, which is already its behavior today; the only change is
being able to distinguish "never existed" from "existed, was denied" in
logs if that distinction turns out to matter.
_Pros:_ nearly free given the existing architecture; gives the *strong*
capability-based guarantee (a denied tool's `Tool` object is never built,
not just hidden), not just a runtime check that some future code path
could accidentally skip.
_Cons:_ requires each task to get its **own** `Context`/`Registry` pair
rather than sharing the one built in `Boukensha.run`/`.repl` today. This
sounds like new complexity but isn't optional scope creep — it's a
prerequisite the orchestrator needs anyway: once `judge`/`player`/
`inspector`/`navigator` are separate `Agent` instances running in one
process, they each need their own conversation history and token
accounting too, not just their own tools. Today's code already builds a
fresh `Context`/`Registry` per `Boukensha.run`/`.repl` call
(`boukensha.rb:88-89`, `160-161`) — it just only ever gets called once per
process. Nothing here changes that shape; it just means each agent's
future construction call passes its own `task_settings`-derived policy in.

### Recommendation

**C (named roles) for config ergonomics, expressed as B (glob allow/deny)
matching, enforced structurally per D (checked once, inside
`Registry#tool`, so a denied tool is never built) — plus A only as a minor
complement where a whole server is irrelevant to a task, not as the
primary mechanism.**

Reasoning, tied back to what you actually asked for:

- You said tasks shouldn't have to carry "all tools and permissions" and
  should get only what "their role and purpose" needs — that's RBAC's
  entire pitch (Option C), and your orchestrator roster
  (`docs/journal/3_capable.md`) already reads like a role list waiting to
  be named: `readonly` (navigator, room surveyor, judge?), `full` (player),
  maybe `social` later.
- Glob matching (Option B) is the mechanism that makes roles cheap to
  write — `tbamud__say_*` instead of five lines — and it's a model you
  already have muscle memory for from Claude Code's own settings.
- Enforcing at `Registry#tool` (Option D) rather than, say, filtering the
  MCP client's tool list before calling `Tools::Mcp.register` is the
  cheaper *and* stronger choice: cheaper because it's one integration
  point instead of two (both the MCP path and the ad hoc `RunDSL` path
  already funnel through it), stronger because it denies at the point of
  creation rather than trusting every future caller to filter before it
  gets there.
- This directly reuses the extension point `room_world_inspector.md`
  already reserved (`tasks.<name>.*`, same family as `.provider`/`.model`)
  instead of inventing a new config surface next to it.

### Default / fail-safe: deny-by-default for new tasks, explicit allow for `player`

This is the one real judgment call in this design, worth stating
explicitly rather than leaving implicit: when a task has no `tools:` block
at all, should it get every tool (today's de facto behavior, since nothing
filters yet) or none?

**Recommended: deny-by-default.** A task with no `tools:`/`role:`
configured gets zero tools — matching "least privilege by construction"
rather than "secure only if every future task remembers to configure
itself." The cost is that `Tasks::Player` — the one task that currently
does need everything — needs an explicit grant the same day this ships:

```yaml
tasks:
  player:
    tools: { role: full }   # unchanged behavior, now explicit instead of implicit
```

so nothing regresses silently. The alternative (allow-by-default,
opt-in-to-restrict) is safer for backward compatibility but defeats the
actual goal here — a new task that forgets to add a `tools:` block would
silently inherit `attack`/`quit`/`give`, which is precisely the failure
mode this plan exists to prevent.

### Staged implementation

Mirrors this repo's existing plan → numbered-step convention (this plan
would land as a new `week2_observability/ruby/17_tools_policy/`, copied
forward from `16_visibility/` the same way `13_room_inspector` etc. were):

1. `Config#tool_roles` (reads top-level `tool_roles:`, expands to
   `{ role_name => [glob, ...] }`) and `Tasks::Base.tool_policy(settings)`
   alongside the existing `.provider`/`.model`/`.prompt_override?`
   (`tasks/base.rb`), reading `tasks.<name>.tools` and resolving any
   `role:` against `Config#tool_roles`.
2. A small `ToolPolicy` object: `allowed?(name) -> bool`, built from the
   resolved `{ allow:, deny: }` glob lists (`File.fnmatch`-style matching
   is enough — no need for a regex engine).
3. `Registry.new(context, policy: ToolPolicy.new(allow: ["*"]))` (default
   arg preserves today's tests/behavior for anything that constructs a
   bare `Registry` directly); `Registry#tool` checks
   `policy.allowed?(name)` before delegating to `@context.register_tool`,
   silently skipping (or logging at debug level) a denied tool rather than
   raising — a task legitimately shouldn't crash just because its policy
   is narrower than a server's full catalog.
4. `Registry#dispatch` gains the `PermissionDeniedError` distinction
   (optional, but cheap defense-in-depth).
5. `Boukensha.run`/`.repl` build each task's `Registry` with
   `Tasks::Player.tool_policy(task_settings)` (today: still the only
   caller, so this is a no-behavior-change refactor once step 5's
   `settings.yaml` grant lands).
6. `settings.yaml`: add `tool_roles:` and `tasks.player.tools: { role:
   full }`.
7. Tests alongside the existing `test_mcp_servers_config.rb` /
   `test_tools_mcp.rb` — glob matching edge cases, deny-overrides-allow,
   deny-by-default with no `tools:` block, `role:` + `allow:` composition.

Steps 1-4 are pure additions with no observable behavior change by
themselves (nothing calls `tool_policy` yet). Step 5+6 together are the
one commit where behavior can regress if done separately — land them
together.

### Not doing (out of scope for this pass)

- **Interactive `ask` tier / mid-turn human confirmation** for a
  destructive call. Real idea (see "What permissions means here" above),
  but it needs new plumbing — `Agent#handle_tool_calls` would need a
  callback back out to `Repl`/`Tui` before dispatching a specific call,
  and there's no such hook today. Revisit once static allow/deny (this
  plan) turns out insufficient in practice, not before.
- **Sandboxing/resource limits on the MCP server subprocesses themselves**
  (e.g. the filesystem server actually being unable to write outside
  `/tmp`, independent of which tools boukensha chose to register). That's
  a property of how each server is spawned/configured, orthogonal to which
  of its advertised tools a given task is allowed to call.
- **Wiring `Tasks::Base.max_iterations`/`.max_output_tokens` into
  `boukensha.rb`** (they're currently dead code — see "Current state"
  above). Same family of "per-task, not global" idea, but a separate
  change with its own review; noted here only as evidence the pattern
  this plan uses is already half-adopted elsewhere.
- **Fixing the `filesystem:` indentation bug** in `.boukensha/
  settings.yaml`. Flagged above; a one-line fix, not part of this design.

### Open questions

- Do you want tool-name globs (`tbamud__say_*`) or would exact-name lists
  be clearer to hand-maintain given ~58 tools is not that many? Globs earn
  their complexity mainly if the mud_manager catalog keeps growing.
  Recommendation: **globs**, since `ToolCatalog` auto-reflects new
  `Primitives` methods (see `tool_catalog.rb:1-8`) — the tool surface
  grows without a matching settings.yaml update prompting you to think
  about it, so name-prefix globs (`tbamud__say_*`) age better than an
  exact list someone has to remember to extend.
  A: Yes please go globs
- Should a denied tool call from the model (if it somehow still asks for
  one — e.g. a stale prompt/cache) fail loudly (`PermissionDeniedError`
  surfaced to the transcript, letting the model self-correct next
  iteration) or silently (treated as `UnknownToolError`, current
  behavior)? Recommendation: loud but distinct — same visible failure
  mode as today (an error string comes back as the tool result, per
  `agent.rb:196-205`), just log/trace it distinguishably
  (`boukensha.tool.denied` span attribute alongside the existing
  `boukensha.tool.ok`) so a denial shows up differently from a genuine
  bug in observability, without changing what the model sees mid-turn.
  A: Agree with recommendation
- One `tool_roles:` role per task, or composable multiple roles
  (`roles: [readonly, social]`)? The example above sketches single-role +
  ad hoc `allow:`/`deny:` overrides as the simpler v1; multi-role
  composition is a natural v2 if roles start overlapping in ways ad hoc
  overrides make awkward.
  A: for now can do one role per task