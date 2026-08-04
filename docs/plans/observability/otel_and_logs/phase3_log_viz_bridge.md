# Phase 3 — `log_viz` bridge

**Depends on:** Phase 2 (`Logger#turn` must already carry `trace_id`).
**Blocks:** nothing downstream (Phase 4/5 don't require this to have
shipped, though Phase 5's README screenshot description assumes it has).

Context: see [`00_overview.md`](00_overview.md)'s "Bridging the two
systems: `session_id` as the join key" section for why this is a link, not
a merged pipeline.

## What to build

- **`log_viz/lib/log_viz/session.rb`** (`Session::Entry`/parsing) — read
  the new `trace_id` field off `turn` events, same pattern as other
  optional/new fields already handled there.
- **`session.erb`** — one small "View trace ↗" link per turn header,
  pointing at `<jaeger_ui_base>/trace/<trace_id>`.
  - Base URL from an env var/setting, defaulting to
    `http://localhost:16686`.
  - Blank/hidden if unset or if the turn predates this feature (no
    `trace_id` on the event) — same graceful-degradation posture as the
    existing `compacted` field, which only renders when present.

## Acceptance criteria

- Opening a session in `log_viz` that was recorded after Phase 2 shipped
  shows a working "View trace ↗" link per turn; clicking it lands on the
  correct trace in Jaeger (same turn, matching timestamps/tool calls).
- Opening a session recorded *before* Phase 2 (no `trace_id` on its `turn`
  events) renders with no link and no error — pure graceful degradation.
- Jaeger UI base URL is configurable and not hardcoded to
  `localhost:16686` in a way that breaks if Jaeger runs elsewhere.
