-- === plugin/tests/menu_autoclose_smoke.lua — standalone (plenary-FREE) smoke ===
-- The S37 Level-3 integration gate: a LIGHT real-bridge + real-completion + real-menu
-- AUTO-CLOSE integration. Spins a fake luv unix-socket server (the menu_smoke.lua
-- bootstrap), handshakes the REAL bridge, drives REAL completion via menu.attach() +
-- completion.refresh, then simulates the S37 autocmds via nvim_exec_autocmds (no real
-- keystrokes — headless-safe). Flows:
--   FLOW 1 (InsertLeave):  refresh("/mo") → reply items → menu open → InsertLeave → menu + window closed.
--   FLOW 2 (BufLeave):     refresh → menu open → BufLeave → menu closed.
--   FLOW 3 (CursorMoved-out via refresh — §3): refresh → menu open → move cursor out of prefix →
--                          refresh → reply empty → menu closed (the EXISTING S30 path).
--   FLOW 4 (race):         refresh → menu open → refresh AGAIN → InsertLeave → no stale re-open.
-- Prints SMOKE_PASS / exit 0.
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u NORC +"luafile tests/menu_autoclose_smoke.lua" +qa
--   echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
--
-- NO plenary. Reuses the menu_smoke.lua fake-server bootstrap + check/footer pattern.
-- NEVER pipe a heredoc into nvim stdin (AGENTS.md).

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

-- ── spin a fake luv unix-socket server (mirror menu_smoke) ──────────────────────
-- The server replies: hello→ok; getSuggestions→{items,prefix} where the reply is
-- controlled by `next_reply` (so a flow can send items then empty).
local path = "/tmp/pi-menu-autoclose-smoke-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
os.remove(path)
local srv = uv.new_pipe(false)
srv:bind(path)
local srv_rx, srv_conn
local seen = {}             -- every decoded client request the server saw (order-preserving)
local next_reply = { items = { { value = "/model", label = "model" } }, prefix = "/mo" }
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
    local reply = next_reply or { items = {}, prefix = "" }
    if srv_conn and not srv_conn:is_closing() then
      srv_conn:write(vim.json.encode({
        jsonrpc = "2.0", id = req.id,
        result = reply,
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

-- ── helpers ─────────────────────────────────────────────────────────────────────
-- populate the menu via the REAL seam + wait for it to open. Returns nothing.
local function populate(buf)
  next_reply = { items = { { value = "/model", label = "model" } }, prefix = "/mo" }
  local n0 = #seen
  completion.refresh(buf)
  vim.wait(500, function() return #seen > n0 end, 5)
  vim.wait(500, function() return menu.is_open() end, 5)
end

-- ── the auto-close flows ────────────────────────────────────────────────────────
if pi.bridge == bridge then
  menu.attach()
  check(completion.on_results == menu.on_results, "attach must wire completion.on_results -> menu.on_results")

  -- a pi-prompt-ish buffer + window (2 lines so FLOW 3 can move cursor off the prefix)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mo", "" })
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = 1, col = 1, width = 60, height = 6, border = "none",
  })
  vim.wo[win].virtualedit = "onemore" -- allow cursor at EOL (byte col 3 on '/mo')
  -- source the ftplugin so the InsertLeave/BufLeave buffer-local autocmds are REGISTERED
  -- (a plain scratch buffer has no pi-prompt autocmds; nvim_exec_autocmds would be a no-op).
  vim.bo[buf].filetype = "pi-prompt"

  -- FLOW 1 (InsertLeave): refresh → menu open → InsertLeave → menu + window closed
  vim.api.nvim_win_set_cursor(win, { 1, 3 }) -- end of "/mo"
  populate(buf)
  check(menu.is_open(), "F1: menu must be open before InsertLeave")
  check(menu._state.win ~= nil, "F1: window handle must exist before InsertLeave")
  vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
  vim.wait(300, function() return not menu.is_open() end, 5)
  check(not menu.is_open(), "F1: InsertLeave must close the menu")
  check(menu._state.win == nil, "F1: InsertLeave must nil the window handle")

  -- FLOW 2 (BufLeave): refresh → menu open → BufLeave → menu closed
  vim.api.nvim_win_set_cursor(win, { 1, 3 })
  populate(buf)
  check(menu.is_open(), "F2: menu must be open before BufLeave")
  vim.api.nvim_exec_autocmds("BufLeave", { buffer = buf })
  vim.wait(300, function() return not menu.is_open() end, 5)
  check(not menu.is_open(), "F2: BufLeave must close the menu")

  -- FLOW 3 (CursorMoved-out-of-prefix via the EXISTING refresh path — §3):
  -- refresh → menu open → move cursor to the blank line 2 → refresh → reply empty → closed
  vim.api.nvim_win_set_cursor(win, { 1, 3 })
  populate(buf)
  check(menu.is_open(), "F3: menu must be open before CursorMoved-out")
  vim.api.nvim_win_set_cursor(win, { 2, 0 }) -- move cursor to the blank line 2 (out of /mo)
  next_reply = { items = {}, prefix = "" }    -- pi returns empty (not completable on a blank line)
  local n0 = #seen
  completion.refresh(buf)                     -- CursorMovedI -> refresh
  vim.wait(500, function() return #seen > n0 end, 5)
  vim.wait(500, function() return not menu.is_open() end, 5)
  check(not menu.is_open(), "F3: CursorMoved-out -> refresh -> empty -> menu.close() (the S30 path)")

  -- FLOW 4 (race): refresh → menu open → refresh AGAIN → InsertLeave → no stale re-open
  vim.api.nvim_win_set_cursor(win, { 1, 3 })
  populate(buf)
  check(menu.is_open(), "F4: menu must be open before the race")
  completion.refresh(buf)                     -- schedules a NEW debounce (do_refresh NOT yet issued)
  vim.api.nvim_exec_autocmds("InsertLeave", { buffer = buf }) -- hide + cancel the pending debounce
  vim.wait(150, function() return false end)  -- let the would-be 5ms defer window elapse
  check(not menu.is_open(), "F4: a stale do_refresh must NOT re-open the menu in normal mode")

  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- ── teardown ────────────────────────────────────────────────────────────────────
pcall(function() menu.reset() end)
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