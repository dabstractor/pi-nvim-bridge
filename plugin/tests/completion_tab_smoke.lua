-- === plugin/tests/completion_tab_smoke.lua — standalone (plenary-FREE) smoke ===
-- The Level-3 integration gate for S33 (on_tab): a fake luv unix-socket server + the
-- REAL bridge.handshake + REAL completion + menu.attach(). Flows:
--   FLOW 1 (menu-open accept): refresh(/mod) → getSuggestions reply {items,prefix} → menu
--     populated → on_tab(buf) → server observes applyCompletion → reply {lines,cursorLine,
--     cursorCol} → assert buffer replaced + cursor set (NO -1) + menu closed.
--   FLOW 2 (file-force show): menu closed → on_tab(./src/com) → server observes
--     shouldTriggerFileCompletion → reply true → server observes getSuggestions force=true →
--     reply >1 items → assert menu.is_open().
--   FLOW 3 (single-item auto-apply): menu closed → on_tab(./x) → shouldTrigger true →
--     getSuggestions reply 1 item → server observes applyCompletion → reply {lines,cursor}
--     → assert buffer applied + menu closed.
-- Prints SMOKE_PASS / exit 0.
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u NORC +"luafile tests/completion_tab_smoke.lua" +qa
--   echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
--
-- NO plenary. Mirrors completion_accept_smoke.lua's bootstrap (the fake-server + real-bridge
-- idiom) + ADDS the shouldTriggerFileCompletion round-trip + the 3 Tab flows. NEVER pipe a
-- heredoc into nvim stdin (AGENTS.md).

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

