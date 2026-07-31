# Boukensha — Ruby Steps

Each numbered folder is one iteration of the same agent, building on the
previous step. Full narrative/rationale for each step is in
[`ITERATIONS.md`](ITERATIONS.md); this file is the short operational
reference for actually running one.

```
00_config  01_struct_skeleton  02_the_registry  03_prompt_builder
04_api_client  05_agent_loop  06_the_logger  07_the_run_dsl
08_the_repl_loop  09_global_executable  10_standard_tool_library
```

`10_standard_tool_library` is the current latest step: boukensha as a
generic MCP host with zero built-in tools (see its own
[README](10_standard_tool_library/README.md)).

## Running a step

Two independent ways to run a step's code — pick one, don't mix them up:

**1. Directly, from inside the step's folder** — always runs *that*
folder's code, full stop. Nothing else (`.boukensharc`, an installed gem)
affects this path:

```sh
cd 10_standard_tool_library
BOUKENSHA_DIR=../../../.boukensha bundle exec ruby examples/example.rb
```

Or via a step's own `bin/` wrapper script, if one exists
(`week1_baseline/bin/ruby/<step>`), which just does the `cd`/`BOUKENSHA_DIR`
setup above for you.

**2. Via the global `boukensha` executable** (added in step 9) — installed
once as a gem, callable from anywhere. This is where **`~/.boukensharc`**
decides which step's code actually runs, and it's easy to get out of sync
with what you think is installed.

## Pointing `boukensha` at a step

`bin/boukensha` → `boukensha_loader.rb` resolves, independently for the
source path and the config dir, in this order — first one set wins:

1. `BOUKENSHA_PATH` / `BOUKENSHA_DIR` environment variables
2. `boukensha_path` / `boukensha_dir` in `~/.boukensharc`
3. the installed gem's own bundled `lib/`, and `~/.boukensha`

**The gotcha:** `gem build boukensha.gemspec && gem install
boukensha-X.Y.Z.gem` only changes what's *available* to install — it never
touches `~/.boukensharc`. If that file's `boukensha_path:` still points at
an older step folder, `boukensha` keeps running the **older step's source**
regardless of which gem version `gem list boukensha` shows installed. This
is exactly what happened in this project once: `~/.boukensharc` was left
pointing at `09_global_executable` after `10_standard_tool_library`'s gem
was built and installed — the REPL kept showing `v0.9.0` and, because step 9
predates the `mcp_servers:` rewrite entirely, couldn't see any MUD tools
either. Both symptoms were the one bug: the wrong step's code was running.

### Quick start

```sh
cp week1_baseline/ruby/.boukensharc.example ~/.boukensharc
# edit boukensha_path if your checkout isn't at the path baked into the example
```

### Verifying which step is actually running

Don't guess — check:

```sh
BOUKENSHA_DEBUG=1 boukensha
```

prints `[boukensha] loading from: <step_dir>` before anything else. Compare
that path to the step you meant to run. The REPL's startup banner
(`BOUKENSHA MUD Assistant (vX.Y.Z)`) is a second signal — cross-check `X.Y.Z`
against that step's `lib/boukensha/version.rb`.

### After making code changes

- **Editing a step's source directly**, with `boukensha_path` (or
  `BOUKENSHA_PATH`) pointed at that folder: changes are picked up on the
  next run immediately. No `gem build`/`gem install` needed — the loader
  `require`s `lib/boukensha.rb` straight from that path every time.
- **Building and installing a new gem instead**: update `boukensha_path` to
  point at that step's folder too (simplest — then you don't need the gem
  install at all), or delete `boukensha_path` from `~/.boukensharc` entirely
  so resolution falls through to whatever gem is currently installed. Either
  way, installing a gem by itself changes nothing about what `boukensha`
  actually runs until one of those two things also happens.
