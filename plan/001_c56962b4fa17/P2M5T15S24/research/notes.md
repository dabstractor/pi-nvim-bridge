# research/notes.md — P2.M5.T15.S24 (bridge.lua connect/read/write)

LIVE-VERIFIED probe transcript on **Neovim 0.12.4** (`nvim --version` → `NVIM v0.12.4`),
Linux. Every luv behavior the S24 bridge client relies on was probed in a real `--headless`
nvim process with a real luv unix-socket server. Run via:
`nvim --headless --clean -u NORC +"luafile /tmp/<probe>.lua" +"lua vim.wait(N)" +qa`.

> [Mode A] header convention (matching the sibling `jsonlreader.lua` / S23): each finding
> carries the exact observed value so the PRP can cite LIVE-VERIFIED facts, not guesses.

---

## §0. vim.uv surface — all methods present (nvim 0.12.4)

```
vim.uv present: true
uv.new_pipe: function
new_pipe(false) type: userdata
p:connect   p:read_start   p:write   p:close   p:shutdown   p:is_closing
p:is_readable  p:is_writable   — all type=function
```
`vim.uv` IS `vim.loop` (0.10+ alias; identical bundled luv). Colón syntax `pipe:foo(args)` and
dot syntax `uv.foo(pipe, args)` are interchangeable; **colon is conventional**. `:help vim.uv`.

## §1. `pipe:connect(path, cb)` — SUCCESS path (probe1)

```lua
local srv = uv.new_pipe(false); srv:bind(path); srv:listen(128, acceptcb)
local client = uv.new_pipe(false)
client:connect(path, function(err) ... end)
```
- **cb receives exactly ONE arg `err`**: `err == nil` on success.
  OBSERVED: `client connect cb: err=nil`.
- **Async**: the cb fires later on the event loop (NOT synchronously from the `connect` call).
- **`is_closing()` before/after**: `false` on a live handle (OBSERVED), `true` after `close()`.
- Round-trip works: server `read_start` got the client's `write` payload; server `write` echo was
  read by client `read_start`. (See §3/§4.)
- **No throw** on the success path (pcall not required, but harmless).

## §2. `pipe:connect(path, cb)` — FAILURE paths (probe2)

CRITICAL FINDING — **luv connect errors are the BARE errno name string**, NOT `"<NAME>: msg"`:
| Condition | OBSERVED `err` |
|---|---|
| socket file does NOT exist (ENOENT) | `"ENOENT"` |
| path is a regular FILE, not a socket (ECONNREFUSED) | `"ECONNREFUSED"` |
| (no-permission path, EACCES — standard) | `"EACCES"` |

- `type(err) == "string"` (OBSERVED `T1 err type=string`).
- Failures are delivered via the **callback** (async), NOT thrown — pcall is not needed for a
  well-formed call, but wrap defensively in case of a programming error (closed handle, bad arg).
- This RESOLVES the "VERIFY exact wording" gap from the researcher brief: it is the bare errno
  token, e.g. `err == "ENOENT"`. Pattern-match with `err == "ENOENT"` or `err:match("^E")`.

## §3. `pipe:read_start(function(err, data))` — chunk / EOF / error (probe1, probe3, probe4)

- **cb signature: `(err, data)` — TWO args.**
  - **chunk available**: `err == nil`, `data == <byte string>` (length = byte count).
  - **EOF (peer closed write side)**: `err == nil` AND `data == nil`. ← canonical EOF test.
    OBSERVED (probe3, server closed its conn): `client read cb: rerr=nil data=nil` → `EOF confirmed`.
  - **read error**: `err == <string>`, `data == nil` (e.g. `ECONNRESET` — bare errno name, like §2).
- **`data` is RAW BYTES** — arbitrary chunk boundaries; you MUST buffer + split on `\n`
  (that is the DONE `jsonlreader` / S23 — bridge.lua feeds each chunk to `rx:feed(data)`).
- **jsonlreader (S23) integrates cleanly** (probe4): inside `read_start`'s data branch,
  `rx:feed(data)` → `on_message(decoded_table)`. A full request/response JSONL round-trip
  (client write → server jsonlreader decode → server write → client jsonlreader decode) was
  OBSERVED green: `server decoded request: method=ping id=r1` … `client decoded response: id=r1 ok=true`.
- Calling `read_start` on a CLOSED handle: **silent no-op** (probe3/T3: `pcall ok=true err=nil`),
  i.e. it does NOT throw in this luv build — but still guard with `is_closing()` (defense-in-depth,
  and libuv semantically forbids it).

