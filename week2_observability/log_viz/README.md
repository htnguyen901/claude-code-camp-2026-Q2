# Log Viz

A small Sinatra app that turns `.boukensha/sessions/*.jsonl` logs (written by
`Boukensha::Logger`) into a human-readable transcript in the browser.

## What it does

- **`/`** — lists every session log (start time, session id, logged task,
  provider/model mix, iteration count, token totals, and cost).
- **`/sessions/:id`** — renders one session as a chat-style transcript:
  - the user's task
  - assistant replies, with input/output token counts, provider/model, and
    per-call cost when the logger recorded it
  - cost and token breakdowns grouped by task, provider, and model
  - each tool call and its result, grouped by agent iteration
  - raw MUD output (including ANSI color codes) is converted to colored HTML
    so room descriptions, exits, and status lines look the way they would in
    a terminal
  - when `Boukensha::Compactor` (week2_observability/ruby/14_response_compactor)
    is in play, an **"Injected into next request" panel** right before each
    request block — the exact post-compaction text about to enter that
    request's payload, with a char-count delta, so you don't have to expand
    the request's raw JSON to see what actually got sent
  - a **"View trace ↗"** link on each turn (when the session was logged by
    `week2_observability/ruby/15_observability` — see its README) — jumps
    straight to that turn's Jaeger waterfall. `session_id` is the join key
    between the two systems; this is a link out to the other view, not a
    merged pipeline (see `docs/plans/observability/otel_and_logs/00_overview.md`).
    Older sessions, or any turn logged with `observability.enabled: false`,
    simply render with no link — no error.
- **`/map`** — the accumulated World Map: every room ever visited across
  every session, rendered as a zoomable, scrollable, drag-to-pannable
  node-link graph (`+`/`-`/Reset controls or ctrl/cmd+scroll-wheel to zoom,
  click-and-drag to pan, click a room for an inline detail panel), plus an
  always-visible in-map search box that highlights matching rooms without
  reloading. A visited room's exits that haven't been stepped through yet
  render as small dashed "?" stubs, so a known-but-unexplored path is
  visible without implying it's been discovered. Also shows who's playing
  right now (live session markers on the map, a live-sessions table that
  polls without a full page reload).
- **`/map/rooms`**, **`/map/discoveries`** — the Rooms and Discoveries
  tables live on their own pages (split out of `/map` to keep the map
  itself uncluttered), each with reactive, debounced search/filter and
  keyset pagination — typing updates the results without a page reload; a
  plain form submit is the no-JS fallback.
- **`/players`**, **`/players/:name`** — the player roster and one
  character's detail page (session list, cost/token totals, a "rooms/
  discoveries discovered vs. discoverable" KPI against the global map).
  `/players/:name` also has a **Knowledge** section: the same zoomable/
  searchable map, plus Rooms/Discoveries pages, but scoped to only what
  that player's own sessions have actually visited (`/players/:name/rooms`,
  `/players/:name/discoveries`) — an isolated view of one character's
  explored subgraph, not the engineer-facing "everyone's discoveries" view
  `/map` gives. The Sessions table also carries a small per-row path glyph
  (dots in visit order, one per room, no room names) as a glanceable
  preview of that session's route — click through to `/sessions/:id`'s full
  interactive time-lapse replay for the real thing.

It only reads the `.jsonl` files — nothing is written back.

## Run it

```sh
bundle install
bundle exec ruby bin/log_viz
```

Then open <http://localhost:4567>.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `LOG_VIZ_SESSIONS_DIR` | `<repo root>/.boukensha/sessions` | Directory of `.jsonl` session logs to read |
| `LOG_VIZ_WORLD_MAP_DB` | `<repo root>/.boukensha/world_map.sqlite3` | SQLite file for the accumulated world map (`/map`) — also the file `room_knowledge` (week2_observability/ruby/13_room_inspector) reads read-only |
| `LOG_VIZ_JAEGER_UI_BASE` | `http://localhost:16686` | Base URL the per-turn "View trace ↗" link is built from (`<base>/trace/<trace_id>`) — point this elsewhere if Jaeger isn't running on the default `week2_observability/otel` port |
| `OLLAMA_HOST` | `http://localhost:11434`, or `tasks.content_fact.host` below | Local Ollama daemon used by `ContentFact`'s background classification worker. Wins over `tasks.content_fact.host` if both are set. |
| `PORT` | `4567` | Port to listen on |
| `BIND` | `localhost` | Address to bind to |

`ContentFact`'s **provider**/**model** aren't env vars — they're read from
`.boukensha/settings.yaml`'s `tasks.content_fact` block (`lib/log_viz/
settings.rb`), the same "task" shape `tasks.player` already uses:

```yaml
tasks:
  content_fact:
    provider: ollama   # only "ollama" is implemented; other values warn and fall back to it
    model: gemma4
    # host: http://localhost:11434   # optional — OLLAMA_HOST env var still overrides this
