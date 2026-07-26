# Player: smarty

This file is a snapshot, not a log - overwrite sections in place as things
change rather than appending. It should always describe *now*, so it stays
cheap to read at the start of every session.

## Current Status
- Level: 1 (Smarty the Apprentice of Magic), 1/2500 exp
- HP: 16/16
- Mana: 100/100
- Moves: 83/83
- Gold: 0
- Sex: Female
- Location: The Temple Of Midgaard (South End) - fresh spawn point after character recreation
- Hunger/Thirst: NOT hungry, NOT thirsty - `score` output (2026-07-26) contains no hunger/thirst
  warning line at all (this MUD only prints "You are hungry"/"You are thirsty" style lines in
  `score` when the condition is low; absence = satisfied). No `condition` command exists in this
  build (`condition`/`hunger`/`diagnose` all return "Huh!?!"/errors) - `score` is the way to check.

## Inventory
Nothing (character just recreated, 2026-07-26).

## Learned / Practiced Skills
Not yet checked since recreation - previously had magic missile: poor before the reset.

## Active Goal
None active - last check was a one-off hunger status check (2026-07-26).

### Progress Notes
- Character created 2026-07-24, class Mage, previously reached Mages' Guild and practiced magic
  missile, but by 2026-07-26 the MUD server no longer recognized the `smarty` account (fresh
  server instance/character wipe) - the daemon's login flow got stuck on "Please retype
  password:" because `scripts/mud_client.py`'s `login()` only checks for the literal substring
  "Password" (capital P) and doesn't handle the new-character-creation prompts ("Give me a
  password for X:", "Please retype password:"), so it never actually sent the password during
  a new-character flow. Worked around it manually via a raw socket to recreate the character
  (password goodbyemoon, sex F, class Magic-user [M]), after which normal login via mud_cmd.py
  works fine again (existing-account login path is unaffected by the bug).
- 2026-07-26: Checked hunger via `score` right after respawn - not hungry, not thirsty (see
  Current Status above). All previous guild/route progress needs to be redone since this is a
  brand-new level-1 character standing in Temple Of Midgaard.
- 2026-07-26 (re-check): Re-confirmed hunger status via `score` again after moving south to the
  Temple Square - still no hunger/thirst warning line present, HP/mana/moves at max (16/16,
  100/100, 82-83/83). Not hungry, not thirsty.
- Known bug worth fixing later: `scripts/mud_client.py` login() password-prompt detection is
  case-sensitive and doesn't cover the "new character" password prompts.
