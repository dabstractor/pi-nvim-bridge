-- === plugin/tests/menu_geometry_spec.lua — plenary/busted spec (Level-2 gate) ===
-- DETERMINISTIC geometry proof for the S34 pure helpers (compute_width /
-- compute_height / compute_geometry). The 7-case verified table is from
-- plan/001_c56962b4fa17/P2M5T1S1/research/positioning-math.md (LIVE-VERIFIED
-- prototype, MENU_VERIFY_PASS 0) + research/notes.md §3.
--
-- WHY a separate pure-helper spec: vim.fn.screenrow()/screencol() return 1 in
-- --headless regardless of the real cursor (research/notes.md §4), so the
-- above/below/shift-left/width-clamp math CANNOT be exercised through render's
-- real vim.fn.* calls headlessly. The clamping logic lives in the PURE
-- compute_geometry(screen_row, screen_col, …) taking EXPLICIT inputs → fed
-- synthetic values here → fully deterministic. render's integration asserts
-- width/height/anchor/validity ONLY (never a clamped position).
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/menu_geometry_spec.lua")'
local menu = require("pi-editor.menu")
local compute_width = menu._compute_width
local compute_height = menu._compute_height
local compute_geometry = menu._compute_geometry

-- Helper: deep-compare a geometry result to an expected {anchor,row,col,width,height}.
local function expect_geo(actual, exp, label)
  assert.are.same(exp, actual, label or "geometry mismatch")
end

