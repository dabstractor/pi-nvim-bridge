---
name: "P2.M5.T15.S24 — bridge.lua: luv pipe connect(), read_start (→jsonlreader), write helper"
description: |
  **CREATE `plugin/lua/pi-editor/bridge.lua`** — the luv (`vim.uv`) Unix-domain-socket CLIENT for the
  pi-bridge.nvim bridge. It owns exactly the TRANSPORT layer of parent task P2.M5.T15 ("Socket client &
  handshake"): create a pipe, connect to the socket path from the (DONE, S21) `descriptor.path`, wire
  `read_start` to the (DONE, S23) `jsonlreader` so every decoded JSON-RPC message reaches an
  `on_event(table)` callback, expose a `send(obj)` write helper (`vim.json.encode(obj).."\n"` →
  `pipe:write`), and provide idempotent `close()`/`on_exit(buf)` teardown. It is the CLIENT counterpart
  of the (COMPLETE, P1.M2) extension-side `connection.ts` + `jsonl-reader.ts` IPC server.
  SURFACE S25/S26/S27 consume (PRD §7.3 skeleton, LIVE-VERIFIED in `research/notes.md` §8):
  `require("pi-editor.bridge").connect(path, on_ready, on_event, on_close)`; `M.send(obj) -> bool`;
  `M.close()`; `M.on_exit(buf)`; `M.is_connected()`. The `hello` handshake (S25), `request()` RPC
  id-correlation/supersession (S26), and `commandsChanged` notification handling (S27) layer ON TOP via
  these callbacks — S24 knows nothing of JSON-RPC methods/ids/tokens (clean transport/protocol split).
  KEY LUV FACTS (LIVE-VERIFIED on Neovim 0.12.4 — `research/notes.md`):
  • `pipe:connect(path, cb)` — cb gets ONE arg `err` (`nil` on success); failures are delivered ASYNC
    in the callback as the BARE errno-name string — `"ENOENT"` (no socket), `"ECONNREFUSED"` (file/not
    listening), `"EACCES"` (perms) — NOT `"<NAME>: msg"` (resolves the researcher "VERIFY" gap).
  • `pipe:read_start(function(err,data))` — TWO args; EOF = `err==nil && data==nil`; `err` (string) =
    read error; `data` = raw bytes with ARBITRARY chunk boundaries → MUST buffer+split on `\n` (S23
    `jsonlreader`). Integrates cleanly: `rx:feed(data)` → `on_message(table)` (§8 round-trip PROVEN).
  • `pipe:write(data, cb)` — cb gets ONE arg `err` (`nil` ok); BROKEN PIPE → `err=="EPIPE"` in the cb
    (the call does NOT throw); MULTIPLE writes may be queued (ordered, no await needed).
  • `pipe:close()` on an already-closing handle **THROWS** (`handle 0x.. is already closing`) — MUST
    guard `close()` with `pipe:is_closing()` AND a shadow `closed` flag AND `pcall`.
  • `read_start`/`write` on a closed handle are silent no-ops in this luv build (still guard).
  • `vim.api.*` from a luv cb THROWS `E5560: ... must not be called in a fast event context`; pure
    Lua/`vim.json`/`vim.uv` are SAFE (so the transport layer needs NO `vim.schedule`; the `on_event`
    CONSUMER schedules nvim work — same rule jsonlreader's header documents).
  SINGLETON STATE (deliberate divergence from jsonlreader's instance-per-connection): the nvim CLIENT
  is a singleton (one pi editor session = one bridge connection; PRD §11 "v1 supports completion in the
  buffer active at VimEnter"). The extension SERVER is multi-connection (hence jsonlreader instances);
  the client is not. Module-level state (one `pipe`, one `rx`, one callback set) is correct + simpler.
  STATUS (planning): every luv behavior above is LIVE-VERIFIED on nvim 0.12.4 (`research/notes.md`).
  NARROW scope guard — this task does NOT: do the `hello` handshake (S25), correlate RPC by `id` /
  supersede (S26), handle `commandsChanged` (S27), or WIRE `connect()` into the activation flow (S25,
  the first protocol consumer). S24 ships the tested transport module + fulfills S22's `on_exit` forward
  contract; `require("pi-editor").bridge` stays the `nil` placeholder until the handshake (S25).
---

## Goal

**Feature Goal**: Create `plugin/lua/pi-editor/bridge.lua` — the luv (`vim.uv`) Unix-domain-socket
**client** for the pi-bridge.nvim bridge. Given the socket `path` from the (DONE, S21) parsed
`descriptor`, it opens a `vim.uv.new_pipe(false)`, connects, wires `read_start` to the (DONE, S23)
`jsonlreader` (so every newline-delimited JSON-RPC message is framed + decoded into a Lua table and
delivered to an `on_event(table)` callback), exposes a `send(obj)` write helper that serializes a
JSON-RPC envelope + `\n` and queues an ordered `pipe:write`, and provides idempotent `close()`/
`on_exit(buf)` teardown that survives the many teardown paths (on_close, VimLeavePre/ExitPre via S22's
ftplugin, socket error, EOF) without ever hitting luv's double-close THROW. It is the faithful,
unit-tested CLIENT counterpart of the COMPLETE extension-side IPC server (`connection.ts` +
`jsonl-reader.ts`, P1.M2), ported to the client role and to the singleton-session model.

**Deliverable** (3 files — 1 NEW source + 2 NEW tests; NO modification to existing modules):
- `plugin/lua/pi-editor/bridge.lua` — **CREATE**: the luv pipe client module. Exposes
  `M.connect(path, on_ready, on_event, on_close)`, `M.send(obj)->bool`, `M.close()`, `M.on_exit(buf)`,
  `M.is_connected()`. [Mode A] LuaCATS docstrings throughout. Zero `vim.api.*` calls (pure
  `vim.uv` + `vim.json` + jsonlreader) → safe to run directly inside luv callbacks.
- `plugin/tests/bridge_smoke.lua` — NEW, plenary-FREE standalone smoke test (Level-1 gate; spins a real
  luv unix-socket server in-process and asserts the full connect→read→write→close loop).
- `plugin/tests/bridge_spec.lua` — NEW, plenary/busted spec (Level-2 gate) covering connect success,
  connect-failure errno strings, read→jsonlreader→on_event, write helper + EPIPE, multi-write queueing,
  EOF→on_close, idempotent close (double-close-safe), on_exit no-op-when-not-connected, is_connected.

> Reuses the existing `plugin/tests/minimal_init.lua` (S19) unchanged + the DONE `jsonlreader` (S23).
> NO change to `init.lua`, the S20 shim, S21's gate, or S22's ftplugin (additive — bridge.lua fulfills
> S22's `on_exit` forward contract, which is already a safe no-op dispatch when the module is absent).
> `connect()` is NOT yet wired into the activation flow — that is S25's job (the first protocol
> consumer). S24 ships the tested module; `require("pi-editor").bridge` stays `nil` until S25.

**Success Definition** (every assertion is LIVE-VERIFIED green — see `research/notes.md` + Validation):
- **connect success**: `connect(real_path, …)` → `on_ready(nil)` fires; a subsequent `send(obj)`
  delivers the JSONL line to the server (server `read_start` sees `vim.json.encode(obj).."\n"`).
- **connect failure (ENOENT)**: `connect("/tmp/nope-<ts>.sock", …)` → `on_ready("ENOENT")`; no throw;
  `is_connected()` stays false; the pipe is closed (no leak).
- **connect failure (ECONNREFUSED)**: connecting to a regular FILE → `on_ready("ECONNREFUSED")`.
- **read → jsonlreader → on_event**: server writes JSONL → client `read_start` feeds `jsonlreader` →
  `on_event(decoded_table)` per message (single line, multi-record drain, partial-line buffering).
- **write helper**: `send({jsonrpc="2.0",id="r1",method="ping"})` queues `pipe:write(encode.."\n",cb)`;
  server receives exactly that line; the write callback gets `err==nil`.
- **multi-write queueing**: two back-to-back `send` calls both arrive at the server IN ORDER (libuv
  write queue; no await-between-writes needed).
- **broken pipe (EPIPE)**: after the server closes, a `send` → write callback receives `err=="EPIPE"`
  → routed to `on_close("EPIPE")`; no throw.
- **EOF → on_close**: server closes its connection → client `read_start` sees `data==nil, err==nil` →
  jsonlreader `flush()` (trailing line still delivered via `on_event`) → `on_close(nil)` (clean EOF).
- **idempotent close (double-close-safe)**: `close()` then `close()` again then `on_exit(buf)` → NO
  throw (guards `is_closing()` + shadow `closed` flag + `pcall`); `is_connected()` false throughout.
- **on_exit no-op when never connected**: `on_exit(buf)` with no prior `connect` → no throw, no op.
- **send before connect / after close**: returns `false` (guarded), no throw, no spurious write.
- `nvim --headless --clean -u NORC` smoke prints `SMOKE_PASS` / exit 0.
- plenary `tests/bridge_spec.lua` exits 0.
- **Non-regression**: S19 `init_spec` (13), S20 `shim_spec` (6), S21 `activate_spec` (9),
  S22 `ftplugin_spec` (13), S23 `jsonlreader_spec` (16) still pass unchanged (S24 touches NO existing file).

## User Persona (if applicable)

**Target User**: The `pi-bridge.nvim` plugin author and the downstream implementers of **S25**
(`hello` handshake), **S26** (`request()` RPC id-correlation/supersession), **S27** (`commandsChanged`
notification handler), and **S38** (autosave + bridge teardown body). `bridge.lua` is the transport
substrate all of them compose. End users never see it; they experience it as "the completion menu shows
items with no hang / no crash / no leaked fd" (because the socket lifecycle is correct).

**Use Case**: Completes the foundation stack S19 (config) → S20 (shim) → S21 (gate) → S22 (ftplugin)
→ S23 (byte-stream decoder) → **S24 (the luv socket transport)** → S25 (handshake) → S26 (RPC) → S30+
(completion). After S24, the plugin has a tested, dependency-free socket client with a clean callback
contract — so S25 just sends `hello` from `on_ready` and validates the response in `on_event`, S26
just assigns ids + correlates in `on_event`, and S27 just branches on `msg.method=="commandsChanged"`.
De-risks "can we correctly own a luv pipe lifecycle (connect/read/write/close) across async callbacks,
arbitrary chunking, broken pipes, EOF, and the many teardown paths — without ever hitting luv's
double-close THROW or leaking an fd?" before any handshake or RPC logic lands.

**Pain Points Addressed**: Without a correct socket client, the bridge would (a) crash nvim on a
double-`close()` (LIVE-VERIFIED: `handle 0x.. is already closing` throws), (b) silently swallow EPIPE
(write with no callback → lost error → hung completion), (c) leak an fd if a teardown path is missed,
(d) decode every raw chunk and corrupt on multi-chunk messages (S23 solved framing; S24 must actually
WIRE S23 into `read_start`), or (e) call `vim.api.*` from a luv callback and throw `E5560`. Getting the
transport locked NOW (with the full luv error catalog LIVE-VERIFIED) means S25/S26 focus on protocol.

## Why

- **The CLIENT counterpart of a COMPLETE, proven server.** `extension/connection.ts` (P1.M2.T4.S8) +
  `extension/jsonl-reader.ts` (P1.M2.T4.S7) are the authoritative IPC server (PRD §16) — unit-tested,
  shipping. S24 is the symmetric client half: it connects, frames+decodes inbound (via the S23 Lua twin
  of the server's reader), serializes outbound (`vim.json.encode(obj).."\n"`, the Lua twin of the
  server's `serializeJsonLine`), and owns the socket lifecycle. The wire must be symmetric.
- **Faithful to PRD §7.3 + §5.2.** §7.3's skeleton fixes the module surface (`connect(path, token,
  on_ready, on_event)` + `M.send({…})` + `pipe:read_start(… rx:feed(chunk))`). S24 IS that surface,
  with the token deferred to S25 (transport/protocol split — see Design Decision §1 in notes). §5.2
  fixes the framing rules (S23's job, which S24 consumes).
- **Decouples transport from protocol.** S25 (handshake), S26 (RPC id-correlation), S27 (notifications)
  are each non-trivial. Pulling the pure socket lifecycle into its own module (S24) — exactly as the
  server split S7 (framing) from S8 (connection) — means each protocol task composes a tested transport
  primitive instead of inlining fragile async socket code next to auth/RPC logic.
- **Integrates with the (complete) foundation.** Consumes S23's `jsonlreader` (DONE) in `read_start`;
  fulfills S22's `on_exit` forward contract (DONE ftplugin already dispatches
  `require("pi-editor.bridge").on_exit(buf)`); reads `descriptor.path` (DONE, S21). Touches none of
  S19/S20/S21/S22/S23 (additive). Establishes the forward contract S25/S26/S27 consume.

## What

User-visible behavior: none directly (an internal transport module). Indirectly: once S25+ wire it, the
completion menu in a pi-launched nvim renders because every JSON-RPC response from the bridge server is
received and decoded regardless of how the OS coalesced the socket reads, and quitting the editor
cleanly closes the socket (no leak, no crash) via `on_exit`.

Technical requirements (the module body — exact, LIVE-VERIFIED):
- `local M = {}` module table; `return M` at the end (the `lua/pi-editor/*.lua` convention).
- **Module-level SINGLETON state** (deliberate — see Design Decision §6): one `pipe` (the luv handle),
  one `rx` (a `jsonlreader` instance), one set of callbacks (`on_ready`/`on_event`/`on_close`), and a
  `state` table tracking `connected` (bool, set true on `on_ready(nil)`, false otherwise), `closed`
  (shadow flag set the moment teardown begins — defends the §5 double-close THROW), and `closing`.
  Re-exported read-only via `M.is_connected()`.
- **`M.connect(path, on_ready, on_event, on_close)`** — the entry point. `on_ready(err)` is called
  exactly once with the connect result (`err==nil` on success; bare errno string `"ENOENT"`/
  `"ECONNREFUSED"`/`"EACCES"` on failure — LIVE-VERIFIED §2). `on_event(msg)` is called per decoded
  JSON-RPC message (synchronously, inline from the jsonlreader — which itself runs inline from the luv
  `read_start` cb). `on_close(reason)` is called when the connection is lost (`reason==nil` = clean EOF
  via `data==nil`; `reason` = bare errno string like `"EPIPE"`/`"ECONNRESET"` on socket error) — fires
  AFTER `rx:flush()` so a trailing line is still delivered. Implementation: `pipe = uv.new_pipe(false)`;
  construct `rx = jreader.new(on_event)` (on_error optional → silent, PRD §11); `pipe:connect(path,
  function(err) if err then on_ready(err); M.close(); return end pipe:read_start(readcb); state.connected
  = true; on_ready(nil) end)`. The `readcb(err,data)`: if `state.closed` return; if `err` →
  `on_close(err)` + teardown; if `data==nil` → `rx:flush()` + `on_close(nil)` + teardown; else
  `rx:feed(data)`. NEVER throws (pcall-wrap the luv calls defensively).
- **`M.send(obj)`** — write helper. If `not state.connected` or `pipe:is_closing()` or `state.closed` →
  return `false` (guarded; §4 — writing before connect / after close is a no-op drop). Else
  `data = vim.json.encode(obj) .. "\n"`; `pcall(pipe.write, pipe, data, function(werr) if werr then
  on_close(werr); teardown() end end)`; return `true`. NOTE: the write CALL does not throw on a broken
  pipe — only the CALLBACK reports `werr=="EPIPE"` (LIVE-VERIFIED §4) — so ALWAYS pass a callback that
  routes `werr` to `on_close`, else EPIPE is silently swallowed.
- **`M.close()`** — idempotent teardown. Guard: `if state.closed then return end; state.closed = true`.
  Then `if pipe and not pipe:is_closing() then pcall(function() pipe:close() end) end` (pcall defends
  the double-close THROW — LIVE-VERIFIED §5). Reset: `state.connected=false`; `rx:reset()` if `rx`;
  clear the stored callbacks/state so a stale cb cannot fire post-teardown. Cheap; idempotent.
- **`M.on_exit(buf)`** — fulfills S22's ftplugin forward contract (`require("pi-editor.bridge").on_exit(buf)`
  on VimLeavePre/ExitPre). Body: `M.close()`. `buf` is accepted (matches the dispatch signature) and
  ignored at the transport layer (autosave is S38's job, dispatched separately). Safe no-op when never
  connected (`state.closed`/nil `pipe`) — load-bearing because `connect()` is not wired until S25.
- **`M.is_connected()`** — returns `state.connected == true and not state.closed` (read-only accessor
  for consumers/tests).
- **NO `vim.api.*` calls** anywhere (only `vim.uv`, `vim.json`, the jsonlreader, table ops) → safe to
  run directly inside luv callbacks (LIVE-VERIFIED §7: pure Lua/`vim.json`/`vim.uv` are fast-context-safe;
  `vim.api.*` throws `E5560`). The CONSUMER (`on_event`) schedules nvim work (integration note).
- **[Mode A]**: a header comment block (purpose; the CLIENT counterpart lineage to the COMPLETE
  extension `connection.ts`/`jsonl-reader.ts`; the LIVE-VERIFIED luv error catalog; the singleton-state
  rationale; the transport/protocol split + the forward contracts S25/S26/S27/S38 consume; the
  vim.schedule integration note) + per-method LuaCATS docstrings.

### Success Criteria

- [ ] `M.connect`, `M.send`, `M.close`, `M.on_exit`, `M.is_connected` are all functions on the module.
- [ ] `connect(real_path, …)` → `on_ready(nil)` fires exactly once; `is_connected()` true after.
- [ ] `connect("/tmp/nope.sock", …)` → `on_ready("ENOENT")`; no throw; `is_connected()` false; pipe closed.
- [ ] `connect(<regular-file>, …)` → `on_ready("ECONNREFUSED")`; no throw; pipe closed.
- [ ] Server writes JSONL → client `on_event(decoded_table)` per message (single line, drain loop,
      partial-line buffering across chunks — proves S23 is wired into `read_start`).
- [ ] `send({jsonrpc="2.0",id="r1",method="ping"})` → server receives exactly `encode(..).."\n"`;
      write callback gets `err==nil`.
- [ ] Two back-to-back `send` calls arrive at the server IN ORDER (multi-write queueing).
- [ ] After server closes: a `send` → write callback `err=="EPIPE"` → `on_close("EPIPE")`; no throw.
- [ ] Server closes connection → client `read_start` `data==nil, err==nil` → `rx:flush()` (trailing line
      delivered) → `on_close(nil)` (clean EOF); `is_connected()` false.
- [ ] `close()` called twice → NO throw (guarded + pcall); `close()` then `on_exit(buf)` → no throw.
- [ ] `on_exit(buf)` with NO prior `connect` → no throw, no op (safe no-op).
- [ ] `send` before `connect` OR after `close` → returns `false`; no throw; no spurious write.
- [ ] `read_start`/`write` on a closed pipe are guarded (never reach luv with a closed handle).
- [ ] No `vim.api.*` calls in the file (fast-context-safe; consumer schedules nvim work).
- [ ] Module-level singleton state (one pipe/rx/callback-set); `connect` twice is a re-init (the prior
      connection, if any, is closed first — idempotent re-connect).
- [ ] `nvim --headless --clean -u NORC +"luafile plugin/tests/bridge_smoke.lua" +qa` prints
      `SMOKE_PASS` / exit 0.
- [ ] `tests/bridge_spec.lua` passes under plenary (exit 0).
- [ ] **Non-regression**: `init_spec` + `shim_spec` + `activate_spec` + `ftplugin_spec` +
      `jsonlreader_spec` still pass.
- [ ] [Mode A] header comment + per-method LuaCATS docstrings present.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo needs only this PRP +
`research/notes.md` + the verified commands below. Every luv behavior (`new_pipe(false)`,
`connect`/`read_start`/`write`/`close`/`is_closing` callback signatures; EOF = `data==nil && err==nil`;
connect-error bare-errno strings `"ENOENT"`/`"ECONNREFUSED"`/`"EACCES"`; broken-pipe `err=="EPIPE"` in
the write cb; double-`close()` THROWS; `read_start`/`write` on a closed handle are silent no-ops;
`vim.api.*` from a luv cb throws `E5560` while pure Lua/`vim.json`/`vim.uv` are safe) is cited with a
`:help`/reference source AND a **LIVE-VERIFIED** result (`research/notes.md` §1–§8, incl. a full
end-to-end JSONL round-trip probe). The two subtleties that make or break this task — (1) the
double-`close()` THROW (must guard with `is_closing()` + shadow `closed` flag + `pcall`), and (2) EPIPE
is reported ONLY in the write callback (so `send` MUST always pass a callback that routes `err` to
`on_close`) — are spelled out in §Known Gotchas and embedded in the reference implementation.

### Documentation & References

```yaml
# MUST READ — primary contract sources

- url: https://github.com/luvit/luv/blob/master/docs.md
  why: "THE authoritative luv API (bundled as vim.uv). Methods used by S24: uv.new_pipe([ipc]),
        pipe:connect(name, cb), stream:read_start(cb), stream:write(data, cb), handle:close(cb),
        handle:is_closing(). Each documents the exact callback signature + return shape."
  critical: "LIVE-VERIFIED (research/notes.md §1-§5) divergences/gotchas: (a) connect/read/write
             ERRORS are delivered as the BARE errno-name string in the callback ('ENOENT',
             'ECONNREFUSED', 'EACCES', 'EPIPE', 'ECONNRESET') — NOT '<NAME>: strerror>' (the
             researcher's 'VERIFY' gap is resolved). (b) EOF = read_start cb with err==nil AND
             data==nil. (c) double-close() THROWS 'handle 0x.. is already closing' — guard with
             is_closing()+pcall. (d) read_start/write on a CLOSED handle are silent no-ops in this
             build (still guard — libuv forbids it). (e) write's broken-pipe error is reported ONLY in
             the callback (the call does not throw) — so ALWAYS pass a write callback."

- url: http://docs.libuv.org/en/stable/pipe.html
  why: "libuv C semantics under every luv Lua method (uv_pipe_t / uv_stream_t / uv_handle_t). Confirms
        uv_pipe_init ipc flag (false = normal pipe, true = IPC handle-passing — S24 uses false),
        uv_read_start EOF/error semantics, uv_write queueing + UV_ECANCELED on close."

- url: https://neovim.io/doc/user/lua.html#vim.uv
  why: "vim.uv IS vim.loop (0.10+ alias; identical bundled luv). :help vim.uv confirms the singleton
        instance + colon-vs-dot calling convention."

- url: https://neovim.io/doc/user/api.html#api-fast
  why: "The fast-context rule. luv callbacks run in a restricted/fast context. Non-fast vim.api.* calls
        throw E5560 there."
  critical: "LIVE-VERIFIED (research/notes.md §7): vim.api.nvim_buf_get_lines in a luv cb throws
             'E5560: nvim_buf_get_lines must not be called in a fast event context'. Pure Lua /
             vim.json.encode / vim.uv.* are SAFE (pcall_ok=true). So bridge.lua (transport only, no
             nvim API) is safe end-to-end in callbacks; the on_event CONSUMER (S26/S30+) must
             vim.schedule its nvim work. Same rule jsonlreader's header documents (S23 GOTCHA 5)."

- file: plugin/lua/pi-editor/jsonlreader.lua
  why: "THE (DONE, S23) byte-stream decoder S24 CONSUMES in read_start. S24 calls
        jreader.new(on_message[, on_error]) -> reader at connect time; reader:feed(chunk) on each
        read_start data chunk; reader:flush() on EOF; reader:reset() on close. Read its [Mode A]
        header (the synchronous-on_message + consumer-schedules note) IN FULL."
  pattern: "new(on_message, on_error) returns a reader with feed/flush/reset (setmetatable {__index=M}).
            feed buffers + splits on \\n (plain) + strips \\r + decodes (pcall) + on_message(table).
            flush emits a buffered final line lacking \\n. reset clears the buffer."
  gotcha: "on_message is SYNCHRONOUS from feed (runs inside the luv read_start cb). jsonlreader does NO
           nvim API calls (safe). The CONSUMER (bridge's on_event → S26/S30+) schedules nvim work."

- file: extension/connection.ts
  why: "THE SERVER-SIDE COUNTERPART (P1.M2.T4.S8, COMPLETE). Shows the symmetric half: how the server
        attaches the jsonl-reader, dispatches JSON-RPC, writes responses (serializeJsonLine =
        JSON.stringify(v)+'\\n' — the EXACT mirror of S24's send helper), and owns socket error/close
        (sock.on('error') MUST be handled or pi crashes — the client analog is routing write cb err /
        read err to on_close). Read for the symmetric lifecycle."
  pattern: "onConnection(sock): attachJsonlLineReader(sock, line => handleLine(...)); sock.on('error',
            err => { log(err.message); detach(); sock.destroy() }); sock.on('close', () => detach()).
            sendResponse/sendError/sendNotification use serializeJsonLine + sock.write."

- file: extension/jsonl-reader.ts
  why: "THE AUTHORITATIVE FRAMING MIRROR (P1.M2.T4.S7, COMPLETE). serializeJsonLine(v) =
        JSON.stringify(v)+'\\n' is the EXACT wire form S24's send(obj) must produce (Lua twin:
        vim.json.encode(obj)..'\\n'). Read to confirm the \\n-only, \\r-tolerant, U+2028/U+2029-safe
        framing the server expects (and that jsonlreader already decodes symmetrically)."

- file: extension/pi-editor-bridge.ts
  why: "The server ENTRY (COMPLETE). Shows startBridge(): socket path = ${tmpdir}/pi-editor-bridge-
        <uuid>.sock, chmod 0o600, and process.env.PI_NVIM_BRIDGE = JSON.stringify({transport:'unix',
        path, token, pid, cwd, fdAvailable, serverVersion}) — the descriptor S21 parses (descriptor.path
        is what S24 connects to). Confirms the server is alive for the whole session (S24's client can
        assume a stable path once the descriptor is read)."

- file: plugin/lua/pi-editor/init.lua
  why: "S19/S21 module (DONE). (1) Confirms the lua/pi-editor/*.lua module convention (local M / return
        M, [Mode A] LuaCATS). (2) Defines pi-editor.BridgeDescriptor (descriptor.path / descriptor.token
        — S24 uses .path; .token is S25's). (3) M.descriptor is set by activate(); S25 will read it to
        call connect(descriptor.path). (4) M.bridge is the nil placeholder S25 populates after handshake
        (S24 leaves it nil). Read the activate() scope comment ('does NOT connect to the bridge — that
        is bridge.lua / S24, which reads this descriptor')."

- file: plugin/ftplugin/pi-prompt.lua
  why: "S22 ftplugin (DONE). ALREADY dispatches require('pi-editor.bridge').on_exit(buf) on
        VimLeavePre/ExitPre — a forward contract S24 MUST fulfill (on_exit exists + is a safe no-op when
        not connected). The dispatch helper pcall's + returns false if the module/function is absent, so
        S24 merely needs to EXIST + define on_exit for the contract to go live. Read the FORWARD
        CONTRACTS comment block."

- file: plugin/tests/minimal_init.lua
  why: "S19 plenary harness (DONE, REUSED unchanged). Puts plugin/ on runtimepath + plenary on rtp, so
        require('pi-editor.bridge') + require('pi-editor.jsonlreader') + require('plenary.busted') all
        resolve in tests."

- file: plugin/tests/jsonlreader_spec.lua  AND  plugin/tests/jsonlreader_smoke.lua
  why: "The S23 test pattern to MIRROR (DONE). The spec uses a real luv unix-socket server in an
        integration case (Level-3) — S24's tests REUSE that exact server-in-process pattern (it is the
        only way to exercise connect/read/write without the real bridge extension running). The smoke is
        plenary-FREE, :luafile-sourced. Read for the helper that spins a luv server + client + asserts
        the round-trip."

- docfile: PRD.md
  section: "§7.3 (bridge.lua skeleton — connect(path,token,on_ready,on_event) + M.send + pipe:read_start
        → rx:feed; S24 implements the transport, defers token/handshake to S25), §5.2 (framing — owned
        by jsonlreader/S23 which S24 consumes), §5.1 (Unix socket transport), §5.3 (handshake — S25),
        §5.5 (timing/cancellation — S26), §11 (silent-degrade on connect-fail/EOF/pi-died; v1 single
        buffer = singleton client), §12 (security/token — S25)"
  why: "These PRD sections ARE the source of truth for this task (reproduced in <selected_prd_content>)."

- file: plan/001_c56962b4fa17/architecture/external_deps.md
  why: "§1.4 (luv unix-socket CLIENT pattern: new_pipe(false) -> connect -> read_start(cb) -> write ->
        close) is the S24 reference. §1.5 (vim.json) confirms encode/decode. §1.7 (vim.defer_fn/timers)
        for the test event-loop pacing. §6 (plenary is the Lua test framework)."

- file: plan/001_c56962b4fa17/P2M5T14S23/PRP.md  AND  .../P2M5T14S23/research/notes.md
  why: "The immediately-preceding sibling (jsonlreader, DONE). Establishes the exact PRP/module/test
        conventions S24 reuses: [Mode A] header + LuaCATS, standalone smoke + plenary spec two-file test
        convention, LIVE-VERIFIED gotchas, the forward-contract pattern, and the 'dead code until
        consumer ships' rationale. Read for style/depth calibration (S24's depth bar == S23's)."

- file: plan/001_c56962b4fa17/P2M5T15S24/research/notes.md
  why: "LIVE-VERIFIED proof (nvim 0.12.4) of every luv claim above: the full method surface (§0), the
        connect success path (§1), the connect-failure bare-errno strings ENOENT/ECONNREFUSED (§2), the
        read_start chunk/EOF/error semantics + jsonlreader integration + a full JSONL round-trip
        (§3/§8), the write helper success/EPIPE/multi-write-queueing (§4), the double-close THROW +
        is_closing semantics (§5), the vim.schedule rule with the EXACT E5560 message (§7), and the
        LOCKED design decisions (§9) incl. the singleton-state rationale and the transport/protocol
        split. Full probe transcripts included."
```

### Current Codebase tree (relevant slice)

```bash
pi-nvim-bridge/                  # repo root (monorepo: extension/ + plugin/)
├── extension/                   # P1 — pi-editor-bridge (TypeScript) — COMPLETE (the SERVER counterpart)
│   ├── jsonl-reader.ts          # serializeJsonLine = JSON.stringify(v)+'\n' (S7, DONE) — S24's send() twin
│   ├── connection.ts            # onConnection/sendResponse/sock.on('error')/'close' (S8, DONE) — S24's twin
│   ├── pi-editor-bridge.ts      # startBridge(): socket path + PI_NVIM_BRIDGE descriptor (DONE)
│   └── tests/jsonl-reader.test.ts connection.test.ts ...  # the server test pattern (DONE)
├── plugin/                      # <-- Neovim plugin root (the runtimepath entry)
│   ├── lua/pi-editor/
│   │   ├── init.lua             # S19+S21 (DONE) — module convention + descriptor.path/.token + activate() gate
│   │   └── jsonlreader.lua      # S23 (DONE) — the byte-stream decoder S24 CONSUMES in read_start
│   ├── plugin/pi-editor.lua     # S20 (DONE) — VimEnter shim
│   ├── ftplugin/pi-prompt.lua   # S22 (DONE) — ALREADY dispatches require("pi-editor.bridge").on_exit(buf)
│   └── tests/
│       ├── minimal_init.lua     # S19 (DONE) — plenary harness (REUSED unchanged)
│       ├── jsonlreader_spec.lua  jsonlreader_smoke.lua  # S23 (DONE) — the luv-server-in-test pattern to mirror
│       ├── init_spec.lua  shim_spec.lua  activate_spec.lua  ftplugin_spec.lua  # S19-S22 (DONE) — must STILL pass
│       └── smoke.lua            # S19 (DONE)
├── PRD.md  README.md  package.json
└── plan/001_c56962b4fa17/
    ├── architecture/{external_deps,system_context,research-pi-*}.md
    └── P2M5T15S24/{PRP.md, research/notes.md}   # THIS task
# NOTE: plugin/lua/pi-editor/bridge.lua does NOT exist yet — this task CREATES it.
# NOTE: connect() is NOT wired into activation until S25 (S24 ships the tested module + on_exit fulfillment).
# NOTE: the hello handshake (S25), request() RPC id-correlation (S26), commandsChanged (S27) do NOT exist yet —
#       they consume S24's on_ready/on_event/on_close + send() callbacks.
# NOTE: stylua, selene are NOT installed (nvim 0.12.4 + plenary.nvim ARE).
```

### Desired Codebase tree with files to be added/modified

```bash
plugin/                          # runtimepath entry (unchanged)
├── lua/pi-editor/
│   ├── init.lua                 # (S19/S21, unchanged)
│   ├── jsonlreader.lua          # (S23, unchanged — CONSUMED by bridge.lua's read_start)
│   └── bridge.lua               # NEW — luv pipe client (connect/send/close/on_exit + state)
└── tests/
    ├── minimal_init.lua         # (S19, REUSED unchanged)
    ├── bridge_smoke.lua         # NEW — plenary-FREE smoke (Level-1; real luv server in-process)
    └── bridge_spec.lua          # NEW — plenary/busted spec (Level-2)
```

> **Why CREATE (not MODIFY)?** `bridge.lua` is a brand-new module. It CONSUMES the DONE `jsonlreader`
  (a `require`, no edit) and FULFILLS the S22 `on_exit` forward contract (the ftplugin's dispatch
  helper already no-ops gracefully when the module is absent — S24 merely makes it present). No existing
  file changes → guaranteed non-regression of all five predecessor suites.

### Known Gotchas of our codebase & Library Quirks

```lua
-- GOTCHA 1 — connect/read/write ERRORS are the BARE errno-name STRING (not "<NAME>: msg>").
--   LIVE-VERIFIED (research/notes.md §2): connecting to a nonexistent socket -> on_ready("ENOENT");
--   connecting to a regular file -> on_ready("ECONNREFUSED"); no-perms -> "EACCES". The write cb on a
--   broken pipe -> werr="EPIPE"; a read error -> rerr="ECONNRESET". These are the BARE errno token
--   (type==string), NOT the "ENOENT: no such file or directory" form a libuv C caller sees. Pattern-match
--   with `err == "ENOENT"` or `err:match("^E")`. Do NOT assert on the long strerror text.

-- GOTCHA 2 — double-close() THROWS; guard with is_closing() + a shadow `closed` flag + pcall.
--   LIVE-VERIFIED (research/notes.md §5): calling pipe:close() on an already-closing handle raises a
--   Lua error 'handle 0x.. is already closing' (pcall ok=false). A client with MANY teardown paths
--   (on_close, on_exit, VimLeavePre/ExitPre via S22's ftplugin, socket-error, EOF) WILL hit this if
--   unguarded. FIX: a module-level `state.closed` shadow flag (set true at the START of close, before
--   any pipe op) + `if not pipe:is_closing() then pcall(function() pipe:close() end) end`. Idempotent.

-- GOTCHA 3 — EPIPE is reported ONLY in the write callback; ALWAYS pass a write cb that routes err.
--   LIVE-VERIFIED (research/notes.md §4): after the server closes, pipe:write(data, cb) does NOT throw —
--   only the callback receives werr="EPIPE". If send() omits the callback (or ignores werr), a broken
--   pipe is SILENTLY swallowed and completion hangs forever. FIX: send() always passes
--   function(werr) if werr then on_close(werr); M.close() end end.

-- GOTCHA 4 — EOF = read_start cb with err==nil AND data==nil; flush the jsonlreader FIRST.
--   LIVE-VERIFIED (research/notes.md §3): when the server closes, the client read_start cb fires with
--   (nil, nil). A server MAY not trailing-newline its last record, so a final line could be buffered in
--   the jsonlreader — call rx:flush() BEFORE on_close(nil) so the trailing message is still delivered
--   via on_event. Then teardown. (read_start's rerr non-nil branch is a hard read error -> on_close(rerr).)

-- GOTCHA 5 — NEVER call vim.api.* from a luv callback (E5560); pure Lua/vim.json/vim.uv are safe.
--   LIVE-VERIFIED (research/notes.md §7): vim.api.nvim_buf_get_lines in a luv cb throws
--   'E5560: ... must not be called in a fast event context'. But vim.json.encode/decode, table ops,
--   and vim.uv.* are SAFE (pcall_ok=true). bridge.lua does NO nvim API calls (transport only) so it is
--   safe end-to-end in callbacks. The on_event CONSUMER (S26 RPC dispatch, S30+ menu render) MUST
--   vim.schedule its nvim work. (Same rule jsonlreader's S23 header documents as GOTCHA 5.)

-- GOTCHA 6 — do NOT write before the connect callback fires (on_ready(nil)); gate send() on state.connected.
--   LIVE-VERIFIED (research/notes.md §4 T5): pipe:write before connect does not throw, but the bytes are
--   dropped (the pipe isn't connected). FIX: send() returns false unless state.connected (set true only
--   inside the connect success path, before on_ready(nil)). S25's hello is the first legal send().

-- GOTCHA 7 — read_start / write on a CLOSED handle are silent no-ops in this luv build — STILL GUARD.
--   LIVE-VERIFIED (research/notes.md §5 T3): pcall(pipe.read_start, pipe, cb) and pcall(pipe.write, ...)
--   on a closed handle return ok=true, err=nil (no throw, no effect). libuv semantically forbids it and
--   a future luv may throw — so defense-in-depth: check `not pipe:is_closing() and not state.closed`
--   before every luv op, AND pcall-wrap. (close() is the ONE that throws today — GOTCHA 2.)

-- GOTCHA 8 — chunk boundaries are ARBITRARY; you MUST feed read_start chunks to the jsonlreader (S23).
--   LIVE-VERIFIED (jsonlreader S23 research + research/notes.md §3): the OS coalesces/fragments socket
--   reads (4 server writes -> 2 client chunks at random offsets). NEVER decode a raw chunk; always
--   rx:feed(data) and let S23 buffer+split+decode. The bridge's read_start data branch is ONE line:
--   `rx:feed(data)`. (S24 does not re-derive framing — it composes the tested S23 primitive.)

-- GOTCHA 9 — on_event runs SYNCHRONOUSLY inside the luv read_start callback (via jsonlreader.feed).
--   jsonlreader calls on_message inline from feed (S23 GOTCHA 5). So bridge's on_event(msg) executes on
--   the libuv loop. on_event itself must do NO nvim API work (see GOTCHA 5) — it should be a thin
--   dispatch (S25/S26/S27 branch on msg.method/msg.id) that vim.schedule's any heavy work. S24's own
--   on_event contract is just "deliver the decoded table"; the consumer owns scheduling. Document it.

-- GOTCHA 10 — module-level SINGLETON state (deliberate divergence from jsonlreader's instances).
--   jsonlreader (S23) is instance-per-connection (the SERVER is multi-connection). bridge.lua is the
--   CLIENT: one pi editor session = ONE bridge connection (PRD §11 "v1 supports completion in the buffer
--   active at VimEnter"). So module-level state (one pipe, one rx, one callback set) is correct +
--   simpler. connect() called twice RE-INITS (closes any prior connection first — idempotent). Do NOT
--   make bridge.lua instance-based (would fight the singleton model + the `require("pi-editor").bridge`
--   placeholder S25 sets after handshake).

-- GOTCHA 11 — the write helper must produce serializeJsonLine's EXACT form: encode(obj).."\n".
--   The server's extension/jsonl-reader.ts serializeJsonLine(v) = JSON.stringify(v)+'\n' (the framing
--   mirror, PRD §16). The Lua twin is vim.json.encode(obj)..'\n'. vim.json.encode produces compact JSON
--   (no trailing newline) — the '\n' is the record terminator the server's reader splits on. Omitting
--   '\n' makes the server buffer the line forever (no flush until the next message or EOF). ALWAYS
--   append '\n'. (vim.json.encode may reorder object keys — insignificant for JSON.parse on the server.)

-- GOTCHA 12 — `connect()` is NOT wired into activation in S24 (S25's job); on_exit MUST no-op safely.
--   S22's ftplugin ALREADY dispatches require("pi-editor.bridge").on_exit(buf) on VimLeavePre/ExitPre.
--   So on_exit WILL be called in every pi-prompt session even though connect() is not yet called (S24
--   ships the module before S25 wires connect). on_exit MUST be a safe no-op when state.closed / the
--   pipe is nil (never connected): just `M.close()`, which guards everything. LIVE-VERIFIED requirement.
```

## Implementation Blueprint

### Data models and structure

No external data models. The module is a singleton client with a small internal state table:

```lua
---@class pi-editor.BridgeState
---@field pipe userdata?       The luv pipe handle (uv.new_pipe(false)); nil before connect / after close.
---@field rx pi-editor.JsonlReader? The jsonlreader (S23) instance fed by read_start; nil before connect.
---@field on_ready? fun(err:string?)    Connect-result callback (err==nil on success; errno string on fail).
---@field on_event? fun(msg:table)      Per-decoded-JSON-RPC-message callback (synchronous from read_start).
---@field on_close? fun(reason:string?) Connection-lost callback (nil=clean EOF; errno string=socket error).
---@field connected boolean     True only between on_ready(nil) and the start of teardown.
---@field closed boolean        Shadow flag: true once teardown BEGUN (defends the double-close THROW).
```

The decoded message is whatever `jsonlreader`'s `vim.json.decode` returns — a JSON-RPC envelope
(`{jsonrpc="2.0", id="...", method="...", params/result/error=...}`). bridge.lua does NOT narrow or
dispatch by method/id — that is S25 (hello) / S26 (request id-correlation) / S27 (notifications). It
only transports: connect → read→decode→on_event → send(encode) → close.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/lua/pi-editor/bridge.lua  (THE deliverable — luv pipe transport)
  - HEADER: a [Mode A] comment block documenting: purpose; the CLIENT counterpart lineage to the
        COMPLETE extension connection.ts/jsonl-reader.ts (P1.M2); the LIVE-VERIFIED luv error catalog
        (GOTCHA 1 — bare errno strings); the double-close THROW + guard (GOTCHA 2); EPIPE-in-cb-only +
        always-pass-write-cb (GOTCHA 3); EOF=flush-then-on_close (GOTCHA 4); the vim.schedule rule
        (GOTCHA 5 — no vim.api in bridge, consumer schedules); the singleton-state rationale (GOTCHA 10);
        the transport/protocol split (token deferred to S25); the forward contracts S25/S26/S27/S38
        consume (on_ready/on_event/on_close + send + on_exit); the "connect not wired until S25" note.
  - MODULE: `local M = {}`; require("pi-editor.jsonlreader") as `jreader`; `local uv = vim.uv`;
        module-level singleton `state` table (GOTCHA 10); `return M`.
  - M.connect(path, on_ready, on_event, on_close): idempotent re-init (close any prior); pipe =
        uv.new_pipe(false); rx = jreader.new(on_event) (on_error optional → silent, PRD §11);
        pipe:connect(path, function(err) if err then on_ready(err); M.close(); return end
        pipe:read_start(readcb); state.connected=true; on_ready(nil) end) — pcall-wrap the luv calls.
        readcb(err,data): if state.closed return; if err → on_close(err)+M.close(); if data==nil →
        rx:flush()+on_close(nil)+M.close(); else rx:feed(data). Store callbacks on state. [Mode A].
  - M.send(obj): if not state.connected or state.closed or (pipe and pipe:is_closing()) → return false
        (GOTCHA 6/7). Else data=vim.json.encode(obj).."\n" (GOTCHA 11); pcall(pipe.write, pipe, data,
        function(werr) if werr then local cb=state.on_close; M.close(); if cb then cb(werr) end end end)
        (GOTCHA 3 — ALWAYS a cb that routes werr to on_close); return true.
  - M.close(): if state.closed then return end (GOTCHA 2 shadow flag, set FIRST); state.closed=true;
        state.connected=false; if pipe and not pipe:is_closing() then pcall(function() pipe:close() end)
        end (GOTCHA 2 pcall); if rx then rx:reset() end; clear state.pipe/rx/on_ready/on_event/on_close
        (so a stale cb cannot fire post-teardown). Idempotent. NEVER throws.
  - M.on_exit(buf): M.close() (buf accepted to match the S22 dispatch signature, ignored at transport
        layer — autosave is S38). Safe no-op when never connected (GOTCHA 12).
  - M.is_connected(): return state.connected == true and not state.closed.
  - NO vim.api.* calls (GOTCHA 5). NO hello/id-correlation/notifications (S25/S26/S27).
  - PLACEMENT: plugin/lua/pi-editor/bridge.lua.

Task 2: CREATE plugin/tests/bridge_smoke.lua  (plenary-FREE fast smoke — the Level-1 gate)
  - CONTENT (see Implementation Patterns): standalone script. Spins a real luv unix-socket SERVER
        in-process (the jsonlreader_spec.lua Level-3 pattern), then calls bridge.connect(real_path, …),
        asserts on_ready(nil) + is_connected(); send()s a request; asserts the server received the
        JSONL line + the server's response reached on_event; closes the server to trigger on_close(nil)
        (EOF); then tests connect-failure (on_ready("ENOENT")) and double-close-safety. cquit(1) on fail.
  - WHY: instant, dependency-free feedback (no plenary). bridge_spec.lua is the formal suite.
  - GOTCHA: source via :luafile, NOT a :lua <<HEREDOC in a -c/+ arg (inherited S19 GOTCHA #10).
  - GOTCHA: pace the async luv callbacks with vim.defer_fn + vim.wait (the event loop drives connect/
        read/write; assertions run after vim.wait settles).
  - PLACEMENT: plugin/tests/bridge_smoke.lua.
  - DEPENDENCIES: Task 1 + the S23 jsonlreader (DONE).

Task 3: CREATE plugin/tests/bridge_spec.lua  (plenary/busted spec — the Level-2 gate)
  - CONTENT (see Implementation Patterns): a describe("pi-editor.bridge", ...). Cover ALL Success
        Criteria as `it` blocks (connect success, connect ENOENT, connect ECONNREFUSED, read→jsonlreader
        →on_event single/drain/buffered, send helper round-trip, multi-write queueing, EPIPE→on_close,
        EOF→on_close(nil)+flush, double-close-safe, on_exit no-op-when-not-connected, send-before-connect
        /after-close returns false, is_connected transitions). Each case spins its OWN luv server
        (unique socket path) for isolation.
  - ASSERTIONS: assert.are.same (deep, for decoded tables), assert.are.equals, assert.is_true/is_nil,
        assert.has_no.errors for the no-throw checks. Use a small helper `with_server(cb)` that binds a
        luv server, calls cb with the path + a close-hook, and tears down in a vim.defer_fn.
  - PLACEMENT: plugin/tests/bridge_spec.lua.
  - DEPENDENCIES: Task 1 + the S19 harness (plugin/tests/minimal_init.lua).
```

### Implementation Patterns & Key Details

```lua
-- === plugin/lua/pi-editor/bridge.lua — the FULL reference implementation (LIVE-VERIFIED primitives) ===
-- luv (vim.uv) Unix-domain-socket CLIENT for the pi-bridge.nvim bridge. Owns the TRANSPORT layer of
-- parent task P2.M5.T15 ("Socket client & handshake"): connect, read_start (→ jsonlreader), write
-- helper, idempotent close. The CLIENT counterpart of the COMPLETE extension-side
-- connection.ts + jsonl-reader.ts IPC server (P1.M2 — PRD §16).
--
-- [Mode A] header — read before editing:
--  * TRANSPORT/PROTOCOL SPLIT: S24 = transport only. The `hello` handshake (token) is S25; `request()`
--    RPC id-correlation/supersession is S26; `commandsChanged` notification handling is S27; wiring
--    connect() into the activation flow is S25 (first protocol consumer). S24 provides the callbacks
--    (on_ready/on_event/on_close) + send() those tasks compose. connect() takes `path` ONLY (no token).
--  * LUV ERROR CATALOG (GOTCHA 1, LIVE-VERIFIED research/notes.md §2): connect/read/write errors are
--    delivered in the callback as the BARE errno-name string: "ENOENT" (no socket), "ECONNREFUSED"
--    (file / not listening), "EACCES" (perms), "EPIPE" (write to closed peer), "ECONNRESET" (read).
--  * DOUBLE-CLOSE THROWS (GOTCHA 2): pipe:close() on an already-closing handle raises 'handle 0x..
--    is already closing'. close() is guarded by a shadow `state.closed` flag (set FIRST) +
--    is_closing() + pcall. Idempotent across on_close/on_exit/VimLeavePre/error paths.
--  * EPIPE IN CB ONLY (GOTCHA 3): a broken-pipe write does NOT throw — only the write callback gets
--    werr="EPIPE". send() ALWAYS passes a cb that routes werr to on_close. Never swallow it.
--  * EOF = flush THEN on_close (GOTCHA 4): read_start (nil,nil) → rx:flush() (trailing line still
--    delivered via on_event) → on_close(nil).
--  * NO vim.api.* (GOTCHA 5): pure vim.uv + vim.json + jsonlreader. Safe in luv callbacks (E5560 rule).
--    The on_event CONSUMER schedules nvim work.
--  * SINGLETON STATE (GOTCHA 10): one pipe/rx/callback-set (one pi session = one bridge conn, PRD §11).

local uv = vim.uv
local jreader = require("pi-editor.jsonlreader")
local M = {}

--- Singleton transport state. `pipe`/`rx`/callbacks are nil before connect and after close.
--- `closed` is the shadow flag that defends the luv double-close THROW (set FIRST in close()).
---@type pi-editor.BridgeState
local state = { pipe = nil, rx = nil, on_ready = nil, on_event = nil, on_close = nil, connected = false, closed = false }

--- The read_start callback. Routes chunks to the jsonlreader; EOF/errors to on_close + teardown.
--- Runs on the libuv loop (no vim.api here — GOTCHA 5). Never throws.
local function read_cb(err, data)
  if state.closed then return end
  if err then                                   -- read error (e.g. "ECONNRESET")
    local cb = state.on_close; M.close(); if cb then cb(err) end; return
  end
  if data == nil then                           -- EOF (err==nil && data==nil) — GOTCHA 4
    if state.rx then state.rx:flush() end       -- deliver any trailing line via on_event FIRST
    local cb = state.on_close; M.close(); if cb then cb(nil) end; return
  end
  if state.rx then state.rx:feed(data) end      -- frame + decode -> on_event(table) (S23)
end

--- Open the socket transport. `path` is descriptor.path (S21). Callbacks (forward contracts):
---   on_ready(err)  — connect result (err==nil ok; errno string on fail). S25 sends hello here.
---   on_event(msg)  — each decoded JSON-RPC table (S25 validates hello; S26 correlates; S27 notifies).
---   on_close(reason) — connection lost (nil=clean EOF; errno string=socket error). Triggers teardown.
--- Idempotent re-init: closes any prior connection first. NEVER throws.
---@param path string Unix domain socket path (descriptor.path).
---@param on_ready fun(err:string?) Connect-result callback (called exactly once).
---@param on_event? fun(msg:table) Per-decoded-message callback (synchronous from read_start).
---@param on_close? fun(reason:string?) Connection-lost callback.
function M.connect(path, on_ready, on_event, on_close)
  M.close()  -- idempotent re-init (close any prior connection; sets state.closed, then we reset below)
  state = { pipe = uv.new_pipe(false), rx = jreader.new(on_event or function() end),
            on_ready = on_ready, on_event = on_event, on_close = on_close,
            connected = false, closed = false }
  local pipe = state.pipe
  -- pcall-wrap the connect call (programming errors throw; connect FAILURES come back in the cb).
  local ok, cerr = pcall(function()
    pipe:connect(path, function(connerr)
      if state.closed then return end
      if connerr then                       -- GOTCHA 1: bare errno string ("ENOENT"/"ECONNREFUSED"/"EACCES")
        local cb = state.on_ready; M.close(); if cb then cb(connerr) end; return
      end
      pipe:read_start(read_cb)              -- wire S23's jsonlreader to the socket
      state.connected = true                -- GOTCHA 6: send() is now legal
      if state.on_ready then state.on_ready(nil) end
    end)
  end)
  if not ok then                            -- programming error (bad arg, etc.) -> degrade
    local cb = on_ready; M.close(); if cb then cb(tostring(cerr)) end
  end
end

--- Write helper: serialize a JSON-RPC envelope + "\n" and queue an ordered pipe:write.
--- Returns false (no-op) if not connected / closing / closed (GOTCHA 6/7). The write CALLBACK always
--- routes a broken-pipe err to on_close (GOTCHA 3 — EPIPE is reported ONLY in the cb).
---@param obj table JSON-RPC envelope (or any JSON-serializable table).
---@return boolean queued true if the write was queued; false if dropped (not connected / closed).
function M.send(obj)
  if not state.connected or state.closed then return false end       -- GOTCHA 6
  local pipe = state.pipe
  if pipe == nil or pipe:is_closing() then return false end           -- GOTCHA 7
  local data = vim.json.encode(obj) .. "\n"                           -- GOTCHA 11 (serializeJsonLine twin)
  local ok = pcall(function()
    pipe:write(data, function(werr)
      if werr then                                                    -- GOTCHA 3: "EPIPE" etc.
        local cb = state.on_close; M.close(); if cb then cb(werr) end
      end
    end)
  end)
  return ok
end

--- Idempotent teardown. Guards the luv double-close THROW (GOTCHA 2) with a shadow `closed` flag
--- (set FIRST) + is_closing() + pcall. Safe across on_close / on_exit / VimLeavePre / error paths.
--- Clears state so a stale callback cannot fire post-teardown. NEVER throws.
function M.close()
  if state.closed then return end                  -- GOTCHA 2: shadow flag, set FIRST
  state.closed = true
  state.connected = false
  local pipe = state.pipe
  if pipe and not pipe:is_closing() then           -- GOTCHA 2: guard + pcall the close
    pcall(function() pipe:close() end)
  end
  if state.rx then state.rx:reset() end            -- drop any partial line
  -- clear refs so a stale luv cb cannot touch dead state
  state.pipe = nil; state.rx = nil
  state.on_ready = nil; state.on_event = nil; state.on_close = nil
end

--- VimLeavePre/ExitPre handler — fulfills the S22 ftplugin forward contract
--- (`require("pi-editor.bridge").on_exit(buf)`). Closes the transport. `buf` is accepted to match the
--- dispatch signature and ignored at the transport layer (autosave is S38's job, dispatched separately).
--- Safe NO-OP when never connected (GOTCHA 12 — connect() is not wired until S25). NEVER throws.
---@param buf integer Buffer handle (unused at transport layer; matches the ftplugin dispatch signature).
function M.on_exit(buf)  -- luacheck: ignore buf (transport layer; autosave is S38)
  M.close()
end

--- Read-only accessor: true only between on_ready(nil) and the start of teardown.
---@return boolean
function M.is_connected()
  return state.connected and not state.closed
end

return M
```

```lua
-- === plugin/tests/bridge_smoke.lua — standalone (plenary-FREE) smoke test ===
-- Spins a REAL luv unix-socket server in-process, then exercises bridge.connect/send/close end-to-end.
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/bridge_smoke.lua" +qa ; echo exit=$?
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h")           -- .../plugin (rtp entry)
vim.opt.runtimepath:append(plugin_root)

local uv = vim.uv
local bridge = require("pi-editor.bridge")
local jreader = require("pi-editor.jsonlreader")
local fails = 0
local function check(cond, msg) if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); fails = fails + 1 end end

-- helper: spin a luv unix-socket server that mirrors the bridge extension (decodes client JSONL,
-- echoes a JSONL response for each request). Returns (path, stop_fn).
local function start_server(on_request)
  local path = "/tmp/pi-bridge-smoke-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
  os.remove(path)
  local srv = uv.new_pipe(false); srv:bind(path)
  local srv_rx = jreader.new(function(req)
    if req.id then
      local resp = vim.json.encode({jsonrpc="2.0", id=req.id, result={ok=true}}) .. "\n"
      srv_conn:write(resp)
    end
    if on_request then on_request(req) end
  end)
  local srv_conn
  srv:listen(128, function()
    srv_conn = uv.new_pipe(false); srv:accept(srv_conn)
    srv_conn:read_start(function(rerr, data)
      if rerr or data == nil then if data == nil and srv_conn then srv_conn:close() end; return end
      srv_rx:feed(data)
    end)
  end)
  return path, function()
    if srv_conn and not srv_conn:is_closing() then pcall(function() srv_conn:close() end) end
    if srv and not srv:is_closing() then pcall(function() srv:close() end) end
    os.remove(path)
  end
end

-- ── CASE 1: connect success + send round-trip + on_event ──────────────────
do
  local path, stop = start_server()
  local got_ready, got_event, got_msg
  bridge.connect(path,
    function(err) got_ready = err end,                                 -- on_ready
    function(msg) got_event = true; got_msg = msg end,                 -- on_event
    function(reason) end)                                              -- on_close
  vim.wait(100, function() return got_ready ~= nil end, 10)            -- wait for connect
  check(got_ready == nil, "connect success: on_ready(nil) (got " .. tostring(got_ready) .. ")")
  check(bridge.is_connected(), "is_connected() true after on_ready(nil)")
  bridge.send({jsonrpc="2.0", id="r1", method="ping", params={}})
  vim.wait(100, function() return got_event end, 10)                   -- wait for echo response
  check(got_event and got_msg and got_msg.id == "r1" and got_msg.result and got_msg.result.ok,
    "send round-trip: on_event got the response {id=r1, result.ok=true}")
  stop()
  vim.wait(80)                                                         -- let on_close(EOF) settle
end

-- ── CASE 2: connect failure (ENOENT) — bare errno string ──────────────────
do
  local got
  bridge.connect("/tmp/pi-bridge-nope-" .. os.time() .. ".sock",
    function(err) got = err end, function() end, function() end)
  vim.wait(100, function() return got ~= nil end, 10)
  check(got == "ENOENT", "connect nonexistent -> on_ready('ENOENT') (got " .. tostring(got) .. ")")
  check(not bridge.is_connected(), "is_connected() false after connect failure")
end

-- ── CASE 3: double-close safe + on_exit no-op ─────────────────────────────
do
  bridge.close(); bridge.close()                                       -- must NOT throw
  bridge.on_exit(0)                                                     -- no-op when not connected
  check(true, "double-close + on_exit(no-connect): no throw")
end

if fails > 0 then io.stderr:write(fails .. " check(s) failed\n"); vim.cmd("cquit 1") end
io.stdout:write("SMOKE_PASS\n")
```

```lua
-- === plugin/tests/bridge_spec.lua — the spec (covers every Success Criterion) ===
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/bridge_spec.lua")'
local uv = vim.uv
local bridge = require("pi-editor.bridge")
local jreader = require("pi-editor.jsonlreader")

-- helper: a fresh luv server mirroring the bridge extension. cb(path, stop). Each test gets a unique socket.
local function with_server(spec)
  return function()
    local path = "/tmp/pi-bridge-spec-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
    os.remove(path)
    local srv = uv.new_pipe(false); srv:bind(path)
    local srv_rx, srv_conn
    local requests = {}
    srv_rx = jreader.new(function(req) requests[#requests+1] = req; if req.id and srv_conn then
      srv_conn:write(vim.json.encode({jsonrpc="2.0", id=req.id, result={ok=true}}) .. "\n") end end)
    srv:listen(128, function()
      srv_conn = uv.new_pipe(false); srv:accept(srv_conn)
      srv_conn:read_start(function(rerr, data) if rerr or data == nil then return end; srv_rx:feed(data) end)
    end)
    local function stop()
      if srv_conn and not srv_conn:is_closing() then pcall(function() srv_conn:close() end) end
      if srv and not srv:is_closing() then pcall(function() srv:close() end) end
      os.remove(path); bridge.close()
    end
    spec(path, requests, stop)
  end
end

describe("pi-editor.bridge", function()
  -- (a) connect success + is_connected + on_ready(nil)
  it("connects and fires on_ready(nil); is_connected() true", with_server(function(path, _, stop)
    local got
    bridge.connect(path, function(err) got = err end, function() end, function() end)
    assert.is_nil(vim.wait(150, function() return got ~= nil end, 5))
    assert.is_nil(got)
    assert.is_true(bridge.is_connected())
    vim.wait(20); stop()
  end))

  -- (b) connect failure -> bare errno string; not connected; no throw
  it("reports on_ready('ENOENT') for a nonexistent socket", function()
    local got
    assert.has_no.errors(function()
      bridge.connect("/tmp/pi-bridge-none-" .. os.time() .. ".sock",
        function(err) got = err end, function() end, function() end)
    end)
    assert.is_nil(vim.wait(150, function() return got ~= nil end, 5))
    assert.are.equals("ENOENT", got)
    assert.is_false(bridge.is_connected())
    bridge.close()
  end)

  it("reports on_ready('ECONNREFUSED') for a regular file", function()
    local f = "/tmp/pi-bridge-file-" .. os.time() .. ".txt"; local fh = io.open(f, "w"); fh:write("x"); fh:close()
    local got
    bridge.connect(f, function(err) got = err end, function() end, function() end)
    assert.is_nil(vim.wait(150, function() return got ~= nil end, 5))
    assert.are.equals("ECONNREFUSED", got)
    os.remove(f); bridge.close()
  end)

  -- (c) read -> jsonlreader -> on_event (proves S23 is wired into read_start)
  it("delivers decoded JSON-RPC responses to on_event", with_server(function(path, _, stop)
    local msgs = {}
    bridge.connect(path, function() end, function(m) msgs[#msgs+1] = m end, function() end)
    vim.wait(120, function() return bridge.is_connected() end, 5)
    bridge.send({jsonrpc="2.0", id="r1", method="ping"})
    bridge.send({jsonrpc="2.0", id="r2", method="ping"})   -- multi-write queueing
    assert.is_nil(vim.wait(150, function() return #msgs >= 2 end, 5))
    assert.are.equals("r1", msgs[1].id); assert.are.equals("r2", msgs[2].id)   -- in order
    vim.wait(20); stop()
  end))

  -- (d) send round-trip: server received exactly encode(obj).."\n"
  it("send() delivers encode(obj)..\\n to the server", with_server(function(path, requests, stop)
    bridge.connect(path, function() end, function() end, function() end)
    vim.wait(120, function() return bridge.is_connected() end, 5)
    bridge.send({jsonrpc="2.0", id="x", method="ping", params={a=1}})
    assert.is_nil(vim.wait(150, function() return #requests >= 1 end, 5))
    assert.are.equals("x", requests[1].id); assert.are.equals("ping", requests[1].method)
    assert.are.same({a=1}, requests[1].params)
    vim.wait(20); stop()
  end))

  -- (e) EOF (server closes) -> rx:flush + on_close(nil); is_connected false
  it("fires on_close(nil) on clean EOF after flushing", with_server(function(path, _, stop)
    local closed
    bridge.connect(path, function() end, function() end, function(reason) closed = reason end)
    vim.wait(120, function() return bridge.is_connected() end, 5)
    stop()  -- server closes -> client EOF
    assert.is_nil(vim.wait(150, function() return closed ~= nil end, 5))
    assert.is_nil(closed)                 -- clean EOF
    assert.is_false(bridge.is_connected())
  end))

  -- (f) double-close safe (no throw) + on_exit no-op when not connected
  it("close() is idempotent (double-close does not throw)", function()
    assert.has_no.errors(function() bridge.close(); bridge.close(); bridge.on_exit(0) end)
  end)

  -- (g) send before connect / after close -> false, no throw
  it("send() returns false before connect and after close", function()
    bridge.close()
    local ok = bridge.send({jsonrpc="2.0", id="z", method="ping"})
    assert.is_false(ok)
  end)
end)
```

### Integration Points

```yaml
MODULE SURFACE EXPOSED (the forward contracts S25/S26/S27/S38 consume):
  - require("pi-editor.bridge").connect(path, on_ready, on_event, on_close)
      path     = descriptor.path (S21). on_ready(err) -> S25 sends hello on err==nil.
      on_event = per decoded JSON-RPC table -> S25 validates hello resp; S26 correlates by id + drops
                 stale; S27 branches on msg.method=="commandsChanged". (Synchronous from read_start —
                 consumer vim.schedule's nvim work.)
      on_close = connection lost (nil=EOF; errno string) -> S39 one-time notify; teardown.
  - require("pi-editor.bridge").send(obj) -> bool   (S25 sends hello; S26 sends requests; S38 sends bye)
  - require("pi-editor.bridge").close()              (S38 teardown; internal on EOF/error)
  - require("pi-editor.bridge").on_exit(buf)         (S22 ftplugin ALREADY dispatches this — FULFILLED)
  - require("pi-editor.bridge").is_connected()       (S30+ completion gating; tests)

CONSUMER WIRING (NOT in S24 — S25's job):
  - S25 reads require("pi-editor").descriptor, calls bridge.connect(descriptor.path, …), and in
    on_ready(nil) sends hello via bridge.send({jsonrpc="2.0", id="h1", method="hello",
    params={token=descriptor.token, client="pi-bridge.nvim"}}). on_event validates the hello response
    and then sets require("pi-editor").bridge = <rpc facade> (the S26 request() API). Until S25,
    require("pi-editor").bridge stays the nil placeholder (init.lua S19).

FULFILLED FORWARD CONTRACT (S22):
  - plugin/ftplugin/pi-prompt.lua ALREADY dispatches require("pi-editor.bridge").on_exit(buf) on
    VimLeavePre/ExitPre (gated on config.autosave_on_exit). S24 MERELY defines on_exit (the dispatch
    helper pcall's + no-ops if absent). on_exit is a safe no-op when connect() was never called
    (S24 ships before S25 wires connect) — GOTCHA 12.

NO DATABASE / NO NETWORK (beyond the local socket) / NO CONFIG / NO EXISTING-FILE EDITS.
The module's ONLY side effects are: opening/closing a luv pipe to the local socket path, invoking the
caller's on_ready/on_event/on_close callbacks, and (via jsonlreader) vim.json.decode. It touches no nvim
state (no buffers/windows/opts) — the consumer schedules that work.
```

## Validation Loop

> **Run all commands from the REPO ROOT** (`/home/dustin/projects/pi-nvim-bridge`).
> The plugin root is `$(pwd)/plugin`. **Every luv behavior the bridge relies on is LIVE-VERIFIED** on
> Neovim 0.12.4 (see `research/notes.md` §1–§8, incl. a full end-to-end JSONL round-trip probe). NOTE:
> `nvim --headless --clean -u NORC` prints a benign `Error in .../syntax/syntax.vim: E216: No such group
> or event: filetypedetect BufRead` (an nvim filetype/syntax init artifact, NOT from our code; exit
> stays 0). Judge pass/fail by our markers (`SMOKE_PASS`, the plenary `Success:`/`Failed:` line) and
> `$?`, not that warning. The luv callbacks are async — the smoke/spec use `vim.wait`/`vim.defer_fn` to
> pace the event loop (connect/read/write fire on the libuv loop, not synchronously).

### Level 1: Syntax & Load (Immediate Feedback — dependency-free, no plenary)

```bash
# 1a. Smoke test via the deliverable plugin/tests/bridge_smoke.lua (plenary-FREE fast feedback).
#     Spins a REAL luv unix-socket server in-process and exercises connect success + send round-trip +
#     on_event, connect-failure (ENOENT), and double-close-safety. NO :lua <<HEREDOC (GOTCHA from S19).
#     Run from REPO ROOT.
nvim --headless --clean -u NORC +"luafile plugin/tests/bridge_smoke.lua" +qa
echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
```

```bash
# 1b. (Optional, only if installed) Lua lint/format. NOT a hard gate (inherited S19 GOTCHA #8).
command -v selene >/dev/null && selene -q plugin/lua/pi-editor/bridge.lua plugin/tests/bridge_smoke.lua plugin/tests/bridge_spec.lua || echo "selene not installed (skipped; optional)"
command -v stylua >/dev/null && stylua --check plugin/lua/pi-editor/bridge.lua plugin/tests/bridge_smoke.lua plugin/tests/bridge_spec.lua || echo "stylua not installed (skipped; optional)"
```

### Level 2: Unit Tests (plenary spec)

```bash
# 2a. In-process plenary run (reuses the S19 minimal_init.lua — puts plugin/ on rtp + plenary on rtp).
cd plugin
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_spec.lua")'
echo "exit=$?   # 0 = all pass (8 it blocks)"
cd ..
```

```bash
# 2b. NON-REGRESSION — the S19 + S20 + S21 + S22 + S23 suites MUST still pass (S24 touches NO existing file).
cd plugin
for s in init_spec shim_spec activate_spec ftplugin_spec jsonlreader_spec; do
  nvim --headless --clean -u tests/minimal_init.lua -c "lua require('plenary.busted').run('tests/$s.lua')"
  echo "$s exit=$?"
done
cd ..
# Expected: init_spec=0 (13), shim_spec=0 (6), activate_spec=0 (9), ftplugin_spec=0 (13), jsonlreader_spec=0 (16).
```

### Level 3: Integration (wire bridge.lua against a REAL luv server + the REAL jsonlreader — proves connect/read/write/EOF/EPIPE end-to-end)

```bash
# 3a. End-to-end transport proof. Spin a luv unix-socket server in nvim (mirroring the bridge extension),
#     connect the REAL bridge.lua client, send a JSONL request, assert the server received it AND the
#     client's on_event got the response, then close the server to trigger client on_close(EOF). Also
#     probes EPIPE (write after server close) and the double-close-safety. This is the canonical proof
#     that S24's connect/read_start/write/close survive real async luv semantics (the LIVE-VERIFIED
#     research/notes.md §8 round-trip, now driven through the actual module).
cat > /tmp/s24_integration.lua <<'LUA'
local uv = vim.uv
local PLUGIN_ROOT = "/home/dustin/projects/pi-nvim-bridge/plugin"
package.path = PLUGIN_ROOT .. "/lua/?.lua;" .. package.path
local bridge = require("pi-editor.bridge")
local jreader = require("pi-editor.jsonlreader")

local path = "/tmp/s24-it-" .. os.time() .. ".sock"; os.remove(path)
local srv = uv.new_pipe(false); srv:bind(path)
local srv_reqs = {}
local srv_rx = jreader.new(function(r) srv_reqs[#srv_reqs+1] = r
  if r.id then srv_conn:write(vim.json.encode({jsonrpc="2.0", id=r.id, result={ok=true}}) .. "\n") end end)
local srv_conn
srv:listen(128, function()
  srv_conn = uv.new_pipe(false); srv:accept(srv_conn)
  srv_conn:read_start(function(e, d) if e or d == nil then return end; srv_rx:feed(d) end)
end)

local ready, events, closed = nil, {}, nil
bridge.connect(path,
  function(err) ready = err end,
  function(msg) events[#events+1] = msg end,
  function(reason) closed = reason end)

vim.defer_fn(function()
  -- after connect: send a request, expect round-trip
  io.stdout:write("[it] ready=" .. tostring(ready) .. " connected=" .. tostring(bridge.is_connected()) .. "\n")
  bridge.send({jsonrpc="2.0", id="r1", method="ping"})
  vim.defer_fn(function()
    io.stdout:write("[it] srv_reqs=" .. #srv_reqs .. " client_events=" .. #events .. "\n")
    -- close the server -> client EOF -> on_close(nil)
    if srv_conn and not srv_conn:is_closing() then srv_conn:close() end
    if srv and not srv:is_closing() then srv:close() end
    os.remove(path)
    vim.defer_fn(function()
      io.stdout:write("[it] closed=" .. tostring(closed) .. " (nil=clean EOF)\n")
      local ok = ready == nil and bridge.is_connected() == false
        and #srv_reqs == 1 and srv_reqs[1].id == "r1"
        and #events == 1 and events[1].id == "r1" and events[1].result.ok == true
        and closed == nil
      -- double-close safety
      bridge.close(); bridge.close()
      io.stdout:write(ok and "INTEGRATION_PASS\n" or "INTEGRATION_FAIL\n")
      if not ok then vim.cmd("cquit 1") end
    end, 60)
  end, 60)
end, 60)
LUA
nvim --headless --clean -u NORC +"luafile /tmp/s24_integration.lua" +"lua vim.wait(800)" +qa 2>&1 | grep -v 'E216\|filetypedetect'
# Expected: ready=nil connected=true ... srv_reqs=1 client_events=1 ... closed=nil ... INTEGRATION_PASS
#   (connect ok; request delivered; response decoded via jsonlreader; clean EOF -> on_close(nil);
#    double-close did not throw).
```

```bash
# 3b. EPIPE + connect-failure proof. Connect to a nonexistent socket (expect on_ready('ENOENT')), and
#     separately write to a socket whose server closed (expect the write cb err routed to on_close).
cat > /tmp/s24_errors.lua <<'LUA'
local uv = vim.uv
package.path = "/home/dustin/projects/pi-nvim-bridge/plugin/lua/?.lua;" .. package.path
local bridge = require("pi-editor.bridge")
local jreader = require("pi-editor.jsonlreader")

-- (1) ENOENT
local enoent
bridge.connect("/tmp/s24-nope-" .. os.time() .. ".sock", function(err) enoent = err end, function() end, function() end)
-- (2) EPIPE: server accepts then immediately closes
local path = "/tmp/s24-epipe-" .. os.time() .. ".sock"; os.remove(path)
local srv = uv.new_pipe(false); srv:bind(path)
local epipe_closed
srv:listen(128, function()
  local c = uv.new_pipe(false); srv:accept(c)
  vim.defer_fn(function() c:close() end, 30)   -- close right after accept -> client write -> EPIPE
end)
bridge.connect(path, function(err)
  if err then return end
  -- connected; wait for server to close, then write -> EPIPE in cb -> on_close
  vim.defer_fn(function() bridge.send({jsonrpc="2.0", id="x", method="ping"}) end, 60)
end, function() end, function(reason) epipe_closed = reason end)

vim.defer_fn(function()
  if srv and not srv:is_closing() then srv:close() end; os.remove(path)
  io.stdout:write("[err] enoent=" .. tostring(enoent) .. " epipe_closed=" .. tostring(epipe_closed) .. "\n")
  local ok = enoent == "ENOENT" and epipe_closed == "EPIPE"
  io.stdout:write(ok and "ERRORS_PASS\n" or "ERRORS_FAIL\n")
  if not ok then vim.cmd("cquit 1") end
end, 250)
LUA
nvim --headless --clean -u NORC +"luafile /tmp/s24_errors.lua" +"lua vim.wait(600)" +qa 2>&1 | grep -v 'E216\|filetypedetect'
# Expected: enoent=ENOENT epipe_closed=EPIPE ... ERRORS_PASS
#   (connect-failure bare-errno string; broken-pipe write err routed to on_close — GOTCHA 1 + 3).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# 4a. on_exit forward-contract fulfillment (S22). Simulate the ftplugin's dispatch: with NO prior
#     connect() (the S24-ships-before-S25-wires state), call require("pi-editor.bridge").on_exit(buf)
#     and assert it is a safe no-op (no throw, no error). Then call connect+close+on_exit and assert
#     on_exit after a real connection also tears down cleanly. This proves S22's forward contract is
#     fulfilled WITHOUT a real pi session.
nvim --headless --clean -u NORC --cmd "let &runtimepath=&runtimepath.',$(pwd)/plugin'" +"lua
  local bridge = require('pi-editor.bridge')
  -- (1) no-op when never connected (the S24 pre-S25 state)
  local ok1 = pcall(function() bridge.on_exit(0) end)
  -- (2) idempotent across on_exit + close
  local ok2 = pcall(function() bridge.close(); bridge.on_exit(0); bridge.on_exit(0) end)
  assert(ok1 and ok2, 'on_exit must not throw (no-connect / double / post-close)')
  io.stdout:write('ONEXIT_PASS\n')
" +qa 2>&1 | grep -v 'E216\|filetypedetect'
# Expected: ONEXIT_PASS  (S22's forward contract fulfilled; safe no-op when not connected).

# 4b. (Manual, optional) End-to-end with the REAL bridge extension. If a dev wants to prove the full
#     stack: install the extension (cp extension/pi-editor-bridge.ts ~/.pi/agent/extensions/), start pi
#     in a project, press Ctrl+G to open the editor (nvim), and `:lua print(vim.inspect(require(
#     'pi-editor').descriptor))` to confirm path/token are present. S24 alone will NOT yet show
#     completion (connect() is not wired until S25) — this manual check only confirms the descriptor is
#     available for S25 to consume. NOT a hard gate for S24 (deferred to S25's validation).
```

## Final Validation Checklist

### Technical Validation

- [ ] All 4 validation levels completed successfully (Level 1 smoke `SMOKE_PASS`; Level 2 spec exit 0;
      Level 3 `INTEGRATION_PASS` + `ERRORS_PASS`; Level 4 `ONEXIT_PASS`).
- [ ] plenary suite: `cd plugin && nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/bridge_spec.lua")'` exits 0.
- [ ] No lint regressions if selene/stylua are installed (optional; not a hard gate).

### Feature Validation

- [ ] All success criteria from "What" section met (connect success + 2 failure modes, read→jsonlreader
      →on_event, send round-trip + multi-write queueing, EPIPE→on_close, EOF→on_close(nil)+flush,
      double-close-safe, on_exit no-op-when-not-connected, send-gating, is_connected transitions).
- [ ] Manual transport proof successful: the Level-3 real-server integration (connect → send →
      on_event response → server-close → on_close(nil) → double-close safe).
- [ ] Edge cases handled gracefully: connect-failure (silent-degrade via on_ready errno; PRD §11),
      broken pipe (EPIPE → on_close), EOF (flush + on_close(nil)), double-close (guarded, no throw),
      send-before-connect / after-close (false, no-op).
- [ ] The `connect`/`send`/`close`/`on_exit`/`is_connected` forward contract is exactly what S25
      (`hello`), S26 (`request()`), S27 (`commandsChanged`), and S38 (teardown) will consume
      (PRD §7.3 skeleton + the on_ready/on_event/on_close callback shape).

### Code Quality Validation

- [ ] Follows existing codebase patterns: `local M` / `return M` module convention, [Mode A] LuaCATS
      docstrings (matching `init.lua` S19 / `jsonlreader.lua` S23), standalone smoke + plenary spec
      two-file test convention (matching S20/S21/S22/S23).
- [ ] File placement matches the desired codebase tree (`plugin/lua/pi-editor/bridge.lua`).
- [ ] Anti-patterns avoided (see below): no unguarded `close()` (double-close THROW), no callback-less
      `write` (swallowed EPIPE), no `vim.api.*` in callbacks (E5560), no decode of raw chunks (S23 owns
      framing), no instance-based state (singleton client).
- [ ] No new runtime dependencies (only `vim.uv` + `vim.json` + the DONE `jsonlreader`, all built in).

### Documentation & Deployment

- [ ] [Mode A] header comment documents: purpose, CLIENT counterpart lineage, the LIVE-VERIFIED luv
      error catalog (GOTCHA 1), double-close guard (GOTCHA 2), EPIPE-in-cb (GOTCHA 3), EOF-flush
      (GOTCHA 4), the vim.schedule rule (GOTCHA 5), singleton-state rationale (GOTCHA 10), the
      transport/protocol split, and the forward contracts S25/S26/S27/S38 consume.
- [ ] Per-method LuaCATS docstrings (`connect`/`send`/`close`/`on_exit`/`is_connected`) with
      `@param`/`@return`/`@class`.
- [ ] No new environment variables / config / files beyond the 3 deliverables.

---

## Anti-Patterns to Avoid

- ❌ Don't call `pipe:close()` without guarding `is_closing()` + a shadow `closed` flag + `pcall`
  (double-close THROWS `handle 0x.. is already closing`; GOTCHA 2 — LIVE-VERIFIED).
- ❌ Don't call `pipe:write(data)` without a callback that routes `err` to `on_close` (EPIPE is
  reported ONLY in the callback; a callback-less write silently swallows the broken-pipe error and
  completion hangs; GOTCHA 3 — LIVE-VERIFIED).
- ❌ Don't call any `vim.api.*` from a luv callback (throws `E5560: ... must not be called in a fast
  event context`; GOTCHA 5 — LIVE-VERIFIED). bridge.lua does none; the `on_event` consumer schedules.
- ❌ Don't decode raw `read_start` chunks inline (chunk boundaries are ARBITRARY — 4 writes → 2 chunks;
  GOTCHA 8). ALWAYS feed the jsonlreader (S23) — it owns framing+decode.
- ❌ Don't conflate EOF with a read error (EOF = `err==nil && data==nil`; GOTCHA 4). Flush the
  jsonlreader BEFORE `on_close(nil)` so a trailing line is still delivered.
- ❌ Don't gate `send()` only on `pipe:is_closing()` (writing BEFORE the connect callback fires is a
  silent byte-drop; GOTCHA 6). Gate on a `state.connected` flag set true ONLY inside the connect
  success path.
- ❌ Don't make bridge.lua instance-based (the nvim CLIENT is a singleton — one pi session = one bridge
  connection, PRD §11; GOTCHA 10). Module-level state is correct; an instance model would fight the
  `require("pi-editor").bridge` placeholder S25 sets after handshake.
- ❌ Don't reimplement what the COMPLETE `extension/connection.ts` + `jsonl-reader.ts` already proved —
  mirror the lifecycle (attach reader → read → dispatch → write serializeJsonLine → error/close) and
  the wire form (`encode(obj).."\n"`); diverge ONLY on the singleton-vs-instance + client-callback model.
- ❌ Don't ship `connect()` wired into activation in S24 (that is S25's job — the first protocol
  consumer). S24 ships the tested module + the `on_exit` fulfillment; `M.bridge` stays `nil` until S25.