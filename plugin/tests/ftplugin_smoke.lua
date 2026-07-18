-- === plugin/tests/ftplugin_smoke.lua — plenary-FREE standalone smoke test ===
-- Level-1 gate: fast, dependency-free feedback on plugin/ftplugin/pi-prompt.lua.
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/ftplugin_smoke.lua" +qa ; echo exit=$?
-- Prints `SMOKE_PASS` on success; prints `FAIL: ...` lines and `cquit 1` on failure.
-- (Sourced via :luafile — NOT a :lua <<HEREDOC in a -c/+ arg; S19 GOTCHA #10 / S21 GOTCHA I.)

local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h")           -- .../plugin (rtp entry)
vim.opt.runtimepath:append(plugin_root)

-- Simulate S20's startup: create the shared "pi-editor" augroup with the VimEnter
-- autocmd BEFORE any ftplugin sources, so we can verify GOTCHA C (clear=false does
-- NOT wipe it). In a real session the auto-sourced plugin/pi-editor.lua does this.
vim.api.nvim_create_augroup("pi-editor", { clear = true })
vim.api.nvim_create_autocmd("VimEnter", { group = "pi-editor", once = true, callback = function() end })

local fails = 0
local function check(cond, msg)
  if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); fails = fails + 1 end
end

-- fresh scratch buffer as the current, then set filetype (triggers the ftplugin)
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].formatoptions = "tcqj"   -- deterministic baseline (t present)
vim.bo[buf].textwidth = 80
vim.bo[buf].filetype = "pi-prompt"   -- -> sources ftplugin/pi-prompt.lua

-- ── Options ────────────────────────────────────────────────────────────────────
check(not string.find(vim.bo[buf].formatoptions or "", "t"), "formatoptions should have no 't'")
check(vim.bo[buf].textwidth == 0, "textwidth should be 0")
check(vim.wo[0].wrap == true, "wrap should be true")
check(vim.wo[0].spell == false, "spell should be false")

-- ── Keymaps (6 insert, buffer-local, 'pi-editor:' desc) ────────────────────────
local kms = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "i")) do kms[m.lhs] = m.desc end
for _, k in ipairs({ "<Tab>", "<S-Tab>", "<C-N>", "<C-P>", "<C-E>", "<CR>" }) do
  -- NOTE: use `sub` not `find("^pi-editor:")` — `-` is a Lua pattern metachar so the
  -- anchored find silently fails. `sub(1,11) == "pi-editor: " is literal & robust.
  local d = kms[k]
  check(type(d) == "string" and d:sub(1, 11) == "pi-editor: ", "keymap " .. k .. " missing/bad desc")
end

-- ── Autocmds (buffer-scoped, in the pi-editor group) ───────────────────────────
local acs = {}
local okac, list = pcall(vim.api.nvim_get_autocmds, { buffer = buf, group = "pi-editor" })
check(okac, "get_autocmds ok")
if okac then for _, a in ipairs(list) do acs[a.event] = true end end
for _, ev in ipairs({ "InsertEnter", "TextChangedI", "CursorMovedI", "VimLeavePre", "ExitPre" }) do
  check(acs[ev] == true, "autocmd " .. ev .. " missing")
end

-- ── No-op-safe: fire TextChangedI with completion.lua ABSENT -> no throw ────────
local okfire = pcall(vim.api.nvim_exec_autocmds, "TextChangedI", { buffer = buf })
check(okfire, "TextChangedI should not throw with completion absent")

-- ── Cross-buffer safety: a sibling buffer is untouched ─────────────────────────
local sib = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(sib)
local sib_km = 0
for _ in ipairs(vim.api.nvim_buf_get_keymap(sib, "i")) do sib_km = sib_km + 1 end
check(sib_km == 0, "sibling buffer should have no pi-editor keymaps")
-- switch back so buffer-scoped queries below target `buf`
vim.api.nvim_set_current_buf(buf)

-- ── S20's VimEnter autocmd in the shared group is preserved (GOTCHA C) ─────────
local ve = vim.api.nvim_get_autocmds({ event = "VimEnter", group = "pi-editor" })
check(#ve >= 1, "S20 VimEnter autocmd should still exist (clear=false)")

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")