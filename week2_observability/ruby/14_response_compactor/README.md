# Step 14 - Response Compactor

Branched from `13_room_inspector` (which stays the source of truth for the
context-management/TUI/MCP-host/`room_knowledge` framework this step
carries forward unchanged). This step's only addition is `Boukensha::Compactor`,
which shrinks a MUD tool result's text before it enters `@context.messages`,
so a session survives more turns before hitting the context window. Full
design/rationale: `docs/plans/token_optimization/mud_response_compaction.md`.

## Build

```sh
gem build boukensha.gemspec
gem install boukensha-0.14.0.gem
```

## What's new in this step

### `Boukensha::Compactor` — shrinking MUD replies before they enter context

MUD game text is written for a human at a terminal, not for an LLM tracking
state: flavor prose, ANSI/whitespace noise, and narrative padding around a
handful of facts that actually matter (exits, what's here, what changed).
`Agent#handle_tool_calls` now runs every MUD tool result through the
compactor before adding it to context — the `.jsonl` session log's
`tool_result` event still carries the full, raw, uncompacted text in its
`result` field (the observability record must stay untouched); a new
`compacted` field on that same event additionally records exactly what got
injected into context, purely for visibility (see "Seeing what got
compacted" below) — only `result` is ever the source of truth for
downstream consumers like `log_viz`'s `ContentFact`/`WorldKnowledge`. See
the compactor's own header comment (`lib/boukensha/compactor.rb`) for the
full tier breakdown, briefly:

- **Tier 0** (always on) — strips ANSI color codes, the trailing telnet
  prompt fragment, and collapses blank-line/whitespace noise. Zero semantic
  loss.
- **Tier 1** (always on, no model call) — splits a CircleMUD room echo into
  title / free-prose description / `[ Exits: ... ]` / itemized "X is here."
  content lines. The structured parts are reassembled byte-for-byte; only
  the free prose is ever a compaction candidate.
- **Tier 2** (opt-in, default off) — runs one model call over the isolated
  prose to cut it down to the facts an agent actually needs, cached by
  content hash so a revisited room's identical description is only ever
  compacted once. Gated behind `tasks.compactor.enabled` in
  `settings.yaml` until its eval (task completion / next-action correctness
  unchanged) is run.

Compaction is hard-scoped to tool names under the MUD MCP server's
`tbamud__` prefix — this project targets tbaMUD specifically, so the
prefix is a constant in `Compactor`, not config. Any compaction failure, at
any tier, fails open: the agent gets the original raw text rather than a
broken turn.

Tier 2 doesn't speak to one hardcoded provider's API — it reuses
boukensha's own `Context`/`PromptBuilder`/`Client` request path against
whichever `Backends::*` instance `tasks.compactor` configures, exactly the
same way the main agent loop talks to its own backend. That means the
compaction call gets the same retry/timeout behavior as any other API call
in the codebase, and switching it to a different provider or model is a
config change, not a code change.

### Switching the compactor's model

`tasks.compactor` in `settings.yaml` takes the same `provider`/`model`
shape as `tasks.player` (the main agent's own backend config):

```yaml
tasks:
  compactor:
    enabled: true
    provider: ollama              # anthropic | openai | gemini | ollama | ollama_cloud
    model: gemma4                 # must be a model that `provider`'s Backends:: class supports
    host: http://localhost:11434  # only read when provider: ollama
    min_chars: 400                # prose shorter than this skips Tier 2 entirely
```

- `provider: ollama` (the default) costs nothing per call and needs no API
  key — matches `log_viz`'s `ContentFact` precedent. Point `host` at a
  non-default Ollama daemon if needed (e.g. Ollama running on the Windows
  side of a WSL setup).
- Any other `provider` (`anthropic`, `openai`, `gemini`, `ollama_cloud`)
  picks up its credentials from the same environment variable the main
  agent uses for that provider (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
  `GEMINI_API_KEY`, `OLLAMA_API_KEY`) — nothing compactor-specific to set.
  This is a real per-call token cost, unlike the local-Ollama default, so
  weigh that against wanting a stronger model for the summarization itself.
- `model` must actually be listed in that provider's `Backends::*` class
  (e.g. `lib/boukensha/backends/anthropic.rb`'s `MODELS`) — an unsupported
  `provider`/`model` pairing is logged and degrades to Tier 2 disabled for
  that session; it never blocks the agent from starting, since Tiers 0/1
  never depend on this and must still run.

### Seeing what got compacted

Previously the only way to check what a request actually sent was to expand
that request's raw JSON payload in `log_viz`'s session viewer — awkward to
do for every iteration when you're specifically trying to watch compaction
behavior. `Boukensha::Logger#tool_result` now takes an additional
`compacted:` argument, logged alongside the untouched `result:` field on the
same `tool_result` event:

```json
{"phase": "tool_result", "name": "tbamud__look", "result": "<raw text>", "ok": true, "error": null, "compacted": "<what got injected>"}
```

`log_viz` (`week2_observability/log_viz`) reads this and renders an
**"Injected into next request" panel** right before each request block in
the session transcript — one entry per tool call since the last request,
each showing its post-compaction text and a char-count delta (e.g.
`512 → 210 chars (-59%)`, or `128 chars · unchanged` when nothing was
touched). No expanding required. Sessions logged before this change simply
have no `compacted` field and render exactly as before — the panel only
appears where there's something to show.

