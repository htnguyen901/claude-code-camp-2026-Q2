## Week 1 Technical Documentation 

## Technical Goal
The goal is to build a baseline agent that has all the common components of building any kind of agent

## Technical Uncertainty
- I'm uncertain whether a hand-built agentic loop (tool registry, prompt builder, logging, REPL — no SDK) is enough on its own to drive an open-ended objective, or whether it needs an explicit planning component from day one.
- I'm uncertain whether a cheap/small model (gpt-4o-mini) is capable enough for reliable tool-calling on this workload, or whether baseline results will really be measuring prompt-scaffolding quality instead of agent-architecture quality.
- I'm uncertain whether we just need an SDK for interacting with the MUD or is there any use cases for an MCP server.
- I'm uncertain how much of "the agent got a bad result" is actually a transport/session bug versus a genuine model reasoning failure.
- I'm uncertain whether the agent can recover from tool errors it doesn't understand (e.g. MUD usage errors) without an explicit error-handling or self-correction step in the loop.


## Technical Hypothesis
- I think our own agentic loop will match a coding-harness loop for straightforward tool-calling, but will reproduce preweek's planning gap on any objective that needs multi-step strategy rather than reactive per-turn tool use.
- I think we will need not to implement a MCP
- I think smaller models can be brought closer to larger-model performance with more explicit prompting. But it will make baseline results sensitive to prompt wording, not just model choice.
- I think without an explicit planning or error-awareness step, the agent will keep calling malformed commands after receiving a clear usage error, because nothing in the loop routes tool errors back into its decision-making.

## Technical Observations

**Summary**
- Model capability materially affects tool-use reliability, but explicit prompting can partly close the gap: gpt-4o-mini wandered and misread paths, gpt-5.4-mini succeeded in 2 iterations, gpt-4o-mini + an explicit path hint succeeded in 3.
- MCP was the right call for Ruby↔other-language interfacing. boukensha's client was already generic and server-agnostic; the only real gap was a missing MudManager MCP *server*, solved by auto-reflecting `Primitives` methods into tools.
- The first end-to-end run was blocked by three unrelated bugs that all produced the *same* symptom ("no active MUD connection" / "server closed the connection") — stale config, a missing `PATH` entry, and a Bundler env leak into the spawned child process. Identical symptoms, unrelated causes, surfacing child stderr cut diagnosis time from hours to seconds.
- The real tbaMUD server diverges from the FakeMud fixture in ways `Session#login` never accounted for: a new-character creation flow, and a linkdead/"Reconnecting" path that leaves text unconsumed in the buffer.
- That unconsumed buffer text caused tool results to be off by one — a tool call would silently receive the *previous* command's leftover output instead of its own, because `read_until` only consumes up to the matched pattern and the Reconnecting branch never drains what's left.
- Found and fixed dispatch bug: the LLM called `look` with an empty target plus a preposition, which `Primitives.look` turned into the literal invalid command `"look at"`.
- Given a vague objective ("log in and defeat the Big Minotaur"), the agent has no plan and wanders through a wide range of commands, and visibly ignores clear tool-usage errors instead of correcting course.
- The agent also struggles with interactive MUD UI conventions it was never told about — e.g. it can recognize from context that it needs a light source in a dark room but can't act on that, and gets stuck in a pager it doesn't know how to quit despite the pager's instructions being right there in the text it received.

- Found and fixed a backend api bug: the `/v1/chat/completions` did not return the reasonings, the agent loop failed to acknowledge its mistake and reasoning next step (mentioned aboved). The `phase: plan` added in 12_context was a big milestone helping the agents reasoning for every steps to execute the goal


## Technical Conclusions

- MCP is worth the development now we need to be able to make use of `mud_manager` regardless of what language Agent is developed on. Reflecting `Primitives` into tools automatically means the daemon's tool surface can never drift from what the gem actually supports. A new primitive is a new tool for free, in every language, without touching the daemon.
- Isolate-testing a spawned subprocess in the same shell we're debugging from isn't sufficient; it has to be spawned the same way the real caller spawns it.
- A generic transport (MCP) does not make the thing behind it generic. The MUD-specific bugs (new-character flow, linkdead reconnects, `look`'s preposition/target coupling) all live one layer below MCP, in `Primitives`/`Session`/`ToolCatalog` — the protocol choice never had to change to fix any of them.
- "Garbage in, garbage out" recurred every time we investigated a bad-looking agent response: the off-by-one buffer bug, the Bundler env leak, and the stale reconnect-banner text all looked like model or MUD misbehavior until traced to the session/transport layer. Before blaming the model, verify what it actually received.
- The baseline loop (tool registry + prompt builder + logging + REPL) covers mechanics but not strategy. It has no planning primitive. This directly confirms preweek's uncertainty about needing a specialized planning step, not just a specialized loop.
- Tool/environment errors are currently a dead end for the agent: it receives a clear MUD usage error and proceeds as if nothing happened, because nothing in the loop feeds tool errors back into the next decision. Error-awareness needs to be a first-class baseline component alongside the tool registry and prompt builder, not an afterthought.
- Model choice and prompt specificity trade off against each other, which makes them hard to evaluate independently: gpt-4o-mini only matched gpt-5.4-mini's outcome after we added an explicit path hint to the prompt. Any future model comparison needs to hold prompt scaffolding constant, or the result measures prompting, not the model.
- The off-by-one buffer bug means tool-call history can't currently be trusted for evaluation. An "observation" the agent reasoned over may belong to a different command than the one it's attributed to. This should be fixed and specifically regression-tested before using transcripts to judge agent quality.


## Key Takeaway
- A hand-built agentic loop (tool registry + prompt builder + logging + REPL) is sufficient for mechanical tool-calling, but it is not sufficient on its own to drive an open-ended objective: without a planning primitive and without error-awareness feeding tool failures back into the next decision, the agent wanders and repeats invalid commands. Planning and error-handling are baseline components, not optional extras — confirmed by the `phase: plan` milestone in 12_context measurably improving reasoning per step.
- MCP was worth the added complexity for Ruby↔other-language interfacing
- Most "the agent/model did something dumb" symptoms we investigated were actually transport/session bugs (stale config, PATH gaps, a Bundler env leak, an unconsumed reconnect buffer causing off-by-one tool results) wearing the same costume ("no active MUD connection", garbled observations). The standing rule going forward: verify what the model actually received before attributing a bad result to reasoning or model choice.
- Model capability and prompt specificity are entangled, not independent variables — gpt-4o-mini only matched gpt-5.4-mini after an explicit path hint was added. Any future model-comparison baseline must hold prompt scaffolding fixed, or the comparison silently measures prompting instead of the model.