-- === tests/completion_spec.lua — plenary/busted spec (the Level-2 gate) ===
-- Covers every Success Criterion from PRP P2.M7.T18.S30. MOCKS the bridge (sets
-- require("pi-bridge").bridge = fake with controllable request/cancel/is_connected) so
-- it tests the debounce / supersession / seam logic FAST without a socket (the bridge
-- transport is already exhaustively tested by bridge_request_spec). Mirrors the
-- vim.wait(ms, predicate, interval) async style of bridge_request_spec.lua.
--
-- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
-- `pending` (the test-SKIP function). We use `got`/`results` locals.
--
-- Run (from the repo root):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
local completion = require("pi-bridge.completion")
local menu = require("pi-bridge.menu")
local pi = require("pi-bridge")

if pi.config == nil then pi.setup({ debounce_ms = 10 }) end -- self-sufficient (mirror smoke.lua GOTCHA D)

-- Save/restore debounce_ms across cases so a case can shrink it without leaking.
local DEFAULT_DEBOUNCE = (pi.config or pi.defaults).debounce_ms

--- A fake bridge with controllable request/cancel/is_connected. request() stores the cb
--- (returns a fresh numeric-string id); the spec fires cbs via fake.resolve(idx, err, result)
--- OR fake.resolve_last(err, result). cancel() records the cancelled id (and ALSO fires
--- the cb with "cancelled" — mirroring the real bridge so the gen-guard path is exercised).
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
      -- find + fire the matching cb (mirrors the real bridge) so a stale cb is testable
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

--- Reset between cases: clear the fake bridge, run completion.reset() (cancels timer +
--- inflight), restore debounce_ms, + menu.reset() (closes + detaches + clears menu
--- state). Idempotent + never throws.
local function reset()
  pi.bridge = nil
  completion.on_results = nil
  pcall(completion.reset)
  pcall(menu.reset)
  if pi.config then pi.config.debounce_ms = DEFAULT_DEBOUNCE end
end

--- Wait helper: vim.wait until `predicate()` is true (mirrors bridge_request_spec).
local function wait_for(ms, predicate)
  return vim.wait(ms, predicate, 5)
end

