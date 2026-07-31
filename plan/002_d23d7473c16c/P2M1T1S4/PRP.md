# PRP — P2.M1.T1.S4: Extract shell fields in `bridge.lua` `M.server_info` + descriptor type

> **Plan mapping:** task `P2.M1.T1.S4` ("Extract shell fields in bridge.lua M.server_info +
> descriptor type"). Fourth (last) subtask of **P2.M1.T1** ("Bridge descriptor
> shell/shellSource/shellPath") within the **Shell Completion for !/!! Bash Mode** epic
> (PRD §17). S1 (TS types) + S2 (resolver + descriptor population) are **DONE**; S3
> (hello/ping RPC mirror) is **Implementing** (treat its PRP as a contract — it populates the
> `hello`/`ping` *results* this task reads). **S4 is the Lua read side**: surface the §17.10
> advisory shell fields on the plugin's `M.server_info` / `M.descriptor` and export
> `M.get_shell_info()` for `shell.lua` (P2.M1.T2) to consume.

---

## Goal

**Feature Goal**: Make the §17.10 advisory shell fields (`shell`/`shellSource`/`shellPath`)
available on the Lua plugin side: (a) document them on the `pi-bridge.ServerInfo` class
(bridge.lua) + the `pi-bridge.BridgeDescriptor` class (init.lua) as **optional** fields;
(b) defensively extract them into `M.server_info` at handshake success (result value with
fallback to the descriptor — mirroring the existing `cwd` extraction); (c) export
`M.get_shell_info()` returning a fresh `{shell, shellSource, shellPath}` table (values may be
nil) read from `M.server_info`, falling back to `require("pi-bridge").descriptor` when
server_info is nil (the pre-handshake window). After this task, `shell.lua` has ONE merged
view of the resolved execution shell.

**Deliverable** (files modified — all EXIST; no new files):
- `lua/pi-bridge/bridge.lua` — MODIFY: +3 optional `---@field`s on `pi-bridge.ServerInfo`;
  +3 extraction lines (via a tiny local `pick_str` helper) in `resolve_handshake`'s success
  branch; +`M.get_shell_info()` public accessor (after `M.is_connected()`, before `return M`).
- `lua/pi-bridge/init.lua` — MODIFY: +3 optional `---@field`s on `pi-bridge.BridgeDescriptor`
  + a one-line caveat on the class's doc comment (the shell fields are the optional exception).
- `tests/bridge_handshake_spec.lua` — MODIFY: extend the `descriptor()` + `with_hello_server`
  helpers to thread shell fields; ADD 3 focused cases (shell-from-result, descriptor-fallback,
  get_shell_info accessor).

**Success Definition**:
- `bridge.server_info` carries `shell`/`shellSource`/`shellPath` after a successful handshake
  whose `hello` result advertises them (values verbatim from the result); and falls back to the
  descriptor's values when the result omits them; and leaves them `nil` when neither has them.
- `bridge.get_shell_info()` returns the merged view (server_info preferred, else descriptor,
  else `nil`); the returned table is a fresh copy (mutating it does not touch module state).
- `bridge_handshake_spec` green with the 3 new cases (12 → 15 pass, ℹ fail 0); `bridge_smoke`,
  `init_spec`, `health_spec` stay green (the annotation/extraction edits are additive).
- NO edit to transport/protocol/connection (`bridge.lua` public signatures unchanged), NO edit
  to `extension/*`, NO new RPC method, NO edit to `shell.lua`.

## User Persona (if applicable)

**Target User**: `shell.lua` (P2.M1.T2.S2 — "resolve_shell(prefer)") — the §17 completion-daemon
manager that resolves ONE shell per session at first `!` activation, then caches it. It calls
`bridge.get_shell_info()` to read the `prefer:"pi"` value (PRD §17.4: `descriptor.shell → $SHELL
→ /bin/bash`). Secondary consumer: `:checkhealth pi-bridge` (P2.M3.T6.S2) may report the
resolved shell/source (reads `M.server_info`/`M.get_shell_info()`).

**Use Case**: `shell.lua` needs the shell pi executes `!`/`!!` in. Two sources exist after
S2/S3: the descriptor (env-var blob, available from `activate()` — covers the pre-handshake
window) and the hello/ping RPC result (live, post-handshake). `get_shell_info()` merges them
into one accessor with the right priority.

**Pain Points Addressed**: without S4, `shell.lua` would have to (a) reach into both
`M.server_info` AND `M.descriptor` itself, (b) re-implement the result-or-descriptor merge, and
(c) duplicate the defensive type-checks. S4 centralizes that in the module that OWNS
`server_info` (bridge.lua), behind a stable, documented, never-throws accessor.

## Why

- **Closes the Lua half of §17.10.** S2 put the fields on the descriptor; S3 mirrored them into
  the RPC results. S4 is the read-side counterpart: without it the fields are on the wire but
  unreachable from the plugin. This is the last subtask of P2.M1.T1 (the descriptor-shell-fields
  milestone) and the direct prerequisite of P2.M1.T2 (`shell.lua`).
- **Mirrors a proven convention.** `resolve_handshake` already defensively extracts
  `serverVersion`/`cwd`/`fdAvailable` into `M.server_info` (cwd even does result-or-descriptor:
  `(type(r.cwd)=="string") and r.cwd or (desc.cwd or "")`). Shell fields are the 4th such
  extraction — mechanical, same shape (the only twist: optional→`nil`, not `""`).
- **Consumes S2/S3's contract cleanly, ZERO file conflict.** S1 owns `protocol.ts`; S2 owns the
  resolver + descriptor literal; S3 owns the handlers + registration. S4 owns the Lua
  `ServerInfo`/`BridgeDescriptor` annotations + the `resolve_handshake` extraction + the new
  accessor + the handshake spec. No overlap with any sibling.
- **Forward contract for shell.lua.** `get_shell_info()` is the stable seam P2.M1.T2.S2 keys on
  (its `resolve_shell(prefer)` reads `prefer:"pi"` from it). Defining it here lets shell.lua be
  built against a real, tested API rather than reaching into module internals.

## What

**User-visible behavior**: none directly (the plugin carries 3 extra optional fields on its
internal server-identity + descriptor tables; no user-facing output until `shell.lua` (P2.M1.T2)
+ completion routing (P2.M2.T3) land). The *contract* change — after a successful handshake,
`bridge.server_info` looks like:

```lua
{ serverVersion = "0.1.0", cwd = "/home/u/proj", fdAvailable = true,
  shell       = "/bin/zsh",   -- NEW (§17.10) — nil when unresolved (advisory)
  shellSource = "pi",         -- NEW — "pi" | "$SHELL" | "default" | nil
  shellPath   = "/bin/zsh" }  -- NEW — nil unless the user set shellPath
```
And `bridge.get_shell_info()` returns `{shell=…, shellSource=…, shellPath=…}` (a fresh table;
any value nil when unresolved), or `nil` when neither server_info nor descriptor is populated.

**Technical requirements** (all in `lua/pi-bridge/` unless noted):
- Add 3 optional `---@field`s (`shell`, `shellSource`, `shellPath`) to `pi-bridge.ServerInfo`
  (bridge.lua L183-186) AND to `pi-bridge.BridgeDescriptor` (init.lua L98-105). All three are
  `string?` (shellSource is the literal union `"pi"|"$SHELL"|"default"`). Document them as
  ADVISORY/OPTIONAL (absent on older clients ⇒ shell.lua falls back to `$SHELL`).
- In `resolve_handshake`'s success branch (bridge.lua L327-331), extract the 3 fields via a new
  local `pick_str(a, b)` helper (first string of `a`,`b`, else `nil`): `shell =
  pick_str(r.shell, desc.shell)` ×3. This honors the contract's "result with fallback to
  descriptor" AND mirrors the existing type-check discipline, while keeping shell fields `nil`
  (NOT `""`) when unresolved.
- Add `M.get_shell_info()` (bridge.lua, after `M.is_connected()` @ L845): returns a fresh
  `{shell, shellSource, shellPath}` from `M.server_info`, else from
  `require("pi-bridge").descriptor`, else `nil`. Never throws (defensive table reads).

### Success Criteria

- [ ] `pi-bridge.ServerInfo` class declares optional `shell`/`shellSource`/`shellPath` fields.
- [ ] `pi-bridge.BridgeDescriptor` class declares the same 3 optional fields (+ doc caveat).
- [ ] `resolve_handshake` extracts them (result-or-descriptor via `pick_str`); `nil` when both
      sources lack them; the existing `serverVersion`/`cwd`/`fdAvailable` lines are unchanged.
- [ ] `M.get_shell_info()` returns the merged view (server_info → descriptor → nil); fresh table.
- [ ] `bridge_handshake_spec` green with 3 new cases (15 pass, ℹ fail 0); `bridge_smoke`,
      `init_spec`, `health_spec` stay green.
- [ ] NO public-signature change to `M.connect`/`M.handshake`/`M.send`/`M.request`/`M.close`/
      `M.on_exit`/`M.is_connected`; NO edit to `extension/*`, `connection`/transport, or
      `shell.lua`; NO new RPC method; NO docs beyond the inline annotations.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo gets the verbatim
BEFORE/AFTER for all 4 edits, the verified line numbers + grep anchors (post-S25, 2025-07-31),
the test-extension recipe (which 2 helpers to extend, which 3 cases to add, the save/restore
hygiene), and the validation commands (verified green at baseline). The one judgment call (the
`pick_str` helper vs inline ternary) is documented in §Design Decision + §Anti-Patterns.

### Documentation & References

```yaml
# MUST READ — the spec (reproduced in this PRP's <selected_prd_content>)
- docfile: PRD.md
  why: "§17.10.1 gives the EXACT field shapes + the 'absent on older clients is fine' advisory contract. §17.4.1 documents descriptor.shell contents + shellSource semantics + the fallback chain shell.lua will run."
  section: "h3.39 (§17.10), h4.9 (§17.10.1), h3.33 (§17.4 + §17.4.1 fallback chain)"
  critical: "shellSource union is literally \"pi\" | \"$SHELL\" | \"default\" (the '$SHELL' member has a '$'). Fields are ADVISORY + OPTIONAL → on the Lua side they MUST be nil (NOT \"\") when unresolved, or shell.lua's fallback chain (descriptor.shell → $SHELL → /bin/bash) is defeated."

# MUST READ — the file being edited (verbatim BEFORE/AFTER in the Blueprint)
- file: lua/pi-bridge/bridge.lua
  why: "(1) ServerInfo class L183-188 (annotation edit). (2) resolve_handshake success-branch extraction L326-332 (the `local info = {...}` block + `M.server_info = info`). (3) public-API tail L845-849 (`M.is_connected` → `return M`; insertion point for `M.get_shell_info`)."
  pattern: "defensive extract: `cwd = (type(r.cwd)=='string') and r.cwd or (desc.cwd or '')`. Shell fields mirror this but return nil (optional). `desc` in resolve_handshake == handshake_state.desc == the descriptor passed to M.handshake == init.lua's M.descriptor at activate() time."
  gotcha: "`M.close()` clears `M.server_info = nil` at L788 (reconnect hygiene) — the shell fields ride along for free; do NOT add a separate clear. `require(\"pi-bridge\")` inside bridge.lua is SAFE (already used at L333 + L559; runs post-activate so init is fully loaded)."

# MUST READ — the other file being edited (annotation only; non-functional)
- file: lua/pi-bridge/init.lua
  why: "BridgeDescriptor class L98-105 (annotation edit) + its doc comment L93-97 (append the §17.10 optional caveat to 'all fields are present & non-null when transport==unix'). M.descriptor set at activate() L141."
  pattern: "luaemmy `---@class`/`---@field` annotations (consumed by lua-language-server; NOT enforced at runtime — there is no lua linter in this repo)."
  gotcha: "annotation edits are COMMENTS at runtime — zero behavioral risk. The runtime extraction is entirely in bridge.lua."

# MUST READ — the test file to MODIFY (the S25 spec; the MOCKING contract)
- file: tests/bridge_handshake_spec.lua
  why: "the `with_hello_server(opts, spec)` helper (L40-) spins a luv server whose 'success' mode replies {ok,serverVersion,cwd,fdAvailable}; the `descriptor(path)` helper (L24-) builds a descriptor. EXTEND both to thread shell fields; ADD 3 cases. Baseline 12/0/0 (verified)."
  pattern: "field-by-field `assert.are.equals` on server_info (NOT deepEqual) → adding shell=nil to server_info is invisible to existing asserts. `reset_module()` (L37-) calls bridge.close() (nils server_info) + sets pi.bridge=nil. Drive async via `vim.wait(300, predicate, 5)`."

# MUST READ — S3's CONTRACT (defines the INPUT this task reads off the wire)
- file: plan/002_d23d7473c16c/P2M1T1S3/PRP.md
  why: "S3 makes hello/ping results carry shell/shellSource/shellPath via CONDITIONAL SPREAD (keys ABSENT when getShellInfo() returns undefined). So on the wire the keys are present-when-resolved, absent-when-not. S4's `pick_str(r.shell, desc.shell)` reads `nil` for an absent key → correctly leaves server_info.shell nil. No conflict: S3 owns extension TS; S4 owns lua."

# MUST READ — local research notes (verified facts + the design decisions + baseline table)
- docfile: plan/002_d23d7473c16c/P2M1T1S4/research/notes.md
  why: "exact current line numbers, the verbatim BEFORE/AFTER, the pick_str design decision, the get_shell_info source-priority rationale, the 3-case test recipe, the baseline table (all green), the scope fence."

# SUPPORTING — architecture research (confirms ServerInfo extraction + descriptor shape)
- docfile: plan/002_d23d7473c16c/architecture/research-plugin-side.md
  why: "§2 documents M.server_info (L183-188) + the resolve_handshake extraction + the descriptor type (init.lua L98-108). Confirms shell is the 4th such extraction."
  section: "§2 (bridge.lua), §3 (init.lua)"
```

### Current Codebase tree (relevant slice)

```bash
lua/pi-bridge/
├── bridge.lua     # MODIFY — ServerInfo annotation (L183-186) + resolve_handshake extraction (L326-332) + M.get_shell_info (new, after L845)
├── init.lua       # MODIFY — BridgeDescriptor annotation (L98-105) + doc comment caveat (L93-97)
└── (shell.lua)    # DOES NOT EXIST YET — P2.M1.T2 creates it; S4 only exports the accessor it will call
tests/
├── bridge_handshake_spec.lua   # MODIFY — extend descriptor()+with_hello_server() helpers + ADD 3 cases
├── bridge_smoke.lua            # READ-ONLY regression (the S24 transport smoke)
├── init_spec.lua               # READ-ONLY regression (annotation edit to init.lua is non-functional)
└── health_spec.lua             # READ-ONLY regression (health reads server_info; unaffected by optional fields)
```

### Desired Codebase tree with files to be modified

```bash
lua/pi-bridge/bridge.lua                  # MODIFIED — annotation + extraction + accessor (3 edits)
lua/pi-bridge/init.lua                    # MODIFIED — annotation + doc caveat (1 edit block)
tests/bridge_handshake_spec.lua           # MODIFIED — 2 helper extensions + 3 new test cases
# (NO other lua, NO extension/*, NO new files, NO docs beyond inline annotations.)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL GOTCHA #1 — shell fields are OPTIONAL ⇒ nil, NOT "" (unlike cwd/serverVersion).
-- cwd/serverVersion are REQUIRED result fields → default "" when malformed (the server's
-- `getCwd() ?? ""`). shell* are ADVISORY → MUST be ABSENT (nil) when unresolved so shell.lua's
-- fallback chain (descriptor.shell → $SHELL → /bin/bash, PRD §17.4) engages. A "" would be a
-- bogus path that short-circuits the fallback. `pick_str` returns nil by design (no `or ""`).

-- GOTCHA #2 — `desc` in resolve_handshake IS the descriptor (one table, two names).
-- `handshake_state.desc` is the `desc` passed to `M.handshake(desc, …)`, which init.lua's
-- activate() passes as the parsed env-var blob = `M.descriptor`. So `desc.shell` IS
-- `M.descriptor.shell` at handshake time. The result-or-descriptor merge is a same-source
-- belt-and-suspenders in production (S2 writes the SAME ShellInfo into both), but it is the
-- correct defensive read + it covers the S2-done/S3-not transient.

-- GOTCHA #3 — `require("pi-bridge")` inside bridge.lua is SAFE (no circular-require hazard).
-- bridge.lua ALREADY does `require("pi-bridge").bridge = M` (L333) + `local cfg =
-- require("pi-bridge")` (L559). get_shell_info() runs post-activate (shell.lua calls it), so
-- the require returns the already-loaded init module table. Do NOT add a top-level require.

-- GOTCHA #4 — `M.close()` already clears `M.server_info = nil` (L788).
-- The shell fields ride along (they're keys on the same table). Do NOT add a separate clear.
-- get_shell_info() sees `M.server_info == nil` after close() → falls through to descriptor
-- (correct: the descriptor survives close(); only server_info is connection-scoped).

-- GOTCHA #5 — no lua linter/formatter in this repo (no luacheck/selene/stylua/.luarc at root).
-- The ONLY "type" surface is the luaemmy annotations (lua-language-server, not runtime-enforced).
-- So S4's validation = the plenary spec (Level 2) + the smoke (Level 2a). There is no `ruff`/
-- `mypy`/`stylua --check` equivalent to run.

-- GOTCHA #6 — TAB indentation throughout bridge.lua/init.lua (verified). Match tabs on every
-- new line. The `pick_str` body and the `get_shell_info` body use tabs.

-- GOTCHA #7 — the task description's line numbers (L183-187, L329-333, L98-108) are ACCURATE
-- for the current tree (verified 2025-07-31, post-S25/S27/S39). Unlike S3 (whose numbers were
-- stale pre-S2), these are current. Still: grep the exact anchor strings (see Blueprint) rather
-- than trusting the digits blindly — a future sibling edit could shift them.

-- GOTCHA #8 — existing handshake tests use FIELD-BY-FIELD asserts (assert.are.equals on
-- server_info.serverVersion etc.), NOT deepEqual. So adding shell=nil to server_info (default
-- success reply has no shell; default descriptor() has no shell) is INVISIBLE to them. The 12
-- existing cases pass unchanged. (If any test DID deepEqual server_info, adding keys would
-- break it — verified: none do.)

-- SCOPE — this task is the Lua extraction + accessor + annotation + handshake-spec tests.
--   Do NOT: edit extension/* (S1/S2/S3), transport/connection/protocol, shell.lua (P2.M1.T2),
--   completion.lua, or any docs file (Mode-B P2.M4.T7). Do NOT make shell fields required.
--   Do NOT add a new RPC method. Do NOT change any public function signature.
```

## Implementation Blueprint

### Design Decision (READ FIRST — why `pick_str`, not inline ternary)

The contract #3b literally specifies `info.shell = result.shell or descriptor.shell` (direct
form). This PRP **honors the result-or-descriptor semantics** but adds the existing
type-check discipline (defends a malformed server) via a tiny local helper:

```lua
local function pick_str(a, b)
  if type(a) == "string" then return a end
  if type(b) == "string" then return b end
end  -- returns nil when neither is a string (advisory field absent)
```

**Why** (each reason verified):
1. **Faithful to the contract.** `pick_str(r.shell, desc.shell)` IS `result.shell or
   descriptor.shell` when both are strings-or-nil (the only realistic wire shapes after S3's
   conditional spread). It additionally rejects a non-string (e.g. a malformed `shell: 123`),
   matching the existing `cwd`/`serverVersion` type-check.
2. **DRY + readable.** The naive inline form `(type(r.shell)=="string") and r.shell or
   (type(desc.shell)=="string" and desc.shell or nil)` ×3 is a triple-nested ternary — ugly and
   copy-paste-prone. The helper is 4 lines, used 3×, self-documenting.
3. **nil, not "".** `pick_str` returns `nil` (no `or ""`) — the load-bearing distinction for
   advisory fields (GOTCHA #1). An inline `or ""` would be a subtle bug.
4. **Local + trivial.** It is a file-local helper defined once, immediately before
   `resolve_handshake` (its only caller). No new module pattern, no export, no test surface of
   its own. This is the ONE small new pattern in the task; it is documented + justified.

> The literal-contract alternative (direct `result.shell or descriptor.shell`, no type-check) is
> also correct and would pass every test — the server (S3) only ever emits string-or-absent. The
> helper is the *defensive* choice, matching this file's established discipline. See Anti-Patterns.

### Data models and structure

No new runtime types. Two existing luaemmy classes gain 3 optional fields each:

```lua
---@class pi-bridge.ServerInfo                       (bridge.lua L183)
---@field serverVersion string                       (existing)
---@field cwd string                                 (existing)
---@field fdAvailable boolean                        (existing)
---@field shell string?                              -- NEW (§17.10/S4): advisory; nil ⇒ shell.lua falls back to $SHELL
---@field shellSource ("pi"|"$SHELL"|"default")?     -- NEW (§17.10/S4): how `shell` was derived
---@field shellPath string?                          -- NEW (§17.10/S4): the raw shellPath setting, if set

---@class pi-bridge.BridgeDescriptor                 (init.lua L98)
---@field transport "unix"                           (existing)
---@field path string  ... serverVersion string      (existing, L99-105)
---@field shell string?                              -- NEW (§17.10/S4): advisory (mirrors extension/protocol.ts)
---@field shellSource ("pi"|"$SHELL"|"default")?     -- NEW (§17.10/S4)
---@field shellPath string?                          -- NEW (§17.10/S4)
```
The runtime shape of `M.server_info` after extraction: a plain Lua table with the 6 keys above
(shell* possibly nil). `M.get_shell_info()` returns a fresh 3-key table (values possibly nil).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY lua/pi-bridge/bridge.lua — add `pick_str` helper + 3 extraction lines
  - DEFINE `pick_str` (4 lines + JSDoc) as a LOCAL function immediately BEFORE the
        `resolve_handshake = function(msg, err)` assignment (in the "S25" section, after the
        forward-declarations + read_cb). See "Reference implementation" block A.
  - EDIT the `local info = {...}` block in resolve_handshake's success branch (L327-331): append
        3 lines (`shell = pick_str(r.shell, desc.shell)`, …) AFTER the `fdAvailable` line, BEFORE
        the closing `}`. Leave serverVersion/cwd/fdAvailable UNTOUCHED. See block B (BEFORE→AFTER).
  - DO NOT: change the `local r = msg.result` line, the `M.server_info = info` line, the
        `require("pi-bridge").bridge = M` line, or the failure/malformed/timeout branches.

Task 2: MODIFY lua/pi-bridge/bridge.lua — `pi-bridge.ServerInfo` class annotation (+3 fields)
  - AT L183-186: append 3 `---@field` lines after the `fdAvailable` line + before the
        `---@type pi-bridge.ServerInfo|nil` line. See block C (BEFORE→AFTER).
  - DO NOT: change the `---@class` line, the existing 3 fields, or the `M.server_info = nil` line.
    DO NOT mark the new fields required (they are `string?` / the union `?`).

Task 3: MODIFY lua/pi-bridge/bridge.lua — add `M.get_shell_info()` public accessor
  - INSERT a new `function M.get_shell_info() … end` (with JSDoc) AFTER `M.is_connected()`
        (ends L847) and BEFORE `return M` (L849). See block D (verbatim to insert).
  - DO NOT: change `M.is_connected`'s body or any other public function. DO NOT add a top-level
        `require("pi-bridge")` (require lazily INSIDE the function — GOTCHA #3).

Task 4: MODIFY lua/pi-bridge/init.lua — `pi-bridge.BridgeDescriptor` class annotation (+3 fields + caveat)
  - AT L98-105: append 3 `---@field` lines after the `serverVersion` line + before the next
        non-field line. See block E (BEFORE→AFTER).
  - AT L93-97 (the class's doc comment): append ONE sentence to the "all fields are present &
        non-null when transport==\"unix\"" line, noting the §17.10 shell fields are the OPTIONAL
        exception. See block E (the doc-comment edit).
  - DO NOT: change `---@class`, the existing fields, `M.descriptor = nil` (L110), or activate().

Task 5: MODIFY tests/bridge_handshake_spec.lua — extend helpers + ADD 3 cases
  - EXTEND `descriptor(path, shell_fields?)` (L24-): add an OPTIONAL 2nd arg; when it's a table,
        copy shell/shellSource/shellPath onto the descriptor. Backward-compatible (existing
        1-arg calls unchanged). See block F.
  - EXTEND `with_hello_server` "success" reply (L55-66 area): build the `result` table, then
        CONDITIONALLY add shell/shellSource/shellPath ONLY when opts provides them (mirrors S3's
        conditional spread — keys absent when unresolved). See block F.
  - ADD 3 `it(...)` cases inside the existing `describe("pi-bridge.bridge handshake", …)` block
        (after the (a) success case is a good spot): (1) shell-from-result, (2) descriptor-
        fallback, (3) get_shell_info accessor. See block G (verbatim).
  - DO NOT: change the existing 12 cases, reset_module(), or TOKEN/DESC_CWD. DO NOT name a
        spec-local `pending` (shadows plenary's skip fn — research-plugin-side.md §9).
```

### Reference implementation

```lua
-- === Block A: the `pick_str` helper (bridge.lua, S25 section, before resolve_handshake) ===
-- INSERT this local function immediately BEFORE `resolve_handshake = function(msg, err)`:

--- §17.10 (S4): first string of (a, b), else `nil` — the defensive extractor for the advisory
--- shell fields. Mirrors the existing cwd/serverVersion type-check discipline, but returns
--- `nil` (NOT `""`) because the shell fields are OPTIONAL: an unresolved field must be ABSENT
--- so `shell.lua`'s fallback chain (`descriptor.shell → $SHELL → /bin/bash`, PRD §17.4) engages
--- (a `""` would be a bogus shell path that short-circuits the fallback). Never throws.
---@param a any Candidate value (e.g. `r.shell` — the live hello result).
---@param b any Fallback value (e.g. `desc.shell` — the descriptor / env-var blob).
---@return string|nil
local function pick_str(a, b)
  if type(a) == "string" then return a end
  if type(b) == "string" then return b end
end
```

```lua
-- === Block B: the extraction (bridge.lua resolve_handshake success branch, ~L327-331) ===
-- BEFORE (current):
    local info = {
      serverVersion = (type(r.serverVersion) == "string") and r.serverVersion or "",
      cwd           = (type(r.cwd) == "string") and r.cwd or (desc.cwd or ""),
      fdAvailable   = (r.fdAvailable == true),
    }

-- AFTER (S4): append the 3 advisory shell fields (result-or-descriptor via pick_str; nil when
-- both are absent — NOT ""). `desc` here IS the descriptor (handshake_state.desc == M.descriptor).
    local info = {
      serverVersion = (type(r.serverVersion) == "string") and r.serverVersion or "",
      cwd           = (type(r.cwd) == "string") and r.cwd or (desc.cwd or ""),
      fdAvailable   = (r.fdAvailable == true),
      -- §17.10 (S4): advisory shell fields — OPTIONAL (nil, NOT "", when unresolved, so
      -- shell.lua's fallback chain `descriptor.shell → $SHELL → /bin/bash` engages). Defensive:
      -- prefer the live hello result, fall back to the descriptor (PRD §17.10.1).
      shell       = pick_str(r.shell, desc.shell),
      shellSource = pick_str(r.shellSource, desc.shellSource),
      shellPath   = pick_str(r.shellPath, desc.shellPath),
    }
```

```lua
-- === Block C: ServerInfo class annotation (bridge.lua L183-186) ===
-- BEFORE (current):
---@class pi-bridge.ServerInfo
---@field serverVersion string Bridge server version (default `""` if absent/malformed).
---@field cwd string Session cwd (falls back to `descriptor.cwd`).
---@field fdAvailable boolean True ONLY if `result.fdAvailable == true`.

-- AFTER (S4): +3 optional fields documenting the advisory shell triple. (The `---@type
-- pi-bridge.ServerInfo|nil` + `M.server_info = nil` lines below are UNCHANGED.)
---@class pi-bridge.ServerInfo
---@field serverVersion string Bridge server version (default `""` if absent/malformed).
---@field cwd string Session cwd (falls back to `descriptor.cwd`).
---@field fdAvailable boolean True ONLY if `result.fdAvailable == true`.
---@field shell string? §17.10 — the resolved execution-shell binary (advisory; absent on older clients ⇒ `shell.lua` falls back to `$SHELL`). Defensive extract: `result.shell or descriptor.shell`.
---@field shellSource ("pi"|"$SHELL"|"default")? §17.10 — how `shell` was derived. Absent when `shell` is absent.
---@field shellPath string? §17.10 — the raw `shellPath` setting, if the user set one. Absent otherwise.
```

```lua
-- === Block D: M.get_shell_info() (bridge.lua, INSERT after M.is_connected(), before return M) ===
-- INSERT verbatim (tab-indented to match the file):

--- §17.10 (S4): read-only accessor for the advisory shell fields, consumed by `shell.lua`
--- (the §17 completion-daemon manager resolves ONE shell per session at first `!` activation,
--- then caches it). Returns a FRESH table `{shell, shellSource, shellPath}` (any value may be
--- `nil` when unresolved — `shell.lua` then runs its fallback chain `descriptor.shell → $SHELL
--- → /bin/bash`, PRD §17.4). Source priority: `M.server_info` (the live `hello`/`ping` RPC
--- result, post-handshake) wins; else `require("pi-bridge").descriptor` (the `PI_NVIM_BRIDGE`
--- env-var blob, available from `activate()` — covers the pre-handshake window where `shell.lua`
--- may resolve the shell before the async handshake completes). Returns `nil` ONLY when NEITHER
--- is populated. Note: at extraction time `server_info.shell` is ALREADY the merged
--- `pick_str(result.shell, descriptor.shell)` value (see `resolve_handshake`), so no per-field
--- re-fallback is needed here. NEVER throws (pure defensive table reads); the returned table is
--- a fresh copy (mutating it cannot touch module state).
---@return {shell:string?, shellSource:string?, shellPath:string?}|nil
function M.get_shell_info()
	local src = M.server_info
	if src == nil then
		src = require("pi-bridge").descriptor  -- env-var blob; set by activate() before handshake resolves
	end
	if type(src) ~= "table" then return nil end
	return {
		shell       = (type(src.shell) == "string") and src.shell or nil,
		shellSource = (type(src.shellSource) == "string") and src.shellSource or nil,
		shellPath   = (type(src.shellPath) == "string") and src.shellPath or nil,
	}
end
```

```lua
-- === Block E: BridgeDescriptor annotation + doc caveat (init.lua L93-105) ===
-- BEFORE — doc comment (L93-97, last sentence):
--   ... Mirrors the extension's BridgeDescriptor
--   (extension/protocol.ts); all fields are present & non-null when transport=="unix".
-- BEFORE — class (L98-105):
---@class pi-bridge.BridgeDescriptor
---@field transport "unix" Transport type (v1 literal "unix"; PRD §5.1 names a future "tcp").
---@field path string Unix domain socket path (${tmpdir}/pi-nvim-bridge-<uuid>.sock).
---@field token string Random 32-byte hex secret — the REAL auth boundary (PRD §5.3, §12).
---@field pid integer pi's process id.
---@field cwd string pi session working directory (ctx.cwd).
---@field fdAvailable boolean Whether the `fd` binary resolved (controls @file fuzzy search).
---@field serverVersion string Bridge server version string (PRD §6.4 hardcodes "0.1.0").

-- AFTER — doc comment (append to the last sentence):
--   ... Mirrors the extension's BridgeDescriptor
--   (extension/protocol.ts); all fields are present & non-null when transport=="unix",
--   EXCEPT the §17.10 `shell`/`shellSource`/`shellPath` fields which are OPTIONAL + advisory
--   (absent on older clients ⇒ `shell.lua` falls back to `$SHELL`).
-- AFTER — class (+3 optional fields):
---@class pi-bridge.BridgeDescriptor
---@field transport "unix" Transport type (v1 literal "unix"; PRD §5.1 names a future "tcp").
---@field path string Unix domain socket path (${tmpdir}/pi-nvim-bridge-<uuid>.sock).
---@field token string Random 32-byte hex secret — the REAL auth boundary (PRD §5.3, §12).
---@field pid integer pi's process id.
---@field cwd string pi session working directory (ctx.cwd).
---@field fdAvailable boolean Whether the `fd` binary resolved (controls @file fuzzy search).
---@field serverVersion string Bridge server version string (PRD §6.4 hardcodes "0.1.0").
---@field shell string? §17.10 — the resolved execution-shell binary (advisory; mirrors extension/protocol.ts; absent on older clients).
---@field shellSource ("pi"|"$SHELL"|"default")? §17.10 — how `shell` was derived.
---@field shellPath string? §17.10 — the raw `shellPath` setting, if the user set one.
```

```lua
-- === Block F: test-helper extensions (tests/bridge_handshake_spec.lua) ===
-- (F1) descriptor() — add an OPTIONAL 2nd arg (backward-compatible):
-- BEFORE:
local function descriptor(path)
  return {
    transport = "unix",
    path = path,
    token = TOKEN,
    pid = 1,
    cwd = DESC_CWD,
    fdAvailable = true,
    serverVersion = "0.1.0",
  }
end

-- AFTER:
local function descriptor(path, shell_fields)
  local d = {
    transport = "unix",
    path = path,
    token = TOKEN,
    pid = 1,
    cwd = DESC_CWD,
    fdAvailable = true,
    serverVersion = "0.1.0",
  }
  if type(shell_fields) == "table" then
    d.shell = shell_fields.shell
    d.shellSource = shell_fields.shellSource
    d.shellPath = shell_fields.shellPath
  end
  return d
end

-- (F2) with_hello_server "success" reply — build result, then conditionally add shell keys:
-- BEFORE (inside srv_rx callback, mode == "success"):
        if req.method == "hello" then
          srv_conn:write(vim.json.encode({
            jsonrpc = "2.0", id = "h1",
            result = {
              ok = true,
              serverVersion = "0.1.0",
              cwd = opts.cwd or DESC_CWD,
              fdAvailable = (opts.fdAvailable == nil) and true or opts.fdAvailable,
            },
          }) .. "\n")
        end

-- AFTER (mirrors S3's conditional spread — keys ABSENT when opts doesn't provide them):
        if req.method == "hello" then
          local result = {
            ok = true,
            serverVersion = "0.1.0",
            cwd = opts.cwd or DESC_CWD,
            fdAvailable = (opts.fdAvailable == nil) and true or opts.fdAvailable,
          }
          -- §17.10 (S4): include shell fields ONLY when opts provides them (mirrors the
          -- extension's conditional spread — absent when unresolved).
          if opts.shell ~= nil then result.shell = opts.shell end
          if opts.shellSource ~= nil then result.shellSource = opts.shellSource end
          if opts.shellPath ~= nil then result.shellPath = opts.shellPath end
          srv_conn:write(vim.json.encode({
            jsonrpc = "2.0", id = "h1", result = result,
          }) .. "\n")
        end
```

```lua
-- === Block G: 3 new test cases (ADD inside the describe("pi-bridge.bridge handshake",…) block) ===
-- Place after the existing "(a) SUCCESS" case. (sibling style: vim.wait(300, pred, 5).)

  -- (a-shell) SUCCESS with shell fields in the hello result → server_info carries them (§17.10/S4)
  it("carries §17.10 shell fields in server_info when the hello result advertises them",
    with_hello_server({ mode = "success", shell = "/bin/zsh", shellSource = "pi", shellPath = "/bin/zsh" },
    function(path, _opts, stop)
      local err, info
      bridge.handshake(descriptor(path), function(e, i) err, info = e, i end)
      vim.wait(300, function() return err ~= nil or info ~= nil end, 5)
      assert.is_nil(err, "expected success, got err=" .. tostring(err))
      assert.are.equals("/bin/zsh", bridge.server_info.shell)
      assert.are.equals("pi",       bridge.server_info.shellSource)
      assert.are.equals("/bin/zsh", bridge.server_info.shellPath)
      stop()
    end))

  -- (a-shell-fb) result OMITS shell but descriptor HAS them → server_info falls back to descriptor
  it("falls back to descriptor.shell when the hello result omits §17.10 shell fields",
    with_hello_server({ mode = "success" }, function(path, _opts, stop)
      local err, info
      bridge.handshake(descriptor(path, { shell = "/bin/fish", shellSource = "$SHELL" }),
        function(e, i) err, info = e, i end)
      vim.wait(300, function() return err ~= nil or info ~= nil end, 5)
      assert.is_nil(err)
      assert.are.equals("/bin/fish", bridge.server_info.shell)        -- from descriptor (result omitted)
      assert.are.equals("$SHELL",    bridge.server_info.shellSource)  -- from descriptor
      assert.is_nil(bridge.server_info.shellPath)                     -- descriptor omitted it → nil (optional)
      stop()
    end))

  -- (get_shell_info) accessor: server_info preferred, else descriptor, else nil; fresh table
  it("get_shell_info() returns server_info shell, else descriptor, else nil (§17.10/S4)", function()
    reset_module()
    local saved_desc = pi.descriptor
    -- (i) neither populated → nil
    pi.descriptor = nil
    assert.is_nil(bridge.get_shell_info())
    -- (ii) descriptor only (the pre-handshake window) → its values
    pi.descriptor = { shell = "/bin/zsh", shellSource = "pi", shellPath = "/bin/zsh", cwd = "/x" }
    local si = bridge.get_shell_info()
    assert.are.equals("/bin/zsh", si.shell)
    assert.are.equals("pi",       si.shellSource)
    assert.are.equals("/bin/zsh", si.shellPath)
    -- (iii) server_info wins over descriptor
    bridge.server_info = {
      serverVersion = "0.1.0", cwd = "/y", fdAvailable = true,
      shell = "/bin/bash", shellSource = "default",  -- shellPath intentionally absent
    }
    si = bridge.get_shell_info()
    assert.are.equals("/bin/bash", si.shell)
    assert.are.equals("default",   si.shellSource)
    assert.is_nil(si.shellPath)
    -- (iv) fresh table — mutating the return does NOT touch module state
    si.shell = "MUTATED"
    assert.are.equals("/bin/bash", bridge.server_info.shell)
    -- restore (hygiene — reset_module nils server_info via close(); restore descriptor)
    bridge.server_info = nil
    pi.descriptor = saved_desc
    reset_module()
  end)
```

### Integration Points

```yaml
MODULE STATE (lua/pi-bridge/bridge.lua — additive):
  - pi-bridge.ServerInfo class: +shell? +shellSource? +shellPath?        (annotation)
  - resolve_handshake success branch: +3 extraction lines (pick_str)     (runtime)
  - public API: +M.get_shell_info()                                     (runtime; new export)

MODULE STATE (lua/pi-bridge/init.lua — additive, annotation only):
  - pi-bridge.BridgeDescriptor class: +shell? +shellSource? +shellPath?  (annotation)
  - class doc comment: +1 sentence (the §17.10 optional exception)       (annotation)
  - (M.descriptor is ALREADY populated from the env var at activate() L141; S2 made the
     extension emit the shell fields in that blob. S4 only DOCUMENTS them on the lua type.)

NO DATABASE / NO CONFIG / NO ROUTES / NO new RPC method / NO transport change / NO env var /
NO extension/* edit / NO shell.lua (P2.M1.T2) / NO docs files (Mode-B P2.M4.T7).

FORWARD CONTRACT (for P2.M1.T2.S2 — shell.lua resolve_shell(prefer)):
  - `local si = require("pi-bridge.bridge").get_shell_info()`
  - `si` is `{shell=…, shellSource=…, shellPath=…}` or nil.
  - For prefer:"pi": use `si and si.shell`; if nil, fall back to `$SHELL`, then `/bin/bash`.
  - shell.lua MUST treat nil as "unresolved" and run its own fallback (do NOT assume non-nil).
```

## Validation Loop

> Run all commands from the repo root (`/home/dustin/projects/pi-nvim-bridge`).
> Baseline (verified 2025-07-31, BEFORE S4): bridge_handshake_spec 12/0/0; bridge_smoke
> SMOKE_PASS; init_spec 14/0/0; health_spec 13/0/0. No lua linter exists (GOTCHA #5) — the
> spec + smoke ARE the gate. ALWAYS wrap nvim in `timeout` (AGENTS.md HARD RULE).

### Level 1: Sanity (the file still parses; the accessor exists)

```bash
# 1a. Confirm the new symbol + extraction are present in source:
grep -n "function M.get_shell_info" lua/pi-bridge/bridge.lua            # expect 1
grep -n "pick_str(r.shell, desc.shell)" lua/pi-bridge/bridge.lua        # expect 1 (the extraction)
grep -n "@field shell string?" lua/pi-bridge/bridge.lua                 # expect 1 (ServerInfo)
grep -n "@field shell string?" lua/pi-bridge/init.lua                   # expect 1 (BridgeDescriptor)
# 1b. Byte-compile both files (catches a syntax error / unbalanced block fast, no server):
timeout 30 nvim --headless --clean -u NORC \
  -c 'lua assert(loadfile("lua/pi-bridge/bridge.lua"))' \
  -c 'lua assert(loadfile("lua/pi-bridge/init.lua"))' \
  -c 'qa' && echo "PARSE_OK exit=$?"
# Expected: PARSE_OK exit=0. If loadfile returns nil + err, READ it: likely a tab/space mix,
#   an unbalanced `end`, or a typo in pick_str / get_shell_info.
```

### Level 2: Unit/Integration Tests (the new behavior + regressions)

```bash
# 2a. THE gate — bridge_handshake_spec with the 3 new cases (expect 15 pass, ℹ fail 0):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_handshake_spec.lua")' 2>&1 | tail -8
echo "exit=${PIPESTATUS[0]}"
# Expected: "Success: 15", "Failed : 0", "Errors : 0", exit 0.
#   If a NEW case fails: re-read its block G verbatim — the most likely cause is a typo in the
#   opts keys (shell/shellSource/shellPath) or forgetting the save/restore of pi.descriptor.
#   If an EXISTING case fails: you changed serverVersion/cwd/fdAvailable handling (Task 1 must
#   be purely ADDITIVE — re-read block B).

# 2b. Regression — the other 3 lua suites stay green (annotation/extraction edits are additive):
timeout 60 nvim --headless --clean -u NORC +"luafile tests/bridge_smoke.lua" +qa 2>&1 | tail -2
echo "smoke exit=${PIPESTATUS[0]}"   # expect SMOKE_PASS, exit 0
timeout 60 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/init_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(init_spec)"
timeout 60 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/health_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(health_spec)"
# Expected: SMOKE_PASS; init_spec 14/0/0; health_spec 13/0/0.
```

### Level 3: End-to-end handshake (the actual server_info wire shape)

```bash
# 3a. Drive a REAL handshake whose hello result advertises shell fields, then read server_info
#     + get_shell_info(). (File-based luafile — NEVER heredoc-to-nvim-stdin; AGENTS.md HARD RULE.)
cat > /tmp/s4_e2e.lua <<'LUA'
local me = debug.getinfo(1, "S").source:sub(2)
vim.opt.runtimepath:append(vim.fn.fnamemodify(me, ":h:h"))
local uv = vim.uv
local bridge = require("pi-bridge.bridge")
local jreader = require("pi-bridge.jsonlreader")
local pi = require("pi-bridge"); if pi.config == nil then pi.setup({}) end
local path = "/tmp/s4-" .. os.time() .. ".sock"; os.remove(path)
local srv = uv.new_pipe(false); srv:bind(path)
local conn
srv_rx = jreader.new(function(req)
  if req.method == "hello" then
    conn:write(vim.json.encode({ jsonrpc="2.0", id="h1", result={
      ok=true, serverVersion="0.1.0", cwd="/tmp/proj", fdAvailable=true,
      shell="/bin/zsh", shellSource="pi", shellPath="/bin/zsh" } }) .. "\n")
  end
end)
srv:listen(128, function() conn = uv.new_pipe(false); srv:accept(conn)
  conn:read_start(function(e,d) if e or d==nil then return end; srv_rx:feed(d) end) end)
bridge.handshake({ transport="unix", path=path, token="t", pid=1, cwd="/tmp/proj",
                   fdAvailable=true, serverVersion="0.1.0" }, function() end)
vim.wait(300, function() return bridge.server_info ~= nil end, 5)
print("server_info.shell =", tostring(bridge.server_info.shell))
print("server_info.shellSource =", tostring(bridge.server_info.shellSource))
local si = bridge.get_shell_info()
print("get_shell_info.shell =", tostring(si and si.shell), "| shellPath =", tostring(si and si.shellPath))
if conn and not conn:is_closing() then pcall(function() conn:close() end) end
if srv and not srv:is_closing() then pcall(function() srv:close() end) end
os.remove(path); bridge.close()
LUA
timeout 30 nvim --headless --clean -u NORC +"luafile /tmp/s4_e2e.lua" +qa 2>&1 | grep -E "shell"
rm -f /tmp/s4_e2e.lua /tmp/s4-*.sock
# Expected:
#   server_info.shell = /bin/zsh
#   server_info.shellSource = pi
#   get_shell_info.shell = /bin/zsh | shellPath = /bin/zsh
```

### Level 4: (none — no MCP/Docker/Playwright/web surface; this is pure lua)

## Final Validation Checklist

### Technical Validation

- [ ] Level 1b: both files byte-compile (`PARSE_OK exit=0`).
- [ ] Level 1a: `M.get_shell_info`, the `pick_str` extraction, and the 2 `@field shell string?`
      annotations are all present (4 greps, each expect 1).
- [ ] Level 2a: `bridge_handshake_spec` green with 3 new cases (Success: 15, Failed: 0, Errors: 0).
- [ ] Level 2b: `bridge_smoke` (SMOKE_PASS), `init_spec` (14/0/0), `health_spec` (13/0/0) green.
- [ ] Level 3a: real handshake → `server_info.shell == "/bin/zsh"`, `get_shell_info().shell` ditto.
- [ ] No file other than `lua/pi-bridge/bridge.lua`, `lua/pi-bridge/init.lua`, and
      `tests/bridge_handshake_spec.lua` is modified.

### Feature Validation

- [ ] `pi-bridge.ServerInfo` + `pi-bridge.BridgeDescriptor` each declare the 3 optional shell fields.
- [ ] `resolve_handshake` extracts them via `pick_str` (result-or-descriptor); `nil` when both
      sources lack them; serverVersion/cwd/fdAvailable lines unchanged.
- [ ] `M.get_shell_info()` returns `{shell, shellSource, shellPath}` (fresh table) from
      server_info, else descriptor, else `nil`; never throws; mutating the return is safe.
- [ ] New tests prove: shell-from-result, descriptor-fallback (incl. shellPath nil when omitted),
      and the accessor's source-priority + fresh-table properties.

### Code Quality Validation

- [ ] TAB indentation throughout (match both files); the `pick_str` + `get_shell_info` bodies use tabs.
- [ ] The extraction edit is PURELY ADDITIVE (3 new lines in the `info` table; nothing reordered).
- [ ] No public function signature changed (`connect`/`handshake`/`send`/`request`/`close`/`on_exit`/
      `is_connected`); `M.get_shell_info` is the only new export.
- [ ] The `descriptor()` + `with_hello_server()` helper extensions are backward-compatible
      (existing 1-arg calls + shell-less opts unchanged → the 12 existing cases pass verbatim).
- [ ] No edit to extension/*, transport/connection, shell.lua, completion.lua, or any docs file.

### Documentation & Deployment

- [ ] [Mode A] the 6 new `---@field` lines + the `pick_str` / `get_shell_info` JSDoc blocks
      document the advisory/optional nature + the result-or-descriptor merge + the fallback chain
      shell.lua will run (so a future reader understands WHY nil-not-"").
- [ ] No README / `doc/pi-bridge.txt` / `doc/pi-bridge-shell.txt` / `extension/README.md` change
      (Mode-B task P2.M4.T7 + vimdoc task P2.M3.T6.S4 own those).

---

## Anti-Patterns to Avoid

- ❌ Don't default shell fields to `""` (`shell = pick_str(...) or ""`). They are ADVISORY +
  OPTIONAL — `nil` when unresolved is the contract (GOTCHA #1). A `""` would be a bogus shell
  path that defeats shell.lua's fallback chain (`descriptor.shell → $SHELL → /bin/bash`).
- ❌ Don't skip the type-check ("just use `r.shell or desc.shell`"). The existing cwd/serverVersion
  lines type-check (defends a malformed server). `pick_str` preserves that discipline AND keeps the
  nil-when-absent semantics. The raw `or` would propagate a non-string (e.g. `123`) unguarded.
  (Acceptable ONLY if a reviewer mandates the literal contract form — it still passes every test
  because S3 only ever emits string-or-absent; but it's less defensive than this file's norm.)
- ❌ Don't add a per-field re-fallback inside `get_shell_info` (e.g. "if server_info.shell is nil,
  try descriptor.shell"). At extraction time `server_info.shell` is ALREADY the merged
  `pick_str(result.shell, descriptor.shell)` value. Re-falling-back is redundant + muddies the
  source-priority contract. Read server_info wholesale; fall through to descriptor only when
  server_info is ENTIRELY nil (the pre-handshake window).
- ❌ Don't return a REFERENCE to `M.server_info` from `get_shell_info`. Return a fresh table so the
  caller (shell.lua) cannot mutate module state. (Block D builds a new `{...}` literal — correct.)
- ❌ Don't add a top-level `require("pi-bridge")` to bridge.lua (circular-load hazard at module
  init). Require LAZILY inside `get_shell_info` (GOTCHA #3) — it's the established pattern (L333/L559).
- ❌ Don't touch `M.close()`'s `M.server_info = nil` (L788) — the shell fields ride along for free.
  Adding a separate clear is dead code + a maintenance trap.
- ❌ Don't break the 12 existing handshake cases. They use field-by-field `assert.are.equals`
  (NOT deepEqual), so adding `shell=nil` to server_info is invisible to them — BUT only if the
  `descriptor()` + `with_hello_server()` extensions stay backward-compatible (optional args /
  conditional keys). If you make shell REQUIRED in the helper, you'll break them.
- ❌ Don't edit extension/* (S1/S2/S3), transport/connection, shell.lua (P2.M1.T2), completion.lua,
  or any docs file. Don't add a new RPC method. Don't change any public function signature.
- ❌ Don't heredoc lua into nvim's stdin (AGENTS.md HARD RULE — it hangs the session). Write the
  Level-3 e2e snippet to `/tmp/s4_e2e.lua` and run `+"luafile /tmp/s4_e2e.lua" +qa` (as shown).