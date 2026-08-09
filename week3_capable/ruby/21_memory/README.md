# Step 21 - Memory

Branched from `20_navigator` (stays the source of truth for everything
carried forward unchanged: context/token management, the TUI, the MCP-host
tool model, multi-player support, MUD response compaction, OpenTelemetry
traces/metrics, per-task tool policy, the Planner/Player/Judge/Navigator
agentic loop, and `world__room_knowledge`/`world__route_to` — see that
step's README). This step adds a per-player memory that survives across
separate play sessions: a fifth agent-as-tool sibling to Planner/Player/
Judge/Navigator, `Tasks::Chronicler`, reflects on how a session went and
rewrites that character's private notes, which the Planner (and only the
Planner) reads back in on the next session. Wired into both drivers that
can log in as a player: `Session.play` (the play-by-itself loop) and the
interactive `boukensha --player NAME` REPL. Full design/rationale:
[`docs/plans/memory/player_memory.md`](../../../docs/plans/memory/player_memory.md).

## What's new in this step

### `Boukensha::PlayerMemory` — one player's cross-session store

`lib/boukensha/player_memory.rb` is the new, separate persistence layer this
step's plan calls for — not `world_map.sqlite3` (that's world facts, not a
character's own experience) and not `PlayerProfile` (that's static,
read-only identity config). Two files per player under
`.boukensha/memory/`: `<name>.jsonl` (append-only, one line per finished
`Session.play` run — goal, outcome, that session's checkpoint history) and
`<name>.md` (a small, bounded prose digest — the only one of the two ever
read back into a prompt). `PlayerMemory.load(name, memory_dir:)` never
constructs anything shared between two different names — two players'
files never cross-contaminate, even against the same `memory_dir:`.

### `Tasks::Chronicler` — reflection, zero tools by design

`lib/boukensha/tasks/chronicler.rb` mirrors `Tasks::Planner`'s shape
exactly, but with no `tasks.chronicler.tools` block in `settings.yaml` at
all — `Tasks::Base.tool_policy`'s deny-by-default means it can never call
`world__room_knowledge`, `consult_navigator`, or any `tbamud__*` command.
This is the literal enforcement of the project goal's own framing: "tools
are just tools and world knowledge are just helpers/info, they are not
considered memory/experience." `Boukensha.run_chronicler` mirrors
`run_planner`'s shape, minus tools and minus an `mcp:` parameter — unlike
every other `run_*` sibling, it is never handed the session's live MCP
connections at all, so there's nothing to dispatch even if a tool somehow
got past the policy.

```ruby
Boukensha.run_chronicler(
  goal: "explore the temple square", outcome: "Completed: found the temple.",
  checkpoints: judge_memory.entries, prior_digest: memory.digest_text, logger: logger
)
# -> "Discoveries\n- The priest mentions a hidden passage if asked about the temple.\n..."
```

### Memory reaches the Player only through the Planner

`Boukensha.run_planner`/`planner_input` gain a `player_memory:` kwarg, one
more block folded into the Planner's own request alongside `prior_plan:`/
`replan_reason:`/`transcript_tail:` — never a second channel straight into
the Player's system prompt. The Player's own prompt is completely
untouched; whatever the Planner does with old lessons shows up, if at all,
inside `ctx.plan` the same way a replan's reasoning already does.

### `Session.play` writes memory — checkpoint by checkpoint, not at session end

`lib/boukensha/session.rb`, all of it a no-op unless both
`memory.enabled: true` and a `player:` were given:

- Before the first Planner call, `PlayerMemory.load` resolves this
  player's prior digest (`nil` for a brand-new character), threaded into
  every `run_planner` call (initial seed and every replan).
- Memory is chronicled **live**, not saved up for the end of the session — a
  self-managed run can keep going until a big goal is done (or the cost cap
  is hit), which can mean the entire session, so waiting until then to learn
  anything defeats the point. Instead, a `flush_memory` step runs
  immediately on every Judge **`:replan`** verdict, *before* that replan's
  own `run_planner` call — so the replanned plan already reflects what was
  just learned — and on every **`:flag`** verdict too. It's gated by the
  same "only when there was something notable to learn" rule as before (at
  least one non-`:continue` checkpoint since the last flush); a session
  where every checkpoint says `:continue` never triggers a write. Because
  every non-`:continue` verdict is handled by one of those two live call
  sites, there's nothing left to flush once the loop exits — the old
  end-of-session write is gone.
- Each flush both appends a raw JSON record and calls
  `Boukensha.run_chronicler` to update the saved digest via
  `PlayerMemory#save_digest`, wrapped in a `rescue StandardError` — a broken
  Chronicler backend degrades to "this checkpoint's lesson isn't captured,"
  never to a failed session. The raw JSON record itself is plain file I/O
  and is never skipped by that rescue.
- The Judge's own cross-checkpoint history (`judge_memory`, used as
  `history:` on every `run_judge` call) is a *separate*, untouched
  accumulator from the one memory flushes read and reset — flushing never
  erases what the Judge itself remembers about this session.

