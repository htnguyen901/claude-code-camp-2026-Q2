# tbaMUD Quick Reference

## Navigation Commands

| Command | Abbreviation | Description |
|---------|-------------|-------------|
| `north` | `n` | Move north |
| `south` | `s` | Move south |
| `east` | `e` | Move east |
| `west` | `w` | Move west |
| `up` | `u` | Move up |
| `down` | `d` | Move down |
| `look` | `l` | Look at current location |
| `exits` | — | Show available exits |

## Interaction Commands

| Command | Usage | Description |
|---------|-------|-------------|
| `examine <object>` | `examine door` | Look closely at an object |
| `take <item>` | `take bread` | Pick up an item |
| `drop <item>` | `drop bread` | Drop an item |
| `inventory` | `i` | Show what you're carrying |
| `ask <npc> <question>` | `ask baker about menu` | Talk to an NPC |

## Shopping Commands

| Command | Usage | Description |
|---------|-------|-------------|
| `list` | — | Show items for sale at current shop |
| `buy <item>` | `buy bread` | Purchase an item |
| `sell <item>` | `sell bread` | Sell an item from inventory |
| `identify <item>` | `identify #1` | Check item details before buying |

## Character Information

| Command | Abbreviation | Description |
|---------|-------------|-------------|
| `score` | — | Show full character stats |
| `inventory` | `i` | Show inventory |
| `status` | — | Show current HP/Mana/Moves |
| `help` | `h` | Show MUD help |
| `help <command>` | — | Get help on specific command |

## World Information

| Command | Description |
|---------|-------------|
| `news` | Read the bulletin board |
| `shops` | Find nearby shops |

## Useful Emotes/Communication

| Command | Usage |
|---------|-------|
| `say <message>` | Speak to nearby people |
| `shout <message>` | Speak to the whole area |
| `tell <player> <message>` | Send private message |

## Status Bar Format

When connected, you'll see a status line like:

```
21H 100M 85V (news) (motd) >
```

This means:
- **21H** = Current Health Points (out of max)
- **100M** = Current Mana Points
- **85V** = Current Movement Points
- **>(news)(motd)** = Available options/news available

## Locations seen in past sessions

These are hints from earlier exploration, not guarantees - the map can
change and this list isn't kept in sync automatically. Treat `data/world.md`
as the source of truth (it's the one you're expected to keep current
yourself); use this section only as a head start when world.md is empty
or thin.

- **Main Street** - north to The Bakery, south to The Armory, east
  mentioned toward a Market Square (unconfirmed)
- **The Bakery** - sells danish pastry, bread, waybread
- **The Armory** - sells leather/bronze/chain armor pieces and a shield
- A guildmaster exists somewhere and responds to `practice` - exact
  location not yet confirmed as of this writing

## Money

- Prices are shown when you `list` items at a shop
- `value <item>` checks what something in your inventory is worth

## Practice and skills

- `practice` with no argument lists skills you know (and don't yet know)
  plus remaining practice sessions
- `practice <skill>` trains that skill, but only works in a guild, with a
  guildmaster present ("You can only practice skills in your guild.")
- Practice sessions are limited - spend them on skills relevant to your
  current goal

## Tips

1. **`look` when entering a new location** - the room text is your only
   source of truth for what's there; there's no separate exits/NPCs feed
2. **Confirmed exits only** - a room description mentioning a nearby place
   isn't the same as a walkable exit; only record one in `world.md` after
   actually walking it
3. **Talk to shopkeepers and NPCs** - `ask <npc> <topic>` can surface
   information not in the room description
4. **`help <command>`** gives detailed usage for anything you're unsure
   about, including MUD-specific mechanics like combat or practice

## Connection notes

- `mud_cmd.py` starts a background daemon on first use and keeps the
  telnet session alive across every subsequent call in the session
- If a command fails due to a dropped connection, the daemon reconnects
  and retries automatically
- Run `mud_cmd.py --stop` to log out cleanly when done; not required, but
  polite
