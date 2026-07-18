-- === plugin/tests/shim_smoke.lua — standalone (plenary-FREE) smoke test for the shim ===
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/shim_smoke.lua" +qa ; echo exit=$?
-- Exits 0 on pass (prints SMOKE_PASS), 1 on any check failure (via cquit). Zero deps.
-- NOTE: this file is sourced at step 17 (+), AFTER step-12 auto-source of plugin/pi-editor.lua
-- (provided plugin/ is on runtimepath — set below). Do NOT move the runtimepath set into
-- the shim or into a --cmd (GOTCHA #1/#3).
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")                  -- absolute path of THIS file
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../plugin  (rtp entry — GOTCHA #1)
vim.opt.runtimepath:append(plugin_root)

-- Force a (re)source of the shim now that plugin/ is on rtp, so this file is self-contained
-- and does not depend on having been auto-sourced in this --clean session.
vim.cmd("runtime plugin/pi-editor.lua")

local fails = 0
local function check(cond, msg)
  if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); fails = fails + 1 end
end

-- helpers
local function autovims()
  return vim.api.nvim_get_autocmds({ event = "VimEnter", group = "pi-editor" })
end
local function resource() vim.cmd("runtime plugin/pi-editor.lua") end

-- CHECK 1: exactly 1 VimEnter autocmd, once=true, group=pi-editor, callback is a fn.
local a = autovims()
check(#a == 1, "expected exactly 1 VimEnter autocmd, got " .. #a)
if a[1] then
  check(a[1].once == true, "autocmd.once should be true")
  check(a[1].group_name == "pi-editor", "group_name should be 'pi-editor', got " .. tostring(a[1].group_name))
  check(type(a[1].callback) == "function", "callback should be a function")
end

-- CHECK 2: mock activate injected → called EXACTLY ONCE on one VimEnter fire.
resource()                                               -- fresh once-autocmd
package.loaded["pi-editor"] = nil; local pi = require("pi-editor")
vim.g.pi_calls = 0
pi.activate = function() vim.g.pi_calls = vim.g.pi_calls + 1 end
vim.api.nvim_exec_autocmds("VimEnter", {})               -- step-17 manual fire (GOTCHA #3/#4)
check(vim.g.pi_calls == 1, "mock activate should be called exactly once (got " .. tostring(vim.g.pi_calls) .. ")")

-- CHECK 3: fire VimEnter a SECOND time → still 1 (once=true).
vim.api.nvim_exec_autocmds("VimEnter", {})
check(vim.g.pi_calls == 1, "once=true should prevent a second call (got " .. tostring(vim.g.pi_calls) .. ")")
pi.activate = nil                                        -- clean up the mock

-- CHECK 4: NO activate present → firing VimEnter does NOT error (interim/dormant-safe).
resource()                                               -- fresh once-autocmd
package.loaded["pi-editor"] = nil; require("pi-editor")  -- fresh module, activate == nil
local ok, err = pcall(vim.api.nvim_exec_autocmds, "VimEnter", {})
check(ok, "firing VimEnter with no activate should not error: " .. tostring(err))
check(vim.g.pi_calls == 1, "no-activate fire should not have called the (removed) mock")

-- CHECK 5: idempotent re-source → still exactly 1 autocmd (clear=true, GOTCHA #5).
resource(); resource()                                   -- source 2 extra times
check(#autovims() == 1, "re-source should not stack duplicates (got " .. #autovims() .. ")")

-- CHECK 6 (structural + no env-read): assert the core tokens are present AND the shim
-- does NOT read the environment. We use only ROBUST literals: the doc-comment header
-- mentions "PI_EDITOR_BRIDGE"/"setup()" by name to explain they are NOT used here, so a
-- naive "does NOT contain those words" search would FALSE-POSITIVE on the comment.
-- Instead we assert no env access (vim.env / os.getenv) + presence of the structural
-- tokens. (No-setup-call / no-bridge-require are code-inspection checklist items.)
local src = table.concat(vim.fn.readfile(plugin_root .. "/plugin/pi-editor.lua"), "\n")
check(src:find('nvim_create_autocmd("VimEnter"', 1, true) ~= nil, "shim must register a VimEnter autocmd")
check(src:find("once = true", 1, true) ~= nil, "shim must set once = true")
check(src:find("clear = true", 1, true) ~= nil, "shim must set clear = true")
check(src:find("vim.env", 1, true) == nil, "shim must NOT read the env (PI_EDITOR_BRIDGE is S21's job)")
check(src:find("getenv", 1, true) == nil, "shim must NOT call os.getenv (S21's job)")

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")
