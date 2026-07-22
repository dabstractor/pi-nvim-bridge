-- === plugin/tests/cmp_source_smoke.lua — standalone (plenary-FREE) smoke ===
-- The Level-3 integration gate for S46 (cmp_source): a fake luv unix-socket server +
-- the REAL bridge.handshake + REAL cmp_source + REAL coords. NO real nvim-cmp (we drive
-- the module directly — the smoke IS the automated proof of the same surface Level 4
-- covers manually with a real nvim-cmp install).
-- Flow:
--   set buffer {"@sr"}, filetype pi-prompt, cursor EOL →
--   src:complete(make_request(buf), cb) → server sees getSuggestions →
--   reply {items={{value="@/src/comp.ts",label="comp.ts",description="src/comp.ts"}},
--   prefix="@sr"} → vim.wait → assert resp.items[1].textEdit.newText == "@/src/comp.ts"
--   + .data.pi.value + .data.prefix + .data.bufnr == buf →
--   src:execute(resp.items[1], cb) → server sees applyCompletion with
--   {item=<pi>, prefix="@sr", lines={"@sr"}, cursorLine=0, cursorCol=3} →
--   reply {lines={"@/src/comp.ts "}, cursorLine=0, cursorCol=14} →
--   vim.wait → assert buffer == {"@/src/comp.ts "} + cursor {1,14}.
-- Prints SMOKE_PASS / exit 0.
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua +"luafile tests/cmp_source_smoke.lua" +qa
--   echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
--
-- NO plenary. Mirrors blink_source_smoke.lua's bootstrap (the fake-server + real-bridge
-- idiom) VERBATIM; swaps blink→cmp + get_completions→complete + the execute signature.
-- NEVER pipe a heredoc into nvim stdin (AGENTS.md ⛔ HARD RULE).

-- Add the plugin root to runtimepath so `require("pi-bridge.*")` resolves (the
-- coords_smoke.lua bootstrap pattern). Works whether run from plugin/ or repo root.
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../plugin (the runtimepath entry)
vim.opt.runtimepath:append(plugin_root)

local uv = vim.uv
local jreader = require("pi-bridge.jsonlreader")
local bridge = require("pi-bridge.bridge")
local pi = require("pi-bridge")
local cmpsrc = require("pi-bridge.cmp_source")

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

