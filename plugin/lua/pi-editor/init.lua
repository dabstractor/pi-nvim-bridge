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

-- ===========================================================================
-- S21 — VimEnter activation gate (PRD §7.1, §11). Called once by the auto-sourced
-- shim (plugin/pi-editor.lua) on VimEnter. DORMANT BY DESIGN: returns nil unless pi
-- spawned this editor with the bridge descriptor env var set AND valid. NEVER throws
-- and NEVER notifies (the one-time notify on hard failure is task S39's job). The shim
-- calls this WITHOUT a pcall, so internal safety is load-bearing (GOTCHA E).
-- ===========================================================================

--- Bridge descriptor parsed from the env var by |activate()|. `nil` until activation
--- succeeds. Downstream modules read it: bridge.lua (S24) uses `.path` + `.token` to
--- connect; completion (S30+) uses `.cwd`. Mirrors the extension's BridgeDescriptor
--- (extension/protocol.ts); all fields are present & non-null when transport=="unix".
---@class pi-editor.BridgeDescriptor
---@field transport "unix" Transport type (v1 literal "unix"; PRD §5.1 names a future "tcp").
---@field path string Unix domain socket path (${tmpdir}/pi-editor-bridge-<uuid>.sock).
---@field token string Random 32-byte hex secret — the REAL auth boundary (PRD §5.3, §12).
---@field pid integer pi's process id.
---@field cwd string pi session working directory (ctx.cwd).
---@field fdAvailable boolean Whether the `fd` binary resolved (controls @file fuzzy search).
---@field serverVersion string Bridge server version string (PRD §6.4 hardcodes "0.1.0").

--- The parsed bridge descriptor once |activate()| succeeds; `nil` in every dormant session
--- and before the first successful activation. Read by downstream modules (see class doc).
---@type pi-editor.BridgeDescriptor|nil
M.descriptor = nil

--- Activate pi-editor for this session — the VimEnter entry point.
---
--- Called once per session by the auto-sourced shim (`plugin/pi-editor.lua`). Reads the
--- bridge descriptor from the env var named by |pi-editor.Config.env_var| (default
--- "PI_EDITOR_BRIDGE"), validates it, and — ONLY on success — stores it on |descriptor|
--- and marks the current buffer as a pi prompt (`vim.bo.filetype = "pi-prompt"`).
---
--- DORMANT BY DESIGN (PRD §7.1, §11): in every ordinary (non-pi) nvim session the env var
--- is unset, so this returns nil immediately and the plugin does nothing. A descriptor that
--- is malformed JSON, valid JSON but not a JSON object (e.g. a bare `123`/`true`/`"s"`), or
--- has `transport ~= "unix"` is ALSO treated as dormant. This function NEVER throws and
--- NEVER notifies (the optional one-time `vim.notify` on hard failure is task S39's job).
---
--- Scope (what this gate does NOT do): it does NOT connect to the bridge (that is
--- `bridge.lua` / S24, which reads this |descriptor|) and it does NOT set buffer options or
--- keymaps (that is `ftplugin/pi-prompt.lua` / S22, auto-sourced when this sets filetype).
--- Setting the filetype is this gate's ONLY buffer mutation; it is the handshake to S22.
---
---@return pi-editor.BridgeDescriptor|nil desc The parsed descriptor on success; nil if dormant.
function M.activate()
  -- Self-sufficient if the user's config never called setup() (e.g. the NVIM_APPNAME minimal
  -- config, S47). setup({}) applies the documented defaults and sets M.config. (GOTCHA D)
  if M.config == nil then M.setup({}) end
  local env_name = M.config.env_var or "PI_EDITOR_BRIDGE"
  local raw = vim.env[env_name]
  if raw == nil then return nil end                       -- (b) no env var -> dormant
  local ok, desc = pcall(vim.json.decode, raw)            -- (c) decode (THROWS -> pcall)
  if not ok or type(desc) ~= "table" then return nil end  -- malformed / non-object -> dormant (GOTCHA B)
  if desc.transport ~= "unix" then return nil end         -- (d) wrong transport -> dormant
  M.descriptor = desc                                     -- (e) store for S24/S30+
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "pi-prompt"                      -- (f) activate -> fires FileType (S22 seam)
  return desc                                             -- (g)/(h) are S22/S24's job (see doc)
end

return M
