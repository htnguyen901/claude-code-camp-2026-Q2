## Goal

I need a way to store and serve player's memory. In the real world, the more I play the game the more I know about it. I could learn from my discoveries, my mistakes, my trials; may not be all the details and everything but should learn along the way. The player should mimic this too. It should have a memory (by player not shared). Tools are just tools and world knowledge are just helpers/info, they are not considered 'memory/experience'. 

So please help me design a memory system and flow that's suitable for this project and this specific use-case of this project - To have Agent play the game by itself and accomplised complex tasks/quests

---

## Research findings

- **Nothing today persists a lesson across separate `boukensha` processes.**
  Every state object that looks memory-shaped is scoped to one process or one
  call: `Context` (`lib/boukensha/context.rb`) lives and dies with one
  `boukensha`/`Session.play` invocation; `JudgeMemory`
  (`lib/boukensha/judge_memory.rb`) is explicitly "gone when the process
  exits" per its own design doc
  (`docs/plans/agent_loop/evaluator_judge_redesign.md` §8, which even names
  this exact gap and defers it: *"If a future need shows up for 'this
  character has a known-bad pattern that should be remembered next time they
  play,' `WorldKnowledge`'s SQLite-backed, cross-session surface is the
  natural extension point — out of scope here, don't build it
  speculatively."* This doc is that future need, being addressed on purpose.
- **...but `WorldKnowledge`/`world_map.sqlite3` is the wrong extension
  point for it**, and the goal statement above says so directly: "tools are
  just tools and world knowledge are just helpers/info, they are not
  considered memory/experience." That's also consistent with how the rest of
  this codebase already treats `world_map.sqlite3` —
  `docs/plans/observability/players/multiple_concurrent_players.md` states
  plainly that the World Map "belong[s] to and [is] only viewable to
  user/engineer/me," and its per-player scoping work (§2 of that doc) is
  about *what a room-facts query is allowed to answer*, not about anything
  resembling a lesson, strategy, or mistake. Room exits, item locations, and
  examination results are objective facts about the world; what this doc
  needs to store is the Player's own subjective take on what worked, what
  didn't, and what it's still trying to do — a different axis entirely, and
  one nothing in this codebase persists today.
- **`.boukensha/players/*.yaml` (`PlayerProfile`,
  `lib/boukensha/player_profile.rb`) is the existing per-character identity
  file, and already reserves a `persona:` block for exactly this kind of
  future work** (`docs/plans/observability/players/players_seeding.md`:
  "reserved for future agent-loop work; unused today"). It's read-only
  static config (name/password/class/persona), not a place anything writes
  to at runtime — the right sibling to put a *new*, separate, writable file
  next to, not the right place to bolt growing memory data onto.
  `PlayerProfile.load`'s pattern (one YAML file per character, keyed by
  name, aborts loudly on a missing file) is the template this doc's own
  loader follows.
- **The codebase already has a working precedent for "cheap deterministic
  layer always on, expensive LLM layer opt-in until evaluated"**: the MUD
  response compactor (`docs/plans/token_optimization/mud_response_compaction.md`,
  `lib/boukensha/compactor.rb`). Tiers 0/1 (ANSI stripping, structure-aware
  trim) always run, no config; Tier 2 (an LLM prose rewrite) is gated by
  `tasks.compactor.enabled`, **defaulting off** specifically because it's an
  unevaluated behavior change, per `Config#compactor_enabled?`'s own comment.
  `Boukensha.build_compactor` also demonstrates the fail-open posture for a
  configured-but-broken backend: warn and disable for this session, never
  abort the run. Both conventions apply directly to a memory-consolidation
  step that's also new, also LLM-driven, and also capable of injecting bad
  guidance into future play if wrong.
- **The Planner is already the layer that turns auxiliary context into a
  plan the Player actually sees**, and already accepts exactly this shape of
  input. `Boukensha.run_planner`/`planner_input`
  (`lib/boukensha.rb:310-361`) already assembles `goal:` + `prior_plan:` +
  `replan_reason:` + `transcript_tail:` into one user message; the Player
  itself never sees any of that directly, only `ctx.plan` rendered through
  `Context#effective_system` (`docs/plans/agent_loop/orchestrator.md` §2).
  That's the established boundary this doc should extend, not bypass:
  memory should reach the Planner as one more auxiliary input block, and
  reach the Player only however the Planner chooses to fold it into the plan
  text — not as a second channel straight into the Player's system prompt.
- **`Boukensha::Session.play` (`lib/boukensha/session.rb`) is the one
  driver built for "play by itself and accomplish complex tasks/quests"** —
  the goal's own framing. It already owns exactly the state this doc needs
  at exactly the right lifetime: `judge_memory` (a `JudgeMemory` accumulating
  one entry — turn, stop_reason, plan, verdict, reasoning, repeated_actions,
  overridden — per checkpoint for the whole session), the `goal` text, and
  the loop's own final `agent`/`turn`/`text` once it ends (natural
  completion, `max_turns` exhaustion, or a Judge `:flag`). Nothing needs to
  be reconstructed to get session-level signal — it already exists in
  memory (the Ruby kind) by the time `.play` returns. `Repl`'s interactive
  path has no equivalent single-session lifetime (a human can `/clear` and
  keep going indefinitely in one process), so it's a natural v2 rather than
  a day-one target — same "ship on `Session` first, retrofit `Repl` once the
  shape is proven" sequencing this repo already used twice for Planner and
  Judge (`repl_planner_integration.md`, `repl_judge_integration.md`).
- **Every new `Tasks::*` sibling in this codebase (`Planner`, `Judge`,
  `Navigator`) follows the identical shape**: a `Tasks::Base` subclass
  naming a `task_name`, a `Boukensha.run_<name>` module method building a
  throwaway `Context`/`Registry`/`Agent#run` loop, a `prompts/<name>/system.md`,
  and a `tasks.<name>:` block in `settings.yaml`. A memory-writing role fits
  this exact template — no new architectural pattern needs inventing, only
  one more instance of the existing one.

## Plan: `Tasks::Chronicler` + per-player memory files, feeding the Planner

### Decisions this plan makes

1. **A new, separate persistence layer — not `world_map.sqlite3`, not
   `PlayerProfile`, not `JudgeMemory`.** One new directory,
   `.boukensha/memory/`, sibling to `players/`, `sessions/`, and
   `world_map.sqlite3`, holding two files per player (§2). This is the
   direct, literal answer to "tools are just tools and world knowledge are
   just helpers/info, they are not considered memory/experience" — memory
   gets its own home precisely so it's never confused with either.
