-- === tests/menu_shell_visual_cue_smoke.lua — standalone (plenary-FREE) smoke test ===
-- The Level-3 validation gate for P2.M2.T3.S5 (the shell-context visual cue, PRD §17.9).
-- Proves the `$ ` gutter end-to-end in a REAL headless nvim: drive the menu's on_results
-- seam DIRECTLY with a shell context + a slash context, and assert the rendered buffer
-- shows the gutter ONLY for shell context. NO plenary, NO fake socket server (the cue is
-- a pure rendering concern — the on_results 4th-arg seam is the integration boundary).
--
-- Run (from the repo root):
--   nvim --headless --clean -u NORC +"luafile tests/menu_shell_visual_cue_smoke.lua" +qa
--   echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
--
-- Follows the menu_smoke.lua / coords_smoke.lua `check`/`fails`/`SMOKE_PASS` footer.

-- Add the plugin root to runtimepath so `require("pi-bridge.*")` resolves (the
-- coords_smoke.lua bootstrap pattern). Works whether run from plugin/ or repo root.
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../<repo-root> (the runtimepath entry)
vim.opt.runtimepath:append(plugin_root)

local pi = require("pi-bridge")
local menu = require("pi-bridge.menu")

-- self-sufficient: setup() with the shell visual_cue explicitly "gutter" (the default).
-- (GOTCHA D from menu_smoke: setup() must run so M.config exists before render reads it.)
pi.setup({ debounce_ms = 5, shell = { visual_cue = "gutter" } })

local fails = 0
local function check(cond, msg)
  if not cond then
    io.stderr:write("FAIL: " .. msg .. "\n")
    fails = fails + 1
  end
end

-- A real cursor window so the cursor-relative popup has a context (menu_smoke.lua pattern).
local cbuf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(cbuf, 0, -1, false, { "!git ch" }) -- a `!`-prefixed shell line
local cwin = vim.api.nvim_open_win(cbuf, true, {
  relative = "editor",
  row = 1,
  col = 1,
  width = 60,
  height = 6,
  border = "none",
})
vim.wo[cwin].virtualedit = "onemore"
vim.api.nvim_win_set_cursor(cwin, { 1, 6 }) -- end of "!git ch"

local items = {
  { value = "checkout", label = "checkout" },
  { value = "cherry-pick", label = "cherry-pick" },
}