## §4. `pipe:write(data, cb)` — success / EPIPE / queueing (probe1, probe3, probe4)

- **cb receives exactly ONE arg `err`**: `err == nil` on success. OBSERVED: `client write cb: err=nil`.
- **`data` is a STRING (bytes)**. The write-helper pattern `vim.json.encode(obj) .. "\n"` works
  (OBSERVED — server received exactly the JSONL line + its trailing `\n`).
- **Broken pipe (peer gone) → `err == "EPIPE"`** in the write callback (probe3: server closed,
  then client wrote → `client post-close write cb: werr=EPIPE`). The `write` CALL itself does NOT
  throw synchronously; only the callback reports the error. → ALWAYS pass a callback that routes
  `err` to `on_close`/teardown, else EPIPE is silently swallowed.
- **MULTIPLE writes may be queued** (probe4): two back-to-back `write_message` calls (r1, r2)
  both arrived at the server in order and both responses decoded in order (`got=2 responses`).
  libuv maintains an ordered write queue per stream. → The write helper need NOT await each
  callback before issuing the next.
- Writing BEFORE the connect cb fires: no throw (probe2/T5: `pcall ok=true`), but the bytes are
  dropped / never sent. → The bridge MUST gate `send()` on `on_ready(nil)` (connected state).

## §5. `pipe:close()` + `is_closing()` — the DOUBLE-CLOSE THROWS (probe2)

- `is_closing()` returns `false` on a live handle, `true` once `close()` has been requested OR
  completed (OBSERVED: `false` before close, `true` after close).
- **DOUBLE-CLOSE THROWS** (probe2/T4): calling `close()` on an already-closing handle raises a
  Lua error: `handle 0x.. is already closing` (pcall `ok=false`). → `close()` MUST be guarded by
  `if not pipe:is_closing() then ... end` AND wrapped in `pcall`, AND/OR track a shadow `closed`
  flag. This is the #1 luv gotcha for a client with multiple teardown paths (on_exit, on_close,
  VimLeavePre, error path).
- `read_start`/`write` on a CLOSED handle: **silent no-ops** (probe2/T3, T3b: `pcall ok=true`),
  i.e. they do not throw in this luv build. Still guard (libuv forbids; future luv may throw).

## §6. `pipe:shutdown(cb)` — half-close (not strictly needed for v1 client)

- Sends FIN on the write side while keeping the read side open (drain remaining replies).
- For a request/response bridge that hands control back to pi on `:q`, plain `close()` (full
  teardown) is the right primitive; `shutdown` is an optional refinement (e.g. graceful `bye` →
  shutdown → read-drain → close). S24 uses `close()` only (matches PRD §5.4 `bye` → server
  half-closes; the client just `close()`s).

## §7. The vim.schedule rule — CONFIRMED with the EXACT error (probe4)

- Calling a non-fast `vim.api.*` from a luv callback **throws** (probe4):
  `E5560: nvim_buf_get_lines must not be called in a fast event context`.
- Pure-Lua / `vim.json.encode` / `vim.json.decode` / `vim.uv.*` are **SAFE** directly in the
  callback (probe4: `vim.json in luv cb: pcall_ok=true`).
- IMPLICATION for bridge.lua: `connect`/`read_start`/`write`/`close`/`vim.json.encode`/`rx:feed`
  are all safe to run directly inside luv callbacks (no `vim.schedule` needed for the transport
  layer itself). The CONSUMER of `on_event(msg)` (S26 RPC dispatch, S30+ menu render) is
  responsible for `vim.schedule`-wrapping any `vim.api.*` work it does — same rule jsonlreader's
  header already documents (S23 GOTCHA 5). S24 does NO nvim API calls (pure luv/json), so it is
  safe end-to-end in the callback. Documented as an integration note.

## §8. End-to-end bridge protocol loop — PROVEN (probe4)

The probe implemented BOTH halves (a luv server mirroring the extension + a client mirroring
bridge.lua) and OBSERVED a complete JSONL round-trip:
```
client connect err=nil
client write(r1 ping)  client write(r2 getCommands)   [two queued writes]
server decoded request: method=ping id=r1
server decoded request: method=getCommands id=r2       [server got both, in order]
client decoded response: id=r1 ok=true
client decoded response: id=r2 ok=true                 [client got both responses]
got=2 responses PROBE4_DONE
```
This is the exact pattern S24 ships: `pipe:connect` → `read_start` (feeds `jsonlreader`) →
`send(obj)` = `write(vim.json.encode(obj).."\n", cb)`. The probe IS the reference implementation,
LIVE-VERIFIED.

