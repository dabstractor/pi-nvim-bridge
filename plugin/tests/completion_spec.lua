-- === plugin/tests/completion_spec.lua — plenary/busted spec (the Level-2 gate) ===
-- Covers every Success Criterion from PRP P2.M7.T18.S30. MOCKS the bridge (sets
-- require("pi-editor").bridge = fake with controllable request/cancel/is_connected) so
-- it tests the debounce / supersession / seam logic FAST without a socket (the bridge
-- transport is already exhaustively tested by bridge_request_spec). Mirrors the
-- vim.wait(ms, predicate, interval) async style of bridge_request_spec.lua.
--
-- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
-- `pending` (the test-SKIP function). We use `got`/`results` locals.
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
local completion = require("pi-editor.completion")
local pi = require("pi-editor")

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
--- inflight), restore debounce_ms. Idempotent + never throws.
local function reset()
  pi.bridge = nil
  completion.on_results = nil
  pcall(completion.reset)
  if pi.config then pi.config.debounce_ms = DEFAULT_DEBOUNCE end
end

--- Wait helper: vim.wait until `predicate()` is true (mirrors bridge_request_spec).
local function wait_for(ms, predicate)
  return vim.wait(ms, predicate, 5)
end

describe("pi-editor.completion", function()
  before_each(reset)
  after_each(reset)

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
end)