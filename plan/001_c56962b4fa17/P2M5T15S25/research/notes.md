# Research Notes — P2.M5.T15.S25 (`hello` handshake, Lua client)

> Scope: AFTER the S24 transport (`bridge.connect/send/close/on_exit/is_connected`)
> connects, **send the JSON-RPC `hello` request with the descriptor token, validate the
> server's success/error response, extract `serverVersion`/`cwd`/`fdAvailable`, and wire
> connect+handshake into the VimEnter activation flow.** Sets `require("pi-editor").bridge`
> on success; degrades silently on any failure (PRD §11).

## 0. The authoritative contracts (READ FIRST)

| Concern | File (repo-relative) | Why it's authoritative |
|---|---|---|
| Transport the handshake rides on (S24, DONE) | `plugin/lua/pi-editor/bridge.lua` | `connect(path,on_ready,on_event,on_close)` + `send(obj)` + `close()`. Its header is the S24→S25 forward contract: *"S25 sends hello in on_ready; S25 validates hello in on_event; the `require("pi-editor").bridge` placeholder S25 sets after handshake."* |
| Server `hello` handler (DONE, P1.M2.T5.S9) | `extension/pi-editor-bridge.ts` `makeHelloHandler` (~L500) | Token match ⇒ `{ok:true,serverVersion,cwd,fdAvailable}` + flips `handshakeComplete`; any mismatch/missing/stopped ⇒ `throw BridgeRpcError(-32600,"bad token",{fatal:true})` ⇒ `handleLine` replies `-32600` THEN `sock.end()` (close). **Message is literal `"bad token"`; token NEVER in the message (PRD §12).** |
| Wire types (DONE, P1.M1.T2.S4) | `extension/protocol.ts` | `HelloParams{token,client?,clientVersion?}`, `HelloResult{ok:true,serverVersion,cwd,fdAvailable}`. `id` is `string` (PRD §5.3 restricts). `commandsChanged` is a notification (no id). |
| Dispatch / fatal-close (DONE, S8/S10) | `extension/connection.ts` `handleLine` | Request branch: handler returns ⇒ `sendResponse(reqId,result)`; handler throws `BridgeRpcError(fatal:true)` ⇒ `sendError(code)` THEN `sock.end()`. Bad-token close is GRACEFUL (`end()` = FIN), so the client sees the error line THEN EOF. |
| Activation gate (DONE, S21) | `plugin/lua/pi-editor/init.lua` `activate()` | Stores `M.descriptor` (parsed env-var), sets `vim.bo.filetype="pi-prompt"`. Has the `token`/`path` the handshake needs. **S25 wires the handshake call here** (S24 notes L175: *"WIRING connect() into the activation flow (ftplugin/activate) — S25"*). |
| `pi.bridge` placeholder | `plugin/lua/pi-editor/init.lua` | `M.bridge = nil` (typed `table|nil`). Doc: *"Populated by bridge.lua after a successful connect + handshake."* `plugin/tests/smoke.lua` asserts `pi.bridge == nil` in a dormant (no-env-var) session — S25 must KEEP that true when no env var is set. |
| Server contract test | `extension/tests/hello-handler.test.ts` | The exact success/error envelopes + the "bad token ⇒ -32600 then close" behavior the Lua client must consume. |
| Lua test pattern | `plugin/tests/bridge_spec.lua` | `with_server(spec)` helper spins a REAL luv unix-socket server (unique path), collects decoded requests, echoes responses. S25's spec mirrors this but the server implements `hello` semantics (token-gated success vs `-32600`+close). |
| Timing/cancellation | PRD §5.5 | Client applies a per-RPC timeout (config `rpc_timeout_ms` default 2000) + supersession (ignore stale `id`). Handshake has exactly ONE outstanding request, so supersession = "resolve once, ignore later". |

## 1. The exact wire exchange (what S25 must produce/consume)

