### Goal

I need to implement a subtask running parallel with the main task player to inspect every room the play goes in. I don't know if the player is currently looking and inspecting every details/items in the room. I can see the world map parser (map tracking) is currently logging and grouping the items/mobs/npc/etc but I'm not sure if it includes all details. I also noticed that the Noticed in log_viz contains long text that's hard to group or quickly identified. For example: 

1. 'A large fountain carved from blue-streaked marble is here, bubbling merrily' - the item here is the fountain, the rest could be characteristic or something else, but main item is the fountain, having that long text is hard to read. Also I think player can drink from the fountain when they're thirsty but that text doesn't appear here. So did player really inspect it fully? If not then inspection here will play a big role in the exploration. 

2. 'An odif yltsaeb is here, walking backwards.', 'A cityguard stands here.', 'An oozing green gelatinous blob is here, sucking in bits of debris' - I assume these are NPCs and/or mobs that could appear in multiple rooms. But all the textual words like 'is here', 'stands here' are not very helpful as I know they are there (found in the room). For this I need a extractor to extract and separate the object from their subjective or description for grouping and searching/filtering purposes. For this I'm thinking of using a local low-level but efficient enough to extract the objective so it adds more cost

3. Room(s) in Log viz are now appears in a list, which is hard to search and filter. In this world map, I expect to be able to filter by room, or search a NPC, mobs, items, etc and view their found locations

4. The discoveries and rooms table now are not scalable. Meaning if the exploration keep going the tables will grow too large to be able to view and audit through scrolling. I need a better solution to vizualize and interact with this on my end. But keep in mind that later in this project I expect to allow Agents to view its history of explorations/discoveries to make decisions and plans too so make sure solution doesn't hinder this.

Questions:
- Is the above implementation built for Ruby specfically and do we need to port it over to Python if the we decided to switch to implementing the Agent in Python?
- Are there any issues regarding loading/executing the viz after this implementation?
- The world map currently pings location and add text when and if a player is actively playing, but I need to refresh the whole page for the ping/data to update. Is there any way I can view the path and exploration in real time without having to refresh?

---

## Plan: structured discoveries, examined-coverage, search/filter, live updates

### Scope decision (resolved before designing further)

"Inspector" could mean three very different things: (a) a purely passive
log/DB-side analyzer, (b) that plus a read-only tool the Player agent can
query mid-turn, or (c) a new agent that itself issues live `examine`/`look
at` commands in the game (interleaved into the player's turn, or as a
second logged-in character). Option (c) is a real behavior change to
`week2_observability/ruby/12_context/` with real risk (spends the player's
own iteration/token budget, or needs a second MUD login and coordination
logic) — a materially different, bigger project than "improve
observability."

**Resolved: build (b).** Everything below stays a passive analyzer living
in `log_viz` (same footprint as the three sibling plans in this directory —
reads `.boukensha/sessions/*.jsonl`, writes only to
`.boukensha/world_map.sqlite3`), plus exactly one small new read-only tool
exposed to the Player agent so *it* can decide to go back and examine
something — the agent remains the only actor that ever sends a command to
the MUD. Option (c) is listed under "Not doing" below; revisit only if (b)
turns out insufficient once the Player agent actually has the tool to use.

### 1. `ContentFact` — structured extraction of room-content lines (addresses concern #2)

New `week2_observability/log_viz/lib/log_viz/content_fact.rb`. Two-tier
extraction, run once per **unique raw content string ever seen** (not once
per sighting — `"A cityguard stands here."` recurs across many rooms, so
the cache key is the content string itself, not `(room, content)`):

