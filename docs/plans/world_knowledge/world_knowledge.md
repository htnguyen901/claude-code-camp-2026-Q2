## Goal

I need to implement a tool that interact with Player's discovered world map/ world knowledge and provide Agent with knowledge to make decision about their plan, navigation, path finding, etc:

- The tool can only read the area that the Player have been to/have discovered in its journey
- The tool needs to be aware of directions in the map. For example:
    - Exits of each discovered room
    - Path to get to certain room from current position
- The tool should not read all world/map data since the world is huge and that is too much data to read
- The tool should summarize and determine the most useful information regarding the purpose of the agent calling the tool
- The agent calling the tool could break the request down into smaller sub-goal/sub-request so the tool should serve smaller scope too. For Example:
    - The shortest path to Room A
    - Items located in Room B
    - Examined Items in Room C and each item's examination findings
    - Possible undiscovered area in Room D (assuming world map is already tracking/logging this)
- The tool should live in an MCP server so that it could be called by Agent built in Ruby or Python or any other languagues without having to port

---

## Plan: `room_knowledge` becomes a `log_viz`-hosted MCP server, plus pathfinding

### Evaluation of the other two docs in this directory

- `architecture_and_python_port.md` already designed the *hosting* question:
  `room_knowledge` today is a hand-written Ruby method
  (`Boukensha::WorldKnowledge`, `18_orchestrator/lib/boukensha/
  world_knowledge.rb`) registered as a **native, in-process boukensha
  tool** (`boukensha_loader.rb`'s `tool "room_knowledge" do ... end`), not
  an MCP tool at all — it duplicates SQL that `log_viz`'s own `WorldMap`
  already owns. That doc's recommendation, made for the Python-port
  question but equally the right call for "any language, no porting":
  **promote it to an MCP server hosted by `log_viz`** (which already owns
  `WorldMap` and the live `world_map.sqlite3` connection), registered via
  `settings.yaml`'s `mcp_servers:` exactly like `mud-manager` is today.
  Not `mud_manager` itself — that server wraps the telnet/MUD protocol and
  has no relationship to `world_map.sqlite3`; bundling world-knowledge
  queries into it would just recreate the coupling problem in a different
  shape. This resolves the goal's last bullet directly.
- `room_connections.md` already designed the *directions* half (exits →
  resolved destinations, `edges` as a queryable graph) but explicitly
  stopped short of pathfinding (§4, "not designed further here, revisit as
  its own plan"). The goal doc's "path to get to certain room from current
  position" and "shortest path to Room A" bullets are exactly that
  deferred §4 — this plan un-defers it.
- Neither doc has been implemented yet: there is no `connections_for` on
  `WorldMap`, no `edges` exposure on `room_knowledge`, and `room_knowledge`
  is still the native tool described above. This plan supersedes both:
  §1–§3 of `room_connections.md` are folded in as-is (implemented here,
  not separately), and its §4 is designed concretely below instead of
  deferred again.

### Decisions this plan makes (so implementation isn't blocked on open questions)

1. **One new MCP server, hosted by `log_viz`**, stdio transport (same
   `command`/`args`/`env` shape every `mcp_servers:` entry already uses —
   no new transport code needed anywhere, `Boukensha::Tools::Mcp` and
   `Boukensha::Mcp::Client` are already fully generic). `log_viz` isn't
   step-numbered (it evolves in place, unlike the `ruby/NN_*` folders), so
   this lands directly in `week3_capable/log_viz/`.
2. **Two tools, not one mega-tool and not a pile of one-field tools** —
   this is what satisfies "the tool should serve smaller scope too"
   without over-fragmenting:
   - `room_knowledge(room_title)` — the existing shape
     (`examined`/`unexamined`, with results) **plus** a new `connections`
     field (§1 below). Covers "items located in Room B", "examined items
     in Room C + findings", and — via connections whose `to` is `nil`
     (a listed exit never walked) — "possible undiscovered area in Room
     D", to the extent the map already tracks it (see "Not doing").
   - `route_to(from, to)` — new, BFS pathfinding (§2 below). Covers
     "shortest path to Room A" / "path to get to a room from current
     position". `from`/`to` are both room titles the calling model
     already has in its own context (its current room from the last
     `look`/`move`, and whatever room title it's trying to reach) — same
     "no cross-process room tracking" posture `room_knowledge` already
     uses.
   Both stay room/route-scoped by construction — neither can return "all
   map data"; that satisfies the "shouldn't read all world data" bullet
   structurally, not just by convention.
3. **Schema/query logic moves fully into `log_viz`'s `WorldMap`**, not
   duplicated a third time. Today `boukensha/world_knowledge.rb` already
   hand-duplicates `log_viz`'s `EXAMINED_EXISTS_SQL`/
   `EXAMINATION_RESULT_SQL` (flagged in both existing docs as the
   duplication risk). Moving the MCP server to `log_viz`'s own process
   means the boukensha-side copy can be deleted outright — collapsing two
   copies into one, per `architecture_and_python_port.md`'s stated
   rationale, instead of the "three copies" failure mode that doc warned
   about for a naive Python port.
4. **Player identity travels via env var at server-spawn time, not as a
   model-fillable tool parameter.** Today `player` is threaded into
   `room_knowledge` via a Ruby closure in `boukensha_loader.rb`
   (`player&.name`) — the model never sees it, never chooses it, can't
   spoof another character's discoveries. A generic
   `Boukensha::Tools::Mcp.register` call turns every parameter into
   something the model supplies, which would break that invariant. Fix:
   a `WORLD_MAP_PLAYER` env var, read once by the server at startup
   (mirrors `mud`'s `MUD_NAME`/`MUD_PASSWORD`), filled in by extending
   `Boukensha.overlay_player_credentials` the same way it already fills
   `MUD_NAME`/`MUD_PASSWORD` for the `mud` entry. `room_knowledge` and
   `route_to` both read the player from server-side state; `player` is
   never a tool-call argument.
5. **`route_to` is scoped to the calling player's own visited-room
   subgraph** when a player identity is present (same join `room_knowledge`
   already does via `visits`/`sessions`), consistent with "the tool can
   only read the area the Player have been to." A route that would cross
   through a room only some other character has visited isn't returned —
   stated as a known limitation below, not silently papered over.
6. **Target directory for the boukensha side:
   `week3_capable/ruby/19_knowledge`** — already exists as an untouched,
   byte-identical copy of `18_orchestrator` (scaffolded, not yet
   customized; this is this curriculum's established "branch a new step
   folder, write its README" pattern, same as `18_orchestrator`'s own
   README opens with "Branched from `17_tool_permission`"). Implement
   there, not by editing `18_orchestrator` in place.

### 1. `LogViz::WorldMap#connections_for(room_title)`

New accessor in `week3_capable/log_viz/lib/log_viz/world_map.rb`, alongside
`unexamined_in`/`examined_in`/`edges` — this is `room_connections.md` §1,
with its one open question resolved:

```
connections_for(room_title) ->
  [{ direction: "north", to: "Temple Square", via: ["north"] },
   { direction: "east",  to: nil,             via: [] },
   { direction: "flee",  to: "The Dump",      via: ["flee"] }, ...]
```

- Left-join `rooms.exits` (parsed JSON letters `n/s/e/w/u/d`, mapped to
  full direction names via `DIRECTION_DELTA`'s vocabulary) against `edges`
  rows where `from_title = room_title`. Every exit letter gets exactly one
  output row; `to: nil` is a first-class "listed, never walked" state.
- **Resolved decision** (left open in `room_connections.md` §1): aggregate
  by `to_title`, not by raw `edges` row — a direction can have more than
  one `via` string pointing at the same destination (the observed
  `("Market Square", "south", ...)` / `("Market Square", "look", ...)`
  duplicate). Group by direction, collect the distinct `via` values seen
  into an array, report one row per direction either way.
- Directions with no exit letter but a real `edges` row anyway
  (`enter`/`leave`/`flee` arrivals) are still included, `direction` set to
  the raw `via` string.
- No reverse-edge inference (`to` stays `nil` just because the destination
  happens to lead back) — same stated limitation as `room_connections.md`.

### 2. `LogViz::WorldMap#route_to(from:, to:, player: nil)`

New accessor, same file. This is `room_connections.md` §4, designed
concretely instead of deferred:

```
route_to(from: "Market Square", to: "Temple Bakery", player: "Alice") ->
  { from:, to:, hops: [{direction: "north", to: "Temple Square"},
                        {direction: "east",  to: "Temple Bakery"}] }
  # or, if unreachable from what this player has discovered:
  { from:, to:, hops: nil, note: "no known route" }
```

- Build an adjacency list from `edges` (unweighted, directed — exactly the
  graph `connections_for` reads), scoped to rows where both `from_title`
  and `to_title` are rooms the player has visited (`visits`/`sessions`
  join, same shape as `WorldKnowledge#player_visited_room?` today) when
  `player` is non-nil; unscoped (whole map) when `player` is nil, same
  backward-compatible default `room_knowledge` already uses for a run
  launched without `--player`.
- Plain BFS, hop-count shortest path (ties broken arbitrarily — no
  weighting by danger/distance, see "Not doing"). `from == to` returns
  `hops: []`. `from`/`to` not found in the player's visited set, or no
  path exists, both return `hops: nil` with a `note` explaining which —
  never raises, same posture as `room_knowledge` (a missing DB, a bad room
  title, or any SQLite error degrades to an empty-but-valid result).
- Reuses `connections_for`'s direction-letter vocabulary so a `route_to`
  hop's `direction` matches what `connections_for`/`room_knowledge` would
  report for the same edge.

### 3. `LogViz::WorldMap#room_knowledge(room_title:, player: nil)`

Port `Boukensha::WorldKnowledge.room_knowledge`'s logic (GLOBAL/PLAYER
`EXAMINED_EXISTS_SQL`/`EXAMINATION_RESULT_SQL` variants, the
`player_visited_room?` gate, the "you have not been here" note) into
`WorldMap` itself — `log_viz` already owns near-identical SQL
(`EXAMINED_EXISTS_SQL`/`EXAMINATION_RESULT_SQL` at the top of
`world_map.rb`), so this collapses the existing two-copy duplication
rather than moving it sideways. Extend the return shape with `connections`
from §1:

```
room_knowledge(room_title:, player: nil) ->
  { room_title:, examined: [{subject:, result:}, ...], unexamined: [...],
    connections: [{direction:, to:, via:}, ...] }
```

### 4. `LogViz::McpServer` — new stdio JSON-RPC server

New file `week3_capable/log_viz/lib/log_viz/mcp_server.rb`, structured
like `MudManager::McpServer`
(`week0_explore/mud_manager/lib/mud_manager/mcp_server.rb`): `initialize`/
`tools/list`/`tools/call` over stdin/stdout, `protocolVersion
"2025-06-18"`. Much smaller — two hand-written tool defs (no reflection
machinery needed, unlike `mud_manager`'s `ToolCatalog`, since there are
only two methods, not two dozen):

```
room_knowledge  { room_title: string }              -> WorldMap#room_knowledge
route_to        { from: string, to: string }         -> WorldMap#route_to
```

- Reads `WORLD_MAP_PLAYER` from `ENV` once at startup (empty/absent means
  nil, same as today's no-`--player` run) — never a tool parameter (see
  decision 4).
- Reads `LOG_VIZ_WORLD_MAP_DB` the same way `WorldKnowledge.db_path` does
  today, `readonly: true`, same WAL-concurrency posture as every other
  reader of this file.
- `week3_capable/log_viz/bin/log_viz` gains a `--mcp` branch (mirrors
  `mud-manager`'s `bin/mud-manager`: `--mcp` present → run the JSON-RPC
  server over stdio and never start Sinatra; absent → today's behavior,
  unchanged). MCP mode needs nothing from the web app — no Sinatra/Puma
  dependency at runtime for this path.

### 5. Retire the native tool, in `19_knowledge`

- Delete `lib/boukensha/world_knowledge.rb` and the
  `tool "room_knowledge" do |room_title:| ... end` block in
  `lib/boukensha_loader.rb` (the whole reason that block exists —
  "`room_knowledge` is the one exception... it doesn't talk to the MUD, so
  it doesn't belong in `mcp_servers`" — stops being true once it *is* an
  MCP server).
- Extend `Boukensha.overlay_player_credentials` (`lib/boukensha.rb`) to
  also fill `WORLD_MAP_PLAYER` when an entry's `env:` declares that key,
  same pattern as the existing `MUD_NAME`/`MUD_PASSWORD` two lines.
- No other orchestrator-side code changes — registration goes through the
  existing generic `Boukensha::Tools::Mcp.register` path, same as `mud`.

### 6. `settings.yaml` wiring

- New `mcp_servers.log-viz` entry:
  ```yaml
  log-viz:
    command: log_viz
    args:    [--mcp]
    env:
      WORLD_MAP_PLAYER: ""
      LOG_VIZ_WORLD_MAP_DB: ""   # only if not already relying on the default path
    prefix: world
  ```
  giving `world__room_knowledge` / `world__route_to` as the model-visible
  names (`Boukensha::Tools::Mcp`'s `prefix__name` convention, same as
  `tbamud__*`).
- `tool_roles.inspector` list: rename bare `room_knowledge` →
  `world__room_knowledge`, add `world__route_to`.
- `prompts/judge/system.md` and any other prose mentioning `room_knowledge`
  by its old bare name: update to `world__room_knowledge`.

### 7. (bundled, cheap reuse — optional, do last) `/map` UI

`room_connections.md` §2: `log_viz/lib/log_viz/app.rb`'s `/map` `@rooms`
assembly and `views/map.erb`'s Rooms table `Exits` column render
`connections_for` output (`n → Temple Square · e (unexplored)`) instead of
raw exit letters, since §1 already builds the exact data this needs.
Doesn't block §1–§6; do it if there's time left, not a prerequisite for
the MCP tool.

## Known tradeoffs / risks

- No reverse-edge inference (carried from `room_connections.md`): `edges`
  only records directions actually walked *from* a room, so `route_to`
  can silently miss a path that's only ever been walked in the opposite
  direction. A `"no known route"` result can mean "genuinely never
  connected" or "only walked the other way" — indistinguishable to the
  caller. Worth restating here (not just in `room_connections.md`) because
  a pathfinding tool failing quietly reads much more like a bug than a
  missing-exit-resolution field does.
- `route_to` scoped to the calling player's own visited rooms by default:
  a route that passes through a room only a *different* character
  discovered won't be found, even if the world map (unscoped) has it.
  Deliberate, consistent with `room_knowledge`'s existing per-player
  scoping (`multiple_concurrent_players.md`), but worth the caller
  understanding it's "routes through what *I've* seen," not "routes
  through everything ever logged."
- Tool rename (`room_knowledge` → `world__room_knowledge`, new
  `world__route_to`) is a breaking name change for anything hardcoding the
  bare name — `settings.yaml` (`tool_roles`), `prompts/judge/system.md`,
  and any other doc referencing it by name need a grep-and-update pass;
  listed in "Files touched" below.
- "Possible undiscovered area in Room D" is only partially satisfied:
  unresolved exits (`connections_for`'s `to: nil`) are covered; a room
  only ever *mentioned* in room-description prose (never an actual exit
  letter) is not — same "mention extraction" gap `room_connections.md` §4
  already flagged from the bakery investigation. Explicitly out of scope
  here too (see "Not doing").
- One long-lived `log_viz --mcp` subprocess per boukensha process/player,
  spawned fresh at each `boukensha --player NAME` launch and closed at
  exit — identical lifecycle shape to `mud-manager`'s subprocess today, no
  new operational pattern introduced.

## Files touched

- `week3_capable/log_viz/lib/log_viz/world_map.rb` — `connections_for`,
  `route_to`, `room_knowledge` (ported from boukensha).
- `week3_capable/log_viz/lib/log_viz/mcp_server.rb` — new.
- `week3_capable/log_viz/bin/log_viz` — `--mcp` branch.
- `week3_capable/log_viz/test/test_world_map.rb` — fixtures for all three
  new/moved accessors (a resolved direction, a listed-but-untraveled exit,
  an `enter`/`flee`-only arrival, the duplicate-`via` case, a reachable
  and an unreachable `route_to`, player-scoped vs. unscoped).
- `week3_capable/log_viz/test/test_mcp_server.rb` — new, JSON-RPC
  dispatch/`tools/list`/`tools/call` coverage, mirroring however
  `mud_manager` is tested.
- `week3_capable/log_viz/lib/log_viz/app.rb`, `views/map.erb`,
  `public/style.css` — §7, optional.
- `week3_capable/ruby/19_knowledge/lib/boukensha/world_knowledge.rb` —
  deleted.
- `week3_capable/ruby/19_knowledge/lib/boukensha_loader.rb` — remove the
  local `tool "room_knowledge"` block.
- `week3_capable/ruby/19_knowledge/lib/boukensha.rb` —
  `overlay_player_credentials` gains `WORLD_MAP_PLAYER`.
- `week3_capable/ruby/19_knowledge/prompts/judge/system.md` — rename
  references.
- `week3_capable/ruby/19_knowledge/test/test_world_knowledge.rb` — remove
  (native-tool tests no longer apply); coverage for the new pieces lives
  in `log_viz`'s tests plus a `mcp_servers`-config test for the
  `WORLD_MAP_PLAYER` overlay (mirrors `test_player_credentials.rb`'s
  existing `MUD_NAME`/`MUD_PASSWORD` coverage).
- `week3_capable/ruby/19_knowledge/README.md` — write this step's "Branched
  from `18_orchestrator`, what's new" doc, per this curriculum's
  convention.
- `.boukensha/settings.yaml` — new `mcp_servers.log-viz` entry,
  `tool_roles.inspector` rename.
- `docs/plans/world_knowledge/room_connections.md` — mark §1–§3
  "Implemented, see `world_knowledge.md`"; §4 folded into this plan as
  `route_to`.
- `~/.boukensharc` (per-machine, not repo) — update `boukensha_path` to
  `19_knowledge` once built, same manual step every prior README calls
  out; not part of this change set.

## Not doing (this pass)

- Reverse-edge inference or assuming MUD exits are symmetric.
- Mention-based undiscovered-room detection (routing toward a place named
  in prose but never entered) — flagged, not designed, same as
  `room_connections.md` §4's original scope note.
- Weighted/cost-aware pathfinding (danger, distance, mob presence) —
  unweighted hop-count BFS only.
- Auto-injecting `route_to`/connection results into the agent's context —
  stays a tool the agent chooses to call, same standing rule
  `room_world_inspector.md` §3 set for `room_knowledge` itself.
- The Python port itself — this plan is the prerequisite
  `architecture_and_python_port.md` called for ("promote to MCP *before*
  porting"), not the port.
