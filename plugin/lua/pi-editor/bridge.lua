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
  -- pcall-wrap the connect call (programming errors throw; connect FAILURES come back in the cb).
  local ok, cerr = pcall(function()
    pipe:connect(path, function(connerr)
      if state.closed then return end
      if connerr then -- GOTCHA 1: bare errno string ("ENOENT" / "ECONNREFUSED" / "EACCES")
        local cb = state.on_ready
        M.close()
        if cb then cb(connerr) end
        return
      end
      pipe:read_start(read_cb) -- wire S23's jsonlreader to the socket
      state.connected = true   -- GOTCHA 6: send() is now legal
      if state.on_ready then state.on_ready(nil) end
    end)
  end)
  if not ok then -- programming error (bad arg, etc.) -> degrade via on_ready
    local cb = on_ready
    M.close()
    if cb then cb(tostring(cerr)) end
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