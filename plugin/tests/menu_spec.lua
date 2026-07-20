-- === plugin/tests/menu_spec.lua — plenary/busted spec (the Level-2 gate) ===
-- Covers every Success Criterion from PRP P2.M7.T18.S31. STATE-ONLY assertions (NO
-- nvim_open_win — mirrors cmp's source_spec-vs-no-view-spec testability split: the DATA/
-- state layers are unit-tested; the window layer is S34's job). Includes a FULL-FLOW
-- case using REAL completion + a fake_bridge (the completion_spec helper) +
-- menu.attach() → refresh → resolve the cb → assert menu populated (proves the S30→S31
-- seam end-to-end without a socket).
--
-- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
-- `pending` (the test-SKIP function).
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/menu_spec.lua")'
local menu = require("pi-editor.menu")
local completion = require("pi-editor.completion")
local pi = require("pi-editor")

if pi.config == nil then pi.setup({ debounce_ms = 10 }) end -- self-sufficient (mirror smoke.lua GOTCHA D)

-- Save/restore debounce_ms across cases so a case can shrink it without leaking.
local DEFAULT_DEBOUNCE = (pi.config or pi.defaults).debounce_ms

--- A fake bridge with controllable request/cancel/is_connected. request() stores the cb
--- (returns a fresh numeric-string id); the spec fires cbs via fake.resolve(idx, err,
--- result) OR fake.resolve_last(err, result). Mirrors completion_spec.lua's helper.
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
  function self.resolve(i, err, result)
    local entry = self.requests[i]
    if not entry then return end
    vim.schedule_wrap(entry.cb)(err, result)
  end
  function self.resolve_last(err, result)
    self.resolve(#self.requests, err, result)
  end
  return self
end

--- Reset between cases: clear the fake bridge, run menu.reset() (closes + detaches +
--- clears state) + completion.reset(), restore debounce_ms. Idempotent + never throws.
local function reset()
  pi.bridge = nil
  pcall(menu.reset)
  pcall(completion.reset)
  if pi.config then pi.config.debounce_ms = DEFAULT_DEBOUNCE end
end

--- Wait helper: vim.wait until `predicate()` is true (mirrors completion_spec).
local function wait_for(ms, predicate)
  return vim.wait(ms, predicate, 5)
end

describe("pi-editor.menu", function()
  before_each(reset)
  after_each(reset)

  -- (1) surface: all public fns are functions
  it("exposes attach/detach/on_results/open/close/get_*/is_open/has_items/reset as functions", function()
    for _, name in ipairs({
      "attach", "detach", "on_results", "open", "close",
      "get_selected", "get_items", "get_prefix", "get_buf", "is_open", "has_items", "reset",
    }) do
      assert.are.equals("function", type(menu[name]), name .. " must be a function")
    end
  end)

  -- (2) attach() wires the seam idempotently (last-wins overwrite + attached-flag no-op)
  it("attach() sets completion.on_results to menu.on_results and is idempotent", function()
    assert.is_nil(completion.on_results, "pre: completion.on_results must be nil")
    menu.attach()
    assert.are.equals(menu.on_results, completion.on_results, "attach must wire the seam (function-equal)")
    assert.is_true(menu.is_open() == false, "attach must not open the menu")
    -- idempotent: a 2nd attach is a no-op (does not re-save prev_on_results)
    menu.attach()
    assert.are.equals(menu.on_results, completion.on_results, "2nd attach is a no-op")
    -- detach restores the original (nil — proving prev_on_results was saved ONCE)
    menu.detach()
    assert.is_nil(completion.on_results, "detach must restore the original nil")
    assert.is_false(menu.is_open())
  end)

  -- (3) on_results routing: NON-empty items -> open() -> populated state
  it("on_results(buf, items, prefix) with non-empty items opens + populates state", function()
    local buf = vim.api.nvim_create_buf(true, false)
    local items = { { value = "a", label = "a" }, { value = "b", label = "b" } }
    menu.on_results(buf, items, "ab")
    assert.is_true(menu.is_open(), "non-empty items must open the menu")
    assert.are.equals(buf, menu.get_buf(), "get_buf == buf")
    assert.are.equals("ab", menu.get_prefix(), "get_prefix == prefix")
    assert.are.equals(items[1], menu.get_selected(), "get_selected == items[1] (selected=1)")
    assert.are.equals("a", menu.get_selected().value)
    local got = menu.get_items()
    assert.are.equals("a", got[1].value, "get_items()[1].value == 'a'")
    assert.are.equals("b", got[2].value, "get_items()[2].value == 'b'")
    assert.are.equals(2, #got)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (4) on_results routing: empty items -> close() -> closed state
  it("on_results(buf, {}, prefix) with empty items closes the menu", function()
    local buf = vim.api.nvim_create_buf(true, false)
    -- first open, then an empty result closes
    menu.on_results(buf, { { value = "a", label = "a" } }, "a")
    assert.is_true(menu.is_open())
    menu.on_results(buf, {}, "ab")
    assert.is_false(menu.is_open(), "empty items must close the menu")
    assert.is_nil(menu.get_selected(), "get_selected is nil when closed (selected==0)")
    assert.is_false(menu.has_items(), "has_items is false after close")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (5) on_results routing: nil items (defensive) -> close
  it("on_results(buf, nil, prefix) defensively closes (treats nil items as empty)", function()
    local buf = vim.api.nvim_create_buf(true, false)
    menu.on_results(buf, { { value = "a", label = "a" } }, "a")
    assert.is_true(menu.is_open())
    assert.has_no.errors(function() menu.on_results(buf, nil, "ab") end)
    assert.is_false(menu.is_open(), "nil items must close (defensive)")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (6) on_results routing: non-table items (defensive) -> close, never throws
  it("on_results(buf, 'x', nil) never throws and closes (non-table items defensive)", function()
    local buf = vim.api.nvim_create_buf(true, false)
    menu.on_results(buf, { { value = "a", label = "a" } }, "a")
    assert.is_true(menu.is_open())
    assert.has_no.errors(function() menu.on_results(buf, "x", nil) end)
    assert.is_false(menu.is_open(), "non-table items must close (defensive)")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (7) on_results routing: wiped buf -> no throw, state.buf unchanged (validity guard bails)
  it("on_results on a wiped buf never throws and leaves state.buf unchanged", function()
    local live = vim.api.nvim_create_buf(true, false)
    menu.on_results(live, { { value = "a", label = "a" } }, "a")
    assert.are.equals(live, menu.get_buf())
    local dead = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_delete(dead, { force = true })
    assert.has_no.errors(function() menu.on_results(dead, { { value = "x", label = "x" } }, "x") end)
    assert.are.equals(live, menu.get_buf(), "a wiped-buf on_results must NOT overwrite state.buf")
    assert.is_true(menu.is_open(), "the prior open state is unchanged")
    vim.api.nvim_buf_delete(live, { force = true })
  end)

  -- (8) on_results routing: non-number buf (nil) -> no throw, bails
  it("on_results(nil, items, prefix) never throws (non-number buf guard)", function()
    assert.has_no.errors(function()
      menu.on_results(nil, { { value = "a", label = "a" } }, "a")
    end)
    assert.is_false(menu.is_open(), "a non-number buf must not open the menu")
  end)

  -- (9) open(items) S34-compat: signature items-only; selected==1; open==true
  it("open(items) sets selected=1 + open=true (items-only signature, S34-compatible)", function()
    menu.open({ { value = "x", label = "x" } })
    assert.is_true(menu.is_open())
    assert.are.equals("x", menu.get_selected().value, "selected==1 -> items[1]")
    -- close() resets selected to 0 + items to {}
    menu.close()
    assert.is_false(menu.is_open())
    assert.are.equals(0, #menu.get_items(), "close clears items")
    assert.is_nil(menu.get_selected(), "selected==0 after close")
  end)

  -- (10) open() defensive: empty array -> open stays false (no items to show)
  it("open({}) does not open the menu (defensive against an empty open() call)", function()
    menu.open({})
    assert.is_false(menu.is_open(), "open with no items must not set open=true")
    assert.is_nil(menu.get_selected())
  end)

  -- (11) get_items is a SHALLOW copy (mutating the returned table does not touch state)
  it("get_items() returns a shallow copy (caller may not mutate state.items)", function()
    menu.open({ { value = "a", label = "a" }, { value = "b", label = "b" } })
    local got = menu.get_items()
    got[1] = { value = "MUTATED", label = "MUTATED" }
    got[3] = { value = "extra" }
    local again = menu.get_items()
    assert.are.equals("a", again[1].value, "mutating the copy must NOT touch state.items")
    assert.are.equals(2, #again, "the copy's # change must NOT leak into state")
  end)

  -- (12) detach() restores a NON-nil prior on_results (saved at the FIRST attach)
  it("detach() restores a pre-existing on_results sentinel (saved at the first attach)", function()
    local sentinel = function() end
    completion.on_results = sentinel
    menu.attach()
    assert.are.equals(menu.on_results, completion.on_results, "attach overwrites the slot")
    -- a 2nd attach does NOT re-save prev_on_results (still the sentinel)
    menu.attach()
    menu.detach()
    assert.are.equals(sentinel, completion.on_results, "detach must restore the sentinel, not nil")
    completion.on_results = nil
  end)

  -- (13) reset() is idempotent + never throws; closes + detaches + clears state
  it("reset() is idempotent + never throws + clears state", function()
    local buf = vim.api.nvim_create_buf(true, false)
    menu.attach()
    menu.on_results(buf, { { value = "a", label = "a" } }, "a")
    assert.is_true(menu.is_open())
    assert.are.equals(menu.on_results, completion.on_results)
    assert.has_no.errors(function()
      menu.reset(); menu.reset(); menu.reset()
    end)
    assert.is_false(menu.is_open(), "reset must close")
    assert.is_nil(menu.get_buf(), "reset must clear buf")
    assert.are.equals("", menu.get_prefix(), "reset must clear prefix")
    assert.is_false(menu.has_items())
    assert.is_nil(completion.on_results, "reset must detach (restore on_results)")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (14) reset() never throws when never activated
  it("reset() never throws when never attached", function()
    assert.has_no.errors(function()
      menu.reset(); menu.reset()
    end)
    assert.is_false(menu.is_open())
  end)

  -- (15) detach() when never attached is a no-op (never throws)
  it("detach() when never attached never throws", function()
    assert.is_nil(completion.on_results)
    assert.has_no.errors(function() menu.detach() end)
    assert.is_nil(completion.on_results)
  end)

  -- (16) FULL FLOW: real completion + fake bridge + attach -> refresh -> resolve -> populated
  it("FULL FLOW: attach + completion.refresh + a getSuggestions reply populates the menu", function()
    local fake = fake_bridge()
    pi.bridge = fake
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "/mo" })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].virtualedit = "onemore"
    vim.api.nvim_win_set_cursor(win, { 1, 3 }) -- end of "/mo"

    menu.attach()
    assert.are.equals(menu.on_results, completion.on_results, "attach wired the seam")
    completion.refresh(buf)
    wait_for(200, function() return #fake.requests >= 1 end)
    assert.are.equals(1, #fake.requests)
    fake.resolve_last(nil, { items = { { value = "/model", label = "model" } }, prefix = "/mo" })
    wait_for(200, function() return menu.is_open() end)
    assert.is_true(menu.is_open(), "menu must open after a getSuggestions reply")
    assert.are.equals("/model", menu.get_items()[1].value)
    assert.are.equals("/model", menu.get_selected().value, "selected must be the first item")
    assert.are.equals("/mo", menu.get_prefix())
    assert.are.equals(buf, menu.get_buf())
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (17) FULL FLOW: an empty result closes the menu (the empty->close routing)
  it("FULL FLOW: an empty getSuggestions result closes the menu", function()
    local fake = fake_bridge()
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
    fake.resolve_last(nil, { items = { { value = "/model", label = "model" } }, prefix = "/mo" })
    wait_for(200, function() return menu.is_open() end)
    assert.is_true(menu.is_open())

    -- now an empty result closes it
    completion.refresh(buf)
    wait_for(200, function() return #fake.requests >= 2 end)
    fake.resolve_last(nil, { items = {}, prefix = "/zz" })
    wait_for(200, function() return not menu.is_open() end)
    assert.is_false(menu.is_open(), "an empty result must close the menu")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (18) no nvim_open_win/nvim_create_buf/nvim_buf_set_lines in the module (state only)
  --      — verified structurally by the open/close/get_* surface above (no window args).
  --      This case asserts the menu never opened a window during the full flow.
  it("does not create a floating window during the full flow (state-only — S34's job)", function()
    local wins_before = vim.api.nvim_list_wins()
    local fake = fake_bridge()
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
    fake.resolve_last(nil, { items = { { value = "/model", label = "model" } }, prefix = "/mo" })
    wait_for(200, function() return menu.is_open() end)
    local wins_after = vim.api.nvim_list_wins()
    assert.are.equals(#wins_before, #wins_after, "S31 must NOT create a floating window (S34's job)")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)