# Research Notes — P4.M1.T2.S1: cmp_source.lua (nvim-cmp source)

> Sibling of P4.M1.T1.S1 (blink_source.lua). This file captures the **nvim-cmp-specific**
> findings that differ from the blink sibling. The codebase analysis (bridge/completion/
> coords/init/notify + the test patterns) is identical to the blink PRP and is not repeated.

## 1. nvim-cmp is NOT installed locally (unlike blink.cmp)

`find ~/.local/share/nvim ~/.config/nvim` → no `nvim-cmp` dir, no `cmp/source.lua`. The machine
uses **blink.cmp + blink.compat**. So the nvim-cmp source contract was verified against
**blink.compat** (`lua/blink/compat/source.lua`, `lib/context.lua`, `registry.lua`), which is a
maintained, faithful re-implementation of the **nvim-cmp source-API consumer** (it accepts
nvim-cmp-style sources and adapts them to blink). blink.compat's `context.new` constructs the
EXACT same `params.context` object shape nvim-cmp itself builds, so the field names below are
authoritative. The full deep-dive report is at
`.pi-subagents/artifacts/outputs/ba2f63dd/research.md`.

## 2. The source object interface (verified via blink.compat/source.lua)

| method | required? | signature | returns |
|---|---|---|---|
| `source.new(opts)` | yes (user calls it) | `setmetatable({}, {__index=source})` | the source instance |
| `source:is_available()` | optional (omitted ⇒ always true) | `→ bool` | true iff bridge connected |
| `source:get_trigger_characters()` | optional (omitted ⇒ `{}`) | `→ string[]` | `{ "/", "@" }` |
| `source:get_keyword_pattern()` | optional | `→ string` (vim regex) | OMIT (use cmp default; see §7) |
| `source:complete(params, callback)` | **required** | `callback(items)` where `items` is an LSP-`CompletionItem[]` (or `{items=…,isInComplete=…}`, or `nil`/empty ⇒ no items) | nothing (NO cancel fn — see §6) |
| `source:resolve(item, callback)` | optional | OMIT (minimal; not in work item) | — |
| `source:execute(item, callback)` | optional | `callback()` when done | OMIT — see §4 (ADDITIVE ⇒ breaks applyCompletion) |

Registration: `require('cmp').register_source('pi-editor', source.new())` (verified via
`registry.lua`). The instance handed to `register_source` is what `source.new()` returns. To use
it: list `'pi-editor'` in `cmp.setup({ sources = { { name = 'pi-editor' } } })`.

## 3. THE `params` shape of `complete` (verified via blink.compat/lib/context.lua)

**`params.context.cursor` — CRITICAL indexing (differs from blink!):**

```lua
-- blink.compat/lib/context.lua context.new (verbatim):
cursor = {
  row      = ctx.cursor[1],          -- 1-based line  (== nvim_win_get_cursor()[1])  ✓ SAME as nvim row
  col      = ctx.cursor[2] + 1,      -- 1-based BYTE  (nvim 0-based byte + 1)         ⚠ +1 vs nvim!
  line     = ctx.cursor[1] - 1,      -- 0-based line
  character= vim.str_utfindex(ctx.line, ctx.cursor[2]),  -- UTF codepoint index
}
```

**⇒ To feed `coords.nvim_to_pi_coords(lines, row, byte_col)`, which expects a 0-based BYTE col
(the `nvim_win_get_cursor()[2]` convention), we MUST do:**

```lua
local row      = params.context.cursor.row        -- already 1-based (matches nvim row) — NO ±1
local byte_col = params.context.cursor.col - 1    -- cmp 1-based byte → nvim 0-based byte  ⚠ THE -1
local pi       = require("pi-editor.coords").nvim_to_pi_coords(lines, row, byte_col)
```

**This `-1` is the single most important cmp-specific detail** (blink's source used
`context.cursor[2]` directly because blink's col is already 0-based byte; cmp's is 1-based).
For `/mo` with the cursor at the end: nvim reports col 3 (0-based byte); cmp reports col 4
(1-based byte); `4 - 1 = 3` → UTF-16 cursorCol 3. ✓ (matches completion_accept_smoke's assertion.)

Other `params.context` fields (all verified): `bufnr` (buffer handle), `cursor_line` (full current
line string — but getSuggestions needs the FULL buffer, so still call `nvim_buf_get_lines(bufnr,
0,-1,false)`), `cursor_before_line` / `cursor_after_line` (byte substrings), `filetype`, `id`
(staleness token — not used; we do our own gen-guard).

`params.offset` = 1-based byte column where the completion keyword STARTS (derived from
keyword_pattern matched at end of cursor_before_line). **Not used** — we send the full buffer +
cursor to pi (pi computes the prefix server-side, same as the builtin engine).

`params.completion_context` = LSP `{triggerCharacter, triggerKind}` (triggerKind 1=Invoked,
2=TriggerCharacter, 3=Incomplete). Not used by us.

## 4. CONFIRM / ACCEPT — `execute()` is ADDITIVE (cannot cleanly override)

Verified via blink.compat/source.lua `source:execute` + blink.cmp accept/init.lua + text_edits.lua:

- **Insertion fallback on `cmp.confirm`: `textEdit` → `insertText` → `label`.** An item with only
  `label`+`detail` (no textEdit/insertText) ⇒ **the `label` is inserted** (detail is display-only).
- **`source:execute(item, callback)` runs AFTER cmp's text insertion** (blink.compat applies the
  default text FIRST, then calls `s:execute`). The nvim-cmp `execute(item, callback)` signature
  has **NO `default_implementation` parameter** (that 4th-arg skip is blink-native ONLY). So there
  is **no way for a cmp source's `execute` to skip cmp's own insertion.**
