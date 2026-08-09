# Step 18 - Orchestrator

Branched from `17_tool_permission` (stays the source of truth for everything
carried forward unchanged: context/token management, the TUI, the MCP-host
tool model, multi-player support, MUD response compaction, OpenTelemetry
traces/metrics, and per-task tool policy — see that step's README). This
step builds the Planner/Player/Judge agentic loop:
`Tasks::Planner` sets a plan before play starts, the existing `Tasks::Player`
ReAct loop stays untouched, and `Tasks::Judge` checks in at checkpoints to
decide `continue`/`replan`/`flag`. Full design/rationale:
[`docs/plans/agent_loop/`](../../../docs/plans/agent_loop/) — the
[implementation plan](../../../docs/plans/agent_loop/implementation_plan.md)
sequences the build into phases; this step currently covers **Phase 0**
(driver architecture decision — see
[`phase0_decision.md`](../../../docs/plans/agent_loop/phase0_decision.md)),
**Phase 1** (shared plumbing), **Phase 2** (`Tasks::Planner`), **Phase 3**
(`Tasks::Judge` — read-only checkpoint evaluator, `continue`/`replan`/`flag`),
**Phase 4** (`Boukensha::Session`, the full Planner → Player → Judge turn
loop — a checkpoint now really calls the Judge and branches on its verdict,
not just a `warn` + `max_turns:` stand-in), **Phase 4.5** (`log_viz` task
visibility — Planner/Judge/any future subagent's activity now renders as its
own clearly labeled section in `log_viz`'s Iteration view, not folded into
generic "Assistant" text), **Phase 4.6** (Planner-by-default —
`boukensha --player`/`bin/play_players` now seed a plan automatically; this
reverses the high-level doc's original "disabled by default" call, on
purpose, ahead of Judge existing — see
[`repl_planner_integration.md`](../../../docs/plans/agent_loop/repl_planner_integration.md)),
and **Phase 4.7** (Judge-by-default — the same `boukensha --player`
session now also checks in with the Judge at every checkpoint, adapted for
a human-driven REPL rather than `Boukensha::Session`'s autonomous loop —
see
[`repl_judge_integration.md`](../../../docs/plans/agent_loop/repl_judge_integration.md)).
The rest of **Phase 5** (validation) is not yet done — see "Not doing yet"
below.

## Install

```sh
cd week3_capable/ruby/18_orchestrator
bundle install
```

Prerequisites beyond the Ruby gems: same as `17_tool_permission` — a
`mud-manager` MCP server on `PATH`, `.boukensha/players/*.yaml` character
profiles (see `week3_capable/bin/seed_players`), and optionally a local
Ollama daemon for `log_viz`'s classification features.

## Build

```sh
gem build boukensha.gemspec
gem install boukensha-0.18.0.gem
```

Installs the `boukensha` executable. `~/.boukensharc`'s `boukensha_path`
must point at this step's directory for it to run this step's code — see
`lib/boukensha_loader.rb`'s header comment.

## What's new in this step

### Phase 1 — shared plumbing

No user-visible behavior change on its own — nothing downstream (Planner,
Judge, the session driver) used this plumbing until Phase 2 below. Running
`boukensha`/`boukensha --no-tui`/`play_players` still behaves exactly like
`17_tool_permission`, since none of them call `Tasks::Planner` yet.

#### Task-scoped default prompts

Before this step, `Tasks::Base.read_default_prompt` resolved every task's
default system prompt from the same unscoped path
(`default_prompts_dir/system.md`) — invisible with one task (`player`), but
the moment a second task (`planner`, `judge`) needs its own default prompt,
both would collide on the Player's. `read_default_prompt` is now scoped by
`task_name`, mirroring how `read_user_prompt` already worked:

```
prompts/player/system.md   # was prompts/system.md — moved, content unchanged
```

A no-op path change for `Tasks::Player`, the only caller before this step;
`Tasks::Planner` (below) reads `prompts/planner/system.md` for free because
of it, without accidentally inheriting the Player's prompt, and a future
`Tasks::Judge` gets the same for `prompts/judge/system.md`.

#### `Context#plan` / `Context#effective_system`

```ruby
ctx.plan = "1. Reach the temple square.\n2. Talk to the priest."
ctx.effective_system
# => "<system prompt>\n\n## Current Plan\n1. Reach the temple square.\n2. Talk to the priest."
```

Where a future Planner's output will live: a mutable field on `Context`,
separate from the fixed-at-construction `system` string. `effective_system`
is `system` verbatim when `plan` is `nil`/blank (orchestration disabled, or
no Planner has run yet) — every backend now builds its request from
`context.effective_system` instead of `context.system`, so a plan (once
something sets one) shows up in the Player's system prompt on every
iteration, immune to `compact_messages!` (which only ever touches
`@messages`, never `@system`).

#### `Agent#stop_reason`

```ruby
agent.run
agent.stop_reason   # => :completed | :max_iterations | :max_tokens
```

Exposes *why* `Agent#run` returned, set at each of its three return points
with no change to control flow. `Boukensha::Session` (Phase 4, below) is
the first real reader — it's how the turn loop tells a natural end-of-turn
apart from a limit-triggered wrap-up without re-parsing the returned text;
`Session.checkpoint?` (Phase 3/4, below) reads it the same way to decide
whether a turn is worth handing to the Judge at all.

### Phase 2 — `Tasks::Planner`

Still no change to the default `boukensha`/`play_players` path — neither
calls `Boukensha.run_planner`. This phase adds the Planner itself plus one
call site that can be exercised directly, e.g. from a script or a REPL
session (or, per Phase 4 below, from inside `Boukensha::Session`):

```ruby
plan_text = Boukensha.run_planner(goal: "explore the temple square")
ctx.plan  = plan_text   # Context#plan, from Phase 1 — shows up in
                         # ctx.effective_system on every subsequent turn
```

#### `Tasks::Planner` — pure reasoning, no tools

```ruby
module Boukensha
  module Tasks
    class Planner < Base
      def self.task_name = "planner"
    end
  end
end
```

Mirrors `Tasks::Player` exactly. No `tools:` block in its `settings.yaml`
entry means `Tasks::Base.tool_policy` denies every tool name by the same
deny-by-default rule `17_tool_permission` introduced — "pure reasoning over
the goal, no tools" for free, nothing to configure or remember not to grant.
`prompts/planner/system.md` is its own scoped default prompt (Phase 1's
task-scoped `read_default_prompt` is what makes this resolve correctly
instead of colliding with the Player's).

#### Config: `tasks.planner:`

Same shape as `tasks.player:`/`tasks.compactor:` — user-side
`.boukensha/settings.yaml`, not shipped in this repo:

```yaml
tasks:
  planner:
    provider: anthropic
    model: claude-haiku-4-5       # cheap/fast — short structured output,
                                   # not open-ended play
    max_output_tokens: 512
```

All three keys are optional at the `Boukensha.run_planner` call site — pass
`model:`/`backend:`/`max_output_tokens:` directly (as the snippet above
does, relying on defaults) and this block is never consulted for that call.
`Boukensha::Session` (below) reads it by default too, the same way
`tasks.player:` already governs the Player's own call.

#### `Boukensha.run_planner` — one bare model call, no `Agent#run` loop

```ruby
def self.run_planner(goal:, transcript_tail: nil, prior_plan: nil,
                      model: nil, backend: nil, api_key: nil,
                      ollama_host: "http://localhost:11434",
                      max_output_tokens: nil, logger: nil)
```

Builds a throwaway `Context` (Planner's own system prompt + one user message
assembled from `goal:`, and on a replan, `prior_plan:`/`transcript_tail:`),
makes one `Client#call` tagged `task: "planner"`, and returns the model's
plain-text reply. No `Registry`, no tool dispatch, no iteration loop — there
is nothing for Planner to call, so `Agent#run`'s machinery would be pure
overhead here. `task: "planner"` on the `Client#call` is what makes
`log_viz`/OTEL separate this call from Player activity automatically (the
same per-`task_name` convention `content_fact`/`compactor` already use) —
no new observability plumbing needed. `Boukensha::Session` (below) calls
this from inside its loop instead of duplicating the request-building
logic; it's also still usable standalone, e.g. from a script or REPL
session.

### Phase 3 — `Tasks::Judge`

Adds the read-only checkpoint evaluator: `Boukensha.run_judge` reads the
Player's current plan and a transcript tail, may call read-only tools to
fact-check a claim, and returns a `continue`/`replan`/`flag` verdict.

```ruby
verdict = Boukensha.run_judge(
  plan: ctx.plan, transcript_tail: Boukensha.transcript_tail(ctx.messages),
  player_context: ctx, logger: logger
)
verdict            # => { verdict: :continue | :replan | :flag, text: "<Judge's full response>" }
```

#### `Tasks::Judge` — read-only, `role: inspector`

```ruby
module Boukensha
  module Tasks
    class Judge < Base
      def self.task_name = "judge"
    end
  end
end
```

Mirrors `Tasks::Planner`/`Tasks::Player`. Unlike the Planner (no tools at
all), the Judge gets `tools: { role: inspector }` in its `settings.yaml`
entry — the same read-only glob set (`look`/`examine`/`consider`/`diagnose`
+ `room_knowledge`) `17_tool_permission` already defined, reused verbatim so
there's zero new `ToolPolicy` code. `move`/`attack`/`quit`/`give` are never
in that list — an evaluator that can act on the world isn't an evaluator.
`Tasks::Judge.max_iterations` also overrides `Tasks::Base`'s default (25)
down to a `DEFAULT_MAX_ITERATIONS = 5` — "check a couple of facts, then
decide," not another open-ended play loop — unless `tasks.judge.max_iterations`
says otherwise.

#### Config: `tasks.judge:`

```yaml
tasks:
  judge:
    provider: anthropic
    model: claude-haiku-4-5   # cheap/fast — short structured verdict
    max_output_tokens: 400
    max_iterations: 5
    tools:
      role: inspector
```

#### `Boukensha.run_judge` — a small `Agent#run` loop, a throwaway `Context`

```ruby
def self.run_judge(plan:, transcript_tail:, player_context:, logger:,
                    model: nil, backend: nil, api_key: nil,
                    ollama_host: "http://localhost:11434",
                    max_output_tokens: nil, max_iterations: nil)
```

Unlike `run_planner` (a single bare `Client#call` — Planner has no tools to
dispatch), the Judge might call `room_knowledge` or `look`/`examine` to
verify a transcript claim, so it needs `Agent#run`'s iteration loop, just a
small one. `player_context:` is the Player's **live** `Context` — read only,
for its already-registered `Tool` objects. `run_judge` re-registers those
same tool objects (same block, so the same live MCP session — no second
character login) onto the Judge's own **throwaway** `Context`/`Registry`,
filtered through the Judge's own `role: inspector` policy; `Registry#tool`
silently drops anything that policy denies, so `move`/`attack`/`quit`/`give`
never even get registered on the Judge's side, no matter what the Player's
own (broader) policy allowed. `player_context` itself is never passed to
`Agent#run` and is never mutated — its `messages`/`plan` are exactly what
they were before the Judge call, after it returns.

`logger:` is required here (unlike `run_planner`'s optional one) — `Agent#run`
always logs through one, and every real caller (`Boukensha::Session`) already
has the Player's logger to hand it.

#### The verdict contract

The Judge's system prompt (`prompts/judge/system.md`) instructs it to end
its final response with exactly one line: `VERDICT: continue`, `VERDICT:
replan`, or `VERDICT: flag`. `run_judge` parses that line with an anchored
regex (`Boukensha::VERDICT_PATTERN`) and returns the parsed symbol alongside
the full response text. A response that doesn't end with that line falls
back to `:flag`, not `:continue` — a checkpoint the Judge couldn't even be
parsed for should stop and surface to a human, not sail through silently.
`logger.judge_verdict(verdict:, text:, task:)` is a new `Logger` event,
distinct from the Judge's own `response` event (already logged by
`Agent#run`), so a viewer can find "what did the Judge decide" without
re-parsing response text.

### Phase 4 — `Boukensha::Session`, the full Planner → Player → Judge loop

```ruby
result = Boukensha::Session.play(goal: "explore the temple square", player: my_player, max_turns: 10)
```

What it does, per `orchestrator.md` §4's pseudocode and
[`evaluator.md`](../../../docs/plans/agent_loop/evaluator.md) §4-§5: builds
ctx/registry/backend/logger the same way `Boukensha.run` does → calls
`Boukensha.run_planner` once to seed `ctx.plan` → loops `Agent#run` calls,
turn after turn, feeding the goal on turn 1 and the literal `"continue"`
(the Phase 0 decision) on every turn after → after each call, checks
`Session.checkpoint?` (`stop_reason` in `[:max_iterations, :max_tokens]`, or
the `every_n_turns:` fallback, default off) → on a checkpoint, calls
`Boukensha.run_judge` and branches on its verdict (`continue`: loop back
around; `replan`: re-run the Planner with the prior plan + a fresh
transcript tail, update `ctx.plan`; `flag`: log distinctly and stop — v1 has
no automatic recovery from a flag, a human reviews the log) → stops when
`agent.stop_reason == :completed`, a `flag` verdict, or `max_turns:` is hit
(now an outer backstop against a Judge that keeps saying `:continue`
forever, not the primary stop mechanism).

`planner_model:`/`planner_backend:`/`planner_api_key:`/
`planner_ollama_host:` and `judge_model:`/`judge_backend:`/
`judge_api_key:`/`judge_ollama_host:` let the Planner's and Judge's calls
each use different provider/model settings than the Player's own
`model:`/`backend:`/`api_key:`/`ollama_host:` — all default to their
respective `tasks.<name>:` config, same as calling `run_planner`/`run_judge`
standalone. The `warn` output at every plan/checkpoint/replan/flag is
deliberately loud, meant for watching a session live (see
`examples/session_demo.rb` below) in the terminal, in addition to (not
instead of) what shows up in `log_viz` too — see Phase 4.5 next.

### Phase 4.5 — `log_viz` task visibility

Answers "where do I actually *see* the Planner ran?" beyond the terminal
`warn` output above. Full design:
[`log_viz_visibility.md`](../../../docs/plans/agent_loop/log_viz_visibility.md).
What changed:

- `Agent#run`/`Boukensha.run_planner` now tag every logged event
  (`request`/`tool_call`/`tool_result`/`reasoning`/the tool-call-preamble
  `plan` event) with `task:`, not just `response` — `@task_name` was
  already in scope at each call site, this just threads it through.
- `log_viz`'s Iteration view (a session's page,
  `week3_capable/log_viz/views/session.erb`) now inserts a colored
  section marker every time the task changes — a Planner call before the
  Player's first turn gets its own clearly labeled "planner" section
  instead of rendering as an unlabeled "Assistant" entry under whatever
  iteration counter happened to be current.
- The existing "Cost by task / provider / model" table (it already grouped
  correctly — nothing to fix there) is retitled "Usage & cost by task /
  provider / model" so it's unambiguous it also answers "how much did the
  Planner/Judge/Player each use," rather than needing a second, redundant
  table with identical numbers.
- Colors are index-cycled per session (same pattern
  `LIVE_MARKER_COLORS` already uses for map markers) — no hardcoded
  `"player"`/`"planner"`/`"judge"` anywhere in `log_viz`, so a future
  subagent gets this for free the moment its events carry a `task` string.

### Phase 4.6 — Planner-by-default in `boukensha --player`

**The behavior change that actually matters if you just run `boukensha`.**
Reverses `high_level_agentic_loop_design.md`'s original "Planner/Judge
disabled == today's behavior" default — on purpose, ahead of Judge
existing, so the Planner can be observed in the actual command instead of
only via `examples/session_demo.rb`. Full design:
[`repl_planner_integration.md`](../../../docs/plans/agent_loop/repl_planner_integration.md).

```
$ boukensha --player noir
(planning...)
Plan:
1. ...
2. ...

boukensha> defeat the newbie zone rat
...
```

- **On by default.** `Config#planner_enabled?` reads
  `tasks.planner.enabled` in `settings.yaml`, defaulting `true`. Set it to
  `false` to opt back out — no CLI flag, same "config is the toggle"
  convention `tasks.compactor.enabled`/`observability.enabled` already use.
- **Seeds once per REPL session**, on the first turn — not once per turn.
  The Judge (Phase 4.7 below) decides `continue`/`replan`/`flag` at a
  checkpoint, not "is this a new quest" on every single turn, so re-running
  the Planner on every turn would still just be wasted calls. `/clear`
  resets it, so a REPL session that moves on to a completely different
  quest can get a fresh plan by running `/clear` first.
- **`bin/play_players` needed zero changes** — it already spawns
  `boukensha --player NAME --no-tui` with the goal piped as one line, which
  goes through the exact same `Repl#run_turn` this now seeds a plan from.
- **No auto-continue, then or now.** A turn that hits
  `:max_iterations`/`:max_tokens` still doesn't loop automatically —
  `Agent#run`'s own wrap-up fires and the human decides what to type next.
  That part is still exclusive to `Boukensha::Session` (Phase 4 above),
  which remains a separate, opt-in entry point for anyone who wants the
  fully autonomous multi-turn loop. **What changed since this phase
  shipped:** the Judge itself no longer sits that turn out — see Phase 4.7
  next.

### Phase 4.7 — Judge-by-default in `boukensha --player`

Applies the same reversal to the Judge, once Phase 3 made it real. Full
design:
[`repl_judge_integration.md`](../../../docs/plans/agent_loop/repl_judge_integration.md).

```
boukensha> attack the rat
(the Player fights, hits its action limit mid-fight)
I got a few hits in but couldn't finish it off before running out of turns...

(checking in with the Judge...)
Judge: continue — The Player made real progress and can pick this back up.

boukensha> continue
...
```

- **On by default.** `Config#judge_enabled?` reads `tasks.judge.enabled` in
  `settings.yaml`, defaulting `true` — same convention as
  `planner_enabled?`. Set it to `false` to opt back out.
- **Only checks in at a checkpoint** — a turn that hits
  `:max_iterations`/`:max_tokens` (`Repl#maybe_check_judge`, reusing
  `Session.checkpoint?`, the same predicate `Boukensha::Session` uses). A
  turn that completes normally does not call the Judge; there's also an
  optional `judge_every_n_turns:` fallback (Ruby kwarg only, off by
  default) for checking in periodically even when nothing hits a limit.
- **Adapted for a human, not an autonomous loop.** `continue` just prints
  the verdict; `replan` re-runs the Planner and updates the plan (skipped,
  with a note, if `planner_enabled:` is false — a Judge verdict shouldn't
  reintroduce Planner activity a session opted out of); `flag` prints a
  warning and nothing more — unlike `Boukensha::Session`, there's no
  auto-continue loop here for a flag to stop, so it surfaces instead of
  halting.
- **`bin/play_players` needed zero changes** — same reason as Phase 4.6:
  it already funnels through `Repl#run_turn`.
- **`Boukensha.run` (the one-shot path) is untouched, on purpose** — a
  single call has no further turn for a `replan`/`flag` verdict to actually
  do anything with, so adding a checkpoint check there would only ever
  print something, never change behavior.

## Run

Offline smoke test, no live MUD needed (built-in fake MUD):

```sh
ruby examples/mcp_mud_demo.rb --dry
ruby examples/example.rb
```

Watch the Planner → Player → Judge loop live (needs real API keys + a
reachable MUD — see `examples/session_demo.rb`'s header for details):

```sh
ruby examples/session_demo.rb --goal "explore the temple square" --player noir
```

Prints the Planner's plan to stderr as soon as it's produced, then the
Judge's verdict (and a replan, if it calls for one) at every checkpoint.
This is `Boukensha::Session` — the separate, still-opt-in autonomous driver.

The **ordinary** path — `boukensha --player NAME`, `boukensha --no-tui`,
`bin/play_players` — adds no new CLI surface (no new flags, no new
executable), but its *behavior* changed as of Phase 4.6/4.7: the first turn
of every REPL session now seeds a plan by default (prints `(planning...)`
then the plan to the terminal) before the Player acts, and any turn that
hits its action/token limit now also prints `(checking in with the
Judge...)` followed by the Judge's verdict — with a `Replanned:` block if it
asked for one, or a `⚠` warning if it flagged something. Everything else
about those commands — the ReAct loop, its limits, `/quiet`/`/compact`/
`/exit`, one-shot goal-piped-via-stdin — is exactly as in
`17_tool_permission`. Set `tasks.planner.enabled: false` and/or
`tasks.judge.enabled: false` in `settings.yaml` to get that byte-for-byte
old behavior back, independently of each other.

## Tests

```sh
rake test
```

New coverage for this step:

Phase 1 — `test_context_plan.rb` (`plan`/`effective_system` defaulting and
formatting), `test_backends_effective_system.rb` (all five backends read
`effective_system`, and are byte-identical to the pre-step payload when
`plan` is never set), `test_tasks_base_prompts.rb` (the moved, task-scoped
default prompt path, including two tasks resolving distinct prompts), and
`test_agent_stop_reason.rb` (`:completed`/`:max_iterations`/`:max_tokens`
for all three of `Agent#run`'s return points).

Phase 2 — `test_tasks_planner.rb` (deny-by-default `tool_policy` with no
`tools:` block, the planner-scoped default prompt resolves), and
`test_run_planner.rb` (`run_planner` returns the model's plan text end to
end through a scripted `Backends::Ollama` server; that text, once assigned
to a Player `Context#plan`, shows up in `effective_system` and never in
`Context#messages`; a replan call's request body carries both `prior_plan:`
and `transcript_tail:`).

Phase 3 — `test_tasks_judge.rb` (`task_name`, the `role: inspector` tool
policy denies `move`/`attack`/`quit`/`give` and allows
`look`/`examine`/`room_knowledge`, the judge-scoped default prompt
resolves, `max_iterations` defaults to `5` and honors an explicit
`tasks.judge.max_iterations`) and `test_run_judge.rb` (fixture-driven: a
"clearly on track" transcript parses `:continue`, a "same room repeated
many times" transcript parses `:flag`, an explicit `VERDICT: replan` line
parses `:replan`, a response with no `VERDICT:` line falls back to `:flag`;
an isolation test proving a Judge call that dispatches `room_knowledge`
never mutates the Player's live `Context#messages`/`#plan`; a test that only
`room_knowledge` and inspector-role tool names actually get registered on
the Judge's own registry, even when the Player's live context has broader
ones registered).

Phase 4 — `test_session.rb`: `Session.play` seeds the plan and it shows up
(`## Current Plan`) in the Player's actual request payload on turn 1; a
checkpoint (iteration-limit wrap-up) calls the Judge and, on `:continue`,
doesn't end the session — turn 2 is fed the literal `"continue"` and the
loop keeps going; a `:replan` verdict re-runs the Planner and the new plan
text shows up in the next turn's request payload; a `:flag` verdict stops
the session immediately, before `max_turns:` would have; `max_turns:` still
stops the session as an outer backstop when checkpoints keep coming back
`:continue`. All run against scripted `Backends::Ollama` servers (one each
for the Planner, Player, and Judge) — no live provider or MUD needed.

Phase 4.5 — new cases added to `test_logger.rb` (`request`/`tool_call`/
`tool_result`/`reasoning`/`plan` all carry `task:`, defaulting to `nil` when
omitted so old call sites stay byte-identical). `week3_capable/log_viz`'s
own suite gets a new `test/test_session_task.rb` (every entry type carries
`task`, `task_names` reflects it, `nil`-task old-log entries read back
`nil` not `""`) — run that suite separately, it's a different Ruby program:
`cd ../../../week3_capable/log_viz && ruby -Itest -Ilib test/test_session_task.rb`
(no Rakefile there — each `test_*.rb` runs standalone).

Phase 4.6 — `test_config_planner.rb` (`Config#planner_enabled?` defaults
`true` with no block or an explicit `enabled: true`; `false` only when set)
and `test_repl_planner.rb` (a `Repl`'s first `run_turn` seeds the plan and
it reaches the Player's request payload; a second turn does not re-invoke
the Planner; `/clear` allows a fresh plan on the next turn;
`planner_enabled: false` skips seeding with a byte-identical request
payload) — all against scripted `Backends::Ollama` servers, same pattern as
Phase 4's `test_session.rb`.

Phase 4.7 — `test_config_judge.rb` (`Config#judge_enabled?` defaults `true`
with no block or an explicit `enabled: true`; `false` only when set) and
`test_repl_judge.rb` (a limit-triggered checkpoint calls the Judge exactly
once and its verdict reaches the REPL's printed output; a naturally-
completed turn never calls the Judge; `judge_enabled: false` skips it even
at a checkpoint; a `:replan` verdict re-runs the Planner and updates
`ctx.plan`, and is a no-op with a printed note when `planner_enabled:` is
false; a `:flag` verdict prints a warning without raising; `judge_every_n_
turns:` checkpoints a naturally-completed turn once the count is reached;
`/clear` resets the checkpoint counter) — same scripted-`Backends::Ollama`
pattern as Phase 4.6.

## Not doing yet (later phases of this same step)

Tracked in
[`implementation_plan.md`](../../../docs/plans/agent_loop/implementation_plan.md),
not filed as bugs:

- **`bin/play_players`/`Boukensha::Session`'s auto-continue loop wiring** —
  orchestrator.md §4 still proposes a `--planned`/`--orchestrated` flag on
  `bin/play_players` for `Session`'s *autonomous multi-turn* loop
  specifically (checkpoint → Judge → continue/replan/flag — now real, see
  Phase 3/4 above); `examples/session_demo.rb` is the standalone way to
  exercise that today. This is narrower than it used to be: `play_players`
  already gets Planner-seeding for free as of Phase 4.6 (it funnels through
  `Boukensha.repl` like everything else) — what's still missing is only the
  Session-specific auto-continue behavior (including its Judge checkpoints)
  reaching `bin/play_players` itself, not Planner or Judge existing.
- **A manual `/replan` REPL command** — `/clear` is the only way to force a
  fresh plan mid-session today (it also wipes conversation history, which
  is blunter than strictly necessary); see
  [`repl_planner_integration.md`](../../../docs/plans/agent_loop/repl_planner_integration.md)'s
  Deferred section.
- **Validation against the journal's hypotheses** (Phase 5) — not code, a
  written comparison of Judge on vs. off (Planner-on is already the
  default, decided ahead of these numbers — see Phase 4.6) against real
  `Boukensha::Session` runs, including whether the Judge's `replan`/`flag`
  verdicts line up with what a human reviewer would also call "stuck" — now
  possible to actually run since Phase 3/4 make real verdicts instead of the
  old `warn` stub, but the write-up itself hasn't been done yet.