describe("pi-bridge.completion", function()
  before_each(reset)
  after_each(reset)

  --- Set up a populated menu via the REAL seam: a buffer with the given line + cursor,
  --- menu.attach(), refresh(), resolve getSuggestions with the given items/prefix,
  --- wait for the menu to open. Returns (fake, buf, win). The caller deletes buf/win.
  --- Shared by the S32 (accept/on_enter) + S33 (on_tab) describe blocks.
  local function populated_menu(line, byte_col, items, prefix)
    local fake = fake_bridge()
    pi.bridge = fake
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].virtualedit = "onemore" -- allow cursor at EOL
    vim.api.nvim_win_set_cursor(win, { 1, byte_col })
    menu.attach()
    completion.refresh(buf)
    wait_for(200, function() return #fake.requests >= 1 end)
    fake.resolve_last(nil, { items = items, prefix = prefix })
    wait_for(200, function() return menu.is_open() end)
    return fake, buf, win
  end

  -- (1) surface: refresh/reset/current are functions; on_results is settable (nil default)
  it("exposes refresh/reset/current as functions and on_results as a settable nil slot", function()
    assert.are.equals("function", type(completion.refresh))
    assert.are.equals("function", type(completion.reset))
    assert.are.equals("function", type(completion.current))
    assert.is_nil(completion.on_results)
    completion.on_results = function() end
    assert.are.equals("function", type(completion.on_results))
    completion.on_results = nil
    assert.is_nil(completion.on_results)
  end)

  -- (2) debounce: 3 rapid refreshes within the window issue EXACTLY ONE request
  it("debounces rapid refreshes into exactly one getSuggestions request", function()
    local fake = fake_bridge()
    pi.bridge = fake
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mod" })
    -- make the buffer the CURRENT window buffer (do_refresh guards buf == current_buf,
    -- so a non-current buf would correctly bail — set it current to exercise the fetch)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    -- 3 rapid refreshes (no wait between them -> all collapse into the last defer)
    completion.refresh(buf); completion.refresh(buf); completion.refresh(buf)
    wait_for(200, function() return #fake.requests >= 1 end)
    assert.are.equals(1, #fake.requests, "debounce must issue exactly 1 request, got " .. #fake.requests)
    assert.are.equals("getSuggestions", fake.requests[1].method)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (3) params composition via S29 coords (real buffer so coords converts real data)
  it("issues getSuggestions with params == {lines, cursorLine=row-1, cursorCol=<S29>, force=false}", function()
    local fake = fake_bridge()
    pi.bridge = fake
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mod" })
    -- make the buffer current + put the cursor on it (completion reads the CURRENT buf)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    -- virtualedit=onemore so the cursor can sit at EOL (byte col 4 == one past last char
    -- of "/mod"); without it nvim clamps to col 3.
    vim.wo[win].virtualedit = "onemore"
    vim.api.nvim_win_set_cursor(win, { 1, 4 }) -- row 1, byte col 4 (end of "/mod")
    completion.refresh(buf)
    wait_for(200, function() return #fake.requests >= 1 end)
    assert.are.equals(1, #fake.requests)
    local p = fake.requests[1].params
    assert.are.same({ "/mod" }, p.lines)
    assert.are.equals(0, p.cursorLine)  -- row 1 - 1
    assert.are.equals(4, p.cursorCol)   -- S29: "/mod" ASCII byte 4 == utf16 4
    assert.is_false(p.force)
    assert.is_nil(p.method)             -- sanity: the envelope's `method` is NOT in params
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (4) two-layer supersession: cancel(prev) AND a stale cb is dropped (gen-guard)
  it("supersedes via cancel(prev_id) AND drops a stale response at the gen-guard", function()
    local fake = fake_bridge({ auto_cancel_fires = false }) -- we drive cbs manually
    pi.bridge = fake
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mod" })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_cursor(win, { 1, 4 })
    -- 1st refresh -> request 1 (slow; do not resolve)
    completion.refresh(buf)
    wait_for(200, function() return #fake.requests >= 1 end)
    local id1 = fake.requests[1].id
    local stale_cb = fake.requests[1].cb
    -- 2nd refresh -> cancels request 1 (layer 1) + bumps gen (layer 2)
    local seam = 0
    completion.on_results = function() seam = seam + 1 end
    completion.refresh(buf)
    wait_for(200, function() return #fake.requests >= 2 end)
    -- layer 1: cancel(prev_id) was called
    assert.is_true(#fake.cancels >= 1, "cancel(prev_id) must be called on supersede")
    assert.are.equals(id1, fake.cancels[1])
    -- layer 2: resolve the STALE (1st) cb with a result — on_results must NOT fire
    vim.schedule_wrap(stale_cb)(nil, { items = { { value = "x", label = "x" } }, prefix = "/mod" })
    wait_for(100, function() return false end) -- let the scheduled cb run (no-op wait)
    assert.are.equals(0, seam, "a stale response must NOT fire on_results (gen-guard)")
    assert.is_nil(completion.current(), "last_result must be untouched by a stale response")
    -- now resolve the 2nd (current-gen) cb -> on_results fires + stores
    local items2 = { { value = "model", label = "model" } }
    vim.schedule_wrap(fake.requests[2].cb)(nil, { items = items2, prefix = "/mod" })
    wait_for(200, function() return seam >= 1 end)
    assert.are.equals(1, seam, "the latest response must fire on_results")
    assert.are.same(items2, completion.current().items)
    assert.are.equals("/mod", completion.current().prefix)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (5) on_results seam fires on success with (buf, items, prefix)
  it("fires on_results(buf, items, prefix) on the latest success", function()
    local fake = fake_bridge()
    pi.bridge = fake
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "@app" })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_cursor(win, { 1, 4 })
    local got
    completion.on_results = function(b, items, prefix) got = { b, items, prefix } end
    completion.refresh(buf)
    wait_for(200, function() return #fake.requests >= 1 end)
    local items = { { value = "app.ts", label = "app.ts" } }
    vim.schedule_wrap(fake.requests[1].cb)(nil, { items = items, prefix = "@app" })
    wait_for(200, function() return got ~= nil end)
    assert.is_not_nil(got)
    assert.are.equals(buf, got[1])
    assert.are.same(items, got[2])
    assert.are.equals("@app", got[3])
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (6) null result (cb(nil, nil)) -> {items={}, prefix=""} stored + on_results(buf, {}, "")
  it("treats a null result as success with empty items (NOT an error)", function()
    local fake = fake_bridge()
    pi.bridge = fake
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/zzz" })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_cursor(win, { 1, 4 })
    local got
    completion.on_results = function(b, items, prefix) got = { b, items, prefix } end
    completion.refresh(buf)
    wait_for(200, function() return #fake.requests >= 1 end)
    vim.schedule_wrap(fake.requests[1].cb)(nil, nil) -- null result -> cb(nil, nil)
    wait_for(200, function() return got ~= nil end)
    assert.is_not_nil(got, "null result must fire on_results (success, empty)")
    assert.are.same({}, got[2])
    assert.are.equals("", got[3])
    local cur = completion.current()
    assert.is_not_nil(cur)
    assert.are.same({}, cur.items)
    assert.are.equals("", cur.prefix)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (7) error/cancelled/timeout -> touch nothing (last_result unchanged, on_results NOT called)
  describe("error/cancelled/timeout -> touch nothing", function()
    local function case(err_value)
      local fake = fake_bridge({ auto_cancel_fires = false })
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/m" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.api.nvim_win_set_cursor(win, { 1, 2 })
      -- pre-seed last_result so we can PROVE it is untouched on a failed fetch
      completion.on_results = function() end
      -- drive a success first to seed last_result
      completion.refresh(buf)
      wait_for(200, function() return #fake.requests >= 1 end)
      vim.schedule_wrap(fake.requests[1].cb)(nil, { items = { { value = "seed", label = "seed" } }, prefix = "/m" })
      wait_for(200, function() return completion.current() ~= nil end)
      local seeded = completion.current()
      -- now a 2nd refresh resolves with an ERROR -> must NOT clear last_result / NOT fire on_results
      local seam = 0
      completion.on_results = function() seam = seam + 1 end
      completion.refresh(buf)
      wait_for(200, function() return #fake.requests >= 2 end)
      vim.schedule_wrap(fake.requests[2].cb)(err_value, nil)
      wait_for(150, function() return false end) -- let the scheduled err cb settle
      assert.are.equals(0, seam, "on_results must NOT fire on " .. tostring(err_value))
      assert.are.same(seeded.items, completion.current().items, "last_result must be unchanged on " .. tostring(err_value))
      vim.api.nvim_buf_delete(buf, { force = true })
    end

    it("timeout leaves last_result unchanged + does not call on_results", function() case("timeout") end)
    it("cancelled leaves last_result unchanged + does not call on_results", function() case("cancelled") end)
    it("a generic error leaves last_result unchanged + does not call on_results", function() case("rpc error -32603") end)
  end)

  -- (8) bridge read FRESH at call time (require completion FIRST, THEN set pi.bridge)
  it("works when pi.bridge is set AFTER completion is first required (no module-load caching)", function()
    -- completion was already required at the top of this file; set the bridge NOW
    local fake = fake_bridge()
    pi.bridge = fake
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/m" })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_cursor(win, { 1, 2 })
    completion.refresh(buf)
    wait_for(200, function() return #fake.requests >= 1 end)
    assert.are.equals(1, #fake.requests, "refresh must use the bridge set after require (read fresh)")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (9) bridge absent / disconnected -> no throw, no request, no-op
  describe("bridge absent / disconnected -> silent degrade", function()
    it("pi.bridge == nil: refresh never throws and issues no request", function()
      pi.bridge = nil
      local buf = vim.api.nvim_create_buf(true, false)
      assert.has_no.errors(function()
        completion.refresh(buf)
        wait_for(100, function() return false end) -- let the defer fire + bail
      end)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("bridge.is_connected() == false: refresh issues no request", function()
      local fake = fake_bridge({ connected = false })
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      assert.has_no.errors(function()
        completion.refresh(buf)
        wait_for(100, function() return false end)
      end)
      assert.are.equals(0, #fake.requests, "disconnected bridge must issue no request")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  -- (10) reset(): cancels the debounce timer (no leak), cancels inflight, clears state; idempotent
  describe("reset()", function()
    it("cancels a pending debounce timer mid-flight without throwing (no leak)", function()
      local fake = fake_bridge()
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      completion.refresh(buf)
      -- reset BEFORE the defer fires (mid-flight) — must stop+close the timer (no leak, no throw)
      assert.has_no.errors(function() completion.reset() end)
      wait_for(200, function() return false end) -- give the (cancelled) defer window time to prove it never fired
      assert.are.equals(0, #fake.requests, "a mid-flight reset must cancel the pending fetch")
      assert.is_nil(completion.current(), "reset must clear last_result")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("cancels an in-flight request via bridge.cancel", function()
      local fake = fake_bridge({ auto_cancel_fires = false })
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/m" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.api.nvim_win_set_cursor(win, { 1, 2 })
      completion.refresh(buf)
      wait_for(200, function() return #fake.requests >= 1 end)
      local id = fake.requests[1].id
      completion.reset()
      assert.is_true(#fake.cancels >= 1, "reset must call bridge.cancel for the in-flight request")
      assert.are.equals(id, fake.cancels[#fake.cancels])
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("is idempotent + never throws (safe when never activated)", function()
      assert.has_no.errors(function()
        completion.reset(); completion.reset(); completion.reset()
      end)
    end)
  end)

  -- (11) never-throws on bad args (non-number buf, nil, wiped buf)
  describe("never-throws on bad args", function()
    it("refresh(nil) / refresh('x') never throw", function()
      assert.has_no.errors(function()
        completion.refresh(nil)
        completion.refresh("x")
        completion.refresh({})
      end)
    end)

    it("refresh on a wiped buf never throws (bails in do_refresh)", function()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_delete(buf, { force = true })
      pi.bridge = fake_bridge()
      assert.has_no.errors(function()
        completion.refresh(buf)
        wait_for(100, function() return false end)
      end)
    end)
  end)

  -- =====================================================================
  -- S32: accept(item) + on_enter(buf) — the PRD §7.4 accept flow.
  -- Drives the REAL menu via menu.attach() + completion.refresh() + a
  -- getSuggestions reply (don't hand-set menu state — test the real seam).
  -- =====================================================================
  describe("accept/on_enter", function()
    -- populated_menu is shared at the top-level describe scope (used by on_tab too).

    -- (1) accept issues applyCompletion with the EXACT params shape
    it("accept issues applyCompletion with {lines, cursorLine, cursorCol, item, prefix} (no force)", function()
      local fake, buf = populated_menu("/mo", 3, { { value = "/model", label = "model" } }, "/mo")
      assert.is_true(menu.is_open())
      assert.are.equals("/model", menu.get_selected().value)
      local n0 = #fake.requests
      local ok = completion.accept(menu.get_selected())
      assert.is_true(ok, "accept returns true (RPC issued)")
      wait_for(200, function() return #fake.requests > n0 end)
      local req = fake.requests[#fake.requests]
      assert.are.equals("applyCompletion", req.method)
      assert.are.same({ "/mo" }, req.params.lines)
      assert.are.equals(0, req.params.cursorLine) -- row 1 - 1
      assert.are.equals(3, req.params.cursorCol)  -- "/mo" ASCII byte 3 == utf16 3
      assert.are.same({ value = "/model", label = "model" }, req.params.item)
      assert.are.equals("/mo", req.params.prefix)
      assert.is_nil(req.params.force)             -- NO force on apply
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (2) cb success applies pi's result EXACTLY (buffer + cursor + menu closed)
    it("cb success replaces the buffer wholesale, sets the cursor (NO -1), closes the menu", function()
      local fake, buf, win = populated_menu("/mo", 3, { { value = "/model", label = "model" } }, "/mo")
      local ok = completion.accept(menu.get_selected())
      assert.is_true(ok)
      fake.resolve_last(nil, { lines = { "/model " }, cursorLine = 0, cursorCol = 7 })
      wait_for(200, function() return not menu.is_open() end)
      assert.are.same({ "/model " }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.are.same({ 1, 7 }, vim.api.nvim_win_get_cursor(win)) -- 0-based byte col 7 (NO -1)
      assert.is_false(menu.is_open())
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (2b) MULTIBYTE cursor is byte-correct (NO -1; utf16→byte conversion)
    it("positions the cursor at the exact BYTE offset on a multibyte result (proves NO -1)", function()
      -- "/café": é is 2 bytes (UTF-8). #line = 6 bytes; utf16 = 5 (é = 1 utf16 unit).
      -- cursor at EOL = byte 6 (utf16 5).
      local fake, buf, win = populated_menu("/café", 6, { { value = "/café", label = "café" } }, "/café")
      local ok = completion.accept(menu.get_selected())
      assert.is_true(ok)
      -- pi replies with cursorCol = 6 (utf16 units: / c a f é = ... actually 5+? use a clearer case)
      -- Use a result line where the cursor lands after a multibyte char: "/cafér" → byte 7, utf16 6.
      fake.resolve_last(nil, { lines = { "/cafér" }, cursorLine = 0, cursorCol = 6 }) -- utf16 6
      wait_for(200, function() return not menu.is_open() end)
      -- "/cafér" = / c a f é r = 1+1+1+1+2+1 = 7 bytes; cursor after r (utf16 6) = byte 7 (0-based)
      assert.are.same({ "/cafér" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.are.same({ 1, 7 }, vim.api.nvim_win_get_cursor(win), "cursor must be byte 7, NOT 6 (NO -1)")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (3) cb error → degrade (buffer untouched + menu closed + never throws)
    describe("cb error → degrade (buffer untouched, menu closed)", function()
      local function case(err_value)
        local fake, buf = populated_menu("/mo", 3, { { value = "/model", label = "model" } }, "/mo")
        local ok = completion.accept(menu.get_selected())
        assert.is_true(ok)
        fake.resolve_last(err_value, nil)
        wait_for(200, function() return not menu.is_open() end)
        assert.are.same({ "/mo" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), "buffer must be UNTOUCHED on " .. tostring(err_value))
        assert.is_false(menu.is_open())
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      it("rpc error leaves the buffer untouched + menu closed", function() case("rpc error -32603") end)
      it("timeout leaves the buffer untouched + menu closed", function() case("request timeout") end)
    end)

    -- (4) on_enter gate: true iff buf valid+current AND menu open+table-selected
    describe("on_enter gate", function()
      it("returns true + issues accept when the menu is open with a selected item", function()
        local fake, buf = populated_menu("/mo", 3, { { value = "/model", label = "model" } }, "/mo")
        local n0 = #fake.requests
        local handled = completion.on_enter(buf)
        assert.is_true(handled, "on_enter returns true when accepting")
        wait_for(200, function() return #fake.requests > n0 end)
        assert.are.equals("applyCompletion", fake.requests[#fake.requests].method)
        vim.api.nvim_buf_delete(buf, { force = true })
      end)

      it("returns false when the menu is closed (CR falls through to a newline)", function()
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mo" })
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
        menu.attach()
        pi.bridge = fake_bridge() -- connected but no refresh → menu closed
        assert.is_false(menu.is_open())
        local handled = completion.on_enter(buf)
        assert.is_false(handled)
        vim.api.nvim_buf_delete(buf, { force = true })
      end)

      it("returns false when buf is not the current buffer", function()
        local _, buf = populated_menu("/mo", 3, { { value = "/model", label = "model" } }, "/mo")
        -- switch the window to a 2nd buffer so `buf` is no longer current
        local other = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), other)
        local handled = completion.on_enter(buf)
        assert.is_false(handled, "on_enter returns false when buf != current")
        vim.api.nvim_buf_delete(buf, { force = true })
        vim.api.nvim_buf_delete(other, { force = true })
      end)
    end)

    -- (5) never-throws on bad args
    describe("accept/on_enter never-throws on bad args", function()
      it("accept(nil) / accept on a wiped buf / on_enter(nil) never throw", function()
        assert.has_no.errors(function()
          completion.accept(nil)
          completion.accept("x")
        end)
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_delete(buf, { force = true })
        assert.has_no.errors(function()
          completion.accept({ value = "x", label = "x" }) -- item ok but no bridge → false, no throw
          completion.on_enter(nil)
          completion.on_enter(buf) -- wiped buf → false, no throw
        end)
        assert.is_false(completion.accept({ value = "x", label = "x" })) -- pi.bridge == nil
      end)
    end)
  end)

  -- =====================================================================
  -- S33: on_tab(buf) — pi's handleTabCompletion replication.
  -- Reuses the S32 populated_menu helper (menu-open BRANCH 1) + adds a
  -- closed_menu helper (menu-closed BRANCH 2a/2b). Drives menu state via the
  -- REAL seam (fake_bridge + menu.attach + refresh); uses the same reset()
  -- before/after_each.
  -- =====================================================================
  describe("on_tab", function()
    --- A CLOSED-menu setup: a buf + cursor with NO refresh (or an empty-items
    --- reply) so menu.is_open()==false. Returns (fake, buf, win). The caller
    --- deletes buf. Attaches menu so completion.on_results is wired (for the
    --- multi-item routing cases). When `lines` is a multi-line table the cursor
    --- is placed on its LAST row; otherwise the single line is used.
    local function closed_menu(line, byte_col, lines_opt)
      local fake = fake_bridge()
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      local src = lines_opt or { line }
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, src)
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].virtualedit = "onemore" -- allow cursor at EOL
      vim.api.nvim_win_set_cursor(win, { #src, byte_col }) -- last row (1-indexed)
      menu.attach()
      assert.is_false(menu.is_open(), "closed_menu must start with the menu closed")
      return fake, buf, win
    end

    -- (1) BRANCH 1 — menu open + Tab → accept (delegates to the S32 core)
    it("BRANCH 1: menu open + selected → accept (applyCompletion) + returns true", function()
      local fake, buf = populated_menu("/mod", 3, { { value = "/model", label = "model" } }, "/mo")
      local n0 = #fake.requests
      local ok = completion.on_tab(buf)
      assert.is_true(ok, "on_tab returns true (Tab consumed)")
      wait_for(200, function() return #fake.requests > n0 end)
      local req = fake.requests[#fake.requests]
      assert.are.equals("applyCompletion", req.method)
      assert.are.equals("/model", req.params.item.value)
      assert.are.equals("/mo", req.params.prefix) -- the on_results prefix (menu.get_prefix)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (2) BRANCH 2b — file-force: shouldTrigger=true → force:true getSuggestions
    it("BRANCH 2b: shouldTriggerFileCompletion=true → force:true getSuggestions (menu opens)", function()
      local fake, buf = closed_menu("./src/com", 8)
      local n0 = #fake.requests
      local ok = completion.on_tab(buf)
      assert.is_true(ok, "on_tab returns true (Tab consumed; shouldTrigger issued)")
      wait_for(200, function() return #fake.requests > n0 end)
      local trigger_req = fake.requests[#fake.requests]
      assert.are.equals("shouldTriggerFileCompletion", trigger_req.method)
      assert.are.same({ "./src/com" }, trigger_req.params.lines)
      assert.are.equals(0, trigger_req.params.cursorLine)
      assert.are.equals(8, trigger_req.params.cursorCol)
      -- resolve shouldTrigger=true → the NEXT req must be getSuggestions force=true
      fake.resolve_last(nil, true)
      wait_for(200, function() return #fake.requests > n0 + 1 end)
      local gs_req = fake.requests[#fake.requests]
      assert.are.equals("getSuggestions", gs_req.method)
      assert.is_true(gs_req.params.force, "getSuggestions force must be true (file-force)")
      -- resolve with >1 items → menu OPENS (shown, not auto-applied)
      local items = { { value = "./src/a", label = "a" }, { value = "./src/b", label = "b" } }
      fake.resolve_last(nil, { items = items, prefix = "./" })
      wait_for(200, function() return menu.is_open() end)
      assert.is_true(menu.is_open(), "multi-item result must open the menu (not auto-apply)")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (3) BRANCH 2b — shouldTrigger=false → NO getSuggestions (pi:2150 abort)
    it("BRANCH 2b: shouldTriggerFileCompletion=false → NO getSuggestions (Tab still consumed)", function()
      local fake, buf = closed_menu("./src/com", 8)
      local n0 = #fake.requests
      local ok = completion.on_tab(buf)
      assert.is_true(ok, "on_tab returns true (Tab consumed; shouldTrigger issued)")
      wait_for(200, function() return #fake.requests > n0 end)
      assert.are.equals("shouldTriggerFileCompletion", fake.requests[#fake.requests].method)
      fake.resolve_last(nil, false) -- guard false → abort
      wait_for(150, function() return false end) -- let the scheduled cb settle
      assert.are.equals(n0 + 1, #fake.requests, "NO getSuggestions must be issued when shouldTrigger=false")
      assert.is_false(menu.is_open())
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (4) SINGLE-ITEM AUTO-APPLY — force:true + 1 item → applyCompletion with the RESULT prefix
    it("SINGLE-ITEM AUTO-APPLY: force:true + 1 item → applyCompletion(result prefix) + menu CLOSED", function()
      local fake, buf = closed_menu("./x", 3)
      local n0 = #fake.requests
      completion.on_tab(buf)
      wait_for(200, function() return #fake.requests > n0 end)
      fake.resolve_last(nil, true) -- shouldTrigger=true
      wait_for(200, function() return #fake.requests > n0 + 1 end)
      local gs_req = fake.requests[#fake.requests]
      assert.are.equals("getSuggestions", gs_req.method)
      assert.is_true(gs_req.params.force)
      -- resolve with EXACTLY 1 item → auto-apply (applyCompletion with the result prefix)
      fake.resolve_last(nil, { items = { { value = "./x.rs", label = "x.rs" } }, prefix = "./" })
      wait_for(200, function() return #fake.requests > n0 + 2 end)
      local apply_req = fake.requests[#fake.requests]
      assert.are.equals("applyCompletion", apply_req.method)
      assert.are.equals("./x.rs", apply_req.params.item.value)
      assert.are.equals("./", apply_req.params.prefix, "prefix must be the getSuggestions RESULT prefix (NOT menu.get_prefix)")
      assert.is_false(menu.is_open(), "single-item auto-apply must NOT open the menu")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (5) BRANCH 2a — slash ctx (cursorLine 0, bare /cmd) → force:FALSE (no shouldTrigger first)
    it("BRANCH 2a: bare slash command at cursorLine==0 → force:FALSE getSuggestions (no shouldTrigger)", function()
      local fake, buf = closed_menu("/mod", 3)
      local n0 = #fake.requests
      local ok = completion.on_tab(buf)
      assert.is_true(ok, "on_tab returns true (Tab consumed; slash fetch issued)")
      wait_for(200, function() return #fake.requests > n0 end)
      local first = fake.requests[#fake.requests]
      assert.are.equals("getSuggestions", first.method, "slash branch must issue getSuggestions FIRST (no shouldTrigger)")
      assert.is_false(first.params.force, "slash branch force must be FALSE")
      -- resolve with 1 item → menu OPENS (slash path NEVER auto-applies even with 1 item)
      fake.resolve_last(nil, { items = { { value = "/model", label = "model" } }, prefix = "/mo" })
      wait_for(200, function() return menu.is_open() end)
      assert.is_true(menu.is_open(), "slash path must show the menu (never auto-apply)")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (6) slash gate on cursorLine!=0 — a /cmd on line 2 routes to the file-force branch
    it("BRANCH 2b (slash gate): a /cmd on line 2 → file-force (shouldTrigger), NOT slash", function()
      -- multi-line buf { '', '/mod' }; cursor on row 2 (cursorLine==1, NOT 0)
      local fake, buf = closed_menu(nil, 3, { "", "/mod" })
      local n0 = #fake.requests
      completion.on_tab(buf)
      wait_for(200, function() return #fake.requests > n0 end)
      local first = fake.requests[#fake.requests]
      assert.are.equals("shouldTriggerFileCompletion", first.method, "line-2 /cmd must route to file-force (NOT slash)")
      assert.are.equals(1, first.params.cursorLine, "cursorLine must be 1 (row 2)")
      fake.resolve_last(nil, true)
      wait_for(200, function() return #fake.requests > n0 + 1 end)
      local gs_req = fake.requests[#fake.requests]
      assert.are.equals("getSuggestions", gs_req.method)
      assert.is_true(gs_req.params.force, "line-2 /cmd must force==true (file-force)")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (7) never-throws / degrade
    describe("on_tab never-throws / degrade", function()
      it("on_tab(nil) / on_tab('x') never throw", function()
        assert.has_no.errors(function()
          completion.on_tab(nil)
          completion.on_tab("x")
        end)
      end)

      it("on_tab on a wiped buf never throws + returns false", function()
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_delete(buf, { force = true })
        pi.bridge = fake_bridge()
        local ok = completion.on_tab(buf)
        assert.is_false(ok)
      end)

      it("pi.bridge == nil → on_tab returns false (Tab → indent, no throw)", function()
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mod" })
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
        pi.bridge = nil
        local ok = completion.on_tab(buf)
        assert.is_false(ok)
        vim.api.nvim_buf_delete(buf, { force = true })
      end)

      it("bridge disconnected → on_tab returns false", function()
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mod" })
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
        pi.bridge = fake_bridge({ connected = false })
        local ok = completion.on_tab(buf)
        assert.is_false(ok)
        vim.api.nvim_buf_delete(buf, { force = true })
      end)

      it("on_tab returns false when buf is not the current buffer", function()
        local _, buf = populated_menu("/mod", 3, { { value = "/model", label = "model" } }, "/mo")
        local other = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), other)
        local ok = completion.on_tab(buf)
        assert.is_false(ok, "on_tab returns false when buf != current")
        vim.api.nvim_buf_delete(buf, { force = true })
        vim.api.nvim_buf_delete(other, { force = true })
      end)
    end)

    -- (8) supersession: a refresh after Tab supersedes the Tab fetch (shared state.gen)
    it("supersession: a refresh after on_tab supersedes the Tab fetch (shared gen-guard)", function()
      local fake, buf = closed_menu("./src/com", 8)
      local n0 = #fake.requests
      completion.on_tab(buf)
      wait_for(200, function() return #fake.requests > n0 end)
      assert.are.equals("shouldTriggerFileCompletion", fake.requests[#fake.requests].method)
      fake.resolve_last(nil, true) -- shouldTrigger=true → force_fetch issues getSuggestions
      wait_for(200, function() return #fake.requests > n0 + 1 end)
      local tab_req = fake.requests[#fake.requests]
      assert.are.equals("getSuggestions", tab_req.method)
      -- NOW a refresh fires (TextChangedI) → it bumps state.gen + cancels the Tab in-flight
      local seam = 0
      completion.on_results = function() seam = seam + 1 end
      completion.refresh(buf)
      wait_for(200, function() return #fake.requests > n0 + 2 end, 5)
      -- cancel(prev_id) was called (layer 1) for the Tab request
      assert.is_true(#fake.cancels >= 1, "refresh must cancel the in-flight Tab fetch")
      -- resolve the STALE Tab cb with items → on_results must NOT fire (gen-guard)
      vim.schedule_wrap(tab_req.cb)(nil, { items = { { value = "stale", label = "stale" } }, prefix = "./" })
      wait_for(120, function() return false end) -- let the stale cb settle (a no-op)
      assert.are.equals(0, seam, "a stale Tab response must NOT fire on_results (gen-guard)")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  -- =====================================================================
  -- S36: on_next(buf) / on_prev(buf) / on_dismiss(buf) — the navigation/dismiss
  -- keymap handlers. Each gates like on_enter (buf valid+current + menu state) and
  -- delegates to menu.next/prev/dismiss. Returns true (key CONSUMED) only when the
  -- menu is open (+has_items for next/prev); false → fall-through. Never throws.
  -- Reuses the S32 populated_menu + the S33 closed_menu helpers. (research/notes.md §4.)
  -- =====================================================================
  describe("on_next/on_prev/on_dismiss", function()
    -- (1) on_next: open menu → true + menu.next() advances selected (1→2)
    it("on_next returns true + advances menu.selected when the menu is open (1→2)", function()
      local _, buf = populated_menu("/mo", 3, {
        { value = "/model", label = "model" },
        { value = "/mood", label = "mood" },
      }, "/mo")
      assert.are.equals(1, menu._state.selected)
      local handled = completion.on_next(buf)
      assert.is_true(handled, "on_next returns true (key consumed)")
      assert.are.equals(2, menu._state.selected, "on_next advanced selected 1→2")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (2) on_prev: open menu → true + menu.prev() retreats (1→2→1 wrap)
    it("on_prev returns true + retreats menu.selected (2→1 via prev from 1 wraps to n)", function()
      local _, buf = populated_menu("/mo", 3, {
        { value = "/a", label = "a" },
        { value = "/b", label = "b" },
        { value = "/c", label = "c" },
      }, "/mo")
      assert.are.equals(1, menu._state.selected)
      -- prev from 1 wraps to 3
      assert.is_true(completion.on_prev(buf) == true)
      assert.are.equals(3, menu._state.selected, "on_prev wrap: 1→3")
      -- prev 3→2
      assert.is_true(completion.on_prev(buf) == true)
      assert.are.equals(2, menu._state.selected, "on_prev: 3→2")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (3) on_dismiss: open menu → true + menu.dismiss() closes
    it("on_dismiss returns true + closes the menu", function()
      local _, buf = populated_menu("/mo", 3, { { value = "/model", label = "model" } }, "/mo")
      assert.is_true(menu.is_open())
      local handled = completion.on_dismiss(buf)
      assert.is_true(handled, "on_dismiss returns true (key consumed)")
      assert.is_false(menu.is_open(), "on_dismiss closed the menu")
      assert.are.equals(0, menu._state.selected, "on_dismiss reset selected to 0")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (4) closed menu: all three return false (fall-through)
    it("returns false on all three when the menu is CLOSED (fall-through)", function()
      local fake = fake_bridge()
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mo" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].virtualedit = "onemore"
      vim.api.nvim_win_set_cursor(win, { 1, 3 })
      menu.attach()
      assert.is_false(menu.is_open(), "pre: menu closed")
      assert.is_false(completion.on_next(buf), "on_next false when closed")
      assert.is_false(completion.on_prev(buf), "on_prev false when closed")
      assert.is_false(completion.on_dismiss(buf), "on_dismiss false when closed")
      assert.is_false(menu.is_open(), "closed handlers must not open the menu")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (5) non-current buf → false on all three
    it("returns false when buf is not the current buffer", function()
      local _, buf = populated_menu("/mo", 3, { { value = "/a", label = "a" } }, "/mo")
      -- switch the window to a 2nd buffer so `buf` is no longer current
      local other = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), other)
      assert.is_false(completion.on_next(buf), "on_next false when buf != current")
      assert.is_false(completion.on_prev(buf), "on_prev false when buf != current")
      assert.is_false(completion.on_dismiss(buf), "on_dismiss false when buf != current")
      vim.api.nvim_buf_delete(buf, { force = true })
      vim.api.nvim_buf_delete(other, { force = true })
    end)

    -- (6) never-throws on bad args (nil/wiped buf/non-number)
    it("never throws on nil/string/wiped buf (returns false)", function()
      assert.has_no.errors(function()
        completion.on_next(nil)
        completion.on_next("x")
        completion.on_prev(nil)
        completion.on_prev("x")
        completion.on_dismiss(nil)
        completion.on_dismiss("x")
      end)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.has_no.errors(function()
        completion.on_next(buf)
        completion.on_prev(buf)
        completion.on_dismiss(buf)
      end)
      assert.is_false(completion.on_next(buf), "wiped buf → false")
      assert.is_false(completion.on_prev(buf), "wiped buf → false")
      assert.is_false(completion.on_dismiss(buf), "wiped buf → false")
    end)
  end)

  -- =====================================================================
  -- S37: on_insert_leave(buf) / on_buf_leave(buf) — the AUTOCMD-driven
  -- auto-close handlers. Each hides the menu + cancels the pending refresh so a
  -- stale do_refresh cannot re-open the menu in normal mode (THE race fix —
  -- research/notes.md §1). Fire-and-forget (NO bool return). Never throws.
  -- Reuses the S32 populated_menu helper. (research/notes.md §6.)
  -- =====================================================================
  describe("S37: on_insert_leave / on_buf_leave", function()
    -- (a) populated menu → on_insert_leave(buf) → menu closed + last_result cleared
    it("on_insert_leave hides the menu + clears last_result (reset)", function()
      local _, buf = populated_menu("/mo", 3, { { value = "/model", label = "model" } }, "/mo")
      assert.is_true(menu.is_open())
      assert.is_not_nil(completion.current())
      completion.on_insert_leave(buf)
      assert.is_false(menu.is_open(), "on_insert_leave must close the menu")
      assert.is_nil(completion.current(), "on_insert_leave must clear last_result (reset)")
      assert.is_nil(menu._state.win, "on_insert_leave must nil the window handle")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (b) populated menu → on_buf_leave(buf) → same teardown
    it("on_buf_leave hides the menu + clears last_result (same teardown)", function()
      local _, buf = populated_menu("/mo", 3, { { value = "/model", label = "model" } }, "/mo")
      assert.is_true(menu.is_open())
      completion.on_buf_leave(buf)
      assert.is_false(menu.is_open(), "on_buf_leave must close the menu")
      assert.is_nil(completion.current(), "on_buf_leave must clear last_result")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (c) THE RACE FIX: refresh-then-immediately-leave does NOT re-open + no new RPC
    it("RACE FIX: refresh then on_insert_leave cancels the stale do_refresh (no re-open, no new RPC)", function()
      local fake, buf = populated_menu("/mo", 3, { { value = "/model", label = "model" } }, "/mo")
      assert.is_true(menu.is_open())
      local reqs_before = #fake.requests
      -- shrink the debounce so the would-be stale defer window is provably elapsed in the wait
      if pi.config then pi.config.debounce_ms = 10 end
      completion.refresh(buf)               -- schedules a NEW debounce (do_refresh NOT yet issued)
      completion.on_insert_leave(buf)       -- InsertLeave: hide + cancel the pending debounce
      wait_for(120, function() return false end) -- let the would-be 10ms defer elapse
      assert.is_false(menu.is_open(), "a stale do_refresh must NOT re-open the menu in normal mode")
      assert.are.equals(reqs_before, #fake.requests, "no new getSuggestions issued (debounce cancelled)")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (d) inflight supersession: a stale cb resolved AFTER on_insert_leave is dropped (gen-guard)
    it("INFLIGHT SUPERSESSION: a stale cb resolved after on_insert_leave does NOT re-open (gen-guard)", function()
      local fake = fake_bridge({ auto_cancel_fires = false }) -- drive cbs manually
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mo" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].virtualedit = "onemore"
      vim.api.nvim_win_set_cursor(win, { 1, 3 })
      menu.attach()
      completion.refresh(buf)
      wait_for(200, function() return #fake.requests >= 1 end)
      -- a pending in-flight req is now stored; on_insert_leave resets state.gen=0 (drops it)
      completion.on_insert_leave(buf)
      assert.is_false(menu.is_open())
      -- NOW resolve the stale (old-gen) cb with items → on_results must NOT fire (gen-guard)
      vim.schedule_wrap(fake.requests[1].cb)(nil, { items = { { value = "/model", label = "model" } }, prefix = "/mo" })
      wait_for(120, function() return false end) -- let the scheduled stale cb settle (a no-op)
      assert.is_false(menu.is_open(), "a stale in-flight cb must NOT re-open the menu (gen-guard)")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (e) closed menu / nothing pending → harmless no-op (no throw)
    it("closed-menu / nothing-pending → on_insert_leave / on_buf_leave are harmless no-ops", function()
      local fake = fake_bridge()
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mo" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      menu.attach()
      assert.is_false(menu.is_open())
      assert.has_no.errors(function()
        completion.on_insert_leave(buf)
        completion.on_buf_leave(buf)
      end)
      assert.is_false(menu.is_open(), "no-op handlers must not open the menu")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (f) never-throws on nil / string / wiped buf
    it("never throws on nil / string / wiped buf", function()
      assert.has_no.errors(function()
        completion.on_insert_leave(nil)
        completion.on_insert_leave("x")
        completion.on_buf_leave(nil)
        completion.on_buf_leave("x")
      end)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.has_no.errors(function()
        completion.on_insert_leave(buf)
        completion.on_buf_leave(buf)
      end)
    end)

    -- (g) does NOT detach the menu: re-entry re-populates with NO re-attach
    it("does NOT detach the menu: re-entry re-populates without re-attach", function()
      local fake = fake_bridge()
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mo" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].virtualedit = "onemore"
      vim.api.nvim_win_set_cursor(win, { 1, 3 })
      menu.attach()
      local seam = completion.on_results          -- the seam menu.attach wired
      completion.refresh(buf)
      wait_for(200, function() return #fake.requests >= 1 end)
      fake.resolve_last(nil, { items = { { value = "/model", label = "model" } }, prefix = "/mo" })
      wait_for(200, function() return menu.is_open() end)
      completion.on_insert_leave(buf)              -- hide + reset (does NOT detach)
      assert.is_false(menu.is_open())
      assert.are.equals(seam, completion.on_results, "the on_results seam must stay wired (NOT detached)")
      -- re-entry WITHOUT menu.attach()
      completion.refresh(buf)
      wait_for(200, function() return #fake.requests >= 2 end)
      fake.resolve_last(nil, { items = { { value = "/model", label = "model" } }, prefix = "/mo" })
      wait_for(200, function() return menu.is_open() end)
      assert.is_true(menu.is_open(), "re-entry re-populates the menu with NO re-attach")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  -- =====================================================================
  -- S37: CursorMoved-out-of-prefix closes via the EXISTING refresh path (§3).
  -- PROOF the third trigger is OWNED by S30's refresh (no local prefix detector).
  -- =====================================================================
  describe("S37: CursorMoved-out-of-prefix closes via refresh", function()
    it("populated menu → cursor to a non-completable line → refresh → empty → menu.close()", function()
      local fake = fake_bridge()
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mo", "" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].virtualedit = "onemore"
      vim.api.nvim_win_set_cursor(win, { 1, 3 })
      menu.attach()
      completion.refresh(buf)
      wait_for(200, function() return #fake.requests >= 1 end)
      fake.resolve_last(nil, { items = { { value = "/model", label = "model" } }, prefix = "/mo" })
      wait_for(200, function() return menu.is_open() end)
      assert.is_true(menu.is_open())
      -- move cursor OUT of the prefix (to the blank line 2)
      vim.api.nvim_win_set_cursor(win, { 2, 0 })
      completion.refresh(buf)                       -- CursorMovedI -> refresh
      wait_for(200, function() return #fake.requests >= 2 end)
      fake.resolve_last(nil, { items = {}, prefix = "" }) -- pi returns empty (not completable)
      wait_for(200, function() return not menu.is_open() end)
      assert.is_false(menu.is_open(), "CursorMoved-out -> refresh -> empty -> menu.close() (the S30 path)")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  -- =====================================================================
  -- S40: TRIGGER-AWARE DEBOUNCE — mirrors pi's TUI `getAutocompleteDebounceMs`
  -- (editor.ts:2214): slash/typing fire IMMEDIATELY (0 ms), @/#/attachment context
  -- (incl. the @"..." quoted-path case) debounce by `debounce_ms` (default 20). The
  -- two-layer supersession stays TRIGGER-AGNOSTIC (a fast @sr→@src still drops the
  -- stale @sr at the gen-guard). Covers: direct is_attachment_context unit cases
  -- (the §3 table), the @-window, slash-0ms-collapse, @"... detection, mid-word
  -- foo@bar NOT-detected, + a file-context stale-result supersession case.
  -- (research/notes.md §2/§3/§6.)
  -- =====================================================================
  describe("S40: trigger-aware debounce (pi getAutocompleteDebounceMs)", function()
    -- (a) DIRECT unit cases — the research/notes.md §3 table (pi-faithful).
    describe("is_attachment_context (direct unit cases)", function()
      it("@src/comp → true (attachment context)", function()
        assert.is_true(completion.is_attachment_context("@src/comp"))
      end)
      it("#tag → true (attachment context)", function()
        assert.is_true(completion.is_attachment_context("#tag"))
      end)
      it("quoted-path UNCLOSED arm -> true", function()
        assert.is_true(completion.is_attachment_context('@"my dir'))
      end)
      it("quoted-path CLOSED -> false", function()
        assert.is_false(completion.is_attachment_context('@"my dir"'))
      end)
      it("/model → false (slash = 0 ms immediate)", function()
        assert.is_false(completion.is_attachment_context("/model"))
      end)
      it("hello world → false (plain typing)", function()
        assert.is_false(completion.is_attachment_context("hello world"))
      end)
      it("foo@bar → false (mid-token @ — NOT at a whitespace boundary)", function()
        assert.is_false(completion.is_attachment_context("foo@bar"))
      end)
      it("empty string → false", function()
        assert.is_false(completion.is_attachment_context(""))
        assert.is_false(completion.is_attachment_context(nil))
      end)
      it("@日 → true (multibyte after @; proves the byte-slice path is correct)", function()
        assert.is_true(completion.is_attachment_context("@日"))
      end)
      it("quoted-path multibyte UNCLOSED -> true", function()
        assert.is_true(completion.is_attachment_context('hello @"src/日'))
      end)
      it("a leading-@ path after other text → true (@ at a whitespace boundary)", function()
        assert.is_true(completion.is_attachment_context("see @sr"))
      end)
    end)

    -- (b) refresh("/mod") fires at 0 ms (next event-loop tick); 3 rapid refreshes STILL
    --     collapse to exactly 1 request (the cancel path collapses them, NOT the
    --     duration — research §2; guards against a regression to "0ms = N requests").
    it("slash /mod refresh fires at 0 ms (no full debounce wait); 3 rapid still collapse to 1", function()
      local fake = fake_bridge({ auto_cancel_fires = false }) -- do NOT let cancel() mutate fake.requests
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mod" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.api.nvim_win_set_cursor(win, { 1, 4 })
      local n0 = #fake.requests
      -- a SINGLE slash refresh should fire on the next tick WITHOUT a long debounce wait.
      -- (slash → 0 ms; a short 60ms budget is ample for defer_fn(0) but proves no ~20ms wait.)
      completion.refresh(buf)
      wait_for(60, function() return #fake.requests >= n0 + 1 end)
      assert.are.equals(n0 + 1, #fake.requests, "slash refresh must fire at 0 ms (no debounce window)")
      -- reset state so the prior inflight doesn't get cancelled (which would mutate fake.requests)
      completion.reset()
      -- now 3 RAPID refreshes collapse to exactly 1 MORE request (cancel path, not duration)
      local n1 = #fake.requests
      completion.refresh(buf); completion.refresh(buf); completion.refresh(buf)
      wait_for(60, function() return #fake.requests >= n1 + 1 end)
      assert.are.equals(n1 + 1, #fake.requests, "3 rapid slash refreshes must STILL collapse to 1 (defer_fn(0))")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (c) refresh("@sr") debounces by debounce_ms (set 10 in this case) — a request is
    --     issued ONLY after the window. Proves @-context uses the window, not 0.
    it("@sr refresh debounces by debounce_ms (a request issues only after the window)", function()
      local fake = fake_bridge()
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "@sr" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.api.nvim_win_set_cursor(win, { 1, 3 })
      if pi.config then pi.config.debounce_ms = 10 end
      local n0 = #fake.requests
      completion.refresh(buf)
      -- inside a SHORT window (3ms < 10ms): NO request yet (the debounce is respected)
      wait_for(3, function() return false end)
      assert.are.equals(n0, #fake.requests, "@sr must NOT issue before the debounce window elapses")
      -- after the 10ms window + a tick: the request issues
      wait_for(200, function() return #fake.requests >= n0 + 1 end)
      assert.are.equals(n0 + 1, #fake.requests, "@sr must issue exactly 1 request after the window")
      assert.are.equals("getSuggestions", fake.requests[#fake.requests].method)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (d) refresh('@"my dir') is detected as attachment context (uses the window, not 0).
    it("quoted-path refresh is detected as attachment context (debounced)", function()
      local fake = fake_bridge()
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '@"my dir' })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].virtualedit = "onemore"
      vim.api.nvim_win_set_cursor(win, { 1, 8 }) -- EOL of '@"my dir'
      if pi.config then pi.config.debounce_ms = 10 end
      local n0 = #fake.requests
      completion.refresh(buf)
      wait_for(3, function() return false end) -- inside the window
      assert.are.equals(n0, #fake.requests, "quoted-path must NOT issue before the window (debounced)")
      wait_for(200, function() return #fake.requests >= n0 + 1 end)
      assert.are.equals(n0 + 1, #fake.requests, "quoted-path must issue 1 request after the window")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (e) FILE-CONTEXT SUPERSESSION: typing @sr (slow) → @src drops the stale @sr at the
    --     gen-guard (layer 2) AND bridge.cancel(prev_id) was recorded (layer 1). Only
    --     the latest (@src) result lands. Mirrors the S30 (4) two-layer test for the
    --     @-context path (proves the supersession is still trigger-agnostic). research §6.
    it("file-context supersession: a stale @sr result is dropped when @src supersedes it", function()
      local fake = fake_bridge({ auto_cancel_fires = false }) -- drive cbs manually
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "@sr" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].virtualedit = "onemore"
      vim.api.nvim_win_set_cursor(win, { 1, 3 })
      if pi.config then pi.config.debounce_ms = 10 end
      -- 1st refresh (@sr) -> request 1 (slow; do not resolve yet)
      completion.refresh(buf)
      wait_for(200, function() return #fake.requests >= 1 end)
      local id1 = fake.requests[1].id
      local stale_cb = fake.requests[1].cb
      -- user types '@src' (buffer + cursor advance) -> a 2nd refresh cancels req 1 + bumps gen
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "@src" })
      vim.api.nvim_win_set_cursor(win, { 1, 4 })
      local seam = 0
      completion.on_results = function() seam = seam + 1 end
      completion.refresh(buf)
      wait_for(200, function() return #fake.requests >= 2 end)
      -- layer 1: cancel(prev_id) was called for the @sr request
      assert.is_true(#fake.cancels >= 1, "cancel(prev_id) must be called on @-context supersede")
      assert.are.equals(id1, fake.cancels[1])
      -- layer 2: resolve the STALE (@sr) cb with a result → on_results must NOT fire
      vim.schedule_wrap(stale_cb)(nil, { items = { { value = "@sr/stale", label = "stale" } }, prefix = "@sr" })
      wait_for(100, function() return false end) -- let the scheduled stale cb settle (a no-op)
      assert.are.equals(0, seam, "a stale @sr response must NOT fire on_results (gen-guard)")
      assert.is_nil(completion.current(), "last_result must be untouched by the stale @sr response")
      -- now resolve the 2nd (@src, current-gen) cb → on_results fires + stores
      local items2 = { { value = "@src/comp.lua", label = "comp.lua" } }
      vim.schedule_wrap(fake.requests[2].cb)(nil, { items = items2, prefix = "@src" })
      wait_for(200, function() return seam >= 1 end)
      assert.are.equals(1, seam, "the latest (@src) response must fire on_results")
      assert.are.same(items2, completion.current().items)
      assert.are.equals("@src", completion.current().prefix)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  -- =====================================================================
  -- S41: on_commands_changed(buf?) — react to the `commandsChanged` server→client
  -- notification (PRD §5.4 / §13 step 13 / §11). The mechanism is DONE (S27's
  -- on_notification dispatches it; init.lua M.activate() registers the handler). THIS
  -- describe block covers the BEHAVIOR: clear the cache (last_result + menu's own
  -- items) + bump gen (drop a late stale cb) + conditionally re-query iff the menu
  -- WAS open (the "actively completing" signal) + buf valid+current. PRESERVES
  -- state.buf (contrast reset()). Reuses the populated_menu + reset helpers. Idempotent.
  -- (PRP P3.M10.T26.S41; research/notes.md §5.)
  -- =====================================================================
  describe("on_commands_changed", function()
    -- (a) surface: exposes on_commands_changed as a function
    it("exposes on_commands_changed as a function", function()
      assert.are.equals("function", type(completion.on_commands_changed))
    end)

    -- (b) clears last_result + closes the stale menu
    it("clears last_result + closes the stale menu", function()
      local _, buf = populated_menu("/mod", 3, { { value = "/model", label = "model" } }, "/mo")
      assert.is_true(menu.is_open())
      assert.is_not_nil(completion.current())
      completion.on_commands_changed(buf)
      assert.is_nil(completion.current(), "on_commands_changed must clear last_result (the cache)")
      assert.is_false(menu.is_open(), "on_commands_changed must close the stale menu")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (c) cancels the in-flight getSuggestions + bumps gen → a LATE stale cb does NOT repopulate
    it("cancels the in-flight request + bumps gen so a late stale cb is dropped", function()
      local fake = fake_bridge({ auto_cancel_fires = false }) -- drive cbs manually
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mod" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].virtualedit = "onemore"
      vim.api.nvim_win_set_cursor(win, { 1, 3 })
      menu.attach()
      completion.refresh(buf)
      wait_for(200, function() return #fake.requests >= 1 end)
      local stale_cb = fake.requests[1].cb
      local stale_id = fake.requests[1].id
      -- fire on_commands_changed → cancels inflight + bumps gen + clears cache + closes menu
      completion.on_commands_changed(buf)
      assert.is_true(#fake.cancels >= 1, "on_commands_changed must cancel the in-flight request")
      assert.are.equals(stale_id, fake.cancels[#fake.cancels])
      assert.is_nil(completion.current(), "cache cleared")
      assert.is_false(menu.is_open(), "menu closed")
      -- a LATE stale cb with OLD items must NOT repopulate the cache / reopen the menu (gen-guard)
      local seam = 0
      completion.on_results = function() seam = seam + 1 end
      vim.schedule_wrap(stale_cb)(nil, { items = { { value = "/stale", label = "stale" } }, prefix = "/mo" })
      wait_for(120, function() return false end) -- let the scheduled stale cb settle (a no-op)
      assert.are.equals(0, seam, "a late stale cb must NOT fire on_results (gen-guard)")
      assert.is_nil(completion.current(), "a late stale cb must NOT repopulate the cache")
      assert.is_false(menu.is_open(), "a late stale cb must NOT reopen the menu")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (d) RE-QUERIES when was_open: a fresh getSuggestions is issued; on success the menu reopens with NEW items
    it("re-queries (fresh getSuggestions) when the menu WAS open + buf current", function()
      local fake, buf = populated_menu("/mod", 3, { { value = "/model", label = "model" } }, "/mo")
      assert.is_true(menu.is_open())
      local n0 = #fake.requests
      completion.on_commands_changed(buf)
      -- a FRESH getSuggestions was issued (the re-query against the rebuilt provider)
      wait_for(200, function() return #fake.requests > n0 end)
      assert.are.equals(n0 + 1, #fake.requests, "on_commands_changed must issue a fresh getSuggestions when was_open")
      assert.are.equals("getSuggestions", fake.requests[#fake.requests].method)
      -- the cache was cleared first (the re-query has not yet resolved)
      assert.is_nil(completion.current())
      -- resolve the fresh request with NEW items → the menu reopens with them
      local new_items = { { value = "/model-new", label = "model-new" } }
      fake.resolve_last(nil, { items = new_items, prefix = "/mo" })
      wait_for(200, function() return menu.is_open() end)
      assert.is_true(menu.is_open(), "the menu must reopen with the fresh items")
      assert.are.same(new_items, completion.current().items, "the cache holds the NEW items")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (e) does NOT re-query when the menu was CLOSED (no spurious pop)
    it("does NOT re-query when the menu was CLOSED (no fresh request)", function()
      local fake = fake_bridge()
      pi.bridge = fake
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mod" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].virtualedit = "onemore"
      vim.api.nvim_win_set_cursor(win, { 1, 3 })
      menu.attach()
      -- refresh + resolve with EMPTY items so the menu is closed but last_result was set
      completion.refresh(buf)
      wait_for(200, function() return #fake.requests >= 1 end)
      fake.resolve_last(nil, { items = {}, prefix = "" })
      wait_for(200, function() return completion.current() ~= nil end)
      assert.is_false(menu.is_open(), "pre: menu closed (empty result)")
      assert.is_not_nil(completion.current(), "pre: last_result was set")
      local n0 = #fake.requests
      completion.on_commands_changed(buf)
      wait_for(120, function() return false end) -- let any deferred re-query fire (none)
      assert.are.equals(n0, #fake.requests, "on_commands_changed must NOT re-query when the menu was closed")
      assert.is_nil(completion.current(), "the cache was still cleared")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (f) does NOT re-query when buf isn't current (even if was_open)
    it("does NOT re-query when buf isn't the current buffer (even if was_open)", function()
      local fake, buf = populated_menu("/mod", 3, { { value = "/model", label = "model" } }, "/mo")
      assert.is_true(menu.is_open())
      -- switch the window to a 2nd buffer so `buf` is no longer current
      local other = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), other)
      local n0 = #fake.requests
      completion.on_commands_changed(buf)
      wait_for(120, function() return false end)
      assert.are.equals(n0, #fake.requests, "on_commands_changed must NOT re-query when buf != current")
      vim.api.nvim_buf_delete(buf, { force = true })
      vim.api.nvim_buf_delete(other, { force = true })
    end)

    -- (g) preserves state.buf (contrast reset() — reset() nils it)
    it("preserves state.buf (the re-query re-opens the menu; reset() would nil state.buf)", function()
      local fake, buf = populated_menu("/mod", 3, { { value = "/model", label = "model" } }, "/mo")
      assert.is_true(menu.is_open())
      local n0 = #fake.requests
      completion.on_commands_changed(buf)
      -- on_commands_changed PRESERVES state.buf: the internal re-query (M.refresh(buf))
      -- re-fetches + re-opens the menu. Contrast reset(), which nils state.buf → a
      -- subsequent refresh would have nothing targeting the pi-prompt buffer.
      wait_for(200, function() return #fake.requests > n0 end)
      assert.are.equals(n0 + 1, #fake.requests, "a fresh re-query issued (state.buf was preserved)")
      local new_items = { { value = "/model2", label = "model2" } }
      fake.resolve_last(nil, { items = new_items, prefix = "/mo" })
      wait_for(200, function() return menu.is_open() end)
      assert.is_true(menu.is_open(), "the preserved state.buf let the re-query re-open the menu")
      assert.are.same(new_items, completion.current().items)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    -- (h) never throws on bad state (nil/wiped buf, absent bridge)
    describe("never-throws on bad state", function()
      it("on_commands_changed(nil) with nil state.buf never throws", function()
        assert.has_no.errors(function() completion.on_commands_changed(nil) end)
      end)

      it("on_commands_changed() with a wiped buf never throws", function()
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_delete(buf, { force = true })
        assert.has_no.errors(function() completion.on_commands_changed(buf) end)
      end)

      it("on_commands_changed() with pi.bridge == nil never throws + still clears cache", function()
        pi.bridge = nil
        local buf = vim.api.nvim_create_buf(true, false)
        assert.has_no.errors(function() completion.on_commands_changed(buf) end)
        -- the cache clear path runs even with no bridge (cancel is guarded)
        assert.is_nil(completion.current())
        vim.api.nvim_buf_delete(buf, { force = true })
      end)
    end)

    -- (i) idempotent: call twice; no throw; cache cleared; the debounce coalesces
    -- (the 2nd call's cancel_timer cancels the 1st's pending re-query defer + sees the
    -- menu closed → no 2nd re-query; at most ONE fresh re-query ever issues).
    it("is idempotent (twice → no throw; cache cleared; at most ONE fresh re-query)", function()
      local fake, buf = populated_menu("/mod", 3, { { value = "/model", label = "model" } }, "/mo")
      assert.is_true(menu.is_open())
      local n0 = #fake.requests
      assert.has_no.errors(function()
        completion.on_commands_changed(buf)
        completion.on_commands_changed(buf)
      end)
      wait_for(200, function() return false end) -- let any deferred re-query settle
      -- the 2nd call cancels the 1st's pending defer + sees menu closed → at most ONE re-query
      assert.is_true(#fake.requests - n0 <= 1, "a double-call must issue at most ONE fresh re-query (got " .. (#fake.requests - n0) .. ")")
      assert.is_nil(completion.current(), "cache cleared")
      assert.is_false(menu.is_open(), "menu closed")
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)