-- === plugin/tests/coords_smoke.lua — standalone (plenary-FREE) smoke test ===
-- The Level-1 validation gate: instant, dependency-free feedback (no plenary).
--
-- Exercises the headline cases that justify this module's existence:
--   * astral round-trip (😀 = surrogate pair = 2 UTF‑16 units — counted natively, NOT approximated)
--   * EOL cursor (byte_idx == #line is LEGAL → maps to utf16 length)
--   * clamp (negative → 0, past-end → max)
--   * empty string (both return 0)
--   * never-throws (non-string line degrades to 0)
--   * full round-trip on a CJK line
--
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/coords_smoke.lua" +qa
--   echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
--
-- NO `:lua <<HEREDOC` in a -c/+ arg (inherited S19 GOTCHA #10 — source via :luafile).
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../plugin (the runtimepath entry)
vim.opt.runtimepath:append(plugin_root)

local coords = require("pi-editor.coords")

local fails = 0
local function check(cond, msg)
  if not cond then
    io.stderr:write("FAIL: " .. msg .. "\n")
    fails = fails + 1
  end
end

-- ── headline astral round-trip (the REASON this module exists) ─────────────
check(coords.byte_to_utf16("a😀b", 5) == 3, "astral byte_to_utf16 a😀b@5 == 3 (NOT 2)")
check(coords.utf16_to_byte("a😀b", 3) == 5, "astral utf16_to_byte a😀b@3 == 5 (round-trip)")

-- ── EOL cursor (byte_idx == #line is legal → maps to utf16 length) ─────────
check(coords.byte_to_utf16("héllo", 6) == 5, "EOL héllo@6 == 5 (utf16 len)")
check(coords.byte_to_utf16("a😀b", 6) == 4, "EOL a😀b@6 == 4 (utf16 len)")

-- ── clamp (out-of-range → nearest boundary) ────────────────────────────────
check(coords.byte_to_utf16("hi", -5) == 0, "clamp low byte_to_utf16 hi@-5 == 0")
check(coords.byte_to_utf16("hi", 99) == 2, "clamp high byte_to_utf16 hi@99 == 2")
check(coords.utf16_to_byte("hi", -5) == 0, "clamp low utf16_to_byte hi@-5 == 0")
check(coords.utf16_to_byte("hi", 99) == 2, "clamp high utf16_to_byte hi@99 == 2")

-- ── empty string (both return 0) ───────────────────────────────────────────
check(coords.byte_to_utf16("", 0) == 0, "empty byte_to_utf16@0 == 0")
check(coords.utf16_to_byte("", 0) == 0, "empty utf16_to_byte@0 == 0")

-- ── never-throws (non-string line degrades to 0) ───────────────────────────
check(pcall(coords.byte_to_utf16, nil, 0), "byte_to_utf16(nil, 0) does not throw")
check(coords.byte_to_utf16(nil, 0) == 0, "byte_to_utf16(nil, 0) == 0")
check(pcall(coords.utf16_to_byte, nil, 0), "utf16_to_byte(nil, 0) does not throw")
check(coords.utf16_to_byte(nil, 0) == 0, "utf16_to_byte(nil, 0) == 0")

-- ── full round-trip on a multibyte CJK line (日本語) ───────────────────────
do
  local L = "日本語"
  for _, b in ipairs({ 0, 3, 6, 9 }) do
    check(coords.utf16_to_byte(L, coords.byte_to_utf16(L, b)) == b, "round-trip 日本語@" .. b)
  end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- S29 wrapper smoke (nvim_to_pi_coords / pi_to_nvim_coords) — the public API.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── astral round-trip (😀 = surrogate pair = 2 UTF‑16 units; NO -1 on inverse) ─
check(coords.nvim_to_pi_coords({ "a😀b" }, 1, 5).cursorCol == 3, "wrap astral nvim→pi a😀b@5 cursorCol == 3")
check(coords.pi_to_nvim_coords({ "a😀b" }, 0, 3).col == 5, "wrap astral pi→nvim a😀b cursorCol 3 col == 5 (NO -1)")
check(coords.pi_to_nvim_coords(coords.nvim_to_pi_coords({ "a😀b" }, 1, 5).lines, coords.nvim_to_pi_coords({ "a😀b" }, 1, 5).cursorLine, coords.nvim_to_pi_coords({ "a😀b" }, 1, 5).cursorCol).col == 5, "wrap astral full round-trip col == 5")

-- ── row ±1 (the ONLY index arithmetic; column is ±0) ───────────────────────────
check(coords.nvim_to_pi_coords({ "x", "y" }, 2, 0).cursorLine == 1, "wrap nvim→pi row 2 → cursorLine 1")
check(coords.pi_to_nvim_coords({ "x", "y" }, 1, 0).row == 2, "wrap pi→nvim cursorLine 1 → row 2")

-- ── EOL cursor (maps to utf16 length) ───────────────────────────────────────────
check(coords.nvim_to_pi_coords({ "héllo" }, 1, 6).cursorCol == 5, "wrap EOL héllo@6 cursorCol == 5 (utf16 len)")

-- ── never-throws (empty lines + out-of-range row) ──────────────────────────────
check(pcall(coords.nvim_to_pi_coords, {}, 5, 9), "wrap nvim_to_pi_coords({}, 5, 9) does not throw")
check(pcall(coords.pi_to_nvim_coords, {}, 9, 9), "wrap pi_to_nvim_coords({}, 9, 9) does not throw")
check(coords.nvim_to_pi_coords({}, 5, 9).cursorCol == 0, "wrap nvim_to_pi_coords({}, 5, 9).cursorCol == 0 (missing line → \"\" → 0)")
check(coords.pi_to_nvim_coords({}, 9, 9).col == 0, "wrap pi_to_nvim_coords({}, 9, 9).col == 0 (missing line → \"\" → 0)")

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")