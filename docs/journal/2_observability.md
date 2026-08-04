## Week 2 Technical Documentation 

## Problems observed in Week 1
These are considered high-risked limitation that needs to be optimized prior to the implementation of Week 2 - when we allow agents to be capable of executing the goal on its own
- The agent is currently highly token-inefficient. 
- As the codebase grows much larger, it's hard for engineer (us) to observe the reasoning process of agent and how it decides tool calling. 
- Log viz is not real time nor human-friendly readable nor interactive making human review and guidance different (with no planning and guidance in place).
- Tool/environment errors: nothing in the loop feeds tool errors back into the next decision. Agent has no error-awareness and proceed as if nothing happens. (week 1)

## Technical Goal

- Optimize token usage, improve observability and human feedback/intervention 

## Technical Uncertainty
[todo]
- I am uncertain that we will need to implement a database in addition to sessions to store observability files
- I am uncertain that reducing list of available tools to only 'useful tool' will defer Agent's capability
- I am uncertain that the limited knowledge and context momery will be enough for Agent to execute complex tasks

## Technical Hypothesis
[todo]
- I think that reducing list of tools sent to LLM Client could potentially cause: 'missing an important tool that could guide Agent to the direct path'
- 

## Technical Observations
- Context are growing too fast depsite no effort for narration
- Agents could not even complete simple task such as: find the bakery and tell me what is on the menu
- Lots of wasted tool calls
- 

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
- Agent was able to get out of sewage, not sure if due to tool world_knowledge. Can't trace tool called. 
    > Should trace tool call
- Discoveries in room: Uncertain whether it needs to be included in compacted context or we could utilize
player's knowledge

### 7. Tracing
Noticed Agent was taking longer time than before
 

## 8. Seed players bin & Add safe fallback error when player not created




## Technical Conclusions
[todo]
- I think the agents need to have access to its own knowledge/discoveries
- I think the agents need initiate a plan before executing the task
-  

- Consideration of injecting into a running agent's turn (pausing it, asking it a question mid-goal, nudging its plan)


## Key Takeaway
