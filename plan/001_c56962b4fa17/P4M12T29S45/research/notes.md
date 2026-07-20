# P4.M12.T29.S45 — Research Notes (blink.cmp source module)

Task: CREATE `plugin/lua/pi-editor/blink_source.lua` — a `blink.cmp` completion
source that exposes pi's live `AutocompleteProvider` (slash commands, `skill:`
templates, arg completions, `@file`, paths) through blink.cmp's source interface.
The source calls the COMPLETE in-tree bridge (`require("pi-editor").bridge`) +
coords (`require("pi-editor.coords")`) + config (`require("pi-editor")`); it does
NOT touch sockets itself. It is OPT-IN (the user adds it to their blink.cmp config).

This file consolidates: (§1) the blink.cmp source contract, (§2) the accept-time
design decision (the load-bearing one — pi's `applyCompletion` returns the WHOLE
buffer while blink applies a `text_edit` *before* `execute`), (§3) the codecompanion
reference implementation, (§4) the integration seams in THIS repo, (§5) supersession
+ async + the "never require blink.cmp" rule, (§6) the test plan, (§7) scope guards +
the `engine` coordination forward-contract.

---

## §1 — The blink.cmp source contract (authoritative: Saghen/blink.cmp master)

Sources are authored as a Lua MODULE exporting `.new(opts)` → a source OBJECT.
blink calls `require("user.module").new(opts)` ONCE per provider-config entry and
caches it. The object implements a method-style interface (COLON methods — `self`
is the first arg):

| Method | Required | When blink calls it |
|---|---|---|
| `new(opts)` | **Yes** | once per provider entry, at first completion in that mode |
| `get_completions(ctx, callback)` | **Yes** | on every completion request |
| `get_trigger_characters()` | No | to gather trigger chars across sources |
| `enabled()` | No | gate the source per buffer/mode (blink skips if falsy) |
| `should_show_items(ctx, items)` | No | hide items even after fetch |
| `resolve(item, callback)` | No | on doc-hover or item accept (enrich item) |
| `execute(ctx, item, callback, default_implementation)` | No | **accept-time hook** — AFTER blink applied the item's `textEdit` |
| `get_signature_help(ctx, callback)` | No | n/a for us |