- ⇒ Implementing `execute` to call `completion.accept` would be **BROKEN**: by the time `execute`
  fires, cmp has ALREADY inserted the item text, so `accept`'s fresh `nvim_buf_get_lines` would
  read the POST-insertion buffer and send WRONG lines to pi. **DO NOT implement `execute` for
  acceptance.**

## 5. The clean acceptance override = custom `<CR>` confirm mapping (work item §3e "override")

Because cmp can't be cleanly bypassed from inside the source, the pi-faithful path is a **user-side
confirm mapping** that calls `applyCompletion` and does **NOT** call `cmp.confirm`. The cmp source
module provides a helper `M.confirm()` returning a `cmp.mapping`-compatible `function(fallback)`
so the override is ergonomic + DRY:

```lua
-- user config:
cmp.setup({
  sources = { { name = 'pi-editor' } },
  mapping = {
    ['<CR>']  = cmp.mapping(require('pi-editor.cmp_source').confirm(), { 'i' }),
    ['<C-y>'] = cmp.mapping(require('pi-editor.cmp_source').confirm(), { 'i' }),
  },
})
```

Helper logic (defensive; cmp API read lazily + type-guarded so the module loads even without cmp):
1. `pcall(require, "cmp")` — if missing → call `fallback()` (no active cmp).
2. `cmp.get_active_entry()` — if nil → `fallback()` (no selection → newline / default).
3. Read `entry.completion_item.data`; if it's a pi payload (`data.pi_item` table) →
   `require("pi-editor.completion").accept(data.pi_item, data.pi_prefix)` (the SAME reuse path as
   the builtin engine + the blink source — works WITHOUT the builtin menu attached because `accept`
   falls back to the current buffer + uses `prefix_override`), then `cmp.abort()` (close menu
   WITHOUT confirming ⇒ NO cmp text insertion).
4. Else (non-pi entry) → `cmp.confirm({behavior=Replace, select=false})` (let cmp handle other
   sources' items normally).

`completion.accept` reads the LIVE buffer + cursor, so it sees the PRE-confirm buffer (correct).
This mirrors blink's `execute` override in spirit (both "handle acceptance in the module"), adapted
to cmp's additive-execute limitation.

cmp public-API methods used (stable, but UNVERIFIED against nvim-cmp source this session — cmp not
installed): `require('cmp')`, `cmp.get_active_entry()`, `cmp.abort()`, `cmp.confirm({behavior,
select})`, `cmp.ConfirmBehavior.Replace`, `cmp.mapping(fn, modes)`. Document in the docstring;
implementer should spot-check against the user's cmp version.

## 6. CANCELLATION / supersession (NO cancel-fn return from `complete`)

Verified (negative evidence) in blink.compat/source.lua: `get_completions` calls `s:complete(params,
callback)` and returns nothing — **no cancel/abort fn is returned, and there is no `source:abort()`
method the consumer calls.** cmp simply issues a NEW `complete()` on the next keystroke; a late
callback for the prior call must be dropped by the SOURCE itself.

⇒ The cmp source keeps its OWN local supersession state (it MUST NOT touch `completion.lua`'s
singleton `state` — that belongs to the builtin engine; the user runs ONE engine, PRD §7.7):

```lua
local ss = { gen = 0, inflight_id = nil }   -- cmp-source-local supersession
-- in complete(): bump gen; bridge.cancel(prev inflight_id); issue new request; gen-guard the cb.
```

This is the SAME two-layer pattern as `completion.lua` (gen-guard + bridge.cancel), localized to the
cmp source. The callback still fires EXACTLY ONCE per complete() (bridge.request guarantees
exactly-once); stale cbs are gen-guarded and dropped (cmp tolerates a never-called callback for a
superseded context).

## 7. `get_keyword_pattern` — OMIT (use cmp default); reasoning

nvim-cmp's default keyword pattern is derived from `'iskeyword'` (`/` and `@` are NOT keyword chars).
- Typing `/` ⇒ trigger character fires `complete()` (good — the source's
  `get_trigger_characters()` returns `{"/","@"}`).
- Typing `mod` after `/` ⇒ each char extends a keyword (`m`,`o`,`d` are iskeyword) ⇒ cmp re-fires
  `complete()` (good — pi re-queried per keystroke, matching the builtin engine's pi-faithful
  "ask on every change" model).
- The keyword pattern ONLY affects the REPLACEMENT RANGE on a plain `cmp.confirm` — which we bypass
  via the custom `M.confirm()` mapping. So the default is correct for our needs.
- (An AI source like minuet returns `'^$'` to fire ONLY on trigger chars; pi wants re-firing on
  typing, so we keep the default.) Document in gotchas.

## 8. Item mapping (per work item §3d + refinements)

Per the work item: `label = item.label`, `detail = item.description`. Refinements necessary for
correctness/usability:

```lua
{
  label     = ai.label,          -- display (per work item)
  detail    = ai.description,    -- display secondary (per work item)
  filterText= ai.value,          -- so cmp's client-side filter matches the typed "/mo"/"@me" prefix
  kind      = 1,                 -- LSP Text (hardcode 1; do NOT require cmp.types — module must load w/o cmp)
  data      = { pi_item = vim.deepcopy(ai), pi_prefix = prefix },  -- LSP-standard opaque field, for M.confirm()
}
```

- `filterText = ai.value`: cmp matches the typed keyword against `filterText` (defaults to `label`).
  If the user types `/mo` and label is `model`, cmp would NOT match (no `/`). Setting filterText to
  the value (`/model`) makes the match work. Verified idiom.
- `data`: LSP CompletionItem's standard opaque field — cmp preserves it and returns it on the entry
  (`entry.completion_item.data`). Used by `M.confirm()` to recover the original pi item + prefix.
- `vim.deepcopy(ai)`: cmp may mutate items; deepcopy so `accept` gets an untouched AutocompleteItem
  (same discipline as the blink source).
- `pi_prefix` stashed per-item: the `getSuggestions` result's prefix (fetch-time; server
  reconciles). Mirrors the builtin engine's fetch-time-prefix behavior.