2. **Two files per player, not one — an append-only raw record and a
   bounded digest.** `.boukensha/memory/<name>.jsonl` (one line per
   completed `Session.play` run: goal, outcome, this session's checkpoint
   history) and `.boukensha/memory/<name>.md` (a small, bounded, prose
   digest — the only one of the two ever read back into a prompt). This
   mirrors the compactor's own two-tier shape (§ Research): the raw record
   is cheap, deterministic, and safe to always write once memory is on at
   all; the digest is the part an LLM produces and the part that can
   actually go wrong (drift, hallucinated "lessons"), so it's the one kept
   replaceable and inspectable as its own file rather than interleaved with
   raw data. It also means a future `log_viz` "Memory" tab (mirroring the
   `Players` tab `multiple_concurrent_players.md` already added) has a
   ready-made timeline to render, and a bad digest can always be
   regenerated from the raw record without losing history.
3. **One new task, `Tasks::Chronicler`, with zero tools by design.** Its
   only job is to read what already happened (the goal, the outcome, the
   session's `JudgeMemory` checkpoint history, and its own prior digest) and
   rewrite the digest — it never calls `world__room_knowledge`,
   `consult_navigator`, or any `tbamud__*` command. This is the mechanical
   enforcement of decision 1: giving it tools at all would blur exactly the
   line the goal statement draws between "helpers/info" and
   "memory/experience." `Tasks::Base.tool_policy` already denies everything
   by default when a task's `settings.yaml` entry has no `tools:` block
   (same default `Tasks::Planner` relies on) — the Chronicler simply never
   gets one.
4. **Memory reaches the Player only through the Planner, never directly.**
   `Boukensha.run_planner` gains a `player_memory:` kwarg (the digest text,
   or nil) folded into `planner_input` as one more block, exactly parallel
   to how `prior_plan:`/`replan_reason:`/`transcript_tail:` already work.
   The Player's own system prompt is untouched; whatever the Planner does
   with old lessons shows up, if at all, inside `ctx.plan` the same way a
   replan's reasoning already does. This preserves the existing
   Player/Planner boundary (`orchestrator.md` §2) instead of adding a
   second, competing channel into the Player's context.
5. **Gated by one new setting, defaulting off: `memory.enabled` (false).**
   Same posture and same reasoning as `tasks.compactor.enabled` (Research,
   above) — an LLM-authored digest that's wrong doesn't just waste tokens,
   it can actively steer a future session's plan in the wrong direction
   ("last time, attacking the rat swarm worked great" from a hallucinated
   digest is worse than no memory at all). Ship it real but off, turn it on
   once a few real sessions' digests have been read and look sane. When
   off, `Session.play` behaves exactly as it does today — no file I/O, no
   extra LLM call, `player_memory:` stays nil at every call site.
6. **No player, no memory — not a global fallback.** Unlike
   `world__room_knowledge`'s "no `--player` means unscoped, whole-map"
   behavior (a sensible fallback for objective world facts), there is no
   meaningful "memory shared by nobody in particular." A `Session.play` run
   with `player: nil` simply never constructs a `PlayerMemory` at all,
   regardless of `memory.enabled`. This is the isolation guarantee the goal
   asks for ("by player not shared") enforced structurally — there is no
   code path that reads or writes a memory file without a player name to
   key it by.
7. **Target directory: `week3_capable/ruby/21_memory`** — already exists as
   an untouched, byte-identical copy of `20_navigator` (scaffolded, not yet
   customized), continuing this curriculum's established "branch a new step
   folder, write its README" convention every prior step
   (`19_knowledge`, `20_navigator`) already used.

### 1. `Boukensha::Tasks::Chronicler`

Mirrors `Tasks::Planner` exactly — the simplest existing sibling, since like
the Planner (by default) it needs no tool-policy overrides and no
`max_iterations` tuning (zero tools means exactly one round trip regardless):

```ruby
# lib/boukensha/tasks/chronicler.rb
module Boukensha
  module Tasks
    # Reflects on one finished Session.play run and rewrites that player's
    # memory digest. Never given tools — it reasons over the goal, the
    # session's outcome, and its own prior digest, never the live game or
    # world_knowledge (see docs/plans/memory/player_memory.md decision 3).
    # No tasks.chronicler.tools block in settings.yaml -> Tasks::Base.
    # tool_policy denies everything, same default Tasks::Planner relies on.
    class Chronicler < Base
      def self.task_name = "chronicler"
    end
  end
end
```

`settings.yaml` addition:

```yaml
tasks:
  chronicler:
    provider: openai
    model: gpt-5.4-mini      # cheap/fast — one reflective rewrite, not open-ended play
    max_output_tokens: 600   # a short digest, not a transcript
    # Deliberately no tools: block — see decision 3.

memory:
  enabled: false   # opt-in until evaluated against real sessions — same
                   # posture as tasks.compactor.enabled, see decision 5.
  # dir: memory    # relative to .boukensha/, default shown
```

### 2. `Boukensha::PlayerMemory` — the storage class

New file, `lib/boukensha/player_memory.rb`, same loader shape as
`PlayerProfile.load` but read-write:

```ruby
require "json"
require "fileutils"

module Boukensha
  # One player's persistent, cross-session memory — .boukensha/memory/
  # <name>.jsonl (raw, append-only, one line per finished Session.play run)
  # and .boukensha/memory/<name>.md (the bounded digest, the only one of the
  # two ever read back into a prompt). See docs/plans/memory/
  # player_memory.md decisions 2 and 6 — never constructed without a player
  # name, never shared between two players' names.
  class PlayerMemory
    def self.load(player_name, memory_dir:)
      new(player_name, memory_dir: memory_dir)
    end

    def initialize(player_name, memory_dir:)
      @player_name = player_name
      @memory_dir  = memory_dir
    end

    # nil if no digest has ever been written for this player yet — a brand
    # new character's first session sees player_memory: nil end-to-end, the
    # same "byte-identical when the feature has nothing to say" posture
    # Context#effective_system already uses for a nil/blank plan.
    def digest_text
      return nil unless File.exist?(digest_path)

      text = File.read(digest_path).strip
      text.empty? ? nil : text
    end

    def save_digest(text)
      FileUtils.mkdir_p(@memory_dir)
      File.write(digest_path, text.to_s.strip)
    end

    # One line per finished Session.play run. record: a JSON-serializable
    # Hash (goal:, stop_reason:, turns:, checkpoints:, outcome:).
    def append_session_record(record)
      FileUtils.mkdir_p(@memory_dir)
      File.open(raw_path, "a") { |f| f.puts(record.merge(at: Time.now.utc.iso8601).to_json) }
    end

    # For a future log_viz "Memory" viewer, or manual digest re-derivation —
    # not on Session.play's hot path, which only ever needs digest_text.
    def session_records(last: nil)
      return [] unless File.exist?(raw_path)

      lines = File.readlines(raw_path)
      lines = lines.last(last) if last
      lines.map { |l| JSON.parse(l) }
    end

    private

    def digest_path = File.join(@memory_dir, "#{@player_name}.md")
    def raw_path    = File.join(@memory_dir, "#{@player_name}.jsonl")
  end
end
```

### 3. `Boukensha.run_chronicler` — mirrors `run_planner`'s shape, minus tools

```ruby
# lib/boukensha.rb
def self.run_chronicler(
  goal:, outcome:, checkpoints:, prior_digest: nil,
  logger:,
  model:             nil,
  backend:           nil,
  api_key:           nil,
  ollama_host:       "http://localhost:11434",
  max_output_tokens: nil
)
  cfg           = config
  task_class    = Tasks::Chronicler
  task_settings = cfg.tasks(task_class.task_name)
  system        = task_class.system_prompt(task_settings, user_prompts_dir: cfg.user_prompts_dir, default_prompts_dir: Config::PROMPTS_DIR)
  model       ||= task_class.model(task_settings)
  backend     ||= task_class.provider(task_settings).to_sym
  api_key     ||= resolve_api_key(backend)
  max_output_tokens ||= task_class.max_output_tokens(task_settings)

  ctx      = Context.new(system: system)
  policy   = task_class.tool_policy(task_settings, tool_roles: cfg.tool_roles)
  registry = Registry.new(ctx, policy: policy)
  # No mcp&.register(registry), no register_navigator_tool — unlike every
  # other run_* sibling, the Chronicler is never handed the session's live
  # MCP connections at all. It has nothing to dispatch even if a tool
  # somehow got past tool_policy — see decision 3.

  ctx.add_message(:user, chronicler_input(goal: goal, outcome: outcome, checkpoints: checkpoints, prior_digest: prior_digest))

  be      = build_backend(backend, model: model, api_key: api_key, ollama_host: ollama_host)
  builder = PromptBuilder.new(ctx, be)
  client  = Client.new(builder)

  agent = Agent.new(context: ctx, registry: registry, builder: builder, client: client, logger: logger,
                     task_name: task_class.task_name, max_output_tokens: max_output_tokens)
  agent.run.strip
end

# checkpoints: an Array of JudgeMemory::Entry (or anything responding to
# turn/verdict/reasoning/overridden) — plain text is enough here, same
# "consumed only by a human/LLM-readable block, never branched on" posture
# planner_input/judge_input already use.
def self.chronicler_input(goal:, outcome:, checkpoints:, prior_digest: nil)
  parts = []
  parts << "Your existing notes on this character (revise and condense these — don't just restate them verbatim):\n#{prior_digest}" if prior_digest && !prior_digest.to_s.strip.empty?
  parts << "This session's goal: #{goal}"
  parts << "This session's outcome: #{outcome}"
  unless checkpoints.empty?
    lines = checkpoints.map { |c| "- turn #{c.turn}: #{c.verdict}#{c.overridden ? " [repeated action detected]" : ""} — #{c.reasoning}" }
    parts << "Checkpoints during this session (most recent last):\n#{lines.join("\n")}"
  end
  parts.join("\n\n")
end
private_class_method :chronicler_input
```

`task_name: "chronicler"` gives free `log_viz`/OTel per-task separation, same
as every other sibling (`orchestrator.md` §5, already confirmed to need zero
`log_viz`-side changes for a new task name).

### 4. `prompts/chronicler/system.md`

```
You are the Chronicler: you keep one adventurer's private notes across many
play sessions. You never act in the world and you are never given tools —
you only read what already happened and rewrite this character's notes.

You will be given, if they exist: this character's current notes, this
session's goal, its outcome, and a log of checkpoints from during the
session (a mentor's periodic verdicts on how the session was going).

Rewrite the notes under these headers, omitting any with nothing to say:

Discoveries — things worth remembering that aren't the map itself (a
merchant's prices, an NPC's behavior, a class's weakness against a
particular enemy). Never record room exits, connections, or layout — that's
tracked elsewhere and is not your job.
Mistakes — approaches that didn't work and why, especially anything a
checkpoint flagged as repeated or risky.
Strategies — approaches that worked, worth repeating.
Open threads — quests or goals still in progress, worth resuming next time.

Revise and condense existing notes rather than appending to them — merge
duplicates, drop anything superseded by what happened this session, and keep
the whole document short (well under a page). A shorter set of notes that's
still true is more useful than a longer one padded with restated detail.

Output plain text only: the notes themselves, under the headers above,
nothing else. No preamble, no meta-commentary about what you changed — this
text is read back verbatim next session, by you, as "your existing notes."
```

### 5. `Boukensha::Session.play` integration

**Superseded by "Revision (2026-08-08)" below** — the original design here
flushed once, at the very end of the loop; the code now flushes live at each
`:replan`/`:flag` checkpoint instead, and the post-loop write shown below no
longer exists. Kept as-written for the historical record of what shipped
first; see the Revision section for the current behavior and why it changed.

Three touch points, all additive and all no-ops when `player` is nil or
`memory.enabled?` is false:

```ruby
# Near the top, alongside judge_memory's construction:
memory       = (player && cfg.memory_enabled?) ? PlayerMemory.load(player.name, memory_dir: cfg.memory_dir) : nil
prior_digest = memory&.digest_text

# Both run_planner call sites (initial seed, and the :replan branch) gain:
ctx.plan = Boukensha.run_planner(
  goal: goal, player_memory: prior_digest, logger: logger, mcp: connections, ...
)
```

`run_planner`/`planner_input` gain the matching `player_memory:` kwarg and
block, parallel to `prior_plan:`/`replan_reason:`:

```ruby
def self.planner_input(goal:, transcript_tail: nil, prior_plan: nil, replan_reason: nil, player_memory: nil)
  parts = ["Goal: #{goal}"]
  parts << "What you've learned about this character from past sessions:\n#{player_memory}" if player_memory && !player_memory.to_s.strip.empty?
  parts << "Prior plan:\n#{prior_plan}" if prior_plan && !prior_plan.to_s.strip.empty?
  parts << "Why the prior plan is being replaced:\n#{replan_reason}" if replan_reason && !replan_reason.to_s.strip.empty?
  parts << "Recent transcript:\n#{transcript_tail}" if transcript_tail && !transcript_tail.to_s.strip.empty?
  parts.join("\n\n")
end
```

And, after the `loop do ... end` ends (whatever way it ended — natural
completion, `max_turns`, or a Judge `:flag`), before the method returns
`text`:

```ruby
if memory
  outcome = case
            when agent.stop_reason == :completed then "Completed: #{text}"
            when turn >= max_turns               then "Stopped: reached max_turns (#{max_turns}) without completing."
            else                                       "Stopped: Judge flagged a risk — #{Boukensha.verdict_reasoning(text)}"
            end

  memory.append_session_record(
    goal: goal, stop_reason: agent.stop_reason.to_s, turns: turn,
    checkpoints: judge_memory.entries.map { |e| { turn: e.turn, verdict: e.verdict, reasoning: e.reasoning, overridden: e.overridden } },
    outcome: outcome
  )

  begin
    digest = Boukensha.run_chronicler(goal: goal, outcome: outcome, checkpoints: judge_memory.entries, prior_digest: prior_digest, logger: logger)
    memory.save_digest(digest)
  rescue StandardError => e
    warn "[boukensha] Chronicler failed (#{e.message}) — memory digest left unchanged for #{player.name}"
  end
end
```

The `rescue` is deliberate and mirrors `build_compactor`'s own fail-open
pattern (Research, above): a broken Chronicler backend degrades to "this
session's lessons aren't captured," never to a failed/aborted play session.
`append_session_record` itself (plain file I/O, no LLM call) is not wrapped
the same way — if `.boukensha/memory/` isn't writable that's a real
configuration problem worth surfacing loudly, same posture `PlayerProfile.load`
already takes for a missing players file.

### 6. `Config` additions

```ruby
# ---------- Player memory -----------------------------------------------
# Reads `memory.enabled`. Defaults OFF — an LLM-authored digest that's wrong
# doesn't just waste tokens, it can steer a future session's plan in the
# wrong direction, so this stays opt-in-until-evaluated the same way
# compactor_enabled? does. See docs/plans/memory/player_memory.md decision 5.
def memory_enabled?
  v = dig(:memory, :enabled)
  v.nil? ? false : !!v
end

def memory_dir
  File.join(@dir, (dig(:memory, :dir) || "memory").to_s)
end
```

## Acceptance criteria

- With `memory.enabled: false` (the default) or `player: nil`, `Session.play`
  produces byte-identical behavior to today: no `.boukensha/memory/` file is
  read or written, `run_planner` is called with `player_memory: nil` at
  every call site — a direct regression test, same style every other
  additive feature in this plan set uses.
- `PlayerMemory#digest_text` returns `nil` for a player with no memory file
  yet (first-ever session); after `save_digest`, returns the saved text
  verbatim.
- `PlayerMemory#append_session_record` followed by `#session_records`
  round-trips a Hash through JSON; two different player names never read or
  write each other's files (construct both against the same `memory_dir:`
  and assert no cross-contamination) — the direct test of decision 6's
  isolation claim.
