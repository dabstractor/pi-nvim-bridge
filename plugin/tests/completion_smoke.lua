-- === plugin/tests/completion_smoke.lua — standalone (plenary-FREE) smoke test ===
-- The Level-2a validation gate: a LIGHT real-bridge integration. Spins a fake luv
-- unix-socket server (the bridge_request_spec `with_request_server` pattern), handshakes
-- the REAL bridge, sets a buffer's lines + cursor, calls completion.refresh(buf), drives
-- the debounce with vim.wait, and asserts the server received a getSuggestions request
-- whose params match the buffer via S29 coords. Prints SMOKE_PASS / exit 0.
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u NORC +"luafile tests/completion_smoke.lua" +qa
--   echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
--
-- NO plenary. Reuses the coords_smoke.lua `check`/`fails`/`cquit`/`SMOKE_PASS` footer.

-- Add the plugin root to runtimepath so `require("pi-editor.*")` resolves (the
-- coords_smoke.lua bootstrap pattern). Works whether run from plugin/ or repo root.
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../plugin (the runtimepath entry)
vim.opt.runtimepath:append(plugin_root)

local uv = vim.uv
local jreader = require("pi-editor.jsonlreader")
local bridge = require("pi-editor.bridge")
local pi = require("pi-editor")
local completion = require("pi-editor.completion")
local coords = require("pi-editor.coords")

if pi.config == nil then pi.setup({ debounce_ms = 5 }) end -- self-sufficient (GOTCHA D)

local DESC_CWD = "/tmp/proj"
local TOKEN = "deadbeefdeadbeefdeadbeefdeadbeef"

local fails = 0
local function check(cond, msg)
  if not cond then
    io.stderr:write("FAIL: " .. msg .. "\n")
    fails = fails + 1
  end
end

-- ── spin a fake luv unix-socket server (mirror bridge_request_spec) ──────────────
local path = "/tmp/pi-comp-smoke-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
os.remove(path)
local srv = uv.new_pipe(false)
srv:bind(path)
local srv_rx, srv_conn
local seen = {}     -- every decoded client request the server saw (order-preserving)
local hello_replied = false
srv_rx = jreader.new(function(req)
  -- ALWAYS reply to `hello` with a valid HelloResult so the handshake succeeds.
  if req.method == "hello" then
    hello_replied = true
    if srv_conn and not srv_conn:is_closing() then
      srv_conn:write(vim.json.encode({
        jsonrpc = "2.0", id = req.id,
        result = {
          ok = true,
          serverVersion = "0.1.0",
          cwd = DESC_CWD,
          fdAvailable = true,
        },
      }) .. "\n")
    end
    return -- hello handled; getSuggestions handled below
  end
  seen[#seen + 1] = req
  if req.method == "getSuggestions" then
    -- reply with an empty result (null) so completion's cb resolves cleanly
    if srv_conn and not srv_conn:is_closing() then
      srv_conn:write(vim.json.encode({ jsonrpc = "2.0", id = req.id, result = vim.NIL }) .. "\n")
    end
  end
end)
srv:listen(128, function()
  srv_conn = uv.new_pipe(false)
  srv:accept(srv_conn)
  srv_conn:read_start(function(rerr, data)
    if rerr or data == nil then return end
    srv_rx:feed(data)
  end)
end)

-- ── handshake the REAL bridge ───────────────────────────────────────────────────
local descriptor = {
  transport = "unix", path = path, token = TOKEN,
  pid = 1, cwd = DESC_CWD, fdAvailable = true, serverVersion = "0.1.0",
}
local hs_err
bridge.handshake(descriptor, function(err) hs_err = err end)
vim.wait(500, function() return hs_err ~= nil or pi.bridge == bridge end, 5)
check(hs_err == nil, "handshake must succeed (got: " .. tostring(hs_err) .. ")")
check(pi.bridge == bridge, "handshake must publish pi.bridge")
check(hello_replied, "server must have seen + replied to the hello handshake")

-- ── headline: refresh(buf) -> a getSuggestions request with S29 params arrives ────
if pi.bridge == bridge then
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mod" })
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = 1, col = 1, width = 40, height = 4, border = "none",
  })
  vim.wo[win].virtualedit = "onemore" -- allow cursor at EOL (byte col 4 on '/mod')
  vim.api.nvim_win_set_cursor(win, { 1, 4 }) -- row 1, byte col 4 (EOL of "/mod")
  local n_before = #seen
  completion.refresh(buf)
  -- drive the debounce + the request round-trip
  vim.wait(500, function() return #seen > n_before end, 5)
  vim.wait(80)
  check(#seen == n_before + 1, "exactly one getSuggestions request must arrive (got " .. (#seen - n_before) .. ")")
  local req = seen[#seen]
  check(req ~= nil, "the request must be captured")
  if req then
    check(req.method == "getSuggestions", "method == getSuggestions")
    check(req.params.lines[1] == "/mod", "params.lines[1] == '/mod' (got " .. tostring(req.params.lines and req.params.lines[1]) .. ")")
    check(req.params.cursorLine == 0, "params.cursorLine == 0 (row 1 - 1)")
    check(req.params.cursorCol == 4, "params.cursorCol == 4 (S29 UTF-16 of byte 4 in '/mod')")
    check(req.params.force == false, "params.force == false")
    -- cross-check against coords (the composition is nvim_to_pi_coords + force)
    local pi_coords = coords.nvim_to_pi_coords({ "/mod" }, 1, 4)
    check(req.params.cursorLine == pi_coords.cursorLine, "server cursorLine matches coords.nvim_to_pi_coords")
    check(req.params.cursorCol == pi_coords.cursorCol, "server cursorCol matches coords.nvim_to_pi_coords")
  end

  -- ── debounce: 3 rapid refreshes collapse to ≤1 NEW request ────────────────────
  local n_before2 = #seen
  completion.refresh(buf); completion.refresh(buf); completion.refresh(buf)
  vim.wait(500, function() return #seen > n_before2 end, 5)
  vim.wait(80)
  local new_after2 = #seen - n_before2
  check(new_after2 <= 1, "3 rapid refreshes must collapse to <=1 new request (got " .. new_after2 .. ")")
  check(new_after2 >= 1, "the debounced burst must still issue >=1 request (got " .. new_after2 .. ")")

  -- ── reset() never throws + is idempotent ─────────────────────────────────────
  check(pcall(function() completion.reset(); completion.reset(); completion.reset() end),
    "reset() is idempotent + never throws")

  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- ── teardown: completion.reset + bridge.close + server stop ─────────────────────
pcall(function() completion.reset() end)
pcall(function() bridge.close() end)
if srv_conn and not srv_conn:is_closing() then pcall(function() srv_conn:close() end) end
if srv and not srv:is_closing() then pcall(function() srv:close() end) end
os.remove(path)

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")