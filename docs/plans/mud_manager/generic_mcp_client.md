# The Generic MCP Client (boukensha)

This documents `Boukensha::Mcp::Client` and `Boukensha::Tools::Mcp` —
`week1_baseline/ruby/10_standard_tool_library/lib/boukensha/mcp/client.rb` and
`lib/boukensha/tools/mcp.rb`. This is the *client* (host) side of the MCP
integration; the *server* side (`mud-manager --mcp`) is documented in
`week0_explore/mud_manager/README.md`. The options analysis that led here is
in [`generic_interfacing.md`](generic_interfacing.md).

## What it is

Boukensha ships **no tools of its own**. Every tool an agent can call comes
from an MCP server declared in `settings.yaml`'s `mcp_servers:` block. The two
classes here are what make that possible, and neither one knows what a MUD
is — `mud-manager` is registered by the exact same code path as a filesystem
server, a Slack server, or anything else that speaks MCP over stdio.

```
settings.yaml (mcp_servers:)
        │
        ▼
Boukensha.register_mcp_servers        (lib/boukensha.rb)
        │  for each entry: command / args / env / prefix / required
        ▼
Boukensha::Tools::Mcp.register        (lib/boukensha/tools/mcp.rb)
        │  spawns a client, walks its tools, registers each one
        ▼
Boukensha::Mcp::Client                (lib/boukensha/mcp/client.rb)
        │  JSON-RPC 2.0 over stdio: initialize → tools/list → tools/call
        ▼
   <the server subprocess>            (mud-manager --mcp, npx ..., etc.)
```

## `Boukensha::Mcp::Client`

A minimal MCP-over-stdio client. Three responsibilities:

1. **Spawn.** `Client.spawn(command:, args: [], env: {})` runs
   `Open3.popen3` on `[command, *args]`, with `env` merged into the child's
   environment (string keys and values only — `env.each_with_object({}) {
   |(k,v), h| h[k.to_s] = v.to_s }`).
2. **Handshake.** `initialize` is sent with `protocolVersion:
   "2025-06-18"` (`PROTOCOL_VERSION`), empty `capabilities`, and a
   `clientInfo` of `{name: "boukensha", version: Boukensha::VERSION}`.
   The response's `serverInfo` is stored on `#server_info`. A
   `notifications/initialized` notification (no `id`, no reply expected)
   follows, per the spec.
3. **Discover and call tools.** `tools/list` is fetched once, right after
   the handshake, and cached on `#tools` (an array of raw
   `{"name" =>, "description" =>, "inputSchema" =>}` hashes — untouched
   MCP wire format, not yet anything boukensha-shaped). `#call_tool(name,
   arguments = {})` sends `tools/call` and normalizes the result to
   `{text:, error:}` — `text` is every `content` block's `"text"` field
   joined with `\n` (non-text blocks, e.g. images, are silently dropped —
   they contribute nothing rather than raising), `error` is
   `result["isError"]` coerced to a boolean.

`#close` closes stdin (signals EOF to the server), waits on the child
(`@wait.value`), then closes stdout/stderr. Every step is best-effort
(`rescue nil`) since by the time you're closing, the server may already be
gone.

### Request/response plumbing

Requests get a monotonically increasing integer `id` (`@id += 1`). `write`
serializes one JSON object per line to stdin and flushes immediately — MCP's
stdio transport is newline-delimited JSON, not a length-prefixed frame.
`read_until(id)` reads lines from stdout in a loop, parses each as JSON, and
returns the first one whose `"id"` matches; anything else (a
notification, or a stale/mismatched id) is silently skipped. This means the
client is **synchronous and single-flight** — one request is outstanding at a
time, `call_tool` blocks until its specific response arrives.

If `@stdout.gets` returns `nil` (the child closed its stdout — crashed, exited,
or otherwise died), `read_until` raises `Error, "server closed the
connection"`. It also opportunistically reads whatever the child had written
to stderr (`read_nonblock(8192)`, best-effort) and appends it to the error
message — a child that died with a real Ruby exception surfaces that
exception's text instead of a bare "closed the connection", which is the
difference between diagnosing a spawn failure in seconds versus needing to
reproduce it by hand.

### Environment sanitization (`clear_bundler_env!`)

