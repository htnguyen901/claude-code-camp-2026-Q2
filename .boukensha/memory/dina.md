Discoveries
- `consider` can be used to judge whether a target is safe/easy before attacking; it helped identify a fido and a beggar as "Fairly easy."
- Attacking without checking first can pull a Peacekeeper into combat; the Peacekeeper is dangerous when combat starts around it.
- The Dark Alley contains dangerous targets; `consider` helped identify them before committing to combat.
- The Grubby Inn has a reception area and can provide gold/food opportunities, but NPC/food/drink attempts there may require the right command or resources.
- Bar/General Store/Bakery shopping attempts with 0 gold did not reveal a usable food/drink option.
- Drinking from a fountain can fix thirst.
- Picking up/equipping items is syntax-sensitive: `get ... from ground` fails because the ground is not a container, while exact visible names worked for `sword`, cape, boots, shield, leggings, and one wristguard; repeated gear-equipping attempts still need correct item/slot syntax.
- The game has a score/status check command that confirms current HP, hunger, and thirst.

Mistakes
- Trying to buy food without gold failed.
- Using wrong pickup/equipment syntax, especially container-style ground commands or incorrect visible names for items like breast plate/gorget/neck guard, caused repeated misparsed or unsuccessful results instead of gaining/equipping items.
- Attacking while critically low on HP was unsafe and led to combat problems.
- Repeating failed menu/reconnect inputs or failed target syntax did not advance gameplay.
- Starting combat while unequipped left the character in an ongoing fight without the benefit of newly acquired gear.

Strategies
- Use `consider` before combat; it helps avoid dangerous fights.
- Pick up unattended gear by exact visible item name rather than container-style commands.
- After securing gear, equip it immediately, starting with the shield; use equipment/status checks if `wear` attempts seem to fail.
- If inventory is full, dropping a duplicate item can free space for needed food or loot.
- Eating collected meat/food can resolve hunger.
- Checking score/status during combat can confirm whether HP is safe before continuing.

Open threads
- The considered beggar is now dead; useful next step is to loot the corpse.
- Need to find the correct command/slot syntax to equip or confirm equipment status for the newly acquired shield, cape, boots, leggings, and wristguard.
- Still need to recover enough HP/food before safe leveling.
- Goal remains to reach level 20.