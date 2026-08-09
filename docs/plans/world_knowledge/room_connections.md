### Goal

In `log_viz` the Rooms table shows a room's exits (e.g. `n e s w`), but not
where each one goes. The `edges` table in `world_map.sqlite3` already
records `(from_title, via, to_title)` triples, but that data is only ever
used to draw lines on the `/map` SVG graph — it's never surfaced as text in
the Rooms table, and `room_knowledge` (the agent-facing tool) exposes
nothing about connectivity at all. If directions/the map are important
knowledge for Agents (see `architecture_and_python_port.md` and the bakery
investigation that prompted this), room connections need to be logged
*and* exposed, not just logged. This is a planning doc — not started, see
`docs/plans/observability/room_world_inspector.md` for the format this
follows.

## Current state (what already exists)

- `rooms.exits` (`world_map.rb` `SCHEMA`): the raw direction tokens from
  the MUD's own `[ Exits: n e s w ]` line — labels only, no resolution.
- `edges (from_title, via, to_title)`, PK `(from_title, via)`: populated by
  `WorldMap#record_visit` every time a location-tool result resolves to a
  new room and the player's previous room is known. `via` is the compass
  direction for a `move`, or the bare tool name (`enter`/`leave`/`flee`/
  `look`) for a direction-less arrival. This *is* "room connections" — it's
  already being logged today, just not read back anywhere useful.
- `WorldMap#edges` (public reader) is consumed exactly once, by
  `app.rb#map_svg`, to draw `<line>` elements between two rooms' precomputed
  coordinates. The header line "`N known connections`" (`map.erb:6`) is the
  only place a human sees a number derived from it. `room_knowledge`
  (`13_room_inspector/lib/boukensha/world_knowledge.rb`) queries
  `content_facts`/`examinations` only — it has zero knowledge of `edges`.

Checked against the live `world_map.sqlite3` (45 rooms): only **65 of 108**
listed room-exit letters have a matching `edges` row. Most of the map's
"known" exits currently point nowhere as far as any reader of this data can
tell — they're indistinguishable from an exit that's never been checked.
That gap — "this room has a `north` exit" vs. "we know `north` leads to
Temple Square" — is exactly what this plan needs to make visible.

## Plan

### 1. `WorldMap#connections_for(room_title)` — merge exits ∪ edges

New read accessor in `log_viz/lib/log_viz/world_map.rb`, alongside
`unexamined_in`/`examined_in`:

```
connections_for(room_title) ->
  [{ direction: "north", to: "Temple Square" }, { direction: "east", to: nil }, ...]
```

- Left-joins `rooms.exits` (parsed JSON) against `edges` rows where
  `from_title = room_title`, mapping single-letter tokens (`n`/`s`/`e`/`w`/
  `u`/`d`) to full direction names the same way `DIRECTION_DELTA` already
  does, so both sides compare on the same vocabulary.
  Every letter in `rooms.exits` gets exactly one output row; `to: nil`
  means "listed as an exit, never traversed" — a first-class, visible
  state, not an absence.
  - Also worth logging in this doc as a known nuance and *not* immediately
    fixing: `edges` is keyed by `(from_title, via)`, so a real captured
    example in the live DB has both `("Market Square", "south", "The
    Common Square")` and `("Market Square", "look", "The Common Square")`
    — the same connection recorded twice under different `via` labels
    (likely a bare `look` issued right after a `move`, or the rare
    tool_call/tool_result mispairing `WorldMap#pop_pending_call` already
    documents as a known imprecision). `connections_for` should probably
    aggregate by `to_title` and *report* which `via` values were seen for
    a direction, rather than assume one `via` per direction — needs a
    decision at implementation time, not resolved here.
- Directions never mentioned in `rooms.exits` but present as an `edges` row
  anyway (arrivals via `enter`/`leave`/`flee` — no compass letter to match)
  should still be included, tagged with their raw `via` string instead of
  a direction name (e.g. `{ direction: "flee", to: "The Dump" }`), since
  they're real, useful connectivity info even though CircleMUD's exits line
  never listed them.
