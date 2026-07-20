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
local column_metrics = menu._column_metrics
local _truncate = menu._truncate

-- Helper: deep-compare a geometry result to an expected {anchor,row,col,width,height}.
local function expect_geo(actual, exp, label)
  assert.are.same(exp, actual, label or "geometry mismatch")
end

describe("pi-editor.menu geometry helpers", function()
  -- surface: all three pure helpers are exposed (+ S35 _truncate / column_metrics)
  it("exposes _compute_width / _compute_height / _compute_geometry / _truncate / _column_metrics as functions", function()
    assert.are.equals("function", type(compute_width))
    assert.are.equals("function", type(compute_height))
    assert.are.equals("function", type(compute_geometry))
    assert.are.equals("function", type(_truncate))
    assert.are.equals("function", type(column_metrics))
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
    -- S35 two-column: items WITH descriptions => max_label_w + DESC_GAP(2) + max_desc_w
    it("is label+gap+desc when any item has a description (S35 two-column)", function()
      local items = {
        { label = "/model", description = "Switch the model" }, -- 6 + 2 + 16 = 24
        { label = "/mood", description = "Mood" },            -- 5 + 2 + 4
      }
      assert.are.equals(24, compute_width(items, 80, 2),
        "max_label_w(6) + DESC_GAP(2) + max_desc_w(16) == 24")
    end)
    it("two-column CJK label + CJK description width is cell-correct", function()
      local items = { { label = "日本語", description = "説明" } } -- 6 + 2 + 4 = 12
      assert.are.equals(12, compute_width(items, 80, 2),
        "CJK label 6 + DESC_GAP 2 + CJK desc 4 == 12 (strdisplaywidth, NOT #s)")
    end)
    it("two-column clamps to (ui_cols - border_h_overhead) when over-wide", function()
      local items = { { label = "x", description = string.rep("y", 200) } }
      assert.are.equals(78, compute_width(items, 80, 2), "clamped to 80-2")
    end)
    it("collapses to label-only when description is the empty string", function()
      -- {label="x",description=""} => any_desc=false => label-only max_label_w
      local items = { { label = "abc", description = "" }, { label = "de", description = "" } }
      assert.are.equals(3, compute_width(items, 80, 2),
        "empty descriptions => label-only (max_label_w=3)")
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

  -- ── _truncate (S35 pure helper — ellipsis truncation, CJK-correct) ────────────
  describe("_truncate", function()
    it("returns the text as-is when it already fits within max_w", function()
      assert.are.equals("abc", _truncate("abc", 5))
      assert.are.equals("abc", _truncate("abc", 3)) -- exact fit, no ellipsis
      assert.are.equals("/x", _truncate("/x", 10))
    end)
    it("truncates ASCII text with an ellipsis when it exceeds max_w", function()
      -- 'verylong' (8) to 5: budget=4 (ellipsis '…' is 1 cell), fits 'very'(4), append '…' => 'very…' (5)
      assert.are.equals("very…", _truncate("verylong", 5))
      -- to 6: budget=5, fits 'veryl'(5), append '…' => 'veryl…' (6)
      assert.are.equals("veryl…", _truncate("verylong", 6))
    end)
    it("truncates CJK text correctly (each CJK char = 2 display cells)", function()
      -- '日本語です' (5 chars = 10 cells) to 5: budget=4, fits '日本'(4), append '…' => '日本…' (5)
      local t = _truncate("日本語です", 5)
      assert.is_true(vim.fn.strdisplaywidth(t) <= 5, "CJK truncation <= max_w cells")
      assert.are.equals("…", string.sub(t, -3)) -- ends with the ellipsis (UTF-8 3 bytes)
      assert.are.equals(5, vim.fn.strdisplaywidth(t), "'日本…' = 5 display cells")
      -- 6-cell budget: budget=5, fits '日本'(4), 語 would make 6>5 break => '日本…' (5)
      local t2 = _truncate("日本語です", 6)
      assert.are.equals(5, vim.fn.strdisplaywidth(t2), "6-cell budget still yields '日本…' (5)")
    end)
    it("returns the text as-is when CJK text fits", function()
      assert.are.equals("日本語", _truncate("日本語", 6)) -- 6 cells, exact fit
      assert.are.equals("日本語", _truncate("日本語", 8)) -- fits with room
    end)
    it("returns '' when max_w <= 0", function()
      assert.are.equals("", _truncate("abc", 0))
      assert.are.equals("", _truncate("abc", -1))
      assert.are.equals("", _truncate("", 0))
    end)
    it("returns '' when the input is non-string / nil (type-guarded)", function()
      assert.are.equals("", _truncate(nil, 5))
      assert.are.equals("", _truncate(42, 5))
      assert.are.equals("", _truncate({}, 5))
    end)
    it("with 1 cell of room returns the first char alone (no ellipsis fits)", function()
      -- 'abc' to 1: budget = 1 - strdisplaywidth('…')(1?) ... the ellipsis '…' is 1 cell
      -- wide (U+2026 is a single-width char). So budget=0 => first char alone.
      local t = _truncate("abc", 1)
      assert.are.equals(1, vim.fn.strdisplaywidth(t), "1-cell room => first char only (no ellipsis)")
      assert.are.equals("a", t)
    end)
    it("never throws on a malformed input", function()
      assert.has_no.errors(function()
        _truncate(nil, -1)
        _truncate("x", nil)
        _truncate({"x"}, 5)
      end)
    end)
  end)

  -- ── column_metrics (S35 pure helper — shared by compute_width + render) ────────
  describe("column_metrics", function()
    it("returns max_label_w + max_desc_w + any_desc for mixed items", function()
      local r = column_metrics({
        { label = "/model", description = "Switch the model" }, -- label 6, desc 16
        { label = "/mood", description = "Mood" },            -- label 5, desc 4
      })
      assert.are.same({ max_label_w = 6, max_desc_w = 16, any_desc = true }, r)
    end)
    it("sets any_desc=false + max_desc_w=0 for label-only items", function()
      local r = column_metrics({ { label = "a" }, { label = "bb" } })
      assert.are.same({ max_label_w = 2, max_desc_w = 0, any_desc = false }, r)
    end)
    it("counts an empty-string description as NO description (any_desc stays false)", function()
      local r = column_metrics({ { label = "x", description = "" } })
      assert.are.equals(false, r.any_desc, "description=='' is treated as no description")
      assert.are.equals(0, r.max_desc_w)
    end)
    it("counts CJK label/desc widths by display cells (NOT #s)", function()
      local r = column_metrics({ { label = "日本語", description = "説明です" } })
      -- 日本語 = 6 cells; 説明です = 8 cells
      assert.are.equals(6, r.max_label_w, "CJK label = 6 display cells (not #s=3)")
      assert.are.equals(8, r.max_desc_w, "CJK desc = 8 display cells (not #s=4)")
      assert.is_true(r.any_desc)
    end)
    it("type-guards each item (non-table / non-string fields never throw)", function()
      local r
      assert.has_no.errors(function()
        -- (no nil hole — ipairs stops at the first nil; mix only non-tables + bad-typed tables)
        r = column_metrics({ "x", 42, { label = 7, description = 9 }, { label = "ok" } })
      end)
      assert.are.equals(2, r.max_label_w, "only the valid 'ok' label counts")
      assert.are.equals(0, r.max_desc_w)
      assert.are.equals(false, r.any_desc)
    end)
    it("returns zeros for an empty / non-table input (never throws)", function()
      assert.are.same({ max_label_w = 0, max_desc_w = 0, any_desc = false }, column_metrics({}))
      assert.are.same({ max_label_w = 0, max_desc_w = 0, any_desc = false }, column_metrics(nil))
      assert.are.same({ max_label_w = 0, max_desc_w = 0, any_desc = false }, column_metrics("x"))
    end)
  end)
end)