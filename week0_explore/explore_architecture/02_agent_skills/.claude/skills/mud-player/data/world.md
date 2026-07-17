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
Notes: The baker (shopkeeper), Peacekeeper NPC. Sells: danish pastry (7g), bread (14g), waybread (74g).

## Main Street
Commercial through-street.
Exits:
- north -> The Bakery
- south -> The Armory
- east -> Market Square
- west -> unexplored
Notes: Main north-south corridor.

## Market Square
Famous square with large statue in middle.
Exits:
- west -> Main Street
- north -> Temple Square
- south -> unexplored ("common square" mentioned in room text)
- east -> unexplored (main street mentioned)
Notes: No shops or NPCs.

## Temple District

## Temple Square
Marble steps leading to temple, inn to east, clerics' guild to west.
Exits:
- north -> The Temple Of Midgaard
- south -> Market Square
- east -> The Grunting Boar Inn
- west -> Entrance to Clerics' Guild
Notes: Fountain here. Various NPCs.

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
