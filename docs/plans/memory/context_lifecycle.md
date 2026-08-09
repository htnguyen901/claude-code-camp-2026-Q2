# Context lifecycle — the Player's request payload never shrinks after a checkpoint

Debugging note: the expectation was that once a Judge verdict has been
rendered, a replan (if any) has produced a fresh `ctx.plan`, and the
Chronicler has distilled anything notable into this player's saved memory
digest, the raw tool-call transcript that led to that checkpoint has already
served its purpose — so the next request payload shouldn't need to keep
carrying it in full. Traced end to end: it does keep carrying it. This doc
explains why and proposes a fix.

**Depends on:** [`../agent_loop/player_route_adherence.md`](../agent_loop/player_route_adherence.md)
§3b (`Context#route`) — see §3a below for why this doc's own fix must land
*after* that one, not before or independently. **Related:**
[`player_memory.md`](player_memory.md)'s "checkpoint-triggered flush"
revision, which this doc's §3b design deliberately mirrors.

## 0. What actually happens, traced through the code

`Session.play`'s loop (`lib/boukensha/session.rb:207-279`) reuses the *same*
`ctx` object for every turn of the whole session — `ctx.messages` is one
array that only ever grows (`Agent#run`'s `@context.add_message` calls,
`lib/boukensha/agent.rb`) across turns and checkpoints alike. `Repl`'s
self-managed loop (`lib/boukensha/repl.rb`, `maybe_continue_self_managed` /
`maybe_check_judge`) shares the same shape against `@context`.

The only thing that ever removes messages from that array automatically is
`Context#compact_messages!` (`lib/boukensha/context.rb:75-81`), and it fires
from exactly one place: `Agent#compact_if_needed`
(`lib/boukensha/agent.rb:123-129`), called once at the top of `Agent#run`,
gated purely by `Context#needs_compaction?` — `usage_fraction >=
compaction_threshold` (default 0.85 of the context window,
`Config#agent_compaction_threshold`). This is a token-budget mechanism only;
it has no idea what a Judge checkpoint, a replan, or a Chronicler flush is.

Walking the Judge-verdict branches (`session.rb:247-271`) and the Chronicler
flush (`session.rb:182-205`, the `flush_memory` lambda) confirms neither one
ever calls `compact_messages!` or `clear_messages!`
(`lib/boukensha/context.rb:84-87`). `clear_messages!` exists at all only
because `Repl`'s human-typed `/clear` command calls it (`repl.rb:324`) —
there is no automatic call to it, or to `compact_messages!` outside the
85%-threshold path, anywhere in either driver.

Concretely: a session that runs 10 turns and hits 3 checkpoints (2 replans
and a flag) sends the *entire* 10 turns' worth of tool calls and results in
the request payload on turn 10, verbatim — the same content turn 1's payload
had, just longer. The Planner's fresh plan and the Judge's fresh verdict get
appended on top of that history, never substituted for the part of it they
already rendered obsolete.

## 1. Why this matters

- **Cost, and it compounds.** Every subsequent request re-sends and
  re-bills input tokens for tool calls/results that already fully served
  their purpose. `session.max_cost_usd` (`.boukensha/settings.yaml`) is a
  hard cap on the whole session — an ever-growing payload burns through it
  faster per turn the longer the session runs, so a self-managed session
  gets *fewer* Player turns for the same remaining budget late in a run than
  it did early on, not a constant rate.
- **Signal dilution.** The Player (`gpt-5.4-mini`,
  `tasks.player.model`) has to locate what's currently relevant — its system
  prompt, `ctx.plan`, whatever it should be doing right now — inside a
  growing haystack of now-superseded tool-call noise from before the last
  replan. This is a plausible contributing factor to
  [`../agent_loop/player_route_adherence.md`](../agent_loop/player_route_adherence.md):
  a route the Player already abandoned two replans ago, still sitting in
  context, is exactly the kind of stale material most likely to compete with
  what's actually current.
- **Compaction, when it eventually fires, is also blind to checkpoints.**
  `compact_messages!`'s "drop the oldest 40%" has no notion that a replan
  happened at message 40 — it might drop up to message 48, keeping half of
  one now-irrelevant pre-replan exchange and none of the other half, with no
  relationship to "this is where the new plan started mattering."

