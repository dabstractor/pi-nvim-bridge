--- pi-editor.nvim — entry module.
--
-- Call |setup()| once from your config to apply options:
-- >
--   require("pi-editor").setup({})
-- <
-- The plugin stays dormant unless pi spawned this Neovim with the PI_EDITOR_BRIDGE
-- env var set (PRD §7.1; the activation gate lives in plugin/pi-editor.lua, added by
-- a later task). setup() itself is side-effect-free: it only merges options into
-- |M.config|.
--
-- All other modules read their resolved config from `require("pi-editor").config`.

---@class pi-editor.MenuConfig
---@field max_height integer Maximum visible rows in the floating completion popup.
---@field border ("none"|"single"|"double"|"rounded"|"solid"|"shadow"|string[]) Border style (nvim_open_win 'border').

---@class pi-editor.Config
---@field menu pi-editor.MenuConfig Floating-menu appearance (PRD §7.5).
---@field debounce_ms integer Ms to debounce before re-querying the bridge after a change.
---@field rpc_timeout_ms integer Ms before a pending RPC is considered stale (supersession).
---@field autosave_on_exit boolean Write the pi temp file on VimLeavePre if modified (PRD §7.6, §11).
---@field engine ("builtin"|"blink"|"cmp") Which completion UI engine to drive.
---@field env_var? string Override the bridge-descriptor env var (default "PI_EDITOR_BRIDGE"; PRD §7.1).

local M = {}

--- Default options (PRD §10.5). Exported so :checkhealth / tests can read the
--- shipped values. Never mutated by setup() — vim.tbl_deep_extend returns a new table.
---@type pi-editor.Config
M.defaults = {
  menu = {
    max_height = 12,
    border = "rounded",
  },
  debounce_ms = 25,
  rpc_timeout_ms = 2000,
  autosave_on_exit = true,
  engine = "builtin",
}

--- Resolved configuration. `nil` until |setup()|; a `pi-editor.Config` afterwards.
---@type pi-editor.Config|nil
M.config = nil

--- Bridge client. Populated by `bridge.lua` after a successful connect + handshake;
--- `nil` before that and in dormant sessions (no PI_EDITOR_BRIDGE env var). External
--- code (blink/cmp sources, user code) reads `require("pi-editor").bridge` to issue
--- RPCs (PRD §7.7). Typed `table|nil` until bridge.lua ships a concrete type.
---@type table|nil
M.bridge = nil

--- Apply user options over the defaults and store the merged result in |M.config|.
---
--- Call once from your init config:
--- >
---   require("pi-editor").setup({
---     menu = { max_height = 20 },
---     debounce_ms = 40,
---     autosave_on_exit = false,
---   })
--- <
--- Re-calling setup() re-merges and overwrites M.config (safe to re-source).
---
---@param opts? pi-editor.Config User-provided options (empty table or nil OK).
---@return pi-editor.Config The resolved, merged config (also stored as M.config).
function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.defaults, opts)
  return M.config
end

return M
