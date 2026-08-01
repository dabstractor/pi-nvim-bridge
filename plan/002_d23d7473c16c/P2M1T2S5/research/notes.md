# Research Notes — P2.M1.T2.S5: `_feed(chunk)` buffering + sentinel slicing + JSON decode + normalize

> Fifth subtask of **P2.M1.T2** ("shell.lua daemon manager + fish spike"). S5 **REPLACES the
> S3 `_feed` STUB body** with the full §17.5.1/§17.5.2 response parser: append chunk →
> drain sentinel pairs → `pcall(vim.json.decode)` → normalize to `AutocompleteItem[]` →
> invoke the gen-guarded `state.pending_cb`. Plus the §17.12 parse-failure counter + threshold.
>
> **Parallel context:** S4 (`request`) is being implemented in parallel (treat its PRP as a
> CONTRACT — it sets `state.pending_cb`). S5 CONSUMES `state.pending_cb`. S2/S3 are DONE
> (Complete). S6 (`teardown`) is Planned.

---

## §0 — Task boundary (what S5 owns vs. defers)

**S5 OWNS (the ONLY edits):**
1. **REPLACE the body of `M._feed(chunk)`** (the S3 stub currently does
   `state.rx_buf = state.rx_buf .. (chunk or "")`). Keep the SIGNATURE `M._feed(chunk)` +
   the export (S3's `read_start` wiring + tests call `M._feed`).
2. **ADD `state.parse_failures = 0`** to S2's `state` literal + **`state.parse_failures = 0`**
   to `M.reset()` (the §17.12 "N consecutive parse failures" counter — MUST clear on reset
   or it leaks across daemon restarts; therefore a `state` field, NOT a module-local).
3. **ADD module-local helpers** (`START`/`END` sentinel constants + `normalize_item` +
   `max_parse_failures`) immediately before `M._feed`.
4. **2 new test files**: `tests/shell_feed_smoke.lua` + `tests/shell_feed_spec.lua`.

**S5 DEFERS (forward contracts — documented, NOT implemented):**
- `M.teardown()` → S6 (kill proc + close pipes). S5 forward-GUARDS it
  (`if type(M.teardown)=="function" then ... end`); no-op until S6 lands.
- `notify.once` (the §17.12 one-time degrade notice) → P2.M2.T3.S4. S5 sets the FACT
  (`state.failed=true`); it does NOT notify (mirrors S3 `_reset` / S4 `request`).
- The daemon DRIVER that EMITS the `{"items":[...]}` payload → P2.M2.T4 (fish) / P2.M3.T5
  (zsh/bash). S5 only PARSES what crosses the sentinels.

**S5 does NOT touch:** S2's functions other than the `state` literal + `M.reset()` (additive
1-field/1-line each); S3's `ensure`/`_reset`; S4's `request`/`cancel_req_timer`/`req_timer`;
`completion.lua`, `bridge.lua`, `init.lua`, `notify.lua`; any `extension/`/`doc/`/`ftplugin/`
file; NO `shell/*.lua` driver; NO real subprocess in tests.

---

## §1 — Input contracts (what S5 consumes)

### 1a. The read_start wiring (S3, ALREADY in shell.lua — the caller of _feed)
```lua
-- S3's ensure wires (L~ in the driver.start success cb):
stdout:read_start(function(_, chunk)
    if chunk then M._feed(chunk) else M._reset() end   -- data → S5; EOF → S6 stub
end)
```
→ **`_feed(chunk)` receives ONLY the raw stdout chunk** (a string) — NEVER `line`/`cursor`.
This is the crux of the prefix-resolution design decision (§3 D4): `_feed` has no line/cursor,
so it CANNOT "derive prefix client-side from line[1..cursor]" despite the item description
saying so. It reads `prefix` from the decoded response JSON (§17.5.1 emits it).

