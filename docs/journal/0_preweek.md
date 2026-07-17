## Preweek Technical Documentation 

## Technical Goal
The technical goal is to determine how well an Agent Architecture fit our bussiness use-case.

[Ref 1] Examples of Agent Architecture that scale with Effort:
- An Agent file with referenced files eg. Agent.md, @~/docs/*.md
- Agent Skills driven by main Agent eg. ~/.skills
- Filesystem Subagent driven by Coding Harness or Coding SDK eg. ~/subagents
- AI workflow automation platform eg. n8n
- Use a generic AI Agent SDK that leverages plug and plays generic AI packages.
- Use low level first-party LLM SDKs and write our own agentic loop
- Use REST APIs directly, write our own agentic loop
    - The agentic loop is model-driven orchestration with middleware programmatic guidance
    - The agentic loop is code-driven orchestration

## Technical Uncertainty
- I'm uncertain if a Coding Harness agentic loop is effective enough to drive a non-coding workload.
- I'm uncertain if a LLM model thinking mode is sufficient enough to hold memory and drive decisions for our specific use-case.
- I'm uncertain that a coding harness can interact with the MUD without an interface or an SDK or manage the telnet session.
- I'm uncertain of how many architectures are out there that are efficient for our business use-case as well as pros and cons and whether one architecture outperforms the others

## Technical Hypothesis
- Based on our [Ref 1] I think the agent will struggle to drive the MUD without an interface because we don't we a define API, we are driving commands over a protocol that we need live monitor. Telnet communication seems like a sticking point.
- I think we will need an interface because managing a long-lived telnet session may prove difficult. 
- I think generic models memory will not be capbale enough of navigating and playing a MUD to achieve complex goals. 
- I think we need to implement our own agent with a specialized agentic loop without an SDK because generic primitives for observability, for memory, and our use-case requires specialized implementation. And for the ability to connect broadly with all frontier models and many SDKs will lack one of them

## Technical Observations
- An Agent.md struggled then successfully connected to the MUD but due to pure luck. It could produce temporary scripts but is unreliable in creating a connection to the MUD and need knowledge from the determistic TUI of the MUD
- Agent Skills creation using low model (Haiku 4.5) created vague skill instruction and rigid, hard-coded scripts that struggled to work even with simple task.
- Agent Skills established a stable connection to MUD with a script, and managed commands in MUD with a markdown file, but played inefficiently.
- Using markdown files where the Coding Harness updates memory files produced brittle structure. Agents also forgot to update these files and needed reminder
- Agent's progress/journey is hard to pin down

## Technical Conclusions
- Agent Skills is capable of driving the MUD
- We need better memory management, as well as visibility on token usage and agent's progress/journey.
- Without customized agentic loop the agents could not plan and execute the goals efficiently. And did not consider the different strategies or play style (Player Persona).
- I didn't explore subagents as I do not see the need in having multiple agents working in parallel to achieve a request. Might be useful for game state logging.
- We opened a new technical use-case if we should have our agent handle multiple connections for multiplayer players playing as the same time as co-op is a common factor in MUD that we forget to consider in our design
- We could not explore n8n completely due to technical restraints executing external scripts.
- Implementing our own specialized loops remain technial uncertain and will need to be explored in depth in Week 2.

## Key Takeaway
When we have a specialized use-case like playing a MUD, we cannot leverage only the generic SDKs and Agents because we need specialized tooling and agentic loops.