-- === plugin/tests/menu_smoke.lua — standalone (plenary-FREE) smoke test ===
-- The Level-2a validation gate: a LIGHT real-bridge + real-completion integration. Spins
-- a fake luv unix-socket server (the bridge_request_spec `with_request_server` pattern),
-- handshakes the REAL bridge, drives REAL completion via menu.attach() + completion.refresh,
-- and asserts the server's getSuggestions REPLY populates the menu state (is_open +
-- get_items + get_selected), then an empty reply CLOSES it. Prints SMOKE_PASS / exit 0.
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u NORC +"luafile tests/menu_smoke.lua" +qa
--   echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
--
-- NO plenary. Reuses the coords_smoke.lua `check`/`fails`/`cquit`/`SMOKE_PASS` footer +
-- the completion_smoke.lua fake-server bootstrap.

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
local menu = require("pi-editor.menu")

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

-- ── spin a fake luv unix-socket server (mirror completion_smoke) ────────────────
-- The server replies to getSuggestions with a controlled {items, prefix} payload so we
-- can drive BOTH the open path (non-empty items) and the close path (empty items).
local path = "/tmp/pi-menu-smoke-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
os.remove(path)
local srv = uv.new_pipe(false)
srv:bind(path)
local srv_rx, srv_conn
local seen = {}             -- every decoded client request the server saw (order-preserving)
local next_reply = nil      -- the {items, prefix} to reply for the NEXT getSuggestions
local hello_replied = false
srv_rx = jreader.new(function(req)
  if req.method == "hello" then
    hello_replied = true
    if srv_conn and not srv_conn:is_closing() then
      srv_conn:write(vim.json.encode({
        jsonrpc = "2.0", id = req.id,
        result = { ok = true, serverVersion = "0.1.0", cwd = DESC_CWD, fdAvailable = true },
      }) .. "\n")
    end
    return
  end
  seen[#seen + 1] = req
  if req.method == "getSuggestions" then
    -- reply with the controlled payload (default empty if none set)
    local payload = next_reply or { items = {}, prefix = "" }
    next_reply = nil -- consume
    if srv_conn and not srv_conn:is_closing() then
      srv_conn:write(vim.json.encode({
        jsonrpc = "2.0", id = req.id,
        result = payload,
      }) .. "\n")
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

-- ── CASE 1: a getSuggestions reply with items populates the menu ────────────────
if pi.bridge == bridge then
  menu.attach()
  check(completion.on_results == menu.on_results, "attach must wire completion.on_results -> menu.on_results")

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mo" })
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = 1, col = 1, width = 40, height = 4, border = "none",
  })
  vim.wo[win].virtualedit = "onemore" -- allow cursor at EOL (byte col 3 on '/mo')
  vim.api.nvim_win_set_cursor(win, { 1, 3 }) -- end of "/mo"

  -- prime the server reply + refresh
  next_reply = { items = { { value = "/model", label = "model" } }, prefix = "/mo" }
  local n_before = #seen
  completion.refresh(buf)
  -- drive the debounce + the request round-trip + the menu population
  vim.wait(500, function() return #seen > n_before end, 5)
  vim.wait(500, function() return menu.is_open() end, 5)
  check(menu.is_open(), "menu must be open after a non-empty getSuggestions reply")
  check(menu.get_items()[1] ~= nil and menu.get_items()[1].value == "/model",
    "menu.get_items()[1].value == '/model' (got " .. tostring(menu.get_items()[1] and menu.get_items()[1].value) .. ")")
  check(menu.get_selected() ~= nil and menu.get_selected().value == "/model",
    "menu.get_selected().value == '/model' (the first item, selected=1)")
  check(menu.get_prefix() == "/mo", "menu.get_prefix() == '/mo' (got " .. tostring(menu.get_prefix()) .. ")")
  check(menu.get_buf() == buf, "menu.get_buf() == the pi-prompt buffer")
  check(menu.has_items(), "menu.has_items() is true")

  -- ── CASE 2: an empty getSuggestions reply CLOSES the menu ────────────────────
  next_reply = { items = {}, prefix = "/zz" }
  local n_before2 = #seen
  completion.refresh(buf)
  vim.wait(500, function() return #seen > n_before2 end, 5)
  vim.wait(500, function() return not menu.is_open() end, 5)
  check(not menu.is_open(), "menu must be CLOSED after an empty getSuggestions reply")
  check(not menu.has_items(), "menu.has_items() is false after close")

  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- ── CASE 3: reset() never throws + bridge.close + server stop ───────────────────
check(pcall(function() menu.reset(); menu.reset() end), "menu.reset() is idempotent + never throws")
check(completion.on_results ~= menu.on_results, "reset must detach (restore on_results)")
check(not menu.is_open(), "reset must close the menu")

-- ── teardown ────────────────────────────────────────────────────────────────────
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