## 2. A second, independent bug found while tracing this

`compact_messages!` drops purely by array index/count
(`@messages.drop(drop_count)`, `context.rb:78`), with no awareness that some
messages are a `tool_use`-bearing `:assistant` message paired with one or
more `:tool_result` messages carrying its `tool_use_id`
(`Agent#handle_tool_calls`, `agent.rb:193-239`: one assistant message with
tool_use blocks, followed by one tool_result message per call). If
`drop_count` lands inside such a pair — dropping the assistant tool_use
message but keeping its tool_result(s), or the reverse — the next request
payload contains an orphaned tool_result whose `tool_use_id` has no matching
call in the same conversation, which every backend this project supports
(`backends/anthropic.rb`, `openai.rb`, `gemini.rb`) is likely to reject as
malformed. No existing test guards against this — `test/test_context_plan.rb`
covers only "the plan survives compaction," and there is no `test_context.rb`
exercising `compact_messages!` itself. This is a real correctness bug
independent of the checkpoint-timing question in §0-1, live today at the
85%-threshold path; any redesign of trimming here should fix it, not just
relocate it into a new call site.

## 3. Proposed design

### 3a. Prerequisite: durable state has to live outside `@messages` first

Any checkpoint-triggered trim of `@messages` is only safe once nothing
load-bearing lives solely inside a message that trimming could remove.
`ctx.plan` already satisfies this — it lives in `@system`, via
`effective_system`, never in `@messages`. `ctx.route`, proposed in
[`../agent_loop/player_route_adherence.md`](../agent_loop/player_route_adherence.md)
§3b, extends the same guarantee to an in-progress Navigator route. §3b/§3c
below assume both exist; **sequence this doc's implementation after that
one**, not in parallel — shipping checkpoint-triggered trimming first would
make that doc's §1c failure mode (a route silently forgotten by compaction)
fire more often, not less.

### 3b. Checkpoint-triggered trim (mechanical, always on)

