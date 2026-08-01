# PRP — P2.M1.T2.S5: `_feed(chunk)` — sentinel slicing + JSON decode + normalize → `AutocompleteItem[]`

> **Plan mapping:** task `P2.M1.T2.S5` ("`_feed(chunk)` buffering + sentinel slicing + JSON decode +
> normalize to AutocompleteItem[]"). Fifth subtask of **P2.M1.T2** ("shell.lua daemon manager + fish
> spike") within the **Shell Completion for !/!! Bash Mode** epic (PRD §17). This is the **RESPONSE
> PARSE layer** of `shell.lua`: it **REPLACES the S3 `_feed` STUB body** (currently
> `state.rx_buf = state.rx_buf .. (chunk or "")`) with the full §17.5.1/§17.5.2 parser — append chunk →
> drain `__PIRESP_START__\n`…`__PIRESP_END__\n` pairs → `pcall(vim.json.decode)` → normalize to
> `AutocompleteItem[]` → invoke the gen-guarded `state.pending_cb` (set by S4). Plus the §17.12
> consecutive-parse-failure counter + threshold (`state.parse_failures` → `state.failed`).
>
> **Critical scope fact:** S5 does NOT set `state.pending_cb` (S4's `request` owns that — S5 only
> INVOKES it, guarded by `if type(state.pending_cb)=="function"`). S5 does NOT spawn (S3 `ensure`),
> send (S4 `request`), teardown (S6), notify (P2.M2.T3.S4), or route (P2.M2.T3). S5 is the PARSE +
> DELIVER layer. Tests feed canned response STRINGS (with sentinels, JSON payloads, noise) via
> `M._feed(...)` directly + via the S3 fake-driver `read_cb` — NO real subprocess.
>
> **Sibling context (running in PARALLEL with S4):** S4 implements `request` + sets
> `state.pending_cb` (the gen-guarded one-shot response cb). **S5 treats S4's PRP as a CONTRACT** —
> S5 invokes `state.pending_cb(items, prefix)`. S5's delivery tests call `request()` (S4) to ARM
> `pending_cb` (state is module-local — no direct setter), then `M._feed(canned)` to deliver. S2/S3
> are DONE; S5 makes ONE additive edit to S2's surface (adds `parse_failures = 0` to the `state`
> literal + `M.reset()` — see D2). The fish driver (P2.M2.T4) produces the `{"items":[...]}` payload
> S5 parses; S6's `teardown()` (forward-guarded) kills the daemon on parse-failure threshold.

---

## Goal

