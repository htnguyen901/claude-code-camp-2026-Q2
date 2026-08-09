## Goal

To allow the Agent to act by themselves and no need to ask user for feedback/request after turn ends

- Right now after a turn ends (could be due to max token reached), the judge will make a verdict and Agent will stop working untill I send 'continue' or another request. I need Agents to keep going after the verdict
- For that I need few things to happen first:
    - I need to be able to interfere mid-journey, meaning I can pause, stop, interfere with new request/comments or revoke the session. I assume I will need to send interfering request from the boukensha TUI, just make sure that it is not a Ctrl+ C (to immidate quit the TUI). I still want to keep the session in TUI, I just need to interfere with the Agent Flow
        - For now I only need to pause (then able to continue again) or stop. No need to implement interfering with new request yet.
    - I need to set maximum cost consumption per session by ALL tasks. This should be configed from settings.yaml. The agent will keep going unless it almost hit this limit then do a wind-down request just like the mechanism of the current compacting

**Status: implemented** (`lib/boukensha/repl.rb`, `21_memory` step),
**with one amendment post-implementation**: §3's original stopping
condition #2 below (`agent.stop_reason == :completed` auto-stops the loop)
shipped as designed, but real self-managed play showed it was wrong — see
the note under "Stopping conditions".

## Relationship to existing docs

This is the third and last piece of the "bring `Session`-style autonomy into
the interactive path" series that started with
[`repl_planner_integration.md`](repl_planner_integration.md) (Planner-by-
default in `Repl`) and [`repl_judge_integration.md`](repl_judge_integration.md)
(Judge-by-default in `Repl`). Those two docs made `Repl` *check in* with
Planner/Judge the same way `Boukensha::Session` (`lib/boukensha/session.rb`)
already did for its own autonomous CLI driver, but left the human still
typing every turn. This doc closes that last gap: after a Judge checkpoint
says `:continue`/`:replan`, `Repl` keeps going on its own — literally
issuing `Session::CONTINUE_INSTRUCTION` ("continue") as the next turn's
input — instead of returning control to the prompt.

`Boukensha::Session.play` itself is **not** touched or reused directly. It
remains what `repl_judge_integration.md` already documented it as: a
separate, non-interactive, single-goal CLI driver with no TUI, no pause/stop
surface, and no session-wide cost governor. This doc gives `Repl` an
equivalent "keep calling `Agent#run` until something says stop" loop, but
one that's cooperative (checkable/pausable between turns) and cost-gated —
neither of which `Session.play` has today. `Session.checkpoint?` is reused
as-is (same predicate, no changes); nothing here forks it.

**Depends on:** `Config#planner_enabled?`/`Config#judge_enabled?`
(`lib/boukensha/config.rb:131-144`), `Repl#maybe_seed_plan`/
`Repl#maybe_check_judge` (`lib/boukensha/repl.rb:249-328`), and the existing
`Tui` output/event-callback wiring (`lib/boukensha/tui.rb`).

Three sub-problems, in the order they need to land (each is a prerequisite
for the next — see "Rollout / sequencing" below):

1. **§1 — session-wide cost budget**, so an unattended loop has a hard
   backstop on spend, across every task (Player + Planner + Judge +
   Navigator), not just the Player's own per-turn token ceiling.
2. **§2 — pause / resume / stop**, a control surface the human can reach
   from the TUI without killing the process, so an unattended loop is never
   actually unattended-and-unstoppable.
3. **§3 — the self-managed continuation loop itself**, which only auto-
   continues at all when both of the above are in place to bound it.

## §1. Session-wide cost budget

### Why `Logger` is the right place to track it

