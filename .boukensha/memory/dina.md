Discoveries
- `consider` can be used to judge whether a target is safe/easy before attacking; it helped identify a fido as "Fairly easy."
- Attacking without checking first can pull a Peacekeeper into combat; the Peacekeeper is dangerous when combat starts around it.
- The Grubby Inn has a reception area and NPC interaction there did not immediately produce food; food/drink attempts can fail there without gold or the right command.
- Picking up items is syntax-sensitive: some attempts were misparsed as container actions / "not a container," while exact visible names worked for `sword`, cape, boots, and shield.
- The game has a score/status check command that confirms current HP and hunger.
- `wear` is a valid equipment command; the next useful step after getting gear was to wear the shield.

Mistakes
- Trying to buy food without gold failed.
- Using the wrong pickup syntax caused repeated "not a container" / misparsed results instead of gaining items.
- Attacking while critically low on HP was unsafe and led to combat problems.
- Repeating failed menu/reconnect inputs did not advance gameplay.

Strategies
- Use `consider` before combat; it helps avoid dangerous fights.
- Pick up gear by exact visible item name rather than container-style commands.
- After securing gear, equip it immediately, starting with the shield.

Open threads
- Need to equip the newly acquired shield, cape, and boots.
- Still need to recover enough HP/food before safe leveling.
- Goal remains to reach level 20.
