# Worker — the Player, and what (little) changes for it

Splits out of [`high_level_agentic_loop_design.md`](high_level_agentic_loop_design.md)'s
Recommendation section. The high-level doc's central claim is that the
existing `Tasks::Player` / `Agent#run` ReAct loop stays **unchanged** — this
doc exists to say precisely what "unchanged" means and to name the two small,
additive touch points the Player side still needs so the rest of the design
([`orchestrator.md`](orchestrator.md)'s Planner, [`evaluator.md`](evaluator.md)'s
Judge) has something to hook into.

**Depends on:** [`orchestrator.md`](orchestrator.md) §2 for the
`Context#plan` / `Context#effective_system` field this doc's §1 reads from.
**Blocks:** [`evaluator.md`](evaluator.md)'s checkpoint trigger, which reads
the `Agent#stop_reason` accessor added in §2 below.

## What does NOT change

- `Agent#run`'s loop body (`lib/boukensha/agent.rb:50-88`): iteration
  counting, `max_iterations`/`max_turn_tokens` limits, tool dispatch,
  compaction-if-needed, wrap-up call. Zero edits inside the `loop do ...
  end`.
- `Tasks::Player` itself (`lib/boukensha/tasks/player.rb`) — no new fields,
  no new `task_name`.
- The Player's tool policy — stays `role: full` in `settings.yaml`, per the
  existing `tasks.player.tools` block (`README.md:92-95`). The Player is the
  only role in this design that's allowed to act on the world; Planner has no
  tools ([`orchestrator.md`](orchestrator.md) §3) and Judge is read-only-only
  ([`evaluator.md`](evaluator.md) §1) specifically so neither can accidentally
  play the game.

## 1. What the Player sees differently: the plan, via `effective_system`

The only per-iteration behavior change: `PromptBuilder`/backends read
`context.effective_system` instead of `context.system`
([`orchestrator.md`](orchestrator.md) §2 defines this method and lists the
four backend call sites to update). When `ctx.plan` is `nil` (orchestration
disabled, or not yet reached the Planner), `effective_system` returns
`context.system` verbatim — byte-identical behavior to today. When a plan is
set, the Player sees a `## Current Plan` block appended to its system prompt
on every iteration, the same way it already sees the rest of its system
prompt — no new message type, nothing `compact_messages!`
(`context.rb:64-70`) can drop, since compaction only ever touches
`@messages`, never `@system`.

The Player's own prompt (`prompts/player/system.md` after the
[`orchestrator.md`](orchestrator.md) §1 path move) does not need to change
its wording to "know about" plans — it already receives whatever's in
`effective_system` as its system prompt; no new instruction like "check your
plan" is required for the model to see the block. Whether the prompt should
be *tuned* to react to it usefully (e.g. explicitly referencing "Current
Plan" in its guidance) is a prompt-engineering pass to do once the plumbing
lands, not a blocking prerequisite.

## 2. `Agent#stop_reason` — small, additive

The session driver ([`orchestrator.md`](orchestrator.md) §4) and the Judge's
checkpoint trigger ([`evaluator.md`](evaluator.md)) both need to know, after
an `Agent#run` call returns, *why* it stopped — a normal `end_turn`
completion (the Player decided it was done) versus a limit-triggered
wrap-up (it ran out of iterations or tokens mid-task). Today `Agent#run`
returns a bare `String` in both cases (`agent.rb:84`, `:141`, `:146`) — the
caller can't distinguish them without re-parsing text.

Add a reader, set at each return point, no change to control flow:

```ruby
attr_reader :stop_reason   # :completed | :max_iterations | :max_tokens

# in the natural-completion branch (agent.rb:84, before `return text`):
@stop_reason = :completed

# in wrap_up(reason) (agent.rb:129, using the existing reason: param):
@stop_reason = reason.to_sym   # "max_iterations" / "max_tokens" -> already the right strings
```

This is exactly the kind of "thin wrap around code that already exists — no
new business logic" touch point the codebase already uses elsewhere (see
`docs/plans/observability/otel_and_logs/phase2_instrumentation.md`'s
"Guiding constraint"). `@logger.limit_reached(kind:, n:, max:)`
(`agent.rb:56`, `:60`) already carries this same information into the log —
`stop_reason` just also exposes it on the object itself, for a same-process
caller that doesn't want to go re-read the log to find out.

## 3. Deferred: Player-initiated early replan

The high-level doc's Cons/risks section flags this as the plan going stale
between Judge checkpoints — "worth a cheap heuristic escape hatch later
(e.g. Player's own wrap-up text could request a replan) if this proves to
matter in practice." Not required for v1: the checkpoint cadence
([`evaluator.md`](evaluator.md)) already covers the common case (limit
reached). Only revisit if testing shows the Player getting stuck badly
enough, well before a natural checkpoint, that this matters — same
evidence-gated posture the high-level doc takes with `Tasks::Navigator`.

## Acceptance criteria

- With orchestration disabled (no `ctx.plan` ever set), a Player turn today
  vs. after this change produces byte-identical request payloads — a direct
  regression test comparing a request payload's `system`/`instructions`
  field before and after wiring in `effective_system`.
- `agent.stop_reason` is `:completed` after a normal end-of-turn text
  response, `:max_iterations` / `:max_tokens` after each respective
  wrap-up path — unit-testable the same way `test_logger.rb` presumably
  already asserts on `limit_reached`/`turn_end` calls (mirror that test's
  setup for the two wrap-up branches).
- No existing test in `test/` needs to change because of this doc's changes
  (confirms "unchanged" is actually true, not just asserted).
