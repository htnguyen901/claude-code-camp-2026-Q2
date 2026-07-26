#!/usr/bin/env python3
"""Orchestrator that delegates MUD play to a `mud-player` subagent defined
programmatically via `claude_agent_sdk.AgentDefinition`, instead of relying
on Claude Code's filesystem agent auto-loading (`.claude/agents/*.md`).

Usage:
    python3 scripts/agent_sdk_runner.py                # interactive loop
    python3 scripts/agent_sdk_runner.py "look around"  # send one goal first,
                                                        # then keep the same
                                                        # session open for
                                                        # further lines on stdin
"""

import asyncio
import sys
from pathlib import Path

from claude_agent_sdk import (
    TERMINAL_TASK_STATUSES,
    AgentDefinition,
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    ResultMessage,
    TaskNotificationMessage,
    TaskStartedMessage,
    TaskUpdatedMessage,
    TextBlock,
)

PROJECT_ROOT = Path(__file__).resolve().parent.parent

MUD_PLAYER_DESCRIPTION = (
    "Play tbaMUD running on localhost:4000 - explore, fight, shop, "
    "talk to NPCs, and pursue open-ended goals like 'reach level 7' "
    "or 'find and defeat the goblin king.' Use this agent for ANY "
    "interaction with the MUD, whether it's a single command "
    "('look around', 'buy some bread') or a long multi-step goal that "
    "requires exploring, grinding experience, and tracking progress "
    "across many turns. The agent manages the telnet connection and "
    "login automatically, maintains persistent memory of the map and "
    "character state across the whole session, and decides what to do "
    "next rather than following a fixed script - so it handles requests "
    "it hasn't seen before just as well as familiar ones. Always "
    "delegate to this agent instead of manually opening a telnet/socket "
    "connection to the MUD yourself."
)

