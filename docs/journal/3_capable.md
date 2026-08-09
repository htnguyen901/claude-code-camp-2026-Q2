## Week 3 Technical Documentation 

## Technical Goal
[todo]
- Design the Agentic Loop that is capable of executing complex goal
- Plan decomposition
- Refine memory and knowledge access
- (Optional) Implement playstyle/persona and risk mode

## Technical Uncertainty
[todo]
- I am uncertain that having a complex orchestrator and evaluator system will correlate exponentially with capability
- I am uncertain that world knowledge is enough to aid player with effectively exploring MUD and completing complex tasks

## Technical Hypothesis
[todo]
- Agents will struggle at first when exploration is low
- Latency on tool call and iteration will significantly increase
- Agents will need memory and not just world knowledge

## Technical Observations
[todo]
### 1. Design a high level planner -> Execution -> Judge loop
- Agents need to plan before executing tasks. But despite having a plan Agent could still drift away from the initial plan or got stuck and need feedback/guidance
> We also need a judge to evaluate the current progress and to make decision if Agent got stuck

#### The Planner
**Tasked with lvl up to 10**
- Agent view level info, then can't get out of the level view because Agent don't have tool to exit
  - Root cause: CircleMUD's own pager ("[ Return to continue, (q)uit, (r)efresh, (b)ack, or page number (N/M) ]") takes over input on any long response and ignores every other command until answered — the agent had no primitive that could send a bare Return/"q"/"r"/"b"/page number.
    > Missing primitives from mud_manager (commands and pagers) => FIXED
- Planner made a plan with 5 decomposted smaller steps before Player started its journey
- Planner initiated the plan without player's conditions (level, skills, world knowledge, etc)
  > The steps taken by Players are almost the same as before. The planner didnot help here since the plan was made without acknowleging player's condition. The planner seems like a generic system prompt at this stage
  > Questions: How much should the planner know and when to trigger a planner that could stay true to 'real player playstyle' AKA keep playing untill stuck and start thinking and planning

#### The Judge
- The judge was called when the turn stopped due to 'max token'. Judge decide to continue the plan
  - Tasked with find and defeat the minotaur, player reasoned that the minotaur could be further down the dump, planned for next action is to find a light source and head futher to The Dump => Judge said Continue
- Judge kept giving the green light to Continue. Without World Knowledge, Judge does not have significant leverage than the player
- Cost (Token usage) by Player is growing tremendeously => Need immediate optimization

### 2. World Knowledge
A planner/judge or a new subtask to read world knowledge and plan the route => offload movement tools from player to this subagent
- We have a valid reason to move room_knowledge (to check examination of object in room) to a MCP server to allow porting to Python
  - Extended room_knowledge:
    - connections: exits, exits never walked
  - Added new tool:
    - `route_to(from, to)` to cover path finding

**Observation**
Tasked with finding the bakery and tell me what is on the menu
- Agents navigate better with planning but reaching destination is still a matter of luck
- Found out that if given another goal in the same session, Planner doesn't make a new plan

Tasked with resolve hunger and thirst:
- Agent asked beggar multiple times for food and water (beggar is asking for spare coins)
- Player stayed with trying to ask NPCs for free food instead of considering fighting mobs for food source
- Judge kept giving the green flag to that because it **does not negate the plan**
  > Judge is lacking prior iteration's outcome and summary

- Found out that Planner and Judge's tools are bound by Player's tool => FIXED by implementing separate Registry for each Task
- Found out that Judge were not carrying previous's judments into memory => FIXED

Tasked with finding and examine the corridor in The Begining of The Passage (player has walked this room)
- Planner did not use world tools (room_knowledge and route_to), instead gave a very generic plan that wasn't helpful
- Player explored randomly again, somehow found a teleporter, didn't know how to use the device, then decided to transport to SANCTUS (but failed) with reasons:
  `I’ll teleport to SANCTUS, since it’s a likely source for a named passage or corridor.`
- The Judge successfully replan that action: `A new plan should refocus on systematic adjacent-room exploration or clarify the teleporter usage before pursuing SANCTUS.`
- The Planner made a new reasonable plan but didn't use the world tools to pin the exact location of that room on the map, instead gave another general plan again
- Found out world tools didn't have access to discoveries yet, route_to would require an exact room name and sometimes request won't classify an exact match
  > Planner needs rework on system prompt. World tools need access to discoveries/rooms

### 3. Navigator/Path planner. Tools and System prompt re-work
A specialized sub-agent responsible for path-finding.
- A specialized sub-task perform read-only route finder answering "is there a know path, what is it"
- Planner and Player now can delegate tasks to this sub-agent to mimic the 'map reading' technique

**Observations:**
- World tools are called more efficiently
- Agents are no longer wandering mindlessly. Judge kept the agent in checked and redirected the Agent to plan as well as replan if needed
- Planner are providing a somewhat goal-decomposition and more detailed guidance


### 4. Self-managed session with a capped cost and user pause/unpause/stop
Allow the Agent loop to keep going until cap hit
- Implement interfering with pause, continue, and stop via tui
- Enable Agents to keep going
  - Turn stop will trigger Judge, Judge will provide a verdict and Agent loop keeps going until cap hit


### 5. Memory
A chronicler to summrize and learn after gaming session, log as a markdown file living under .boukensha
- Planner will access this memory/learnt experience prior to making a plan
- Player will only see the memory effect, not the memory itself 
- Memory summarized after a session ends
  > Does this align with normal play flow: player learn as they play and not after a whole session. This is also not very sufficient with agent loop design because the session keep going until goal is accomplished

**Tasked with leveling up to 20**
- Agents fought mobs, died and managed to log back to game to continue with the plan       
- Judge flagged a possible problem with the session and asked for user to review, turned out Player didn't follow Navigator's path-finding instructions
- Memory summarized into 4 categories: discoveries, mistakes, strategies and open threads
- When memory is low Player tend to try and fail multiple times, feeding experience to memory
  > Changed memory machenics to flush after a turn ends, not when session ends, aliging with: 'when I get stuck I need to joggle my experience and thinking to find a another/better solution'
- Found out that consult_navigator tool result got compacted in message, Player is missing most of the hop-by-hop instruction
- Overflowing context in a session because we never compact or clear message after a Judge's verdict
- Agents really struggled to resolve hunger

**Implemented a new Context#route, same as Context#plan to survive compactation**
- Add numbered route ouput from Navigator
- Add a Context#route that carries route and follow-it instruction => only cost token when a route is active

**Bug: memory wasn't updating on long, never-escalating sessions**
- Observed: a broke Player kept visiting bars, pet shops, and food shops that never resolve hunger since it can't afford anything — a clearly learnable mistake — but nothing landed in memory that session
  > FIXED: - Chronicler now runs once per checkpoint instead of only on :replan/:flag — watch real session cost/latency and digest quality now that it fires more often

- Agents could easily resolve thirst but couldn't resolve hunger. Assuming Agents has to accomplish this at least once to learn ways to resolve hunger but got blocked by the self-imposed combat ban (don't fight when low HP or hungry)

**Prompt Engineering**
- Reduced the self-imposed ban. Provided more generic instructions
- Made Chronicler to check outcomes before making something a strategy

**Observations**
- Agents manage to learn and grow with the game:
  - Learn how to kill a monster
  - Learn that it can loot free resource from monster
  - Learn that it made a mistakes repeating failed commands instead of pivoting (was calling examine/consider instead of attacking)
  - Decide to fight the fido but somehows fighting with Peacekeeper instead and not the inteded target => die


### 
- Caveman language?

### Error awareness

## Technical Conclusions
[todo]



## Key Takeaway
