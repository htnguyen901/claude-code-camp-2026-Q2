# Evaluation: Subtask Separation, Multi-Agent Monitoring, and OpenTelemetry

## What this document is

Not a build plan like the other four documents in this directory — an
evaluation of three architectural questions, each with a firm conclusion.
Incorporates `player_journey_map.md`'s resolved open questions: the map/
discoveries data is historical and cross-session (accumulates across every
run rather than restarting from empty), rendered as an actual node-link
graph with a live current-location highlighter, `flee` counts as
location-revealing, and §6 (inventory/self-state) ships in v1.

---

## Q1: Does journey/map tracking need its own subtask to avoid costing the playing agent tokens/time?

**Conclusion: no. It costs the playing agent exactly zero tokens and zero
wall-clock time, because none of the parsing runs inside the agent's loop
— and that holds regardless of the map being cross-session/historical.**

Trace the actual path data takes:

1. `Agent#run` calls `@registry.dispatch(name, args)` and passes the raw
   result string to `@logger.tool_result(name:, result:, ...)`.
2. `Logger#tool_result` writes one JSON line to `.boukensha/sessions/
   <id>.jsonl` and returns. That's the entire cost the agent pays — one
   `write` + `flush` of a string it was already producing as a tool
   result, identical to today's behavior with none of this built.
3. `RoomEcho.parse` and the world-model build only ever run inside
   `log_viz`, a **separate OS process**, reading `.jsonl` files from disk
   whenever a human opens a session or map page.

No new code is added to `agent.rb`, `client.rb`, or any `backends/*.rb`
file. Nothing here adds a token to any request the agent sends or delays
its next tool call — parsing happens on `log_viz`'s own schedule, fully
decoupled from the agent's pacing. The "subtask separation" instinct is
already satisfied, as a **process boundary** (log_viz vs. the agent
process), not an in-loop feature that needs building — the same principle
every plan in this directory already commits to.

**The one real design gap this surfaces**: making the map historical
(accumulating across every session rather than restarting per run) means
`log_viz` needs a merged, cross-session view it doesn't have today —
`Session.load(path)` currently builds a fresh in-memory object from one
`.jsonl` file per HTTP request, with no persistent store spanning multiple
files or requests.

**Resolution: an incrementally-updated persisted index, not a rescan.**
Re-parsing every `.jsonl` file in full on every map-page request is O(all
history ever logged) per request — it gets slower with every session ever
played and with every line a long-running session appends, which is
exactly the "big sessions and rapid growth of sessions" case that needs to
stay cheap. The fix: a `WorldMap` object that persists its own merged state
(`.boukensha/world_map_index.json`) plus, per session file, **the byte
offset it has already folded in**. On each refresh it only reads the bytes
appended since that file's last recorded offset — a brand-new session file
costs one full parse (unavoidable, and small — a single session), but a
session file already indexed costs O(new lines since last refresh), and a
session file with no new lines costs a `File.size` stat and nothing else.
Total refresh cost is proportional to *new* data since the last refresh,
never to the full history — this is what actually fixes the scalability
complaint, not a "revisit later" deferral.

Storage engine: **SQLite** (`.boukensha/world_map.sqlite3`), not a JSON
file — a JSON blob would still need to serialize and rewrite the *entire*
merged structure on every save even with incremental reads, which only
half-fixes the growth problem. SQLite makes the write side incremental
too (targeted `INSERT`/`UPDATE`, not a full rewrite), at the cost of one
new, embedded, no-server-process dependency (`sqlite3` gem). Full schema
and ingestion design in `player_journey_map.md` §2.

**Standing guidance for actual future subtasks**: the "subtask" pattern is
only needed for an *interpretive* layer that makes its own LLM calls (e.g.
auto-narrating the journey, flagging when the agent looks stuck). That
would run as its own always-tailing process, with its own token/context
budget, never inline in `Agent#run` and never sharing the playing agent's
`Context`. Nothing today requires this — noted so it doesn't need
re-deriving if proposed later.

---

## Q2: Multi-agent monitoring — "how many agents are playing, view a summary of each, interact without intervening"

**Conclusion: the historical world map and the multi-agent dashboard are
the same feature, not two — build them together as one deliverable.**

Grounding for why this is already mostly buildable:

- `MudManager::McpServer` already supports several logged-in characters at
  once in a single daemon process, addressed by `session_id`
  (`mud_manager-0.2.0/lib/mud_manager/mcp_server.rb:14-19`) — concurrent
  characters is a supported scenario at the MUD-transport layer already.
- Every `boukensha` invocation (REPL, TUI, one-shot run) builds its own
  `Logger` with its own `session_id` and writes its own `.boukensha/
  sessions/<id>.jsonl` — running N characters simultaneously today already
  means N independent processes with no shared state to race on.
