# Step 13 - Room Inspection

Branched from `12_context` (which stays the source of truth for the
context-management/TUI/MCP-host framework this step carries forward
unchanged). This step's only addition is `room_knowledge`, a small
read-only tool that lets the Player agent check its own past exploration
history. Full design/rationale:
`docs/plans/observability/room_world_inspector.md`.

## Build

```sh
gem build boukensha.gemspec
gem install boukensha-0.13.0.gem
```

## What's new in this step

### `room_knowledge` — a read-only look at your own exploration history

`bin/boukensha` (via `lib/boukensha_loader.rb`) registers one extra tool on
top of whatever `settings.yaml`'s `mcp_servers:` block provides:

```
room_knowledge(room_title: "The Temple Square")
  -> {
       room_title:,
       examined: [{subject: "lever", result: "It's a rusty iron lever."}, ...],
       unexamined: [...subjects]
     }
```

It queries `log_viz`'s own `world_map.sqlite3` (`content_facts` +
`examinations` tables, opened read-only — WAL mode makes this safe
alongside `log_viz`'s own concurrent reads/writes and its background
classification worker) to answer: of the items/mobs/NPCs/scenery ever
noticed in this room, which has the player actually `examine`d /
`look at`-ed, and which hasn't? It's a passive record from past sessions,
**not** a live scan of the room right now.

Each `examined` entry's `result` is the actual text the room printed back
for that examine/look-at — a real gameplay clue (an NPC's dialogue, an
item's fine print) can live there. The point of surfacing it, not just a
bare "examined: true", is so the agent can reuse a remembered answer
instead of spending another turn re-examining something it already
inspected. `unexamined` stays a plain subject list — there's by definition
no result to report for those yet.

`room_title` must be the exact title as it appeared in the agent's own
last `look`/`move` result — there's no cross-process "what room am I in"
tracking on this end. The agent already has that in its own transcript, so
none was built; see the plan's §3 for the reasoning.

This is a genuinely new, two-way coupling: `log_viz` already depends on
this agent's `.jsonl` log format one way; `room_knowledge` is the opposite
direction — the agent now depends on a schema `log_viz` owns. The query
logic lives in one small file, `lib/boukensha/world_knowledge.rb`, that
touches only `content_facts`/`examinations`/`rooms`, so a schema change is
a one-place update on each side. It fails soft — empty `examined`/
`unexamined` lists — if `log_viz` has never run or the database is
unreadable; a missing observability signal must never break the player's
turn.

The tool is opt-in for the *model*, not auto-injected: nothing puts its
result into the system prompt or context automatically. Whether the Player
agent finds it worth calling is exactly the open question this addition
was meant to answer.

## Run

```sh
# Offline, no API key, no live MUD — uses the daemon's built-in fake MUD:
ruby examples/mcp_mud_demo.rb --dry

# One-shot demo:
ruby examples/example.rb

# Interactive TUI (registers room_knowledge automatically):
BOUKENSHA_DIR=/path/to/.boukensha BOUKENSHA_PATH=/path/to/week2_observability/ruby/13_room_inspector boukensha

# Plain REPL (no charm dependency required):
BOUKENSHA_PATH=/path/to/week2_observability/ruby/13_room_inspector boukensha --no-tui
```

`room_knowledge` reads `LOG_VIZ_WORLD_MAP_DB` (default:
`<repo root>/.boukensha/world_map.sqlite3`) — the same file `log_viz`'s
`/map` page reads and writes.

## Tests

```sh
rake test
```

Everything else — context/token tracking, auto-compaction, the MCP-host
tool model, the TUI, `Boukensha.run`/`.repl` — is unchanged from
`12_context`; see that step's README for the full feature history.
