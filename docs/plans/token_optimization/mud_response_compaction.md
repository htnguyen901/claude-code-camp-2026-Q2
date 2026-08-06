# Plan: Compacting MUD Tool-Result Text Before It Enters Context

## Goal

Every MUD tool call's reply — room descriptions, combat spam, social/emote
text, shop menus — gets appended to `@context.messages` verbatim today and
stays there for the rest of the session (until the coarse whole-history
compactor drops it, see "Relationship to existing compaction" below). MUD
game text is often written for a human reading a terminal, not for an LLM
tracking state: flavor prose, repeated ANSI/whitespace noise, and
narrative padding around a small number of facts that actually matter
(exits, HP, what's here, what changed). This plan adds a **compaction
step** that runs on each MUD tool result *before* it's added to context,
condensing it to the meaningful, LLM-relevant content — so a session can
run more turns before hitting the context window, and each request's
message-history portion costs fewer tokens.

**Not this plan**: `docs/plans/observability/tool_token_optimization.md`
already targets the *tool schema* block (57 tools' JSON definitions,
~25.7 KB, sent unchanged on every call). That's static, request-shaped
data. This plan targets a different, disjoint set of bytes: the
*tool-result message content* that accumulates in `@context.messages` as
the session progresses — the MUD's replies, not the tool catalog. The two
plans don't share code paths and can ship independently.

## Current state (grounded in the actual code path)

The full round-trip, today, with no compaction anywhere in it:

1. `Agent#handle_tool_calls` (`lib/boukensha/agent.rb:154-182`) dispatches
   each tool call: `result = @registry.dispatch(name, args)`
   (`agent.rb:173`).
2. For an MCP-backed MUD tool, `dispatch` (`registry.rb:19-22`) calls the
   block `Tools::Mcp.register_client` built (`tools/mcp.rb:52-59`), which
   calls `client.call_tool(remote, kwargs)` → `Mcp::Client#call_tool`
   (`mcp/client.rb:36-41`) → the MUD's raw reply text, joined from the
   MCP `content` array, returned as `result[:text]`.
3. Back in `handle_tool_calls`, that string is logged in full
   (`@logger.tool_result(name:, result:, ok:)`, `agent.rb:174`/`177` —
   this is the observability record and **must stay untouched**, see
   below) and then, **unmodified**, appended to context:
   `@context.add_message(:tool_result, result.to_s, tool_use_id: use_id)`
   (`agent.rb:180`).
4. That message sits in `@context.messages` and is re-sent, in full, on
   every subsequent API call of the session — `PromptBuilder#to_api_payload`
   serializes the whole message list every turn — until either the turn
   ends or `Context#compact_messages!` (`context.rb:64-71`) drops it as
   part of a blanket "oldest 40%" purge.

There is no per-message shaping anywhere in this path today. The nearest
prior art in the repo is **not** in this path at all:
`LogViz::ContentFact` (`week2_observability/log_viz/lib/log_viz/content_fact.rb`)
already does LLM-based structured extraction over MUD room text — but it
runs **out-of-band**, in `log_viz`'s own background worker thread, reading
from the `.jsonl` session log after the fact, writing to
`world_map.sqlite3`, and is explicitly documented as never feeding back
into the agent's context (`world_knowledge.rb:14-15`: *"nothing injects
this into its context automatically"*). It's a good template for *how* to
call a cheap local model and fail open — see Design §2 — but it solves a
different problem (durable world knowledge for a separate inspector tool)
and runs on a different clock (async, after the fact) than what this plan
needs (synchronous, in the agent's own turn, before the next request is
built).

## Design constraints, stated up front

- **The observability record is not the context record.** `@logger.tool_result`
  (`agent.rb:174`/`177`) must keep receiving the full, uncompacted
  `result` — it feeds the `.jsonl` session log, which `log_viz`,
  `WorldKnowledge`, and any future analysis depend on having at full
  fidelity. Compaction only changes what goes into
  `@context.add_message(:tool_result, ...)` on `agent.rb:180`. This is a
  one-line change in shape (compact the string passed to `add_message`,
  not the string passed to the logger) but worth stating as an explicit
  invariant, since it's easy to accidentally compact-in-place and lose the
  raw record.
  **Extension, added after initial ship**: `Logger#tool_result` now also
  accepts an optional `compacted:` argument, logged as an *additional*
  field on the same event (`result:` unchanged) — purely for visibility,
  since without it there was no way to see what actually got injected
  short of expanding a request's raw JSON payload in `log_viz`. `log_viz`
  buffers this across a batch of tool calls and renders it as an "Injected
  into next request" panel right before the following `request` entry
  (`log_viz/lib/log_viz/session.rb`, `log_viz/views/session.erb`). The
  invariant above is unchanged — `result:` is still the only field any
  downstream consumer should treat as ground truth.
- **Fail open, always.** If compaction errors, times out, or produces
  something that looks broken, fall back to the original raw text —
  exactly the posture `ContentFact.extract`/`extract_mentions` already use
  (`content_fact.rb:115-119`, `:156-160`: `rescue StandardError` →
  degrade, never raise) and `WorldKnowledge.room_knowledge` uses for a
  missing/corrupt DB (`world_knowledge.rb:82-90`). A compaction bug must
  never be the reason a turn breaks.
- **Errors are never compacted.** `handle_tool_calls` already distinguishes
  success/failure (`agent.rb:172-178`); an `"ERROR: ..."` result is short,
  structured, and exactly the kind of thing the agent needs verbatim to
  self-correct. Skip compaction whenever `ok` is false.
- **Cheap replies pass through untouched.** Most MUD replies are already
  short (`"You move north."`, `"Ok."`, a one-line combat swing). Gate
  compaction on a minimum length (in characters, cheap to check before
  spending any latency) so the common case costs nothing extra.
- **Scope: MUD-sourced tool results only, hard-coded.** Only tool names
  under the MUD MCP server's prefix (`tbamud__*`) are candidates — this is
  a literal constant in `Compactor`, not derived from `mcp_servers:`
  config, since this project targets tbaMUD specifically (resolved, Open
  Questions §1). A future filesystem/other MCP server's output (code, file
  contents) is never touched.

