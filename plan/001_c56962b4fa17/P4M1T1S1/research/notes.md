# Research Notes — P4.M12.T29.S45 (blink_source.lua)

All findings below were **verified against the locally cloned blink.cmp** at
`/home/dustin/.local/share/nvim/lazy/blink.cmp` (HEAD `78336bc8…`, the v0.12.x line)
and against the **shipped pi-editor.nvim** modules in `plugin/lua/pi-editor/`.

---

## 1. blink.cmp `Source` interface — EXACT signatures (verified)

Source: `lua/blink/cmp/sources/lib/types.lua` in the blink.cmp repo.

```lua
--- @class blink.cmp.Source
--- @field new fun(opts: table, config: blink.cmp.SourceProviderConfig): blink.cmp.Source
--- @field enabled? fun(self: blink.cmp.Source): boolean
--- @field get_trigger_characters? fun(self: blink.cmp.Source): string[]
--- @field get_completions? fun(self: blink.cmp.Source, context: blink.cmp.Context,
---        callback: fun(response?: blink.cmp.CompletionResponse)): (fun(): nil) | nil
--- @field should_show_items? fun(self, context, items): boolean
--- @field resolve? fun(self, item, callback): (fun(): nil) | nil
--- @field execute? fun(self: blink.cmp.Source, context: blink.cmp.Context,
---        item: blink.cmp.CompletionItem, callback: fun(),
---        default_implementation: fun(context?: blink.cmp.Context, item?: blink.cmp.CompletionItem))
---        : ((fun(): nil) | nil)
--- @field get_signature_help_trigger_characters? fun(self): string[]
--- @field get_signature_help? fun(self, context, callback): (fun(): nil) | nil
--- @field reload? fun(self): nil
```

Key facts:
- **`new(opts, config)` takes TWO args** — blink calls `require(MODULE).new(opts, config)`.
  `external_deps.md` shows only `opts`; both are present on the wire. We accept `(opts, config)`
  and ignore both (read the bridge live from `require("pi-editor").bridge`).
- **`get_completions` returns an OPTIONAL cancel function** (`fun(): nil | nil`). Returning a
  cancel fn lets blink abort a long-running request. We return one that calls `bridge.cancel(id)`.
- **The callback type is `fun(response?: CompletionResponse)`** — `response` is OPTIONAL/nullable,
  i.e. a source MAY call the callback with `nil` to signal "no results yet" and call again later
  (streaming). For our RPC, we always pass a concrete `{items=…, is_incomplete_*=false}` table
  (or the empty variant on degrade). We call it **exactly once** per `get_completions` invocation.
- **`execute`** signature: `execute(self, context, item, callback, default_implementation)`.
  `callback` is `fun()` (NO args) — call it to tell blink "I handled the accept; do NOT apply
  your default". `default_implementation(context?, item?)` is the fn that would apply blink's
  text-edit. **We intentionally NEVER call it** (see §3). `execute` may also return a cancel fn.

## 2. `blink.cmp.Context` shape (verified)

Source: `lua/blink/cmp/completion/trigger/context.lua`.

```lua
--- @class blink.cmp.Context
--- @field mode    blink.cmp.Mode          -- 'cmdline' | 'cmdwin' | 'term' | 'default'
--- @field id      number
--- @field bufnr   number                  -- the buffer completion is running in
--- @field cursor  number[]                -- {row(1-indexed), col(0-indexed BYTE)} (see get_cursor)
--- @field line    string                  -- the CURRENT line only (NOT the whole buffer)
--- @field bounds  blink.cmp.ContextBounds -- keyword bounds {line_number,start_col,length}
--- @field trigger blink.cmp.ContextTrigger
```

`context.get_cursor()` is defined as:
```lua
function context.get_cursor()
  return context.get_mode() == 'cmdline'
    and { 1, vim.fn.getcmdpos() - 1 }
    or vim.api.nvim_win_get_cursor(0)   -- {row(1-idx), col(0-idx BYTE)}
end
```
=> **`context.cursor` is `{row(1-indexed), byte_col(0-indexed)}`** — IDENTICAL convention to
`nvim_win_get_cursor`. This is exactly what `coords.nvim_to_pi_coords(lines, row, byte_col)`
already consumes (see completion.lua S32). **CRITICAL: `context.line` is ONE line only.**
`bridge.getSuggestions` needs the FULL `lines[]`, so we must call
`vim.api.nvim_buf_get_lines(context.bufnr, 0, -1, false)` ourselves.

## 3. `blink.cmp.CompletionResponse` + `CompletionItemKind` (verified)

Source: `lua/blink/cmp/types.lua`.

```lua
--- @class blink.cmp.CompletionResponse
--- @field is_incomplete_forward boolean
--- @field is_incomplete_backward boolean
--- @field items blink.cmp.CompletionItem[]

CompletionItemKind = { ..., Text = 1, ..., File = 17, Folder = 19, ... }
-- (a 1..25 integer enum; Text == 1. blink.cmp keeps its OWN copy because some plugins
--  mutate vim.lsp.protocol.CompletionItemKind.)
```

`blink.cmp.CompletionItem : lsp.CompletionItem` — LSP-shaped: `label`, `detail`, `kind` (int),
optional `documentation`, `textEdit`, etc. We map pi `AutocompleteItem {value,label,description}`
→ `{ label, detail=description, kind=1 (Text) }`.

## 4. WHY `execute` is mandatory — blink's default accept uses `textEdit` (verified)

