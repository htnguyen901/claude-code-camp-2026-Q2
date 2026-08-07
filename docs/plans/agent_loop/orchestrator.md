# Orchestrator — Planner + session glue

Splits out of [`high_level_agentic_loop_design.md`](high_level_agentic_loop_design.md)'s
Recommendation section. Covers the pieces owned by the "decide what the plan
is" role: `Tasks::Planner`, where its output lives, and the glue that ties
Planner → Player → Judge into one session. The Player's own changes are in
[`worker.md`](worker.md); the Judge is in [`evaluator.md`](evaluator.md).

**Depends on:** nothing (this is the first piece — Planner can be built and
tested with a hardcoded/no-op Judge).
**Blocks:** the "replan" branch of [`evaluator.md`](evaluator.md) (Judge needs
somewhere to hand a replan verdict to), and the session driver both other
docs' checkpoint/plan-visibility hooks assume exists.

## Open question to resolve before starting (flag for discussion, not a decision made here)

`bin/play_players` today spawns `boukensha --player NAME --no-tui` with the
goal piped in as **one line of stdin** — `Repl#start` reads it, calls
`run_turn` exactly once, then hits EOF and exits. So a real autonomous play
session is currently **one `Agent#run` call**, and everything the Player does
happens inside that one call's `@iteration` loop
(`lib/boukensha/agent.rb:50-88`), bounded by `max_iterations`/`max_turn_tokens`.

That means "Judge checks in every N turns" (high-level doc, Cadence trigger)
can't mean `Repl#run_turn` turns for this project's actual usage pattern —
there's only ever one. The Planner→Player→Judge loop this design wants
requires *multiple* `Agent#run` calls per goal, with the driver deciding what
instruction to feed the next one (the model's own wrap-up "next action" text?
a literal "continue"?) after each Judge checkpoint. That's a new driver, not
a wrapper around `Repl` or `Boukensha.run` as they exist today — see
"The session driver" below for the concrete proposal. **Confirm this reading
of `bin/play_players` before building the driver** — if there's a different
intended entry point for orchestrated play, the driver's shape changes.

## 1. Shared prerequisite: task-scoped default prompts

Both Planner and Judge are new `Tasks::*` classes reading a `system.md`.
`Tasks::Base.prompt` (`lib/boukensha/tasks/base.rb:28-34`) resolves the
*default* prompt via `read_default_prompt`, which does
`File.join(default_prompts_dir, "#{prompt_name}.md")` — **not** scoped by
`task_name`, unlike `read_user_prompt` (line 89-93) which is. Today this is
invisible because there's exactly one task (`player`) and one file
(`prompts/system.md`). The moment `Tasks::Planner.system_prompt(...)` and
`Tasks::Judge.system_prompt(...)` are called with the same
`default_prompts_dir: Config::PROMPTS_DIR` the `.run`/`.repl` call sites pass
today (`lib/boukensha.rb:82`, `:155`), they'd all resolve to the identical
`prompts/system.md` — the Player's prompt, not their own.

Fix (small, additive): move `prompts/system.md` → `prompts/player/system.md`,
add `prompts/planner/system.md` and `prompts/judge/system.md`, and change
`read_default_prompt` to mirror `read_user_prompt`'s shape:
`File.join(default_prompts_dir, task_name, "#{prompt_name}.md")`. Update the
two existing call sites in `lib/boukensha.rb` — no behavior change for
`Tasks::Player` since it's the only caller today, just a path move.

## 2. Where the plan lives: `Context#plan`