### 1b. The daemon response wire format (§17.5.1 — what _feed slices)
```text
__PIRESP_START__\n
{"items":[{"value":"checkout","description":"Checkout and switch to a branch"},...],"prefix":"ch"}
__PIRESP_END__\n
```
- **ONE JSON object** between the sentinels: `{ items:[...], prefix:"..." }`. NOT NDJSON.
  (LIVE-VERIFIED: `vim.json.decode('{"a":1}\n{"b":2}')` THROWS — two objects fail. So the
  payload MUST be a single object. The §17.6.x driver sketches emit per-item lines — that is
  a DOC INCONSISTENCY; the WIRE format is the §17.5.1 `{items}` wrapper. The drivers
  P2.M2.T4/P2.M3.T5 MUST emit `{items:[...]}`, not per-line JSON. FLAGGED forward.)
- **`__PIRESP_END__\n` is MANDATORY** even on error/empty (§17.5.1 robustness) so the slicer
  never waits for a missing close sentinel.

### 1c. The S2 `state` fields S5 reads/writes (the contract)
```lua
---@type pi-bridge.ShellState
local state = { ..., rx_buf="", gen=0, inflight=false, pending_cb=nil, failed=false }
```
- **READS**: `state.rx_buf` (append target), `state.pending_cb` (deliver target).
- **WRITES**: `state.rx_buf` (append/drain), `state.pending_cb` (NOT written — S4 owns it;
  S5 only INVOKES it), `state.parse_failures` (NEW — S5 adds this field), `state.failed`
  (set true on threshold).
- **NEW field `state.parse_failures = 0`** (added to the literal + `M.reset()`). Integer; 0
  on success; incremented per decode failure; threshold → `failed=true`.

