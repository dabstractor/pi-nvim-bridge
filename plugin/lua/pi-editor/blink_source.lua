--- blink_source.lua — an OPT-IN [blink.cmp](https://github.com/Saghen/blink.cmp) completion
-- source that exposes pi's **live** `AutocompleteProvider` (slash commands, `skill:`
-- templates, argument completions, `@file` mentions, paths) through blink's source
-- interface — by delegating to the COMPLETE in-tree bridge + coords modules. This is
-- Component B §7.7's first optional integration (P4). The source is DORMANT outside pi
-- prompt buffers and NEVER requires blink.cmp at runtime.
--
-- WHAT THE USER REGISTERS (in THEIR blink.cmp config — NOT this repo's setup()):
--   {
--     "Saghen/blink.cmp",
--     opts = {
--       sources = {
--         default = { "pi" },
--         providers = { pi = { name = "pi", module = "pi-editor.blink_source" } },
--       },
--     },
--   }
--
-- [Mode A] header — read before editing:
--  * ROLE: a `blink.cmp.Source` ADAPTER. It maps pi's live provider (over the existing
--    Unix-socket bridge) into blink's `get_trigger_characters` / `enabled` /
--    `get_completions` / `execute` source contract. It owns NO buffer, NO socket, NO
--    menu — it is a pure RPC→item-mapping adapter. All insertion is delegated to pi's
--    authoritative `applyCompletion` (via `execute`), so accept is byte-for-byte
--    identical to pi's TUI (PRD §1 Goal).
--
--  * NEVER `require("blink.cmp")` AT RUNTIME (CRITICAL — the load-bearing dormant rule):
--    blink.cmp is the USER's plugin, NOT a project dependency. A runtime `require` would
--    ERROR when blink isn't installed (the COMMON case for builtin-menu / nvim-cmp users)
--    and break dormant-by-default. Reference blink types ONLY via emmy `---@module
--    'blink.cmp'` COMMENTS (mirrors codecompanion's blink provider line 1). Verified at
--    test time: `package.loaded["blink.cmp"]` stays `nil` after requiring this module.
--
--  * THE ACCEPT DESIGN — `execute` OVERWRITES WHOLESALE (the load-bearing decision):
--    blink applies the item's `textEdit` BEFORE calling `execute(ctx, item, callback,
--    default_implementation)` (confirmed against blink's
--    `lua/blink/cmp/sources/lib/init.lua` master: "execute — After textEdit"). So by the
--    time `execute` runs, the buffer already has blink's edit. WE then overwrite the
--    WHOLE buffer with pi's `applyCompletion` result in the async cb — blink's textEdit
--    is a TRANSIENT that gets clobbered. The textEdit is therefore only a GRACEFUL
--    FALLBACK insertion (newText=pi.value); `applyCompletion` (in execute) is AUTHORITATIVE.
--    Consequences (Anti-Patterns avoided):
--      - Do NOT reimplement insertion in the textEdit (trailing space, quotes, cursor) —
--        `execute`→`applyCompletion` is authoritative; the textEdit is the fallback.
--      - Do NOT call `default_implementation()` in execute (we overwrite wholesale, NOT
--        compose with blink's snippet logic).
--      - Do NOT "clear the keyword" in execute (codecompanion clears because it does NOT
--        full-buffer-replace; we DO → redundant).
--
--  * CALL blink's `callback` EXACTLY ONCE per get_completions / execute, or blink's
--    accept HANGS. On get_completions error/timeout/cancel → `callback()` (nil). On
--    execute, call `callback()` IMMEDIATELY after issuing `applyCompletion` (responsive;
--    NEVER hangs blink even if the RPC times out — the buffer mutation is async
--    fire-and-forget in the cb, mirrors completion.lua's on_enter returning true once
--    issued).
--
--  * bridge.request cb IS schedule_wrap'd → api-safe (main loop). Do NOT wrap blink's
--    callback in `vim.schedule_wrap` (a needless hop — mirrors completion.lua). Contrast
--    blink's path source, which DOES wrap because ITS completion runs in a luv cb; OURS
--    runs in the bridge's already-schedule_wrap'd cb.
--
--  * GOTCHA: nvim_win_set_cursor col is 0-based BYTE (coords.pi_to_nvim_coords returns
--    EXACTLY that). NO `-1` (PRD §7.4's `bytecol - 1` is superseded by coords.lua's
--    exact-UTF-16 design — see coords.lua header).
--
--  * GOTCHA: read the bridge + coords FRESH at call time (`require("pi-editor").bridge`
--    INSIDE the fn, NOT a module-load local). The handshake resolves ASYNC after
--    VimEnter; tests swap fakes in AFTER require; /reload re-runs activate. Caching
--    breaks all three. (Same rule as completion.lua do_refresh.)
--
--  * GOTCHA: supersession is TWO layers (mirrors completion.lua do_refresh).
--      Layer 1 (optimization): `bridge.cancel(prev_id)` (frees the round-trip).
--      Layer 2 (CORRECTNESS boundary): capture `ctx.id` in the cb closure; ignore the cb
--        if `ctx.id` changed (`state.current_id`). cancel can RACE (a response can land
--        between cancel and the new request); the id-guard CANNOT. Do BOTH.
--
--  * GOTCHA: blink items ADD `source_id`/`source_name`/`cursor_column`/`score` themselves
--    (blink types.lua). We set ONLY lsp fields + label + kind + detail + textEdit + data.
--    `data` is the ONLY field that round-trips our pi item + pre-accept snapshot into
--    `execute()` (blink passes the accepted item — including `data` — back to us).
--
--  * GOTCHA: lsp.CompletionItemKind values: 17=File, 19=Folder, 14=Keyword, 3=Function,
--    1=Text. Map pi items cosmetically (pi items don't carry a kind): slash/template/
--    skill (value starts with "/") → Keyword; `@file` → File; directory → Folder; else →
--    Text. Defensive: if pi item lacks a kind hint, use Text.
--
--  * NEVER THROWS (pcall every bridge/nvim call; type-guards; malformed `item.data` →
--    `callback()` + degrade). A throw out of get_completions/execute would abort blink's
--    accept pipeline.
--
--  * KNOWN FORWARD-CONTRACT (out of scope for S45; documented for the follow-up): when
--    `config.engine == "blink"`, the builtin menu autocmds (ftplugin→completion.lua→
--    menu.lua) should be SUPPRESSED by a FUTURE engine-wiring task to avoid double-UI.
--    S45's module is correct standalone + additive. The source module READS
--    `config.engine` only to degrade (no behavioral change in S45).
--
-- Node builtins analog: pure Lua + the COMPLETE in-tree bridge
-- (`require("pi-editor").bridge`) + coords (`require("pi-editor.coords")`) + config
-- (`require("pi-editor")`). No sockets of its own — the smoke's fake luv server is the
-- integration surface. Singleton state (mirrors completion.lua's `state` shape, NOT
-- coords.lua's stateless shape — the source HAS supersession state).

---@module 'blink.cmp'  -- emmy TYPE-HINT ONLY (never a runtime require; blink is the user's plugin)

local M = {}

--- Singleton source supersession state. One blink provider entry → one source object, but
--- the supersession counters are module-level (one pi-prompt buffer per session, PRD §11).
--- `current_id` is the LATEST `ctx.id` seen in get_completions (the gen-guard boundary);
--- `inflight_id` is the bridge.request id of the in-flight getSuggestions (for bridge.cancel).
--- Mirrors completion.lua's `state.gen` / `state.inflight_id` pair (named distinctly so a
--- reader does not confuse them).
---@class pi-editor.BlinkSourceState
---@field current_id  any       the latest ctx.id seen in get_completions (supersession guard)
---@field inflight_id string?   the bridge.request id of the in-flight getSuggestions (for bridge.cancel)
local state = { current_id = nil, inflight_id = nil }

--- TEST-ONLY reset of the module-level supersession state (`current_id` / `inflight_id`).
--- Exported so plenary specs can isolate cases (mirrors completion.lua's `M.reset()`
--- seam). Idempotent + never throws. NOT part of the blink source contract — never call
--- from user code / blink.cmp.
function M._reset_for_test()
  state.current_id = nil
  state.inflight_id = nil
end

-- ===========================================================================
-- Internals (forward declaration; defined below)
-- ===========================================================================
local map_item   -- (pi_item, pi_coords, prefix) → blink lsp.CompletionItem (the item mapper)
local guess_kind -- (pi_item) → vim.lsp.protocol.CompletionItemKind (cosmetic kind)

-- ===========================================================================
-- new + get_trigger_characters + enabled — the source skeleton (Task 1).
-- Mirrors codecompanion's `providers/completion/blink/init.lua`: M.new() returns a
-- setmetatable'd table with `__index = M`; the methods are colon-style. opts is the
-- blink provider config (read pi config LIVE; accept + ignore opts).
-- ===========================================================================

--- Construct a blink.cmp source object. `opts` is the blink provider config table
--- (e.g. `{ name = "pi", module = "pi-editor.blink_source" }`); accepted + ignored — the
--- source reads pi's config LIVE at call time (`require("pi-editor").config`). Returns a
--- fresh table whose metatable is `M` (the codecompanion pattern). The object is
--- stateless; supersession state is module-level (one pi-prompt buffer per session).
---@param opts table? The blink provider config (ignored — pi config is read live).
---@return table source A blink.cmp source object (`new`/`get_trigger_characters`/`enabled`/`get_completions`/`execute`).
function M.new(opts) -- luacheck: ignore opts (accepted for blink's contract; unused by design)
  return setmetatable({}, { __index = M })
end

--- The trigger characters that start a pi completion context (blink calls this to decide
--- when to fire `get_completions`). Returns pi's two trigger chars: `/` (slash commands +
--- `skill:` templates) and `@` (file mentions + paths). `#` (the attachment context
--- completion.lua's `is_attachment_context` also matches) is OPTIONAL — pi's TUI does not
--- treat it as a hard trigger, so we omit it to match the TUI's menu-pop timing.
---@return string[] chars The trigger characters.
function M:get_trigger_characters()
  return { "/", "@" }