- **Tier A — regex fast path**, covering the fixed grammars already visible
  in real captured content lines:
  - `/^(?<art>An?|The)\s+(?<subject>.+?)\s+is here,?\s*(?<clause>.+)?\.?$/i`
    → `"A large fountain carved from blue-streaked marble is here, bubbling
    merrily"` → `subject: "fountain"` is wrong by itself — the naive regex
    captures `"large fountain carved from blue-streaked marble"` as
    `subject`. Real CircleMUD long-descriptions don't put the noun first in
    a way regex alone can reliably split ("large fountain carved from
    blue-streaked marble" — is the head noun "fountain" or "marble"?). So
    Tier A only handles the mechanically fixed *suffix* grammar
    (`is here|stands here|sits here|lies here|floats here`, trailing
    gerund clause) and always emits the **full noun phrase** as a
    candidate `subject` plus the trailing clause separately; it does not
    attempt head-noun extraction. That's Tier B's job.
  - `/^(?<art>An?|The)\s+(?<subject>.+?)\s+(?<verb>stands|sits|lies|floats)
    here\.?$/i` → subject captured cleanly (no trailing clause).
  - Fallback: whole line as `subject`, `clause: nil`, `kind: "unknown"`.
- **Tier B — local LLM fallback**, used only when Tier A's confidence is
  low (multi-word noun phrase with no clean head noun, or the fallback
  case). One tight single-purpose prompt: *"Extract JSON {subject, kind:
  item|mob|npc|scenery, clause} from this MUD room-content line."* Sent to
  a **local Ollama model** — already a zero-network, zero-`cost_per_million`
  backend in this repo (`backends/ollama.rb`, `MODEL_PRICES` in
  `session.rb`) — via a direct HTTP call to `OLLAMA_HOST` (default
  `http://localhost:11434`), independent of the agent process. This
  matches the user's own framing ("local low-level but efficient enough")
  and costs nothing to run repeatedly, but it does cost *latency* per
  unique string — bounded by uniqueness (see caching above), not by total
  sightings.
- Storage: new table
  `content_facts (content_hash TEXT PRIMARY KEY, raw TEXT, subject TEXT,
  kind TEXT, clause TEXT, source TEXT /* 'regex'|'llm'|'fallback' */,
  extracted_at TEXT)`, `content_hash` = SHA-256 of the raw string.
  `room_contents.content` remains the untouched raw source of truth;
  `content_facts` is a derived cache joined by content hash — if it's ever
  missing or wrong, worst case is "unclassified," never data loss (same
  posture as `WorldMap`'s existing corrupt-DB recovery: cache over durable
  source, never a second source of truth).
- Extraction runs lazily inside `WorldMap#refresh!`, only for
  `room_contents` rows with no matching `content_facts` row yet — same
  proportional-to-new-data cost property the rest of `WorldMap` already
  has. `ContentFact` fails soft: if Ollama isn't reachable, the row is left
  `kind: "unknown"` rather than blocking ingestion (see question 2 below).

### 2. Examined-coverage tracking (addresses concern #1)

Today `WorldMap` only handles `tool_result`s from `RoomEcho.location_tool?`
(`look`/`move`/`enter`/`leave`/`flee`) and `SelfState.info_self?`
(`info_self`) — an `examine` or `look at <target>` result is silently
dropped. That's the actual gap behind the fountain question: the plan
can't fabricate "you can drink from it" out of nothing, but it *can* make
visible, per room, which content lines were ever the target of an
`examine`/`look at` call and which weren't — turning "did the player
really inspect it?" from a guess into a queryable fact.

- Extend `WorldMap#handle_tool_result` to also recognize `examine` and
  `look` (when called with a `target`), matching against
  `content_facts.subject` for the current room (case-insensitive substring
  match — MUD `examine`/`look at` targets are player-typed keywords, e.g.
  `examine fountain`, and rarely match a subject string verbatim).
- New table
  `examinations (room_title TEXT, subject TEXT, session_id TEXT,
  turn INTEGER, iteration INTEGER, at TEXT, result_text TEXT,
  PRIMARY KEY (room_title, subject))` — first-ever examination per
  `(room, subject)`, same "first-seen, not every-occurrence" shape as
  `rooms`/`room_contents`.