### 1d. The S4 `state.pending_cb` contract (the deliver target)
```lua
-- S4's request() sets (treat as contract):
state.pending_cb = function(items, prefix)
    if gen ~= state.gen then return end          -- STALE → drop (supersession)
    cancel_req_timer(); state.pending_cb = nil    -- null-slot-FIRST (exactly-once)
    state.inflight = false
    cb(nil, items, prefix)                        -- success-shape
end
```
→ S5 invokes it as **`if type(state.pending_cb)=="function" then state.pending_cb(items, prefix) end`**.
The `if type(...)` guard is what makes it ONE-SHOT (S4 nils the slot first; a late duplicate
_feed delivery after the slot was nil'd is a no-op). **S5 does NOT vim.schedule the call**
(matches jsonlreader GOTCHA 5 + the §17.5.2 skeleton's direct `pending_cb(...)`; the consumer
P2.M2.T3 schedules the menu hop — E5560).

### 1e. AutocompleteItem (the normalize TARGET — completion.lua L244-250)
```lua
---@class pi-bridge.AutocompleteItem
---@field value string The text to insert on accept (the canonical value).
---@field label string Human-readable label shown in the menu.
---@field [string] any Extra fields (detail, kind, filterText...).
```
Daemon items are `{ value, description? }` (§17.6). Normalize → `{ value, label, description? }`
with `label = item.label or item.value` (defensive: a future driver may send a label).

---

## §2 — Canonical in-repo references (the patterns S5 mirrors)

### 2a. jsonlreader.lua — THE pattern (a sentinel-delimited variant of it)
`lua/pi-bridge/jsonlreader.lua` is the canonical buffered + JSON-decode-from-luv-read_start
reader (for the bridge's newline-delimited JSON-RPC socket). S5's `_feed` is a
**sentinel-delimited** variant. Mirror EXACTLY:
- **Append**: `self.buffer = self.buffer .. chunk` (byte-safe — Lua strings are byte buffers;
  split-multibyte chars reassemble on the next chunk, NO UTF-8 streaming decoder needed).
- **Drain loop**: `while true do local nl = self.buffer:find("\n", 1, true) if not nl then
  return end ... end` — the `true` (4th arg) = **PLAIN byte scan** (pattern matching OFF, so
  literal `%`/`.`/`+` in JSON values don't corrupt the search). S5 uses the SAME plain-search
  for the sentinel needles.
- **Decode**: `local ok, msg = pcall(vim.json.decode, line)` — pcall'd, NEVER throws.
- **on success** → `on_message(msg)` (SYNCHRONOUS, inline — the consumer schedules nvim API work).
- **on failure** → `on_error(line, err)` or SILENT (PRD §11 silent-degrade).
- **GOTCHA list** (jsonlreader header): byte-safe (G1), decode-in-reader (G2), plain find (G3),
  blank-skip (G4 — `decode("")` throws), synchronous on_message (G5), never-throws (G6).
  S5 inherits G1/G3/G5/G6; the sentinel slicer replaces the `\n`-split (G4 becomes "empty
  payload between sentinels throws → parse_failure", which is CORRECT per §17.5.1).

### 2b. tests/shell_fish_spike.lua — the REAL luv read + sentinel slice (handle shape + slicing)
The spike's `try_parse()` is the CLOSEST existing slicing example:
```lua
local s = rx_buf:find("__PIRESP_START__\n", 1, true)
local e = rx_buf:find("__PIRESP_END__", (s or 1) + 1, true)
if not (s and e) then return end
local body = rx_buf:sub(s + #"__PIRESP_START__\n", e - 1)
```
- Confirms `find(needle, 1, true)` plain-search + `sub(s + len, e-1)` slicing idiom.
- The spike parses `word\tdesc` LINES (the §17.6.1 NDJSON sketch). **S5 does NOT** — it
  `vim.json.decode`s the whole body as ONE `{items}` object (§17.5.1, per the item description).
- Confirms the read_start cb shape `function(rerr, data) ... end` + EOF = `data==nil`.

### 2c. completion.lua do_refresh (L465-490) — the normalize + prefix precedent
```lua
local items  = (result and type(result.items)  == "table")  and result.items  or {}
local prefix = (result and type(result.prefix) == "string") and result.prefix or ""
state.last_result = { items = items, prefix = prefix }
if type(M.on_results) == "function" then pcall(M.on_results, buf, items, prefix) end
```
→ S5 mirrors this defensive-shape read (`decoded.items` table-guarded; `decoded.prefix`
string-guarded default ""). S5's `pending_cb(items, prefix)` is the shell analogue of
`on_results(buf, items, prefix)`.

### 2d. S3/S4 sibling tests — the fake-driver injection recipe (Block H)
`tests/shell_ensure_spec.lua` + the S4 PRP Block H: inject `package.loaded["pi-bridge.shell.fish"]`
= a fake driver whose `start(opts, cb)` calls `cb(nil, fake_proc, fake_stdin, fake_stdout)`
SYNCHRONOUSLY + captures the `read_cb` from `stdout:read_start`. This lets tests drive the
read_cb with canned chunks WITHOUT a real subprocess. **S5 reuses this** to set `state.stdin`
(via the real `ensure`) so `request()` (S4) can arm `state.pending_cb` for delivery tests.

---

## §3 — Verified facts (LIVE-CHECKED on Neovim, /tmp/decode_check.lua)

| Probe | Result | Implication |
|---|---|---|
| `vim.json.decode('{"a":1}\n')` | **ok=true, val=1** | trailing `\n` is TOLERATED — payload need not be perfectly trimmed |
| `vim.json.decode('  {"a":1}  ')` | **ok=true** | surrounding whitespace tolerated |
| `vim.json.decode('\n{"a":1}\n')` | **ok=true** | leading+trailing newline tolerated |
| `vim.json.decode('')` | **THROWS** "T_END at char 1" | empty payload → parse_failure (correct; §17.5.1 mandates `{"items":[]}`) |
| `vim.json.decode('   ')` | **THROWS** "T_END at char 4" | whitespace-only → parse_failure |
| `vim.json.decode('{"a":1}\n{"b":2}')` | **THROWS** "T_OBJ_BEGIN at char 9" | **NDJSON FAILS** → payload MUST be ONE `{items}` object (§17.5.1) |
| sentinel slice `sub(ps, e-1)` | payload = `{"items":[]}\n` (trailing \n) | harmless (decode tolerates); trim anyway for determinism |

**Conclusion**: decode tolerates whitespace, so trimming is insurance not necessity — but I
TRIM (`gsub("^%s+",""):gsub("%s+$","")`) for determinism + to make the empty-payload edge
explicit. The payload MUST be a single JSON object (NDJSON breaks).

---

## §4 — Design Decisions (LOCKED)

**D1 — Single-object decode (NOT NDJSON), per §17.5.1 + the item description.**
The item description: "extract the substring … pcall(vim.json.decode, payload) … normalize
items: for each item". This is ONE decode of `{"items":[...], "prefix":"..."}`, then iterate
`.items`. The §17.6.x driver sketches emit per-item lines (NDJSON) — that is a DOC
inconsistency; the WIRE format is §17.5.1's `{items}` wrapper. S5 decodes the single object;
the drivers (P2.M2.T4/P2.M3.T5) MUST conform. (Verified NDJSON fails to decode — §3.)

**D2 — `state.parse_failures` is a STATE field (cleared by `M.reset()`), NOT a module-local.**
Unlike S4's `req_timer` (module-local to avoid touching S2's literal — S4 was parallel with
S3), S5's `parse_failures` is FAILURE STATE that MUST clear on daemon teardown/reset (else it
leaks across restarts → a single failure post-restart immediately re-trips the threshold).
S2/S3 are DONE; S4 uses a module-local (doesn't touch state); S6 calls `reset()` (doesn't
rewrite it). So S5 ADDING `parse_failures = 0` to the `state` literal + `M.reset()` is SAFE
(additive, no parallel conflict) and CORRECT. This is the ONE edit to S2's surface.

**D3 — Threshold = 5, read defensively as `cfg.max_parse_failures` (default 5).**
§17.11 config defines NO parse-failure key (grep-confirmed: zero matches repo-wide). The item
description says "N (config or 5)". So: `local n = cfg.max_parse_failures; if type(n)~="number"
or n<1 then return 5 end`. Forward-compatible (a future config key works) without requiring one
today. The helper `max_parse_failures()` reads config FRESH (lazy require — async handshake +
test mocks; mirrors S2/S4). Called ONLY on the failure path (cheap).

**D4 — Prefix is READ from the decoded response `prefix` field (NOT derived client-side).**
The item description says "derive prefix client-side: last whitespace-delimited token of
line[1..cursor]" — but **`_feed(chunk)` has NO `line`/`cursor`** (the read_start cb passes only
the chunk; §1a). §17.5.1's response JSON INCLUDES `prefix` ("ch" in the example). So S5 reads
`decoded.prefix` (string-guarded, default ""). The CONSUMER `complete_current` (P2.M2.T3.S3),
which HAS the buffer+cursor, may refine/override prefix. S5's job is to PASS IT THROUGH.
This is the only viable resolution given the `_feed(chunk)` signature; documented loudly.

**D5 — Normalize defensively; DROP malformed items (never throw).**
`normalize_item(raw)`: non-table → nil; `value` non-string/empty → nil; else
`{value, label = raw.label or value, description = raw.description or nil}`. A malformed item
is SKIPPED, not fatal (a single bad item among 50 shouldn't fail the whole response). Mirrors
jsonlreader's "never throws" + completion.lua's defensive `result.items or {}`.

**D6 — `parse_failures` resets to 0 on a SUCCESSFUL decode (§17.12 "consecutive").**
A parse success mid-stream clears the counter (a transient glitch shouldn't accumulate). Only
N failures IN A ROW trip the threshold.

**D7 — On threshold: `state.failed=true` + forward-guarded `M.teardown()` + re-assert failed;
NO notify.once.**
§17.12: "after N consecutive parse failures the daemon is killed and marked unhealthy". S5 sets
`failed=true` (the disable fact — `ensure()` short-circuits on it, no new requests). It
forward-GUARDS `M.teardown()` (`if type(M.teardown)=="function" then pcall(M.teardown) end` —
no-op until S6 lands) AND re-asserts `state.failed=true` after (S6's teardown may call
`reset()`, which clears `failed`; the daemon is DEAD → must STAY failed so `ensure()` doesn't
re-spawn a known-broken daemon — §17.12 "no auto-respawn in v1"). S5 does NOT call
`notify.once` (the §17.12 one-time degrade notice is P2.M2.T3.S4 — mirrors S3 `_reset`/S4
`request`: set the fact, defer the side-effect). FLAGGED for S6: teardown() must be safe to
call from inside the stdout read_start callback (S5 invokes it there).

**D8 — EOF guard: `if chunk==nil then M._reset(); return end`.**
S3's read_cb routes EOF to `_reset` directly (`if chunk then M._feed(chunk) else M._reset()`),
so `_feed(nil)` shouldn't occur via the loop. But the item description says "if not chunk then
M._reset()" — so S5 includes the guard (defensive for a direct `_feed(nil)` test call;
idempotent with `_reset`). `chunk==""` → no-op return (avoids a useless `.. ""` + drain loop).

**D9 — `_feed` runs in libuv FAST context; NO `vim.schedule` inside it.**
Matches jsonlreader GOTCHA 5 + the §17.5.2 skeleton's direct `pending_cb(items, prefix)` +
S4's FORWARD CONTRACT. `_feed` does only: string concat + `find`/`sub` (plain) +
`vim.json.decode` (pcall'd) + state writes + the `pending_cb` call (which does state writes +
the user cb). NO `vim.api.*` → fast-safe (E5560). The user cb's editor work (menu hop) is the
CONSUMER's (P2.M2.T3) scheduling responsibility.

---

## §5 — The slicing algorithm (the heart of S5)

```
M._feed(chunk):
  if chunk == nil: M._reset(); return        -- D8 (EOF; idempotent with S3's routing)
  if chunk == "": return
  state.rx_buf = state.rx_buf .. chunk       -- append (byte-safe; mirrors jsonlreader)
  while true:                                -- drain ALL complete pairs in this chunk
    s  = state.rx_buf:find(START, 1, true)   -- "__PIRESP_START__\n", PLAIN (jsonlreader G3)
    if not s: break                          -- no START → wait for more (noise buffered)
    ps = s + #START                          -- payload starts AFTER START\n
    e  = state.rx_buf:find(END, ps, true)    -- "__PIRESP_END__\n", AFTER the START
    if not e: break                          -- START but no END yet → wait for more
    payload = state.rx_buf:sub(ps, e-1)      -- bytes between (may have trailing \n; D trim)
                :gsub("^%s+",""):gsub("%s+$","")   -- trim (decode tolerates ws; insurance)
    state.rx_buf = state.rx_buf:sub(e + #END)     -- ADVANCE past this response (keep remainder)
    ok, decoded = pcall(vim.json.decode, payload)
    if not ok or type(decoded) ~= "table":
        state.parse_failures = (state.parse_failures or 0) + 1
        if state.parse_failures >= max_parse_failures():
            state.failed = true
            pcall(() -> if type(M.teardown)=="function": M.teardown())   -- forward-guard (S6)
            state.failed = true            -- re-assert (S6 reset() may clear; daemon dead)
    else:
        state.parse_failures = 0           -- D6 (consecutive reset on success)
        raw_items = type(decoded.items)=="table" and decoded.items or {}
        prefix     = type(decoded.prefix)=="string" and decoded.prefix or ""
        items = [normalize_item(r) for r in raw_items if normalize_item(r)]  -- D5 (drop malformed)
        if type(state.pending_cb)=="function":
            state.pending_cb(items, prefix)   -- D9 (direct; S4's one-shot gen-guarded cb)
```

**Edge cases handled:**
- **Split across chunks**: START in chunk1, END in chunk2 → buffer accumulates; the `while`
  re-scans each `_feed` until both present. (Mirrors jsonlreader partial-line buffering.)
- **Multiple pairs per chunk**: the `while true` drains them all (each iteration advances
  `rx_buf` past one response).
- **Noise before START** (`prompt$ __PIRESP_START__...`): the `find(START)` skips to START;
  when we advance `rx_buf` past END, the leading noise is discarded. ✓ §17.5.1 "discarded".
- **Noise after END** (`...__PIRESP_END__\nprompt$ `): stays in `rx_buf` as remainder; the
  next START (or next chunk) handles it; if never paired, it's inert buffered bytes (bounded
  by the next valid response or the request timeout). ✓
- **Empty payload** (`START\n\nEND`): trim → `""` → decode throws → parse_failure. ✓ (§17.5.1
  mandates `{"items":[]}`, so empty is a protocol violation.)
- **START but END never arrives**: `find(END)` nil → break → buffer retains START+partial;
  S4's per-request timeout eventually soft-degrades `cb(nil, {}, "")`. ✓ (§17.5.1 robustness.)

---

## §6 — Gotchas

- **G1 (AGENTS.md HARD RULE):** run tests via `+"luafile tests/shell_feed_smoke.lua" +qa` (a
  FILE). NEVER heredoc→nvim stdin (HANGS). Wrap every nvim in `timeout`.
- **G2 — `find(needle, 1, true)` 4th arg MUST be `true` (PLAIN byte scan).** Without it, a `%`
  or `.` inside the JSON payload (or a sentinel byte) corrupts the search. jsonlreader GOTCHA 3.
- **G3 — payload MUST be ONE `{items}` object, NOT NDJSON.** `vim.json.decode('{"a":1}\n{"b":2}')`
  THROWS (verified §3). The §17.6.x driver sketches emit per-item lines — that's a doc bug; the
  WIRE format is §17.5.1's wrapper. S5 decodes single-object; drivers MUST conform.
- **G4 — empty/whitespace payload THROWS** (`T_END`). This is CORRECT (counts as parse_failure;
  §17.5.1 mandates `{"items":[]}`). Do NOT special-case empty→success.
- **G5 — `state.pending_cb` may be NIL** (no request in flight — e.g. stray daemon output, or
  S4's one-shot already fired). The `if type(state.pending_cb)=="function"` guard is MANDATORY
  (a bare `state.pending_cb(...)` would throw on nil). S5 INVOKES it; S4 OWNS setting/niling it.
- **G6 — `parse_failures` MUST be a state field (cleared by reset).** A module-local would
  leak across daemon restarts (reset wouldn't clear it) → a single failure post-restart
  re-trips. D2. (Contrast S4's `req_timer` module-local — a timer isn't failure state.)
- **G7 — NEVER `vim.schedule` inside `_feed`.** It runs in the read_start cb (fast context)
  but does NO `vim.api.*` → fast-safe WITHOUT schedule. The menu hop is P2.M2.T3's job. D9.
- **G8 — `M.teardown()` does NOT exist yet (S6).** Forward-GUARD it (`if type(...)=="function"`)
  + re-assert `state.failed=true` after (S6's teardown may `reset()` and clear `failed`; the
  daemon is dead → stay failed). D7. FLAG for S6: must be callable from the read_start cb.
- **G9 — NO `notify.once` in S5.** The §17.12 degrade notice is P2.M2.T3.S4. S5 sets `failed`
  only (mirrors S3 `_reset` / S4 `request`).
- **G10 — TAB indentation throughout** (match S2/S3/S4's shell.lua). Every new line uses tabs.
- **G11 — no lua linter/formatter.** Validation = the smoke + spec (the ONLY gate).
- **G12 — `require("pi-bridge")` LAZY inside `max_parse_failures()`** (async handshake + test
  mocks swap fakes after require). NEVER at module top. (S2 GOTCHA #1.)
- **G13 — `(pi.config and pi.config.shell) or {}`** NOT `pi.config.shell or {}` (throws if
  config nil). (S2 GOTCHA #2.)
- **G14 — `decode` result type-guard:** `if not ok or type(decoded) ~= "table"`. A successful
  decode of e.g. `"42"` (a bare number) returns a non-table → must be treated as a parse
  failure (no `.items`). Defensive.
- **G15 — `ipairs` over `decoded.items` (NOT `pairs`).** Items are an ORDERED array; `ipairs`
  preserves order + stops at the first nil hole. A non-array `.items` (object) → `ipairs`
  yields nothing → empty items (graceful, not a crash).
- **G16 — Tests set `pending_cb` via `request()` (S4)** (state is module-local — no direct
  setter). Recipe: fake-driver injection (S3/S4 Block H) → real `ensure` caches fake stdin →
  `request(line,cursor,after,cb)` arms `pending_cb` → `M._feed(canned)` delivers → assert `cb`.
  Parse-failure tests need NO `request()` (feed malformed directly; assert via the
  `ensure`→"daemon disabled" probe after N, mirroring ensure_spec).
- **G17 — Don't name a spec-local `pending`** (shadows plenary.busted's skip fn). Use
  `got`/`cb`/`captured`. (S2/S3 note.)

---

## §7 — Forward contracts (do NOT implement in S5)

1. **S6 `teardown()`** — kill proc (`uv.process_kill SIGKILL`) + `pipe:read_stop()` +
   `pipe:close()`×3. S5 forward-GUARDS it on the parse-failure threshold. **S6 must:**
   (a) be safe to call from inside the stdout `read_start` callback (S5 invokes it there);
   (b) if it calls `reset()`, leave `state.failed=true` (the daemon is dead) — S5 re-asserts
   `failed=true` after the call as a belt-and-suspenders guard.
2. **P2.M2.T3.S4** — the §17.12 one-time degrade `notify.once` (category e.g.
   `"shell-daemon-parse"`). S5 sets `failed`; the notice is P2.M2.T3.S4.
3. **P2.M2.T3.S2/S3** — `complete_current(buf, cb)` calls `shell.request(...)`; its `cb`
   receives `(err, items, prefix)` from S5's `pending_cb` → S4's `cb`. It may RE-DERIVE
   `prefix` from the buffer (it has line/cursor, which `_feed` lacks — D4) + must
   `vim.schedule` the menu hop (E5560; the `pending_cb` runs in fast context — D9).
4. **P2.M2.T4 / P2.M3.T5 drivers** — MUST emit the §17.5.1 single-object format
   `__PIRESP_START__\n{"items":[{"value":..,"description":..},...],"prefix":..}\n__PIRESP_END__\n`,
   NOT the §17.6.x per-item NDJSON sketch (G3 — NDJSON fails to decode).
5. **P2.M3.T6.S2** (`:checkhealth`) — may read `state.parse_failures` + `state.failed` to
   report "daemon disabled after N parse failures" + the last error.

---

## §8 — References

**In-repo (READ these):**
- `lua/pi-bridge/jsonlreader.lua` — THE buffered+decode pattern (sentinel variant of it).
- `lua/pi-bridge/shell.lua` — S2 state/resolve/reset + S3 ensure/_feed-STUB/_reset (S5 replaces
  the _feed stub body + adds parse_failures to state/reset).
- `lua/pi-bridge/completion.lua` L244-250 (AutocompleteItem) + L465-490 (normalize+prefix+on_results).
- `tests/shell_fish_spike.lua` — the REAL luv read + sentinel slice (handle shape + find/sub idiom).
- `tests/shell_ensure_spec.lua` + `tests/shell_ensure_smoke.lua` — sibling test conventions
  (fake_bridge, make_fake_driver, before/after_each, the ensure→"daemon disabled" probe).
- `tests/jsonlreader_spec.lua` — the canned-feed test pattern (`reader(feeds, opts)` helper).
- `plan/002_d23d7473c16c/P2M1T2S4/PRP.md` — the `state.pending_cb` contract (S4; S5 invokes it).
- `plan/002_d23d7473c16c/architecture/research-prd-section-17.md` — §17.5.1 (framing),
  §17.5.2 (skeleton), §17.11 (config — no parse key), §17.12 (failure model), §17.15 (testing).

**External (verified facts, not just URLs):**
- `:help vim.json` — `vim.json.decode` tolerates leading/trailing whitespace (LIVE-VERIFIED §3);
  throws on empty/whitespace-only (`T_END`) + on trailing extra tokens (NDJSON). `pcall` it.
- `:help E5560` — api calls forbidden in `vim.uv` fast callbacks; `_feed` (string+json+state
  writes only) is fast-safe WITHOUT `vim.schedule`.
- `:help string.find` — 4th arg `plain=true` = literal byte scan (no pattern interpretation).
- Lua reference — `string.sub(s, i, j)` is byte-based; `..` concatenates byte buffers (UTF-8
  transparent; no streaming decoder needed — jsonlreader GOTCHA 1).