--- completion.lua — the per-keystroke completion TRIGGER module (parent P2.M7.T18).
--
-- Owns EXACTLY the pipeline the buffer-local autocmds (ftplugin S22) drive:
--   InsertEnter / TextChangedI / CursorMovedI
--     → require("pi-bridge.completion").refresh(buf)   (fire-and-forget; wired via the
--                                                         ftplugin's no-op-safe `dispatch`)
--     → debounce (TRIGGER-AWARE via `compute_debounce`: 0 ms for slash/typing, the
--        configured window — default 20 — for @/#/attachment context; mirrors pi's TUI
--        `getAutocompleteDebounceMs` editor.ts:2214) via `vim.defer_fn`
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
--    It reads the bridge FRESH at call time (`require("pi-bridge").bridge`, NOT a cached
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
--  * BRIDGE READ FRESH AT CALL TIME: `local bridge = require("pi-bridge").bridge` INSIDE
--    do_refresh, NOT a module-load `local bridge = require("pi-bridge").bridge`. The
--    handshake resolves ASYNC after activation — at first-require time `pi.bridge` is
--    still nil; tests must be able to swap in a fake bridge after `require`. Caching
--    breaks both.
--  * `state.gen` vs `state.inflight_id` — NAMED DISTINCTLY so a reader does not confuse
--    them: `gen` is completion's OWN monotonic int supersession guard (captured in the
--    cb closure); `inflight_id` is the STRING id `bridge.request` returned (for
--    `bridge.cancel`). (bridge ids are `tostring(next_id)` numeric strings; gen is a
--    Lua int.)
--
--  * S40 — TRIGGER-AWARE DEBOUNCE (mirrors pi's TUI `getAutocompleteDebounceMs`,
--    editor.ts:2214): pi does NOT apply a flat debounce. It computes the window PER
--    request from the text before the cursor:
--      • explicitTab || force              → 0 ms (IMMEDIATE) — already correct in the
--        plugin via `force_fetch` (S33, the 0-debounce Tab sibling).
--      • file/attachment context (`@…` / `#…`, incl. the `@"…"` quoted-path-with-spaces
--        case, editor.ts:247 `buildDebouncePattern`) → ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS
--        = 20 ms (editor.ts:236).
--      • else (slash commands `/model`, plain typing) → 0 ms (IMMEDIATE).
--    S40 closes this gap: `M.is_attachment_context(text)` (pure, exported — the coords.lua
--    style) + `compute_debounce(lines, cursorLine, cursorCol)` (0 or the configured
--    window), and `M.refresh(buf)` reads the cursor line + computes the window BEFORE
--    `vim.defer_fn` (so the window reflects the text at refresh time, exactly like pi).
--    The default `debounce_ms` is now 20 (was 25; pi's constant). `debounce_ms` is now
--    semantically "the file/attachment-context window" (slash/typing use 0 ms —
--    NOT separately configurable; pi hardcodes 0).
--  * `vim.defer_fn(fn, 0)` is STILL ASYNC + CANCELLABLE (research §2): N rapid
--    cancel_timer()+defer_fn(0) calls collapse to EXACTLY ONE callback (the cancel path
--    collapses them, NOT the duration). => the existing slash `/mod` collapse tests STILL
--    PASS at 0 ms. Do NOT add a "0 ms = call do_refresh synchronously" path (it would
--    re-introduce the re-entrancy/loop risks this header warns of); keep defer_fn (the
--    free coalescing of the TextChangedI+CursorMovedI pair a keystroke emits is desirable).
--  * SUPERSESSION IS TRIGGER-AGNOSTIC (research §6): the two-layer supersession keys on
--    a monotonic `gen` int, NOT the trigger char. The trigger-aware debounce does NOT
--    weaken it — a fast-typed @sr→@src still bumps gen + drops the stale @sr at the
--    gen-guard. Do NOT add trigger-awareness to the gen-guard. (See S40 tests.)
--
--  * PI-FAITHFUL "ASK ON EVERY CHANGE" MODEL (PRD §7.4): "the simplest correct approach
--    is to ask the provider on every change and let IT decide." So refresh re-fetches on
--    TextChangedI AND CursorMovedI (pi's provider returns `null` when the cursor is not
--    in a completable position); the trigger-aware debounce naturally collapses the
--    TextChangedI+CursorMovedI pair a single keystroke emits into ONE fetch. NO
--    CursorMovedI special-case (it would diverge from pi's TUI; nvim-cmp's re-filter-only
--    CursorMovedI handling is a source-level optimization that does not apply to a
--    single central provider).
--
--  * FORWARD CONTRACTS (do NOT implement in S30; just expose the seams):
--      M.on_results         → S31 (menu population) registers it; fires on the latest success.
--      M.current()          → S32 (accept) / S33 (Tab) read the latest items without menu coupling.
--      M.reset()            → the cleanup seam for tests + the S37 InsertLeave/BufLeave teardown.
--      M.on_insert_leave    → S37 (InsertLeave autocmd → hide + cancel pending refresh).
--      M.on_buf_leave       → S37 (BufLeave autocmd → same teardown on buffer switch).
--    S30 implements `refresh` ONLY. The 6 keymaps (on_tab/on_enter/on_next/on_prev/
--    on_dismiss) are now ALL SHIPPED (on_tab S33, on_enter S32, on_next/on_prev/
--    on_dismiss S36). The 2 auto-close AUTOCMD handlers (on_insert_leave/on_buf_leave)
--    are now SHIPPED (S37). The third auto-close trigger ("CursorMoved out of prefix") is
--    OWNED pi-faithfully by S30's EXISTING CursorMovedI→refresh→re-fetch→empty→close
--    path (research/notes.md §3 — NO local prefix detector).
--
--  * S32 — accept(item) + on_enter(buf): the PRD §7.4 5-step applyCompletion flow (the
--    ACCEPT half of completion). accept(item) reads the selected item + prefix + buf
--    from the COMPLETE menu module (S31), reads the CURRENT buffer lines + cursor,
--    converts nvim→pi via coords (S29), issues `applyCompletion` over the bridge (S26)
--    with params {lines, cursorLine, cursorCol, item, prefix} (the EXACT mirror of
--    extension/protocol.ts ApplyCompletionParams), and in the ASYNC cb (schedule_wrap'd
--    by bridge → nvim main loop, api-safe) converts pi→nvim via coords + replaces the
--    WHOLE buffer via nvim_buf_set_lines(buf, 0, -1, false, nv.lines) + positions the
--    cursor via nvim_win_set_cursor(0, {nv.row, nv.col}) (NO `-1` — coords.lua's
--    exact-UTF-16 + 0-based-byte-cursor-API design SUPERSEDES PRD §7.4's `bytecol - 1`;
--    it would nudge the cursor one byte LEFT on every accept, worst on multibyte lines)
--    + closes the menu via menu.close(). on_enter(buf) is the `<CR>` handler the
--    ftplugin ALREADY dispatches (S22) — returns true (CR CONSUMED) iff buf is
--    valid+current AND the menu is open with a table selected item → accept(item).
--
--    nvim INSERT-MODE accept semantics (LIVE-VERIFIED, research §5):
--      (a) nvim_buf_set_lines is an API mutation — it does NOT fire TextChangedI
--          (`:help TextChangedI` — only TYPED input does; b:changedtick DOES increment,
--          but do NOT key refresh off changedtick). => accept's buffer-replace CANNOT
--          re-trigger the refresh autocmd; NO re-entrancy guard is REQUIRED. Do NOT
--          route the edit through feedkeys ("to trigger refresh") — that WOULD fire
--          TextChangedI + risk a loop.
--      (b) nvim_win_set_cursor moves the VISIBLE cursor in Insert + scrolls into view
--          (`:help nvim_win_set_cursor`) WITHOUT firing CursorMovedI and WITHOUT a
--          redraw/feedkeys nudge. `:help mode()` — API mutations do NOT change mode()
--          ⇒ the user STAYS in Insert (no `<Esc>`/`<i>` dance). The sequence is TWO
--          API calls in order (set_lines THEN set_cursor) — model on blink.cmp's
--          accept/init.lua (NOT nvim-cmp's feedkeys/<C-g>U confirm path).
--      (c) insertion is PI'S JOB. applyCompletion returns the COMPLETE new lines[] +
--          cursor (pi computes trailing space / dir-vs-file / quotes / cursor
--          reposition). S32 applies result.lines WHOLESALE via nvim_buf_set_lines — it
--          NEVER string-replaces the prefix in-place (that would diverge from the TUI).
--
--    ONE-SHOT user action — NO generation-id supersession guard (unlike getSuggestions).
--    Capture buf in the closure; in the cb the accept result is AUTHORITATIVE (the user
--    explicitly accepted; overwriting interim typing is pi-faithful). The bridge's
--    TWO-LAYER pending map holds applyCompletion + getSuggestions separately (they
--    never mis-drop each other). on_enter returns true as soon as the RPC is ISSUED
--    (CR consumed); the buffer mutation is async in the cb (< rpc_timeout_ms).
--    cb error ("rpc error …"/"request timeout"/"connection closed") → DEGRADE: leave
--    the buffer UNTOUCHED + menu.close() (silent; S39's job to notify once). A
--    non-table result (a null/malformed response) → same degrade. accept reads the
--    bridge/menu/coords FRESH at call time (same rule as do_refresh — handshake
--    resolves async + tests swap fakes after require). accept/on_enter NEVER throw
--    (pcall every nvim call; type-guard; bad args → false). on_enter is now SHIPPED
--    (S32); on_tab is now SHIPPED (S33 — see the on_tab block below);
--    on_next/on_prev/on_dismiss are now SHIPPED (S36).
--
--  * S33 — on_tab(buf) + force_fetch + _route_or_accept + the accept prefix_override:
--    pi's `handleTabCompletion` replication (the THIRD keymap handler; the ftplugin
--    ALREADY dispatches on_tab). BRANCH 1 (menu open+selected) → M.accept (pi
--    editor.ts:664 Tab-confirm). BRANCH 2 (menu closed) → pi handleTabCompletion
--    (editor.ts:2126): 2a slash ctx (cursorLine==0 + bare `/cmd` no-space) →
--    force_fetch force=false (pi handleSlashCommandCompletion editor.ts:2132 +
--    isSlashMenuAllowed=cursorLine===0 editor.ts:2068; NO shouldTrigger call); 2b
--    else → shouldTriggerFileCompletion RPC → iff true → force_fetch force=true
--    (pi forceFileAutocomplete editor.ts:2143/2150; abort if the guard is false —
--    pi:2150). Single-item auto-apply on the file-force path (editor.ts:2253) is
--    handled inside _route_or_accept via accept's prefix_override.
--    (A) 0-DEBOUNCE: pi's getAutocompleteDebounceMs (editor.ts:2214) returns 0 for
--        explicitTab/force → force_fetch is IMMEDIATE (NO vim.defer_fn — unlike
--        do_refresh's 20ms). force_fetch DUPLICATES do_refresh's supersession block
--        INTENTIONALLY (additive over refactor — the codebase pattern; do_refresh is
--        exhaustively S30-tested). It SHARES state.gen/inflight_id/debounce_timer so
--        refresh↔Tab supersession is CORRECT (a refresh after Tab supersedes the Tab
--        fetch via the shared gen-guard; Tab cancels a pending refresh debounce via
--        the SHARED cancel_timer() — the S30 stop+close leak fix, NEVER stop-only).
--    (B) beforeCursor UTF-16 SLICE: pi.cursorCol is a UTF-16 (JS string) index;
--        pi.lines[cursorLine] is a UTF-8 Lua string. NEVER :sub(1, pi.cursorCol) on
--        the UTF-8 line (wrong for multibyte). ALWAYS go UTF-16→byte via
--        coords.utf16_to_byte(line, pi.cursorCol) first (S28). The slash/space checks
--        are ASCII so the UTF-8 prefix is char-faithful.
--    (C) shouldTriggerFileCompletion is RPC'd (the bridge method S13) — NEVER
--        reimplemented locally (divergence risk). Consulted ONLY on the force:true
--        path (pi requestAutocomplete:2150 guards only when force). The slash branch
--        does NOT call it.
--    (D) SINGLE-ITEM AUTO-APPLY uses the getSuggestions RESULT's prefix (NOT
--        menu.get_prefix() — the menu is NOT shown, so it's stale/empty). That is
--        why accept gains the optional prefix_override arg (backward-compatible:
--        S32's on_enter calls accept(item) with no override → reads menu.get_prefix()).
--        The auto-apply fires ONLY on the file-force path (force:true && explicitTab
--        && items.length===1); the slash path NEVER auto-applies.
--    (E) CONSUME-vs-INDENT RETURN CONTRACT: on_tab returns true ONLY when it acts
--        (BRANCH 1 accept issued OR a BRANCH 2 fetch/shouldTrigger issued) so the
--        ftplugin CONSUMES the Tab; returns false/nil on bad args / disconnected
--        bridge / wiped buf / non-current buf (feedkey("<Tab>") runs the DEFAULT —
--        indent). on_tab returns true as soon as the fetch/shouldTrigger is ISSUED
--        (the menu population / auto-apply is async in the cb).
--    (F) API-SAFE on the MAIN LOOP (on_tab is a vim.keymap.set('i',…) callback) →
--        nvim_buf_get_lines / nvim_win_get_cursor / bridge.request DIRECTLY (NO
--        vim.schedule wrapper; same contract as do_refresh S30 + accept S32). The
--        bridge cb is schedule_wrap'd → also api-safe.
--    (G) NO TextChangedI RE-ENTRANCY: the auto-apply reuses M.accept, whose
--        nvim_buf_set_lines is an API mutation (does NOT fire TextChangedI — :help).
--        So no refresh loop. The menu-populating Tab path does NOT mutate the buffer
--        at all. NO window coupling (routes via menu.on_results STATE + menu.close
--        STATE; the window is S34's job inside menu's render).
--
-- Node builtins analog: pure Lua + the COMPLETE in-tree bridge (`require("pi-bridge").bridge`)
-- + coords (`require("pi-bridge.coords")`) + config (`require("pi-bridge")`). No sockets
-- of its own — the smoke's fake luv server is the integration surface. Singleton state
-- (mirrors bridge.lua's `state` shape, NOT coords.lua's stateless shape — completion HAS
-- state). One pi-prompt buffer per session (PRD §11); reset() clears state for tests +
-- the future S37 wiring.

local M = {}

-- [TEMP DEBUG] trace completion flow to /tmp/pi-bridge-menu-debug.log (always-on; remove after diagnosing).
local function dbg(msg)
  pcall(function()
    local f = io.open("/tmp/pi-bridge-menu-debug.log", "a")
    if f then f:write(tostring(msg) .. "\n"); f:close() end
  end)
end

--- A pi completion item (mirror of the extension's AutocompleteItem; the bridge delivers
--- these as the `result.items` array of a successful `getSuggestions`). Opaque to S30 —
--- S30 only stores + forwards the array; S31 renders it, S32 applies it. Fields typed
--- loosely here (the exact shape is the extension's protocol; S30 is shape-agnostic).
---@class pi-bridge.AutocompleteItem
---@field value string The text to insert on accept (the canonical value).
---@field label string Human-readable label shown in the menu.
---@field [string] any Extra fields the extension includes (e.g. detail, kind, filterText).

--- Singleton completion state. One pi-prompt buffer per session (PRD §11). Cleared by
--- `reset()`. Mirrors `bridge.lua`'s `state` shape (completion HAS state).
---@class pi-bridge.CompletionState
---@field buf            integer?    The pi-prompt buffer handle refresh() is debouncing for.
---@field debounce_timer userdata?   The `vim.defer_fn` handle (tracked for stop+close — NEVER stop-only; leaks).
---@field gen            integer     Monotonic supersession guard (bumped per fetch; captured in the cb closure).
---@field inflight_id    string?     The `bridge.request` id string of the current in-flight getSuggestions (for `bridge.cancel`).
---@field last_result    {items:pi-bridge.AutocompleteItem[], prefix:string}? Latest non-stale {items,prefix} (for current()/S32/S33).
---@type pi-bridge.CompletionState
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
local do_refresh  -- (buf) — the debounced body (runs inside the api-safe vim.defer_fn cb).
local force_fetch -- (buf, pi, opts, on_items) — S33: the IMMEDIATE (0-debounce) Tab sibling of do_refresh.

--- The result→menu seam (forward contract for S31). Set by S31 to receive the latest
--- non-stale `{items, prefix}`: `function(buf, items, prefix)`. `nil` today → no-op
--- (silent). Mirrors `bridge.lua`'s `M.on_notification` slot pattern. Called on the
--- nvim main loop (api-safe — the bridge's cb is `schedule_wrap`d, so on_result is too).
--- NOT called for stale / error / cancelled results (the two-layer supersession + the
--- error→touch-nothing idiom guarantee that). Last-wins re-registration (a Lua table set).
---@type fun(buf:integer, items:pi-bridge.AutocompleteItem[], prefix:string)|nil
M.on_results = nil

--- Detect whether `text_before_cursor` is a file/attachment context that pi would
--- DEBOUNCE (mirror of pi's `buildDebouncePattern(["@","#"])` `autocompleteDebouncePattern`,
--- editor.ts:247). Returns `true` iff the last whitespace-delimited token before the
--- cursor starts with `@` or `#`, OR the cursor is inside an UNCLOSED `@"..."` quoted
--- mention (pi's `@(?:"[^"]*|[^\s]*)` arm). Lua has no regex `|`/`(?:...)`, so this is
--- explicit logic (NOT a single Lua pattern) — the coords.lua pure-tested style.
---
--- PURE: no nvim API, no state, no side effects → directly unit-testable (coords_spec
--- round-trip shape). The `@`/`#`/`"`/space checks are all ASCII, so a UTF-8 BYTE slice
--- of the cursor line is CORRECT here (NO coords conversion — coords is for the RPC
--- params, which `do_refresh` already does).
---
---@param text_before_cursor string? The cursor line from col 0 to the cursor (UTF-8 byte slice).
---@return boolean is_attachment true iff pi would DEBOUNCE here (attachment/file context).
M.is_attachment_context = function(text_before_cursor)
  local t = text_before_cursor or ""
  if t == "" then return false end
  -- (1) UNCLOSED @"...  quoted-path-with-spaces case (pi @(?:"[^"]*|...)).
  --     Find the LAST '@"' (forward plain search), then count '"' AFTER it; EVEN (incl. 0)
  --     = unclosed → we are inside a quoted mention → attachment context. (Forward scan
  --     avoids the reverse()-on-UTF-8 question entirely; the '@"' needle is ASCII so
  --     string.find plain search is byte-safe.)
  local last_atq
  local i = 1
  while true do
    local s = t:find('@"', i, true)        -- plain search (4th arg = literal); ASCII needle, byte-safe
    if not s then break end
    last_atq = s
    i = s + 2
  end
  if last_atq then
    local after = t:sub(last_atq + 2)
    local _, nq = after:gsub('"', '"')
    if nq % 2 == 0 then return true end      -- EVEN quotes after the last @" (incl. 0) → the
                                               -- opening " is UNCLOSED → inside the mention
  end
  -- (2) PLAIN token: the trailing non-whitespace run starts with '@' or '#'.
  local last = t:match("[%S]+$") or ""
  if last ~= "" then
    local c = last:sub(1, 1)
    if c == "@" or c == "#" then return true end
  end
  return false
end

--- Compute the per-refresh debounce window (mirror of pi's `getAutocompleteDebounceMs`,
--- editor.ts:2214). Returns `0` for non-attachment context (slash/typing — pi-faithful
--- IMMEDIATE), else the configured attachment window (`config.debounce_ms`, default 20 =
--- pi's `ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS`). Tab/force NEVER reach here (`force_fetch`
--- is the separate 0-debounce path; S33). Clamps + falls back defensively (the existing
--- `debounce_ms()` discipline; fallback 25→20).
---
---@param lines      string[] The buffer lines (as `nvim_buf_get_lines` returns).
---@param cursorLine integer The 0-based pi cursor line (nvim row - 1).
---@param cursorCol  integer The 0-based BYTE col (`nvim_win_get_cursor`[2]).
---@return integer ms The debounce window (0 or the configured attachment window).
local function compute_debounce(lines, cursorLine, cursorCol)
  -- §17.11: shell context (line 1 begins with "!") uses config.shell.debounce_ms (default 0 —
  -- immediate; the daemon is warm after first use + the per-shell engine is fast). Checked BEFORE
  -- the attachment check (a "!git ch" line is non-attachment → would otherwise fall to the 0-ms
  -- default, which happens to match, but honoring the config knob is the explicit §17.11 contract).
  -- Read DEFENSIVELY (the shell={} config block is P2.M3.T6.S1, not done yet — a nil config must NOT throw).
  local line1 = (type(lines) == "table") and (lines[1] or "") or ""
  if cursorLine == 0 and line1:sub(1, 1) == "!" then
    local pi = require("pi-bridge")
    local cfg = (pi.config and pi.config.shell) or {}
    local ms = cfg.debounce_ms
    if type(ms) ~= "number" or ms < 0 then ms = 0 end
    return math.max(0, math.floor(ms))
  end
  local line = (type(lines) == "table") and (lines[cursorLine + 1] or "") or "" -- pi 0-based → Lua 1-based
  local byte_end = cursorCol                              -- 0-based BYTE col; ASCII @/#/"/space checks → byte slice is correct
  local before = line:sub(1, byte_end)
  if not M.is_attachment_context(before) then return 0 end
  local cfg = require("pi-bridge")
  local ms = ((cfg.config or cfg.defaults) or {}).debounce_ms
  if type(ms) ~= "number" or ms < 0 then ms = 20 end     -- fallback 20 (pi constant; was 25)
  return math.max(0, math.floor(ms))
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
-- do_shell_fetch(buf) — the SHARED shell-completion fetch helper (P2.M2.T3.S2 / §17.7).
-- Mirrors the codebase's helper-extraction pattern (cancel_timer, _route_or_accept,
-- hide_and_cancel): both do_refresh (debounced) + on_tab (immediate Tab-force, §17.9)
-- route a `ctx == "shell"` line here instead of copy-pasting the shell-fetch logic.
--
-- Invariants (the 4 things that make shell↔bridge supersession correct):
--   * bumps the SHARED state.gen (the SAME counter the bridge path bumps — the
--     shell↔bridge supersession boundary); captures `gen` in the cb closure. Do NOT
--     introduce a separate shell-gen counter (a slash↔shell switch would NOT supersede).
--     (shell.lua has its OWN state.gen for the daemon's in-flight request; completion
--     NEVER touches that one.)
--   * layer-1 supersession: cancels a pending BRIDGE inflight (the slash→shell switch;
--     frees the round-trip). shell.lua has NO cancel wire method (it's a local
--     subprocess; it supersedes internally via its own gen + overwriting pending_cb) —
--     do NOT call bridge.cancel for a shell request, and do NOT invent a shell cancel.
--   * FORWARD CONTRACT: shell.complete_current(buf, cb) is S3 (P2.M2.T3.S3), not yet
--     defined → `type(...) == "function"` guard makes this a SILENT NO-OP until S3
--     lands (mirrors S1's inert intermediate-state posture; S2 cannot break the live
--     plugin). cb signature: cb(err, items, prefix) where items is AutocompleteItem[]
--     (already normalized by shell.lua _feed) + prefix is a string (may be "").
--   * FAST-CONTEXT SAFETY: the shell daemon's cb runs in LIBUV FAST context
--     (shell.lua:642/650 forward contract), NOT the nvim main loop (UNLIKE the bridge
--     cb, which bridge.lua schedule_wrap's). So the cb does the gen-guard + the
--     state.last_result write DIRECTLY (fast-safe: Lua table read/write, single-
--     threaded) but `vim.schedule`s the M.on_results menu hop (NOT fast-safe — :help
--     E5560; it drives the floating window). Forgetting the schedule throws E5560 or
--     corrupts the UI mid-redraw — the #1 trap in S2 (the shell cb is NOT a copy of
--     the bridge cb). Contrast: the bridge cb needs NO extra schedule.
-- Shell completion is BRIDGE-INDEPENDENT (the daemon is a child of nvim — §17.3/§17.13);
-- a `!` line with no bridge still routes here. Shell uses BYTE offsets (§17.14) — NO
-- coords.nvim_to_pi_coords call; do_shell_fetch(buf) takes just the buf.
-- Reads bridge/shell FRESH (lazy require; handshake async + test mocks). Never throws
-- (pcall every external call; per-keystroke + autocmd contract).
-- ===========================================================================
local function do_shell_fetch(buf)
  local bridge = require("pi-bridge").bridge -- READ FRESH (only for canceling a pending BRIDGE request)
  -- SUPERSEDE layer 1: cancel any in-flight BRIDGE request (the slash→shell switch).
  if state.inflight_id and bridge and type(bridge.cancel) == "function" then
    pcall(bridge.cancel, state.inflight_id)
  end
  state.inflight_id = nil
  -- SUPERSEDE layer 2: gen-guard (SHARED with the bridge path — the shell↔bridge boundary).
  state.gen = state.gen + 1
  local gen = state.gen
  -- FORWARD CONTRACT (S3): shell.complete_current(buf, cb). Not yet defined → silent no-op
  -- (S2→S3 intermediate state; mirrors S1's posture).
  local shell = require("pi-bridge.shell")
  if type(shell.complete_current) ~= "function" then
    dbg("[do_shell_fetch] shell.complete_current NOT defined (S3) — silent degrade")
    return
  end
  pcall(shell.complete_current, buf, function(err, items, prefix)
    -- ⚠ LIBUV FAST CONTEXT (shell.lua:642/650). gen-guard + state.last_result write are
    -- fast-safe (Lua table r/w); M.on_results drives the menu → vim.schedule it (E5560).
    if gen ~= state.gen then return end -- STALE (superseded) — drop, touch nothing
    state.inflight_id = nil
    if err then dbg("[do_shell_fetch.cb] ERR=" .. tostring(err)); return end -- silent degrade (S4 notifies)
    local its = items  or {}
    local pfx = prefix or ""
    state.last_result = { items = its, prefix = pfx } -- fast-safe (Lua table write)
    if type(M.on_results) == "function" then
      vim.schedule(function() pcall(M.on_results, buf, its, pfx, "shell") end) -- fast → nvim main loop (menu hop); S5: thread the shell context
    end
  end)
end

-- ===========================================================================
-- completion_context(lines, cursorLine, cursorCol) — the CLIENT-SIDE completion gate.
-- Returns "slash" | "path" | "shell" | nil. Mirrors the user's intent: completion should fire ONLY
--   • "shell" — line 1 (cursorLine 0) begins with "!" (pi bash mode; covers both "!" and "!!").
--               Checked FIRST so it wins over slash/path. Routed to the shell-completion daemon by S2.
--   • "slash" — line 1 (cursorLine 0) begins with "/"  (commands / skills / prompts + their args)
--   • "path"  — the trailing token before the cursor begins with "@", "#", ".", "~/", or "/"
--               (file/path/attachment; "@" always — pi's @file mention)
-- Plain typing (words, spaces, bare quotes) returns nil → do_refresh skips the request +
-- closes any open menu. Byte-correct on UTF-8 (trigger chars are ASCII).
---@param lines      string[] Buffer lines (raw UTF-8, as nvim_buf_get_lines returns).
---@param cursorLine integer 0-based line index.
---@param cursorCol  integer 0-based BYTE column.
---@return string|nil "slash" | "path" | "shell" | nil
local function completion_context(lines, cursorLine, cursorCol)
  -- §17.7: bash mode is line 1 starting with "!". Checked FIRST so it wins over
  -- slash/path. Catches BOTH "!" and "!!" (bang-count strip is shell.lua's job, S3).
  local line1 = (type(lines) == "table") and (lines[1] or "") or ""
  if cursorLine == 0 and line1:sub(1, 1) == "!" then return "shell" end
  local line = (type(lines) == "table") and (lines[cursorLine + 1] or "") or ""
  local before = line:sub(1, cursorCol)                 -- 0-based byte col → bytes [1..cursorCol]
  local token = before:match("[%S]+$") or ""            -- trailing non-whitespace run (the word being typed)
  local token_start = #before - #token                  -- 0-based byte column where `token` begins
  -- (1) A "/" WORD: a slash command ONLY when it is THE first character of line 1
  --     (cursorLine 0 and the token begins at col 0). A "/" beginning any OTHER word —
  --     on any other line, or after the command on line 1 (e.g. "/foo /bar") — is a PATH.
  --     (A bare "/abs/path" as the very first utterance is thus a (non-matching) command,
  --     not a path; users prepend "@" for a first-utterance absolute path.)
  if token ~= "" and token:sub(1, 1) == "/" then
    if cursorLine == 0 and token_start == 0 then return "slash" end
    return "path"
  end
  -- (2) Still on line 1 which begins with "/", but the cursor is past the command name
  --     (the token is a non-slash argument) → slash-command ARGUMENT completion
  --     (e.g. "/model ant").
  if cursorLine == 0 and before:sub(1, 1) == "/" then return "slash" end
  -- (3) File/path/attachment triggers on the current word.
  if token == "" then return nil end
  local c1 = token:sub(1, 1)
  if c1 == "@" or c1 == "#" then return "path" end       -- @ (always) / # attachment
  if c1 == "." then return "path" end                     -- ./  ../  .
  if token:sub(1, 2) == "~/" then return "path" end       -- home path
  return nil
end

-- Pure-helper export: mirrors M.is_attachment_context for direct unit testing of the gate
-- (tests/completion_spec.lua). do_refresh still calls the LOCAL upvalue — unchanged.
M.completion_context = completion_context

-- ===========================================================================
-- do_refresh(buf) — the debounced body (runs inside the api-safe vim.defer_fn cb).
-- Read buffer + convert to pi coords (S29) + supersede (BOTH layers) + issue RPC.
-- ===========================================================================
do_refresh = function(buf)
  -- GUARD: buf validity (a wipe during the debounce) + still-current (a switch during
  -- the 20ms window — the cursor is for the current window; if buf isn't current the
  -- read is wrong; silent no-op, not a fetch on stale state).
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  if buf ~= vim.api.nvim_get_current_buf() then return end
  -- READ buffer lines + cursor FIRST (§17.7: the SHELL branch does NOT need the bridge —
  -- the daemon is a child of nvim, §17.3/§17.13; only the slash/path branch does, so the
  -- bridge-connected bail moved BELOW the ctx computation).
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok or type(lines) ~= "table" then return end
  local cur
  ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok or type(cur) ~= "table" then return end
  local row, byte_col = cur[1], cur[2]
  -- CLIENT-SIDE COMPLETION GATE (user-facing UX): only ask pi's provider in a
  -- slash-command context (line 1 starts with "/") or a file/path/attachment context
  -- (a token before the cursor begins with "@", ".", "~/", or "/"). Plain prose — words,
  -- spaces, quotes — does NOT request, so no dropdown appears mid-sentence. (pi's provider
  -- otherwise returns a cwd file listing after a trailing space/quote, which is its TAB
  -- behavior — wanted only on explicit Tab, not on every keystroke.) Byte-correct: uses
  -- the RAW UTF-8 `lines` + the 0-based BYTE `byte_col` (all trigger chars are ASCII), so
  -- multibyte text before the trigger does not skew the slice. The Tab path (force_fetch)
  -- is EXPLICIT and bypasses this gate.
  local ctx = completion_context(lines, row - 1, byte_col)
  -- ── SHELL CONTEXT (§17.7): route to the shell-completion daemon, NOT the bridge ──
  -- A `!`/`!!` line 1 routes to shell.complete_current (S3; forward-guarded → silent
  -- no-op until S3 lands). Shell completion is BRIDGE-INDEPENDENT → checked BEFORE the
  -- bridge-connected bail (a `!` line with no bridge still routes here).
  if ctx == "shell" then
    do_shell_fetch(buf)
    return
  end
  if not ctx then
    dbg(string.format("[do_refresh] ctx=nil (plain) line1=%q col=%s — close, no request", tostring((lines or {})[1] or ""), tostring(byte_col)))
    if type(M.on_results) == "function" then pcall(M.on_results, buf, {}, "", nil) end -- S5: explicit nil context (plain typing)
    return
  end
  -- READ BRIDGE FRESH (only the slash/path path needs it; handshake resolves async +
  -- test mocks swap in after require).
  local pi_mod = require("pi-bridge")
  local bridge = pi_mod.bridge
  if not bridge
     or type(bridge.is_connected) ~= "function"
     or not bridge.is_connected() then
    dbg("[do_refresh] NOT CONNECTED — bail")
    return -- silent degrade (S39's job to notify once); never throw
  end
  -- CONVERT (S29 — THE centralized seam; the ONLY ±1 is the row). `pi.lines` is the SAME
  -- reference as `lines`, so the result drops straight into the RPC params.
  local pi = require("pi-bridge.coords").nvim_to_pi_coords(lines, row, byte_col)
  -- SUPERSEDE layer 1 (cancel prev in-flight — optimization; frees the round-trip).
  if state.inflight_id and type(bridge.cancel) == "function" then
    pcall(bridge.cancel, state.inflight_id)
  end
  state.inflight_id = nil
  -- SUPERSEDE layer 2 (gen-guard — the CORRECTNESS boundary; captured in the cb closure).
  dbg(string.format("[do_refresh] newgen=%s cursorLine=%s cursorCol=%s line1=%q inflight=%s",
      state.gen + 1, tostring(pi.cursorLine), tostring(pi.cursorCol), tostring(pi.lines[1] or ""), tostring(state.inflight_id)))
  state.gen = state.gen + 1
  local gen = state.gen
  -- force=true for PATH context makes pi SKIP its own slash-command branch (which
  -- returns commands for ANY line starting with "/", not just line 1) and do file/path
  -- completion instead. force=false for SLASH context lets pi return commands/skills/prompts.
  -- Net effect: commands/skills/prompts appear ONLY for "/" at the start of line 1; a
  -- "/" word anywhere else yields paths — exactly the requirement.
  local params = vim.tbl_extend("keep", pi, { force = (ctx == "path") }) -- {lines,cursorLine,cursorCol,force}
  -- ISSUE (pcall so a bridge bug never aborts the autocmd chain). `id` may be nil if the
  -- bridge raced to disconnected (no inflight to track — the gen-guard still drops a late cb).
  local id
  ok, id = pcall(bridge.request, "getSuggestions", params, function(err, result)
    if gen ~= state.gen then
      dbg(string.format("[do_refresh.cb] STALE drop (cb gen=%s != state.gen=%s)", tostring(gen), tostring(state.gen)))
      return end                 -- STALE (superseded) — drop, touch nothing
    state.inflight_id = nil
    if err then dbg("[do_refresh.cb] ERR=" .. tostring(err)); return end                              -- cancelled/timeout/error → touch nothing
    -- NORMALIZE: null result (cb(nil,nil)) = SUCCESS with empty items, NOT an error.
    local items  = (result and type(result.items)  == "table")  and result.items  or {}
    local prefix = (result and type(result.prefix) == "string") and result.prefix or ""
    state.last_result = { items = items, prefix = prefix }
    local first = (items[1] and (items[1].label or items[1].value)) or "<none>"
    dbg(string.format("[do_refresh.cb] OK items=%d prefix=%q first=%q on_results=%s",
        #items, tostring(prefix), tostring(first), tostring(type(M.on_results) == "function")))
    -- S31 seam (api-safe; nil today → no-op). Fires ONLY for the latest non-stale success.
    if type(M.on_results) == "function" then
      pcall(M.on_results, buf, items, prefix, ctx) -- S5: thread the completion context ("slash"|"path"; shell routes to do_shell_fetch above)
    end
  end)
  if ok and type(id) == "string" then state.inflight_id = id end
end

-- ===========================================================================
-- force_fetch(buf, pi, opts, on_items) — S33: the IMMEDIATE (0-debounce) Tab sibling of
-- do_refresh. Cancels the debounce timer + any in-flight request (supersede layer 1),
-- bumps state.gen (layer 2), issues bridge.request("getSuggestions", {lines,cursorLine,
-- cursorCol,force}, cb). cb: gen-guard, normalize null→{items={},prefix=""}, store
-- last_result, call on_items(buf, items, prefix). pcall-wrapped; never throws.
--
-- WHY A SEPARATE FUNCTION (NOT a refactor of do_refresh): pi's getAutocompleteDebounceMs
-- (editor.ts:2214) returns 0 for explicitTab/force, so Tab is IMMEDIATE. do_refresh
-- DEBOUNCES ~20ms (the natural-typing path); reusing it would add a Tab lag + diverge
-- from the TUI. force_fetch DUPLICATES do_refresh's few-line supersession block
-- INTENTIONALLY (additive over refactor — the codebase pattern; do_refresh is
-- exhaustively S30-tested). It SHARES state.gen / state.inflight_id / state.debounce_timer
-- so refresh↔Tab supersession is CORRECT (a keystroke after Tab supersedes the Tab fetch
-- via the shared gen-guard; Tab cancels a pending refresh debounce via cancel_timer()).
-- Reuses the EXISTING cancel_timer() local (the S30 stop+close leak fix — NEVER stop-only).
-- (research/notes.md §3.)
--
-- @param buf      integer                The pi-prompt buffer handle (captured in the cb closure).
-- @param pi       pi-bridge.PiCoords      The pi coords {lines, cursorLine, cursorCol} (S29).
-- @param opts     {force:boolean}        force=true ⇒ the file-force path; force=false ⇒ the slash path.
-- @param on_items fun(buf:integer, items:pi-bridge.AutocompleteItem[], prefix:string) The result router.
force_fetch = function(buf, pi, opts, on_items)
  -- §17.9: shell Tab-force routes to the shell daemon (NOT the bridge). on_tab detects
  -- ctx=="shell" and calls do_shell_fetch directly; this seam lets a future caller drive
  -- a shell force-fetch via force_fetch too (shell uses BYTE offsets — pi's UTF-16 coords
  -- do not apply; do_shell_fetch(buf) takes just the buf).
  if opts and opts.shell == true then
    do_shell_fetch(buf)
    return
  end
  cancel_timer()                                   -- drop any pending refresh debounce (can't race)
  local bridge = require("pi-bridge").bridge          -- READ FRESH (handshake async + test mocks)
  -- SUPERSEDE layer 1 (cancel prev in-flight — optimization; frees the round-trip).
  if state.inflight_id and type(bridge.cancel) == "function" then
    pcall(bridge.cancel, state.inflight_id)
  end
  state.inflight_id = nil
  -- SUPERSEDE layer 2 (gen-guard — the CORRECTNESS boundary; captured in the cb closure).
  state.gen = state.gen + 1
  local gen = state.gen
  local params = vim.tbl_extend("keep", pi, { force = (opts.force == true) }) -- {lines,cursorLine,cursorCol,force}
  local ok, rid = pcall(bridge.request, "getSuggestions", params, function(err, result)
    if gen ~= state.gen then return end               -- STALE (superseded) — drop, touch nothing
    state.inflight_id = nil
    if err then return end                            -- cancelled/timeout/error → touch nothing
    -- NORMALIZE: null result (cb(nil,nil)) = SUCCESS with empty items, NOT an error.
    local items  = (result and type(result.items)  == "table")  and result.items  or {}
    local prefix = (result and type(result.prefix) == "string") and result.prefix or ""
    state.last_result = { items = items, prefix = prefix }
    pcall(on_items, buf, items, prefix)               -- route to menu OR auto-apply
  end)
  if ok and type(rid) == "string" then state.inflight_id = rid end
end

--- Builds the result-router closure for a Tab fetch (S33). Single-item auto-apply on the
--- file-force path (force+1 item → M.accept(item, prefix)); otherwise route to the menu via
--- the SAME `completion.on_results` → `menu.on_results` seam S30 uses (empty→close,
--- non-empty→open). `allow_auto` is true ONLY on the file-force path (pi editor.ts:2253:
--- force && explicitTab && items.length===1); the slash path (force:false) NEVER
--- auto-applies (pi applyAutocompleteSuggestions always sets the list).
---@param buf        integer  The pi-prompt buffer handle.
---@param allow_auto boolean  true on the file-force path (auto-apply eligible); false on the slash path.
---@return fun(buf:integer, items:pi-bridge.AutocompleteItem[], prefix:string) router The result router.
local function _route_or_accept(buf, allow_auto)
  return function(_, items, prefix)
    -- SINGLE-ITEM AUTO-APPLY (file-force path): pi editor.ts:2253. Uses the getSuggestions
    -- RESULT's prefix (the menu is NOT shown → menu.get_prefix() is stale/empty) via accept's
    -- prefix_override arg. Forward item VERBATIM.
    if allow_auto and #items == 1 then
      M.accept(items[1], prefix)
      return
    end
    -- else route to the menu via the SAME seam S30 uses (registered by menu.attach onto
    -- completion.on_results; drives empty→menu.close / non-empty→menu.open). api-safe.
    -- S5: shell Tab routes to do_shell_fetch before reaching here, so this path is NEVER
    -- shell → pass an explicit nil context (slash/file only).
    if type(M.on_results) == "function" then pcall(M.on_results, buf, items, prefix, nil) end
  end
end
-- Public API
-- ===========================================================================

--- The autocmd entry point (InsertEnter/TextChangedI/CursorMovedI; wired buffer-local
--- by the ftplugin S22 via its no-op-safe `dispatch`). Fire-and-forget (the autocmd
--- callback ignores the return value). Debounces: cancels any pending debounce timer
--- (`stop()`+`close()` — the LIVE-VERIFIED leak fix; NEVER `stop()`-only), then computes
--- the TRIGGER-AWARE window from the CURRENT cursor line (S40 — mirror of pi's
--- `getAutocompleteDebounceMs`, editor.ts:2214: 0 ms for slash/typing, `debounce_ms`
--- for @/#/attachment context incl. the `@"..."` quoted-path case), and schedules
--- `do_refresh(buf)` after that window (0 or `config.debounce_ms`, default 20). Re-fetches
--- on EVERY change (pi-faithful — PRD §7.4; the provider returns null when not completable;
--- the debounce collapses a TextChangedI+CursorMovedI pair into one fetch). Never throws;
--- silent degrade if the bridge is absent/disconnected (checked in `do_refresh`).
---
---@param buf integer The pi-prompt buffer handle (from the autocmd; NOT 0).
function M.refresh(buf)
  if type(buf) ~= "number" then return end -- never-throws (per-keystroke + autocmd contract)
  state.buf = buf
  cancel_timer()                           -- stop+close the prior pending defer (leak fix)
  -- S40: compute the TRIGGER-AWARE window from the cursor line at refresh time (mirrors pi
  -- computing debounceMs at requestAutocomplete entry from the *current* state). pcall-wrapped
  -- (a wiped buf / odd state degrades silently to the 0-ms default — never throws). The line
  -- may change DURING the debounce window; do_refresh re-reads it FRESH for the RPC params.
  local ms = 0
  pcall(function()
    if buf ~= vim.api.nvim_get_current_buf() then return end -- one buf/session (unchanged guard)
    local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
    if not ok or type(lines) ~= "table" then return end
    local cur
    ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
    if not ok or type(cur) ~= "table" then return end
    local row, byte_col = cur[1], cur[2]
    ms = compute_debounce(lines, row - 1, byte_col) -- row 1-based → pi 0-based; byte_col is 0-based byte
  end)
  -- SCHEDULE (the cb is api-safe — main loop; research §5; NO vim.schedule needed).
  dbg(string.format("[completion.refresh] buf=%s ms=%s", tostring(buf), tostring(ms)))
  state.debounce_timer = vim.defer_fn(function() do_refresh(buf) end, ms)
end

--- Teardown: cancel the debounce timer (`stop()`+`close()`) + any in-flight request;
--- clear `last_result`; reset the generation counter. Idempotent + never throws
--- (pcall-wrapped; safe to call when never activated — mirrors `bridge.on_exit`).
--- The cleanup seam for tests + the S37 InsertLeave/BufLeave auto-close wiring
--- (S37's `on_insert_leave`/`on_buf_leave` call `M.reset()` AFTER `menu.close()` —
--- research/notes.md §1/§6).
function M.reset()
  cancel_timer()
  local b = require("pi-bridge").bridge
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
---@return {items:pi-bridge.AutocompleteItem[], prefix:string}? result The latest result, or nil.
function M.current()
  local r = state.last_result
  if not r then return nil end
  return { items = r.items, prefix = r.prefix }
end

-- ===========================================================================
-- S32: accept(item) + on_enter(buf) — the PRD §7.4 accept flow (the ACCEPT half).
-- The 5-step applyCompletion flow: read current lines+cursor → convert nvim→pi →
-- bridge.request("applyCompletion", {lines,cursorLine,cursorCol,item,prefix}, cb) →
-- in the async cb: convert pi→nvim + nvim_buf_set_lines (whole buffer) +
-- nvim_win_set_cursor (NO -1) + menu.close. on_enter gates on buf/menu + delegates.
-- ===========================================================================

--- The pi→nvim result of a successful `applyCompletion` (mirror of
--- `extension/protocol.ts` `ApplyCompletionResult`). pi returns the COMPLETE new buffer
--- + cursor; S32 applies it wholesale via `nvim_buf_set_lines`. Delivered as the
--- `result` arg of the `bridge.request` cb (cb(nil, result)).
---@class pi-bridge.ApplyCompletionResult
---@field lines      string[] The COMPLETE new line array (replace buf wholesale).
---@field cursorLine integer 0-indexed pi line (coords.pi_to_nvim_coords adds +1).
---@field cursorCol  integer 0-indexed UTF-16 offset (coords.pi_to_nvim_coords → 0-based byte; NO -1).

--- The 5-step PRD §7.4 accept flow. Reads the selected item's prefix + buf from the
--- COMPLETE menu module (S31) + the CURRENT buffer lines + cursor, converts nvim→pi via
--- coords (S29), issues `applyCompletion` over the bridge (S26), and in the ASYNC cb
--- (schedule_wrap'd by bridge → api-safe) converts pi→nvim + replaces the WHOLE buffer
--- + sets the cursor (NO -1) + closes the menu. NEVER reimplements insertion (pi does
--- it — returns the whole new lines[]). Returns true iff the RPC was issued (the cb is
--- fire-and-forget). Never throws (pcall-wrapped nvim + bridge/menu/coords read FRESH).
--- cb error → degrade (buffer untouched + menu.close). (research/notes.md §2/§3/§5/§6.)
---
---@param item            pi-bridge.AutocompleteItem The selected item (from menu.get_selected()) — forwarded VERBATIM.
---@param prefix_override string?                     OPTIONAL (S33): the getSuggestions result's prefix (the single-item auto-apply path — the menu is NOT shown, so `menu.get_prefix()` is stale/empty). Defaults to `menu.get_prefix()` (S32's on_enter calls accept(item) with NO override → IDENTICAL behavior).
---@return boolean issued true iff the applyCompletion RPC was accepted by the bridge.
function M.accept(item, prefix_override)
  if type(item) ~= "table" then return false end                    -- defensive (on_enter pre-checks; direct callers may not)
  -- RESOLVE buf BEFORE the bridge check: a `!`/`!!` line MUST route to the shell path even
  -- when the bridge is disconnected (shell completion is bridge-independent, §17.3/§17.13).
  -- menu.get_buf() may be nil/stale (S33 auto-apply path) → fall back to the current buf.
  local menu = require("pi-bridge.menu")
  local buf  = menu.get_buf()
  -- S33 auto-apply path: the menu is NOT shown (closed) OR its buf is stale/wiped, so
  -- menu.get_buf() is nil/invalid. Fall back to the current buffer (on_tab already gated
  -- buf==current; accept re-validates below + reads lines fresh).
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_get_current_buf()
  end
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end    -- one buf/session; cursor is the current win's
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok or type(lines) ~= "table" then return false end
  -- SHELL ROUTE (§17.8): a `!`/`!!` line accepts via the LOCAL word-replacement path, NOT the
  -- pi bridge (pi's applyCompletion does not apply to shell words — shell candidates are
  -- plain words, not pi AutocompleteItems). Re-derive context from line 1 (the source of
  -- truth; NOT menu.state.context, which is the visual-cue's source only + may be stale).
  -- prefix_override is IGNORED on the shell path (shell accept recomputes the word from the
  -- buffer). Runs BEFORE the bridge guard so a `!` line routes even with no bridge.
  if type(lines[1]) == "string" and lines[1]:sub(1, 1) == "!" then
    return require("pi-bridge.shell.accept").apply(buf, item) == true
  end
  -- READ bridge FRESH (handshake resolves async + test mocks swap in after require). The pi
  -- path reuses the already-read `lines` (no double-read).
  local bridge = require("pi-bridge").bridge
  if not bridge
     or type(bridge.is_connected) ~= "function"
     or not bridge.is_connected() then
    return false                                                    -- silent degrade (S39 notifies once)
  end
  local cur
  ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok or type(cur) ~= "table" then return false end
  local coords = require("pi-bridge.coords")
  local pi = coords.nvim_to_pi_coords(lines, cur[1], cur[2])        -- {lines, cursorLine, cursorCol(UTF-16)}
  local params = {
    lines      = pi.lines,
    cursorLine = pi.cursorLine,
    cursorCol  = pi.cursorCol,
    item       = item,                                              -- forwarded VERBATIM (the whole AutocompleteItem table)
    prefix     = (type(prefix_override) == "string") and prefix_override or (menu.get_prefix() or ""), -- S33: the auto-apply passes the result's prefix; S32 (no override) reads menu.get_prefix()
  }
  -- ONE-SHOT user action — NO gen-guard (capture buf in the closure; cb validates nothing
  -- else — the accept result is AUTHORITATIVE). pcall bridge.request so a bridge bug never throws.
  pcall(bridge.request, "applyCompletion", params, function(err, result)
    -- async, schedule_wrap'd by bridge → nvim main loop (api-safe; NO extra vim.schedule).
    if err then pcall(menu.close); return end                       -- DEGRADE: buffer UNTOUCHED
    if type(result) ~= "table" then pcall(menu.close); return end   -- malformed/null → degrade
    local nv = coords.pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, nv.lines)  -- replace WHOLE buffer (NOT TextChangedI)
    pcall(vim.api.nvim_win_set_cursor, 0, { nv.row, nv.col })       -- col 0-based BYTE (NO -1); Insert-safe
    pcall(menu.close)                                               -- clear state (+ no-op render until S34)
  end)
  return true                                                       -- bridge accepted the request (fire-and-forget cb)
end

--- The `<CR>` handler (accept-or-newline; the ftplugin ALREADY dispatches on_enter).
--- Returns true (CR CONSUMED) iff buf is valid+current AND the menu is open with a table
--- selected item → calls M.accept(item). Otherwise returns false (the ftplugin's
--- `feedkey("<CR>")` inserts a NEWLINE — PRD §7.4: no Enter-to-submit in the external
--- editor; quitting submits). Never throws (the dispatch is pcall-wrapped in the ftplugin
--- + accept is defensive).
---
---@param buf integer The pi-prompt buffer handle (from the buffer-local <CR> keymap dispatch).
---@return boolean handled true iff CR was consumed (accept issued); false to fall through to a newline.
function M.on_enter(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end    -- one buf/session
  local menu = require("pi-bridge.menu")
  if not menu.is_open() or not menu.has_items() then return false end
  local item = menu.get_selected()
  if type(item) ~= "table" then return false end
  return M.accept(item) == true                                     -- true iff RPC issued (CR consumed)
end

-- ===========================================================================
-- S33: on_tab(buf) — pi's handleTabCompletion replication (the THIRD keymap handler).
-- BRANCH 1 (menu OPEN + selected) → M.accept (pi editor.ts:664 Tab-confirm).
-- BRANCH 2 (menu CLOSED) → pi handleTabCompletion (editor.ts:2126):
--   2a slash ctx (cursorLine==0 + bare /cmd no-space) → force_fetch force=false
--      (pi handleSlashCommandCompletion — NO shouldTriggerFileCompletion call).
--   2b else → shouldTriggerFileCompletion RPC; iff true → force_fetch force=true
--      (pi forceFileAutocomplete — editor.ts:2143/2150; abort if the guard is false).
-- Returns true when it acts (Tab CONSUMED); false on bad args / disconnected bridge /
-- wiped buf / non-current buf (the ftplugin's feedkey("<Tab>") runs the DEFAULT — indent).
-- Never throws (pcall every nvim/bridge/coords call; read bridge/menu/coords FRESH).
-- (research/notes.md §2/§3/§5.)
-- ===========================================================================

--- The `<Tab>` handler (the ftplugin ALREADY dispatches on_tab). Replicates pi's
--- `handleTabCompletion` (editor.ts:2126): BRANCH 1 — menu open+selected → accept
--- (pi editor.ts:664); BRANCH 2 — menu closed → the slash-command branch (cursorLine==0
--- + bare `/cmd` no-space → force:false getSuggestions, pi handleSlashCommandCompletion
--- editor.ts:2132 + isSlashMenuAllowed=cursorLine===0 editor.ts:2068; NO shouldTrigger call)
--- OR the file-force branch (shouldTriggerFileCompletion RPC → iff true → force:true
--- getSuggestions, pi editor.ts:2143/2150). The file-force single-item auto-apply
--- (editor.ts:2253) is handled inside `_route_or_accept` via the `accept` prefix_override.
--- Returns `true` ONLY when Tab is consumed (accept/fetch/shouldTrigger issued); `false`
--- → indent fall-through. Never throws.
---
---@param buf integer The pi-prompt buffer handle (from the buffer-local <Tab> keymap dispatch).
---@return boolean handled true iff Tab was consumed (accept/fetch/shouldTrigger issued); false → indent.
function M.on_tab(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end    -- one buf/session
  local menu = require("pi-bridge.menu")
  -- ── BRANCH 1 (menu OPEN + selected): pi editor.ts:664 Tab-confirm ──
  if menu.is_open() and menu.has_items() then
    local item = menu.get_selected()
    if type(item) == "table" then return M.accept(item) == true end   -- S32 core (no override)
  end
  -- ── BRANCH 2 (menu CLOSED): pi handleTabCompletion (editor.ts:2126) ──
  -- Read lines + cursor FIRST (§17.9: the SHELL branch does NOT need the bridge — the
  -- daemon is a child of nvim; a `!` line with no bridge still force-completes).
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok or type(lines) ~= "table" then return false end
  local cur
  ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok or type(cur) ~= "table" then return false end
  -- ── SHELL CONTEXT (§17.9): force an immediate shell fetch (mirrors file-force; 0 debounce).
  -- Shell items are plain words → route to the menu (on_results), NOT _route_or_accept
  -- (pi's single-item auto-apply does not apply; shell accept is P2.M2.T4).
  if completion_context(lines, cur[1] - 1, cur[2]) == "shell" then
    do_shell_fetch(buf)
    return true                                                     -- Tab CONSUMED
  end
  -- bridge-connected check (only the slash/file paths need the bridge)
  local bridge = require("pi-bridge").bridge                          -- READ FRESH
  if not bridge
     or type(bridge.is_connected) ~= "function"
     or not bridge.is_connected() then
    return false                                                    -- silent degrade (Tab → indent)
  end
  local coords = require("pi-bridge.coords")
  local pi = coords.nvim_to_pi_coords(lines, cur[1], cur[2])         -- {lines, cursorLine, cursorCol(UTF-16)}
  -- beforeCursor (UTF-16→byte slice — pi.cursorCol is UTF-16; pi.lines[cursorLine] is UTF-8).
  local line_str = pi.lines[pi.cursorLine + 1] or ""       -- pi cursorLine is 0-based → Lua 1-based (the SAME +1 coords uses)
  local bok, byte_end = pcall(coords.utf16_to_byte, line_str, pi.cursorCol)
  if not bok or type(byte_end) ~= "number" then byte_end = #line_str end -- defensive (utf16_to_byte is pure; shouldn't fail)
  local before  = line_str:sub(1, byte_end)
  local trimmed = (before:gsub("^%s+", "")) or ""                   -- trimStart
  local is_slash_ctx = (pi.cursorLine == 0) and trimmed:sub(1, 1) == "/" -- isSlashMenuAllowed (cursorLine===0) + trimStart starts "/"
  local no_space     = not trimmed:find(" ")                            -- !trimStart().includes(" ")
  -- ── BRANCH 2a (slash command, force:false): pi handleSlashCommandCompletion ──
  if is_slash_ctx and no_space then
    force_fetch(buf, pi, { force = false }, _route_or_accept(buf, false))
    return true                                                     -- Tab CONSUMED
  end
  -- ── BRANCH 2b (file force, force:true): pi forceFileAutocomplete → shouldTriggerFileCompletion guard ──
  -- Consulted ONLY on the force:true path (pi requestAutocomplete:2150 guards only when force).
  pcall(bridge.request, "shouldTriggerFileCompletion",
    { lines = pi.lines, cursorLine = pi.cursorLine, cursorCol = pi.cursorCol },
    function(err, trig)
      if err or trig ~= true then return end                        -- false/no-op (Tab already consumed)
      force_fetch(buf, pi, { force = true }, _route_or_accept(buf, true))
    end)
  return true                                                       -- Tab CONSUMED
end

-- ===========================================================================
-- S36: on_next(buf) / on_prev(buf) / on_dismiss(buf) — the navigation/dismiss keymap
-- handlers. The ftplugin ALREADY dispatches <C-N>/<Down>→on_next, <S-Tab>/<C-P>/<Up>→on_prev,
-- <C-E>→on_dismiss. Each gates like on_enter/on_tab (buf valid+current + menu state) and
-- delegates to menu.next/prev/dismiss. Returns true (key CONSUMED) only when the menu is
-- open; false → the ftplugin feeds the literal key (normal insert-mode behavior). Never
-- throws (type-guards + nvim_buf_is_valid; the ftplugin's dispatch is also pcall-wrapped).
-- Read menu FRESH (require at call time — handshake async + test fakes + /reload).
-- API-safe (main loop — same contract as on_enter/on_tab/do_refresh). (research/notes.md §4.)
-- ===========================================================================

--- The `<C-N>`/`<Down>` handler (the ftplugin ALREADY dispatches on_next). Returns true (key
--- consumed) iff buf is valid+current AND the menu is open with items → menu.next().
--- Otherwise false (the key falls through to its default). Never throws.
---
---@param buf integer The pi-prompt buffer handle (from the buffer-local keymap dispatch).
---@return boolean handled true iff the key was consumed (selection advanced).
function M.on_next(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end    -- one buf/session (PRD §11)
  local menu = require("pi-bridge.menu")                            -- READ FRESH
  if not menu.is_open() or not menu.has_items() then return false end
  menu.next()
  return true                                                       -- key CONSUMED (cursor does NOT move)
end

--- The `<S-Tab>`/`<C-P>`/`<Up>` handler. Symmetric to on_next → menu.prev(). Never throws.
---
---@param buf integer The pi-prompt buffer handle.
---@return boolean handled true iff the key was consumed (selection retreated).
function M.on_prev(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end
  local menu = require("pi-bridge.menu")
  if not menu.is_open() or not menu.has_items() then return false end
  menu.prev()
  return true
end

--- The `<C-E>` handler (the ftplugin ALREADY dispatches on_dismiss). Returns true (key
--- consumed) iff buf is valid+current AND the menu is open → menu.dismiss(). Otherwise
--- false (C-E falls through to :help i_CTRL-E insert-char-below). Never throws.
--- (on_dismiss is S36 — the KEY handler; the auto-close AUTOCMDS are S37.
--- research/notes.md §7.)
---
---@param buf integer The pi-prompt buffer handle.
---@return boolean handled true iff the key was consumed (menu dismissed).
function M.on_dismiss(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end
  local menu = require("pi-bridge.menu")
  if not menu.is_open() then return false end                       -- has_items implied by open()'s contract
  menu.dismiss()
  return true
end

-- ===========================================================================
-- S37: on_insert_leave(buf) / on_buf_leave(buf) — the AUTOCMD-driven auto-close handlers
-- (the complement to S36's KEY handlers). The ftplugin dispatches InsertLeave→on_insert_leave +
-- BufLeave→on_buf_leave (buffer-local, the "pi-bridge" augroup). Each hides the menu + CANCELS the
-- pending debounced refresh so a stale do_refresh cannot re-open the menu in normal mode (THE race
-- fix — research/notes.md §1; reset()'s docstring promised it for S37). The "CursorMoved out of
-- prefix" trigger is OWNED by the EXISTING CursorMovedI→refresh→re-fetch→empty→close path (S30,
-- COMPLETE — research §3; no local prefix detector). Fire-and-forget (autocmd; return value ignored);
-- never throws (pcall; type-guard; nvim_buf_is_valid). Read menu FRESH (require at call time).
-- Does NOT detach the menu (M.reset is completion's, not menu's) — re-entry re-populates w/o re-attach.
-- ===========================================================================

--- The shared S37 teardown: hide the window FIRST (immediate UX), then cancel the pending debounce +
--- in-flight RPC + clear completion state (M.reset sets state.gen=0 → a stale getSuggestions cb's
--- gen-guard drops it → the stale on_results never fires → no normal-mode re-open). Never throws
--- (menu.close + M.reset are both idempotent + pcall-safe). (research/notes.md §1/§6.)
local function hide_and_cancel()
  pcall(function() require("pi-bridge.menu").close() end)   -- hide the floating window FIRST
  M.reset()                                                  -- cancel_timer + cancel inflight + gen=0 + clear state
end

--- InsertLeave handler (autocmd-fired by the ftplugin). Hides the menu + cancels the pending refresh
--- so a stale do_refresh cannot re-open the menu in normal mode. No-op when the menu is closed +
--- nothing pending (menu.close/M.reset are idempotent + never throw). Never throws.
---@param buf integer The pi-prompt buffer handle (from the buffer-local InsertLeave autocmd).
function M.on_insert_leave(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  hide_and_cancel()
end

--- BufLeave handler (autocmd-fired by the ftplugin). Same teardown as on_insert_leave; clearing
--- state.buf/last_result is correct since we left the buffer (the next refresh on a future pi-prompt
--- buffer rebuilds). Never throws. (research/notes.md §4/§6.)
---@param buf integer The pi-prompt buffer handle (from the buffer-local BufLeave autocmd).
function M.on_buf_leave(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  hide_and_cancel()
end

-- ===========================================================================
-- S41: on_commands_changed(buf?) — react to the `commandsChanged` server→client
-- notification (PRD §5.4 / §13 step 13 / §11). The MECHANISM is DONE: S27's
-- `bridge.on_notification("commandsChanged", handler)` (schedule_wrap'd → api-safe)
-- routes the notification to the handler `init.lua` registers in `M.activate()`.
-- THIS fn is the BEHAVIOR: clear the completion cache (the menu's rendered items were
-- computed against the OLD command set + may now be stale — a command added/removed/
-- renamed, a new prompt template) + close the stale menu, then CONDITIONALLY re-query
-- via `M.refresh(buf)` so a *live* menu reflects the rebuilt provider — WITHOUT
-- spuriously popping a menu when the user is not actively completing (PRD §11: "Reload
-- during an open editor … The open editor's existing connection stays valid.").
--
-- WHY `was_open` (NOT vim.fn.mode()): menu.is_open() is the PRECISE "actively completing
-- with visible suggestions" signal + is trivially observable in a headless plenary test
-- (via populated_menu). vim.fn.mode() is fiddly to drive deterministically headless.
-- WHY BUMP gen (NOT zero — contrast reset() which zeroes + nils buf): the gen-guard
-- idiom (`gen ~= state.gen` → drop) is shared with do_refresh/force_fetch. Bumping
-- (forward) is clearer than zeroing; both drop a late stale cb whose captured gen is
-- now stale. We PRESERVE `state.buf` so the re-query can target the pi-prompt buffer
-- (reset() nils it → the re-query would have nothing to target).
-- WHY the provider gates context itself: pi's getSuggestions returns null (→ empty →
-- menu.close) for non-trigger cursor positions, so a re-query never spuriously re-opens
-- the menu. (The empty-result non-refresh edge does NOT re-query — accepted minor; the
-- next keystroke fetches fresh; PRD §11 "existing connection stays valid" is satisfied.)
--
-- NEVER throws (out-of-band event; pcall every external call). Idempotent (safe to fire
-- twice). Called by init.lua's `commandsChanged` registration. (research/notes.md §5.)
-- ===========================================================================

--- S41 — Clear the completion cache + close the stale menu; iff a menu WAS open (actively
--- completing) + `buf` valid+current, re-query so the menu reflects the rebuilt provider.
--- Called by init.lua's `commandsChanged` registration (S41; consumes S27's on_notification).
--- Idempotent + never throws (out-of-band event; pcall every external call). PRESERVES
--- `state.buf` (contrast `M.reset()`, which nils it) so the re-query can target the pi-prompt buf.
---@param buf integer? The pi-prompt buffer (defaults to state.buf).
function M.on_commands_changed(buf)
  buf = buf or state.buf
  local was_open = false
  pcall(function() was_open = require("pi-bridge.menu").is_open() end) -- capture BEFORE close (the "actively completing" signal)
  cancel_timer()                                              -- stop()+close() the pending defer (leak fix; NEVER stop-only)
  local b = require("pi-bridge").bridge                       -- READ FRESH (handshake async; test mocks swap in after require)
  if state.inflight_id and b and type(b.cancel) == "function" then
    pcall(b.cancel, state.inflight_id)                        -- supersede layer 1 (cancel the in-flight getSuggestions)
  end
  state.inflight_id = nil
  state.last_result = nil                                     -- CLEAR THE CACHE (the stale items)
  state.gen = state.gen + 1                                   -- supersede layer 2 (drop a late stale cb via the gen-guard)
  pcall(function() require("pi-bridge.menu").close() end)     -- clear the menu's OWN stale items (menu holds its own copy)
  if not was_open then return end                             -- not actively completing → next keystroke fetches fresh
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  if buf ~= vim.api.nvim_get_current_buf() then return end    -- one buf/session (PRD §11)
  pcall(M.refresh, buf)                                       -- re-query (debounced; the provider gates non-trigger context itself)
end

return M