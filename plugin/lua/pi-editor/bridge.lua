--- bridge.lua — the luv (`vim.uv`) Unix-domain-socket CLIENT for the pi-editor.nvim bridge.
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
--    the `require("pi-editor").bridge` placeholder S25 sets after handshake).
--  * WIRE FORM = encode(obj).."\n" (GOTCHA 11): the exact mirror of the server's
--    `extension/jsonl-reader.ts` `serializeJsonLine(v) = JSON.stringify(v)+'\n'` (the
--    framing terminator the server's reader splits on). ALWAYS append `\n`.
--  * on_exit IS A SAFE NO-OP (GOTCHA 12): S22's ftplugin ALREADY dispatches
--    `require("pi-editor.bridge").on_exit(buf)` on VimLeavePre/ExitPre. So `on_exit` WILL
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
--  * `require("pi-editor").bridge` placeholder: S24 left it `nil`; S25 sets it to THIS
--    module table ONLY on a `result.ok == true` response (the gate downstream completion
--    keys on). A malformed / error / timeout / close path leaves it `nil` (silent degrade).
--
-- Node builtins analog: only `vim.uv` + `vim.json` (both built in) + the S23 `jsonlreader`.
-- Module-level singleton state (one connection) — see Design Decision §6 in notes.

local uv = vim.uv
local jreader = require("pi-editor.jsonlreader")

local M = {}

--- Singleton transport state. `pipe` / `rx` / the callbacks are `nil` before `connect()`
--- and after `close()` (cleared so a stale luv callback cannot touch dead state).
--- `closed` is the shadow flag that defends the luv double-close THROW (set FIRST in
--- `close()`, before any pipe op).
---@class pi-editor.BridgeState
---@field pipe      userdata?            The luv pipe handle (`uv.new_pipe(false)`); nil before connect / after close.
---@field rx        pi-editor.JsonlReader? The jsonlreader (S23) instance fed by `read_start`; nil before connect.
---@field on_ready  fun(err:string?)?    Connect-result callback (`err==nil` on success; bare errno string on fail).
---@field on_event  fun(msg:table)?      Per-decoded-JSON-RPC-message callback (synchronous from `read_start`).
---@field on_close  fun(reason:string?)? Connection-lost callback (`nil` = clean EOF; errno string = socket error).
---@field connected boolean              True ONLY between `on_ready(nil)` and the start of teardown.
---@field closed    boolean              Shadow flag: `true` once teardown has BEGUN (defends the double-close THROW).
---@type pi-editor.BridgeState
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
---@class pi-editor.ServerInfo
---@field serverVersion string Bridge server version (default `""` if absent/malformed).
---@field cwd string Session cwd (falls back to `descriptor.cwd`).
---@field fdAvailable boolean True ONLY if `result.fdAvailable == true`.
---@type pi-editor.ServerInfo|nil
M.server_info = nil

--- In-flight handshake race-guard. Set by `M.handshake()`; cleared (`pending=false`) by
--- the FIRST resolver (response / timeout / close). Holds the caller callback + the luv
--- timer so any resolver can finalize EXACTLY ONCE and stop the timer. Module-level
--- (singleton — one handshake per session; GOTCHA 10). Cleared in `M.close()`.
---@class pi-editor.HandshakeState
---@field desc pi-editor.BridgeDescriptor The descriptor (has `.path` + `.token` + `.cwd`).
---@field on_result fun(err:string?, info:pi-editor.ServerInfo?) Caller callback (exactly once).
---@field pending boolean `false` once ANY resolver has fired (the exactly-once guard).
---@field timer userdata? luv timer for the handshake timeout (`nil` if not armed).
---@type pi-editor.HandshakeState|nil
local handshake_state = nil

-- ===========================================================================
-- S25 — handshake internals (forward declarations; defined below).
-- ===========================================================================
local resolve_handshake -- (msg, err) — the SINGLE exit point (race-safe).
local dispatch          -- (msg)       — the single on_event (S26/S27 extension seam).

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
    M.close()
    if cb then cb(err) end
    return
  end
  if data == nil then -- EOF (err==nil && data==nil) — GOTCHA 4
    if state.rx then state.rx:flush() end -- deliver any trailing line via on_event FIRST
    local cb = state.on_close
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
    require("pi-editor").bridge = M -- publish (pure Lua table write; luv-safe; was nil)
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

--- The single `on_event` dispatcher the jsonlreader feeds (SINGLETON — GOTCHA 10).
--- `M.handshake()` passes this as `connect()`'s `on_event`. Today it has ONE branch:
--- the `id == "h1"` hello response → `resolve_handshake`. It is the SEAM S26/S27 extend:
---   * S26 EXTENSION POINT: add `if pending[msg.id] then ... end` here (request correlation).
---   * S27 EXTENSION POINT: add `if msg.method == "commandsChanged" then ... end` here.
--- Runs INLINE from the luv `read_start` cb (via `jsonlreader.feed`); does NO `vim.api.*`
--- work (GOTCHA 5). `resolve_handshake` is pure Lua writes + `M.send`/`M.close` (luv-safe).
---@param msg table A decoded JSON-RPC message (a table from `vim.json.decode`).
dispatch = function(msg)
  if handshake_state and handshake_state.pending and msg and msg.id == "h1" then
    resolve_handshake(msg, nil)
    return
  end
  -- S26 EXTENSION POINT: `if pending[msg.id] then ... end`.
  -- S27 EXTENSION POINT: `if msg.method == "commandsChanged" then ... end`.
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
--- The `hello` envelope (EXACT — sent inside `on_ready`):
---   `{jsonrpc="2.0", id="h1", method="hello", params={token=desc.token,
---   client="pi-editor.nvim", clientVersion=M.version}}` (LF-terminated by `M.send`).
---
--- Outcomes (all call `on_result` EXACTLY ONCE, guarded by `handshake_state.pending`):
---   * success (`result.ok==true`)  → `on_result(nil, {serverVersion,cwd,fdAvailable})`;
---                                    `require("pi-editor").bridge` is set to this module;
---                                    `M.server_info` holds the extracted triple.
---   * error (`error.code`, e.g. -32600) → transport closed; `pi.bridge` stays `nil`;
---                                    `on_result("handshake rejected (-32600)")`.
---   * malformed response (no `result`/`error`)  → failure path (above).
---   * silent close / connect failure / timeout → `on_result(<err>)`; `pi.bridge` stays `nil`.
--- NEVER throws; NEVER includes `desc.token` in any error string (PRD §12).
---
---@param desc      pi-editor.BridgeDescriptor The descriptor (`.path`, `.token`, `.cwd`).
---@param on_result fun(err:string?, info:pi-editor.ServerInfo?) Resolved EXACTLY ONCE.
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
    local cfg = require("pi-editor")
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
          params  = { token = desc.token, client = "pi-editor.nvim", clientVersion = M.version },
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
end

--- VimLeavePre / ExitPre handler — fulfills the S22 ftplugin forward contract
--- (`require("pi-editor.bridge").on_exit(buf)`). Closes the transport. `buf` is accepted
--- to match the dispatch signature and ignored at the transport layer (autosave is S38's
--- job, dispatched separately). Safe NO-OP when never connected (GOTCHA 12 — `connect()`
--- is not wired into the activation flow until S25). NEVER throws.
---@param buf integer Buffer handle (unused at transport layer; matches the ftplugin dispatch signature).
function M.on_exit(buf) -- luacheck: ignore buf (transport layer; autosave is S38)
  M.close()
end

--- Read-only accessor: `true` only between `on_ready(nil)` and the start of teardown.
---@return boolean
function M.is_connected()
  return state.connected and not state.closed
end

return M