This is not part of the MCP spec — it's a fix for a boukensha-specific
footgun discovered while wiring up `mud-manager`. `Open3.popen3(env, *cmd)`
only *adds*/*overrides* environment variables on top of whatever the parent
process already has; it does not clear anything. If boukensha itself is
running under `bundle exec` (as every step's `bin/` launcher script does),
the spawned server subprocess inherits the parent's Bundler state —
`BUNDLE_GEMFILE`, `BUNDLE_LOCKFILE`, `BUNDLER_VERSION`, `RUBYOPT`'s
`-rbundler/setup`, and friends. If the server is a *different* gem not listed
in boukensha's own `Gemfile` (`mud_manager`, say), Bundler refuses to resolve
its executable at all and the child dies before writing a single byte — which
without the stderr-surfacing fix above showed up as an opaque "server closed
the connection".

The fix, in `initialize` before spawning: every key in the *current*
process's `ENV` that starts with `BUNDLE_` or `BUNDLER_`, plus `RUBYOPT`, gets
set to `nil` in the child's env hash (Ruby's `Process.spawn`/`Open3.popen3`
treat a `nil` value as "delete this variable for the child") — unless the
caller's own `env:` argument already sets that key, which always wins. The
set is computed dynamically from what's actually present rather than a fixed
list, because which exact variable names a given Bundler version uses has
already changed once within this project (older versions leaned on
`RUBYOPT`; the version this repo hit also uses `BUNDLE_LOCKFILE` and
`BUNDLER_VERSION`/`BUNDLER_SETUP` independent of `RUBYOPT`).

**Takeaway for anyone spawning MCP servers from inside a `bundle exec`'d Ruby
process elsewhere:** a server is an independent process, not part of
whatever bundle happens to be launching it. Don't assume `Open3.popen3`'s
`env` argument gives you a clean slate — it doesn't.

## `Boukensha::Tools::Mcp`

Turns a spawned client's tool list into actual boukensha tools.

```ruby
Boukensha::Tools::Mcp.register(
  registry, command: "mud-manager", args: ["--mcp"],
  env: { "MUD_HOST" => "localhost" }, prefix: "tbamud"
)
```

- `.register(registry, command:, args:, env:, prefix:)` spawns a `Client`,
  registers an `at_exit` hook to close it when the process exits, and
  delegates to `.register_client`. Returns the `Client` (so callers, and
  tests, can still call `.close` explicitly or inspect `.tools`/`.server_info`
  without waiting for process exit).
- `.register_client(registry, client, prefix:)` walks `client.tools`, and for
  each one calls `registry.tool(local_name, description:, parameters:) {
  |**kwargs| ... }` — `registry` just needs to respond to `#tool` and
  optionally `#tool_names` (a `Registry` or the `RunDSL` object satisfy
  this). The registered block calls back into `client.call_tool`, forwarding
  boukensha's symbol-keyed kwargs as the string-keyed hash the wire format
  wants, and returns the tool's text (or `"error: <text>"` if `isError` was
  set) as a plain string — boukensha's tool-call contract.
- **Prefixing is client-side policy, not part of the protocol.**
  `prefixed(name, prefix)` joins `prefix` and the server's own tool name with
  `__` (e.g. `tbamud__look`). The server is called with its own bare name
  (`look`) on every `tools/call` — it never hears about the prefix. This
  exists so two servers with overlapping tool names (`look`, say, from a MUD
  and a text-adventure filesystem server) don't collide; a `nil`/blank
  `prefix` just uses the bare name.
- **A name collision is always fatal**, even for a server marked
  `required: false` in config — `CollisionError` (an `ArgumentError`
  subclass) is raised regardless. The reasoning: an unreachable *server* is
  an environment problem the config author anticipated (that's what
  `required: false` is for); two tools claiming the same *name* is a
  contradiction in the config itself, and silently dropping the loser would
  be the single worst way to resolve it — it fails silently and looks like
  the tool exists.
- `to_boukensha_params(input_schema)` converts an MCP `inputSchema` (JSON
  Schema `{"type": "object", "properties": {...}}`) into boukensha's
  `{name => {type:, description:}}` parameter shape. Every property is
  listed — including ones the server's schema marks optional — because
  boukensha doesn't yet distinguish required from optional in what it tells
  the LLM (see Known Limitations). If a property has an `"enum"`, its
  allowed values get appended to the description text as `"(one of: a, b,
  c)"`, since that's the only place boukensha's tool-calling surface has to
  put it.

## Wiring: `mcp_servers:` in `settings.yaml`

```yaml
mcp_servers:
  mud:
    command: mud-manager
    args:    [--mcp]
    prefix:  tbamud
    env:
      MUD_HOST:     your.mud.host
      MUD_NAME:     Gandalf
      MUD_PASSWORD: your-password

  filesystem:
    command:  npx
    args:     [-y, "@modelcontextprotocol/server-filesystem", /tmp]
    prefix:   fs
    required: false          # can't start? warn and continue without its tools
```

Parsed by `Boukensha::Config#mcp_servers` (`lib/boukensha/config.rb`) into
`{name => {command:, args:, env:, prefix:, required:}}` with defaults applied
(`args: []`, `env: {}`, `prefix: nil`, `required: true`). `env` values are
always stringified, since YAML hands back an `Integer` for something like
`MUD_PORT: 4000` but the spawn environment only accepts strings.

`Boukensha.register_mcp_servers(registry, cfg)` (`lib/boukensha.rb`, private,
called from both `.run` and `.repl`) iterates every entry and calls
`Tools::Mcp.register`:

- A `required: true` (default) server that fails to spawn/handshake raises
  `RuntimeError, "boukensha: MCP server '<name>' failed to start: <message>"`
  and takes the whole agent process down with it — you asked for those
  tools, so silently continuing without them would be a worse failure mode
  than crashing loudly.
- A `required: false` server that fails to spawn instead prints `[boukensha]
  optional MCP server '<name>' failed to start: <message> — continuing
  without its tools` and the agent proceeds with whatever else registered.
- A `CollisionError` is **never** downgraded by `required: false` — see
  above.
- The return value is `{server_name => tool_count}`, used for the startup
  banner ("what can this agent actually do") since without at least one
  server it can do nothing at all.

## Known limitations

These don't affect `mud-manager --mcp` (a tools-only, text-only, stdio
server with a static tool list), but they're the actual boundary of "any MCP
server," not a theoretical one — worth knowing before pointing this client at
something that leans on the rest of the spec:

| Limitation | Detail |
|---|---|
| stdio transport only | No HTTP/SSE. Only servers that can run as a local subprocess. |
| Tools only | `initialize` sends `capabilities: {}`. No `resources/list`, `prompts/list`, sampling, roots, or elicitation. |
| Static tool list | `tools/list` is fetched once, right after the handshake. A `notifications/tools/list_changed` from the server is never handled — tools added after startup are invisible until the process is restarted. |
| Every schema property is "required" | `to_boukensha_params` doesn't read `inputSchema["required"]`; boukensha currently tells the LLM every listed parameter is mandatory, even genuinely-optional ones on third-party servers. Fixing this touches `Boukensha::Tool` itself, not just this file. |
| Non-text content is dropped | Image/embedded-resource content blocks in a `tools/call` result contribute nothing to `#call_tool`'s `text` — no error, just absence. |
| Protocol version is hardcoded | `PROTOCOL_VERSION = "2025-06-18"` is sent, not negotiated. A server expecting strict adherence to a different version isn't accounted for. |
| Single-flight, synchronous | One in-flight request at a time; no concurrent tool calls to the same server. |

## Testing

`week1_baseline/ruby/10_standard_tool_library/test/`:

- `helper.rb` — `McpTestHelper#start_fake_mud` spawns
  `MudManager::FakeMud` (from the sibling `week0_explore/mud_manager`
  package) as the "some MCP server" fixture; tests `skip` if that package
  isn't checked out rather than failing.
- `test_mcp_client.rb` — exercises `Boukensha::Mcp::Client` directly:
  handshake reports `server_info`, `tools/list` discovery, `call_tool`
  reaching the (fake) MUD and getting real text back, a tool-level failure
  coming back as `isError` data rather than an exception, and spawning a
  nonexistent command raising `Errno::ENOENT`.
- `test_tools_mcp.rb` — exercises `Boukensha::Tools::Mcp`: registration
  populates the registry, prefixing is applied locally while the server only
  ever sees bare names, a `nil` prefix yields bare names, enum values show up
  in a parameter's description, and both collision cases (two MCP servers,
  and an MCP server against a tool boukensha registered itself) raise.
- `test_mcp_servers_config.rb` — exercises the `settings.yaml` → `Config` →
  `register_mcp_servers` path: defaults get applied, an absent block yields
  `{}`, a required server that fails to spawn raises with a message naming
  it, an optional one warns and continues, a collision is never excused by
  `required: false`, and the returned per-server tool-count summary is
  correct. The `filesystem:` entry in these tests exists specifically to
  prove the config layer treats an unrelated server identically to `mud:` —
  no special-casing anywhere.

Run with `rake test` from `week1_baseline/ruby/10_standard_tool_library`.

## See also

- [`generic_interfacing.md`](generic_interfacing.md) — why MCP was chosen
  over a per-language wrapper, a CLI, or a custom protocol.
- `week0_explore/mud_manager/README.md` — the server side (`mud-manager
  --mcp`): tool reflection off `Primitives`, multi-session support, the
  `FakeMud` test fixture, and MUD-protocol-shaped quirks found while testing
  against a live server.
- `docs/journal/1_week1.md` — the debugging session that found the
  Bundler-env-leak bug and the `look` argument-normalization bug documented
  above.