Every task's model call — Player, Planner, Judge, Navigator — already ends
up in one place: `Agent#run` calls `@logger.response(...)`
(`lib/boukensha/agent.rb:87`, and again in `wrap_up`, `agent.rb:145`), and
`Logger#execution_metadata` already computes a per-response `cost_usd` via
`backend.estimate_cost` (`lib/boukensha/logger.rb:164-179`, `:207-212`).
Crucially, **one `Logger` instance is shared across all of them for the
whole session** — `Boukensha.repl` builds it once (`lib/boukensha.rb:217`)
and threads the same object into `Repl.new`, `Boukensha.run_planner`,
`Boukensha.run_judge`, and `register_navigator_tool` (`boukensha.rb:232-264`
and the equivalent calls inside `Repl#maybe_seed_plan`/`#maybe_check_judge`).
So a running total of `cost_usd` inside `Logger` is automatically a true
session-wide, all-tasks total, with no new plumbing between tasks — just an
accumulator at the one choke point every task's response already passes
through.

(`tasks.content_fact`/`tasks.compactor` Tier 2, per `settings.yaml:119-149`,
call Ollama directly and today price at `cost_per_million: { input: 0.0,
output: 0.0 }` for every Ollama model — `backends/ollama.rb:11-51` — so they
contribute `$0.0` to the total even once wired in. Whether they go through
this same `Logger`/`Client` path at all is unconfirmed and out of scope for
this doc; noted under "Open questions" since it only matters the day one of
them gets a non-free backend.)

### Changes

- **`Logger`** (`lib/boukensha/logger.rb`): add `attr_reader :total_cost_usd`,
  initialized to `0.0`. In `execution_metadata` (`:164-179`), after computing
  `cost_usd`, add it to the running total: `@total_cost_usd += cost_usd if
  cost_usd`. Purely additive — no existing field changes shape.
- **`Config`** (`lib/boukensha/config.rb`): new top-level `session:` block
  (sibling to the existing `agent:`/`tasks:`/`tool_roles:` blocks), read with
  the same `dig(...)` + nil-coalesced-default convention as
  `agent_max_turn_tokens`/`agent_compaction_threshold` (`config.rb:112-120`):

  ```yaml
  session:
    max_cost_usd:   null   # session-wide spend cap across every task combined; null/0 disables
    cost_warn_pct:  0.85   # fraction of max_cost_usd that triggers a one-turn wind-down before stopping
  ```

  ```ruby
  def session_max_cost_usd
    v = dig(:session, :max_cost_usd)
    v.nil? ? nil : Float(v)   # nil/0 = disabled, same convention as agent_max_turn_tokens
  end

  def session_cost_warn_pct
    v = dig(:session, :cost_warn_pct)
    v.nil? ? 0.85 : Float(v)
  end
  ```

- **`Boukensha.session_budget_status(logger, cfg)`** — a small free function
  in `lib/boukensha.rb`, alongside existing session-scoped helpers like
  `Boukensha.repeated_tool_calls`/`Boukensha.verdict_reasoning`. Returns
  `:ok`, `:warn`, or `:exhausted`:

  ```ruby
  def self.session_budget_status(logger, cfg)
    budget = cfg.session_max_cost_usd
    return :ok unless budget && budget.positive?

    spent = logger.total_cost_usd
    return :exhausted if spent >= budget
    return :warn       if spent >= budget * cfg.session_cost_warn_pct

    :ok
  end
  ```

  Deliberately a free function over `(logger, cfg)`, not a new class — this
  mirrors `Session.checkpoint?`'s own shape (a small predicate, not an
  object) rather than introducing a `CostGuard`/`Budget` class for what's
  fundamentally one comparison.

### The wind-down, mirroring `Agent#wrap_up`

`Agent#wrap_up` (`lib/boukensha/agent.rb:136-156`) already has a name and a
mechanism for exactly this shape of problem at the *turn* level: stop
starting new work, make one short, cheap, tools-disabled call so the model
ends in character instead of being cut off, using a fixed `WRAP_UP_DIRECTIVE`
and `WRAP_UP_OUTPUT_TOKENS` (`agent.rb:14-20`). This doc reuses the same
idea one level up, at the *session* level, without touching `Agent` at all:

