--- pi-prompt buffer setup. Auto-sourced on |FileType| `pi-prompt` (set by
--- `require("pi-editor").activate()` — S21). Configures the pi temp-file buffer for
--- prompt editing and wires the completion keymaps + the completion/autosave autocmds.
---
--- Scope (what this ftplugin DOES): set the editing |options|, register the 6 insert-mode
--- |buffer-local keymaps|, and register the |buffer-local| completion/autosave |autocmds|.
--- It runs once per buffer whose filetype becomes `pi-prompt`; it touches ONLY that buffer.
---
--- Scope (what this ftplugin does NOT do): it does NOT implement completion (that is
--- `pi-editor.completion` / S30+) or autosave (that is the bridge's `on_exit` / S38). It
--- only WIRES them. The keymaps/autocmds below dispatch into those modules via a
--- lazy-require helper; until those modules ship the dispatches are silent no-ops (autocmds)
--- or fall through to the key's default behavior (keymaps). So this buffer behaves as a
--- normal markdown buffer TODAY and goes live the moment S30/S38 land — with NO ftplugin
--- edit (the contract is just module + function names, established here).
---
--- FORWARD CONTRACTS (established here; implemented by later tasks):
---   require("pi-editor.completion"):                    (S30+)
---     refresh(buf)              -- InsertEnter/TextChangedI/CursorMovedI; fire-and-forget.
---     on_tab(buf)   -> truthy    -- <Tab>: trigger / accept the menu (S33); truthy == handled.
---     on_enter(buf) -> truthy    -- <CR>: accept if menu open else insert newline (S32).
---     on_next(buf)  -> truthy    -- <C-N>: next item (S36).
---     on_prev(buf)  -> truthy    -- <S-Tab>/<C-P>: prev item (S36).
---     on_dismiss(buf)-> truthy   -- <C-E>: dismiss the menu (S37).
---   require("pi-editor.bridge"):                       (connection: S24; on_exit body: S38)
---     on_exit(buf)              -- VimLeavePre/ExitPre: autosave-if-modified + send bye + close.
--- A keymap dispatch returns `true` ONLY if the module exists AND its function returned
--- truthy; otherwise the keymap falls through to its default (see |feedkeys()| below).
---
--- pi-specific <CR> behavior (PRD §2.1 / §7.4): there is NO Enter-to-submit in the
--- external editor — pi reads the temp file only AFTER the editor EXITS. So `<CR>` inserts
--- a NEWLINE; it accepts only when the completion menu is open (owned by
--- `completion.on_enter` / S32). Documented for implementers & users.
--
-- Read resolved config safely (config may be nil if the user never called setup() — the
-- shim's pcall(require,"pi-editor") guard plus activate()'s self-setup cover the real path,
-- but this ftplugin can also be sourced directly by tests / a manual `:set ft=pi-prompt`).
local pi_ok, pi = pcall(require, "pi-editor")
local config = (pi_ok and pi and (pi.config or pi.defaults)) or {}

local buf = vim.api.nvim_get_current_buf()   -- the matched pi-prompt buffer (ftplugin runs current==matched; :help filetype-plugins)
local win = vim.api.nvim_get_current_win()

-- ── Options (PRD §7.6) ──────────────────────────────────────────────────────────
-- GOTCHA A: `vim.bo[buf].formatoptions` is a plain STRING (e.g. "tcqj"), NOT an Option
-- object — calling `:remove("t")` THROWS ("attempt to call method 'remove' (a nil value)").
-- Use the gsub form (captured-buf-scoped, deterministic). Removing 't' stops insert-time
-- auto-wrapping regardless of textwidth; textwidth=0 neutralizes the width threshold.
vim.bo[buf].formatoptions = (vim.bo[buf].formatoptions or ""):gsub("t", "")  -- stop insert-time auto-wrap
vim.bo[buf].textwidth = 0                                                   -- disable wrap width threshold
vim.wo[win].wrap = true                                                     -- window-local (GOTCHA E: accepted leak)
vim.wo[win].spell = false                                                   -- window-local (GOTCHA E: accepted leak)

-- ── Forward-contract dispatch (GOTCHA B: no-op-safe against absent modules) ─────
--- Lazily require a forward-contract module and call one of its functions on a buffer.
--- Returns `true` ONLY if the module exists AND its function returned truthy ("handled").
--- Any failure (module missing, field not a function, function threw) returns `false`
--- silently — so keymaps/autocmds installed today stay safe until the target ships.
---@param modname string  Module to require (e.g. "pi-editor.completion").
---@param fnname  string  Function field to call (e.g. "on_tab").
---@param b       integer Buffer handle passed as the sole argument.
---@return boolean handled true iff the module+function ran and returned truthy.
local function dispatch(modname, fnname, b)
  local ok, mod = pcall(require, modname)
  if not ok or type(mod) ~= "table" then return false end
  local fn = mod[fnname]
  if type(fn) ~= "function" then return false end
  local pok, handled = pcall(fn, b)
  return pok and handled == true
end

--- Feed a key literally WITHOUT re-entering any mapping. `feedkeys` with the `'n'` flag
--- feeds the key as not-remappable, so e.g. `<CR>` inserts a newline instead of recursing
--- into this buffer-local map. Used for the keymap fall-through (GOTCHA D — keeps
--- `<CR>`/`<Tab>`/etc. usable while completion.lua is absent).
---@param k string The key expression to feed (e.g. "<CR>", "<Tab>").
local function feedkey(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, true, true), "n", false)
end