## Design: three tiers, ordered by risk (same shape as the sibling tool-schema plan)

### Tier 0: deterministic normalization — always on

Strip what's pure noise, never information: ANSI/VT100 color escape
codes (CircleMUD emits these when a character has color prefs on —
`Primitives`/`Session` pass raw bytes through, nothing currently strips
them before they reach context), trailing telnet prompt fragments (the
`"> "` `Session#read_until_prompt` leaves attached), and collapsing
runs of blank lines/repeated whitespace. Zero semantic loss — this is
"the MUD's bytes are noisier than needed," not summarization.

**Verification**: fixture-based unit tests, input → exact expected
output, byte-for-byte. No live model, no live MUD needed.

### Tier 1: structure-aware trimming — always on, no model call

CircleMUD's `look`/`examine` replies have a fairly fixed shape: a room
title line, a free-form prose paragraph, itemized "`X is here.`"-style
lines, and a trailing `[ Exits: ... ]` line (the same shape
`WorldKnowledge`/`ContentFact`'s `room_contents` itemization already
assumes — see `content_fact.rb`'s header comment on why itemized lines
and prose are treated differently). Keep the structured parts —
title, itemized contents, exits — **verbatim**: they're already compact,
and they're exactly what `WorldKnowledge`-style consumers key off of, so
mangling them would break more than it saves. Only the free prose
paragraph is a compaction candidate, and only once it clears the Tier-0
length gate.

**Verification**: fixture tests over a handful of realistic CircleMUD-shaped
replies (title/prose/items/exits), asserting the structured fields survive
character-for-character and only the prose paragraph is ever touched.

### Tier 2: LLM-based prose compaction — opt-in, default off until evaluated

For the free-form prose portion isolated by Tier 1 (long room
descriptions, narrated combat rounds, social text), run one small model
call that reduces it to the handful of facts an agent actually needs:
what's notable, what changed, anything actionable — dropping flavor
adjectives and repeated scene-setting.

**Model call shape (resolved, Open Questions §2): reuse boukensha's own
backend abstraction, not a bespoke Ollama call.** Rather than mirroring
`ContentFact.call_ollama`'s raw HTTP call to one hardcoded provider,
`Compactor` is handed an already-constructed `Backends::*` instance (any
of `Anthropic`, `OpenAI`, `Gemini`, `Ollama`, `OllamaCloud` — whichever
`tasks.compactor.provider`/`model` name) and drives it through the exact
same `Context`/`PromptBuilder`/`Client` path `Agent` uses for a real turn:
a throwaway one-message `Context`, `tools: []` so no tool schema is ever
sent, and `Client#call`'s existing retry/timeout behavior for free.
Default stays local Ollama (zero marginal cost, matches `ContentFact`'s
precedent), but switching provider/model is a `settings.yaml` edit — see
the step README's "switching the compactor's model" section.

**The one real architectural difference from `ContentFact`**: this call is
**synchronous, in the agent's own turn**, not an async background-thread
job. `ContentFact`'s worker can take its time because nothing is waiting
on it; here, the compacted text has to exist before `Agent#run`'s next
loop iteration builds the next request (`agent.rb:47`). That means this
tier's latency is *added turn latency*, not free background work — every
gated tool result pays one model round-trip (plus `Client`'s own retry
backoff if that backend is briefly unreachable). Two things bound that
cost:

- **The length gate already limits how often this fires** (Tier 0/1 skip
  the common short replies entirely).
- **Cache by content hash.** MUD room descriptions are static text keyed
  off room ID — revisiting a room produces byte-identical prose. Mirror
  `ContentFact.content_hash` (`content_fact.rb:97-99`, SHA256 of the raw
  string) as the cache key, so the same paragraph is only ever compacted
  once per session. **In-memory only, not persisted (resolved, Open
  Questions §3)** — no `world_map.sqlite3` writer coupling; the compacted
  text's only destination is the next request payload's tool-result
  message (e.g. an OpenAI-style backend's `function_call_output`), not
  durable storage.

**Verification — this is the tier that needs a real eval, not just a
diff** (same posture as the sibling plan's Tier 3):

1. `MudManager::FakeMud` (`week0_explore/mud_manager/lib/mud_manager/fake_mud.rb`)
   currently returns minimal fixture text (`"A nondescript room.\r\nExits:
   north.\r\n> "` — `fake_mud.rb:61`) — too short to exercise prose
   compaction at all. A prerequisite for this tier's testing is extending
   `FakeMud` with at least one longer, realistically-flowery room
   description fixture.
2. Build a small fixed task suite against that extended `FakeMud` (mirrors
   the sibling plan's suite, reusing `McpTestHelper#start_fake_mud` from
   `test/helper.rb:16-22`).
3. Run each task twice — once with Tier 2 off (today's behavior, full raw
   text in context), once on — and compare: task completion, whether the
   agent's next action still correctly reacts to state the prose
   contained (an exit it needs to take, an NPC it needs to address), and
   the actual token delta (via the existing request-payload/usage
   logging this repo already has, per
   `docs/plans/observability/token_composition_observability.md`).
4. Ship as default-on only once completion and next-action-correctness
   are unchanged — same "unchanged, not close" bar the sibling plan holds
   Tier 3 to, since this is the only tier here with real information-loss
   risk.
5. Until then, gate behind an explicit config flag (see below), off by
   default.

## Relationship to existing compaction

`Context#compact_messages!` (`context.rb:64-71`) is *reactive*: once
`current_tokens` crosses `compaction_threshold` (default 0.85 —
`context.rb:9`), it drops the oldest ~40% of messages wholesale,
regardless of what's in them. This plan's compaction is *proactive*: it
shrinks each MUD tool-result message's content **at insert time**, before
it ever contributes to `current_tokens`. The two are complementary, not
overlapping — smaller messages going in means the window fills slower and
more real turns survive before the reactive drop has to throw anything
away at all. No change needed to `context.rb`'s existing logic.

## Integration shape: named collaborator, not a generic hooks system

`Agent` is already a thin orchestrator: everything it does is delegate to
an injected, concretely-named collaborator (`context:, registry:,
builder:, client:, logger:` in its constructor — `agent.rb:15-16`) rather
than owning logic itself. `Compactor` follows that same shape: a plain
class, constructed once (in whatever wires up `Agent` today — the
`run_dsl`/task-construction path), passed into `Agent#initialize` as a new
named argument, and called with one line in `handle_tool_calls`:

```ruby
compacted = @compactor.compact(name: name, result: result, ok: ok)
@context.add_message(:tool_result, compacted, tool_use_id: use_id)
```

This is deliberately **not** a generic hooks/pipeline registry (e.g. a
`lib/boukensha/hooks/` directory with named extension points like
`:after_tool_result` that arbitrary future hooks register into), even
though compaction is unlikely to be the last cross-cutting step this
project adds. A hook-point interface designed against a single concrete
use case tends to guess wrong on the questions that actually matter once
a second hook shows up — can a hook abort the pipeline, do multiple hooks
run per point and in what order, does a hook see other hooks' output or
only the original — and this codebase's own convention (concrete named
collaborators, not generic plugin lists) already answers "how do we add
one more cross-cutting concern" today: give `Agent` one more named,
constructor-injected argument, the same way `logger:` or `registry:`
already work. If a second, third, and fourth hook do materialize later,
that's the right time to look at the 2-3 concrete call sites that exist by
then and extract a real hooks abstraction shaped by what they actually
need — not to build that abstraction now, speculatively, against one
example.

## Config surface

New `tasks.compactor` block in `settings.yaml`, read via `Boukensha::Config`
the same way `tasks.content_fact` already is for `log_viz`
(`config.rb`'s `tasks(name = nil)` helper already supports this shape with
no change needed):

```yaml
tasks:
  compactor:
    enabled: false        # Tier 2 opt-in; Tiers 0/1 always run
    provider: ollama       # any of: anthropic, openai, gemini, ollama, ollama_cloud
    model: gemma4          # must be one that `provider` actually supports
    host: http://localhost:11434  # only used when provider: ollama
    min_chars: 400         # length gate before Tier 2 fires at all
```

`provider` selects any backend boukensha already supports (resolved, Open
Questions §2) via the same `build_backend` selection `Boukensha.run`/`.repl`
use for the main agent loop; a cloud provider picks up its API key from the
same env var the main agent uses (`ANTHROPIC_API_KEY`, etc.). `model` must
be one `provider`'s `Backends::*` class actually lists in its `MODELS`
table — an unsupported combination degrades to Tier 2 disabled for that
session (logged, not fatal), never blocks boot.

## Files touched

- `lib/boukensha/compactor.rb` (new) — Tier 0/1 (pure functions, no I/O)
  and Tier 2 (cache + a one-shot call through an injected `Backends::*`
  instance via `Context`/`PromptBuilder`/`Client`), analogous in spirit to
  `LogViz::ContentFact`'s fail-open posture but living in `boukensha` since
  it runs in the agent's own hot path, not `log_viz`'s, and reuses
  boukensha's own request machinery rather than a bespoke HTTP call.
- `lib/boukensha/agent.rb` — new `compactor:` constructor argument
  alongside `context:, registry:, builder:, client:, logger:` (`:15-16`);
  `handle_tool_calls` (`:154-182`) calls `@compactor.compact(...)` and
  passes the result into `add_message` (`:180`) instead of the raw
  string. `@logger.tool_result` (`:174`/`:177`) stays untouched, still
  receiving the raw `result`, per the invariant above.
- `lib/boukensha/config.rb` — a `compactor_*` accessor group mirroring the
  existing `agent_*`/`tasks` accessors, reading the new `tasks.compactor`
  block.
- `lib/boukensha.rb` — extracts the backend-selection `case` and API-key
  lookup already duplicated between `.run`/`.repl` into shared
  `build_backend`/`resolve_api_key` helpers, so `build_compactor` can
  construct a real backend for Tier 2 the identical way, for whichever
  provider `tasks.compactor.provider` names.
- `week0_explore/mud_manager/lib/mud_manager/fake_mud.rb` — add at least
  one longer, prose-heavy room-description fixture (Tier 2 eval
  prerequisite).
- `test/test_compactor.rb` (new) — Tier 0/1 fixture tests plus
  deterministic Tier 2 tests (gate/cache/fail-open) against a small
  in-test fake backend, no live model or live MUD needed.
- Step README — documents how to point `tasks.compactor` at a different
  provider/model.

## Rollout order

1. **Tier 0** — ship first. Zero risk, purely mechanical noise removal.
2. **Tier 1** — ship next. No model call, deterministic, reviewable as a
   byte diff against a small fixture set; the risk is entirely "did the
   structure-parsing regex correctly identify title/items/exits," checked
   by the fixture tests, not by any live-model judgment call.
3. **Tier 2** — land behind `tasks.compactor.enabled: false` first, build
   the `FakeMud` fixture + eval suite, run the comparison, and only flip
   the default once completion/correctness are confirmed unchanged.

## Open questions — resolved

1. **Scope beyond MUD tools**: should compaction ever apply to non-MUD MCP
   servers if/when they're added, or should it stay hard-scoped to the
   `tbamud__` prefix indefinitely? Leaving it prefix-scoped is the safer
   default (this plan assumes that); flag if you want a more general
   per-server opt-in instead.
   A: For now this project is developed solely for tbaMUD, so we will keep it
   hard-coded to tbaMUD
2. **Tier 2's model**: reuse local Ollama (zero marginal cost, matches
   `ContentFact`'s existing pattern, but adds real per-call latency inside
   the synchronous agent turn — unlike `ContentFact`'s background thread)
   vs. the same backend/model already paying for the main agent loop
   (no new dependency, faster wall-clock since no extra local daemon
   round-trip, but real per-call **token cost** on every gated tool result,
   which cuts against this plan's own goal if the compaction call itself
   isn't cheap). Recommend starting with local Ollama, matching
   `ContentFact`'s precedent — confirm before implementation.
   A: re-use local Ollama for now, but allows to choose any backend provided
   by boukensha. Also add how to switch model in the README.md file
3. **Cache persistence**: is an in-memory (per-session, lost on restart)
   cache enough, or is it worth persisting compacted text across sessions
   the way `ContentFact` persists into `world_map.sqlite3`? Persisting
   would mean `boukensha` becomes a *writer* to a database `log_viz`
   currently owns exclusively (today `WorldKnowledge` is read-only against
   it, by design — `world_knowledge.rb:1-9`), which is a real coupling
   direction change worth deciding explicitly rather than defaulting into.
   A: No, the compactor should condense the response then pass to context 
   assuming this lives in the output: of type:function_call_output in 
   request payload