- `:ok` — self-managed loop (§3) continues normally, issuing `"continue"`.
- `:warn` — instead of `"continue"`, the loop issues one more turn with a
  fixed wind-down instruction (analogous to `WRAP_UP_DIRECTIVE`, but as a
  normal turn input, not a tools-disabled call — `Agent#run`'s own
  `max_iterations`/`max_turn_tokens` wrap-up still applies normally if that
  turn itself runs long):

  ```ruby
  WIND_DOWN_INSTRUCTION = <<~MSG.strip
    You're nearing this session's cost budget. Do not start any new
    multi-step subtask. Finish or abandon whatever you're doing now,
    briefly say what's left undone, and stop.
  MSG
  ```

  then the self-managed loop stops after that turn, regardless of its
  Judge verdict.
- `:exhausted` — the loop stops immediately, before starting another turn
  at all (no more spend, not even one wind-down call) — a printed notice
  explains why, same pattern as the existing `:flag` notice
  (`repl.rb:326`).

## §2. Pause / Resume / Stop

### Why this lives in `Repl`, driven from `Tui`

`Tui` already runs each turn on a background `Thread`
(`@turn_thread = Thread.new { @repl.run_turn(input) }`, `tui.rb:272-282`)
while its own `Bubbletea::Runner` event loop keeps reading keypresses on the
main thread (`update`/`handle_key`, `tui.rb:98-123`, `:213-236`). That's
exactly the split the user is asking for: a way to signal the in-flight
background turn without touching the foreground TUI loop that owns
Ctrl+C/Ctrl+D (`tui.rb:215-216`, unchanged — those still quit immediately,
as today). Plain `--no-tui` `Repl#start` (`repl.rb:215-235`) has no such
split — it blocks on `$stdin.gets` and has no second thread reading input
while a turn (or a self-managed run of several turns) is in progress. So:

