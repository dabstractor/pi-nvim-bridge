-- === plugin/tests/minimal_init.lua — plenary harness bootstrap ===
-- Run (from the plugin/ directory, OR pass absolute spec path — see Validation):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/init_spec.lua")'
local me = debug.getinfo(1, "S").source:sub(2)            -- .../plugin/tests/minimal_init.lua
me = vim.fn.fnamemodify(me, ":p")                          -- absolute (relative-path safety)
local plugin_root = vim.fn.fnamemodify(me, ":h:h")         -- .../plugin   (runtimepath entry — GOTCHA #1)
local plenary = os.getenv("PLENARY_PATH")
  or "/home/dustin/.local/share/nvim/lazy/plenary.nvim"    -- verified install location

vim.opt.runtimepath:prepend(plenary)                       -- so require("plenary.busted") resolves
vim.opt.runtimepath:append(plugin_root)                    -- so require("pi-bridge") resolves