- `log_viz`'s index page (`app.rb`'s `get "/"`, `views/index.erb`) already
  globs every `.jsonl` file and lists one row per agent run with task,
  model, iterations, tokens, cost.

What closes the gap to the actual ask: the merged `WorldMap` from Q1 is
built from every session file at once, so it already knows every room any
agent has ever visited *and*, from each session's most recent `:tool`
location entry, where every **currently live** agent is right now. A
node-link graph rendering of that structure, with one marker per live
session placed on its current room (color- or label-coded by session/task
so multiple simultaneous characters are distinguishable), directly answers
all three original use cases at once:

- **"How many agents are playing"** — count of distinct live markers on
  the map.
- **"Summary of every character"** — each marker's tooltip/side panel:
  task, model, iteration count, cost so far, current room — the same data
  Tier A's table would have shown, just attached to a map position instead
  of a table row.
- **"Interact without intervening"** — satisfied for these two use cases
  specifically by construction: this is read-only reconstruction from
  already-appended log files, which cannot affect a running agent no
  matter how it's rendered.

**Liveness** ("is this session currently being played") is a session-file
mtime heuristic — recent write + no `turn_end` as the last event — no new
logging required.

**What's explicitly out of scope here, and why**: actually *injecting*
into a running agent's turn (pausing it, asking it a question mid-goal,
nudging its plan) is a different, larger feature — no channel into a
running `Agent#run` loop exists today; `Repl#run_turn` blocks synchronously
on `agent.run` and nothing else reads from or writes into that process
mid-turn. If that's ever wanted, the lowest-risk shape is a per-session
control file (`.boukensha/sessions/<id>.control`) that `Agent#run` checks
once per iteration — the same place it already checks
`iteration_limit_reached?`/`token_limit_reached?` — answered either
mechanically from state the agent/logger already holds (zero extra cost),
or by injecting a message for next turn the way `Agent#wrap_up` already
does (a real, if small, intervention: one extra model turn, sharing the
agent's context/turn budget). Not designed further here — build the
read-only shared map first; only scope real intervention if that turns out
insufficient once it's in front of you.

---

## Q3: OpenTelemetry

**Conclusion: not now.** Nothing in Q1 or Q2 requires it — both are fully
answered on top of the current `Logger` + `log_viz`, including the merged
multi-agent map.

**What it would buy**: off-the-shelf latency waterfalls (today's logs have
timestamps but no per-phase duration); a metrics API (`UpDownCounter`) that
fits "how many agents right now" more natively than a file-mtime
heuristic; alignment with emerging `gen_ai.*` semantic conventions other
tooling already expects; standard trace-context propagation if the
`mud-manager` MCP daemon ever gets its own instrumentation.

**What it costs here**: real integration work across `agent.rb`/
`client.rb`/every `backends/*.rb` file — a materially bigger lift than
every other change in this directory, which has stayed at the level of
"add a field to a `Logger` call." It also needs a collector + backend
running (even a local Jaeger/Tempo container) — real infrastructure this
project doesn't otherwise need, in tension with `token_composition
_observability.md`'s explicit framing of `log_viz` as "a dev tool over
local session logs with no compatibility requirement." And it wouldn't
replace any of the actual hard work here: CircleMUD room-text parsing and
provider-specific payload splitting are domain logic that exists
regardless of the transport layer, and the room/edge/visit graph doesn't
map onto OTel's span model at all — a bespoke world-model object is needed
either way.

**Revisit if**: this moves off a single local machine into a
shared/multi-person environment where others need to query traces without
custom UI; precise per-phase latency (LLM call vs. tool round-trip vs.
parse time) becomes something worth measuring, not just tokens/cost; or an
OTel backend is already running for something else and this should show up
alongside it. None of these apply today.

**Cheap hedge, optional**: name new `Logger` fields loosely after OTel's
`gen_ai.*` conventions where there's already a natural match (e.g.
`input_tokens` ~ `gen_ai.usage.input_tokens`), so a future migration is a
rename, not a redesign. Not required, not worth doing speculatively.

---

## What this settles for `player_journey_map.md`

- No subtask/process split needed for the parser itself — proceed as
  designed.
- Add a `WorldMap` layer — a persisted, incrementally-updated index (byte
  offset per session file, so a refresh only costs O(new data), never
  O(all history)) — as the backing store for the historical map, instead
  of scoping the map to a single `Session` object's `@rooms`/`@visits`/
  `@edges`.
- Build the map page as the multi-agent live-status view directly — one
  node-link graph, live-session markers with per-agent summaries, sourced
  from the same merged structure — rather than a separate table-based
  dashboard.
- Real intervention into a running agent (pause it, query it, redirect it)
  stays deliberately out of scope until the read-only shared map proves
  insufficient.
- OpenTelemetry stays off the table until this leaves solo local dev.