describe("pi-editor.menu geometry helpers", function()
  -- surface: all three pure helpers are exposed
  it("exposes _compute_width / _compute_height / _compute_geometry as functions", function()
    assert.are.equals("function", type(compute_width))
    assert.are.equals("function", type(compute_height))
    assert.are.equals("function", type(compute_geometry))
  end)

  -- ── compute_height ───────────────────────────────────────────────────────────
  describe("compute_height", function()
    it("returns 0 for empty / non-positive / invalid input", function()
      assert.are.equals(0, compute_height(0, 12))
      assert.are.equals(0, compute_height(-1, 12))
      assert.are.equals(0, compute_height(nil, 12))
      assert.are.equals(0, compute_height("x", 12))
    end)
    it("clamps to max_height when #items > max_height", function()
      assert.are.equals(12, compute_height(50, 12))
      assert.are.equals(5, compute_height(20, 5))
    end)
    it("returns #items when #items <= max_height", function()
      assert.are.equals(3, compute_height(3, 12))
      assert.are.equals(1, compute_height(1, 12))
    end)
    it("falls back to a default max_height=12 when given an invalid one", function()
      assert.are.equals(12, compute_height(50, nil))
      assert.are.equals(12, compute_height(50, 0))
      assert.are.equals(12, compute_height(50, -3))
    end)
  end)

  -- ── compute_width ────────────────────────────────────────────────────────────
  describe("compute_width", function()
    it("is the max label display width (strdisplaywidth, NOT #s)", function()
      local items = { { label = "a" }, { label = "/model" }, { label = "bb" } }
      assert.are.equals(6, compute_width(items, 80, 2), "'/model' is the widest at 6 cells")
    end)
    it("counts CJK / double-width glyphs as 2 cells each (日本語 = 6)", function()
      local items = { { label = "日本語" } }
      assert.are.equals(6, compute_width(items, 80, 2), "日本語 = 6 display cells (NOT #s=3)")
    end)
    it("returns at least 1 for empty / label-less items", function()
      assert.are.equals(1, compute_width({}, 80, 2))
      assert.are.equals(1, compute_width({ {} }, 80, 2))           -- no label field
      assert.are.equals(1, compute_width({ { label = 42 } }, 80, 2)) -- non-string label
    end)
    it("clamps to (ui_cols - border_h_overhead) when the labels are over-wide", function()
      local items = { { label = string.rep("x", 200) } }
      assert.are.equals(78, compute_width(items, 80, 2), "clamped to 80-2")
      assert.are.equals(80, compute_width(items, 80, 0), "no border ⇒ 80-0")
    end)
    it("type-guards each item (never throws on a non-table item)", function()
      assert.has_no.errors(function()
        compute_width({ "x", nil, 42, { label = "ok" } }, 80, 2)
      end)
    end)
  end)

  -- ── compute_geometry: the verified 7-case table ──────────────────────────────
  -- (ui_lines=24, ui_cols=80, border="rounded" ⇒ bv=2, bh=2)
  describe("compute_geometry verified case table (24×80, border=rounded)", function()
    local UL, UC = 24, 80
    local MH = 12
    local BORDER = "rounded"

    -- Case 1: top-left caret (1,1), room below → below (NW,1,0,40,3)
    it("case 1: caret (1,1) opens BELOW the caret", function()
      expect_geo(compute_geometry(1, 1, UL, UC, 40, 3, MH, BORDER),
        { anchor = "NW", row = 1, col = 0, width = 40, height = 3 })
    end)

    -- Case 2: bottom caret (24,1), no room below → above (SW,0,0,40,3)
    it("case 2: caret (24,1) opens ABOVE the caret (no room below)", function()
      expect_geo(compute_geometry(24, 1, UL, UC, 40, 3, MH, BORDER),
        { anchor = "SW", row = 0, col = 0, width = 40, height = 3 })
    end)

    -- Case 3: (20,1), space_below=3<5, space_above=19>=5 → above (SW,0,0,40,3)
    it("case 3: caret (20,1) opens ABOVE (below too tight, above fits)", function()
      expect_geo(compute_geometry(20, 1, UL, UC, 40, 3, MH, BORDER),
        { anchor = "SW", row = 0, col = 0, width = 40, height = 3 })
    end)

    -- Case 4: right edge (1,80), need_w=42>1 → shift left col=-41 (NW,1,-41,40,3)
    it("case 4: caret (1,80) shifts the window LEFT (negative col)", function()
      expect_geo(compute_geometry(1, 80, UL, UC, 40, 3, MH, BORDER),
        { anchor = "NW", row = 1, col = -41, width = 40, height = 3 })
    end)

    -- Case 5: over-wide w=100, shift would spill past left edge → pin left + clamp width
    it("case 5: over-wide w=100 pins left + clamps width to ui_cols-bh", function()
      expect_geo(compute_geometry(10, 1, UL, UC, 100, 3, MH, BORDER),
        { anchor = "NW", row = 1, col = 0, width = 78, height = 3 })
    end)

    -- Case 6: neither side fits full height (12 items at row 12) → clamp height to 9 below
    it("case 6: caret (12,1) with 12 items clamps height (neither side fits)", function()
      expect_geo(compute_geometry(12, 1, UL, UC, 40, 12, MH, BORDER),
        { anchor = "NW", row = 1, col = 0, width = 40, height = 9 })
    end)

    -- Case 7: border="none" (no border overhead), bottom caret → above (SW,0,0,40,3)
    it("case 7: border='none' at (24,1) opens ABOVE (no border overhead)", function()
      expect_geo(compute_geometry(24, 1, UL, UC, 40, 3, MH, "none"),
        { anchor = "SW", row = 0, col = 0, width = 40, height = 3 })
    end)
  end)

  -- ── additional compute_geometry edge cases ──────────────────────────────────
  describe("compute_geometry additional cases", function()
    it("clamps height to max_height before space math", function()
      -- 50 items at top-left: height=min(50,12)=12, space_below=22>=14 → below, h stays 12
      local g = compute_geometry(1, 1, 24, 80, 40, 50, 12, "rounded")
      assert.are.equals(12, g.height)
      assert.are.equals("NW", g.anchor)
    end)
    it("returns height=1 floor when neither side has room for even the clamped height", function()
      -- tiny screen 5×80, caret (3,1), 10 items, border=rounded (bv=2):
      -- height=min(10,12)=10; need_h=12; space_below=(5-1)-3=1; space_above=2
      -- space_below<space_above → SW,row0,h=max(1,2-2)=1
      local g = compute_geometry(3, 1, 5, 80, 20, 10, 12, "rounded")
      assert.are.equals("SW", g.anchor)
      assert.are.equals(0, g.row)
      assert.are.equals(1, g.height)
    end)
    it("border as a table (char array) is treated as a real border (+2/+2)", function()
      local g = compute_geometry(24, 1, 24, 80, 40, 3, 12, { "x" })
      assert.are.equals("SW", g.anchor)
    end)
  end)
end)