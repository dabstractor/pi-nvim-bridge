---
name: "P2.M5.T14.S23 — jsonlreader.lua: buffer chunks, split on \\n, decode each line"
description: |
  **CREATE `plugin/lua/pi-editor/jsonlreader.lua`** — the strict-JSONL framing + decode module for
  the Neovim-side bridge client. It is the **Lua twin of the (DONE, P1.M2.T4.S7)
  `extension/jsonl-reader.ts`** (designated the authoritative framing mirror by PRD §5.2 + §16),
  ported to Lua/`vim.uv` semantics and to the CLIENT role. It owns exactly the FRAMING+DECODE half
  of parent task P2.M5.T14 ("JSONL reader module (Lua)"); the SOCKET/handshake/RPC-dispatch half is
  S24/S25/S26 (`bridge.lua`). S23 is dead code (imported nowhere) until S24 — by design, so the
  framing+decode logic is unit-tested in isolation, exactly as S7 was on the extension side.
  SURFACE S24 consumes (PRD §7.3 skeleton, LIVE-VERIFIED):
  `require("pi-editor.jsonlreader").new(on_message[, on_error]) -> reader`;
  `reader:feed(chunk)` (append chunk, drain complete `\n`-terminated lines, strip a trailing `\r`,
  `vim.json.decode` each, call `on_message(decoded_table)`); `reader:flush()` (on EOF, emit a
  buffered final line lacking `\n` — mirrors TS `onEnd`); `reader:reset()` (clear the buffer for
  reconnect/test isolation).
  KEY SIMPLIFICATION OVER THE TS TWIN (LIVE-VERIFIED, research/notes.md §4): Lua strings are BYTE
  buffers, so `..`/`string.find(s,"\n",1,true)`/`string.sub` are inherently UTF-8-correct and NO
  `StringDecoder` equivalent is needed — a split multi-byte char is transparently reassembled on the
  next chunk because `\n` (0x0A) never appears inside a UTF-8 multi-byte sequence. The reader must
  NOT add any char-decoder (cargo-culting the TS `StringDecoder` would INTRODUCE a bug).
  DELIBERATE DIVERGENCE from the TS twin (documented): the TS reader emits RAW string lines and lets
  S8 parse+dispatch; the Lua reader DECODES each line itself (`vim.json.decode` + `pcall`) and emits
  a Lua table — because (a) the task title ("…decode each line") and PRD §7.3 skeleton
  (`on_event(msg)` receives a decoded `msg`) require it, and (b) the Lua side is a CLIENT that
  cannot send a JSON-RPC `-32700` back, so a decode failure must be handled LOCALLY (pcall + optional
  `on_error`, never thrown — PRD §11 silent-degrade). This collapses S7+S8's two-step into one reader
  for the client side, matching the skeleton. Empty lines (after `\r`-strip) are SKIPPED (not
  decoded) — `vim.json.decode("")` throws (LIVE-VERIFIED), and a stray blank line from the trusted
  local server is not a hard error for a client.
  STATUS (planning): every API + byte-level behavior (`string.find` plain LF search, `\r` strip,
  `vim.json.decode` throw + pcall, luv `read_start` arbitrary chunking, EOF = `data==nil && err==nil`,
  byte-safe multibyte concat, U+2028/U+2029 contain no 0x0A) is LIVE-VERIFIED on Neovim 0.12.4 — see
  `research/notes.md`. NARROW scope guard — this task does NOT: open a socket (S24 `bridge.lua`), do
  the `hello` handshake (S25), correlate RPC by `id` / supersede (S26), or handle `commandsChanged`
  (S27). S23 only FRAMES + DECODES; it emits tables and knows nothing about JSON-RPC methods/ids.
---

## Goal

**Feature Goal**: Create `plugin/lua/pi-editor/jsonlreader.lua` — the strict-JSONL framing+decode
module for the pi-editor.nvim bridge client. Given an arbitrary sequence of byte chunks from a luv
`pipe:read_start` callback (whose chunk boundaries are ARBITRARY — LIVE-VERIFIED that 4 writes can
arrive as 2 chunks at any byte offset), it buffers partial lines, splits on `\n` ONLY (never
U+2028/U+2029 — PRD §5.2), strips a single trailing `\r` (CRLF tolerance), `vim.json.decode`s each
complete non-empty line into a Lua table, and invokes a caller-supplied `on_message(table)` callback.
It is the faithful, unit-tested Lua twin of the DONE extension-side `jsonl-reader.ts` (P1.M2.T4.S7),
ported to client-side semantics (decode-in-reader) and to Lua's byte-string model.

**Deliverable** (3 files — 1 NEW source + 2 NEW tests; NO modification to existing modules):
- `plugin/lua/pi-editor/jsonlreader.lua` — **CREATE**: the framing+decode module. Exposes
  `M.new(on_message[, on_error]) -> reader`, `reader:feed(chunk)`, `reader:flush()`, `reader:reset()`.
  [Mode A] LuaCATS docstrings throughout. Zero nvim API calls (pure string/`vim.json` work) → safe to
  run directly inside the luv `read_start` callback.
