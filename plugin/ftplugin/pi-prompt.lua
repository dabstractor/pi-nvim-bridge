--- pi-prompt buffer setup. Auto-sourced on |FileType| `pi-prompt` (set by
--- `require("pi-bridge").activate()` — S21). Configures the pi temp-file buffer for
--- prompt editing and wires the completion keymaps + the completion/autosave autocmds.
---
--- Scope (what this ftplugin DOES): set the editing |options|, register the 6 insert-mode
--- |buffer-local keymaps|, and register the |buffer-local| completion/autosave |autocmds|.
--- It runs once per buffer whose filetype becomes `pi-prompt`; it touches ONLY that buffer.
---
--- Scope (what this ftplugin does NOT do): it does NOT implement completion (that is
--- `pi-bridge.completion` / S30+) or autosave (that is the bridge's `on_exit` / S38). It
--- only WIRES them. The keymaps/autocmds below dispatch into those modules via a
--- lazy-require helper; until those modules ship the dispatches are silent no-ops (autocmds)
--- or fall through to the key's default behavior (keymaps). So this buffer behaves as a
--- normal markdown buffer TODAY and goes live the moment S30/S38 land — with NO ftplugin
--- edit (the contract is just module + function names, established here).
---
--- FORWARD CONTRACTS (established here; implemented by later tasks):
---   require("pi-bridge.completion"):                    (S30+)
---     refresh(buf)              -- InsertEnter/TextChangedI/CursorMovedI; fire-and-forget.
---     on_tab(buf)   -> truthy    -- <Tab>: trigger / accept the menu (S33); truthy == handled.
---     on_enter(buf) -> truthy    -- <CR>/<C-Y>: accept if menu open else insert newline (S32).
---     on_next(buf)  -> truthy    -- <C-N>/<Down>: next item (S36). <Up>/<Down> mirror <C-P>/<C-N>.
---     on_prev(buf)  -> truthy    -- <S-Tab>/<C-P>/<Up>: prev item (S36).
---     on_dismiss(buf)-> truthy   -- <C-E>: dismiss the menu (S36 — the KEY handler; S37 is the
---                                auto-close AUTOCMDS).
---     on_insert_leave(buf)       -- InsertLeave autocmd → hide + cancel pending refresh (S37).
---     on_buf_leave(buf)          -- BufLeave autocmd → same teardown on buffer switch (S37).
---   require("pi-bridge.bridge"):                       (connection: S24; on_exit body: S38)
---     on_exit(buf)              -- VimLeavePre/ExitPre: autosave-if-modified + send bye + close.
--- A keymap dispatch returns `true` ONLY if the module exists AND its function returned
--- truthy; otherwise the keymap falls through to its default (see |feedkeys()| below).
--- <C-Y> REUSES on_enter (NO on_accept): accept if the menu is open, else fall through
--- to :help i_CTRL-Y (research/notes.md §6).
---
--- S37 auto-close ownership: InsertLeave + BufLeave are autocmd-fired (above). The third
--- trigger ("CursorMoved out of prefix") is OWNED pi-faithfully by the EXISTING
--- CursorMovedI→refresh→re-fetch→empty→close path (S30, COMPLETE — NO local prefix
--- detector; research/notes.md §3).
---
--- pi-specific <CR> behavior (PRD §2.1 / §7.4): there is NO Enter-to-submit in the
--- external editor — pi reads the temp file only AFTER the editor EXITS. So `<CR>` inserts
--- a NEWLINE; it accepts only when the completion menu is open (owned by
--- `completion.on_enter` / S32). Documented for implementers & users.
--
-- Read resolved config safely (config may be nil if the user never called setup() — the
-- shim's pcall(require,"pi-bridge") guard plus activate()'s self-setup cover the real path,
-- but this ftplugin can also be sourced directly by tests / a manual `:set ft=pi-prompt`).
local pi_ok, pi = pcall(require, "pi-bridge")
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

-- ── Suppress other completion engines (avoid a double completion UI) ───────────
-- This plugin renders its OWN floating menu from pi's live provider. If the user
-- also drives blink.cmp and/or nvim-cmp, those engines would pop their OWN menu in
-- this buffer (double UI, conflicting <Tab>/<CR>). Disable them HERE — buffer-local
-- + best-effort — so only pi-bridge's menu shows, WITHOUT touching the user's global
-- config. Resolved FRESH (pcall) so a missing/odd engine config degrades silently.
--   * blink.cmp: its `enabled()` explicitly honors `vim.b.completion == false`
--     (blink.cmp/lua/blink/cmp/config/init.lua) → setting it disables blink HERE.
--   * nvim-cmp: per-buffer disable via `cmp.setup.buffer({ enabled = false })`.
-- Note: the shipped opt-in blink/cmp *adapter sources* (engine="blink"/"cmp") are a
-- DIFFERENT, user-chosen path; this block only suppresses the user's EXISTING engine
-- so the builtin menu is the sole UI. Users who prefer their engine can set
-- `vim.g.pi_bridge_suppress_engines = false` to opt out.
if vim.g.pi_bridge_suppress_engines ~= false then
  vim.b[buf].completion = false -- blink.cmp honors this (forces disabled in this buffer)
  pcall(function()
    local ok, cmp = pcall(require, "cmp")
    -- (nvim-cmp: `cmp.setup` is a function carrying a `.buffer` method. blink.compat's
    --  `cmp` shim has neither → the guard skips it cleanly; only real nvim-cmp is affected.)
    if ok and type(cmp.setup) == "function" and type(cmp.setup.buffer) == "function" then
      cmp.setup.buffer({ enabled = false })
    end
  end)
end

-- ── Forward-contract dispatch (GOTCHA B: no-op-safe against absent modules) ─────
--- Lazily require a forward-contract module and call one of its functions on a buffer.
--- Returns `true` ONLY if the module exists AND its function returned truthy ("handled").
--- Any failure (module missing, field not a function, function threw) returns `false`
--- silently — so keymaps/autocmds installed today stay safe until the target ships.
---@param modname string  Module to require (e.g. "pi-bridge.completion").
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
--- key's default via |feedkey| (GOTCHA D). `desc` is prefixed `"pi-bridge:"` for discovery.
---@param mode    string  Mapping mode (e.g. "i").
---@param lhs     string  Left-hand side key (e.g. "<Tab>").
---@param modname string  Forward-contract module (e.g. "pi-bridge.completion").
---@param fnname  string  Forward-contract function (e.g. "on_tab").
local function map_dispatch(mode, lhs, modname, fnname)
  vim.keymap.set(mode, lhs, function()
    if not dispatch(modname, fnname, buf) then feedkey(lhs) end
  end, { buffer = buf, desc = "pi-bridge: " .. fnname })
end

-- ── Keymaps (insert-mode, buffer-local; PRD §7.6) ──────────────────────────────
-- Each maps to a forward-contract completion function and falls through to its default
-- when that function is absent / signals fall-through. Until completion.lua (S30+) ships,
-- all six behave as their normal insert-mode defaults (Tab indents, CR inserts a newline).
map_dispatch("i", "<Tab>",   "pi-bridge.completion", "on_tab")     -- trigger / accept the menu (S33)
map_dispatch("i", "<S-Tab>", "pi-bridge.completion", "on_prev")    -- previous completion item (S36)
map_dispatch("i", "<C-N>",   "pi-bridge.completion", "on_next")    -- next completion item (S36)
map_dispatch("i", "<C-P>",   "pi-bridge.completion", "on_prev")    -- previous completion item (S36)
map_dispatch("i", "<C-E>",   "pi-bridge.completion", "on_dismiss") -- dismiss the completion menu (S36)
map_dispatch("i", "<CR>",    "pi-bridge.completion", "on_enter")   -- accept-or-newline (S32); no Enter-to-submit (PRD §7.4)
-- S36: the PRD §7.5 full key set — arrows navigate; <C-Y> accepts (reuses on_enter).
map_dispatch("i", "<Down>",  "pi-bridge.completion", "on_next")    -- next completion item (S36; mirrors <C-N>)
map_dispatch("i", "<Up>",    "pi-bridge.completion", "on_prev")    -- previous completion item (S36; mirrors <C-P>)
map_dispatch("i", "<C-Y>",   "pi-bridge.completion", "on_enter")   -- accept (S36; reuses on_enter's accept-or-fall-through)

-- ── Autocmds (buffer-local, shared "pi-bridge" group; GOTCHA C: clear=false) ────
-- The "pi-bridge" augroup is SHARED with S20's VimEnter autocmd. Creating it here with
-- `clear=true` would WIPE that autocmd (and sibling buffers' pi-bridge autocmds). We use
-- `clear=false`. Per-buffer idempotency (so a re-source via `:doautocmd FileType` does not
-- stack duplicates) is via a BUFFER-SCOPED `nvim_clear_autocmds` — it leaves siblings intact.
local group = vim.api.nvim_create_augroup("pi-bridge", { clear = false })
vim.api.nvim_clear_autocmds({ buffer = buf, group = "pi-bridge" })   -- idempotent on re-source

-- Completion refresh triggers — fire-and-forget (no default to preserve, so no fall-through).
for _, ev in ipairs({ "InsertEnter", "TextChangedI", "CursorMovedI" }) do
  vim.api.nvim_create_autocmd(ev, {
    group = group,
    buffer = buf,
    desc = "pi-bridge: completion refresh (" .. ev .. ")",
    callback = function() dispatch("pi-bridge.completion", "refresh", buf) end,
  })
end

-- ── S37: auto-close the menu when the user leaves the completion context (PRD §7.5) ─────────────
-- InsertLeave covers <Esc>/<C-\><C-n>; BufLeave covers :bnext/:e/split-to-another-buffer. Each hides
-- the menu + cancels the pending refresh so a stale do_refresh cannot re-open the menu in normal mode
-- (research §1). The "CursorMoved out of prefix" trigger is owned pi-faithfully by the EXISTING
-- CursorMovedI→refresh→re-fetch→empty→close path above (S30, COMPLETE; no local prefix detector — §3).
-- Fire-and-forget (autocmd; dispatch's bool return is ignored here — used only for the no-op-safe-
-- absent-module guarantee). Buffer-local + the SHARED "pi-bridge" group + clear=false (idempotent via
-- the nvim_clear_autocmds line above).
for _, ev in ipairs({ "InsertLeave", "BufLeave" }) do
  local fn = (ev == "InsertLeave") and "on_insert_leave" or "on_buf_leave"
  vim.api.nvim_create_autocmd(ev, {
    group = group,
    buffer = buf,
    desc = "pi-bridge: auto-close completion menu on " .. ev,
    callback = function() dispatch("pi-bridge.completion", fn, buf) end,
  })
end

-- Autosave + bridge teardown on exit (gated on config; default true — PRD §7.6, §11). The
-- body (write-if-modified, send bye, close socket) is S38's job; the WIRING lives here.
if config.autosave_on_exit ~= false then
  for _, ev in ipairs({ "VimLeavePre", "ExitPre" }) do
    vim.api.nvim_create_autocmd(ev, {
      group = group,
      buffer = buf,
      desc = "pi-bridge: autosave + bridge teardown on " .. ev,
      callback = function() dispatch("pi-bridge.bridge", "on_exit", buf) end,
    })
  end
end

-- BufWritePre: intentionally NOT overridden. The pi temp file is writable, so the default
-- `:w` works (PRD §7.6 "no-op normal write" = let the default proceed). Registering a no-op
-- BufWritePre would be pointless and could risk breaking `:w`. No autocmd registered.