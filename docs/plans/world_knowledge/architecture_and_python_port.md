# `room_knowledge`/`WorldKnowledge` — architecture notes and the Python-port question

Written 2026-08-04, as a design-question writeup — not an implementation
plan yet. Captures how `room_knowledge` currently works, a structuring
critique, and the options for porting Boukensha to Python. Revisit this
when the Python port is actually scheduled and turn the "Porting to
Python" section below into a real implementation plan.

## What `room_knowledge`/`WorldKnowledge` do

`WorldKnowledge.room_knowledge(room_title:)`
(`week2_observability/ruby/13_room_inspector/lib/boukensha/world_knowledge.rb`)
is a **read-only SQL query layer** over `log_viz`'s `world_map.sqlite3`. It
does no extraction or writing itself — `log_viz`'s `WorldMap`
(`week2_observability/log_viz/lib/log_viz/world_map.rb`, a separate,
independently-running Ruby process — the Sinatra app) is what continuously
tails `.jsonl` session logs and populates `content_facts`/`room_contents`/
`examinations` in the background, whether or not an agent happens to be
running at the time. `room_knowledge` just opens that same file
`readonly: true` (WAL mode is what makes two independent processes safely
sharing one SQLite file possible) and answers: *"of everything ever noticed
in this room, what have I already examined (and what did it say), and what
haven't I?"*

## The flow

```
log_viz process (background, always running independently)
  .jsonl logs -> WorldMap#refresh! -> world_map.sqlite3
                                           ^ (read-only)
Boukensha agent process
  boukensha_loader.rb: Boukensha.repl { tool "room_knowledge" { ... } }
    -> registers it, same as any other tool
  Registry#tool -> Context#register_tool -> @context.tools["room_knowledge"]

  every turn:
    PromptBuilder#to_tools -> backend#to_tools(@context.tools)
      serializes ALL registered tools (MCP-derived + room_knowledge)
      into the provider's native function-calling schema
    model sees room_knowledge in its tool list, alongside
      tbamud__look/move/examine/... -- no special-casing
    model decides to call it (or not) -- ordinary LLM tool-choice
    agent.rb#handle_tool_calls -> @registry.dispatch("room_knowledge", args)
      -> Registry#dispatch: tool.block.call(**args)
         -> WorldKnowledge.room_knowledge(room_title: ...)
    result stringified back into context as a tool_result message
```

`agent.rb`'s `@registry.dispatch(name, args)` is the exact same dispatch
path for `room_knowledge` and every `tbamud__*` MCP tool. The model, the
prompt-building, and the dispatch loop treat them identically — nothing
distinguishes a locally-implemented tool from an MCP-derived one once
registered.

## Is it gated? When would it fire?

Yes — normal tool grant, called only when the model chooses to
(`boukensha_loader.rb`: *"nothing injects its result automatically"*). The
intended use, per its own tool description: after a `look`/`move` reveals
room contents, call `room_knowledge` before deciding what to `examine`
next, so the model doesn't burn a turn re-examining something it already
has an answer for. This is explicitly flagged in the plan doc as
**unvalidated** — *"let the Player agent's own tool-choice behavior show
whether it's used before building more on top of it"*
(`docs/plans/observability/room_world_inspector.md` §3). Nothing currently
measures whether the model actually calls it in practice.

## Structuring critique — should this be an MCP server instead (given `tools/mcp.rb` already exists)?

Legitimate question, and the code half-admits it — `world_knowledge.rb`'s
own header comment calls this *"the one deliberate two-way coupling this
step introduces."* Compare:

- `tools/mcp.rb` is a **generic protocol adapter**: point it at any MCP
  server (stdio transport, JSON-RPC), it introspects `tools/list` and
  registers whatever comes back. It knows nothing about the MUD
  specifically — that's why it's reusable.
- `room_knowledge` is a **hand-written Ruby method that duplicates SQL**
  (`EXAMINED_EXISTS_SQL`, `EXAMINATION_RESULT_SQL`) that also lives in
  `log_viz/lib/log_viz/world_map.rb`. Every `log_viz` schema change (one
  recent session alone added a whole new column, `result_text`, plus new
  matching SQL) means updating both copies by hand, in two different
  repos/languages, with only a code comment as the reminder.

Not "wrong" for a single-language, single-machine setup — it avoids
standing up a whole second process/transport for what's one `SELECT` — but
the schema-duplication risk is real and has already bitten once
conceptually.

## Porting to Python — the important part, revisit as a real plan later

Two options:

1. **Rewrite the query logic in Python** (stdlib `sqlite3`, trivial, ~80
   lines). But now `EXAMINED_EXISTS_SQL`/`EXAMINATION_RESULT_SQL` is
   duplicated in **three** places (log_viz-Ruby, boukensha-Ruby,
   boukensha-Python) instead of two — worse, not better. Every future
   `log_viz` schema change needs three synchronized edits.

2. **Turn `log_viz` itself into an MCP server for `room_knowledge`** (a
   small addition — it already owns `WorldMap` and an open DB connection;
   wrap `room_knowledge(room_title:)` as one MCP tool over stdio, or an
   HTTP endpoint on the existing Sinatra app), registered via
   `mcp_servers:` in `settings.yaml` exactly like `mud-manager` is today. A
   Python Boukensha then needs **zero new code** for this beyond the MCP
   client it already needs for the MUD — `tools/mcp.rb`'s registration
   pattern is already fully generic and language-agnostic on the consuming
   side. Schema and query logic live in exactly one place (Ruby, inside
   `log_viz`, which isn't part of the port at all) — the duplication
   problem disappears rather than growing a third copy.

**Recommendation for the future implementation plan**: if the Python port
is real, promote `room_knowledge` to a proper MCP server on the `log_viz`
side *before* porting — it's a smaller change now than after maintaining
two agent-language codebases against a hand-duplicated schema.

Not scoped or started as of this writing. See
`docs/plans/python_port/` for the port plan itself once it exists, and
cross-link this doc from there.
