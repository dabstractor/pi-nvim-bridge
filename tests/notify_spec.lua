-- === tests/notify_spec.lua — plenary/busted spec (the Level-2 gate for S39) ===
-- Covers every Success Criterion of notify.lua. Stubs vim.notify locally to capture calls;
-- each case flushes the scheduled notify via vim.wait before asserting (once() vim.schedule's
-- so it is safe from luv fast context — GOTCHA A).
--
-- Run (from the repo root):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/notify_spec.lua")'
local notify = require("pi-bridge.notify")
local WARN = vim.log.levels.WARN

local calls, orig_notify

local function flush(target, timeout)
  -- wait until the scheduled notify count reaches `target` (default 1) or timeout (ms)
  local want = target or 1
  vim.wait(timeout or 100, function() return #calls >= want end, 5)
end

describe("pi-bridge.notify (S39)", function()
  before_each(function()
    notify.reset()
    calls = {}
    orig_notify = vim.notify
    vim.notify = function(msg, level, opts)
      calls[#calls + 1] = { msg = msg, level = level, opts = opts }
    end
  end)
  after_each(function() vim.notify = orig_notify end)

  -- (a) once() calls vim.notify exactly once for a category
  it("once() calls vim.notify exactly once for a category", function()
    notify.once("bridge", WARN, "x")
    flush(1)
    assert.are.equals(1, #calls)
    assert.are.equals("x", calls[1].msg)
    assert.are.equals(WARN, calls[1].level)
    assert.are.equals("pi-bridge", calls[1].opts.title)
  end)

  -- (b) dedup: a 2nd once() with the same category is a silent no-op
  it("dedup: a 2nd once() with the same category is a silent no-op", function()
    notify.once("bridge", WARN, "a")
    flush(1)
    notify.once("bridge", WARN, "b")
    vim.wait(50, function() return #calls > 1 end, 5)
    assert.are.equals(1, #calls)
    assert.are.equals("a", calls[1].msg)
  end)

  -- (c) distinct categories each notify once
  it("distinct categories each notify once", function()
    notify.once("bridge", WARN, "b")
    notify.once("menu", WARN, "m")
    vim.wait(100, function() return #calls >= 2 end, 5)
    assert.are.equals(2, #calls)
  end)

  -- (d) default category is 'bridge' (nil/empty/non-string collapse to one toast)
  it("default category is 'bridge' (nil/empty/non-string collapse)", function()
    notify.once(nil, WARN, "n")
    notify.once("", WARN, "e")
    notify.once(123, WARN, "num")
    vim.wait(50, function() return #calls > 1 end, 5)
    assert.are.equals(1, #calls, "all defaulted to 'bridge' -> one toast")
  end)

  -- (e) default level is WARN when level is nil/non-number
  it("default level is WARN when level is nil/non-number", function()
    notify.once("bridge", nil, "x")
    flush(1)
    assert.are.equals(WARN, calls[1].level)
    notify.once("bridge2", "notnum", "y") -- non-number also defaults (distinct cat so it fires)
    flush(2)
    assert.are.equals(WARN, calls[2].level)
  end)

  -- (f) context-safe: callable from a luv timer callback without throwing E5560
  it("context-safe: callable from a luv timer callback without throwing E5560", function()
    local uv = vim.uv
    local t = uv.new_timer()
    local threw
    t:start(0, 0, function()
      local ok, err = pcall(notify.once, "luvctx", WARN, "from luv")
      threw = not ok and tostring(err) or nil
      t:stop()
      t:close()
    end)
    vim.wait(100, function() return threw ~= nil or #calls > 0 end, 5)
    assert.is_nil(threw, "once() threw from luv fast context: " .. tostring(threw))
  end)

  -- (g) reset() re-arms the dedup
  it("reset() re-arms the dedup", function()
    notify.once("bridge", WARN, "a")
    flush(1)
    notify.reset()
    notify.once("bridge", WARN, "y")
    flush(2)
    assert.are.equals(2, #calls)
    assert.are.equals("y", calls[2].msg)
  end)

  -- (h) did_notify() reports the dedup state
  it("did_notify() reports the dedup state", function()
    assert.is_false(notify.did_notify("bridge"))
    notify.once("bridge", WARN, "x")
    assert.is_true(notify.did_notify("bridge"))
    assert.is_true(notify.did_notify()) -- default category
    assert.is_false(notify.did_notify("other"))
  end)

  -- (i) never throws on bad args (nil msg, non-string msg)
  it("never throws on bad args (nil / non-string msg)", function()
    assert.has_no.errors(function()
      notify.once("badbridge", WARN, nil)
      notify.once("badbridge2", WARN, 123)
    end)
  end)
end)