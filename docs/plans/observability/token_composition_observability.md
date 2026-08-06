# Plan: Token Composition Observability (system / tools / messages)

## Goal

Before executing `docs/plans/tool_token_optimization.md`, be able to answer
"how many of this request's tokens are system prompt, how many are tool
schemas, how many are conversation history?" — per request, and trended
across a whole session — in `log_viz`, without guessing from raw bytes by
hand the way the tool-optimization plan's own "Current state" numbers were
produced.

This sits **between** the other two plans in the same directory:

- `request_payload_tracker.md` already gets the *raw payload* and its
  *byte size* into `log_viz`, per request. This plan is additive on top of
  that — no new logging format, no agent-behavior change, same "purely
  additive to `.jsonl` + the Sinatra viewer" contract.
- `tool_token_optimization.md` proposes three tiers of token reduction and,
  for each one, asks "how do we know it didn't regress?" This plan is the
  instrument that answers that question by making the before/after
  difference visible per component, instead of re-deriving it by hand from
  session logs the way this plan's own "Current state" section had to.

## Current state (what's missing, precisely)

- `log_viz` already has, per request (via `request_payload_tracker.md`):
  the full raw `payload`, its total `bytes`, and `message_count`/
  `tool_count`. It does **not** know how those bytes split between system
  prompt, tool schemas, and message history — today that split can only be
  computed by hand (which is exactly how `tool_token_optimization.md`'s
  25.7 KB / 70% `parameters` / 11% `description` numbers were produced: a
  one-off `python3` script against a raw session file, not anything visible
  in the UI).
- `log_viz` already has the **real, ground-truth token count** per call —
  `usage.input_tokens` from the `response` phase event
  (`session.rb:129-149`, feeding `@usage_series`) — but nothing connects
  that number back to *which part* of the request it was spent on.