--- Register a buffer-local keymap that dispatches to a forward-contract function; if the
--- dispatch is not handled (module absent or signalled fall-through), fall through to the
--- key's default via |feedkey| (GOTCHA D). `desc` is prefixed `"pi-editor:"` for discovery.
---@param mode    string  Mapping mode (e.g. "i").
---@param lhs     string  Left-hand side key (e.g. "<Tab>").
---@param modname string  Forward-contract module (e.g. "pi-editor.completion").
---@param fnname  string  Forward-contract function (e.g. "on_tab").
local function map_dispatch(mode, lhs, modname, fnname)
  vim.keymap.set(mode, lhs, function()
    if not dispatch(modname, fnname, buf) then feedkey(lhs) end
  end, { buffer = buf, desc = "pi-editor: " .. fnname })
end

-- ── Keymaps (insert-mode, buffer-local; PRD §7.6) ──────────────────────────────
-- Each maps to a forward-contract completion function and falls through to its default
-- when that function is absent / signals fall-through. Until completion.lua (S30+) ships,
-- all six behave as their normal insert-mode defaults (Tab indents, CR inserts a newline).
map_dispatch("i", "<Tab>",   "pi-editor.completion", "on_tab")     -- trigger / accept the menu (S33)
map_dispatch("i", "<S-Tab>", "pi-editor.completion", "on_prev")    -- previous completion item (S36)
map_dispatch("i", "<C-N>",   "pi-editor.completion", "on_next")    -- next completion item (S36)
map_dispatch("i", "<C-P>",   "pi-editor.completion", "on_prev")    -- previous completion item (S36)
map_dispatch("i", "<C-E>",   "pi-editor.completion", "on_dismiss") -- dismiss the completion menu (S37)
map_dispatch("i", "<CR>",    "pi-editor.completion", "on_enter")   -- accept-or-newline (S32); no Enter-to-submit (PRD §7.4)

-- ── Autocmds (buffer-local, shared "pi-editor" group; GOTCHA C: clear=false) ────
-- The "pi-editor" augroup is SHARED with S20's VimEnter autocmd. Creating it here with
-- `clear=true` would WIPE that autocmd (and sibling buffers' pi-editor autocmds). We use
-- `clear=false`. Per-buffer idempotency (so a re-source via `:doautocmd FileType` does not
-- stack duplicates) is via a BUFFER-SCOPED `nvim_clear_autocmds` — it leaves siblings intact.
local group = vim.api.nvim_create_augroup("pi-editor", { clear = false })
vim.api.nvim_clear_autocmds({ buffer = buf, group = "pi-editor" })   -- idempotent on re-source

-- Completion refresh triggers — fire-and-forget (no default to preserve, so no fall-through).
for _, ev in ipairs({ "InsertEnter", "TextChangedI", "CursorMovedI" }) do
  vim.api.nvim_create_autocmd(ev, {
    group = group,
    buffer = buf,
    desc = "pi-editor: completion refresh (" .. ev .. ")",
    callback = function() dispatch("pi-editor.completion", "refresh", buf) end,
  })
end

-- Autosave + bridge teardown on exit (gated on config; default true — PRD §7.6, §11). The
-- body (write-if-modified, send bye, close socket) is S38's job; the WIRING lives here.
if config.autosave_on_exit ~= false then
  for _, ev in ipairs({ "VimLeavePre", "ExitPre" }) do
    vim.api.nvim_create_autocmd(ev, {
      group = group,
      buffer = buf,
      desc = "pi-editor: autosave + bridge teardown on " .. ev,
      callback = function() dispatch("pi-editor.bridge", "on_exit", buf) end,
    })
  end
end

-- BufWritePre: intentionally NOT overridden. The pi temp file is writable, so the default
-- `:w` works (PRD §7.6 "no-op normal write" = let the default proceed). Registering a no-op
-- BufWritePre would be pointless and could risk breaking `:w`. No autocmd registered.