Our MUD Manager is written in Ruby.
In this project I'd like to implement my agents in Python

What is the solution?
- We have to create weapper per lang (in this case Python)
- We make MudManager a command line tool, and other langs execute shell commands in their lang
- We implement a communication protocol
- We implment MCP as a layer

Consider that the Mud Manager is managing the sessions for the MUD.

## Technical Exploration

### Constraints

- `MudManager::Session` (week0_explore/mud_manager) isn't stateless — it holds a
  live TCP/telnet socket plus a background reader thread and buffer. The whole
  point of that design is that the connection survives across many tool calls
  without re-logging-in. Whatever cross-language solution we pick has to
  preserve that: one login, many calls.
- We only want **one** implementation of CircleMUD session handling
  (telnet/IAC stripping, login dance, prompt detection). Reimplementing
  `Session`/`Primitives` per language duplicates the trickiest part of this
  codebase (see the IAC stripper and `read_until_prompt` in `session.rb`) and
  guarantees the ports drift.
- Ruby's own agent (`boukensha`) already had to solve "how does an agent
  process, which may be restarted, get tools backed by a persistent MUD
  session" — Python isn't a new instance of this problem, it's the same
  problem asked twice.

### Options considered

1. **Wrapper per language** (reimplement `Session`/`Primitives` in Python,
   later Go/Rust/whatever) — rejected. Duplicates the login/telnet/buffering
   logic that's the hard part of `mud_manager`, and every new language means
   another copy to keep in sync with CircleMUD's actual behavior.
2. **CLI tool + shell exec** (`mud-manager look`, `mud-manager attack orc`,
   one process per command) — rejected on its own. A new OS process per
   command can't hold the persistent socket that `Session` exists to provide;
   we'd immediately need a *second* long-lived process behind the CLI to hold
   the connection, which is really option 4 with extra steps.
3. **Custom communication protocol** (bespoke JSON-lines or a raw socket
   protocol we design) — rejected. We'd be re-inventing request framing, tool
   discovery/schema, and error semantics that an existing standard already
   provides, and we'd still have to hand-write a client for every language.
4. **MCP as the layer** — recommended, and it's what the Ruby side already
   built and tested against (`Boukensha::Mcp::Client`,
   `Boukensha::Tools::Mcp`, `mcp_servers:` in `settings.yaml`, all in
   `week1_baseline/ruby/10_standard_tool_library`). MCP over stdio gives us
   process-boundary tool discovery (`tools/list`) and invocation
   (`tools/call`) for free, in a form every agent SDK (and a ~100-line
   hand-rolled client, see `lib/boukensha/mcp/client.rb`) already knows how to
   speak.

### Recommended architecture

- `MudManager` gains a `bin/mud-manager` executable with a `--mcp` mode: a
  JSON-RPC 2.0 stdio server (`initialize` → `tools/list` → `tools/call`,
  same protocol version boukensha's client already targets:
  `2025-06-18`).
- **One OS process = one persistent `Session` = one logged-in character.**
  The daemon calls `Session#login` once at startup and keeps the socket open
  for the daemon's whole lifetime; this is what "MudManager manages the
  session" (line 10) means in practice — the session lives in the daemon, not
  in whatever process is calling it, so it's reachable by a Ruby agent, a
  Python agent, or anything else that can spawn a subprocess and speak
  JSON-RPC over stdin/stdout.
- Tool surface: every public method in `MudManager::Primitives` becomes an
  MCP tool. The enum constants already there (`DIRECTIONS`, `POSITIONS`,
  `ATTACK_STYLES`, ...) map directly to JSON Schema `enum` fields in each
  tool's `inputSchema` — this is the same shape
  `Boukensha::Tools::Mcp.to_boukensha_params` already expects from a server,
  so no change needed on the Ruby agent side.
- `tools/call` dispatch: validate args through `Primitives` (an
  `ArgumentError` becomes `isError: true` + message, not a crash), build the
  `Command`, send it via `Session#send_command`, collect the reply via
  `read_until_prompt`/`read_until_quiet`, return the text as MCP tool content.
- Credentials (`MUD_HOST`/`MUD_PORT`/`MUD_NAME`/`MUD_PASSWORD`) travel as
  environment variables — the same `env:` convention `mcp_servers:` entries
  already use for every other server.