```

Missing settings.yaml, a missing `tasks.content_fact` block, or a missing
key all fall back to the defaults above — log_viz keeps working with zero
configuration, same fail-soft posture as an unreachable Ollama daemon.

### Setting up Ollama (this repo's dev setup: WSL)

`ContentFact` needs a reachable Ollama daemon serving the configured model.
If you're on WSL (like this repo's dev environment) and already have Ollama
installed on the **Windows** side, don't reuse that one — WSL2's default
(NAT) networking doesn't share `localhost` with Windows, so `log_viz`
running inside WSL can't reach a Windows-side Ollama without extra
networking setup (a Windows-side `OLLAMA_HOST=0.0.0.0` + firewall rule +
finding WSL's current gateway IP, which can change across restarts).

Simpler: install Ollama **inside WSL** — it's a separate, self-contained
install from the Windows one (yes, the model gets downloaded a second time,
but there's no networking to reason about):

```sh
curl -fsSL https://ollama.com/install.sh | sh   # needs sudo; asks for it interactively
ollama pull gemma4                              # or whatever tasks.content_fact.model is set to
```

The installer sets up an `ollama.service` systemd unit (this repo's WSL
distro already runs `systemd=true`, per `/etc/wsl.conf`) — check it with
`systemctl status ollama`. If the installer can't get non-interactive sudo
in your shell, run those two commands directly in a real terminal (not
piped through another process) so it can prompt for your password.

Once running, `curl http://localhost:11434/api/version` should return a
version string, and `ollama list` should show the pulled model.

## How it works

- `lib/log_viz/session.rb` — streams a `.jsonl` file and turns the raw
  `session_start` / `turn` / `iteration` / `prompt` / `response` /
  `tool_call` / `tool_result` events into an ordered list of transcript
  entries (`user`, `assistant`, `tool`). Response events are treated as the
  source of truth for task/provider/model/cost so one session can mix models.
  A `tool_result` event's optional `compacted` field (written by
  `Boukensha::Logger#tool_result` alongside the always-raw `result` field —
  see week2_observability/ruby/14_response_compactor/lib/boukensha/
  compactor.rb) is buffered across however many tool calls happen in one
  iteration and flushed into a single `injected` entry right before the
  `request` entry that follows — that's the "Injected into next request"
  panel. Older logs with no `compacted` field simply produce no `injected`
  entries; nothing else about the transcript changes.
- `lib/log_viz/ansi.rb` — converts ANSI SGR escape codes in tool results into
  `<span>` elements styled via `public/style.css`.
- `lib/log_viz/world_map.rb` — the cross-session accumulated world model
  behind `/map` (see `docs/plans/observability/player_journey_map.md`):
  rooms, edges, discoveries, live sessions, plus (see
  `docs/plans/observability/room_world_inspector.md`) `content_facts`
  (LLM-extracted subject/kind/clause per unique room-content line,
  classified lazily by a background thread — never blocks a request) and
  `examinations` (first-ever `examine`/`look at` per room/target, backing
  the "examined ✓ / not yet" markers — plus the actual reply text, see
  below).
- `lib/log_viz/content_fact.rb` — Tier B (local-LLM-only; see the plan for
  why the original regex "Tier A" was dropped) structured extraction, two
  shapes: `.extract` classifies one itemized "X is here" room-content line;
  `.extract_mentions` scans a room's free-form *description* paragraph for
  things narrated in prose instead ("A small note hangs on the wall.") that
  never got their own itemized line — see the plan's "Follow-up:
  description-embedded mentions." Both go through a local Ollama call and
  fail soft (`kind: "unknown"` / no mentions found) if Ollama is
  unreachable — never blocks ingestion.
- `bin/backfill_content_facts` — one-off script, two passes: classify
  existing `room_contents` history, then scan existing room descriptions
  for embedded mentions — both immediately instead of waiting for the
  background worker to reach them organically.
- **Examination results as clues, not just a checkbox** (plan's "Follow-up:
  examination results as a 'keeper'"): `examinations.result_text` — the
  actual text an `examine`/`look at <target>` printed back, ANSI- and
  status-prompt-stripped (`RoomEcho.clean_reply`) — is surfaced two places:
  the `/map` discoveries table's "Findings" column
  (`WorldMap#discoveries`' `examination_result` field), and the
  `room_knowledge` agent tool (`week2_observability/ruby/13_room_inspector`),
  whose `examined` entries are now `{subject:, result:}` pairs instead of
  bare subject strings — the point being that an examine reply can hold a
  real gameplay clue (an NPC's dialogue, an item's fine print) worth
  recalling later without spending another turn re-examining it.
- `lib/log_viz/app.rb` — the Sinatra app and view helpers. `map_svg` renders
  the node-link graph in three scopes (full map, one `session_id:`'s actual
  path, one `player:`'s visited-rooms subgraph) and synthesizes the
  unexplored-exit stubs at render time — nothing about "unexplored" is ever
  written to the database, it's recomputed from each visited room's parsed
  `exits` on every render. `/map/rooms`, `/map/discoveries`,
  `/players/:name/rooms`, `/players/:name/discoveries` share the same
  `rooms.erb`/`discoveries.erb` templates as their global counterparts, just
  with results scoped via `WorldMap#rooms_matching`/`#discoveries`'
  `room_titles:` allowlist param. `session_path_glyph` renders the compact
  per-session route preview on `/players/:name`.
- `views/` — ERB templates for the session list, transcript, map, and
  player/knowledge pages, plus two shared script-only partials:
  `_map_zoom.erb` (zoom controls — `+`/`-`/Reset buttons and ctrl/cmd+wheel,
  via a CSS `transform: scale()` on the map SVG, layered on top of the
  existing native scroll/drag-to-pan) and `_map_search.erb` (`/map`'s
  in-map, client-side, reactive-to-keystroke room search). Both are pure
  progressive enhancement — a page with JS disabled renders and works
  exactly as it did before either existed.
