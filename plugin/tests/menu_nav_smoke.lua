-- === plugin/tests/menu_nav_smoke.lua — standalone (plenary-FREE) smoke test ===
-- The S36 Level-3 validation gate: a LIGHT real-bridge + real-completion + real-menu
-- NAVIGATION integration. Spins a fake luv unix-socket server (the menu_smoke.lua
-- bootstrap), handshakes the REAL bridge, drives REAL completion via menu.attach() +
-- completion.refresh, populates the menu with 3 items, then exercises the S36 keymap
-- handlers on_next/on_prev/on_dismiss end-to-end:
--   FLOW 1 (next cycle): on_next(buf) → selected 1→2→3→1 + PmenuSel extmark moves +
--     window id UNCHANGED (in-place, no flicker).
--   FLOW 2 (prev + wraparound): on_prev(buf) → 1→3 (wrap) → 3→2.
--   FLOW 3 (dismiss): on_dismiss(buf) → menu closed + window closed.
--   FLOW 4 (closed fall-through): on_next/on_prev/on_dismiss on a closed menu → false.
-- Prints SMOKE_PASS / exit 0.
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u NORC +"luafile tests/menu_nav_smoke.lua" +qa
--   echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
--
-- NO plenary. Reuses the menu_smoke.lua fake-server bootstrap + check/footer pattern.

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
local path = "/tmp/pi-menu-nav-smoke-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
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

-- ── the 0-based row carrying PmenuSel, or nil (headless-safe — NOT screenattr) ──
local function sel_row()
  if not menu._state.menu_buf then return nil end
  local ns = vim.api.nvim_create_namespace("pi-editor-menu")
  for r = 0, 9 do
    for _, mk in ipairs(vim.api.nvim_buf_get_extmarks(menu._state.menu_buf, ns, { r, 0 }, { r, -1 }, { details = true })) do
      if mk[4] and mk[4].hl_group == "PmenuSel" then return r end
    end
  end
  return nil
end

if pi.bridge == bridge then
  menu.attach()
  check(completion.on_results == menu.on_results, "attach must wire completion.on_results -> menu.on_results")

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mo" })
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = 1, col = 1, width = 60, height = 6, border = "none",
  })
  vim.wo[win].virtualedit = "onemore" -- allow cursor at EOL
  vim.api.nvim_win_set_cursor(win, { 1, 3 }) -- end of "/mo"

  -- prime the server reply with 3 items + refresh (populate the menu)
  next_reply = {
    items = {
      { value = "/model", label = "model", description = "Switch the model" },
      { value = "/mood", label = "mood", description = "Set the mood" },
      { value = "/more", label = "more", description = "More" },
    },
    prefix = "/mo",
  }
  local n_before = #seen
  completion.refresh(buf)
  vim.wait(500, function() return #seen > n_before end, 5)
  vim.wait(500, function() return menu.is_open() end, 5)
  check(menu.is_open(), "menu must be open after a non-empty getSuggestions reply")
  check(menu._state.selected == 1, "selected==1 after open (1-based)")
  check(sel_row() == 0, "PmenuSel at row 0 (selected-1) after open")
  local win0 = menu._state.win
  check(type(win0) == "number" and vim.api.nvim_win_is_valid(win0), "window valid after open")

  -- ── FLOW 1: on_next(buf) cycles 1→2→3→1; PmenuSel moves; window UNCHANGED ──
  check(completion.on_next(buf) == true, "FLOW1 on_next(buf) returns true (1→2)")
  check(menu._state.selected == 2, "FLOW1 on_next: selected==2")
  check(sel_row() == 1, "FLOW1 on_next: PmenuSel@row1")
  check(menu._state.win == win0, "FLOW1 on_next: window id UNCHANGED (in-place)")
  check(vim.api.nvim_win_is_valid(win0), "FLOW1 on_next: window still valid")

  check(completion.on_next(buf) == true, "FLOW1 on_next(buf) returns true (2→3)")
  check(menu._state.selected == 3, "FLOW1 on_next: selected==3")
  check(sel_row() == 2, "FLOW1 on_next: PmenuSel@row2")

  check(completion.on_next(buf) == true, "FLOW1 on_next(buf) returns true (3→1 wrap)")
  check(menu._state.selected == 1, "FLOW1 on_next wrap: selected==1")
  check(sel_row() == 0, "FLOW1 on_next wrap: PmenuSel@row0")
  check(menu._state.win == win0, "FLOW1 on_next wrap: window still UNCHANGED")

  -- ── FLOW 2: on_prev(buf) retreats + wraparound 1→3→2 ──
  check(completion.on_prev(buf) == true, "FLOW2 on_prev(buf) returns true (1→3 wrap)")
  check(menu._state.selected == 3, "FLOW2 on_prev wrap: selected==3")
  check(sel_row() == 2, "FLOW2 on_prev wrap: PmenuSel@row2")

  check(completion.on_prev(buf) == true, "FLOW2 on_prev(buf) returns true (3→2)")
  check(menu._state.selected == 2, "FLOW2 on_prev: selected==2")
  check(sel_row() == 1, "FLOW2 on_prev: PmenuSel@row1")
  check(menu._state.win == win0, "FLOW2 on_prev: window still UNCHANGED (in-place)")

  -- ── FLOW 3: on_dismiss(buf) closes the menu + window ──
  check(completion.on_dismiss(buf) == true, "FLOW3 on_dismiss(buf) returns true")
  check(not menu.is_open(), "FLOW3 on_dismiss: menu closed")
  check(menu._state.selected == 0, "FLOW3 on_dismiss: selected==0")
  check(menu._state.win == nil, "FLOW3 on_dismiss: state.win nil")
  check(not vim.api.nvim_win_is_valid(win0), "FLOW3 on_dismiss: window closed")

  -- ── FLOW 4: closed fall-through — on_next/on_prev/on_dismiss → false (no throw) ──
  check(completion.on_next(buf) == false, "FLOW4 on_next false when closed")
  check(completion.on_prev(buf) == false, "FLOW4 on_prev false when closed")
  check(completion.on_dismiss(buf) == false, "FLOW4 on_dismiss false when closed")
  check(not menu.is_open(), "FLOW4 closed handlers must not reopen the menu")
  check(menu._state.win == nil, "FLOW4 closed handlers must not create a window")

  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- ── reset() never throws + bridge.close + server stop ───────────────────────────
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