-- ── spin a fake luv unix-socket server (mirror completion_accept_smoke) ──────────
-- The server replies: hello→ok; getSuggestions→{items,prefix}; applyCompletion→
-- {lines,cursorLine,cursorCol} + stashes the observed req for the assertions.
local path = "/tmp/pi-cmp-smoke-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
os.remove(path)
local srv = uv.new_pipe(false)
srv:bind(path)
local srv_rx, srv_conn
local seen = {}             -- every decoded client request (order-preserving)
local gs_req = nil          -- the observed getSuggestions req
local apply_req = nil       -- the observed applyCompletion req
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
    gs_req = req
    if srv_conn and not srv_conn:is_closing() then
      srv_conn:write(vim.json.encode({
        jsonrpc = "2.0", id = req.id,
        result = {
          items = { { value = "@/src/comp.ts", label = "comp.ts", description = "src/comp.ts" } },
          prefix = "@sr",
        },
      }) .. "\n")
    end
  elseif req.method == "applyCompletion" then
    apply_req = req
    if srv_conn and not srv_conn:is_closing() then
      srv_conn:write(vim.json.encode({
        jsonrpc = "2.0", id = req.id,
        result = { lines = { "@/src/comp.ts " }, cursorLine = 0, cursorCol = 14 },
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

-- ── the cmp source round-trip (driven directly — NO real nvim-cmp) ──────────────
if pi.bridge == bridge then
  -- sanity: requiring cmp_source did NOT require cmp (the dormant rule)
  check(package.loaded["cmp"] == nil, "package.loaded['cmp'] must stay nil (dormant rule)")

  local src = cmpsrc.new()
  check(type(src.complete) == "function", "new() returns a source with complete")
  check(type(src.execute) == "function", "new() returns a source with execute")
  check(type(src.is_available) == "function", "new() returns a source with is_available")
  check(type(src.get_keyword_pattern) == "function", "new() returns a source with get_keyword_pattern")

  -- trigger characters contain "/" + "@"
  local chars = src:get_trigger_characters()
  local has = {}
  for _, c in ipairs(chars) do has[c] = true end
  check(has["/"] == true, "get_trigger_characters contains '/'")
  check(has["@"] == true, "get_trigger_characters contains '@'")

  -- get_keyword_pattern returns a non-empty string (informational)
  local pat = src:get_keyword_pattern({})
  check(type(pat) == "string" and #pat > 0, "get_keyword_pattern returns a non-empty string")

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "@sr" })
  vim.bo[buf].filetype = "pi-prompt"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = 1, col = 1, width = 40, height = 4, border = "none",
  })
  vim.wo[win].virtualedit = "onemore" -- allow cursor at EOL
  vim.api.nvim_win_set_cursor(win, { 1, 3 }) -- end of "@sr" (byte col 3)

  -- is_available() is true in a pi-prompt buffer
  check(src:is_available() == true, "is_available() == true in a pi-prompt buffer")

  -- build a minimal cmp SourceRequestParams subset (the source reads bufnr + real cursor)
  local function make_request(bufnr)
    return {
      context = {
        bufnr = bufnr,
        cursor = { row = 1, col = 1, line = 0, character = 0 },
        cursor_line = "",
        cursor_before_line = "",
      },
      offset = 0,
      completion_context = { triggerKind = 2, triggerCharacter = "/" },
    }
  end

  -- 1) complete → server sees getSuggestions → reply {items, prefix}
  local resp
  src:complete(make_request(buf), function(r) resp = r end)
  vim.wait(500, function() return gs_req ~= nil end, 5)
  check(gs_req ~= nil, "server must observe a getSuggestions request")
  if gs_req then
    local p = gs_req.params or {}
    check(p.method == nil, "the envelope's method must NOT be in params")
    check(vim.deep_equal(p.lines, { "@sr" }), "getSuggestions params.lines == { '@sr' }")
    check(p.cursorLine == 0, "getSuggestions params.cursorLine == 0 (got " .. tostring(p.cursorLine) .. ")")
    check(p.cursorCol == 3, "getSuggestions params.cursorCol == 3 (utf16; got " .. tostring(p.cursorCol) .. ")")
    check(p.force == false, "getSuggestions params.force == false")
  end
  vim.wait(500, function() return resp ~= nil end, 5)
  check(resp ~= nil, "complete callback must fire with a response")
  if resp then
    check(resp.isIncomplete == false, "response.isIncomplete == false")
    check(#resp.items == 1, "response has exactly 1 item")
    local it = resp.items[1]
    check(it.label == "comp.ts", "item.label == 'comp.ts'")
    check(it.kind == vim.lsp.protocol.CompletionItemKind.File, "item.kind == File (17) for an @file value")
    check(it.detail == "src/comp.ts", "item.detail == 'src/comp.ts'")
    check(it.textEdit.newText == "@/src/comp.ts", "item.textEdit.newText == '@/src/comp.ts'")
    -- range covers the prefix at the cursor (line 0, end 3, start 3-utf16('@sr')=0)
    check(it.textEdit.range.start.line == 0, "range.start.line == 0")
    check(it.textEdit.range.start.character == 0, "range.start.character == 0 (3 - utf16('@sr')=3 → 0)")
    check(it.textEdit.range["end"].line == 0, "range['end'].line == 0")
    check(it.textEdit.range["end"].character == 3, "range['end'].character == 3 (cursor utf16)")
    -- data round-trips the snapshot (incl. bufnr — the load-bearing cmp-vs-blink field)
    check(it.data.bufnr == buf, "data.bufnr == buf (cmp's execute has NO ctx)")
    check(it.data.pi.value == "@/src/comp.ts", "data.pi.value == '@/src/comp.ts' (verbatim)")
    check(it.data.pi.label == "comp.ts", "data.pi.label == 'comp.ts' (verbatim)")
    check(it.data.prefix == "@sr", "data.prefix == '@sr'")
    check(vim.deep_equal(it.data.lines, { "@sr" }), "data.lines == { '@sr' }")
    check(it.data.cursorLine == 0, "data.cursorLine == 0")
    check(it.data.cursorCol == 3, "data.cursorCol == 3")

    -- 2) execute → server sees applyCompletion with the snapshot → reply {lines,cursorLine,cursorCol}
    local n_before = #seen
    local cb_fired = false
    local cb_arg
    src:execute(it, function(ret) cb_fired = true; cb_arg = ret end)
    check(cb_fired == true, "execute callback(item) must fire IMMEDIATELY (before the RPC resolves)")
    check(cb_arg == it, "execute callback receives the completion_item back")
    vim.wait(500, function() return #seen > n_before end, 5)
    vim.wait(500, function() return apply_req ~= nil end, 5)
    check(apply_req ~= nil, "server must observe an applyCompletion request")
    if apply_req then
      local ap = apply_req.params or {}
      check(ap.method == nil, "applyCompletion envelope method must NOT be in params")
      check(ap.item ~= nil and ap.item.value == "@/src/comp.ts",
        "applyCompletion params.item.value == '@/src/comp.ts' (got " .. tostring(ap.item and ap.item.value) .. ")")
      check(ap.prefix == "@sr", "applyCompletion params.prefix == '@sr' (got " .. tostring(ap.prefix) .. ")")
      check(vim.deep_equal(ap.lines, { "@sr" }), "applyCompletion params.lines == { '@sr' }")
      check(ap.cursorLine == 0, "applyCompletion params.cursorLine == 0 (got " .. tostring(ap.cursorLine) .. ")")
      check(ap.cursorCol == 3, "applyCompletion params.cursorCol == 3 (got " .. tostring(ap.cursorCol) .. ")")
      check(ap.force == nil, "applyCompletion params has NO force key")
    end

    -- 3) server reply → buffer replaced wholesale + cursor set (NO -1)
    vim.wait(500, function()
      return vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "@/src/comp.ts " })
    end, 5)
    check(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "@/src/comp.ts " }),
      "buffer must be replaced wholesale with { '@/src/comp.ts ' }")
    check(vim.deep_equal(vim.api.nvim_win_get_cursor(win), { 1, 14 }),
      "cursor must be {1,14} (0-based byte col 14; NO -1)")
  end

  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- ── teardown ────────────────────────────────────────────────────────────────────
pcall(function() bridge.close() end)
if srv_conn and not srv_conn:is_closing() then pcall(function() srv_conn:close() end) end
if srv and not srv:is_closing() then pcall(function() srv:close() end) end
os.remove(path)

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")