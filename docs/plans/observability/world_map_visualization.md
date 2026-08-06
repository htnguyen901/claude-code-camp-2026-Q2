### Goal

The World Map (`/map`'s `map_svg` helper in `app.rb`) is now hard to read as
the accumulated map has grown:

1. Rooms render as a small dot plus an adjacent text label
   (`.map-node-dot` + `.map-node-label` in `map_svg`). As rooms fill in,
   labels sit close enough together to overlap, and the room name is only
   fully knowable by hovering the node's `<title>` tooltip — not something
   that scales past a handful of rooms.
2. The map isn't actually scrollable. `.map-scroll { overflow: auto }`
   wraps the `<svg>`, but the `<svg>` itself has no explicit pixel
   `width`/`height` — only a `viewBox` plus `.map-svg { min-width: 100% }`
   in CSS. With no intrinsic size, the browser stretches the SVG to the
   container's width and scales the `viewBox` down to fit, so a bigger map
   doesn't overflow and scroll — it just zooms out and gets denser, which
   is the opposite of what's wanted.

Fix both: give each room a labeled box that can't overlap its neighbors by
construction, and give the map a real, growable canvas that scrolls (and
can be dragged) instead of shrinking to fit. Layer in click-to-inspect on
top, since a hover-only tooltip is exactly the "always have to hover"
complaint.

---

## Plan: box nodes, real scrolling, click-to-inspect

### 1. Room nodes: dot+label → labeled box (fixes overlap)

In `LogViz::App#map_svg` (`app.rb`), replace each room's
`<circle class="map-node-dot"/>` + adjacent `<text>` with a single
fixed-size rounded `<rect>` with the room title centered inside it:

```
<g class="map-node" transform="translate(x, y)">
  <rect class="map-node-box" x="-65" y="-18" width="130" height="36" rx="6"/>
  <text class="map-node-label" x="0" y="4" text-anchor="middle">#{truncate(title, 20)}</text>
  <title>#{full title} · visited N×</title>
</g>
```

- **Fixed box size (130×36), not text-measured.** SVG text can't be
  server-side measured in Ruby without a browser, so instead of trying to
  size the box to the string (fragile, and the actual overlap-prevention
  mechanism anyway), the box is a constant size and the label is
  `truncate`d to fit it — reusing the same `truncate` helper already used
  for the discoveries "Findings" column, not a new formatting concept.
  Overlap is prevented by construction: **fixed box size + grid spacing
  wider than the box** (see below), not by measuring anything.
- **`cell` (grid spacing) increases from 90 to 160**, and `margin` from 70
  to 90 — enough gap between adjacent grid slots (rooms are placed one
  compass-step apart, `DIRECTION_DELTA` in `world_map.rb`) that two
  side-by-side 130px-wide boxes never touch. This is the actual fix for
  "names are overlapping each other" — today's 90px `cell` is narrower
  than most room-name labels already are.
  - `up`/`down` rooms are nudged diagonally by a *fraction* of a cell
    (`DIRECTION_DELTA`'s `[0.4, -0.4]`) specifically so they land in a free
    slot next to, not on top of, their parent — that math is unaffected by
    changing `cell`'s pixel value, it's still a fraction of one grid step.
- The full (untruncated) title stays in the `<title>` tooltip (hover, as
  today) **and** becomes the headline of the new click panel (§3) — so the
  truncated label is never the *only* place the full name is visible,
  addressing "I always have to hover to read [the name]."
- Live-session pulse markers (`.map-live-marker`) keep their current
  behavior — a ring centered on the room's `(x, y)`, now visually centered
  on the box instead of the old dot. No positioning-math change needed,
  since `(x, y)` is still the node's single reference point.

### 2. A real scrollable (and draggable) canvas (fixes "not scrollable")

- Give the generated `<svg>` explicit pixel `width="#{svg_w}"
  height="#{svg_h}"` attributes (`svg_w`/`svg_h` are already computed in
  `map_svg` from the room coordinate bounding box) instead of relying on
  `viewBox` + CSS to imply a size. An explicit intrinsic size stops the
  browser from treating the SVG as infinitely shrinkable to fit its
  container — once the content is wider/taller than `.map-scroll`, the
  existing `overflow: auto` on that wrapper starts producing real
  scrollbars instead of squeezing the `viewBox`.
- Drop `.map-svg { min-width: 100% }` from `style.css` — it's precisely
  the rule fighting the fix above (forces the element to stretch to fill
  the container regardless of its own intrinsic size). Keep
  `display: block` (avoids the few-px inline-baseline gap under the SVG).
- **Click-and-drag panning**, layered on top of native scrolling (not a
  replacement for it — native scrollbars/trackpad/keyboard scrolling all
  keep working as the no-JS-needed baseline): a small addition to the
  existing `<script>` block in `map.erb` (the same file that already runs
  the live-update poller — this project's one deliberate, narrow, already-
  documented departure from its plain-ERB/no-JS house style, see
  `room_world_inspector.md` §5). `mousedown` on `.map-scroll` starts a
  drag that adjusts `scrollLeft`/`scrollTop` on `mousemove`, `mouseup`/
  `mouseleave` ends it; `cursor: grab` / `:active { cursor: grabbing }` on
  `.map-scroll` signals it's draggable. No new dependency, no canvas
  reflow — it's just programmatic scrolling of the same scrollable element
  the browser already gives us from §2's fix.
- **Not doing (this pass): zoom controls.** Panning solves "I can't get to
  the parts of the map that are offscreen"; zoom solves a different
  problem ("show me more at once, smaller") that the box-node redesign in
  §1 already mitigates by making labels legible without needing to zoom in
  per-room. Worth revisiting only if the accumulated map gets large enough
  that even panning a wide canvas becomes tedious — call it out explicitly
  rather than build it speculatively now.

### 3. Click a room → see its discoveries and exits (fixes "always have to hover")

- New read-only JSON endpoint, `GET /map/rooms/:title.json`, in `app.rb`.
  It calls into `WorldMap` accessors that **already exist** (built for
  `room_world_inspector.md` §2–§4 — no new `WorldMap` methods needed):
  - `world_map.rooms.find { |r| r[:title] == title }` for description,
    exits, visit_count, first_seen.
  - `world_map.discoveries(room: title, limit: nil)` for the room's
    noticed items/mobs/NPCs, each with its `kind`, `examined` flag, and
    `examination_result` — the exact same fields the page's Discoveries
    table already renders, just pre-filtered to one room.
  - Returns 404 (`content_type :json`, an error body) for an unknown
    title, matching the existing `/sessions/:id` 404 convention.
- Every room `<g class="map-node">` is wrapped in an SVG
  `<a href="/map?room=<title>&room_q=<title>">` (URL-encoded) pointing at
  the **existing** `?room=` discoveries filter and `?room_q=` rooms
  filter from `room_world_inspector.md` §4. This is the no-JS baseline:
  clicking a room, JS or not, always does *something* useful (jumps to a
  full-page reload with both tables pre-filtered to that room) —
  `cursor: pointer` added to `.map-node` in CSS as the visual affordance.
- With JS available, the existing `<script>` block in `map.erb` adds a
  delegated `click` listener on the map SVG: on a `.map-node` click,
  `preventDefault()` the navigation, `fetch` `/map/rooms/:title.json`
  instead, and render the result into a new always-in-the-DOM (initially
  `hidden`) side panel, `#room-detail-panel`, positioned next to
  `.map-scroll`: room title, description, exits, visit count/first-seen,
  and a compact discoveries list (subject, kind badge, examined badge,
  finding text — reusing the same badge CSS classes `.kind-badge`/
  `.examined-badge` already defined for the Discoveries table, not new
  ones) with a close button. This is strictly an enhancement: if `fetch`
  fails or JS is off, the `<a>` navigation above already happened/still
  happens instead.
- A drag-to-pan gesture (§2) and a click both start with `mousedown` — the
  click handler only fires the panel fetch on a `mouseup` that lands
  within a small pixel threshold of the matching `mousedown` (a "was this
  a click or a drag" check), so panning the map never accidentally pops
  the detail panel open on every drag release.

### Files touched

- `week2_observability/log_viz/lib/log_viz/app.rb` — `map_svg`: box nodes
  instead of dot+label, explicit `width`/`height` on the generated `<svg>`,
  wider `cell`/`margin` defaults, `<a>`-wrapped nodes. New
  `GET /map/rooms/:title.json` route.
- `week2_observability/log_viz/views/map.erb` — `#room-detail-panel`
  markup (hidden by default), extends the existing `<script>` block with
  the click-to-fetch-panel handler and the drag-to-pan handler.
- `week2_observability/log_viz/public/style.css` — `.map-node-box`
  (replaces `.map-node-dot`), updated `.map-node-label` (centered, fixed
  box), drop `.map-svg { min-width: 100% }`, `.map-scroll { cursor: grab }`
  / `:active { cursor: grabbing }`, `#room-detail-panel` layout/badges.
- `week2_observability/log_viz/test/test_app.rb` — new (this file doesn't
  exist yet; today `map_svg`/routes have no direct test coverage). Cover
  `GET /map/rooms/:title.json` for a known room (shape + discoveries
  content) and an unknown title (404), using Sinatra's `Rack::Test` the
  same way other Sinatra apps in this style are typically tested — pick
  whatever test harness the rest of `log_viz/test/` already standardizes
  on if one materializes before this ships (currently all existing tests
  under `log_viz/test/` exercise `WorldMap`/`ContentFact`/`RoomEcho`
  directly, not the Sinatra routes, so this is new ground for the test
  suite either way).

### Known tradeoffs / risks

- Truncating room titles to fit a fixed-width box (§1) means a handful of
  very long titles won't be fully readable on the map itself — mitigated
  by the full title always being in the `<title>` hover tooltip and the
  click panel's headline (§3), never *only* available by squinting at a
  truncated label.
- Drag-to-pan and click-to-inspect (§2, §3) are both JS, extending this
  project's one already-accepted, narrow JS departure
  (`room_world_inspector.md` §5's live-update poller) rather than adding a
  second one — but it is more JS surface area than today. Both degrade to
  a working non-JS baseline (native scroll/keyboard panning; full-page
  `?room=` navigation) by design, not as an afterthought.
- Wider `cell`/`margin` spacing (§1) makes the overall map canvas larger
  for the same room count, which is exactly what makes native scrolling
  (§2) load-bearing rather than optional — shipping §1 without §2 would
  make the "can't reach the edges" complaint worse, not better.

## Implemented (deviations from the original design, as shipped)

- **§1/§2/§3 shipped as designed** — fixed 130×36 rounded-rect boxes with
  centered/truncated labels, `cell` 90→160 / `margin` 70→90, explicit
  `width`/`height` on the generated `<svg>`, drag-to-pan layered on native
  scrolling, `<a href="/map?room=...">`-wrapped nodes with a JS-enhanced
  `/map/rooms/:title.json` click panel. All in `app.rb`'s `map_svg` +
  new route, `map.erb`'s script, `style.css`.
- **New, not in the original plan: rendering-layer overlap resolution for
  coordinate collisions.** Verified against the real accumulated
  `world_map.sqlite3` (45 rooms) before shipping — 5 groups of rooms
  (11 rooms total) share an *identical* `(x, y)`, because
  `WorldMap#assign_coordinate` places rooms from real compass deltas with
  no collision-free layout guarantee (a pre-existing, documented
  simplification, not introduced by this plan). Left alone this renders as
  fully overlapping, unclickable boxes — confirmed directly: a headless
  Chromium click at "The Temple Square" was intercepted by "The Temple Of
  Midgaard"'s identically-positioned box on top of it. Fixed at the
  rendering layer only (`assign_coordinate` untouched, per "Not doing"
  below):
  - `map_svg` fans out same-coordinate rooms **vertically** in a small
    stack (`MAP_CLUSTER_FAN_GAP` = box height + 8px). A first version used
    a *horizontal* fan wide enough for 3-way clusters and made things
    worse (9 → 11 overlaps) — the fan gap needed to separate siblings ate
    most of the ~30px of horizontal slack to the next grid column and
    collided with whatever unrelated room already lived there. Vertical
    has ~124px of headroom to the next row, comfortably clear.
  - `resolve_node_overlaps!` (new, private) — a bounded (6 passes),
    deterministic minimum-translation separation pass over every room
    pair, as a safety net for any residual/secondary collision (a fanned
    cluster member landing near an unrelated neighbor, etc.). Confirmed
    against real data: 0 overlaps across all 45 rooms after this pass,
    down from 9 before any fix and 11 with the first (horizontal) attempt.
  - Canvas `width`/`height` are now derived from the actual post-fan-out
    `positions`, not re-derived from grid math, since the fan-out
    deliberately perturbs some rooms off their nominal cell.
- Verified end-to-end with a real headless-Chromium session (Playwright,
  via Docker since this WSL host has no passwordless sudo for
  `playwright install --with-deps`) against the live server and real
  session data: 0 box overlaps, `.map-scroll`'s `scrollWidth` genuinely
  exceeds `clientWidth` (real scrollbars, not a squeezed `viewBox`),
  drag-to-pan moves `scrollLeft`/`scrollTop` by exactly the drag delta,
  and clicking a room opens the detail panel with real description/exits/
  discoveries data without a page navigation (URL unchanged) or console
  errors.

### Not doing (out of scope for this pass)

- Zoom controls (see §2's "Not doing" note) — revisit only if panning a
  wide canvas proves insufficient once this ships.
- Any layout algorithm change (force-directed, auto-fit, etc.) — room
  coordinates stay exactly as `WorldMap#assign_coordinate` already
  computes them (real compass directions → real 2D deltas, documented in
  `world_map.rb`); this plan only changes how those coordinates are
  *rendered*, not how they're chosen.
- A minimap/overview inset for orienting after panning — worth
  considering if drag-to-pan on a large map turns out to be disorienting
  in practice, not designed in speculatively now.