- `plugin/tests/jsonlreader_smoke.lua` — NEW, plenary-FREE standalone smoke test (Level-1 gate;
  `:luafile`-sourced — inherited S19 GOTCHA #10).
- `plugin/tests/jsonlreader_spec.lua` — NEW, plenary/busted spec (Level-2 gate) mirroring the TS
  `extension/tests/jsonl-reader.test.ts` cases + Lua-specific cases.

> Reuses the existing `plugin/tests/minimal_init.lua` (S19) unchanged. NO change to `init.lua`, the
> S20 shim, S21's gate, or S22's ftplugin (additive). `bridge.lua` (S24) does NOT exist yet — S23
> establishes the `new`/`feed`/`flush`/`reset` contract S24 will consume (a forward contract, like
> S22's `completion.lua`/`bridge.on_exit` seams).

**Success Definition** (every assertion is LIVE-VERIFIED green — see `research/notes.md` + Validation):
- **Single line**: `feed('{"a":1}\n')` → `on_message` called once with `{a=1}`.
- **Drain loop**: `feed('{"a":1}\n{"b":2}\n')` → two messages, in order.
- **Buffering**: partial line split across two `feed`s → one message (no premature decode).
- **CRLF**: `feed('{"a":1}\r\n')` → one message `{a=1}` (trailing `\r` stripped, not in any value).
- **Final line w/o LF**: buffered bytes + `flush()` → one message (mirrors TS `onEnd`).
- **Multibyte split**: a `€` (E2 82 AC) split across two `feed`s → one message `{e="€"}` (byte-safe
  concat, NO StringDecoder, NO U+FFFD).
- **U+2028/U+2029 preserved**: a line containing literal U+2028/U+2029 inside a string value → ONE
  message (LF-only split did not break it; separators preserved in the decoded value).
- **Empty input**: `feed("")` → no messages, no throw. `flush()` on empty buffer → no-op.
- **Blank lines skipped**: `feed('\n\n{"a":1}\n\n')` → exactly ONE message `{a=1}` (blank lines not
  decoded — `vim.json.decode("")` throws; LIVE-VERIFIED).
- **Plain search (not pattern)**: a line value containing `%`, `.`, `(`, `+` is decoded correctly
  (proves `string.find(..., true)` plain mode, not Lua pattern matching).
- **Decode failure → on_error, not throw**: `feed('{not json}\n')` with `on_error` set → `on_error`
  called with `(line, err)`; `on_message` NOT called; `feed` returns normally (pcall'd). Without
  `on_error` → silent (no throw).
- **reset()**: after a partial `feed('xx')`, `reset()` clears the buffer so a subsequent `flush()`
  emits nothing.
- **No throw ever**: `feed`/`flush`/`reset` never throw out (every decode is pcall'd; `on_message`
  is the consumer's responsibility and is documented as such).
- `nvim --headless --clean -u NORC` smoke prints `SMOKE_PASS` / exit 0.
- plenary `tests/jsonlreader_spec.lua` exits 0.
- **Non-regression**: S19 `init_spec` (13), S20 `shim_spec` (6), S21 `activate_spec` (9),
  S22 `ftplugin_spec` (13) still pass unchanged (S23 touches NO existing file).

## User Persona (if applicable)

**Target User**: The `pi-editor.nvim` plugin author and the downstream implementer of **S24**
(`bridge.lua` — the luv socket client + handshake + RPC dispatch). `jsonlreader.lua` is the byte→table
decoder S24 plugs into its `pipe:read_start` callback. End users never see it; they experience it as
"the completion menu shows the right items" (because the JSON-RPC responses were framed correctly).

**Use Case**: Completes the foundation stack S19 (config) → S20 (shim) → S21 (gate) → S22 (ftplugin)
→ **S23 (the byte-stream decoder)** → S24 (bridge wires S23 into a real socket). After S23, the
plugin has a tested, dependency-free JSONL decoder ready for S24's `read_start` callback — so S24
can focus on socket connect/handshake/RPC-id-correlation and just call `rx:feed(chunk)`. De-risks
"can we correctly frame the newline-delimited JSON the bridge server emits, across arbitrary socket
chunk boundaries and CRLF/multibyte edge cases?" before any socket or handshake logic lands.

**Pain Points Addressed**: Without a correct JSONL reader, the bridge client would (a) decode every
raw chunk and corrupt on the first multi-chunk message (LIVE-VERIFIED: 4 writes → 2 chunks), (b)
break on CRLF or U+2028/U+2029, or (c) throw out of the luv callback on a malformed line and surface
a spurious error. Getting the framing+decode locked NOW (with the full TS test suite mirrored) means
S24 just wires the socket — neither re-derives the decoder nor re-tests byte edge cases.

## Why

- **The Lua twin of a DONE, proven module.** `extension/jsonl-reader.ts` (P1.M2.T4.S7) is the
  authoritative framing mirror (PRD §16) — unit-tested, shipping. S23 ports its EXACT framing rules
  (`\n`-only split, `\r` strip, partial-line buffering, drain loop, final-line flush) to Lua, so both
  halves of the socket speak byte-for-byte the same JSONL. The wire must be symmetric.
- **Faithful to PRD §5.2 + §7.3.** §5.2 fixes the framing rules; §7.3's skeleton fixes the module
  surface (`new(cb)` + `feed(chunk)` that "splits on \n, vim.json.decode[s] each line"). S23 IS that
  surface. Decode-in-reader is the skeleton's explicit contract (`on_event(msg)` gets a decoded msg).
- **Decouples framing from sockets.** S24 (`bridge.lua`) is a big task (connect + handshake + id
  correlation + supersession + teardown). Pulling the pure, socket-free, easily-unit-tested decoder
  into its own module (S23) — exactly as S7/S8 were split on the extension side — means S24 composes
  a tested primitive instead of inlining fragile string arithmetic next to async socket code.
- **Integrates with the (complete) foundation.** Builds on S19's `init.lua` (DONE) only insofar as it
  lives under the same `lua/pi-editor/` package and is `require`-able as `"pi-editor.jsonlreader"`.
  Touches none of S19/S20/S21/S22 (additive). Establishes the forward contract S24 consumes.

## What

User-visible behavior: none directly (an internal module). Indirectly: once S24 ships, the completion
menu in a pi-launched nvim renders the correct items because every JSON-RPC response from the bridge
server is correctly framed and decoded regardless of how the OS coalesced the socket reads.

Technical requirements (the module body — exact, LIVE-VERIFIED):
- `local M = {}` module table; `return M` at the end (the `lua/pi-editor/*.lua` convention).
- **`M.new(on_message[, on_error])`** — factory. Returns a reader object (a table with `buffer=""`,
  `on_message`, `on_error`). `on_message` is a `function(table)` called per decoded message;
  `on_error` is an OPTIONAL `function(line_string, err_string)` called when `vim.json.decode` throws
  on a non-empty line (default behavior when omitted: silent — PRD §11). [Mode A] docstrings.
- **`reader:feed(chunk)`** — append `chunk` to `self.buffer`; loop: `string.find(self.buffer, "\n",
  1, true)` (PLAIN LF search); if none, return (partial line stays buffered); else extract the line
  (`self.buffer:sub(1, nl-1)`), advance (`self.buffer = self.buffer:sub(nl+1)`), strip a single
  trailing `\r` (`if line:sub(-1)=="\r" then line=line:sub(1,-2) end`), and if the line is non-empty
  `pcall(vim.json.decode, line)` → on success call `self.on_message(msg)`; on failure call
  `self.on_error(line, err)` if set. NEVER throws. Handles a chunk carrying MANY records (drain loop)
  and a chunk carrying a PARTIAL record (buffering).
- **`reader:flush()`** — on EOF (luv `read_start` callback with `data==nil, err==nil` —
  LIVE-VERIFIED): if `self.buffer` is non-empty, treat it as a final line lacking `\n` (strip `\r`,
  skip if empty, decode+`on_message`/`on_error` as in `feed`), then clear `self.buffer`. Mirrors TS
  `onEnd`. No-op on an empty buffer.
- **`reader:reset()`** — set `self.buffer = ""` (clear any partial line). For reconnect / test
  isolation. Cheap; idempotent.
- **NO nvim API calls** anywhere (only `string.*`, `vim.json.decode`, table ops) → safe to call
  directly from the luv `read_start` callback (which fires on the libuv loop). The CONSUMER
  (`on_message`) is responsible for `vim.schedule`-wrapping any nvim-API work it does (standard
  luv→nvim rule; documented as an integration note, not enforced here).
- **NO module-level mutable state** — each reader instance owns its own `buffer` (so two sockets get
  two independent readers). Mirrors the TS "No module state" property (the TS reader uses closures;
  Lua uses an object/table because the PRD §7.3 skeleton is `new()`+`:feed()`, an object shape).
- **[Mode A]**: a header comment block (purpose, the TS-mirror lineage, the byte-safe-concat
  simplification, the decode-in-reader divergence + why, the `on_message` synchronous +
  consumer-schedules integration note) + per-method LuaCATS docstrings.

### Success Criteria

- [ ] `M.new` is a function; `M.new(cb)` returns a table with `feed`/`flush`/`reset` methods.
- [ ] `feed('{"a":1}\n')` → exactly one `on_message({a=1})`.
- [ ] `feed('{"a":1}\n{"b":2}\n')` → two messages in order (drain loop).
- [ ] Partial line across two `feed`s → one message (buffering; no premature decode of the prefix).
- [ ] `feed('{"a":1}\r\n')` → one message `{a=1}`; the `\r` is stripped (not inside any value).
- [ ] Buffered bytes + `flush()` → one message (final line without trailing `\n`).
- [ ] A `€` split across two `feed`s → one message `{e="€"}` (byte-safe; no U+FFFD; no StringDecoder).
- [ ] A line with literal U+2028/U+2029 in a value → ONE message; separators preserved in the value.
- [ ] `feed("")` → no messages, no throw. `flush()` on empty buffer → no messages, no throw.
- [ ] `feed('\n\n{"a":1}\n\n')` → exactly ONE message `{a=1}` (blank lines skipped, not decoded).
- [ ] A value containing `%`/`.`/`(`/`+` decodes correctly (plain LF search, not Lua pattern).
- [ ] `feed('{not json}\n')` with `on_error` → `on_error(line, err)` called; `on_message` NOT called;
      `feed` returns normally. Without `on_error` → silent (no throw).
- [ ] `reset()` after a partial `feed('xx')` → subsequent `flush()` emits nothing.
- [ ] `feed`/`flush`/`reset` NEVER throw (every `vim.json.decode` is pcall'd).
- [ ] No module-level mutable state: two `new()` readers are independent (feed one, the other empty).
- [ ] No `vim.api.*` calls in the file (pure string/json — safe in a luv callback).
- [ ] `nvim --headless --clean -u NORC +"luafile plugin/tests/jsonlreader_smoke.lua" +qa` prints
      `SMOKE_PASS` / exit 0.
- [ ] `tests/jsonlreader_spec.lua` passes under plenary (exit 0).
- [ ] **Non-regression**: `init_spec` + `shim_spec` + `activate_spec` + `ftplugin_spec` still pass.
- [ ] [Mode A] header comment + per-method LuaCATS docstrings present.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo needs only this PRP +
`research/notes.md` + the verified commands below. Every Lua primitive (`string.find` plain LF,
`string.sub`, `:sub(-1)`/`:sub(1,-2)` `\r` strip, `vim.json.decode` + pcall) and every luv behavior
(arbitrary chunking, EOF = `data==nil && err==nil`) is cited with a `:help`/reference source AND a
**LIVE-VERIFIED** result (`research/notes.md` §3–§7). The two subtleties that make or break this
task — (1) Lua `..`/`string.*` are BYTE operations so NO `StringDecoder` is needed (cargo-culting the
TS `StringDecoder` introduces a bug), and (2) the reader DECODES (unlike the TS twin which emits raw
strings) because the task title + PRD §7.3 skeleton require it and the client can't send a `-32700` —
are spelled out in §Known Gotchas and embedded in the reference implementation.

### Documentation & References

```yaml
# MUST READ — primary contract sources

- url: https://neovim.io/doc/user/lua.html#vim.json
  why: "vim.json.decode(str) parses JSON into a Lua table; THROWS on invalid input (incl. empty
        string). Must be pcall'd. vim.json.encode(obj) produces compact JSON (used by S24 to WRITE;
        S23 only decodes)."
  critical: "LIVE-VERIFIED (research/notes.md §5/§7): decode('') throws 'Expected value but found
             T_END at character 1'; decode('not json') throws. So the reader MUST pcall every decode
             and SKIP empty lines (a blank line is not a hard error for a client — PRD §11)."

- url: https://www.lua.org/manual/5.1/manual.html#pdf-string.find
  why: "string.find(s, pattern, init, plain). The 4th arg plain=TRUE disables Lua pattern matching
        (so literal '%','.','+','(' in JSON values don't break the search) and makes it a pure byte
        scan. This is the LF-only split primitive."
  critical: "GOTCHA: omitting `plain` (the 4th `true` arg) makes '%','.' etc. be interpreted as Lua
             patterns and corrupts the split on real JSON. ALWAYS pass `, 1, true`. LIVE-VERIFIED
             that ('ab\\ncd'):find('\\n',1,true) == 3."

- url: https://www.lua.org/manual/5.1/manual.html#pdf-string.sub
  why: "string.sub(s, i [, j]) — byte slicing. :sub(1, nl-1) extracts the line before the \\n;
        :sub(nl+1) keeps the remainder. Byte-exact (no UTF-8 awareness needed — see the byte-safety
        gotcha)."

- url: https://neovim.io/doc/user/luaref.html#luaref-notes
  why: "LuaJIT (Neovim's Lua, 5.1 semantics): strings are IMMUTABLE BYTE SEQUENCES (8-bit clean,
        not Unicode-aware). `..`, string.find, string.sub all operate on BYTES."
  critical: "THE KEY SIMPLIFICATION (research/notes.md §4): because Lua strings are byte buffers,
             concatenating two chunks with `..` (even when the first ends mid-multibyte-char) and
             splitting on 0x0A is INHERENTLY UTF-8-correct — 0x0A never appears inside a UTF-8
             multi-byte sequence. NO StringDecoder/streaming-UTF-8-decoder is needed (unlike the TS
             side which reads Buffers). LIVE-VERIFIED: string.char(0xE2,0x82)..string.char(0xAC)
             decodes to '€'. Do NOT add vim.str_utfindex/utf8.len on partial chars — that's WRONG."

- url: https://github.com/luvit/luv/blob/master/docs.md
  why: "luv (vim.uv) pipe:read_start(callback) — callback signature (err, data); data==nil signals
        EOF (err nil) or a read error (err non-nil). Chunk boundaries are ARBITRARY (the OS coalesces
        / fragments reads). The bridge server's four writes arrived as two chunks at random offsets."
  critical: "LIVE-VERIFIED (research/notes.md §3): 4 client writes -> server read_start fired TWICE
             (chunks of 16 and 19 bytes). So the reader CANNOT assume one chunk == one line; it MUST
             buffer. EOF = the read_start callback receiving data==nil, err==nil -> call flush()."

- file: extension/jsonl-reader.ts
  why: "THE AUTHORITATIVE MIRROR (PRD §16). S23 is its Lua twin — same framing rules (\\n-only split,
        \\r strip, drain loop, partial-line buffering, final-line flush on end), same 'no module
        state', same 'detaches on close'. Read it IN FULL before implementing."
  pattern: "attachJsonlLineReader(stream, onLine) emits RAW string lines via onData (buffer += chunk;
            while newlineIndex != -1: emitLine(slice); buffer = slice after \\n) + onEnd (flush final
            line). serializeJsonLine(v) = JSON.stringify(v)+'\\n' (S24's job on the Lua side)."
  gotcha: "TWO DELIBERATE DIVERGENCES (documented in this PRP's §Known Gotchas): (1) the Lua reader
           DECODES (vim.json.decode) and emits tables — the TS reader emits raw strings because the
           server can reply -32700; the client cannot. (2) the Lua reader SKIPS blank lines — the TS
           reader emits them and lets them parse-error. Both because the Lua side is a CLIENT."

- file: extension/tests/jsonl-reader.test.ts
  why: "THE TEST PATTERN TO MIRROR. Its 11 cases map 1:1 to jsonlreader_spec.lua cases (single line,
        drain loop, buffering, CRLF \\r strip, final-line-no-LF flush, U+2028/U+2029 preserved,
        multibyte split reassembled, empty input no-op, plus Lua-specific blank-skip + on_error)."
  pattern: "feed(chunks) collects lines; assert.deepEqual. Lua equivalent: new(collect-table),
            feed each chunk, assert.are.same the collected messages."

- file: extension/connection.ts
  why: "Shows how S8 (the TS connection handler) CONSUMES the reader: attachJsonlLineReader(sock,
        line => handleLine(sock, state, line)) — i.e. the reader emits, the connection parses+
        dispatches. On the Lua side these two roles MERGE into bridge.lua (S24/S26) which will do
        pipe:read_start(function(err,chunk) if not chunk then rx:flush() else rx:feed(chunk) end) and
        receive decoded tables via on_message. Establishes the consumer contract S23 must serve."

- docfile: PRD.md
  section: "§5.2 (Framing — \\n-only, \\r strip, no U+2028/U+2029), §7.3 (bridge.lua skeleton — the
        `new(cb)`/`feed(chunk)` surface + `on_event(msg)` decoded-msg contract), §5.5 (timing/
        cancellation — owned by S26, NOT S23), §11 (silent-degrade on malformed/EOF)"
  why: "These PRD sections ARE the source of truth for this task (reproduced in <selected_prd_content>).
        §5.2 fixes the framing rules; §7.3 fixes the module surface."

- file: plan/001_c56962b4fa17/architecture/external_deps.md
  why: "§1.4 (luv unix-socket pattern: new_pipe(false) -> connect -> read_start(cb) -> write ->
        close) is the S24 consumer of THIS module. §1.5 (vim.json) confirms decode throws on invalid.
        §6 confirms plenary is the Lua test framework."

- file: plugin/lua/pi-editor/init.lua
  why: "S19/S21 module (DONE). Confirms the `lua/pi-editor/*.lua` module convention (`local M` /
        `return M`, [Mode A] LuaCATS `---@class`/`---@param`/`---@return` docstrings) and that
        `require(\"pi-editor.jsonlreader\")` will resolve once the file exists under lua/pi-editor/."

- file: plugin/tests/minimal_init.lua
  why: "S19 plenary harness (DONE, REUSED unchanged). Puts plugin/ on runtimepath + plenary on rtp,
        so require(\"pi-editor.jsonlreader\") + require(\"plenary.busted\") both resolve in tests."

- file: plan/001_c56962b4fa17/P2M4T13S22/PRP.md
  why: "The immediately-preceding sibling (ftplugin, DONE). Establishes the forward-contract pattern
        S23 reuses (a module that is correct & tested TODAY and goes live when its consumer ships) and
        the smoke+spec two-file test convention. Read for style/depth calibration."

- file: plan/001_c56962b4fa17/P2M5T14S23/research/notes.md
  why: "LIVE-VERIFIED proof (nvim 0.12.4) of every claim above: the TS-mirror lineage, the consumer
        contract, luv arbitrary chunking (4 writes -> 2 chunks), EOF signaling, byte-safe multibyte
        concat (no StringDecoder), the byte-level primitives, U+2028/U+2029 contain no 0x0A, and
        decode('') throws. Full probe transcript included."
```

### Current Codebase tree (relevant slice)

```bash
pi-nvim-bridge/                  # repo root (monorepo: extension/ + plugin/)
├── extension/                   # P1 — pi-editor-bridge (TypeScript) — COMPLETE
│   ├── jsonl-reader.ts          # THE AUTHORITATIVE MIRROR (P1.M2.T4.S7, DONE) — S23's Lua twin
│   ├── connection.ts            # S8 consumer of jsonl-reader.ts (P1.M2.T4.S8, DONE)
│   └── tests/jsonl-reader.test.ts  # the test pattern to mirror (DONE)
├── plugin/                      # <-- Neovim plugin root (the runtimepath entry)
│   ├── lua/pi-editor/
│   │   └── init.lua             # S19+S21 (DONE) — module convention + activate() gate
│   ├── plugin/pi-editor.lua     # S20 (DONE) — VimEnter shim
│   ├── ftplugin/pi-prompt.lua   # S22 (DONE) — buffer setup (wires completion/bridge forward contracts)
│   └── tests/
│       ├── minimal_init.lua     # S19 (DONE) — plenary harness (REUSED unchanged)
│       ├── init_spec.lua        # S19 (DONE) — must STILL pass
│       ├── smoke.lua            # S19 (DONE)
│       ├── shim_spec.lua  shim_smoke.lua       # S20 (DONE) — must STILL pass
│       ├── activate_spec.lua  activate_smoke.lua  # S21 (DONE) — must STILL pass
│       └── ftplugin_spec.lua  ftplugin_smoke.lua  # S22 (DONE) — must STILL pass
├── PRD.md  README.md  package.json
└── plan/001_c56962b4fa17/
    ├── architecture/{external_deps,system_context}.md
    └── P2M5T14S23/{PRP.md, research/notes.md}   # THIS task
# NOTE: plugin/lua/pi-editor/jsonlreader.lua does NOT exist yet — this task CREATES it.
# NOTE: plugin/lua/pi-editor/bridge.lua (S24) does NOT exist yet — it is this module's CONSUMER.
#       S23 establishes the new/feed/flush/reset surface; S24 wires it into pipe:read_start.
# NOTE: stylua, selene are NOT installed (nvim 0.12.4 + plenary.nvim ARE).
```

### Desired Codebase tree with files to be added/modified

```bash
plugin/                          # runtimepath entry (unchanged)
├── lua/pi-editor/
│   ├── init.lua                 # (S19/S21, unchanged)
│   └── jsonlreader.lua          # NEW — strict-JSONL framing + decode (the S7 Lua twin)
└── tests/
    ├── minimal_init.lua         # (S19, REUSED unchanged)
    ├── jsonlreader_smoke.lua    # NEW — plenary-FREE smoke test (Level-1 gate; :luafile-sourced)
    └── jsonlreader_spec.lua     # NEW — plenary/busted spec (Level-2 gate)
```

> **Why CREATE (not MODIFY)?** `jsonlreader.lua` is a brand-new, dependency-free, stateless module.
  It consumes nothing from the existing modules (it does not even `require("pi-editor")` — it is
  pure string/`vim.json` work). No existing file changes → guaranteed non-regression of all four
  predecessor suites.

### Known Gotchas of our codebase & Library Quirks

```lua
-- GOTCHA 1 — Lua strings are BYTE buffers; do NOT add a UTF-8/char decoder.
--   The TS twin needs Node's StringDecoder("utf8") because it reads `Buffer` chunks (raw bytes)
--   and a multi-byte char can be split across two Buffers. Lua strings are ALREADY byte sequences
--   (8-bit clean, immutable); `..`, string.find, string.sub are BYTE operations. Concatenating two
--   chunks where the first ends mid-char, then splitting on 0x0A, is INHERENTLY correct because
--   0x0A never appears inside a UTF-8 multi-byte sequence (continuation bytes are 0x80-0xBF).
--   LIVE-VERIFIED (research/notes.md §4): string.char(0xE2,0x82)..string.char(0xAC) -> decodes to "€".
--   CRITICAL: an implementer who cargo-cults the TS StringDecoder and reaches for vim.str_utfindex /
--   utf8.len on a PARTIAL char would INTRODUCE a bug (those require complete, valid UTF-8). Do NOT.

-- GOTCHA 2 — the reader DECODES (diverges from the TS twin, which emits raw strings).
--   The TS reader's docstring is explicit: "emits RAW string lines only. Does NOT JSON.parse ...
--   that is S8's job." On the Lua CLIENT side we DELIBERATELY decode inside the reader because
--   (a) the task title ("...decode each line") + PRD §7.3 skeleton (on_event(msg) gets a decoded
--   msg) require it, and (b) the client cannot send a JSON-RPC -32700 back on a malformed line, so
--   the decode failure must be handled LOCALLY (pcall + optional on_error). This collapses S7+S8's
--   two-step into one reader for the client. Document the divergence in the header comment.

-- GOTCHA 3 — string.find MUST be called with the plain=true 4th arg.
--   string.find(s, "\n", 1, true). Omitting `true` makes Lua interpret the "pattern" (so a JSON
--   value containing '%', '.', '+', '(', etc. would corrupt the search). ALWAYS pass `, 1, true`.
--   LIVE-VERIFIED that ('ab\ncd'):find('\n', 1, true) == 3.

-- GOTCHA 4 — blank lines (empty after \r-strip) MUST be skipped, not decoded.
--   vim.json.decode("") THROWS ("Expected value but found T_END at character 1" — LIVE-VERIFIED).
--   The TS reader emits blank lines and lets S8's JSON.parse("") throw -> -32700 response; the Lua
--   client cannot reply, and a stray blank line from the trusted local server is not a hard error
--   (PRD §11 silent-degrade). So SKIP lines that are empty after the \r-strip. Only pcall-decode
--   NON-empty lines. Documented deviation.

-- GOTCHA 5 — on_message is called SYNCHRONOUSLY from feed; the consumer schedules nvim API calls.
--   The luv pipe:read_start callback fires on the libuv event loop. The reader does NO nvim API
--   calls (pure string/vim.json), so calling it directly from the luv callback is safe. But the
--   consumer's on_message(table) MAY need to touch nvim state (menu render, buffer set) — that work
--   is the consumer's responsibility to vim.schedule-wrap (standard luv->nvim rule). The reader does
--   NOT impose scheduling (would complicate testing). Document as an integration note.

-- GOTCHA 6 — NEVER throw out of feed/flush/reset.
--   A throw would escape the luv read_start callback and surface as a spurious error (bridge.lua's
--   err path is for SOCKET errors, not reader-internal decode errors). Every vim.json.decode is
--   pcall'd; on_message/on_error are the consumer's (if THEY throw, that's the consumer's bug, but
--   the reader should still not add its own throws). feed/flush/reset always return normally.

-- GOTCHA 7 — string.char is clearest for byte-level control (LuaJIT DOES support \u{}).
--   CORRECTION: LuaJIT (Neovim's Lua) DOES support the `\u{XXXX}` escape (a documented LuaJIT
--   extension — LIVE-VERIFIED: '\u{20ac}\u{2028}' yields E2 82 AC E2 80 A8). So `\u{}` is NOT a
--   syntax error. BUT for TESTS that construct SPLIT byte sequences or need exact bytes, string.char
--   is clearer and universally portable: U+2028 = string.char(0xE2,0x80,0xA8); U+2029 =
--   string.char(0xE2,0x80,0xA9). The reference tests use string.char to make the byte splitting
--   explicit (e.g. feeding E2 82 then AC). Do not assume \u{} is unavailable (it isn't).

-- GOTCHA 8 — U+2028/U+2029 do NOT need special handling in the reader.
--   Their UTF-8 encodings (E2 80 A8 / E2 80 A9) contain NO 0x0A byte, so a plain '\n' search can
--   never split them. The reader is automatically PRD-§5.2-compliant. The TEST asserts this (feed a
--   line with literal separators, expect ONE message). LIVE-VERIFIED (research/notes.md §6).

-- GOTCHA 9 — feed must DRAIN all complete lines in one chunk, not just the first.
--   A single chunk can carry MANY records ('{"a":1}\n{"b":2}\n'). Use a `while true` loop that
--   re-searches the REMAINING buffer (self.buffer = self.buffer:sub(nl+1)) until no '\n' remains.
--   LIVE-VERIFIED (luv delivered a 19-byte chunk that could carry multiple lines).

-- GOTCHA 10 — flush() is for EOF only; it must be a no-op on an empty buffer.
--   The TS onEnd emits a final line only if buffer.length > 0. Mirror that: if self.buffer == "",
--   flush() does nothing. EOF = the luv read_start callback receiving data==nil, err==nil
--   (LIVE-VERIFIED); bridge.lua (S24) calls rx:flush() there. reset() also clears the buffer (for
--   reconnect/test isolation) but does NOT decode — distinct from flush().

-- GOTCHA 11 — M.new MUST wrap the state table in setmetatable({…}, {__index = M}).
--   The methods live on the MODULE (M.feed/M.flush/M.reset). A bare `return {buffer=…}` has NO
--   feed/flush/reset fields, so `rx:feed(chunk)` resolves `feed` on `rx`, finds nil, and THROWS
--   "attempt to call method 'feed' (a nil value)" — LIVE-VERIFIED (the reference impl WITHOUT the
--   metatable fails the very first smoke check). FIX: `return setmetatable({…}, {__index = M})` so
--   `rx:feed(chunk)` -> M.feed(rx, chunk) (standard Lua module-OOP; `:` passes rx as self).

-- GOTCHA 12 — collect()/reader() test helpers take a TABLE of feeds, NOT a bare string.
--   `ipairs(someString)` THROWS in LuaJIT ("bad argument #1 to 'ipairs' (table expected, got
--   string)" — LIVE-VERIFIED). A test that calls `collect('{…}\n')` (bare string) crashes the helper,
--   not the reader. Always wrap: `collect({'{…}\n'})`. (The reference tests do.)
```

## Implementation Blueprint

### Data models and structure

No external data models. The reader is a small self-contained object:

```lua
---@class pi-editor.JsonlReader
---@field private buffer string   Pending partial-line bytes accumulated across feed() calls.
---@field private on_message function  Called per decoded JSON-RPC message: on_message(table).
---@field private on_error? fun(line:string, err:string)  Optional; called when decode throws.
```

The decoded message is whatever `vim.json.decode` returns for the line — a Lua table (a JSON-RPC
envelope `{jsonrpc="2.0", id="...", method="...", params/result/error=...}`). The reader does NOT
narrow or dispatch by method/id — that is `bridge.lua`/S26's job. It only frames + decodes.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/lua/pi-editor/jsonlreader.lua  (THE deliverable — framing + decode)
  - HEADER: a [Mode A] comment block documenting: purpose; the TS-mirror lineage (extension/
        jsonl-reader.ts, P1.M2.T4.S7, PRD §16); the byte-safe-concat simplification (NO
        StringDecoder — GOTCHA 1); the decode-in-reader divergence from the TS twin + WHY (GOTCHA 2);
        the synchronous on_message + consumer-schedules integration note (GOTCHA 5); the narrow
        scope (frames+decodes only; socket/handshake/id-correlation are S24/S25/S26).
  - MODULE: `local M = {}` ... `return M` (the lua/pi-editor/*.lua convention).
  - M.new(on_message[, on_error]) -> reader: construct the object via setmetatable({buffer="",
        on_message=on_message, on_error=on_error}, {__index = M}) — GOTCHA 11 (WITHOUT the metatable,
        rx:feed is a nil-method call and THROWS; LIVE-VERIFIED). Validate on_message is a function
        (assert / error at construction — caller bug, not a runtime decode path). [Mode A] docstring.
  - reader:feed(chunk): append chunk..self.buffer semantics (self.buffer = self.buffer .. chunk);
        drain loop (string.find plain LF, GOTCHA 3); per complete line: \r-strip, skip-empty
        (GOTCHA 4), pcall(vim.json.decode) -> on_message or on_error; NEVER throw (GOTCHA 6).
  - reader:flush(): if self.buffer ~= "" treat as final line (\r-strip, skip-empty, decode/emit),
        then self.buffer = ""; else no-op (GOTCHA 10).
  - reader:reset(): self.buffer = "" (no decode; reconnect/test isolation).
  - NO vim.api.* calls (GOTCHA 5 — pure string/vim.json). NO module-level mutable state (each reader
        owns its buffer).
  - DO NOT require("pi-editor") or any sibling (the module is pure/standalone).
  - DO NOT implement socket/handshake/id-correlation (S24/S25/S26).
  - PLACEMENT: plugin/lua/pi-editor/jsonlreader.lua.

Task 2: CREATE plugin/tests/jsonlreader_smoke.lua  (plenary-FREE fast smoke — the Level-1 gate)
  - CONTENT (see Implementation Patterns): standalone script. require("pi-editor.jsonlreader"); build
        a reader whose on_message pushes into a table; feed the canonical cases (single line, drain
        loop, buffering across feeds, CRLF, final-line-via-flush, multibyte-split, blank-skip,
        on_error-on-malformed, reset-clears-buffer); assert each. cquit(1) on failure.
  - WHY: instant, dependency-free feedback (no plenary). jsonlreader_spec.lua is the formal suite.
  - GOTCHA: source via :luafile, NOT a :lua <<HEREDOC in a -c/+ arg (inherited S19 GOTCHA #10).
  - GOTCHA: build U+2028/U+2029 via string.char for explicit byte control (GOTCHA 7 — LuaJIT
        supports \u{} too, but string.char is clearest for split sequences).
  - PLACEMENT: plugin/tests/jsonlreader_smoke.lua.
  - DEPENDENCIES: Task 1.

Task 3: CREATE plugin/tests/jsonlreader_spec.lua  (plenary/busted spec — the Level-2 gate)
  - CONTENT (see Implementation Patterns): a describe("pi-editor.jsonlreader", ...). Cover ALL
        Success Criteria as `it` blocks (single line, drain loop, buffering, CRLF, flush final-line,
        multibyte split, U+2028/U+2029 preserved, empty input no-op, blank-skip, plain-search
        pattern chars, on_error on malformed + silent when omitted, reset, no-throw, instance
        independence). Mirror the TS jsonl-reader.test.ts case set + Lua-specific cases.
  - ASSERTIONS: assert.are.same (deep, for decoded tables), assert.are.equals, assert.is_true /
        is_nil / is_not_nil, assert.has_no.errors for the no-throw checks.
  - PLACEMENT: plugin/tests/jsonlreader_spec.lua.
  - DEPENDENCIES: Task 1 + the S19 harness (plugin/tests/minimal_init.lua).
```

### Implementation Patterns & Key Details

```lua
-- === plugin/lua/pi-editor/jsonlreader.lua — the FULL reference implementation (LIVE-VERIFIED) ===
-- Strict-JSONL framing + decode for the pi-editor.nvim bridge CLIENT. Lua twin of the DONE
-- extension-side extension/jsonl-reader.ts (P1.M2.T4.S7 — the authoritative framing mirror,
-- PRD §16), ported to Lua's byte-string model and to the client role.
--
-- [Mode A] header — read before editing:
--  * BYTE-SAFE (GOTCHA 1): Lua strings are byte buffers; `..`/string.find/string.sub are byte
--    operations, so split-multibyte chars are transparently reassembled on the next chunk and NO
--    StringDecoder/streaming-UTF-8-decoder is needed (unlike the TS side which reads Buffers). Do
--    NOT add vim.str_utfindex/utf8.len on partial chars — that is a BUG.
--  * DECODE-IN-READER (GOTCHA 2): unlike the TS twin (which emits raw string lines and lets S8
--    parse), this reader DECODES each line (vim.json.decode) and emits a Lua table. Required by the
--    task title + PRD §7.3 skeleton (on_event(msg)); and the client cannot reply -32700, so decode
--    failure is handled locally (pcall + optional on_error).
--  * SYNCHRONOUS on_message (GOTCHA 5): on_message(table) is called inline from feed/flush. The
--    reader does NO nvim API calls (safe in a luv read_start callback). The CONSUMER schedules any
--    nvim-API work it does inside on_message (standard luv->nvim rule).
--  * SCOPE: frames + decodes ONLY. Socket/handshake/id-correlation/supersession are bridge.lua
--    (S24/S25/S26). This module knows nothing of JSON-RPC methods/ids.

local M = {}

--- A strict-JSONL reader. Buffers byte chunks, splits on `\n` only, strips a trailing `\r`,
--- `vim.json.decode`s each complete non-empty line, and invokes `on_message(table)`.
---
--- Use inside a luv `pipe:read_start` callback (PRD §7.3):
--- >
---   local rx = require("pi-editor.jsonlreader").new(function(msg) ... end)
---   pipe:read_start(function(err, chunk)
---     if err then return end           -- socket error -> bridge.lua handles
---     if chunk == nil then rx:flush()   -- EOF (data==nil, err==nil) -> final line
---     else rx:feed(chunk) end
---   end)
--- <
---@class pi-editor.JsonlReader
---@field private buffer string Pending partial-line bytes accumulated across feed() calls.
---@field private on_message function Called per decoded message: on_message(table).
---@field private on_error? fun(line:string, err:string) Optional decode-error callback.

--- Construct a new reader.
---
---@param on_message fun(msg:table) Called once per decoded JSON-RPC message (synchronously).
---@param on_error? fun(line:string, err:string) Called when `vim.json.decode` throws on a
---  non-empty line. If omitted, decode failures are SILENT (PRD §11 silent-degrade). Never throws.
---@return pi-editor.JsonlReader
function M.new(on_message, on_error)
  assert(type(on_message) == "function", "jsonlreader.new: on_message must be a function")
  -- GOTCHA 11: setmetatable {__index = M} so rx:feed(chunk) -> M.feed(rx, chunk). WITHOUT it,
  -- rx.feed is nil and rx:feed(...) throws "attempt to call method 'feed' (a nil value)"
  -- (LIVE-VERIFIED against the reference impl). Standard Lua module-OOP pattern.
  return setmetatable({
    buffer = "",
    on_message = on_message,
    on_error = on_error,
  }, { __index = M })
end

--- Process the next chunk: append to the buffer, then drain ALL complete `\n`-terminated lines.
--- A single chunk may carry MANY records (drain loop) or a PARTIAL record (left buffered).
--- Each complete line: strip a single trailing `\r`, skip if empty, else `pcall(vim.json.decode)`
--- and invoke `on_message(table)` (or `on_error(line, err)` on failure). Never throws.
---@param chunk string The raw byte chunk from a luv `read_start` callback.
function M.feed(self, chunk)
  self.buffer = self.buffer .. chunk
  while true do
    local nl = self.buffer:find("\n", 1, true)   -- GOTCHA 3: PLAIN LF search (pattern OFF)
    if not nl then return end                    -- incomplete trailing line stays buffered
    local line = self.buffer:sub(1, nl - 1)
    self.buffer = self.buffer:sub(nl + 1)
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end  -- CRLF tolerance (strip ONE \r)
    if line ~= "" then                           -- GOTCHA 4: skip blank (decode("") throws)
      local ok, msg = pcall(vim.json.decode, line)
      if ok then
        self.on_message(msg)
      elseif self.on_error then
        self.on_error(line, msg)
      end
    end
  end
end

--- Flush a buffered FINAL line that lacks a trailing `\n` (mirrors the TS reader's `onEnd`).
--- Call on EOF (the luv `read_start` callback with `data == nil, err == nil`). No-op on an empty
--- buffer. Never throws.
function M.flush(self)
  if self.buffer == "" then return end           -- GOTCHA 10
  local line = self.buffer
  self.buffer = ""
  if line:sub(-1) == "\r" then line = line:sub(1, -2) end
  if line ~= "" then
    local ok, msg = pcall(vim.json.decode, line)
    if ok then self.on_message(msg)
    elseif self.on_error then self.on_error(line, msg) end
  end
end

--- Clear the internal buffer (drop any partial line). For reconnect / test isolation. Does NOT
--- decode or emit. Idempotent.
function M.reset(self)
  self.buffer = ""
end

return M
```

```lua
-- === plugin/tests/jsonlreader_smoke.lua — standalone (plenary-FREE) smoke test ===
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/jsonlreader_smoke.lua" +qa ; echo exit=$?
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h")           -- .../plugin (rtp entry)
vim.opt.runtimepath:append(plugin_root)

local jreader = require("pi-editor.jsonlreader")
local fails = 0
local function check(cond, msg) if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); fails = fails + 1 end end

local function collect(feeds, opts)
  opts = opts or {}
  local msgs, errs = {}, {}
  local rx = jreader.new(function(m) msgs[#msgs+1] = m end, opts.on_error and function(l,e) errs[#errs+1]={l,e} end or nil)
  for _, f in ipairs(feeds) do rx:feed(f) end
  if opts.flush then rx:flush() end
  return msgs, errs
end

-- single line
local m = collect({'{"a":1}\n'})
check(#m == 1 and m[1].a == 1, "single line -> 1 message {a=1}")
-- drain loop (many records in one chunk)
m = collect({'{"a":1}\n{"b":2}\n'})
check(#m == 2 and m[1].a == 1 and m[2].b == 2, "drain loop -> 2 messages in order")
-- buffering across feeds
m = collect({'{"x":"', 'val"}\n'})
check(#m == 1 and m[1].x == "val", "partial line buffered across feeds -> 1 message")
-- CRLF
m = collect({'{"a":1}\r\n'})
check(#m == 1 and m[1].a == 1, "CRLF -> \\r stripped, 1 message")
-- final line via flush
m = collect({'{"final":true}'}, {flush=true})
check(#m == 1 and m[1].final == true, "flush emits final line w/o trailing \\n")
-- multibyte split (€ = E2 82 AC): feed1 ends MID-char with NO closing quote; feed2 completes it.
-- (The \" after 0xE2,0x82 in a naive version prematurely CLOSES the JSON string — LIVE-VERIFIED bug.)
m = collect({'{"e":"' .. string.char(0xE2,0x82), string.char(0xAC) .. '"}\n'})
check(#m == 1 and m[1].e == "€", "split multibyte reassembled -> e=€ (no U+FFFD)")
-- U+2028/U+2029 preserved (ONE record; build via string.char — clearest byte control, GOTCHA 7)
local LS, PS = string.char(0xE2,0x80,0xA8), string.char(0xE2,0x80,0xA9)
m = collect({'{"t":"a' .. LS .. 'b' .. PS .. 'c"}\n'})
check(#m == 1 and m[1].t == "a" .. LS .. "b" .. PS .. "c", "U+2028/U+2028 preserved (LF-only split)")
-- empty input
m = collect({""})
check(#m == 0, "empty feed -> no messages, no throw")
-- blank lines skipped
m = collect({'\n\n{"a":1}\n\n'})
check(#m == 1 and m[1].a == 1, "blank lines skipped -> exactly 1 message")
-- plain search (pattern chars in value)
m = collect({'{"p":"50% off (now) +tax"}\n'})
check(#m == 1 and m[1].p == "50% off (now) +tax", "pattern chars survive plain LF search")
-- on_error on malformed
local _, errs = collect({'{not json}\n'}, {on_error=true})
check(#errs == 1, "malformed line -> on_error called once")
-- silent when on_error omitted (no throw)
local ok = pcall(function() collect({'{also not json}\n'}) end)
check(ok, "malformed line with no on_error -> silent (no throw)")
-- reset clears buffer
do
  local msgs = {}
  local rx = jreader.new(function(mm) msgs[#msgs+1]=mm end)
  rx:feed('partial-no-newline-yet')
  rx:reset()
  rx:flush()
  check(#msgs == 0, "reset() clears the buffer (flush emits nothing)")
end

if fails > 0 then io.stderr:write(fails .. " check(s) failed\n"); vim.cmd("cquit 1") end
io.stdout:write("SMOKE_PASS\n")
```

```lua
-- === plugin/tests/jsonlreader_spec.lua — the spec (covers every Success Criterion) ===
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/jsonlreader_spec.lua")'
local jreader = require("pi-editor.jsonlreader")

describe("pi-editor.jsonlreader", function()
  local LS = string.char(0xE2, 0x80, 0xA8)  -- U+2028 (string.char for explicit byte control — GOTCHA 7)
  local PS = string.char(0xE2, 0x80, 0xA9)  -- U+2029

  local function reader(feeds, opts)
    opts = opts or {}
    local msgs, errs = {}, {}
    local rx = jreader.new(
      function(m) msgs[#msgs+1] = m end,
      opts.on_error and function(l, e) errs[#errs+1] = { line = l, err = e } end or nil)
    for _, f in ipairs(feeds) do rx:feed(f) end
    if opts.flush then rx:flush() end
    return msgs, errs, rx
  end

  it("exposes new/feed/flush/reset", function()
    local rx = jreader.new(function() end)
    assert.are.equals("function", type(rx.feed))
    assert.are.equals("function", type(rx.flush))
    assert.are.equals("function", type(rx.reset))
  end)

  it("decodes a single complete line", function()
    local m = reader({'{"a":1}\n'})
    assert.are.same({{ a = 1 }}, m)
  end)

  it("drains multiple records in one chunk (drain loop)", function()
    local m = reader({'{"a":1}\n{"b":2}\n'})
    assert.are.same({{ a = 1 }, { b = 2 }}, m)
  end)

  it("buffers a partial line split across chunks", function()
    local m = reader({'{"x":"', 'val"}\n'})
    assert.are.same({{ x = "val" }}, m)
  end)

  it("strips a trailing \\r on CRLF-delimited input", function()
    local m = reader({'{"a":1}\r\n{"b":2}\r\n'})
    assert.are.same({{ a = 1 }, { b = 2 }}, m)
    for _, mm in ipairs(m) do assert.is_nil(mm["\r"]) end
  end)

  it("flush emits a final line lacking a trailing \\n", function()
    local m = reader({'{"final":true}'}, { flush = true })
    assert.are.same({{ final = true }}, m)
  end)

  it("flush is a no-op on an empty buffer", function()
    local m = reader({""}, { flush = true })
    assert.are.same({}, m)
  end)

  it("reassembles a multibyte char split across chunks (byte-safe, no StringDecoder)", function()
    -- feed1 ends mid-€ (E2 82, NO closing quote yet); feed2 supplies AC + "} + \n. The euro is split
    -- across the two feeds exactly the way the OS can split a socket chunk.
    local m = reader({'{"e":"' .. string.char(0xE2, 0x82), string.char(0xAC) .. '"}\n'})
    assert.are.same({{ e = "€" }}, m)
  end)

  it("preserves U+2028/U+2029 inside a value (LF-only split, ONE record)", function()
    local m = reader({'{"t":"a' .. LS .. 'b' .. PS .. 'c"}\n'})
    assert.are.equals(1, #m)
    assert.are.equals("a" .. LS .. "b" .. PS .. "c", m[1].t)
  end)

  it("emits nothing and does not throw on empty input", function()
    local m = reader({""})
    assert.are.same({}, m)
  end)

  it("skips blank lines (does not decode them)", function()
    local m = reader({'\n\n{"a":1}\n\n'})
    assert.are.same({{ a = 1 }}, m)
  end)

  it("survives Lua pattern chars in values via plain LF search", function()
    local m = reader({'{"p":"50% off (now) +tax"}\n'})
    assert.are.same({{ p = "50% off (now) +tax" }}, m)
  end)

  it("calls on_error on a malformed line and does NOT call on_message", function()
    local m, errs = reader({'{not json}\n'}, { on_error = true })
    assert.are.same({}, m)
    assert.are.equals(1, #errs)
    assert.are.equals("{not json}", errs[1].line)
    -- Do NOT assert a specific decode-error substring: vim.json.decode's message varies by input
    -- ("Expected value but found T_END" for ""; "Expected object key string but found invalid token"
    -- for "{not json}" — both LIVE-VERIFIED). Just assert it is a non-nil string.
    assert.are.equals("string", type(errs[1].err))
    assert.is_not_nil(errs[1].err)
  end)

  it("is silent (no throw) on a malformed line when on_error is omitted", function()
    assert.has_no.errors(function() reader({'{also not json}\n'}) end)
  end)

  it("never throws out of feed/flush/reset", function()
    assert.has_no.errors(function()
      local rx = jreader.new(function() end)
      rx:feed('{"a":1}\n{bad\n{"b":2}\n')
      rx:flush()
      rx:reset()
    end)
  end)

  it("reset() clears the buffer so a later flush emits nothing", function()
    local m, _, rx = reader({'partial-no-newline-yet'})
    rx:reset()
    rx:flush()
    assert.are.same({}, m)
  end)

  it("two reader instances are independent (no shared module state)", function()
    local m1, m2 = {}, {}
    local r1 = jreader.new(function(mm) m1[#m1+1] = mm end)
    local r2 = jreader.new(function(mm) m2[#m2+1] = mm end)
    r1:feed('{"only":"r1"}\n')
    assert.are.same({{ only = "r1" }}, m1)
    assert.are.same({}, m2)   -- r2 untouched
  end)
end)
```

### Integration Points

```yaml
MODULE SURFACE EXPOSED (the forward contract S24 consumes):
  - require("pi-editor.jsonlreader").new(on_message[, on_error]) -> reader
  - reader:feed(chunk)        -- call from pipe:read_start's data branch
  - reader:flush()            -- call from pipe:read_start's EOF branch (data==nil, err==nil)
  - reader:reset()            -- call on reconnect / before re-use

CONSUMER (S24 bridge.lua — does NOT exist yet; this PRP only establishes the contract):
  pipe:read_start(function(err, chunk)
    if err then ... silent-degrade ... return end       -- socket error -> S24/S39
    if chunk == nil then rx:flush(); return end          -- EOF -> final line + teardown (S38)
    rx:feed(chunk)                                       -- frame + decode -> on_message(table)
  end)
  The on_message callback (S26) dispatches by msg.method/msg.id, correlates responses, drops stale
  ids. Any nvim-API work in on_message is the consumer's responsibility to vim.schedule (GOTCHA 5).

NO DATABASE / NO NETWORK / NO CONFIG / NO EXISTING-FILE EDITS. The module is pure (string +
vim.json). It has NO side effects beyond invoking the caller's on_message/on_error callbacks.
```

## Validation Loop

> **Run all commands from the REPO ROOT** (`/home/dustin/projects/pi-nvim-bridge`).
> The plugin root is `$(pwd)/plugin`. **Every Lua primitive + luv behavior the reader relies on is
> LIVE-VERIFIED** on Neovim 0.12.4 (see `research/notes.md`). NOTE: `nvim --headless --clean -u NORC`
> prints a benign `Error in .../syntax/syntax.vim: E216: No such group or event: filetypedetect
> BufRead` (an nvim filetype/syntax init artifact, NOT from our code; exit stays 0). Judge pass/fail
> by our markers (`SMOKE_PASS`, the plenary `Success:`/`Failed:` line) and `$?`, not that warning.

### Level 1: Syntax & Load (Immediate Feedback — dependency-free, no plenary)

```bash
# 1a. Smoke test via the deliverable plugin/tests/jsonlreader_smoke.lua (plenary-FREE fast feedback).
#     Exercises every framing+decode path: single line, drain loop, buffering, CRLF, flush final-line,
#     multibyte split, U+2028/U+2029 preserved, empty input, blank-skip, pattern chars, on_error,
#     silent-no-throw, reset. NO :lua <<HEREDOC (GOTCHA inherited from S19 #10). Run from REPO ROOT.
nvim --headless --clean -u NORC +"luafile plugin/tests/jsonlreader_smoke.lua" +qa
echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
```

```bash
# 1b. (Optional, only if installed) Lua lint/format. NOT a hard gate (inherited S19 GOTCHA #8).
command -v selene >/dev/null && selene -q plugin/lua/pi-editor/jsonlreader.lua plugin/tests/jsonlreader_smoke.lua || echo "selene not installed (skipped; optional)"
command -v stylua >/dev/null && stylua --check plugin/lua/pi-editor/jsonlreader.lua plugin/tests/jsonlreader_smoke.lua || echo "stylua not installed (skipped; optional)"
```

### Level 2: Unit Tests (plenary spec)

```bash
# 2a. In-process plenary run (reuses the S19 minimal_init.lua — puts plugin/ on rtp + plenary on rtp).
cd plugin
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/jsonlreader_spec.lua")'
echo "exit=$?   # 0 = all pass (16 it blocks)"
cd ..
```

```bash
# 2b. NON-REGRESSION — the S19 + S20 + S21 + S22 suites MUST still pass (S23 touches NO existing file).
cd plugin
for s in init_spec shim_spec activate_spec ftplugin_spec; do
  nvim --headless --clean -u tests/minimal_init.lua -c "lua require('plenary.busted').run('tests/$s.lua')"
  echo "$s exit=$?"
done
cd ..
# Expected: init_spec=0 (13), shim_spec=0 (6), activate_spec=0 (9), ftplugin_spec=0 (13).
```

### Level 3: Integration (wire the reader into a REAL luv socket — proves the framing under true chunking)

```bash
# 3a. Real-socket framing proof. Spin a luv unix-socket server in nvim, write fragmented JSONL from a
#     client across MULTIPLE write() calls (mirroring the LIVE-VERIFIED probe: 4 writes -> 2 chunks),
#     feed every server read_start chunk into a jsonlreader, and assert the decoded messages are
#     correct + in order. This proves the reader survives ARBITRARY OS chunk coalescing (the exact
#     failure mode a naïve "decode every chunk" impl hits). Written to a temp file + :luafile.
cat > /tmp/s23_integration.lua <<'LUA'
local uv = vim.uv
local sockpath = "/tmp/s23-it-" .. os.time() .. ".sock"; os.remove(sockpath)
local jreader = require("pi-editor.jsonlreader")

local got = {}
local rx = jreader.new(function(m) got[#got+1] = m end)

local srv = uv.new_pipe(false)
srv:bind(sockpath)
srv:listen(128, function(err)
  assert(not err, err)
  local conn = uv.new_pipe(false)
  srv:accept(conn)
  conn:read_start(function(rerr, data)
    if rerr then return end
    if data == nil then rx:flush(); conn:close(); srv:close(); os.remove(sockpath); return end
    rx:feed(data)   -- real chunk -> reader
  end)
end)

local client = uv.new_pipe(false)
client:connect(sockpath, function(err)
  assert(not err, err)
  -- 4 fragmented writes (server will coalesce into ~2 chunks — LIVE-VERIFIED pattern)
  client:write('{"jsonrpc":"2.0","id":"1","result":{"a":1}}\n{"partial":"')
  client:write(string.char(0xE2, 0x82))   -- split € mid-char across writes
  vim.defer_fn(function()
    client:write(string.char(0xAC) .. '"}\r\n')                         -- CRLF + completes €
    client:write('{"jsonrpc":"2.0","method":"commandsChanged"}')        -- final line, NO trailing \n
    vim.defer_fn(function()
      client:shutdown(function()
        client:close()
        vim.defer_fn(function()
          io.stdout:write("INTEGRATION got=" .. #got .. " msgs\n")
          for i, m in ipairs(got) do io.stdout:write("  ["..i.."] "..vim.inspect(m):gsub("\n"," ").."\n") end
          local ok = #got == 3 and got[1].id == "1" and got[1].result.a == 1
                    and got[2].partial == "€" and got[3].method == "commandsChanged"
          io.stdout:write(ok and "INTEGRATION_PASS\n" or "INTEGRATION_FAIL\n")
          if not ok then vim.cmd("cquit 1") end
        end, 30)
      end)
    end, 30)
  end, 30)
end)
LUA
PLUGIN_ROOT="$(pwd)/plugin"
nvim --headless --clean -u NORC --cmd "let &runtimepath=&runtimepath.',$PLUGIN_ROOT'" \
  +"luafile /tmp/s23_integration.lua" +"lua vim.wait(800)" +qa 2>&1 | grep -v 'E216\|filetypedetect'
# Expected: INTEGRATION got=3 msgs ... INTEGRATION_PASS  (3 records, in order, € reassembled,
#   CRLF tolerated, final-line-via-flush emitted, across arbitrary real-socket chunking).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. U+2028/U+2029 byte-safety stress (PRD §5.2 compliance). Build a JSONL stream containing literal
#     LINE/PARAGRAPH separators INSIDE string values and assert they survive as ONE record each (never
#     split by the reader). This is the PRD §5.2 "do not use readers that split on U+2028/U+2029" gate.
nvim --headless --clean -u NORC --cmd "let &runtimepath=&runtimepath.',$(pwd)/plugin'" +"lua
  local LS = string.char(0xE2,0x80,0xA8)  -- U+2028
  local PS = string.char(0xE2,0x80,0xA9)  -- U+2029
  local jreader = require('pi-editor.jsonlreader')
  local got = {}
  local rx = jreader.new(function(m) got[#got+1] = m end)
  rx:feed('{\"a\":\"x'..LS..'y'..PS..'z\"}\n')          -- one record, separators in a value
  rx:feed('{\"b\":\"1\"}\n{\"c\":\"2'..LS..'\"}\n')      -- two records, 2nd has a separator
  assert(#got == 3, 'expected 3 records, got '..#got)
  assert(got[1].a == 'x'..LS..'y'..PS..'z', 'U+2028/U+2029 must be preserved in value 1')
  assert(got[3].c == '2'..LS, 'U+2028 must be preserved in value 3')
  io.stdout:write('U2028_PASS\n')
" +qa 2>&1 | grep -v 'E216\|filetypedetect'
# Expected: U2028_PASS  (no record split by a separator; separators preserved verbatim).
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully (Level 1 smoke `SMOKE_PASS`; Level 2 spec exit 0;
      Level 3 `INTEGRATION_PASS`; Level 4 `U2028_PASS`).
- [ ] plenary suite: `cd plugin && nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/jsonlreader_spec.lua")'` exits 0.
- [ ] No lint regressions if selene/stylua are installed (optional; not a hard gate).

### Feature Validation

- [ ] All success criteria from "What" section met (single line, drain loop, buffering, CRLF,
      flush final-line, multibyte split, U+2028/U+2029 preserved, empty/blank handling, plain
      search, on_error + silent, reset, no-throw, instance independence).
- [ ] Manual framing proof successful: the Level-3 real-socket integration (4 fragmented writes →
      correct in-order decode with € reassembled + CRLF tolerated + final-line-via-flush).
- [ ] Edge cases handled gracefully: empty input (no-op), blank lines (skipped), malformed line
      (on_error or silent, never thrown), multibyte split (reassembled), EOF (flush).
- [ ] The `new`/`feed`/`flush`/`reset` forward contract is exactly what S24 (`bridge.lua`) will
      consume (PRD §7.3 skeleton).

### Code Quality Validation

- [ ] Follows existing codebase patterns: `local M` / `return M` module convention, [Mode A] LuaCATS
      docstrings (matching `init.lua` S19), standalone smoke + plenary spec two-file test convention
      (matching S20/S21/S22).
- [ ] File placement matches the desired codebase tree (`plugin/lua/pi-editor/jsonlreader.lua`).
- [ ] Anti-patterns avoided (see below): no `StringDecoder` cargo-cult, no plain-less `string.find`,
      no decode of blank lines, no throw out of feed/flush/reset, no nvim API calls, no module state.
- [ ] No new runtime dependencies (Node builtins analog: only `string.*` + `vim.json`, both built in).

### Documentation & Deployment

- [ ] [Mode A] header comment documents: purpose, TS-mirror lineage, byte-safe-concat simplification,
      decode-in-reader divergence + why, synchronous on_message + consumer-schedules note, scope.
- [ ] Per-method LuaCATS docstrings (`new`/`feed`/`flush`/`reset`) with `@param`/`@return`/`@class`.
- [ ] No new environment variables / config / files beyond the 3 deliverables.

---

## Anti-Patterns to Avoid

- ❌ Don't add a UTF-8 / char decoder (the TS `StringDecoder` has no Lua analog and none is needed —
  Lua `..`/`string.*` are byte operations; GOTCHA 1). Cargo-culting one INTRODUCES a bug.
- ❌ Don't call `string.find` without the `plain=true` 4th arg (pattern chars in JSON values break the
  split; GOTCHA 3).
- ❌ Don't `vim.json.decode` a blank/empty line (it throws; skip blanks; GOTCHA 4).
- ❌ Don't let `feed`/`flush`/`reset` throw (a throw escapes the luv callback; pcall every decode;
  GOTCHA 6).
- ❌ Don't call any `vim.api.*` from the reader (it must be safe to run in a luv callback; the consumer
  schedules nvim work; GOTCHA 5).
- ❌ Don't share `buffer` at module level (each reader instance owns its own; two sockets → two readers).
- ❌ Don't decode only the FIRST line of a chunk (drain ALL complete lines; GOTCHA 9).
- ❌ Don't skip `flush()` (the final-line-without-`\n` case is real — servers may not trailing-newline
  their last record; GOTCHA 10 / TS `onEnd`).
- ❌ Don't reimplement what the DONE `extension/jsonl-reader.ts` already proved — mirror its framing
  rules; diverge ONLY on the two documented, justified points (decode-in-reader, blank-skip).