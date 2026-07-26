# World Map

A room graph, built up as you explore. Each room gets one entry with its
known exits. Add a room the first time you `look` there; add/confirm an
exit once you've actually walked it (don't guess exits from prose in the
room description - MUD descriptions mention nearby places narratively, and
that's not the same as a confirmed, walkable exit).

Format per room:

```
## <Room Name>
<one-line description, optional>
Exits:
- <direction> -> <Room Name | "unexplored">
Notes: <NPCs, monsters, shops, anything goal-relevant>
```

## Downtown/Shopping District

## The Bakery
Small bakery with danish and bread smell.
Exits:
- south -> Main Street
Notes: The baker (shopkeeper), Peacekeeper NPC, a cityguard. Sells: danish pastry (7g), bread (14g), waybread (74g).

## Main Street
Commercial through-street.
Exits:
- north -> The Bakery
- south -> The Armory
- east -> Market Square
- west -> Main Street (West End)
Notes: Main north-south corridor.

## The Armory
Shop with helmets, shields, and suits of armor for sale.
Exits:
- north -> Main Street
Notes: Dead end (only north exit). An armorer NPC (shopkeeper). Not a guild - just a shop. Small note on wall explains buy/sell/value/list commands.

## Main Street (West End)
End of main street; magic shop to north, Guild of Magic Users to south, city gate to west.
Exits:
- east -> Main Street
- north -> unexplored (magic shop)
- south -> The Entrance To The Mages' Guild
- west -> Inside The West Gate Of Midgaard
Notes: Beastly fidos seen here.

## MAGE'S GUILD (Guild of Magic Users)

## The Entrance To The Mages' Guild
Small, poorly lit entrance hall.
Exits:
- north -> Main Street (West End)
- south -> The Mages' Bar
Notes: ATM machine here. A sorcerer guards the entrance.

## The Mages' Bar
Weird bar with mystical floating images and illusions of fine furniture.
Exits:
- north -> The Entrance To The Mages' Guild
- east -> The Mages' Laboratory
Notes: Bulletin board and a waiter (ex-sorcerer) here.

## The Mages' Laboratory
Magical Experiments Laboratory; oaken tables cluttered with pipes/flasks, half-erased pentagrams on the floor.
Exits:
- west -> The Mages' Bar
Notes: **Guildmaster is here** ("Your guildmaster is studying a spellbook while preparing to cast a spell"). Confirmed via `practice`/`practice magic missile` (2026-07-24) - this is smarty's (Mage) guild. Route from Temple Square: south to Market Square, west, west, west, south, south, east.

## Inside The West Gate Of Midgaard
Two small towers built into the city wall, connected by a footbridge over the gate.
Exits:
- east -> Main Street (West End)
- south -> Wall Road (near gate)
- west -> unexplored (city gate, leads out of town)
Notes: Cityguards guarding the gate.

## Wall Road (near gate)
Road next to western city wall, just south of the west gate.
Exits:
- north -> Inside The West Gate Of Midgaard
- south -> Wall Road (alley junction)
Notes:

## Wall Road (alley junction)
Wall Road continues north/south; a small poor alley leads east. Letters written on the wall.
Exits:
- north -> Wall Road (near gate)
- south -> Wall Road (near bridge)
- east -> Poor Alley
Notes:

## Wall Road (near bridge)
Road next to western city wall; bridge across the river is south.
Exits:
- north -> Wall Road (alley junction)
- south -> On The Bridge
Notes:

## On The Bridge
Stone bridge built out from the western city wall, river flows west below.
Exits:
- north -> Wall Road (near bridge)
- south -> unexplored
Notes: Leads out of the city toward countryside/river.

## Poor Alley
Alley next to the city wall, continues east.
Exits:
- east -> The Eastern End Of Poor Alley
- west -> Wall Road (alley junction)
Notes: A janitor and a beggar here.

