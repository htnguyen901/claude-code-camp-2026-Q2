## Goal

Items to enhanced after the implementation of `players/multiple_concurrent_players.md`

I need to enhance the log_viz UI to be more human-friendly and modern:
- All map including World Map and Path taken this session in Player poage needs to be zoomable and scrollable
- Map should have a visual indicator of 'unexplored room'. This means:
The room can be signaled, defined through the room inspector tool, but if the players 
have never entered this room, it should not displayed on the map as a 'discovered node'
- I should be able to search for room by text in map. The map should be reactive to 
my key-in
- Rooms and Discoveries should have their own page to avoid clustering the map page
- The Players page needs enhancers:
    - Should have an isolated map, rooms and discoveries found, which list exactly how they are in 
    the map page. Should also follow the above refactoration: separate section for map, room and
    discoveries. I shall call this knowledge (player's knowledge)
    - For the Sessions I want to add: the speed up progression of the path. Can just display room as node and does not have to show room name

For the above requirments, is Sinatra capable of serving us or do we have better solutions?

---

## Research findings — what's already shipped vs. what's actually new here

This plan lands on top of two already-implemented sibling plans, so it's
worth being precise about which asks are genuinely new work and which are
partially satisfied already:

- **Scroll + drag-to-pan already exist, zoom does not.**
  `world_map_visualization.md` §2 shipped a real, growable `<svg>` (explicit
  `width`/`height`, not just `viewBox`) inside a `.map-scroll { overflow:
  auto }` wrapper, plus JS click-and-drag panning — but that same plan's
  "Not doing" section explicitly deferred zoom controls. So "zoomable and
  scrollable" is half-true today: scrollable/draggable, not zoomable. The
  session-scoped "Path taken this session" panel on `/sessions/:id`
  (`multiple_concurrent_players.md` §4, `session.erb`'s `time-lapse-panel`)
  reuses the exact same `map_svg`/`.map-scroll` markup with a
  `session_id:` filter, so it inherits the identical gap.
- **A room can never appear on the map without being visited — already true
  by construction, just not documented as an explicit guarantee.**
  `WorldMap#upsert_room` (`world_map.rb`) — the only path that ever inserts
  a `rooms` row — is called exclusively from `record_visit`, itself only
  called from `handle_tool_result` when `RoomEcho.location_tool?` matches
  (`look`/`move`/`enter`/`leave`/`flee`). The read-only `room_knowledge`
  agent tool (`13_room_inspector/lib/boukensha/world_knowledge.rb`) only
  ever `SELECT`s from `content_facts`/`examinations` — it has no write path
  into `rooms` at all. So "signaled... through the room inspector tool, but
  not displayed as discovered until entered" already holds; what's missing
  is the other half of the ask — visualizing that a *known, unvisited*
  neighbor exists (see §2 below).
- **Rooms/discoveries search exists but is full-page-reload, not
  reactive-to-keystroke.** `room_world_inspector.md` §4 shipped `?q=`,
  `?kind=`, `?room=`, `?examined=`, `?room_q=` as plain GET form params —
  submit-to-filter, not live. "Reactive to my key-in" is genuinely new.
- **Rooms and Discoveries share `/map` with the map itself and the live
  sessions table** — one page, four sections, exactly the clustering
  complaint in this doc's Goal. Splitting them into their own pages is
  genuinely new routing/view work, not a rewrite of the underlying queries.
- **The Players page and per-session time-lapse already exist; a
  player-scoped "Knowledge" view (isolated map/rooms/discoveries) does
  not.** `multiple_concurrent_players.md` shipped `/players`, `/players/:name`
  (KPI progress bars, session list), and `/sessions/:id`'s time-lapse path
  panel — but that same plan's §6 explicitly scoped `log_viz`'s dashboard as
  "the engineer's tool," deliberately showing everything across every
  player, precisely because the ask at the time was aggregate KPIs, not a
  per-player map. This plan's "Players page needs... an isolated map, rooms
  and discoveries... I shall call this knowledge" is a new, narrower ask
  that supersedes that framing for `/players/:name` specifically (not a
  reversal of `room_knowledge`'s agent-side per-player isolation from
  `multiple_concurrent_players.md` §2, which is unrelated and unaffected).
- **The Sessions table on `/players/:name` (`player.erb`) has no path
  visualization at all today** — just tabular metadata (started, id, task,
  model, iterations, tokens, cost). The full interactive time-lapse replay
  already lives one click away on `/sessions/:id`; what's being asked for
  here is a small glance-able indicator inline in the list itself, not a
  duplicate of the full panel.

## Answer: is Sinatra capable, or do we need something else?

**Yes — extend it, same as the last two rounds of this question.** Every
item below is one of three shapes, and none of the three is a different
*kind* of feature than what `log_viz` already does successfully in plain
Sinatra/ERB/SQLite + a narrowly-scoped vanilla-JS island:

1. More routes/views over queries `WorldMap` already exposes, plus a
   handful of new keyword args on existing methods (§4, §5 below) — the
   same shape as every route added by the last two plans.
2. A rendering-only addition to `map_svg` (§2's unexplored-neighbor stubs)
   — no new table, no layout algorithm, same "rendering layer only, storage
   untouched" precedent `world_map_visualization.md`'s coordinate-collision
   fix already established.
3. More vanilla JS islands (§1 zoom, §3 live search) layered onto the one
   already-accepted, narrowly-scoped JS departure from this project's
   otherwise plain-ERB house style (`room_world_inspector.md` §5) — bigger
   in surface area than before, but not a different architecture.

Nothing here needs a client-side framework, a build step, or a second
runtime: data volumes are still the same order of magnitude flagged as the
threshold in `multiple_concurrent_players.md` §6 (rooms in the tens,
sessions in the hundreds, players in the low double digits at most), and
this repo has already shipped drag-to-pan, click-to-inspect, 5-second
polling, and keyset pagination inside that same stack without strain.
**Where this would flip**: if concurrent players grow from a handful to
dozens+, or the map grows from tens of rooms to thousands — restated from
the prior plan because nothing here changes that calculus, not because
there's new evidence either way.

---

## Plan

### 1. Zoom on every map instance (World Map, session time-lapse, new player Knowledge map)

Layered on top of the existing native scroll + JS drag-to-pan
(`world_map_visualization.md` §2), not a replacement for either:

- A small `.map-zoom-controls` overlay (`+`, `-`, `Reset` buttons) pinned to
  a corner of `.map-scroll`, plus `ctrl`/`cmd` + mouse-wheel zoom centered
  on the cursor position.
- Mechanism: a CSS `transform: scale(n)` on the `<svg>` element itself
  (`transform-origin` tracking the zoom-focus point), driven by a `zoom`
  state variable in JS — **not** a change to the SVG's `viewBox`/`width`/
  `height`. This matters: those attributes are exactly what
  `world_map_visualization.md` §2 fixed to give `.map-scroll` a real,
  growable `scrollWidth`/`scrollHeight` in the first place (`min-width:
  100%` was deliberately dropped from `.map-svg` to stop the browser from
  auto-shrinking it). A `transform: scale()` changes the *rendered* box
  size (and therefore what `.map-scroll`'s native scrollbars measure
  against) without touching the intrinsic content size those fixes rely
  on, so zoom and the existing real-scrolling fix compose instead of
  fighting each other.
- Clamp zoom to a sane range (e.g. 0.4×–2.5×) — a lower bound stops boxes
  from shrinking past clickable/legible, an upper bound stops the canvas
  from exceeding a reasonable scroll area.
- Shared implementation: one small ERB partial, `views/_map_zoom.erb`
  (script + `.map-zoom-controls` markup), rendered into `map.erb`,
  `session.erb`'s time-lapse panel, and the new player Knowledge map (§5) —
  avoids writing the same zoom script three times, matching how `map.erb`'s
  drag-to-pan/click-to-inspect script is already one block reused
  conceptually (though not yet literally shared) across pages.
- No-JS fallback: today's plain 1×, scroll/drag-only behavior — zoom is
  purely additive, exactly like drag-to-pan and click-to-inspect before it.

### 2. Unexplored-room indicator (fog-of-war exit stubs)

Two parts, one already true and one new:

- **Already true, being made explicit**: a room is never rendered as a
  discovered node until `record_visit`/`upsert_room` has actually inserted
  it — restated above in Research findings, no code change needed for this
  half. Add one line to `map.erb`'s intro paragraph making the invariant
  visible to whoever's reading the page ("nodes shown are rooms this world
  map has actually visited; dashed markers are known-but-unvisited exits"),
  so the distinction introduced below is self-explanatory in the UI itself.
- **New**: every visited room already stores its `exits` (a list of
  direction strings parsed by `RoomEcho.parse`, e.g. `["n", "e"]`) — a
  signal of what the player *saw listed* that may or may not have been
  followed yet. In `map_svg` (`app.rb`), after computing `positions` for
  all visited rooms: for each rendered room, for each of its `exits`,
  compute the neighbor coordinate using the same `DIRECTION_DELTA` table
  `assign_coordinate` (`world_map.rb`) already uses for real placement. If
  no room currently occupies that coordinate, render a small, visually
  distinct placeholder — dashed-outline circle, "?" glyph, direction shown
  in its `<title>` tooltip (e.g. "north of The Temple Square &middot; not
  yet visited") — instead of a full solid labeled box.
  - Purely a rendering-time synthesis: no `rooms` row is created, no
    `WorldMap` write happens, nothing is stored — if the plan's own
    "already true" guarantee (no phantom discovered nodes) is to keep
    holding, this must stay client-visible-only, computed fresh from
    `exits` + `DIRECTION_DELTA` on every render, same posture as the
    existing coordinate-collision fan-out fix (`resolve_node_overlaps!`)
    already takes toward "rendering layer only, storage untouched."
  - Dedupe: multiple rooms can list an exit toward the same unvisited
    coordinate (or the same room can be reached by different directions
    from different neighbors); collapse to one stub per unique target
    coordinate before rendering.
  - Skip drawing a stub if its computed coordinate collides with an
    already-placed real room — that's the pre-existing "two different
    explored paths compute the identical (x, y)" simplification
    (`world_map_visualization.md`'s "Implemented" section) showing up from
    the unvisited side; simplest correct behavior is just not drawing a
    stub on top of a real node, not attempting to disambiguate further.
  - Not clickable, no `/map/rooms/:title.json` lookup (nothing exists to
    look up yet) — `cursor: default`, no `<a href>` wrapper, unlike real
    room nodes.
  - **Scope: full accumulated map only** (`session_id` / `player` both
    `nil`). A session-scoped or player-scoped replay (§5) showing
    speculative unvisited neighbors would misrepresent "what this specific
    session/player actually saw" — those views stay exactly what was
    actually visited, matching `world_map_visualization.md`'s existing
    "Not doing: any layout algorithm change" posture of not overreaching
    beyond real data.

### 3. Search reactive to key-in

Progressive enhancement over the existing GET-param filter forms (kept as
the no-JS fallback — submitting the form still narrows results exactly as
today):

- **Rooms/Discoveries tables** (after §4 splits them onto their own pages):
  a debounced (~200ms) `input` listener on each filter's text field, using
  `fetch` to re-request the same route with updated query params and
  swapping only the results `<tbody>`/pagination-footer markup — the same
  "patch, don't reload" shape `/map/live.json`'s poller already
  established, generalized into one small `fetchAndSwap(url,
  targetSelector)` helper reused by both pages' scripts. This (not
  purely-client-side hide/show) is deliberate: `PAGE_SIZE = 50` pagination
  means a purely client-side filter over the currently-rendered rows would
  silently miss matches sitting on a later page — re-querying the server
  keeps search correct against pagination instead of just against
  whatever's currently on screen.
- **The map's own search** (`/map`): a separate small always-visible search
  box overlaid on `.map-scroll` (not tied to the Rooms-table form, which
  after §4 lives on a different page). Since every visited room is already
  fully present in the rendered SVG (`map_svg` draws the whole accumulated
  map, unpaginated), this one is genuinely client-side: matching room
  `<g class="map-node">` elements (matched by `data-room`, case-insensitive
  substring) get a `.map-node-match` highlight outline; non-matching nodes
  get `.map-node-dim` (reduced opacity, not `display:none` — keeps edges
  and overall map shape legible while searching rather than making the
  canvas jump around). Clearing the box removes both classes from every
  node.
- Both pieces ship in the same `_map_zoom.erb`-adjacent script area (or a
  second small shared partial, `views/_map_search.erb`, if the two don't
  naturally belong in one file) rather than duplicated per page.

### 4. Rooms and Discoveries get their own pages

- **`GET /map/rooms`** (new route, `app.rb`) → `views/rooms.erb` (new) —
  the Rooms table, `room_q` search (now reactive per §3), and its keyset
  pagination (`rooms_before`), lifted verbatim out of `map.erb`'s current
  "Rooms" `<div class="breakdown">` block. Handler computes exactly what
  today's `/map` computes for this table: `@rooms =
  @world_map.rooms_matching(q: @room_q, before: @rooms_before, limit:
  PAGE_SIZE)`, `@next_rooms_before`.
- **`GET /map/discoveries`** (new route) → `views/discoveries.erb` (new) —
  the Discoveries table, `q`/`kind`/`room`/`examined` filters (reactive per
  §3), pagination (`before`), lifted the same way. Handler keeps
  `@kinds = LogViz::ContentFact::KINDS + ["unknown"]` and `@room_titles =
  @world_map.rooms.map { |r| r[:title] }.sort` (today computed once inside
  `/map`, needed here for the filter dropdowns) — moved into this route,
  not duplicated into `/map`'s handler anymore.
- **`/map` itself shrinks** to: the live-sessions banner/table (unchanged),
  the map SVG with zoom (§1) and in-map search (§3), and two summary links
  ("N rooms discovered &rarr;", "N discoveries &rarr;") pointing at the two
  new pages instead of rendering the tables inline. `@rooms`/`@discoveries`
  and their filter params come out of the `/map` handler entirely — it no
  longer needs `PAGE_SIZE`-bounded queries at all, just the counts already
  available via `@world_map.rooms.length`/`edges.length` (already used in
  today's intro paragraph).
- **Nav**: `views/layout.erb`'s `<nav class="topnav">` gains `Rooms` and
  `Discoveries` links next to the existing `World Map`/`Players` — same
  flat top-level pattern already established, rather than nesting them
  under a `/map` dropdown (keeps every page reachable in one click, no new
  nav interaction pattern to build).
- `/map/rooms/:title.json` (the click-to-inspect endpoint) is unaffected —
  it's the *map's* feature, stays on `/map`.

### 5. Players page: isolated "Knowledge" (map/rooms/discoveries) + compact per-session path

- **`WorldMap#rooms_matching` and `#discoveries` gain an optional
  `room_titles:` allowlist param** (`world_map.rb`) — appends an `AND
  title IN (?,...)` / `AND rc.room_title IN (?,...)` clause to the existing
  `WHERE` builder when given a non-nil array, no-op (today's unfiltered
  behavior) when omitted. `/map/rooms` and `/map/discoveries` (§4) pass
  nothing; the new player-scoped routes below pass
  `@world_map.rooms_visited_by(name)` (existing accessor from
  `multiple_concurrent_players.md` §2/§3 — already the source of truth for
  "what has this player's own character actually seen").
- **`map_svg` gains a third scope, `player:`** (mutually exclusive with the
  existing `session_id:`, both default `nil` for the full map): rooms
  restricted to `world_map.rooms_visited_by(player)`; edges drawn from the
  existing global `edges` table filtered to pairs where both endpoints are
  in that set. This is a deliberate approximation, called out explicitly:
  unlike a `session_id:`-scoped map (which draws that one session's *real,
  ordered* transitions), a player aggregated across possibly many sessions
  has no single ordered path — the global-edges-between-visited-rooms
  rendering answers "what does this player's own explored subgraph look
  like," not "what order did they see it in" (that finer-grained replay
  already exists per-session on `/sessions/:id`). No live-session markers,
  no seq badges (same posture the session-scoped map already takes for
  markers; seq badges stay session-only since "visit order" is only
  well-defined for one session).
- **`GET /players/:name/rooms`**, **`GET /players/:name/discoveries`** (new
  routes) → reuse `views/rooms.erb`/`views/discoveries.erb` from §4 with an
  extra `@scope_player = name` local (adds a "scoped to <player>" note in
  the header and threads `name` through pagination/filter links) rather
  than forking two more templates — same tables, same filter/search/
  pagination behavior, just pre-scoped.
- **`GET /players/:name`** (existing route, `player.erb`) gains a
  "Knowledge" section: the zoomable/searchable map (§1/§3 reused, scoped
  via `map_svg(@world_map, player: name)`) plus links to the two routes
  above — mirroring `/map`'s own map-plus-links-out layout, one level under
  `/players/:name`.
- **Compact per-session path glyph** (the "speed up progression... can
  just display room as node, no room name" ask) — new helper
  `session_path_glyph(visits, width: 160, height: 28)` in `app.rb`'s
  `helpers` block, same family as the existing `sparkline`/
  `request_sparkline`/`composition_sparkline` inline-SVG helpers (not a
  scaled-down `map_svg` — no boxes, no labels, no pan/zoom, just small dots
  in visit order connected by a line, so it stays glanceable at list-row
  size). Added as a new column in `/players/:name`'s Sessions table
  (`player.erb`), fed by `@world_map.visits_for(s[:session_id])` computed
  once per row in the `/players/:name` handler (cheap indexed queries,
  same `visits_for` method the full time-lapse panel already uses) —
  clicking the glyph (or the row, as today) still goes to `/sessions/:id`
  for the full interactive time-lapse; this is a preview, not a
  replacement for it.

### 6. Sinatra vs. an alternative stack

Answered above under "Answer: is Sinatra capable" — no separate
implementation work, this section exists so the question posed in the Goal
has a visible, findable answer in the plan itself.

### 7. Drag-to-pan on every map instance (not just the World Map)

Click-and-drag panning already exists (`world_map_visualization.md` §2),
but only inside `map.erb`'s own inline script — a monolithic block that
also owns the live-session poller and click-to-inspect, neither of which
the session time-lapse panel or the player Knowledge map (§5) need. When
zoom (§1) was generalized into a shared `_map_zoom.erb` partial reused
across all three map instances, drag-to-pan wasn't: it stayed
map.erb-only, so `/sessions/:id`'s time-lapse map and `/players/:name`'s
Knowledge map ended up with zoom + native scroll but no drag — an
inconsistent set of controls depending on which page you're on.

- Extract drag-to-pan out of `map.erb`'s script into its own shared
  partial, `views/_map_drag.erb` — same discovery pattern as
  `_map_zoom.erb`/`_map_search.erb`: finds every `.map-zoom-root` on the
  page and wires its scrollable child (`.map-scroll` or `.time-lapse-map`)
  for click-and-drag panning, layered on top of native `overflow: auto`
  scrolling exactly as before, never a replacement for it. Rendered
  alongside `_map_zoom.erb` into `map.erb`, `session.erb`'s time-lapse
  panel, and the player Knowledge map — one script instead of copy-pasting
  the drag logic a third time.
- Drag-vs-click disambiguation moves with it: `_map_drag.erb`'s `<script>`
  tag renders before `map.erb`'s own (which still owns click-to-inspect),
  so its `click` listener registers on the shared scrollable element
  first and swallows (`stopImmediatePropagation`) the click that follows a
  real drag — `map.erb`'s click-to-inspect handler no longer needs its own
  `dragState` bookkeeping to tell a drag-release from a genuine click;
  that disambiguation now lives in exactly one place.
- CSS: the `.dragging` cursor rule (today scoped to `.map-scroll` only)
  extends to `.time-lapse-map` too, and `.time-lapse-map` gains
  `cursor: grab` to match `.map-scroll`'s existing affordance — today it
  had zoom controls but no visual hint that dragging works there too.
- **Addendum, found once this shipped**: extracting the script wasn't
  enough on its own. Neither `.map-scroll` nor `.time-lapse-map` has ever
  had a height cap (a pre-existing gap from `world_map_visualization.md`
  §2, not introduced here) — without one, the box just grows to fit its
  SVG and the *page* scrolls instead, so there was never any vertical
  overflow to drag. The World Map usually overflows horizontally anyway
  (enough rooms spread wide enough), which is what made drag look like it
  worked there; the player Knowledge map (§5), scoped to one player's
  usually-smaller room set, routinely fits its container in *both*
  directions and so had nothing to pan — not a broken listener, a
  container with zero overflow to begin with. Fixed by giving both
  `.map-scroll` and `.time-lapse-map` a `max-height: 36rem` — every map
  instance now gets a real bounded viewport, and zooming in (§1) on a
  small map creates genuine overflow to drag-pan through instead of
  silently doing nothing.
- **Second addendum**: the height fix above wasn't the whole story either.
  Every room box is wrapped in an `<a class="map-node-link">` (`app.rb#
  map_svg`), and browsers make links (including inside SVG) natively
  draggable by default — a mousedown-and-move that *starts on a room node*
  hands the gesture to the browser's own drag-and-drop (a ghost-image drag
  of the link) before our mousemove-based panning ever sees clean deltas,
  so `scrollLeft`/`scrollTop` never move. This is easy to miss on the
  World Map, which usually has plenty of empty canvas to grab; it's the
  common case on the player Knowledge map, whose smaller, denser room set
  makes starting a drag squarely on a node far more likely than finding
  empty space. Fixed in `_map_drag.erb` with one `dragstart` listener
  (`e.preventDefault()`) on the shared scrollable element — real link
  clicks (navigation, or the click-to-inspect override) are unaffected,
  since a click isn't a drag.

---

## Files touched

- `week2_observability/log_viz/lib/log_viz/app.rb` — `map_svg` gains
  `player:` scope + unexplored-neighbor stub rendering (§2); new routes
  `GET /map/rooms`, `GET /map/discoveries`, `GET /players/:name/rooms`,
  `GET /players/:name/discoveries`; `/map` handler shrinks (§4); `/players/
  :name` handler adds per-session `visits_for` lookups (§5); new
  `session_path_glyph` helper (§5).
- `week2_observability/log_viz/lib/log_viz/world_map.rb` — `rooms_matching`/
  `discoveries` gain optional `room_titles:` allowlist param (§5).
- `week2_observability/log_viz/views/map.erb` — trimmed to live banner +
  map + in-map search/zoom/drag + links out to Rooms/Discoveries;
  unexplored-stub legend note (§2); drag-to-pan extracted out into
  `_map_drag.erb` (§7), click-to-inspect simplified to no longer track its
  own drag state.
- `week2_observability/log_viz/views/rooms.erb` (new), `discoveries.erb`
  (new) — lifted tables from today's `map.erb`, reused (with
  `@scope_player`) for the player-scoped routes (§4/§5).
- `week2_observability/log_viz/views/player.erb` — Knowledge section (map +
  links), Sessions table gains the path-glyph column (§5); map wrapper
  gains drag-to-pan via `_map_drag.erb` (§7).
- `week2_observability/log_viz/views/session.erb` — time-lapse map gains
  zoom (§1) and drag-to-pan via `_map_drag.erb` (§7).
- `week2_observability/log_viz/views/layout.erb` — `Rooms`/`Discoveries`
  nav links (§4).
- `week2_observability/log_viz/views/_map_zoom.erb` (new, shared partial) —
  zoom controls markup + script, rendered into `map.erb`, `session.erb`,
  and the player Knowledge map (§1).
- `week2_observability/log_viz/views/_map_search.erb` (new, shared partial,
  may be merged into `_map_zoom.erb` if they naturally fit one file) —
  in-map search box markup + script (§3).
- `week2_observability/log_viz/views/_map_drag.erb` (new, shared partial) —
  drag-to-pan script, extracted out of `map.erb` and rendered into all
  three map instances instead (§7).
- `week2_observability/log_viz/public/style.css` — `.map-node-unexplored`
  (§2), `.map-zoom-controls` (§1), `.map-node-match`/`.map-node-dim` (§3),
  session-path-glyph styling (§5), `.time-lapse-map` gains `cursor: grab`/
  `.dragging` styling to match `.map-scroll` (§7), both gain
  `max-height: 36rem` (§7 addendum) so there's always real overflow to
  drag-pan through.
- `week2_observability/log_viz/test/test_world_map.rb` — `room_titles:`
  filter tests for `rooms_matching`/`discoveries` (§5).
- `week2_observability/log_viz/test/test_app.rb` — new routes
  (`/map/rooms`, `/map/discoveries`, `/players/:name/rooms`, `/players/
  :name/discoveries`), `map_svg`'s `player:` scope and unexplored-stub
  rendering.

## Known tradeoffs / risks

- **Player-scoped map edges are an approximation, not a real path** —
  global edges between a player's visited-room set, not that player's
  actual ordered traversal (which only a single `session_id:`-scoped map
  can represent exactly). Stated explicitly in §5 rather than implied.
- **Zoom via CSS `transform: scale()` doesn't change hit-testing costs**,
  but zooming out shrinks click targets — mitigated by clamping the
  minimum zoom level so room boxes stay reasonably clickable even at the
  lowest allowed zoom.
- **Unexplored stubs inherit `DIRECTION_DELTA`'s existing simplification**
  (real compass deltas, not a collision-free layout) — a stub can be
  skipped (not drawn) when its computed coordinate happens to coincide
  with an already-placed real room, rather than attempting further
  disambiguation; stated as a known gap, not silently hidden.
- **More vanilla-JS surface area** — zoom (§1) and live search (§3) both
  extend this project's one previously-accepted, narrowly-scoped JS
  departure (`room_world_inspector.md` §5) across three pages instead of
  one. Still no framework/build step, but a meaningfully larger amount of
  hand-written JS to keep consistent than before.
- **Splitting Rooms/Discoveries onto their own pages (§4) means the
  in-map search (§3) and the Rooms-table search (§3, after the split) are
  two separate, non-synced search boxes** — searching the map doesn't
  filter the Rooms page and vice versa, since they're different pages by
  design now. Worth flagging as a possible follow-up (a shared "jump to
  room" search in the top nav) if it turns out to be wanted, not designed
  in speculatively here.

## Open questions

1. Is "Knowledge" the right label for the new player-scoped section
   (nav text, route naming under `/players/:name/...`), or is there a
   preferred term?
   A: Please recommend a suitable term
2. Should the map's in-map search (§3) and the standalone Rooms page's
   search (§4) be unified into one shared search experience (e.g. a
   top-nav-level "jump to room" box that works from any page) now, or is
   keeping them page-scoped or fine for this pass, with unification only
   if it's actually missed in practice?
   A: keep them page-scopred is fine for now