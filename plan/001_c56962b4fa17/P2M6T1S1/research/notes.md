# Research Notes — P2.M9.T23.S38 (PRP path P2M6T1S1)
## VimLeavePre/ExitPre — autosave if modified, send bye, close connection

Logical id **S38** ("on_exit body"). PRP output dir `P2M6T1S1`. Consumes the bridge
client seam established by **S22** (`plugin/ftplugin/pi-prompt.lua`) + **S24–S27**
(`plugin/lua/pi-editor/bridge.lua`).

---

## 1. Codebase facts (LIVE-READ, not assumed)

### 1a. The ftplugin ALREADY WIRES VimLeavePre/ExitPre → `bridge.on_exit(buf)`
`plugin/ftplugin/pi-prompt.lua` (DONE by S22) registers, gated on
`config.autosave_on_exit ~= false` (default TRUE — `init.lua` `M.defaults`):

```lua
if config.autosave_on_exit ~= false then
  for _, ev in ipairs({ "VimLeavePre", "ExitPre" }) do
    vim.api.nvim_create_autocmd(ev, {
      group = group, buffer = buf,
      desc = "pi-editor: autosave + bridge teardown on " .. ev,
      callback = function() dispatch("pi-editor.bridge", "on_exit", buf) end,
    })
  end
end
```

So **S38's PRIMARY job is to IMPLEMENT `M.on_exit(buf)`** in `bridge.lua`. The wiring
exists; the body does not. S22 left it as a no-op-safe forward contract (lines 425-426,
501-503 of the S22 PRP; the ftplugin header comment `FORWARD CONTRACT B`).

### 1b. The ftplugin does NOT register BufWriteCmd
S22 deliberately did NOT wire `BufWriteCmd` (it only documents that `BufWritePre` is
intentionally not overridden — "the pi temp file is writable, so the default `:w` works").
PRD §7.6, however, LISTS `BufWriteCmd` in the autosave group, and the S38 CONTRACT requires
it ("Also implement BufWriteCmd handler that writes to the temp file"). → **S38 must ADD the
BufWriteCmd wiring** to the ftplugin (additive edit; the existing `ftplugin_spec.lua` does
NOT assert BufWriteCmd absence, so the edit is non-breaking — verified by reading the spec).

### 1c. The `dispatch()` helper (ftplugin) — the contract for module functions
```lua
local function dispatch(modname, fnname, b)
  local ok, mod = pcall(require, modname)
  if not ok or type(mod) ~= "table" then return false end
  local fn = mod[fnname]
  if type(fn) ~= "function" then return false end
  local pok, handled = pcall(fn, b)
  return pok and handled == true      -- true ONLY if fn returned truthy
end
```
→ `bridge.on_write(buf)` MUST return **truthy** (`true`) when it handled the write, else the
ftplugin's BufWriteCmd callback falls through to its fallback. `bridge.on_exit(buf)`'s return
value is ignored by the exit autocmd (fire-and-forget) — but it must NEVER THROW (the pcall
in `dispatch` swallows a throw, but on_exit is ALSO pcall'd internally per the contract, and
VimLeavePre must never abort exit).

### 1d. Config resolution pattern
`require("pi-editor").config` (set by `setup()`; `activate()` self-sets it via
`if M.config == nil then M.setup({}) end`). Modules read it defensively:
`local cfg = require("pi-editor").config or require("pi-editor").defaults`.
`autosave_on_exit` default `true` (init.lua `M.defaults`).

### 1e. Test harness (reused unchanged)
`plugin/tests/minimal_init.lua` (S19) prepends plenary + `plugin/` to rtp. Run specs:
```
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/<spec>.lua")'
```
Smoke (Level-1, plenary-FREE): `nvim --headless --clean -u NORC +"luafile tests/<smoke>.lua" +qa`.
Plenary installed at `/home/dustin/.local/share/nvim/lazy/plenary.nvim`. nvim **0.12.4**.

### 1f. `bridge.lua` EXISTS — S24 LANDED during this planning session (READ VERBATIM)
`plugin/lua/pi-editor/bridge.lua` is present (created by the parallel S24 work; `git status`
showed it + `bridge_spec.lua`/`bridge_smoke.lua` as new untracked files). I READ it: it ships
`M.connect(path,on_ready,on_event,on_close)`, `M.send(obj)`, `M.close()`, `M.is_connected()`,
and a STUB `M.on_exit(buf)` (body = `M.close()` only; comment "autosave is S38's job"). So
**S38 EXTENDS the on_exit stub** (adds save+bye before the existing close) and ADDS
`save_buffer`/`M.on_write` — it does NOT create the module and does NOT rename/clobber S24's
seams. Dependency note: S24 landed; S25 (handshake) / S26 (id correlation) / S27 (notif
handler) are still PLANNED, but S38 needs NONE of them — it only uses S24's send/close/is_connected.

---

## 2. bridge.lua seam contract S38 depends on — READ VERBATIM from S24 (LANDED in parallel)