**`get_completions(ctx, callback)`** — the data faucet:
- `callback` is invoked EXACTLY ONCE per request (blink's `async.Task` awaits it).
- Success shape: `callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = {...} })`.
- "Nothing to show / cancel": `callback()` with NO arg (nil). blink treats a nil/empty
  response as "this source has nothing" (NOT an error).
- `callback` should be safe to call from a fast/async context — the `path` source
  wraps it: `callback = vim.schedule_wrap(callback)`. **For us the bridge `request`
  cb is ALREADY `schedule_wrap`d (bridge.lua S26), so our `callback(...)` runs on the
  nvim main loop — NO extra wrap needed** (mirrors completion.lua do_refresh).

**`ctx` (blink.cmp.Context) shape — confirmed via `path/init.lua` + codecompanion:**
```
ctx.bufnr            integer   the buffer completion is requested in
ctx.id               <token>   monotonic per-request id (blink's staleness key)
ctx.mode             string    'default' | 'cmdline' | 'cmdwin' | 'term'
ctx.line             string    the current line (the one completion is for)
ctx.cursor           table     { line, col }  (col is 1-based? — prefer ctx.bounds)
ctx.bounds           table     { line_number, start_col, length } — 1-based byte
ctx.trigger          table     { kind: 'trigger'|'keyword'|'manual'|'prefetch',
                                character: string|nil }
```
- `ctx.bounds.line_number` is **1-based** (codecompanion: `ctx.bounds.line_number - 1` → LSP 0-based line).
- `ctx.bounds.start_col` is **1-based byte** (codecompanion: `ctx.bounds.start_col - 2` arithmetic).
- `ctx.id` is the supersession key blink itself uses at the source→consumer seam
  (`completion/init.lua`: `event.context.id ~= trigger.context.id`) — we reuse it as
  our gen-guard value (§5).

**Completion item = `lsp.CompletionItem`** (blink.cmp `types.lua`: `@class blink.cmp.CompletionItem : lsp.CompletionItem`). Fields we set:
```
label        string   REQUIRED — the menu text (what blink fuzzy-matches)
kind         integer  lsp.protocol.CompletionItemKind (Keyword/Function/File/Folder/...)
detail       string   side text (one line)
documentation { kind='plaintext'|'markdown', value=string }  resolved later (resolve)
textEdit     { newText=string, range=lsp.Range }   the edit blink applies on accept
insertText   string   fallback if no textEdit
filterText   string   override what blink fuzzy-matches (defaults to label)
sortText     string   override sort within source
data         any      opaque per-source payload — SURVIVES into execute() (our snapshot lives here)
```
blink ADDS `source_id`/`source_name`/`cursor_column`/`score` itself — do NOT set those.
`data` is the ONLY field that round-trips our pi item + snapshot into `execute` (§2).

---

## §2 — The accept-time design decision (THE load-bearing block)

**The tension:** PRD §7.7 + TL;DR mandate "acceptance delegated back to pi's
`applyCompletion` so that insertion behavior is identical to the TUI" (trailing
space for files/slash, no space for dirs, quote handling, cursor reposition).
`applyCompletion(lines, cursorLine, cursorCol, item, prefix)` returns the
**COMPLETE new buffer + cursor** (extension/protocol.ts `ApplyCompletionResult`) —
it is authoritative. BUT blink.cmp's accept flow applies the item's `textEdit`
**FIRST**, THEN calls the source's `execute(ctx, item, callback, default_impl)` (per
`sources/lib/init.lua` `execute()` + the zread sequence diagram: "execute — After
textEdit"). So by the time `execute` runs, the buffer already contains blink's edit.

**The resolution (mirrors codecompanion §3 — the closest analog):** store a
**snapshot of the pre-accept state on each item's `data.pi`** at `get_completions`
time, set a **`textEdit` that does a correct basic insertion as a graceful
fallback**, and have **`execute` issue `applyCompletion(snapshot)` and overwrite the
WHOLE buffer + set the cursor** in the async cb. blink's `textEdit` is a transient
that gets immediately overwritten by pi's authoritative result.

Concretely each mapped blink item:
```lua
{
  label   = pi_item.label,                       -- menu text
  kind    = guess_kind(pi_item),                 -- Keyword for /cmd, File/Folder for @/path
  detail  = pi_item.description,                 -- side text
  textEdit = {                                   -- graceful-fallback insertion + menu preview
    newText = pi_item.value,                     -- the FULL canonical value (e.g. "/model", "@/src/comp.ts")
    range   = prefix_range,                      -- covers EXACTLY pi's prefix (cursor-relative, via coords)
  },
  data = { pi = pi_item, prefix = prefix,        -- the round-trip payload execute() reads
           lines = snap_lines, cursorLine = snap_cl, cursorCol = snap_cc },
}
```

