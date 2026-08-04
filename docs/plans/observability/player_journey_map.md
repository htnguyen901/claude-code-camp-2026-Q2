# Plan: Player Journey & World-State Observability (log_viz)

## Goal

Make the player's journey inspectable in `log_viz` without reading raw
`tool_result` text call-by-call. At any point in time, across any number
of past and currently-running agents, answer:

- Where is each agent *right now*?
- What path did it take to get here, and has it (or any other agent) been
  here before?
- What did it actually see in each room (description, exits)?
- What has it noticed along the way (items, NPCs, mobs mentioned in room
  text) and what does it currently carry?

This is reconstructed entirely from data already logged in
`.boukensha/sessions/*.jsonl` — purely additive to `log_viz`, no agent
behavior change. Same contract as the other three plans in this directory:
this plan touches none of `week2_observability/ruby/12_context/`.

> **Update (room_world_inspector.md):** this plan's own scope is still
> exactly what's described above — `log_viz` remains a passive reader,
> `12_context` remains untouched. But "no agent behavior change" no longer
> holds *project-wide*: `docs/plans/observability/room_world_inspector.md`
> §3 adds a `room_knowledge` tool to a **new** step,
> `week2_observability/ruby/13_room_inspector/` (branched from
> `12_context`, which stays the source of truth), that reads this plan's
> `WorldMap`-owned schema (`content_facts`/`examinations`, both additive to
> what's designed here) read-only. It's the first agent-side consumer of
> data this plan produces — worth knowing if you're changing the `rooms`/
> `room_contents` schema this plan defines below, since `13_room_inspector/
> lib/boukensha/world_knowledge.rb` now depends on it too.

The map/discoveries data is **historical and cross-session** — every agent
run adds to one accumulating world model rather than starting from empty —
and doubles as the multi-agent monitoring view: "where is each agent right
now" is answered by the same structure that answers "what has been
discovered so far."

## Background: there is no world/location model anywhere in the stack today

- `MudManager::Primitives` (the gem behind every `tbamud__*` tool) is
  explicitly stateless by design — its own docstring says runtime
  preconditions and game state "require live game state and belong to the
  Agent layer," and no such layer exists yet.
- `MudManager::Session` is a raw telnet client — it drains bytes, strips
  IAC sequences, and waits for a prompt. It has zero concept of "room" or
  "location."
- `Boukensha::Tools::Mcp` (`lib/boukensha/tools/mcp.rb`) forwards whatever
  string the MUD server sends back as the tool's entire result — no
  structured fields, ANSI codes and all.
- `MudManager::McpServer` already supports several logged-in characters at
  once in one daemon process, addressed by `session_id` — multiple agents
  playing concurrently is already a supported scenario at the transport
  layer, and each `boukensha` invocation (REPL/TUI/one-shot) writes its own
  `.boukensha/sessions/<session_id>.jsonl` independently, with no shared
  state to race on at the logging layer.

Concretely, here is what a `move` actually produces today (grounded from a
real logged session, `.boukensha/sessions/20260802T062614Z-0fb3a786.jsonl`):

```
tool_call:   tbamud__move  {"direction": "south", "session_id": "default"}
tool_result: "\e[0;33mBehind The Temple Altar\e[0m\r\n   You are on a dirt
              path leading away from the Temple Altar which is south\r\n
              of here.  To the north, the path continues through the lush
              contryside of Midgaard towards the Dragonhelm Mountains far
              off to the north.\r\n\e[0;36m[ Exits: n s ]\e[0m\r\n\r\n
              22H 100M 84V (news) (motd) > "
```

This CircleMUD/tbaMUD room echo is a fixed, mechanical shape — title line,
description paragraph, `[ Exits: ... ]` line, zero or more room-content
lines (objects/mobs, each its own ANSI-colored line), then the HP/Mana/Move
prompt. Every `look`/`move` result sampled across the real session logs in
this repo follows this shape exactly. And `move`'s own `tool_call` args
already carry the compass `direction` — pairing that with the room title
before/after gives a directed, spatially-meaningful map edge for free, no
new logging required (§3 uses this for real x/y layout, not just graph
connectivity).

Two more findings worth stating up front, both grounded in the actual
session logs rather than assumed:

- **Real sessions barely touch objects.** Across every `.boukensha/sessions/
  *.jsonl` file in this repo, `get`/`equip`/`put` never appear; inventory is
  only ever inspected via `info_self kind: inventory` / `kind: equipment`,
  and rarely. That's itself an observability finding worth surfacing, not
  something to paper over by fabricating item-tracking data.
- **Tool-call/tool-result pairing can already be wrong, for reasons
  unrelated to this plan.** Replaying `log_viz`'s existing FIFO pairing
  against real session files turns up results that don't match their
  call's own intent (e.g. an `info_self kind: "score"` call paired with a
  stray `"Look at what?"` result). This is the same class of
  transport-level misattribution `docs/journal/1_baseline.md` already
  flagged — a pre-existing risk in the log/session pairing itself, not
  something this plan introduces or fixes. It's why the parser is designed
  to fail closed (§1): a misattributed result either won't match the
  strict room-echo shape (correctly skipped) or, if it happens to be a real
  room echo that slipped one slot, the *location* it reports is still
  accurate even though it's attached to the wrong step.

