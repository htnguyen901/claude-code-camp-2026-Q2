# Judge redesign — memory across checkpoints

Follow-up to [`evaluator.md`](evaluator.md), triggered by a real-session
observation, not a hypothetical: over several checkpoints the Player kept
asking beggars/NPCs for food and water, made no progress, and the Judge kept
returning `continue` every time. Looking at the actual verdict text across
those checkpoints, the Judge wasn't being fooled by one bad transcript
tail — it simply had no way to know it had already seen this exact pattern
and already said `continue` about it before. Each checkpoint is a clean
slate. This doc redesigns `Tasks::Judge`'s inputs so it isn't.

**Depends on:** [`evaluator.md`](evaluator.md) (this doc changes §2–§5 of
that spec, not its §1 tool policy or its overall continue/replan/flag
shape), [`orchestrator.md`](orchestrator.md) §4 (`Session.checkpoint?`,
`run_planner`'s `prior_plan:`/`transcript_tail:` kwargs, both touched
below).
**Blocks:** nothing downstream in this plan set — same terminal position
`evaluator.md` occupies. [`implementation_plan.md`](implementation_plan.md)
should grow a phase for this once the approach here is agreed.

## 1. Root cause

`Boukensha.run_judge` (`lib/boukensha.rb:358-397`) builds a **fresh**
`Context.new(system:)` on every call and seeds it with exactly two things
(`judge_input`, `lib/boukensha.rb:410-415`):

- `ctx.plan` — the Player's *current* plan text.
- `transcript_tail(ctx.messages, last: 20)` — the last 20 Player messages,
  rendered to text.

That throwaway `Context` was a deliberate isolation choice —
[`evaluator.md`](evaluator.md) §2 requires the Judge "must never share or
mutate the Player's live `Context`" — but isolation-per-call was implemented
as *no state survives between calls*, which is a stronger property than the
isolation requirement actually needed. The Judge has no memory that:

- It already returned `continue` at the last checkpoint, or the one before,
  for what turns out to be the same underlying problem.
- The current plan has now survived N consecutive checkpoints without
  being challenged — a plan nobody's questioned in a while isn't
  necessarily fine, it might just be past the point where anyone's looking
  at it critically.
- The Player has issued the same or a near-identical action (same tool,
  same target argument) repeatedly across checkpoints. A 20-message tail
  can even *contain* several repeats of "ask beggar for food" and the Judge
  still reasons about each checkpoint's tail in isolation, with no counter
  saying "this is the 4th time, not the 1st."

Symptom observed: not-dangerous, not-off-plan, just *inefficient* —
exactly the case [`evaluator.md`](evaluator.md)'s verdict taxonomy has no
sharp trigger for, because "efficiency of the strategy" was never one of
the three things the Judge was ever asked to track. Bolting memory onto the
existing three-verdict grading (continue/replan/flag) surfaces the same
inefficiency evidence, without needing a new "efficiency" verdict.

Also secondary: on a `replan`, `run_planner` is fed `prior_plan:` +
`transcript_tail:` but never the Judge's own reasoning for *why* it wanted
a replan (`session.rb:161-164`, `repl.rb:295-298`). A replan can regenerate
an equally vague plan and the Player can drift right back into the same
unproductive pattern, because the Planner was never told what specifically
went wrong.

## 2. Goals / non-goals

**Goals:**
- The Judge sees what it decided at previous checkpoints in *this* session
  before deciding again.
- Recurring, non-progressing action patterns (not just "off-plan" or
  "dangerous" ones) get surfaced to the Judge as a concrete signal, not
  something it has to notice by re-reading prose.
- A mechanical backstop exists for the exact failure observed — an LLM
  that keeps saying `continue` about the same loop — independent of
  whether the LLM's own reasoning improves. This is deterministic code,
  not another model call grading the first model's call.
- A `replan` carries forward *why*, so the new plan has a chance of
  actually avoiding the pattern that triggered it.