**`execute(ctx, item, callback, default_implementation)` flow (NEVER call default_impl —
we do NOT want blink's snippet/extra logic; we overwrite wholesale):**
1. Read `item.data` defensively (bail + `callback()` if malformed — never hang blink).
2. Read `require("pi-editor").bridge` FRESH; if absent/disconnected → degrade to the
   blink `textEdit` already applied: call `default_implementation()`? NO — the
   textEdit is ALREADY applied by blink before execute; just call `callback()` and
   return (the basic insertion stays; graceful). (Confirmed: blink applies textEdit
   pre-execute, so the buffer is already sensible.)
3. Issue `bridge.request("applyCompletion",
   { lines=snap_lines, cursorLine=snap_cl, cursorCol=snap_cc, item=pi_item,
     prefix=prefix }, cb)`. **Call `callback()` immediately after issuing** (responsive;
   never hang blink even if the RPC times out — mirrors completion.lua `on_enter`
   returning true as soon as the RPC is issued).
4. In the async cb (`schedule_wrap`d by bridge → api-safe): on success convert pi→nvim
   via `coords.pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)`
   → `nvim_buf_set_lines(ctx.bufnr, 0, -1, false, nv.lines)` (WHOLE buffer replace) +
   `nvim_win_set_cursor(0, { nv.row, nv.col })` (0-based byte col, **NO -1** —
   coords.lua's exact-UTF-16 design supersedes PRD §7.4). On error: leave the buffer
   as blink's textEdit left it (graceful — the basic insertion stays); never throw.

**Why the snapshot is correct (and its one limitation):** applyCompletion computes
the result from the `(lines, cursorLine, cursorCol, item, prefix)` it receives. We
give it the EXACT params from the `getSuggestions` request whose result produced this
item (consistent — the `prefix` in the result matches the `lines` we sent). So the
wholesale overwrite is byte-consistent with pi's TUI for that fetch. **Limitation:** if
the user types between the last fetch and accept, the snapshot is stale (applyCompletion
uses the pre-typing state). For a prompt editor this is vanishingly rare AND matches
pi's own model (pi applies on Enter/Tab from the state at that moment); document it.
A v1.1 refinement could re-read the buffer in execute and re-derive the prefix, but
that fights blink's already-applied textEdit — not worth it for v1.

**Why NOT let blink's textEdit be the final state (i.e. why execute is required):**
blink's textEdit can only insert `pi_item.value` (no trailing space, no cursor
reposition, no quote handling). That DIVERGES from the TUI for files/slash — e.g.
accepting `/model` would yield `/model` not `/model `; accepting `comp.ts` would
yield `@/src/comp.ts` not `@/src/comp.ts `. The PRD's "identical to the TUI" goal
REQUIRES `execute`→`applyCompletion`. The `textEdit` is purely the graceful fallback
+ the menu preview (blink shows `label`; the textEdit only matters on accept).

---

## §3 — The codecompanion.nvim reference (authoritative real-world analog)

`olimorris/codecompanion.nvim` `lua/codecompanion/providers/completion/blink/init.lua`
is a chat-buffer slash-command completion source — the EXACT same shape as ours
(slash commands + `@`-style editor context in a chat buffer). Verified patterns to
MIRROR:

- **`M.new()` = `setmetatable({}, { __index = M })`** — single line, no opts needed
  for us (opts is the provider config table; we accept + ignore it, or read
  `require("pi-editor").config`).
- **`M:enabled()` gates by filetype**: `return vim.bo.filetype == "pi-prompt"` (so
  the source is dormant outside pi prompt buffers — the SOURCE-level twin of our
  `init.lua` VimEnter activation gate). This is cleaner than gating in get_completions.
- **`M:get_trigger_characters()`** returns `{ "/", "@" }` (the two pi trigger chars;
  `/` for commands/templates/skills, `@` for file/path mentions). Optionally `#` if
  we mirror completion.lua's `is_attachment_context` (`@`/`#`).
- **`M:get_completions(ctx, callback)`** builds an `edit_range` from `ctx.bounds`,
  maps items to `{ kind, label, textEdit={newText,range}, documentation={...},
  data={...} }`, calls `callback({ is_incomplete_forward, is_incomplete_backward,
  items })`. On "no trigger / nothing": `callback()` (nil).
- **`M:execute(ctx, item, callback, default_implementation)`** — codecompanion's
  slash path CLEARS the keyword blink inserted then runs its own logic:
  ```lua
  -- clear the inserted text (blink's textEdit already ran)
  vim.lsp.util.apply_text_edits({ { newText = "", range = item.textEdit.range } }, ctx.bufnr, "utf-8")
  -- ... custom logic ...
  callback()
  ```
  **WE DO NOT need to clear** — we overwrite the WHOLE buffer with applyCompletion's
  `result.lines`, so the keyword is gone implicitly. (Clearing then overwriting is
  redundant.) Keep this as a documented divergence (codecompanion clears because it
  does NOT do a full-buffer replace; we DO).
- **`callback()` MUST be called exactly once** or blink's accept hangs (codecompanion
  always reaches a `callback()`). We call it right after issuing applyCompletion (§2).

