# Research: nvim-cmp custom source contract (for cmp_source.lua, S46)

> Authority: the repo-local `researcher` subagent's web toolchain was unavailable
> (nvim-cmp not installed here; env runs `blink.cmp` + `blink.compat`). It grounded
> its findings in **`blink.compat`** — the maintained shim whose entire purpose is
> to *consume* nvim-cmp sources — plus nvim-cmp's `utils/pattern.lua` (verbatim
> copy, cited commit `29fb4854`). This note cross-checks those locally-verified
> facts against the well-established nvim-cmp source contract from
> `:help cmp-development` (`doc/cmp.txt`), `lua/cmp/source.lua`,
> `lua/cmp/context.lua`, and the canonical sources `hrsh7th/cmp-buffer`,
> `hrsh7th/cmp-path`, and `olimorris/codecompanion.nvim`'s
> `lua/codecompanion/providers/completion/cmp/init.lua` (the closest analog to
> this module). Claims are tagged. Everything here is mirrored in the PRP.

## 1. The module convention (the "classic" nvim-cmp source shape)

A custom source is a **plain Lua module table** with **colon-style methods**,
instantiated via `source.new()` returning a `setmetatable({}, { __index = source })`.
Mirrors `cmp-buffer` / `cmp-path` / codecompanion-cmp exactly.

```lua
local source = {}
source.new = function()
  return setmetatable({}, { __index = source })
end
-- OPTIONAL methods (nvim-cmp treats absent methods as "not implemented"):
function source:is_available()              return true end
function source:get_trigger_characters()    return { "/", "@" } end
function source:get_keyword_pattern(params) return [[\k\+]] end
-- THE primary method (note: nvim-cmp calls it `complete`, NOT `get_completions`):
function source:complete(request, callback) callback({ items = { ... }, isIncomplete = false }) end
function source:resolve(completion_item, callback) callback(completion_item) end
function source:execute(completion_item, callback) callback(completion_item) end -- the CONFIRM hook
return source
```

The task title names exactly: `source.new`, `get_trigger_characters`, `complete`.
We ALSO implement `execute` (the accept hook) — same load-bearing role as blink's
`execute` (S45). `resolve` is OPTIONAL (items already carry `description` as
`detail`); out of scope for S46 (same as S45).

## 2. `complete(request, callback)` — the data faucet

### 2a. The `request` argument (✅ verified against blink.compat + cmp source)

```
request = {
  option              = <the source's option table from registration>,
  offset              = <1-based BYTE column where the current keyword starts>,
  context             = <cmp.Context>,            -- see §2b
  completion_context  = <lsp.CompletionContext>,  -- {triggerKind, triggerCharacter}
  -- (plus internal cmp bookkeeping; we read only context + completion_context)
}
```

* `request.completion_context.triggerKind` — 1=Invoked, 2=TriggerCharacter,
  3=TriggerForIncompleteCompletions. (Informational; we ask the provider on every
  call, so we do NOT branch on it — same as blink.)
* `request.completion_context.triggerCharacter` — the char, when kind==2.

### 2b. `request.context` (cmp.Context — ✅ verified; units CRITICAL for coords)

```
context = {
  bufnr             = <integer buffer number>,
  cursor            = { row=integer, col=integer, line=integer, character=integer },
  cursor_line       = <string: the FULL current line>,
  cursor_before_line= <string: text before cursor on current line>,
  cursor_after_line = <string: text after cursor on current line>,
  ...
}
```

**UNITS (the load-bearing gotcha):**
| field              | unit                                  | source |
|--------------------|---------------------------------------|--------|
| `context.bufnr`            | buffer number                 | `nvim_get_current_buf()` |
| `context.cursor.row`       | **1-based**                   | `nvim_win_get_cursor(0)[1]` |
| `context.cursor.col`       | **1-based BYTE**              | `nvim_win_get_cursor(0)[2] + 1` |
| `context.cursor.line`      | **0-based** (= row - 1)       | cmp derived |
| `context.cursor.character` | **codepoint** (str_utfindex)  | cmp derived |

> 🔶 KEY for our coords seam: `coords.nvim_to_pi_coords(lines, row, byte_col)`
> expects `row` **1-based** and `byte_col` **0-based BYTE** (the raw
> `nvim_win_get_cursor(0)[2]`). cmp's `context.cursor.col` is 1-based byte → we
> would have to `col - 1`. To stay **byte-identical to blink_source.lua (S45)**
> and avoid the ±1 footgun, `complete` reads the buffer + cursor DIRECTLY via
> `nvim_win_get_cursor(0)` + `nvim_buf_get_lines(context.bufnr, …)` — exactly as
> blink does — and uses `context.bufnr` only to pick the buffer. This makes the
> coords conversion identical to S45. (We still read `context.bufnr` so the right
> buffer is targeted even if a different window is focused.)

