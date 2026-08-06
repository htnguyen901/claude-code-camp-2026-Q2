## Week 2 Technical Documentation 

## Problems observed in Week 1
These are considered high-risked limitation that needs to be optimized prior to the implementation of Week 2 - when we allow agents to be capable of executing the goal on its own
- The agent is currently highly token-inefficient. 
- As the codebase grows much larger, it's hard for engineer (us) to observe the reasoning process of agent and how it decides tool calling. 
- Log viz is not real time nor human-friendly readable nor interactive making human review and guidance different (with no planning and guidance in place).
- Tool/environment errors: nothing in the loop feeds tool errors back into the next decision. Agent has no error-awareness and proceed as if nothing happens. (week 1)

## Technical Goal

- Optimize token usage, improve observability and visbility of journey

## Technical Uncertainty
[todo]
- I am uncertain that we will need to implement a database in addition to sessions to store observability files
- I am uncertain that reducing list of available tools to only 'useful tool' will defer Agent's capability
- I am uncertain that the limited knowledge and context momery will be enough for Agent to execute complex tasks

## Technical Hypothesis
[todo]
- I think that reducing list of tools sent to LLM Client could potentially cause: 'missing an important tool that could guide Agent to the correct path'
- I think we will need to implement tracing to track request payload and growth of context

## Technical Observations
- Context are growing too fast depsite no effort for narration
- Agents could not even complete simple task such as: find the bakery and tell me what is on the menu
- Lots of wasted tool calls

### 1. Expose Request payload details
- Tasked to find the bakery but decided to find bar instead => Found system prompt has never been passed 
- Tools take up the majority of request payload and token count

> I need visibility on token breakdown and cost to have better judgement on tools size
> For every request, the raw output from MUD is injected to the next request payload. Can it be reduced/summarized?

### 2. Add Token composition and est. cost
- Tools takes up 70-90% of the context, token are counted toward the allowed MAX
    > Can we take advantage of prompt caching? -  front-load them so they can be cached

### 3. Improve Visibility and Add World Map Tracking
**Tasked with find Big Minotaur**
- Agent called: `tbamud__info_world(kind: "help", filter: "newbie", session_id: "default")`, MUD returns with text snippet: 
    `Once promoted GOTO 3 and read through the Builder Academy's tutorial 
    zone. Your third task as a builder is explained under HELP TRIAL. `
    Agent then decided the target should be in `GOTO 3` ?!
    > Agents fail to understand the context of MUD, as well as the odd usage of languague in MUD

- Items/NPC/mobs are now extracted but contains redundant text: `A knight is guarding the entrance.`, `A waiter is here.`
    > filler words like 'is here' is not needed => might need a word parser to extract object, then location/status of object if needed
- Agents kept circling around even in the same turn. Agents can't see its previous encounters in the same turn

### 4. An Inspector to ensure every passed-thru rooms are effectively and precisely described
**Passive room analyzer and read-back tool, added as subtask and configs controlled in settings.yaml**
- local LLM model vs lightweight NLP - encoders only (for ex BERT)
    - MUD world has gibberish name that BERT might not be able to catch, for ex: odif yltsaeb (beastly fido spelled backward)  => need reasonings
    - I also need the classify the discoveries into 4-way taxonomy: item, mob, npc, scenery
    - We wish to run this inspector in parellel and parse the room/discoveries alongside with the exploration => unknown about Ruby ecosystem for running HF model
    - We wish to subtract 2 parts: the subject, and the clause. For encoders only we'll need a 2-stage pipeline

    > local LLM might be a better fit here

- LLM cant tell npc and mobs apart, classifying most of the npcs as mobs (model used: Ollama - genma4)
- Agents's moving slower than before => need to track time spent
- Agents do not know how to read note, but examine note instead which is the wrong command
    - The substask automatically inspect and log in findings: `You do not see that here` which is not a real findings
    > Agent might need to manage its own inpsect room call. To try calling diffrent tools till a real desc is reached
- Agents struggles to call the right command
    - Found bakery but circle through: read signs, examine counter, back to look. Then just assume the look command gives 'what is on the menu' which is only 2 items and the bakery infact has 3
    - When prompted to 'check exact items sold and their price' then Agents successfully called `list` and completed the task

> Agents were not calling the right tools, and have not learnt from mistake (that is outside of context)
> Agents half-completed the task, assumed answers

- Agents did find the bakery (many requests ago - logged in session log) but kept failing to navigate to it
- Agents are not making connections of which room leads to which

> Agents need better knowledge of the world map

**Note**: Added simple implementation world knowledge as tool to boukensha. Will revisit to see if we need to separate into mcp server for when porting to Python. Will expand further to improve Agent's capability

### 5. Path vizualizer
- Node-link map on world map is low on readibility
> Minor implementation of a better map viz

**Potential issue**: 
- Uncertain how some rooms are overlapping each other. Might have been cause by the off-one bug
- Log_viz is refresh in time_interval, clearing current view => need to remove

### 6. Compact & Expose context injected
A hook implemented as named collaborator to compact MUD's response before passing to context
- Used ollama model for compactor: super slow wait during compactation

