--- menu.lua — the windowless menu-STATE module (parent P2.M7.T18) + the S30
-- `completion.on_results` seam consumer (the data-consumption half of completion).
--
-- Owns EXACTLY the result→menu-state pipeline that S30's `on_results(buf, items, prefix)`
-- drives:
--   activate() (S21, COMPLETE + this task's 2-line wiring)
--     → menu.attach()                              (sets completion.on_results = M.on_results)
--   completion.refresh(buf) (S30, COMPLETE)
--     → debounce → fetch → supersede (two-layer) → on the latest non-stale success:
--       M.on_results(buf, items, prefix)          (the seam this module registers)
--     → empty items  → M.close()                  (clear state; blink list.show's hide path)
--     → non-empty    → store buf/prefix + M.open(items)  (selected=1, open=true; blink's show path)
--
-- This is the DATA-CONSUMPTION half of completion. The floating WINDOW is S34 (Planned);
-- S31 owns the STATE layer underneath it + a LOCAL no-op `render(state)` seam that S34
-- implements (nvim_create_buf + nvim_open_win). Until S34 lands there is no popup, but
-- the `completion → menu` data path is live and testable via STATE assertions.
--
-- [Mode A] header — read before editing:
--  * ROLE: the windowless menu-STATE consumer of S30's `on_results` seam. Model on
--    blink.cmp's `completion/list.lua` (a pure-Lua windowless singleton with
--    `items`/`selected_item_idx`/`context` fields + a `show()` that routes empty→hide /
--    non-empty→store+show + an `accept()` that reads selection DIRECTLY from state —
--    ZERO window coupling). nvim-cmp FUSES state+window in `custom_entries_view.lua` —
--    the ANTI-PATTERN; do NOT copy cmp. (research/notes.md §2/§5.)
--  * STATE ≠ WINDOW (the blink split): `open()`/`close()` manage STATE ONLY
--    (`items`/`selected`/`open`) + call a LOCAL no-op `render(state)` stub. menu.lua
--    makes ZERO `nvim_open_win`/`nvim_create_buf`/`nvim_buf_set_lines` calls. S34
--    implements `render()`; S35 enhances it (two-column); S36's `next`/`prev`/`dismiss`
--    set `selected` + call `render()`; S37's auto-close calls `close()`/`reset()`.
--
--  * NO REDUNDANT STALENESS GUARD (research §4, LIVE-VERIFIED in blink + cmp): S30's
--    two-layer supersession (cancel + generation-id guard) ALREADY guarantees
--    `on_results` fires ONLY for the latest non-stale success whose params matched the
--    buffer at issue time. NEITHER blink nor cmp re-guards staleness inside the menu:
--    blink guards ONCE at the source→consumer seam (`event.context.id ~=
--    trigger.context.id` in `completion/init.lua`), then `list.show` TRUSTS it; cmp
--    guards ONCE in `source.lua` (`if self.context ~= ctx then return end`), then the
--    view pulls fresh. Re-deriving staleness in the consumer by re-querying
--    `nvim_win_get_cursor`/`nvim_buf_get_lines` is a FALSE-NEGATIVE RACE (the buffer
--    may legitimately advance past the request position for a VALID latest result).
--    So `on_results` routes on the PAYLOAD ONLY (`buf`/`items`/`prefix` are cb args) +
--    an `nvim_buf_is_valid(buf)` WIPE guard (a buffer wiped during the 25ms debounce).
--  * S30 ALREADY NORMALIZES null: the S30 do_refresh cb normalizes a null `getSuggestions`
--    result to `{items={}, prefix=""}` BEFORE firing `on_results`. So `on_results`
--    ALWAYS receives a valid `items` array (possibly empty) + a string `prefix`. Do NOT
--    handle `result==vim.NIL`/nil result here (that's the bridge's job, DONE S26); the
--    `type(items)=="table"`/`type(prefix)=="string"` checks below are DEFENSIVE only.
--
--  * LAST-WINS OVERWRITE for the single `on_results` slot, NOT save-and-restore-a-list.
--    cmp's single-callback seams (`source:complete(ctx, callback)`) are a bare closure
--    overwrite; multi-listener `table.insert` is only for pub/sub emitters (multiple
--    consumers). S31's `on_results` is a single forward contract →
--    `completion.on_results = M.on_results`. Idempotent via the module `attached` flag
--    (a 2nd `attach()` is a no-op — does NOT re-save `prev_on_results`). `detach()`
--    restores the prior `on_results` saved at the FIRST attach (or nil). (research §3.)
--  * NO schedule_wrap ON on_results: S30 fires `on_results` on the nvim MAIN LOOP (the
--    bridge cb is `schedule_wrap`d S26; completion's cb runs via `vim.defer_fn` = main
--    loop). Storing a RAW fn (not wrapped) is correct + avoids a needless hop. (This
--    DIFFERS from `bridge.lua`'s `on_notification`, which DOES wrap — because its
--    dispatch runs inline from the luv `read_start` cb. Different contexts.)
--
--  * open(items) SIGNATURE IS ITEMS-ONLY (matches the S34 contract: tasks.json
--    P2.M8.T21.S34 "Implement M.open(items): … track selected index"). `buf`+`prefix`
--    are stored by the `on_results` handler BEFORE calling `open(items)`, via
--    `state.buf`/`state.prefix`. Accept (S32) reads them via `get_buf()`/`get_prefix()`
--    + `get_selected()`. Do NOT change `open()` to `open(buf, items, prefix)` — it
--    would collide with S34.
--  * selected = 1 after open() (1-INDEXED). Matches the S36 next/prev wraparound
--    arithmetic (`selected = (selected % #items) + 1` for next; the reverse for prev)
--    + `get_selected()` returning `items[selected]`. `close()` resets `selected` to 0.
--
--  * render IS A LOCAL NO-OP STUB (NOT a public `M._render` override). `open()`/`close()`
--    call `render(state)`. S34 will EDIT menu.lua to implement it (`nvim_create_buf` +
--    `nvim_open_win` + `nvim_buf_set_lines`); S35 enhances it; S36's next/prev/dismiss
--    set `selected` + call `render()`; S37's auto-close calls `close()`/`reset()`.
--    Keeping `render` a LOCAL fn (not `M._render`) keeps the public surface minimal +
--    signals "S34 owns this" clearly.
--
--  * READ completion FRESH at call time inside attach()/detach():
--    `require("pi-editor.completion")`. (Same codebase rule as S30's bridge-read-fresh —
--    the handshake resolves async + tests swap fakes after require + a /reload re-runs
--    activate().) Do NOT cache completion at module load.
--
--  * NEVER THROWS (per-keystroke + autocmd contract): attach/detach/on_results/open/
--    close/reset/get_* are all pcall-safe by construction (type-guards +
--    nvim_buf_is_valid). A missing/disconnected bridge = silent degrade (S30's refresh
--    bails when `pi.bridge` is nil → on_results never fires). A programming error in
--    the menu must not abort the autocmd chain.
--
--  * FORWARD CONTRACTS (do NOT implement in S31; just expose the state + accessors):
--      M.get_selected()  → S32 (accept) reads it WITHOUT coupling to the window.
--      M.get_items()     → S34 (rendering) reads the items array (shallow copy).
--      render(state)     → S34 (window) implements the LOCAL no-op stub.
--      M.next/prev/dismiss → S36 (navigation) set `selected` + call `render()`.
--      M.reset()/close() → S37 (auto-close on InsertLeave/CursorMoved-out) calls them.
--    S31 implements attach/detach/on_results/open/close/get_*/reset ONLY. NO accept
--    (S32), NO Tab-force (S33), NO window (S34), NO navigation (S36), NO auto-close (S37).
--
-- Node builtins analog: pure Lua + the COMPLETE in-tree completion seam
-- (`require("pi-editor.completion")`). No sockets of its own — the smoke's fake luv
-- server is the integration surface (via the bridge + completion). Singleton state
-- (mirrors `bridge.lua`/`completion.lua`'s `state` shape, NOT `coords.lua`'s stateless
-- shape — menu HAS state). One pi-prompt buffer per session (PRD §11); `reset()` clears
-- state for tests + the future S37 wiring.

local M = {}

--- A pi completion item (mirror of the extension's AutocompleteItem; the bridge delivers
--- these as the `result.items` array of a successful `getSuggestions` — passed through
--- S30's `on_results`). Opaque to S31 — S31 stores + forwards the array; S34 renders it,
--- S32 applies it. Fields typed loosely (the exact shape is the extension's protocol; S31
--- is shape-agnostic — same as S30's note).
---@class pi-editor.AutocompleteItem
---@field value string The text to insert on accept (the canonical value).
---@field label string Human-readable label shown in the menu.
---@field [string] any Extra fields the extension includes (e.g. description, kind, filterText).

--- Singleton menu-state (the blink.cmp `list.lua` model — a windowless pure-Lua
--- singleton). One pi-prompt buffer per session (PRD §11). Cleared by `reset()`. Mirrors
--- `bridge.lua`/`completion.lua`'s `state` shape (menu HAS state). The floating WINDOW
--- (`win`/`menu_buf` handles) are FORWARD-CONTRACT fields left nil until S34 implements
--- `render()`.
---@class pi-editor.MenuState
---@field attached        boolean                     Whether `completion.on_results` is wired to M.on_results.
---@field prev_on_results fun|nil                     The on_results saved at the FIRST attach (restored by detach).
---@field buf             integer|nil                 The pi-prompt buffer handle of the latest on_results (for get_buf/S32).
---@field items           pi-editor.AutocompleteItem[] The latest items array (1-indexed; {} when closed).
---@field prefix          string                      The latest prefix (for get_prefix/S32 applyCompletion).
---@field selected        integer                     1-indexed selected row; 1 after open(), 0 when closed/empty.
---@field open            boolean                     Whether the menu is showing (true after open() with items).
---@field win             integer|nil                 FORWARD CONTRACT (S34): the floating window handle. nil until S34.
---@field menu_buf        integer|nil                 FORWARD CONTRACT (S34): the scratch buffer handle. nil until S34.
---@type pi-editor.MenuState
local state = {
  attached = false,
  prev_on_results = nil,
  buf = nil,
  items = {},
  prefix = "",
  selected = 0,
  open = false,
  win = nil,
  menu_buf = nil,
}

-- ===========================================================================
-- The LOCAL no-op render(state) seam — the S34 DI hook.
-- S34 will EDIT this to create/draw the floating window (nvim_create_buf + nvim_open_win
-- + nvim_buf_set_lines). S35 enhances it to two-column rendering. S36's next/prev/dismiss
-- set `selected` then call render(state). S31: a pure no-op (state-only module). The
-- leading-underscore param signals "unused in S31"; S34/S35 read it.
-- ===========================================================================
local render = function(_state) end -- S34 implements; S31 no-op.

-- ===========================================================================
-- Public API
-- ===========================================================================

--- The S30→S31 seam consumer. Set onto `completion.on_results` by `attach()`. Routes the
--- latest non-stale `{items, prefix}`: empty → `close()`; non-empty → store context +
--- `open(items)`. TRUSTS S30's two-layer supersession (NO redundant staleness guard —
--- research/notes.md §4; re-querying cursor/lines is a false-negative race). Called on
--- the nvim main loop (api-safe — S30 fires it inline from its `vim.defer_fn` cb, whose
--- bridge cb is itself `schedule_wrap`d). Never throws.
---@param buf    integer                      The pi-prompt buffer handle (from S30's on_results).
---@param items  pi-editor.AutocompleteItem[] The completion items (possibly empty — S30 normalized null→{}).
---@param prefix string                       The completion prefix (for get_prefix/S32).
function M.on_results(buf, items, prefix)
  -- WIPE guard (the ONLY nvim-state read here — NOT a staleness re-derive): a buffer may
  -- be wiped during the 25ms debounce. Silent no-op, never throw.
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  state.buf = buf
  state.prefix = (type(prefix) == "string") and prefix or "" -- defensive (S30 sends a string)
  items = (type(items) == "table") and items or {}           -- defensive (S30 sends a valid array)
  -- THE routing (blink list.show: empty→hide / non-empty→store+show).
  if #items == 0 then M.close() else M.open(items) end
end

--- Idempotently register `M.on_results` on `require("pi-editor.completion").on_results`
--- (last-wins overwrite — the cmp single-callback-seam pattern). Guarded by
--- `state.attached` so a 2nd `attach()` (e.g. a /reload re-running `activate()`) is a
--- no-op (does NOT re-save `prev_on_results`). Never throws; silent degrade if
--- `completion` is absent. Safe to call BEFORE the bridge connects — `completion.refresh`
--- degrades silently when `pi.bridge` is nil (no fetch → no `on_results`).
function M.attach()
  if state.attached then return end                                  -- idempotent (no stack on /reload)
  local ok, comp = pcall(require, "pi-editor.completion")            -- READ FRESH (handshake async + test mocks)
  if not ok or type(comp) ~= "table" then return end                 -- never throws (completion absent)
  state.prev_on_results = comp.on_results                            -- save prior (nil-safe; restored by detach)
  comp.on_results = M.on_results                                     -- last-wins overwrite
  state.attached = true
end

--- Restore the prior `completion.on_results` (saved at the FIRST attach, or nil); set
--- `attached=false`. Never throws; no-op if never attached.
function M.detach()
  if not state.attached then return end
  local ok, comp = pcall(require, "pi-editor.completion")
  if ok and type(comp) == "table" then comp.on_results = state.prev_on_results end -- restore prior (or nil)
  state.prev_on_results = nil
  state.attached = false
end

--- Store items + set `selected=1` + `open=true`; call `render(state)`. The STATE half of
--- S34's `M.open(items)` — S34 ADDS the floating window inside `render()`. Signature is
--- items-only (matches the S34 contract; `buf`+`prefix` are stored by `on_results`).
---@param items pi-editor.AutocompleteItem[] The items to display (non-empty — on_results guards empty→close).
function M.open(items)
  items = (type(items) == "table") and items or {}  -- defensive (on_results guards; direct callers may not)
  state.items = items
  state.selected = (items[1] ~= nil) and 1 or 0     -- 1 after open with items (1-indexed; S36 wraparound); 0 if empty
  state.open = (#items > 0)                         -- open ONLY if items (defensive)
  render(state)                                     -- S34 hook: create/draw the floating window. S31: no-op.
end

--- Clear items + `selected=0` + `open=false`; call `render(state)`. The STATE half of
--- S34's close — S34 ADDS `nvim_win_close` inside `render()`.
function M.close()
  state.items = {}
  state.selected = 0
  state.open = false
  render(state)                                     -- S34 hook: close the floating window. S31: no-op.
end

--- The selected item (`items[selected]`), or `nil`. For S32 accept to read WITHOUT
--- coupling to the window (blink `list.accept` reads state, not the popup).
---@return pi-editor.AutocompleteItem|nil
function M.get_selected()
  return state.items[state.selected]                -- nil when closed (selected==0)
end

--- Shallow copy of items (the caller may not mutate `state.items`). The item tables
--- themselves are shared (fine — S32 reads `item.value`, S34 reads `item.label`/`description`).
---@return pi-editor.AutocompleteItem[]
function M.get_items()
  local copy = {}
  for i = 1, #state.items do copy[i] = state.items[i] end
  return copy
end

--- The latest prefix (for S32 applyCompletion's `prefix` param).
---@return string
function M.get_prefix()
  return state.prefix
end

--- The latest pi-prompt buffer handle (for S32 to read lines/convert coords).
---@return integer|nil
function M.get_buf()
  return state.buf
end

--- Whether the menu is showing (`open==true`). For S36/S37/the ftplugin keymap dispatch.
---@return boolean
function M.is_open()
  return state.open == true                         -- only true after open() with items
end

--- Whether there are items to show (`#items > 0`). For S33 Tab-force / S32 accept gating.
---@return boolean
function M.has_items()
  return #state.items > 0
end

--- Teardown: `close()` + `detach()` (if attached); clear `buf`/`prefix` + forward-contract
--- `win`/`menu_buf`. Idempotent + never throws. The cleanup seam for tests + the future
--- S37 InsertLeave/CursorMoved-out wiring. Mirrors `completion.reset()`/`bridge.close()`.
function M.reset()
  M.close()                               -- clears items/selected/open (+ no-op render)
  if state.attached then M.detach() end   -- restore prior on_results
  state.buf = nil                         -- full teardown for tests + S37
  state.prefix = ""
  state.win = nil                         -- forward-contract hygiene
  state.menu_buf = nil
end

return M