# S23 Research Notes — `jsonlreader.lua` (buffer chunks, split on `\n`, decode each line)

LIVE-VERIFIED evidence (Neovim 0.12.4 headless `--clean -u NORC`) for every API + behavior the
PRP cites. Transcripts are the probe scripts + their stdout (see bottom). This file is the
authoritative companion to `P2M5T14S23/PRP.md` — every "LIVE-VERIFIED" claim there traces here.

---

## 1. The authoritative mirror — extension-side `jsonl-reader.ts` (DONE, P1.M2.T4.S7)

`extension/jsonl-reader.ts` is the proven, unit-tested framing half of the bridge. S23 is its
**Lua-side twin**. Read it in full; it encodes every framing rule the Lua reader must honor.

**Framing rules (PRD §5.2):**
- Exactly one JSON object per line, delimited by `\n` ONLY.
- An optional trailing `\r` is stripped (CRLF tolerance).
- Do NOT split on U+2028 / U+2029 — those are valid INSIDE JSON strings and would corrupt
  payloads. (`JSON.stringify` / `vim.json.encode` do not escape them.)
- Both sides must buffer partial lines and decode on `\n`.

**TS design decisions the Lua port inherits unchanged:**
- `indexOf("\n")` plain LF search — Lua equivalent `string.find(s, "\n", 1, true)` (plain=true).
- Drain loop: process ALL complete lines in a chunk, leave the trailing partial buffered.
- `onEnd`: flush a final line lacking a trailing `\n`. Lua equivalent = `reader:flush()`.
- Detach on close/error to avoid a listener leak — Lua equivalent = drop the reader reference +
  `reader:reset()` (cheap, for reconnect/test isolation).

**TS design decision the Lua port DELIBERATELY DIVERGES from (documented in PRP §Known Gotchas):**
- TS reader emits RAW string lines (no `JSON.parse`); S8 connection handler parses + dispatches.
- Lua reader **DECODES each line** (`vim.json.decode`) and emits a Lua TABLE. WHY: the task title
  ("…decode each line") and PRD §7.3 skeleton (`on_event(msg)` receives a decoded `msg`) both
  require it; AND the Lua side is a CLIENT that cannot send a JSON-RPC `-32700` back, so a
  decode failure must be handled LOCALLY (pcall + optional `on_error`). This collapses S7+S8's
  two-step into one reader for the client side, which is simpler and matches the skeleton.

---

## 2. The consumer contract — PRD §7.3 skeleton (bridge.lua / S24)

```lua
local rx = require("pi-editor.jsonlreader").new(function(msg) on_event(msg) end)
pipe:read_start(function(err, chunk)
  if err or not chunk then return end   -- err/EOF handled by bridge.lua
  rx:feed(chunk)                         -- splits on \n, vim.json.decode each line
end)
```

So the module surface S23 MUST expose for S24:
- `require("pi-editor.jsonlreader").new(on_message[, on_error]) -> reader`
- `reader:feed(chunk_string)` — append + drain complete lines + decode + call `on_message(table)`.
- `reader:flush()` — on EOF, emit a buffered final line lacking `\n` (mirrors TS `onEnd`).
- `reader:reset()` — clear the internal buffer (reconnect / test isolation; cheap, optional-but-useful).

`on_message(table)` is called SYNCHRONOUSLY from `feed`. The reader does NO nvim API calls, so it
is safe to run directly inside the luv `read_start` callback (which fires on the libuv loop). The
**consumer** (bridge.lua/S26) is responsible for `vim.schedule`-wrapping any nvim-API-touching
work it does inside `on_message` (standard luv→nvim rule; documented as an integration note).

---

## 3. LIVE-VERIFIED: luv `pipe:read_start` chunking is ARBITRARY (buffering is mandatory)

