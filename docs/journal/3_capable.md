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
- I am uncertain that 

## Technical Hypothesis
[todo]
- Agents will struggle at first when exploration is low
- Latency on tool call and iteration will significantly increase
- 

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

### 2. Memory / World Knowledge
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
- Found out that Judge were not carrying previous's judments into memory

### 3. Navigator/Path planner

### 
- Caveman language?

### Error awareness

## Technical Conclusions
[todo]



## Key Takeaway