---

## §9. Design decisions (LOCKED, with rationale)

1. **connect signature: `M.connect(path, on_ready, on_event, on_close)`** (path ONLY — no token).
   Rationale: S24 is the TRANSPORT layer (task title: "luv pipe, read_start, write helper"). The
   token is consumed by the `hello` handshake (S25), which calls `M.send({method="hello",
   params={token=...}})` from inside `on_ready`. Keeping the token out of `connect` is clean task
   separation (S24 = transport, S25 = auth). The descriptor (incl. token) is available to S25 via
   `require("pi-editor").descriptor`.
2. **Callbacks**:
   - `on_ready(err)`: connect result. `err==nil` on success → caller (S25) sends hello here.
     `err=="ENOENT"/"ECONNREFUSED"/"EACCES"` on failure → caller degrades silently (S39).
   - `on_event(msg)`: each decoded JSONL table (from jsonlreader). S25 validates hello response;
     S26 correlates by `id` + drops stale; S27 handles `commandsChanged` notifications.
   - `on_close(reason)`: connection lost. `reason==nil` = clean EOF (peer closed); `reason` =
     bare-errno string (`"EPIPE"`, `"ECONNRESET"`, …) on socket error. Fires AFTER jsonlreader
     `flush()` (so a trailing line is still delivered via `on_event`). Triggers teardown.
3. **`M.send(obj)` write helper**: `data = vim.json.encode(obj) .. "\n"`; guard
   `not pipe:is_closing()` and a `state.connected` flag (gated on `on_ready(nil)`); `pcall` the
   `write(data, cb)`; route any `cb` `err` to `on_close(err)` + teardown. Returns `bool` (queued).
4. **Idempotent `M.close()`**: shadow `state.closed` flag + `pipe:is_closing()` double-guard +
   `pcall(pipe.close)` — defends against the §5 double-close THROW across on_close/on_exit/
   VimLeavePre/error paths. Resets state + the jsonlreader (`rx:reset()`).
5. **`M.on_exit(buf)`**: fulfills S22's ftplugin forward contract
   (`require("pi-editor.bridge").on_exit(buf)` on VimLeavePre/ExitPre). Calls `M.close()`.
   Safe no-op when never connected (state.closed / nil pipe) — this is load-bearing because S24
   ships connect() as a TESTED module that is not yet WIRED into activation (S25 wires it).
6. **Module-level SINGLETON state** (one `pipe`, one `rx`, one callback set) — UNLIKE jsonlreader
   (instance-per-connection). Rationale: the nvim CLIENT is a singleton (one pi editor session =
   one bridge connection; PRD §11 "v1 supports completion in the buffer active at VimEnter"). The
   extension SERVER is multi-connection (hence jsonlreader instances); the client is not.
   Documented as a deliberate, justified divergence.
7. **Scope NOT in S24** (forward contracts established, implemented by later tasks):
   - `hello` handshake (send token + validate response + extract server info) — **S25**.
   - `request(method, params, cb)` with auto-id + correlation + stale-drop — **S26**.
   - `commandsChanged` notification handler — **S27**.
   - WIRING `connect()` into the activation flow (ftplugin/activate) — **S25** (first protocol
     consumer; natural place to wire connect AND send hello). S24 ships the tested module + the
     on_exit fulfillment; `M.bridge` placeholder in init.lua stays `nil` until handshake (S25).
8. **NO nvim API calls** in bridge.lua (pure `vim.uv` + `vim.json` + jsonlreader) — safe to run
   directly in luv callbacks (§7). The on_event consumer schedules nvim work (integration note).

## §10. Scope vs the sibling jsonlreader.lua (S23) — divergence notes

- S23 = instance-based, pure string/`vim.json`, no socket, dead code until S24.
- S24 = singleton, owns the luv pipe lifecycle, CONSUMES S23's `jsonlreader` in its `read_start`,
  fulfills S22's `on_exit` forward contract, dead code (connect not wired) until S25.
- Both share: `local M`/`return M` convention, [Mode A] LuaCATS, standalone smoke + plenary spec
  two-file test convention, LIVE-VERIFIED claims, silent-degrade (PRD §11).