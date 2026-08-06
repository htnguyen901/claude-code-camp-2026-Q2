# Step 16 - Visibility

Branched from `15_observability` (stays the source of truth for everything
carried forward unchanged: context/token management, the TUI, the
MCP-host tool model, MUD response compaction, and OpenTelemetry
traces/metrics — see that step's README, and `13_room_inspector`'s for
`room_knowledge`'s original single-player shape). This step's addition is
running **multiple players concurrently**: each `boukensha` process logs in
as a distinct character, gets its own MUD session and its own slice of
`room_knowledge`, and `log_viz` gains a `/players` view to see them
side by side. Full design/rationale:
`docs/plans/observability/players/multiple_concurrent_players.md`.

## Install

```sh
cd week2_observability/ruby/16_visibility
bundle install
```

Prerequisites beyond the Ruby gems:

- A `mud-manager` MCP server on `PATH` (built from `week0_explore/mud_manager`
  — see that package's README) pointed at a running MUD, or its bundled fake
  MUD for offline testing.
- `.boukensha/players/*.yaml` character profiles. If `.boukensha/players/`
  is empty, seed them first (from the repo root):

  ```sh
  week2_observability/bin/seed_players
  ```

  This creates/confirms an `admin` character (CircleMUD's rules require the
  *first* character ever created on a fresh world to be the top-level
  admin) plus one character per `.boukensha/players/*.yaml` profile already
  on disk. See `week2_observability/bin/seed_players`'s own header comment.
- (optional, for `log_viz`'s world map / discoveries / content
  classification) a local Ollama daemon — see `log_viz/README.md`'s
  "Setting up Ollama" section.

## Build

```sh
gem build boukensha.gemspec
gem install boukensha-0.16.0.gem
```

Installs the `boukensha` executable. `~/.boukensharc`'s `boukensha_path`
must point at this step's directory (or the freshly-built/installed gem
must be the one on `PATH`) for `--player` to be available — see
`lib/boukensha_loader.rb`'s header comment for the full resolution order.

## What's new in this step

### Player identity: `boukensha --player NAME`

Until this step, every `boukensha` process logged into the MUD as whatever
static `MUD_NAME`/`MUD_PASSWORD` `.boukensha/settings.yaml`'s
`mcp_servers.mud.env` declared — so two processes running at once both
tried to become the same character. `--player NAME` (or
`BOUKENSHA_PLAYER=NAME`, CLI wins if both are given) loads
`.boukensha/players/NAME.yaml` and overlays its `name`/`password` onto
every configured MCP server whose `env:` block already declares
`MUD_NAME`/`MUD_PASSWORD` — matched by key name, not a hardcoded server
name, so it stays generic if a second MUD-like server is ever added.
`settings.yaml`'s own `MUD_NAME`/`MUD_PASSWORD` keys are now blank
placeholders for exactly this reason (there's no shared default character
anymore); omitting `--player` prints a one-line notice and runs with no MUD
identity at all, rather than silently reusing a shared login.

```sh
boukensha --player noir              # TUI, logged in as noir.yaml
boukensha --player dina --no-tui     # plain REPL, logged in as dina.yaml
```

Each process spawns its own `mud-manager --mcp` subprocess (already
isolated per process, unchanged from earlier steps) and writes its own
`.boukensha/sessions/<session_id>.jsonl`, now additionally tagged with a
`player` field on its `session_start` event — the field `log_viz`'s
`/players` view and the per-player `room_knowledge` scoping below both key
off.

### Per-player `room_knowledge` isolation

`room_knowledge` (`lib/boukensha/world_knowledge.rb`, introduced in
`13_room_inspector`) previously answered "what's been examined in this
room" from the *entire* accumulated map, regardless of which character was
asking — any player could see what any other player's character had
discovered. It now takes the calling player's name (threaded automatically
from `--player`) and scopes both halves of the answer:

- A room the player's own sessions have never visited returns
  `{ room_title:, examined: [], unexamined: [], note: "you have not been here" }`
  instead of another character's findings.