- `Tasks::Chronicler.tool_policy` denies every tool name with no
  `tasks.chronicler.tools` block configured, same assertion style
  `test_tasks_base_tool_policy.rb` already uses for deny-by-default; even if
  a test intentionally configures one, `Boukensha.run_chronicler` never
  passes it a live `mcp:` to dispatch anything against (there is no `mcp:`
  parameter on `run_chronicler` at all).
- A fixture `Session.play` run with `memory.enabled: true` and a scripted
  Chronicler response: after a session that hits a `:flag` checkpoint (or
  `max_turns`), `.boukensha/memory/<name>.jsonl` gains exactly one new line
  containing that session's goal/outcome/checkpoint history, and
  `.boukensha/memory/<name>.md` is overwritten with the scripted digest
  text.
- A second fixture run for the same player, seeded with a digest file
  already on disk: the Planner's request payload (spot-checked, same style
  as `orchestrator.md`'s own acceptance criterion) includes a "What you've
  learned about this character from past sessions" block containing that
  prior digest text.
- A Chronicler backend that raises: the session's `text` return value and
  exit path are unaffected, a warning is printed, and the digest file is
  left exactly as it was before the run (not truncated, not partially
  written) — the fail-open guarantee.

## Files touched

- `week3_capable/ruby/21_memory/lib/boukensha/tasks/chronicler.rb` — new.
- `week3_capable/ruby/21_memory/lib/boukensha/player_memory.rb` — new.
- `week3_capable/ruby/21_memory/lib/boukensha.rb` — `run_chronicler`,
  `chronicler_input`; `player_memory:` kwarg on `run_planner`/
  `planner_input`; `require_relative "boukensha/tasks/chronicler"` and
  `require_relative "boukensha/player_memory"`.