Add a mutable field to `Context` (`lib/boukensha/context.rb`), same
category as `working_dir`/`system` (the agent's notion of current state) but
mutable, since `system` is fixed at construction (`attr_reader :system`,
no writer):

```ruby
attr_accessor :plan   # nil, or the Planner's latest plan text

def effective_system
  return system if plan.nil? || plan.strip.empty?
  "#{system}\n\n## Current Plan\n#{plan}"
end
```

`effective_system` — not `system` directly — is what must reach the model,
because every backend's `to_payload` reads `context.system` directly and
independently:

- `backends/anthropic.rb:81` — `system: context.system`
- `backends/openai.rb:73` — `instructions: context.system`
- `backends/gemini.rb:89` — `systemInstruction: { parts: [{ text: context.system }] }`
- `backends/ollama.rb:97` / `backends/ollama_cloud.rb:~68` — `to_messages(context.system, context.messages)`

Four call sites, one line each: `context.system` → `context.effective_system`.
This is the only change needed for the Player to see "current plan: …" on
every iteration without a pinned message `compact_messages!` could drop —
matches the high-level doc's rationale exactly.

**Naming collision to avoid:** `Logger` already has a `#plan(text:)` method
(`lib/boukensha/logger.rb:103`), used by `Agent#handle_tool_calls` for the
preamble text before a tool call (`agent.rb:180`) — an unrelated, pre-existing
"plan" (the model's inline reasoning before acting, not the Planner's output).
Don't reuse that event name for logging Planner updates; log the Planner's
output under its own `task_name` (`"planner"`) via the normal
`request`/`response` events instead, the same way `content_fact` and
`compactor` already get separated in `log_viz` purely by `task_name`.

## 3. `Tasks::Planner`

Mirrors `Tasks::Player` exactly (`lib/boukensha/tasks/player.rb`):

```ruby
module Boukensha
  module Tasks
    class Planner < Base
      def self.task_name = "planner"
    end
  end
end
```

**No `tools:` block in its `settings.yaml` entry, by default.**
`Tasks::Base.tool_policy` returns `ToolPolicy.new(allow: [])` —
deny-everything — when a task has no `tools:` block (`tasks/base.rb:62-71`,
and see `docs/plans/tools_policy/permission.md`'s "Default / fail-safe").
That's "pure reasoning over the transcript + current plan, no tools" for
free when nobody configures otherwise — see the correction below for why
this is now a default rather than a hard rule.

`settings.yaml` addition:

```yaml
tasks:
  planner:
    provider: anthropic
    model: claude-haiku-4-5   # cheap/fast — short structured output, not open-ended play
    max_output_tokens: 512
```

Input to the Planner call: the current goal (whatever was piped in as the
turn's input) plus, on a replan, the Player transcript tail and the prior
plan (so it can say what changed, not just restate from scratch). Output:
plain text plan, stored verbatim into `ctx.plan`. No structured-output
parsing needed here (unlike the Judge — see `evaluator.md` — the Planner's
output is consumed only by a human-readable prompt block, not branched on
programmatically).

**Correction (2026-08-07):** "no `tools:` block" above was implemented as a
hardcoded rule, not just a default — `Boukensha.run_planner` ignored
`tasks.planner.tools` entirely and always called the model with `tools: []`
via a bare `Client#call`, never `tool_policy`. That's a real bug against
this project's actual policy (`docs/plans/tools_policy/permission.md`):
every task's permissions are supposed to live in `settings.yaml`, not be
special-cased in agent code. Fixed by making `run_planner` mirror
`run_judge` exactly — `Tasks::Base.tool_policy(task_settings, ...)` builds
its `ToolPolicy` from `tasks.planner.tools` like any other task, a
throwaway `Registry` reuses the Player's already-connected Tool objects
(`Boukensha.reuse_registered_tools`, the renamed and now-shared
`reuse_inspector_tools`) when a `player_context:` is passed, and the call
runs through a real (if usually one-iteration) `Agent#run` loop instead of
a bare `Client#call`, so a granted tool can actually be dispatched, not
just listed. The "§5 Observability" bare-`Client#call` claim below is
stale for the same reason — see its own correction. Deny-by-default when
`tools:` is omitted still holds, but now purely because
`Tasks::Base.tool_policy` returns `ToolPolicy.new(allow: [])` for an absent
block — the same generic mechanism every task gets, not a Planner-specific
carve-out anywhere in `lib/boukensha.rb`.

**Third correction (2026-08-07, supersedes the one directly above):**
`reuse_registered_tools`/`reuse_inspector_tools` is gone — it re-registered
the *Player's* already-filtered `Tool` objects onto the Judge's/Planner's
own `Registry`, which meant a task's effective tool set was bounded by
`intersection(tasks.<name>.tools, tasks.player.tools)`, not just
`tasks.<name>.tools`: a `role: inspector` grant (e.g. `world__room_knowledge`)
was unreachable by the Judge/Planner whenever the Player's own
`role: gameplay` never registered it first. Fixed per
[`docs/plans/tools_policy/mcp_connection_sharing.md`](../tools_policy/mcp_connection_sharing.md):
connecting to an MCP server (spawn + handshake, exactly once per server per
session — the real constraint that made the old hack exist, since `mud` is
a stateful login) is now split from registering a task's own filtered view
of that connection's full catalog. `Boukensha::McpConnections.connect(cfg,
servers:)` does the former, once, at whichever call site starts a session
(`Boukensha.run`/`.repl`/`Session.play`); `run_judge`/`run_planner` take an
`mcp:` kwarg (that same `McpConnections`, or `nil`) in place of
`player_context:`, and call `mcp&.register(registry)` — a fresh pass of
`Registry#tool`, and therefore that task's *own* `ToolPolicy`, over the
already-fetched catalog, independent of what the Player's own policy
allows. Player, Judge, and Planner are siblings now, not a hierarchy where
the latter two can only borrow what the first already claimed.

## 4. The session driver

New, opt-in — does **not** modify `Boukensha.run`, `Boukensha.repl`, or
`Repl` (per the high-level doc's Alternative B: Planner/Judge disabled ==
today's unchanged behavior, kept as the fallback/baseline). Proposed shape,
pending the open question above:

**Correction (2026-08-07):** the "does not modify `Boukensha.run`/`.repl`/
`Repl`" framing above is now only true for *this section's* specific
mechanism — the autonomous "loop `Agent#run` calls, checkpoint, ask a
Judge" driver below is still exactly what `Boukensha::Session` alone does,
opt-in, unchanged. But `Boukensha.run`/`.repl`/`Repl` themselves are no
longer untouched: they now seed a plan by default (Planner only, no
checkpoint loop, no Judge) — see
[`repl_planner_integration.md`](repl_planner_integration.md), which reverses
the high-level doc's Alternative-B default for exactly that piece. Read
"opt-in" below as scoped to *Session's auto-continue loop specifically*,
not to Planner activity reaching the real CLI at all.

**Second correction (2026-08-07, later the same day):** the same reversal
was then extended to the Judge specifically — `Repl` now also calls
`Boukensha.run_judge` by default at a checkpoint (limit-triggered wrap-up,
same `checkpoint?` predicate as below, now named `Session.checkpoint?` and
shared by both callers) and branches on `continue`/`replan`/`flag`, adapted
for a human-driven REPL: `flag` prints a warning instead of `break`-ing,
since there is no auto-continue loop in `Repl` for it to stop. See
[`repl_judge_integration.md`](repl_judge_integration.md). "Opt-in" below is
now scoped even more narrowly: *Session's specific shape* (an autonomous
loop that feeds itself the literal `"continue"` with no human typing
between turns) is still the only opt-in piece — checkpoint → Judge →
verdict handling itself now reaches the ordinary CLI path too.

```
Boukensha::Session (or similar — naming TBD)
  .play(goal:, player:, ...same kwargs as Boukensha.run...)
    1. build ctx/registry/backend/logger as .run does today
    2. Tasks::Planner call -> ctx.plan = plan_text
    3. loop:
         instruction = first iteration ? goal : "continue"
         agent = Agent.new(context: ctx, ..., task_name: "player")
         text  = agent.run
         break if agent.stop_reason == :completed   # Player declared itself done
         if checkpoint?(agent)                       # see evaluator.md
           verdict = run_judge(ctx, ...)
           case verdict
           when :replan then ctx.plan = rerun_planner(ctx, ...)
           when :flag    then log + break             # surface to human, v1: no auto-recovery
           when :continue then next
           end
         end
    4. return final text / summary
```

`agent.stop_reason` is a small additive accessor on `Agent` — see
[`worker.md`](worker.md) §2 — it does not change `Agent#run`'s loop body,
only exposes why it returned. `checkpoint?` is defined in
[`evaluator.md`](evaluator.md) as `Session.checkpoint?` (limit-triggered
wrap-up, or an `every_n_turns:` fallback). Originally written assuming that
fallback would only ever be counted across *this loop's* iterations, not
`Repl#turn` — since corrected: `Repl` now counts its own
`@turns_since_checkpoint` and calls the same `Session.checkpoint?` predicate
(`repl_judge_integration.md`), so `every_n_turns:` is a real, independently
configurable cadence in both callers, not exclusive to `Session`.

`bin/play_players` would gain a `--planned`/`--orchestrated` flag (or a
sibling script) that calls this instead of spawning
`boukensha --player NAME --no-tui`; the existing one-shot path stays exactly
as it is for anyone not opting in.

## 5. Observability

Free for OTel, by the existing per-`task_name` convention (`log_viz`/OTEL
already separate `content_fact`/`compactor`/`player` — see
`lib/boukensha/agent.rb:37-41`'s `boukensha.task` span attribute and
`Logger.new(snapshot: { task: ... })`): give the Planner call `task_name:
"planner"` when constructing whatever calls it (likely a bare
`Client#call` + `PromptBuilder`, not a full `Agent#run` loop, since it makes
exactly one call with no tools to dispatch — no iteration loop needed).

**Correction (2026-08-06, after Phase 2 shipped and was checked against a
real session in `log_viz`):** "free" undersold what `log_viz` itself
actually does with `task_name` beyond OTel spans. Its `Cost by Task` table
already groups by task and needed no changes — but its Iteration view
doesn't visually distinguish which task an entry belongs to (most entry
types don't even carry a `task` field yet — only `response` events do), and
it has no Model usage breakdown at all. See
[`implementation_plan.md`](implementation_plan.md)'s Phase 4.5 and
[`log_viz_visibility.md`](log_viz_visibility.md) for the actual gap and fix
— genuinely new plumbing, on the `log_viz`/`Logger` side, not on the
Planner/Judge side this section is otherwise about.

**Correction (2026-08-07):** "likely a bare `Client#call` + `PromptBuilder`,
not a full `Agent#run` loop, since it makes exactly one call with no tools
to dispatch" is stale — see §3's correction of the same date.
`Boukensha.run_planner` now always runs through `Agent#run`, the same as
`run_judge`; `task_name: "planner"` is passed to `Agent.new` the normal way
instead of being threaded through by hand on a bare `Client#call`/
`logger&.request`/`logger&.response` sequence. Behavior is unchanged for
the common case (no `tasks.planner.tools` configured still means exactly
one round trip, since an empty `Registry` never returns a `tool_use` stop
reason) — this only changes what happens once an operator actually grants
the Planner a tool.

## Acceptance criteria

- With no `tasks.planner` block in `settings.yaml`, nothing changes for
  `Boukensha.run`/`.repl` — `ctx.plan` stays `nil`, `effective_system ==
  system` always.
- `prompts/player/system.md` (moved) resolves identically to the old
  `prompts/system.md` — a no-op path change verified by existing tests
  continuing to pass unmodified.
- A `Tasks::Planner` call with a goal produces plan text that shows up in
  the next Player iteration's `system` payload (spot-check a logged request
  payload) without appearing as a `Context#messages` entry.
- With no `tools:` block configured, Planner's `tool_policy` denies every
  tool name — assert this the same way `test_tasks_base_tool_policy.rb`
  already does for deny-by-default. **(2026-08-07):** additionally, with a
  `tasks.planner.tools` block configured and a `player_context:` passed,
  the Planner must be able to actually dispatch a granted tool, and must
  still be denied one outside its configured role even when the Player's
  live context has it registered — see `test_run_planner.rb`'s
  `test_a_configured_role_lets_the_planner_actually_dispatch_a_tool` /
  `test_a_tool_outside_the_configured_role_is_never_dispatchable_by_the_planner`.
  **(2026-08-07, later the same day):** `player_context:` above is stale —
  see §3's third correction. Read it as `mcp:` (a `Boukensha::McpConnections`),
  and "the Player's live context has it registered" as "the shared MCP
  connections' full catalog includes it" — the acceptance criterion itself
  (own-role grants dispatchable, out-of-role grants denied, independent of
  any other task) is unchanged, only what's being reused is.

## Deferred / out of scope here

Concurrent/multi-goal plans, a persona/room-surveyor layer on the Planner's
prompt, and `Tasks::Navigator` are all called out as v2 in the high-level
doc's "Deferred to v2" section — unchanged, not re-litigated here.
