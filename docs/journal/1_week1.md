## Preweek Technical Documentation 

## Technical Goal
The goal is to build a baseline agent that has all the common components of building any kind of agent

## Technical Uncertainty


## Technical Hypothesis


## Technical Observations

**Agent Loop**
- OpenAI requires content to be string and not null
- Running examples on model gpt-4o-mini, Agents start wonder to search in random paths, open random files (fail to read README.md) 
- Increased to model gpt-5.4-mini, Agents successin 2 iterations
- Reduced back to gpt-4o-mini but add to prompt: ".. README.md in the current folder...", Agents success in 3 iterations

## Technical Conclusions


## Key Takeaway