`insertText` is intentionally UNSET ⇒ a plain `cmp.confirm` inserts the `label` (item.label) —
the work item's documented "not faithful" fallback. The `M.confirm()` mapping is the faithful path.

## 9. silent degrade (repo convention — S39 owns toasts)

On no-bridge / not-connected / RPC-error / null-result / bad params: call the cmp `callback()` with
NO items (empty / nil). NEVER `vim.notify` (S39's `notify.lua` owns the single dedup'd toast; an
empty completion list is the correct "no completions" signal to cmp). NEVER throw out of a source
method. (Same convention as the blink source.)

## 10. Key files to reference (all SHIPPED — read-only for this task)

- `plugin/lua/pi-editor/bridge.lua` — `M.request(method, params, on_result)` (cb exactly-once,
  schedule_wrap'd ⇒ api-safe), `M.cancel(id)`, `M.is_connected()`. getSuggestions params =
  `{lines, cursorLine, cursorCol}` (+ optional `force`; OMIT for the normal cmp trigger).
- `plugin/lua/pi-editor/coords.lua` — `M.nvim_to_pi_coords(lines, row_1_idx, byte_col_0_idx)`
  → `{lines, cursorLine=row-1, cursorCol=UTF-16}`. **Route through this; never hand-roll UTF-16.**
- `plugin/lua/pi-editor/completion.lua` — `M.accept(item, prefix_override?)` (the reuse path; works
  without the builtin menu via prefix_override + current-buffer fallback).
- `plugin/lua/pi-editor/init.lua` — `M.bridge` (the published seam; nil until handshake; read LIVE
  inside each method — handshake resolves async).
- `plugin/lua/pi-editor/notify.lua` — `M.once(category, level, msg)` (we do NOT call it; silent
  degrade).
- Test patterns: `plugin/tests/completion_accept_smoke.lua` (plenary-FREE fake-server + real-bridge
  idiom — mirror for cmp_source_smoke.lua), `plugin/tests/bridge_request_spec.lua` (plenary/busted
  layout — mirror for cmp_source_spec.lua).

## 11. The -1 GOTCHA — concrete worked example (must appear in the PRP)

| Buffer | nvim cursor (`nvim_win_get_cursor`) | cmp `params.context.cursor.col` | `col - 1` → coords byte_col | UTF-16 cursorCol |
|---|---|---|---|---|
| `{"/mo"}` | `{1, 3}` (0-based byte) | `4` (1-based byte) | `3` | `3` |
| `{"héllo"}` cursor after `é` | `{1, 3}` | `4` | `3` | `2` (é = 1 UTF-16 unit; "hé" = 2) |

The smoke test should set `params.context.cursor = { row=1, col=4, line=0 }` and assert the server
sees `cursorCol == 3` for `/mo` (mirroring completion_accept_smoke.lua's assertion).

## 12. Residual risk

- nvim-cmp's OWN source.lua/entry.lua were NOT line-verified (cmp not installed; no web tools). The
  CONTRACT (§2/§3) is reliably reconstructed from blink.compat (the authoritative consumer). The
  cmp public API used by `M.confirm()` (`get_active_entry`/`abort`/`confirm`/`mapping`) is
  stable-from-knowledge but should be spot-checked against the user's cmp version. This risk does
  NOT affect the source-contract correctness (new/is_available/get_trigger_characters/complete),
  which the Level-3 smoke proves end-to-end with a fake bridge.