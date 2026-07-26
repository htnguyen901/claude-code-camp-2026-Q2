# Plan: Replace filesystem subagent with `AgentDefinition` (Claude Agent SDK)

## Context

`03b_subagent_sdk` is currently an exact copy of `03a_subagent_sdk`: the
`mud-player` subagent is defined purely on disk as
`.claude/agents/mud-player.md` (YAML frontmatter `name`/`description`/`tools`
+ a markdown body used as the subagent's system prompt), and it only runs
inside the Claude Code CLI harness, which auto-discovers it from the
filesystem. There is no SDK driver script here yet — `scripts/mud_client.py`,
`mud_cmd.py`, and `mud_daemon.py` are plain Python (telnet client / unix
socket daemon) with zero dependency on Claude Code or the Agent SDK; they're
just the tool the subagent shells out to via `Bash`.

Per `docs/explore_architectures.md`, 03a is "Filesystem Subagents driven by
coding harness" and 03b is meant to be "Agent SDK" — i.e. the same
mud-player behavior, but the subagent is defined **programmatically** via
`AgentDefinition` in a Python script using `claude_agent_sdk`, instead of
being auto-loaded from `.claude/agents/*.md`.

## Goal

Add a Python driver script in `03b_subagent_sdk` that:
- Defines the `mud-player` subagent in code via `AgentDefinition` (same
  description/prompt/tools content that currently lives in
  `.claude/agents/mud-player.md`).
- Runs a top-level SDK session (`ClaudeAgentOptions` + `ClaudeSDKClient`)
  where the orchestrator delegates to that subagent for MUD interaction.
- Does **not** rely on Claude Code's filesystem agent auto-loading, so the
  behavior in 03b is attributable entirely to the SDK config, not to a
  `.claude/agents/*.md` file sitting around.

## Proposed changes

### 1. New dependency

Add `claude-agent-sdk` (PyPI) to a `requirements.txt` in
`03b_subagent_sdk/` (there's currently no manifest at all in this repo for
Python deps). Note: this sandbox's `python3` currently has no `pip` module
installed, so getting a working environment (`python3 -m ensurepip`, or a
venv, or `uv`) is a prerequisite step before the script can actually be run
and tested — flagging this so it's not a surprise mid-implementation.

### 2. New driver script — `scripts/agent_sdk_runner.py`

```python
from claude_agent_sdk import AgentDefinition, ClaudeAgentOptions, ClaudeSDKClient

MUD_PLAYER_PROMPT = """<body of current .claude/agents/mud-player.md,
verbatim - the "Players" / "MUD Player Agent" / tool usage / memory /
navigation / combat / goal-pursuit instructions>"""

mud_player = AgentDefinition(
    description=(
        "Play tbaMUD running on localhost:4000 - explore, fight, shop, "
        "talk to NPCs, and pursue open-ended goals like 'reach level 7' "
        "or 'find and defeat the goblin king' ... (same description text "
        "as the current frontmatter)"
    ),
    prompt=MUD_PLAYER_PROMPT,
    tools=["Bash", "Read", "Edit"],
)

options = ClaudeAgentOptions(
    agents={"mud-player": mud_player},
    allowed_tools=["Task"],       # orchestrator only needs to delegate
    setting_sources=[],           # do NOT auto-load .claude/agents/*.md
    cwd=".",                      # so Bash calls to scripts/mud_cmd.py resolve
)

async def main(goal: str):
    async with ClaudeSDKClient(options=options) as client:
        await client.query(goal)
        async for message in client.receive_response():
            ...  # print/stream text blocks
```

Invocation: `python3 scripts/agent_sdk_runner.py "reach level 7 and defeat
the goblin king"` — one CLI arg as the goal/instruction, mirroring how the
03a harness is driven today by typed requests.

**Open question:** the exact `AgentDefinition`/`ClaudeAgentOptions` field
names and `setting_sources` default behavior above are from memory and
should be double-checked against the installed SDK version's actual API
(e.g. via the `claude-code-guide` agent or the installed package's
docstrings) before writing real code, rather than assumed correct.

### 3. Retire the filesystem definition

Since `setting_sources=[]` means `.claude/agents/mud-player.md` won't be
picked up by the SDK run regardless, decide one of:

- **(A) Delete** `.claude/agents/mud-player.md` in 03b entirely, so the
  directory unambiguously demonstrates "subagent defined in code" with no
  leftover file that could confuse a reader about which mechanism is
  actually in effect.
- **(B) Keep** the file as reference/documentation (e.g. rename to
  `.claude/agents/mud-player.md.reference` or move under `references/`),
  with a comment that it's superseded by `agent_sdk_runner.py`.

Recommendation: **(A)**, to keep the 03a/03b contrast clean — but flagging
for your call since it's a one-line decision either way.

### 4. Leave untouched

- `scripts/mud_client.py`, `mud_cmd.py`, `mud_daemon.py` — the actual MUD
  I/O layer doesn't change; it's invoked identically via `Bash` regardless
  of whether the calling agent was filesystem-defined or code-defined.
- `data/*.md`, `references/commands.md` — subagent memory/reference files,
  unaffected by this change.
- `evals/evals.json` — prompts are harness-agnostic already; no changes
  needed there.

### 5. Testing

- Run one short one-shot command (`"look around"`) to confirm the SDK
  session boots, delegates to `mud-player`, and gets a real MUD response
  through the existing daemon.
- Run one longer goal-style prompt to exercise memory read/update behavior
  identically to what was observed in 03a.
- Record findings under `## 3b. Agent SDK` → `### Technical Conclusions`
  in `docs/explore_architectures.md` (currently empty), particularly any
  *difference* from 03a's behavior attributable to the SDK path itself
  (e.g. token usage, reliability, how delegation/`Task`-tool invocation
  feels vs. automatic harness dispatch).

## Open questions for you

1. Python SDK vs TypeScript SDK — going with Python since all existing
   tooling here is Python and there's no `package.json`/`node` in this
   directory. Confirm that's the intent.
2. Delete vs. keep the old `.claude/agents/mud-player.md` (see §3, A vs B).
3. One-shot `query()` per invocation (matches `mud_cmd.py`'s
   call-once-per-Bash-invocation model) vs. a persistent
   `ClaudeSDKClient` session kept open for a whole multi-turn goal — which
   fits the intended comparison with 03a better?

## Answer to above questions:
1. Yes go with Python
2. We want the full replacement so can delete if not needed
3. A persistant session (interactive loop)