**Client → Server (sent inside the S24 `on_ready(nil)` callback, i.e. once `state.connected==true`):**
```jsonc
{"jsonrpc":"2.0","id":"h1","method":"hello","params":{"token":"<desc.token>","client":"pi-editor.nvim","clientVersion":"0.1.0"}}
```
Framed by `bridge.send(obj)` → `vim.json.encode(obj).."\n"` (S24 GOTCHA 11). The `id` is the
literal **`"h1"`** — matches PRD §5.3 example AND the server's `hello-handler.test.ts`; the
server echoes whatever `id` it received, so the client correlates on `"h1"`. `client`/
`clientVersion` are informational (server ignores them; `HelloParams` marks both optional).

**Server → Client success (arrives via S23 `jsonlreader` → S24 `on_event(msg)`):**
```jsonc
{"jsonrpc":"2.0","id":"h1","result":{"ok":true,"serverVersion":"0.1.0","cwd":"/home/u/proj","fdAvailable":true}}
```

**Server → Client failure (bad/missing/stopped token) — then the server closes:**
```jsonc
{"jsonrpc":"2.0","id":"h1","error":{"code":-32600,"message":"bad token"}}
```
followed (after a graceful `sock.end()`/FIN) by EOF on the client pipe. The Lua client MUST
treat the error line as the handshake verdict (don't wait for the close); the close is just
cleanup. The error `message` is the literal `"bad token"` (never the token value — PRD §12).

## 2. Where the handshake logic lives (design decision)

**Decision: extend `plugin/lua/pi-editor/bridge.lua`** (the S24 transport module) with a
public `handshake(desc, on_result)` + a small internal single-message dispatcher. Reasons:

1. **Singleton transport (S24 GOTCHA 10):** one pipe, ONE `on_event` per session. S25 must
   own the `on_event` the reader feeds, because S26/S27 will LATER extend that SAME dispatch.
   Putting the dispatcher in `bridge.lua` gives S26 a single extension point (it adds a
   `pending[id]` map + a branch in the dispatcher; the handshake branch stays).
2. **The bridge.lua header already says so:** *"the `require("pi-editor").bridge`
   placeholder S25 sets after handshake"* — bridge.lua is the module that becomes `pi.bridge`.
3. **No new file / no new runtimepath entry** — keeps the plugin's module count minimal and
   matches PRD §7.2's layout (no `handshake.lua` is listed there).
4. **connect()'s public signature is UNTOUCHED** — `connect(path,on_ready,on_event,on_close)`
   stays exactly as S24 spec'd/tested. `handshake()` is an ADDED caller of `connect()` that
   passes its OWN internal `on_event` (the dispatcher). The existing `bridge_spec.lua`
   (which calls `connect` directly with its own `on_event`) keeps passing unchanged.

**Module state added to `bridge.lua` (all singleton, all cleared on `close()`):**
- `handshake_state` — `{ desc, on_result, pending=true, timer }` or `nil`. Guards the
  "resolve exactly once" race (response vs timeout vs close).
- `M.server_info` — `nil` until a successful hello; then `{serverVersion,cwd,fdAvailable}`.
  Read by future tasks (S30+ completion uses `cwd`; `:checkhealth` S42 uses all three).
- `M.version` — plugin version string `"0.1.0"` (mirrors `package.json` + the extension's
  `BRIDGE_VERSION`). Sent as `clientVersion`; informational only.

**Internal dispatcher `dispatch(msg)` (the single `on_event`):**
- `if handshake_state and handshake_state.pending and msg.id == "h1"` → resolve handshake
  (validate `result.ok` vs `error`, extract info, clear `pending` + stop timer).
- `else` → **documented S26 extension point** (S26 adds `pending[msg.id]` lookup here).
  Today it is a no-op (handshake is the only legal pre-ready message).

> Scope guard: S25 does NOT build the generic `pending` map / `request()` — that is S26
> ("request(method, params, cb) with auto-id, correlation, stale drop"). S25 builds only the
> dispatch SEAM (one function, one branch) S26 extends. This keeps S25 tightly scoped while
> avoiding a refactor when S26 lands.

## 3. Race-safety: "resolve exactly once" (the load-bearing property)

Three asynchronous events can fire, in any order, for ONE handshake:
1. the `hello` success/error **response** (via `on_event`),
2. the **handshake timeout** (`uv.new_timer`, `config.rpc_timeout_ms`),
3. an **on_close** (transport error / EOF / server fatal-close after bad token).

Resolution rule: the FIRST of {response, timeout, close} that sees
`handshake_state.pending == true` flips it `false` and calls `on_result(...)` exactly once;
the other two see `pending == false` and no-op. Concretely:
- **response:** `pending=false` → (success) set `M.server_info` + `pi.bridge=M`, `on_result(nil,info)`;
  (error/malformed) `M.close()`, `on_result(err)`.
- **timeout:** if `pending` → `pending=false`, `M.close()`, `on_result("handshake timeout")`.
- **on_close:** if `pending` → `pending=false`, `on_result(reason or "connection closed during handshake")`.
  (`M.close()` is already idempotent; calling it twice across these paths is safe per S24 GOTCHA 2.)

Single-threaded nvim/luv loop ⇒ no true concurrency; the `pending` flag is a sequenced-event
guard, not a lock. No `vim.schedule` needed for the resolve path itself (it does only Lua
table writes + `M.close()`/`M.send()`, both luv-safe — same rule S23/S24 document).

## 4. Wiring into `activate()` (init.lua)

`activate()` runs once (`VimEnter`, `once=true`), owns `M.descriptor`, and is the natural
"this is a pi session" seam. Add the handshake kick-off AFTER `M.descriptor = desc`:

```lua
-- S25: connect + hello handshake (async; degrade silently on any failure).
-- pcall so a bridge bug can never break activation (buffer still works as plain markdown).
pcall(function()
  require("pi-editor.bridge").handshake(desc, function(_err, _info)
    -- success: bridge.lua already set pi.bridge + M.server_info.
    -- failure: degrade silently (the one-time vim.notify is task S39's job).
  end)
end)
```

**Why here, not the ftplugin:** the transport is a SESSION singleton (S24 GOTCHA 10), and
`activate()` is the once-per-session entry point. The ftplugin (S22) is per-buffer and
already owns `bridge.on_exit`; it does NOT need the connection (its keymaps/autocmds are
no-op-safe until S30/S38 land). `activate()`'s "NEVER throws" contract is preserved by the
pcall; its "NEVER notifies" contract is preserved (the notify is deferred to S39).

## 5. Defensive extraction (mirror the server's `getCwd() ?? ""`)

The server is already defensive (`makeHelloHandler` returns `cwd: deps.getCwd() ?? ""`). The
CLIENT must be equally defensive — a malformed-but-`ok:true` result must not crash completion
later. Extract with per-field type guards:
```lua
local r = msg.result or {}
info.serverVersion = (type(r.serverVersion)=="string") and r.serverVersion or ""
info.cwd           = (type(r.cwd)=="string") and r.cwd or (desc.cwd or "")
info.fdAvailable   = (r.fdAvailable == true)                       -- boolean; false unless literally true
```
`cwd` falls back to the descriptor's `cwd` (they SHOULD match — same `ctx.cwd` — but the
descriptor value is always present and trustworthy).