- New accessors: `WorldMap#unexamined_in(room_title)` and folding an
  `examined: true/false` flag into `WorldMap#discoveries`.
- UI: a per-room "examined ✓ / not yet" marker next to each discovery row,
  and a standalone "unexamined across the map" filter (ties into §4).

### 3. `room_knowledge` — read-only agent tool (the resolved scope's one agent-side change)

A single new tool in `week2_observability/ruby/12_context/`, registered
like any other `RunDSL.tool` (not an MCP tool — it doesn't talk to the MUD,
it reads `log_viz`'s own SQLite file):

```
room_knowledge(room_title: nil, session_id: "default")
  -> { room_title:, examined: [...subjects], unexamined: [...subjects] }
```

- Defaults `room_title` to the session's current room (needs the agent to
  track `current_room` the same way `Session#current_room` already does in
  `log_viz` — a small, independent tracking addition inside the agent's own
  context, not a `log_viz` dependency in that direction).
- Opens `world_map.sqlite3` **read-only** (`SQLite3::Database.new(path,
  readonly: true)`), same path convention as `LOG_VIZ_WORLD_MAP_DB`. WAL
  mode (already enabled by `WorldMap#connect!`) makes concurrent readers
  safe by design — this is exactly the scenario that mode already exists
  to support.
- This is a genuinely new, previously-nonexistent coupling: today
  `log_viz` depends one-way on the agent's `.jsonl` log format; this adds a
  second, opposite dependency — the agent now depends on a schema
  `log_viz` owns (`content_facts`, `examinations`, `rooms`). Keep it
  contained: put the query logic in its own small module,
  `lib/boukensha/world_knowledge.rb`, that touches only those three tables,
  so a schema change is a one-place update on each side, not a scattered
  one. Document the coupling in both this file and
  `player_journey_map.md`.
- This is also the seed of the journal's Technical Conclusion — "agents
  need to have access to its own knowledge/discoveries" — without yet
  committing to how much further that goes (e.g., injecting a summary into
  the system prompt automatically). Ship the tool; let the Player agent's
  own tool-choice behavior show whether it's used before building more on
  top of it.

### 4. Search/filter + scalable UI (addresses concerns #3 and #4)

- Discoveries and rooms move from "load everything into one `<table>` and
  scroll" to server-side filtered, indexed, paginated queries:
  - New indexes: `CREATE INDEX idx_content_facts_subject ON
    content_facts(subject)`, `idx_content_facts_kind ON
    content_facts(kind)`.
  - `/map` gains query params: `?q=` (substring match on `subject`),
    `?kind=item|mob|npc|scenery`, `?room=<title>` — plain GET form inputs,
    no JS required for filtering itself (consistent with house style).
  - Both rooms and discoveries get `LIMIT`/keyset pagination (order by
    `first_seen_at`, default page size ~50, a "next" link carrying the last
    seen timestamp) instead of unbounded `SELECT *`.
- The reason this section matters beyond "make the human's scrolling
  better": the *same* indexed, filtered SQL queries the UI issues are what
  `room_knowledge` (§3) and any future "let the agent browse its own
  history" feature will also issue. Keeping the query path indexed and
  bounded now is what keeps that door open later, per the explicit ask in
  concern #4 — an unbounded `rooms` table today would become an unbounded
  tool-result payload tomorrow.

### 5. Real-time updates without a full page reload (the third open question)

- Today: `<meta http-equiv="refresh">` on `/map`, a full reload.
- Add a small, plain `<script>` (no framework, no bundler — an explicit,
  documented departure from this project's otherwise-JS-free house style,
  scoped narrowly) that polls a new lightweight endpoint (e.g.
  `/map/live.json`) every few seconds and patches only what changed: live
  session marker positions, and a "N new since last check" counter for
  rooms/discoveries (clicking it re-fetches the filtered list from §4
  rather than the whole page). Keep the meta-refresh fallback for
  JS-disabled viewing.
