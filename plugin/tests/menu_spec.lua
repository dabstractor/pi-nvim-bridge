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

  -- (18) FLIPPED for S34: the full flow now CREATES a floating window (S34 implements
  --      render). A non-empty getSuggestions reply must add a NEW floating window beyond
  --      the test's pi-prompt window; an empty reply must remove it. Asserts window COUNT +
  --      validity only (GOTCHA A: never assert cfg.relative=="cursor"; border is a table).
  it("FLIPPED (S34): the full flow CREATES a floating window on a non-empty reply", function()
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
    assert.is_true(#wins_after > #wins_before, "S34 render must CREATE a floating window")
    -- the menu's window handle must be a valid float
    local mwin = menu._state.win
    assert.is_number(mwin, "state.win must be set after open")
    assert.is_true(vim.api.nvim_win_is_valid(mwin), "the menu window must be valid")

    -- the menu buffer shows the label-only line (S34 content; S35 widens to two-column)
    local mbuf = menu._state.menu_buf
    assert.is_number(mbuf, "state.menu_buf must be set")
    assert.is_true(vim.api.nvim_buf_is_valid(mbuf), "the scratch buffer must be valid")
    local lines = vim.api.nvim_buf_get_lines(mbuf, 0, -1, false)
    assert.are.equals(1, #lines, "one item ⇒ one line")
    assert.are.equals("model", lines[1]:match("^%s*(.-)%s*$"), "the line shows the label")

    -- an empty reply CLOSES the window (count returns to before)
    completion.refresh(buf)
    wait_for(200, function() return #fake.requests >= 2 end)
    fake.resolve_last(nil, { items = {}, prefix = "/zz" })
    wait_for(200, function() return not menu.is_open() end)
    local wins_closed = vim.api.nvim_list_wins()
    assert.are.equals(#wins_before, #wins_closed, "an empty reply must CLOSE the menu window")
    assert.is_nil(menu._state.win, "state.win must be nil after close")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- (19) DIRECT open(items) creates a valid floating window showing the labels
  it("open(items) directly creates a valid floating window showing the labels", function()
    menu.open({
      { value = "/model", label = "/model" },
      { value = "/mood", label = "/mood" },
    })
    assert.is_true(menu.is_open())
    local mwin = menu._state.win
    assert.is_number(mwin, "state.win set by open")
    assert.is_true(vim.api.nvim_win_is_valid(mwin), "window must be valid")
    -- width tracks the max label display width (strdisplaywidth): '/model' = 6 cells.
    -- With border='rounded' the nvim_win_get_config width == content width (border is extra).
    local cfg = vim.api.nvim_win_get_config(mwin)
    assert.are.equals(6, cfg.width, "width == max label display width ('/model'=6)")
    assert.are.equals(2, cfg.height, "height == #items")
    -- border is a TABLE in get_config even when 'rounded' was passed (GOTCHA A)
    assert.is_table(cfg.border, "border is a table in get_config (GOTCHA A)")
    -- the buffer shows the label-only lines
    local lines = vim.api.nvim_buf_get_lines(menu._state.menu_buf, 0, -1, false)
    assert.are.equals(2, #lines)
    assert.are.equals("/model", lines[1]:match("^%s*(.-)%s*$"))
    assert.are.equals("/mood", lines[2]:match("^%s*(.-)%s*$"))
  end)

  -- (20) close() closes the window (validity==false) + nils state.win
  it("close() closes the floating window + nils state.win", function()
    menu.open({ { value = "/x", label = "/x" } })
    local mwin = menu._state.win
    assert.is_true(vim.api.nvim_win_is_valid(mwin))
    menu.close()
    assert.is_false(vim.api.nvim_win_is_valid(mwin), "close() must close the window")
    assert.is_nil(menu._state.win, "close() must nil state.win")
  end)

  -- (21) a second open() REUSES the scratch buffer + repositions the window in place
  --      (no flicker, no buffer leak) — the blink.cmp lifecycle pattern.
  it("a 2nd open() reuses the scratch buffer + repositions the same window in place", function()
    menu.open({ { value = "/a", label = "/a" } }) -- label width 2
    local mwin1 = menu._state.win
    local mbuf = menu._state.menu_buf
    assert.is_true(vim.api.nvim_win_is_valid(mwin1))
    assert.is_true(vim.api.nvim_buf_is_valid(mbuf))

    -- close (window goes away, buffer survives)
    menu.close()
    assert.is_nil(menu._state.win)
    assert.is_true(vim.api.nvim_buf_is_valid(mbuf), "the scratch buffer must SURVIVE close")
    assert.are.equals(mbuf, menu._state.menu_buf, "state.menu_buf unchanged across close")

    -- reopen: same buffer handle reused; a NEW window created reusing it
    menu.open({ { value = "/abcdefgh", label = "/abcdefgh" } }) -- label width 9
    local mwin2 = menu._state.win
    assert.is_true(vim.api.nvim_win_is_valid(mwin2), "window recreated on 2nd open")
    assert.are.equals(mbuf, menu._state.menu_buf, "2nd open REUSES the scratch buffer (no leak)")
    local cfg = vim.api.nvim_win_get_config(mwin2)
    assert.are.equals(9, cfg.width, "2nd open width tracks the NEW max label (repositioned)")

    -- a THIRD open while the window stays open repositions IN PLACE (same window id)
    menu.open({ { value = "/zz", label = "/zz" } }) -- label width 3
    assert.are.equals(mwin2, menu._state.win, "3rd open repositions the SAME window in place")
    assert.is_true(vim.api.nvim_win_is_valid(mwin2))
    local cfg2 = vim.api.nvim_win_get_config(mwin2)
    assert.are.equals(3, cfg2.width, "3rd open resized in place to the new width")
  end)

  -- (22) open({}) does NOT create a window (render's hide path)
  it("open({}) does NOT create a window (render hide path)", function()
    assert.is_nil(menu._state.win, "pre: no window")
    menu.open({})
    assert.is_false(menu.is_open(), "open({}) must not open")
    assert.is_nil(menu._state.win, "open({}) must not create a window")
  end)

  -- (23) reset() closes the window + nils win AND menu_buf (teardown)
  it("reset() closes the window + nils state.win / state.menu_buf", function()
    menu.open({ { value = "/a", label = "/a" } })
    local mwin = menu._state.win
    assert.is_true(vim.api.nvim_win_is_valid(mwin))
    assert.is_not_nil(menu._state.menu_buf)
    menu.reset()
    assert.is_false(vim.api.nvim_win_is_valid(mwin), "reset must close the window")
    assert.is_nil(menu._state.win, "reset must nil state.win")
    assert.is_nil(menu._state.menu_buf, "reset must nil state.menu_buf")
  end)

  -- (24) render never throws when window creation would fail (defensive degrade)
  it("menu.open/close/reset never throw (render is pcall-safe by construction)", function()
    assert.has_no.errors(function() menu.open({ { value = "/a", label = "/a" } }) end)
    assert.has_no.errors(function() menu.open({ { value = "/bb", label = "/bb" } }) end)
    assert.has_no.errors(function() menu.close() end)
    assert.has_no.errors(function() menu.reset() end)
  end)

  -- (25) geometry: compute_geometry is exposed + matches the verified 7-case table
  --      (the pure-helper smoke — render can't test clamping headlessly: screenrow()=1)
  it("exposes _compute_geometry returning the verified case-1 (below caret) geometry", function()
    assert.are.equals("function", type(menu._compute_geometry))
    -- ui_lines=24, ui_cols=80, border='rounded' ⇒ bv=2,bh=2; caret (1,1) ⇒ below
    local g = menu._compute_geometry(1, 1, 24, 80, 40, 3, 12, "rounded")
    assert.are.same({ anchor = "NW", row = 1, col = 0, width = 40, height = 3 }, g)
  end)

  -- ══ S35: two-column content + highlight decorations ════════════════════════════
  -- A real cursor window so the cursor-relative popup has a context (the e2e pattern).
  -- Asserts the BUFFER line content (two-column) + the DECORATIONS via get_extmarks
  -- (screenattr()=0 headlessly — research/notes.md §5).
  local function with_cursor_window(fn)
    local cbuf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, { "/mo" })
    local cwin = vim.api.nvim_open_win(cbuf, true, {
      relative = "editor", row = 1, col = 1, width = 60, height = 6, border = "none",
    })
    vim.wo[cwin].virtualedit = "onemore"
    vim.api.nvim_win_set_cursor(cwin, { 1, 3 })
    local ok, err = pcall(fn)
    pcall(vim.api.nvim_win_close, cwin, true)
    pcall(vim.api.nvim_buf_delete, cbuf, { force = true })
    assert.is_true(ok, err)
  end

  --- Collect the hl_group names on a (0-based) row via nvim_buf_get_extmarks. The
  --- headless-safe decoration assertion (screenattr()=0 — assert the mechanism, not pixels).
  local function hl_groups_on_row(buf, namespace, row0)
    local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, { row0, 0 }, { row0, -1 }, { details = true })
    local groups = {}
    for _, mk in ipairs(marks) do
      if mk[4] and mk[4].hl_group then groups[mk[4].hl_group] = true end
    end
    return groups
  end

  -- (26) two-column content: open(items WITH descriptions) renders label + gap + desc
  it("S35: open(items with descriptions) renders a two-column buffer (label + gap + desc)", function()
    with_cursor_window(function()
      menu.open({
        { value = "/model", label = "/model", description = "Switch the model" },
        { value = "/mood", label = "/mood", description = "Mood" },
      })
      assert.is_true(menu.is_open())
      local mbuf = menu._state.menu_buf
      assert.is_true(vim.api.nvim_buf_is_valid(mbuf))
      local lines = vim.api.nvim_buf_get_lines(mbuf, 0, -1, false)
      assert.are.equals(2, #lines)
      -- row 1: '/model' (6) + pad to label_w(6) (0) + DESC_GAP(2) + 'Switch the model'
      assert.are.equals("/model", lines[1]:sub(1, 6), "row1 starts with the label")
      assert.are.equals("  ", lines[1]:sub(7, 8), "DESC_GAP (2 spaces) between label + desc")
      assert.is_true(lines[1]:find("Switch the model", 9, true) ~= nil,
        "row1 contains the description text (two-column)")
      -- width tracks max_label_w(6) + DESC_GAP(2) + max_desc_w(16) = 24
      local cfg = vim.api.nvim_win_get_config(menu._state.win)
      assert.are.equals(24, cfg.width, "two-column width == max_label_w + DESC_GAP + max_desc_w")
    end)
  end)

  -- (27) two-column CJK: a CJK description renders (no byte-mangling)
  it("S35: a CJK description renders cell-correctly in the two-column layout", function()
    with_cursor_window(function()
      menu.open({ { value = "日本語", label = "日本語", description = "説明" } })
      local mbuf = menu._state.menu_buf
      local lines = vim.api.nvim_buf_get_lines(mbuf, 0, -1, false)
      assert.are.equals(1, #lines)
      assert.is_true(lines[1]:find("日本語", 1, true) ~= nil, "row has the CJK label")
      assert.is_true(lines[1]:find("説明", 1, true) ~= nil, "row has the CJK description")
      -- CJK label 6 + DESC_GAP 2 + CJK desc 4 = 12 cells
      assert.are.equals(12, vim.fn.strdisplaywidth(lines[1]), "clean 12-cell rectangle")
    end)
  end)

  -- (28) highlight decorations: base Pmenu every row + PmenuSel on the selected row +
  --      Comment on description ranges. Asserts via get_extmarks (NOT screenattr).
  it("S35: applies Pmenu (base) + Comment (desc) + PmenuSel (selected) decorations", function()
    with_cursor_window(function()
      menu.open({
        { value = "/model", label = "/model", description = "Switch the model" },
        { value = "/mood", label = "/mood", description = "Mood" },
      })
      local mbuf = menu._state.menu_buf
      local ns = vim.api.nvim_create_namespace("pi-editor-menu")
      -- selected row (selected=1 => row 0): Pmenu base + PmenuSel (LAST-wins) + Comment
      local g0 = hl_groups_on_row(mbuf, ns, 0)
      assert.is_true(g0.Pmenu == true, "base Pmenu on the selected row 0")
      assert.is_true(g0.PmenuSel == true, "PmenuSel on the selected row 0 (selected=1)")
      assert.is_true(g0.Comment == true, "Comment on row 0's description range")
      -- non-selected row 1: Pmenu base + Comment (NO PmenuSel)
      local g1 = hl_groups_on_row(mbuf, ns, 1)
      assert.is_true(g1.Pmenu == true, "base Pmenu on row 1")
      assert.is_true(g1.Comment == true, "Comment on row 1's description")
      assert.is_nil(g1.PmenuSel, "row 1 is NOT selected (only row 0 is)")
    end)
  end)

  -- (29) the 1-based ↔ 0-indexed trap: open() sets selected=1 ⇒ PmenuSel at ROW 0 (not 1)
  it("S35: open() selected=1 puts PmenuSel at row 0 (NOT row 1) — the 1-based↔0-indexed trap", function()
    with_cursor_window(function()
      menu.open({
        { value = "/a", label = "/a", description = "Aaa" },
        { value = "/b", label = "/b", description = "Bbb" },
      })
      assert.are.equals(1, menu._state.selected, "selected is 1-based (1 after open)")
      local mbuf = menu._state.menu_buf
      local ns = vim.api.nvim_create_namespace("pi-editor-menu")
      local g0 = hl_groups_on_row(mbuf, ns, 0)
      local g1 = hl_groups_on_row(mbuf, ns, 1)
      assert.is_true(g0.PmenuSel == true, "row 0 (selected-1) has PmenuSel")
      assert.is_nil(g1.PmenuSel, "row 1 (selected) must NOT have PmenuSel")
    end)
  end)

  -- (30) label-only regression: open(items WITHOUT descriptions) renders label-only +
  --      base Pmenu + PmenuSel, NO Comment anywhere (S34 backward-compat)
  it("S35: label-only items render label-only lines + base/selected (NO Comment)", function()
    with_cursor_window(function()
      menu.open({ { value = "/model", label = "/model" }, { value = "/mood", label = "/mood" } })
      local mbuf = menu._state.menu_buf
      local lines = vim.api.nvim_buf_get_lines(mbuf, 0, -1, false)
      -- label-only: strip whitespace ⇒ the bare label
      assert.are.equals("/model", lines[1]:match("^%s*(.-)%s*$"))
      assert.are.equals("/mood", lines[2]:match("^%s*(.-)%s*$"))
      -- width == max_label_w only (6), NOT two-column
      local cfg = vim.api.nvim_win_get_config(menu._state.win)
      assert.are.equals(6, cfg.width, "label-only width == max_label_w (no desc column)")
      local ns = vim.api.nvim_create_namespace("pi-editor-menu")
      local g0 = hl_groups_on_row(mbuf, ns, 0)
      assert.is_true(g0.Pmenu == true, "label-only still has base Pmenu")
      assert.is_true(g0.PmenuSel == true, "label-only still has PmenuSel on row 0")
      assert.is_nil(g0.Comment, "label-only ⇒ NO Comment anywhere")
    end)
  end)

  -- (31) namespace is cleared between renders: reopen reuses the scratch buffer but the
  --      decorations are wiped + repainted (no stale PmenuSel/Comment from the prior render)
  it("S35: apply_highlights clears the namespace on each render (no stale decorations)", function()
    with_cursor_window(function()
      -- open WITH descriptions (Comment decorations applied)
      menu.open({ { value = "/a", label = "/a", description = "Aaa" } })
      local mbuf = menu._state.menu_buf
      local ns = vim.api.nvim_create_namespace("pi-editor-menu")
      local g0a = hl_groups_on_row(mbuf, ns, 0)
      assert.is_true(g0a.Comment == true, "first render has Comment")
      -- reopen WITHOUT descriptions on the SAME buffer: Comment must be GONE (cleared)
      menu.open({ { value = "/x", label = "/x" } })
      assert.are.equals(mbuf, menu._state.menu_buf, "scratch buffer reused")
      local g0b = hl_groups_on_row(mbuf, ns, 0)
      assert.is_nil(g0b.Comment, "re-render WITHOUT desc clears the stale Comment")
      assert.is_true(g0b.Pmenu == true, "base Pmenu repainted")
      assert.is_true(g0b.PmenuSel == true, "PmenuSel repainted")
    end)
  end)
end)