--- pi-bridge.nvim — entry module.
--
-- Call |setup()| once from your config to apply options:
-- >
--   require("pi-bridge").setup({})
-- <
-- The plugin stays dormant unless pi spawned this Neovim with the PI_NVIM_BRIDGE
-- env var set (PRD §7.1; the activation gate lives in plugin/pi-bridge.lua, added by
-- a later task). setup() itself is side-effect-free: it only merges options into
-- |M.config|.
--
-- All other modules read their resolved config from `require("pi-bridge").config`.

---@class pi-bridge.MenuConfig
---@field max_height integer Maximum visible rows in the floating completion popup.
---@field border ("none"|"single"|"double"|"rounded"|"solid"|"shadow"|string[]) Border style (nvim_open_win 'border').

---@class pi-bridge.Config
---@field menu pi-bridge.MenuConfig Floating-menu appearance (PRD §7.5).
---@field debounce_ms integer The file/attachment-context debounce window (default 20 = pi's ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS, editor.ts:236). Slash commands and plain typing use 0 ms (immediate), matching pi's TUI `getAutocompleteDebounceMs` (editor.ts:2214); NOT separately configurable (pi hardcodes 0). S40.
---@field rpc_timeout_ms integer Ms before a pending RPC is considered stale (supersession). MUST exceed the server fd-abort GET_SUGGESTIONS_TIMEOUT_MS (1500, extension/pi-nvim-bridge.ts:289) so the server's own abort wins (timeouts cascade outward); default 2000. See bridge.lua header. S40.
---@field autosave_on_exit boolean Write the pi temp file on VimLeavePre if modified (PRD §7.6, §11).
---@field engine ("builtin"|"blink"|"cmp") Which completion UI engine to drive.
---@field env_var? string Override the bridge-descriptor env var (default "PI_NVIM_BRIDGE"; PRD §7.1).

local M = {}

--- Default options (PRD §10.5). Exported so :checkhealth / tests can read the
--- shipped values. Never mutated by setup() — vim.tbl_deep_extend returns a new table.
---@type pi-bridge.Config
M.defaults = {
  menu = {
    max_height = 12,
    border = "rounded",
  },
  debounce_ms = 20,        -- pi ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS (editor.ts:236). file/attachment-context window; slash/typing use 0 ms (pi-faithful). S40 (was 25).
  rpc_timeout_ms = 2000,   -- MUST exceed the server fd-abort GET_SUGGESTIONS_TIMEOUT_MS (1500). S40.
  autosave_on_exit = true,
  engine = "builtin",
}

--- Resolved configuration. `nil` until |setup()|; a `pi-bridge.Config` afterwards.
---@type pi-bridge.Config|nil
M.config = nil

--- Bridge client. Populated by `bridge.lua` after a successful connect + handshake;
--- `nil` before that and in dormant sessions (no PI_NVIM_BRIDGE env var). External
--- code (blink/cmp sources, user code) reads `require("pi-bridge").bridge` to issue
--- RPCs (PRD §7.7). Typed `table|nil` until bridge.lua ships a concrete type.
---@type table|nil
M.bridge = nil

--- Apply user options over the defaults and store the merged result in |M.config|.
---
--- Call once from your init config:
--- >
---   require("pi-bridge").setup({
---     menu = { max_height = 20 },
---     debounce_ms = 40,
---     autosave_on_exit = false,
---   })
--- <
--- Re-calling setup() re-merges and overwrites M.config (safe to re-source).
---
---@param opts? pi-bridge.Config User-provided options (empty table or nil OK).
---@return pi-bridge.Config The resolved, merged config (also stored as M.config).
function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.defaults, opts)
  -- S40 optional invariant guard: WARN (dedup'd via notify.once) if a user set rpc_timeout_ms
  -- at/below the server fd-abort floor (GET_SUGGESTIONS_TIMEOUT_MS=1500). A client timeout BELOW
  -- the server abort would orphan the server's fd scan + cut off @file searches client-side.
  -- pcall-wrapped (setup NEVER throws; notify.once schedules the vim.notify internally + dedups).
  pcall(function()
    local rt = M.config.rpc_timeout_ms
    if type(rt) == "number" and rt > 0 and rt <= 1500 then
      require("pi-bridge.notify").once("config", vim.log.levels.WARN,
        "pi-bridge: rpc_timeout_ms (" .. rt .. "ms) is at/below the bridge fd-abort (1500ms) "
          .. "— @file searches may be cut off client-side")
    end
  end)
  return M.config
end

-- ===========================================================================
-- S21 — VimEnter activation gate (PRD §7.1, §11). Called once by the auto-sourced
-- shim (plugin/pi-bridge.lua) on VimEnter. DORMANT BY DESIGN: returns nil unless pi
-- spawned this editor with the bridge descriptor env var set AND valid. NEVER throws
-- and now (S39) emits at most ONE `vim.notify` on hard failure (the dedup is task
-- S39's `notify.lua`). The shim
-- calls this WITHOUT a pcall, so internal safety is load-bearing (GOTCHA E).
-- ===========================================================================

--- Bridge descriptor parsed from the env var by |activate()|. `nil` until activation
--- succeeds. Downstream modules read it: bridge.lua (S24) uses `.path` + `.token` to
--- connect; completion (S30+) uses `.cwd`. Mirrors the extension's BridgeDescriptor
--- (extension/protocol.ts); all fields are present & non-null when transport=="unix",
--- EXCEPT the §17.10 `shell`/`shellSource`/`shellPath` fields which are OPTIONAL + advisory
--- (absent on older clients ⇒ `shell.lua` falls back to `$SHELL`).
---@class pi-bridge.BridgeDescriptor
---@field transport "unix" Transport type (v1 literal "unix"; PRD §5.1 names a future "tcp").
---@field path string Unix domain socket path (${tmpdir}/pi-nvim-bridge-<uuid>.sock).
---@field token string Random 32-byte hex secret — the REAL auth boundary (PRD §5.3, §12).
---@field pid integer pi's process id.
---@field cwd string pi session working directory (ctx.cwd).
---@field fdAvailable boolean Whether the `fd` binary resolved (controls @file fuzzy search).
---@field serverVersion string Bridge server version string (PRD §6.4 hardcodes "0.1.0").
---@field shell string? §17.10 — the resolved execution-shell binary (advisory; mirrors extension/protocol.ts; absent on older clients).
---@field shellSource ("pi"|"$SHELL"|"default")? §17.10 — how `shell` was derived.
---@field shellPath string? §17.10 — the raw `shellPath` setting, if the user set one.

--- The parsed bridge descriptor once |activate()| succeeds; `nil` in every dormant session
--- and before the first successful activation. Read by downstream modules (see class doc).
---@type pi-bridge.BridgeDescriptor|nil
M.descriptor = nil

--- Activate pi-bridge for this session — the VimEnter entry point.
---
--- Called once per session by the auto-sourced shim (`plugin/pi-bridge.lua`). Reads the
--- bridge descriptor from the env var named by |pi-bridge.Config.env_var| (default
--- "PI_NVIM_BRIDGE"), validates it, and — ONLY on success — stores it on |descriptor|
--- and marks the current buffer as a pi prompt (`vim.bo.filetype = "pi-prompt"`).
---
--- DORMANT BY DESIGN (PRD §7.1, §11): in every ordinary (non-pi) nvim session the env var
--- is unset, so this returns nil immediately and the plugin does nothing. A descriptor that
--- is malformed JSON, valid JSON but not a JSON object (e.g. a bare `123`/`true`/`"s"`), or
--- has `transport ~= "unix"` is ALSO treated as dormant. This function NEVER throws
--- and emits at most ONE `vim.notify` on hard failure (the optional one-time notify,
--- implemented in S39's `notify.lua` — dedup'd by category "bridge").
---
--- Scope (what this gate does NOT do): it does NOT set buffer options or keymaps
--- (that is `ftplugin/pi-prompt.lua` / S22, auto-sourced when this sets filetype).
--- Setting the filetype is this gate's ONLY buffer mutation; it is the handshake to S22.
--- (S25: this gate also kicks off the bridge `hello` handshake — async, `pcall`-wrapped,
--- silent on failure. It does NOT block on the result; `bridge.lua` sets
--- `require("pi-bridge").bridge` on success.)
---
---@return pi-bridge.BridgeDescriptor|nil desc The parsed descriptor on success; nil if dormant.
function M.activate()
  -- Self-sufficient if the user's config never called setup() (e.g. the NVIM_APPNAME minimal
  -- config, S47). setup({}) applies the documented defaults and sets M.config. (GOTCHA D)
  if M.config == nil then M.setup({}) end
  local env_name = M.config.env_var or "PI_NVIM_BRIDGE"
  local raw = vim.env[env_name]
  if raw == nil then return nil end                       -- (b) no env var -> dormant
  local ok, desc = pcall(vim.json.decode, raw)            -- (c) decode (THROWS -> pcall)
  if not ok or type(desc) ~= "table" then return nil end  -- malformed / non-object -> dormant (GOTCHA B)
  if desc.transport ~= "unix" then return nil end         -- (d) wrong transport -> dormant
  M.descriptor = desc                                     -- (e) store for S24/S30+
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "pi-prompt"                      -- (f) activate -> fires FileType (S22 seam)
  -- S25 + S39: connect + `hello` handshake (async), then surface a SINGLE notify on hard
  -- failure (connect refused / bad token / timeout / malformed — PRD §11). pcall so a
  -- bridge bug can NEVER break activation (the buffer still works as plain markdown).
  -- The handshake `on_result` cb runs INLINE from luv fast context (resolve_handshake is
  -- NOT schedule_wrap'd) → notify.once schedules the vim.notify internally (GOTCHA A/C).
  -- `bridge.handshake` sets `require("pi-bridge").bridge` on success ONLY (stays nil on
  -- failure → completion auto-bails → degrade to a normal buffer). Register the disconnect
  -- handler AFTER handshake() (handshake() runs M.close() at its start which would clear
  -- an earlier registration — GOTCHA D).
  pcall(function()
    local ok, br = pcall(require, "pi-bridge.bridge")
    if not ok or type(br.handshake) ~= "function" then return end
    br.handshake(desc, function(err, _info)
      if err == nil then return end -- success
      -- forward the bridge's token-free error string VERBATIM (GOTCHA H; PRD §12)
      require("pi-bridge.notify").once("bridge", vim.log.levels.WARN,
        "pi-bridge: completion unavailable — " .. tostring(err))
    end)
    -- S39: process-death (post-handshake socket drop) → single notify + hide stale menu +
    -- cancel pending completion. The handler is schedule_wrap'd by on_disconnect (runs on
    -- the nvim main loop → api-safe; GOTCHA I). notify.once dedups with the handshake cb
    -- (same category "bridge" → at most ONE toast per session; GOTCHA B).
    if type(br.on_disconnect) == "function" then
      br.on_disconnect(function(_reason)
        pcall(function() require("pi-bridge.menu").close() end)
        pcall(function() require("pi-bridge.completion").reset() end)
        require("pi-bridge.notify").once("bridge", vim.log.levels.WARN,
          "pi-bridge: bridge connection lost — completion disabled")
      end)
    end
    -- S41: clear caches + re-query on `commandsChanged` (the server rebuilt the provider
    -- on /reload/new/resume/fork — PRD §11 / §13 step 13). Registered AFTER handshake()
    -- (handshake() runs M.close() at its start which clears notification_handlers —
    -- GOTCHA D). schedule_wrap'd by on_notification (api-safe; can touch buffers/menus).
    -- Never throws (pcall-wrapped body; on_commands_changed is itself never-throws).
    if type(br.on_notification) == "function" then
      br.on_notification("commandsChanged", function(_params)
        pcall(function() require("pi-bridge.completion").on_commands_changed() end)
      end)
    end
  end)
  -- S31: wire completion results -> menu population (forward-contract no-op-safe,
  -- mirrors the bridge.handshake pcall above). menu.attach() registers
  -- completion.on_results. Safe to call before the bridge connects (refresh is a
  -- silent no-op then); idempotent across /reload (the `attached` flag).
  pcall(function()
    local ok, menu = pcall(require, "pi-bridge.menu")
    if ok and type(menu.attach) == "function" then menu.attach() end
  end)
  return desc                                             -- (g)/(h) are S22/S24's job (see doc)
end

return M
