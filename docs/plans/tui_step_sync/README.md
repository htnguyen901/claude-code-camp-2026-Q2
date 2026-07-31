# Carrying the `10_standard_tool_library` deltas into `11_tui`

## Context

`week1_baseline/ruby/11_tui` is an untracked copy (no git history of its own)
that was branched from `10_standard_tool_library` at commit `901b130` ("add
standard tool lib"), *before* the two MCP-focused commits landed:

- `0347918` — add mcp server to communicate with MudManager
- `32dfa05` — fix delay reading from mcp due to buffer messages in mud

`11_tui` then had TUI-only work (`Boukensha::Tui`, the `patches/` dir, the
`tui:`/`--no-tui` plumbing, `charm` dependency) layered on top of that older
base. It never picked up the MCP client bug fixes or the follow-on test/example
updates that `10_standard_tool_library` got afterward. This plan enumerates the
exact deltas (confirmed via `diff -rq`/`diff -u` between the two directories)
and the order to port them in, without disturbing the TUI-specific code.

## Non-goals

Do **not** touch these — they are intentionally 11-only or already correct:

- `lib/boukensha/tui.rb`, `patches/` — TUI-only, no equivalent in step 10.
- `lib/boukensha/repl.rb` — already refactored in 11 for TUI composability
  (`on_output`, `handle_command`, public `run_turn`). Step 10's `repl.rb` is
  the *older* shape; do not copy it over 11's.
- `lib/boukensha.rb`, `lib/boukensha_loader.rb`, `boukensha.gemspec`,
  `Gemfile`, `lib/boukensha/version.rb` — 11's diffs from 10 here are only the
  `tui:`/`--no-tui` wiring and the `charm` dependency/version bump. No MCP
  logic differs in these files; leave as-is.

## Deltas to port

### 1. `lib/boukensha/mcp/client.rb` — critical bug fixes (highest priority)

11's copy is missing both fixes from `32dfa05`/`0347918`'s follow-up work,
which are the exact "server closed the connection" bugs recorded in
`docs/journal/1_baseline.md`:

- `clear_bundler_env!` is missing entirely, and `initialize` never calls it.
  Without it, spawning a server under `bundle exec` (i.e. every launcher
  script) leaks the parent's `BUNDLE_GEMFILE`/`BUNDLE_LOCKFILE`/
  `BUNDLER_VERSION`/`RUBYOPT` into the child. If the child is a different gem
  (e.g. `mud-manager`) not listed in boukensha's own Gemfile, Bundler refuses
  to resolve it and the child dies silently before printing anything.
- `read_until` no longer surfaces the child's stderr when the connection
  closes unexpectedly — it just raises `"server closed the connection"` with
  no detail, which is exactly the symptom that took hours to diagnose the
  first time.

No TUI-specific code exists in this file — 10's current version can be copied
over 11's wholesale.

### 2. `lib/boukensha/backends/openai.rb` — content-must-be-a-string fix

`to_messages` in 11 builds the system message as
`{ role: "system", content: system }`; 10 has `content: system.to_s`. This is
the "OpenAI requires content to be string and not null" fix from the journal's
Agent Loop notes. Same as above — this is the only difference in the file, so
copy 10's version over wholesale.

### 3. `test/test_mcp_servers_config.rb` and `test/test_tools_mcp.rb` — stale assertions

Both tests assert against the *live* `mud-manager --mcp` binary's reflected
tool count, which has grown since 11 was forked (`{"mud" => 26}` in 11 vs.
`{"mud" => 57}` in 10; a collision-message regex pinned to a specific tool
name changed too). These aren't independent bugs — they're the test suite
catching up to `mud_manager`'s current `Primitives` surface. Copy 10's
versions of both files over 11's; there is no other content difference to
preserve.

### 4. Examples — sync task wording (lower priority, no functional risk)

- `examples/example.rb`: 10's task is `"Connect to the MUD, Look at your
  surroundings, ..."`; 11's drops the `"Connect to the MUD, "` prefix. Update
  the task string only — keep 11's extra header paragraph explaining this is
  the one-shot demo (that paragraph doesn't exist in 10 and is correct/useful
  for 11).
- `examples/mcp_mud_demo.rb`: 10 exercises the actual task that was debugged
  end-to-end (`"...log in as player dummy then find and defeat the Big
  Minotaur in the newbie zone"`) and a `tbamud__cast_spell` bad-input probe;
  11 still has an earlier, simpler placeholder task and a `tbamud__move`
  probe. Bring the task string and the bad-input probe line up to match 10.

### 5. `README.md` — sync the shared MCP section (docs only)

11's README has its own "What's new" section for the TUI that doesn't exist
in 10, plus the shared "standard tool library is MCP" framing that predates
the TUI. Only the shared framing needs a light sync, not a replacement:
- 11 is missing 10's note that the gemspec declares no tool dependencies
  (10's wording) — 11 currently only mentions this in the TUI-dependency
  context. Leave as-is unless it reads as contradictory once the other
  changes land; this is optional polish, not a functional delta.
- Leave every TUI-specific subsection (`Boukensha::Tui`, the `tui:` keyword,
  the `Repl` composability table) untouched.

## Order of operations

1. Port `mcp/client.rb` and `backends/openai.rb` (the actual bug fixes) first
   — these are the ones that make `11_tui` functionally match `10`'s MCP
   behavior.
2. Port the two test files so the suite reflects the current `mud_manager`
   tool surface.
3. Run `11_tui`'s test suite (`rake test` or equivalent) to confirm it's
   green against the live `mud-manager --mcp` binary on `PATH`.
4. Sync the example task strings.
5. Optional README polish.

## Verification

- `cd week1_baseline/ruby/11_tui && bundle exec rake test` — all tests pass,
  including the two updated MCP config/collision tests.
- Manually run `bin/boukensha` (and `bin/boukensha --no-tui`) from `11_tui`
  against the repo-root `.boukensha` config that has the `mud:` MCP server
  configured, under `bundle exec`, and confirm the connection no longer dies
  with "server closed the connection" — this was previously untestable in
  `11_tui` specifically because of the missing `clear_bundler_env!` fix.
- Run `examples/mcp_mud_demo.rb` in `11_tui` and confirm it completes the
  same task 10 was validated against.
