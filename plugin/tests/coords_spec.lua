-- === plugin/tests/coords_spec.lua — plenary/busted spec (the Level-2 gate) ===
-- Covers every Success Criterion from the PRP: round-trip invariant across
-- ASCII / BMP multibyte (é, 日本語) / astral (😀) / empty; exact known values;
-- EOL-cursor (byte_idx == #line) cases; never-throws + clamp (negative /
-- past-end / empty / non-string line); 0-based both directions; surface exports.
--
-- Mirrors bridge_spec.lua (S24) + jsonlreader_spec.lua (S23): describe/it/
-- assert.are.equals. NO sockets — pure functions (no setup/teardown needed).
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/coords_spec.lua")'
local coords = require("pi-editor.coords")

describe("pi-editor.coords", function()
  -- surface: both exports are functions
  it("exposes byte_to_utf16 and utf16_to_byte as functions", function()
    assert.are.equals("function", type(coords.byte_to_utf16))
    assert.are.equals("function", type(coords.utf16_to_byte))
  end)

  -- ROUND-TRIP (the headline invariant): utf16_to_byte(L, byte_to_utf16(L, b)) == b
  -- for every char-boundary byte index b in [0, #L].
  describe("round-trip utf16_to_byte(byte_to_utf16(b)) == b", function()
    it("ASCII 'hello' (all 6 positions incl. EOL)", function()
      local L = "hello"
      for _, b in ipairs({ 0, 1, 2, 3, 4, 5 }) do
        assert.are.equals(b, coords.utf16_to_byte(L, coords.byte_to_utf16(L, b)))
      end
    end)

    it("BMP multibyte 'héllo' (é = 2 bytes = 1 utf16)", function()
      local L = "héllo"
      for _, b in ipairs({ 0, 1, 3, 4, 5, 6 }) do
        assert.are.equals(b, coords.utf16_to_byte(L, coords.byte_to_utf16(L, b)))
      end
    end)

    it("BMP CJK '日本語' (3×3-byte = 3 utf16)", function()
      local L = "日本語"
      for _, b in ipairs({ 0, 3, 6, 9 }) do
        assert.are.equals(b, coords.utf16_to_byte(L, coords.byte_to_utf16(L, b)))
      end
    end)

    it("astral 'a😀b' (😀 = surrogate pair = 2 utf16)", function()
      local L = "a😀b"
      for _, b in ipairs({ 0, 1, 5, 6 }) do
        assert.are.equals(b, coords.utf16_to_byte(L, coords.byte_to_utf16(L, b)))
      end
    end)

    it("empty '' (only position 0 → 0↔0)", function()
      local L = ""
      assert.are.equals(0, coords.utf16_to_byte(L, coords.byte_to_utf16(L, 0)))
    end)
  end)

  -- EXACT known values (LIVE-VERIFIED on nvim 0.12.4). NOTE: byte 2 in "héllo" is the
  -- SECOND byte of é (a mid-character position); it maps to utf16 2 (rounds up per
  -- GOTCHA 3). The utf16 index 2 points at the 1st 'l' (byte 3). Both values below are
  -- the genuine nvim output, not the PRP §6 table (which mislabeled byte 2 as '1st l').
  describe("exact known values", function()
    it("byte_to_utf16 returns the verified UTF‑16 offsets", function()
      assert.are.equals(2, coords.byte_to_utf16("héllo", 2))   -- mid-é -> utf16 2 (rounds up)
      assert.are.equals(2, coords.byte_to_utf16("héllo", 3))   -- 1st 'l' (byte 3) -> utf16 2
      assert.are.equals(1, coords.byte_to_utf16("a😀b", 1))    -- 😀 high-surrogate start
      assert.are.equals(3, coords.byte_to_utf16("a😀b", 5))    -- 'b' (astral headline — NOT 2)
      assert.are.equals(1, coords.byte_to_utf16("日本語", 3))  -- 本 (2nd codepoint)
    end)

    it("utf16_to_byte returns the verified byte offsets", function()
      assert.are.equals(3, coords.utf16_to_byte("héllo", 2))   -- utf16 2 -> byte 3 (1st 'l')
      assert.are.equals(1, coords.utf16_to_byte("a😀b", 1))    -- utf16 1 -> byte 1
      assert.are.equals(5, coords.utf16_to_byte("a😀b", 3))    -- astral round-trip
      assert.are.equals(3, coords.utf16_to_byte("日本語", 1))  -- utf16 1 -> byte 3 (本)
    end)
  end)

  -- EOL cursor (byte_idx == #line is LEGAL → maps to the UTF‑16 length)
  describe("EOL cursor (byte_idx == #line)", function()
    it("ASCII EOL maps to utf16 length", function()
      assert.are.equals(5, coords.byte_to_utf16("hello", 5))
    end)

    it("BMP EOL maps to utf16 length", function()
      assert.are.equals(5, coords.byte_to_utf16("héllo", 6))   -- #line=6, utf16 len=5
    end)

    it("astral EOL maps to utf16 length", function()
      assert.are.equals(4, coords.byte_to_utf16("a😀b", 6))    -- #line=6, utf16 len=4
    end)
  end)

  -- 0-based both directions (no ±1 in this layer)
  describe("0-based both directions", function()
    it("byte_to_utf16(line, 0) == 0", function()
      assert.are.equals(0, coords.byte_to_utf16("héllo", 0))
      assert.are.equals(0, coords.byte_to_utf16("a😀b", 0))
    end)

    it("utf16_to_byte(line, 0) == 0", function()
      assert.are.equals(0, coords.utf16_to_byte("héllo", 0))
      assert.are.equals(0, coords.utf16_to_byte("a😀b", 0))
    end)
  end)

  -- CLAMP (out-of-range → nearest boundary)
  describe("clamp out-of-range to nearest boundary", function()
    it("byte_to_utf16 clamps negative → 0, past-end → max", function()
      assert.are.equals(0, coords.byte_to_utf16("hi", -5))     -- clamped low
      assert.are.equals(2, coords.byte_to_utf16("hi", 99))     -- clamped high (== utf16 len)
    end)

    it("utf16_to_byte clamps negative → 0, past-end → max", function()
      assert.are.equals(0, coords.utf16_to_byte("hi", -5))
      assert.are.equals(2, coords.utf16_to_byte("hi", 99))     -- == #line
    end)
  end)

  -- EMPTY string
  describe("empty string", function()
    it("returns 0 for both directions", function()
      assert.are.equals(0, coords.byte_to_utf16("", 0))
      assert.are.equals(0, coords.utf16_to_byte("", 0))
    end)

    it("clamps a non-zero index on empty to 0", function()
      assert.are.equals(0, coords.byte_to_utf16("", 99))
      assert.are.equals(0, coords.utf16_to_byte("", 99))
    end)
  end)

  -- NEVER THROWS (a non-string line / non-number index degrades to 0)
  describe("never-throws on bad inputs", function()
    it("non-string line returns 0 without throwing", function()
      assert.has_no.errors(function()
        coords.byte_to_utf16(nil, 0)
        coords.utf16_to_byte(nil, 0)
      end)
      assert.are.equals(0, coords.byte_to_utf16(nil, 0))
      assert.are.equals(0, coords.utf16_to_byte(nil, 0))
    end)

    it("non-number index is treated as 0 without throwing", function()
      assert.has_no.errors(function()
        coords.byte_to_utf16("hi", "x")
        coords.utf16_to_byte("hi", "x")
      end)
      assert.are.equals(0, coords.byte_to_utf16("hi", "x"))
      assert.are.equals(0, coords.utf16_to_byte("hi", "x"))
    end)
  end)
end)