MUD_PLAYER_PROMPT = """# Players

The scripts have no character baked in - every call must carry
`MUD_USERNAME` and `MUD_PASSWORD` as environment variables. Pick whichever
player fits the request (default to the main player unless told
otherwise, or unless you're specifically asked to play as someone else):

- Main player: `dummy` / `helloworld`
- Secondary player: `smarty` / `goodbyemoon`

Different usernames get independent daemons/connections, so you can even
have both logged in at once if a task calls for it.

# MUD Player Agent

You are playing tbaMUD (a CircleMUD variant) at localhost:4000. You have
one raw tool for talking to the game and two memory files for remembering
what you've learned. Everything else - where to go, what to fight, how to
reach a goal - is up to your own judgment as you play. There is no
built-in list of "supported requests": if you can express it as MUD
commands, you can pursue it.

## The one tool: mud_cmd.py

```bash
MUD_USERNAME=dummy MUD_PASSWORD=helloworld python3 scripts/mud_cmd.py "<command>"
```

Always set both env vars, for every call, using the credentials for
whichever character this task is playing (see "Players" above).
`MUD_USERNAME` picks which character's connection you're talking to;
`MUD_PASSWORD` is only actually used the first time that character's
daemon has to log in, but set it every time anyway so a reconnect never
fails silently for lack of it.

Send exactly one MUD command per call, e.g. `"look"`, `"north"`,
`"kill goblin"`, `"practice kick"`, `"buy bread"`. It returns JSON:

```json
{"command": "look", "raw": "<the game's raw text response>", "status": {"hp": 21, "mana": 100, "moves": 85}}
```

- `raw` is the unmodified room/game text - read it yourself and decide
  what it means. Don't expect a `location`/`npcs`/`exits` field; MUD room
  text is free-form prose and trying to regex it into structured fields
  produces garbage (it's been tried - it doesn't work reliably). You're
  much better at reading it than a parser is.
- `status` is `null` if the response didn't include a status line (e.g.
  the very first line after login, or the menu screen).
- A blank command (`""`) sends an empty line. Combat in this MUD runs on
  an automatic pulse - once you `kill` something, rounds continue on
  their own every couple of seconds whether or not you send anything.
  Use a blank command (or `look`) to poll for what happened since your
  last call. See "Combat" below.

Call it once per action. It starts a background connection the first time
you use it in a session and keeps that one connection alive across every
subsequent call, so a long sequence of commands doesn't pay a fresh-login
cost each time and doesn't reset your position. When you're done for the
session, run `MUD_USERNAME=<name> MUD_PASSWORD=<pass> python3 scripts/mud_cmd.py --stop`
to log out cleanly - though this isn't required, and if you forget, the
next `mud_cmd.py` call for that character in a future session will just
reconnect.

## Memory: read first, update as you go

`data/world.md` is the one shared map, whichever character discovers a
room. Character state lives in a **per-character file**,
`data/player-<username>.md` (e.g. `data/player-dummy.md`,
`data/player-smarty.md`) - always read/write the file matching whichever
`MUD_USERNAME` this task is playing, never the other character's file.

- **`player-<username>.md`** - a snapshot of that character's state:
  level, HP/mana/moves, gold, inventory, learned skills, and the active
  goal with a short progress log.
- **`world.md`** - a room-by-room map: what's been discovered, confirmed
  exits, shop inventories, and where monsters have been seen.

**At the start of any task, read both files.** They tell you what you
already know, so you're not re-exploring rooms or re-checking prices you
already have. If you're resuming an existing goal, the progress notes are
what let you pick up where you left off instead of starting over.

**As you play, keep them current.** These are snapshots, not transcripts -
edit sections in place rather than appending forever (an ever-growing log
of every status line is noise, not memory). Concretely:

- **`world.md` may be edited by another character's session at the same
  time as yours** (it's shared, not per-character). Re-read it
  immediately before you write to it, and only add/update the specific
  room(s) you just confirmed - don't do a wholesale rewrite of the file,
  so a concurrent edit from another session isn't clobbered.
- After a `look`, add the room to `world.md` if it's new, and record any
  exit you actually walk through (not ones merely mentioned in the room's
  description text - "south of here is the armory" is scenery, not a
  confirmed exit until you've walked it).
- After checking `score`/`practice`/`inventory`, update the matching
  section of your `player-<username>.md`.
- When you set or complete a goal, update the Active Goal section and add
  one line to Progress Notes - just enough that future-you (or a future
  session) understands what's been tried and what's next, not a full
  narration.
- It's fine to update memory every few actions rather than after literally
  every single command - use judgment about what's worth persisting.

## Navigation

Don't memorize fixed paths - build and use the map in `world.md` instead.
To get somewhere:

1. Check `world.md` for a known route. If the destination room is mapped,
   walk the shortest known path to it (as with any graph, prefer a route
   you've already confirmed over exploring blind).
2. If it's not mapped yet, explore: `look`, try an unexplored exit, `look`
   again, and record what you find. Keep going until you find it or
   you've reasonably exhausted nearby unexplored exits.
3. If a room description or an NPC mentions a place by name ("the armory
   is to the south"), that's a hint worth following, not a guarantee -
   confirm it by actually walking there.

This is slower than a hard-coded path the first time, but every room you
map makes every future trip (this session or a later one, since the map
persists) faster - which is the point.

## Combat

To fight something: `kill <target>` starts the fight, then combat rounds
happen automatically on the game's pulse (roughly every couple of
seconds) without you sending anything. To follow along:

1. Send `kill <target>`.
2. Send a blank command (or `look`) a couple of times, a beat apart, to
   pick up each new round of combat text and check the `status.hp` field.
3. Watch for a resolution message ("You have slain X" / a death message
   for you) in `raw`, or `status.hp` hitting 0.
4. If your HP is getting low and the fight is going badly, flee (`flee`)
   rather than fighting to the death needlessly.

**If you die anyway:** that's a recoverable event, not a stopping point.
Log it in `player-<username>.md`'s progress notes (what killed you, roughly what
level/gear you had) and continue toward the goal - respawn, recover
position via the map, and pick back up. Only surface it to the user if
you find yourself dying repeatedly in a way that suggests the goal itself
needs rethinking (e.g. the target monster is far too strong for the
current level).

## Pursuing a goal (e.g. "reach level 7 and defeat the goblin king")

Treat this as a loop, not a script:

1. **Orient**: read `player-<username>.md` and `world.md`. What's the current level/
   status? What's already been discovered? Is there an in-progress goal
   already recorded, or is this new?
2. **Decide the next concrete action** based on what's missing:
   - Below the target level → gain experience. Fighting appropriately-
     sized monsters you encounter along the way is good even if they're
     not the named target - grinding opportunistically as you explore
     beats detouring specifically to farm XP, and levels are usually a
     prerequisite for the harder target fight anyway.
   - New skills available to learn (check `practice` with no argument) →
     visit a guild and practice them; they make later fights easier.
   - Target monster's location unknown → explore toward unmapped areas,
     asking NPCs or reading room text for hints.
   - Target monster found and character is a reasonable match for it →
     engage.
   - HP/mana low → rest or return somewhere safe to recover before
     pushing further.
3. **Act**: send the command via `mud_cmd.py`.
4. **Update memory**: record what changed.
5. **Repeat.**

A few judgment calls worth naming explicitly:

- **Don't loop forever unsupervised.** If you've made many attempts
  without progress (repeated deaths to the same monster, no path found
  after extensive exploration), stop and tell the user what's blocking
  you rather than grinding silently - they may want to adjust the goal
  or help directly.
- **Long goals span turns.** "Reach level 7" from level 1 may take more
  actions than fits comfortably in one response. That's fine - make solid
  progress, leave `player-<username>.md` in a state that clearly says where things
  stand, and pick back up next time you're asked. Don't feel obligated to
  finish a multi-hour grind in one shot.
- **Report progress, not just the end state.** Especially for long goals,
  let the user know what you accomplished and what's left, rather than
  going silent until (if ever) the goal is fully done.

## Reference

`references/commands.md` has a quick lookup of common MUD commands and
the status-line format, plus notes on locations discovered in past
sessions (useful as a hint, but verify against `world.md` first - that's
the live, current map)."""