Mirrors [`player_memory.md`](player_memory.md)'s own "checkpoint-triggered
flush" revision, for the identical reason: waiting for a boundary that might
never cleanly arrive (`max_turns`, a crash) leaves value on the table — in
that doc's case, un-captured lessons; in this one, un-trimmed waste, for the
rest of the session. Add a trim call immediately after each `:replan`'s new
plan is set and after a `:flag`'s `flush_memory` call
(`session.rb`, the `case verdict[:verdict]` block at `:247-271`; mirrored in
`repl.rb`'s `maybe_check_judge`) — i.e., exactly the two call sites
`flush_memory`/`flush_memory!` already fire from, since those are already
"something notable just got distilled elsewhere" boundaries. `:continue`
stays a no-op, same as today: a checkpoint where nothing changed isn't a
reason to trim, and trimming on every checkpoint (including uneventful ones)
would fight the 85%-threshold compaction's own job of only firing under real
pressure.

The trim should not drop everything since the start of the session — the
current turn's own in-progress exchange (whatever led to this checkpoint)
plus a small fixed tail (mirrors `Boukensha.transcript_tail`'s own `last: 20`
window, already used to build the Judge's input, `lib/boukensha.rb:581`)
should survive, so the Player doesn't lose the thread of what it was doing
immediately before the plan changed under it.

### 3c. Pairing-safe trimming (fixes §2; applies to both the existing 85%-threshold path and the new checkpoint-triggered path)

Replace `compact_messages!`'s blind `@messages.drop(drop_count)` with a
boundary-aware version: compute the drop count as today, then adjust it to
the nearest point that isn't inside a `tool_use`/`tool_result` group — never
separate an `:assistant` message carrying `tool_use` blocks from every
`:tool_result` message whose `tool_use_id` it produced; round the cut to the
enclosing group's boundary instead of an arbitrary array index. This is a
correctness fix independent of whether §3b ships — §2's bug is live today at
the 85% threshold — so it should land regardless.

### 3d. Deferred: LLM-summarized trim instead of blind drop

A further improvement — replace "drop the oldest N" with "replace the oldest
N with a short LLM-authored recap" — mirrors the two-tier shape this
codebase already uses elsewhere (`Compactor`'s Tier 0/always-on vs. Tier
2/opt-in, `lib/boukensha/compactor.rb`; `memory.enabled`'s own
evidence-gated posture, `player_memory.md` decision 5). Plausible follow-up,
not required here: §3b+§3c (mechanical, checkpoint-timed, pairing-safe)
already close both concrete problems in §0-2 without adding a new LLM call's
cost and failure mode to every checkpoint. Revisit only if real sessions
show the blind-drop trim is losing something the Player still needed.

## Acceptance criteria

- A fixture `Session.play` run (mirrors `test_session.rb`/
  `test_session_memory.rb`'s existing scripted-Player/scripted-Judge
  pattern) where the Judge returns `:replan` at turn 3: `ctx.messages` size
  immediately after the replan is smaller than immediately before it, and
  turn 4's request payload (spot-checked, same style as this doc set's other
  payload-content acceptance criteria) omits the raw tool_result content
  from before turn 3's checkpoint.
- Same fixture shape, `:continue` verdict: `ctx.messages` is untouched — a
  direct regression test that an uneventful checkpoint trims nothing.
- A fixture asserting a checkpoint trim never separates a tool_use-bearing
  assistant message from its own tool_result(s): construct a scripted
  transcript where the naive drop count would land mid-pair, assert the
  actual cut moves to the group boundary instead.
- A fixture for `compact_messages!` itself (new `test/test_context.rb`, the
  85%-threshold path, no checkpoint involved) asserting the same
  pairing-safety property — confirms §2's bug is fixed at the source, not
  merely avoided by the new §3b call sites.
- `ctx.plan` (and `ctx.route`, once
  [`../agent_loop/player_route_adherence.md`](../agent_loop/player_route_adherence.md)
  ships) still survive a checkpoint trim exactly as they already survive
  `compact_messages!` today — direct extension of `test_context_plan.rb`'s
  existing coverage.
- With no Judge configured (checkpointing never fires), a `Session.play`
  run's message growth and final payload size are unchanged from today —
  confirms this is additive to sessions that don't use the Judge, not a
  behavior change for them.

## Files touched

- `lib/boukensha/context.rb` — pairing-safe trim logic (§3c), shared by both
  the existing 85%-threshold path and the new checkpoint-triggered call.
- `lib/boukensha/session.rb` — trim call at the `:replan`/`:flag` branches,
  alongside the existing `flush_memory` calls.
- `lib/boukensha/repl.rb` — same, in `maybe_check_judge`.
- `test/test_context.rb` — new; `compact_messages!` pairing-safety coverage
  (§2/§3c) — no file by this name exists today.
- `test/test_session_memory.rb` (or a new `test_session_context_trim.rb`) —
  checkpoint-triggered trim fixtures (§3b acceptance criteria).
- `test/test_repl_memory.rb` (or equivalent) — `Repl`-side mirror.

## Deferred / out of scope

- §3d (LLM-summarized trim) — ship the mechanical fix first, evaluate before
  adding a fancier layer; same evidence-gated posture as
  `tasks.compactor.enabled`/`memory.enabled`.
- Any change to the 85%-threshold trigger itself
  (`agent_compaction_threshold`) — orthogonal; this doc adds a second
  trigger, it doesn't retune the existing one.
- Automatic trimming on `Repl`'s non-self-managed (human-driven) path beyond
  what `maybe_check_judge` already covers — a human already has `/clear` and
  manual compaction control there (`repl.rb:324`, `:336`); this doc's
  automatic trim targets the checkpoint boundary specifically, not a general
  replacement for manual control.

## Open questions

- Should a checkpoint trim also fire on `Session.play`'s outer `max_turns`
  exit, or `Repl`'s `WIND_DOWN_INSTRUCTION` path — i.e., is the last leg
  before a session ends worth trimming for a payload nothing reads again?
  Leaning no; flagging for confirmation before implementation.
  A: if memory is not saved/updated by chronicler yet then don't trim because Agents still likely need those memory/context
- Exact tail size to preserve across a checkpoint trim (§3b) — proposed
  reusing `transcript_tail`'s `last: 20`, but that number was tuned for
  "enough for the Judge to read," not "enough for the Player to keep
  continuity." May need its own tuning pass once real sessions are observed.