### What this means for Python (and any future language)

Nothing MUD-specific has to exist in Python at all. A Python agent becomes an
MCP *host* exactly like boukensha did: spawn `mud-manager --mcp` as a
subprocess (via the official `mcp` PyPI package, or a small hand-rolled stdio
JSON-RPC client mirroring `boukensha/mcp/client.rb`), do the `initialize`
handshake, call `tools/list`, dispatch `tools/call`. "Port to Python" stops
meaning "port `mud_manager`" — it only means "port the agent loop." This is
what makes the protocol *generic*: the daemon doesn't know or care what's on
the other end of stdio.

### Status: implemented

The gap below is closed. `week0_explore/mud_manager` now ships `bin/mud-manager
--mcp` (`lib/mud_manager/mcp_server.rb`, `lib/mud_manager/tool_catalog.rb`,
`lib/mud_manager/fake_mud.rb`), reflecting all 55 `Primitives` methods into MCP
tools plus `connect`/`disconnect` for the multi-session case (57 tools total).
`week1_baseline/ruby/10_standard_tool_library`'s previously-skipped MCP tests
now run for real against it (22 runs, 0 skips) and
`examples/mcp_mud_demo.rb --dry` exercises the full path end-to-end. Kept
below as the record of what was missing and why, since the reasoning still
explains the design.

### Status before implementation (for the record)

**Done and tested** (`week1_baseline/ruby/10_standard_tool_library`):
- `Boukensha::Mcp::Client` — generic MCP-over-stdio client (spawn, handshake,
  `tools/list`, `tools/call`), knows nothing about MUDs specifically.
- `Boukensha::Tools::Mcp` — registers any spawned server's tools into the
  agent's tool registry, with client-side name-prefixing and collision
  detection.
- `mcp_servers:` in `settings.yaml` — adding an MCP-backed capability is a
  config edit, not a code change.

**Missing** — the actual next implementation task, in
`week0_explore/mud_manager`, not in the agent layer:
- `bin/mud-manager` executable and its `--mcp` server mode described above.
- The `Primitives` → JSON Schema mapping that mirrors what
  `Boukensha::Tools::Mcp.to_boukensha_params` already assumes a server
  provides.
- `MudManager::FakeMud` — an in-process fake telnet server for offline/dry-run
  testing. Already referenced by
  `week1_baseline/ruby/10_standard_tool_library/test/helper.rb` (which
  `skip`s MCP tests when `bin/mud-manager` isn't found) and by
  `examples/mcp_mud_demo.rb --dry`, but the file doesn't exist yet.

This gap is already flagged (not yet fixed) in
`week1_baseline/ruby/10_standard_tool_library/README.md`'s "Technical
Observations" table, row 3: *"mud_manager gem has no bin/mud-manager / --mcp
mode / fake_mud yet — needs to be implemented before [settings.yaml's
`mcp_servers:`] can actually spawn anything."*

### Open questions / risks worth flagging before building

- **Concurrency model — resolved: yes, one daemon handles multiple
  sessions.** Every gameplay tool takes an optional `session_id` (default
  `"default"`, opened eagerly from `MUD_NAME`/`MUD_PASSWORD`/etc. at
  startup); `connect` opens additional sessions under a chosen id and
  `disconnect` closes them. Implemented in `McpServer#connect_session` /
  `#handle_connect` / `#handle_disconnect` (`lib/mud_manager/mcp_server.rb`).
  Sessions are held in a plain `Hash` guarded by a `Mutex` — fine for a
  handful of characters per daemon; would need revisiting if one process
  were expected to hold hundreds.
- **Existing-session collision**: CircleMUD prompts "already playing — kick
  the other connection?" on double-login, and neither `Session#login` nor the
  daemon has a way to answer that prompt yet (also flagged in the
  10_standard_tool_library README). This needs a decision independent of the
  transport choice — likely: daemon auto-answers "yes" and takes over, since
  it's meant to be the sole owner of the session.
- **Tool surface completeness**: `Primitives` is missing some verbs (thief
  commands, rest, per `ITERATIONS.md`). Orthogonal to the interfacing
  question, but any new primitive automatically becomes a new MCP tool once
  the mapping above exists — no separate Python-side work required.