-- ══ CASE 1: shell context → every line has the `$ ` gutter ════════════════════════
menu.on_results(cbuf, items, "ch", "shell")
check(menu.is_open(), "shell on_results must open the menu")
check(menu._state.context == "shell", "state.context == 'shell' after shell on_results")
local mbuf = menu._state.menu_buf
check(type(mbuf) == "number" and vim.api.nvim_buf_is_valid(mbuf), "menu buffer valid after open")
local lines_shell = vim.api.nvim_buf_get_lines(mbuf, 0, -1, false)
check(#lines_shell == 2, "two shell items → two lines (got " .. #lines_shell .. ")")
check(
  lines_shell[1]:sub(1, 2) == "$ ",
  "shell row 1 starts with `$ ` gutter (got: " .. tostring(lines_shell[1]) .. ")"
)
check(
  lines_shell[2]:sub(1, 2) == "$ ",
  "shell row 2 starts with `$ ` gutter (got: " .. tostring(lines_shell[2]) .. ")"
)
check(lines_shell[1]:find("checkout", 3, true) ~= nil, "shell row 1 has the label after the gutter")
-- PiBridgeShellGutter decoration present
local ns = vim.api.nvim_create_namespace("pi-bridge-menu")
local marks0 = vim.api.nvim_buf_get_extmarks(mbuf, ns, { 0, 0 }, { 0, -1 }, { details = true })
local has_gutter_hl = false
for _, mk in ipairs(marks0) do
  if mk[4] and mk[4].hl_group == "PiBridgeShellGutter" then
    has_gutter_hl = true
  end
end
check(has_gutter_hl, "PiBridgeShellGutter decoration present on the shell row")

-- ══ CASE 2: slash context → NO gutter (identical to today) ════════════════════════
menu.on_results(cbuf, items, "ch", "slash")
check(menu.is_open(), "slash on_results keeps the menu open")
check(menu._state.context == "slash", "state.context == 'slash' after slash on_results")
local lines_slash = vim.api.nvim_buf_get_lines(mbuf, 0, -1, false)
check(
  lines_slash[1]:sub(1, 2) ~= "$ ",
  "slash row 1 does NOT start with `$ ` (got: " .. tostring(lines_slash[1]) .. ")"
)
check(lines_slash[1]:find("checkout", 1, true) ~= nil, "slash row 1 has the bare label (no gutter)")
-- PiBridgeShellGutter decoration cleared (the namespace is wiped + repainted per render)
local marks0b = vim.api.nvim_buf_get_extmarks(mbuf, ns, { 0, 0 }, { 0, -1 }, { details = true })
local still_gutter_hl = false
for _, mk in ipairs(marks0b) do
  if mk[4] and mk[4].hl_group == "PiBridgeShellGutter" then
    still_gutter_hl = true
  end
end
check(
  not still_gutter_hl,
  "PiBridgeShellGutter decoration cleared after switching to slash context"
)

-- ══ CASE 3: nil context (omitted 4th arg) → NO gutter (back-compatible) ══════════
menu.on_results(cbuf, items, "ch")
check(menu._state.context == nil, "omitted 4th arg → state.context == nil (back-compatible)")
local lines_nil = vim.api.nvim_buf_get_lines(mbuf, 0, -1, false)
check(lines_nil[1]:sub(1, 2) ~= "$ ", "nil-context row 1 does NOT start with `$ `")

-- ══ CASE 4: visual_cue = "off" → no gutter even for shell context ═════════════════
pi.config.shell = pi.config.shell or {}
pi.config.shell.visual_cue = "off"
menu.on_results(cbuf, items, "ch", "shell")
check(menu._state.context == "shell", "context is shell even when cue is 'off'")
local lines_off = vim.api.nvim_buf_get_lines(mbuf, 0, -1, false)
check(lines_off[1]:sub(1, 2) ~= "$ ", "visual_cue='off' → shell row 1 does NOT start with `$ `")
check(lines_off[1]:find("checkout", 1, true) ~= nil, "visual_cue='off' → bare label (no gutter)")

-- ══ CASE 5: visual_cue = "border" → FloatBorder tint + NO gutter ══════════════════
pi.config.shell.visual_cue = "border"
menu.on_results(cbuf, items, "ch", "shell")
local mwin = menu._state.win
check(
  type(mwin) == "number" and vim.api.nvim_win_is_valid(mwin),
  "menu window valid in border mode"
)
if type(mwin) == "number" then
  local wh = vim.wo[mwin].winhighlight
  check(
    type(wh) == "string" and wh:find("FloatBorder:PiBridgeShellBorder", 1, true) ~= nil,
    "border mode → winhighlight maps FloatBorder:PiBridgeShellBorder (got: "
      .. tostring(wh)
      .. ")"
  )
end
local lines_border = vim.api.nvim_buf_get_lines(mbuf, 0, -1, false)
check(lines_border[1]:sub(1, 2) ~= "$ ", "border mode → NO `$ ` gutter")
-- restore the default for any later teardown
pi.config.shell.visual_cue = "gutter"

-- ══ CASE 6: reset() clears state.context (hygiene) ═══════════════════════════════
menu.on_results(cbuf, items, "ch", "shell")
check(menu._state.context == "shell", "shell context set before reset")
menu.reset()
check(menu._state.context == nil, "reset() must clear state.context (hygiene)")

-- ══ teardown ════════════════════════════════════════════════════════════════════
pcall(function()
  menu.reset()
end)
pcall(vim.api.nvim_win_close, cwin, true)
pcall(vim.api.nvim_buf_delete, cbuf, { force = true })

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")
