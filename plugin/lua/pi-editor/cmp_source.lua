--- cmp_source.lua — an OPT-IN [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) completion
--- source that exposes pi's **live** `AutocompleteProvider` (slash commands, `skill:`
--- templates, argument completions, `@file` mentions, paths) through nvim-cmp's source
--- interface — by delegating to the COMPLETE in-tree bridge + coords modules. This is
--- Component B §7.7's second optional integration (P4) and the DIRECT ANALOG of the
--- COMPLETE `blink_source.lua` (S45). The source is DORMANT outside pi prompt buffers
--- and NEVER requires nvim-cmp at runtime.
---
--- WHAT THE USER REGISTERS (in THEIR nvim-cmp config — NOT this repo's setup()):
---   require("cmp").setup({
---     sources = cmp.config.sources({ { name = "pi" } }),
---   })
---   -- register ONCE (e.g. in the cmp config or a lazy.nvim `config` fn):
---   require("cmp").register_source("pi", require("pi-editor.cmp_source").new())
---
--- [Mode A] header — read before editing:
---  * ROLE: an `nvim-cmp` SOURCE ADAPTER (the classic module convention used by
---    `cmp-buffer` / `cmp-path` / `codecompanion-cmp`). It maps pi's live provider
---    (over the existing Unix-socket bridge) into nvim-cmp's `is_available` /
---    `get_trigger_characters` / `get_keyword_pattern` / `complete` / `execute` source
---    contract. It owns NO buffer, NO socket, NO menu — it is a pure RPC→item-mapping
---    adapter. All insertion is delegated to pi's authoritative `applyCompletion` (via
---    `execute`), so accept is byte-for-byte identical to pi's TUI (PRD §1 Goal). This
---    module is the near-verbatim nvim-cmp-flavored twin of `blink_source.lua` (S45) —
---    `map_item` / `guess_kind` / the execute cb body port VERBATIM; only the method
---    names, the ctx→request arg shape, the callback success-shape, and the execute
---    signature differ.
---
---  * NEVER `require("cmp")` AT RUNTIME (CRITICAL — the load-bearing dormant rule):
---    nvim-cmp is the USER's plugin, NOT a project dependency. A runtime `require` would
---    ERROR when nvim-cmp isn't installed (the COMMON case for builtin-menu / blink
---    users) and break dormant-by-default. Unlike blink (lazy `module=` registration),
---    nvim-cmp registration is the USER's EXPLICIT `require("cmp").register_source("pi",
---    …)` call in THEIR config — we reference cmp's contract ONLY via the method names +
---    this docstring (no emmy `@module 'cmp'` needed; cmp's contract is method-name-based,
---    not type-based). Verified at test time: `package.loaded["cmp"]` stays `nil` after
---    requiring this module.
---
---  * THE ACCEPT DESIGN — `execute` OVERWRITES WHOLESALE (the load-bearing decision):
---    nvim-cmp applies the item's `textEdit` BEFORE calling `execute(completion_item,
---    callback)` (confirmed against `:help cmp-development`: execute is the CONFIRM hook,
---    run after the item's textEdit). So by the time `execute` runs, the buffer already
---    has cmp's edit. WE then overwrite the WHOLE buffer with pi's `applyCompletion`
---    result in the async cb — cmp's textEdit is a TRANSIENT that gets clobbered. The
---    textEdit is therefore only a GRACEFUL FALLBACK insertion (newText=pi.value);
---    `applyCompletion` (in execute) is AUTHORITATIVE. Consequences (Anti-Patterns
---    avoided):
---      - Do NOT reimplement insertion in the textEdit (trailing space, quotes, cursor) —
---        `execute`→`applyCompletion` is authoritative; the textEdit is the fallback.
---      - Do NOT expect a `ctx`/`request`/`default_implementation` argument in `execute`
---        — nvim-cmp's `execute(completion_item, callback)` takes NEITHER (unlike blink's
---        `execute(ctx, item, callback, default_implementation)`). THEREFORE the buffer
---        handle MUST be carried on `completion_item.data.bufnr` (captured at `complete`
---        time). On accept, read `bufnr` from the snapshot, NOT from a ctx.
---
---  * CALL nvim-cmp's `callback` EXACTLY ONCE per complete / execute, or cmp's
---    complete/confirm STALLS. On complete error/timeout/cancel → `callback()` (nil). On
---    execute, call `callback(completion_item)` IMMEDIATELY after issuing
---    `applyCompletion` (responsive; NEVER stalls cmp even if the RPC times out — the
---    buffer mutation is async fire-and-forget in the cb; mirrors completion.lua's
---    on_enter returning true once issued). Pass `completion_item` back to callback
---    (cmp convention; never nil).
---
---  * bridge.request cb IS schedule_wrap'd → api-safe (main loop). Do NOT wrap nvim-cmp's
---    callback in `vim.schedule_wrap` (a needless hop — mirrors completion.lua +
---    blink_source). Contrast cmp's path source, which DOES wrap because ITS completion
---    runs in a luv cb; OURS runs in the bridge's already-schedule_wrap'd cb.
---
---  * GOTCHA: nvim_win_set_cursor col is 0-based BYTE (coords.pi_to_nvim_coords returns
---    EXACTLY that). NO `-1` (PRD §7.4's `bytecol - 1` is superseded by coords.lua's
---    exact-UTF-16 design — see coords.lua header).
---
---  * GOTCHA: read the bridge + coords FRESH at call time (`require("pi-editor").bridge`
---    INSIDE the fn, NOT a module-load local). The handshake resolves ASYNC after
---    VimEnter; tests swap fakes in AFTER require; /reload re-runs activate. Caching
---    breaks all three. (Same rule as completion.lua do_refresh.)
---
---  * GOTCHA: supersession is TWO layers (mirrors completion.lua do_refresh).
---      Layer 1 (optimization): `bridge.cancel(prev_id)` (frees the round-trip).
---      Layer 2 (CORRECTNESS boundary): a SELF-INCREMENTED `state.gen` (cmp passes NO id
---        to `complete`, unlike blink's `ctx.id` — so we mirror completion.lua's `gen`).
---        Capture `my_gen` in the cb closure; ignore the cb if `state.gen` changed. cancel
---        can RACE (a response can land between cancel and the new request); the gen-guard
---        CANNOT. Do BOTH. (cmp itself ALSO discards stale responses, but the gen guard
---        prevents a stale complete cb from racing an execute's whole-buffer-replace.)
---
---  * GOTCHA: `request.context.cursor.col` is 1-based BYTE; `coords.nvim_to_pi_coords`
---    wants 0-based byte. SIDESTEP the ±1 footgun: read the cursor DIRECTLY via
---    `nvim_win_get_cursor(0)` in `complete` (matching blink/coords.lua's 0-based-byte
---    contract — byte-identical conversion), using `request.context.bufnr` ONLY to pick
---    the buffer.
---
---  * GOTCHA: cmp items take ONLY lsp fields + label + kind + detail + textEdit + data
---    (cmp does NOT add `source_id`/`source_name` to the table the way blink does, but it
---    tracks the source internally — we set nothing extra). `data` is the ONLY field that
---    round-trips our pi item + bufnr + pre-accept snapshot into `execute()` (cmp passes
---    the accepted item — including `data` — back to us).
---
---  * GOTCHA: lsp.CompletionItemKind values: 17=File, 19=Folder, 14=Keyword, 3=Function,
---    1=Text. Map pi items cosmetically (pi items don't carry a kind): slash/template/
---    skill (value starts with "/") → Keyword; `@file` → File; directory → Folder; else →
---    Text. PORT guess_kind VERBATIM from blink_source.lua. Defensive: if pi item lacks a
---    kind hint, use Text.
---
---  * GOTCHA: `get_keyword_pattern` is NON-CRITICAL (our items always carry an explicit
---    textEdit that overrides the keyword-derived range). Return `[[\k\+]]` (cmp default).
---    Trigger chars `/` + `@` fire complete regardless; subsequent chars are `\k` so cmp
---    keeps the context.
---
---  * NEVER THROWS (pcall every bridge/nvim call; type-guards; malformed `completion_item
---    .data` / nil bridge / wiped buf → `callback(completion_item)` + degrade). A throw
---    out of complete/execute would abort cmp's pipeline.
---
---  * KNOWN FORWARD-CONTRACT (out of scope for S46; documented for the follow-up): when
---    `config.engine == "cmp"`, the builtin menu autocmds (ftplugin→completion.lua→
---    menu.lua) should be SUPPRESSED by a FUTURE engine-wiring task to avoid double-UI.
---    S46's module is correct standalone + additive (mirrors S45's note). The source
---    module READS `config.engine` only to degrade (no behavioral change in S46).
---
--- Node builtins analog: pure Lua + the COMPLETE in-tree bridge
--- (`require("pi-editor").bridge`) + coords (`require("pi-editor.coords")`) + config
--- (`require("pi-editor")`). No sockets of its own — the smoke's fake luv server is the
--- integration surface. Singleton state (mirrors completion.lua's `state` shape, NOT
--- coords.lua's stateless shape — the source HAS supersession state).

local source = {}

--- Singleton source supersession state. One nvim-cmp registration → one source object,
--- but the supersession counters are module-level (one pi-prompt buffer per session, PRD
--- §11). `gen` is the LATEST complete-call generation (the self-incremented supersession
--- guard — cmp passes NO id to `complete`, unlike blink's `ctx.id`; mirrors
--- completion.lua's `state.gen`); `inflight_id` is the bridge.request id of the in-flight
--- getSuggestions (for bridge.cancel).
---@class pi-editor.CmpSourceState
---@field gen         integer the latest complete-call generation (the supersession guard; cmp gives no id)
---@field inflight_id string? the bridge.request id of the in-flight getSuggestions (for bridge.cancel)
local state = { gen = 0, inflight_id = nil }

--- TEST-ONLY reset of the module-level supersession state (`gen` / `inflight_id`).
--- Exported so plenary specs can isolate cases (mirrors completion.lua's `M.reset()` seam
--- + blink_source's `_reset_for_test`). Idempotent + never throws. NOT part of the
--- nvim-cmp source contract — never call from user code / nvim-cmp.
function source._reset_for_test()
  state.gen = 0
  state.inflight_id = nil
end

-- ===========================================================================
-- Internals (forward declaration; defined below)
-- ===========================================================================
local map_item   -- (pi_item, pi_coords, prefix, bufnr) → cmp lsp.CompletionItem (the item mapper)
local guess_kind -- (pi_item) → vim.lsp.protocol.CompletionItemKind (cosmetic kind)

-- ===========================================================================
-- new + is_available + get_trigger_characters + get_keyword_pattern — the source
-- skeleton (Task 1). Mirrors cmp-buffer / codecompanion-cmp: source.new() returns a
-- setmetatable'd table with `__index = source`; the methods are colon-style. params is
-- cmp's option table (read pi config LIVE; accept + ignore params).
-- ===========================================================================

--- Construct an nvim-cmp source object. `params` is the cmp option table (e.g. from the
--- registration config); accepted + ignored — the source reads pi's config LIVE at call
--- time (`require("pi-editor").config`). Returns a fresh table whose metatable is
--- `source` (the cmp-buffer / codecompanion-cmp pattern). The object is stateless;
--- supersession state is module-level (one pi-prompt buffer per session).
---@param params table? The cmp option table (ignored — pi config is read live).
---@return table source An nvim-cmp source object (`new`/`is_available`/`get_trigger_characters`/`get_keyword_pattern`/`complete`/`execute`).
function source.new(params) -- luacheck: ignore params (accepted for cmp's contract; unused by design)
  return setmetatable({}, { __index = source })
end

--- The trigger characters that start a pi completion context (cmp calls this to decide
--- when to fire `complete`). Returns pi's two trigger chars: `/` (slash commands +
--- `skill:` templates) and `@` (file mentions + paths). `#` (the attachment context
--- completion.lua's `is_attachment_context` also matches) is OPTIONAL — pi's TUI does not
--- treat it as a hard trigger, so we omit it to match the TUI's menu-pop timing.
---@return string[] chars The trigger characters.
function source:get_trigger_characters()
  return { "/", "@" }