Probe (`/tmp/luv_probe.lua`, see §9) set up a unix-socket server+client. The client made FOUR
separate `write()` calls:
```
write('{"a":1}\n{"e":"')              -- 16 bytes (line1 complete + line2 prefix)
write(string.char(0xE2, 0x82))         -- euro prefix split mid-char (2 bytes)
...defer 40ms...
write(string.char(0xAC) .. '"}\r\n')   -- CRLF + completes euro (6 bytes)
write('{"final":true}')                -- final line NO trailing newline (14 bytes)
```
The **server** `read_start` callback fired **TWICE** — chunks of **16** and **19** bytes:
```
SERVER CHUNK len=16
SERVER CHUNK len=19
SERVER EOF: err=nil
```
i.e. the OS/libuv COALESCED four writes into two chunks arriving at arbitrary byte boundaries.
**Conclusion (LIVE-VERIFIED):** the reader CANNOT assume one chunk == one line (or even one
record). It MUST buffer partial lines across chunks and split purely on `\n`. A naïve
"decode every chunk" implementation would corrupt on the very first multi-write message.

**EOF signal (LIVE-VERIFIED):** when the peer half-closes (client `shutdown`+`close`), the
`read_start` callback fires with `data == nil, err == nil`. This is the EOF that triggers
`reader:flush()`. (A non-nil `err` with `data == nil` is a read ERROR — bridge.lua handles both;
the reader only needs `flush()` on clean EOF, and `flush()` is harmless on error.)

---

## 4. LIVE-VERIFIED: Lua string `..` is BYTE-SAFE → NO `StringDecoder` needed (key simplification)

The TS reader needs Node's `StringDecoder("utf8")` to reassemble a multi-byte UTF-8 char split
across two `Buffer` chunks (e.g. `€` = E2 82 AC delivered as `[E2 82]` then `[AC]`). **Lua needs
no such thing** — Lua strings are byte buffers (8-bit clean), so:

Probe assertion (LIVE-VERIFIED):
```lua
local b1 = string.char(0xE2, 0x82)      -- incomplete € prefix
local b2 = string.char(0xAC)             -- € suffix
local joined = b1 .. b2                  -- byte concatenation
local jok, jmsg = pcall(vim.json.decode, '{"e":"' .. joined .. '"}')
-- => split-multibyte concat: pcall=true e=€
```
Because `..`, `string.find(s,"\n",1,true)`, and `string.sub` are all BYTE operations, a split
multi-byte char in `self.buffer` is transparently reassembled when the next chunk arrives. The
COMPLETE line handed to `vim.json.decode` is always valid UTF-8 (assuming the server sent valid
UTF-8). `\n` (0x0A) never appears INSIDE a multi-byte UTF-8 sequence (continuation bytes are
0x80–0xBF, lead bytes 0xC0+), so byte-splitting on `\n` is inherently UTF-8-correct.

**This is the #1 implementation simplification vs the TS twin and the #1 cargo-cult trap.** An
implementer who reaches for a Lua "UTF-8 decoder" because the TS side has a `StringDecoder` would
ADD a bug (LuaJIT has no streaming UTF-8 decoder; naive `utf8.len`/`vim.str_utfindex` on a partial
char is WRONG). The PRP's §Known Gotchas calls this out explicitly: **do NOT add any char-decoder;
byte-buffer arithmetic is already correct.**

---

## 5. LIVE-VERIFIED: the byte-level primitives the reader uses

All verified in the probe (§9):
```lua
-- plain LF search (pattern OFF — must be plain so literal '%','.',etc. don't break it)
("ab\ncd\n"):find("\n", 1, true)        -- => 3   (byte index of first \n)
("ab\ncd\n"):sub(1, 3 - 1)              -- => "ab" (line before the \n)
("ab\ncd\n"):sub(3 + 1)                 -- => "cd\n" (remainder)

-- trailing \r strip (CRLF tolerance)
('{"c":1}\r'):sub(-1) == "\r"           -- => true
('{"c":1}\r'):sub(1, -2)                -- => '{"c":1}'   (drop the single trailing \r)

-- empty string decode THROWS (so blank lines must be SKIPPED, not decoded)
pcall(vim.json.decode, "")              -- => false, err "Expected value but found T_END at character 1"
```
**Decision (documented deviation from TS):** the TS reader emits EVERY complete line including
blank ones and lets S8's `JSON.parse("")` throw → `-32700` response. The Lua CLIENT cannot send a
`-32700`; a stray blank line from the trusted-local server should NOT be a hard error (silent-
degrade, PRD §11). So the Lua reader **SKIPS lines that are empty after `\r`-strip** and only
`pcall`s `vim.json.decode` on non-empty lines (failures → optional `on_error`, never thrown).

