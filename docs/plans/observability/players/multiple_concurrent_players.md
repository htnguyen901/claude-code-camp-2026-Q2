## Goal

I want to allow boukensha to log in and and play as multiple players at the same time.
The player profiles are located in .boukensha/players. Boukensha should have different
sessions for each users and play independently. 

- Each player should have their own memory and they can't access to other player's memory
- Each player play independently and track their own token usage/path/discoveries independent
- Each player should grow their own knowledge base/discoveries/rooms. These knowledge will 
contribute to the growth the world knowledge - world map (which belong to and only viewable 
to user/engineer/me). 
- Players should not have access to the global world map or world knowledge. They each should have
and manage their own

Additional requirements:
- I need a better interface to be able to view the World Map and each player's knowledge/discoveries/maps 
and other info
- For this might need to separate each entity into different tabs in log_viz
- For each player, I need view view a time-lapse path taken (movement) by the player in each session.
Each session should have a panel overviewing the path in node-like view. And details will show exact 
path takens
- For each player, There should be a friendly summary, or KPI card showcasing the discoveried vs discoverables
comparing to the my World Map (compare player's journey to what could be discovered in the current explored global World Map)
- Right now the log_viz also has 1 issue: the page keep refreshing at a certain inverval and I lose my current opened view,
which is annoying. I want this gone.

Based on all the above requirements, please research and evaluate if the current log_viz is capable and 
is enough to serve those. Or should we move to a better/interactive solution

---

## Research findings

- **Character creation is already solved; running characters concurrently is not.**
  `.boukensha/players/{admin,dina,dummy,noir}.yaml` already exist
  (`docs/plans/observability/players/players_seeding.md`, implemented) — one
  YAML per profile with `name`/`password`/`sex`/`class`/`admin`/`persona`.
  This plan doesn't need to seed anyone new; it needs the *runtime* to
  actually use more than one of these at once, which nothing does today.
- **Today there is exactly one MUD identity, hardcoded in shared config.**
  `.boukensha/settings.yaml`'s `mcp_servers.mud.env` pins `MUD_NAME: dummy` /
  `MUD_PASSWORD: helloworld` for every `boukensha` invocation.
  `Boukensha::Config#mcp_servers` (`16_navigation/lib/boukensha/config.rb`)
  reads that block verbatim and `boukensha_loader.rb`'s own comment states
  plainly: *"config now wins over the environment, where it used to lose"* —
  i.e. you cannot today override `MUD_NAME` by exporting it before running
  `boukensha`. Two concurrent `boukensha` processes launched right now would
  both try to log `dummy` in at once. This is the actual blocker behind "log
  in and play as multiple players at the same time," not a missing feature
  so much as a missing plumbing path from an already-built player profile to
  the process that logs in.
- **The transport already supports this; the agent process is the gap.**
  `MudManager::McpServer` (`week0_explore/mud_manager/lib/mud_manager/
  mcp_server.rb`) keys sessions by `session_id` and happily holds several
  logged-in characters — but each `boukensha` invocation spawns its *own*
  `mud-manager --mcp` subprocess (`Boukensha::Tools::Mcp.register` →
  `Open3.popen3`), one per process, each authenticating its lone `"default"`
  session from `ENV["MUD_NAME"]`/`ENV["MUD_PASSWORD"]` at boot
  (`McpServer#open_default_session_from_env`). So "multiple concurrent
  players" in this codebase means **multiple concurrent `boukensha`
  processes**, each spawning its own isolated `mud-manager` subprocess as a
  different character — not one process juggling several sessions. That
  isolation is good news for this plan: it means conversation `Context`
  (`16_navigation/lib/boukensha/context.rb`) is already per-process and
  therefore already never shared between two players — nothing to build
  there. What's missing is purely (a) getting each process to authenticate
  as a *different* character, and (b) tagging what it logs with *which*
  character, so the pieces downstream (log_viz, `room_knowledge`) can tell
  players apart.
- **`.boukensha/sessions/*.jsonl` already has zero player identity in it.**
  `Boukensha::Logger#initialize` (`16_navigation/lib/boukensha/logger.rb`)
  writes a `session_start` event from a `snapshot:` hash built in
  `Boukensha.run`/`.repl` (`lib/boukensha.rb`) — `model`, `provider`, `task`,
  limits, OTel config. `task` is always the literal string `"player"`
  (`Tasks::Player.task_name`) regardless of who's playing — it identifies
  the *task type*, not the character. Nothing in the snapshot, and nothing
  in `LogViz::Session`/`LogViz::WorldMap`'s parsing of it
  (`world_map.rb`'s `sessions` table: `session_id, path, task, provider,
  model, started_at, last_room, last_seen_at, turn, iteration`), carries a
  player name. Every plan in this directory so far (`player_journey_map.md`,
  `room_world_inspector.md`, `world_map_visualization.md`) was written and
  shipped under an implicit one-player-at-a-time assumption; grouping
  sessions by *who* was playing is new ground, not an oversight in those.
- **`room_knowledge` already leaks across players by construction — this is
  the real "memory isolation" gap, not conversation `Context`.**
  `Boukensha::WorldKnowledge.room_knowledge` (`16_navigation/lib/boukensha/
  world_knowledge.rb`) opens `.boukensha/world_map.sqlite3` read-only and
  answers "what's examined/unexamined in room X" from `content_facts`/
  `examinations` with **no scoping at all** — any agent process, playing as
  any character, can ask about (and get real answers for) any room *any*
  player has ever visited, including rooms the calling player's own
  character has never set foot in. `rooms`/`room_contents`/`content_facts`
  in `LogViz::WorldMap` (`log_viz/lib/log_viz/world_map.rb`) are, by design,
  global dedup tables keyed by room title / content string — deliberately
  so two different sessions discovering "The Temple Square" don't double
  up. That global-dedup design is fine and worth keeping (it's factually
  correct — two characters seeing the same room *are* seeing the same
  room), but the **query surface** built on top of it never learned to ask
  "but has *this* player's own character actually been here" before
  answering. That's the concrete thing this plan has to fix to satisfy "each
  player should have their own memory and can't access other player's."
- **The world map / `log_viz` UI is explicitly the engineer's tool, not the
  agent's** — the user's own goal statement says the World Map "belong[s] to
  and [is] only viewable to user/engineer/me." So the isolation problem above
  is entirely about the `room_knowledge` *tool* (what an agent can query
  mid-game), not about `log_viz`'s dashboard (what the human sees in a
  browser) — `log_viz` can and should keep showing everything across every
  player, since nothing there is agent-facing.
- **The "page keeps refreshing" bug is real and has an identifiable root
  cause, not just an annoyance to paper over.** `views/map.erb` already
  ships a `<meta http-equiv="refresh" content="15" id="map-meta-refresh">`
  plus a `<script>` that does `document.getElementById("map-meta-refresh").
  remove()` on load, intended as a no-JS fallback
  (`room_world_inspector.md` §5). But browsers commit to an
  `http-equiv="refresh"` timer at *parse* time — removing the `<meta>`
  element from the DOM afterward does not reliably cancel an
  already-scheduled reload in Chrome/Firefox. The JS-removal approach looks
  correct in isolation (and the rest of the polling/drag/click JS on that
  page does work) but the fallback mechanism itself is the bug: it fires on
  a timer regardless of whether JS is running, which matches exactly what
  was reported — the view resets (scroll position, an open room-detail
  panel, typed-but-unsubmitted search filters) every ~15s. No other page
  (`index.erb`, `session.erb`) has any refresh mechanism today, so this is
  isolated to `/map`.
- **No existing page groups sessions by player, and no existing schema
  column could support it without a migration.** `index.erb` lists every
  `.jsonl` file as a flat, most-recent-first list; nothing aggregates
  "everything Noir has ever done" across her possibly-many session files.

## Plan: player identity end-to-end, isolated per-player knowledge, and a Players view in log_viz

### 0. Scope decision

"Multiple concurrent players" decomposes into four genuinely separate
problems, and it's worth being explicit that this plan addresses all four
but with very different amounts of new code:

1. **Make it possible to run two `boukensha` processes as two different
   characters at the same time.** Currently blocked by shared static config
   (Research, above). Small, load-bearing fix — §1.
2. **Stop `room_knowledge` (and any future "what do I know" surface) from
   leaking one player's discoveries into another's.** Currently leaks by
   omission, not by a deliberate design that needs undoing — §2.
3. **Let a human see, per player, what happened** — aggregated usage, a
   discovered-vs-discoverable KPI, and a time-lapse path view per session.
   Net-new UI on top of data that (mostly) already exists once §1 tags it —
   §3/§4.
4. **Fix the refresh bug and decide whether `log_viz` is still the right
   tool.** Independent of 1–3 but explicitly asked for — §5/§6.

Per-player *conversation* memory needs no new work: `Context` is already
one-per-process and never shared (Research, above) — restated here so it's
clear this plan isn't silently skipping it, it's already satisfied.

### 1. Player identity through the run/repl entrypoint

The one load-bearing change: let a `boukensha` invocation say *which*
`.boukensha/players/*.yaml` profile it's logging in as, and have that
actually override the MUD credentials instead of losing to `settings.yaml`.
Additive and backward compatible — omit it and behavior is byte-for-byte
what it is today (static `MUD_NAME`/`MUD_PASSWORD` from `settings.yaml`),
which matters because it means existing single-player workflows and the
`seed_players` script are untouched.

- **`boukensha_loader.rb`**: parse a `--player NAME` CLI flag (falling back
  to `ENV["BOUKENSHA_PLAYER"]`, CLI wins if both given — same precedence
  convention the file already documents for `BOUKENSHA_PATH`/`BOUKENSHA_DIR`).
  If given, load `.boukensha/players/#{name}.yaml` via a small new
  `Boukensha::PlayerProfile.load(name, players_dir:)` (new file,
  `16_navigation/lib/boukensha/player_profile.rb` — reuses the plain
  `YAML.safe_load` convention `Config#load_settings` already uses, no new
  dependency). Abort with a clear message if the named file doesn't exist —
  same posture as `boukensha_loader.rb`'s existing `BOUKENSHA_PATH` abort
  message, not a silent fallback to the shared default character.
- **`Boukensha.run`/`.repl`** (`lib/boukensha.rb`) gain a `player: nil`
  kwarg. When present:
  - Before `register_mcp_servers(registry, cfg)`, overlay
    `player.name`/`player.password` onto whichever `mcp_servers` entries
    already declare `MUD_NAME`/`MUD_PASSWORD` keys in their `env:` block —
    matched by key name, not a hardcoded `"mud"` server name, so this stays
    generic the way `Config#mcp_servers` already is (nothing about the MUD
    is special-cased elsewhere in this file). Concretely: `cfg.mcp_servers`
    already returns a plain hash; a tiny `overlay_player_credentials(servers,
    player)` helper mutates `env["MUD_NAME"]`/`env["MUD_PASSWORD"]` in place
    only where those keys already exist, before the loop that spawns each
    server.
  - Add `player: player&.name` to the `Logger.new(snapshot: {...})` hash in
    both `.run` and `.repl` — this is the one field that lets every
    downstream consumer (log_viz, a future per-player export) tell sessions
    apart by character.
- **`boukensha_loader.rb`'s `Boukensha.repl(tui: !no_tui) do ... end` call**
  passes `player: profile` through.
- Running two players concurrently becomes: two terminals (or a `tmux`/
  process-manager layer, unchanged from how any two long-running CLI
  processes are normally run — no new process supervisor is being built
  here), `boukensha --player noir` in one, `boukensha --player dina` in the
  other. Each spawns its own `mud-manager --mcp` subprocess authenticated as
  a different character (already-supported per Research), each writes its
  own `.boukensha/sessions/<session_id>.jsonl` (session ids are already
  random per process — `SecureRandom.hex(4)` — so no collision risk), tagged
  `player: "noir"` / `player: "dina"` in its `session_start` event.
- **Not doing**: no built-in process supervisor/launcher script to start N
  players at once. `week2_observability/bin/` could grow a thin
  `play_players noir dina` wrapper later if it turns out to be wanted, but
  the ask here is "allow... to log in and play as multiple players," which
  §1 satisfies — orchestrating *when* each one runs is a separate,
  smaller, and speculative addition not asked for.

### 2. Per-player knowledge isolation (fixes the actual "own memory" gap)

Keep `rooms`/`room_contents`/`content_facts`/`edges` exactly as they are —
global, deduped-by-content tables. That's correct: two characters seeing
"The Temple Square" *are* seeing the same room, and re-deriving Tier-B LLM
extraction per player would be pure waste. What changes is that every
player-facing *query* over that shared storage gets scoped through the
requesting player's own visit history, the same way the real game already
scopes what a character can plausibly know (only what they've personally
seen).

- **`world_map.sqlite3` schema** (`log_viz/lib/log_viz/world_map.rb`):
  add `player TEXT` to `sessions` (additive column, same `CREATE TABLE IF
  NOT EXISTS` + a guarded `ALTER TABLE ... ADD COLUMN` migration path the
  file doesn't have a precedent for yet but `content_facts`/`examinations`'
  own additive-tables precedent already establishes the posture for —
  existing rows get `player: NULL` until their session is re-ingested, no
  destructive migration). Populated from the `session_start` event's new
  `player` field (§1) inside `WorldMap#process_line`'s existing
  `session_start` handling.
- **New accessor**: `WorldMap#rooms_visited_by(player)` — `SELECT DISTINCT
  room_title FROM visits WHERE session_id IN (SELECT session_id FROM
  sessions WHERE player = ?)`. This single query is the backbone of both
  §2's isolation and §4's KPI card.
- **`Boukensha::WorldKnowledge.room_knowledge`** (agent-side,
  `16_navigation/lib/boukensha/world_knowledge.rb`) gains a required
  `player:` argument (threaded from `Boukensha.config`'s loaded
  `PlayerProfile`, resolved once when the tool is registered in
  `boukensha_loader.rb` — the tool block already closes over local state,
  so this is a one-line change to what it passes through). Before answering,
  it checks the requested `room_title` against that player's own visited
  rooms (a duplicate of `rooms_visited_by`'s query, same different-process
  reason `EXAMINED_EXISTS_SQL` is already duplicated between `log_viz` and
  this file, documented inline the same way): if the player's own sessions
  never visited that room, return `{room_title:, examined: [], unexamined:
  [], note: "you have not been here"}` instead of the globally-known
  answer — this is the actual fix for "players should not have access to
  the global world map or world knowledge."
  - When the player *has* visited the room, the existing
    `EXAMINED_EXISTS_SQL`/`EXAMINATION_RESULT_SQL` queries are additionally
    scoped: an `examinations` row only counts as "this player examined it"
    if it came from one of *their own* sessions (join `examinations` →
    `sessions.player = ?` the same way). A room can be genuinely
    "unexamined by you" even if a different character examined the same
    subject in the same room — that's correct: they're different
    characters with different knowledge, not one shared save file.
- No change to `content_facts`/Tier-B extraction, `room_description_scans`,
  or the background worker thread — those stay global/shared exactly as
  designed, since they're facts about the *world*, not about any player's
  awareness of it.

### 3. Aggregating a player across (possibly many) sessions

New `WorldMap` accessors, all straightforward `GROUP BY player` queries over
existing tables plus the new column:

- `WorldMap#players` → one row per distinct non-null `sessions.player`:
  session count, total turns/iterations (sum), first/last-seen timestamps,
  whether any of their sessions is currently live (`last_seen_at` within
  `LIVE_WINDOW_SECONDS`, same heuristic `/map` already uses), current room
  if live.
- `WorldMap#player_summary(name)` → that player's own session list (id,
  task, provider/model, started_at, room count via `rooms_visited_by`,
  turn/iteration totals) plus the discovered-vs-discoverable numbers for
  the KPI card (§4).
- Cost/token totals reuse `LogViz::Session`'s existing per-session
  computation (`session.rb` already parses `request`/`response` events into
  `total_input_tokens`/`total_output_tokens`/`estimated_cost` per session) —
  `player_summary` sums those across the player's session ids rather than
  recomputing token accounting from scratch, keeping the "cost math lives in
  `Session`" boundary that already exists.

### 4. log_viz UI: Players tab, KPI card, per-session time-lapse path

- **Nav** (`views/layout.erb`): add a `Players` link next to the existing
  `World Map` one.
- **`GET /players`** (new route, `app.rb`) → `views/players.erb`: one card
  per player from `WorldMap#players` — name, live/idle badge, session
  count, total cost/tokens, rooms discovered. Links to `/players/:name`.
- **`GET /players/:name`** (new route) → `views/player.erb`:
  - **KPI card**: "discovered vs. discoverable" — `rooms_visited_by(name).
    count` / `WorldMap#rooms.count` (the engineer's current global total,
    per the user's own framing: "compare player's journey to what could be
    discovered in the current explored global World Map" — the denominator
    is *what's been found so far by anyone*, not a claim about the MUD's
    true total size, which nothing in this stack knows). Same shape for
    discoveries: distinct `content_facts.subject` this player's rooms
    contain vs. the global distinct-subject count. Rendered with the
    existing `progress_bar` helper (`app.rb`) already used for context-window
    /turn-token bars on `session.erb` — reused, not a new widget.
  - **Session list** for this player (from `player_summary`), each row
    linking to `/sessions/:id` as today.
- **Per-session time-lapse path panel**, on the *existing* `/sessions/:id`
  page (`session.erb`) — not a new route, since "each session should have a
  panel" reads as part of that session's own page, right below the existing
  location chip/self-state panel from `player_journey_map.md` §4:
  - **Overview**: a small node-link graph scoped to *this session's own*
    `visits` (reusing `map_svg`'s box-node rendering primitive from
    `world_map_visualization.md`, called with a `session_id:` filter instead
    of the full map — same coordinates as the global map, since
    `rooms.coord_x/coord_y` are stable and shared, just drawing a subset of
    nodes/edges plus a sequence number badge per node for visit order).
  - **Detail / time-lapse**: the ordered `visits` rows for this session
    (`room_title`, `turn`, `iteration`, `at`, `arrived_via`) rendered as a
    list **and** driving a small step-through control — a `<script>` island
    (same narrow-departure precedent as `map.erb`'s existing JS) with
    prev/next/play buttons and a slider bound to visit index; stepping
    highlights the corresponding node in the overview graph
    (`.map-node.active` outline) and scrolls the detail list to that row.
    Data for this is small (one session's visit count, not the whole map)
    and already fully available server-side per request — the panel can
    render the complete ordered visit list inline as JSON for the script to
    animate over, no new polling endpoint needed (this is historical replay
    of a specific session, not a live feed — worth distinguishing from
    `/map/live.json`, which is about *current* positions across sessions).
  - Degrades with no JS to: the plain ordered list (works today's way),
    just without the animated scrubber/highlight — consistent with every
    other JS addition in this codebase being additive over a working
    fallback.

### 5. Fixing the refresh bug

Root cause per Research: `<meta http-equiv="refresh">`'s timer is
committed at parse time; DOM removal after the fact doesn't reliably cancel
it. Fix: wrap it in `<noscript>` instead of giving it an `id` for JS to
remove —

```erb
<noscript><meta http-equiv="refresh" content="15"></noscript>
```

— which the browser only ever parses/applies when scripting is disabled in
the first place, eliminating the race entirely (no JS-removal step needed,
so that code comes out of `map.erb`'s `<script>` block too). Apply the same
`<noscript>`-wrapped pattern to any future auto-refreshing fallback this
plan adds (`/players`, `/players/:name` don't get a meta-refresh at all —
they're not live-updating pages, a plain page load is enough; only `/map`
had this to begin with).

### 6. Should log_viz be replaced?

**No — extend it.** Grounds for that, weighed against what this plan
actually needs:

- Every prior ask in this same category (drag-to-pan, click-to-inspect
  detail panel, search/filter/pagination, 5-second live polling) was
  delivered inside `log_viz`'s existing Ruby/Sinatra/ERB + SQLite +
  narrowly-scoped-vanilla-JS house style, without a framework or build
  step, and is working in production against real 45-room accumulated data
  (`world_map_visualization.md`'s "Implemented" section). Nothing this plan
  needs is a different *kind* of feature — a Players tab is more routes/
  views over the same `WorldMap` object; per-player scoping is a `WHERE
  player = ?` clause; the time-lapse panel is one more narrowly-scoped JS
  island animating over data the server already has fully in hand for one
  session (dozens to low hundreds of visit rows, not a streaming problem).
- The project has already explicitly considered and rejected heavier
  machinery for adjacent problems — SSE for live updates
  (`room_world_inspector.md` §5: "more operational cost than a local dev/
  observability tool warrants"), a JS framework for the map. Nothing about
  "add player grouping + a session-scoped path replay" changes that
  calculus; the data volumes are the same order of magnitude (players in
  the single-to-low-double digits, sessions in the hundreds, rooms in the
  tens).
- A rewrite (React SPA, a bundler, a second runtime) would mean a new build
  pipeline and dependency surface for a tool used by one person (the
  engineer) locally, to save nothing this plan actually needs saved — the
  slowest part of any of this is Tier-B Ollama extraction latency
  (already async, per `room_world_inspector.md`'s background-worker
  design), not rendering.
- **Where this reasoning would flip**: if concurrent live players grow from
  a handful to dozens+, or accumulated sessions grow from hundreds to tens
  of thousands, server-rendered full-table pages and 5s polling could start
  to strain. Worth flagging, not worth solving speculatively — same posture
  every sibling plan in this directory already takes on its own "known
  tradeoffs" (e.g. `world_map_visualization.md` explicitly deferred zoom
  controls the same way). Revisit if/when it's actually the bottleneck.

## Files touched

- `week2_observability/ruby/16_navigation/lib/boukensha_loader.rb` —
  `--player`/`BOUKENSHA_PLAYER` parsing, loads `PlayerProfile`, passes
  `player:` into `Boukensha.repl`.
- `week2_observability/ruby/16_navigation/lib/boukensha/player_profile.rb`
  (new) — loads/validates one `.boukensha/players/*.yaml`.
- `week2_observability/ruby/16_navigation/lib/boukensha.rb` — `player:`
  kwarg on `.run`/`.repl`, credential-overlay helper before
  `register_mcp_servers`, `player:` added to the `Logger.new(snapshot:)`
  hashes.
- `week2_observability/ruby/16_navigation/lib/boukensha/world_knowledge.rb`
  — `player:` scoping on `room_knowledge` (§2).
- `week2_observability/log_viz/lib/log_viz/world_map.rb` — `sessions.player`
  column + migration, `rooms_visited_by`, `players`, `player_summary`
  accessors (§2/§3), `map_svg` gains an optional `session_id:` filter for
  the per-session overview (§4).
- `week2_observability/log_viz/lib/log_viz/session.rb` — no change expected
  beyond what §4 needs read from `WorldMap`/`visits` directly (the session
  page's new panel is fed by `WorldMap`, matching how `current_room`/
  `self_state` already coexist without `Session` depending on `WorldMap`,
  per `player_journey_map.md` §3's existing boundary).
- `week2_observability/log_viz/lib/log_viz/app.rb` — `/players`,
  `/players/:name` routes; `map_svg` session-filter param; drop the
  `map-meta-refresh` JS-removal code (§5).
- `week2_observability/log_viz/views/players.erb` (new), `player.erb` (new)
  — §4.
- `week2_observability/log_viz/views/session.erb` — time-lapse panel (§4).
- `week2_observability/log_viz/views/map.erb` — `<noscript>`-wrapped
  meta-refresh (§5), remove the now-unnecessary removal script.
- `week2_observability/log_viz/views/layout.erb` — `Players` nav link.
- `week2_observability/log_viz/public/style.css` — player card, KPI
  progress-bar labels, time-lapse control, `.map-node.active` styling.
- `week2_observability/log_viz/test/test_world_map.rb` — `sessions.player`
  ingestion, `rooms_visited_by`, `players`/`player_summary`, migration of a
  pre-existing (no-`player`-column) database.
- `week2_observability/ruby/16_navigation/test/` — `PlayerProfile` loading/
  missing-file behavior, credential-overlay helper, `room_knowledge`'s new
  "haven't been here" branch.

## Known tradeoffs / risks

- **Two players sharing one `session_id` collision is theoretically
  possible but not newly introduced** — `SecureRandom.hex(4)` timestamps
  were already assumed unique per process; nothing here changes that
  surface.
- **`player` is trusted, not authenticated.** `--player noir` just means
  "load `noir.yaml` and log in as her" — there's no check that the human
  running the process is who they claim, matching this whole project's
  single-operator threat model (same posture as `seed_players`' own "this
  script is for the engineer, not the agent" note).
- **A player who never gets tagged (pre-this-plan session files, or a run
  launched without `--player`) stays `player: NULL`** — falls out of every
  `/players/*` page and the isolation check in `room_knowledge` (a `NULL`
  player's `room_knowledge` calls keep today's un-scoped, whole-map-visible
  behavior, since there's no player to scope by) — an explicit, visible gap
  rather than a guess, and fully backward compatible.
- **The discoverable denominator in the KPI card is "what's been found by
  anyone so far," not the MUD's true size** — stated plainly in §4 rather
  than implied; nothing in this stack (or the MUD protocol as used here)
  knows the real total room count.
- **`room_knowledge`'s per-player scoping duplicates query logic that
  already exists in two places** (`log_viz`'s `WorldMap` and the agent-side
  `WorldKnowledge`) — same maintenance cost the file's own comments already
  flag for `EXAMINED_EXISTS_SQL`, just extended to one more query. A schema
  change now has to be applied in three places instead of two; still judged
  worth it over adding a runtime dependency between the two processes.

## Open questions

1. `--player` flag name / `BOUKENSHA_PLAYER` env var name — any preference,
   or is the above fine?
2. Should an omitted `--player` (falling back to `settings.yaml`'s static
   `dummy` credentials) keep working silently as today, or should it print
   a one-line notice ("no --player given, using settings.yaml's default
   MUD_NAME") so it's obvious which mode a given run is in? Leaning toward
   a notice — it's the exact ambiguity that caused the "who am I logged in
   as" confusion this plan exists to fix.
    A: It should print a one-line notice as the player credentials in settings.yaml shall 
    be removed
3. Is a `week2_observability/bin/play_players` convenience launcher (spawn
   N `boukensha --player X` processes, one per given name, each in its own
   log file) wanted now, or should §1's "not doing" stand for this pass?
   A: for now we can use that play_players launcher, assuming I can pass in the
   goal as well and all players selected are executing the same goal. But later
   I need to be able to give them separate goals