# Phase 0 decision — driver architecture

Resolves [`orchestrator.md`](orchestrator.md)'s "Open question to resolve
before starting". Not a design doc — just the answer, so Phase 4 has an
unblocked starting point.

## Reading confirmed

Checked `week3_capable/bin/play_players` and `lib/boukensha/repl.rb`
directly: `play_players` spawns `boukensha --player NAME --no-tui` with the
goal piped in as one line of stdin; `Repl#start` reads it, calls
`run_turn` exactly once (`Agent.new(...).run`), then the next `$stdin.gets`
hits EOF and the loop breaks. So today's autonomous play session is
confirmed to be exactly **one `Agent#run` call** — there is no existing
multi-turn entry point for a driver to wrap. `orchestrator.md`'s reading is
accurate as written.

## Answers

1. **Driver shape:** `Boukensha::Session`, as sketched in
   [`orchestrator.md`](orchestrator.md) §4. No alternative existing entry
   point was found — `Boukensha.run`, `Boukensha.repl`, and `Repl` all stay
   untouched per the high-level doc's Alternative B, so the new driver is
   additive, not a wrapper around any of them.
2. **Next instruction after a `continue` verdict:** the literal string
   `"continue"`, per §4's pseudocode. Simplest option that needs no new
   parsing of the Player's wrap-up text; revisit only if Phase 5's
   validation run shows the Player doesn't pick up its own thread well from
   a bare "continue".

Both answers match `orchestrator.md`'s own proposal — no changes to that
doc's §4 pseudocode are needed going into Phase 4.
