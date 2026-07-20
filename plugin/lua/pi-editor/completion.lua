--- completion.lua — the per-keystroke completion TRIGGER module (parent P2.M7.T18).
--
-- Owns EXACTLY the pipeline the buffer-local autocmds (ftplugin S22) drive:
--   InsertEnter / TextChangedI / CursorMovedI
--     → require("pi-editor.completion").refresh(buf)   (fire-and-forget; wired via the
--                                                         ftplugin's no-op-safe `dispatch`)
--     → debounce (~25 ms via `vim.defer_fn`)
--     → read buffer lines + cursor (api-safe inside the defer cb)
--     → convert to pi coords via the COMPLETE S29 `coords.nvim_to_pi_coords`
--     → issue `getSuggestions` over the COMPLETE S26 `bridge.request`
--     → SUPERSEDE stale responses (BOTH layers: cancel prev in-flight + a generation-id
--        guard in the callback — the LIVE-VERIFIED nvim-cmp/blink.cmp pattern)
--     → store the latest {items, prefix} + push them to a forward-contract `on_results`
--        seam (nil-safe today; registered by S31 to populate the menu)
--
-- This is the DATA-PRODUCTION half of completion. Rendering is S31 (menu.lua / S34+).
--
-- [Mode A] header — read before editing:
--  * ROLE: the per-keystroke TRIGGER layer of P2.M7.T18. refresh(buf) is the autocmd
--    entry point; do_refresh(buf) is the debounced body. It owns the debounce, the RPC
--    issuance, supersession, result storage, the `on_results` seam, and `reset()`/`current()`.
--    It does NOT render the menu (S31), accept (S32), Tab-force (S33), or navigate (S36).
--    It reads the bridge FRESH at call time (`require("pi-editor").bridge`, NOT a cached
--    local — so the async handshake + test mocks both work).
--
--  * `vim.defer_fn` STOP+CLOSE LEAK (LIVE-VERIFIED, research/vim-defer-fn-semantics.md §3):
--    `external_deps.md §1.7`'s debounce recipe (`if timer then timer:stop() end`) is
--    WRONG on nvim 0.12.x — `:stop()` SUPPRESSES the callback but LEAKS the `uv_timer_t`
--    (`is_closing()` stays false). S30 supersedes §1.7: the reschedule path does `:stop()`
--    THEN `:close()` on every superseded timer. A reader of §1.7 should not be surprised
--    by the `:close()` — that is why this note exists (the codebase's "document every
--    refinement over PRD/docs" pattern).
--  * AUTO-CLOSE-AFTER-FIRE (research §4): a defer that FIRED naturally has already
--    AUTO-CLOSED. NEVER `:close()` a fired timer — it throws "already closing". Every
--    stop/close here is guarded by `is_closing()` + `pcall` so a fired-then-reschedule
--    sequence degrades to a silent no-op (never throws).
--  * API-SAFE CALLBACK (research §5): the `vim.defer_fn` callback runs on the nvim MAIN
--    LOOP (vim.defer_fn internally `vim.schedule`s the fn). So do_refresh may call
--    `nvim_buf_get_lines` / `nvim_win_get_cursor` / `bridge.request` DIRECTLY — NO extra
--    `vim.schedule` wrapper needed (it still works with one, but adds a needless hop).
--    This is UNLIKE a raw `uv.new_timer()` fast-context callback (where `vim.api.*`
--    throws E5560). The bridge's OWN cb is ALSO pre-`schedule_wrap`d (S26), so
--    on_result is api-safe too.
--
--  * TWO-LAYER SUPERSESSION (LIVE-VERIFIED best practice from nvim-cmp + blink.cmp,
--    research/nvim-completion-debounce-supersession.md §2). NEITHER plugin relies on
--    cancel alone:
--      Layer 1 (optimization): `bridge.cancel(state.inflight_id)` when a newer refresh
--        fires while a request is in-flight (frees the socket round-trip + drains the
--        server's AbortController promptly).
--      Layer 2 (CORRECTNESS boundary): a generation-id guard in the callback —
--        `if gen ~= state.gen then return end`. cancel can RACE (the cb is
--        `schedule_wrap`d; a response can land between cancel and the new request); the
--        id guard CANNOT. Do BOTH. (bridge.lua's header EXPLICITLY delegates supersession
--        to the caller: "tracks its latest id and ignores stale cbs OR calls cancel(old_id)".)
--  * ERROR/CANCELLED/TIMEOUT → TOUCH NOTHING (research §3, the nvim-cmp + blink idiom).
--    On `cb("cancelled"/"timeout"/<err>)`, return early WITHOUT clearing `last_result`
--    and WITHOUT calling `on_results`. Menu clearing is a SEPARATE signal
--    (InsertLeave / S37 / cursor-left-keyword), NOT a failed fetch. Clearing on a failed
--    fetch causes flicker (the blink.cmp `async_initial_items` "flash of no items" trap).
--  * NULL RESULT → EMPTY (research §3): a `getSuggestions` no-matches response resolves
--    `cb(nil, nil)` — SUCCESS with empty items, NOT an error. Normalize to
--    `{items={}, prefix=""}`, store, and fire `on_results(buf, {}, "")`.
--
--  * BRIDGE READ FRESH AT CALL TIME: `local bridge = require("pi-editor").bridge` INSIDE
--    do_refresh, NOT a module-load `local bridge = require("pi-editor").bridge`. The
--    handshake resolves ASYNC after activation — at first-require time `pi.bridge` is
--    still nil; tests must be able to swap in a fake bridge after `require`. Caching
--    breaks both.
--  * `state.gen` vs `state.inflight_id` — NAMED DISTINCTLY so a reader does not confuse
--    them: `gen` is completion's OWN monotonic int supersession guard (captured in the
--    cb closure); `inflight_id` is the STRING id `bridge.request` returned (for
--    `bridge.cancel`). (bridge ids are `tostring(next_id)` numeric strings; gen is a
--    Lua int.)
--
--  * PI-FAITHFUL "ASK ON EVERY CHANGE" MODEL (PRD §7.4): "the simplest correct approach
--    is to ask the provider on every change and let IT decide." So refresh re-fetches on
--    TextChangedI AND CursorMovedI (pi's provider returns `null` when the cursor is not
--    in a completable position); the ~25 ms debounce naturally collapses the
--    TextChangedI+CursorMovedI pair a single keystroke emits into ONE fetch. NO
--    CursorMovedI special-case (it would diverge from pi's TUI; nvim-cmp's re-filter-only
--    CursorMovedI handling is a source-level optimization that does not apply to a
--    single central provider).
--
--  * FORWARD CONTRACTS (do NOT implement in S30; just expose the seams):
--      M.on_results   → S31 (menu population) registers it; fires on the latest success.
--      M.current()    → S32 (accept) / S33 (Tab) read the latest items without menu coupling.
--      M.reset()      → S37 (auto-close on InsertLeave/CursorMoved-out) calls it for teardown.
--    S30 implements `refresh` ONLY. The 6 keymaps (on_tab/on_enter/on_next/on_prev/
--    on_dismiss) stay absent — the ftplugin's `dispatch` returns false → feedkey
--    fall-through (Tab indents, CR inserts a newline). CORRECT for S30's scope.
--
-- Node builtins analog: pure Lua + the COMPLETE in-tree bridge (`require("pi-editor").bridge`)
-- + coords (`require("pi-editor.coords")`) + config (`require("pi-editor")`). No sockets
-- of its own — the smoke's fake luv server is the integration surface. Singleton state
-- (mirrors bridge.lua's `state` shape, NOT coords.lua's stateless shape — completion HAS
-- state). One pi-prompt buffer per session (PRD §11); reset() clears state for tests +
-- the future S37 wiring.

local M = {}

--- A pi completion item (mirror of the extension's AutocompleteItem; the bridge delivers
--- these as the `result.items` array of a successful `getSuggestions`). Opaque to S30 —
--- S30 only stores + forwards the array; S31 renders it, S32 applies it. Fields typed
--- loosely here (the exact shape is the extension's protocol; S30 is shape-agnostic).
---@class pi-editor.AutocompleteItem
---@field value string The text to insert on accept (the canonical value).
---@field label string Human-readable label shown in the menu.
---@field [string] any Extra fields the extension includes (e.g. detail, kind, filterText).

--- Singleton completion state. One pi-prompt buffer per session (PRD §11). Cleared by
--- `reset()`. Mirrors `bridge.lua`'s `state` shape (completion HAS state).
---@class pi-editor.CompletionState
---@field buf            integer?    The pi-prompt buffer handle refresh() is debouncing for.
---@field debounce_timer userdata?   The `vim.defer_fn` handle (tracked for stop+close — NEVER stop-only; leaks).
---@field gen            integer     Monotonic supersession guard (bumped per fetch; captured in the cb closure).
---@field inflight_id    string?     The `bridge.request` id string of the current in-flight getSuggestions (for `bridge.cancel`).
---@field last_result    {items:pi-editor.AutocompleteItem[], prefix:string}? Latest non-stale {items,prefix} (for current()/S32/S33).
---@type pi-editor.CompletionState
local state = {
  buf = nil,
  debounce_timer = nil,
  gen = 0,
  inflight_id = nil,
  last_result = nil,
}

-- ===========================================================================
-- Internals (forward declaration; defined below)
-- ===========================================================================
local do_refresh -- (buf) — the debounced body (runs inside the api-safe vim.defer_fn cb).

--- The result→menu seam (forward contract for S31). Set by S31 to receive the latest
--- non-stale `{items, prefix}`: `function(buf, items, prefix)`. `nil` today → no-op
--- (silent). Mirrors `bridge.lua`'s `M.on_notification` slot pattern. Called on the
--- nvim main loop (api-safe — the bridge's cb is `schedule_wrap`d, so on_result is too).
--- NOT called for stale / error / cancelled results (the two-layer supersession + the
--- error→touch-nothing idiom guarantee that). Last-wins re-registration (a Lua table set).
---@type fun(buf:integer, items:pi-editor.AutocompleteItem[], prefix:string)|nil
M.on_results = nil

--- Resolve the debounce ms from config (self-sufficient if setup() was never called —
--- mirrors bridge.lua's `((cfg.config or cfg.defaults) or {}).rpc_timeout_ms or 2000`).
---@return integer ms The debounce window (default 25).
local function debounce_ms()
  local cfg = require("pi-editor")
  local ms = ((cfg.config or cfg.defaults) or {}).debounce_ms
  if type(ms) ~= "number" or ms < 0 then return 25 end
  return ms
end

--- Cancel + free the debounce timer (stop+close — the LIVE-VERIFIED leak fix). A fired
--- timer has already auto-closed (research §4); the `is_closing()` guard + `pcall` defend
--- the "already closing" throw so a fired-then-reschedule sequence is a silent no-op.
--- Never throws.
local function cancel_timer()
  pcall(function()
    if state.debounce_timer and not state.debounce_timer:is_closing() then
      state.debounce_timer:stop()
      state.debounce_timer:close()
    end
  end)
end

-- ===========================================================================
-- do_refresh(buf) — the debounced body (runs inside the api-safe vim.defer_fn cb).
-- Read buffer + convert to pi coords (S29) + supersede (BOTH layers) + issue RPC.
-- ===========================================================================
do_refresh = function(buf)
  -- GUARD: buf validity (a wipe during the debounce) + still-current (a switch during
  -- the 25ms window — the cursor is for the current window; if buf isn't current the
  -- read is wrong; silent no-op, not a fetch on stale state).
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  if buf ~= vim.api.nvim_get_current_buf() then return end
  -- READ BRIDGE FRESH (handshake resolves async + test mocks swap in after require).
  local pi_mod = require("pi-editor")
  local bridge = pi_mod.bridge
  if not bridge
     or type(bridge.is_connected) ~= "function"
     or not bridge.is_connected() then
    return -- silent degrade (S39's job to notify once); never throw
  end
  -- READ buffer lines + cursor (api-safe — research §5; NO vim.schedule needed).
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok or type(lines) ~= "table" then return end
  local cur
  ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok or type(cur) ~= "table" then return end
  local row, byte_col = cur[1], cur[2]
  -- CONVERT (S29 — THE centralized seam; the ONLY ±1 is the row). `pi.lines` is the SAME
  -- reference as `lines`, so the result drops straight into the RPC params.
  local pi = require("pi-editor.coords").nvim_to_pi_coords(lines, row, byte_col)
  -- SUPERSEDE layer 1 (cancel prev in-flight — optimization; frees the round-trip).
  if state.inflight_id and type(bridge.cancel) == "function" then
    pcall(bridge.cancel, state.inflight_id)
  end
  state.inflight_id = nil
  -- SUPERSEDE layer 2 (gen-guard — the CORRECTNESS boundary; captured in the cb closure).
  state.gen = state.gen + 1
  local gen = state.gen
  local params = vim.tbl_extend("keep", pi, { force = false }) -- {lines,cursorLine,cursorCol,force=false}
  -- ISSUE (pcall so a bridge bug never aborts the autocmd chain). `id` may be nil if the
  -- bridge raced to disconnected (no inflight to track — the gen-guard still drops a late cb).
  local id
  ok, id = pcall(bridge.request, "getSuggestions", params, function(err, result)
    if gen ~= state.gen then return end                 -- STALE (superseded) — drop, touch nothing
    state.inflight_id = nil
    if err then return end                              -- cancelled/timeout/error → touch nothing
    -- NORMALIZE: null result (cb(nil,nil)) = SUCCESS with empty items, NOT an error.
    local items  = (result and type(result.items)  == "table")  and result.items  or {}
    local prefix = (result and type(result.prefix) == "string") and result.prefix or ""
    state.last_result = { items = items, prefix = prefix }
    -- S31 seam (api-safe; nil today → no-op). Fires ONLY for the latest non-stale success.
    if type(M.on_results) == "function" then
      pcall(M.on_results, buf, items, prefix)
    end
  end)
  if ok and type(id) == "string" then state.inflight_id = id end
end

-- ===========================================================================
-- Public API
-- ===========================================================================

--- The autocmd entry point (InsertEnter/TextChangedI/CursorMovedI; wired buffer-local
--- by the ftplugin S22 via its no-op-safe `dispatch`). Fire-and-forget (the autocmd
--- callback ignores the return value). Debounces: cancels any pending debounce timer
--- (`stop()`+`close()` — the LIVE-VERIFIED leak fix; NEVER `stop()`-only), schedules
--- `do_refresh(buf)` after `config.debounce_ms` (default 25). Re-fetches on EVERY change
--- (pi-faithful — PRD §7.4; the provider returns null when not completable; the debounce
--- collapses a TextChangedI+CursorMovedI pair into one fetch). Never throws; silent
--- degrade if the bridge is absent/disconnected (checked in `do_refresh`).
---
---@param buf integer The pi-prompt buffer handle (from the autocmd; NOT 0).
function M.refresh(buf)
  if type(buf) ~= "number" then return end -- never-throws (per-keystroke + autocmd contract)
  state.buf = buf
  cancel_timer()                           -- stop+close the prior pending defer (leak fix)
  -- SCHEDULE (the cb is api-safe — main loop; research §5; NO vim.schedule needed).
  state.debounce_timer = vim.defer_fn(function() do_refresh(buf) end, debounce_ms())
end

--- Teardown: cancel the debounce timer (`stop()`+`close()`) + any in-flight request;
--- clear `last_result`; reset the generation counter. Idempotent + never throws
--- (pcall-wrapped; safe to call when never activated — mirrors `bridge.on_exit`).
--- The cleanup seam for tests + the future S37 InsertLeave/CursorMoved-out wiring (S30
--- does NOT modify the ftplugin; `reset()` is called by S37 once it lands).
function M.reset()
  cancel_timer()
  local b = require("pi-editor").bridge
  if state.inflight_id and b and type(b.cancel) == "function" then
    pcall(b.cancel, state.inflight_id)
  end
  state.debounce_timer = nil
  state.inflight_id    = nil
  state.last_result    = nil
  state.gen            = 0
  state.buf            = nil
end

--- Read-only accessor: the latest non-stale `{items, prefix}`, or `nil`. For S32 accept /
--- S33 Tab to read the current items WITHOUT coupling to the menu. Returns a SHALLOW copy
--- (the caller may not mutate `state.last_result`).
---
---@return {items:pi-editor.AutocompleteItem[], prefix:string}? result The latest result, or nil.
function M.current()
  local r = state.last_result
  if not r then return nil end
  return { items = r.items, prefix = r.prefix }
end

return M