end

--- Source-level dormancy gate — the twin of `init.lua`'s VimEnter activation gate +
--- blink's `enabled()`. Returns `true` ONLY in a `pi-prompt` buffer (so the source is
--- SAFE to register GLOBALLY in a cmp config; it never fires in ordinary buffers). cmp
--- calls `is_available()` to decide whether to consult the source, so a `false` return
--- short-circuits the whole pipeline (no RPC, no menu). Never throws.
---@return boolean available `true` iff the current buffer's filetype is `pi-prompt`.
function source:is_available()
  return vim.bo.filetype == "pi-prompt"
end

--- The keyword pattern (informational — NON-CRITICAL). Our items always carry an explicit
--- `textEdit` that OVERRIDES the keyword-derived range, so the pattern only governs
--- cmp's in-buffer keyword bounding on the fallback path. Returns `[[\k\+]]` (the cmp
--- default). `params` is cmp's option table; accepted + ignored (read pi config live).
---@param _params table? cmp's option table (ignored — pi config is read live).
---@return string pattern The keyword pattern.
function source:get_keyword_pattern(_params)
  return [[\k\+]]
end

-- ===========================================================================
-- map_item + guess_kind — the pi→cmp item mapper (Task 3).
-- Builds a cmp lsp.CompletionItem from a pi AutocompleteItem. cmp items are the SAME
-- lsp.CompletionItem shape blink uses (cmp tracks the source internally — it does NOT add
-- `source_id`/`source_name` to the table). The `textEdit.range` is derived from the
-- cursor + pi's prefix via coords (0-based line + 0-based UTF-16 character — the
-- lsp.Range contract). The `data` field round-trips the pi item + `bufnr` + the
-- pre-accept snapshot into `execute()` (NOTE: `bufnr` is REQUIRED here because cmp's
-- `execute` takes NO context, unlike blink's). PORT VERBATIM from blink_source.lua
-- map_item / guess_kind; ONLY ADD `data.bufnr`.
-- ===========================================================================

--- Guess the cosmetic lsp.CompletionItemKind for a pi item (for the icon/sort). pi items
--- do NOT carry a kind; this is a SIMPLE, DEFENSIVE heuristic (PORTED VERBATIM from
--- blink_source.lua):
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

--- Map a pi AutocompleteItem → a cmp lsp.CompletionItem. The item carries:
---   * `label`     — the pi item's label (shown in the menu).
---   * `kind`      — the cosmetic kind (guess_kind).
---   * `detail`    — the pi item's description (shown beside the label).
---   * `textEdit`  — `{ newText = pi_item.value, range = {start, ["end"]} }` — the GRACEFUL
---                   FALLBACK insertion (applyCompletion in execute is AUTHORITATIVE). The
---                   range is a valid lsp.Range (0-based line + 0-based UTF-16 character)
---                   covering pi's `prefix` at the cursor.
---   * `data`      — the round-trip snapshot: `{ bufnr, pi, prefix, lines, cursorLine,
---                   cursorCol }` (see pi-editor.CmpItemData). `bufnr` is REQUIRED (cmp's
---                   execute has NO ctx — the buffer to mutate on accept is read from
---                   here). Forwarded VERBATIM to applyCompletion.
---
--- The range is derived via coords: `line = pi_coords.cursorLine` (0-based);
--- `end_char = pi_coords.cursorCol` (already UTF-16); `start_char = end_char -
--- utf16_len(prefix)` where `utf16_len(prefix)` is computed from the cursor line via
--- coords (`coords.byte_to_utf16(line, #prefix)`). Defensive: clamp `start_char >= 0`.
---
--- NEVER throws (type-guards `pi_item`/`pi_coords`; `or ""` line guard). `pi_item` is
--- forwarded VERBATIM (the bridge server forwards it verbatim to pi; pi keys on the whole
--- table — completion.lua accept does the same). PORT VERBATIM from blink_source.lua
--- map_item; ADD `data.bufnr`.
---@param pi_item  pi-editor.AutocompleteItem The pi item (forwarded VERBATIM in data.pi).
---@param pi_coords pi-editor.PiCoords          The pi coords {lines, cursorLine, cursorCol} (from nvim_to_pi_coords).
---@param prefix    string                      The getSuggestions result.prefix (applyCompletion's prefix).
---@param bufnr     integer                     The buffer to mutate on accept (cmp's execute has NO ctx — carried here).
---@return table item A cmp lsp.CompletionItem.
map_item = function(pi_item, pi_coords, prefix, bufnr)
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
      bufnr      = bufnr,                          -- REQUIRED (cmp's execute has NO ctx — read from here)
      pi         = pi_item,                        -- forwarded VERBATIM to applyCompletion's `item`
      prefix     = (type(prefix) == "string") and prefix or "",
      lines      = pi_coords.lines,                -- the buffer lines at getSuggestions issue time
      cursorLine = pi_coords.cursorLine,           -- 0-indexed pi line
      cursorCol  = pi_coords.cursorCol,            -- 0-indexed UTF-16 pi col
    },
  }
end

-- ===========================================================================
-- complete — the data faucet (Task 2).
-- Reads the buffer + cursor, converts nvim→pi via coords, issues `getSuggestions` over
-- the bridge (TWO-LAYER supersession via state.gen + bridge.cancel — cmp gives NO id,
-- unlike blink's ctx.id), maps pi items → cmp lsp.CompletionItems, and calls cmp's
-- `callback` EXACTLY ONCE. Error/nothing → `callback()` (nil). Mirrors completion.lua's
-- do_refresh (RPC shapes, two-layer supersession, "bridge read fresh", null→empty,
-- error→touch-nothing) — adapted: we call cmp's `callback` instead of firing a menu seam,
-- use a self-incremented `state.gen` as the guard, read `bufnr` from `request.context`,
-- and read the cursor directly via `nvim_win_get_cursor(0)` (sidestepping cmp's 1-based
-- `request.context.cursor.col` footgun).
-- ===========================================================================

--- The complete handler (cmp calls this on a trigger char / typing). Reads the buffer +
--- cursor, converts nvim→pi via coords, issues `getSuggestions` over the bridge with
--- `{lines, cursorLine, cursorCol, force=false}` (EXACT shape completion.lua uses),
--- superseds (two-layer: cancel + gen), maps pi items → cmp items, and calls `callback`
--- ONCE with `{items, isIncomplete=false}`. Error/timeout/cancel → `callback()` (nil).
--- NEVER throws; NEVER stalls cmp (callback always called once). Do NOT wrap `callback`
--- in vim.schedule_wrap (the bridge cb already runs on the main loop).
---
---@param request  table   The cmp SourceRequestParams (`request.context.bufnr`, `.cursor`, …).
---@param callback fun(resp?:table) cmp's completion callback; call ONCE with `{items, isIncomplete}` OR `callback()` (nil).
function source:complete(request, callback)
  -- DEFENSIVE: a nil/non-table request is a caller bug (cmp always passes one) — degrade to callback().
  if type(request) ~= "table" then return callback() end
  -- READ BRIDGE FRESH (handshake resolves async + test mocks swap in after require).
  local bridge = require("pi-editor").bridge
  if not bridge
     or type(bridge.is_connected) ~= "function"
     or not bridge.is_connected() then
    return callback()                                -- nothing (graceful; matches cmp-buffer's callback() on nothing)
  end
  -- READ bufnr from the request (cmp packs the buffer in request.context.bufnr). Guard buf valid.
  local bufnr = (request.context and type(request.context.bufnr) == "number") and request.context.bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) then return callback() end
  -- READ buffer + cursor DIRECTLY (api-safe — complete runs on the main loop). SIDESTEP the
  -- ±1 footgun of request.context.cursor.col (1-based BYTE) by matching blink/coords.lua's
  -- 0-based-byte contract: nvim_win_get_cursor(0) returns {row 1-based, col 0-based byte}.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cur   = vim.api.nvim_win_get_cursor(0)       -- {row 1-based, col 0-based byte}
  -- CONVERT nvim→pi (S29 — THE centralized seam). `pi_coords.lines` is the SAME reference as
  -- `lines`, so the result drops straight into the RPC params.
  local pi_coords = require("pi-editor.coords").nvim_to_pi_coords(lines, cur[1], cur[2])
  -- SUPERSEDE layer 1 (cancel prev in-flight — optimization; frees the round-trip).
  if state.inflight_id and type(bridge.cancel) == "function" then
    pcall(bridge.cancel, state.inflight_id)
  end
  state.inflight_id = nil
  -- SUPERSEDE layer 2 (gen guard — the CORRECTNESS boundary; cmp gives NO ctx.id, so we
  -- self-increment a generation, mirroring completion.lua's `state.gen`). Captured in the cb closure.
  state.gen = (state.gen or 0) + 1
  local my_gen = state.gen
  local params = vim.tbl_extend("keep", pi_coords, { force = false }) -- {lines,cursorLine,cursorCol,force=false}
  -- ISSUE (pcall so a bridge bug never throws out of cmp's pipeline).
  local ok, rid = pcall(bridge.request, "getSuggestions", params, function(err, result)
    if my_gen ~= state.gen then return end           -- STALE (superseded) — drop, touch nothing
    state.inflight_id = nil
    if err then return callback() end                -- timeout/cancel/rpc error → nothing (no throw, no stale items)
    -- NORMALIZE: null result (cb(nil,nil)) = SUCCESS with empty items, NOT an error.
    local items  = (result and type(result.items)  == "table")  and result.items  or {}
    local prefix = (result and type(result.prefix) == "string") and result.prefix or ""
    -- MAP (defensive: skip non-table pi items). `map_item` PORTED VERBATIM from blink; adds data.bufnr.
    local cmp_items = {}
    for _, it in ipairs(items) do
      if type(it) == "table" then
        cmp_items[#cmp_items + 1] = map_item(it, pi_coords, prefix, bufnr)
      end
    end
    callback({ items = cmp_items, isIncomplete = false })
  end)
  if not ok then return callback() end               -- bridge.request itself threw → nothing
  if type(rid) == "string" then state.inflight_id = rid end
end

-- ===========================================================================
-- execute — accept via applyCompletion (Task 4).
-- Reads the pre-accept snapshot from `completion_item.data` (which MUST include `bufnr` —
-- cmp's execute takes NO context, unlike blink's), issues `applyCompletion` over the
-- bridge, calls `callback(completion_item)` IMMEDIATELY (responsive; NEVER stalls cmp),
-- and in the async cb overwrites the WHOLE buffer + sets the cursor from pi's
-- authoritative result. Mirrors completion.lua's accept() (the 5-step applyCompletion
-- flow) — adapted: the bufnr/lines/cursor come from the snapshot (captured at complete
-- time), NOT live, and there is NO ctx / default_implementation arg.
-- ===========================================================================

--- The execute (accept) handler (cmp calls this AFTER applying the item's textEdit).
--- Reads the pre-accept snapshot from `completion_item.data` (incl. `bufnr`), issues
--- `applyCompletion` with `{lines, cursorLine, cursorCol, item, prefix}` (EXACT shape
--- completion.lua accept uses), calls `callback(completion_item)` IMMEDIATELY (responsive;
--- the buffer mutation is async fire-and-forget in the cb), and in the async cb overwrites
--- the WHOLE buffer + sets the cursor (0-based byte col, NO `-1`) from pi's authoritative
--- result on `data.bufnr`. Also best-effort closes the builtin menu if open (avoid a stale
--- builtin popup lingering when the user accepted via cmp). NEVER throws; NEVER fails to
--- call `callback(completion_item)` (malformed `completion_item.data`, nil bridge, wiped
--- buf → `callback(completion_item)` + degrade).
---
---@param completion_item table        The accepted cmp item (its `data` carries the snapshot incl. `bufnr`).
---@param callback        fun(item:table) cmp's execute callback; call ONCE with `completion_item`.
function source:execute(completion_item, callback)
  -- DEFENSIVE: malformed completion_item.data → tell cmp "done"; never stall; never throw.
  local d = completion_item and completion_item.data
  if type(d) ~= "table" or type(d.pi) ~= "table" then return callback(completion_item) end
  -- READ BRIDGE FRESH (handshake resolves async + test mocks swap in after require).
  local bridge = require("pi-editor").bridge
  if not bridge
     or type(bridge.is_connected) ~= "function"
     or not bridge.is_connected() then
    return callback(completion_item)                -- graceful: cmp's textEdit already applied pre-execute
  end
  -- READ bufnr from the snapshot (cmp's execute has NO ctx — `data.bufnr` is authoritative).
  local bufnr = (type(d.bufnr) == "number") and d.bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) then return callback(completion_item) end
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
    if err or type(result) ~= "table" then return end -- degrade: buffer left as cmp's textEdit
    local nv = require("pi-editor.coords").pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)
    -- WHOLE buffer replace on the snapshot buf (nvim_buf_set_lines does NOT fire TextChangedI →
    -- no refresh loop; completion.lua §5 Q2). pcall so a wiped buf / odd state never throws.
    pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, nv.lines)
    pcall(vim.api.nvim_win_set_cursor, 0, { nv.row, nv.col }) -- 0-based byte col, NO -1
    -- close a stale builtin menu if open (defensive; never throws). Avoids a lingering
    -- builtin popup when the user accepted via cmp.
    pcall(function() require("pi-editor.menu").close() end)
  end)
  callback(completion_item)                         -- IMMEDIATE: never stall cmp (RPC is fire-and-forget)
end

return source