**Feature Goal**: Replace the `M._feed(chunk)` stub in `lua/pi-bridge/shell.lua` with the full §17.5.1
sentinel-framing response parser + §17.5.2 item normalization + §17.12 parse-failure handling. On each
stdout chunk from the daemon pipe: (1) append to `state.rx_buf`; (2) drain EVERY complete
`__PIRESP_START__\n`…`__PIRESP_END__\n` pair present (loop, mirroring `jsonlreader.feed`); (3) for each
pair: trim the payload, `pcall(vim.json.decode)`, and on success reset `state.parse_failures`, extract
`items` + `prefix` (defensively), normalize each raw `{value, description?}` → `AutocompleteItem
{value, label, description?}` (dropping malformed items), and invoke `state.pending_cb(items, prefix)`
if it is a function (the S4 one-shot gen-guarded cb); on decode failure increment
`state.parse_failures` and at the §17.12 threshold (default 5) mark `state.failed=true` +
forward-guard `M.teardown()` (no-op until S6) + re-assert `failed`; (4) advance `rx_buf` past each
consumed response (leftover stays buffered). Anything outside the sentinels (prompts, async segments,
stray output) is buffered-then-discarded. NEVER throws (pcall decode; type-guarded extracts); runs in
libuv fast context with NO `vim.api.*` (no `vim.schedule` — the menu hop is the consumer's job).

**Deliverable** (ONE source file EDITED + 2 new test files — nothing else touched):
- **`lua/pi-bridge/shell.lua`** — THREE additive edits: (a) **REPLACE the `M._feed(chunk)` STUB body**
  (keep the signature `M._feed(chunk)` + the export — S3's `read_start` wiring + tests call it) with
  the full parser (~45-60 lines); (b) **ADD `parse_failures = 0,`** to S2's `state` literal + a
  module-local `START`/`END` sentinel constant + a `normalize_item` local + a `max_parse_failures`
  local placed immediately before `M._feed`; (c) **ADD `state.parse_failures = 0`** to `M.reset()`.
  Zero edits to S2's other functions / S3's `ensure`/`_reset` / S4's `request`/`cancel_req_timer`/
  `req_timer` / the `[Mode A]` header (beyond the 1-line `state` + `reset` additions). Zero
  `vim.uv.spawn`; zero `vim.notify`/`notify.once`; zero `vim.schedule`.
- **`tests/shell_feed_smoke.lua`** — plenary-FREE smoke (mirror `tests/shell_ensure_smoke.lua` +
  `tests/jsonlreader_smoke.lua`): exercises the parse matrix (happy-path single/multi-pair, split-
  across-chunks, noise-outside-discarded, empty-items, malformed→parse_failure, threshold→disabled,
  prefix-passthrough, EOF, never-throws, pending_cb-nil-safe, label-from-value) with canned strings
  fed to `M._feed` (+ the S3 fake-driver `read_cb`). Prints `SMOKE_PASS`; exit 0.
- **`tests/shell_feed_spec.lua`** — plenary/busted spec (mirror `tests/shell_ensure_spec.lua` +
  `tests/jsonlreader_spec.lua`): the same matrix as focused `it(...)` cases with field-by-field asserts
  + before/after_each save/restore.

**Success Definition**:
- `M._feed("__PIRESP_START__\n" .. '{"items":[{"value":"checkout","description":"Checkout a branch"}],"prefix":"ch"}' .. "\n__PIRESP_END__\n")`
  with `state.pending_cb` armed (via `request`, S4) invokes `pending_cb({{value="checkout",
  label="checkout", description="Checkout a branch"}}, "ch")` → the user `cb(nil, items, "ch")` fires;
  `state.rx_buf` is drained to `""` (the pair consumed); `state.parse_failures==0`.
- A SINGLE chunk carrying TWO pairs drains BOTH (loop); each invokes `pending_cb` once (the 2nd is a
  no-op only if S4 already nil'd the slot — S5 just calls through the `if type(...)` guard).
- A pair SPLIT across two chunks (`"...START__\n{..."` then `...}\n__PIRESP_END__\n"`) is reassembled:
  the first `_feed` buffers (no delivery, no error); the second delivers.
- Noise OUTSIDE sentinels (`"prompt$ __PIRESP_START__\n{...}\n__PIRESP_END__\n trailing$ "`) is
  discarded: the payload parses, `rx_buf` ends holding only `" trailing$ "` (or `""` if trailing
  trimmed). NO parse_failure.
- Malformed JSON between sentinels (`"__PIRESP_START__\n{bad json}\n__PIRESP_END__\n"`) → decode throws
  (pcall'd) → `state.parse_failures` increments; `pending_cb` NOT called. After N (default 5)
  CONSECUTIVE failures: `state.failed=true`; a follow-up `ensure(cb)` short-circuits with
  `cb("daemon disabled")` (the same probe `shell_ensure_spec` uses). A SUCCESSFUL parse mid-stream
  resets `parse_failures` to 0 (§17.12 "consecutive").
- `M._feed(nil)` → calls `M._reset()` (EOF; idempotent with S3's read_cb routing); `M._feed("")` →
  no-op. `M._feed(...)` NEVER throws (a payload that is a bare number `"42"` → decode succeeds but
  `type(decoded)~="table"` → treated as a parse failure; a non-array `.items` → empty items, no crash).
- `M._feed` with `state.pending_cb == nil` (no request in flight) parses + drains silently (no throw
  on the nil cb — the `if type(...)=="function"` guard).
- `shell_feed_smoke` prints `SMOKE_PASS` (exit 0); `shell_feed_spec` green (0 fail, 0 error).
- `shell_spec` (S2), `shell_ensure_spec`/`_smoke` (S3), `shell_request_spec`/`_smoke` (S4, if landed),
  `completion_spec`, `jsonlreader_spec`, `bridge_handshake_spec`, `init_spec` stay green (S5 is purely
  additive + the 1-line state/reset additions).
- NO file under `extension/`, `doc/`, `ftplugin/`, `plugin/`, `completion.lua`, `bridge.lua`,
  `init.lua`, `notify.lua`, `jsonlreader.lua`, or `README.md` is modified. NO `shell/*.lua` driver
  created. NO real subprocess spawned.

## User Persona (if applicable)

**Target User**: the implementer of **P2.M2.T3** (completion routing) — specifically
**P2.M2.T3.S2/S3** (`completion.lua` shell branch + `shell.complete_current(buf, cb)`). Routing calls
`M.request(line, cursor, after, cb)` (S4); its `cb(err, items, prefix)` is the S4 `pending_cb` → which
S5's `_feed` invokes with the parsed+normalized `items` + `prefix`. Secondary consumers: the daemon
DRIVERS (**P2.M2.T4** fish / **P2.M3.T5** zsh/bash) which MUST emit the §17.5.1 single-object
`{"items":[...],"prefix":"..."}` payload S5 decodes (NOT the §17.6.x per-item NDJSON sketch — verified
NDJSON fails to decode); **P2.M3.T6.S2** (`:checkhealth`) which reads `state.parse_failures`/`failed`;
**S6** (`teardown`) which S5 forward-guards on the parse-failure threshold.

**Use Case**: per keystroke on a `!`-line, the daemon (warm after S3's first `ensure`) emits a framed
`__PIRESP_START__\n{items}\n__PIRESP_END__\n` response. Because the daemon's stdout also carries shell
prompt noise (PS1 segments, async prompt decorators), the sentinels ISOLATE the JSON payload. S5's
`_feed` buffers the raw chunks (which the OS may split arbitrarily), slices each sentinel pair, decodes,
normalizes to the menu's `AutocompleteItem` shape, and delivers to the in-flight request's cb — all
without blocking the editor (fast context) or throwing on any malformed input (silent-degrade to empty
or, after N consecutive garbage responses, daemon-disable per §17.12).

**Pain Points Addressed**: without S5, S3's stub `_feed` just accumulates bytes in `rx_buf` forever
(never parses, never delivers) — completion would hang until S4's per-request timeout soft-degrades to
empty on every keystroke. S5 is the layer that turns raw pipe bytes into menu items. The sentinel
slicing (not a naive `\n`-split, like the bridge's `jsonlreader`) is what handles prompt noise +
split-across-chunks correctly. The defensive normalization + parse-failure counter (§17.12) ensure a
buggy/fragile driver (zsh capture-completion is explicitly "the most fragile driver", §17.6.2) degrades
gracefully instead of crashing the editor or wedging the menu.

## Why

- **It is the explicit §17.16 step-22 response half.** PRD §17.16 orders Phase 6: *(22) `shell.lua`
  daemon manager: resolution, spawn/teardown, framed protocol, gen-guard supersession, item
  normalization.* S2 = resolution+state; S3 = spawn; S4 = request/send; **S5 = feed/parse/normalize +
  the §17.12 parse-failure disable**; S6 = teardown. The §17.5.2 skeleton's `_feed` comment is verbatim
  the S5 spec: "_feed(chunk): append to rx_buf; while a `__PIRESP_START__`/`__PIRESP_END__` pair is
  present, slice it out, vim.json.decode, normalize to AutocompleteItem[], call pending_cb (gen-guarded).
  Leftover stays in rx_buf. pcall every decode."
- **Consumes the S4 `pending_cb` contract cleanly, ZERO file conflict.** S4 OWNS `request` + setting
  `state.pending_cb`; S5 OWNS `_feed` (REPLACE its body) + INVOKING `pending_cb`. S5's only edit OUTSIDE
  `_feed` is the additive `parse_failures = 0` in `state` + `reset()` (S2's surface — DONE, no parallel
  editor; D2). S4 uses a module-local `req_timer` (avoids touching `state`); S5's `parse_failures` is
  failure state that MUST reset (D2) — so it's a state field. No overlap.
- **The §17.12 "N consecutive parse failures → disabled" is a correctness + UX requirement.** Without
  it, a fragile driver (zsh) emitting garbage would silently fail EVERY completion (decode throws →
  pcall swallows → `pending_cb` never called → S4 timeout soft-degrades to empty every keystroke — the
  menu flickers empty forever, no diagnostic). S5's counter trips at N (default 5) → `state.failed=true`
  → `ensure()` short-circuits → completion cleanly OFF for the session + the health check reports it.
- **The sentinel framing (vs the bridge's `\n`-delimited JSONL) is mandated by the daemon's stdout
  carrying prompt noise.** A naive `jsonlreader`-style `\n`-split would try to decode prompt segments
  (`"user@host:~$ "`) as JSON → constant parse noise. The `__PIRESP_*` sentinels isolate the payload;
  S5's slicer discards everything outside them (§17.5.1 "discarded"). This is the central framing
  difference from the bridge path.
- **The "never blocks, never throws" invariant is a luv-callback safety requirement.** `_feed` runs in
  the `stdout:read_start` callback (libuv fast context). A throw would escape the luv callback and
  surface as a spurious pipe error (jsonlreader GOTCHA 6). S5 pcalls every decode + type-guards every
  extract + guards the `pending_cb` call → it can never throw, on ANY input (empty, malformed,
  non-object, non-array `.items`, nil `pending_cb`).
- **Canned-string tests give full parse coverage WITHOUT a real shell.** The live spawn + framed
  round-trip was proven by S1's spike (and re-provable via `tests/shell_fish_spike.lua`). S5's logic
  (append + sentinel-find + slice + decode + normalize + deliver + failure-count) is pure string +
  table work — exhaustively testable by feeding canned response strings to `M._feed`. (research §5/§6.)

## What

**User-visible behavior**: none at runtime (no caller wires `shell.lua` into the plugin yet —
completion routing is P2.M2.T3; the daemon driver is P2.M2.T4). The observable artifact is the module's
`_feed` behavior + the test verdicts:

```bash
$ timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_feed_smoke.lua" +qa
SMOKE_PASS
$ echo "exit=$?"
exit=0
```

**Technical requirements** (all in `lua/pi-bridge/shell.lua` unless noted):
- **Module-local sentinel constants** (declared immediately before `M._feed`):
  `local START = "__PIRESP_START__\n"` + `local END = "__PIRESP_END__\n"`. Used by the `find(..., true)`
  plain byte scan (jsonlreader GOTCHA 3 — the 4th `true` arg disables pattern matching, so a `%`/`.` in
  the JSON never corrupts the sentinel search).
- **`local function normalize_item(raw)`**: returns an `AutocompleteItem` `{value, label, description?}`
  or `nil` (drop malformed). `type(raw)~="table"` → nil; `type(raw.value)~="string"` or `""` → nil;
  else `label = (type(raw.label)=="string" and raw.label~="" and raw.label) or raw.value`,
  `description = (type(raw.description)=="string" and raw.description~="") and raw.description or nil`.
  (D5 — defensive; a malformed item among many is skipped, not fatal.)
- **`local function max_parse_failures()`**: `local pi = require("pi-bridge"); local cfg = (pi.config and
  pi.config.shell) or {}; local n = cfg.max_parse_failures; if type(n)~="number" or n<1 then return 5 end;
  return math.floor(n)`. (D3 — §17.11 defines no key; defensive read defaults to 5; lazy require.)
- **`M._feed(chunk)`** (REPLACE the S3 stub body; keep signature + export):
  1. `if chunk == nil then M._reset(); return end` — EOF guard (D8; idempotent with S3's read_cb routing).
  2. `if chunk == "" then return end` — no-op on empty (avoid a useless concat + drain loop).
  3. `state.rx_buf = state.rx_buf .. chunk` — append (byte-safe; jsonlreader GOTCHA 1).
  4. `while true do` — drain EVERY complete pair (mirror `jsonlreader.feed`'s drain loop):
     - `local s = state.rx_buf:find(START, 1, true)`; `if not s then break end` (no START → wait).
     - `local ps = s + #START` (payload starts AFTER `START\n`).
     - `local e = state.rx_buf:find(END, ps, true)`; `if not e then break end` (START but no END → wait).
     - `local payload = state.rx_buf:sub(ps, e - 1):gsub("^%s+", ""):gsub("%s+$", "")` (extract +
       trim; decode tolerates whitespace but trim is deterministic — verified §3).
     - `state.rx_buf = state.rx_buf:sub(e + #END)` (ADVANCE past this response; keep remainder).
     - `local dok, decoded = pcall(vim.json.decode, payload)`.
     - **on failure** (`not dok or type(decoded) ~= "table"`): `state.parse_failures =
       (state.parse_failures or 0) + 1`; `if state.parse_failures >= max_parse_failures() then
       state.failed = true; pcall(function() if type(M.teardown)=="function" then M.teardown() end end);
       state.failed = true end` (D7 — disable + forward-guard S6 teardown + re-assert failed).
     - **on success**: `state.parse_failures = 0` (D6); `local raw_items = (type(decoded.items)=="table")
       and decoded.items or {}`; `local prefix = (type(decoded.prefix)=="string") and decoded.prefix or
       ""`; build `items = {}` via `for _, raw in ipairs(raw_items) do local n = normalize_item(raw); if
       n then items[#items+1] = n end end`; `if type(state.pending_cb)=="function" then
       state.pending_cb(items, prefix) end` (D9 — direct invoke; S4's one-shot gen-guarded cb).
- **`state` literal**: ADD `parse_failures = 0,` (the §17.12 counter; D2). **`M.reset()`**: ADD
  `state.parse_failures = 0` (clear on teardown/restart; D2).
- **NEVER throws**: `pcall` decode; type-guard `decoded`/`.items`/`.prefix`/`pending_cb`; `ipairs`
  (ordered, nil-hole-safe); guard `chunk` nil/"". `_feed` does NO `vim.api.*` (string + `vim.json` +
  state writes + the `pending_cb` call only) → fast-context-safe WITHOUT `vim.schedule` (E5560). The
  user cb's editor work is the CONSUMER's (P2.M2.T3) scheduling responsibility (FORWARD CONTRACT §3).

### Success Criteria

- [ ] `lua/pi-bridge/shell.lua` exposes `M._feed` as a function (signature unchanged from S3); the body
      is the full parser (NOT the `state.rx_buf = state.rx_buf .. (chunk or "")` stub); `START`/`END`/
      `normalize_item`/`max_parse_failures` module-locals exist before it; `state.parse_failures` field
      + `M.reset()` clear line exist.
- [ ] A complete single-pair chunk → `pending_cb({normalized}, prefix)` invoked (with `pending_cb`
      armed via `request`/S4); `rx_buf` drained to `""`; `parse_failures==0`.
- [ ] A chunk with TWO pairs drains BOTH (loop); each invokes `pending_cb` (subject to S4's one-shot).
- [ ] A pair SPLIT across two `_feed` calls is reassembled (1st buffers, 2nd delivers).
- [ ] Noise OUTSIDE sentinels is discarded (payload parses; `rx_buf` holds only trailing remainder).
- [ ] Malformed JSON → `parse_failures` increments; `pending_cb` NOT called. N (default 5) CONSECUTIVE →
      `state.failed=true`; follow-up `ensure` → `cb("daemon disabled")`. A mid-stream success resets
      `parse_failures` to 0.
- [ ] `config.shell.max_parse_failures` honored (NOT 5 default when set to e.g. 3); nil config → 5, no throw.
- [ ] Empty `items` array (`{"items":[]}`) → `pending_cb({}, "")` (NOT a parse failure).
- [ ] `prefix` read from `decoded.prefix` (string-guarded, default "") — NOT derived from line/cursor
      (which `_feed` lacks; D4).
- [ ] `label = item.label or item.value` (defensive; description-less items get `label==value`).
- [ ] `M._feed(nil)` → `M._reset()` (EOF); `M._feed("")` → no-op. `M._feed` NEVER throws (bare-number
      payload, non-table `.items`, nil `pending_cb`, `request(nil,6,"",nil)` not in scope but `_feed`
      itself never throws on any string).
- [ ] `shell_feed_smoke` prints `SMOKE_PASS` (exit 0); `shell_feed_spec` green (0 fail, 0 error).
- [ ] `shell_spec` (S2), `shell_ensure_*` (S3), `shell_request_*` (S4, if landed), `completion_spec`,
      `jsonlreader_spec`, `bridge_handshake_spec`, `init_spec` stay green.
- [ ] NO edit to `extension/*`, `doc/*`, `ftplugin/*`, `plugin/*`, `completion.lua`, `bridge.lua`,
      `init.lua`, `notify.lua`, `jsonlreader.lua`, or `README.md`. NO `shell/*.lua` created. NO real
      subprocess. NO `vim.uv.spawn` / `notify.once` / `vim.schedule(` CALL in S5's code.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo gets (a) the verbatim
§17.5.1/§17.5.2 spec (the EXACT `__PIRESP_START__\n{items,prefix}\n__PIRESP_END__\n` wire shape + the
`_feed` skeleton comment), (b) the EXACT S2 `state` fields S5 reads/writes + the EXACT S3 `read_start`
wiring (the caller of `_feed`) + the EXACT S4 `state.pending_cb` contract S5 invokes (all three treated
as contracts), (c) the canonical in-repo references for EVERY non-obvious mechanic — `jsonlreader.lua`
(THE buffered+decode-from-luv pattern; S5 is its sentinel-framed twin), the fish spike (the REAL luv
read + `find`/`sub` sentinel-slice idiom), `completion.lua` (the `AutocompleteItem` shape + the
defensive `result.items`/`result.prefix` normalize precedent), the S3/S4 sibling tests (the
fake-driver injection recipe), (d) the LIVE-VERIFIED facts (`vim.json.decode` tolerates whitespace but
throws on empty/NDJSON; `find` plain-search; byte-safe concat) with the probe that proved them, (e) the
two test files to mirror (`shell_ensure_smoke/spec` + `jsonlreader_spec`), (f) the locked design
decisions (single-object decode not NDJSON; `parse_failures` as a state field not module-local; prefix
read from JSON not derived; defensive normalize drops malformed; threshold 5; forward-guarded teardown;
no notify; no vim.schedule; cb-only/pending_cb invoke), and (g) the scope fence (NOT: set pending_cb,
spawn, send, teardown, notify, route, drivers). The genuine judgment calls (the item description's
"derive prefix client-side" vs `_feed` lacking line/cursor; the `M.teardown()` call when S6 isn't
landed; `parse_failures` as state vs module-local; single-object vs NDJSON) are decided in Design
Decisions §1-§9 + Anti-Patterns.

### Documentation & References

```yaml
# MUST READ — the spec (reproduced in this PRP's <selected_prd_content>)
- docfile: PRD.md
  why: "§17.5.1 gives the framing protocol (the EXACT __PIRESP_START__\\n{items,prefix}\\n__PIRESP_END__\\n wire shape + the 'discard anything outside sentinels' rule + the '__PIRESP_END__ even on error/empty' robustness). §17.5.2 gives the shell.lua _feed skeleton comment (append→drain pairs→decode→normalize→pending_cb→leftover stays; pcall every decode). §17.12 gives the failure model ('after N consecutive parse failures the daemon is killed and marked unhealthy'). §17.11 gives config (NO parse-failure key → default 5). §17.15 gives the testing strategy (shell_daemon_spec: 'N consecutive-parse-failures → disabled')."
  section: "h3.34 (§17.5 + §17.5.2 skeleton), h4.3 (§17.5.1 framing), h4.4 (§17.5.2 _feed skeleton), h3.41 (§17.12 failure modes), h3.40 (§17.11 config), h3.44 (§17.15 testing)"
  critical: "The skeleton's _feed comment is verbatim the S5 spec. The §17.6.x driver sketches emit per-item NDJSON lines — that is a DOC INCONSISTENCY with §17.5.1's single-object {items} wrapper; S5 decodes single-object (LIVE-VERIFIED NDJSON fails: vim.json.decode('{\"a\":1}\\n{\"b\":2}') THROWS). Drivers (P2.M2.T4/P2.M3.T5) MUST emit the §17.5.1 {items} format. The item description's 'derive prefix client-side: last whitespace-delimited token of line[1..cursor]' is impossible for _feed (it only receives the chunk, never line/cursor — see S3's read_start wiring); S5 reads decoded.prefix instead (D4)."

# MUST READ — the canonical in-repo buffered+decode pattern (S5 is its sentinel-framed twin)
- file: lua/pi-bridge/jsonlreader.lua
  why: "the SINGLE best reference for S5's structure. M.feed: `self.buffer = self.buffer .. chunk` (append) + `while true do local nl = self.buffer:find(\"\\n\", 1, true) if not nl then return end ... end` (drain loop, PLAIN find — GOTCHA 3 the 4th true arg) + `pcall(vim.json.decode, line)` (never throws — GOTCHA 6) + `on_message(msg)` (SYNCHRONOUS inline — GOTCHA 5, consumer schedules nvim work). S5 mirrors ALL of these; the ONLY difference is the sentinel pair (START..END) replaces the `\\n`-split, and S5 delivers to state.pending_cb instead of an on_message cb. The header GOTCHA list (byte-safe G1, plain-find G3, blank-skip G4, synchronous G5, never-throws G6) is S5's reference card."
  pattern: "append → drain loop (plain find) → pcall decode → synchronous deliver → never throws."
  gotcha: "jsonlreader splits on \\n (the bridge socket is clean JSONL). S5 CANNOT — the daemon's stdout carries shell prompt noise, so it slices START..END sentinels and DISCARDS the rest. A naive \\n-split would try to decode prompt segments as JSON → constant parse noise."

# MUST READ — the canonical REAL luv read + sentinel slice (the handle shape + the find/sub idiom)
- file: tests/shell_fish_spike.lua
  why: "the LIVE proof of the framed round-trip + the slicing idiom. try_parse(): `s = rx_buf:find(\"__PIRESP_START__\\n\", 1, true); e = rx_buf:find(\"__PIRESP_END__\", (s or 1)+1, true); body = rx_buf:sub(s + #\"__PIRESP_START__\\n\", e-1)` — the EXACT find(plain)+sub(s+len, e-1) idiom S5 uses. Also: stdout:read_start(function(rerr, data) ... end) with EOF = data==nil; pcall every uv call; teardown kill+close×N."
  pattern: "find(needle, 1, true) plain byte scan; sub(s + #sentinel_with_newline, e-1) slices the payload; read_start cb is _feed's caller."
  gotcha: "the spike parses word\\tdesc LINES (the §17.6.1 NDJSON sketch) via gmatch. S5 does NOT — it vim.json.decode's the WHOLE body as ONE {items} object (§17.5.1; verified NDJSON fails). The spike's line-parser is the OLD format; do not copy it. Also: the spike searches END without the trailing \\n; S5 searches END WITH \\n (__PIRESP_END__\\n) to match §17.5.1 exactly + ensure the full close-sentinel arrived."

# MUST READ — the AutocompleteItem shape + the normalize/prefix precedent
- file: lua/pi-bridge/completion.lua
  why: "L244-250 the @class pi-bridge.AutocompleteItem {value, label, [extra]} (the normalize TARGET). L465-490 do_refresh's cb: the defensive extract `items = (result and type(result.items)==\"table\") and result.items or {}`; `prefix = (result and type(result.prefix)==\"string\") and result.prefix or \"\"` — the EXACT shape-guard S5 mirrors on decoded.items/.prefix. And `pcall(M.on_results, buf, items, prefix)` — the synchronous deliver S5 mirrors via state.pending_cb(items, prefix)."
  pattern: "type-guarded .items (table) + .prefix (string, default \"\") extract; deliver synchronously."
  gotcha: "completion.lua's cb runs via bridge's schedule_wrap (already in the nvim loop). shell.lua has NO bridge — _feed runs in the raw luv read_start cb (fast context). So the consumer (P2.M2.T3) must vim.schedule the menu hop; S5's pending_cb call itself is fast-safe (state writes + the user cb)."

# MUST READ — the IMMEDIATE upstream contract (S4 sets pending_cb; S5 invokes it). Treat as a contract.
- file: plan/002_d23d7473c16c/P2M1T2S4/PRP.md
  why: "defines state.pending_cb EXACTLY: a one-shot gen-guarded closure `function(items, prefix) if gen ~= state.gen then return end; cancel_req_timer(); state.pending_cb = nil (null-slot-FIRST); state.inflight = false; cb(nil, items, prefix) end`. S5 invokes it as `if type(state.pending_cb)==\"function\" then state.pending_cb(items, prefix) end` — the `if type(...)` guard is what makes a late/duplicate _feed delivery a no-op after S4 nil'd the slot. S5's delivery tests ARM pending_cb via request() (S4) — see the test recipe (GOTCHA #16)."
  critical: "S4 is editing shell.lua IN PARALLEL with S5 (request appends; S5 replaces the _feed body + adds parse_failures). S5 does NOT touch request/cancel_req_timer/req_timer. If S4 hasn't landed, S5's parse-failure + slicing tests still work (they feed M._feed directly + assert via the ensure probe); only the DELIVERY tests need request() (gate them on S4's presence, OR arm pending_cb via a fake-driver+request once S4 lands)."

# MUST READ — the sibling test conventions (S3; the exact patterns S5's tests mirror)
- file: tests/shell_ensure_spec.lua
  why: "the bootstrap (require pi-bridge + shell; if pi.config==nil then pi.setup({}) end); fake_bridge(shell_path, server_cwd); make_fake_driver() with captured.read_cb + fake_pipe() (read_start/write/close/read_stop/is_closing); before_each/after_each save/restore SHELL/bridge/descriptor/config/package.loaded[fish] + shell.reset(); describe/it with assert.are.equals/is_nil/is_truthy/has_no.errors. The `ensure→cb(\"daemon disabled\")` probe (after state.failed) is the EXACT way S5's parse-failure tests assert the threshold tripped."
  pattern: "fake-driver injection → real ensure caches fake stdin/stdout + wires read_cb → tests invoke read_cb(nil, chunk) OR call M._feed(chunk) directly. The ensure short-circuit ('daemon disabled') is the observable for state.failed."
  gotcha: "do NOT name a spec-local `pending` (shadows plenary.busted's skip fn). state is module-local — tests cannot set state.pending_cb directly; they ARM it via request() (S4) with a fake-driver-backed ensure (GOTCHA #16)."

# MUST READ — the canned-feed test pattern (jsonlreader_spec's reader(feeds, opts) helper)
- file: tests/jsonlreader_spec.lua
  why: "the EXACT pattern for feeding canned multi-chunk strings + asserting decoded output. reader(feeds, opts): creates a reader, feeds a TABLE of chunk strings (NOT a bare string — GOTCHA 12), captures msgs. S5's analogue: a feed(feeds, opts) helper that arms pending_cb (via request/S4) + feeds canned strings to M._feed + captures (items, prefix). The split-across-chunks case (reader({ '{\"x\":\"', 'val\"}\\n' })) is the template for S5's split-pair test."
  pattern: "feeds is a TABLE of chunk strings; assert.are.same on the captured msgs table."

# MUST READ — local research notes (verified facts + the 9 locked design decisions + the slicing algorithm + the test matrix)
- docfile: plan/002_d23d7473c16c/P2M1T2S5/research/notes.md
  why: "§0 the task-boundary fence (S5 vs S2/S3/S4/S6/drivers/routing). §1 the INPUT contracts (S3 read_start wiring, S2 state, S4 pending_cb, the daemon response format, AutocompleteItem). §2 the canonical in-repo references (jsonlreader, the fish spike, completion normalize, the sibling tests). §3 the LIVE-VERIFIED facts (decode whitespace tolerance, NDJSON fails, empty throws — with the /tmp probe). §4 the 9 locked design decisions (D1 single-object; D2 parse_failures as state; D3 threshold 5; D4 prefix from JSON; D5 defensive normalize; D6 consecutive reset; D7 teardown forward-guard + re-assert; D8 EOF guard; D9 no vim.schedule). §5 the slicing algorithm pseudocode + edge cases. §6 the 17 gotchas. §7 the forward contracts. §8 references."

# SUPPORTING — the current shell.lua (S2+S3 output; S5 replaces the _feed stub body)
- file: lua/pi-bridge/shell.lua
  why: "the file S5 edits. S2's `local state = { ... }` literal (add parse_failures=0); S2's M.reset() (add state.parse_failures=0); S3's M.ensure read_start wiring (the _feed CALLER — confirms _feed receives only chunk); S3's M._feed STUB (the body to REPLACE — currently `state.rx_buf = state.rx_buf .. (chunk or \"\")`); S3's M._reset (the EOF path S5's nil-guard calls). The `[Mode A]` header documents the forward-contract seams (M._feed → S5)."

# SUPPORTING — architecture research (confirms the skeleton + framing + failure model + config + testing)
- docfile: plan/002_d23d7473c16c/architecture/research-prd-section-17.md
  why: "§17.5.1 (the framing protocol + 'discard outside sentinels' + '__PIRESP_END__ even on error'). §17.5.2 (the _feed skeleton comment). §17.11 (config — grep-confirmed NO parse-failure key → default 5). §17.12 ('N consecutive parse failures → killed + marked unhealthy'). §17.15 (shell_daemon_spec: 'N consecutive-parse-failures → disabled')."
  section: "§17.5.1, §17.5.2, §17.11, §17.12, §17.15"

# SUPPORTING — the dedup notify mechanism (S5 references in HEADER only; does NOT call)
- file: lua/pi-bridge/notify.lua
  why: "M.once(category, level, msg). S5's header documents that the §17.12 one-time degrade notify (category e.g. 'shell-daemon-parse') is P2.M2.T3.S4's job; S5 has ZERO notify.once calls (it sets only state.failed — mirrors S3 _reset / S4 request)."
```

### Current Codebase tree (relevant slice)

```bash
lua/pi-bridge/
├── shell.lua          # ← S2 CREATED (state + resolve/pick/cwd/reset); S3 APPENDED ensure/_feed(STUB)/_reset.
│                      #   S5 REPLACES the _feed STUB BODY + adds parse_failures to state/reset + the
│                      #   START/END/normalize_item/max_parse_failures module-locals. Does NOT touch
│                      #   S2's other functions / S3's ensure/_reset / S4's request (if landed).
├── jsonlreader.lua    # READ-ONLY — THE buffered+decode pattern (S5 is its sentinel-framed twin).
├── completion.lua     # READ-ONLY — AutocompleteItem shape (L244-250) + the normalize/prefix precedent (L465-490).
├── bridge.lua         # READ-ONLY (resolve_request/M.send — S4's reference; S5 does not touch).
├── init.lua           # READ-ONLY — M.config (nil until setup; max_parse_failures defensive read).
└── notify.lua         # READ-ONLY — M.once dedup (S5 header-only reference; NOT called in S5).
lua/pi-bridge/shell/   # DOES NOT EXIST YET — P2.M2.T4 (fish) / P2.M3.T5 (zsh/bash) create the drivers
                      #   that EMIT the {items} payload S5 parses. S5 tests feed canned strings — no driver.
tests/
├── shell_fish_spike.lua      # READ-ONLY — the canonical real uv.spawn + pipe read + sentinel slice.
├── shell_ensure_smoke.lua    # READ-ONLY (S3) — the smoke convention S5's smoke mirrors.
├── shell_ensure_spec.lua     # READ-ONLY (S3) — the spec convention + fake-driver recipe S5's spec mirrors.
├── jsonlreader_spec.lua      # READ-ONLY — the canned-feed test pattern (reader(feeds, opts)).
├── (shell_request_smoke.lua, shell_request_spec.lua)   # S4's tests (if landed) — S5's tests are SIBLINGS.
└── (shell_feed_smoke.lua, shell_feed_spec.lua)         # ← S5 CREATES both
```

### Desired Codebase tree with files to be added/edited

```bash
lua/pi-bridge/shell.lua             # EDIT — REPLACE M._feed body (~+50-65 lines); ADD parse_failures to
                                     #   state literal + M.reset() (2 additive lines); ADD START/END/
                                     #   normalize_item/max_parse_failures module-locals before _feed.
tests/shell_feed_smoke.lua          # NEW — plenary-FREE smoke (the parse matrix; canned strings to M._feed).
tests/shell_feed_spec.lua           # NEW — plenary/busted spec (the same matrix as it(...) cases).
# (NO other file is created or modified.)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (AGENTS.md HARD RULE): run tests via `+"luafile tests/shell_feed_smoke.lua" +qa` (a FILE on disk).
-- NEVER pipe a heredoc into nvim's stdin (`nvim ... +"luafile /dev/stdin" +qa <<EOF` HANGS the session —
-- ~10 killed sessions in this repo). Wrap every nvim in `timeout` (a hung headless nvim blocks the turn).

-- GOTCHA #1 — find(needle, 1, true) 4th arg MUST be `true` (PLAIN byte scan). Without it, a `%`, `.`,
-- `+`, `(` inside the JSON payload (or sentinel bytes) is interpreted as a Lua pattern → corrupts the
-- sentinel search. jsonlreader GOTCHA 3. S5 uses plain find for BOTH START and END needles.

-- GOTCHA #2 — the payload MUST be ONE {items} object, NOT NDJSON. LIVE-VERIFIED: vim.json.decode(
-- '{"a":1}\n{"b":2}') THROWS ("T_OBJ_BEGIN at char 9"). The §17.6.x driver sketches emit per-item lines
-- (NDJSON) — that is a DOC INCONSISTENCY with §17.5.1's single-object wrapper. S5 decodes single-object;
-- the drivers (P2.M2.T4/P2.M3.T5) MUST emit {"items":[...],"prefix":"..."}. (research §3 / D1.)

-- GOTCHA #3 — empty/whitespace-only payload THROWS ("T_END"). This is CORRECT — §17.5.1 mandates the
-- daemon emit at least {"items":[]}, so empty is a protocol violation → counts as a parse_failure. Do
-- NOT special-case empty→success. (Trim is for determinism, not to rescue empty.) (research §3 / G4.)

-- GOTCHA #4 — state.pending_cb may be NIL (no request in flight; or S4's one-shot already fired). The
-- `if type(state.pending_cb)=="function"` guard is MANDATORY — a bare state.pending_cb(items, prefix)
-- THROWS on nil. S5 INVOKES pending_cb; S4 OWNS setting/niling it. (research §6 G5.)

-- GOTCHA #5 — parse_failures MUST be a state field (cleared by reset), NOT a module-local. A module-local
-- would leak across daemon restarts (M.reset wouldn't clear it) → a single failure post-restart immediately
-- re-trips the threshold. Contrast S4's req_timer (module-local — a timer isn't failure state, and S4 was
-- parallel with S3 editing state). S5 adds parse_failures=0 to the state literal + M.reset(). (D2.)

-- GOTCHA #6 — NEVER vim.schedule inside _feed. It runs in the read_start cb (libuv fast context) but does
-- NO vim.api.* (string + vim.json + state writes + the pending_cb call) → fast-safe WITHOUT schedule
-- (E5560). The menu hop is the CONSUMER's (P2.M2.T3) scheduling responsibility. Matches jsonlreader GOTCHA
-- 5 + the §17.5.2 skeleton's direct pending_cb(...) + S4's FORWARD CONTRACT. (D9.)

-- GOTCHA #7 — M.teardown() does NOT exist yet (S6). Forward-GUARD it (`if type(M.teardown)=="function"
-- then pcall(M.teardown) end`) AND re-assert state.failed=true AFTER (S6's teardown may call reset() and
-- clear failed; the daemon is DEAD → must stay failed so ensure() doesn't re-spawn a known-broken daemon
-- — §17.12 "no auto-respawn in v1"). NO notify.once (that's P2.M2.T3.S4). (D7.)

-- GOTCHA #8 — _feed has NO line/cursor (the read_start cb passes only the chunk). The item description's
-- "derive prefix client-side: last whitespace-delimited token of line[1..cursor]" is IMPOSSIBLE for _feed.
-- §17.5.1's response JSON INCLUDES prefix ("ch"). S5 reads decoded.prefix (string-guarded, default "").
-- The consumer complete_current (P2.M2.T3.S3, which HAS the buffer) may refine prefix. (D4.)

-- GOTCHA #9 — pcall decode AND type-guard the result. `if not dok or type(decoded) ~= "table"`. A
-- successful decode of a bare number "42" or string returns a non-table → must be a parse_failure (no
-- .items). And `ipairs` over decoded.items (NOT pairs) — items is an ORDERED array; ipairs preserves
-- order + stops at the first nil hole. A non-array .items → ipairs yields nothing → empty (graceful).
-- (research §6 G14/G15.)

-- GOTCHA #10 — (pi.config and pi.config.shell) or {} NOT pi.config.shell or {} (throws if config nil).
-- And the max_parse_failures read: type(n)~="number" or n<1 → default 5. Lazy require inside the helper.
-- (S2 GOTCHA #1/#2.)

-- GOTCHA #11 — TAB indentation throughout (match S2/S3/S4's shell.lua / completion.lua / bridge.lua).
-- Every new line uses tabs. (S2 GOTCHA #5.)

-- GOTCHA #12 — no lua linter/formatter (no luacheck/selene/stylua/.luarc). The ONLY "type" surface is the
-- luaemmy @class/@field annotations (lua-language-server, NOT runtime-enforced). Validation = the smoke + spec.

-- GOTCHA #13 — S5 REPLACES the _feed STUB BODY (keep signature M._feed(chunk) + the export). Do NOT change
-- the function name/params (S3's read_start wiring + tests call M._feed). Do NOT touch S3's ensure/_reset or
-- S4's request. The [Mode A] header's forward-contract note for M._feed (→ S5) becomes accurate post-S5.
-- (research §6 G-replace.)

-- GOTCHA #14 — TESTS ARM pending_cb via request() (S4). state is module-local — NO direct setter. Recipe:
-- fake-driver injection (S3/S4 Block H: package.loaded["pi-bridge.shell.fish"]=fake; pi.bridge=fake_bridge(
-- "/usr/bin/fish"); shell.ensure(cb) caches fake stdin + wires read_cb) → shell.request(line,cursor,after,cb)
-- arms state.pending_cb → M._feed(canned) delivers → assert cb(err, items, prefix). Parse-FAILURE tests need
-- NO request() (feed malformed directly; assert via the ensure→"daemon disabled" probe after N). (G16.)

-- GOTCHA #15 — Don't name a spec-local `pending` (shadows plenary.busted's skip fn). Use got/cb/captured.
-- (S2/S3 note.)

-- GOTCHA #16 — Don't leave rx_buf wedged across test cases. shell.reset() between cases clears rx_buf +
-- parse_failures + pending_cb. For delivery tests, drive request() to a terminal state (the _feed delivery
-- finalizes S4's pending_cb → cb fires → timer closed — no leak). For parse-failure tests, after N failures
-- state.failed=true is set; reset() clears it. (research §6.)

-- GOTCHA #17 — Don't search END without its trailing \n inconsistently with START. S5 searches BOTH with
-- their \n: START = "__PIRESP_START__\n", END = "__PIRESP_END__\n" (matches §17.5.1 exactly + ensures the
-- full close-sentinel arrived before slicing). The fish spike searched END without \n; S5 is stricter.
```

## Implementation Blueprint

### Design Decisions (READ FIRST)

**1. Single-object decode (NOT NDJSON), per §17.5.1 + the item description.** The item description:
"extract the substring … pcall(vim.json.decode, payload) … normalize items: for each item". This is ONE
decode of `{"items":[...], "prefix":"..."}`, then iterate `.items`. LIVE-VERIFIED NDJSON fails
(`vim.json.decode('{"a":1}\n{"b":2}')` throws). The §17.6.x driver sketches emit per-item lines — a doc
inconsistency; the WIRE format is §17.5.1's wrapper. S5 decodes single-object; drivers MUST conform. (D1.)

**2. `state.parse_failures` is a STATE field (cleared by `M.reset()`), NOT a module-local.** Unlike S4's
`req_timer` (module-local to avoid touching S2's literal — S4 was parallel with S3), `parse_failures` is
FAILURE STATE that MUST clear on daemon teardown/reset (else a single failure post-restart re-trips the
threshold). S2/S3 are DONE; S4 uses a module-local (doesn't touch state); S6 calls reset() (doesn't
rewrite it). So S5 ADDING `parse_failures = 0` to the `state` literal + `M.reset()` is SAFE (additive, no
parallel conflict) and CORRECT. This is the ONE edit to S2's surface. (D2.)

**3. Threshold = 5, read defensively as `cfg.max_parse_failures` (default 5).** §17.11 config defines NO
parse-failure key (grep-confirmed: zero matches repo-wide). The item description says "N (config or 5)".
So: `type(n)~="number" or n<1 → return 5`. Forward-compatible (a future config key works) without
requiring one today. The helper reads config FRESH (lazy require). Called ONLY on the failure path. (D3.)

**4. Prefix is READ from `decoded.prefix` (NOT derived client-side).** The item description says "derive
prefix client-side: last whitespace-delimited token of line[1..cursor]" — but `_feed(chunk)` has NO
`line`/`cursor` (the read_start cb passes only the chunk; §1a). §17.5.1's response JSON INCLUDES `prefix`
("ch"). So S5 reads `decoded.prefix` (string-guarded, default ""). The consumer `complete_current`
(P2.M2.T3.S3), which HAS the buffer+cursor, may refine/override prefix. S5's job is to PASS IT THROUGH.
This is the only viable resolution given the `_feed(chunk)` signature. (D4.)

**5. Normalize defensively; DROP malformed items (never throw).** `normalize_item(raw)`: non-table → nil;
`value` non-string/empty → nil; else `{value, label = raw.label or value, description = raw.description
or nil}`. A malformed item is SKIPPED, not fatal (a single bad item among 50 shouldn't fail the whole
response). Mirrors jsonlreader's "never throws" + completion.lua's defensive `result.items or {}`. (D5.)

**6. `parse_failures` resets to 0 on a SUCCESSFUL decode (§17.12 "consecutive").** A parse success
mid-stream clears the counter (a transient glitch shouldn't accumulate). Only N failures IN A ROW trip
the threshold. (D6.)

**7. On threshold: `state.failed=true` + forward-guarded `M.teardown()` + re-assert failed; NO
notify.once.** §17.12: "after N consecutive parse failures the daemon is killed and marked unhealthy".
S5 sets `failed=true` (the disable fact — `ensure()` short-circuits on it). It forward-GUARDS
`M.teardown()` (`if type(M.teardown)=="function" then pcall(M.teardown) end` — no-op until S6 lands) AND
re-asserts `state.failed=true` after (S6's teardown may call `reset()`, clearing `failed`; the daemon is
DEAD → must STAY failed so `ensure()` doesn't re-spawn a known-broken daemon). S5 does NOT call
`notify.once` (the §17.12 one-time degrade notice is P2.M2.T3.S4 — mirrors S3 `_reset`/S4 `request`).
FLAG for S6: teardown() must be safe to call from inside the stdout read_start callback. (D7.)

**8. EOF guard: `if chunk==nil then M._reset(); return end`.** S3's read_cb routes EOF to `_reset`
directly, so `_feed(nil)` shouldn't occur via the loop. But the item description says "if not chunk then
M._reset()" — so S5 includes the guard (defensive for a direct `_feed(nil)` test call; idempotent with
`_reset`). `chunk==""` → no-op return. (D8.)

**9. `_feed` runs in libuv FAST context; NO `vim.schedule`.** Matches jsonlreader GOTCHA 5 + the §17.5.2
skeleton's direct `pending_cb(items, prefix)` + S4's FORWARD CONTRACT. `_feed` does only string concat +
`find`/`sub` (plain) + `vim.json.decode` (pcall'd) + state writes + the `pending_cb` call → fast-safe
(E5560). The menu hop is the CONSUMER's (P2.M2.T3) scheduling responsibility. (D9.)

### Data models and structure

S5 does NOT introduce new runtime types — it consumes S2's `state` (adding one field) + S3's `M._feed`
signature + S4's `state.pending_cb` contract, and produces `AutocompleteItem[]` (completion.lua's type).
The only NEW contract surface is the **`state.pending_cb` invocation** (what S5 calls):

```lua
--- The gen-guarded response cb S4 sets; S5 INVOKES it (guarded). 2-arg: (items, prefix).
--- items  = AutocompleteItem[] (normalized: {value, label, description?}); {} on empty results.
--- prefix = string (read from decoded.prefix; default "" — _feed has no line/cursor to derive it).
--- Invoked from libuv FAST context (the read_start cb) → the consumer (P2.M2.T3.complete_current)
---   must vim.schedule any editor-touching work (E5560). S5 does NOT schedule (matches the skeleton).
---@type fun(items:pi-bridge.AutocompleteItem[], prefix:string)|nil  (set by S4 request; nil'd one-shot by S4)
```

S5 ADDS the `state.parse_failures` field (the §17.12 counter):
```lua
---@field parse_failures integer Consecutive decode-failure count (§17.12). Reset to 0 on success + by M.reset(). At threshold (default 5) → state.failed=true.
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ the contracts + the canonical references
  - READ lua/pi-bridge/shell.lua: confirm `local state = {...}` (add parse_failures=0); confirm M.reset()
    (add state.parse_failures=0); confirm S3's M._feed STUB body (`state.rx_buf = state.rx_buf .. (chunk
    or "")`) — the body to REPLACE; confirm S3's ensure read_start wiring (`if chunk then M._feed(chunk)
    else M._reset()` — confirms _feed receives only chunk); confirm the file ends with `return M`.
  - READ lua/pi-bridge/jsonlreader.lua (THE pattern: append + drain-loop + plain-find + pcall-decode +
    synchronous-deliver + never-throws). Internalize the 6 GOTCHAs (byte-safe, plain-find, blank-skip→
    empty-throws, synchronous, never-throws).
  - READ tests/shell_fish_spike.lua (the find(needle,1,true) + sub(s+len, e-1) sentinel-slice idiom +
    the read_start cb shape). NOTE: the spike parses word\tdesc LINES — S5 does NOT (single-object decode).
  - READ lua/pi-bridge/completion.lua L244-250 (AutocompleteItem) + L465-490 (the defensive
    result.items/result.prefix extract + pcall(on_results,...) deliver).
  - READ tests/shell_ensure_spec.lua + tests/jsonlreader_spec.lua (the test conventions + the
    fake-driver injection + the canned-feed pattern + the ensure→"daemon disabled" probe).
  - READ plan/002_d23d7473c16c/P2M1T2S4/PRP.md (the state.pending_cb contract — S5 invokes it).
  - RUN the /tmp/decode_check.lua probe (research §3) to re-confirm vim.json.decode whitespace tolerance
    + NDJSON-fails + empty-throws on YOUR Neovim (the facts S5 depends on).

Task 2: EDIT lua/pi-bridge/shell.lua — add parse_failures to state + reset (D2)
  - In the `local state = { ... }` literal, ADD `parse_failures = 0,` (anywhere among the fields; place
    it near `failed = false` for locality — both are failure state).
  - In M.reset(), ADD `state.parse_failures = 0` (near `state.failed = false`).
  - DO NOT: touch any other state field or function. DO NOT add a module-local parse_failures (GOTCHA #5).

Task 3: ADD the module-local helpers before M._feed (START/END/normalize_item/max_parse_failures)
  - PLACE: immediately BEFORE the `function M._feed(chunk)` definition (after S3's M._reset, before _feed;
    OR replace the S3 _feed block wholesale — see Task 4). Declare `local START = "__PIRESP_START__\n"` +
    `local END = "__PIRESP_END__\n"` (module-locals, used by the plain find).
  - WRITE normalize_item per Reference block N1 (defensive; non-table/non-string-value → nil; label =
    raw.label or value; description = raw.description or nil). JSDoc: "Normalize ONE raw daemon item
    {value, description?} → AutocompleteItem {value, label, description?}. Defensive: a non-table or a
    non-string/empty value → nil (DROP — a malformed item among many is skipped, not fatal; mirrors
    jsonlreader's never-throws + completion.lua's result.items or {}). label defaults to value (the §17.6
    drivers emit {value, description?} — no label); a future driver's label is honored if present."
  - WRITE max_parse_failures per Reference block N2 (lazy require; (pi.config and pi.config.shell) or {};
    type(n)~="number" or n<1 → 5; else math.floor(n)). JSDoc: "The §17.12 consecutive-parse-failure
    threshold. §17.11 config defines NO key (grep-confirmed) → default 5; reads cfg.max_parse_failures
    defensively (forward-compatible). Lazy require (async handshake + test mocks). Called ONLY on the
    failure path (cheap)."

Task 4: REPLACE the M._feed(chunk) STUB BODY with the full parser (keep signature + export)
  - FIND the S3 stub: `function M._feed(chunk)\n\tstate.rx_buf = state.rx_buf .. (chunk or "")\nend`
    (plus its JSDoc). REPLACE the BODY (keep `function M._feed(chunk)` + `end` + the export) with the
    full parser per Reference block F1 + Design Decisions §1-§9. Expand the JSDoc to document: the
    append→drain→decode→normalize→pending_cb flow; the sentinel framing (vs jsonlreader's \n-split —
    prompt-noise isolation); the single-object decode (NOT NDJSON — drivers MUST emit {items}); prefix
    read from decoded.prefix (NOT derived — _feed lacks line/cursor; D4); the §17.12 parse_failures
    counter + threshold (state.failed + forward-guarded teardown + re-assert; NO notify); the never-
    throws/pcall discipline; the fast-context safety (no vim.schedule; consumer schedules); the EOF
    nil-guard (→ M._reset); the forward contracts (S4 pending_cb one-shot via the `if type(...)` guard;
    S6 teardown; P2.M2.T3.S4 notify; P2.M2.T4/P2.M3.T5 drivers emit {items}).
  - DO NOT: change the function name/params (S3's read_start + tests call M._feed). Do NOT touch S3's
    ensure/_reset or S4's request. Do NOT vim.schedule (GOTCHA #6). Do NOT call notify.once (GOTCHA #7).
    Do NOT special-case empty→success (GOTCHA #3). Do NOT derive prefix from line/cursor (impossible; D4).

Task 5: CREATE tests/shell_feed_smoke.lua — plenary-FREE smoke (mirror shell_ensure_smoke + jsonlreader_smoke)
  - WRITE the header doc-comment with the run command: `timeout 60 nvim --headless --clean -u NORC -c 'set
    rtp+=.' +"luafile tests/shell_feed_smoke.lua" +qa`. Note the AGENTS.md HARD RULE.
  - BOOTSTRAP: `local me = debug.getinfo(1,"S").source:sub(2); local root = vim.fn.fnamemodify(me, ":h:h");
    vim.opt.runtimepath:append(root)`; `local pi = require("pi-bridge"); if pi.config==nil then pi.setup({}) end`;
    `local shell = require("pi-bridge.shell")`.
  - HELPERS: fake_bridge() + make_fake_driver() (copy from shell_ensure_smoke — captured.read_cb +
    fake_pipe). A `feed_and_capture(payload_str_or_feeds)` helper that: injects fake driver; sets
    pi.bridge; shell.ensure(cb) (caches fake stdin + wires read_cb); shell.request("git ch",6,"",
    function(err,items,prefix) captured={err=err,items=items,prefix=prefix} end) (ARMS pending_cb via S4);
    then calls shell._feed(payload) (or feeds a TABLE of chunks) → returns captured. A
    `feed_malformed(n)` helper that calls shell._feed(malformed) n times (no request needed) + returns
    state via the ensure probe. restore() between cases (save/restore SHELL/bridge/descriptor/config/
    package.loaded[fish] + shell.reset()).
  - CASES (each a `check`; see Validation Loop §Level-2-smoke for the full matrix): happy-path-single
    (items parsed + prefix "ch" + label==value + description), multi-pair-one-chunk (drain loop),
    split-across-chunks (1st buffers, 2nd delivers), noise-outside-discarded (prompt before/after), empty-
    items-array (pending_cb({}, "") — NOT a parse failure), malformed-increments-parse_failures (via
    ensure probe after 1 — still NOT disabled), threshold-5-disables (5 malformed → ensure "daemon
    disabled"; teardown forward-guard no-op), threshold-config-honored (cfg.max_parse_failures=3 →
    disabled after 3), consecutive-reset-on-success (4 fail + 1 success + 4 fail → NOT yet disabled —
    parse_failures reset), prefix-passthrough (decoded.prefix honored; missing → ""), label-from-value
    (description-less item: label==value), never-throws (_feed(nil)/("")/("garbage no sentinels")/
    ("__PIRESP_START__\n42\n__PIRESP_END__\n" bare-number)/("__PIRESP_START__\n{\"items\":\"notarray\"}
    \n__PIRESP_END__\n" non-array items)), pending_cb-nil-safe (no request armed → _feed parses silently,
    no throw), EOF (_feed(nil) → M._reset → ensure "daemon disabled"), rx_buf-drained (after a pair,
    rx_buf is "" — observable via a 2nd valid pair parsing cleanly).
  - FOOTER: `if fails>0 then io.stderr:write(fails.." check(s) failed\n"); vim.cmd("cquit 1") end;
    io.stdout:write("SMOKE_PASS\n")`.
  - DO NOT: spawn a real subprocess. Do NOT leave rx_buf/parse_failures/pending_cb armed across cases
    (shell.reset() + drive request() to terminal). Do NOT test request/ensure/teardown internals (S4/S3/S6).

Task 6: CREATE tests/shell_feed_spec.lua — plenary/busted spec (mirror shell_ensure_spec + jsonlreader_spec)
  - WRITE the header doc-comment with the run command (minimal_init + plenary.busted.run).
  - BOOTSTRAP + before_each (save orig SHELL/bridge/descriptor/config/package.loaded[fish]; shell.reset())
    + after_each (restore all + shell.reset()).
  - CASES: the same matrix as `it(...)` with assert.are.equals/same/is_nil/is_truthy/has_no.errors. Group
    under `describe("pi-bridge.shell _feed (P2.M1.T2.S5)", ...)`.
  - DO NOT: spawn subprocess. Do NOT name a spec-local `pending` (GOTCHA #15). Do NOT test request/ensure/
    teardown (S4/S3/S6).
```

### Reference implementation

```lua
-- === Block N1: normalize_item — ADD as a module-local before M._feed (S5 block) ===
-- (Tabs throughout. Defensive: a malformed item is DROPPED (nil), never throws.)

--- Normalize ONE raw daemon item `{ value, description? }` (§17.6 driver wire shape) into an
--- `AutocompleteItem { value, label, description? }` (completion.lua L244-250). Defensive: a non-table
--- item, or a non-string/empty `value`, returns `nil` (the item is DROPPED — a single malformed item
--- among many must NOT fail the whole response; mirrors jsonlreader's never-throws + completion.lua's
--- `result.items or {}`). `label` defaults to `value` (the §17.6 drivers emit no label); a future
--- driver's explicit label is honored if it is a non-empty string. `description` is carried through iff
--- present + non-empty, else omitted (nil). NEVER throws (pure table reads).
---@param raw table? A raw daemon item `{ value:string, description?:string, label?:string }`.
---@return table|nil item The normalized AutocompleteItem, or nil to drop.
local function normalize_item(raw)
	if type(raw) ~= "table" then return nil end
	local value = raw.value
	if type(value) ~= "string" or value == "" then return nil end
	return {
		value = value,
		label = (type(raw.label) == "string" and raw.label ~= "" and raw.label) or value,
		description = (type(raw.description) == "string" and raw.description ~= "") and raw.description or nil,
	}
end
```

```lua
-- === Block N2: max_parse_failures — ADD as a module-local before M._feed (S5 block) ===
--- The §17.12 consecutive-parse-failure threshold. PRD §17.11 config defines NO parse-failure key
--- (grep-confirmed: zero matches repo-wide) → default `5`. Reads `config.shell.max_parse_failures`
--- DEFENSIVELY (forward-compatible — a future config key works without a code change): a non-number or
--- `<1` falls back to 5. Lazy `require("pi-bridge")` (async handshake + test mocks swap fakes after
--- require — mirrors S2/S4). Called ONLY on the decode-failure path (cheap). NEVER throws.
---@return integer n The threshold (>=1; default 5).
local function max_parse_failures()
	local pi = require("pi-bridge")
	local cfg = (pi.config and pi.config.shell) or {}
	local n = cfg.max_parse_failures
	if type(n) ~= "number" or n < 1 then return 5 end
	return math.floor(n)
end

-- The sentinel delimiters (§17.5.1). Module-locals so the plain `find` reuses them without re-allocating.
-- The trailing `\n` is part of the delimiter (§17.5.1: `__PIRESP_START__\n` / `__PIRESP_END__\n`) —
-- searching WITH the `\n` ensures the FULL sentinel arrived before slicing (a half-arrived
-- `__PIRESP_END` does not falsely match; we wait for the close newline).
local START = "__PIRESP_START__\n"
local END   = "__PIRESP_END__\n"
```

```lua
-- === Block F1: M._feed(chunk) — REPLACE the S3 stub body (keep signature + export) ===
-- (Tabs throughout. Appends the chunk, drains every __PIRESP_START__\n..\__PIRESP_END__\n pair,
--  pcall-decodes the single {items,prefix} object, normalizes to AutocompleteItem[], invokes the
--  gen-guarded state.pending_cb (S4). §17.12 parse-failure counter + threshold. NEVER throws.)

--- The §17.5.1/§17.5.2 response PARSE layer of the completion daemon. Appends a stdout `chunk` to
--- `state.rx_buf`, then DRAINS every complete `__PIRESP_START__\n`…`__PIRESP_END__\n` pair present:
--- trims the payload between them, `pcall(vim.json.decode)`s it as ONE `{ items, prefix }` object
--- (§17.5.1 — NOT NDJSON; the §17.6 driver sketches' per-line format is a doc inconsistency the drivers
--- must reconcile), normalizes each raw `{ value, description? }` item into an `AutocompleteItem
--- { value, label, description? }` (dropping malformed items), and invokes the gen-guarded
--- `state.pending_cb(items, prefix)` (set by S4 `request`) — guarded by `if type(...)=="function"` so a
--- late/duplicate delivery after S4 nil'd the slot is a no-op. Anything OUTSIDE the sentinels (prompts,
--- async segments, stray output) is buffered-then-discarded. Leftover (a partial pair) stays in `rx_buf`.
---
--- §17.12 parse-failure handling: a decode failure (or a non-table decode) increments
--- `state.parse_failures`; at the threshold (`config.shell.max_parse_failures`, default 5) the daemon is
--- marked unhealthy (`state.failed = true` — `ensure()` then short-circuits, no new requests) +
--- `M.teardown()` is forward-GUARDED (no-op until S6 lands) + `failed` re-asserted (S6's teardown may
--- `reset()`; the daemon is DEAD → must stay failed — §17.12 "no auto-respawn in v1"). The one-time
--- degrade NOTIFY is P2.M2.T3.S4's job (S5 sets only the FACT — mirrors S3 `_reset` / S4 `request`). A
--- SUCCESSFUL decode resets `parse_failures` to 0 (§17.12 "consecutive").
---
--- `prefix` is READ from `decoded.prefix` (§17.5.1; default "") — NOT derived from `line[1..cursor]`,
--- because `_feed` receives ONLY the chunk (the `read_start` cb passes no line/cursor; see S3's wiring).
--- The consumer `complete_current` (P2.M2.T3.S3), which has the buffer, may refine prefix.
---
--- Runs in the libuv `read_start` callback (FAST context) but does NO `vim.api.*` (string + `vim.json`
--- + state writes + the `pending_cb` call only) → fast-safe WITHOUT `vim.schedule` (E5560); the menu hop
--- is the CONSUMER's (P2.M2.T3) scheduling responsibility. NEVER throws (`pcall` decode; type-guarded
--- `decoded`/`.items`/`.prefix`/`pending_cb`; `ipairs` over `.items`; nil/"" `chunk` guarded).
---
---@param chunk string? A stdout chunk from the daemon pipe (nil ⇒ EOF ⇒ `M._reset`; "" ⇒ no-op).
function M._feed(chunk)
	-- (0) EOF guard (D8). S3's read_start routes EOF to _reset directly, so _feed(nil) shouldn't occur
	--     via the loop — but a direct _feed(nil) call (e.g. a test) also marks the daemon unhealthy
	--     (idempotent with _reset). Empty chunk → no-op (avoid a useless concat + drain loop).
	if chunk == nil then M._reset(); return end
	if chunk == "" then return end
	-- (1) APPEND (byte-safe — Lua strings are byte buffers; split-multibyte chars reassemble on the
	--     next chunk, NO UTF-8 streaming decoder needed; mirrors jsonlreader GOTCHA 1).
	state.rx_buf = state.rx_buf .. chunk
	-- (2) DRAIN: while a complete __PIRESP_START__\n .. __PIRESP_END__\n pair is present, slice + decode
	--     + normalize + deliver. A single chunk may carry MANY pairs (drain loop) or a PARTIAL pair
	--     (left buffered). Mirrors jsonlreader.feed's drain loop.
	while true do
		-- plain byte scan (4th `true` arg — jsonlreader GOTCHA 3: pattern matching OFF, so literal
		-- '%'/'+.'/etc in the JSON payload never corrupts the sentinel search).
		local s = state.rx_buf:find(START, 1, true)
		if not s then break end                         -- no START → noise-only; wait for more
		local ps = s + #START                           -- payload starts AFTER "__PIRESP_START__\n"
		local e = state.rx_buf:find(END, ps, true)      -- END\n AFTER the START
		if not e then break end                         -- START but no END yet → wait for more
		-- (3) EXTRACT the payload (bytes between START\n and END\n) + trim surrounding whitespace.
		--     vim.json.decode tolerates whitespace (LIVE-VERIFIED) but trim is deterministic + makes
		--     the empty-payload edge explicit (empty → "" → decode throws → parse_failure; §17.5.1
		--     mandates {"items":[]} so empty is a protocol violation — do NOT special-case it to success).
		local payload = state.rx_buf:sub(ps, e - 1):gsub("^%s+", ""):gsub("%s+$", "")
		-- (4) ADVANCE rx_buf PAST this response (keep the remainder for the next iteration / chunk;
		--     trailing noise after END\n stays buffered, inert until the next START or chunk).
		state.rx_buf = state.rx_buf:sub(e + #END)
		-- (5) DECODE (pcall'd — never throws; mirrors jsonlreader GOTCHA 6). The payload MUST be a
		--     single {items,prefix} object (§17.5.1; NDJSON throws — D1). A bare number/string decodes
		--     to a non-table → treated as a parse failure (no .items).
		local dok, decoded = pcall(vim.json.decode, payload)
		if not dok or type(decoded) ~= "table" then
			-- (6a) PARSE FAILURE: increment the §17.12 consecutive counter. At threshold → disable +
			--     forward-guard teardown (S6) + re-assert failed. NO notify (P2.M2.T3.S4).
			state.parse_failures = (state.parse_failures or 0) + 1
			if state.parse_failures >= max_parse_failures() then
				state.failed = true
				-- Forward-guard: kill the daemon IF S6's teardown() has landed (no-op today). Re-assert
				-- failed AFTER (S6's teardown may reset(); the daemon is dead → must STAY failed so
				-- ensure() short-circuits instead of re-spawning a known-broken daemon — §17.12).
				pcall(function() if type(M.teardown) == "function" then M.teardown() end end)
				state.failed = true
			end
		else
			-- (6b) SUCCESS: reset the consecutive counter (§17.12 "consecutive"). Extract items +
			--     prefix DEFENSIVELY (mirrors completion.lua do_refresh L465-470: type-guarded, default
			--     {} / ""). Normalize each item → AutocompleteItem[] (drop malformed — D5).
			state.parse_failures = 0
			local raw_items = (type(decoded.items) == "table") and decoded.items or {}
			local prefix     = (type(decoded.prefix) == "string") and decoded.prefix or ""
			local items = {}
			for _, raw in ipairs(raw_items) do           -- ipairs: ordered + nil-hole-safe; non-array → {}
				local norm = normalize_item(raw)
				if norm then items[#items + 1] = norm end
			end
			-- (7) DELIVER via the gen-guarded ONE-SHOT pending_cb (set by S4 request). The
			--     `if type(...)=="function"` guard is MANDATORY (pending_cb may be nil — no request in
			--     flight, or S4 already fired+nil'd it). S5 INVOKES it; S4 OWNS setting/niling it. Do
			--     NOT vim.schedule (fast context; the consumer P2.M2.T3 schedules the menu hop — D9).
			if type(state.pending_cb) == "function" then
				state.pending_cb(items, prefix)
			end
		end
	end
end
```

```lua
-- === Block H: the canned-feed test helpers (tests/shell_feed_smoke.lua + _spec.lua) ===
-- Two recipes: (1) DELIVERY tests arm pending_cb via request() (S4) + feed canned → assert cb;
--              (2) PARSE-FAILURE tests feed malformed directly (no request) → assert via the ensure probe.
-- state is module-local → tests CANNOT set pending_cb directly; they ARM it via request() with a
-- fake-driver-backed ensure (S3/S4 Block H recipe).

local function fake_bridge(shell_path)
	return { get_shell_info = function() return { shell = shell_path } end, server_info = {} }
end

local function make_fake_driver()
	local captured = { read_cb = nil }
	local function fake_pipe()
		return {
			read_start = function(_, cb) captured.read_cb = cb end, -- ensure wires this
			write      = function(_, data, wcb) if wcb then wcb(nil) end end, -- request() writes the frame; cb(nil)=OK
			close      = function() end, read_stop = function() end, is_closing = function() return false end,
		}
	end
	return {
		captured = captured,
		start = function(opts, cb) cb(nil, { is_closing = function() return false end }, fake_pipe(), fake_pipe()) end,
	}
end

-- (1) DELIVERY: arm pending_cb via request(), feed a canned response, capture the cb.
--     feeds: a string OR a TABLE of chunk strings (split-across-chunks case).
local function feed_and_capture(shell, pi, feeds)
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	local captured = { err = "UNSET" }
	shell.ensure(function() end)                       -- caches fake stdin/stdout + wires read_cb
	shell.request("git ch", 6, "", function(err, items, prefix)
		captured = { err = err, items = items, prefix = prefix }
	end)                                               -- ARMS state.pending_cb (S4); writes the frame
	-- feed the canned response (a string → one _feed; a table → sequential _feeds)
	local list = (type(feeds) == "table") and feeds or { feeds }
	for _, chunk in ipairs(list) do shell._feed(chunk) end
	return captured, fake
end

-- (2) PARSE-FAILURE: feed malformed N times (no request needed), then probe state.failed via ensure.
local function feed_malformed_and_probe(shell, pi, payload, n)
	shell.reset()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	for _ = 1, n do shell._feed(payload) end           -- parse_failures += 1 each (pending_cb nil → no delivery)
	local got = "UNSET"
	shell.ensure(function(err) got = err end)          -- if failed → "daemon disabled"; else nil (spawns fake)
	return got
end
```

### Integration Points

```yaml
MODULE STATE (lua/pi-bridge/shell.lua — EDIT, additive):
  - parse_failures (state field)   → NEW (the §17.12 counter; 0 on success/reset; ++ per decode failure).
  - M.reset()                      → EDIT: add `state.parse_failures = 0` (clear on teardown/restart).
  - START / END (module-locals)    → NEW sentinel constants (used by the plain find).
  - normalize_item (local fn)      → NEW defensive item normalizer.
  - max_parse_failures (local fn)  → NEW threshold reader (default 5; cfg.max_parse_failures if set).
  - M._feed(chunk)                 → REPLACE the STUB BODY with the full parser (signature unchanged).
  - state SET by _feed: rx_buf (append/drain), parse_failures (++/reset), failed (true on threshold).
  - state READ by _feed: rx_buf, pending_cb (invoked, never written).

NO EDITS to any existing file other than shell.lua:
  - lua/pi-bridge/* other than shell.lua are READ-ONLY (jsonlreader = the pattern twin; completion.lua =
    AutocompleteItem + normalize precedent; bridge.lua = S4's reference; init.lua = config; notify.lua =
    header-only ref).
  - S2's functions other than the `state` literal + `M.reset()` (additive) are UNTOUCHED. S3's ensure/
    _reset are UNTOUCHED. S4's request/cancel_req_timer/req_timer are UNTOUCHED (if landed).
  - extension/*, doc/*, ftplugin/*, plugin/* — all UNTOUCHED.
  - NO shell/*.lua driver created (P2.M2.T4 / P2.M3.T5). NO new config key (max_parse_failures is read
    defensively but NOT added to setup() defaults — P2.M3.T6.S1 owns the config block).

FORWARD CONTRACTS (do NOT implement in S5; just invoke/guard + document them):
  - S4's state.pending_cb → S5 invokes `if type(state.pending_cb)=="function" then
    state.pending_cb(items, prefix) end`. The `if type(...)` guard is what makes a late/duplicate
    delivery a no-op (S4 nil's the slot first — one-shot).
  - S6's M.teardown() → S5 forward-guards it on the parse-failure threshold (`if type(M.teardown)==
    "function" then pcall(M.teardown) end`) + re-asserts state.failed=true after. S6 must be safe to call
    from inside the read_start callback.
  - P2.M2.T3.S4 → the §17.12 one-time degrade notify.once (S5 sets failed; the notice is P2.M2.T3.S4).
  - P2.M2.T3.S2/S3 → complete_current(buf, cb) receives (err, items, prefix) from S5→S4's cb; it may
    RE-DERIVE prefix from the buffer (it has line/cursor, which _feed lacks — D4) + must vim.schedule the
    menu hop (E5560; pending_cb runs in fast context — D9).
  - P2.M2.T4 / P2.M3.T5 drivers → MUST emit the §17.5.1 single-object format
    `__PIRESP_START__\n{"items":[...],"prefix":"..."}\n__PIRESP_END__\n`, NOT the §17.6.x per-item NDJSON
    sketch (NDJSON fails to decode — GOTCHA #2).
  - P2.M3.T6.S2 (:checkhealth) → may read state.parse_failures + state.failed to report the disable.
```

## Validation Loop

> Run from the repo root (`/home/dustin/projects/pi-nvim-bridge`). ALWAYS wrap nvim in `timeout`
> (AGENTS.md HARD RULE). No lua linter exists (GOTCHA #12) — the smoke + spec ARE the gate. S5 spawns NO
> real subprocess (canned strings to M._feed + the S3 fake-driver read_cb) → no live-shell gate.

### Level 1: Syntax (the file parses; the symbols exist)

```bash
# 1a. Confirm the _feed body was REPLACED (no longer the stub) + the helpers + state field exist:
grep -n "function M._feed\|local function normalize_item\|local function max_parse_failures\|local START\|local END\b\|parse_failures" lua/pi-bridge/shell.lua
# expect: M._feed present (body changed); normalize_item + max_parse_failures + START + END NEW;
#   parse_failures appears in BOTH the state literal AND M.reset() AND _feed.
grep -n 'state.rx_buf = state.rx_buf .. (chunk or "")' lua/pi-bridge/shell.lua   # expect: 0 (the stub is GONE)
grep -n "^return M" lua/pi-bridge/shell.lua              # expect 1 (EOF preserved)
grep -n "vim.uv.spawn\|notify.once\|vim.schedule(" lua/pi-bridge/shell.lua | grep -v "^.*--"   # expect: 0 CALLS in S5's code
# (vim.json.decode + string.find/sub + state writes ARE expected + present — those are S5's surface.)
# 1b. Byte-compile the module (catches a syntax error fast; no subprocess):
timeout 30 nvim --headless --clean -u NORC \
  -c 'lua assert(loadfile("lua/pi-bridge/shell.lua"))' -c 'qa' && echo "PARSE_OK exit=$?"
# Expected: PARSE_OK exit=0. If loadfile returns nil + err, READ it: likely a tab/space mix, an
#   unbalanced `end`/`while`/`function`, or a typo. (The `while true do ... break ... end` must have
#   exactly one `end`; the `if/elseif/else` ladders balanced; normalize_item/max_parse_failures declared
#   BEFORE _feed references them.)
# 1c. RE-RUN the decode probe to re-confirm the facts S5 depends on (whitespace tolerance, NDJSON fails):
cat > /tmp/decode_check.lua <<'LUA'
local function probe(label, fn) local ok,val=pcall(fn); print(string.format("%-30s ok=%s val=%s",label,tostring(ok),tostring(val))) end
probe("ws-tolerant", function() return vim.json.decode('\n{"a":1}\n').a end)
probe("ndjson-fails", function() return vim.json.decode('{"a":1}\n{"b":2}') end)
probe("empty-throws", function() return vim.json.decode('') end)
LUA
timeout 30 nvim --headless --clean -u NORC +"luafile /tmp/decode_check.lua" +qa
# Expected: ws-tolerant ok=true val=1 ; ndjson-fails ok=false ; empty-throws ok=false. (Matches research §3.)
```

### Level 2-smoke: the plenary-FREE smoke (the full parse matrix)

```bash
# 2a. THE gate — run the smoke (prints SMOKE_PASS + exit 0):
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_feed_smoke.lua" +qa
echo "exit=$?"
# Expected: SMOKE_PASS, exit=0.
# The smoke MUST cover (mirror these `check(...)` cases — see Task 5 + research §5):
#   HAPPY-PATH-SINGLE:   feed_and_capture("__PIRESP_START__\n"..'{"items":[{"value":"checkout","description":"Checkout a branch"}],"prefix":"ch"}'.."\n__PIRESP_END__\n")
#                        → captured.err==nil; captured.items[1].value=="checkout"; .label=="checkout";
#                        .description=="Checkout a branch"; captured.prefix=="ch"; (rx_buf drained "").
#   MULTI-PAIR-ONE-CHUNK: feed TWO complete pairs in ONE _feed → pending_cb invoked for the FIRST (the
#                        2nd is a no-op IF S4 nil'd the slot — assert the 1st delivered; the 2nd doesn't
#                        throw — the `if type(pending_cb)` guard). (Loop drains both.)
#   SPLIT-ACROSS-CHUNKS: feed_and_capture({ "__PIRESP_START__\n"..'{"items":[{"value":"x"}],"prefix":""}',
#                        '...\n'.."\n__PIRESP_END__\n" }) → 1st _feed buffers (no delivery); 2nd delivers.
#   NOISE-OUTSIDE:       feed_and_capture("prompt$ __PIRESP_START__\n"..'{"items":[]}'.."\n__PIRESP_END__\n trail$ ")
#                        → captured.items=={} (empty, NOT a parse failure); prefix==""; no parse_failure.
#   EMPTY-ITEMS-ARRAY:   '{"items":[]}' between sentinels → pending_cb({}, "") (NOT a parse_failure).
#   MALFORMED-INCREMENTS: feed "__PIRESP_START__\n{bad json}\n__PIRESP_END__\n" → after 1, ensure still OK
#                        (failed still false); parse_failures==1 (probe via ensure NOT "daemon disabled").
#   THRESHOLD-5-DISABLES: feed the malformed payload 5× → ensure → "daemon disabled" (failed=true).
#                        (teardown forward-guard is a no-op today — no throw.)
#   THRESHOLD-CONFIG:    cfg.shell.max_parse_failures=3 → after 3 malformed, ensure → "daemon disabled".
#   CONSECUTIVE-RESET:   4 malformed + 1 VALID (resets parse_failures to 0) + 4 malformed → NOT yet
#                        disabled (ensure OK) — proves the success resets the counter.
#   PREFIX-PASSTHROUGH:  decoded.prefix=="ch" honored; a payload without prefix → prefix=="".
#   LABEL-FROM-VALUE:    item {value="x"} (no label) → label=="x"; item {value="y",label="Y"} → label=="Y".
#   NEVER-THROWS:        _feed(nil) → M._reset (no throw); _feed("") → no-op; _feed("garbage no sentinels")
#                        → buffers, no throw; _feed("__PIRESP_START__\n42\n__PIRESP_END__\n") (bare number)
#                        → parse_failure (no throw); _feed("__PIRESP_START__\n{\"items\":\"x\"}\n__PIRESP_END__\n")
#                        (non-array items) → items=={} (no throw).
#   PENDING-CB-NIL-SAFE: no request armed → _feed(valid pair) → parses silently (no throw on nil cb).
#   EOF:                 _feed(nil) → M._reset → ensure → "daemon disabled".
#   RX_BUF-DRAINED:      after one valid pair, a SECOND valid pair in a new _feed parses cleanly (proves
#                        rx_buf was advanced past the first — not wedged concatenating).
# If a check FAILS: re-read the FAIL line; the most common causes are (i) a non-plain find (GOTCHA #1 —
#   missing the 4th `true`), (ii) NDJSON-shaped test payload (GOTCHA #2 — use a single {items} object),
#   (iii) a bare state.pending_cb(...) without the `if type(...)` guard (GOTCHA #4), (iv) parse_failures
#   as a module-local instead of state (GOTCHA #5 — reset won't clear it), (v) not type-guarding decoded
#   (GOTCHA #9 — a bare-number decode crashes the .items read), (vi) searching END without its \n vs
#   START with its \n (GOTCHA #17 — be consistent: both WITH \n).
```

### Level 2-spec: the plenary/busted spec (the same matrix, asserted)

```bash
# 2b. THE spec gate — run shell_feed_spec (expect all pass, 0 fail, 0 error):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_feed_spec.lua")' 2>&1 | tail -8
echo "exit=${PIPESTATUS[0]}"
# Expected: "Success: <N>", "Failed : 0", "Errors : 0", exit 0. (~14-18 cases.)
# If a case fails: re-read its body vs the smoke case it mirrors — the assertion shapes must match
#   (assert.are.same on captured.items; assert.are.equals on captured.prefix; assert.is_nil on err;
#   assert.has_no.errors on the never-throws cases). Verify before_each restores SHELL/bridge/descriptor/
#   config/package.loaded[fish] AND calls shell.reset() (so rx_buf/parse_failures/pending_cb don't leak).
```

### Level 3: Regression (the additive edit + state/reset additions break nothing)

```bash
# 3a. S2 + S3 + S4's own tests stay green (S5 edits shell.lua's _feed + state/reset; siblings must pass):
for spec in shell_spec shell_ensure_spec shell_request_spec; do
  [ -f tests/$spec.lua ] || continue
  timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require(\"plenary.busted\").run(\"tests/$spec.lua\")" 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "($spec)"
done
# Expected: green (S5 is additive — S2/S3/S4's functions are untouched; only _feed body + state/reset
#   grew). If S4 hasn't landed yet, shell_request_spec is absent — skip. NOTE: S3's shell_ensure_spec has
#   a case "_feed is append-only + never throws" that calls _feed(nil)/("")/("abc") — S5's nil-guard now
#   calls M._reset on nil, which sets failed=true; that case asserts only `assert.has_no.errors` (still
#   passes) but if it ALSO asserts rx_buf growth, it may need the S5 update — VERIFY (see Note below).
# 3b. The suites that read the files S5 is adjacent to stay green:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(completion_spec)"
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/jsonlreader_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(jsonlreader_spec)"
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_handshake_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(bridge_handshake_spec)"
timeout 60 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/init_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(init_spec)"
# Expected: completion_spec green; jsonlreader_spec green; bridge_handshake_spec 15/0/0; init_spec 14/0/0.
# (S5 edits shell.lua + adds 2 tests; it touches NOTHING else — these can only fail if you accidentally
#   modified a sibling or S2/S3's functions inside shell.lua.)
# 3c. Isolation — confirm the 3 expected files changed (shell.lua EDITED + 2 tests NEW; no sibling touched):
git status --porcelain
# Expected: ` M lua/pi-bridge/shell.lua`, `?? tests/shell_feed_smoke.lua`, `?? tests/shell_feed_spec.lua`.

# NOTE on S3's shell_ensure_spec "_feed is append-only" case: S3 shipped _feed as a stub that appends.
# S5 REPLACES the body. S3's case asserts `assert.has_no.errors(function() shell._feed(nil); shell._feed("");
# shell._feed("abc") end)`. S5's nil-guard now calls M._reset() (sets failed=true) on _feed(nil) — still
# no-throw, so `has_no.errors` PASSES. BUT if S3's case ALSO peeks rx_buf growth (it doesn't — it only
# asserts no-throw + the EOF→_reset probe separately), it stays green. If a SIBLING spec breaks, it is
# because S5 changed _feed's observable behavior — update THAT spec's assertion to match S5 (the spec
# documents the NEW behavior; S5 OWNS _feed now). Do NOT weaken S5 to keep a stale S3 assertion.
```

### Level 4: (none — no MCP/Docker/Playwright/web/real-subprocess surface; S5 is pure lua + canned strings)

## Final Validation Checklist

### Technical Validation

- [ ] Level 1a: `M._feed` body REPLACED (stub `state.rx_buf = state.rx_buf .. (chunk or "")` GONE);
      `normalize_item` + `max_parse_failures` + `START` + `END` module-locals present; `parse_failures`
      in the `state` literal AND `M.reset()` AND `_feed`; `return M` at EOF; ZERO `vim.uv.spawn`/
      `notify.once`/`vim.schedule(` CALLS in S5's code (vim.json.decode + find/sub + state writes present).
- [ ] Level 1b: `lua/pi-bridge/shell.lua` byte-compiles (`PARSE_OK exit=0`).
- [ ] Level 1c: decode probe confirms ws-tolerant / ndjson-fails / empty-throws.
- [ ] Level 2a: `tests/shell_feed_smoke.lua` prints `SMOKE_PASS` + `exit=0` (the ~15-case parse matrix).
- [ ] Level 2b: `tests/shell_feed_spec.lua` green (all cases pass, 0 fail, 0 error).
- [ ] Level 3a: `shell_spec` (S2) + `shell_ensure_spec` (S3) + `shell_request_spec` (S4, if landed) green.
- [ ] Level 3b: `completion_spec`, `jsonlreader_spec`, `bridge_handshake_spec` (15/0/0), `init_spec` (14/0/0) green.
- [ ] Level 3c: `git status --porcelain` shows shell.lua (edited) + the 2 new tests ONLY.

### Feature Validation

- [ ] A complete `__PIRESP_START__\n{items,prefix}\n__PIRESP_END__\n` chunk → `pending_cb(normalized,
      prefix)` invoked (pending_cb armed via request/S4); rx_buf drained to ""; parse_failures==0.
- [ ] Multi-pair one-chunk drains BOTH (loop); split-across-chunks reassembles; noise-outside discarded.
- [ ] Malformed JSON → parse_failures++; pending_cb NOT called. N (default 5) CONSECUTIVE → failed=true →
      ensure "daemon disabled". A mid-stream success resets parse_failures to 0.
- [ ] `config.shell.max_parse_failures` honored; nil config → 5 (no throw).
- [ ] Empty `{"items":[]}` → pending_cb({}, "") (NOT a parse failure).
- [ ] prefix read from decoded.prefix (string-guarded, default ""); label = item.label or value.
- [ ] `_feed` NEVER throws (nil/""/garbage/bare-number/non-array-items/nil-pending_cb).
- [ ] `_feed(nil)` → M._reset (EOF); `_feed("")` → no-op.

### Code Quality Validation

- [ ] TAB indentation throughout (match S2/S3/S4's shell.lua).
- [ ] `find(START/END, _, true)` — 4th arg `true` (plain byte scan) on BOTH sentinels (GOTCHA #1).
- [ ] The payload is decoded as ONE `{items}` object (NOT NDJSON) (GOTCHA #2).
- [ ] `state.pending_cb` invoked ONLY behind `if type(...)=="function"` (GOTCHA #4).
- [ ] `parse_failures` is a `state` field cleared by `M.reset()` (NOT a module-local) (GOTCHA #5).
- [ ] NO `vim.schedule` in `_feed` (GOTCHA #6); NO `notify.once` (GOTCHA #7); NO `vim.uv.spawn`.
- [ ] `decode` is `pcall`'d AND the result is `type(...) ~= "table"`-guarded; `.items` iterated via
      `ipairs` (GOTCHA #9).
- [ ] `M.teardown()` is forward-guarded + `failed` re-asserted after (GOTCHA #7).
- [ ] S2's functions (other than the additive `state` field + `M.reset()` line) + S3's `ensure`/`_reset`
      + S4's `request`/`cancel_req_timer`/`req_timer` are UNTOUCHED.
- [ ] No edit to `extension/*`, `doc/*`, `ftplugin/*`, `plugin/*`, `completion.lua`, `bridge.lua`,
      `init.lua`, `notify.lua`, `jsonlreader.lua`, or `README.md`. No `shell/*.lua` created. No subprocess.

### Documentation & Deployment

- [ ] JSDoc blocks on `_feed` + `normalize_item` + `max_parse_failures` document: the append→drain→decode
      →normalize→pending_cb flow; the sentinel framing (vs jsonlreader's \n-split — prompt-noise
      isolation); the single-object decode (NOT NDJSON — drivers MUST emit {items}); prefix read from
      decoded.prefix (NOT derived — _feed lacks line/cursor; D4); the §17.12 parse_failures counter +
      threshold (failed + forward-guarded teardown + re-assert; NO notify); the never-throws/pcall
      discipline; the fast-context safety (no vim.schedule; consumer schedules); and the forward contracts
      (S4 pending_cb one-shot via the `if type(...)` guard; S6 teardown; P2.M2.T3.S4 notify;
      P2.M2.T4/P2.M3.T5 drivers emit {items}).
- [ ] No README / `doc/pi-bridge.txt` / `doc/pi-bridge-shell.txt` / `extension/README.md` change (Mode-B
      task P2.M4.T7 + vimdoc task P2.M3.T6.S4 own those; S5 is pre-doc).
- [ ] Inline comments cite PRD §17.5.1 / §17.5.2 / §17.12 + jsonlreader + the fish spike + completion.lua
      so a future reader knows WHY each piece exists.

---

## Anti-Patterns to Avoid

- ❌ **Don't `find(needle)` without the 4th `true` arg.** jsonlreader GOTCHA 3: without `plain=true`, a
  `%`/`.`/`+` inside the JSON payload is interpreted as a Lua pattern → corrupts the sentinel search.
  ALWAYS `find(START, 1, true)` / `find(END, ps, true)`. (GOTCHA #1.)
- ❌ **Don't decode NDJSON (per-item lines).** LIVE-VERIFIED `vim.json.decode('{"a":1}\n{"b":2}')` THROWS.
  The payload MUST be ONE `{items,prefix}` object (§17.5.1). The §17.6.x driver sketches' per-line format
  is a doc inconsistency; S5 decodes single-object + the drivers MUST conform. (GOTCHA #2 / D1.)
- ❌ **Don't call `state.pending_cb(...)` without the `if type(...)=="function"` guard.** `pending_cb` may
  be nil (no request in flight; or S4 already fired+nil'd it). A bare call THROWS on nil. (GOTCHA #4.)
- ❌ **Don't make `parse_failures` a module-local.** It is FAILURE STATE that MUST clear on reset (else it
  leaks across daemon restarts → a single failure post-restart re-trips the threshold). It's a `state`
  field + `M.reset()` clears it. (Contrast S4's `req_timer` module-local — a timer isn't failure state +
  S4 was parallel with S3 editing state.) (GOTCHA #5 / D2.)
- ❌ **Don't `vim.schedule` inside `_feed`.** It runs in the read_start cb (fast context) but does NO
  `vim.api.*` → fast-safe WITHOUT schedule (E5560). The menu hop is the CONSUMER's (P2.M2.T3) job.
  (GOTCHA #6 / D9.)
- ❌ **Don't call `notify.once` or `vim.uv.spawn` in S5.** The §17.12 degrade notify is P2.M2.T3.S4; spawn
  is S3's ensure (delegated to the driver). S5 has only string ops + `vim.json.decode` + state writes +
  the `pending_cb` call. (GOTCHA #7.)
- ❌ **Don't derive `prefix` from `line[1..cursor]`.** `_feed(chunk)` has NO line/cursor (the read_start
  cb passes only the chunk). Read `decoded.prefix` (§17.5.1 emits it; default ""). The consumer
  `complete_current` (P2.M2.T3.S3, which has the buffer) may refine it. (GOTCHA #8 / D4.)
- ❌ **Don't skip the `pcall` on decode, and don't skip the `type(decoded) ~= "table"` guard.** A
  successful decode of a bare number `"42"` returns a non-table → reading `.items` would crash. And use
  `ipairs` (not `pairs`) over `.items` — it's an ordered array; ipairs is nil-hole-safe + stops at holes.
  (GOTCHA #9.)
- ❌ **Don't call `M.teardown()` unconditionally.** It does NOT exist yet (S6). Forward-GUARD it
  (`if type(M.teardown)=="function" then pcall(M.teardown) end`) + re-assert `state.failed=true` after
  (S6's teardown may reset(); the daemon is dead → stay failed). (GOTCHA #7 / D7.)
- ❌ **Don't special-case an empty payload as success.** §17.5.1 mandates the daemon emit at least
  `{"items":[]}`; an empty payload is a protocol violation → counts as a parse_failure (the correct
  behavior). Trim is for determinism, not to rescue empty. (GOTCHA #3.)
- ❌ **Don't change the `M._feed(chunk)` signature or stop exporting it.** S3's `read_start` wiring +
  tests call `M._feed`. S5 REPLACES the BODY only. (GOTCHA #13.)
- ❌ **Don't touch S2's functions (other than the additive `state` field + `M.reset()` line), S3's
  `ensure`/`_reset`, or S4's `request`/`cancel_req_timer`/`req_timer`.** S5 owns `_feed` + the
  `parse_failures` state/reset additions + the module-local helpers. (GOTCHA #13.)
- ❌ **Don't spawn a real subprocess or rely on a real shell in tests.** Feed canned response strings to
  `M._feed` (+ the S3 fake-driver `read_cb`). The parse matrix is pure string+table work. (GOTCHA #14.)
- ❌ **Don't name a spec-local `pending`.** It shadows plenary.busted's skip fn. Use `got`/`cb`/`captured`.
  (GOTCHA #15.)
- ❌ **Don't leave `rx_buf`/`parse_failures`/`pending_cb` armed across test cases.** `shell.reset()`
  between cases; for delivery tests, drive `request()` to a terminal state (the `_feed` delivery
  finalizes S4's `pending_cb` → cb fires → timer closed). (GOTCHA #16.)
- ❌ **Don't heredoc lua into nvim's stdin** (AGENTS.md HARD RULE — it hangs the session). Write the smoke
  to `tests/shell_feed_smoke.lua` and run `+"luafile tests/shell_feed_smoke.lua" +qa` (as shown). Wrap
  every nvim in `timeout`.

---

## Confidence Score

**9/10** for one-pass implementation success. The design is a faithful sentinel-framed port of the
LIVE-VERIFIED in-repo `jsonlreader.lua` (append + drain-loop + plain-find + pcall-decode + synchronous-
deliver + never-throws) + the fish spike's `find`/`sub` sentinel-slice idiom + completion.lua's
defensive `result.items`/`result.prefix` normalize. Every non-obvious mechanic has a concrete in-repo
precedent. The tricky facts (`vim.json.decode` whitespace tolerance, NDJSON-fails, empty-throws) are
LIVE-VERIFIED with a copy-pasteable probe. The item description is unusually precise (it gives the exact
drain-loop body, the exact normalize shape, the exact threshold semantics). The genuine ambiguities are
resolved in Design Decisions with clear reasoning: (D1) single-object decode not NDJSON (verified); (D2)
`parse_failures` as a state field not module-local (it's failure state that must reset); (D4) prefix read
from `decoded.prefix` not derived (`_feed` lacks line/cursor — the only viable reading); (D7) teardown
forward-guarded + failed re-asserted (S6 not landed; reset-conflict avoided). The remaining risk is the
S3 `shell_ensure_spec` "_feed is append-only" case (S5 changes `_feed`'s nil-guard to call `_reset`) —
flagged in Level 3a with the exact update guidance (the `has_no.errors` assertion still passes; if a
stale rx_buf-growth assertion exists, update it to S5's new behavior, since S5 OWNS `_feed` now). -1 for
the inherent coupling of S5's delivery tests to S4's `request` (S5 invokes `pending_cb` which S4 sets) —
mitigated by treating S4's PRP as a contract + providing parse-failure tests that need NO `request()`.