## The Eastern End Of Poor Alley
Poor alley meets the Grubby Inn (south) and common square (east).
Exits:
- east -> The Common Square
- south -> unexplored (Grubby Inn)
- west -> Poor Alley
Notes: Beastly fidos, green gelatinous blob seen here.

## The Common Square
Square where people pass by; connects poor alley (west), dark alley (east), market square (north).
Exits:
- north -> Market Square
- east -> The Dark Alley
- west -> The Eastern End Of Poor Alley
- south -> unexplored ("nasty smell" - likely sewer)
Notes: Beastly fidos seen here.

## The Dark Alley
Dark alley; Guild of Thieves is south. Continues east/west.
Exits:
- east -> The Dark Alley At The Levee
- west -> The Common Square
- south -> unexplored (Guild of Thieves)
Notes: Mercenaries waiting for jobs here. NOT the warrior guild (that's the Guild of Swordsmen, see below).

## The Dark Alley At The Levee
Alley continuing east/west; the levee is south.
Exits:
- east -> The Eastern End Of The Alley
- west -> The Dark Alley
- south -> unexplored (levee)
Notes:

## The Eastern End Of The Alley
Dead end at the city wall; a small warehouse is south.
Exits:
- south -> unexplored (small warehouse)
- west -> The Dark Alley At The Levee
Notes: Cityguard stands here.

## Market Square
Famous square with large statue in middle.
Exits:
- west -> Main Street
- north -> Temple Square
- south -> The Common Square
- east -> Main Street (East, General Store) (confirmed by room text: "east and westbound is the main street")
Notes: The Mayor and an oozing green gelatinous blob seen here (2026-07-24).

## Main Street (East, General Store)
Main street segment; general store north, Pet Shop south, continues east.
Exits:
- east -> Main Street (East, Weapon Shop / Guild of Swordsmen)
- west -> Market Square
- north -> unexplored (general store)
- south -> unexplored (Pet Shop)
Notes:

## Main Street (East, Weapon Shop / Guild of Swordsmen)
Main street segment; weapon shop to north, Guild of Swordsmen to south, leads out of town to east.
Exits:
- west -> Main Street (East, General Store)
- north -> unexplored (weapon shop)
- south -> The Entrance Hall To The Guild Of Swordsmen
- east -> unexplored (leaves town)
Notes: Janitor and beastly fidos seen here.

## WARRIOR'S GUILD (Guild of Swordsmen)

## The Entrance Hall To The Guild Of Swordsmen
Entrance hall; bar to east, main street to north.
Exits:
- north -> Main Street (East, Weapon Shop / Guild of Swordsmen)
- east -> The Bar Of Swordsmen
Notes: ATM machine here. A knight guards the entrance.

## The Bar Of Swordsmen
Once-beautiful bar, now trashed furniture everywhere. Yard to south, entrance hall to west.
Exits:
- south -> The Tournament And Practice Yard
- west -> The Entrance Hall To The Guild Of Swordsmen
Notes: Bulletin board and a waiter here.

## The Tournament And Practice Yard
Practice yard of the fighters; a well leads down into darkness.
Exits:
- north -> The Bar Of Swordsmen
- down -> unexplored (well)
Notes: **Guildmaster is here** ("Your guildmaster is standing here sharpening an axe"). Confirmed via `practice`/`practice kick` (2026-07-24) - this is dummy's (Warrior) guild. Route from Temple Square: south to Market Square, east, east, east, south, east, south.

## Temple District

## Temple Square
Marble steps leading to temple, inn to east, clerics' guild to west.
Exits:
- north -> The Temple Of Midgaard
- south -> Market Square
- east -> The Grunting Boar Inn
- west -> Entrance to Clerics' Guild
Notes: Fountain here. Various NPCs (janitor).

## The Temple Of Midgaard (South End)
Giant marble blocks, ancient wall paintings.
Exits:
- north -> By The Temple Altar
- south -> Temple Square
- east -> The Donation Room
- west -> The Reading Room
- down -> unknown
Notes: ATM machine here.

## By The Temple Altar
Northern end of temple, huge altar and 10-foot Odin statue.
Exits:
- north -> Behind The Temple Altar
- south -> The Temple Of Midgaard (South End)
Notes: Religious location.

## Behind The Temple Altar
Dirt path leading away from temple toward countryside.
Exits:
- north -> The Great Field Of Midgaard
- south -> By The Temple Altar
Notes: Steps lead out back toward Dragonhelm Mountains.

## The Great Field Of Midgaard
Wide dirt path through lush countryside, oak trees, birds.
Exits:
- north -> unexplored
- south -> Behind The Temple Altar
- east -> The Entrance To The Newbie Zone
- west -> The Dirt Path
Notes: Beautiful open area, pleasant weather.

## Countryside

## The Dirt Path
Narrow dirt path through countryside with stone archway and large rusty gate to west.
Exits:
- east -> The Great Field Of Midgaard
- west -> The Great Chessboard Of Midgaard
Notes: Warning: "zone is above your recommended level" when entering west.

## The Great Chessboard Of Midgaard
Giant wooden gate (rusted open), archway entrance.
Exits:
- east -> The Dirt Path
- west -> A White Square (on the chessboard)
Notes: DANGEROUS - above recommended level. Black Knight at one location killed me.

## Newbie Zone

## The Entrance To The Newbie Zone
Gateway to newbie zone, entrance hall.
Exits:
- north -> The Beginning Of The Passage
- west -> The Great Field Of Midgaard
Notes: "Just the place you have been looking for."

## The Beginning Of The Passage
Start of newbie zone passages.
Exits:
- east -> The Dirty Hallway
- south -> The Entrance To The Newbie Zone
Notes: Newbie monster stands here.

## The Dirty Hallway
Slimy, moldy hallway with noises behind locked door to south.
Exits:
- east -> A Nexus
- west -> unexplored
- south -> (locked door)
Notes: Creepy crawling thing. Newbie monster.

## A Nexus
Intersection of two passages, brightens to north/east.
Exits:
- north -> (locked)
- east -> (locked)
- south -> More Of The Hallway
- west -> A Brighter Hallway
Notes: Creepy crawling thing.

## More Of The Hallway
Annoying passage continuing, locked door to west.
Exits:
- north -> A Nexus
- south -> Another Corner
- west -> (locked door)
Notes: Dragon here.

## Another Corner
Corner of passage, untidy, locked door to east.
Exits:
- north -> More Of The Hallway
- east -> (locked door)
- west -> A Brighter Hallway
Notes: No creatures.

## A Brighter Hallway
Hallway brightening toward west, continues east-west.
Exits:
- east -> Another Corner
- west -> The End Of The Passage
Notes: Creepy crawling thing. Newbie monster.

## The End Of The Passage
End of hallway, opens to fresh air.
Exits:
- east -> A Brighter Hallway
- west -> An Open Field By The Great Field
Notes: Dragon. Newbie monster. "At last, the end of the hallway."

## An Open Field By The Great Field
Open field after dank passage, exit to north leads to large field.
Exits:
- east -> The End Of The Passage
- north -> The Great Field Of Midgaard
Notes: Fresh air, relief from passage.

## GOAL TARGET

## The Red Room
**LOCATION: UNKNOWN - NOT YET FOUND**
**Contains: The Massive Minotaur (target monster)**
Notes: User confirmed this exists in the newbie zone but location not yet discovered. May be behind locked doors or in unexplored area.

## Known Monsters
- Newbie monster (generic, appears in multiple rooms in newbie zone)
- Creepy crawling thing (appears in newbie zone passages)
- Dragon (appears in newbie zone)
- Black Knight (in The Great Chessboard - VERY DANGEROUS, above level 1)
- Minotaur (MASSIVE, in The Red Room - TARGET MONSTER - LOCATION TBD)