- Within a room the player *has* visited, an item only counts as
  "examined" if one of that player's own sessions is the one that examined
  it — two different characters examining the same subject in the same
  room are different characters with different knowledge, not one shared
  save file.

A run launched without `--player` (or a pre-this-step session file) keeps
the historical, unscoped, whole-map-visible behavior — an explicit,
visible gap rather than a guess; see the plan's "Known tradeoffs."

### `bin/play_players` — running several players on one goal

```sh
week2_observability/bin/play_players --goal "explore the temple square" noir dina
```

Spawns one `boukensha --player NAME --no-tui` process per name given, all
handed the identical goal as their one turn (piped into each process's
stdin), each logging to its own file under
`.boukensha/play_logs/NAME-<timestamp>.log` instead of a shared terminal.
It's a thin convenience wrapper, not a process supervisor — no
restart-on-crash, and (for now) every listed player gets the same goal;
distinct per-player goals are flagged as a later follow-up in the plan.

### `log_viz`: a Players view, a discovered-vs-discoverable KPI, and per-session time-lapse

- **`/players`** — one card per distinct tagged player: live/idle status,
  session count, rooms discovered, total tokens/cost.
- **`/players/:name`** — that player's own session list, plus a
  "discovered vs. discoverable" progress bar for both rooms and
  discoveries, compared against the *engineer's* current global World Map
  (`/map`) — the denominator is "what's been found by anyone so far," not
  a claim about the MUD's true size, which nothing in this stack knows.
- **Per-session time-lapse** — `/sessions/:id` now has a "Path taken this
  session" panel: a node graph scoped to just that session's own visited
  rooms (with a visit-order badge per room) alongside the ordered visit
  list, driving a prev/next/play scrubber that highlights the active room
  on the graph as you step through. Degrades to a plain ordered list with
  no JS.

The World Map (`/map`) itself stays global/unscoped by design — it's the
engineer's own view, not something any player's character has access to
(that isolation is what `room_knowledge`, above, enforces on the agent
side).

### The `/map` auto-refresh bug is fixed

`/map` previously lost your scroll position and any open room-detail panel
every ~15 seconds. Root cause: the page's `<meta http-equiv="refresh">`
no-JS fallback had its timer committed by the browser at parse time,
so removing the `<meta>` element from the DOM afterward (what the old code
did) never reliably canceled it. Fixed by wrapping it in `<noscript>`
instead, so the browser only ever parses/applies it when there's no script
running to have removed it in the first place.

## Run

Offline smoke test, no live MUD needed (built-in fake MUD, same as
`13_room_inspector`):

```sh
ruby examples/mcp_mud_demo.rb --dry
ruby examples/example.rb
```

Two players at once, against a real MUD:

```sh
# terminal 1
BOUKENSHA_DIR=/path/to/.boukensha boukensha --player noir

# terminal 2
BOUKENSHA_DIR=/path/to/.boukensha boukensha --player dina --no-tui
```

or the one-shot launcher:

```sh
week2_observability/bin/play_players --goal "explore the temple square" noir dina
```

Watch them in the browser:

```sh
cd week2_observability/log_viz
bundle install
bundle exec ruby bin/log_viz
```

Then open <http://localhost:4567/players>.

## Tests

```sh
rake test
```

`log_viz`'s own suite covers the schema migration, the new `WorldMap`
accessors, and the new routes/templates — it has no `Rakefile`, so run its
test files directly:

```sh
cd ../../log_viz
for f in test/test_*.rb; do ruby -Ilib -Itest "$f"; done
```

## Not doing (explicitly out of scope)

Carried over from the plan's own scope decisions — filing a bug for any of
these is filing it against a known, deliberate gap, not an oversight:

- **Distinct goals per player in `play_players`** — every name given gets
  the identical goal text this pass; per-player goals are flagged as a
  follow-up in the plan's "Open questions."
- **Authenticating that the human running `--player noir` really is
  "noir"** — `--player` just means "load that profile and log in as it,"
  matching this whole project's single-operator threat model.
- **A process supervisor** — `play_players` spawns and waits; it doesn't
  restart a crashed player or multiplex N terminals' output back to one
  screen.