- `week3_capable/ruby/21_memory/lib/boukensha/session.rb` — `memory`/
  `prior_digest` construction, `player_memory:` threaded into both
  `run_planner` call sites, the post-loop `append_session_record`/
  `run_chronicler`/`save_digest` block.
- `week3_capable/ruby/21_memory/lib/boukensha/config.rb` —
  `memory_enabled?`, `memory_dir`.
- `week3_capable/ruby/21_memory/prompts/chronicler/system.md` — new.
- `.boukensha/settings.yaml` — new `tasks.chronicler:` and `memory:` blocks.
- `week3_capable/ruby/21_memory/test/test_player_memory.rb` — new (§2's
  round-trip/isolation coverage).
- `week3_capable/ruby/21_memory/test/test_tasks_chronicler.rb` — new
  (task name, prompt resolution, deny-by-default tool policy — mirrors
  `test_tasks_planner.rb`).
- `week3_capable/ruby/21_memory/test/test_run_chronicler.rb` — new (input
  assembly, no tools ever dispatchable, plain-text output — mirrors
  `test_run_planner.rb`).
- `week3_capable/ruby/21_memory/test/test_session.rb` (or a new
  `test_session_memory.rb`) — the fixture runs from Acceptance criteria,
  plus the fail-open Chronicler-raises case.
