# Evaluator — the Judge

Splits out of [`high_level_agentic_loop_design.md`](high_level_agentic_loop_design.md)'s
Recommendation section. Covers `Tasks::Judge`: what it's allowed to see and
do, when it's invoked, and what happens to its verdict.

**Depends on:** [`orchestrator.md`](orchestrator.md) §1 (task-scoped default
prompts — the Judge needs its own `prompts/judge/system.md`, not the
Player's), §2 (`Context#plan`, which the Judge reads to know what it's
grading progress against), and [`worker.md`](worker.md) §2
(`Agent#stop_reason`, which the checkpoint trigger below reads).
**Blocks:** nothing downstream — the Judge is the last link in one pass of
the loop; its verdict feeds back into [`orchestrator.md`](orchestrator.md)
§4's driver, not into a further doc.

## 1. `Tasks::Judge`

Mirrors `Tasks::Player`/`Tasks::Planner` (`lib/boukensha/tasks/player.rb`):

```ruby
module Boukensha
  module Tasks
    class Judge < Base
      def self.task_name = "judge"
    end
  end
end
```

Tool policy: `role: inspector` — already defined in the `tool_roles:`
convention (`README.md:83-103`, `.boukensha/settings.yaml`'s
`tool_roles.readonly`/equivalent — same read-only glob set the existing
`inspector` role uses: `look`/`examine`/`consider`/`diagnose` +
`room_knowledge`, no `move`/`attack`/`quit`/`give`). Reusing an existing role
means zero new `ToolPolicy` code — just:

```yaml
tasks:
  judge:
    provider: anthropic
    model: claude-haiku-4-5   # cheap/fast — short structured verdict, not open-ended play
    max_output_tokens: 400
    tools:
      role: inspector
```

An evaluator that can act on the world (`move`, `attack`) isn't an
evaluator — this is the one hard constraint carried over unmodified from the
high-level doc.

## 2. What the Judge is fed

- The current `ctx.plan` (what the Player was supposed to be doing).
- A transcript tail — the most recent messages from `ctx.messages`, not the
  full history (keeps the Judge call cheap and matches "occasional,
  checkpoint-only" cost). Exact window size is a tuning knob, not fixed here;
  start with whatever's left after the Player's last compaction pass and
  adjust from real logs.
- `room_knowledge` (`lib/boukensha/world_knowledge.rb`) available as a tool
  call, not force-injected — same "the agent decides whether it's useful"
  posture the module's own header comment already establishes for the
  Player. Lets the Judge fact-check a claim like "I already examined the
  fountain" against `log_viz`'s SQLite view instead of trusting the
  transcript's prose.

Since the Judge has tools (`room_knowledge` at minimum), it needs an
`Agent#run`-style loop to actually dispatch them — not a single bare
`Client#call` the way the Planner can get away with
([`orchestrator.md`](orchestrator.md) §3 note). Reuse `Agent` itself:
`Agent.new(context: judge_ctx, registry: judge_registry, ..., task_name:
"judge")` with a small `max_iterations` (a handful — this is meant to be
"check a couple of facts, then decide," not another open-ended play loop) and
its own throwaway `Context`/`Registry` seeded with the transcript tail +
plan, not `ctx` itself — the Judge must never share or mutate the Player's
live `Context` (would risk polluting `ctx.messages`/`ctx.plan` mid-check).

## 3. Verdict contract

The driver needs a programmatically-branchable answer, not free text to
re-parse with regexes. Two viable options, pick one when implementing:

- **Prompt-enforced convention**: instruct the Judge's system prompt to end
  its final (non-tool-use) response with a fixed-format last line, e.g.
  `VERDICT: continue` / `VERDICT: replan` / `VERDICT: flag`, parsed with a
  simple anchored regex on the returned text. Cheapest to build, reuses
  `Agent#run` exactly as-is (its return value is already the final text).
- **Forced tool call**: give the Judge a `deny`-listed-from-everything-else
  `submit_verdict(verdict:, reasoning:)` no-op tool (registered like any
  other `Registry#tool`, dispatched to a block that just returns its args)
  and require the model to call it to end the turn. More robust against the
  model forgetting the exact string, more plumbing (a new tool + policy
  entry).

Recommend starting with the prompt-enforced convention — matches this
codebase's general bias toward "add a field/convention, don't build new
plumbing" (see `docs/plans/observability/otel_and_logs/phase2_instrumentation.md`'s
framing) — and only move to a forced tool call if evaluation shows the
convention gets missed often enough to matter.

## 4. Checkpoint trigger