**Tasked with check status and eat and drink if needed**
- Agent keeps asking ending turns despite not completing the task. Further it'd go is to come up with
a solution then ask if it can go ahead
- Agent does not have a solid plan, head to bar to buy food and drinks but found out no money to buy,
then concluded that it could look for other options such as fountain

> Normally, player would know they need money and would check for money beforehand

**Uncertainty**
- Agent was able to get out of sewage by going 'up', could be due to pure luck
- Discoveries in room: Uncertain whether it needs to be included in compacted context or we could utilize
player's knowledge

> A knowledge base, memory of exploration to make agents more capbale

### 7. Observability - Tracing, Logs, Monitoring
Revisited: precise per-phase latency becomes something worth measuring
and needing to query traces without custom UI
As task and tools are growing larger, analyzing via UI is not enough to serve
- Will circle back to analyze viz when Agents execute more requests

### 8. A script to init all services
We need a script to bring up all services
**Build Gems**
- mud_manager
- boukensha (uninstall, build, install, set path boukensharc)

**Start services**
- log_viz
- OTEL, prometheus, grafana

### 9. Seed players bin & Add safe fallback error when player not created
We need to fast seed a player to world and reset players
- Added persona placeholders
> We need to handle per profiles, as might want to add persona to diversify playstyle

### 10. Clean broken world file from Session Logs
- World map is much more cleaner, room nodes are no longer overlapping each other
- Still can't perform zoom nor view un-discovered exit
    > Room inspec should still cache 'exits' despite exits not discovered

### 11. Player identity end-to-end, isolated per-player knowledge
Conduct multiple players at the same time, isolate their journeyon Admin side
- Block agents from seeing the world knowledge by the previously implemented tool room_knowledge
> Enhance log_viz to view World Map and isolated journeys

**Tasked 2 players with separate tasks**
- Room parser is parsing welcome notes from MUD
    - Noir the Pilferess (linkless) is standing here. 
     + Subject: Noir the Pilferess
     + Classified as Mob

    > Might need to later clean this data a@nd/or stop parser from reading welcome notes
- Examiner not working, could be due to of drop of tool room_knowledge
- At 1 iteration, agent decided to check the surrounding streets from the market for a bakery or food shop => Agent literally just circling around to check every room nearby
    - Only the last MUD response from this is passed to the next request
    > Need a navigator

- Visualizer is not parsing the possible exits from MUD response after a tool call. Path viz shows a question mark, but room inspector should know which room's at that exit
- Found out that the all players are sharing knowledge of discoveries:
    - when player unlock a room, all discoveries in that room is now shared to said player
    > Not suppose to share knowledge, player need to inspect room again and gain its own knowledge

    
### 12. Tools catalog, permission and policy
Mentioned in [2]
- Tools grouped by roles
- Add Policy on Registry
- Subtask will have their own Context/Registry and set of tools to optimize no. of tool calls

**Tasked with checking own status and resolve any problems**
Limit the tools, testing on navigation set and room_knowledge only
- Token sent in request is much reduced
- Fell into sewer, still cant figure out how to get out of sewer
- Agents got stuck multiple times trying to get out of sewer, then stop iteration for feedback
    > Who will give feedback in the loop?

- On 2nd try, Agent successfully found fountain and drank, hunger is not resolved. Agent knew 
they need money to buy food. Or look for a free food source
    - When checked status (1st turn 1st iteration), Agent should have known it has no money
    - Should have had a money to get money first then find shop
    > We need a planner

[todo]

## Technical Conclusions
[todo]
- The agents need to have access to its own knowledge/discoveries
- Agents need initiate a plan before executing the task
- We need an orchestrator with different subagents handling different scopes of tasks
- Agents should have access to its own knowledge, but still have to mimic a 'real player' AKA not all knowledge is accessible


## Key Takeaway

- **Observability was the real unlock this week.** Most Week 1 failures were invisible until we exposed request payloads, token composition, and per-room context. Once visible, root causes turned out to be simple (missing system prompt, unsummarized MUD text flooding context) rather than deep reasoning failures.
- **Token growth needs active management, not just measurement.** Tools alone ate 70-90% of the context budget. Front-loading/caching tools and compacting MUD responses helped, but a slow local-model compactor traded token savings for latency — the fix has to be fast enough to not bottleneck the loop.
- **Visibility without structure doesn't make agents capable.** Seeing *what* the agent did (log_viz, tracing, world map) didn't stop it from circling rooms, forgetting earlier discoveries in the same turn, or assuming an answer instead of checking. Agents need persistent knowledge/memory and an explicit plan, not just a better window into their own behavior.
- **Correctness bugs hide in shared state once you scale beyond one agent.** Multiplayer testing surfaced knowledge leaking across players and shared caches after unlocking rooms — issues invisible with a single agent. Isolation boundaries (per-player knowledge, per-player context) need to be verified explicitly, not assumed from single-agent testing.
- **Reducing tool count reduces tokens but doesn't reduce confusion by itself.** Limiting the toolset per subtask cut token usage clearly, but agents still got stuck (e.g. escaping the sewer) without a planner or feedback mechanism to unstick them.
- **The next bottleneck is orchestration, not observability.** With logging/tracing/world-map infra now in place, the gap has moved to: agents lacking a pre-execution plan, no orchestrator to route subtasks to the right scope/tools, and no feedback loop when an agent is stuck — this is the natural next focus for Week 3.