- `week3_capable/ruby/21_memory/test/test_config_*.rb` — `memory_enabled?`/
  `memory_dir` default and override coverage.
- `week3_capable/ruby/21_memory/README.md` — this step's "Branched from
  `20_navigator`, what's new" doc, per this curriculum's convention.
- `~/.boukensharc` (per-machine, not repo) — update `boukensha_path` to
  `21_memory` once built, same manual step every prior README calls out.

## Known tradeoffs / risks

- **Digest quality is entirely dependent on the Chronicler actually
  following "revise and condense, don't restate."** A model that just
  echoes the prior digest back (or pads it) produces no real learning, and
  one that over-condenses can lose a genuinely load-bearing lesson. The
  `max_output_tokens: 600` cap is a safety net against unbounded growth, not
  a quality guarantee — this needs eyes-on evaluation against a handful of
  real sessions before flipping `memory.enabled: true` by default, exactly
  why decision 5 keeps it opt-in.
- **A hallucinated "lesson" is a worse failure mode than no memory at all**,
  because it actively misdirects the Planner instead of just failing to
  help. There is no fact-checking step between the Chronicler's output and
  the next session's Planner input — the Chronicler's own prompt asks it to
  reason only from what's given (goal/outcome/checkpoints), but nothing
  mechanically prevents it from inventing detail the way any LLM summary
  can. Worth watching for in the evaluation pass above, not solved here.
- **One digest per player, not versioned.** `save_digest` overwrites in
  place — a bad consolidation permanently loses whatever nuance the
  previous digest had, recoverable only by re-deriving from
  `session_records` by hand (no automated re-derivation tool is built here).
  Acceptable for a first pass since the raw JSONL is kept specifically as
  that recovery path, but worth knowing there's no automatic rollback.
- **Only `Session.play` writes memory; `Repl`'s interactive path does not.**
  A human driving `boukensha --player X` interactively today accumulates no
  cross-session memory even with `memory.enabled: true`, since `Repl` has no
  single well-defined "session end" the way `Session.play`'s loop does.
  Consistent with this repo's own precedent of shipping Planner/Judge on
  `Session` first and retrofitting `Repl` afterward (Research, above) — not
  an oversight, but explicitly not done in this pass (see Deferred).

## Deferred / out of scope here

- **Retrofitting `Repl` with the same memory write-out.** Would need its own
  "what counts as a session boundary" decision (on `/clear`? on quit? on a
  Judge flag, same as `Session`?) — a real design question, not a
  copy-paste of §5, deferred the same way `repl_planner_integration.md`/
  `repl_judge_integration.md` were their own follow-up docs rather than part
  of `orchestrator.md`/`evaluator.md`.
- **Splitting `memory.enabled` into two flags** (an always-on, free raw
  record vs. a separately-toggled LLM consolidation) — mentioned as a
  possible refinement in decision 5's reasoning but not built speculatively;
  revisit only if evidence shows the raw record alone (no digest, no
  Chronicler cost) is independently useful.
- **Feeding memory to the Judge or the Player directly.** Decision 4 keeps
  memory Planner-only, matching the existing Player/Planner boundary. A
  Judge that could ask "have I seen this exact mistake before, in a prior
  session" is a plausible future extension (parallel to how `JudgeMemory`
  already tracks it within one session) but is new scope, not assumed here.
- **A `log_viz` "Memory" viewer tab** for a human to read a player's digest
  and raw session records — natural, low-cost follow-up given
  `session_records` already returns viewer-ready data, but UI work outside
  this plan's scope (mirrors how `multiple_concurrent_players.md`'s own
  `Players` tab was itself a separate, later addition to `log_viz`).