## Design

### 1. `RoomEcho` — a small parser for the fixed room-echo shape

New `lib/log_viz/room_echo.rb`. Anchors on the two ANSI-colored lines that
are structurally guaranteed when (and only when) the MUD actually sent a
room description — title in `0;33`, exits line in `0;36` — and returns
`nil` (not a partial/guessed hash) when either anchor is missing:

```ruby
module LogViz
  module RoomEcho
    EXITS_RE = /\[ Exits: ([a-z ]*)\]/i
    PROMPT_RE = /\A\d+H\s+\d+M\s+\d+V\b/

    # Primitives defined to always emit a room echo. `flee` is included:
    # a successful flee relocates the player unpredictably mid-combat, and
    # that unplanned relocation is exactly what a "where is he" view needs
    # to catch, not miss.
    LOCATION_VERBS = %w[look move enter leave flee].freeze

    def self.location_tool?(tool_name)
      LOCATION_VERBS.include?(tool_name.to_s.split("__").last)
    end

    def self.strip_ansi(raw_ansi_text)
      raw_ansi_text.to_s.gsub(Ansi::ESCAPE_RE, "").gsub("\r\n", "\n")
    end

    # Returns nil for anything that isn't a real room echo — a failed move
    # ("Alas, you cannot go that way..."), a dark room ("It is pitch
    # black..."), a mangled/misattributed result, etc. Callers must treat
    # nil as "no location update," never as an empty room.
    def self.parse(raw_ansi_text)
      lines = strip_ansi(raw_ansi_text).split("\n")

      title_line = lines.first
      exits_line = lines.find { |l| l =~ EXITS_RE }
      return nil unless title_line && exits_line && !title_line.strip.empty?

      exits_idx  = lines.index(exits_line)
      description = lines[1...exits_idx].join(" ").squeeze(" ").strip
      contents    = lines[(exits_idx + 1)..]
                      .map(&:strip)
                      .reject { |l| l.empty? || l =~ PROMPT_RE }

      {
        title: title_line.strip,
        description: description,
        exits: exits_line[EXITS_RE, 1].to_s.split(" "),
        contents: contents
      }
    end
  end
end
```

(Reuses `Ansi::ESCAPE_RE` — already defined in `ansi.rb` — rather than
duplicating that regex. Matched against the tool name's suffix after
stripping any MCP prefix, so this doesn't hardcode `tbamud__` — it works
for whatever `prefix:` a given `mcp_servers` config entry uses.)

`info_self` results are handled by a small sibling module,
`lib/log_viz/self_state.rb` (§6):

```ruby
module LogViz
  module SelfState
    def self.info_self?(tool_name)
      tool_name.to_s.split("__").last == "info_self"
    end

    def self.summarize(raw_ansi_text)
      RoomEcho.strip_ansi(raw_ansi_text).strip
    end
  end
end
```

### 2. `WorldMap` — a persisted, incrementally-updated SQLite index

