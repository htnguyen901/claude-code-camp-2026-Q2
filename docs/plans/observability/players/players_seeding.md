## Goal

I need create a script to seed a player into
the MUD world. This stems from an issue where sometimes the world refreshes
and I have to manually create the list of players again which is annoying

- The very first player created in the MUD will be the 'Admin' with 'the Implementor'
role and will have high levels, etc. So should always check if this admin
is already created otherwise we might accidentally create a player with
admin power and that will destroy the gameplay. If the admin doesn't exist
then create admin but know that this admin is not playable by the agent
at the moment

- We should be able to seed multiple users at once. We should create a
folder on disk to store these player profile and seed when needed.

- If a player already existed then should ask user whether to skip the creation
of that user or to delete and seed new

In the thought process of this, I figure I also need to build a proper player profile

- This is potential future developement: each player might have their own persona,
playstyle, risk mode, thought process, etc. Agents then will need to mimic these persona
to play the game as 'true players'. This steps only need to construct and init the player
profiles/persona. There is no implementation of Agent loop yet since it is a future enhancement
only after I'm able to build a capable Agent loop

- For that, I feel like these players profiles should live in .boukensha/, but open to other
options if with better reasonings

---

## Research findings

- **No code path creates a new character today.** `MudManager::Session#login`
  (`week0_explore/mud_manager/lib/mud_manager/session.rb:202`) only implements
  the *existing*-character login dance (name → password → `Welcome` /
  `Reconnecting` / `Wrong password`). Both `mud_manager/README.md` and
  `docs/journal/3_capable.md` explicitly call out that the new-character flow
  (name confirmation, password + confirm, sex, class, race) is a different,
  unimplemented state machine. This is the actual gap the plan needs to close.
- **Admin is a side effect of creation order, not a name.** Per
  `week0_explore/HOW_TO_PLAY.md`, tbaMUD/CircleMUD makes *whichever* character
  is created first on a fresh world the implementor (level 34, "the
  Implementor", top admin role) — it isn't tied to the name `admin`. That
  means seeding order matters: on a freshly-reset world, the seeding script
  must create a known, fixed admin character *before* any regular player
  profile, or the first regular profile seeded silently becomes admin.
- **`MudManager::Session` is the right transport to extend, not replace.** It
  already owns telnet/IAC handling, prompt detection (`read_until`,
  `read_until_prompt`, `PROMPT_SENTINEL = "> "`), and the empirically-derived
  regexes for the existing-login dance. `mud_manager` is intentionally
  MUD-generic (see `docs/plans/mud_manager/generic_interfacing.md`) — no
  concept of "boukensha", "player profile", or "persona" belongs in it. A
  character-creation state machine, however, *is* MUD-generic and belongs
  there, parallel to `#login`.
- **No sqlite table for player accounts.** `.boukensha/world_map.sqlite3` is
  exclusively owned/written by `log_viz` for the world-knowledge map (rooms,
  edges, sessions, content facts — see `docs/plans/world_knowledge/`). Nothing
  in it is about player accounts, and precedent in this repo is to keep that
  file single-purpose. Player profiles should not live there.
- **YAML is the repo's one config idiom.** `.boukensha/settings.yaml` (read via
  `Boukensha::Config#dig`, `week2_observability/ruby/15_observability/lib/boukensha/config.rb`)
  is the only structured-config format anywhere in the repo — no JSON/TOML
  configs exist. Player profile files should follow this, as the plan already
  suspected.
- **`week2_observability/bin/`** already holds small Ruby-adjacent utility
  scripts for this step (`build_gems`, `start_services`), giving a natural,
  consistent home for a new `seed_players` script without gemspec changes —
  it can just `require "mud_manager"` (installed system-wide via
  `build_gems`).