---

## 6. LIVE-VERIFIED: U+2028 / U+2029 do NOT corrupt LF-only splitting

PRD §5.2 + TS reader forbid splitting on U+2028 (LINE SEPARATOR) / U+2029 (PARAGRAPH SEPARATOR).
Their UTF-8 encodings:
- U+2028 = `E2 80 A8`
- U+2029 = `E2 80 A9`

**Neither byte sequence contains 0x0A (`\n`).** (0xA8 ≠ 0x0A, 0xA9 ≠ 0x0A.) Therefore a plain
`string.find(s, "\n", 1, true)` can NEVER split a U+2028/U+2029 char, even when they appear
literally inside a JSON string value (which `vim.json.encode`, like `JSON.stringify`, leaves
unescaped). So the Lua reader is automatically compliant — no special handling. The test
(`jsonlreader_spec.lua`) feeds a line containing literal U+2028/U+2029 and asserts it decodes to a
SINGLE message with the separators preserved.

**GOTCHA (test construction):** LuaJIT (Neovim's Lua, 5.1 semantics) does NOT support the `\u{2028}`
escape in string literals — that is Lua 5.3+. Construct the bytes explicitly:
`string.char(0xE2, 0x80, 0xA8)` for U+2028; `string.char(0xE2, 0x80, 0xA9)` for U+2029.

---

## 7. LIVE-VERIFIED: `vim.json.decode` throws on invalid input → pcall is mandatory

`vim.json.decode("{}")` → `{}`. `vim.json.decode("not json")` → throws. `vim.json.decode("")` →
throws (`Expected value but found T_END`). The reader MUST `pcall` every decode. On failure: call
the optional `on_error(line, err)` if provided; otherwise silent (the default — PRD §11 silent
degrade). The reader NEVER throws out of `feed`/`flush` (a throw would escape the luv
`read_start` callback and surface as a spurious error — bridge.lua's err path is for socket
errors, not reader-internal decode errors).

---

## 8. Test framework + conventions (mirrors S19/S20/S21/S22)

- **plenary.nvim** (`describe`/`it`/`assert.are.same`), run via
  `nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/NAME.lua")'`
  — `tests/minimal_init.lua` (S19) already puts `plugin/` on rtp + plenary on rtp. REUSED unchanged.
- **Standalone smoke** (plenary-FREE, `:luafile`-sourced): the Level-1 gate pattern used by every
  predecessor (`shim_smoke`, `activate_smoke`, `ftplugin_smoke`). Prints `SMOKE_PASS` / `cquit 1`.
- **[Mode A] docstrings** (LuaCATS `---@class`/`---@field`/`---@param`/`---@return`) — the convention
  established in `init.lua` (S19). Applied throughout `jsonlreader.lua`.
- **Non-regression**: S19 `init_spec` (13), S20 `shim_spec` (6), S21 `activate_spec` (9),
  S22 `ftplugin_spec` (13) must STILL pass — S23 adds ONE new module + 2 test files, touches none.
- `nvim --headless --clean -u NORC` prints a benign `E216: No such group or event: filetypedetect
  BufRead` (nvim filetype/syntax init artifact, NOT our code; exit stays 0). Judge by markers.

---

## 9. Probe transcript (the LIVE-VERIFIED evidence above)

`/tmp/luv_probe.lua` (run: `nvim --headless --clean -u NORC +"luafile /tmp/luv_probe.lua" +"lua vim.wait(500)" +qa`):

```
split-multibyte concat: pcall=true e=€
find \n plain: 3
sub on nl: [ab]
decode '': pcall=false err=Expected value but found T_END at character 1
last char is \r: true
stripped: [{"c":1}]
SERVER CHUNK len=16
SERVER CHUNK len=19
SERVER EOF: err=nil
exit=0
```
Confirms: byte-safe concat of split multibyte (€ reassembled); plain `\n` find; `\r` strip;
empty-string decode throws; luv chunking is arbitrary (4 writes → 2 chunks); EOF = `data==nil,
err==nil`.
---

## 10. REFERENCE-IMPL VERIFICATION (all 4 validation levels green against the PRP's verbatim code)

The reference implementation + both test files were EXTRACTED DIRECTLY from `PRP.md`'s ```` ```lua ````
fences (via a python regex) and run on Neovim 0.12.4 + plenary.nvim. **All four validation levels
passed with zero edits** — i.e. the PRP as written is self-consistent and an implementer can copy the
code verbatim. This section records the corrections that were needed to reach that state (the PRP
text already reflects them) so the lineage is auditable.

| Level | Command (from the PRP) | Result |
|-------|------------------------|--------|
| L1 smoke | `nvim --headless --clean -u NORC +"luafile plugin/tests/jsonlreader_smoke.lua" +qa` | `SMOKE_PASS`, exit 0 |
| L2 spec  | `cd plugin && nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/jsonlreader_spec.lua")'` | `Success: 17, Failed: 0`, exit 0 |
| L3 integration | 4 fragmented `pipe:write`s → luv server `read_start` → `rx:feed(chunk)` | `INTEGRATION got=3 msgs` then `INTEGRATION_PASS` (€ reassembled, CRLF tolerated, final-line-via-flush emitted) |
| L4 U+2028 stress | feed lines with literal U+2028/U+2029 in values | `U2028_PASS` (3 records, separators preserved) |

### Corrections discovered during verification (all already folded into the PRP)

1. **GOTCHA 11 — `setmetatable({…}, {__index = M})` in `M.new`.** The first reference draft returned a
   bare `{buffer=…, on_message=…}` table with NO metatable. Because `feed`/`flush`/`reset` live on the
   MODULE (`M.feed`), `rx:feed(chunk)` resolved `feed` on the instance, found `nil`, and THREW
   `attempt to call method 'feed' (a nil value)` — the very first smoke check. FIX: wrap the state
   table in `setmetatable({…}, {__index = M})` so `rx:feed(chunk)` → `M.feed(rx, chunk)` (the `:`
   passes `rx` as `self`). Standard Lua module-OOP; this is now GOTCHA 11 + embedded in `M.new`.

2. **GOTCHA 12 — `collect()`/`reader()` test helpers take a TABLE of feeds.** A draft test called
   `collect('{also not json}\n')` (bare string). LuaJIT's `ipairs(string)` THROWS
   `bad argument #1 to 'ipairs' (table expected, got string)` — LIVE-VERIFIED — so the helper crashed
   (not the reader). FIX: always wrap feeds in a table: `collect({'{also not json}\n'})`. Now GOTCHA 12.

3. **Multibyte-split test stray quote.** A draft fed `{"e":"` + E2 82 + `"` (the trailing `"`
   PREMATURELY CLOSED the JSON string before the split char). FIX: feed `{"e":"` + E2 82 (NO quote),
   then AC + `"}` + `\n` — the euro is split across the two feeds exactly as the OS can split a chunk.
   Applied to BOTH the smoke and the spec.

4. **`on_error` assertion was too specific.** A draft spec asserted `errs[1].err:find("Expected
   value")`. But `vim.json.decode`'s message VARIES by input — LIVE-VERIFIED: `""` →
   `"Expected value but found T_END at character 1"`; `"{not json}"` →
   `"Expected object key string but found invalid token at character 2"`. FIX: assert only that the
   err is a non-nil string (`type(errs[1].err) == "string"`), not a specific substring.

5. **GOTCHA 7 CORRECTION — LuaJIT DOES support `\u{XXXX}`.** A draft claimed LuaJIT lacks the `\u{}`
   escape (a Lua 5.3+ feature). WRONG: LuaJIT extends Lua 5.1 with `\u{}` support — LIVE-VERIFIED
   `'\u{20ac}\u{2028}'` yields `E2 82 AC E2 80 A8`. The PRP's GOTCHA 7 now says: `\u{}` IS available,
   but `string.char` is clearer for byte-level / split-sequence construction. The reference tests use
   `string.char` to make the byte splitting explicit (not because `\u{}` is unavailable).

**Net effect:** the PRP's reference code + test code, copied verbatim, pass all 4 validation levels.
An implementer who copies the fences and runs the Validation Loop commands gets green on the first
pass. (Verification transcript: this section + the `/tmp/s23final/` extract run, 2025.)
