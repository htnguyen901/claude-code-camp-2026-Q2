# Carrying the `11_tui` deltas into `12_context`

## Context

`week1_baseline/ruby/12_context` is an untracked copy (no git history of its
own), same as `11_tui` was in the earlier `tui_step_sync` plan. It was forked
from a base of similar vintage to `11_tui`'s original fork point — i.e.
*before* the mud_manager MCP tool catalog grew, and before two of the demo/
example task strings were finalized — and then had its own substantial
"context management" feature work layered on top (accurate context-window
tracking, auto-compaction, reasoning/thinking normalization across every
backend, the OpenAI Responses API migration, the `Bundler.with_unbundled_env`
MCP-spawn fix, `Boukensha::Models`, the `max_turn_tokens` circuit breaker).

This plan was produced by running `diff -rq` / `diff -u` between `11_tui` and
`12_context` in full. **The result is the opposite shape of the `10→11`
sync**: `12_context` is architecturally *ahead* of `11_tui` in almost every
file that differs, not behind. `bin/`, `patches/`, `boukensha.gemspec`,
`Gemfile`, and the bulk of `lib/` (`client.rb`, `message.rb`, `registry.rb`,
`run_dsl.rb`, `tasks/base.rb`, `tasks/player.rb`, `tool.rb`, `tools/mcp.rb`,
`boukensha_loader.rb`) are byte-identical between the two directories — there
is no TUI-plumbing gap to close this time. The only things actually missing
from `12_context` are the same class of stale-fixture issues the `10→11` plan
fixed: `mud_manager`'s tool catalog having grown, and two demo/example task
strings that were polished in `11_tui` after `12_context`'s fork point.

## Non-goals

Do **not** touch these — `12_context`'s versions are intentionally newer or
already correct:

- `lib/boukensha/context.rb` — `Context#initialize` in 12 no longer takes a
  `task:` keyword (system/context_window/working_dir/compaction_threshold
  only). Do not add `task:` back; `11_tui`'s signature is the *older* shape.
- `lib/boukensha/agent.rb`, `lib/boukensha/config.rb`, `lib/boukensha/logger.rb`,
  every file under `lib/boukensha/backends/`, `lib/boukensha/models.rb` — 12's
  versions are strictly ahead of 11's (reasoning/thinking normalization,
  `max_turn_tokens`, compaction, the OpenAI Responses API rework,
  `spawn_unbundled`). Copying 11's versions over these would be a regression.
- `examples/mcp_mud_demo.rb`'s bad-input probe line — 12 already exercises
  `tbamud__cast_spell`; 11 is the one still stuck on the stale `tbamud__move`
  probe. Leave 12's line as-is. (Fixing 11 to match is a one-line cleanup
  worth doing separately, but it's outside this plan's direction of travel.)
- `Gemfile.lock` — the `boukensha (0.12.0)` version stamp and the extra
  `gum (0.3.2-x86_64-linux)` platform line are artifacts of step 12's own
  gemspec version and a `bundle lock` run, not hand-authored content to sync.
  Leave as-is; regenerate naturally via `bundle install` only if it's ever
  actually broken, not as part of this port.
- `README.md` — 12's README already documents the full step-12 feature set
  and never references the stale tool count or task strings being fixed
  below, so no doc sync is needed for these deltas (confirmed via grep for
  "26", "57", "Big Minotaur", "Connect to the MUD" — no hits in either
  README).

## Deltas to port

### 1. `test/test_mcp_servers_config.rb` and `test/test_tools_mcp.rb` — stale mud_manager assertions (highest priority, same root cause as the 10→11 sync)

`12_context` was forked at a point when mud-manager's reflected `Primitives`
surface was still 26 tools; it's since grown to 57 (already fixed in
`11_tui`). Two assertions need updating, confirmed via `diff -u` to be the
*only* differences in each file:

- `test_mcp_servers_config.rb`: `assert_equal({ "mud" => 26 }, summary)` →
  `{ "mud" => 57 }`.
- `test_tools_mcp.rb`: `assert_match(/collision on 'tbamud__look'/, ...)` →
  widen to `/collision on 'tbamud__\w+'/` — which tool collides first is
  alphabetical-order dependent, not a stable specific name (this is 11's
  fix, already applied there).

Copy 11's current versions of both files over 12's wholesale.

### 2. `examples/example.rb` — restore the `"Connect to the MUD, "` prefix

11: `"Connect to the MUD, Look at your surroundings, check your score, ..."`;
12 dropped the `"Connect to the MUD, "` prefix. Update the task string only.

### 3. `examples/mcp_mud_demo.rb` — restore the debugged end-to-end task

11's final `Boukensha.run` call uses the task that was actually debugged
end-to-end against the live daemon: `"Connect to the MUD, log in as player
dummy then find and defeat the Big Minotaur in the newbie zone"`. 12 still has
a generic placeholder (`"Look at your surroundings, check your score, then
look at the exits and tell me what you see."` — the same string used in
`example.rb`), which defeats the point of having two distinct demos. Update
only this task string; leave everything else in the file — including the
`tbamud__cast_spell` bad-input probe line, which 12 already has correctly and
11 doesn't — untouched (see Non-goals).

## Order of operations

1. Port the two test files first, so the suite reflects the current
   `mud_manager` tool surface.
2. Run `12_context`'s test suite (`rake test`) to confirm it's green against
   the live `mud-manager --mcp` binary on `PATH`.
3. Sync the two example task strings.
4. Manually smoke-test `examples/mcp_mud_demo.rb` and `bin/boukensha` (both
   `tui:` and `--no-tui`) in `12_context`.

## Verification

- `cd week1_baseline/ruby/12_context && bundle exec rake test` — all tests
  pass, including the two updated MCP config/collision tests.
- Run `examples/mcp_mud_demo.rb` in `12_context` and confirm it completes the
  Big Minotaur task, same as previously validated in `11_tui`.
- Manually run `bin/boukensha` (and `--no-tui`) from `12_context` against the
  repo-root `.boukensha` config, and confirm: the MCP connection succeeds
  (exercising the `spawn_unbundled`/`Bundler.with_unbundled_env` path),
  context-window usage tracking and colour-coding update as documented in
  12's README, and `/compact` works.

## Appendix — why this diff looks inverted from the 10→11 sync

`tui_step_sync/README.md` ported bug fixes *forward* because `11_tui` was
behind `10_standard_tool_library` at the time. Here the roles are reversed for
nearly every file: `12_context` is a feature superset of `11_tui`, and only
two narrow categories of test/content staleness need to flow forward from 11
into 12. Worth flagging for whoever does the `12→13` sync next: `11_tui`'s
`mcp_mud_demo.rb` bad-input probe (`tbamud__move`) is itself stale relative to
`12_context`'s (`tbamud__cast_spell`) — not part of this plan, but a one-line
fix worth doing in `11_tui` separately so the two steps don't keep drifting in
opposite directions on the same file.
