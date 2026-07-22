-- === tests/completion_accept_smoke.lua — standalone (plenary-FREE) smoke ===
-- The Level-3 integration gate for S32 (accept/on_enter): a fake luv unix-socket server +
-- the REAL bridge.handshake + REAL completion + menu.attach(). Flow:
--   refresh(/mo) → getSuggestions reply {items,prefix} → menu populated → on_enter(buf) →
--   server observes applyCompletion with {item, prefix, lines, cursorLine, cursorCol} →
--   server replies {lines, cursorLine, cursorCol} → assert buffer replaced + cursor set
--   (NO -1) + menu closed. Prints SMOKE_PASS / exit 0.
--
-- Run (from the repo root):
--   nvim --headless --clean -u NORC +"luafile tests/completion_accept_smoke.lua" +qa
--   echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
--
-- NO plenary. Mirrors menu_smoke.lua's bootstrap (the fake-server + real-bridge idiom) +
-- ADDS the applyCompletion round-trip. NEVER pipe a heredoc into nvim stdin (AGENTS.md).

-- Add the plugin root to runtimepath so `require("pi-bridge.*")` resolves (the
-- coords_smoke.lua bootstrap pattern). Works whether run from plugin/ or repo root.
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../<repo-root> (the runtimepath entry)
vim.opt.runtimepath:append(plugin_root)

local uv = vim.uv
local jreader = require("pi-bridge.jsonlreader")
local bridge = require("pi-bridge.bridge")
local pi = require("pi-bridge")
local completion = require("pi-bridge.completion")
local menu = require("pi-bridge.menu")

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
-- The server replies: hello→ok; getSuggestions→{items,prefix}; applyCompletion→
-- {lines,cursorLine,cursorCol} + stashes the observed req for the assertion.
local path = "/tmp/pi-accept-smoke-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
os.remove(path)
local srv = uv.new_pipe(false)
srv:bind(path)
local srv_rx, srv_conn
local seen = {}             -- every decoded client request (order-preserving)
local apply_req = nil       -- the observed applyCompletion req (for the assertion)
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
    if srv_conn and not srv_conn:is_closing() then
      srv_conn:write(vim.json.encode({
        jsonrpc = "2.0", id = req.id,
        result = { items = { { value = "/model", label = "model" } }, prefix = "/mo" },
      }) .. "\n")
    end
  elseif req.method == "applyCompletion" then
    apply_req = req -- stash for the assertion
    if srv_conn and not srv_conn:is_closing() then
      srv_conn:write(vim.json.encode({
        jsonrpc = "2.0", id = req.id,
        result = { lines = { "/model " }, cursorLine = 0, cursorCol = 7 },
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

-- ── the accept round-trip ───────────────────────────────────────────────────────
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

  -- 1) refresh → getSuggestions reply → menu populated
  local n_before = #seen
  completion.refresh(buf)
  vim.wait(500, function() return #seen > n_before end, 5)
  vim.wait(500, function() return menu.is_open() end, 5)
  check(menu.is_open(), "menu must be open after a non-empty getSuggestions reply")
  check(menu.get_selected() ~= nil and menu.get_selected().value == "/model",
    "menu.get_selected().value == '/model'")
  check(menu.get_prefix() == "/mo", "menu.get_prefix() == '/mo'")

  -- 2) on_enter(buf) → accept → server sees applyCompletion
  local n_before2 = #seen
  local handled = completion.on_enter(buf)
  check(handled == true, "on_enter(buf) must return true (CR consumed)")
  vim.wait(500, function() return #seen > n_before2 end, 5)
  vim.wait(500, function() return apply_req ~= nil end, 5)
  check(apply_req ~= nil, "server must observe an applyCompletion request")
  if apply_req then
    local p = apply_req.params or {}
    check(p.method == nil, "the envelope's method must NOT be in params")
    check(p.item ~= nil and p.item.value == "/model",
      "applyCompletion params.item.value == '/model' (got " .. tostring(p.item and p.item.value) .. ")")
    check(p.prefix == "/mo", "applyCompletion params.prefix == '/mo' (got " .. tostring(p.prefix) .. ")")
    check(vim.deep_equal(p.lines, { "/mo" }), "applyCompletion params.lines == { '/mo' }")
    check(p.cursorLine == 0, "applyCompletion params.cursorLine == 0 (got " .. tostring(p.cursorLine) .. ")")
    check(p.cursorCol == 3, "applyCompletion params.cursorCol == 3 (utf16; got " .. tostring(p.cursorCol) .. ")")
    check(p.force == nil, "applyCompletion params has NO force key")
  end

  -- 3) server reply {lines, cursorLine, cursorCol} → buffer + cursor + menu closed
  vim.wait(500, function() return not menu.is_open() end, 5)
  check(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "/model " }),
    "buffer must be replaced wholesale with { '/model ' }")
  check(vim.deep_equal(vim.api.nvim_win_get_cursor(win), { 1, 7 }),
    "cursor must be {1,7} (0-based byte col 7; NO -1)")
  check(not menu.is_open(), "menu must be closed after accept")

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