-- ── spin a fake luv unix-socket server (mirror completion_accept_smoke) ─────────
-- The server replies: hello→ok; shouldTriggerFileCompletion→<controlled bool>;
-- getSuggestions→<controlled {items,prefix}>; applyCompletion→{lines,cursorLine,cursorCol}
-- + stashes the observed req. The controlled reply values are set per-flow below.
local path = "/tmp/pi-tab-smoke-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
os.remove(path)
local srv = uv.new_pipe(false)
srv:bind(path)
local srv_rx, srv_conn
local seen = {}                 -- every decoded client request (order-preserving)
local apply_req = nil           -- the observed applyCompletion req (for the assertion)
local hello_replied = false
-- Controlled per-flow server replies (mutated before each on_tab).
local reply_trigger = true      -- shouldTriggerFileCompletion reply (bool)
local reply_gs = { items = { { value = "/model", label = "model" } }, prefix = "/mo" } -- getSuggestions reply
local reply_apply = { lines = { "/model " }, cursorLine = 0, cursorCol = 7 } -- applyCompletion reply

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
  if req.method == "shouldTriggerFileCompletion" then
    if srv_conn and not srv_conn:is_closing() then
      srv_conn:write(vim.json.encode({
        jsonrpc = "2.0", id = req.id, result = reply_trigger,
      }) .. "\n")
    end
  elseif req.method == "getSuggestions" then
    if srv_conn and not srv_conn:is_closing() then
      srv_conn:write(vim.json.encode({
        jsonrpc = "2.0", id = req.id, result = reply_gs,
      }) .. "\n")
    end
  elseif req.method == "applyCompletion" then
    apply_req = req -- stash for the assertion
    if srv_conn and not srv_conn:is_closing() then
      srv_conn:write(vim.json.encode({
        jsonrpc = "2.0", id = req.id, result = reply_apply,
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

-- ── handshake the REAL bridge ──────────────────────────────────────────────────
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

-- Helper: make a current window on a buf with the given lines + cursor.
local function open_buf(lines, row, byte_col)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = 1, col = 1, width = 40, height = 4, border = "none",
  })
  vim.wo[win].virtualedit = "onemore" -- allow cursor at EOL
  vim.api.nvim_win_set_cursor(win, { row, byte_col })
  return buf, win
end

local function method_at(i) return seen[i] and seen[i].method end

-- ── the 3 Tab flows ────────────────────────────────────────────────────────────
if pi.bridge == bridge then
  menu.attach()
  check(completion.on_results == menu.on_results, "attach must wire completion.on_results -> menu.on_results")

  -- ═══ FLOW 1: menu OPEN + Tab → accept (applyCompletion) ═══
  do
    reply_gs = { items = { { value = "/model", label = "model" } }, prefix = "/mo" }
    reply_apply = { lines = { "/model " }, cursorLine = 0, cursorCol = 7 }
    apply_req = nil
    menu.close()
    local buf, win = open_buf({ "/mod" }, 1, 3) -- cursor end of "/mod"

    -- 1) refresh → getSuggestions reply → menu populated
    local n0 = #seen
    completion.refresh(buf)
    vim.wait(500, function() return #seen > n0 end, 5)
    vim.wait(500, function() return menu.is_open() end, 5)
    check(menu.is_open(), "FLOW1: menu must be open after a non-empty getSuggestions reply")
    check(menu.get_selected() ~= nil and menu.get_selected().value == "/model",
      "FLOW1: menu.get_selected().value == '/model'")

    -- 2) on_tab(buf) → accept → server sees applyCompletion
    local n1 = #seen
    local handled = completion.on_tab(buf)
    check(handled == true, "FLOW1: on_tab(buf) must return true (Tab consumed)")
    vim.wait(500, function() return #seen > n1 end, 5)
    vim.wait(500, function() return apply_req ~= nil end, 5)
    check(apply_req ~= nil, "FLOW1: server must observe an applyCompletion request")
    if apply_req then
      local p = apply_req.params or {}
      check(p.item ~= nil and p.item.value == "/model",
        "FLOW1: applyCompletion params.item.value == '/model'")
      check(p.prefix == "/mo", "FLOW1: applyCompletion params.prefix == '/mo'")
    end

    -- 3) server reply → buffer + cursor + menu closed
    vim.wait(500, function() return not menu.is_open() end, 5)
    check(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "/model " }),
      "FLOW1: buffer must be replaced wholesale with { '/model ' }")
    check(vim.deep_equal(vim.api.nvim_win_get_cursor(win), { 1, 7 }),
      "FLOW1: cursor must be {1,7} (0-based byte col 7; NO -1)")
    check(not menu.is_open(), "FLOW1: menu must be closed after accept")

    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- ═══ FLOW 2: menu CLOSED + non-slash → shouldTrigger → force:true getSuggestions (show) ═══
  do
    reply_trigger = true
    reply_gs = {
      items = { { value = "./src/a", label = "a" }, { value = "./src/b", label = "b" } },
      prefix = "./",
    }
    menu.close()
    local buf, win = open_buf({ "./src/com" }, 1, 8) -- cursor end of "./src/com"

    local n0 = #seen
    local handled = completion.on_tab(buf)
    check(handled == true, "FLOW2: on_tab(buf) must return true (Tab consumed)")
    -- 1) shouldTriggerFileCompletion fires FIRST
    vim.wait(500, function() return #seen > n0 end, 5)
    check(method_at(#seen) == "shouldTriggerFileCompletion",
      "FLOW2: first req must be shouldTriggerFileCompletion (got " .. tostring(method_at(#seen)) .. ")")
    local trigger_params = seen[#seen].params
    check(vim.deep_equal(trigger_params.lines, { "./src/com" }), "FLOW2: shouldTrigger params.lines")
    check(trigger_params.cursorLine == 0, "FLOW2: shouldTrigger params.cursorLine == 0")
    check(trigger_params.cursorCol == 8, "FLOW2: shouldTrigger params.cursorCol == 8")

    -- 2) → force:true getSuggestions
    vim.wait(500, function() return #seen > n0 + 1 end, 5)
    check(method_at(#seen) == "getSuggestions", "FLOW2: next req must be getSuggestions")
    if method_at(#seen) == "getSuggestions" then
      check(seen[#seen].params.force == true, "FLOW2: getSuggestions force must be true (file-force)")
    end

    -- 3) >1 items reply → menu OPENS (shown, not auto-applied)
    vim.wait(500, function() return menu.is_open() end, 5)
    check(menu.is_open(), "FLOW2: multi-item force result must open the menu (not auto-apply)")

    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- ═══ FLOW 3: single-item auto-apply (force:true + 1 item → applyCompletion) ═══
  do
    reply_trigger = true
    reply_gs = { items = { { value = "./x.rs", label = "x.rs" } }, prefix = "./" }
    reply_apply = { lines = { "./x.rs " }, cursorLine = 0, cursorCol = 7 }
    apply_req = nil
    menu.close()
    local buf, win = open_buf({ "./x" }, 1, 3) -- cursor end of "./x"

    local n0 = #seen
    local handled = completion.on_tab(buf)
    check(handled == true, "FLOW3: on_tab(buf) must return true (Tab consumed)")
    -- shouldTrigger → force getSuggestions (1 item) → applyCompletion
    vim.wait(500, function() return #seen > n0 end, 5)
    check(method_at(#seen) == "shouldTriggerFileCompletion", "FLOW3: first req must be shouldTriggerFileCompletion")
    vim.wait(500, function() return #seen > n0 + 1 end, 5)
    check(method_at(#seen) == "getSuggestions", "FLOW3: next req must be getSuggestions")
    if method_at(#seen) == "getSuggestions" then
      check(seen[#seen].params.force == true, "FLOW3: getSuggestions force must be true")
    end
    -- 1-item reply → auto-apply (applyCompletion with the RESULT prefix, NOT menu.get_prefix)
    vim.wait(500, function() return #seen > n0 + 2 end, 5)
    check(method_at(#seen) == "applyCompletion", "FLOW3: single-item force result must auto-apply (applyCompletion)")
    check(apply_req ~= nil, "FLOW3: server must observe the auto-apply applyCompletion")
    if apply_req then
      local p = apply_req.params or {}
      check(p.item ~= nil and p.item.value == "./x.rs",
        "FLOW3: applyCompletion params.item.value == './x.rs'")
      check(p.prefix == "./", "FLOW3: applyCompletion params.prefix == './' (the RESULT prefix, NOT menu.get_prefix)")
    end
    check(not menu.is_open(), "FLOW3: single-item auto-apply must NOT open the menu")
    -- server reply → buffer applied
    vim.wait(500, function()
      return vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "./x.rs " })
    end, 5)
    check(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "./x.rs " }),
      "FLOW3: buffer must be replaced with { './x.rs ' }")

    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

-- ── teardown ──────────────────────────────────────────────────────────────────
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