end

--- Source-level dormancy gate — the twin of `init.lua`'s VimEnter activation gate. Returns
--- `true` ONLY in a `pi-prompt` buffer (so the source is SAFE to register GLOBALLY in a
--- blink config; it never fires in ordinary buffers). blink calls `enabled()` before
--- `get_completions`, so a `false` return short-circuits the whole pipeline (no RPC, no
--- menu). Never throws.
---@return boolean enabled `true` iff the current buffer's filetype is `pi-prompt`.
function M:enabled()
  return vim.bo.filetype == "pi-prompt"
end

-- ===========================================================================
-- map_item + guess_kind — the pi→blink item mapper (Task 3).
-- Builds a blink lsp.CompletionItem from a pi AutocompleteItem. The `textEdit.range` is
-- derived from the cursor + pi's prefix via coords (0-based line + 0-based UTF-16
-- character — the lsp.Range contract). The `data` field round-trips the pi item + the
-- pre-accept snapshot into `execute()`.
-- ===========================================================================

--- Guess the cosmetic lsp.CompletionItemKind for a pi item (for the icon/sort). pi items
--- do NOT carry a kind; this is a SIMPLE, DEFENSIVE heuristic:
---   * value starts with `/` → Keyword (14) — slash commands / `skill:` templates.
---   * value starts with `@` → File (17) — file mentions.
---   * value ends with `/` → Folder (19) — a directory.
---   * else → Text (1) — defensive default.
--- Never throws (type-guard `pi_item`).
---@param pi_item pi-editor.AutocompleteItem The pi item.
---@return integer kind A `vim.lsp.protocol.CompletionItemKind` value.
guess_kind = function(pi_item)
  local ItemKind = vim.lsp.protocol.CompletionItemKind
  if type(pi_item) ~= "table" then return ItemKind.Text end
  local v = (type(pi_item.value) == "string") and pi_item.value or ""
  -- a value ending in "/" is a DIRECTORY regardless of prefix (an @file mention that resolves
  -- to a dir is still a Folder for icon/sort purposes).
  if v:sub(-1) == "/" then return ItemKind.Folder end
  if v:sub(1, 1) == "/" then return ItemKind.Keyword end -- slash commands / skill: templates
  if v:sub(1, 1) == "@" then return ItemKind.File end    -- file mentions
  return ItemKind.Text