Source: `lua/blink/cmp/completion/accept/init.lua` → `apply_item(ctx, item)`:
```lua
local function apply_item(ctx, item)
  item = vim.deepcopy(item)
  ...
  item.textEdit = text_edit_with_brackets   -- applies an LSP textEdit
  ...
end
```
blink's **default** accept computes + applies an LSP `textEdit`. pi's `AutocompleteItem`s have
**no `textEdit`** — pi does its own prefix replacement **server-side** via `applyCompletion` and
returns the COMPLETE new buffer (PRD §7.4, research/notes §5 of completion.lua). Therefore we
MUST override `execute`, call `applyCompletion`, and **NOT** call `default_implementation`
(the item description's contract §1 is explicit: "blink's default textEdit won't match pi's
insertion rules"). This is the single most important correctness decision in this task.

## 5. The reuse path: `completion.accept(item, prefix_override)` (verified)

`plugin/lua/pi-editor/completion.lua` (S32) ships the full PRD §7.4 5-step accept flow:

```lua
function M.accept(item, prefix_override)
  -- 1. read require("pi-editor").bridge; bail (return false) if not connected
  -- 2. buf = menu.get_buf(); if invalid -> buf = nvim_get_current_buf()
  -- 3. validate buf == current buf
  -- 4. lines = nvim_buf_get_lines(buf,0,-1,false); cur = nvim_win_get_cursor(0)
  -- 5. pi = coords.nvim_to_pi_coords(lines, cur[1], cur[2])   -- {lines, cursorLine, cursorCol(UTF-16)}
  --    bridge.request("applyCompletion",
  --       {lines=pi.lines, cursorLine, cursorCol, item=item(VERBATIM),
  --        prefix = prefix_override OR menu.get_prefix() OR ""},
  --       function(err, result) ... replaces WHOLE buffer + sets cursor (NO -1) + menu.close end)
end
```

**Safe WITHOUT the builtin menu attached** (the blink user's case): `menu.get_buf()` returns
`state.buf` (nil when not attached) → accept falls back to the current buffer; `menu.get_prefix()`
returns `state.prefix` (nil) → but we always pass `prefix_override`, so it's short-circuited.
`menu.close()` is a no-op when not open. Confirmed by reading menu.lua `M.get_buf`/`M.get_prefix`
bodies (both just `return state.<field>`). **=> `source:execute` delegates to
`completion.accept(stashed_item, stashed_prefix)` + calls blink's `callback()`.**

## 6. The prefix-carry problem (the one non-obvious design point)

`get_completions` receives a `getSuggestions` result `{items, prefix}`. But by the time blink
calls `execute(context, item, callback, default)`, the result's `prefix` is LONG GONE — blink only
hands back the `item`. **blink passes the SAME item object we returned** (it adds metadata fields
like `source_id`/`cursor_column`, but our custom fields survive — verified: accept/init.lua does
`item = vim.deepcopy(item)` so it can't strip fields, and execute receives the list item which IS
our table). **=> stash both the original pi item AND the batch's prefix ON each mapped item**:
```lua
{ label=..., detail=..., kind=1, pi_item = vim.deepcopy(it), pi_prefix = prefix }
```
`vim.deepcopy` the original (contract: "blink.cmp will mutate items; deepcopy if caching").

This mirrors the builtin engine's behavior: `completion.accept` passes `menu.get_prefix()`, which
is the FETCH-TIME prefix (set from the getSuggestions result). So the blink source is faithful to
the shipped accept contract by construction (the server reconciles lines+cursor+prefix+item).

## 7. `bridge.request` / `bridge.cancel` / `is_connected` API (verified)

`plugin/lua/pi-editor/bridge.lua`:
```lua
M.request(method, params, on_result) --> string|nil id
  -- on_result(err, result) called EXACTLY ONCE (vim.schedule_wrap'd → api-safe).
  -- returns the request id (string) for cancel/supersede, or nil if not connected / bad args.
M.cancel(id)        --> fires the cb with "cancelled"; no-op if already resolved / unknown. NO wire msg.
M.is_connected()    --> boolean
```
`getSuggestions` params: `{ lines:string[], cursorLine:int, cursorCol:int(UTF-16), force?:bool }`.
For the blink normal-trigger path we OMIT `force` (matches the builtin TextChangedI path; only the
Tab handler sets `force=true`). Result: `AutocompleteSuggestions | null` →
`{ items: AutocompleteItem[], prefix: string }` (null → no matches → we treat as empty).

## 8. coords conversion (verified)

`plugin/lua/pi-editor/coords.lua`:
```lua
M.nvim_to_pi_coords(lines, row_1_indexed, byte_col_0_indexed)
  --> { lines = lines, cursorLine = row_1_indexed - 1, cursorCol = M.byte_to_utf16(line, byte_col) }
```
`context.cursor` already matches the `(row_1_indexed, byte_col_0_indexed)` convention, so we feed
it straight in.

## 9. The `notify` contract from the parallel PRP P3.M10.T24.S39 (treat as contract)

That PRP ships `plugin/lua/pi-editor/notify.lua` exposing `M.once(category, level, msg)` — a
**dedup'd, vim.schedule'd** `vim.notify` (at most one toast per category per session), callable
from luv fast context. **Our source does NOT need to notify** (degrade = empty item list, silent),
so this is informational only — but it confirms "silent degrade" is the repo convention and that we
should NOT add our own `vim.notify` calls (avoid double-toasts / spam).

## 10. Version pin & repo references

- blink.cmp local clone HEAD: `78336bc89ee5365633bcf754d93df01678b5c08f` (≈ v0.12.x).
- Source interface: `lua/blink/cmp/sources/lib/types.lua`
- Context: `lua/blink/cmp/completion/trigger/context.lua`
- CompletionResponse + CompletionItemKind: `lua/blink/cmp/types.lua`
- Default accept (why execute is mandatory): `lua/blink/cmp/completion/accept/init.lua`
- pi-editor reuse: `plugin/lua/pi-editor/{completion,bridge,coords,init,menu}.lua`