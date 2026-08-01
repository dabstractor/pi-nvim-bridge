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
-- This is the DATA-CONSUMPTION half of completion. The floating WINDOW is S34 (COMPLETE):
-- S34 implemented the LOCAL `render(state)` seam — a scratch buffer + nvim_open_win /
-- nvim_win_set_config + cursor-relative positioning + edge clamping (the pure
-- `compute_geometry` — research/notes.md §3 / positioning-math.md's verified 7-case
-- table). S35 (COMPLETE) enhanced `render()` to a TWO-COLUMN layout (label + gap +
-- description, ellipsis-truncated) + 3-layer highlights (base `Pmenu` + desc `Comment` +
-- selected-row `PmenuSel`, applied LAST-WINS — neovim#8449; research/notes.md §2/§3 +
-- highlight-layering.md §1/§2). S36 (COMPLETE) added the navigation mutators
-- `M.next`/`M.prev`/`M.dismiss` (bump `state.selected` 1-based wraparound then call the
-- LOCAL `render(state)` — research/notes.md §1/§2/§3); S37's auto-close calls
-- open()/close()/reset(). The `completion → menu` data path drives a visible popup
-- showing pi's live AutocompleteItems.
--
-- [Mode A] header — read before editing:
--  * ROLE: the windowless menu-STATE consumer of S30's `on_results` seam. Model on
--    blink.cmp's `completion/list.lua` (a pure-Lua windowless singleton with
--    `items`/`selected_item_idx`/`context` fields + a `show()` that routes empty→hide /
--    non-empty→store+show + an `accept()` that reads selection DIRECTLY from state —
--    ZERO window coupling). nvim-cmp FUSES state+window in `custom_entries_view.lua` —
--    the ANTI-PATTERN; do NOT copy cmp. (research/notes.md §2/§5.)
--  * STATE ≠ WINDOW (the blink split): `open()`/`close()` manage STATE ONLY
--    (`items`/`selected`/`open`) + call a LOCAL `render(state)` (S34 IMPLEMENTED it —
--    the floating-window show/hide lifecycle). menu.lua now makes
--    `nvim_open_win`/`nvim_create_buf`/`nvim_buf_set_lines`/`nvim_win_set_config` calls
--    INSIDE `render()`. S35 enhances `render()` (two-column); S36's `next`/`prev`/`dismiss`
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
--    an `nvim_buf_is_valid(buf)` WIPE guard (a buffer wiped during the 20ms debounce).
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
--  * render IS A LOCAL FN (S34 IMPLEMENTED IT). `open()`/`close()` call `render(state)`.
--    S34 implemented the show/hide window lifecycle (nvim_create_buf + nvim_open_win +
--    nvim_buf_set_lines + nvim_win_set_config + nvim_win_close); S35 enhances it
--    (two-column); S36's next/prev/dismiss set `selected` + call `render()`; S37's
--    auto-close calls `close()`/`reset()`. Keeping `render` a LOCAL fn (not `M._render`)
--    keeps the public surface minimal + signals "S34 owns this" clearly.
--
--  * READ completion FRESH at call time inside attach()/detach():
--    `require("pi-bridge.completion")`. (Same codebase rule as S30's bridge-read-fresh —
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
--      render(state)     → S34 (window) IMPLEMENTED (show/hide floating window).
--      M.next/prev/dismiss → S36 (navigation) IMPLEMENTED: bump `selected` + call `render()`.
--      M.reset()/close() → S37 (auto-close on InsertLeave/CursorMoved-out) calls them.
--    S31 implements attach/detach/on_results/open/close/get_*/reset ONLY. NO accept
--    (S32), NO Tab-force (S33), NO window (S34), NO auto-close (S37). S36 is COMPLETE.
--
-- Node builtins analog: pure Lua + the COMPLETE in-tree completion seam
-- (`require("pi-bridge.completion")`). No sockets of its own — the smoke's fake luv
-- server is the integration surface (via the bridge + completion). Singleton state
-- (mirrors `bridge.lua`/`completion.lua`'s `state` shape, NOT `coords.lua`'s stateless
-- shape — menu HAS state). One pi-prompt buffer per session (PRD §11); `reset()` clears
-- state for tests + the future S37 wiring.

local M = {}

-- [TEMP DEBUG] trace completion flow to /tmp/pi-bridge-menu-debug.log (always-on; remove after diagnosing).
local function dbg(msg)
  pcall(function()
    local f = io.open("/tmp/pi-bridge-menu-debug.log", "a")
    if f then f:write(tostring(msg) .. "\n"); f:close() end
  end)
end

--- A pi completion item (mirror of the extension's AutocompleteItem; the bridge delivers
--- these as the `result.items` array of a successful `getSuggestions` — passed through
--- S30's `on_results`). Opaque to S31 — S31 stores + forwards the array; S34 renders it,
--- S32 applies it. Fields typed loosely (the exact shape is the extension's protocol; S31
--- is shape-agnostic — same as S30's note).
---@class pi-bridge.AutocompleteItem
---@field value string The text to insert on accept (the canonical value).
---@field label string Human-readable label shown in the menu.
---@field [string] any Extra fields the extension includes (e.g. description, kind, filterText).

--- Singleton menu-state (the blink.cmp `list.lua` model — a windowless pure-Lua
--- singleton). One pi-prompt buffer per session (PRD §11). Cleared by `reset()`. Mirrors
--- `bridge.lua`/`completion.lua`'s `state` shape (menu HAS state). The floating WINDOW
--- (`win`/`menu_buf` handles) are S34-owned fields (nil until open() runs render).
---@class pi-bridge.MenuState
---@field attached        boolean                     Whether `completion.on_results` is wired to M.on_results.
---@field prev_on_results fun|nil                     The on_results saved at the FIRST attach (restored by detach).
---@field buf             integer|nil                 The pi-prompt buffer handle of the latest on_results (for get_buf/S32).
---@field items           pi-bridge.AutocompleteItem[] The latest items array (1-indexed; {} when closed).
---@field prefix          string                      The latest prefix (for get_prefix/S32 applyCompletion).
---@field selected        integer                     1-indexed selected row; 1 after open(), 0 when closed/empty.
---@field open            boolean                     Whether the menu is showing (true after open() with items).
---@field win             integer|nil                 S34: the floating window handle (set by render; nil when closed).
---@field menu_buf        integer|nil                 S34: the scratch buffer handle (lazy create; reused across opens; nil'd by reset()).
---@field context         string|nil                   S5: the completion context ("shell"|"slash"|"path"|nil) set by on_results. "shell" renders the visual cue.
---@type pi-bridge.MenuState
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
  context = nil, -- S5: shell context → renders the $ gutter (or border) visual cue
}

-- ===========================================================================
-- S35: highlight namespace (cached ONCE — live-verified nvim_create_namespace returns
-- a stable numeric id — research/notes.md §2 / highlight-layering.md §1) + the
-- inter-column gap constant (PRD §10.5 lists no config option for it; module-local
-- constant in v1). Used by apply_highlights + render_lines/compute_width.
-- ===========================================================================
local DESC_GAP = 2
local ns = nil
do
  local ok, id = pcall(vim.api.nvim_create_namespace, "pi-bridge-menu")
  if ok and type(id) == "number" then ns = id end -- nil on failure (apply_highlights degrades)
end

-- ===========================================================================
-- S5: shell-context visual cue (PRD §17.9). When completion_context == "shell", every
-- menu line is prefixed with a `$ ` gutter (2 display cells) — mirroring pi's TUI
-- isBashMode border recolor. Alternative cues ("border"/"off") are read fresh in
-- render() from config.shell.visual_cue. The default hl groups (PiBridgeShellGutter /
-- PiBridgeShellBorder) are defined LAZILY with default=true so user themes win.
-- ===========================================================================
local GUTTER = "$ "   -- the 2-cell prefix prepended to each shell-context line
local GUTTER_W = 2    -- vim.fn.strdisplaywidth(GUTTER) (ASCII; never CJK-skewed)

--- Define the two shell-cue default highlight groups ONCE (idempotent + default=true so
--- a user's :hi / theme wins; mirrors the standard nvim plugin form). pcall-wrapped
--- (never throws; :hi is api-safe on the main loop).
local function define_shell_hl()
  pcall(vim.api.nvim_set_hl, 0, "PiBridgeShellGutter", { link = "SpecialKey", default = true })
  pcall(vim.api.nvim_set_hl, 0, "PiBridgeShellBorder", { link = "WarningMsg", default = true })
end

-- ===========================================================================
-- S35: PURE helpers shared by compute_width + render — column_metrics (the max label
-- + max description display widths + whether any item has a description) and
-- _truncate (ellipsis truncation, CJK-correct via strdisplaywidth/strcharpart/strchars).
-- PURE (no nvim state writes; type-guarded; never throw). Exposed as
-- M._column_metrics / M._truncate (the M._compute_* / coords' fns test-seam convention).
-- ===========================================================================

--- Max label + max description display widths + whether any item has a description.
--- PURE (no nvim state). type-guards each item (never throws). Exposed as M._column_metrics.
---@param items pi-bridge.AutocompleteItem[]
---@return { max_label_w: integer, max_desc_w: integer, any_desc: boolean }
local function column_metrics(items)
  local max_label_w, max_desc_w, any_desc = 0, 0, false
  if type(items) ~= "table" then return { max_label_w = 0, max_desc_w = 0, any_desc = false } end
  for _, it in ipairs(items) do
    if type(it) == "table" then
      if type(it.label) == "string" then
        local lw = vim.fn.strdisplaywidth(it.label) -- CJK/double-width aware (NOT #s)
        if lw > max_label_w then max_label_w = lw end
      end
      if type(it.description) == "string" and it.description ~= "" then
        any_desc = true
        local dw = vim.fn.strdisplaywidth(it.description)
        if dw > max_desc_w then max_desc_w = dw end
      end
    end
  end
  return { max_label_w = max_label_w, max_desc_w = max_desc_w, any_desc = any_desc }
end

--- Truncate `text` to <= max_w DISPLAY cells, appending "…" when truncated.
--- PURE. "" when max_w <= 0; the first char alone when only 1 cell of room. Exposed as M._truncate.
---@param text string
---@param max_w integer max display width
---@return string
local function _truncate(text, max_w)
  if type(text) ~= "string" or type(max_w) ~= "number" or max_w <= 0 then return "" end
  if vim.fn.strdisplaywidth(text) <= max_w then return text end
  local ellipsis = "…"
  local budget = max_w - vim.fn.strdisplaywidth(ellipsis)
  if budget <= 0 then
    -- only 1 cell of room: show the first char alone (no ellipsis fits)
    return vim.fn.strcharpart(text, 0, 1)
  end
  local out, w = "", 0
  local n = vim.fn.strchars(text)
  for i = 0, n - 1 do
    local ch = vim.fn.strcharpart(text, i, 1)
    local cw = vim.fn.strdisplaywidth(ch)
    if w + cw > budget then break end
    out, w = out .. ch, w + cw
  end
  return out .. ellipsis
end

-- ===========================================================================
-- S34: PURE geometry helpers (no vim.fn.screenrow/col reads here — those live in
-- render). Module-level locals, exposed on M as M._compute_* for unit-testing (the
-- codebase convention — pure helpers are unit-tested, like coords_spec's byte_to_utf16).
-- The clamping algorithm + the 7-case verified table are from
-- plan/001_c56962b4fa17/P2M5T1S1/research/positioning-math.md (LIVE-VERIFIED prototype,
-- MENU_VERIFY_PASS 0) + research/notes.md §3. CJK-aware via strdisplaywidth (NOT #s).
-- S35 WIDENED compute_width to two-column (max_label_w + DESC_GAP + max_desc_w when
-- any item has a description; collapses to label-only max_label_w when none do — so
-- every S34 label-only case stays green).
-- ===========================================================================

--- Width = label-only (S34) OR label+gap+description (S35, when any item has a desc),
--- PLUS an optional S5 gutter prefix width (gutter_w, default 0). CJK-aware via
--- strdisplaywidth. Clamped to the available screen columns minus border horizontal
--- overhead.
---@param items pi-bridge.AutocompleteItem[] The items to size for.
---@param ui_cols integer Full-screen columns (vim.o.columns).
---@param border_h_overhead integer Horizontal border overhead in cells (2 for a real border, 0 for "none").
---@param gutter_w? integer S5: the shell-context gutter width (default 0 — no gutter).
---@return integer The content width, >= 1, clamped to fit the screen.
local function compute_width(items, ui_cols, border_h_overhead, gutter_w)
  local m = column_metrics(items)
  local w = m.any_desc and (m.max_label_w + DESC_GAP + m.max_desc_w) or m.max_label_w
  w = w + (gutter_w or 0) -- S5: grow by the gutter prefix width (0 by default — back-compatible)
  return math.max(1, math.min(w, ui_cols - border_h_overhead))
end

-- Height = min(#items, max_height); 0 when empty/invalid (render's show guard handles 0).
---@param n_items integer The item count.
---@param max_height integer The configured max visible rows.
---@return integer The content height (0 when no items).
local function compute_height(n_items, max_height)
  if type(n_items) ~= "number" or n_items <= 0 then return 0 end
  local mh = (type(max_height) == "number" and max_height > 0) and max_height or 12
  return math.min(math.floor(n_items), mh)
end

-- THE clamping algorithm. Returns {anchor,row,col,width,height} for nvim_open_win /
-- nvim_win_set_config. EXACT 7-case outputs in research/notes.md §3 / positioning-math.md
-- (border="rounded" ⇒ bv=2,bh=2). BELOW caret = anchor "NW",row 1; ABOVE = anchor "SW",
-- row 0. A NEGATIVE col shifts the window LEFT.
---@param screen_row integer Cursor screen row (1-based from top).
---@param screen_col integer Cursor screen col (1-based).
---@param ui_lines integer Full-screen rows (vim.o.lines).
---@param ui_cols integer Full-screen columns (vim.o.columns).
---@param width integer The (already-clamped) content width.
---@param height integer The (already-clamped) content height.
---@param max_height integer The configured max visible rows.
---@param border string|table The border config (anything non-nil/non-"none" ⇒ +2/+2 overhead).
---@return table {anchor,row,col,width,height} the resolved window geometry.
local function compute_geometry(screen_row, screen_col, ui_lines, ui_cols, width, height, max_height, border)
  local has_border = (border ~= nil) and (border ~= "none")
  local bv = has_border and 2 or 0 -- border vertical overhead (rows)
  local bh = has_border and 2 or 0 -- border horizontal overhead (cols)
  -- clamp height to max_height first (width already clamped by compute_width)
  height = math.min(height, max_height)
  -- VERTICAL: choose below (NW,row=1) vs above (SW,row=0), clamping to fit
  local reserve = 1                                   -- never paint over the cmdline
  local space_below = (ui_lines - reserve) - screen_row -- rows strictly below caret
  local space_above = screen_row - 1                   -- rows strictly above caret
  local need_h = height + bv
  local anchor, row
  if space_below >= need_h then
    anchor, row = "NW", 1
  elseif space_above >= need_h then
    anchor, row = "SW", 0
  elseif space_below >= space_above then
    anchor, row = "NW", 1
    height = math.max(1, space_below - bv)
  else
    anchor, row = "SW", 0
    height = math.max(1, space_above - bv)
  end
  -- HORIZONTAL: fit right of caret, else shift left (negative col), else pin left + clamp width
  local col
  local need_w = width + bh
  local from_cursor_right = ui_cols - (screen_col - 1)
  if need_w <= from_cursor_right then
    col = 0
  else
    col = from_cursor_right - need_w                    -- NEGATIVE => shift window left
    if col < -(screen_col - 1) then                      -- would spill past the LEFT edge
      col = -(screen_col - 1)
      width = math.max(1, ui_cols - bh)
    end
  end
  return { anchor = anchor, row = row, col = col, width = width, height = height }
end

-- ===========================================================================
-- S34: render(state) — create/show OR close the floating window.
-- Called by S31's open(items) and close() (on the nvim main loop via on_results —
-- api-safe). NEVER throws (pcall every nvim call; nvim_*_is_valid guards). Reads
-- config FRESH via require("pi-bridge") (handshake async + tests mock after require).
-- Lifecycle (blink-verified, research/notes.md §1): REUSE the scratch buffer across
-- open/close (don't delete on close — only reset() nils state.menu_buf); CLOSE the
-- window on hide + RECREATE on the next open reusing the buffer; REPOSITION IN PLACE
-- via nvim_win_set_config while the window stays open (no close+reopen, no flicker).
-- ===========================================================================

--- Lazily create (or reuse) the scratch buffer for the popup content. Create ONCE,
--- reuse across opens (blink pattern). Never throws (create-fail returns nil).
---@param state pi-bridge.MenuState The menu state (reads/writes state.menu_buf).
---@return integer|nil The scratch buffer handle, or nil on create-fail.
local function ensure_menu_buf(state)
  if type(state.menu_buf) == "number" and vim.api.nvim_buf_is_valid(state.menu_buf) then
    return state.menu_buf
  end
  local ok, b = pcall(vim.api.nvim_create_buf, false, true) -- listed=false, scratch=true
  if not ok or type(b) ~= "number" then return nil end
  state.menu_buf = b
  return b
end

--- Build the S35 two-column lines: label (right-padded to label_w) + DESC_GAP + the
--- description truncated to desc_w (right-padded), the whole line padded to a clean
--- rectangle. When desc_w==0, produces S34-identical label-only padded lines.
--- S5: when `gutter` is true, each row is prefixed with the `$ ` gutter (GUTTER_W cells)
--- and `total` grows by GUTTER_W so the clean-rectangle padding stays correct. The
--- label/desc column math is UNCHANGED (the gutter is a fixed once-per-row prefix).
--- Never throws (type-guarded). CJK-aware via strdisplaywidth/strcharpart.
---@param state pi-bridge.MenuState The menu state (reads state.items).
---@param label_w integer The label column width.
---@param desc_w integer The description column width (0 ⇒ label-only).
---@param gutter? boolean S5: prepend the `$ ` gutter to each row (default false).
---@return string[] The padded two-column (or label-only) lines.
local function render_lines(state, label_w, desc_w, gutter)
  local gw = (gutter == true) and GUTTER_W or 0
  local total = gw + label_w + (desc_w > 0 and DESC_GAP or 0) + desc_w
  local prefix = (gutter == true) and GUTTER or ""
  local lines = {}
  for i = 1, #state.items do
    local it = state.items[i]
    local label = ((type(it) == "table" and type(it.label) == "string") and it.label or ""):gsub("[%z\r\n]", " ") -- sanitize: nvim_buf_set_lines rejects NUL/CR/LF
    local lw = vim.fn.strdisplaywidth(label)
    local row = label .. string.rep(" ", math.max(0, label_w - lw)) -- label column, right-padded
    if desc_w > 0 then
      row = row .. string.rep(" ", DESC_GAP) -- the gap
      local has_desc = type(it) == "table" and type(it.description) == "string" and it.description ~= ""
      if has_desc then
        local dt = _truncate(it.description:gsub("[%z\r\n]", " "), desc_w) -- desc, sanitized + truncated
        local dw = vim.fn.strdisplaywidth(dt)
        row = row .. dt .. string.rep(" ", math.max(0, desc_w - dw)) -- desc col, right-padded
      else
        row = row .. string.rep(" ", desc_w) -- no desc → blank desc col
      end
    end
    row = prefix .. row -- S5: prepend the gutter AFTER the label/desc columns are padded
    local rw = vim.fn.strdisplaywidth(row)
    lines[i] = row .. string.rep(" ", math.max(0, total - rw)) -- clean rectangle (CJK-safe)
  end
  return lines
end

--- S35: apply the 3-layer highlight decoration to the popup's scratch buffer. Called
--- from render()'s SHOW path AFTER nvim_buf_set_lines. NEVER throws (pcall every nvim
--- call; type-guards; nvim_buf_is_valid guards; type(ns) guard). Order is load-bearing
--- (LAST-WINS within a namespace, neovim#8449 — research/notes.md §2):
---   (a) clear  (b) base Pmenu every row  (c) Comment on desc ranges
---   (c.5) S5: PiBridgeShellGutter on [0,GUTTER_W) when `gutter`  (d) PmenuSel selected LAST.
--- `state.selected` is 1-BASED (S31); nvim rows are 0-BASED → passes `state.selected - 1`.
--- The gutter highlight PRECEDES PmenuSel (LAST-WINS) so the selected row's `$` stays
--- visible — PmenuSel wins there, tinting it with the selection bg (the intended look).
---@param state pi-bridge.MenuState reads state.items + state.selected (1-based).
---@param buf integer the scratch buffer (state.menu_buf).
---@param label_w integer the label column width.
---@param desc_w integer the description column width (0 ⇒ no desc column).
---@param gutter? boolean S5: paint PiBridgeShellGutter on [0,GUTTER_W) of every row (default false).
local function apply_highlights(state, buf, label_w, desc_w, gutter)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  if type(ns) ~= "number" then return end -- namespace create failed → degrade
  pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1) -- (a) clear (reused scratch buf)
  local n = #state.items
  if n == 0 then return end
  local desc_start = label_w + DESC_GAP
  for i = 1, n do -- (b) base Pmenu whole-line (every row)
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, "Pmenu", i - 1, 0, -1)
  end
  if desc_w > 0 then -- (c) Comment on desc ranges (rows w/ desc)
    for i = 1, n do
      local it = state.items[i]
      if type(it) == "table" and type(it.description) == "string" and it.description ~= "" then
        local dw = math.min(desc_w, vim.fn.strdisplaywidth(it.description))
        if dw > 0 then
          pcall(vim.api.nvim_buf_add_highlight, buf, ns, "Comment", i - 1, desc_start, desc_start + dw)
        end
      end
    end
  end
  if gutter == true then -- (c.5) S5: PiBridgeShellGutter on [0,GUTTER_W) BEFORE PmenuSel (LAST-WINS)
    for i = 1, n do
      pcall(vim.api.nvim_buf_add_highlight, buf, ns, "PiBridgeShellGutter", i - 1, 0, GUTTER_W)
    end
  end
  if type(state.selected) == "number" and state.selected >= 1 and state.selected <= n then
    -- (d) selected LAST → wins (1-based→0-based)
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, "PmenuSel", state.selected - 1, 0, -1)
  end
end

--- S34 render(state): create/show OR close the floating window. Branches on
--- `state.open and #state.items > 0` (open({}) ⇒ state.open=false ⇒ close path).
--- Never throws. Reads config FRESH. Reuses state.menu_buf; repositions state.win in
--- place via nvim_win_set_config when valid, else nvim_open_win; closes on hide.
---@param state pi-bridge.MenuState The menu state (the S31 singleton).
local function render(state)
  if state == nil then return end
  -- HIDE path: state closed (close(), or open({}) which set state.open=false) ⇒ close window.
  if not state.open or #state.items == 0 then
    if type(state.win) == "number" and vim.api.nvim_win_is_valid(state.win) then
      pcall(vim.api.nvim_win_close, state.win, true)
    end
    state.win = nil
    return
  end
  -- SHOW path: ensure scratch buffer (create once, reuse) + set lines + open/reposition window.
  local buf = ensure_menu_buf(state)
  if buf == nil then return end                          -- never throws (create failed → degrade)
  -- READ config FRESH (setup() may never have run — self-sufficient).
  local cfg = require("pi-bridge")
  local menu_cfg = ((cfg.config or cfg.defaults) or {}).menu or {}
  -- S5: shell-context visual cue (PRD §17.9). Read config.shell.visual_cue DEFENSIVELY
  -- (the formal shell={} defaults block is T6.S1, not yet landed — a nil config must NOT
  -- throw; default "gutter"). state.context == "shell" activates the cue; anything else
  -- renders normally (slash/path/nil = no cue).
  local shell_cfg = (cfg.config and cfg.config.shell) or {}
  local cue = (type(shell_cfg.visual_cue) == "string" and shell_cfg.visual_cue) or "gutter"
  local is_shell = state.context == "shell"
  local gutter_on = is_shell and cue == "gutter"
  local border_shell = is_shell and cue == "border"
  local max_height = (type(menu_cfg.max_height) == "number" and menu_cfg.max_height > 0)
                    and menu_cfg.max_height or 12
  local border = (type(menu_cfg.border) == "string" or type(menu_cfg.border) == "table")
                 and menu_cfg.border or "rounded"
  local has_border = border ~= "none"
  local bh = has_border and 2 or 0
  -- S5: define the lazy default hl groups once (default=true → user themes win).
  define_shell_hl()
  -- LIVE screen reads (correct interactively; pinned to 1 headless → geometry is unit-tested
  -- via the pure compute_geometry, NOT through render — research/notes.md §4). pcall-safe.
  local ui_lines, ui_cols = vim.o.lines, vim.o.columns
  local sr = (pcall(vim.fn.screenrow) and vim.fn.screenrow()) or 1
  local sc = (pcall(vim.fn.screencol) and vim.fn.screencol()) or 1
  local width = compute_width(state.items, ui_cols, bh, gutter_on and GUTTER_W or 0)
  local height = compute_height(#state.items, max_height)
  if height <= 0 then                                    -- defensive (items guard already)
    if type(state.win) == "number" and vim.api.nvim_win_is_valid(state.win) then
      pcall(vim.api.nvim_win_close, state.win, true)
    end
    state.win = nil
    return
  end
  local g = compute_geometry(sr, sc, ui_lines, ui_cols, width, height, max_height, border)
  -- S5: the gutter is a fixed 2-cell prefix; subtract it from the FINAL g.width BEFORE the
  -- label/desc split so the desc column math stays correct (compute_width already added it
  -- to the REQUESTED width; compute_geometry may have clamped it — recompute from g.width).
  local gw = gutter_on and GUTTER_W or 0
  -- S35: split the FINAL g.width (compute_geometry may have clamped it) into label + desc
  -- columns. compute_width REQUESTED the two-column width; compute_geometry may clamp it
  -- further (case 5 over-wide). Recompute the split from the FINAL g.width so the desc
  -- column fits what actually got painted.
  local m = column_metrics(state.items)
  local label_w = m.max_label_w
  local desc_w  = m.any_desc and math.max(0, g.width - gw - label_w - DESC_GAP) or 0
  if m.any_desc and desc_w < 3 then desc_w = 0 end -- too thin → label-only (no 1–2 cell sliver)
  local _rlines = render_lines(state, label_w, desc_w, gutter_on)
  dbg(string.format("[menu.render] items=%d height=%s width=%s label_w=%s desc_w=%s nrlines=%d first=%q",
      #state.items, tostring(g.height), tostring(g.width), tostring(label_w), tostring(desc_w), #_rlines, tostring(_rlines[1] or "<none>")))
  local _sl_ok, _sl_err = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, _rlines)
  -- read-back: confirm the buffer actually holds the lines (rules out a silent set_lines failure)
  local _rb = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
  dbg(string.format("[menu.render] set_lines ok=%s err=%q buf_first=%q win=%s", tostring(_sl_ok), tostring(_sl_err), tostring((_rb or {})[1] or "<EMPTY>"), tostring(state.win)))
  apply_highlights(state, buf, label_w, desc_w, gutter_on) -- ← THE S35 INSERTION (3-layer highlights) + S5 gutter
  local win_cfg = {
    relative = "cursor", anchor = g.anchor, row = g.row, col = g.col,
    width = g.width, height = g.height, style = "minimal", border = border,
    focusable = false, noautocmd = true, zindex = 100,
  }
  if type(state.win) == "number" and vim.api.nvim_win_is_valid(state.win) then
    -- REPOSITION/RESIZE IN PLACE (no flicker) — blink pattern.
    pcall(vim.api.nvim_win_set_config, state.win, win_cfg)
  else
    local ok, w = pcall(vim.api.nvim_open_win, buf, false, win_cfg)
    if ok and type(w) == "number" then
      state.win = w
    else
      state.win = nil                                    -- create failed → degrade (next open retries)
      return
    end
  end
  -- window options (non-deprecated form): single-line entries, CJK-safe.
  pcall(vim.api.nvim_set_option_value, "wrap", false, { win = state.win })
  -- S5: border mode — set the FloatBorder tint via the window OPTION (winhighlight is a
  -- win option, NOT a win_config key on nvim < 0.10; setting it as an option is the
  -- cross-version-safe form — mirrors the `wrap` set above). Re-applied each render so an
  -- in-place reposition keeps the shell tint (no flicker). The REUSED window's prior tint
  -- is cleared on a non-border render (the window survives close→reopen — blink lifecycle).
  if border_shell then
    pcall(vim.api.nvim_set_option_value, "winhighlight", "FloatBorder:PiBridgeShellBorder", { win = state.win })
  else
    pcall(vim.api.nvim_set_option_value, "winhighlight", "", { win = state.win })
  end
  -- PAINT the freshly-set buffer lines. The window is opened with `noautocmd=true` from a
  -- deferred/scheduled callback; without an explicit repaint neovim sometimes leaves the
  -- floating window blank until a later keystroke (the intermittent "empty box" that
  -- resolves after a few opens). nvim__redraw(win, valid=false) forces that window's
  -- content to be redrawn now. (0.11+ API; pcall'd for safety.)
  pcall(vim.api.nvim__redraw, { win = state.win, valid = false, flush = true })
end

-- ===========================================================================
-- Public API
-- ===========================================================================

--- The S30→S31 seam consumer. Set onto `completion.on_results` by `attach()`. Routes the
--- latest non-stale `{items, prefix}`: empty → `close()`; non-empty → store context +
--- `open(items)`. TRUSTS S30's two-layer supersession (NO redundant staleness guard —
--- research/notes.md §4; re-querying cursor/lines is a false-negative race). Called on
--- the nvim main loop (api-safe — S30 fires it inline from its `vim.defer_fn` cb, whose
--- bridge cb is itself `schedule_wrap`d). Never throws.
--- S5: the OPTIONAL 4th `context` arg ("shell"|"slash"|"path"|nil) is stored on
--- state.context BEFORE the empty/open routing — it is the ONLY source of truth for the
--- visual cue at render time (coupled to the payload, so a stale menu never shows the
--- wrong cue). Back-compatible: omitted/nil → renders normally (today's behavior).
---@param buf    integer                      The pi-prompt buffer handle (from S30's on_results).
---@param items  pi-bridge.AutocompleteItem[] The completion items (possibly empty — S30 normalized null→{}).
---@param prefix string                       The completion prefix (for get_prefix/S32).
---@param context? string                     S5: the completion context ("shell"|"slash"|"path"|nil). "shell" renders the visual cue.
function M.on_results(buf, items, prefix, context)
  -- WIPE guard (the ONLY nvim-state read here — NOT a staleness re-derive): a buffer may
-- be wiped during the 20ms debounce. Silent no-op, never throw.
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
    dbg(string.format("[menu.on_results] WIPED/NIL buf=%s — bail", tostring(buf)))
    return
  end
  items = (type(items) == "table") and items or {}           -- defensive (S30 sends a valid array)
  local first = (items[1] and (items[1].label or items[1].value)) or "<none>"
  dbg(string.format("[menu.on_results] buf=%s items=%d prefix=%q first=%q ctx=%s",
      tostring(buf), #items, tostring(prefix), tostring(first), tostring(context)))
  state.buf = buf
  state.prefix = (type(prefix) == "string") and prefix or "" -- defensive (S30 sends a string)
  state.context = (type(context) == "string") and context or nil -- S5: store; nil for unknown/non-string
  -- THE routing (blink list.show: empty→hide / non-empty→store+show).
  if #items == 0 then dbg("[menu.on_results] EMPTY → close"); M.close() else M.open(items) end
end

--- Idempotently register `M.on_results` on `require("pi-bridge.completion").on_results`
--- (last-wins overwrite — the cmp single-callback-seam pattern). Guarded by
--- `state.attached` so a 2nd `attach()` (e.g. a /reload re-running `activate()`) is a
--- no-op (does NOT re-save `prev_on_results`). Never throws; silent degrade if
--- `completion` is absent. Safe to call BEFORE the bridge connects — `completion.refresh`
--- degrades silently when `pi.bridge` is nil (no fetch → no `on_results`).
function M.attach()
  if state.attached then return end                                  -- idempotent (no stack on /reload)
  local ok, comp = pcall(require, "pi-bridge.completion")            -- READ FRESH (handshake async + test mocks)
  if not ok or type(comp) ~= "table" then return end                 -- never throws (completion absent)
  state.prev_on_results = comp.on_results                            -- save prior (nil-safe; restored by detach)
  comp.on_results = M.on_results                                     -- last-wins overwrite
  state.attached = true
end

--- Restore the prior `completion.on_results` (saved at the FIRST attach, or nil); set
--- `attached=false`. Never throws; no-op if never attached.
function M.detach()
  if not state.attached then return end
  local ok, comp = pcall(require, "pi-bridge.completion")
  if ok and type(comp) == "table" then comp.on_results = state.prev_on_results end -- restore prior (or nil)
  state.prev_on_results = nil
  state.attached = false
end

--- Store items + set `selected=1` + `open=true`; call `render(state)`. The STATE half of
--- S34's `M.open(items)` — S34 ADDS the floating window inside `render()`. Signature is
--- items-only (matches the S34 contract; `buf`+`prefix` are stored by `on_results`).
---@param items pi-bridge.AutocompleteItem[] The items to display (non-empty — on_results guards empty→close).
function M.open(items)
  items = (type(items) == "table") and items or {}  -- defensive (on_results guards; direct callers may not)
  state.items = items
  state.selected = (items[1] ~= nil) and 1 or 0     -- 1 after open with items (1-indexed; S36 wraparound); 0 if empty
  state.open = (#items > 0)                         -- open ONLY if items (defensive)
  render(state)                                     -- S34: create/draw the floating window.
end

--- Clear items + `selected=0` + `open=false`; call `render(state)`. The STATE half of
--- S34's close — S34 ADDS `nvim_win_close` inside `render()`.
function M.close()
  state.items = {}
  state.selected = 0
  state.open = false
  state.context = nil                              -- S5 hygiene: no cue on a closed menu
  render(state)                                     -- S34: close the floating window.
end

-- ===========================================================================
-- S36: navigation mutators (next/prev/dismiss). Each is a thin STATE change that calls
-- the LOCAL render(state) — render re-applies render_lines (same items) +
-- apply_highlights (new PmenuSel row) + set_config (in-place, no flicker). next/prev
-- bump state.selected (1-based wraparound); dismiss forwards to close(). The completion
-- handlers on_next/on_prev/on_dismiss gate + delegate to these. NEVER throws (guards
-- first; render is pcall-safe). (research/notes.md §1–§3.)
-- ===========================================================================

--- Advance the selection to the NEXT item (1-indexed wraparound), re-rendering in
--- place. No-op (never throws) when the menu is closed/empty. The cursor does NOT move
--- (the handler consumes the key), so render's set_config repositions to the SAME place
--- — no flicker. (research/notes.md §1/§2.)
function M.next()
  if not state.open or #state.items == 0 then return end          -- guard (never throws)
  state.selected = (state.selected % #state.items) + 1            -- 1→2→…→n→1 (1-indexed wrap)
  render(state)                                                   -- LOCAL render: repaint PmenuSel in place
end

--- Retreat the selection to the PREVIOUS item (1-indexed wraparound), re-rendering in
--- place. No-op (never throws) when the menu is closed/empty. (research/notes.md §1/§2.)
function M.prev()
  if not state.open or #state.items == 0 then return end
  state.selected = (state.selected == 1) and #state.items or (state.selected - 1)  -- 1→n→…→2→1
  render(state)
end

--- Dismiss the menu (hide + clear the candidate list). Forwards to M.close() (identical
--- semantics in the pi-faithful "ask on every change" model — the next keystroke
--- re-fetches). Does NOT clear state.buf/state.prefix (only reset() does). Never throws.
--- (research/notes.md §3.)
function M.dismiss()
  M.close()                                                        -- items={}; selected=0; open=false; render hide
end

--- The selected item (`items[selected]`), or `nil`. For S32 accept to read WITHOUT
--- coupling to the window (blink `list.accept` reads state, not the popup).
---@return pi-bridge.AutocompleteItem|nil
function M.get_selected()
  return state.items[state.selected]                -- nil when closed (selected==0)
end

--- Shallow copy of items (the caller may not mutate `state.items`). The item tables
--- themselves are shared (fine — S32 reads `item.value`, S34 reads `item.label`/`description`).
---@return pi-bridge.AutocompleteItem[]
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

--- Teardown: `close()` + `detach()` (if attached); clear `buf`/`prefix` + close + nil
--- the window handles (`win`/`menu_buf` — S34 owns these). Idempotent + never throws.
--- The cleanup seam for tests + the future S37 InsertLeave/CursorMoved-out wiring.
--- Mirrors `completion.reset()`/`bridge.close()`.
function M.reset()
  M.close()                               -- clears items/selected/open (closes the window via render)
  if state.attached then M.detach() end   -- restore prior on_results
  state.buf = nil                         -- full teardown for tests + S37
  state.prefix = ""
  state.win = nil                         -- S34: closed by M.close() inside render
  state.menu_buf = nil                    -- S34: scratch buffer fully torn down
  state.context = nil                     -- S5: clear the shell-context cue (closed already nil'd it; explicit hygiene)
end

-- ===========================================================================
-- S34 INTERNAL TEST SEAMS (underscore-prefixed). The public API (open/close/reset/
-- on_results/get_*) is UNCHANGED. These expose the pure geometry helpers (for the
-- deterministic 7-case verified table) + the state singleton (for window-lifecycle
-- integration asserts) so the spec/smoke can reach internals without a public
-- surface change. Mirrors how coords_spec tests coords.byte_to_utf16/utf16_to_byte.
-- ===========================================================================
M._compute_width = compute_width
M._compute_height = compute_height
M._compute_geometry = compute_geometry
M._state = state
-- S35 internal test seams (the pure helpers — mirror coords_spec's byte_to_utf16 convention).
M._column_metrics = column_metrics
M._truncate = _truncate

return M