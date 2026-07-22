-- === plugin/tests/jsonlreader_spec.lua — plenary/busted spec (the Level-2 gate) ===
-- Covers every Success Criterion from the PRP. Mirrors the TS extension/tests/
-- jsonl-reader.test.ts case set + the Lua-specific cases (blank-skip, on_error,
-- silent-no-throw, reset, instance independence).
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/jsonlreader_spec.lua")'
local jreader = require("pi-bridge.jsonlreader")

describe("pi-bridge.jsonlreader", function()
  -- string.char for explicit byte control (GOTCHA 7 — LuaJIT supports \u{} too, but
  -- string.char is clearest for constructing split sequences / exact bytes).
  local LS = string.char(0xE2, 0x80, 0xA8) -- U+2028 LINE SEPARATOR
  local PS = string.char(0xE2, 0x80, 0xA9) -- U+2029 PARAGRAPH SEPARATOR

  -- helper: feeds is a TABLE of chunk strings (GOTCHA 12 — NOT a bare string).
  local function reader(feeds, opts)
    opts = opts or {}
    local msgs, errs = {}, {}
    local rx = jreader.new(
      function(m) msgs[#msgs + 1] = m end,
      opts.on_error and function(l, e) errs[#errs + 1] = { line = l, err = e } end or nil
    )
    for _, f in ipairs(feeds) do
      rx:feed(f)
    end
    if opts.flush then
      rx:flush()
    end
    return msgs, errs, rx
  end

  it("exposes new/feed/flush/reset", function()
    local rx = jreader.new(function() end)
    assert.are.equals("function", type(rx.feed))
    assert.are.equals("function", type(rx.flush))
    assert.are.equals("function", type(rx.reset))
  end)

  it("decodes a single complete line", function()
    local m = reader({ '{"a":1}\n' })
    assert.are.same({ { a = 1 } }, m)
  end)

  it("drains multiple records in one chunk (drain loop)", function()
    local m = reader({ '{"a":1}\n{"b":2}\n' })
    assert.are.same({ { a = 1 }, { b = 2 } }, m)
  end)

  it("buffers a partial line split across chunks", function()
    local m = reader({ '{"x":"', 'val"}\n' })
    assert.are.same({ { x = "val" } }, m)
  end)

  it("strips a trailing \\r on CRLF-delimited input", function()
    local m = reader({ '{"a":1}\r\n{"b":2}\r\n' })
    assert.are.same({ { a = 1 }, { b = 2 } }, m)
    for _, mm in ipairs(m) do
      assert.is_nil(mm["\r"])
    end
  end)

  it("flush emits a final line lacking a trailing \\n", function()
    local m = reader({ '{"final":true}' }, { flush = true })
    assert.are.same({ { final = true } }, m)
  end)

  it("flush is a no-op on an empty buffer", function()
    local m = reader({ "" }, { flush = true })
    assert.are.same({}, m)
  end)

  it("reassembles a multibyte char split across chunks (byte-safe, no StringDecoder)", function()
    -- feed1 ends mid-€ (E2 82, NO closing quote yet); feed2 supplies AC + "} + \n. The euro
    -- is split across the two feeds exactly the way the OS can split a socket chunk.
    local m = reader({ '{"e":"' .. string.char(0xE2, 0x82), string.char(0xAC) .. '"}\n' })
    assert.are.same({ { e = "€" } }, m)
  end)

  it("preserves U+2028/U+2029 inside a value (LF-only split, ONE record)", function()
    local m = reader({ '{"t":"a' .. LS .. 'b' .. PS .. 'c"}\n' })
    assert.are.equals(1, #m)
    assert.are.equals("a" .. LS .. "b" .. PS .. "c", m[1].t)
  end)

  it("emits nothing and does not throw on empty input", function()
    local m = reader({ "" })
    assert.are.same({}, m)
  end)

  it("skips blank lines (does not decode them)", function()
    local m = reader({ '\n\n{"a":1}\n\n' })
    assert.are.same({ { a = 1 } }, m)
  end)

  it("survives Lua pattern chars in values via plain LF search", function()
    local m = reader({ '{"p":"50% off (now) +tax"}\n' })
    assert.are.same({ { p = "50% off (now) +tax" } }, m)
  end)

  it("calls on_error on a malformed line and does NOT call on_message", function()
    local m, errs = reader({ '{not json}\n' }, { on_error = true })
    assert.are.same({}, m)
    assert.are.equals(1, #errs)
    assert.are.equals("{not json}", errs[1].line)
    -- Do NOT assert a specific decode-error substring: vim.json.decode's message varies by
    -- input ("Expected value but found T_END" for ""; a different token-error for "{not
    -- json}" — both LIVE-VERIFIED). Just assert it is a non-nil string.
    assert.are.equals("string", type(errs[1].err))
    assert.is_not_nil(errs[1].err)
  end)

  it("is silent (no throw) on a malformed line when on_error is omitted", function()
    assert.has_no.errors(function() reader({ '{also not json}\n' }) end)
  end)

  it("never throws out of feed/flush/reset", function()
    assert.has_no.errors(function()
      local rx = jreader.new(function() end)
      rx:feed('{"a":1}\n{bad\n{"b":2}\n')
      rx:flush()
      rx:reset()
    end)
  end)

  it("reset() clears the buffer so a later flush emits nothing", function()
    local m, _, rx = reader({ "partial-no-newline-yet" })
    rx:reset()
    rx:flush()
    assert.are.same({}, m)
  end)

  it("two reader instances are independent (no shared module state)", function()
    local m1, m2 = {}, {}
    local r1 = jreader.new(function(mm) m1[#m1 + 1] = mm end)
    local r2 = jreader.new(function(mm) m2[#m2 + 1] = mm end)
    r1:feed('{"only":"r1"}\n')
    assert.are.same({ { only = "r1" } }, m1)
    assert.are.same({}, m2) -- r2 untouched
  end)
end)