- No reverse-edge inference: `to` stays `nil` for a direction just because
  the *destination's* exits happen to lead back — CircleMUD exits aren't
  guaranteed symmetric, so this only ever reports directions actually
  walked *from* `room_title` itself. State this as a known limitation, not
  something to silently paper over.

### 2. Rooms table — resolve exits instead of listing raw letters

`log_viz/views/map.erb`'s Rooms table (`Exits` column, ~line 151/160) and
`app.rb`'s `@rooms` assembly: replace the bare `r[:exits].join(" ")` with
the `connections_for` result, rendered as e.g. `n → Temple Square · e
(unexplored)`. Each resolved destination becomes a link/filter into the
Rooms table scoped to that room (`?room_q=<title>`), same interaction
pattern the rest of `/map` already uses. Unexplored directions get a
distinct visual treatment (muted, no link) so "known but never walked" is
scannable at a glance across the whole table — this is the human-facing
version of the same gap that made "bakery" invisible: an exit nobody's
resolved yet is easy to miss today.

### 3. Expose connections to the `room_knowledge` agent tool

`13_room_inspector/lib/boukensha/world_knowledge.rb`: add a `connections`
field to `room_knowledge`'s return shape —

```
room_knowledge(room_title:) ->
  { room_title:, examined: [...], unexamined: [...], connections: [{direction:, to:}, ...] }
```

— duplicating the merge query the same way `EXAMINED_EXISTS_SQL` is already
duplicated between `log_viz` and `boukensha` (documented coupling, same
file-header caveat). This is the actually load-bearing half of this plan:
today the agent's only knowledge of exits is whatever raw `[ Exits: ... ]`
line is sitting in its own context from the last `look`/`move` — it has no
way to ask "have I (or a past session) already learned where any of these
exits lead?" without literally walking there again. A room with a `to:`
already resolved means the agent can decide to head that way with a known
destination in mind instead of guessing.

### 4. (Not scoped yet, flagged as the natural follow-on) Pathfinding