`Session.play` also grew `chronicler_model:`/`chronicler_backend:`/
`chronicler_api_key:`/`chronicler_ollama_host:` overrides, mirroring the
`planner_*`/`judge_*`/`navigator_*` kwargs it already had.

### `Repl` (the real `boukensha --player NAME` path) writes memory too

The plan doc originally deferred this ("Repl has no single well-defined
session end the way `Session.play`'s loop does") — that gap is now closed,
and (like `Session.play` above) memory is chronicled live rather than only
at a boundary. `Repl` takes the same `player:`/`chronicler_*:` kwargs as
`Session.play`, builds its own `PlayerMemory` at construction time the same
way, and feeds `player_memory:` into every `run_planner` call (the initial
seed and any Judge-triggered replan). A Judge **`:replan`** verdict calls
`Repl#flush_memory!(:replan, outcome:)` immediately, before that replan's own
`run_planner` call, exactly mirroring `Session.play`. Since a human can also
keep one REPL process running indefinitely, `/clear` and `/exit` (or
EOF/Ctrl-D) remain a catch-all boundary on top of that — `flush_memory!`
runs there too, for a `:flag` (which doesn't stop the REPL by itself — same
"print a note, don't halt" posture `repl_judge_integration.md` already
established) or any trailing checkpoint that hasn't triggered a replan of
its own yet. `Boukensha.repl` also calls `flush_memory!(:exit)` in its own
`ensure`, as a safety net for an exit path outside `Repl`'s own control
(e.g. Ctrl-C); `flush_memory!` resets its own pending-checkpoint tracking
once it fires (leaving `@judge_memory`'s own cross-checkpoint history
untouched — see `Session.play` above), so a repeat call is a no-op if
`/exit` or EOF already flushed. The banner shows `memory: on for NAME` when
this is active.

`boukensha --player noir` with `memory.enabled: true` now behaves like the
design doc's goal, and better: a replan mid-session already reflects the
lesson from the checkpoint that triggered it, and playing a while, `/clear`
or `/exit`, and coming back later as the same character still means the
Planner's next plan can say "what you've learned about this character from
past sessions."

### `memory.enabled` — opt-in, same posture as the compactor's Tier 2

`Config#memory_enabled?`/`#memory_dir` read a new `memory:` block, defaulting
**off** — an LLM-authored digest that's wrong doesn't just waste tokens, it
can actively steer a future session's plan in the wrong direction. Same
"ship it real but off until a few real sessions' digests have been read and
look sane" posture `tasks.compactor.enabled` already established.

```yaml
memory:
  enabled: false   # opt-in until evaluated
  # dir: memory    # relative to .boukensha/, default shown

tasks:
  chronicler:
    provider: openai
    model: gpt-5.4-mini      # cheap/fast — one reflective rewrite, not open-ended play
    max_output_tokens: 600   # a short digest, not a transcript
    # Deliberately no tools: block.
```

### `prompts/chronicler/system.md`

Rewrite instructions under four headers (Discoveries, Mistakes, Strategies,
Open threads), told explicitly to revise and condense existing notes rather
than append to them, and to never record room exits/layout — that's tracked
elsewhere. Output is plain text only, read back verbatim next session as
"your existing notes."

## Install

```sh
cd week3_capable/ruby/21_memory
bundle install
```

Prerequisites: unchanged from `20_navigator` — a `mud-manager` MCP server on
`PATH`, `.boukensha/players/*.yaml` character profiles, `log_viz` on `PATH`
for `world__room_knowledge`/`world__route_to`, and optionally a local Ollama
daemon.

## Build

```sh
gem build boukensha.gemspec
gem install boukensha-0.21.0.gem
```

Installs the `boukensha` executable. `~/.boukensharc`'s `boukensha_path`
must point at this step's directory for it to run this step's code — see
`lib/boukensha_loader.rb`'s header comment.

## Run

Memory needs both `memory.enabled: true` in `settings.yaml` and a
`--player`/`player:` given — either driver (`Session.play` or the
interactive `boukensha --player NAME` REPL) constructs nothing at all
without both.

```sh
boukensha --player noir
```

Play for a while, hit at least one Judge `:replan`/`:flag` checkpoint,
then `/clear` or `/exit`. Log back in as the same character later and the
Planner's plan (printed to stderr as "(planning...)" resolves) will include
a "What you've learned about this character from past sessions" block. The
banner also shows `memory: on for noir` (or `(no notes yet)` the first
time) whenever this is active.

`Session.play` (the play-by-itself driver, e.g. `examples/session_demo.rb`)
works the same way, without needing a `/clear`/`/exit` — a session's own
natural end (completion, `max_turns`, or a Judge flag) is already a clear
boundary there.

## Tests

```sh
rake test
```

New coverage for this step: `test_player_memory.rb` (digest/raw-record
round-tripping, missing-file defaults, and the isolation guarantee that two
different player names sharing a `memory_dir:` never cross-contaminate);
`test_tasks_chronicler.rb`/`test_run_chronicler.rb` (task name, prompt
resolution, deny-by-default tool policy, request assembly, and that the
request payload it sends carries zero tools — mirrors
`test_tasks_planner.rb`/`test_run_planner.rb`); `test_config_memory.rb`
(`memory_enabled?`/`memory_dir` default and override coverage);
`test_session_memory.rb` (a flagged session writes exactly one raw record
plus the scripted digest; a session with no notable checkpoint writes
nothing at all; a prior digest reaches the Planner's request payload; a
replan flushes memory live and the *replanned* Planner request itself
already carries the freshly chronicled digest, not just the session-start
one; a failing Chronicler leaves the digest file untouched and doesn't
affect the session's own result; and `memory.enabled: false`/no `player:`
reproduce pre-memory `Session.play` behavior exactly); and
`test_repl_memory.rb` (the same replan-flushes-before-the-replanned-Planner-
call case through `Repl`, plus `/clear`/`/exit` boundary coverage for a
`:flag` that never triggered a replan, and the prior-digest-reaches-the-
Planner case for the REPL's own first-turn seeding).

## Not doing (this step)

Carried over from `player_memory.md`'s "Deferred / out of scope" section —
flagged, not designed:

- **Splitting `memory.enabled` into two flags** (an always-on free raw
  record vs. a separately-toggled LLM consolidation) — a plausible
  refinement, not built speculatively.
- **Feeding memory to the Judge or the Player directly** — memory stays
  Planner-only, matching the existing Player/Planner boundary.
- **A `log_viz` "Memory" viewer tab** for a human to read a player's digest
  and raw session records — `PlayerMemory#session_records` already returns
  viewer-ready data, but the UI work is out of this plan's scope.
- **Automatic digest re-derivation from the full raw record** (rebuild a
  digest from scratch across every `session_records` entry, e.g. after
  improving the Chronicler's prompt) — the raw JSONL exists specifically as
  this recovery path, but no such tool is built here.
