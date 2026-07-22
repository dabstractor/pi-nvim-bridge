--- jsonlreader.lua — strict-JSONL framing + decode for the pi-bridge.nvim bridge CLIENT.
--
-- Lua twin of the DONE extension-side `extension/jsonl-reader.ts` (P1.M2.T4.S7 — the
-- authoritative framing mirror, PRD §16), ported to Lua's byte-string model and to the
-- CLIENT role.
--
-- [Mode A] header — read before editing:
--  * BYTE-SAFE (GOTCHA 1): Lua strings are byte buffers; `..`/string.find/string.sub are
--    byte operations, so split-multibyte chars are transparently reassembled on the next
--    chunk and NO StringDecoder/streaming-UTF-8-decoder is needed (unlike the TS side
--    which reads `Buffer` chunks). Do NOT add vim.str_utfindex/utf8.len on partial chars
--    — that is a BUG (those require complete, valid UTF-8). LIVE-VERIFIED that
--    string.char(0xE2,0x82)..string.char(0xAC) decodes to "€".
--  * DECODE-IN-READER (GOTCHA 2): unlike the TS twin (which emits RAW string lines and
--    lets S8 JSON.parse + dispatch), this reader DECODES each line (`vim.json.decode`)
--    and emits a Lua table. Required by the task title ("…decode each line") + PRD §7.3
--    skeleton (`on_event(msg)` receives a decoded `msg`); and the client cannot send a
--    JSON-RPC `-32700` back on a malformed line, so a decode failure must be handled
--    LOCALLY (pcall + optional `on_error`, never thrown — PRD §11 silent-degrade).
--  * BLANK-SKIP (GOTCHA 4): empty lines (after `\r`-strip) are SKIPPED, not decoded —
--    `vim.json.decode("")` throws (LIVE-VERIFIED). A stray blank line from the trusted
--    local server is not a hard error for a client.
--  * SYNCHRONOUS on_message (GOTCHA 5): `on_message(table)` is called inline from
--    feed/flush. The reader makes NO nvim API calls (pure string/`vim.json`), so calling
--    it directly from a luv `read_start` callback is safe. The CONSUMER is responsible
--    for `vim.schedule`-wrapping any nvim-API work it does inside `on_message` (the
--    standard luv->nvim rule; documented here, not enforced by the reader).
--  * NEVER THROWS (GOTCHA 6): every `vim.json.decode` is pcall'd; feed/flush/reset
--    always return normally (a throw would escape the luv callback and surface as a
--    spurious socket error in bridge.lua's err path).
--  * SCOPE: frames + decodes ONLY. Socket connect / `hello` handshake / RPC id
--    correlation / supersession / `commandsChanged` are bridge.lua (S24/S25/S26/S27).
--    This module knows nothing of JSON-RPC methods/ids.
--
-- Node builtins analog: only `string.*` + `vim.json` (both built in). No module-level
-- mutable state — each reader instance owns its own `buffer` (two sockets → two readers).

local M = {}

--- A strict-JSONL reader. Buffers byte chunks, splits on `\n` only, strips a single
--- trailing `\r`, `vim.json.decode`s each complete NON-empty line, and invokes
--- `on_message(table)`.
---
--- Use inside a luv `pipe:read_start` callback (PRD §7.3):
--- >
---   local rx = require("pi-bridge.jsonlreader").new(function(msg) ... end)
---   pipe:read_start(function(err, chunk)
---     if err then return end            -- socket error -> bridge.lua handles
---     if chunk == nil then rx:flush()    -- EOF (data==nil, err==nil) -> final line
---     else rx:feed(chunk) end
---   end)
--- <
---@class pi-bridge.JsonlReader
---@field private buffer string Pending partial-line bytes accumulated across feed() calls.
---@field private on_message fun(msg:table) Called once per decoded JSON-RPC message.
---@field private on_error? fun(line:string, err:string) Optional decode-error callback.

--- Construct a new strict-JSONL reader.
---
---@param on_message fun(msg:table) Called once per decoded JSON-RPC message (synchronously,
---  inline from feed/flush). Never called for blank or un-decodable lines.
---@param on_error? fun(line:string, err:string) Called when `vim.json.decode` throws on a
---  NON-empty line (the raw line string + the decode error string). If omitted, decode
---  failures are SILENT (PRD §11 silent-degrade). Never throws.
---@return pi-bridge.JsonlReader reader A new reader with `feed`/`flush`/`reset` methods.
function M.new(on_message, on_error)
  assert(type(on_message) == "function", "jsonlreader.new: on_message must be a function")
  -- GOTCHA 11: setmetatable {__index = M} so `rx:feed(chunk)` -> `M.feed(rx, chunk)`.
  -- WITHOUT it, `rx.feed` is nil and `rx:feed(...)` throws
  -- "attempt to call method 'feed' (a nil value)" (LIVE-VERIFIED). Standard Lua module-OOP.
  return setmetatable({
    buffer = "",
    on_message = on_message,
    on_error = on_error,
  }, { __index = M })
end

--- Process the next chunk: append it to the buffer, then drain ALL complete
--- `\n`-terminated lines. A single chunk may carry MANY records (drain loop) or a
--- PARTIAL record (left buffered for the next chunk).
---
--- Each complete line: strip a single trailing `\r` (CRLF tolerance), skip if empty
--- (`vim.json.decode("")` throws), else `pcall(vim.json.decode)` and invoke
--- `on_message(table)` on success — or `on_error(line, err)` on failure (silent if
--- `on_error` is unset). Never throws.
---
---@param self pi-bridge.JsonlReader
---@param chunk string The raw byte chunk from a luv `read_start` callback.
function M.feed(self, chunk)
  self.buffer = self.buffer .. chunk
  while true do
    -- GOTCHA 3: the 4th `true` arg = PLAIN byte scan (pattern matching OFF), so literal
    -- '%', '.', '+', '(' etc. inside JSON values do not corrupt the LF search.
    local nl = self.buffer:find("\n", 1, true)
    if not nl then
      return -- incomplete trailing line stays buffered for the next chunk
    end
    local line = self.buffer:sub(1, nl - 1)
    self.buffer = self.buffer:sub(nl + 1)
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2) -- strip ONE trailing \r (CRLF tolerance)
    end
    if line ~= "" then -- GOTCHA 4: skip blank lines (decode("") throws)
      local ok, msg = pcall(vim.json.decode, line)
      if ok then
        self.on_message(msg)
      elseif self.on_error then
        self.on_error(line, msg)
      end
      -- else: silent-degrade (PRD §11) when on_error is unset.
    end
  end
end

--- Flush a buffered FINAL line that lacks a trailing `\n` (mirrors the TS reader's
--- `onEnd`). Call on EOF — the luv `read_start` callback receiving `data == nil, err ==
--- nil`. No-op on an empty buffer. Never throws.
---
---@param self pi-bridge.JsonlReader
function M.flush(self)
  if self.buffer == "" then
    return -- GOTCHA 10: no-op on an empty buffer (no spurious empty-line decode)
  end
  local line = self.buffer
  self.buffer = ""
  if line:sub(-1) == "\r" then
    line = line:sub(1, -2)
  end
  if line ~= "" then
    local ok, msg = pcall(vim.json.decode, line)
    if ok then
      self.on_message(msg)
    elseif self.on_error then
      self.on_error(line, msg)
    end
  end
end

--- Clear the internal buffer (drop any partial line). For reconnect / test isolation.
--- Does NOT decode or emit. Cheap; idempotent.
---
---@param self pi-bridge.JsonlReader
function M.reset(self)
  self.buffer = ""
end

return M