- **The exact new-character telnet prompts are not yet confirmed against the
  live server.** `Session#login`'s regexes were derived empirically against
  the real dockerized tbaMUD (per its inline comments on "real-server
  quirks"), and the new-character flow must be derived the same way — no
  CircleMUD/tbaMUD source is vendored in this repo to read the prompts from
  statically. This is called out explicitly as an implementation-time step
  below, not assumed up front.

## Design

### 1. `MudManager::Session#create_character` (new-character telnet flow)

Add a sibling to `#login` in `session.rb` that drives CircleMUD's `nanny()`
new-character state machine. Both flows start identically — send a name at
the `By what name do you wish to be known?` prompt — and only diverge on the
server's response:

- Existing name → server asks for `Password:` directly (today's `#login`
  path).
- Unrecognized name → server asks to confirm the spelling (`Did I get that
  right, <Name> (y/n)?`), then walks: confirm → new password → confirm
  password → sex → class → (race, if the server build has races enabled) →
  MOTD/press-enter → into the game.

Because the branch point is shared, refactor slightly:

```ruby
def identify(name)
  read_until(/By what name do you wish to be known.*\?/i)
  send_command(name)
  read_until(/Password|Did I get that right/i)
end
```

`#login` and the new `#create_character` both call `identify` and branch on
its result, instead of `#login` unconditionally assuming an existing name.
`#create_character(name, password, sex:, char_class:, race: nil)` drives the
confirm → password → confirm-password → sex → class → (race) → enter-game
sequence using the same `send_command` / `read_until` primitives already in
the file, ending the same way `#login`'s fresh-`Welcome` branch does
(`send_command(:return)`, `send_command(1)`, `read_until_quiet`).

**The exact prompt regexes must be captured against the live server** the
same way `#login`'s were (connect via `telnet localhost 4000` per
`HOW_TO_PLAY.md`, walk a real new-character creation, transcribe the literal
prompt text) before wiring the regexes — do not guess at CircleMUD's stock
prompt strings, since tbaMUD forks routinely reword them.

This addition is MUD-generic and belongs in `mud_manager`, not in a
boukensha-specific script — any future client (Python port, MCP tool) gets
character creation for free once it's here. Expose it through
`McpServer` as well (a `create_character` MCP tool alongside `connect`) so
it's usable outside the seeding script too, mirroring how `connect_session`
already wraps `#login`.

### 2. Player profile storage: `.boukensha/players/`

One YAML file per profile, sibling to `settings.yaml`, `.env`, and
`sessions/` — consistent with `.boukensha/`'s existing "one concern per file"
layout and `Boukensha::Config`'s YAML-reading conventions:

```
.boukensha/
  players/
    admin.yaml       # fixed, well-known admin profile — see §3
    dummy.yaml
    scout.yaml
```