- **Automatic digest re-derivation from the full raw record** (rebuild the
  digest from scratch across every `session_records` entry, e.g. after
  improving the Chronicler's prompt) — flagged in "Known tradeoffs" as the
  recovery path that exists in principle, not built as a tool here.

## Open questions

- **Naming**: `Tasks::Chronicler` / `.boukensha/memory/` are this plan's
  proposed names, chosen for fitting the existing evocative naming
  (`Navigator`, `Judge`, `Planner`) without colliding with `PlayerMemory`
  (the storage class) or `JudgeMemory` (the existing session-scoped struct)
  — open to bikeshedding before implementation, same as `Session`'s own
  "naming TBD" note in `orchestrator.md` §4.
- **Digest size ceiling**: `max_output_tokens: 600` is a starting guess
  (Research's "tuning knob, not fixed constant" posture, same as
  `Tasks::Judge`'s `repeated_action_window`/`threshold`) — adjust once a
  real digest has been read and judged too short or too long.
- **Should a session that ends via ordinary `:completed` still write a
  memory record**, or only sessions with at least one `:replan`/`:flag`
  checkpoint (i.e., only when there was something notable to learn)? This
  plan's §5 always writes one record per session, on the theory that
  "nothing went wrong, the plan worked" is itself a useful Strategies-header
  fact for the Chronicler to fold in — flagging in case the resulting digest
  turns out noisier than useful once real sessions are read.
    A: only when there was something notable to learn
    Superseded by the 2026-08-09 revisions below, twice over: first,
    "notable" turned out to mean "at least one checkpoint happened," not
    "at least one checkpoint escalated past :continue" (the "flush on every
    checkpoint" revision); then, "a session that never reaches a checkpoint
    at all still writes nothing" turned out to be a bug in its own right,
    not a stable resting point — see the "checkpoint the ending turn too"
    revision for why a natural completion needed to force one.

## Revision (2026-08-08): checkpoint-triggered flush, not session-end

**Problem.** §5 as originally built only ever chronicled once, at the very
end of `Session.play`'s loop (or, for `Repl`, at `/clear`/`/exit`/EOF). That
made sense for a short-lived session, but doesn't for the "Agent plays the
game by itself" use case this whole project is for: a self-managed
`Session.play` run can keep going — turn after turn, replan after replan —
until a large goal is accomplished or the cost cap is hit, which can mean
the entire session. A real player doesn't wait until they log off to learn
something; they learn along the way, and each new plan should already
reflect the lesson from the last mistake, not just plans in some *future*
session. Waiting for session-end also means a session that never reaches a
clean end (crashes, gets killed, runs indefinitely) writes nothing at
all — the exact gap that motivated this revision.

**New behavior.** Memory is now flushed live, checkpoint by checkpoint,
immediately before whichever Planner call would benefit from it:

- On a Judge **`:replan`** verdict, `flush_memory` runs *before* that
  replan's own `Boukensha.run_planner` call — so the replanned plan already
  sees whatever was just learned, not the digest from session start.
- On a Judge **`:flag`** verdict, `flush_memory` also runs immediately
  (`Session.play` breaks its loop right after anyway; `Repl` doesn't stop on
  `:flag`, so this just gets the lesson recorded promptly instead of waiting
  for a later boundary).
- `Session.play`'s old post-loop write is gone entirely — every non-`:continue`
  verdict is now handled by one of the two live call sites above, so nothing
  notable is ever left unflushed by the time the loop exits (natural
  completion or `max_turns`).
- `Repl`'s `/clear`/`/exit`/EOF boundary flush is **kept**, not removed — it's
  now a catch-all rather than the only mechanism: it still needs to catch a
  `:flag` that hasn't been followed by a replan yet, or any trailing
  checkpoint, since a human-driven REPL has no other natural "session end."

**Mechanism.** `judge_memory` (`Session.play`) / `@judge_memory` (`Repl`) —
the Judge's own cross-checkpoint history, used as `history:` on every
`Boukensha.run_judge` call (`evaluator_judge_redesign.md` §3) — must stay
cumulative for the *entire* session; resetting it on every flush would undo
that fix ("Judge were not carrying previous judgments into memory"). So a
second, separate accumulator was added purely for the Chronicler's own
bookkeeping: `pending_checkpoints` (`Session.play`, a local var) /
`@pending_checkpoints` (`Repl`, an ivar) — every checkpoint entry is pushed
onto both `judge_memory`/`@judge_memory` *and* the pending list, but only the
pending list is read and reset by a flush. `judge_memory`/`@judge_memory`
itself is untouched by any flush; `Repl`'s `/clear` still resets it
explicitly, same as before, since a full context reset legitimately deserves
a fresh Judge history too.

**Files touched (beyond §5's original list):**
`week3_capable/ruby/21_memory/lib/boukensha/session.rb` (the `flush_memory`
lambda, `pending_checkpoints`, `:replan`/`:flag` call sites, post-loop write
removed), `lib/boukensha/repl.rb` (`flush_memory!` reworked to accept an
optional `outcome:` and operate on `@pending_checkpoints`, new `:replan` call
site in `maybe_check_judge`, `@pending_checkpoints` added alongside
`@judge_memory`), `test/test_session_memory.rb` and `test/test_repl_memory.rb`
(new replan-flush tests asserting the *replanned* Planner request itself
carries the freshly chronicled digest).

## Revision (2026-08-09): flush on every checkpoint, not just :replan/:flag

**Problem.** The 2026-08-08 revision above flushed live, but only from the
`:replan` and `:flag` branches of `Session.play`'s verdict switch (and
`Repl#maybe_check_judge`'s equivalent). `flush_memory`'s own gate made this
explicit: it no-opped unless at least one *non*-`:continue` verdict had
landed in `pending_checkpoints` since the last flush. That's the direct
reading of the "only when there was something notable to learn" answer to
this doc's own open question (§ "Open questions") — but it conflates "the
Judge decided to stop or replan" with "something worth remembering
happened," and those are different axes. A session where the Judge only
ever says `:continue` — the Player still technically making progress,
never repeating an identical tool call often enough to trip the mechanical
override — never flushes at all. Observed concretely: a broke Player kept
visiting a bar, a pet shop, and a food shop in turn, none of which could
resolve its hunger because it had no money — a clear, repeated, learnable
mistake, but each individual shop visit was a *different* action, so
`repeated_tool_calls` never fired and the Judge kept saying `:continue`
("still exploring, no immediate risk"). Every one of those checkpoints'
reasoning accumulated in `pending_checkpoints` and was then silently
dropped the moment the session ended via `:completed` or `max_turns`,
since nothing had ever called `flush_memory` for it — the "no post-loop
memory write" design (§ "Revision (2026-08-08)") assumed every notable
checkpoint had already been flushed live, which is false precisely when
nothing ever escalates.

**New behavior.** `flush_memory`'s gate is now just "is anything pending" —
`pending_checkpoints.empty?` — not "did anything escalate." It is now
called from every branch of the verdict switch, including a new `:continue`
branch (`Session.play`) / `maybe_check_judge`'s new `else` (`Repl`), so a
`:continue` checkpoint's Judge reasoning reaches the Chronicler on the same
live cadence a `:replan`/`:flag` checkpoint always did. No new rate limit
was added on top of this: checkpoints themselves are already throttled by
`Session.checkpoint?` (an iteration/token-limit wrap-up, or the
`every_n_turns:` fallback cadence), so this costs exactly one extra
Chronicler call per checkpoint that would otherwise have been silent, not
one per turn.

`Session.play`'s post-loop write, removed in the 2026-08-08 revision on the
now-corrected assumption that nothing could ever be left pending at loop
exit, is back as a guarded catch-all (`if pending_checkpoints.any? ...`) —
cheap insurance, not the primary mechanism, since every checkpoint already
flushes live above. `Repl`'s existing `/clear`/`/exit`/EOF catch-all needed
no new call site, only the same gate change — it already covered whatever
was left pending regardless of verdict, once the gate stopped filtering it
out.

**Known tradeoff.** The Chronicler (an LLM call) now runs as often as the
Judge does on a long session — previously it only ran on escalation, which
is inherently rarer. Acceptable given `tasks.chronicler`'s existing "cheap
model, `max_output_tokens: 600`" posture, but worth watching once real,
longer self-managed sessions (docs/plans/agent_loop/self_management.md) are
evaluated against actual cost.

**Files touched (beyond the 2026-08-08 revision's list):**
`week3_capable/ruby/21_memory/lib/boukensha/session.rb` (`flush_memory`'s
gate, the new `else`/`:continue` branch in the verdict `case`, the restored
guarded post-loop catch-all), `lib/boukensha/repl.rb` (`flush_memory!`'s
gate, the new `else`/`:continue` branch in `maybe_check_judge`'s verdict
`case`), `test/test_session_memory.rb`
(`test_a_continue_only_checkpoint_still_flushes_memory`),
`test/test_repl_memory.rb`
(`test_a_continue_checkpoint_flushes_memory_without_clear_or_exit`).

## Revision (2026-08-09, cont.): checkpoint the ending turn too

**Problem.** Even after the "flush on every checkpoint" revision above,
`Session.play`'s loop still had `break if agent.stop_reason == :completed`
*before* `checkpoint?` was ever consulted. `checkpoint?` itself only fires
on a limit-triggered wrap-up or the `every_n_turns:` fallback cadence —
neither of which a turn that ends by the Player simply replying with plain
text (no further tool call) necessarily hits. So a session that ended by
natural completion, and had not yet hit any other checkpoint that session,
flushed nothing at all: not the raw JSONL record, not a digest update,
nothing — the exact same silent-loss shape the "flush on every checkpoint"
revision fixed for `:continue`, but for `:completed` instead of a verdict.

This is not a hypothetical. A live self-managed run (`session.self_manage:
true`) attacked a mob in a room with a Peacekeeper NPC present; the
Peacekeeper retaliated against the Player instead, killing the character and
ending the MUD connection. The Player's own final turn, with nothing left to
call a tool against, just narrated that the session was over — a natural
`:completed`. Concretely, `.boukensha/memory/dina.jsonl`'s 26 records at the
time this was noticed were **100% `replan` or `continue`** — zero
`completed`, zero `flag`, zero `max_turns` — meaning every session that had
ever ended by running out of turns, completing, or (had one occurred) being
flagged, had written nothing about how it ended, regardless of what
happened. One of those 26 records (a live `:replan` checkpoint mid-session,
not an ending one) does show the Judge catching the Peacekeeper danger in
the moment — *"they attacked/examined fido without using `consider`, and the
result shows they are now fighting a Peacekeeper... HP has dropped"* — proof
the MUD told the agent exactly what happened, in-band, as tool output. The
signal was never missing; the pipeline just never asked the Judge to look at
it on the turn where the session actually ended.

**New behavior.** A natural completion (`agent.stop_reason == :completed`)
now forces one checkpoint of its own, gated on `memory` being present (a
`player:` given and `memory.enabled?` true) — so a plain one-shot goal with
no player/memory costs exactly what it always did, and `checkpoint?` itself
is still never invoked with a `:completed` agent (this is a separate,
explicit trigger evaluated before falling back to `checkpoint?`, not a case
`checkpoint?` needs to know about — see its own updated comment). When this
fires, the Judge is consulted once more against the final transcript tail,
the resulting entry is recorded, and `flush_memory` is called unconditionally
with `reason: :completed` — no `:replan`/`:continue` branching afterward,
since the Player already decided the session is over (the next "continue"
turn may well be talking to a MUD connection that no longer exists).

**Known tradeoff.** Every session that completes naturally now costs one
extra Judge (and, via `flush_memory`, one extra Chronicler) call when memory
is on — including a short, completely uneventful one-shot goal — where
before this fix it cost nothing if no other checkpoint had fired. This is
the same "more LLM calls, in exchange for actually capturing what happened"
tradeoff the "flush on every checkpoint" revision above already accepted for
`:continue`; extending it to `:completed` closes the one remaining gap where
a session's own outcome — including a lethal mistake — could still be
silently unrecorded.

**Files touched:** `week3_capable/ruby/21_memory/lib/boukensha/session.rb`
(`checkpoint?`'s comment, the new `completed_this_turn`/`run_checkpoint`
split before the checkpoint block, the `if completed_this_turn ...
flush_memory.call(reason: :completed, ...)` branch, `break if
completed_this_turn` replacing the old early `break`),
`test/test_session_memory.rb` (renamed
`test_a_session_that_completes_with_no_checkpoint_writes_nothing` to
`test_a_session_that_completes_on_the_first_turn_still_flushes_memory` and
inverted its assertions; new
`test_a_session_that_completes_with_memory_disabled_never_checks_the_judge`;
`test_a_continue_only_checkpoint_still_flushes_memory`,
`test_a_replan_flushes_memory_before_the_replanned_planner_call`, and
`test_a_prior_digest_reaches_the_planners_request_payload` updated to script
the now-mandatory final checkpoint's Judge/Chronicler responses).

## Revision (2026-08-09, cont.): merge, don't condense — the Chronicler stops discarding lessons

**Problem.** `prompts/chronicler/system.md` told the Chronicler to "revise
and condense existing notes rather than appending to them... keep the whole
document short (well under a page)." This is exactly the "Digest quality is
entirely dependent on the Chronicler actually following 'revise and
condense'... one that over-condenses can lose a genuinely load-bearing
lesson" risk this doc's own "Known tradeoffs" section already named — but it
was observed happening for real, not just in principle. The same
`dina.jsonl` record discussed in the revision above (a `:replan` checkpoint
that caught the Player fighting a Peacekeeper) *was* chronicled at the time
— but by the time `dina.md` was next read, that specific, high-severity,
named-NPC danger had been generalized away into a vaguer "Use `consider`
before committing to combat" line with no mention of Peacekeepers at all.
The lesson wasn't dropped by a bug; the prompt asked for exactly this
("condense... short... under a page"), and a later session's danger from the
very same mechanism (attacking near a Peacekeeper) went unwarned-against
because the specific fact no longer existed anywhere memory could surface
it. A digest that only ever gets *shorter* cannot durably hold more than
whatever fits in "under a page," no matter how many sessions taught it
something new — every new lesson is competing with every old one for the
same fixed, shrinking budget.

**New behavior.** `prompts/chronicler/system.md` now treats the existing
digest as durable knowledge by default rather than a draft to be freely
rewritten: every existing line carries forward into the output unless the
session at hand gives a specific reason to MERGE it (this session's finding
is clearly the same fact — combine the two, keeping every specific detail
either had, not just the more general phrasing) or DROP it (this session's
outcome directly proves the line false or resolved). Anything else — most
existing lines, on most sessions — is copied forward unchanged, with new,
genuinely non-duplicate findings added alongside it. The "keep it short"
instruction is reframed as a wording concern, not a content one: tighten
sentences and cut narration/flavor text first, and only fall back to merging
near-duplicates once wording is already tight — "losing a distinct,
still-true lesson is a worse outcome than a longer document." The
Discoveries header explicitly calls out preserving a named NPC's specific
behavior (the Peacekeeper case, now used as the header's own example)
instead of laundering it into generic advice that loses the name and the
reason it matters.

`tasks.chronicler.max_output_tokens` (`.boukensha/settings.yaml`) was raised
600 → 900 to give a genuinely accumulating digest room to actually keep
what it's told to keep, instead of being forced back into condensing to fit
regardless of the prompt's new instructions — still a real ceiling (this
digest is re-read into every Planner call, so it isn't free), just not one
tuned for the old "rewrite from scratch every time" behavior.

**Known tradeoff.** A digest that only ever grows (merge/keep, rarely drop)
will cost more tokens per Planner call over a character's lifetime than one
that gets condensed on every write, and depends on the Chronicler actually
recognizing when two write-ups describe the same fact (a MERGE) rather than
either duplicating them or, worse, still smoothing them together into
something vaguer than either — this is a prompt-engineering property to
keep evaluating against real digests, not something this revision can prove
correct on its own. `max_output_tokens: 900` is a stopgap ceiling, not a
long-term answer to unbounded growth across dozens of sessions; if a
character's digest keeps hitting it, that's a signal this prompt needs a
harder per-line budget or a move to a structured (not free-text) store, not
just another bump to the token cap.

**Files touched:**
`week3_capable/ruby/21_memory/prompts/chronicler/system.md` (rewritten:
MERGE/DROP-with-reason replaces "revise and condense... under a page"),
`.boukensha/settings.yaml` (`tasks.chronicler.max_output_tokens: 600 → 900`).
`.boukensha/memory/dina.md` was also regenerated by replaying the full
`dina.jsonl` history through the corrected prompt from scratch (rather than
patched by hand), to recover lessons — including the Peacekeeper danger —
that the old condense-every-time behavior had already discarded from the
live file; see the regenerated file's own content for what came back.

## Revision (2026-08-09, cont.): the Chronicler is not a second Judge — scope it to plan-independent facts only

**Problem.** The "merge, don't condense" revision above fixed the wrong
axis. It stopped lessons from being silently dropped, but it never
questioned *what counted as a lesson in the first place* — and the
Chronicler's only input besides the digest itself is a Judge checkpoint's
own reasoning, which is inherently about that session's plan ("deviated
from the plan," "was against the stop/report guidance," "diverted from the
survival/gearing priority"). Left unfiltered, that framing bled straight
into the notes: real `dina.md` output after the previous revision included
lines like *"Attacking/examining fido without using `consider` after
failing to buy drink due to no gold was a serious plan mismatch that
dropped HP and left the plan's safety assumptions invalid"* and *"Repeating
`1` again during menu recovery was against the stop/report guidance"* — the
second one, in particular, is purely about one session's specific recovery
plan and has no meaning at all once that plan is gone. With the 12-line
cap from the previous revision permissive enough to rarely bind, and every
checkpoint treated as worth mining for *something*, the digest ballooned to
~46 lines / ~6.7KB after replaying 27 real sessions — described accurately
by the user as "too large," "too detailed," and "all over the place," for a
character barely past its first few play sessions. The Chronicler had
drifted into re-deriving a Judge-style plan-compliance log instead of
writing a knowledge base: exactly the boundary decision 1 and decision 3
(§ "Decisions this plan makes," above) already drew — "tools are just tools
and world knowledge are just helpers/info, they are not considered
memory/experience" applies just as much to *a Judge's plan verdicts*, which
are neither.

**New behavior.** `prompts/chronicler/system.md` now opens with an explicit
scope statement before any MERGE/DROP mechanics: the Chronicler records
durable facts about the game that would hold under a *different* plan, not
commentary on this session's compliance with *this* plan. It's told
directly to read through a checkpoint's plan-flavored framing and ask "is
there a fact about the world underneath this, independent of what any plan
said to do" — with the Peacekeeper line kept as the positive example (survives
the question) and a plan-compliance line ("repeating `1` violated the
recovery plan's stop condition") added as the explicit negative example
(does not). Each header's own definition was narrowed the same way (a
Mistake is now "an action whose in-game consequence was worse than
expected," not "an action a checkpoint disliked"; Open Threads is "the goal
and where it stands," not a recovery-plan play-by-play). The doc now says
outright that adding nothing is the expected outcome for most sessions,
since most checkpoints are pure plan-adherence and there's nothing under
them to keep. The per-header hard cap was tightened 12 → 6 lines, framed as
rarely worth reaching given how narrow the scope already is, rather than a
target to fill.

**Regenerating `dina.md` again exposed a second, independent problem**:
replaying 27 sessions as 27 sequential Chronicler calls (each one's output
feeding the next as `prior_digest`) is fragile under ordinary LLM
non-determinism — a fact can be captured correctly at the session it
happened, then silently fail to survive one of the next 15 MERGE decisions
purely by chance, with no single call at fault. Two consecutive replays
this way (same prompt, same input) produced digests that had lost the
Peacekeeper fact entirely, versus a third that kept it — the same rewritten
prompt, three different outcomes, because 27 rounds of "is this still
worth keeping" compounds whatever error rate any one round has. **The fix
for a one-time historical backfill was to stop simulating incremental play
and instead make a single Chronicler call over the *entire* concatenated
history at once** (every session's checkpoints, in order, as one input,
`prior_digest: nil`) — removing the 27-step compounding chain removes the
failure mode along with it, since there's now exactly one MERGE/DROP pass
to get right instead of 26 sequential ones. This is a backfill-only
technique, not a change to live play: `Session.play` still (correctly)
calls the Chronicler once per checkpoint, incrementally, since a live
session doesn't have "the entire future history" available up front the
way a historical replay does.

**Known tradeoff.** Scoping the Chronicler this tightly means a checkpoint
that's 90% plan-talk and 10% a genuine discovery relies on the model
correctly extracting that 10% rather than discarding the whole thing
because most of it read as plan commentary — the two bad replays above show
this isn't yet reliable per-call. A single-pass, full-history regeneration
is a reasonable one-time recovery tool exactly because it's cheap to
inspect and re-run before committing (as this revision's own repair did),
but it is not a substitute for improving reliability of the live,
one-session-at-a-time path, which cannot be re-run and inspected the same
way before it's already saved.

**Files touched:**
`week3_capable/ruby/21_memory/prompts/chronicler/system.md` (rewritten
again: explicit plan-vs-game-fact scope statement with worked positive/
negative examples, narrowed Mistakes/Strategies/Open-threads definitions,
12 → 6 line cap, "adding nothing is normal" framing).
`.boukensha/memory/dina.md` regenerated a second time, this time via a
single full-history Chronicler call rather than a 27-step replay (see
above) — the file's own content is the result.