- Considered and rejected for this scope: Sinatra's `stream do |out| ...
  end` (SSE) — works, but holds a Puma worker thread open for the life of
  every connected tab, more operational cost than a local dev/observability
  tool warrants. Plain polling against an already-cheap, already-indexed
  query is simpler and sufficient.

### Schema migration

All new tables (`content_facts`, `examinations`) are additive
(`CREATE TABLE IF NOT EXISTS`, same pattern `WorldMap::SCHEMA` already
uses), so the existing populated `.boukensha/world_map.sqlite3` is
untouched by upgrade — no column is renamed or dropped on `rooms` or
`room_contents`. Historical rows get classified gradually, the first time
each is touched by a `refresh!` after this ships (same "cost proportional
to what's new to *this* table" property, not a blocking migration). For
anyone who wants the whole history classified immediately rather than
waiting for it to accumulate: a small one-off script,
`week2_observability/log_viz/bin/backfill_content_facts`, running
`ContentFact` over every existing `room_contents` row once.

## Answers to the original questions

1. **Ruby-specific, needs a Python port?** No, mostly. `log_viz` (§1, §2,
   §4, §5) only ever reads `.boukensha/sessions/*.jsonl` — a log-format
   contract, not Ruby code — and writes to its own SQLite file; none of
   that changes if the agent's language changes. The one piece that *is*
   language-coupled is `room_knowledge` (§3): it lives inside the agent
   process, so a Python agent needs its own small read-only sqlite3
   module. That's a deliberately thin, self-contained port (a handful of
   `SELECT`s against three tables), not a rewrite of the
   extraction/UI pipeline, which never leaves Ruby/`log_viz`.
2. **Any loading/execution issues after this?** One real one: Tier B
   extraction (§1) needs a local Ollama daemon reachable at `OLLAMA_HOST`
   from wherever `log_viz` runs, which may not be the same host/container
   the agent's own Ollama calls hit. Document the env var; make Tier B
   fail soft (`kind: "unknown"`, ingestion proceeds) if unreachable —
   matches `WorldMap`'s existing "never let an observability feature break
   ingestion" posture (same spirit as its corrupt-DB recovery). No other
   new runtime dependency beyond the already-added `sqlite3` gem.
3. **Real-time without refresh?** Solved in §5 — small polling `<script>`
   patching only live markers + change counters, meta-refresh kept as a
   no-JS fallback. SSE considered and rejected for this scope (see §5).

## Known tradeoffs / risks

- Tier B (LLM) extraction adds ingestion latency proportional to *unique*
  content strings seen so far, not sightings — still a real cost on a
  cold/never-run-before world map with many distinct rooms.
- Fuzzy substring matching between an `examine`/`look at` target and a
  `content_facts.subject` can miss (player types a synonym) or
  over-match (a short subject substring collides with an unrelated one) —
  stated here as a known imprecision, not silently hidden.
- Regex Tier A will still misclassify some builder-authored purple prose
  that doesn't follow the `is here`/`stands here` suffix shape at all —
  those fall through to Tier B or the `unknown` fallback, not silently
  wrong data.
- `room_knowledge` (§3) is a new two-way coupling between the agent and a
  schema `log_viz` owns — a schema change now has to consider both sides
  (mitigated by keeping the query surface in one small module per side,
  per §3).
- The live-update `<script>` (§5) is a deliberate, narrow departure from
  the project's plain-ERB/no-JS house style — scoped to polling +
  DOM-patching only, not a framework.

## Files touched

- `week2_observability/log_viz/lib/log_viz/content_fact.rb` (new) — §1.
- `week2_observability/log_viz/lib/log_viz/world_map.rb` — `content_facts`/
  `examinations` schema, lazy extraction during `refresh!`, `examine`/
  `look at` handling, `unexamined_in`, filtered/paginated accessors (§1,
  §2, §4).
- `week2_observability/log_viz/lib/log_viz/app.rb` — `/map` query-param
  filtering/pagination, `/map/live.json` endpoint (§4, §5).
- `week2_observability/log_viz/views/map.erb` — search/filter form,
  paginated tables, examined/kind badges, polling `<script>` (§4, §5).
- `week2_observability/log_viz/public/style.css` — badge/filter-form
  styling.
- `week2_observability/log_viz/bin/backfill_content_facts` (new, optional
  one-off script) — migration helper.
- `week2_observability/log_viz/test/test_content_fact.rb` (new) — regex
  Tier A fixtures from the real captured lines above (fountain, `odif
  yltsaeb`, cityguard, gelatinous blob), Tier B fallback stubbed/mocked
  (no live Ollama dependency in tests).
- `week2_observability/log_viz/test/test_world_map.rb` — extend for
  `examinations`, `content_facts` caching-by-content-hash, filtered/
  paginated queries.
- `week2_observability/ruby/12_context/lib/boukensha/world_knowledge.rb`
  (new) — §3, the one agent-side file.
- `week2_observability/ruby/12_context/lib/boukensha/tools/*` or wherever
  built-in (non-MCP) tools are registered — wire `room_knowledge` in.
- `.boukensha/settings.yaml` — no schema change needed; documents
  `LOG_VIZ_WORLD_MAP_DB` / `OLLAMA_HOST` if not already set.
- `docs/plans/observability/player_journey_map.md` — note the new
  agent-facing coupling introduced by §3 (that plan's original claim
  "no agent behavior change" no longer holds project-wide once this ships,
  even though `log_viz` itself is still unchanged in that respect).

## Not doing (out of scope for this pass)

- An active in-game Inspector agent that itself calls `examine`/`look at`
  live (interleaved into the player's turn or via a second MCP session) —
  the rejected option (c) from the scope decision above. Revisit only if
  the read-only `room_knowledge` tool proves insufficient once the Player
  agent actually has it to use.
- Injecting discoveries/examined-state automatically into the Player's
  system prompt or context — §3 ships a tool the agent can *choose* to
  call, not an automatic context injection. A separate decision, if wanted
  later.

## Feedback
1. `ContentFact` — structured extraction of room-content lines (addresses concern #2) 
    => just go with Tier B. I will need to run a one-time extractor on historical discoveries. But for ongoing and future discoveries I need that subtask to run in parallel. For now we don't mind the latency. Will revisit if need
2. I have copy the week2_observability/12_context to week2_observability/13_room_inspector. Keep 12_context as source of truth. Do not implement anything here. Please execute your plan to week2_observability/13_room_inspector and week2_observability/log_viz. Keep documentation reference and targets updated 

## Implemented (deviations from the original design, as shipped)

- **§1, Tier A dropped entirely**, per feedback #1 — `ContentFact` is
  Tier-B-only (`log_viz/lib/log_viz/content_fact.rb`), one Ollama
  `/api/generate` call per unique raw string, cached by content, fails soft
  to `kind: "unknown"` (`source: "fallback"`) on any error.
- **§1, "runs in parallel" implemented as a background thread**, not a
  queue/job system: `WorldMap` opens a *second* SQLite connection (its own
  `db_path`, WAL mode already shared) on a dedicated `Thread`, polling for
  unclassified `room_contents` rows and classifying one at a time. This
  keeps request handling (`refresh!`, `/map`) and session-log ingestion
  completely decoupled from LLM latency, matching feedback #1's "latency is
  fine, just don't block ingestion." `content_fact_worker: false` +
  injected `content_fact_extractor:` make this deterministically testable
  (see `log_viz/test/test_world_map.rb`) without a live Ollama daemon.
- **§1, one-time backfill**: `log_viz/bin/backfill_content_facts`, using a
  new public `WorldMap#backfill_content_facts!` that runs the same
  extraction synchronously to completion — one method shared by both the
  background worker and the one-off script, not two implementations.
- **§2, examinations keyed by the raw typed target, not a resolved
  content_facts.subject.** The plan's original PK sketch implied resolving
  `examine <target>` to a `content_facts.subject` at write time; shipped
  instead as `examinations(room_title, subject=<player-typed text,
  lowercased>, ...)`, with the fuzzy case-insensitive substring match
  (either direction) happening at **read** time
  (`WorldMap::EXAMINED_EXISTS_SQL`, reused by `#discoveries`' `examined`
  flag and `#unexamined_in`/`#examined_in`). Reason: `ContentFact`
  classification is asynchronous (see above) — the subject for a room's
  content may not exist yet at the moment a player examines it, so
  resolving at write time would silently under-record. Same known
  imprecision either way (typed synonyms can miss/over-match), just
  deferred to query time instead of baked into storage.
- **§3, `room_knowledge(room_title:)` has no `session_id`-based "current
  room" default** — ships as documented in the plan as a possible future
  addition, not built here: the tool requires `room_title` explicitly
  (every backend's `to_tools` already marks all declared `Tool#parameters`
  keys as schema-`required`, so this is enforced, not just suggested). The
  agent already has its last `look`/`move` result in its own transcript, so
  this needed no new tracking machinery to be useful. `13_room_inspector/
  lib/boukensha/world_knowledge.rb` holds the query logic;
  `13_room_inspector/lib/boukensha_loader.rb` registers the tool via the
  same `RunDSL` block mechanism every other `Boukensha.run`/`.repl` caller
  uses — no changes to `12_context`.
- **§4/§5 shipped as designed** — `/map` query-param filtering
  (`q`/`kind`/`room`/`examined`), keyset pagination (`before`/
  `rooms_before` cursors) on both the discoveries and rooms tables
  independently, `/map/live.json` polling (~5s) patching only the live-
  session table/banner and a "N new since load" counter, `<meta refresh>`
  kept as the no-JS fallback.

## Follow-up: `tasks.content_fact` in settings.yaml

Later feedback: move `ContentFact`'s config into `.boukensha/settings.yaml`
the same way `tasks.player` is configured, rather than env vars/hardcoded
constants — "so we can set provider, model, or even scope of permissions or
tools allowed for this task."

**Shipped**: `log_viz/lib/log_viz/settings.rb` (new) reads a
`tasks.content_fact` block —

```yaml
tasks:
  content_fact:
    provider: ollama
    model: gemma4
    # host: http://localhost:11434   # optional; OLLAMA_HOST env still overrides this
```

— and `WorldMap` builds its default extractor from it (`host`/`model`
threaded into the real `ContentFact.extract` call; see
`test_default_extractor_reads_model_and_host_from_settings_yaml` in
`test_world_map.rb`). `content_fact.rb`'s `DEFAULT_HOST`/`DEFAULT_MODEL`
constants are now just the last-resort fallback for direct callers (tests),
not the real config path.

**Deliberately not full parity with `Tasks::Base`**: `tasks.player.provider`/
`.model` *raise* if missing (`Player` has no sensible default). `content_fact`
keeps this feature's existing fail-soft posture instead — missing
settings.yaml, a missing `tasks.content_fact` block, or a missing key all
silently fall back to `ollama`/`gemma4`/`http://localhost:11434` rather than
raising, so `log_viz` keeps working with zero configuration. `host` is the
one field that stays primarily env-driven (`OLLAMA_HOST` wins over
`tasks.content_fact.host` if both are set) — deliberately asymmetric with
provider/model, for the same reason the agent's own `ollama_host:` argument
was never a `tasks.player` setting either: it's per-machine network
placement, not a task policy choice.

**"Scope of permissions or tools allowed for this task"** — not built.
`ContentFact` never calls a tool (it's one text-in/JSON-out classification
call), so there's nothing to scope yet. The settings block is nested under
`tasks.<name>`, the same family as `tasks.player`, specifically so a future
task that *does* need a tool/permission allowlist has an obvious, consistent
place to add one — not designed in speculatively here.

**Also**: Ollama ended up installed directly inside WSL (this repo's actual
dev environment), not on the Windows host — sidesteps the WSL2 NAT
networking question entirely (no gateway-IP lookup, no Windows firewall
rule, no `OLLAMA_HOST` override needed). See `log_viz/README.md`'s "Setting
up Ollama" section for the install steps and why the Windows-side install
wasn't reused.

## Follow-up: description-embedded mentions

Bug report: a real captured room echo —

```
The General Store
You are inside the general store.  All sorts of items are stacked on shelves
behind the counter, safely out of your reach.
A small note hangs on the wall.
[ Exits: s ]
A Peacekeeper is standing here, ready to jump in at the first sign of trouble.
A grocer stands at the counter, with a slightly impatient look on his face.
```

— never surfaced "items on the shelves" or "the note on the wall" as
discoveries, only the Peacekeeper and the grocer. This looked at first like
"the room inspector only reads the very last subject," but that wasn't
accurate: both NPCs *were* correctly captured. **Root cause**: everything
before `[ Exits: ]` is `RoomEcho.parse`'s `description` field (the narrative
paragraph); only the "X is here"/"X stands here" bullet lines *after*
`[ Exits: ]` ever became `room_contents` rows and got fed to `ContentFact`.
Prose-embedded mentions — a real, common CircleMUD pattern for anything the
builder didn't bother itemizing — were structurally invisible to the whole
discoveries/examined-tracking pipeline, not merely misclassified.

**Shipped**: a second, parallel extraction pipeline reusing the existing
storage/query layer end to end —

- `ContentFact.extract_mentions(description)` (`content_fact.rb`) — one
  Ollama call per room description, asking for zero-or-more `{quote,
  subject, kind, clause}` mentions instead of `.extract`'s exactly-one.
  Same `{mentions:, source: "llm"|"fallback"}` fail-soft shape as `.extract`.
- `room_description_scans(room_title PRIMARY KEY, source, scanned_at)` (new
  table) — one row per room tracks whether its description has been
  scanned yet, mirroring `content_facts`' `source`/retry-cooldown shape so
  a `fallback` scan (Ollama unreachable, malformed reply) is retried later
  and a real `"llm"` scan (possibly zero mentions found) is not.
- `WorldMap`'s background worker thread now drains two queues — unclassified
  `room_contents` first, then unscanned room descriptions, then sleep — not
  a second thread; one slow/unreachable Ollama daemon already explains why
  either queue would stall, so a second thread would just double the idle
  polling.
- `WorldMap#backfill_description_mentions!` — the one-off migration
  counterpart to `#backfill_content_facts!`; `bin/backfill_content_facts`
  now runs both passes.
- Each accepted mention is written into `room_contents` (same table/shape a
  real itemized line would produce) plus its `content_facts` classification
  — the rest of the pipeline (discoveries, examined-tracking,
  `room_knowledge`) needed zero changes, since a mention row is
  indistinguishable from a bullet-line row once stored.

**Real-world discovery, found by actually running the backfill against the
live 45-room `world_map.sqlite3` (not just hand-written unit tests)**:
gemma4 almost never followed "respond with a JSON array, even for one
match" — nearly every room came back as a single bare `{"quote": ...}`
object instead of `[{"quote": ...}]`, which the original parser treated as
a hard failure (all 45 rooms scanned to `source: "fallback"` on the first
real run). Fixed two ways: the prompt now states the array requirement more
forcefully ("Never respond with a single bare object"), and
`as_mention_array` treats a bare hash with a `"quote"` key as a one-element
array rather than an error — small-model instruction-following is
unreliable enough that defending against the *common* failure shape beats
relying on the prompt alone. Regression test:
`test_extract_mentions_treats_a_single_bare_object_reply_as_one_mention`.

**A second real-world failure, found the same way, after fixing the
first**: once replies were actually being parsed, one room's scan
(`A Scraggly Trail`, a room whose description never mentions a note)
produced a mention `"a small note hangs on the wall"` — a phrase that
belongs to *The General Store*'s description, not its own. The model
invented (or cross-contaminated from) content that was never in the text it
was given, despite the prompt explicitly requiring a verbatim quote. Fixed
by holding the reply to that same verbatim standard: `extract_mentions` now
drops any mention whose `quote` isn't actually a (whitespace-normalized,
case-insensitive) substring of the description it was extracted from,
before it's ever written to `room_contents`. This is a precision-over-
recall choice — a hallucinated quote is silently dropped rather than
attributed to the wrong room, at the cost of also dropping a real mention
that happens to be misquoted; `source: "llm"` still records the scan as
successful either way (a hallucination being caught isn't a scan failure).
Regression test:
`test_extract_mentions_drops_a_quote_that_does_not_actually_appear_in_the_description`.
Verified against live data: after purging the one bad `room_contents` row
and re-running the backfill, `A Scraggly Trail` came back clean and *The
General Store* correctly produced `"A small note hangs on the wall."` this
time.

## Follow-up: examination results as a "keeper," not just a checkbox

Bug report: the discoveries table already showed a &check; **examined**
badge for the grocer (`examinations.result_text` was captured by
`WorldMap#record_examination` from the moment §2 shipped), but the actual
text of what `examine grocer` printed back — a real gameplay clue — was
captured and then never surfaced anywhere, in the UI or to the agent. "Was
this examined" was a checkbox with no memory of *what was learned*.

**Shipped**:

- `WorldMap::EXAMINATION_RESULT_SQL` — the same fuzzy room-scoped
  subject-match as `EXAMINED_EXISTS_SQL`, but selecting
  `examinations.result_text` (most recent match, `ORDER BY ex.at DESC LIMIT
  1`) instead of a boolean. `#discoveries` now returns an
  `examination_result` field alongside `examined`.
- `/map`'s discoveries table gained a "Findings" column showing it
  (truncated to 140 chars via the existing `truncate` helper; `—` when not
  examined).
- `RoomEcho.clean_reply` (new) — `#record_examination` was storing
  `result_text` with the trailing MUD status-prompt line
  (`"...\n\n21H 100M 83V (news) (motd) > "`) still attached, which would
  otherwise leak into the UI as noise. Mirrors `#parse`'s existing
  `PROMPT_RE`-based filtering of a room's `contents` lines, applied to a
  non-room-echo reply (an `examine`/`look at <target>` result isn't itself
  parseable by `#parse` — no title/Exits line — so it needed its own
  entry point).
- `13_room_inspector/lib/boukensha/world_knowledge.rb`'s `room_knowledge`
  tool: `examined` changed shape from a bare subject-string array to
  `[{subject:, result:}, ...]` (duplicating `EXAMINATION_RESULT_SQL` the
  same way it already duplicated `EXAMINED_EXISTS_SQL`, for the same
  different-process reason). `unexamined` is unchanged — there is by
  definition no result to report for those yet. This is the actually
  load-bearing half of the fix: a human can always re-read the session
  transcript, but the agent's own stated reason to call `room_knowledge` at
  all (per its tool description) is deciding whether it's worth spending a
  turn re-examining something — having the remembered answer inline means
  it doesn't have to.

Verified against live data: `The General Store`'s grocer discovery row now
carries `examination_result: "A tall grocer, who moves two 200 pounds bag of
flour around on his shoulders.\n\nThe grocer is in excellent condition.\n\n
The grocer is using:\n<wielded>"` — a real answer, not a stale prompt-line
artifact.