## 6. Gotchas (Lua/luv-specific, LIVE-VERIFIED by S23/S24 research)

- **`state.connected` gate (S24 GOTCHA 6):** `send()` returns `false` unless connected.
  `on_ready(nil)` is fired AFTER `state.connected=true` is set inside the connect callback, so
  calling `M.send(hello)` at the TOP of `on_ready` is legal. Do NOT send hello before `on_ready`.
- **on_close fires after on_event on fatal close:** S24's `read_cb` EOF path calls
  `state.rx:flush()` (delivers a trailing error line via `on_event`) BEFORE `on_close`. So a
  server that replies `-32600` then closes delivers the error line first → handshake resolves
  as failure via `on_event`, THEN `on_close` sees `pending==false` and no-ops. Correct.
- **`M.close()` clears `on_close` (S24):** once the error-response path calls `M.close()`,
  `state.on_close` is nil'd, so the subsequent EOF `on_close` won't double-fire. The handshake
  resolves via the response path; the close is silent cleanup.
- **Timer must be a luv timer, not `vim.defer_fn`:** bridge.lua is pure `vim.uv` (S24 GOTCHA 5:
  no `vim.api`/nvim-loop calls from luv callbacks). Use `uv.new_timer()` + `timer:start(ms,0,…)`
  + `timer:stop()`/`:close()` in the resolve path. (`vim.defer_fn` would also work — nvim's
  loop and libuv are unified — but a luv timer is consistent with the transport layer.)
