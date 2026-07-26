# Player: dummy

This file is a snapshot, not a log - overwrite sections in place as things
change rather than appending. It should always describe *now*, so it stays
cheap to read at the start of every session.

## Current Status
- **RESET 2026-07-26**: server-side no longer had prior character data for `dummy` -
  login hit the "New character" creation flow instead of a normal password prompt,
  so the account had to be recreated from scratch (see world.md "Server note
  2026-07-26" for details).
- Level: 34, "Dummy the Implementor" (immortal) - unexpectedly auto-granted on
  creation by this dev/test server, not earned via normal play. 7,000,000 exp.
- HP: 500/500
- Mana: 100/100
- Moves: 82/82
- Gold: 0
- Class: Warrior (chosen again at creation to match prior notes), Sex: Male
- Location: The Immortal Board Room (start room for this new character) - see
  world.md for room details. Exit south to "eastern foyer" not yet explored.
- Hunger/Thirst: N/A - confirmed via `help hunger`: "Immortals never become
  hungry, thirsty or full." The `condition`/`cond` commands are not recognized
  by this MUD ("Huh!?!"); hunger/thirst would show via `score` warnings for a
  mortal character, but none apply here.

## Inventory
(not yet checked since reset)

## Learned / Practiced Skills
(unknown since reset - prior "kick" practice no longer applies to this new character)

## Active Goal
None currently active (previous goal "find and defeat the massive minotaur in the
newbie zone" was based on the old, now-lost level-1 character and needs to be
reassessed - the new `dummy` is an immortal level 34, a very different starting
point).

### Progress Notes
- 2026-07-26: Confirmed via task "check hunger status" that the `dummy` account had
  been wiped server-side; recreated character (Warrior/Male), ended up immortal
  level 34 in The Immortal Board Room. Hunger/thirst do not apply to immortals per
  in-game help text.
- 2026-07-26 (re-check): Re-logged in for a follow-up "check hunger" task; state
  unchanged from above (still immortal level 34, 500/500 HP, `condition` command
  still returns "Huh!?!", `score` shows no hunger/thirst line).
- Prior progress (pre-reset, level 1, minotaur hunt in newbie zone) is preserved in
  git history of this file but no longer reflects live game state.
