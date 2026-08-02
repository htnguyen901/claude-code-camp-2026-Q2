## Week 2 Technical Documentation 

## Problems observed in Week 1
**These are considered high-risked limitation that needs to be optimized prior to the implementation of Week 2 - when we allow agents to be capable of executing the goal on its own
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

## Technical Hypothesis
[todo]
- I think that reducing list of tools sent to LLM Client could potentially cause: 'missing an important tool that could guide Agent to the direct path'
- 

## Technical Observations
- Memory are stored in context and it grows fast
- Tasked to find the bakery but decided to find bar instead
- Tools takes up 70-90% of the context
- When Agent cannot log to MUD due to refreshed game data, boukensha just throws an error > Should have safe-landing to asked user to create user to play

**Task with find Big Minotaur**
- Agent called: `tbamud__info_world(kind: "help", filter: "newbie", session_id: "default")`, MUD returns with text snippet: 
    `Once promoted GOTO 3 and read through the Builder Academy's tutorial 
    zone. Your third task as a builder is explained under HELP TRIAL. `
    Agent then decided the target should be in `GOTO 3` ?!
    > Agents fail to understand the context of MUD, as well as the odd usage of languague in MUD

**Improve Visibility and Add World Map Tracking**
- Items/NPC/mobs are now extracted but contains redundant text: `A knight is guarding the entrance.`, `A waiter is here.`
    > filler words like 'is here' is not needed => might need a word parser to extract object, then location/status of object if needed

**Non-technical Issue**
- Game data does not get saved, refreshed every time reset PC


Q:
- Are all the tools (57) are being passed to request?
## Technical Conclusions
[todo]
- Consideration of injecting into a running agent's turn (pausing it, asking it a question mid-goal, nudging its plan)


## Key Takeaway
