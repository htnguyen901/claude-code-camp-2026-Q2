# `~/.boukensharc`

See [`../../../week1_baseline/ruby/README.md`](../../../week1_baseline/ruby/README.md)
for the operational how-to; this doc tracks the artifact itself — what it
is, why it's easy to get wrong, and what's already gone wrong.

## What it is

A YAML file in the user's home directory (`~/.boukensharc`), read by
`boukensha_loader.rb` (added in step 9, `09_global_executable`). It resolves
two independent things, each in this priority order — first one set wins:

1. `BOUKENSHA_PATH` / `BOUKENSHA_DIR` environment variables
2. `boukensha_path:` / `boukensha_dir:` in the rc file
3. the installed gem's own bundled `lib/`, and `~/.boukensha`

`boukensha_path` decides **which step's source code the global `boukensha`
executable actually runs.** `boukensha_dir` decides where it keeps
`settings.yaml`, `.env`, `prompts/`, and session logs.

## Why it's a floating artifact

It lives in `$HOME`, outside every step's own folder and outside the repo
entirely — no step's git history touches it, and it is not regenerated,
validated, or even referenced by `gem build`/`gem install`. Every step from
9 onward is written assuming it resolves correctly, but nothing enforces
that assumption. Two independent things (the rc file's *content*, and
whichever gem happens to be *installed*) can silently drift apart, and nothing
will error — `boukensha` will just quietly run the wrong step's code.

## Incident 1 — step 9 → step 10 rewrite: YAML rc support regressed

Summarized from `10_standard_tool_library/README.md`'s Technical
Considerations (that file is the only record of this incident; no more
detailed writeup than this exists, despite this doc having been linked from
there as "the incident writeup" since before it existed):

Step 9 introduced `~/.boukensharc` supporting a YAML mapping
(`boukensha_path:` / `boukensha_dir:` keys) as well as backward compatibility
with an even older bare single-line-path format. Step 10's initial rewrite
of `boukensha_loader.rb` (part of the larger MCP-host rewrite that step
shipped) didn't carry that support forward — it silently mis-parsed
step-9-era rc files rather than erroring. It was fixed by restoring the
step-9 loader behavior verbatim.

## Incident 2 — stale `boukensha_path` survives a new gem install

Full account, this session: a user built and installed
`boukensha-0.10.0.gem` from `10_standard_tool_library`, then ran the global
`boukensha` executable expecting step 10's MCP-host behavior. Instead:

- The REPL banner read `BOUKENSHA MUD Assistant (v0.9.0)` — the *old*
  version.
- The agent could not see or connect to the MUD at all, despite
  `settings.yaml` having a correct `mcp_servers: mud:` block.

Root cause: `~/.boukensharc` had

```yaml
boukensha_path: .../week1_baseline/ruby/09_global_executable
```

left over from earlier work on step 9. `BOUKENSHA_PATH` was unset, so per
the resolution order above, the loader used the rc file's `boukensha_path`
and required `boukensha.rb` straight out of the **step 9** folder —
completely bypassing the freshly-installed 0.10.0 gem, regardless of it
being the only version `gem list boukensha` showed installed.

Both symptoms were the *same* bug, not two: step 9 predates the entire MCP
rewrite. Its `Config` only reads a flat `mud_host`/`mud_port`/
`mud_username`/`mud_password` from a `mud:` block — there is no
`mcp_servers` method, no `Tools::Mcp`, nothing that understands the
`mcp_servers:` block the user's `settings.yaml` actually had. Step 9's code
registered zero MUD tooling no matter how correctly `mcp_servers:` was
configured, because it wasn't reading that part of the config at all.

**The lesson:** `gem build && gem install` changes what version is
*available*; it never touches `~/.boukensharc`. The two are entirely
independent, and whichever one you didn't just update is the one that keeps
running.

### Fix delivered

- [`week1_baseline/ruby/.boukensharc.example`](../../../week1_baseline/ruby/.boukensharc.example) —
  a copyable template pointing `boukensha_path` at the current latest step,
  with comments spelling out this exact gotcha inline.
- [`week1_baseline/ruby/README.md`](../../../week1_baseline/ruby/README.md) —
  the two ways to run a step, how rc resolution works, how to verify which
  step is actually running (`BOUKENSHA_DEBUG=1 boukensha` prints
  `[boukensha] loading from: <dir>` — don't guess, check), and what to do
  after code changes depending on which run-mode you're using.

## Checklist before touching `boukensha_loader.rb`, or anything it depends on, in a future step

- [ ] Keep supporting **both** the YAML rc format (`boukensha_path:` /
      `boukensha_dir:`) **and** the pre-step-9 bare single-line-path format
      — step 10 had to restore this once already (Incident 1).
- [ ] Keep the priority order exactly as-is: env vars → rc file → bundled
      default. Both incidents above depend on this ordering being predictable.
- [ ] Don't assume installing a new step's gem makes `boukensha` pick it up.
      When a new step becomes "the one to run," update
      `week1_baseline/ruby/.boukensharc.example`'s `boukensha_path` to point
      at it, so `cp .boukensharc.example ~/.boukensharc` stays correct.
- [ ] Keep the `BOUKENSHA_DEBUG=1` startup line (`[boukensha] loading from:
      <dir>`) working — it's the fast, non-guessing way to check which
      step's source is actually active.
