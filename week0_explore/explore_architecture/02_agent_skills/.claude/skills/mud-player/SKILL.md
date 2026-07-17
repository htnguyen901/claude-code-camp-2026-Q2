---
name: mud-player
description: |
  Play tbaMUD running on localhost:4000 - explore, fight, shop, talk to NPCs, and pursue open-ended goals like "reach level 7" or "find and defeat the goblin king." Use this skill for ANY interaction with the MUD, whether it's a single command ("look around", "buy some bread") or a long multi-step goal that requires exploring, grinding experience, and tracking progress across many turns. The skill manages the telnet connection and login automatically, maintains persistent memory of the map and character state across the whole session, and expects the model itself to decide what to do next rather than following a fixed script - so it handles requests it hasn't seen before just as well as familiar ones. Always use this skill instead of manually opening a telnet/socket connection to the MUD yourself.
compatibility: Python 3.6+, unix sockets, telnet access to localhost:4000
---

# MUD Player Skill

You are playing tbaMUD (a CircleMUD variant) at localhost:4000 as the
character `dummy`. This skill gives you one raw tool for talking to the
game and two memory files for remembering what you've learned. Everything
else - where to go, what to fight, how to reach a goal - is up to your own
judgment as you play. There is no built-in list of "supported requests":
if you can express it as MUD commands, you can pursue it.

## The one tool: mud_cmd.py

```bash
python3 .claude/skills/mud-player/scripts/mud_cmd.py "<command>"
```

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
session, run `python3 .../mud_cmd.py --stop` to log out cleanly - though
this isn't required, and if you forget, the next `mud_cmd.py` call in a
future session will just reconnect.

## Memory: read first, update as you go

Two files live in `.claude/skills/mud-player/data/`:

- **`player.md`** - a snapshot of character state: level, HP/mana/moves,
  gold, inventory, learned skills, and the active goal with a short
  progress log.
- **`world.md`** - a room-by-room map: what you've discovered, confirmed
  exits, shop inventories, and where you've seen monsters.

**At the start of any task, read both files.** They tell you what you
already know, so you're not re-exploring rooms or re-checking prices you
already have. If you're resuming an existing goal, the progress notes are
what let you pick up where you left off instead of starting over.

**As you play, keep them current.** These are snapshots, not transcripts -
edit sections in place rather than appending forever (an ever-growing log
of every status line is noise, not memory). Concretely:

- After a `look`, add the room to `world.md` if it's new, and record any
  exit you actually walk through (not ones merely mentioned in the room's
  description text - "south of here is the armory" is scenery, not a
  confirmed exit until you've walked it).
- After checking `score`/`practice`/`inventory`, update the matching
  section of `player.md`.
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
Log it in `player.md`'s progress notes (what killed you, roughly what
level/gear you had) and continue toward the goal - respawn, recover
position via the map, and pick back up. Only surface it to the user if
you find yourself dying repeatedly in a way that suggests the goal itself
needs rethinking (e.g. the target monster is far too strong for the
current level).

## Pursuing a goal (e.g. "reach level 7 and defeat the goblin king")

Treat this as a loop, not a script:

1. **Orient**: read `player.md` and `world.md`. What's the current level/
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
  progress, leave `player.md` in a state that clearly says where things
  stand, and pick back up next time you're asked. Don't feel obligated to
  finish a multi-hour grind in one shot.
- **Report progress, not just the end state.** Especially for long goals,
  let the user know what you accomplished and what's left, rather than
  going silent until (if ever) the goal is fully done.

## Reference

`references/commands.md` has a quick lookup of common MUD commands and
the status-line format, plus notes on locations discovered in past
sessions (useful as a hint, but verify against `world.md` first - that's
the live, current map).