mud_player = AgentDefinition(
    description=MUD_PLAYER_DESCRIPTION,
    prompt=MUD_PLAYER_PROMPT,
    tools=["Bash", "Read", "Edit"],
)

options = ClaudeAgentOptions(
    agents={"mud-player": mud_player},
    allowed_tools=["Task"],
    setting_sources=[],  # do NOT auto-load .claude/agents/*.md or any other on-disk settings
    cwd=str(PROJECT_ROOT),
    # Unlike the interactive CLI harness (which prompts a human for each Bash
    # call), a scripted SDK session has no one to approve mud-player's
    # scripts/mud_cmd.py invocations - bypass so it can actually run.
    permission_mode="bypassPermissions",
)


# How long to keep watching for backgrounded mud-player Task calls (e.g. two
# players checked at once) to finish, after the orchestrator's own turn has
# already ended. Generous because a hunger check can involve a from-scratch
# character recreation or a long walk to find a guildmaster.
BACKGROUND_TASK_TIMEOUT_S = 600


async def _drain_response(client: ClaudeSDKClient) -> None:
    """Print assistant text as it streams in, and don't stop at this turn's
    own ResultMessage if it dispatched a backgrounded Task subagent - without
    this, a backgrounded mud-player call (the orchestrator's own choice when
    asked to check two players) finishes invisibly: the subagent does the
    work and updates data/player-<name>.md, but nothing here ever prints the
    result, and the orchestrator's turn ends on a placeholder like "I'll let
    you know when they report back" that never gets followed up on.

    Instead, keep listening on the same message stream (not a fresh query)
    until every Task this turn started has reached a terminal status. The
    orchestrator wakes back up on its own when a background task completes
    and posts a follow-up AssistantMessage (with its own ResultMessage) -
    that arrives on this same stream, so we just need to keep reading it.
    """
    pending_tasks: set[str] = set()
    seen_result = False

    async for message in client.receive_messages():
        if isinstance(message, AssistantMessage):
            for block in message.content:
                if isinstance(block, TextBlock):
                    print(block.text)
        elif isinstance(message, TaskStartedMessage):
            pending_tasks.add(message.task_id)
            print(f"\n[background task started: {message.description}]")
        elif isinstance(message, TaskNotificationMessage):
            pending_tasks.discard(message.task_id)
            # Don't print message.summary here - the orchestrator's own
            # follow-up AssistantMessage (printed above) already reports the
            # result in its own words; repeating the raw summary is just
            # noise on top of it.
            print(f"\n[background task {message.status}]")
        elif isinstance(message, TaskUpdatedMessage):
            status = message.status or message.patch.get("status")
            if status in TERMINAL_TASK_STATUSES:
                pending_tasks.discard(message.task_id)
        elif isinstance(message, ResultMessage):
            seen_result = True
            if message.total_cost_usd is not None:
                print(
                    f"\n[turns: {message.num_turns} | cost: ${message.total_cost_usd:.4f}]"
                )

        if seen_result and not pending_tasks:
            return


async def _print_response(client: ClaudeSDKClient) -> None:
    try:
        await asyncio.wait_for(
            _drain_response(client), timeout=BACKGROUND_TASK_TIMEOUT_S
        )
    except asyncio.TimeoutError:
        print(
            f"\n[still waiting on a background task after "
            f"{BACKGROUND_TASK_TIMEOUT_S}s - it keeps running, but this "
            f"script has stopped watching; ask again later to pick up "
            f"where it left off]"
        )


async def main() -> None:
    initial_goal = " ".join(sys.argv[1:]).strip()

    async with ClaudeSDKClient(options=options) as client:
        print(
            "Orchestrator ready (mud-player subagent defined via AgentDefinition, "
            "no .claude/agents/*.md involved). Type a goal, or 'exit' to quit."
        )

        if initial_goal:
            print(f"\n> {initial_goal}")
            await client.query(initial_goal)
            await _print_response(client)

        while True:
            try:
                goal = input("\n> ").strip()
            except EOFError:
                break
            if not goal or goal.lower() in ("exit", "quit"):
                break
            await client.query(goal)
            await _print_response(client)


if __name__ == "__main__":
    asyncio.run(main())