---

## §4 — Integration seams in THIS repo (all COMPLETE + in-tree)

| Seam | Where | How the source uses it |
|---|---|---|
| Bridge RPC | `require("pi-editor").bridge` (set by bridge.lua S25 ONLY after a successful `hello`; `nil` otherwise) | `.request(method, params, cb)` → `cb(err, result)` (schedule_wrap'd → api-safe); `.is_connected()` gate; `.cancel(id)` supersession; `.server_info` (cwd/fdAvailable) |
| Coords | `require("pi-editor.coords")` | `.nvim_to_pi_coords(lines, row, byte_col)` → `{lines, cursorLine, cursorCol}`; `.pi_to_nvim_coords(lines, cl, cc)` → `{lines, row, col}`. **THE centralized seam** (PRD §8) — never call `vim.str_*index` directly. |
| Config | `require("pi-editor").config` (after setup()) | `.rpc_timeout_ms` (default 2000) — informational; the bridge enforces it. `.engine` (we READ it; the module works regardless). |
| Provider item | `pi-editor.AutocompleteItem` (completion.lua class) | `{ value, label, description?, ... }` — forwarded VERBATIM as the `item` param of applyCompletion (the bridge server forwards it verbatim to pi; pi keys on the whole table). |

**RPC param shapes (mirror completion.lua do_refresh / accept EXACTLY):**
- `getSuggestions`: `vim.tbl_extend("keep", pi_coords, { force = false })` → `{lines, cursorLine, cursorCol, force=false}`. Result: `{items, prefix}` or `null` (= `cb(nil, nil)`).
- `applyCompletion`: `{lines, cursorLine, cursorCol, item=pi_item, prefix=prefix}`. Result: `{lines, cursorLine, cursorCol}`.

**Reading the bridge FRESH at call time** (`local bridge = require("pi-editor").bridge`
INSIDE get_completions/execute, NOT a module-load local) — mandatory: the handshake
resolves async after VimEnter, and tests swap a fake bridge in after `require`
(mirrors completion.lua's documented rule).

**Coords are read fresh too** (uniform; coords is stateless so a local would work,
but fresh is the repo convention + survives `/reload`).

---

## §5 — Supersession, async, and the "never require blink.cmp" rule

**Two-layer supersession in get_completions** (mirrors completion.lua do_refresh,
adapted to blink's `ctx.id`):
- **Layer 1 (optimization):** `bridge.cancel(prev_inflight_id)` when a newer
  `get_completions` fires while a request is in-flight (frees the round-trip + drains
  the server's AbortController promptly — the server self-supersedes getSuggestions).
- **Layer 2 (CORRECTNESS boundary):** capture `ctx.id` in the cb closure; ignore the
  cb if a newer `get_completions` bumped the current id (`if captured_id ~= state.current_id then return end`). cancel can RACE (the cb is schedule_wrap'd; a response
  can land between cancel and the new request); the id guard CANNOT.
- **Error/cancel/timeout → touch nothing** (the nvim-cmp + blink idiom): on
  `cb("cancelled"/"timeout"/<err>)`, do NOT call `callback()` with empty items, do
  NOT call it with stale items — just return. (Blink already has the prior context's
  items; a failed fetch is not a "clear".) Actually: blink awaits our `callback`
  ONCE per `get_completions` request. If we NEVER call callback on error, blink's Task
  for that request never resolves → blink's queue handles it (the queue is destroyed on
  the next context.id change). To be SAFE + match blink's contract, on error call
  `callback()` (nil = "nothing from me this round") — this is the cleanest: it tells
  blink "I have nothing" without flicker (blink keeps prior items from OTHER sources,
  not ours). **Decision: on error/timeout/cancel → `callback()` (nil).** Document it.

**`callback()` is api-safe:** the bridge `request` cb is `schedule_wrap`d → runs on
the nvim main loop; calling blink's `callback` there is fine (NO `vim.schedule_wrap`
wrapper needed — mirrors completion.lua). The `path` source wraps in
`schedule_wrap` because its OWN completion runs in a luv callback; ours runs in
the bridge's already-scheduled cb.

**NEVER `require("blink.cmp")` at runtime.** blink.cmp is the USER's optional plugin —
it is NOT a dependency of this repo. The source module must `require()` ONLY:
`pi-editor.bridge`-via-`pi-editor`, `pi-editor.coords`, `pi-editor` (config), and
vim stdlib (`vim.api`, `vim.lsp.protocol`, `vim.json`, `vim.tbl_*`). The blink.cmp
types are referenced via a `---@module 'blink.cmp'` COMMENT / emmy annotations only
(codecompanion does exactly this: line 1 `--- @module 'blink.cmp'`, never a runtime
require). A `require("blink.cmp")` at module top would ERROR when blink isn't
installed (the common case for users who use nvim-cmp or the builtin menu) and break
the dormant-by-default contract.

**`enabled()` is the filetype gate** (`vim.bo.filetype == "pi-prompt"`) — the
source-level twin of `init.lua`'s VimEnter activation gate. Even if the user
registers the source globally in their blink config, `enabled()` keeps it dormant
outside pi prompt buffers.

---

## §6 — Test plan (mirrors the repo's spec + smoke discipline; AGENTS.md hard rule)

**CREATE `plugin/tests/blink_source_spec.lua`** (plenary; reuse a `fake_bridge`
helper modeled on `completion_spec.lua`'s). Cases:
1. `new()` returns a table with `get_trigger_characters`/`get_completions`/`execute`/`enabled` (all functions).
2. `get_trigger_characters()` returns a table containing `"/"` and `"@"`.
3. `enabled()` returns true for a `pi-prompt` buffer, false otherwise.
4. `get_completions(ctx, callback)` with a connected fake bridge:
   - issues `getSuggestions` with `{lines, cursorLine=row-1, cursorCol=<utf16>, force=false}`;
   - the cb maps pi items to blink items: `label=pi.label`, `kind` set, `detail=pi.description`, `textEdit.newText=pi.value`, `data.pi=<pi item>`, `data.prefix=<prefix>`;
   - calls `callback({is_incomplete_forward=false, is_incomplete_backward=false, items=...})`.
5. Supersession: a 2nd `get_completions` (newer `ctx.id`) while in-flight → the OLDER cb does NOT fire `callback` with its items (id-guard) OR fires `callback()` (nil); the NEWER cb's items win. Mirror completion.lua's two-layer test.
6. Error path: `getSuggestions` `cb("timeout")` → `callback()` (nil) — no throw, no stale items.
7. Bridge nil / disconnected → `callback()` (nil) — graceful.
8. `execute(ctx, item, callback, default_impl)`:
   - reads `item.data`, issues `applyCompletion` with `{lines, cursorLine, cursorCol, item=pi_item, prefix}`, calls `callback()` immediately after issuing;
   - in the RPC cb success → `nvim_buf_set_lines(buf,0,-1,false,result.lines)` + `nvim_win_set_cursor(0,{row,col})` (assert content + cursor; include a MULTIBYTE case via coords);
   - error cb → buffer UNTOUCHED (blink's prior textEdit state stays); never throws.
9. `execute` with malformed `item.data` (no `pi`) → `callback()` + no throw (never hang blink).
10. NEVER `require("blink.cmp")` — assert `package.loaded["blink.cmp"] == nil` after requiring the source (the module must load without blink installed).

**CREATE `plugin/tests/blink_source_smoke.lua`** (plenary-free; mirror
`completion_accept_smoke.lua`'s fake-server bootstrap). Fake luv unix-socket server
+ REAL `bridge.handshake` + REAL `blink_source` module + REAL `coords`. Flow:
- set buffer `{"@sr"}`, filetype `pi-prompt`, cursor at EOL;
- `src:get_completions(make_ctx(buf), function(resp) ... end)` → server sees `getSuggestions` → reply `{items={{value="@/src/comp.ts", label="comp.ts", description="src/comp.ts"}}, prefix="@sr"}`;
- `vim.wait` → assert `resp.items[1].textEdit.newText == "@/src/comp.ts"` + `resp.items[1].data.pi.value == "@/src/comp.ts"` + `resp.items[1].data.prefix == "@sr"`;
- build `item` from `resp.items[1]`; `src:execute(make_ctx(buf), item, function() end, function() end)` → server sees `applyCompletion` with `{item=<pi item>, prefix="@sr", lines={"@sr"}, cursorLine=0, cursorCol=4}` → reply `{lines={"@/src/comp.ts "}, cursorLine=0, cursorCol=15}` → `vim.wait` → assert buffer == `{"@/src/comp.ts "}` + cursor at `{1,15}` + `menu.is_open()==false` (we close the builtin menu too if open).
- `bridge.close()` + server stop. Print `SMOKE_PASS` / exit 0.

The smoke does NOT use real blink.cmp (not a project dep) — it drives the MODULE's
`get_completions`/`execute` DIRECTLY with a hand-built `ctx` (the fields from §1).

**⚠️ AGENTS.md hard rule:** write the smoke Lua to a FILE (`plugin/tests/blink_source_smoke.lua`) then run
`timeout 60 nvim --headless --clean -u tests/minimal_init.lua +"luafile tests/blink_source_smoke.lua" +qa`
— NEVER pipe a heredoc into nvim stdin (it hangs the session). Wrap EVERY nvim
invocation in `timeout`. (See AGENTS.md ⛔ HARD RULE.)

---

## §7 — Scope guards, non-regression, and the `engine` forward-contract

**Scope (S45):** ONE new module file `plugin/lua/pi-editor/blink_source.lua` +
its spec + its smoke. That is it. It does NOT modify `init.lua`, `completion.lua`,
`bridge.lua`, `coords.lua`, `menu.lua`, the ftplugin, or the extension. The source
is SELF-CONTAINED and OPT-IN.

**Known coordination point (forward-contract, NOT S45's job to wire):** `init.lua`
config has `engine = "builtin" | "blink" | "cmp"` (auto-detect if unset). When the
user picks `"blink"`, BOTH the builtin floating menu (driven by ftplugin
autocmds → completion.lua → menu.lua) AND blink.cmp would show — a double-UI. The
clean resolution is for the ftplugin (S22) / a future engine-wiring task to SUPPRESS
the builtin menu autocmds when `config.engine == "blink"|"cmp"`. **S45 does NOT
implement that suppression** (it would touch the ftplugin + completion.lua + init,
out of scope for "the source module"). S45's module is correct standalone; the
docstring + this note flag the coordination for the engine-wiring follow-up.
Recommendation to document in the module + README: "to use blink exclusively, set
`engine = 'blink'` in setup() once the suppression lands; until then the source is
additive."

**`getCommands` / `commandsChanged` are out of scope** for S45 (the source gets
items via getSuggestions, which already includes commands/templates/skills). A
future richer-docs-menu task could use `getCommands` + `resolve` for hover docs —
note as a §15-style future enhancement, not S45.

**`NVIM_APPNAME` (S47) is orthogonal** — the source works in any nvim config that
loads `pi-editor.nvim`; the minimal-config optimization doesn't affect the module.

**No external Lua deps added** — the module uses only vim stdlib + the in-tree
`pi-editor.*` modules. blink.cmp is the user's plugin (loaded by THEM; we never
require it).