The concrete problem that motivated this investigation — the agent being
asked to find the bakery and failing, repeatedly, across independent
sessions — isn't actually fixed by §1–§3 alone. Those make "what's through
this specific exit" queryable; they don't answer "how do I get from where I
am to the bakery" unless the agent already happens to be standing next to
it. Once `edges` is a queryable connectivity graph, BFS shortest-path
between any two known room titles is comparatively small (`edges` as an
adjacency list, unweighted hop-count BFS, same "read-only over
`world_map.sqlite3`" posture as everything else here) — a
`route_to(from:, to:)`-shaped addition to `room_knowledge`, or a sibling
tool, returning a direction sequence for any two rooms *both already
present in the accumulated map from any past session*. This is explicitly
a separate, bigger design question (does it search by room title only, or
also by a `content_facts.subject`/room-description mention like "the
bakery is to the north" so it can route toward a place never actually
entered yet? see the mention-extraction gap noted in the bakery
investigation) — not designed further here. Revisit as its own plan once
§1–§3 are shipped and it's clear whether per-room connection lookups alone
change agent behavior, the same "ship the smaller thing, let real usage
show whether more is needed" posture `room_world_inspector.md` §3 already
used for `room_knowledge` itself.

## Known tradeoffs / risks

- `edges` has no `first_seen_at`/timestamp column, unlike every other table
  in the schema — fine for §1–§3 (connectivity doesn't need recency), but
  worth adding if a future feature ever wants "connections learned this
  session" or similar. Not required for this plan.
- Same `(from_title, via)`-not-`(from_title, to_title)` duplication noted
  in §1 means a naive "count of known connections" can overcount real
  distinct paths; `connections_for` needs to decide how to collapse that,
  not just pass raw edge rows through.
- No reverse-edge inference (§1) means the map's "known" connectivity is
  strictly smaller than the MUD's actual (likely mostly-symmetric)
  topology — a direction that's only ever been *arrived from*, never
  *departed through*, stays unresolved in the departing room's row even
  though a human would guess the reverse trivially. Stated limitation, not
  silently hidden.
- §4 (pathfinding) is explicitly out of scope for the first pass and is
  the piece most directly tied to the original "agent can't find the
  bakery" complaint — don't treat §1–§3 landing as having solved that
  problem; it only makes the underlying data legible, not query-able for
  routes yet.

## Files touched (§1–§3, when implemented)

- `week2_observability/log_viz/lib/log_viz/world_map.rb` — new
  `connections_for(room_title)` accessor, direction-letter/name mapping
  reused from `DIRECTION_DELTA`'s vocabulary.
- `week2_observability/log_viz/lib/log_viz/app.rb` — `/map`'s `@rooms`
  assembly gains resolved connections per row.
- `week2_observability/log_viz/views/map.erb` — Rooms table `Exits` column
  becomes resolved destinations + unexplored markers; possible per-room
  filter link.
- `week2_observability/log_viz/public/style.css` — styling for
  resolved-vs-unexplored exit markers.
- `week2_observability/log_viz/test/test_world_map.rb` — `connections_for`
  fixtures: a direction with a resolved edge, a listed-but-untraveled
  exit, an `enter`/`flee`-only arrival with no exits-line letter, the
  duplicate-`via` case observed live (`south` vs. stray `look`).
- `week2_observability/ruby/13_room_inspector/lib/boukensha/world_knowledge.rb`
  — `connections` field on `room_knowledge`'s return shape; duplicated
  query logic, same coupling caveat as `EXAMINED_EXISTS_SQL`.
- `week2_observability/ruby/13_room_inspector/test/test_world_knowledge.rb`
  — matching fixtures for the new field.
- This file — update with an "Implemented" section (per
  `room_world_inspector.md`'s convention) once §1–§3 ship, and revisit §4
  as its own plan.

## Not doing (this pass)

- Pathfinding/route suggestions (§4) — flagged above as the natural next
  step, not designed in detail here.
- Reverse-edge inference or any assumption that MUD exits are symmetric.
- Rendering a live "you are here, go this way" hint automatically into the
  agent's context — matches `room_world_inspector.md`'s existing stance
  that `room_knowledge` (and anything added to it) stays a tool the agent
  chooses to call, never an automatic injection.

## Implemented, see `world_knowledge.md`

§1–§3 shipped as part of
[`world_knowledge.md`](world_knowledge.md), which superseded this doc
rather than being a separate follow-on pass:

- **§1** (`connections_for`) — `LogViz::WorldMap#connections_for`,
  `week3_capable/log_viz/lib/log_viz/world_map.rb`. The "aggregate by
  `to_title` vs. raw `edges` row" open question is resolved: grouped by
  resolved direction (`#direction_key_for_via`), collecting the distinct
  `via` strings seen into an array. This does *not* collapse the specific
  `("Market Square", "south", ...)` / `("Market Square", "look", ...)`
  duplicate this doc flagged — see `world_map.rb`'s `#connections_for`
  comment and `test_world_map.rb`'s
  `test_connections_for_does_not_collapse_a_mispaired_look_duplicate` for
  why, and what merge case the grouping *does* handle instead.
- **§2** (Rooms table resolved-exits rendering) — **not implemented**.
  Carried forward as `world_knowledge.md` §7 ("bundled, cheap reuse —
  optional, do last"), explicitly not a prerequisite for the MCP tool and
  not done in this pass.
- **§3** (`room_knowledge`'s `connections` field) —
  `LogViz::WorldMap#room_knowledge`, same file — ported from the former
  `Boukensha::WorldKnowledge#room_knowledge`
  (`week3_capable/ruby/19_knowledge`, deleted) directly onto `WorldMap`,
  collapsing the `EXAMINED_EXISTS_SQL`/`EXAMINATION_RESULT_SQL`
  duplication this doc's §3 called out, rather than moving it sideways.
  Also newly exposed over MCP (`log_viz --mcp`, `world__room_knowledge`)
  instead of staying a boukensha-local `RunDSL#tool` registration — see
  `world_knowledge.md`'s own evaluation section for why.
- **§4** (pathfinding) — un-deferred, designed and shipped as
  `LogViz::WorldMap#route_to` / the `world__route_to` MCP tool. See
  `world_knowledge.md` §2 for the design (unweighted BFS, player-scoped by
  default, no reverse-edge inference — same limitation as §1 above) and
  its "Not doing" section for what's still out of scope (mention-based
  routing toward a never-entered room, weighted/cost-aware pathfinding).