end

--- Map a pi AutocompleteItem → a blink lsp.CompletionItem. The item carries:
---   * `label`     — the pi item's label (shown in the menu).
---   * `kind`      — the cosmetic kind (guess_kind).
---   * `detail`    — the pi item's description (shown beside the label).
---   * `textEdit`  — `{ newText = pi_item.value, range = {start, ["end"]} }` — the GRACEFUL
---                   FALLBACK insertion (applyCompletion in execute is AUTHORITATIVE). The
---                   range is a valid lsp.Range (0-based line + 0-based UTF-16 character)
---                   covering pi's `prefix` at the cursor.
---   * `data`      — the round-trip snapshot: `{ pi, prefix, lines, cursorLine, cursorCol }`
---                   (see pi-editor.BlinkItemData). Forwarded VERBATIM to applyCompletion.
---
--- The range is derived via coords: `line = pi_coords.cursorLine` (0-based);
--- `end_char = pi_coords.cursorCol` (already UTF-16); `start_char = end_char - utf16_len
--- (prefix)` where `utf16_len(prefix)` is computed from the cursor line via coords
--- (`coords.byte_to_utf16(line, #prefix)`). Defensive: clamp `start_char >= 0`.
---
--- NEVER throws (type-guards `pi_item`/`pi_coords`; `or ""` line guard). `pi_item` is
--- forwarded VERBATIM (the bridge server forwards it verbatim to pi; pi keys on the whole
--- table — completion.lua accept does the same).
---@param pi_item  pi-editor.AutocompleteItem The pi item (forwarded VERBATIM in data.pi).
---@param pi_coords pi-editor.PiCoords          The pi coords {lines, cursorLine, cursorCol} (from nvim_to_pi_coords).
---@param prefix    string                      The getSuggestions result.prefix (applyCompletion's prefix).
---@return table item A blink lsp.CompletionItem.
map_item = function(pi_item, pi_coords, prefix)
  local coords = require("pi-editor.coords")
  local line = pi_coords.cursorLine or 0
  local end_char = pi_coords.cursorCol or 0
  -- start_char = end_char - utf16_len(prefix). Compute utf16_len(prefix) from the cursor
  -- line: the prefix is a PREFIX of the text before the cursor, so its UTF-16 length =
  -- coords.byte_to_utf16(cursor_line, #prefix). Defensive: clamp >= 0.
  local cursor_line = ""
  if type(pi_coords.lines) == "table" then
    cursor_line = pi_coords.lines[(pi_coords.cursorLine or 0) + 1] or "" -- pi 0-based → Lua 1-based
  end
  local prefix_byte_len = (type(prefix) == "string") and #prefix or 0
  local utf16_len_prefix = coords.byte_to_utf16(cursor_line, prefix_byte_len)
  local start_char = end_char - utf16_len_prefix
  if start_char < 0 then start_char = 0 end -- clamp (defensive; a real cursor is always in-range)
  return {
    label   = pi_item.label,
    kind    = guess_kind(pi_item),
    detail  = (type(pi_item.description) == "string") and pi_item.description or nil,
    textEdit = {
      newText = pi_item.value,
      range   = {
        start = { line = line, character = start_char },
        ["end"] = { line = line, character = end_char },
      },
    },
    data = {
      pi         = pi_item,                          -- forwarded VERBATIM to applyCompletion's `item`
      prefix     = (type(prefix) == "string") and prefix or "",
      lines      = pi_coords.lines,                  -- the buffer lines at getSuggestions issue time
      cursorLine = pi_coords.cursorLine,             -- 0-indexed pi line
      cursorCol  = pi_coords.cursorCol,              -- 0-indexed UTF-16 pi col
    },
  }
end

-- ===========================================================================
-- get_completions — the data faucet (Task 2).
-- Reads the buffer + cursor, converts nvim→pi via coords, issues `getSuggestions` over
-- the bridge (TWO-LAYER supersession via ctx.id + bridge.cancel), maps pi items → blink
-- lsp.CompletionItems, and calls blink's `callback` EXACTLY ONCE. Error/nothing →
-- `callback()` (nil). Mirrors completion.lua's do_refresh (RPC shapes, two-layer
-- supersession, "bridge read fresh", null→empty, error→touch-nothing) — adapted: we call
-- blink's `callback` instead of firing a menu seam, and use `ctx.id` as the gen.
-- ===========================================================================

--- The get_completions handler (blink calls this on a trigger char / typing). Reads the
--- buffer + cursor, converts nvim→pi via coords, issues `getSuggestions` over the bridge
--- with `{lines, cursorLine, cursorCol, force=false}` (EXACT shape completion.lua uses),
--- superseds (two-layer), maps pi items → blink items, and calls `callback` ONCE with
--- `{is_incomplete_forward=false, is_incomplete_backward=false, items}`. Error/timeout/
--- cancel → `callback()` (nil). NEVER throws; NEVER hangs blink (callback always called
--- once). Do NOT wrap `callback` in vim.schedule_wrap (the bridge cb already runs on the
--- main loop).
---
---@param ctx      table   The blink context (`ctx.bufnr`, `ctx.id`, `ctx.bounds`, `ctx.line`, …).
---@param callback fun(resp?:table) blink's completion callback; call ONCE with the response table OR `callback()` (nil).
function M:get_completions(ctx, callback)
  -- DEFENSIVE: a nil ctx is a caller bug (blink always passes one) — degrade to callback().
  if type(ctx) ~= "table" then return callback() end
  -- READ BRIDGE FRESH (handshake resolves async + test mocks swap in after require).
  local bridge = require("pi-editor").bridge
  if not bridge
     or type(bridge.is_connected) ~= "function"
     or not bridge.is_connected() then
    return callback()                                -- nothing (graceful; matches blink's path source)
  end
  -- READ buffer + cursor (api-safe — the bridge cb path is scheduled; but get_completions
  -- itself runs on the main loop, so direct nvim calls are fine). Guard buf valid.
  local bufnr = (ctx and type(ctx.bufnr) == "number") and ctx.bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) then return callback() end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cur   = vim.api.nvim_win_get_cursor(0)       -- {row 1-based, col 0-based byte}
  -- CONVERT nvim→pi (S29 — THE centralized seam). `pi.lines` is the SAME reference as
  -- `lines`, so the result drops straight into the RPC params.
  local pi_coords = require("pi-editor.coords").nvim_to_pi_coords(lines, cur[1], cur[2])
  -- SUPERSEDE layer 1 (cancel prev in-flight — optimization; frees the round-trip).
  if state.inflight_id and type(bridge.cancel) == "function" then
    pcall(bridge.cancel, state.inflight_id)
  end
  state.inflight_id = nil
  -- SUPERSEDE layer 2 (ctx.id guard — the CORRECTNESS boundary; captured in the cb closure).
  local my_id = ctx and ctx.id
  state.current_id = my_id
  local params = vim.tbl_extend("keep", pi_coords, { force = false }) -- {lines,cursorLine,cursorCol,force=false}
  -- ISSUE (pcall so a bridge bug never throws out of blink's pipeline).
  local ok, rid = pcall(bridge.request, "getSuggestions", params, function(err, result)
    if my_id ~= state.current_id then return end     -- STALE (superseded) — drop, touch nothing
    state.inflight_id = nil
    if err then return callback() end                -- timeout/cancel/rpc error → nothing (no throw, no stale items)
    -- NORMALIZE: null result (cb(nil,nil)) = SUCCESS with empty items, NOT an error.
    local items  = (result and type(result.items)  == "table")  and result.items  or {}
    local prefix = (result and type(result.prefix) == "string") and result.prefix or ""
    -- MAP (defensive: skip non-table pi items). vim.tbl_map/filter are pure; safe here.
    local blink_items = {}
    for _, it in ipairs(items) do
      if type(it) == "table" then
        blink_items[#blink_items + 1] = map_item(it, pi_coords, prefix)
      end
    end
    callback({
      is_incomplete_forward  = false,
      is_incomplete_backward = false,
      items                  = blink_items,
    })
  end)
  if not ok then return callback() end               -- bridge.request itself threw → nothing
  if type(rid) == "string" then state.inflight_id = rid end
end

-- ===========================================================================
-- execute — accept via applyCompletion (Task 4).
-- Reads the pre-accept snapshot from `item.data`, issues `applyCompletion` over the
-- bridge, calls `callback()` IMMEDIATELY (responsive; NEVER hangs blink), and in the
-- async cb overwrites the WHOLE buffer + sets the cursor from pi's authoritative result.
-- Mirrors completion.lua's accept() (the 5-step applyCompletion flow) — adapted: the
--- lines/cursor come from the snapshot (captured at get_completions time), NOT live.
-- ===========================================================================

--- The execute (accept) handler (blink calls this AFTER applying the item's textEdit).
--- Reads the pre-accept snapshot from `item.data`, issues `applyCompletion` with
--- `{lines, cursorLine, cursorCol, item, prefix}` (EXACT shape completion.lua accept
--- uses), calls `callback()` IMMEDIATELY (responsive; the buffer mutation is async
--- fire-and-forget in the cb), and in the async cb overwrites the WHOLE buffer + sets the
--- cursor (0-based byte col, NO `-1`) from pi's authoritative result. Also best-effort
--- closes the builtin menu if open (avoid a stale builtin popup lingering when the user
--- accepted via blink). NEVER throws; NEVER fails to call `callback()` (malformed
--- `item.data`, nil bridge, wiped buf → `callback()` + degrade). Do NOT call
--- `default_implementation` (we overwrite wholesale, not compose with blink's snippet).
---
---@param ctx                   table   The blink context (`ctx.bufnr`).
---@param item                  table   The accepted blink item (its `data` carries the snapshot).
---@param callback              fun()   blink's execute callback; call ONCE.
---@param default_implementation fun()  blink's default (UNUSED — we overwrite wholesale).
function M:execute(ctx, item, callback, default_implementation) -- luacheck: ignore default_implementation
  -- DEFENSIVE: malformed item.data → tell blink "done"; never hang; never throw.
  local d = item and item.data
  if type(d) ~= "table" or type(d.pi) ~= "table" then return callback() end
  -- READ BRIDGE FRESH (handshake resolves async + test mocks swap in after require).
  local bridge = require("pi-editor").bridge
  if not bridge
     or type(bridge.is_connected) ~= "function"
     or not bridge.is_connected() then
    return callback()                                -- graceful: blink's textEdit already applied pre-execute
  end
  local bufnr = (ctx and type(ctx.bufnr) == "number") and ctx.bufnr or 0
  -- ISSUE applyCompletion with the snapshot (EXACT shape completion.lua accept uses).
  local params = {
    lines      = d.lines,
    cursorLine = d.cursorLine,
    cursorCol  = d.cursorCol,
    item       = d.pi,                               -- forwarded VERBATIM
    prefix     = d.prefix,
  }
  pcall(bridge.request, "applyCompletion", params, function(err, result)
    -- async, schedule_wrap'd by bridge → nvim main loop (api-safe; NO extra vim.schedule).
    if err or type(result) ~= "table" then return end -- degrade: buffer left as blink's textEdit
    local nv = require("pi-editor.coords").pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)
    -- WHOLE buffer replace (nvim_buf_set_lines does NOT fire TextChangedI → no refresh loop;
    -- completion.lua §5 Q2). pcall so a wiped buf / odd state never throws.
    pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, nv.lines)
    pcall(vim.api.nvim_win_set_cursor, 0, { nv.row, nv.col }) -- 0-based byte col, NO -1
    -- close a stale builtin menu if open (defensive; never throws). Avoids a lingering
    -- builtin popup when the user accepted via blink.
    pcall(function() require("pi-editor.menu").close() end)
  end)
  callback()                                        -- IMMEDIATE: never hang blink (RPC is fire-and-forget)
end

return M