- **The pause/resume/stop *primitives* live on `Repl`**, callable safely
  from another thread (plain ivar flips — cooperative, checked only between
  turns, never preempting an in-flight `Agent#run`; see "What does NOT
  change" below for why mid-turn preemption is deliberately out of scope).
  This keeps `--no-tui` able to call the same primitives via slash commands
  for symmetry and testability, even though it can't actually *deliver* one
  while a self-managed run is mid-loop (see "Open questions").
- **`Tui` only supplies the keybindings** that call into those primitives —
  no new state of its own beyond what it already polls each tick.

### `Repl` additions (`lib/boukensha/repl.rb`)

```ruby
attr_reader :autonomy_state   # :manual | :running | :paused | :stopped

def pause_autonomy!
  @autonomy_state = :paused if @autonomy_state == :running
end

def resume_autonomy!
  @autonomy_state = :running if @autonomy_state == :paused
end

def stop_autonomy!
  @autonomy_state = :stopped if %i[running paused].include?(@autonomy_state)
end
```

Idempotent by design (calling `pause!` twice, or `resume!` when not paused,
is a no-op) — a keybinding can be pressed sloppily without needing debounce
logic. `@autonomy_state` starts `:manual` and is only ever `:running`/
`:paused`/`:stopped` while a self-managed loop (§3) is actually in flight;
it resets to `:manual` when that loop exits for any reason, so a stale
"paused" state can never leak into the next goal.

### Slash commands (`Repl#handle_command`, `repl.rb:141-172`)

```
/pause    pause self-managed continuation after the current turn finishes
/resume   resume a paused self-managed run
/stop     stop self-managed continuation (falls back to manual, session stays open)
```

Each just calls the matching `*_autonomy!` method and prints a short
confirmation, same style as the existing `/compact`/`/clear` branches.
`HELP`/`banner` (`repl.rb:27-35`, `:114-137`) gain a line for each, gated
to only mention them when `Config#self_manage?` is on (no point advertising
a mode that's off).

### TUI keybindings (`Tui#handle_key`, `tui.rb:213-236`)

Two new bindings, chosen to avoid: `ctrl+c`/`ctrl+d` (quit), `esc` (hard-
interrupts the *current* turn via `Thread#raise(Interrupt)` — unrelated to
autonomy and left untouched), `ctrl+l` (clear), `pgup`/`pgdown` (scroll),
and terminal flow-control keys (`ctrl+s`/`ctrl+q`, which some terminals
intercept before the app ever sees them — avoided on purpose):

```ruby
when "ctrl+p"
  @repl.autonomy_state == :paused ? @repl.resume_autonomy! : @repl.pause_autonomy!
  nil
when "ctrl+x"
  @repl.stop_autonomy!
  nil
```

`ctrl+p` toggles pause/resume with one key (matches the Goal doc's own
framing: "pause (then able to continue again)"); `ctrl+x` stops. Both are
thin — no new `Tui` state, since `@repl.autonomy_state` is already the
source of truth.

### Status line (`Tui#render_progress`/`#render_status`, `tui.rb:147-191`)

Extend the existing live-progress line with the autonomy state and running
spend, using the same colour-threshold pattern already used for context %
(`CTX_WARN_PCT`/`CTX_ALERT_PCT`, `tui.rb:44-45`, `#ctx_color`):

```
⠋ Calling tool: tbamud__move  (iter 3/25 · 12s · ↑ 1.2k · ↓ 340 · 2 calls)  ●auto turn 7  $1.42/$5.00
```

`●auto` / `⏸paused` / (nothing, when `autonomy_state == :manual`) as the
self-managed indicator; cost coloured via new `COST_WARN_PCT`/
`COST_ALERT_PCT` constants mirroring `CTX_WARN_PCT`/`CTX_ALERT_PCT`,
driven off `Boukensha.session_budget_status`.

### Guarding against concurrent turns while self-managing

`Tui#submit_input` (`tui.rb:238-255`) does not currently check whether
`@turn_thread` is still alive before launching another one — today that's
latent (a human would have to double-submit within one turn's latency to
hit it) but a self-managed run makes the background thread busy for much
longer stretches, so it needs an explicit guard: while
`@repl.autonomy_state` is `:running` or `:paused`, free-text input (not
starting with `/`) is rejected with a short hint ("(self-managed run in
progress — /pause or /stop first)"); slash commands still go through. This
is also exactly the mechanism that satisfies the Goal doc's "no need to
implement interfering with new request yet" — new free-text input is
inert while self-managing, on purpose, until a future doc adds it.

## §3. The self-managed continuation loop

This is the actual "keep going after the verdict" behavior, built on top of
§1 (bound) and §2 (interruptible) — it should not ship ahead of either.

### Config

```yaml
session:
  self_manage: false   # keep going after a Judge checkpoint instead of waiting for the next human message
```

```ruby
def self_manage?
  v = dig(:session, :self_manage)
  v.nil? ? false : !!v
end
```

**Defaults `false`**, unlike `planner_enabled?`/`judge_enabled?`
(`config.rb:131-144`), which both default `true`. Those two are read-only/
advisory — worst case a bad Planner/Judge call wastes one round trip. This
changes the execution model itself: the Player keeps *acting* (calling
real, side-effecting MUD tools) unattended, turn after turn, until
something stops it. That's a materially bigger blast radius, and the
control/budget rails in §1-§2 are new and unproven, so this follows the
project's own evidence-gated posture elsewhere (`tasks.compactor.enabled`
defaults off pending its own eval, per `settings.yaml:140-143`) rather than
the Planner/Judge precedent of flipping straight to on.

### Mechanics

`Repl#run_turn` (`repl.rb:174-213`) already does everything one turn needs:
seed the plan once (`maybe_seed_plan`, idempotent via `@planned`), add the
user message, run the `Agent`, print the result, and check in with the
Judge if a checkpoint fired (`maybe_check_judge`). Because
`maybe_seed_plan`'s guard is already idempotent, **calling `run_turn` again
with `Session::CONTINUE_INSTRUCTION` is already exactly what
`Boukensha::Session.play`'s own loop does** (`session.rb:152-153`) — no new
turn machinery is needed, only a driver that decides whether to call it
again.

Split `run_turn` into the existing body (renamed `perform_turn`, unchanged
behavior) plus a thin wrapper that loops when self-managing:

```ruby
def run_turn(input)
  agent = perform_turn(input)
  maybe_continue_self_managed if agent
end

private

def perform_turn(input)
  @turn += 1
  @goal ||= input
  maybe_seed_plan(input)
  @context.add_message(:user, input)
  agent = Agent.new(...)     # unchanged from today's run_turn body
  result = agent.run
  output("")
  output(result)
  @last_verdict = maybe_check_judge(agent)   # see below — now returns the verdict
  agent
rescue LoopError => e
  output("\n[error] #{e.message}")
  nil
rescue ApiError => e
  output("\n[error] API call failed: #{e.message}")
  nil
end

def maybe_continue_self_managed
  return unless Boukensha.config.self_manage?
  return if @last_verdict.nil? || @last_verdict == :flag   # no checkpoint, or Judge flagged — stop
  return if @agent_stop_reason == :completed                # Player says it's done — stop

  @autonomy_state = :running
  loop do
    return if wait_while_paused == :stopped

    case Boukensha.session_budget_status(@logger, Boukensha.config)
    when :exhausted
      output("(session cost budget exhausted — stopping self-managed run)")
      break
    when :warn
      perform_turn(WIND_DOWN_INSTRUCTION)
      break
    else
      agent = perform_turn(Session::CONTINUE_INSTRUCTION)
      break if agent.nil? || @agent_stop_reason == :completed || @last_verdict.nil? || @last_verdict == :flag
    end
  end
ensure
  @autonomy_state = :manual
end

def wait_while_paused
  return :stopped if @autonomy_state == :stopped
  sleep 0.2 while @autonomy_state == :paused && @autonomy_state != :stopped
  @autonomy_state == :stopped ? :stopped : :running
end
```

(Illustrative, not final — exact ivar bookkeeping for `@agent_stop_reason`
TBD during implementation, but the shape — `perform_turn` as the single
reusable unit, a loop around it gated by verdict/stop_reason/budget/
autonomy_state — is the intended design.)

Stopping conditions, all of which fall back to `:manual` (the human can
keep typing normally — nothing about the session/context/tools is torn
down):

1. **Judge verdict `:flag`** — same "surface, don't enforce" posture
   `repl_judge_integration.md` already chose for the human-driven path, now
   also the posture for the self-managed path: stop and let a human decide.
2. ~~`agent.stop_reason == :completed` — the Player itself said it's done,
   mirroring `Session.play`'s `break if agent.stop_reason == :completed`.~~
   **Reverted after real use.** `Session.play` is a single bounded goal, so
   "the model replied without calling a tool" reasonably means "the goal is
   done." `Repl`'s self-managed loop is an open-ended MUD *journey* with no
   single goal to complete — a plain text reply at the end of a turn is the
   ordinary case, not a signal the journey is over. Treating it as a stop
   condition meant the loop died after its very next "continue" turn almost
   every time (only a further limit-triggered wrap-up could keep it alive),
   which is the opposite of "keep going after a Judge checkpoint." Fixed by
   making `Repl#maybe_check_judge` force a Judge check-in after *every* turn
   while `self_manage?` is on — not only on `Session.checkpoint?`'s
   limit-triggered/`every_n_turns` cadence — so a plain completed turn still
   gets a verdict, and only the Judge (`:flag`) gets to end the journey.
3. **Cost budget exhausted or warned-and-wound-down** — §1.
4. **User hits `/stop` or `ctrl+x`** — §2.

`:replan` is *not* a stopping condition — same as `Session.play`
(`session.rb:185-195`), a replan just updates `ctx.plan` (already handled
inside the existing `maybe_check_judge` branch, unchanged) and the loop
continues on to the next `"continue"` turn.

### `maybe_check_judge` return value

Small, additive change: `maybe_check_judge` (`repl.rb:279-328`) currently
has no meaningful return value. Add an explicit return of the verdict
symbol (`:continue`/`:replan`/`:flag`), or `nil` when `@judge_enabled` is
false or no checkpoint fired this turn — the one new piece of information
`maybe_continue_self_managed` needs from it. No change to its existing
printed output or side effects.

### Threading `self_manage?` through `Boukensha.repl`/`Logger` snapshot

`Boukensha.repl` (`lib/boukensha.rb:162-275`) resolves `cfg.planner_enabled?`/
`cfg.judge_enabled?` and passes them into both `Repl.new` and the `Logger`
snapshot (`boukensha.rb:227-228`) for the same "why don't I see it"
self-documentation reason `repl_judge_integration.md` gives. Do the same
here: `self_manage: cfg.self_manage?`, `session_max_cost_usd:
cfg.session_max_cost_usd` both added to the `Logger.new(snapshot: {...})`
call at `boukensha.rb:217-231`.

## What does NOT change

- **`Agent#run`'s loop body** (`agent.rb:42-96`) — completely untouched,
  same as every prior doc in this series promised. Per-turn iteration/token
  limits and their own `wrap_up` wind-down are orthogonal to the session-
  level budget in §1, which only ever acts *between* `Agent#run` calls.
- **`Boukensha::Session`/`Session.play`** — unchanged. It stays the
  separate autonomous CLI driver; this doc does not make `Repl` call into
  it or vice versa, only mirror its `CONTINUE_INSTRUCTION`/checkpoint-loop
  *shape*.
- **No mid-turn preemption.** Pause and Stop are both checked only *between*
  turns (inside `maybe_continue_self_managed`'s loop), never inside an
  in-flight `Agent#run`. An in-flight tool call (e.g. a MUD command with a
  real side effect) always finishes before pause/stop takes effect — the
  existing `esc` → `Thread#raise(Interrupt)` hard-interrupt
  (`tui.rb:217-219`) remains the only way to abort mid-turn, and is
  unrelated to this doc.
- **Judge/Planner/Navigator task logic itself** — no prompt or tool-policy
  changes; only `Repl`'s driving of them changes.
- **Interfering with a new request/goal mid-run** — explicitly out of scope
  per the Goal doc; §2's input-guard makes this inert rather than silently
  broken, but building the actual "swap in a new goal" flow is deferred.

## Rollout / sequencing

Land in this order — each step is independently useful and safe with
`session.self_manage: false` (the shipped default), so §1 and §2 can merge
and be exercised for real before §3 ever changes what the Player does
unattended:

1. **§1** — `Logger#total_cost_usd`, `Config#session_max_cost_usd`/
   `#session_cost_warn_pct`, `Boukensha.session_budget_status`. Zero
   behavior change (nothing reads the total yet); verifiable purely by
   checking the accumulated number against a session's own log.
2. **§2** — `Repl` pause/resume/stop primitives, slash commands, TUI
   keybindings, status-line indicator, the concurrent-turn guard. Also zero
   behavior change while `self_manage: false` (autonomy_state simply never
   leaves `:manual`), but now independently testable and demoable.
3. **§3** — the self-managed loop, shipped **off by default**
   (`session.self_manage: false`). Turn on for real sessions, read the
   resulting JSONL/log_viz output the same way this project already
   evaluates Planner/Judge behavior (`docs/journal/3_capable.md` §1-§3b),
   before ever proposing the default flip to `true` that
   `repl_planner_integration.md`/`repl_judge_integration.md` did for their
   features.

## Deferred / explicitly out of scope

- Interfering with an in-flight self-managed run via a *new* goal/comment
  (not just pause/stop) — Goal doc says not needed yet.
- Mid-turn preemption of pause/stop (only between-turn, cooperative checks
  are in scope here).
- `--no-tui` mid-run pause/stop delivery (see "Open questions" — no second
  input thread exists there today).
- Per-task cost budgets (e.g. "Judge may not exceed $0.50") — this doc is
  one session-wide total across all tasks only, matching the Goal doc's
  "maximum cost consumption per session by ALL tasks" wording exactly.
- Resuming a *stopped* (not paused) self-managed run without re-issuing a
  new turn manually — `/stop` intentionally falls all the way back to
  manual, not to a resumable-later state; only `/pause` is resumable.

## Open questions

- **`--no-tui` has no way to deliver a pause/stop mid-run.** Plain
  `Repl#start` blocks on `$stdin.gets` in a single thread
  (`repl.rb:215-235`); once `maybe_continue_self_managed`'s loop is
  running, nothing is reading stdin until it exits. Slash commands still
  work for symmetry/tests when called directly, but a human at a plain
  terminal has no live way to trigger them mid-run — only Ctrl+C (which
  kills the process) or waiting for a stopping condition. Worth a startup
  warning when `self_manage: true` and `--no-tui` are combined; possibly
  worth deferring self-managed mode to TUI-only entirely rather than
  half-supporting `--no-tui`.
  A: Don't worry about --no-tui for now. Just assume that if I run --no-tui I will not be interfering with the session when it's running
- **Does `tasks.content_fact`/`tasks.compactor` Tier 2 share this `Logger`/
  `Client` path?** Both are Ollama-only today (`$0.0`, moot for the budget),
  but if either ever gains a paid backend, confirm they flow through the
  same `Logger#response`/`execution_metadata` choke point §1 relies on, or
  the session total would silently under-count.
  A: Yes. It should, in case if it's ever switched to paid backend. Right now since it's local cost is 0
- **Exact keybindings (`ctrl+p`/`ctrl+x`)** are a proposal, not a
  commitment — pick whatever's free once this is actually implemented and
  cross-checked against the bubbletea patch's key table
  (`patches/bubbletea/`).
  A: I prefer to use slash command. For example: to pause use /pause, to unpause use /continue, or to stop the session completely use /stop

## Acceptance criteria

- With `session.self_manage: false` (default), `Repl`/`Tui` behavior is
  byte-identical to today — same requirement `repl_judge_integration.md`
  and `worker.md` both hold themselves to for their own additive changes.
- `Logger#total_cost_usd` after a session equals the sum of every logged
  response's `cost_usd` across every `task:` value seen in that session's
  JSONL, Player and Planner/Judge/Navigator alike.
- `session.max_cost_usd: null` (or omitted) disables the budget entirely —
  `Boukensha.session_budget_status` always returns `:ok`.
- A self-managed run started with `self_manage: true` auto-issues
  `"continue"` turns without further human input until one of: Judge
  `:flag`, `agent.stop_reason == :completed`, budget `:exhausted`,
  `/stop`/`ctrl+x` — and each of those four is independently testable by
  forcing the relevant condition and asserting the loop exits with
  `autonomy_state == :manual`.
- `/pause` (or `ctrl+p`) stops further auto-continuation after the current
  turn finishes without ending the run; `/resume` (or `ctrl+p` again)
  picks back up with the next `"continue"` turn; neither aborts an
  in-flight turn.
- Reaching `:warn` produces exactly one further turn (the wind-down one)
  before the loop stops; reaching `:exhausted` produces zero further turns.
- Free-text input submitted while `autonomy_state` is `:running`/`:paused`
  is rejected with a visible hint and does not spawn a second
  `@turn_thread`; slash commands still work.
