## Preweek Technical Documentation 

## Technical Goal
The goal is to build a baseline agent that has all the common components of building any kind of agent

## Technical Uncertainty


## Technical Hypothesis


## Technical Observations

**Agent Loop**
- OpenAI requires content to be string and not null
- Running examples on model gpt-4o-mini, Agents start wonder to search in random paths, open random files (fail to read README.md) 
- Increased to model gpt-5.4-mini, Agents successin 2 iterations
- Reduced back to gpt-4o-mini but add to prompt: ".. README.md in the current folder...", Agents success in 3 iterations

**Interacting via MudManager**

> We need a solution that allows communcation between various programming language to MUD Manager despite it being written in Ruby

**MCP server for MudManager (generic Python/Ruby interfacing)**
- Explored 4 options for letting a future Python agent drive the same MUD session as boukensha (per-language wrapper, CLI+shell-exec, custom protocol, MCP) — see [`docs/plans/mud_manager/generic_interfacing.md`](../plans/mud_manager/generic_interfacing.md). MCP won: boukensha's side (`Boukensha::Mcp::Client`, `Boukensha::Tools::Mcp`, `mcp_servers:`) was already built and generic, the gap was only that `mud_manager` had no MCP *server*.
- Built `mud-manager --mcp` in `week0_explore/mud_manager`: reflects every `MudManager::Primitives` method into an MCP tool automatically (no hand-maintained tool list), plus `connect`/`disconnect` so one daemon process can hold more than one logged-in character.
- Confirmed `Boukensha::Mcp::Client`/`Boukensha::Tools::Mcp` are genuinely server-agnostic (no MUD-specific code anywhere in either file) — the only thing missing to plug in a *different* MCP server is a different `mcp_servers:` entry. Real limits on "generic" worth remembering: stdio transport only, tools only (no resources/prompts/sampling), tools fetched once at spawn (no `tools/list_changed`), every schema param currently advertised as required, non-text content blocks dropped.
- Debugging the full agent run surfaced three unrelated, stacked failures before it worked end-to-end — worth recording because each one produced the *same* symptom ("I don't have an active MUD connection" / "server closed the connection") for a completely different reason:
  1. `.boukensha/settings.yaml` still had the pre-MCP-rewrite `mud:` block instead of `mcp_servers:` → zero tools registered, no error at all.
  2. `mud_manager` gem was never built/installed, so `mud-manager` wasn't on `PATH` → `Errno::ENOENT`.
  3. The real bug: `Boukensha::Mcp::Client` spawns servers via `Open3.popen3(env, *cmd)`, which only *adds* env vars — it never clears the parent's own Bundler state. Since the launcher scripts run under `bundle exec`, the spawned `mud-manager` child inherited `BUNDLE_GEMFILE`/`BUNDLE_LOCKFILE`/`BUNDLER_VERSION` pointing at boukensha's *own* Gemfile (which doesn't list `mud_manager`), so Bundler refused to resolve the child's executable and it died before printing anything. Fixed by stripping every `BUNDLE_*`/`BUNDLER_*`/`RUBYOPT` var before spawning (a server is an independent process, not part of whatever bundle launched it) and by surfacing the child's stderr in the client's error message — that second part alone would have cut the diagnosis time from hours to seconds.
- Diagnosing against the *real* tbaMUD server (not the FakeMud fixture) surfaced two protocol-shaped quirks that have nothing to do with MCP: a brand-new character name goes through a totally different flow than `Session#login` implements (name confirm → new password → sex → class...), and an abrupt disconnect (no `quit` sent) leaves a character linkdead, so the next login gets `"Reconnecting."` instead of the normal menu. `Session#login` already handled reconnecting correctly; it was never designed to handle character creation.
- Found a live bug once the MUD connection itself worked: the LLM called `look(target: "", preposition: "at")`, which `Primitives.look` turns into the literal (invalid) command `"look at"` — the MUD correctly replied "Look at what?". Fixed at the tool-dispatch layer (`ToolCatalog::NORMALIZERS`), not in `Primitives` — `preposition` without a real `target` now degrades to a plain `look` instead of being forwarded verbatim.


**Tasked with "Log in as dummy and find and defeat the Big Minotaur in the Newbie Zone"**
- Agents does not have a plan for this objective, starts wandering at random directions
- Agents uses a wide range of commands
- Some commands were off - throwing errors but agents ignore:
  - tbamud__info_world(kind: "who", filter: "minotaur", session_id: "default") -> throws: Usage: who [minlev[-maxlev]] [-n name] [-c classlist] [-k] [-l] [-n] [-q] [-r] [-s] [-z]
- Terminal feed back to each command was 1 off AKA answer of the current panel actualy belongs to the previous one - NEED FIX

> There is no plan, all commands (tools) are randomly called and reached to destination

**Read returned text from MUD incorrect**
The MUD's reply, as returned to the tool: ".\r\n\r\n21H 100M 77V (news) (motd) > " — that's a leftover status-line fragment, not a room description. The model reported exactly what it was given — it didn't hallucinate, it accurately summarized garbage input.

Why the reply is garbage: this "dummy" character has been left linkdead by every abrupt disconnect across all our testing (Session#close never sends quit). So the daemon's eager startup login goes through Session#login's "Reconnecting" branch:

output = self.read_until(/Welcome|Reconnecting|Wrong password/i)
if output =~ /Reconnecting/i
  # already in-world, skip menu
elsif output =~ /Welcome/i
  ...

read_until only consumes text up to and including the matched pattern — it matches the word "Reconnecting" itself, not the trailing period or anything after it. The real server sends something like "Reconnecting.\r\n\r\n21H 100M 77V (news) (motd) > " in one chunk; the regex match ends right after "Reconnecting", so everything from the period onward — ".\r\n\r\n21H 100M 77V (news) (motd) > " — is left sitting unconsumed in Session's internal buffer. The "Reconnecting" branch does nothing further and just returns; nothing drains that leftover text.

Then the daemon proceeds to the main loop. The first gameplay tool call (look) does session.send_command(command) followed by session.read_until_prompt, which is read_until("> ") — it matches the first "> " in the buffer, which is the leftover reconnect-banner's own prompt, not anything produced by look. So the tool call returns stale banner text, while the MUD's actual reply to "look" (the real room description) arrives moments later and just sits in the buffer, unread — silently misattributed to whatever the next tool call happens to be, if there is one.

This only happens on the reconnect path — the "Welcome" (fresh menu login) branch already explicitly drains everything with read_until_quiet before returning, so it doesn't have this problem. It's specific to elsif output =~ /Reconnecting/i doing nothing.

**MUD Exploration**
- Agent is using the `look` command instead of `send_raw`
- When stuck in a pitch black room, cant get out, but agent can tell they it needs a light source and did check inventory
- When perform 'info' agent can't quit the the info page despite having clear instruction from MUD: [ Return to continue, (q)uit, (r)efresh, (b)ack, or page number (1/3) ]
    and reasonal thought process: To proceed, I need to exit the pager first:
      - press `q` to quit the info page, or
      - `r`/`return` to continue reading, then `q`



## Technical Conclusions


- MCP earns its complexity here: the alternative was N reimplementations of the hardest part of `mud_manager` (telnet/IAC handling, the login state machine), one per agent language. Reflecting `Primitives` into tools automatically means the daemon's tool surface can never drift from what the gem actually supports — a new primitive is a new tool for free, in every language, without touching the daemon.
- "It works when I run it directly" and "it works when the real host runs it" are different claims — the bundler-env-leak bug only reproduced under `bundle exec`, which is exactly how the shipped launcher scripts invoke everything. Isolate-testing a spawned subprocess in the same shell you're debugging from isn't sufficient; it has to be spawned the same way the real caller spawns it.
- A generic transport (MCP) does not make the thing behind it generic. The MUD-specific bugs (new-character flow, linkdead reconnects, `look`'s preposition/target coupling) all live one layer below MCP, in `Primitives`/`Session`/`ToolCatalog` — the protocol choice never had to change to fix any of them.


## Key Takeaway
[todo]