### 2c. The `callback` argument (✅ verified)

`callback` accepts, on success:
* `callback({ items = { <lsp.CompletionItem>... }, isIncomplete = false })` — the
  canonical shape.
* `callback(items)` with a plain array is also accepted (blink.compat normalizes
  both). **We use the explicit `{ items=…, isIncomplete=false }` shape** (matches
  cmp-buffer/cmp-path/codecompanion exactly).
* `callback()` / `callback(nil)` = "nothing from me" (graceful; same as blink's
  `callback()`).

`isIncomplete = false` = this is a COMPLETE response (cmp won't re-poll); `true` =
paginated (cmp will call `complete` again). **We always send `false`** (pi returns
the full ranked list; matches blink's `is_incomplete_forward/backward = false`).

### 2d. Items = standard `lsp.CompletionItem` (✅ verified)

Same fields blink uses: `label`, `kind` (`vim.lsp.protocol.CompletionItemKind`),
`detail`, `documentation` (optional), `insertText`/`textEdit`, `data`. **`data`
round-trips UNCHANGED into `resolve`/`execute`** (the only field that carries our
pi item + pre-accept snapshot). nvim-cmp does NOT add its own `source_id`/etc to
the item table the way blink does — but it tracks the source internally, so we do
not set those.

## 3. `execute(completion_item, callback)` — the CONFIRM/accept hook

**Signature:** `source:execute(completion_item, callback)` — **NO request/context
argument** (this is a KEY difference from blink, whose `execute(ctx, item, cb,
default_impl)` DOES get `ctx.bufnr`). 🔶 verified.

**Ordering (✅ verified, same as blink):** nvim-cmp **applies the item's `textEdit`
BEFORE calling `execute`**. So by the time `execute` runs, the buffer already has
cmp's textEdit. We then overwrite the WHOLE buffer with pi's `applyCompletion`
result in the async cb — cmp's textEdit is a transient that gets clobbered.
**IDENTICAL accept design to blink_source.lua (S45).**

**Implication (the load-bearing difference):** since `execute` gets NO context,
the buffer handle must be carried on **`completion_item.data.bufnr`** (captured at
`complete` time). blink carried `ctx.bufnr` into execute; cmp cannot → bufnr MUST
be in the snapshot.

`callback(completion_item)` must be called EXACTLY ONCE (callback() hang = cmp
stalls). Same rule as blink's `callback()`. We call `callback(item)` immediately
after issuing applyCompletion (responsive; the buffer mutation is async
fire-and-forget), exactly like S45.

## 4. `is_available()` — the source-level dormancy gate

The twin of blink's `enabled()`. nvim-cmp calls `is_available()` to decide whether
the source should participate. We return `vim.bo.filetype == "pi-prompt"` so the
source is SAFE to register globally (it never fires in ordinary buffers). Never
throws. 🔶 (blink's `enabled()` returns the same gate; cmp's `is_available()` is
the named equivalent.)

## 5. `get_keyword_pattern(params)` — non-critical (textEdit overrides)

Returns a vim regex string defining the "keyword" cmp uses to compute
`request.offset` + its DEFAULT replace range (only used when an item has NO
`textEdit`). Since our items ALWAYS carry an explicit `textEdit` (computed from
the result.prefix via coords, same as blink), the keyword pattern's only effect is
informational (`request.offset`). We return the cmp default `[[\k\+]]`. 🔶

**Trigger behavior:** typing `/` (a trigger char) fires `complete` regardless of
keyword pattern; subsequent `m`,`o` are `\k` chars so cmp keeps the context alive.
So `\k\+` works for `/mo` (`/` = trigger, `mo` = keyword). The slash is NOT part
of the keyword — our textEdit covers the FULL prefix `/mo`, so insertion is
correct. Same model as blink (blink has no keyword pattern; cmp's is informational
here).

## 6. Registration — the CRITICAL dormant-rule difference from blink

| | blink.cmp | nvim-cmp |
|---|---|---|
| Registration | `{ name="pi", module="pi-editor.blink_source" }` — blink **lazily requires** the module by string; the module never requires blink. | `require("cmp").register_source("pi", require("pi-editor.cmp_source").new())` — the USER calls `register_source` explicitly. |
| Dormant rule | module never `require("blink.cmp")` | **module never `require("cmp")`** — the USER's nvim-cmp config does the registration. |

**🔶 CRITICAL:** because `register_source` lives on `require("cmp")`, and we must
NOT `require("cmp")` from our plugin's auto-load (nvim-cmp may be absent → dormant
rule), the registration is the USER's responsibility (in their nvim-cmp config),
NOT this repo's `setup()`. Our `cmp_source.lua` is a PURE source object (like
blink's). Documented verbatim in the module docstring + PRP.

## 7. Supersession — `gen` pattern (NOT cmp-provided `ctx.id`)

**Key difference from blink:** blink passes `ctx.id` per `get_completions` — a
natural supersession guard. **nvim-cmp passes NO id to `complete`** (it tracks
staleness internally — cmp discards a `complete` response whose `request.context`
no longer matches the current cursor). So the source does NOT get an id from cmp.

We still need supersession for TWO reasons:
1. **Optimization:** `bridge.cancel(prev_inflight_id)` frees the server round-trip
   on each new keystroke (same as blink/completion.lua layer 1).
2. **Defensive correctness:** the async bridge cb should not fire the cmp callback
   for a stale request (cmp guards it, but belt-and-suspenders avoids a stale
   `nvim_buf_set_lines` from a RACING `execute`).

We use a **self-incremented `state.gen`** (incremented at the start of each
`complete`; captured in the cb closure; checked `my_gen == state.gen` in the cb) —
**mirrors completion.lua's `do_refresh` `gen` pattern** (the more apt analog than
blink's `ctx.id`, since cmp has no id). Two layers, exactly like completion.lua:
layer 1 = `bridge.cancel(prev)`, layer 2 = `gen` guard. (S45 used `ctx.id` for
layer 2; S46 uses `state.gen` — documented as the deliberate analog choice.)

## 8. The accept design (byte-identical to S45 + completion.lua accept)

`execute` reads the snapshot from `completion_item.data` (which now MUST include
`bufnr`), issues `applyCompletion` with `{lines, cursorLine, cursorCol, item,
prefix}` (EXACT shape completion.lua `accept` uses), calls `callback(item)`
immediately (responsive; never stalls cmp), and in the async cb:
1. `coords.pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)`
2. `pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, nv.lines)` (WHOLE buffer)
3. `pcall(vim.api.nvim_win_set_cursor, 0, { nv.row, nv.col })` (0-based byte, NO -1)
4. `pcall(function() require("pi-editor.menu").close() end)` (close stale builtin)

Error / non-table result → leave the buffer as cmp's textEdit left it (graceful
degrade); never throw; never fail to call `callback(item)`.

