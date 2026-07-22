-- === tests/notify_smoke.lua — standalone (plenary-FREE) smoke test ===
-- The Level-1 validation gate for the S39 notify module: instant, dependency-free
-- feedback (no plenary). Exercises once() / dedup / reset() / did_notify() / bad-args.
--
-- Run from the repo root:
--   nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/notify_smoke.lua" +qa
--   echo "exit=$?"   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed
--
-- NO `:lua <<HEREDOC` in a -c/+ arg (inherited S19 GOTCHA #10 — source via :luafile).
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../<repo-root> (the runtimepath entry)
vim.opt.runtimepath:append(plugin_root)

local notify = require("pi-bridge.notify")

local fails = 0
local function check(cond, msg)
  if not cond then
    io.stderr:write("FAIL: " .. msg .. "\n")
    fails = fails + 1
  end
end

-- (1) require loads + once is a function
check(type(notify) == "table", "require('pi-bridge.notify') returns a table")
check(type(notify.once) == "function", "once is a function")
check(type(notify.reset) == "function", "reset is a function")
check(type(notify.did_notify) == "function", "did_notify is a function")

-- (2) once() calls vim.notify exactly once; flush via a captured call list
do
  notify.reset()
  local calls = {}
  local orig = vim.notify
  vim.notify = function(msg, level, opts) calls[#calls + 1] = { msg = msg, level = level, opts = opts } end
  notify.once("bridge", vim.log.levels.WARN, "hi")
  vim.wait(50, function() return #calls > 0 end, 5)
  check(#calls == 1, "once() fires vim.notify exactly once (got " .. #calls .. ")")
  check(calls[1] and calls[1].msg == "hi", "once() message forwarded verbatim")
  check(calls[1] and calls[1].level == vim.log.levels.WARN, "once() level forwarded")
  check(calls[1] and calls[1].opts and calls[1].opts.title == "pi-bridge", "once() title=pi-bridge")
  -- (3) dedup: a 2nd call with the same category is a silent no-op
  notify.once("bridge", vim.log.levels.WARN, "again")
  vim.wait(50, function() return #calls > 1 end, 5)
  check(#calls == 1, "dedup: 2nd once() with same category is a no-op (got " .. #calls .. ")")
  vim.notify = orig
end

-- (4) reset() re-arms the dedup
do
  notify.reset()
  local calls = {}
  local orig = vim.notify
  vim.notify = function(msg, level, opts) calls[#calls + 1] = { msg = msg } end
  notify.once("bridge", vim.log.levels.WARN, "a")
  vim.wait(50, function() return #calls > 0 end, 5)
  check(#calls == 1, "pre-reset fire (got " .. #calls .. ")")
  notify.reset()
  notify.once("bridge", vim.log.levels.WARN, "b")
  vim.wait(50, function() return #calls > 1 end, 5)
  check(#calls == 2, "reset() re-arms: 2nd once() fires after reset (got " .. #calls .. ")")
  vim.notify = orig
end

-- (5) did_notify() reports the dedup state
do
  notify.reset()
  check(not notify.did_notify("bridge"), "did_notify false before any once()")
  notify.once("bridge", vim.log.levels.WARN, "x")
  check(notify.did_notify("bridge"), "did_notify true after once()")
  check(notify.did_notify(), "did_notify() defaults to category 'bridge'")
end

-- (6) never throws on bad args (nil msg, non-string msg, nil/empty/non-string category)
do
  notify.reset()
  local ok = pcall(function()
    notify.once("bridge", vim.log.levels.WARN, nil)
    notify.once("bridge", vim.log.levels.WARN, 123)
    notify.once(nil, vim.log.levels.WARN, "n")
    notify.once("", vim.log.levels.WARN, "e")
    notify.once(123, vim.log.levels.WARN, "num")
    notify.once("bridge", nil, "nolvl")
    notify.once("bridge", "notnum", "badlvl")
  end)
  check(ok, "once() never throws on bad args")
end

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")