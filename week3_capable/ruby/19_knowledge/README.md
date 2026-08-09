# Step 19 - Knowledge

Branched from `18_orchestrator` (stays the source of truth for everything
carried forward unchanged: context/token management, the TUI, the MCP-host
tool model, multi-player support, MUD response compaction, OpenTelemetry
traces/metrics, per-task tool policy, and the Planner/Player/Judge agentic
loop — see that step's README). This step turns `room_knowledge` — until
now a hand-written Ruby method registered as a local, non-MCP boukensha
tool — into an MCP server hosted by `log_viz`, and adds pathfinding
alongside it. Full design/rationale:
[`docs/plans/world_knowledge/world_knowledge.md`](../../../docs/plans/world_knowledge/world_knowledge.md)
(which supersedes
[`room_connections.md`](../../../docs/plans/world_knowledge/room_connections.md)
and folds in its §1–§3, un-deferring its §4 as `route_to`).

## What's new in this step

### `room_knowledge`/`route_to` move to an MCP server hosted by `log_viz`

Before this step, `room_knowledge` was the one tool boukensha registered
itself — a hand-written `Boukensha::WorldKnowledge` module
(`lib/boukensha/world_knowledge.rb`), wired in via `boukensha_loader.rb`'s
own `RunDSL#tool` block, because it "doesn't talk to the MUD" and so didn't
fit `settings.yaml`'s `mcp_servers:` list. That reasoning stopped holding
once `room_knowledge` itself became an MCP server: `log_viz` (which already
owns `world_map.sqlite3` and the `WorldMap` class that reads/writes it) now
hosts `log_viz --mcp`, a JSON-RPC/MCP stdio server exposing two tools —
structured exactly like `week0_explore/mud_manager`'s own `--mcp` mode, and
registered through the same generic `Boukensha::Tools::Mcp.register` path
`mud` already used. There is no boukensha-side `WorldKnowledge` module any
more; `lib/boukensha/world_knowledge.rb` is deleted, and `boukensha_loader.rb`
registers no local tools at all — every tool the agent can call now comes
from `settings.yaml`'s `mcp_servers:` block, no exceptions.

```yaml
mcp_servers:
  log-viz:
    command: log_viz
    args:    [--mcp]
    prefix:  world
    env:
      WORLD_MAP_PLAYER:
```

reaching the agent as `world__room_knowledge` and `world__route_to` (the
same `prefix__name` convention `tbamud__*` already uses). `tool_roles
.inspector` (the Judge's read-only tool set) is updated to match.

### `route_to` — shortest-path pathfinding, new

```
world__route_to(from: "Market Square", to: "Temple Bakery") ->
  { from:, to:, hops: [{ direction: "north", to: "Temple Square" },
                        { direction: "east",  to: "Temple Bakery" }] }
  # or, if unreachable from what's been discovered so far:
  { from:, to:, hops: nil, note: "no known route" }
```

Unweighted, hop-count BFS over `edges` (`log_viz`'s own record of every
`from_title`/`via`/`to_title` a session has ever walked) — the piece
`room_connections.md` §4 explicitly deferred ("the agent being asked to
find the bakery and failing, repeatedly... isn't actually fixed by §1–§3
alone"). `from`/`to` are room titles the calling model already has in its
own context (its current room from the last `look`/`move`, and whatever
room title it's trying to reach) — same "no cross-process room tracking"
posture `room_knowledge` already used. Scoped to the calling player's own
visited-room subgraph when a player identity is present, same as
`room_knowledge` — a route through a room only a *different* character has
visited is not returned, even if the unscoped map has it. No reverse-edge
inference: a direction only ever *arrived from*, never *departed through*,
stays unresolved even though a human would guess the reverse trivially.

### `room_knowledge` gains a `connections` field

```
world__room_knowledge(room_title: "Market Square") ->
  { room_title:, examined: [{subject:, result:}, ...], unexamined: [...],
    connections: [{ direction: "north", to: "Temple Square", via: ["north"] },
                   { direction: "east",  to: nil,             via: [] }, ...] }
```

Every exit letter the room's `[ Exits: ... ]` line ever listed gets exactly
one row; `to: nil` is a first-class "listed, never walked" state, not an
absence — the queryable answer to "have I (or a past session) already
learned where any of these exits lead," instead of the agent's only signal
being whatever raw exits line is sitting in its own context from the last
`look`. A direction-less arrival (`enter`/`leave`/`flee`, or a bare `look`
right after a `move`) that isn't a listed exit gets its own row too, tagged
with its raw `via` string. A room a player hasn't visited stays fully
opaque — no `connections` either, not just empty `examined`/`unexamined` —
exits are something you only know by having stood in the room. Backed by
`LogViz::WorldMap#connections_for`/`#room_knowledge`, ported from the
former `Boukensha::WorldKnowledge` (which duplicated `log_viz`'s own
`EXAMINED_EXISTS_SQL`/`EXAMINATION_RESULT_SQL`) directly onto `WorldMap`
itself — collapsing that two-copy duplication instead of moving it
sideways.

### `WORLD_MAP_PLAYER` — player identity travels via env, not a tool argument

Mirrors `MUD_NAME`/`MUD_PASSWORD`: `Boukensha.overlay_player_credentials`
now also fills `WORLD_MAP_PLAYER` for any `mcp_servers` entry whose `env:`
block declares it, from `boukensha --player NAME`'s profile. `LogViz::
McpServer` reads it once from `ENV` at its own startup — never a
`world__room_knowledge`/`world__route_to` parameter the model could supply
or spoof. Omitting `--player` runs both tools in their historical,
un-scoped, whole-map-visible mode — unchanged, backward compatible.

### `log_viz --mcp` — a second entry point, no new transport code

`week3_capable/log_viz/bin/log_viz` gains a `--mcp` branch: present, it
runs `LogViz::McpServer` over stdio and never touches Sinatra; absent,
today's web app, unchanged. `log_viz.gemspec` (new) packages `bin/log_viz`
as an installable executable — the same one-time-per-machine `gem build` +
`gem install` step `mud-manager` already needs, so `command: log_viz` in
`settings.yaml` resolves on `PATH` the identical way `command: mud-manager`
already does.

## Install

```sh
cd week3_capable/ruby/19_knowledge
bundle install
```

Prerequisites beyond the Ruby gems: same as `18_orchestrator` — a
`mud-manager` MCP server on `PATH`, `.boukensha/players/*.yaml` character
profiles, and optionally a local Ollama daemon for `log_viz`'s
classification features — **plus, new this step**, `log_viz` itself on
`PATH`:

```sh
cd week3_capable/log_viz
gem build log_viz.gemspec
gem install ./log_viz-0.1.0.gem
```

## Build

```sh
gem build boukensha.gemspec
gem install boukensha-0.19.0.gem
```

Installs the `boukensha` executable. `~/.boukensharc`'s `boukensha_path`
must point at this step's directory for it to run this step's code — see
`lib/boukensha_loader.rb`'s header comment.

## Run

```sh
boukensha --player noir
```

`world__room_knowledge`/`world__route_to` show up in the tool list
alongside every `tbamud__*` command — same REPL, same MCP-host tool model,
nothing new to invoke by hand. To exercise `log_viz --mcp` directly (e.g.
while developing against it):

```sh
LOG_VIZ_WORLD_MAP_DB=.boukensha/world_map.sqlite3 log_viz --mcp
```

reads newline-delimited JSON-RPC off stdin, writes responses to stdout —
meant to be spawned by a host, not run interactively.

## Tests

```sh
rake test
```

New/changed coverage for this step: `test_player_credentials.rb` gains
`WORLD_MAP_PLAYER` overlay cases (mirrors its existing `MUD_NAME`/
`MUD_PASSWORD` coverage); `test_world_knowledge.rb` is removed (the module
it exercised no longer exists — coverage for the same query logic now
lives in `log_viz`'s own suite). `week3_capable/log_viz`'s suite gets the
real new coverage — run it separately, it's a different Ruby program:

```sh
cd ../../log_viz && ruby -Itest -Ilib test/test_world_map.rb
cd ../../log_viz && ruby -Itest -Ilib test/test_mcp_server.rb
```

`test_world_map.rb`: `connections_for` (a resolved direction, a
listed-but-untraveled exit, a direction-less `flee` arrival, the
`room_connections.md`-flagged `look`-mispairing duplicate — documented as
still *not* collapsed — and a same-direction merge across two differently-
cased `via` strings, which *is* collapsed), `route_to` (a multi-hop
shortest path, `from == to`, no route found, and player-scoped vs.
unscoped reachability), `room_knowledge`'s new `connections` field
(including the "have not been here" case omitting it too), and
`readonly: true` (`LogViz::McpServer`'s posture — a missing database
degrades to empty results instead of raising, and a reader instance sees
what a writer instance already committed). `test_mcp_server.rb`:
`initialize`/`tools/list`/`tools/call` JSON-RPC dispatch end to end
against a throwaway `world_map.sqlite3`, an unknown tool name reported as
an error, and `WORLD_MAP_PLAYER` (set, blank, and a missing database)
scoping `room_knowledge`'s result.

## Not doing (this step)

Carried over from `world_knowledge.md`'s "Not doing" section — flagged,
not designed:

- **Reverse-edge inference** — `route_to`/`connections_for` never assume
  MUD exits are symmetric; a direction only ever arrived from, never
  departed through, stays unresolved.
- **Mention-based undiscovered-room detection** — routing toward a place
  only ever named in room-description prose, never actually entered
  (the original "bakery" investigation's gap) is still out of scope.
- **Weighted/cost-aware pathfinding** — `route_to` is unweighted hop-count
  BFS only; no notion of danger, distance, or mob presence.
- **Auto-injecting results into the agent's context** — both tools stay
  something the agent chooses to call, same standing rule
  `room_world_inspector.md` §3 set for `room_knowledge` itself.
- **The Python port** — this step is the prerequisite
  `architecture_and_python_port.md` called for ("promote to MCP *before*
  porting"), not the port itself.
