# MudManager

The MudManager has the following responsibilities:

- manages long-lived telnet sessions
- manages the multi-step process of logging back in
- provides generic primitives for MUD commands

## Build the Gem

From this directory:

```sh
gem build mud_manager.gemspec
gem install ./mud_manager-0.2.0.gem
```

Expected output:

```text
MudManager
```

## Uninstall

```sh
gem uninstall mud_manager
```

## Examples

Test the live session:

```sh
MUD_NAME=YourCharacterName MUD_PASSWORD=yourpassword ruby mud_manager/examples/live_session_test.rb
```

If you are already inside the `mud_manager` directory, run:

```sh
MUD_NAME=YourCharacterName MUD_PASSWORD=yourpassword ruby examples/live_session_test.rb
```

## `mud-manager --mcp` — the MCP server

`Session`/`Primitives` are Ruby. The moment another agent implementation
(Python, or anything else) needs to play the MUD, reimplementing telnet
handling and the login dance in that language was the wrong move — it
duplicates the trickiest part of this gem and guarantees the ports drift.
See [`docs/plans/mud_manager/generic_interfacing.md`](../../docs/plans/mud_manager/generic_interfacing.md)
for the full options analysis; the short version is: wrap `MudManager` in an
MCP server once, and every agent — Ruby's own `boukensha`
(`week1_baseline/ruby/10_standard_tool_library`, already an MCP host with zero
MUD-specific code) or a future Python agent — talks to it the same way, over
stdio, without knowing Ruby exists.

```sh
gem build mud_manager.gemspec
gem install ./mud_manager-0.2.0.gem   # puts `mud-manager` on PATH

MUD_HOST=localhost MUD_PORT=4000 MUD_NAME=Dummy MUD_PASSWORD=yourpassword \
  mud-manager --mcp
```

That's a JSON-RPC 2.0 / MCP stdio server (`initialize` → `tools/list` →
`tools/call`, protocol `2025-06-18`) — it reads requests off stdin and writes
responses to stdout, so it's meant to be spawned by a host, not run by hand.
Point boukensha at it via `mcp_servers:` in `settings.yaml`:

```yaml
mcp_servers:
  mud:
    command: mud-manager
    args:    [--mcp]
    prefix:  tbamud
    env:
      MUD_HOST:     localhost
      MUD_PORT:     4000
      MUD_NAME:     Dummy
      MUD_PASSWORD: yourpassword
```

**Tool surface** (`lib/mud_manager/tool_catalog.rb`): every public method on
`Primitives` is reflected into an MCP tool automatically — no hand-maintained
tool list, so a new primitive is a new tool for free. A couple of small
hand-authored tables sit on top of that reflection where the method signature
alone doesn't say enough:

- `ENUM_PARAMS` mirrors the same constants (`DIRECTIONS`, `POSITIONS`, ...)
  `Primitives#check_enum!` already validates against, so the JSON Schema and
  the runtime check can't drift apart.
- `DEFAULTS` gives ergonomic defaults for parameters an agent will usually
  omit — `attack` requires a style, but "kill" is what an agent means by
  "attack" almost every time, so it's optional on the tool even though
  `Primitives.attack` itself requires it.
- `NORMALIZERS` cleans up argument combinations that are valid MCP input but
  build a broken MUD command — e.g. `look` with `preposition: "at"` and a
  blank `target` degrades to a plain `look` instead of literally sending the
  invalid `"look at"` to the game.

**Sessions** (`lib/mud_manager/mcp_server.rb`): one daemon process can hold
more than one logged-in character. If `MUD_NAME`/`MUD_PASSWORD` (and
optionally `MUD_HOST`/`MUD_PORT`) are present in the environment at startup,
a `"default"` session logs in eagerly — the common case, and what every
gameplay tool call acts on when `session_id` is omitted. Two extra tools,
`connect` and `disconnect`, open and close additional sessions under a chosen
id, so one daemon can drive several characters at once instead of needing one
OS process per character.

**Testing without a live MUD**: `lib/mud_manager/fake_mud.rb` is a minimal
in-process stand-in that speaks just enough of the real login dance (see
`Session#login`) to exercise the whole path — spawn, handshake, `tools/list`,
`tools/call` — with no network dependency. `week1_baseline/ruby/10_standard_tool_library`'s
test suite (`test/test_mcp_client.rb`, `test/test_tools_mcp.rb`,
`test/test_mcp_servers_config.rb`) uses it as the "some MCP server" fixture
for boukensha's generic MCP-host layer.

**Real-server quirks found while wiring this up against a live tbaMUD**
(kept here because they're MUD-protocol-shaped, not transport-shaped — the
transport worked correctly the whole time):

- A brand-new character name goes through an entirely different flow than
  `Session#login` implements (name confirmation, password creation, sex,
  class, ...). `Session#login` is, by design, only for an *existing*
  character — creating one is still a manual/interactive step.
- An abrupt disconnect (closing the socket without sending `quit`, which is
  exactly what `Session#close` does) leaves the character linkdead in the
  game rather than logged out. The next login for that name gets
  `"Reconnecting."` instead of the normal menu, and (until fixed)
  `Session#login`'s `read_until` left the status line/prompt sent right
  after `"Reconnecting."` unread in the buffer — the same instance of the
  general problem below, in login's reconnect branch specifically. Fixed
  there by draining that leftover with `read_until_prompt` before `login`
  returns on the reconnect path.
- **General case of the above, not specific to reconnecting**: CircleMUD
  pushes unsolicited text at any time, independent of anything the client
  sends — broadcasts, other players' visible actions, room spec_procs —
  each followed by its own freshly re-displayed prompt. `send_command` +
  `read_until_prompt` back to back is unsafe: `read_until_prompt` matches
  the *first* `"> "` in the buffer with no way to tell "the prompt that
  terminates my command's response" apart from "a prompt already sitting
  there because something unrelated arrived earlier." If any is buffered
  when `read_until_prompt` runs, its trailing prompt gets matched instead of
  the real one, the command's actual response becomes the leftover for the
  *next* call, and that shift never self-corrects — every later exchange for
  the rest of the session inherits the previous one's real output, one
  message behind. Observed live: a delayed login-arrival broadcast
  (`"A booming voice announces, 'Welcome Dummy to the realm!'"`) caused every
  subsequent tool call in a session to return the *previous* call's real
  result. Fixed with `Session#command(input)` — `drain`, then
  `send_command`, then `read_until_prompt` — used by `McpServer` for every
  tool dispatch instead of the raw two-step sequence. Draining immediately
  before sending guarantees anything already buffered predates (and can't
  belong to) the command about to be issued. Not airtight — CircleMUD's
  plain telnet has no per-request correlation id, so a message landing in
  the microseconds between drain and send is still possible — but it turns
  what was a permanent, session-long misattribution into, at worst, one
  corrupted response that the next command's own drain immediately clears.