**Non-goals (out of scope for this doc):**
- Cross-session memory (a Judge that remembers "last time this character
  played, begging didn't work either"). `WorldKnowledge`
  (`lib/boukensha/world_knowledge.rb`) is the natural home for that kind of
  persistent, queryable fact if it's ever built — see §8.
- A fourth verdict value. `continue`/`replan`/`flag` stays the contract;
  this doc changes what evidence feeds that decision, not the decision's
  shape. (`evaluator.md`'s "Deferred" section already reserves richer
  verdict taxonomies for evidence-gated future work — this isn't that.)
- Changing checkpoint cadence (`Session.checkpoint?`) — unaffected.

## 3. `JudgeMemory` — new, driver-owned, in-process

A small object that accumulates one entry per checkpoint, owned by whoever
already owns checkpoint state today — `Boukensha::Session#play`'s local
`turns_since_checkpoint` and `Repl`'s `@turns_since_checkpoint`
(`repl.rb:97`). Not part of `Context`: `Context#plan` is *Player-facing*
state (rendered into `effective_system`, per `orchestrator.md` §2);
`JudgeMemory` is *Judge-facing* and must never leak into the Player's
prompt — keeping it a sibling of `turns_since_checkpoint` rather than a
`Context` field keeps that boundary the same way the throwaway
Judge-`Context`/live-Player-`Context` split already does.

```ruby
# lib/boukensha/judge_memory.rb
module Boukensha
  class JudgeMemory
    Entry = Struct.new(
      :turn, :stop_reason, :plan, :verdict, :reasoning,
      :repeated_actions, :overridden, keyword_init: true
    )

    def initialize(max_entries: 5)
      @max_entries = max_entries
      @entries     = []
    end

    def record(entry)
      @entries << entry
      @entries.shift while @entries.size > @max_entries
      entry
    end

    def entries = @entries.dup

    # Checkpoints since the plan text last changed — a cheap "how long has
    # this plan gone unchallenged" signal, independent of the LLM noticing.
    def checkpoints_on_current_plan(current_plan)
      streak = 0
      @entries.reverse_each do |e|
        break unless e.plan == current_plan
        streak += 1
      end
      streak
    end

    # Rendered for judge_input — see §4. Most recent last, so it reads like
    # a log, and stays within max_entries regardless of session length.
    def to_prompt_text
      return nil if @entries.empty?

      @entries.map do |e|
        tag = e.overridden ? " [mechanically overridden]" : ""
        "- turn #{e.turn} (#{e.stop_reason}): VERDICT=#{e.verdict}#{tag} — #{e.reasoning}"
      end.join("\n")
    end
  end
end
```

`max_entries: 5` mirrors `transcript_tail`'s own "bounded, not full
history" posture — same reasoning `evaluator.md` §2 already gives for
capping the transcript tail (keep the Judge call cheap, checkpoint-only
cost).

**Lifecycle:** `Boukensha::Session.play` constructs one `JudgeMemory.new`
per `.play` call (session-scoped, same lifetime as `ctx`/`logger`). `Repl`
constructs one in `#initialize` alongside `@turns_since_checkpoint = 0`
(`repl.rb:97`) and resets it wherever that counter already resets on
`/clear` (`repl.rb:157`) — a fresh quest should not carry forward memory of
a different quest's checkpoints, the same reasoning that already resets
`@planned`/`@turns_since_checkpoint` there.

## 4. What `run_judge` is fed: `judge_input` grows a history block

`Boukensha.run_judge` gains a `history: nil` kwarg (a `JudgeMemory`
instance; `nil` — the default — reproduces today's behavior exactly, so
existing callers/tests that don't pass it are unaffected). `judge_input`
(`lib/boukensha.rb:410-415`) grows a third part:

```ruby
def self.judge_input(plan:, transcript_tail:, history: nil, repeated_actions: nil)
  plan_text = plan.to_s.strip.empty? ? "(no plan set)" : plan
  parts = ["Current plan:\n#{plan_text}"]
  parts << "Recent transcript:\n#{transcript_tail}" if transcript_tail && !transcript_tail.to_s.strip.empty?
  if history
    history_text = history.to_prompt_text
    parts << "Your previous judgements this session (most recent last):\n#{history_text}" if history_text
  end
  if repeated_actions && !repeated_actions.empty?
    parts << "Repeated actions detected in the recent transcript (name×count): #{repeated_actions.map { |k, v| "#{k}×#{v}" }.join(", ")}"
  end
  parts.join("\n\n")
end
```

`prompts/judge/system.md` gets one added paragraph telling the Judge to
actually use this:

> You may also be given a log of your own previous verdicts this session,
> and a count of repeated actions in the recent transcript. If you already
> said `continue` about the same plan and the same action keeps repeating
> without new progress, that repetition — not just danger or a plan
> mismatch — is itself a reason to `replan`: the plan or the approach isn't
> working, even if nothing has gone wrong yet.

This directly targets the observed failure: "keeps asking for food/water,
nothing bad is happening, plan is technically still 'find food'" is exactly
the case where `continue` kept winning because neither danger nor
plan-mismatch was ever true. Repetition becomes its own signal.

## 5. Repeated-action detection — deterministic, not another LLM call

A helper alongside `transcript_tail` (same file, same "read `ctx.messages`,
render something small" shape) that scans the **structured** tool-use
blocks in the Player's live `Context` — not the text-joined tail
`transcript_tail` produces, which has already lost the args needed to tell
two calls apart:

```ruby
# player_context: the Player's live Context (already passed to run_judge
# for tool reuse, lib/boukensha.rb:361/383) — read-only here too.
def self.repeated_tool_calls(player_context, window: 20, min_count: 3)
  calls = player_context.messages.last(window).flat_map do |m|
    next [] unless m.role == :assistant && m.content.is_a?(Array)
    m.content.select { |b| b[:type] == "tool_use" }
             .map { |b| "#{b[:name]}(#{b[:input].to_a.sort.map { |k, v| "#{k}: #{v}" }.join(", ")})" }
  end
  calls.tally.select { |_, count| count >= min_count }
end
```

Exact shape of `m.content`'s tool_use blocks should be checked against
`Agent#handle_tool_calls` (`agent.rb`) rather than assumed — written above
to match the `{type:, name:, input:}` shape the Anthropic-style backend
already produces elsewhere in this codebase, but confirm against the real
message structure before implementing.

`window: 20` matches `transcript_tail`'s own default so the two stay
consistent about "how far back is 'recent'"; `min_count: 3` is a starting
guess (three repeats of the identical tool+args before it's flagged as a
loop, not two — avoids flagging a legitimate short retry). Both are
tuning knobs, not fixed constants — expose them as `tasks.judge.repeated_action_window`/
`tasks.judge.repeated_action_threshold` in `settings.yaml`, same pattern
`tasks.judge.max_iterations` already uses.

`Session#play`/`Repl#maybe_check_judge` compute this once per checkpoint
and pass it to both `run_judge` (as the injected signal, §4) and the
mechanical override (§6) — one computation, two consumers.

## 6. Mechanical override: the actual fix for "Judge keeps saying continue"

Feeding history and repeated-action counts into the prompt (§4-§5) makes
the *LLM* more likely to notice — but the original failure was specifically
an LLM that didn't notice a pattern sitting right in front of it. Prompting
harder is not a fix for that class of failure by itself. Add a
deterministic override applied to the parsed verdict, inside `run_judge`,
after `parse_verdict` and before the value is returned/logged:

```ruby
verdict = parse_verdict(text)
overridden = false

if verdict == :continue && repeated_actions && !repeated_actions.empty?
  verdict    = :replan
  overridden = true
end

logger.judge_verdict(verdict: verdict, text: text, task: task_class.task_name, overridden: overridden)
```

If any action repeated at least `min_count` times in the window and the
LLM still said `continue`, the driver receives `:replan` regardless — this
is the concrete, deterministic guarantee that "player keeps begging NPCs
with the Judge saying continue every time" cannot recur silently, whatever
the LLM decides. It never escalates a `continue` all the way to `flag`
mechanically — a repeated-but-not-dangerous pattern warrants a new plan,
not stopping the session for human review; `flag` stays an LLM (or
genuinely repeated-*replan*, see below) call.

`history` entries record `overridden: true` on those checkpoints (`Entry`
in §3) so the rendered history (§4) is honest with the Judge about its own
past overrides, and `Logger#judge_verdict` (`logger.rb:118-119`) gains the
same `overridden:` field so `log_viz`/OTEL can distinguish "the Judge
itself called this" from "the deterministic guard called this" — matters
for Phase 5's validation work
([`implementation_plan.md`](implementation_plan.md)), which explicitly
wants to know whether Judge verdicts track what a human reviewer would
also flag; conflating LLM judgement with a mechanical override would
corrupt that comparison.

**Second-order escalation:** if `checkpoints_on_current_plan` (§3) shows
the plan has *already* been replanned into and the same repeated-action
signal fires again against the *new* plan too, escalate to `:flag` instead
of `:replan` — a second replan that doesn't fix the pattern is the "human
should look at this" case `evaluator.md` §5's `flag` row already describes,
not another automatic replan. Concretely: override to `:flag` when
`overridden` would otherwise fire **and** the most recent history entry's
`verdict` is already `:replan`.

## 7. Replan carries the reason forward

`run_planner`'s replan call (`Session#play` line 161-164, `Repl#maybe_check_judge`
line 295-298) currently passes `prior_plan:` + `transcript_tail:` only.
Add a `replan_reason:` kwarg threaded through from the Judge's own
reasoning text (`Boukensha.verdict_reasoning(verdict[:text])`, already
computed for display in `Repl`) plus, when present, the repeated-actions
signal:

```ruby
reason = Boukensha.verdict_reasoning(verdict[:text])
reason += "\n\nRepeated actions that triggered this replan: #{repeated_actions.map { |k, v| "#{k}×#{v}" }.join(", ")}" if verdict[:overridden]

plan = Boukensha.run_planner(
  goal: goal, prior_plan: ctx.plan, transcript_tail: ...,
  replan_reason: reason, logger: logger, ...
)
```

`planner_input` (`lib/boukensha.rb:316-319`) grows a matching line:
`parts << "Why the prior plan is being replaced:\n#{replan_reason}" if
replan_reason...`. This is the piece that actually closes the loop the
user's report describes — without it, a `:replan` verdict (mechanical or
not) can still regenerate a similarly vague "find food" plan and the
Player drifts back into begging; with it, the new plan is explicitly told
"begging NPCs repeatedly wasn't working," which gives it something concrete
to route around (try a shop, a different NPC type, a different room).

## 8. Deferred / out of scope

- **Cross-session memory.** `JudgeMemory` as designed here is
  per-`Session#play`/per-`Repl` process lifetime, gone when the process
  exits — matches the observed bug, which was within one long session, not
  across restarts. If a future need shows up for "this character has a
  known-bad pattern that should be remembered next time they play,"
  `WorldKnowledge`'s SQLite-backed, cross-session surface
  (`lib/boukensha/world_knowledge.rb`) is the natural extension point — out
  of scope here, don't build it speculatively.
- **A general "efficiency" verdict/score.** This doc treats repeated
  non-progressing actions as a `replan` trigger, not a new scored
  dimension the Judge reports every checkpoint. A richer efficiency metric
  (turns-per-goal, tokens-per-checkpoint) already exists as *validation*
  tooling (`implementation_plan.md` Phase 5's before/after comparison) —
  don't duplicate it as a per-checkpoint Judge output until evidence shows
  the binary "repeated or not" signal here is insufficient.
- **Structured tool-call extraction beyond the heuristic in §5.** Exact
  message content shapes should be verified against `Agent#handle_tool_calls`
  before implementing — flagged there, not re-solved here.
- **Tuning `min_count`/`window`/`max_entries`.** Starting values are
  guesses grounded in existing conventions (`transcript_tail`'s `last: 20`,
  `Tasks::Judge::DEFAULT_MAX_ITERATIONS`'s "keep it small" posture) — adjust
  from real session logs once this ships, the same evidence-gated posture
  the rest of this plan set already takes with e.g. `Tasks::Navigator`.

## Acceptance criteria

- A fixture session with 3+ checkpoints, each with the LLM Judge stub
  scripted to return `VERDICT: continue`, and the Player's transcript
  scripted with the same tool call repeated ≥3 times in the window: the
  *driver* (`Session#play`/`Repl`) ends up with `:replan`, not `:continue`,
  and `Logger#judge_verdict`'s `overridden:` field is `true` for that
  checkpoint.
- The same fixture, run again after that replan, with the new plan and
  transcript still showing the identical repeated action: driver ends up
  with `:flag`, not another silent `:replan` loop.
- `judge_input`'s rendered text, spot-checked via a logged request payload,
  contains prior checkpoints' verdicts/reasoning (history) and the
  repeated-action counts when a `JudgeMemory`/`repeated_actions` are
  passed; with both `nil` (the default), the payload is byte-identical to
  today's — a direct regression test, same style as `worker.md`'s
  effective_system acceptance criterion.
- `run_planner`'s request payload on a replan includes a "why the prior
  plan is being replaced" line derived from the Judge's reasoning when
  `replan_reason:` is passed; omitted entirely when it's `nil` (unrelated
  replan paths, if any ever exist, stay unaffected).
- `/clear` in `Repl` resets `JudgeMemory` the same turn it resets
  `@turns_since_checkpoint`/`@planned` — assert a post-`/clear` checkpoint's
  `judge_input` contains no pre-`/clear` history.
- Existing `test_run_judge.rb`/`test_session.rb`/`test_repl_judge.rb`
  suites pass unmodified where they don't pass the new kwargs — confirms
  this is additive, not a breaking change to the existing verdict contract.
