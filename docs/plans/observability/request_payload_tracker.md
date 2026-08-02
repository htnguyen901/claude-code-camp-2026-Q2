# Plan: Request Payload Tracker in log_viz

## Goal

For every API request the agent (`week1_baseline/ruby/12_context`) sends to a
model backend, capture the *actual outgoing payload* (model, system prompt,
full message history, tool schemas, max_tokens) and make it inspectable in
`log_viz`:

- Hidden by default, expandable per request via a native disclosure widget.
- Grouped under the existing iteration/turn structure in the transcript.
- Also viewable "linearly" across the whole session — a sequential view of
  how the payload grows (message count / byte size) call over call, so
  context growth and compaction effects are visible at a glance.

This is purely additive to the existing `.boukensha/sessions/*.jsonl` log
format and the Sinatra viewer; no change to agent *behavior*.

## Background: why this can't just read the wire payload back out

`Backends::*#to_payload` (`week1_baseline/ruby/12_context/lib/boukensha/
backends/*.rb`) returns a genuinely different shape per provider — there is
no single set of keys that means "the messages" or "the system prompt"
across all four:

| | messages key | system key | per-tool schema key |
|---|---|---|---|
| Anthropic (`backends/anthropic.rb:76`) | `messages` (role/content) | `system` | `input_schema` |
| OpenAI (`backends/openai.rb:68`) | `input` (mixed: `{role,content}` \| `function_call_output` \| `function_call`, **no `role` on the latter two**) | `instructions` | `parameters` (flat, no wrapper) |
| Gemini (`backends/gemini.rb:83`) | `contents` (role/**parts**, not content) | `systemInstruction.parts[].text` | `parameters`, nested inside a **single-element** `tools: [{functionDeclarations: [...]}]` array |
| Ollama (`backends/ollama.rb:82`) | `messages` (role/content, but the **system prompt is injected as the first message**, there's no separate system key) | *(none — folded into messages)* | `function.parameters` (wrapped in `{type: "function", function: {...}}}`) |

This shapes two decisions in the design below:

1. **Summary stats (`message_count`, `tool_count`, last-user-text) must come
   from the backend-agnostic `Context` object** (`@context.messages`,
   `@context.tools`), never by reading them back out of the built `payload`.
   Reading `payload["messages"]`/`payload["tools"].size` looks reasonable for
   Anthropic but silently breaks for the others — OpenAI has no top-level
   `messages` key at all (→ would log `0` messages), and Gemini's `tools`
   array has exactly one element (`functionDeclarations` wrapping every tool)
   regardless of how many tools are actually registered (→ would log `1`
   tool no matter the real count).
2. **The expanded UI renders the raw payload generically** rather than
   picking apart per-backend fields (`system`/`instructions`/
   `systemInstruction`, `messages`/`input`/`contents`, `input_schema`/
   `parameters`) — a structured per-field renderer would need a bespoke
   branch per backend to actually show anything. The one key name that *is*
   consistent across all four backends' `to_payload` is `tools`, which is
   why that's the only key singled out for special (nested, collapsible)
   treatment in §4.

## Design

### 1. Logger: `request` event, with summary stats sourced from `Context`

`Boukensha::Logger#request` writes a `phase: "request"` event carrying the
literal payload about to be sent, plus cheap summary fields for the
collapsed view:

```ruby
# messages/tools are the backend-agnostic Context collections used to build
# `payload` — not the wire payload itself, since every backend serializes
# them under a different key/shape (see Background above).
def request(payload:, messages:, tools:, iteration:, wrap_up: false)
  write_log(
    phase:          "request",
    iteration:      iteration,
    wrap_up:        wrap_up,
    model:          payload[:model] || payload["model"],
    payload:        payload,
    bytes:          JSON.generate(payload).bytesize,
    message_count:  messages.size,
    tool_count:     tools.size,
    last_user_text: messages.reverse.find { |m| m.role == :user }&.content
  )
end
```

- `turn`, `iteration` for grouping; `wrap_up: true` marks the uncounted
  wind-down call so log_viz can label it distinctly instead of silently
  merging it into the last iteration.
- `bytes` is precomputed once so log_viz doesn't re-serialize a potentially
  large hash just to show a number in the session list / sparkline.
- `last_user_text` is logged directly (rather than making log_viz dig for
  it) for the same backend-agnostic reason as `message_count`/`tool_count`
  — see §3.

`Agent#run` and `Agent#wrap_up` each build the payload via
`@builder.to_api_payload(**call_opts)`, then call `@logger.request(payload:
payload, messages: @context.messages, tools: ..., iteration: @iteration,
...)` — `tools:` is `@context.tools` for `run`, and `[]` for `wrap_up`
(matching the `tools: []` it actually sends, since wrap-up is deliberately
tools-disabled).

### 2. Guarantee logged payload == sent payload

To avoid logging one payload and sending a slightly different one (e.g. if
`max_output_tokens`/`tools` computation ever drifts), the payload is built
**once** in `Agent`, logged, then passed into `Client#call` instead of
having the client rebuild it:

- `Client#call` gains an optional `payload:` kwarg; when given, it's used
  as-is instead of calling `@builder.to_api_payload` internally. Backwards
  compatible for any other caller that doesn't pass one.
- `Agent#run` and `Agent#wrap_up` each build the payload via
  `@builder.to_api_payload(**call_opts)`, call `@logger.request(payload: ...)`,
  then pass that same payload into `@client.call(payload: payload, **call_opts)`.

This touches `client.rb`, `agent.rb` only — `prompt_builder.rb` and the
backends are unchanged.

### 3. log_viz: parse the `request` event

In `Session#parse!`, the `when "request"` branch:

- Produces the `:user` transcript entry from `event["last_user_text"]`
  directly — no per-backend key-shape guessing needed, since that field is
  already backend-agnostic text logged by §1.
- Appends a new `Entry` of type `:request` holding `turn`, `iteration`,
  `wrap_up`, `model`, `payload`, `bytes`, `message_count`, `tool_count`.
- Appends a point to a new `@request_series` (parallel to the existing
  `@usage_series`) of `{ turn, iteration, bytes, message_count, tool_count,
  wrap_up, at }` — the data source for the linear growth view (§5).
- Computes `bytes_delta` / `message_count_delta` vs. the previous request in
  the series while building each point, so each entry can show "+3 msgs /
  +1.2kb vs previous call" without the view needing to look backward.

### 4. UI: per-request disclosure, grouped by iteration

Render the `:request` entry immediately where the existing "Iteration N"
marker / tool-use placeholder already sits in `session.erb`, as a native
`<details><summary>Request details ▸</summary>...</details>` block:

- Collapsed by default.
- Summary line shows the cheap fields even collapsed: model, message count,
  payload size, and the delta vs. the previous request (e.g. `Request ·
  claude-sonnet-4-6 · 14 messages (+2) · 8.4kb (+1.1kb)`).
- Wrap-up requests get a visibly distinct label ("Wind-down request") since
  they don't bump the iteration counter.
- **Expanded body** renders the payload generically rather than
  reconstructing a structured view field-by-field (see Background — there's
  no single set of field names that works across backends):
  - Split the payload hash on `tools` — the one key name consistent across
    all four backends' `to_payload` — and put it in its own nested
    `<details><summary>Tool schemas (N)</summary>` block, since it's the
    verbose, mostly-unchanging-per-session part.
  - Render everything else — `payload.reject { |k, _| k == "tools" }` — as
    `<pre>#{JSON.pretty_generate(...)}</pre>` directly. This *is* "the
    actual payload sent to the LLM client": whatever the backend calls its
    message list (`messages`/`input`/`contents`) and system prompt
    (`system`/`instructions`/`systemInstruction`), it's right there,
    verbatim, for every provider, with zero backend-specific parsing in the
    view.

No JavaScript is introduced — `<details>`/`<pre>` matches the rest of
log_viz's "plain ERB + inline SVG, no JS" style (`ansi.rb`, `sparkline`
helper).

### 5. UI: linear/session-wide growth view

Alongside the existing token sparkline at the top of `session.erb`, a second
sparkline-style chart (reusing the `sparkline` SVG helper pattern in
`app.rb`) is driven by `@request_series`:

- X axis: request index (sequential across the whole session, not reset per
  turn — this is the "linear process" view).
- Y axis: `message_count` (chosen over payload bytes — "how much history is
  piling up" is the more useful signal than raw size) — same faint
  turn-boundary rules already drawn for the token sparkline, plus a
  distinct marker at compaction events (already tracked via the existing
  `compaction` phase) so the viewer can see the count drop right where
  compaction kicked in, and a distinct marker for wrap-up requests.
- Lives once per session (not per iteration), since its whole purpose is
  showing growth *across* iterations/turns.

### 6. Known tradeoffs

- **Log size growth**: logging the full payload (messages + tool schemas)
  every iteration is heavier than the old `prompt` event, which serialized
  full message history but skipped tool schemas entirely. Tool schemas are
  static for the whole session, so the marginal cost is mostly the repeated
  schema block per call. Chosen default: log the full payload every time
  (matches "every request" literally, simplest) rather than logging tool
  schemas once and referencing them later — revisit only if session files
  become unwieldy in practice.
- **Old session logs**: existing `.jsonl` files with `phase: "prompt"` have
  no `:request` entries and no growth-chart data (the old branch was
  removed, not kept side-by-side). Acceptable given `log_viz` is a dev tool
  over local session logs with no compatibility requirement.
- **Secrets**: the API key lives in HTTP headers, not the payload body, so
  logging the payload doesn't expose credentials. Tool call arguments/
  results already get logged today (`tool_call`/`tool_result`), so this
  doesn't introduce a new class of exposure.

### 7. Related: the `Plan` panel needed a prompt fix, not a payload fix

While testing this feature, the raw-payload dump (§4) is what surfaced a
separate, real problem: the `Plan` panel (`phase: "plan"`, populated by
`Agent#handle_tool_calls`'s `extract_text` in `agent.rb:158-159`) had
stopped showing up for OpenAI sessions. Investigation (see git history of
this file for the full debugging trail) ruled out every payload-tracker
code path — `Logger#plan` and `extract_text` were unchanged and correct —
and traced it to `prompts/system.md`'s system prompt only *permitting*
narration ("explain only what matters for the current turn") rather than
requiring it. The fix was a prompt change, not a code change:

```diff
- Use available tools to observe the world, act deliberately, and explain
- only what matters for the current turn.
+ Before every tool call, state in one short sentence what you are about to
+ do and why. This is required on every turn that calls a tool, not just
+ when something is unclear — even an obvious action gets its one-line
+ rationale. Keep everything else minimal: don't narrate tool results back
+ verbatim, and don't repeat the rationale sentence.
```

This is backend-agnostic (every backend's `parse_response` normalizes
narration into the same `{"type" => "text", ...}` block `extract_text`
already reads) and unrelated to the payload-tracker mechanism itself — noted
here only because this feature is what made it diagnosable.

## Files touched

- `week1_baseline/ruby/12_context/lib/boukensha/logger.rb` — `#request`
  (§1): `messages:`/`tools:` params, `message_count`/`tool_count`/
  `last_user_text` sourced from them, not from `payload`.
- `week1_baseline/ruby/12_context/lib/boukensha/agent.rb` — builds the
  payload once per call, logs it, passes it to the client (§2); passes
  `messages:`/`tools:` into `@logger.request` (§1).
- `week1_baseline/ruby/12_context/lib/boukensha/client.rb` — `#call` accepts
  an optional precomputed `payload:` (§2).
- `week1_baseline/log_viz/lib/log_viz/session.rb` — parses `request` events,
  new `Entry` fields, new `@request_series` + delta computation (§3).
- `week1_baseline/log_viz/lib/log_viz/app.rb` — `fmt_bytes`, `fmt_delta`,
  and the `request_sparkline` helper (§5).
- `week1_baseline/log_viz/views/session.erb` — `<details>` block per
  request (§4), growth chart near the existing token sparkline (§5).
- `week1_baseline/log_viz/public/style.css` — styling for the request
  disclosure and the growth chart.
- `week1_baseline/ruby/12_context/test/test_logger.rb` — covers
  `Logger#request`, including a regression test asserting summary fields
  come from `messages:`/`tools:` and not from an OpenAI-shaped payload
  (the specific gap that shipped as a bug during this feature's rollout).
- `week1_baseline/ruby/12_context/prompts/system.md` — §7's unrelated but
  feature-adjacent fix.

## Open questions for you

1. Does replacing `prompt` with `request` outright (dropping old-log
   support) sound right, or do you want `Session#parse!` to keep rendering
   old logs gracefully (just without request details)?
   A: The current log needs to also stay. By that I mean I need to see iterations, agent plan, agent commands, etc. Basically the current log_viz UI. Request details could be placed in an expandable div or side view when clicked
2. Full-payload-every-iteration (option a above) vs. schema-once-then-
   reference (option b) for log size — start with (a) and revisit, or
   design for (b) from the start?
   A: Can start with (a) and revisit
3. Is the growth chart wanted as bytes, message_count, or both plotted
   together? Bytes is closer to "how big is this request" but message_count
   is closer to "how much history is piling up."
   A: message_count