- **`handshake()` never throws:** validate `desc.path`/`desc.token` (strings) UP FRONT; a bad
  descriptor calls `on_result("invalid descriptor")` and returns WITHOUT touching luv (so a
  buggy caller / a half-formed test descriptor can't crash activation's pcall-protected call).
- **pcall the `uv.new_timer` / `pipe:connect`-equivalent calls:** mirror S24's pcall discipline.
  Luv programming errors throw; transport failures come back in callbacks. `handshake()` wraps
  its setup in pcall and routes any throw to `on_result`.
- **`M.bridge = M` sets the MODULE as the placeholder value:** downstream (`require("pi-editor").bridge.request(...)`,
  blink/cmp sources per PRD §7.7) calls into the same module. Do NOT set it to a sub-table —
  the public surface (`send`/`request`/`is_connected`) lives on `M`.

## 7. Test strategy (mirror `bridge_spec.lua`'s real-socket server)

A `bridge_handshake_spec.lua` with a `with_hello_server(spec, mode)` helper, where `mode`
selects the server behavior: `"success"` (echo HelloResult on token match), `"bad_token"`
(reply `-32600` + close), `"close_silent"` (accept then close with no reply), `"slow"` (never
reply, to exercise the timeout). Each test gets a unique socket path (isolation). Cases:

1. success: sends `hello` with `id=="h1"` + `params.token==<expected>` + `client=="pi-editor.nvim"`;
   `on_result(nil, info)` with `info.serverVersion/cwd/fdAvailable`; `pi.bridge ~= nil`; `M.server_info` set.
2. bad token: server replies `-32600`; `on_result(err)` (err mentions `-32600`/`bad token`); `pi.bridge == nil`; transport closed.
3. malformed-but-id response (`{id:"h1"}` with no result/error): treated as failure; `pi.bridge == nil`.
4. silent close (server accepts then EOF, no reply): `on_result("connection closed…")`; `pi.bridge == nil`.
5. transport connect failure (`ENOENT`): `on_result("ENOENT…")`; never sends hello; `pi.bridge == nil`.
6. timeout (server never replies): with `rpc_timeout_ms` lowered to ~30ms for the test, `on_result("handshake timeout")`; transport closed.
7. race-safety: success response AND timeout both armed → `on_result` called EXACTLY ONCE.
8. invalid descriptor (no `token`): `on_result("invalid descriptor")`; no socket touched.
9. never-throws: `handshake({}, cb)` and `handshake(nil, cb)` resolve failure without error.
10. regression: re-run `bridge_spec.lua` + `jsonlreader_spec.lua` — unchanged, still green.

Plus a no-dep smoke addition to `plugin/tests/smoke.lua`: in a dormant session `pi.bridge`
is STILL `nil` (handshake never runs without the env var) — preserves the existing assertion.

## 8. Out of scope (explicitly deferred — do NOT implement here)

- `request(method, params, cb)` generic RPC + `pending` map + supersession → **S26**.
- `commandsChanged` notification handling (cache invalidation) → **S27 / S41**.
- The one-time `vim.notify` on handshake failure (UX) → **S39** (PRD §11).
- `bye` on graceful exit (autosave + disconnect) → **S38** (the `on_exit` BODY; S24 ships the no-op).
- Completion triggers / accept / Tab → **S30/S32/S33**.
- coords.lua (byte↔UTF-16) → **S28/S29** (handshake carries NO cursor coordinates).