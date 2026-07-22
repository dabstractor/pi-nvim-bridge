-- === tests/cmp_source_spec.lua — plenary/busted spec (the Level-2 gate) ===
-- Covers every Success Criterion from PRP P4.M12.T30.S46. MOCKS the bridge (sets
-- require("pi-bridge").bridge = fake with controllable request/cancel/is_connected) so it
-- tests the supersession / item-mapping / execute logic FAST without a socket (the bridge
-- transport is already exhaustively tested by bridge_request_spec). Mirrors the
-- vim.wait(ms, predicate, interval) async style of completion_spec.lua / blink_source_spec.
--
-- DIFFERENCES vs blink_source_spec (the DIRECT analog):
--   * describe: pi-bridge.cmp_source (NOT blink_source)
--   * reset: source._reset_for_test() clears gen/inflight_id (NOT current_id)
--   * new(): returns is_available/get_trigger_characters/get_keyword_pattern/complete/execute
--     (NOT enabled/get_completions; cmp adds get_keyword_pattern)
--   * complete(request, callback): builds a cmp SourceRequestParams subset
--     {context={bufnr=…, cursor={…}, cursor_line=…, cursor_before_line=…}, offset=…,
--      completion_context={triggerKind=2, triggerCharacter="/"}}. The source reads bufnr
--     from request.context + cursor via nvim_win_get_cursor (NOT request.context.cursor).
--   * supersession: driven by state.gen (a 2nd complete call bumps gen; the 1st cb is
--     dropped at the gen-guard) — cmp gives NO ctx.id, unlike blink.
--   * callback shape: {items=…, isIncomplete=false} (NOT blink's is_incomplete_forward/…).
--   * execute(item, callback) (NO ctx / default_implementation args — cmp's execute takes
--     NEITHER); callback(completion_item) on accept (NOT callback()); bufnr from
--     completion_item.data.bufnr (the load-bearing cmp-vs-blink difference).
--
-- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
-- `pending` (the test-SKIP function). We use `got`/`results` locals.
--
-- Run (from the repo root):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/cmp_source_spec.lua")'
local cmpsrc = require("pi-bridge.cmp_source")
local pi = require("pi-bridge")

if pi.config == nil then pi.setup({ debounce_ms = 10 }) end -- self-sufficient (mirror smoke.lua GOTCHA D)

--- A fake bridge with controllable request/cancel/is_connected (mirrors
--- completion_spec.lua's fake_bridge + blink_source_spec's). request() stores the cb
--- (returns a fresh numeric-string id); the spec fires cbs via fake.resolve(idx, err,
--- result) OR fake.resolve_last(err, result). cancel() records the cancelled id (and ALSO
--- fires the cb with "cancelled" — mirroring the real bridge so the gen-guard path is
--- exercised).
---@param opts? table optional {connected=false} to force disconnected, {auto_cancel_fires=false} to suppress the cb on cancel.
---@return table fake the fake bridge
local function fake_bridge(opts)
  opts = opts or {}
  local self = {
    connected = (opts.connected ~= false),
    requests = {},     -- every cb the fake has stored (order-preserving; 1-indexed)
    cancels = {},      -- every id passed to cancel (order-preserving)
    last_id = 0,
    auto_cancel_fires = (opts.auto_cancel_fires ~= false),
  }
  function self.is_connected() return self.connected end
  function self.request(method, params, cb)
    if not self.connected then
      vim.schedule_wrap(cb)("not connected")
      return nil
    end
    self.last_id = self.last_id + 1
    local id = tostring(self.last_id)
    self.requests[#self.requests + 1] = { id = id, method = method, params = params, cb = cb }
    return id
  end
  function self.cancel(id)
    self.cancels[#self.cancels + 1] = id
    if self.auto_cancel_fires then
      for i = #self.requests, 1, -1 do
        if self.requests[i].id == id then
          local entry = table.remove(self.requests, i)
          vim.schedule_wrap(entry.cb)("cancelled")
          break
        end
      end
    end
  end
  --- Fire the i-th stored cb (1-indexed) with (err, result).
  function self.resolve(i, err, result)
    local entry = self.requests[i]
    if not entry then return end
    vim.schedule_wrap(entry.cb)(err, result)
  end
  --- Fire the LAST stored cb with (err, result).
  function self.resolve_last(err, result)
    self.resolve(#self.requests, err, result)
  end
  return self
end

--- Reset between cases: clear the fake bridge + reset the cmp source's supersession
--- state. Idempotent + never throws.
local function reset()
  pi.bridge = nil
  -- reset the module-level supersession state (gen / inflight_id)
  pcall(function() require("pi-bridge.cmp_source")._reset_for_test() end)
end

--- Wait helper: vim.wait until `predicate()` is true (mirrors completion_spec / blink_source_spec).
local function wait_for(ms, predicate)
  return vim.wait(ms, predicate, 5)
end

--- Build a minimal cmp SourceRequestParams subset the source reads (`context.bufnr`).
--- The source reads bufnr from request.context + cursor via nvim_win_get_cursor (NOT
--- request.context.cursor.col — cmp's col is 1-based BYTE; the source sidesteps the ±1).
--- The cursor_* fields are forwarded in case a future task needs them, but the current
--- mapper derives the range from the real cursor + coords. The triggerKind=2 /
--- triggerCharacter="/" mirror a real cmp invocation on a slash trigger.
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

describe("pi-bridge.cmp_source", function()
  before_each(reset)
  after_each(reset)

  -- (1) new() returns a source object with all the required methods as functions
  it("new() returns a source with is_available/get_trigger_characters/get_keyword_pattern/complete/execute as functions", function()
    local src = cmpsrc.new()
    assert.is_not_nil(src)
    assert.are.equals("function", type(src.is_available))
    assert.are.equals("function", type(src.get_trigger_characters))
    assert.are.equals("function", type(src.get_keyword_pattern))
    assert.are.equals("function", type(src.complete))
    assert.are.equals("function", type(src.execute))
    -- new() ignores params (pi config read live)
    assert.is_not_nil(cmpsrc.new(nil))
    assert.is_not_nil(cmpsrc.new({ name = "pi" }))
  end)

  -- (2) get_trigger_characters contains "/" + "@"
  it("get_trigger_characters() contains '/' and '@'", function()
    local src = cmpsrc.new()
    local chars = src:get_trigger_characters()
    local has = {}
    for _, c in ipairs(chars) do has[c] = true end
    assert.is_true(has["/"], "must contain '/'")
    assert.is_true(has["@"], "must contain '@'")
  end)

  -- (2b) get_keyword_pattern returns a string (informational; textEdit overrides)
  it("get_keyword_pattern() returns a string", function()
    local src = cmpsrc.new()
    local pat = src:get_keyword_pattern({})
    assert.are.equals("string", type(pat))
    assert.truthy(pat:len() > 0, "pattern must be non-empty")
  end)

  -- (3) is_available() is true in a pi-prompt buffer, false otherwise
  describe("is_available()", function()
    it("returns true in a pi-prompt buffer", function()
      local buf = vim.api.nvim_create_buf(true, false)
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.bo[buf].filetype = "pi-prompt"
      local src = cmpsrc.new()
      assert.is_true(src:is_available())
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("returns false in a non-pi-prompt buffer", function()
      local buf = vim.api.nvim_create_buf(true, false)
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.bo[buf].filetype = "markdown"
      local src = cmpsrc.new()
      assert.is_false(src:is_available())
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  -- (4) complete happy path: issues getSuggestions with EXACT params + maps items + callback shape
  it("complete issues getSuggestions {lines,cursorLine,cursorCol,force=false} + maps items + callback shape", function()
    local fake = fake_bridge()
    pi.bridge = fake
    local src = cmpsrc.new()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mo" })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].virtualedit = "onemore"
    vim.api.nvim_win_set_cursor(win, { 1, 3 }) -- row 1, byte col 3 (end of "/mo")

    local got
    src:complete(make_request(buf), function(resp) got = resp end)
    assert.are.equals(1, #fake.requests, "must issue exactly 1 getSuggestions")
    assert.are.equals("getSuggestions", fake.requests[1].method)
    local p = fake.requests[1].params
    assert.are.same({ "/mo" }, p.lines)
    assert.are.equals(0, p.cursorLine) -- row 1 - 1
    assert.are.equals(3, p.cursorCol)  -- "/mo" ASCII byte 3 == utf16 3
    assert.is_false(p.force)
    assert.is_nil(p.method)            -- sanity: the envelope's `method` is NOT in params

    -- resolve with a slash item → mapped to a cmp item with label/kind/detail/textEdit/data
    fake.resolve_last(nil, { items = { { value = "/model", label = "model", description = "switch model" } }, prefix = "/mo" })
    wait_for(200, function() return got ~= nil end)
    assert.is_not_nil(got, "callback must fire with the response")
    assert.is_false(got.isIncomplete)
    assert.are.equals(1, #got.items, "must map exactly 1 item")
    local it = got.items[1]
    assert.are.equals("model", it.label)
    assert.are.equals(vim.lsp.protocol.CompletionItemKind.Keyword, it.kind, "slash value → Keyword")
    assert.are.equals("switch model", it.detail)
    assert.are.equals("/model", it.textEdit.newText)
    -- range covers the prefix at the cursor (line 0, start_char 0, end_char 3)
    assert.are.equals(0, it.textEdit.range.start.line)
    assert.are.equals(0, it.textEdit.range.start.character) -- end(3) - utf16_len("/mo")=3 → 0
    assert.are.equals(0, it.textEdit.range["end"].line)
    assert.are.equals(3, it.textEdit.range["end"].character)
    -- data round-trips the snapshot (incl. bufnr — the load-bearing cmp-vs-blink field)
    assert.are.equals(buf, it.data.bufnr, "data.bufnr == the request's bufnr")
    assert.are.equals("/model", it.data.pi.value)
    assert.are.equals("/mo", it.data.prefix)
    assert.are.same({ "/mo" }, it.data.lines)
    assert.are.equals(0, it.data.cursorLine)
    assert.are.equals(3, it.data.cursorCol)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (4b) item mapping: @file → File kind; directory → Folder kind; else → Text kind
  describe("item mapping kind heuristic", function()
    local function kind_for(value)
      local src = cmpsrc.new()
      local fake = fake_bridge()
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "@sr" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].virtualedit = "onemore"
      vim.api.nvim_win_set_cursor(win, { 1, 3 })
      local got
      src:complete(make_request(buf), function(resp) got = resp end)
      fake.resolve_last(nil, { items = { { value = value, label = value, description = "d" } }, prefix = "@sr" })
      wait_for(200, function() return got ~= nil end)
      local k = got and got.items and got.items[1] and got.items[1].kind
      vim.api.nvim_buf_delete(buf, { force = true })
      return k
    end

    it("maps an @file value to File (17)", function()
      assert.are.equals(vim.lsp.protocol.CompletionItemKind.File, kind_for("@/src/comp.ts"))
    end)
    it("maps a directory value (ends with /) to Folder (19)", function()
      assert.are.equals(vim.lsp.protocol.CompletionItemKind.Folder, kind_for("@/src/subdir/"))
    end)
    it("maps a plain value to Text (1)", function()
      assert.are.equals(vim.lsp.protocol.CompletionItemKind.Text, kind_for("plain-arg"))
    end)
  end)

  -- (5) supersession: a newer state.gen wins; an older cb is dropped at the gen-guard (no callback, no stale items)
  it("supersedes via cancel(prev_id) AND drops a stale response at the gen-guard", function()
    local fake = fake_bridge({ auto_cancel_fires = false }) -- we drive cbs manually
    pi.bridge = fake
    local src = cmpsrc.new()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mo" })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].virtualedit = "onemore"
    vim.api.nvim_win_set_cursor(win, { 1, 3 })

    -- 1st complete (slow; do not resolve). cmp gives NO id, so the source self-increments state.gen.
    local got1
    src:complete(make_request(buf), function(resp) got1 = resp end)
    wait_for(200, function() return #fake.requests >= 1 end)
    local id1 = fake.requests[1].id
    local stale_cb = fake.requests[1].cb
    -- 2nd complete → cancels request 1 (layer 1) + bumps state.gen (layer 2)
    local got2
    src:complete(make_request(buf), function(resp) got2 = resp end)
    wait_for(200, function() return #fake.requests >= 2 end)
    -- layer 1: cancel(prev_id) was called
    assert.is_true(#fake.cancels >= 1, "cancel(prev_id) must be called on supersede")
    assert.are.equals(id1, fake.cancels[1])
    -- layer 2: resolve the STALE (1st) cb with a result — got1 must NOT fire (gen-guard)
    vim.schedule_wrap(stale_cb)(nil, { items = { { value = "stale", label = "stale" } }, prefix = "/mo" })
    wait_for(100, function() return false end) -- let the scheduled stale cb settle (a no-op)
    assert.is_nil(got1, "a stale response must NOT fire callback (gen-guard)")
    -- now resolve the 2nd (current gen) cb → got2 fires
    vim.schedule_wrap(fake.requests[2].cb)(nil, { items = { { value = "model", label = "model" } }, prefix = "/mo" })
    wait_for(200, function() return got2 ~= nil end)
    assert.is_not_nil(got2, "the latest response must fire callback")
    assert.are.equals(1, #got2.items)
    assert.are.equals("model", got2.items[1].label)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (6) error/cancelled/timeout → callback() (nil); no throw, no stale items
  describe("error/cancelled/timeout → callback() nil", function()
    local function case(err_value)
      local fake = fake_bridge({ auto_cancel_fires = false })
      pi.bridge = fake
      local src = cmpsrc.new()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/m" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].virtualedit = "onemore"
      vim.api.nvim_win_set_cursor(win, { 1, 2 })
      local got = "UNSET"
      src:complete(make_request(buf), function(resp) got = resp end)
      wait_for(200, function() return #fake.requests >= 1 end)
      vim.schedule_wrap(fake.requests[1].cb)(err_value, nil)
      wait_for(150, function() return got ~= "UNSET" end)
      assert.is_nil(got, "callback() must be nil (nothing) on " .. tostring(err_value))
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    it("timeout → callback() nil", function() case("request timeout") end)
    it("cancelled → callback() nil", function() case("cancelled") end)
    it("rpc error → callback() nil", function() case("rpc error -32603") end)
  end)

  -- (7) null result → callback with empty items (NOT an error)
  it("treats a null result as success with empty items (NOT an error)", function()
    local fake = fake_bridge()
    pi.bridge = fake
    local src = cmpsrc.new()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/zzz" })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].virtualedit = "onemore"
    vim.api.nvim_win_set_cursor(win, { 1, 4 })
    local got
    src:complete(make_request(buf), function(resp) got = resp end)
    wait_for(200, function() return #fake.requests >= 1 end)
    fake.resolve_last(nil, nil) -- null result → cb(nil, nil)
    wait_for(200, function() return got ~= nil end)
    assert.is_not_nil(got, "null result must fire callback (success, empty)")
    assert.is_false(got.isIncomplete)
    assert.are.equals(0, #got.items)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (8) bridge nil / disconnected → callback() nil (graceful)
  describe("bridge nil / disconnected → callback() nil", function()
    it("pi.bridge == nil → callback() nil, no throw", function()
      pi.bridge = nil
      local src = cmpsrc.new()
      local got = "UNSET"
      assert.has_no.errors(function()
        src:complete(make_request(0), function(resp) got = resp end)
      end)
      assert.is_nil(got, "callback() must be nil when bridge is nil")
    end)

    it("bridge.is_connected() == false → callback() nil", function()
      local fake = fake_bridge({ connected = false })
      pi.bridge = fake
      local src = cmpsrc.new()
      local got = "UNSET"
      src:complete(make_request(0), function(resp) got = resp end)
      assert.is_nil(got, "callback() must be nil when disconnected")
      assert.are.equals(0, #fake.requests, "disconnected bridge must issue no request")
    end)
  end)

  -- (9) execute happy path: applyCompletion params + callback(item) immediate + cb set_lines/set_cursor
  describe("execute", function()
    -- helper: drive complete to capture a populated cmp item with a snapshot (incl. bufnr)
    local function populated_item(buf_text, byte_col, pi_item, prefix)
      local fake = fake_bridge()
      pi.bridge = fake
      local src = cmpsrc.new()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { buf_text })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].virtualedit = "onemore"
      vim.api.nvim_win_set_cursor(win, { 1, byte_col })
      local got
      src:complete(make_request(buf), function(resp) got = resp end)
      fake.resolve_last(nil, { items = { pi_item }, prefix = prefix })
      wait_for(200, function() return got ~= nil end)
      return fake, buf, win, src, got and got.items and got.items[1]
    end

    -- (9a) execute issues applyCompletion with the EXACT params shape (snapshot; bufnr from data)
    it("execute issues applyCompletion with {lines,cursorLine,cursorCol,item,prefix} from the snapshot", function()
      local fake, buf, _win, src, item = populated_item("/mo", 3, { value = "/model", label = "model" }, "/mo")
      assert.is_not_nil(item, "must have a populated cmp item")
      local n0 = #fake.requests
      local cb_called = false
      local returned
      src:execute(item, function(ret) cb_called = true; returned = ret end)
      -- callback(completion_item) IMMEDIATE (responsive; never stalls cmp)
      assert.is_true(cb_called, "callback(item) must fire IMMEDIATELY (before the RPC resolves)")
      assert.are.equals(item, returned, "callback must receive the completion_item back")
      wait_for(200, function() return #fake.requests > n0 end)
      local req = fake.requests[#fake.requests]
      assert.are.equals("applyCompletion", req.method)
      assert.are.same({ "/mo" }, req.params.lines)
      assert.are.equals(0, req.params.cursorLine)
      assert.are.equals(3, req.params.cursorCol)
      assert.are.same({ value = "/model", label = "model" }, req.params.item)
      assert.are.equals("/mo", req.params.prefix)
      assert.is_nil(req.params.force) -- NO force on apply
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (9b) cb success replaces the buffer wholesale + sets the cursor (NO -1)
    it("cb success replaces the buffer wholesale + sets cursor (NO -1)", function()
      local fake, buf, win, src, item = populated_item("/mo", 3, { value = "/model", label = "model" }, "/mo")
      src:execute(item, function() end)
      fake.resolve_last(nil, { lines = { "/model " }, cursorLine = 0, cursorCol = 7 })
      wait_for(200, function()
        return vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "/model " })
      end)
      assert.are.same({ "/model " }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.are.same({ 1, 7 }, vim.api.nvim_win_get_cursor(win), "cursor must be byte 7 (NO -1)")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (9c) MULTIBYTE cursor is byte-correct (NO -1; utf16→byte conversion)
    it("positions the cursor at the exact BYTE offset on a multibyte result (proves NO -1)", function()
      -- result line "/café " = / c a f é SPACE = 1+1+1+1+2+1 = 7 bytes; utf16 = 6 units.
      -- cursorCol = 6 (utf16) → byte 7 (0-based; NO -1).
      local fake, buf, win, src, item = populated_item("/café", 6, { value = "/café", label = "café" }, "/café")
      src:execute(item, function() end)
      fake.resolve_last(nil, { lines = { "/café " }, cursorLine = 0, cursorCol = 6 }) -- utf16 6
      wait_for(200, function()
        return vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "/café " })
      end)
      assert.are.same({ "/café " }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.are.same({ 1, 7 }, vim.api.nvim_win_get_cursor(win), "cursor must be byte 7, NOT 6 (NO -1)")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (9d) cb error → buffer untouched (degrade; never throws)
    it("cb error leaves the buffer untouched (degrade)", function()
      local fake, buf, _win, src, item = populated_item("/mo", 3, { value = "/model", label = "model" }, "/mo")
      src:execute(item, function() end)
      fake.resolve_last("rpc error -32603", nil)
      wait_for(150, function() return false end) -- let the err cb settle
      assert.are.same({ "/mo" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "buffer UNTOUCHED on error")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (9e) malformed completion_item.data → callback(item) + no throw
    it("malformed completion_item.data (no .pi) → callback(item) + no throw", function()
      local src = cmpsrc.new()
      local cb_called = false
      assert.has_no.errors(function()
        src:execute({ data = nil }, function() cb_called = true end)
        src:execute({ data = { prefix = "x" } }, function() cb_called = true end)
        src:execute(nil, function() cb_called = true end)
      end)
      assert.is_true(cb_called, "callback(item) must fire on malformed data")
    end)

    -- (9f) bridge nil/disconnected → callback(item) (buffer left as cmp's textEdit)
    it("bridge nil/disconnected → callback(item) (graceful)", function()
      local src = cmpsrc.new()
      pi.bridge = nil
      local cb_called = false
      src:execute({ data = { pi = { value = "x" } } }, function() cb_called = true end)
      assert.is_true(cb_called, "callback(item) must fire when bridge is nil")
      local fake = fake_bridge({ connected = false })
      pi.bridge = fake
      cb_called = false
      src:execute({ data = { pi = { value = "x" } } }, function() cb_called = true end)
      assert.is_true(cb_called, "callback(item) must fire when disconnected")
      assert.are.equals(0, #fake.requests, "disconnected bridge must issue no request")
    end)

    -- (9g) execute does NOT take a ctx / default_implementation arg (cmp's execute signature)
    --      — verified structurally: execute(item, callback) reads bufnr from item.data.bufnr.
    it("reads bufnr from completion_item.data (cmp's execute has NO ctx)", function()
      -- two buffers; the snapshot's bufnr must win (NOT the current window's buf)
      local fake = fake_bridge()
      pi.bridge = fake
      local src = cmpsrc.new()
      local buf_a = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf_a, 0, -1, false, { "/mo" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf_a)
      vim.wo[win].virtualedit = "onemore"
      vim.api.nvim_win_set_cursor(win, { 1, 3 })
      local got
      src:complete(make_request(buf_a), function(resp) got = resp end)
      fake.resolve_last(nil, { items = { { value = "/model", label = "model" } }, prefix = "/mo" })
      wait_for(200, function() return got ~= nil end)
      local item = got.items[1]
      assert.are.equals(buf_a, item.data.bufnr, "snapshot carries buf_a")

      -- switch the window to a DIFFERENT buffer (buf_b) BEFORE execute, so the only way
      -- execute mutates buf_a (not buf_b) is by reading bufnr from item.data.
      local buf_b = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf_b, 0, -1, false, { "other" })
      vim.api.nvim_win_set_buf(win, buf_b)

      src:execute(item, function() end)
      fake.resolve_last(nil, { lines = { "/model " }, cursorLine = 0, cursorCol = 7 })
      wait_for(200, function()
        return vim.deep_equal(vim.api.nvim_buf_get_lines(buf_a, 0, -1, false), { "/model " })
      end)
      -- buf_a got the accept (bufnr-from-data), buf_b untouched
      assert.are.same({ "/model " }, vim.api.nvim_buf_get_lines(buf_a, 0, -1, false),
        "buf_a (from data.bufnr) must be mutated")
      assert.are.same({ "other" }, vim.api.nvim_buf_get_lines(buf_b, 0, -1, false),
        "buf_b (current window) must be UNTOUCHED — proves bufnr came from data, not a ctx")
      vim.api.nvim_buf_delete(buf_a, { force = true })
      vim.api.nvim_buf_delete(buf_b, { force = true })
    end)
  end)

  -- (10) never requires cmp at runtime: package.loaded["cmp"] stays nil
  it("never requires cmp at runtime (package.loaded['cmp'] stays nil)", function()
    -- the module was already required at the top of this spec
    assert.is_nil(package.loaded["cmp"], "package.loaded['cmp'] must be nil (dormant rule)")
  end)

  -- (11) never-throws on bad args to complete / execute
  describe("never-throws on bad args", function()
    it("complete with a wiped buf → callback() nil, no throw", function()
      local fake = fake_bridge()
      pi.bridge = fake
      local src = cmpsrc.new()
      local buf = 999999 -- an invalid handle
      local got = "UNSET"
      assert.has_no.errors(function()
        src:complete(make_request(buf), function(resp) got = resp end)
      end)
      assert.is_nil(got, "callback() nil on invalid buf")
    end)

    it("complete with nil request → callback() nil, no throw", function()
      local fake = fake_bridge()
      pi.bridge = fake
      local src = cmpsrc.new()
      local got = "UNSET"
      assert.has_no.errors(function()
        src:complete(nil, function(resp) got = resp end)
      end)
      assert.is_nil(got)
    end)
  end)
end)