**UPDATE (post-S24-landed):** `plugin/lua/pi-editor/bridge.lua` now EXISTS (S24 landed during
this planning session). I READ it verbatim. The seam names below are S24's REAL API (NOT the
`notify`/`disconnect` I first assumed — corrected). S38 must REUSE these, not invent new ones.

| Seam (REAL) | Signature (from bridge.lua) | S38 usage |
|---|---|---|
| `M.send(obj)` | `-> boolean` (queued); writes `vim.json.encode(obj).."\n"` → `pipe:write(data, cb)`; ALREADY gated on `state.connected`/`state.closed` (returns false if not connected); the cb routes `werr` (EPIPE) → `M.close()`. ASYNC. | `M.send({jsonrpc="2.0",method="bye",params={}})` — NO `id` ⇒ a notification |
| `M.close()` | idempotent teardown: sets `state.closed=true` FIRST (GOTCHA 2 double-close guard), `state.connected=false`, `pipe:close()` (pcall'd), `state.rx:reset()`, clears state.* | called AFTER bye; ALWAYS (harmless no-op if never connected) |
| `M.is_connected()` | `-> boolean` = `state.connected and not state.closed` (read-only accessor) | gate the bye send |
| `M.on_exit(buf)` | **S24 STUB** (line ~226): body is JUST `M.close()`. Comment: "autosave is S38's job, dispatched separately". | S38 EXTENDS this stub (save+bye BEFORE the existing close) |

**bye-vs-close RACE (important):** `M.send` is async (`pipe:write + cb`). Calling `M.close()`
immediately after may ABORT the in-flight bye write (libuv cancels pending writes on close).
ACCEPTABLE: bye is best-effort; the server cleans up on EOF when the pipe closes
(connection.ts 'close' handler detaches the reader). The AUTOSAVE (`writefile`) is SYNCHRONOUS
and unaffected — it is the load-bearing part. Never await a bye response (client is exiting).

Tests MOCK `M.send`/`M.close`/`M.is_connected` by overriding the module-table fields before
calling `on_exit` (standard Lua override — same isolation pattern as the extension's
`__reset*ForTest` seams). NOTE: overriding M.close means S24's real close won't run in the unit
test — intended (we test on_exit's ORCHESTRATION; S24's close is covered by bridge_spec).

---

## 3. The `bye` method — server-side handling (LIVE-READ of `extension/connection.ts`)

PRD §5.4: `bye | C→S | {} | {ok:true} *(graceful disconnect)*`. Server dispatch
(`handleLine`, connection.ts:269-380) splits on whether `id` is a string:

- **REQUEST** (string `id`): handler runs → `sendResponse({ok:true})` → THEN checks
  `state.closeAfterResponse` (set by the bye handler, S14) → `sock.end()` (graceful FIN).
  So a bye REQUEST makes the SERVER half-close. ✓
- **NOTIFICATION** (no `id`): handler runs (sets `closeAfterResponse`, returns `{ok:true}`
  which is discarded) → the notification branch does NOT call `sendResponse` and does NOT
  check `closeAfterResponse` → **server does NOT close**; it just returns (logs on throw).

**Implication for on_exit (client, during VimLeavePre):** we are EXITING — we must not block
on a response, and the client closing its own pipe sends an EOF that Node's socket `'end'`/
`'close'` handler cleans up server-side (the connection's reader detaches; the socket is
removed from the registry on close). So sending `bye` as a **NOTIFICATION** + closing the
client pipe is a clean, non-blocking graceful disconnect. This matches the S38 CONTRACT
wording ("send bye notification") and PRD §4 step 6 ("client closes after ack" — S14
documented this as the acceptable client-side-close path). Sending a REQUEST (with id) and
discarding the response is ALSO acceptable but adds id-bookkeeping for no exit-time benefit.
**DECISION: send bye as a NOTIFICATION via S24's `M.send({jsonrpc="2.0",method="bye",params={}})`**
(no `id` field). Then `M.close()`. Documented; trivially switchable. NOTE: S24's `send` is ASYNC
(`pipe:write`+cb) — calling `close()` right after MAY abort the in-flight bye write (libuv cancels
pending writes on close). ACCEPTABLE: bye is best-effort; EOF-on-close cleans up the server. The
autosave (`writefile`) is synchronous and unaffected.

---

## 4. LIVE-VERIFIED Neovim behaviors (nvim 0.12.4, `--headless --clean -u NORC`)

Script `/tmp/verify_exit.lua` (a real temp-file buffer, buftype=""). Results:

1. **BufWriteCmd does NOT recurse on `:write`.** A BufWriteCmd whose callback calls
   `vim.cmd("write")` fired EXACTLY ONCE (`BufWriteCmd_count=1`); the inner `:write`
   `pcall ok=true`; the file was written ("edited line"); `modified=false` after. nvim's
   event-recursion guard suppresses the re-fire. → a BufWriteCmd handler MAY safely call
   `:write` (it performs the default file write). `:noautocmd write` is the explicit form.
2. **`writefile` + `set modified=false` inside BufWriteCmd works** — wrote "writefile line",
   cleared modified. No autocmd interaction at all (writefile is a `vim.fn`, not `:write`).
3. **VimLeavePre fires headlessly**; `vim.cmd("silent! write")` inside it `pcall ok=true`
   and wrote the file ("vleavepre line").
4. **`nvim_exec_autocmds("VimLeavePre", {})` works headlessly** (`pcall ok=true`, handler
   `called=true`) — so tests SIMULATE exit by registering the autocmd then exec'ing it
   (exactly like the ftplugin_spec tests exec `TextChangedI`/`InsertEnter`).

→ save logic choice: a **`writefile` + `set modified=false`** helper is the most
deterministic (no BufWriteCmd coupling, no recursion question, fully under our control, no
'fileformat'/'endofline' surprises — predictable for pi's line-trimming parser which does
`.replace(/\n$/, "")`). The CONTRACT's `vim.cmd("write")` / `nvim_buf_call(buf, function()
vim.cmd("silent! write") end)` are equivalent-and-verified alternatives; we use writefile as
the single `save_buffer(buf)` primitive shared by BOTH `on_exit` and `on_write`, which keeps
the two handlers decoupled (on_exit calling `:write` would route THROUGH a registered
BufWriteCmd → on_write → confusing double-write; calling `save_buffer` directly avoids it).

---

## 5. Design decisions (locked)

- **`save_buffer(buf)`** (module-local helper): `writefile(nvim_buf_get_lines(buf,0,-1,false),
  nvim_buf_get_name(buf))` then `vim.bo[buf].modified=false`; pcall'd; `-> bool`. No-op +
  return false if the buffer has no name (`""`) — defensive.
- **`M.on_write(buf)`** (BufWriteCmd handler): `return save_buffer(buf)` (truthy ⇒ dispatch
  handled). Registered by the ftplugin edit (Option A below).
- **`M.on_exit(buf)`** (VimLeavePre/ExitPre handler — EXTENDS S24's close-only stub): the
  save+bye block is `pcall`'d (NEVER abort exit); `M.close()` runs AFTER (outside the pcall, so a
  throwing send can't skip teardown). Body: `pcall(function() ...if cfg.autosave_on_exit~=false and
  vim.bo[buf].modified then save_buffer(buf) end; if M.is_connected() then
  pcall(M.send,{jsonrpc="2.0",method="bye",params={}}) end end); M.close()`.
- **ftplugin BufWriteCmd wiring** (additive edit in the `autosave_on_exit ~= false` block):
  `callback = function() if not dispatch("pi-editor.bridge","on_write",buf) then
  pcall(vim.cmd,"noautocmd write") end end` — the `noautocmd write` fallback preserves `:w`
  if bridge.lua/on_write is ever absent (verified non-recursive). Gated on the same flag as
  the exit autocmds (PRD §7.6 groups them; when autosave is off, default `:w` still works).
- **[Mode A] docstrings** + a prominent `WARNING:` block comment about the lost-prompt risk
  (PRD §11) at the top of `on_exit`.

## 6. Test matrix (plenary/busted; mocks the 3 seams)
- on_exit modified+connected → save_buffer writes file, modified cleared, `M.send({method="bye"})`
  called once, `M.close()` called once, returns normally (no throw).
- on_exit unmodified+connected → NO write (file untouched); `send(bye)` STILL called + `close()`
  STILL called (teardown is independent of the save).
- on_exit modified+DISCONNECTED (`is_connected()==false`) → save_buffer writes; `send` NOT called;
  `close()` STILL called once (close is idempotent + harmless when never connected; on_exit always
  tears down).
- on_exit `autosave_on_exit=false` → NO write even if modified (config gate); `send(bye)`+`close()`
  still run if connected (teardown is independent of autosave). INTENT: bye/close ALWAYS run on
  exit to release the server connection — only the SAVE is gated.
- on_exit never throws: force `M.send` to throw → on_exit still returns normally AND `close()`
  still runs (close is outside the save/bye pcall).
- on_write writes the temp file + clears modified (via a real scratch buffer named to a
  temp path); returns true.
- ftplugin: a pi-prompt buffer has a BufWriteCmd autocmd in the "pi-editor" group by default;
  `:w` writes the file (integration: exec BufWriteCmd path); absent when autosave_on_exit=false.
- Non-regression: existing specs (init/shim/activate/ftplugin/jsonlreader) still pass.

## 7. Open intent resolution (documented in PRP)
bye+close runs on EVERY exit (connected) regardless of `autosave_on_exit` — only the SAVE is
gated. Rationale: `autosave_on_exit=false` means "don't auto-persist my edits"; it does NOT
mean "leak the server connection". The server connection is a resource that should always be
released. (If a reviewer disagrees, the gate is one line — but this is the defensible read.)