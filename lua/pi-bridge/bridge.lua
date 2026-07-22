--- bridge.lua — the luv (`vim.uv`) Unix-domain-socket CLIENT for the pi-bridge.nvim bridge.
--
-- Owns exactly the TRANSPORT layer of parent task P2.M5.T15 ("Socket client & handshake"):
-- create a pipe, connect to the socket path, wire `read_start` to the (DONE, S23)
-- `jsonlreader` so every decoded JSON-RPC message reaches an `on_event(table)` callback,
-- expose a `send(obj)` write helper (`vim.json.encode(obj).."\n"` -> `pipe:write`), and
-- provide idempotent `close()` / `on_exit(buf)` teardown. It is the CLIENT counterpart of
-- the COMPLETE extension-side `connection.ts` + `jsonl-reader.ts` IPC server (P1.M2 — PRD §16).
--
-- [Mode A] header — read before editing:
--  * TRANSPORT/PROTOCOL SPLIT: S24 = transport only. The `hello` handshake (token) is S25;
--    `request()` RPC id-correlation / supersession is S26; `commandsChanged` notification
--    handling is S27; wiring `connect()` into the activation flow is S25 (the first
--    protocol consumer). S24 provides the callbacks (on_ready / on_event / on_close) +
--    `send()` that those tasks compose. `connect()` takes `path` ONLY (no token).
--  * LUV ERROR CATALOG (GOTCHA 1, LIVE-VERIFIED research/notes.md §2): connect / read /
--    write errors are delivered in the callback as the BARE errno-name string —
--    "ENOENT" (no socket), "ECONNREFUSED" (file / not listening), "EACCES" (perms),
--    "EPIPE" (write to a closed peer), "ECONNRESET" (read error). NOT "<NAME>: strerror".
--  * DOUBLE-CLOSE THROWS (GOTCHA 2): `pipe:close()` on an already-closing handle raises
--    "handle 0x.. is already closing". `close()` is guarded by a shadow `state.closed`
--    flag (set FIRST) + `is_closing()` + `pcall`. Idempotent across on_close / on_exit /
--    VimLeavePre / socket-error paths (this client has MANY teardown paths).
--  * EPIPE IN CB ONLY (GOTCHA 3): a broken-pipe write does NOT throw — only the write
--    callback receives `werr="EPIPE"`. `send()` ALWAYS passes a cb that routes `werr` to
--    `on_close`. Never swallow it (a callback-less write silently drops the error and
--    completion hangs forever).
--  * EOF = flush THEN on_close (GOTCHA 4): `read_start` callback with `(nil, nil)` is
--    clean EOF. Call `rx:flush()` FIRST (a trailing line without a final `\n` is still
--    delivered via `on_event`) THEN `on_close(nil)` + teardown.
--  * NO vim.api.* (GOTCHA 5): pure `vim.uv` + `vim.json` + the `jsonlreader`. Safe to run
--    directly inside a luv callback (`vim.api.*` throws `E5560` there; the `on_event`
--    CONSUMER is responsible for `vim.schedule`-ing its nvim work — same rule the S23
--    jsonlreader header documents as GOTCHA 5).
--  * GATE send() ON state.connected (GOTCHA 6): writing BEFORE the connect callback fires
--    is a silent byte-drop (the pipe isn't connected yet). `send()` returns false unless
--    `state.connected` (set true ONLY inside the connect success path). S25's `hello` is
--    the first legal `send()`.
--  * GUARD CLOSED HANDLES (GOTCHA 7): `read_start` / `write` on a CLOSED handle are
--    silent no-ops in this luv build — still guard (`is_closing()` + `state.closed`) AND
--    `pcall`-wrap. `close()` is the ONE that throws today.
--  * CHUNKS ARE ARBITRARY (GOTCHA 8): the OS coalesces/fragments socket reads (4 server
--    writes -> 2 client chunks at random offsets). NEVER decode a raw chunk; ALWAYS
--    `rx:feed(data)` and let S23 buffer + split + decode.
--  * SYNCHRONOUS on_event (GOTCHA 9): `on_event(msg)` runs inline from `read_start`
--    (via `jsonlreader.feed`). It executes on the libuv loop and must do NO nvim API work
--    itself — it should be a thin dispatch that `vim.schedule`s any heavy work.
--  * SINGLETON STATE (GOTCHA 10): one `pipe` / one `rx` / one callback set (one pi editor
--    session = ONE bridge connection, PRD §11 "v1 supports completion in the buffer active
--    at VimEnter"). `connect()` called twice RE-INITS (closes any prior connection first
--    — idempotent). Do NOT make this instance-based (would fight the singleton model +
--    the `require("pi-bridge").bridge` placeholder S25 sets after handshake).
--  * WIRE FORM = encode(obj).."\n" (GOTCHA 11): the exact mirror of the server's
--    `extension/jsonl-reader.ts` `serializeJsonLine(v) = JSON.stringify(v)+'\n'` (the
--    framing terminator the server's reader splits on). ALWAYS append `\n`.
--  * on_exit IS A SAFE NO-OP (GOTCHA 12): S22's ftplugin ALREADY dispatches
--    `require("pi-bridge.bridge").on_exit(buf)` on VimLeavePre/ExitPre. So `on_exit` WILL
--    be called in every pi-prompt session even though `connect()` is not yet wired (S24
--    ships before S25). It must no-op safely when never connected (just calls `M.close()`).
--
-- [Mode A] S25 EXTENSION — the `hello` handshake (the first PROTOCOL consumer):
--  * S25 adds `M.handshake(desc, on_result)` — the authenticated JSON-RPC `hello` exchange
--    (PRD §5.3 / §5.4). It is an ADDED CALLER of `connect()`/`send()`/`close()` (it does
--    NOT reimplement the transport; it does NOT change `connect()`'s public signature).
--    The existing `bridge_spec.lua` still calls `connect()` directly with its own on_event.
--  * S25 owns the SINGLE `on_event` dispatcher: `dispatch(msg)` is passed as `connect()`'s
--    `on_event`. Today it has ONE branch (`id == "h1"` → resolve_handshake). It is the
--    SEAM S26 (`request`/`pending[id]` correlation) and S27 (`commandsChanged`) extend —
--    do NOT fork it into a per-call closure.
--  * EXACTLY-ONCE `on_result`: the race-guard is `handshake_state.pending` (a single
--    bool on a single-threaded luv loop — a sequenced-event guard, not a lock). The FIRST
--    of {response, timeout, close} that sees `pending==true` flips it false and resolves;
--    the others no-op. The luv timeout timer (`uv.new_timer`, NEVER `vim.defer_fn` —
--    GOTCHA 5) is stopped+closed in the resolver or it leaks across editor open/close cycles.
--  * SECURITY (PRD §12): the token is the auth boundary. NEVER put `desc.token` in any
--    error string / notify / log. The server says the literal `"bad token"`; the client
--    mirrors — error strings are generic codes (e.g. `"handshake rejected (-32600)"`).
--  * `require("pi-bridge").bridge` placeholder: S24 left it `nil`; S25 sets it to THIS
--    module table ONLY on a `result.ok == true` response (the gate downstream completion
--    keys on). A malformed / error / timeout / close path leaves it `nil` (silent degrade).
--
-- [Mode A] S26 EXTENSION — the generic `request()` RPC layer (the SECOND protocol consumer):
--  * S26 adds `M.request(method, params, on_result) -> string|nil` (the generic JSON-RPC
--    primitive S30+ completion keys on) + `M.cancel(id)` (local supersession cleanup).
--    They are ADDED CALLERS of `connect()`/`send()`/`close()` (no public-signature change).
--  * TWO-LAYER design: the transport keeps a `pending` MAP (id → entry) so EVERY concurrent
--    outstanding request (e.g. getSuggestions racing applyCompletion) resolves to its OWN cb.
--    Supersession is the CALLER's job (completion.lua S30+ tracks its latest id and ignores
--    stale cbs OR calls `cancel(old_id)`). Do NOT collapse this to a single "current id" —
--    that would mis-drop a legitimate applyCompletion response when a newer getSuggestions fires.
--  * The dispatch SEAM: `dispatch(msg)` gains ONE branch (`pending[msg.id]`) AFTER the
--    `id=="h1"` handshake branch (handshake routes first; the two are mutually exclusive —
--    the monotonic-int→string counter can NEVER emit `"h1"`).
--  * EXACTLY-ONCE guard: DELETE-THE-ENTRY — `resolve_request` does `pending[id]=nil` FIRST,
--    then stops+ closes the timer, then fires the stored cb (schedule_wrap'd). A late
--    resolver (timeout after response, duplicate response, stray) finds nil and no-ops.
--  * PER-REQUEST LUV TIMER: `uv.new_timer()` (NEVER `vim.defer_fn` — GOTCHA 5). `:close()`
--    is REQUIRED on every resolve path (response/timeout/cancel/close) — `:stop()` alone
--    leaks the `uv_timer_t` handle across editor open/close cycles (PRD §6.7).
--  * CLOSE() DRAINS pending: every outstanding cb resolves with `"connection closed"`
--    (LSP invariant — never leave a cb hanging); timers closed; `next_id` reset to 0.
--    `handshake_state` is NOT cleared here (see the comment in `M.close()` —
--    `resolve_handshake` owns it via the `pending` bool).
--  * `result: null` (getSuggestions empty): the resolver uses `rawget(msg,"result") ~= nil`
--    to distinguish a PRESENT null (`vim.NIL`, success) from an ABSENT key (`nil`, malformed).
--    `vim.NIL` is normalized to `nil` before the cb → `cb(nil, nil)` = "success, no result".
--  * SECURITY (PRD §12): the token NEVER appears in any request/error string (it never
--    appears in RPC responses anyway — verified by the server tests).
--
-- [Mode A] S27 EXTENSION — the notification dispatch (the THIRD protocol consumer):
--  * S27 adds ONE branch to `dispatch(msg)` at the literal `-- S27 EXTENSION POINT`
--    placeholder (AFTER the S25 handshake branch + the S26 request-response branch): if
--    a decoded msg has a string `method` and NO string `id` (JSON-RPC section 4
--    notification), look up `notification_handlers[method]` and invoke it
--    (schedule_wrap'd). NEVER reply (JSON-RPC: a notification expects no response).
--    Unknown method / missing handler -> silently dropped.
--  * S27 adds `M.on_notification(method, handler)` — the registration API S41 (cache
--    invalidation) + future consumers call. Last-wins; nil removes; never throws;
--    handler stored vim.schedule_wrap'd (GOTCHA 5 — dispatch runs inline from the luv
--    read_start cb).
--  * M.close() clears `notification_handlers` (hygiene — no stale handler across
--    reconnects).
--  * The three dispatch branches are mutually exclusive by wire shape: handshake resp
--    has id == "h1"; request resp has a string id (no method); notification has method +
--    no string id.
--  * commandsChanged is the ONLY NotificationMethod in v1 (protocol.ts section D). Its
--    params are EMPTY and OMITTED on the wire (S17) -> the handler receives
--    `params == nil`.
--
-- [Mode A] S39 EXTENSION — the disconnect event (the FOURTH protocol consumer):
--  * S39 adds `M.on_disconnect(handler)` — the sibling of `on_notification` (S27) for the
--    pipe-drop event (process death / dropped connection post-handshake; PRD §11). SAME
--    shape: single slot (last-wins — there is exactly ONE disconnect event), stored
--    `schedule_wrap`'d at registration (GOTCHA 5 — fired from the luv `read_cb`), nil'd
--    by `close()` (hygiene — no stale handler across reconnects), never throws.
--  * `fire_disconnect(reason)` runs INLINE from `read_cb`'s EOF (`data==nil`) + read-error
--    (`err~=nil`) branches, BEFORE `M.close()` (close() nils the slot — GOTCHA G). Gated
--    on `not (handshake_state and handshake_state.pending)` so an UNRESOLVED handshake's
--    drop is owned by the handshake cb (its message is more accurate; dedup covers the
--    overlap — GOTCHA F). Never fired from `close()` itself (close() is also the planned
--    `on_exit`/reconnect path — would notify on a graceful :q; GOTCHA E).
--
-- Node builtins analog: only `vim.uv` + `vim.json` (both built in) + the S23 `jsonlreader`.
-- Module-level singleton state (one connection) — see Design Decision §6 in notes.

local uv = vim.uv
local jreader = require("pi-bridge.jsonlreader")

local M = {}

--- Singleton transport state. `pipe` / `rx` / the callbacks are `nil` before `connect()`
--- and after `close()` (cleared so a stale luv callback cannot touch dead state).
--- `closed` is the shadow flag that defends the luv double-close THROW (set FIRST in
--- `close()`, before any pipe op).
---@class pi-bridge.BridgeState
---@field pipe      userdata?            The luv pipe handle (`uv.new_pipe(false)`); nil before connect / after close.
---@field rx        pi-bridge.JsonlReader? The jsonlreader (S23) instance fed by `read_start`; nil before connect.
---@field on_ready  fun(err:string?)?    Connect-result callback (`err==nil` on success; bare errno string on fail).
---@field on_event  fun(msg:table)?      Per-decoded-JSON-RPC-message callback (synchronous from `read_start`).
---@field on_close  fun(reason:string?)? Connection-lost callback (`nil` = clean EOF; errno string = socket error).
---@field connected boolean              True ONLY between `on_ready(nil)` and the start of teardown.
---@field closed    boolean              Shadow flag: `true` once teardown has BEGUN (defends the double-close THROW).
---@type pi-bridge.BridgeState
local state = {
  pipe = nil,
  rx = nil,
  on_ready = nil,
  on_event = nil,
  on_close = nil,
  connected = false,
  closed = false,
}

--- Plugin version sent as hello's `clientVersion` (informational; the server ignores
--- it). Mirrors `package.json` "version" + the extension `BRIDGE_VERSION` ("0.1.0").
M.version = "0.1.0"

--- Server identity extracted from a successful `hello` result. `nil` until handshake
--- succeeds and `nil` again after `close()` (cleared alongside the transport state so a
--- stale value cannot leak across reconnects). Read by downstream: completion uses `.cwd`
--- (S30+); `:checkhealth` reads all three (S42). Defensive: every field is type-checked
--- on extraction (server is defensive too — `getCwd() ?? ""`).
---@class pi-bridge.ServerInfo
---@field serverVersion string Bridge server version (default `""` if absent/malformed).
---@field cwd string Session cwd (falls back to `descriptor.cwd`).
---@field fdAvailable boolean True ONLY if `result.fdAvailable == true`.
---@type pi-bridge.ServerInfo|nil
M.server_info = nil

--- In-flight handshake race-guard. Set by `M.handshake()`; cleared (`pending=false`) by
--- the FIRST resolver (response / timeout / close). Holds the caller callback + the luv
--- timer so any resolver can finalize EXACTLY ONCE and stop the timer. Module-level
--- (singleton — one handshake per session; GOTCHA 10). Cleared in `M.close()`.
---@class pi-bridge.HandshakeState
---@field desc pi-bridge.BridgeDescriptor The descriptor (has `.path` + `.token` + `.cwd`).
---@field on_result fun(err:string?, info:pi-bridge.ServerInfo?) Caller callback (exactly once).
---@field pending boolean `false` once ANY resolver has fired (the exactly-once guard).
---@field timer userdata? luv timer for the handshake timeout (`nil` if not armed).
---@type pi-bridge.HandshakeState|nil
local handshake_state = nil

--- Monotonic request-id counter. Incremented by `M.request()`; reset to 0 by `close()`
--- so each connection starts at id `"1"` (testability). Numeric strings only → can
--- NEVER equal the handshake's literal `"h1"`. Single-threaded luv loop ⇒ no locking.
local next_id = 0

--- In-flight RPC requests keyed by id (string). Each entry is created by `request()`
--- and deleted by the FIRST resolver (response / timeout / cancel / close) — the delete
--- IS the exactly-once guard (a later resolver finds nil and no-ops). Drained wholesale
--- by `close()`. This is the TWO-LAYER transport MAP: it holds EVERY concurrent
--- outstanding request (e.g. getSuggestions racing applyCompletion); supersession is
--- the CALLER's job (latest-id guard / `cancel(id)`) — see the [Mode A] header.
---@class pi-bridge.PendingRequest
---@field method string The RPC method (for cancel routing / debugging; never sent on cancel wire).
---@field cb fun(err:string?, result:any?) The user callback, wrapped in `vim.schedule_wrap` at
---   store time so it is safe to invoke from BOTH the `read_start` cb and the luv timer cb
---   (libuv/fast context — `vim.api.*` would throw `E5560` there; mirrors vim/lsp/rpc.lua:324).
---@field timer userdata? luv one-shot timer for the per-request timeout (`nil` if disarmed).
---   MUST be `:close()`d (not just `:stop()`d) on resolve or it leaks across editor open/close cycles.
---@type table<string, pi-bridge.PendingRequest>
local pending = {}

--- Notification handlers keyed by method (string). Each value is the user handler wrapped
--- in `vim.schedule_wrap` at registration (GOTCHA 5 — dispatch runs inline from the luv
--- `read_start` callback; raw `vim.api.*` throws `E5560` there). Last-wins re-registration
--- (a Lua table set); `on_notification(method, nil)` removes an entry. Cleared wholesale
--- by `close()` (hygiene: a stale handler must not fire across reconnects — PRD §6.7). S27
--- is the MECHANISM; the cache-invalidation BEHAVIOR is S41 (`require("pi-bridge").bridge.
--- on_notification("commandsChanged", function(_params) ... end)`).
---@type table<string, function>
local notification_handlers = {}

--- S39: single disconnect-handler slot (the pipe-drop event consumer). Mirrors
--- `notification_handlers`/`on_notification` (S27) but a SINGLE slot (last-wins) since
--- there is exactly one disconnect event. schedule_wrap'd at registration (GOTCHA 5/I —
--- fired from the luv read_cb; raw vim.api.* throws E5560 there). nil'd by close()
--- (hygiene — no stale handler across reconnects; mirrors notification_handlers = {}).
--- Fired by the local `fire_disconnect` from read_cb's EOF + read-error branches.
local disconnect_handler = nil

-- ===========================================================================
-- S25/S26/S27 — internals (forward declarations; defined below).
-- ===========================================================================
local resolve_handshake -- (msg, err) — the SINGLE exit point for the handshake (race-safe).
local resolve_request   -- (id, err, msg) — the SINGLE exit point for a regular request (race-safe).
local dispatch          -- (msg)       — the single on_event (S26/S27 extension seam).
local fire_disconnect   -- (reason)   — S39: fire the disconnect handler from read_cb (defined below).
local autosave_if_modified -- (buf) — S38 best-effort autosave helper (pure nvim-API; defined below).

--- S39: fire the registered disconnect handler when the transport pipe drops (EOF or
--- read error) AFTER the handshake has resolved. Gated on `not (handshake_state and
--- handshake_state.pending)` so an UNRESOLVED handshake's drop is owned by the handshake
--- cb (its message is more accurate; dedup covers the overlap anyway — GOTCHA F). Runs
--- INLINE from the luv read_cb; the handler itself is schedule_wrap'd at registration
--- (GOTCHA 5/I) so its nvim-API work (menu.close/completion.reset/notify) defers to the
--- safe nvim loop. Reads the module slot BEFORE close() nils it (GOTCHA G). Never throws.
---@param reason string? nil = clean EOF; bare errno string (e.g. "ECONNRESET") = read error.
fire_disconnect = function(reason)
  if handshake_state and handshake_state.pending then return end -- active handshake owns it
  local h = disconnect_handler
  if type(h) == "function" then pcall(h, reason) end
end

--- The `read_start` callback. Routes data chunks to the `jsonlreader`; EOF / read errors
--- to `on_close` + teardown. Runs on the libuv loop (no `vim.api.*` here — GOTCHA 5).
--- Never throws.
---@param err string? A read error (bare errno name, e.g. "ECONNRESET"); `nil` otherwise.
---@param data string? The raw byte chunk; `nil` on EOF (when `err` is also `nil`).
local function read_cb(err, data)
  if state.closed then
    return
  end
  if err then -- read error (e.g. "ECONNRESET")
    local cb = state.on_close
    fire_disconnect(err)  -- S39: pipe-drop notify (post-handshake); gated inside
    M.close()
    if cb then cb(err) end
    return
  end
  if data == nil then -- EOF (err==nil && data==nil) — GOTCHA 4
    if state.rx then state.rx:flush() end -- deliver any trailing line via on_event FIRST
    local cb = state.on_close
    fire_disconnect(nil)  -- S39: EOF disconnect (post-handshake); gated inside
    M.close()
    if cb then cb(nil) end
    return
  end
  if state.rx then state.rx:feed(data) end -- frame + decode -> on_event(table) (S23)
end

-- ===========================================================================
-- S25 — the `hello` handshake (the first PROTOCOL consumer of the S24 transport)
-- ===========================================================================

--- The SINGLE exit point for every handshake outcome (race-safe). Guards the
--- exactly-once contract: the FIRST of {response, timeout, close} that sees
--- `handshake_state.pending == true` flips it false and resolves; later callers no-op.
--- Stops+ closes the luv timer (or it leaks across editor open/close cycles). Runs
--- inline from a luv callback (the read_start cb / the timer cb / the connect cb) so it
--- does NO `vim.api.*` work (GOTCHA 5) — only Lua writes + `M.send`/`M.close` (luv-safe).
---
--- Branches:
---   (a) `msg==nil`            — TIMEOUT or CLOSE path: close + `cb(err)` (pi.bridge stays nil).
---   (b) `result.ok == true`   — SUCCESS: defensive extract, publish `pi.bridge`, `cb(nil, info)`.
---   (c) else                  — FAILURE (error object OR malformed result): close + `cb(emsg)`.
---
--- NEVER includes the token in any error string (PRD §12).
---@param msg table?  The decoded `id=="h1"` JSON-RPC response (nil on timeout/close).
---@param err string? A failure reason for the `msg==nil` path (timeout / close reason).
resolve_handshake = function(msg, err)
  if not handshake_state or not handshake_state.pending then return end -- EXACTLY-ONCE guard
  handshake_state.pending = false
  if handshake_state.timer then -- stop+close the luv timer (or it leaks across cycles)
    pcall(function() handshake_state.timer:stop() end)
    pcall(function() handshake_state.timer:close() end)
  end
  local cb, desc = handshake_state.on_result, handshake_state.desc

  if msg == nil then -- (a) TIMEOUT or CLOSE path (silent server close / connect failure)
    M.close()        -- idempotent (GOTCHA 2)
    cb(err or "connection closed during handshake")
    return
  end

  if type(msg) == "table" and type(msg.result) == "table" and msg.result.ok == true then
    local r = msg.result -- (b) SUCCESS — defensive extract (mirror the server's getCwd() ?? "")
    local info = {
      serverVersion = (type(r.serverVersion) == "string") and r.serverVersion or "",
      cwd           = (type(r.cwd) == "string") and r.cwd or (desc.cwd or ""),
      fdAvailable   = (r.fdAvailable == true),
    }
    M.server_info = info
    require("pi-bridge").bridge = M -- publish (pure Lua table write; luv-safe; was nil)
    cb(nil, info)
  else -- (c) FAILURE — error object OR malformed result. Close + cb(emsg).
    local emsg = "handshake failed"
    if type(msg.error) == "table" and type(msg.error.code) == "number" then
      emsg = "handshake rejected (" .. msg.error.code .. ")" -- code is safe; NEVER the token
    elseif type(msg.error) == "table" then
      emsg = "handshake rejected"
    elseif type(msg) ~= "table" or msg.id ~= "h1" then
      emsg = "handshake failed: malformed response"
    end
    M.close()
    cb(emsg)
  end
end

--- The SINGLE exit point for every regular-request outcome (race-safe) — the sibling of
--- `resolve_handshake`. Guards the exactly-once contract via DELETE-THE-ENTRY: the FIRST
--- resolver (response / timeout / cancel / close) that finds `pending[id]` deletes it,
--- stops+ closes the luv timer (or it leaks across cycles), then fires the stored cb. A
--- LATE resolver (e.g. the timeout firing after the response already arrived) looks up
--- `pending[id]`, finds nil, no-ops. Single-threaded nvim/luv loop ⇒ this is a
--- sequenced-event guard, not a lock.
---
--- Branches:
---   (a) `msg==nil`             — TIMEOUT / CANCEL / CLOSE path: fire `cb(err)` (err is the reason).
---   (b) `type(msg.error)=="table"` — ERROR response: fire `cb(emsg)` (code + safe message; NEVER the token).
---   (c) `rawget(msg,"result") ~= nil` — SUCCESS: normalize `vim.NIL→nil`, fire `cb(nil, result)`.
---        `rawget` distinguishes a PRESENT null result (`vim.NIL`, getSuggestions empty) from an
---        ABSENT key (`nil`, malformed) — LIVE-VERIFIED on Neovim 0.12.4.
---   (d) else                   — MALFORMED (no result/error): fire `cb("malformed response…")`.
---
--- Runs INLINE from a luv callback (the read_start cb / the timer cb); does NO `vim.api.*`
--- work (GOTCHA 5) — the cb is `schedule_wrap`d at store time so the user's nvim work is
--- deferred to the safe nvim loop (mirrors `vim/lsp/rpc.lua:324`).
---
---@param id  string  The request id (must be a string; non-string is a no-op).
---@param err string? A failure reason for the `msg==nil` path (timeout / cancel / close reason).
---@param msg table?  The decoded JSON-RPC response (nil on timeout / cancel / close).
resolve_request = function(id, err, msg)
  if type(id) ~= "string" then return end
  local entry = pending[id]
  if not entry then return end            -- EXACTLY-ONCE guard (delete-entry); unknown id dropped
  pending[id] = nil                       -- delete FIRST so a racing resolver (timeout vs response) no-ops
  if entry.timer then                     -- luv timer :close() is REQUIRED (not just :stop())
    pcall(function()
      if not entry.timer:is_closing() then entry.timer:stop() end
      if not entry.timer:is_closing() then entry.timer:close() end
    end)
  end
  local cb = entry.cb
  if not cb then return end
  if msg == nil then                      -- timeout / cancel / close path
    cb(err or "request failed")
    return
  end
  if type(msg.error) == "table" then      -- error response (code is safe; NEVER the token — PRD §12)
    local code = (type(msg.error.code) == "number") and msg.error.code or nil
    local emsg = code and ("rpc error " .. code) or "rpc error"
    if type(msg.error.message) == "string" and msg.error.message ~= "" then
      emsg = emsg .. ": " .. msg.error.message  -- server messages are generic codes; safe
    end
    cb(emsg)
  elseif rawget(msg, "result") ~= nil then -- LIVE-VERIFIED: present-null (vim.NIL) ≠ absent (nil)
    local result = msg.result
    if result == vim.NIL then result = nil end  -- normalize getSuggestions null -> nil (no matches)
    cb(nil, result)
  else
    cb("malformed response: no result or error")
  end
end

--- The single `on_event` dispatcher the jsonlreader feeds (SINGLETON — GOTCHA 10).
--- `M.handshake()` passes this as `connect()`'s `on_event`. It has TWO branches today:
---   * `id == "h1"`           → `resolve_handshake` (S25 — the `hello` response; STAYS FIRST).
---   * `pending[msg.id]`      → `resolve_request`  (S26 — a regular JSON-RPC response).
---   * S27 EXTENSION POINT:   notifications (`commandsChanged`) go here.
--- Runs INLINE from the luv `read_start` cb (via `jsonlreader.feed`); does NO `vim.api.*`
--- work (GOTCHA 5) — the resolvers are pure Lua writes + `M.close` (luv-safe).
---@param msg table A decoded JSON-RPC message (a table from `vim.json.decode`).
dispatch = function(msg)
  if handshake_state and handshake_state.pending and msg and msg.id == "h1" then
    resolve_handshake(msg, nil)
    return
  end
  -- S26: correlate a regular JSON-RPC response by id. The `type(msg.id)=="string"` guard
  -- defends a server `id:null` (JSON-RPC §5.1) — `pending[nil]` would be a Lua index error.
  -- (The handshake's literal `"h1"` is a string, but the numeric-only counter can NEVER emit
  -- it — `tostring(n)` is always a numeric string — so the two branches are mutually exclusive.)
  if msg and type(msg.id) == "string" then
    if pending[msg.id] then
      resolve_request(msg.id, nil, msg)
      return
    end
    -- no matching entry: stale / late / duplicate / stray -> dropped silently (PRD §11)
  end
  -- S27: a NOTIFICATION (method present, no string id — JSON-RPC §4). Dispatch to a
  -- registered handler (schedule_wrap'd at registration so it is safe to call from this
  -- luv read_start cb — GOTCHA 5). NEVER reply (JSON-RPC: a notification expects no
  -- response). An unknown method or a missing handler is silently dropped (PRD §11).
  if msg and type(msg.method) == "string" and type(msg.id) ~= "string" then
    local h = notification_handlers[msg.method]
    if h then h(msg.params) end   -- h is schedule_wrap'd -> next nvim loop pass (safe)
    return
  end
end

-- ===========================================================================
-- Public API
-- ===========================================================================

--- Open the socket transport. `path` is `descriptor.path` (S21). The callbacks (the
--- forward contracts S25 / S26 / S27 / S38 consume):
---   * `on_ready(err)`  — connect result (`err==nil` ok; bare errno string on fail).
---     S25 sends `hello` here. Called EXACTLY ONCE.
---   * `on_event(msg)`  — each decoded JSON-RPC table (S25 validates `hello`; S26
---     correlates by `id`; S27 branches on `method=="commandsChanged"`). Synchronous
---     from `read_start` — the consumer `vim.schedule`s nvim work.
---   * `on_close(reason)` — connection lost (`nil` = clean EOF; bare errno string =
---     socket error). Fires AFTER `rx:flush()` so a trailing line is still delivered.
---
--- Idempotent re-init: closes any prior connection FIRST (so a second `connect()` does
--- not leak the old pipe). NEVER throws — the luv `connect` call is `pcall`-wrapped
--- (programming errors degrade via `on_ready`; connect FAILURES come back in the cb).
---
---@param path      string               Unix domain socket path (`descriptor.path`).
---@param on_ready  fun(err:string?)     Connect-result callback (called exactly once).
---@param on_event? fun(msg:table)       Per-decoded-message callback (synchronous from `read_start`).
---@param on_close? fun(reason:string?)  Connection-lost callback.
function M.connect(path, on_ready, on_event, on_close)
  -- Idempotent re-init: close any prior connection (sets state.closed, then we reset below).
  M.close()
  state = {
    pipe = uv.new_pipe(false),
    rx = jreader.new(on_event or function() end), -- on_error omitted -> silent degrade (PRD §11)
    on_ready = on_ready,
    on_event = on_event,
    on_close = on_close,
    connected = false,
    closed = false,
  }
  local pipe = state.pipe
  -- Capture THIS connection's state snapshot. A stale luv connect/read callback from a
  -- PRIOR connection (canceled by the M.close() above, or by a later reconnect) would
  -- otherwise read the CURRENT module `state` and confuse a new handshake. `s` is the
  -- per-connection identity the callbacks below check against (s.closed is set ONLY on
  -- this connection's teardown). Safe, no public-signature change.
  local s = state
  -- pcall-wrap the connect call (programming errors throw; connect FAILURES come back in the cb).
  local ok, cerr = pcall(function()
    pipe:connect(path, function(connerr)
      if s.closed then return end -- stale cb from a closed prior connection -> ignore
      if connerr then -- GOTCHA 1: bare errno string ("ENOENT" / "ECONNREFUSED" / "EACCES" / "ECANCELED")
        local cb = s.on_ready
        -- only tear down if THIS connection is still the active one (s == state)
        if s == state then M.close() end
        if cb then cb(connerr) end
        return
      end
      pipe:read_start(read_cb) -- wire S23's jsonlreader to the socket
      s.connected = true        -- GOTCHA 6: send() is now legal (this connection)
      if s.on_ready then s.on_ready(nil) end
    end)
  end)
  if not ok then -- programming error (bad arg, etc.) -> degrade via on_ready
    local cb = on_ready
    if s == state then M.close() end
    if cb then cb(tostring(cerr)) end
  end
end

--- Send the authenticated JSON-RPC `hello` handshake (PRD §5.3 / §5.4) and resolve the
--- caller callback EXACTLY ONCE. The first PROTOCOL consumer of the S24 transport: it
--- is an ADDED CALLER of `connect()` / `send()` / `close()` (does NOT reimplement them and
--- does NOT change `connect()`'s public signature — `bridge_spec.lua` still calls
--- `connect()` directly with its own on_event).
---
--- Flow:
---   1. validate `desc` + `on_result` UP FRONT — never touch luv on a bad descriptor
---      (the never-throws contract). A bad descriptor calls `on_result("invalid
---      descriptor")` synchronously and returns.
---   2. `pcall` the luv setup so a programming error degrades via `on_result` (S24
---      discipline) instead of throwing out of a VimEnter callback.
---   3. `M.close()` (idempotent) — tear down any prior connection + clear handshake_state.
---   4. arm the race-guard (`handshake_state = {pending=true, …}`) + a luv timeout timer
---      (`uv.new_timer`, NEVER `vim.defer_fn` — GOTCHA 5).
---   5. `M.connect(path, on_ready, dispatch, on_close)`:
---        * `on_ready(connerr)` — `connerr~=nil` (ENOENT/ECONNREFUSED/EACCES) → resolve
---          with the errno; else `M.send({jsonrpc="2.0",id="h1",method="hello",…})`.
---        * `dispatch`          — the single on_event; an `id=="h1"` response resolves.
---        * `on_close(reason)`  — silent server close / transport error → resolve with reason.
---   6. the luv timer fires after `config.rpc_timeout_ms` (default 2000) → resolve timeout.
---
--- S40 INVARIANT (documented, not enforced here): `rpc_timeout_ms` (default 2000) MUST exceed
--- the server fd-abort `GET_SUGGESTIONS_TIMEOUT_MS` (1500, extension/pi-nvim-bridge.ts:289)
--- so the server's OWN `fd` abort wins (timeouts cascade outward). If the client timeout were
--- BELOW the server abort, the client would abandon @file searches first while the server's
--- `fd` scan keeps running (orphaned work + a confusing "request timeout"). The optional
--- setup-time WARN guard (S40, init.lua) protects this.
---
--- The `hello` envelope (EXACT — sent inside `on_ready`):
---   `{jsonrpc="2.0", id="h1", method="hello", params={token=desc.token,
---   client="pi-bridge.nvim", clientVersion=M.version}}` (LF-terminated by `M.send`).
---
--- Outcomes (all call `on_result` EXACTLY ONCE, guarded by `handshake_state.pending`):
---   * success (`result.ok==true`)  → `on_result(nil, {serverVersion,cwd,fdAvailable})`;
---                                    `require("pi-bridge").bridge` is set to this module;
---                                    `M.server_info` holds the extracted triple.
---   * error (`error.code`, e.g. -32600) → transport closed; `pi.bridge` stays `nil`;
---                                    `on_result("handshake rejected (-32600)")`.
---   * malformed response (no `result`/`error`)  → failure path (above).
---   * silent close / connect failure / timeout → `on_result(<err>)`; `pi.bridge` stays `nil`.
--- NEVER throws; NEVER includes `desc.token` in any error string (PRD §12).
---
---@param desc      pi-bridge.BridgeDescriptor The descriptor (`.path`, `.token`, `.cwd`).
---@param on_result fun(err:string?, info:pi-bridge.ServerInfo?) Resolved EXACTLY ONCE.
function M.handshake(desc, on_result)
  -- (1) validate UP FRONT — never touch luv on a bad descriptor (never-throws contract).
  -- If `on_result` itself is not a function we cannot invoke it, so just return (the
  -- caller has a programming bug; we degrade silently rather than throw).
  if type(on_result) ~= "function" then return end
  if type(desc) ~= "table" or type(desc.path) ~= "string" or type(desc.token) ~= "string"
     or desc.token == "" then
    on_result("invalid descriptor")
    return
  end
  -- (2) pcall the luv setup so a programming error degrades via on_result (S24 discipline).
  local ok, setup_err = pcall(function()
    M.close() -- idempotent; clears any prior handshake_state / server_info
    handshake_state = { desc = desc, on_result = on_result, pending = true, timer = nil }
    local cfg = require("pi-bridge")
    local timeout_ms = ((cfg.config or cfg.defaults or {}).rpc_timeout_ms) or 2000
    local timer = uv.new_timer()
    handshake_state.timer = timer
    timer:start(timeout_ms, 0, vim.schedule_wrap(function() -- timer cb -> nvim loop (safe)
      resolve_handshake(nil, "handshake timeout")
    end))
    M.connect(desc.path,
      function(connerr) -- on_ready
        if connerr then -- ENOENT / ECONNREFUSED / EACCES (bare errno string, GOTCHA 1)
          resolve_handshake(nil, connerr)
          return
        end
        -- transport connected (state.connected==true per S24 GOTCHA 6): send hello.
        M.send({
          jsonrpc = "2.0",
          id      = "h1",
          method  = "hello",
          params  = { token = desc.token, client = "pi-bridge.nvim", clientVersion = M.version },
        })
      end,
      dispatch,                                  -- on_event (the single dispatcher)
      function(reason) resolve_handshake(nil, reason) end) -- on_close (silent close / error)
  end)
  if not ok then -- programming error (bad luv arg, etc.) -> degrade via on_result
    M.close()
    on_result("handshake setup error: " .. tostring(setup_err))
  end
end

--- Write helper: serialize a JSON-RPC envelope + `"\n"` and queue an ordered `pipe:write`.
--- Returns `false` (no-op) if not connected / closing / closed (GOTCHA 6 / 7) — writing
--- before connect or after close is a silent byte-drop. The write callback ALWAYS routes a
--- broken-pipe `err` to `on_close` (GOTCHA 3 — EPIPE is reported ONLY in the callback; a
--- callback-less write silently swallows it and completion hangs forever).
---
---@param obj table JSON-RPC envelope (or any JSON-serializable table).
---@return boolean queued `true` if the write was queued; `false` if dropped (not connected / closed).
function M.send(obj)
  if not state.connected or state.closed then return false end -- GOTCHA 6
  local pipe = state.pipe
  if pipe == nil or pipe:is_closing() then return false end    -- GOTCHA 7
  local data = vim.json.encode(obj) .. "\n"                    -- GOTCHA 11 (serializeJsonLine twin)
  local ok = pcall(function()
    pipe:write(data, function(werr)
      if werr then -- GOTCHA 3: "EPIPE" etc. (the call does NOT throw; only the cb sees it)
        local cb = state.on_close
        M.close()
        if cb then cb(werr) end
      end
    end)
  end)
  return ok
end

-- ===========================================================================
-- S26 — the generic JSON-RPC `request()` / `cancel()` (the SECOND protocol consumer
-- of the S24 transport — after the S25 handshake; the SEAM S30+ completion calls).
-- TWO-LAYER design: this layer = the id-keyed `pending` MAP (correlates every concurrent
-- request to its OWN cb); supersession is the CALLER's job (latest-id guard or cancel(id)).
-- ===========================================================================

--- Fire a generic JSON-RPC `request` and resolve `on_result` EXACTLY ONCE — by response,
--- timeout, cancel, or close (LSP invariant: never leave a cb hanging). The generic
--- primitive every downstream RPC (S27/S30/S32/S33/S38/S41/S42/S45/S46) calls.
---
--- Flow:
---   1. validate `method` + `on_result` UP FRONT — never throw on bad args (a caller bug
---      degrades via the cb / a nil return).
---   2. if not connected → fire `on_result("not connected")` (scheduled) + return `nil`
---      (no id, no pending entry, no timer).
---   3. assign a fresh monotonic string id (`"1"`, `"2"`, …; NEVER `"h1"`), register
---      `pending[id]` (cb stored `schedule_wrap`d), arm a per-request luv timeout
---      (`uv.new_timer`, NEVER `vim.defer_fn` — GOTCHA 5).
---   4. `M.send` the envelope `({jsonrpc="2.0",id,method,params})`; if the write was
---      dropped (not connected / closing) → resolve with `"send failed"`.
---   5. return the id so the caller can `cancel(id)` / supersede.
---
--- The `on_result` signature: `function(err:string?, result:any?)`. Success →
--- `on_result(nil, result)`; error response → `on_result("rpc error <code>: <msg>")`;
--- timeout / cancel / close → `on_result("<reason>")`. A `getSuggestions` null result
--- (no matches) resolves `on_result(nil, nil)` (success, no result) — NOT an error.
---
--- NEVER throws (pcall-wrapped luv; bad args degrade via cb / nil return). NEVER includes
--- `desc.token` in any error string (PRD §12 — it never appears in RPC responses anyway).
---
---@param method    string               A RequestMethod (getSuggestions/applyCompletion/…/ping/bye).
---@param params    table?               Sent as-is (`nil` → omitted from the envelope; server reads as unknown).
---@param on_result fun(err:string?, result:any?) Resolved EXACTLY ONCE (response/timeout/cancel/close).
---@return string|nil id The request id (so the caller can `cancel(id)` / supersede); `nil` on bad args / not connected.
function M.request(method, params, on_result)
  -- (1) validate UP FRONT — never throw on bad args (the caller is completion/S30+; a bug must degrade).
  if type(on_result) ~= "function" then return nil end
  if type(method) ~= "string" or method == "" then
    vim.schedule_wrap(on_result)("invalid method")
    return nil
  end
  -- (2) not connected -> fire cb (scheduled) + return nil (no id, no pending entry, no timer).
  if not M.is_connected() then
    vim.schedule_wrap(on_result)("not connected")
    return nil
  end
  -- (3)-(5) pcall the luv setup so a programming error degrades via on_result (S24/S25 discipline).
  local id
  local ok, setup_err = pcall(function()
    next_id = next_id + 1
    id = tostring(next_id)                                      -- numeric string; NEVER "h1"
    pending[id] = { method = method, cb = vim.schedule_wrap(on_result), timer = nil }
    local cfg = require("pi-bridge")
    local timeout_ms = ((cfg.config or cfg.defaults or {}).rpc_timeout_ms) or 2000
    local timer = uv.new_timer()
    pending[id].timer = timer
    timer:start(timeout_ms, 0, function()                       -- luv timer cb (fast ctx); resolve_request is luv-safe
      resolve_request(id, "request timeout", nil)               -- delete-entry guard: no-op if already resolved
    end)
    local sent = M.send({ jsonrpc = "2.0", id = id, method = method, params = params })
    if not sent then resolve_request(id, "send failed", nil) end -- transport dropped the write (GOTCHA 6/7)
  end)
  if not ok then
    if id then resolve_request(id, "request setup error: " .. tostring(setup_err), nil)
    else vim.schedule_wrap(on_result)("request setup error: " .. tostring(setup_err)) end
    return nil
  end
  return id                                                     -- so the caller can cancel(id) / supersede
end

--- Local supersession cleanup — fire the request's cb with `"cancelled"`, stop+close
--- its timer, and delete its `pending` entry. NO wire notification: the server
--- self-supersedes `getSuggestions` (a newer request aborts the prior `AbortController`);
--- `protocol.ts` `BridgeMethod` has NO `cancel` method (a wire cancel would hit the
--- server's `-32601` "method not found" — pointless). `resolve_request` is the SINGLE exit;
--- cancel reuses it (exactly-once guaranteed by the delete-entry guard). NEVER throws.
---
---@param id string The request id returned by `M.request` (non-string / unknown is a no-op).
function M.cancel(id)
  if type(id) ~= "string" then return end
  if not pending[id] then return end                           -- already resolved / unknown -> no-op
  resolve_request(id, "cancelled", nil)                        -- fires cb("cancelled"), stops+closes timer, deletes entry
end

--- Register (or replace / remove) a handler for a server-to-client NOTIFICATION method.
--- handler(params) is invoked (on the next nvim main-loop pass) when the server sends
--- a notification {jsonrpc="2.0",method=METHOD} (no id). Pass nil to remove. Never
--- throws (bad args degrade to a no-op). The handler is stored vim.schedule_wrap'd at
--- REGISTRATION time so dispatch, which runs inline from the luv read_start callback,
--- can call it safely (GOTCHA 5: raw vim.api.* throws E5560 in libuv fast context).
---
--- Last-wins: registering handler B for a method that already had handler A REPLACES A
--- (a Lua table set; no multi-cast in v1 - PRD section 15). The prior closure is GC'd.
---
---@param method  string             Notification method name (PRD section 5.4: "commandsChanged" in v1).
---@param handler fun(params:any?)|nil Called with msg.params (nil for commandsChanged,
---                                      empty params are omitted on the wire by the S17 server).
function M.on_notification(method, handler)
  if type(method) ~= "string" or method == "" then return end   -- bad method -> no-op (never throws)
  if handler == nil then
    notification_handlers[method] = nil                          -- remove
    return
  end
  if type(handler) ~= "function" then return end                 -- non-function -> no-op
  notification_handlers[method] = vim.schedule_wrap(handler)     -- last-wins; safe from luv (GOTCHA 5)
end

--- Register (or replace / remove) the SINGLE disconnect handler — fired when the
--- transport pipe drops (EOF or read error in read_cb) AFTER a successful handshake
--- (process death / dropped connection; PRD §11). The sibling of `on_notification`
--- (S27): same shape, but a single slot (last-wins) since there is one disconnect event.
--- handler(reason) runs on the next nvim main-loop pass (`reason` is nil for clean EOF
--- or a bare errno string for a read error). Pass nil to remove. Never throws.
---@param handler fun(reason:string?)|nil Called when the pipe drops post-handshake.
function M.on_disconnect(handler)
  if handler == nil then disconnect_handler = nil; return end -- remove
  if type(handler) ~= "function" then return end              -- bad arg -> no-op
  disconnect_handler = vim.schedule_wrap(handler)             -- GOTCHA 5/I: safe from luv read_cb
end

--- Idempotent teardown. Guards the luv double-close THROW (GOTCHA 2) with a shadow
--- `state.closed` flag (set FIRST) + `is_closing()` + `pcall`. Safe across the many
--- teardown paths (`on_close`, `on_exit`, VimLeavePre/ExitPre, socket-error, EOF).
--- Clears `state` so a stale luv callback cannot fire post-teardown. NEVER throws.
function M.close()
  if state.closed then return end -- GOTCHA 2: shadow flag, set FIRST
  state.closed = true
  state.connected = false
  local pipe = state.pipe
  if pipe and not pipe:is_closing() then -- GOTCHA 2: guard + pcall the close
    pcall(function() pipe:close() end)
  end
  if state.rx then state.rx:reset() end -- drop any partial line
  -- S26: drain ALL pending requests — a closed transport can NEVER deliver more responses,
  -- so every outstanding cb MUST be finalized (LSP invariant: never leave a cb hanging).
  -- Resolve each with "connection closed", stop+close its timer, then clear the map + reset
  -- the id counter. Snapshot the ids FIRST (clearer than delete-during-pairs — legal in
  -- LuaJIT but unambiguous). The drained cbs are `schedule_wrap`d → they fire on the next
  -- nvim loop pass (close() returns promptly; it does not block on them). NOTE:
  -- `handshake_state` is NOT drained here (see below — `resolve_handshake` owns it via the
  -- `pending` bool; on_close fires AFTER close() in read_cb).
  local ids = {}
  for k in pairs(pending) do ids[#ids + 1] = k end
  for _, k in ipairs(ids) do
    local entry = pending[k]
    pending[k] = nil
    if entry.timer then
      pcall(function()
        if not entry.timer:is_closing() then entry.timer:stop() end
        if not entry.timer:is_closing() then entry.timer:close() end
      end)
    end
    if entry.cb then entry.cb("connection closed") end      -- schedule_wrap'd -> next nvim loop pass
  end
  next_id = 0                                                 -- fresh ids on the next connection
  -- clear refs so a stale luv cb cannot touch dead state
  state.pipe = nil
  state.rx = nil
  state.on_ready = nil
  state.on_event = nil
  state.on_close = nil
  -- S25: clear the extracted server identity so a stale value cannot leak across
  -- reconnects (cleared with the transport). NOTE: `handshake_state` is NOT cleared
  -- here — the EOF / connect-error / read-error paths in read_cb / connect() call
  -- `M.close()` BEFORE invoking on_close / on_ready, which route through
  -- `resolve_handshake`; clearing it here would make the exactly-once guard see a
  -- nil state and silently drop the callback. `resolve_handshake` owns the
  -- `pending` flag (flips false on first resolve); `M.handshake` re-arms a fresh
  -- state on reconnect. `pending==false` makes any stale resolver a no-op.
  M.server_info = nil
  -- S27: clear the notification-handler registry (hygiene - a stale handler must not
  -- fire across reconnects). notification_handlers is a module-level local read as an
  -- upvalue by dispatch; reassigning it updates the upvalue (same pattern connect() uses
  -- to reset the state table), so dispatch sees the empty table. The drained handlers
  -- are user closures; clearing does NOT call them (unlike the S26 pending cbs,
  -- notifications have nothing to resolve). PRD section 6.7: no leak across editor
  -- open/close cycles.
  notification_handlers = {}
  disconnect_handler = nil  -- S39: clear the disconnect slot (hygiene; no stale handler across reconnects)
end

--- Best-effort autosave of `buf` to its named file when modified. Pure nvim-API (no bridge
--- state). NEVER throws — the caller (on_exit) pcalls it. Uses writefile+getbufline for a
--- deterministic UTF-8 + \n + single-trailing-\n write that matches pi's temp-file wire
--- format (PRD §11) WITHOUT running user BufWritePre/Post autocmds (no formatter risk on
--- prompt text). Clears 'modified' manually (writefile does not). Skips invalid / unloaded /
--- unmodified / unnamed buffers. (research/nvim-exit-autosave.md §Q3/Q4/Q6.)
---@param buf integer Buffer handle (0 = current; non-number/invalid/unloaded -> no-op).
autosave_if_modified = function(buf)
  if type(buf) ~= "number" then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if not vim.api.nvim_buf_is_loaded(buf) then return end   -- content resident?
  if not vim.bo[buf].modified then return end              -- nothing to save
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return end                            -- unnamed/scratch -> skip (GOTCHA F)
  -- writefile: UTF-8 + \n-delimited + single trailing \n (pi's exact wire format; GOTCHA B).
  -- NO user autocmds (no formatter risk on prompt text).
  vim.fn.writefile(vim.fn.getbufline(buf, 1, "$"), name)
  vim.bo[buf].modified = false                             -- writefile does NOT clear it (GOTCHA B.3)
end

--- VimLeavePre / ExitPre handler — fulfills the S22 ftplugin forward contract
--- (`require("pi-bridge.bridge").on_exit(buf)`). Three idempotent steps, each pcall-guarded
--- so exit is NEVER blocked or aborted (research §Q6.1; never vim.schedule — GOTCHA E):
---   (1) autosave buf to its file if modified (PRD §11 — prevents the lost-prompt bug;
---       independent of connection state, GOTCHA G).
---   (2) best-effort graceful `bye` JSON-RPC, fire-and-forget, ONLY when connected (PRD §5.4;
---       GOTCHA C — do NOT await; the ~60B bye flushes synchronously, the server handles EOF).
---   (3) M.close() — idempotent transport teardown (GOTCHA 2).
--- Safe across the ExitPre→VimLeavePre double-fire (GOTCHA A): autosave is gated on
--- 'modified' (cleared in step 1), bye on is_connected() (false after step 3), close on
--- state.closed. Safe when never connected (GOTCHA 12 — autosave guard + is_connected gate).
---@param buf integer The pi-prompt buffer handle (from the ftplugin dispatch).
function M.on_exit(buf)
  -- (1) autosave — independent of connection (PRD §11; GOTCHA G). Never throw (GOTCHA E).
  pcall(autosave_if_modified, buf)
  -- (2) best-effort graceful bye — fire-and-forget, ONLY if connected (PRD §5.4; GOTCHA C).
  if M.is_connected() then
    pcall(M.request, "bye", {}, function(_err, _result) end) -- empty cb ignores the ack/drain
  end
  -- (3) teardown — idempotent (GOTCHA 2; safe across the ExitPre+VimLeavePre double-fire, GOTCHA A).
  M.close()
end

--- Read-only accessor: `true` only between `on_ready(nil)` and the start of teardown.
---@return boolean
function M.is_connected()
  return state.connected and not state.closed
end

return M