- `log_viz` already tries to show cache savings, but **only in Anthropic's
  shape**: `UsagePoint`'s `cache_read`/`cache_creation` fields
  (`session.rb:19`, populated at `session.rb:143-144`) read
  `usage["cache_read_input_tokens"]`/`usage["cache_creation_input_tokens"]`
  — Anthropic's field names. OpenAI's actual response shape (confirmed from
  a real logged session) is `usage.input_tokens_details.cached_tokens`/
  `cache_write_tokens` — a different key path entirely. So today, for any
  OpenAI session, `cache_read`/`cache_creation` are silently always `0`,
  even on calls where the real response showed heavy cache use (3,584 of
  3,891 input tokens, in the session already used to write both other
  plans). This is the same "backend-shape-assumed-to-be-Anthropic's"
  category of bug `request_payload_tracker.md` fixed for `messages`/`tools`
  — it just hadn't been hit yet for `usage`. Fixing it is part of this plan,
  not a separate one, because Tier 1 of `tool_token_optimization.md` is
  specifically about caching, and its own verification step ("confirms
  `cached_tokens` rises") is unverifiable in the UI until this is fixed.

## Design

### 1. Split payload bytes into system / tools / messages, generically

Reuse `request_payload_tracker.md` §4's insight — the raw payload is
already logged and already gets split on the one universally-consistent key
(`tools`) for the UI's nested disclosure. This plan extends that same split
one step further, into three named buckets, using a small static
per-provider key table (this is analysis code in `log_viz`, not a new
per-backend branch in the agent's hot path — the agent/backends are
untouched):

```ruby
PROVIDER_KEYS = {
  "anthropic" => { system: ["system"],       messages: "messages" },
  "openai"    => { system: ["instructions"], messages: "input" },
  "gemini"    => { system: ["systemInstruction"], messages: "contents" },
  # Ollama folds the system prompt into messages[0] (role "system") rather
  # than a separate top-level key — handled as a special case: split off
  # the leading role=="system" message before treating the rest as history.
  "ollama"    => { system: nil,              messages: "messages" }
}.freeze
```

`Session#parse!` already knows the provider (`session_start`'s `provider`
field). For each `:request` entry, compute:

- `system_bytes` = `JSON.generate(payload.slice(*system_keys)).bytesize`
  (or, for Ollama, the leading system-role message's bytes)
- `tools_bytes` = `JSON.generate(payload["tools"]).bytesize` (same value
  §4 of `request_payload_tracker.md` already isolates for the nested
  `<details>`)
- `messages_bytes` = `JSON.generate(payload[messages_key]).bytesize` minus
  the system-role message for Ollama
- everything else (model name, `max_output_tokens`, `reasoning`, etc.) is
  fixed, tiny overhead — bucketed as "other" rather than ignored, so the
  three named buckets plus "other" always sum to the total.

This is pure computation over data already logged — no new log fields, no
agent-side change.

### 2. Calibrate the split against the real token count, per request

Byte counts alone would be misleading on their own — repetitive JSON
schema text and natural-language prose don't tokenize at the same
bytes-per-token rate, so a pure byte-based estimate would misstate the
split. Fix: **anchor every request's breakdown to that exact call's real,
already-logged `usage.input_tokens`**, and use the byte proportions only to
*divide* that real number, not to estimate it independently:

```
system_tokens   ≈ input_tokens_real × (system_bytes   / total_bytes)
tools_tokens    ≈ input_tokens_real × (tools_bytes    / total_bytes)
messages_tokens ≈ input_tokens_real × (messages_bytes / total_bytes)
other_tokens    ≈ input_tokens_real × (other_bytes    / total_bytes)
```

This requires pairing each `:request` entry with the `input_tokens` from
its *own* `response` event — the two are emitted back-to-back for the same
`iteration`/`turn` (`agent.rb`: `@logger.request(...)` then `@client.call`
then, on completion, `@logger.response(...)`), so `Session#parse!` (which
already processes events in file order) holds a reference to the most
recent unresolved `:request` entry and fills in its token-split fields the
moment the matching `response` event arrives in the same pass — no new
correlation ID needed, no second pass over the file.

**Why this is trustworthy despite being an approximation**: the four
buckets are constructed to always sum to exactly the real, provider-billed
`input_tokens` for that call — by construction, not by hope. So the
*total* is never in question; only the *apportionment between buckets* is
approximate. That's the right place for the approximation to live, because
apportionment error only affects which bar looks bigger in a breakdown
chart — it can never make the dashboard claim a session used more or fewer
tokens than it actually did, which is the number that actually matters for
verifying `tool_token_optimization.md`'s tiers (a real $/token reduction
will show up as a real drop in the totals no matter how the split is
apportioned).

### 3. Fix the cache-field bug (§ Current state) as part of this plan

`UsagePoint`'s cache fields need to read the right key per provider,
mirroring the same `PROVIDER_KEYS`-style small lookup rather than assuming
Anthropic's shape:

- Anthropic: `usage["cache_read_input_tokens"]` / `["cache_creation_input_tokens"]`
  (unchanged — this is what's there today and is correct for Anthropic).
- OpenAI: `usage.dig("input_tokens_details", "cached_tokens")` for reads;
  OpenAI's `cache_write_tokens` (confirmed present in real logged usage,
  currently always 0 in practice since writes aren't billed separately the
  way Anthropic's are — kept for shape-completeness, not because it's
  expected to be nonzero).
- Gemini: needs one real session to confirm the exact field name
  (`usageMetadata.cachedContentTokenCount` per the public API surface, to
  be confirmed against an actual response rather than assumed — same
  discipline `tool_token_optimization.md` already applied to Gemini).
- Ollama: no cache concept (see `tool_token_optimization.md` Tier 1) — both
  fields simply stay `0`, correctly, not as a bug.

This directly unblocks `tool_token_optimization.md`'s Tier 1 verification
step 2 ("confirms `cached_tokens` rises... without any change in the
transcript") — right now that check can only be done by grepping a raw
`.jsonl` file by hand (as this plan's own "Current state" section had to);
after this fix it's a number already on screen.

### 4. UI: per-request composition indicator (revised)

**First shipped as**: one extra text line in the summary — visible even
collapsed, next to the existing model/message-count/bytes line:

```
System 118 tok (3%) · Tools 3,584 tok (91%) · Messages 189 tok (5%) · cached 3,584 (92%)
```

**Problem found in use**: once §7's per-bucket cost landed too, that single
line grew to 6+ comma/dot-separated fields (tokens, %, and cost for four
buckets, plus cached, plus output). Readable for one request looked at in
isolation; illegible as a *list* — a turn with a dozen-plus iterations means
a dozen-plus of these long lines stacked in the transcript, one per request,
which defeats the actual point of this plan (spotting the odd request out at
a glance across a whole turn) rather than serving it.

**Revised design** — still zero new JS, still zero new disclosure widgets
beyond the one `<details>` `request_payload_tracker.md` already added; the
fix is presentation, not new data:

- **Collapsed summary** (visible without expanding, appended to the existing
  model/message-count/bytes/tool-count/cost line) shows only:
  - A small proportional bar, 4 segments (system/tools/messages/other)
    colored to match the session-wide chart's legend (§5) — glance at the
    fill and you see "this one's almost all tool schema" without reading a
    number.
  - The **dominant bucket's** label + share as the one number worth reading
    without a click, e.g. `Tools 99%` — this is the actual "is this request
    a problem" signal a busy turn needs.
  - A small `cached NN%` tag, shown only when cache_read is non-zero.
  - Full precision (exact token counts and cost per bucket) lives in the
    bar's native `title` tooltip (hover, no JS) for a quick check without
    opening the panel.
- **Expanded body** (inside `<details>`, so it only exists in the DOM
  reasoning a reader is already doing when they open one specific request)
  gains a small table above the raw payload dump: Bucket / Tokens / % of
  input / Cost, plus Cached and Output rows — reusing the existing
  `.breakdown-table` look (already used for the session-level cost-by-task
  table in `session.erb`) rather than inventing new table styling.

Net effect: the always-visible part of the transcript is exactly as dense as
it was before this plan touched it (one line, plus one slim bar) regardless
of how many iterations a turn has; full precision is one hover or one click
away instead of jammed into running text.

### 5. UI: extend the session-wide growth chart into a composition trend

`request_payload_tracker.md` §5 already draws one sparkline (message count
across the whole session). Extend `RequestPoint` with the same
`system_tokens`/`tools_tokens`/`messages_tokens` fields computed in §2, and
draw them as three lines. **Resolved** (open question 1, below): built as a
**second chart directly beneath** the existing message-count sparkline,
three lines overlaid (not stacked) on one axis — stacking would need
cumulative sums and reads worse for "did the tools line drop between two
runs" than three independent lines at their own true height. This is the
view that makes `tool_token_optimization.md`
Tier 1/2/3 before/after comparisons legible at a glance: run a task, land a
tier, run the same task again, and the tools line should visibly drop (or,
for Tier 1, the *cached* portion should visibly grow while the raw tools
line stays flat) without needing to diff raw JSON by hand.

### 6. Verification: how do we know the breakdown itself is trustworthy

- **Total is exact, not estimated** — per §2's construction, the four
  buckets for any given request always sum to that request's real
  `usage.input_tokens`. A unit test asserts this invariant directly (sum of
  computed bucket tokens == the real logged `input_tokens`, for a
  synthetic payload with known byte proportions) — this is checkable
  without any API call and holds regardless of how accurate the
  apportionment turns out to be.
- **Apportionment sanity check, once, not ongoing**: spot-check the
  byte-proportional split against a provider's real token-counting facility
  for one real payload per backend where available (Anthropic has a
  `count_tokens` endpoint; Gemini has `models.countTokens`; OpenAI's
  tokenizer is public/offline-computable) — call it once on the `tools`
  slice alone and once on the full payload, compare the ratio to what the
  byte-proportional method would have guessed, and note the error margin
  in this doc. This is a one-time calibration check, not a runtime
  dependency — the shipped feature never calls these endpoints.
- **No agent-behavior risk**: everything in this plan is `log_viz`-side
  analysis of already-logged data (plus the `UsagePoint` field-name fix in
  §3, which only changes what gets *read* from an already-received `usage`
  hash). Nothing here touches `agent.rb`, `client.rb`, or any
  `backends/*.rb` file — there is no code path by which this plan could
  change what the agent sends or how it behaves, which is why it carries
  none of `tool_token_optimization.md`'s Tier-3-style risk itself; it
  exists specifically so that plan's real risk can be measured before and
  after it ships.

### 7. Cost per request and per composition bucket

Not in the original design — added once the composition split was in front
of real data and the natural next question was "so how much did the
tool-schema bucket actually cost me." Same "no new agent-side change, pure
`log_viz`-side analysis of already-logged data" discipline as the rest of
this plan:

- `MODEL_PRICES` (`session.rb`) is extended from Anthropic-only to mirror
  every backend's `cost_per_million` table (OpenAI, Gemini, Ollama's
  free-tier zero rates) — duplicated locally rather than imported, matching
  the "log_viz has no dependency on the agent" constraint already governing
  §1/§3. OllamaCloud is intentionally left out: that backend itself has no
  fixed per-token price (`cost_per_million: { input: nil, output: nil }`),
  so there's nothing to mirror.
- Each composition bucket's real token count (§2) is priced at the model's
  list input rate; output tokens get their own line at the output rate.
  `system + tools + messages + other + output` is constructed to equal the
  request's total cost exactly — the same "sum is exact by construction, not
  verified after the fact" discipline §2/§6 already apply to the token
  buckets, now applied to their dollar cost.
- This total is independent of whatever `cost_usd` (if any) got logged for
  that call by the agent (`Logger#execution_metadata`, which itself doesn't
  apply any cache discount) — it's computed fresh from the token buckets so
  it stays internally consistent with the composition breakdown it's
  attached to, even if the two numbers drift slightly from a session
  recorded under different pricing.
- Unpriced models (not in `MODEL_PRICES`) yield `nil` cost fields
  throughout, rendered as "—" — matching `point_cost`'s existing
  unknown-model behavior, not a new failure mode.
- Tests (`test/test_session_cost.rb`): the sum-to-total invariant; a
  tools-heavy request attributing most cost to the tools bucket (the
  concrete case `tool_token_optimization.md` cares about); unpriced-model
  graceful nil; Ollama's free tier costing exactly `0.0`, not `nil`.

## Files touched

- `week1_baseline/log_viz/lib/log_viz/session.rb` — provider-keyed payload
  split (§1), request↔response pairing and token calibration (§2),
  `UsagePoint` cache-field fix (§3), `RequestPoint` gains the three token
  fields (§5), `MODEL_PRICES` extended and per-bucket cost computed (§7).
- `week1_baseline/log_viz/lib/log_viz/app.rb` — `composition_bar` (the
  glanceable summary indicator, §4), `composition_rows` (the expanded-body
  table's data, §4/§7), `composition_sparkline` (the session-wide chart,
  §5).
- `week1_baseline/log_viz/views/session.erb` — the composition bar in the
  request summary and the composition table in the expanded body (§4), the
  second chart beneath the message-count sparkline (§5).
- `week1_baseline/log_viz/public/style.css` — `--comp-*` color custom
  properties (single source for the bar segments, chart legend/lines, and
  swatches), the composition bar/tag/table styles (§4), the second chart's
  line styles (§5).
- `week1_baseline/log_viz/test/` (new — `log_viz` had no test directory
  before this plan) — `test_session_composition.rb` covers §6's
  sum-invariant; `test_session_cost.rb` covers §7's cost invariant.
- No files under `week1_baseline/ruby/12_context/` — nothing here touches
  the agent, client, logger, or any backend.

## What this unblocks in `tool_token_optimization.md`

- **Tier 1** (caching): its verification step 2 becomes a number on screen
  (cached-tokens portion of the composition line/chart) instead of a manual
  `usage.input_tokens_details` grep.
- **Tier 2** (schema trimming): the tools-bucket byte/token number before
  and after a trim is directly comparable in the composition line, so "did
  this actually shrink the tools bucket, and by how much" stops being a
  one-off script.
- **Tier 3** (dynamic subsetting): the eval described there compares token
  totals and tool-call correctness across baseline vs. filtered runs — this
  plan's per-request composition line is exactly the artifact that
  comparison should be read off of.

## Open questions for you

1. **Resolved.** §5 proposes either stacking the three token series onto the
   existing message-count sparkline or drawing a second chart beneath it —
   built as a second chart, three lines overlaid (not stacked).
   Separately, §4's *first* shipped design (one text line per request) turned
   out to be the wrong call in practice — illegible once a turn has many
   iterations — and was revised to a compact bar + tooltip + expanded-body
   table; see §4's "Problem found in use" note.
2. §6's one-time calibration spot-check against real provider token-count
   endpoints needs live API credentials (same gap as
   `tool_token_optimization.md`'s Tier 3 eval) — fine to defer until
   credentials are available, or is the byte-proportional estimate
   (uncalibrated) good enough to unblock you starting on
   `tool_token_optimization.md` sooner?
3. Ollama has no separate system key and no cache concept — confirmed from
   `backends/ollama.rb` already read for the other two plans. Gemini's
   exact cache-field name (§3) and whether its `system` key is genuinely
   absent when unset are assumed from public API shape, not yet confirmed
   against a real logged Gemini session (none exists in this repo yet) —
   worth flagging before implementation in case a real session shows a
   surprise, the same way the OpenAI shape surprised the original payload
   tracker plan.
