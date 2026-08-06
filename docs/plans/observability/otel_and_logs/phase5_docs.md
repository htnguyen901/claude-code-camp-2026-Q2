# Phase 5 — Docs

**Depends on:** Phases 0-4 ideally all shipped (this documents the finished
feature) — can start once Phase 2 is stable even if Phase 3 metrics/bridge
lag slightly, but call out any gaps explicitly rather than documenting
aspirational behavior.

Context: see [`00_overview.md`](00_overview.md) for the rationale sections
this should point back to rather than restate.

## What to build

- **`README.md`'s "What's new in this step"** — same format as
  `14_response_compactor/README.md`:
  - what shipped
  - how to run the stack (`docker compose up` from `week2_observability/otel`)
  - how to point `boukensha` at it (env vars from Phase 1)
  - a screenshot-shaped description of a Jaeger trace and a Grafana
    dashboard (actual screenshots if feasible, otherwise a clear
    description of what one would see)
- Note the Phase 0 collector rationale inline (why not scrape Ruby
  directly — see the overview's "Why push (OTLP)" section) so it isn't
  re-derived later, matching this directory's existing habit of writing
  "why," not just "what."

## Acceptance criteria

- A newcomer following only the README can: bring up the stack, run a
  `boukensha` turn, and find that turn's trace in Jaeger and its numbers in
  Grafana — without reading any other file in this plan.
- The README explicitly states what's out of scope (MCP trace propagation,
  alerting — see the overview's "Not doing" section) so readers don't file
  bugs for known gaps.
- If Phase 1's metrics risk checkpoint failed and metrics shipped as a
  fast-follow rather than in the same pass, the README says so plainly
  instead of describing metrics as already working.