Profile shape (persona fields present but inert — no agent loop consumes
them yet, per the plan's own scoping):

```yaml
name: dummy
password: helloworld
sex: M
class: warrior
race: human          # omit if the server build has races disabled
admin: false         # true only for admin.yaml

persona:              # reserved for future agent-loop work; unused today
  playstyle: null
  risk_mode: null
  thought_process: null
  notes: null
```

`admin: true` is an explicit field rather than inferring "admin-ness" from
filename alone, so the seeding script's admin-bootstrap step
(§3) has one unambiguous source of truth even if the file gets renamed.

### 3. Admin bootstrap (always runs first, idempotent)

Since admin status is conferred by *creation order* on a fresh world, not by
name, the script's first action — before touching any regular profile — is
always:

1. Load `.boukensha/players/admin.yaml` (create it with sane defaults +a
   prompt for name/password on first run if missing — see `HOW_TO_PLAY.md`'s
   own suggested `admin`/`password` convention as the default).
2. Connect, call `identify(admin_name)`.
3. If the server asks for `Password:` → admin already exists; log in to
   confirm the stored password is correct (surface a clear error if not —
   don't silently proceed), then disconnect. Nothing created.
4. If the server asks to confirm a new name → world is fresh; drive
   `create_character` for the admin profile, then disconnect.

This directly satisfies the plan's requirement ("should always check if this
admin is already created... know that this admin is not playable by the
agent at the moment") — admin is seeded but never referenced by
`settings.yaml`'s `mcp_servers.mud.env` (`MUD_NAME`/`MUD_PASSWORD`), which
keeps pointing at a regular player profile as it does today.

**Caveat to flag to the user, not silently paper over:** this invariant only
holds if the seeding script is the *only* thing that ever creates characters
first on a fresh world. If someone manually telnets in and creates a
character by hand before running the script (as `HOW_TO_PLAY.md` currently
instructs humans to do), that manual character becomes admin instead, and
the script's own `admin.yaml` character will be created as a second,
non-admin character. The script can't detect this after the fact — a fresh
world has no signal distinguishing "no one has connected yet" from "someone
already took the first slot." Worth a one-line README warning once this
ships, but not solvable in the script itself.

### 4. Seeding multiple players + conflict handling

CLI script `week2_observability/bin/seed_players`:

```
seed_players [--players-dir .boukensha/players] [profile ...]
```

- With no positional args: seed every `*.yaml` in the players dir except
  `admin.yaml` (handled separately per §3, always first).
- With positional args: seed only the named profiles (by filename stem),
  useful for adding one new player without re-touching the rest.

For each profile, per connection:

1. `identify(name)`.
2. Server says name is new → `create_character` → done, report "created".
3. Server says `Password:` → character already exists. Per the plan's
   explicit requirement, prompt interactively:
   ```
   Player 'scout' already exists on the server. [s]kip / [d]elete and reseed / [q]uit?
   ```
   - skip → disconnect, move to next profile, report "skipped (exists)".
   - delete and reseed → log in with the *stored* password (fail loudly if
     it doesn't match — the script has no business guessing/brute-forcing a
     password it doesn't already have on file), then drive the character
     menu's self-delete option, then `create_character` fresh from the
     profile. **The exact self-delete menu flow (letter, confirmation
     prompt) needs the same live-telnet verification as §1** — CircleMUD
     typically exposes it as a numbered option on the post-login character
     menu (`#login` currently skips straight past this menu via
     `send_command(:return); send_command(1)`), so reaching it means
     stopping at the menu instead of auto-advancing, only in this code path.
   - quit → abort the whole run immediately (no more profiles processed).

Each connection is opened and closed per player — CircleMUD's protocol has
no concept of a client holding two identities on one socket, and reusing one
`Session` sequentially (quit, then re-`identify`) adds complexity for no
benefit over just opening a fresh `Session` per profile.

Non-interactive automation (e.g. a future CI/reset-world script) is a
plausible follow-up (`--skip-existing` / `--delete-existing` flags to bypass
the prompt), but is not in this iteration — the plan asks for an interactive
prompt, so that's the MVP behavior.

### 5. What's explicitly out of scope here

- No agent-loop or persona-driven play — `persona:` fields are stored,
  validated as present, and otherwise untouched, matching the plan's own
  scoping note.
- No non-interactive/CI mode beyond what's described above.
- No changes to `world_map.sqlite3` or `log_viz` — unrelated data.

## Implementation steps

1. Against the running dev MUD (`docker compose up` in
   `week0_explore/infrastructure`), manually telnet through a brand-new
   character creation and a character self-delete, transcribing the exact
   prompt strings (including tbaMUD's actual class/race menu text and
   letters) — this de-risks steps 2–3 before writing any regex.
2. Add `Session#identify` (refactor `#login` to use it) and
   `Session#create_character` to `week0_explore/mud_manager/lib/mud_manager/session.rb`,
   using the prompts captured in step 1.
3. Add a character-deletion helper (name pending on what step 1 finds —
   likely `Session#delete_character` reachable only from the post-login
   character menu) for the "delete and reseed" path.
4. Wire both new `Session` methods into `McpServer` as MCP tools
   (`create_character`, `delete_character`) for parity with the rest of the
   gem's surface, per `docs/plans/mud_manager/generic_interfacing.md`'s "wrap
   once" principle.
5. Rebuild/reinstall the `mud_manager` gem (`week2_observability/bin/build_gems`)
   so the new methods are available on `PATH`.
6. Write `week2_observability/bin/seed_players`: loads/creates
   `.boukensha/players/admin.yaml`, runs the admin bootstrap (§3), then
   iterates the remaining profile YAML files (or the given positional
   subset) driving the create/skip/delete-and-reseed flow (§4).
7. Seed a couple of throwaway profiles against the live dev MUD end-to-end,
   including re-running the script a second time to exercise the "already
   exists" prompt for both skip and delete-and-reseed choices.
8. Update `HOW_TO_PLAY.md`'s "Create Admin Character" / "Create Main
   Character" sections to point at `seed_players` as the preferred path,
   keeping the manual telnet instructions as a fallback/explanation of what
   the script automates.

## Open questions

- Exact tbaMUD build config in this repo's Docker image: are races enabled?
  Only resolvable by step 1's live walkthrough.
- Where should a *missing* `admin.yaml` prompt for admin name/password —
  interactively on first run, or just hardcode the `admin`/`password`
  convention `HOW_TO_PLAY.md` already recommends and let the user edit the
  file afterward? Leaning toward the latter (simpler, and the file's easy to
  hand-edit before first run) but flagging as a call the user should confirm.
    A: hardcode the `admin`/`password` convention `HOW_TO_PLAY.md`

## Notes
The agent boukensha should never have permisison to do this. This script is for 
engineer (myself) to run only