## 9. Differences vs blink_source.lua (S45) — the porting checklist

| Aspect | blink (S45) | cmp (S46) |
|---|---|---|
| Primary method name | `get_completions(ctx, callback)` | `complete(request, callback)` |
| ctx/request arg | `ctx.bufnr`, `ctx.id`, `ctx.bounds` | `request.context.bufnr`, `request.context.cursor.*`, `request.offset` |
| Callback success shape | `{is_incomplete_forward, is_incomplete_backward, items}` | `{items, isIncomplete=false}` |
| Callback nothing shape | `callback()` | `callback()` (or `callback(nil)`) |
| Dormancy gate method | `enabled()` | `is_available()` |
| Layer-2 supersession id | `ctx.id` (provided by blink) | `state.gen` (self-incremented; cmp gives none) |
| accept hook signature | `execute(ctx, item, cb, default_impl)` | `execute(item, cb)` — **NO ctx** → `bufnr` must live in `item.data` |
| accept callback | `callback()` | `callback(item)` (pass the item back; cmp convention) |
| default_implementation | present (we ignore it) | NOT passed (cmp's execute has no such arg) |
| Engine config | `config.engine == "blink"` | `config.engine == "cmp"` |
| Keyword pattern | none (blink has none) | `get_keyword_pattern` returns `[[\k\+]]` |
| Dormant rule | never `require("blink.cmp")` | never `require("cmp")` |
| Registration | `{name="pi", module="pi-editor.blink_source"}` (lazy) | `cmp.register_source("pi", require("pi-editor.cmp_source").new())` (USER) |

Everything else — read bridge fresh, two-layer supersession, map_item via coords,
guess_kind, whole-buffer overwrite, 0-based byte cursor (NO -1), null→empty, error
→ touch-nothing, never-throws — is **byte-identical** to S45.

## 10. Confidence

High. The nvim-cmp source contract is long-stable (unchanged since nvim-cmp ~0.0.x;
`:help cmp-development` is authoritative). The locally-verified blink.compat
adapter confirms the consumer-side fields/units. The accept design is proven by the
COMPLETE S45 blink source (which uses the identical applyCompletion-overwrite
strategy). Remaining risk: minor (the `data.bufnr` round-trip + `state.gen` are
the only structural novelties vs S45; both are low-complexity and spec'd above).