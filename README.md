# Claude Code Camp
This is the official repo for the Claude Code Camp operated by [ExamPro](https://www.exampro.co)

## Setup — running the agent loop (`boukensha`)

The latest step lives in `week3_capable/ruby/20_navigator`. It drives a MUD
through `mud-manager` and reads/writes a shared world model through
`log_viz` — both are separate gems that need to be built and installed on
`PATH` once per machine, plus some machine-local config under `.boukensha/`.

### 1. Build & install the gems

Each of these is a real gem, not run via `bundle exec` from its own
directory, because `boukensha` spawns them as MCP servers by bare command
name (`mud-manager`, `log_viz`) — they need to resolve on `PATH`.

```sh
# MudManager — telnet session management + MUD command primitives
cd week0_explore/mud_manager
gem build mud_manager.gemspec
gem install ./mud_manager-*.gem

# log_viz — session dashboard + the world__room_knowledge/world__route_to
# MCP server ("log_viz --mcp")
cd ../../week3_capable/log_viz
gem build log_viz.gemspec
gem install ./log_viz-*.gem

# boukensha — the agent loop itself (Planner/Player/Judge/Navigator)
cd ../ruby/{lastest_boukensha_folder}
gem build boukensha.gemspec
gem install ./boukensha-*.gem
```

`~/.boukensharc` must point `boukensha_path` at this step's directory (see
`week3_capable/ruby/20_navigator/lib/boukensha_loader.rb`'s header comment
for the full resolution order):

```yaml
# ~/.boukensharc
boukensha_path: /absolute/path/to/this/repo/week3_capable/ruby/{lastest_boukensha_folder}
```

### 2. `.boukensha/.env` — API keys and machine-local paths

`.boukensha/.env` is git-ignored (per-machine secrets and paths, never
committed). Create it with:

```sh
ANTHROPIC_API_KEY="sk-ant-..."
OPENAI_API_KEY="sk-..."

# Required so the *installed* log_viz gem's MCP server (world__room_knowledge/
# world__route_to) finds this repo's actual world map instead of an empty one.
# Without these, log_viz computes its default DB/sessions paths relative to
# wherever the gem got installed (e.g. deep inside ~/.rbenv/.../gems/log_viz-*/),
# which doesn't exist — every room_knowledge call then silently returns
# {examined: [], unexamined: [], connections: []} for every room, with no
# error and no "you have not been here" note (that note only appears on the
# separate player-scoping path — its absence is the tell that this is the
# bug, not a player mismatch). See week3_capable/log_viz/lib/log_viz/
# world_map.rb#open_db_readonly!.
LOG_VIZ_WORLD_MAP_DB=/absolute/path/to/this/repo/.boukensha/world_map.sqlite3
LOG_VIZ_SESSIONS_DIR=/absolute/path/to/this/repo/.boukensha/sessions
```

`Boukensha::Config` loads this file via `Dotenv.load` on startup, and the
MCP client spawns `log_viz --mcp` inheriting that env, so no other wiring is
needed once it's set.

### 3. Player profiles

Each character `boukensha --player NAME` can log in as needs a
`.boukensha/players/NAME.yaml` profile (name/password/class/sex — see the
existing files in that directory for the shape).

### 4. Optional: Ollama (for log_viz's background content-fact extraction)

Only needed for `log_viz`'s `ContentFact` classification worker. See
`week3_capable/log_viz/README.md`'s "Setting up Ollama" section — on WSL,
install Ollama *inside* WSL rather than reusing a Windows-side install
(`localhost` isn't shared across the WSL2 NAT boundary).

### 5. Run

```sh
boukensha --player dina                       # the agent loop (TUI REPL)

cd week3_capable/log_viz
bundle install
bundle exec ruby bin/log_viz                  # session/world-map dashboard, http://localhost:4567
```

See each step's own README (e.g.
`week3_capable/ruby/{lastest_boukensha_folder}/README.md`) for what's new in that step and
its own prerequisites/test instructions.
