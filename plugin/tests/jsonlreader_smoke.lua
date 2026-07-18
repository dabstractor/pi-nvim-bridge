-- === plugin/tests/jsonlreader_smoke.lua — standalone (plenary-FREE) smoke test ===
-- The Level-1 validation gate: instant, dependency-free feedback (no plenary).
--
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/jsonlreader_smoke.lua" +qa
--   echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
--
-- Exercises every framing+decode path: single line, drain loop, buffering, CRLF,
-- flush final-line, multibyte split, U+2028/U+2029 preserved, empty input, blank-skip,
-- pattern chars, on_error on malformed, silent-no-throw, reset clears buffer.
-- NO `:lua <<HEREDOC` in a -c/+ arg (inherited S19 GOTCHA #10 — source via :luafile).
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../plugin (the runtimepath entry)
vim.opt.runtimepath:append(plugin_root)

local jreader = require("pi-editor.jsonlreader")
local fails = 0
local function check(cond, msg)
  if not cond then
    io.stderr:write("FAIL: " .. msg .. "\n")
    fails = fails + 1
  end
end

-- helper: feeds is a TABLE of chunk strings (GOTCHA 12 — NOT a bare string).
local function collect(feeds, opts)
  opts = opts or {}
  local msgs, errs = {}, {}
  local rx = jreader.new(
    function(m) msgs[#msgs + 1] = m end,
    opts.on_error and function(l, e) errs[#errs + 1] = { l, e } end or nil
  )
  for _, f in ipairs(feeds) do
    rx:feed(f)
  end
  if opts.flush then
    rx:flush()
  end
  return msgs, errs
end

-- single complete line
local m = collect({ '{"a":1}\n' })
check(#m == 1 and m[1].a == 1, "single line -> 1 message {a=1}")

-- drain loop (many records in one chunk)
m = collect({ '{"a":1}\n{"b":2}\n' })
check(#m == 2 and m[1].a == 1 and m[2].b == 2, "drain loop -> 2 messages in order")

-- buffering across feeds (partial line)
m = collect({ '{"x":"', 'val"}\n' })
check(#m == 1 and m[1].x == "val", "partial line buffered across feeds -> 1 message")

-- CRLF tolerance (trailing \r stripped)
m = collect({ '{"a":1}\r\n' })
check(#m == 1 and m[1].a == 1, "CRLF -> \\r stripped, 1 message")

-- final line via flush (no trailing \n)
m = collect({ '{"final":true}' }, { flush = true })
check(#m == 1 and m[1].final == true, "flush emits final line w/o trailing \\n")

-- multibyte split (€ = E2 82 AC): feed1 ends MID-char with NO closing quote; feed2 completes it.
m = collect({ '{"e":"' .. string.char(0xE2, 0x82), string.char(0xAC) .. '"}\n' })
check(#m == 1 and m[1].e == "€", "split multibyte reassembled -> e=€ (no U+FFFD)")

-- U+2028/U+2029 preserved (ONE record; string.char = clearest byte control, GOTCHA 7/8)
local LS, PS = string.char(0xE2, 0x80, 0xA8), string.char(0xE2, 0x80, 0xA9)
m = collect({ '{"t":"a' .. LS .. 'b' .. PS .. 'c"}\n' })
check(#m == 1 and m[1].t == "a" .. LS .. "b" .. PS .. "c", "U+2028/U+2029 preserved (LF-only split)")

-- empty input -> no messages, no throw
m = collect({ "" })
check(#m == 0, "empty feed -> no messages, no throw")

-- blank lines skipped (not decoded)
m = collect({ '\n\n{"a":1}\n\n' })
check(#m == 1 and m[1].a == 1, "blank lines skipped -> exactly 1 message")

-- plain LF search survives Lua pattern chars in values
m = collect({ '{"p":"50% off (now) +tax"}\n' })
check(#m == 1 and m[1].p == "50% off (now) +tax", "pattern chars survive plain LF search")

-- on_error called on a malformed line
local _, errs = collect({ '{not json}\n' }, { on_error = true })
check(#errs == 1, "malformed line -> on_error called once")

-- silent (no throw) on a malformed line when on_error is omitted
local ok = pcall(function() collect({ '{also not json}\n' }) end)
check(ok, "malformed line with no on_error -> silent (no throw)")

-- reset() clears the buffer so a later flush() emits nothing
do
  local msgs = {}
  local rx = jreader.new(function(mm) msgs[#msgs + 1] = mm end)
  rx:feed("partial-no-newline-yet")
  rx:reset()
  rx:flush()
  check(#msgs == 0, "reset() clears the buffer (flush emits nothing)")
end

-- instance independence: feeding one reader does not touch another
do
  local m1, m2 = {}, {}
  local r1 = jreader.new(function(mm) m1[#m1 + 1] = mm end)
  local r2 = jreader.new(function(mm) m2[#m2 + 1] = mm end)
  r1:feed('{"only":"r1"}\n')
  check(#m1 == 1 and m1[1].only == "r1" and #m2 == 0, "two readers are independent (no shared state)")
end

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")