Fires from the driver — `Boukensha::Session` ([`orchestrator.md`](orchestrator.md)
§4) or, as of `repl_judge_integration.md`, `Repl` too — after each
`Agent#run` call, not from inside `Agent#run` itself (keeps the "Agent's
loop is unchanged" property from [`worker.md`](worker.md) literally true —
the caller polls `agent.stop_reason`, `Agent` doesn't call out to a Judge on
its own):

```ruby
def checkpoint?(agent, turns_since_checkpoint, every_n_turns:)
  return true if [:max_iterations, :max_tokens].include?(agent.stop_reason)
  every_n_turns && every_n_turns.positive? && turns_since_checkpoint >= every_n_turns
end
```

`agent.stop_reason == :completed` never checkpoints **in `Boukensha::
Session`** — if the Player itself declared the turn done via a normal
`end_turn`, the driver's loop already exits before checking (see
[`orchestrator.md`](orchestrator.md) §4's pseudocode: `break if
agent.stop_reason == :completed` comes first). The `every_n_turns:` fallback
exists for the case the high-level doc calls "long uninterrupted sessions
that never hit a limit" — plausible once the driver is looping multiple
`Agent#run` calls per goal (see [`orchestrator.md`](orchestrator.md)'s open
question about what "a turn" even means here); leave it configurable and
default it off (`nil`) until there's a concrete case where limit-triggered
checkpoints alone prove too sparse.

**Extended to `Repl` (2026-08-07):** `checkpoint?` — promoted to
`Session.checkpoint?`, a public predicate both callers share — now also
fires from `Repl#run_turn` (`Repl#maybe_check_judge`), once per human-driven
turn, not just from `Boukensha::Session`'s autonomous loop. `Repl` has no
"break before checking" step the way `Session` does (a human keeps driving
turns regardless of `stop_reason`), so a naturally-completed turn in `Repl`
*can* still trigger a checkpoint if `judge_every_n_turns:` is configured and
the count is reached — the `:completed`-never-checkpoints guarantee above is
specific to `Session`'s own loop shape, not to the predicate itself. See
[`repl_judge_integration.md`](repl_judge_integration.md).

## 5. Acting on the verdict

| Verdict    | Driver action                                                                 |
|------------|--------------------------------------------------------------------------------|
| `continue` | No-op — loop back to another Player turn.                                     |
| `replan`   | Re-invoke `Tasks::Planner` with the transcript tail + prior plan; `ctx.plan =` the new text ([`orchestrator.md`](orchestrator.md) §4). |
| `flag`     | Log at a distinct level (e.g. a dedicated `@logger` event, not reused from an existing one) and stop the driver's loop — v1 has no automatic recovery from a flagged risk; a human reviews the log. Matches the high-level doc's Cons section treating "flag risk" as a stop-and-surface action, not an auto-remediation. |

## 6. Observability

`task_name: "judge"` on the Judge's `Agent.new(...)` call (§2 above) is
enough for OTel spans/metrics to separate it from Player activity
automatically, same as Planner. It is **not** enough on its own for
`log_viz`'s Iteration view or a model-usage breakdown to show Judge
activity distinctly — that needs the logging-side and `log_viz`-side fixes
tracked in [`implementation_plan.md`](implementation_plan.md)'s Phase 4.5
and [`log_viz_visibility.md`](log_viz_visibility.md), which Judge shares
with Planner (same gap, not something to re-solve per task). Judge's own
verdict text (§3) and checkpoint/verdict decisions (§4-§5) should be easy
to find in a session once that phase lands — worth spot-checking against a
real Judge run once both exist, not just assuming the Planner fix covers it.

## Acceptance criteria

- A Judge run against a fixed transcript fixture returns a parseable
  verdict in all three cases — test fixtures for "clearly on track,"
  "clearly stuck" (e.g. same room repeated many times), and a case
  deliberately contradicted by `room_knowledge` (transcript claims something
  examined that the SQLite view says wasn't).
- Judge's `tool_policy` denies `move`/`attack`/`quit`/`give` — same
  assertion style as `test_tool_roles_config.rb`/`test_tasks_base_tool_policy.rb`.
- Judge runs in a separate `Context`/`Registry` from the Player's live one —
  assert the Player's `ctx.messages`/`ctx.plan` are unchanged after a Judge
  call that itself dispatches tools.
- Per the high-level doc's "How to validate" section: log whether each
  Judge "stuck" verdict (`replan`/`flag`) corresponds to a case a human
  reviewer would also call stuck, on a before/after comparison run — this is
  the actual validation of whether the Judge is worth its cost, not just
  that it runs without erroring.

## Deferred / out of scope here

Auto-recovery from a `flag` verdict (today: log-and-stop, human decides
next), and any richer verdict taxonomy beyond continue/replan/flag — start
with the three the high-level doc names, expand only if evidence from real
runs shows a gap.