This is the cross-session, historical piece, and the part that has to be
genuinely scalable: it accumulates across *every* session ever logged, not
just the one being viewed, so its cost can't grow with total history on
every page load.

**Why SQLite, not a JSON blob.** An earlier draft of this plan stored the
merged model in one JSON file, using a per-file byte offset so *reading*
new log lines stayed O(new data). That fixed the read side but not the
write side: persisting the merged result still meant serializing and
rewriting the *entire* rooms/edges/visits structure on every refresh — a
cost that grows without bound as history accumulates, which is exactly the
"big sessions and rapid growth of sessions" case that needs to stay cheap.
SQLite (via the `sqlite3` gem — one new dependency, embedded, no server
process, consistent with this project's otherwise minimal footprint) fixes
this directly: new rooms/edges/visits become targeted `INSERT`/`UPDATE`
statements, so write cost is proportional to *what changed*, not to
everything ever recorded. It also replaces hand-rolled tmp-file-plus-rename
atomicity with real transactions, and gives WAL-mode concurrent-read safety
for free if multiple request threads hit `log_viz` while a refresh is
in flight (this app already runs under Puma's thread pool).

**Storage location**: `.boukensha/world_map.sqlite3`, sibling of
`.boukensha/sessions/` (same directory-resolution convention `log_viz`
already uses for `sessions_dir`, overridable via `LOG_VIZ_WORLD_MAP_DB`).

**Schema**:

```sql
CREATE TABLE file_offsets (
  path TEXT PRIMARY KEY, byte_offset INTEGER NOT NULL
);

CREATE TABLE rooms (
  title TEXT PRIMARY KEY,
  description TEXT,
  exits TEXT,                    -- JSON array, e.g. '["n","s"]'
  coord_x REAL, coord_y REAL,    -- NULL until placed (§ coordinate assignment)
  visit_count INTEGER NOT NULL DEFAULT 0,
  first_seen_session TEXT, first_seen_turn INTEGER,
  first_seen_iteration INTEGER, first_seen_at TEXT
);

CREATE TABLE room_contents (              -- normalized so "discoveries" can
  room_title TEXT NOT NULL,               -- dedupe the same item across rooms
  content TEXT NOT NULL,                  -- with a plain GROUP BY, not by
  first_seen_at TEXT,                     -- loading everything into memory
  PRIMARY KEY (room_title, content)
);

CREATE TABLE edges (
  from_title TEXT NOT NULL, via TEXT NOT NULL, to_title TEXT NOT NULL,
  PRIMARY KEY (from_title, via)           -- first-discovered destination wins
);

CREATE TABLE visits (                     -- the per-session journey timeline
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL, room_title TEXT NOT NULL,
  turn INTEGER, iteration INTEGER, at TEXT, arrived_via TEXT
);
CREATE INDEX idx_visits_session ON visits(session_id);

CREATE TABLE sessions (                   -- one row per agent run
  session_id TEXT PRIMARY KEY, path TEXT,
  task TEXT, provider TEXT, model TEXT, started_at TEXT,
  last_room TEXT, last_seen_at TEXT, turn INTEGER, iteration INTEGER
);

CREATE TABLE self_state (                 -- last-known snapshot per kind (§6)
  session_id TEXT NOT NULL, kind TEXT NOT NULL, text TEXT,
  turn INTEGER, iteration INTEGER, at TEXT,
  PRIMARY KEY (session_id, kind)
);

CREATE TABLE pending_calls (              -- tool_call/tool_result can straddle
  session_id TEXT NOT NULL, seq INTEGER NOT NULL,   -- two different refreshes;
  name TEXT, args TEXT,                             -- this survives that gap
  PRIMARY KEY (session_id, seq)                     -- (an in-memory-only queue
);                                                   -- would lose it on restart)
```

**Incremental ingestion** (`WorldMap#refresh!`), per session file:

```ruby
def ingest_new_lines(path)
  size   = File.size(path)
  offset = stored_offset(path)         # SELECT byte_offset FROM file_offsets
  return if size <= offset

  chunk = File.open(path, "rb") { |f| f.seek(offset); f.read(size - offset) }
  return if chunk.nil? || chunk.empty?

  session_id = File.basename(path, ".jsonl")
  consumed   = 0

  @db.transaction do
    chunk.each_line do |line|
      break unless line.end_with?("\n")   # partial line — wait for next refresh

      process_line(session_id, path, line)
      consumed += line.bytesize
    end

    if consumed.positive?
      @db.execute(
        "INSERT INTO file_offsets(path, byte_offset) VALUES (?, ?) " \
        "ON CONFLICT(path) DO UPDATE SET byte_offset = excluded.byte_offset",
        [path, offset + consumed]
      )
    end
  end
end
```

Cost per refresh: a `File.size` stat for every session file (cheap, even
with hundreds of files), and actual parsing only for bytes appended since
that file's last recorded offset — a brand-new file costs one full parse
(unavoidable — it's one new session), an already-indexed file with no new
activity costs a stat and nothing else, and a growing file costs only its
new tail. The whole per-file ingest runs inside one transaction, so a crash
mid-refresh can't leave `file_offsets` pointing past effects that were
never committed.

`process_line` mirrors the same phase-switch `Session#parse!` already
uses (`turn`, `iteration`, `tool_call`, `tool_result`, `session_start`),
but tracks only what the map needs: `sessions.turn`/`iteration` per
session row, a `pending_calls` queue (persisted, per **why** above), and
on `tool_result` — if `RoomEcho.location_tool?`, parse and record a visit
(§ below); if `SelfState.info_self?`, upsert `self_state`. It deliberately
does **not** process `request`/`response` events at all — token/cost
aggregation stays the single-session `Session#parse!`'s job; keeping
`WorldMap`'s per-line work minimal is itself part of keeping ingestion
cheap.

**Recording a visit**:

```ruby
def record_visit(session_id, parsed, call, event, turn, iteration)
  title = parsed[:title]
  upsert_room(title, parsed, session_id, turn, iteration, event["at"])  # visit_count++, content rows

  direction  = call.dig(:args, "direction")
  via        = direction || call[:name].to_s.split("__").last   # "enter"/"leave"/"flee" w/o direction
  from_title = @db.get_first_value("SELECT last_room FROM sessions WHERE session_id=?", [session_id])

  assign_coordinate(title, from_title, direction)

  @db.execute("INSERT OR IGNORE INTO edges(from_title, via, to_title) VALUES (?,?,?)",
              [from_title, via, title]) if from_title && from_title != title

  @db.execute("UPDATE sessions SET last_room=?, last_seen_at=? WHERE session_id=?",
              [title, event["at"], session_id])
  @db.execute("INSERT INTO visits(session_id, room_title, turn, iteration, at, arrived_via) VALUES (?,?,?,?,?,?)",
              [session_id, title, turn, iteration, event["at"], via])
end
```

A failed `move`/`look` (e.g. `"Alas, you cannot go that way..."`) parses
to `nil` per §1 and this whole method is skipped — the correct behavior,
verified directly against that real logged text.

**Coordinate assignment — real spatial layout, not a generic graph
layout.** Because `move` carries a real compass `direction`, rooms get an
actual (x, y) position instead of a force-directed guess:

```ruby
DIRECTION_DELTA = {
  "north" => [0, -1], "south" => [0, 1],
  "east"  => [1, 0],  "west"  => [-1, 0],
  # up/down have no 2D slot; nudged diagonally purely for visual
  # separation, not claimed as real geometry — a documented simplification.
  "up"    => [0.4, -0.4], "down" => [-0.4, 0.4]
}.freeze

def assign_coordinate(title, from_title, direction)
  return if room_coord(title)   # placed once, ever — never moved again,
                                 # so the map doesn't reshuffle on refresh

  from_coord = from_title && room_coord(from_title)
  x, y =
    if from_coord.nil?
      [0.0, 0.0]                # first room discovered from this session
    else
      delta = DIRECTION_DELTA[direction.to_s]
      delta ? [from_coord[0] + delta[0], from_coord[1] + delta[1]]
            : next_free_slot_near(*from_coord)   # enter/leave/flee: no compass data
    end

  @db.execute("UPDATE rooms SET coord_x=?, coord_y=? WHERE title=?", [x, y, title])
end
```

`next_free_slot_near` tries a small fixed ring of offsets around the source
room and picks the first unoccupied coordinate — used only for
direction-less arrivals (`enter`/`leave`/`flee`).

Known simplifications, stated rather than engineered around: (a) two
rooms sharing a title still collide (unchanged from the original plan —
not observed in sampled data); (b) if two genuinely disconnected regions of
the world are each first discovered with no known `from_title` (e.g. two
characters starting fresh, but landing in *different*, previously-unseen
rooms), both get placed at `(0, 0)` and overlap — in practice this only
risks colliding at the very first room ever recorded, since any
previously-discovered starting room (the shared MUD login room, visited by
a second character) already has a coordinate and is reused, not
re-placed; (c) non-Euclidean MUD geometry (a `south` that doesn't lead back
via `north`) can make edges render as diagonal lines across the grid
rather than perfectly rectilinear — accurate to the game, not a rendering
bug.

**Live agents**: a session counts as live if `sessions.last_seen_at` is
within the last 60 seconds — a plain heuristic over data already being
written, no new signal needed.

**Corrupt-database recovery**: if `SQLite3::Database.new` or the schema
setup raises, the file is renamed aside (`world_map.sqlite3.corrupt-<ts>`)
and a fresh database is created. Since `file_offsets` starts empty again,
the very next refresh replays every session file from scratch and
reconstructs the merged model exactly — the database is a cache over the
durable `.jsonl` logs, never a second source of truth, so losing it is a
one-time full-replay cost, not data loss.

### 3. Per-session inline location/self-state (unchanged in scope, no DB dependency)

The single-session transcript page (`/sessions/:id`) doesn't have the
scaling problem `WorldMap` solves — it already parses exactly one file per
request, same as today. It gains its own small, self-contained extension to
`Session#parse!`'s existing `when "tool_result"` branch: call
`RoomEcho.parse`/`SelfState.summarize` directly (no `WorldMap`/SQLite
dependency, keeping `Session` independently testable), and track:

- `@current_room` — the last successfully parsed room title this session
  reached, exposed via `current_room`.
- `@self_state` — `kind => {text:, turn:, iteration:, at:}`, exposed via
  `self_state`.
- `Entry#room_title` — set on a `:tool` entry when its result parsed to a
  room, for the inline badge (§4). This is a simple "reached this room" tag,
  not a new-vs-revisit distinction — that distinction needs cross-session
  history, which only `WorldMap` has, and lives on the Map page instead.

### 4. UI

**Map page (`/map`, separate from the session page — a running session
page is already dense with the token/request/composition charts from the
other three plans; the world map is a different lens entirely: exploration
progress across every session ever run, not one session's transcript).**

- An inline SVG node-link graph: circles at each room's stored `(coord_x,
  coord_y)` (scaled to pixels, no layout computation needed at render time
  since coordinates are pre-assigned and stable — no JS, matching this
  project's existing "plain ERB + inline SVG" house style), lines for each
  edge.
- One marker per **live** session, placed at its current room, color-coded
  per session so multiple concurrent characters are visually distinguishable
  — a CSS pulse animation is the "highlighter," no JS required. Hovering
  (native `title` attribute) shows task/model/iteration/turn.
- A **discoveries** panel below the graph: every unique room-content string
  across all rooms, deduplicated, each row showing which room(s) it
  appeared in and when first seen (`WorldMap#discoveries`, built with a
  plain `GROUP BY` over `room_contents` — the reason that table is
  normalized rather than a JSON blob per room).
- A **live agents** table: every session currently live, its task/model,
  current room, turn/iteration — this *is* the multi-agent monitoring view
  ("how many agents are playing," "summary of every character"), sourced
  from the same merged structure as the map itself, not a separate
  dashboard.
- The whole page auto-refreshes (`<meta http-equiv="refresh">`) so new
  agents/rooms appear without a manual reload.

**Session page** gains: a current-location chip near the existing header
(from `@session.current_room`), an inline `→ <Room Title>` badge on `:tool`
entries that parsed a location, and a small self-state panel rendering
`@session.self_state` (§6), each entry labeled "as of turn N" rather than
implying continuous tracking.

**Index page** gains a live/ended indicator and current-room column per
session row, sourced from `WorldMap#sessions`.

### 5. Inventory / self-state — included in v1

Already covered by §2/§3's `self_state` table and `Session#self_state`: a
last-known snapshot per `info_self` `kind` (`inventory`, `equipment`,
`score`, `exits`, `where`, `levels`), honestly labeled by the turn/iteration
it was last checked, not a continuously-tracked inventory (the agent only
reveals this when it happens to check — confirmed rare in real sessions).

## Known tradeoffs / risks

- The room-echo parser is specific to CircleMUD/tbaMUD's fixed shape — a
  differently-configured MUD server would need a different parser.
- Dark rooms, combat interruptions, or any tool result that doesn't match
  the title+exits anchors parses to "no update" by design, not a bug.
- Inherited, not introduced: tool_call/tool_result pairing can already be
  wrong for unrelated transport reasons (Background) — this plan fails
  closed against that but doesn't fix the underlying pairing.
- Title-as-room-key can theoretically collide across two distinct rooms
  with the same display name — not observed in sampled data.
- `WorldMap` assumes a single writer process (this `log_viz` instance).
  Concurrent writers from two separately-running `log_viz` processes
  against the same SQLite file aren't a design goal here — WAL mode
  tolerates concurrent *readers* fine, but two refreshers racing on the
  same `file_offsets` row isn't guarded against beyond SQLite's own
  transaction isolation.
- Coordinate assignment's known simplifications are listed inline in §2
  rather than repeated here.

## Files touched

- `week2_observability/log_viz/Gemfile` / `Gemfile.lock` — add `sqlite3`.
- `week2_observability/log_viz/lib/log_viz/room_echo.rb` (new) — §1.
- `week2_observability/log_viz/lib/log_viz/self_state.rb` (new) — §1.
- `week2_observability/log_viz/lib/log_viz/world_map.rb` (new) — §2: schema,
  incremental ingestion, coordinate assignment, live-session/discoveries
  accessors, corrupt-DB recovery.
- `week2_observability/log_viz/lib/log_viz/session.rb` — `Entry#room_title`,
  `current_room`, `self_state` (§3); no dependency on `WorldMap`.
- `week2_observability/log_viz/lib/log_viz/app.rb` — a memoized `WorldMap`
  instance refreshed per request, `/map` route, SVG map-rendering helper,
  discoveries/live-agents helpers, index-page liveness wiring (§4).
- `week2_observability/log_viz/views/map.erb` (new) — §4.
- `week2_observability/log_viz/views/session.erb` — location chip, inline
  badges, self-state panel (§4).
- `week2_observability/log_viz/views/index.erb` — liveness/current-room
  column (§4).
- `week2_observability/log_viz/views/layout.erb` — nav link to the map page.
- `week2_observability/log_viz/public/style.css` — map/badge/self-state/
  live-marker styling.
- `week2_observability/log_viz/test/test_room_echo.rb` (new) — parser
  fixtures from the real captured strings above, plus negative cases
  (`"Look at what?"`, `"Alas, you cannot go that way..."`, a dark room).
- `week2_observability/log_viz/test/test_world_map.rb` (new) — incremental
  ingestion (only new bytes reprocessed on a second refresh), coordinate
  stability across refreshes, corrupt-database recovery, discoveries
  grouping.
- Nothing under `week2_observability/ruby/12_context/` — no change to the
  agent, client, logger, or MCP tool layer.

## Resolved decisions

(Previously open questions — settled and folded into the design above.)

1. `flee` **is** treated as location-revealing (§1) — a successful flee
   relocates the player unpredictably, which is exactly the kind of
   unplanned move this feature needs to catch.
2. The map/discoveries panels live on their **own page** (`/map`), not
   inline on the session page — and are historical/cross-session rather
   than scoped to one session's transcript (§2/§4).
3. The map is an **actual node-link graph** with real coordinates (derived
   from compass directions, §2), not an adjacency table, with a live
   marker/highlighter per currently-playing agent (§4).
4. Inventory/self-state (§5) **ships in v1**, as a last-known-snapshot
   panel rather than continuous tracking.
