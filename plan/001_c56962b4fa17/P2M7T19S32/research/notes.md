# P2.M7.T19.S32 — Research Notes (accept flow via applyCompletion)

The accept task: implement `completion.accept(item)` + `completion.on_enter(buf)` in
`plugin/lua/pi-editor/completion.lua` (MODIFY; the only existing file touched) — read the
selected item + prefix from the COMPLETE menu module (S31), read the CURRENT buffer lines +
cursor, convert nvim→pi via the COMPLETE coords module (S29), issue the `applyCompletion`
JSON-RPC over the COMPLETE bridge (S26), and in the async callback convert pi→nvim + replace
the whole buffer + set the cursor + close the menu. Add `*_spec.lua` cases + a `*_smoke.lua`.

All upstream deps are COMPLETE and in-tree. This file consolidates the contract surface +
the ONE external-research block (nvim insert-mode accept semantics) the implementation hinges
on. No new external libraries; pure Lua + `vim.api` + the in-tree bridge/coords/menu.

---

## §1 — The S32 contract (verbatim from `tasks.json`)

> **Title:** Accept — applyCompletion RPC, replace buffer, set cursor, close menu.
> **Status:** Researching. **Points:** 1. **Dependencies:** `P2.M7.T18.S31` (menu state),
> `P2.M6.T17.S29` (coords wrappers).
>
> 1. RESEARCH NOTE: Per PRD §7.4 accept flow: (1) read current lines + cursor, (2) call
>    `applyCompletion(lines, cursorLine, cursorCol, selectedItem, prefix)`, (3) replace
>    buffer lines via `nvim_buf_set_lines(0, 0, -1, false, result.lines)`, (4) position
>    cursor: convert `result.cursorCol` (UTF-16) → byte via coords, then
>    `nvim_win_set_cursor(0, { result.cursorLine + 1, bytecol })`, (5) close menu, stay in
>    insert mode. Per architecture/research-pi-autocomplete.md, applyCompletion handles all
>    insertion edge cases (trailing spaces, directories, quotes, /cmd space).
> 2. INPUT: the selected AutocompleteItem (from current_items), the current_prefix (from the
>    getSuggestions result). Current buffer lines + cursor.
> 3. LOGIC: Implement `M.accept(item)` that: (a) gets current lines + cursor, converts to pi
>    coords, (b) calls `bridge.request("applyCompletion", {lines, cursorLine, cursorCol,
>    item, prefix}, callback)`, (c) in callback: `nvim_buf_set_lines(0, 0, -1, false,
>    result.lines)`, convert `result.cursorLine/cursorCol` to nvim coords,
>    `nvim_win_set_cursor(0, {row, byte_col})`, close menu, (d) use feedkeys to re-enter
>    insert mode if needed. The RPC is synchronous from pi's side but async on ours — the
>    callback handles the result.
> 4. OUTPUT: buffer updated + cursor positioned correctly.
> 5. MOCKING: mock bridge to verify applyCompletion params + buffer replacement + cursor.
> 6. DOCS: [Mode A] Lua docstring explaining the 5-step PRD §7.4 accept flow.

**Cross-reference (the S36 navigation contract, `tasks.json`):** "The accept is handled by
**completion.lua's accept() (S32)** which calls `M.get_selected()` then closes." → confirms
`accept` lives in **completion.lua** and uses **menu.get_selected()** + **menu.close()**.
This is the authoritative placement decision: NOT menu.lua (menu is windowless STATE only —
the blink `list.lua` model), NOT a new module.

**Cross-reference (the ftplugin, `plugin/ftplugin/pi-prompt.lua`):** `<CR>` →
`dispatch("pi-editor.completion", "on_enter", buf)` → if `on_enter` returns truthy the CR is
CONSUMED; else the ftplugin `feedkey("<CR>")` inserts a NEWLINE (PRD §7.4: no
Enter-to-submit; quitting submits). So **S32 owns `on_enter`** (CR = accept-or-newline);
`on_tab` is S33 (separate task). The ftplugin is ALREADY wired — S32 does NOT touch it.

---

## §2 — The wire shapes (authoritative: `extension/protocol.ts`)

```ts
/** applyCompletion (C→S): delegate insertion to pi for byte-identical behavior. */
export interface ApplyCompletionParams {
  lines: string[];
  cursorLine: number;   // 0-indexed (pi)
  cursorCol: number;    // 0-indexed UTF-16 code-unit offset (pi) — coords.nvim_to_pi_coords
  item: AutocompleteItem;   // { value, label, description?, ... } — forwarded VERBATIM
  prefix: string;           // menu.get_prefix() — the getSuggestions result.prefix
}
/** applyCompletion result: the NEW full buffer + cursor (pi computes insertion). */
export interface ApplyCompletionResult {
  lines: string[];          // the COMPLETE new line array — replace buf wholesale
  cursorLine: number;       // 0-indexed (pi)
  cursorCol: number;        // 0-indexed UTF-16 (pi) — coords.pi_to_nvim_coords
}
```

**Server-side handler (`extension/pi-editor-bridge.ts` `makeApplyCompletionHandler`, ~L750):**
applyCompletion is a **PURE SYNC function** on pi's side (pi `autocomplete.ts:256-271`,
called WITHOUT await in `editor.ts:669/690/2257`). The handler has **NO AbortController, NO
supersession, NO timeout** (unlike getSuggestions) — plain delegation. It forwards
`(lines, cursorLine, cursorCol, item, prefix)` VERBATIM + returns pi's result UNCHANGED.
**Implication for the client:** the RPC round-trip is fast (local socket + a pure fn), but
it is STILL async on our side — the result lands in the `bridge.request` callback
(`schedule_wrap`d → nvim main loop). on_enter must return `true` (CR consumed) as soon as the
RPC is ISSUED; the buffer mutation happens in the callback.

**Insertion edge cases are PI'S job** (PRD §4 step 5, §6.5): slash `/cmd ` trailing space,
`@file` trailing space for files / none for directories, quote handling, cursor
repositioning. The client NEVER reimplements insertion — it applies pi's `result.lines`
WHOLESALE + positions the cursor from pi's `result.cursorCol`. This is why the contract is
"replace ALL lines via `nvim_buf_set_lines(0, 0, -1, false, result.lines)`", not a text-edit.

---

## §3 — The coordinate contract (authoritative: `plugin/lua/pi-editor/coords.lua`)

S32 routes BOTH conversions through the COMPLETE centralized seam (PRD §8 "MUST be
centralized so the fix is one place"; coords.lua header: "Downstream consumers … MUST
require('pi-editor.coords') and call these. They MUST NOT call vim.str_utfindex /
vim.str_byteindex directly"):

```lua
-- (1) nvim → pi (read buffer + cursor, build the applyCompletion params):
local cur   = vim.api.nvim_win_get_cursor(0)            -- {row 1-indexed, col 0-indexed BYTE}
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local pi    = coords.nvim_to_pi_coords(lines, cur[1], cur[2])
-- pi == { lines=lines, cursorLine=cur[1]-1, cursorCol=<UTF-16 via byte_to_utf16> }

-- (2) pi → nvim (apply pi's result.lines + result.cursor*):
local nv = coords.pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)
-- nv == { lines=result.lines, row=result.cursorLine+1, col=<0-indexed BYTE via utf16_to_byte> }
vim.api.nvim_buf_set_lines(buf, 0, -1, false, nv.lines)
vim.api.nvim_win_set_cursor(0, { nv.row, nv.col })     -- NO -1 (see below)
```

**⚠️ REFINEMENT over PRD §7.4 step 4 (documented in `coords.lua` header — "document every
refinement over PRD"):** PRD §7.4 says `nvim_win_set_cursor(0, { row, bytecol - 1 })`. Under
the exact-UTF-16 + 0-based-byte-cursor-API design (S28/S29 + `external_deps.md §1.2`:
`nvim_win_get_cursor[2]` is already 0-based byte, and `nvim_win_set_cursor` takes the SAME
0-based byte), that `-1` DOUBLE-CORRECTS — it would nudge the cursor ONE BYTE LEFT on every
accept (worst on multibyte lines). **S32 follows coords.lua over PRD §7.4: NO `-1`.** The
`pi_to_nvim_coords` wrapper returns a `col` ready for `nvim_win_set_cursor` UNCHANGED. A
reader of PRD §7.4 should not be surprised by the absent `-1` — that is why this note exists
(mirrors the S28 utf16_len_of_prefix / S29 bytecol-1 supersession patterns).

---

## §4 — The menu seam (authoritative: `plugin/lua/pi-editor/menu.lua`, S31)

S32 READS the menu (the windowless STATE layer — the blink `list.lua` model) and CLOSES it.
It does NOT couple to the (Planned, S34) floating window. The accessors S32 uses:

| Accessor | Returns | S32 use |
|---|---|---|
| `menu.is_open()` | bool | on_enter gate (CR accepts ONLY when the menu is showing) |
| `menu.has_items()` | bool (#items>0) | on_enter gate (defensive; is_open implies this) |
| `menu.get_selected()` | `items[selected]` or nil | the `item` param passed to `applyCompletion` |
| `menu.get_prefix()` | string (the last `on_results` prefix) | the `prefix` param of `applyCompletion` |
| `menu.get_buf()` | integer? (the pi-prompt buf of the last `on_results`) | the buffer to read/write |
| `menu.close()` | clears items/selected/open | called in the accept callback (S32's only menu WRITE) |

**Why menu (not `completion.current()`)?** completion.lua's `current()` also exposes
`{items, prefix}`, but the S36 contract pins accept to `menu.get_selected()` + `menu.close()`
— the menu is the accept authority (it owns the SELECTION the user navigated to). The prefix
and buf are consistent between `completion.current()` and the menu (both set from the same
`on_results` payload), so either is correct; the menu is the canonical choice per S36.

**Re-read fresh inside accept (`require("pi-editor.menu")` inside the fn, NOT a module-load
local):** mirrors completion.lua's "bridge read fresh" rule — the handshake resolves async +
tests swap fakes after require + a `/reload` re-runs `activate()`. Same for the bridge +
coords (coords is stateless so a local is fine, but reading fresh is harmless + uniform).

---

## §5 — nvim insert-mode accept semantics (THE external-research block)

Verified via `:help` (stable, confirmable in nvim ≥ 0.9) + the blink.cmp/nvim-cmp source
layout. This is the load-bearing research for S32 — it determines the exact API call sequence
+ whether a re-entrancy guard is needed. **Answer: the sequence is two API calls in order, no
mode dance, no feedkeys, no re-entrancy loop.**

### Q1 — Does `nvim_win_set_cursor` move the VISIBLE cursor in Insert mode?

**YES.** `:help nvim_win_set_cursor()`: moves the cursor AND "This will scroll the window
such that the cursor is visible." It does NOT fire `CursorMoved`/`CursorMovedI`. No `redraw`
normally needed; `:help nvim__redraw({ flush = true })` only for cross-window/TUI stale-cursor
edge cases (out of scope for a single-buffer prompt editor). **Order matters:** `set_lines`
FIRST, then `set_cursor` (so the cursor lands in the NEW buffer content). S32 needs NO
feedkeys/redraw nudge.

### Q2 — Does `nvim_buf_set_lines` (API mutation) fire `TextChangedI` in Insert mode?

**NO.** `:help TextChangedI`: fires "after a change was made to the text in Insert mode" —
i.e. **typed input**, not API mutations. `nvim_buf_set_lines` / `nvim_buf_set_text` do NOT
fire `TextChangedI`/`TextChangedP`/`TextChanged`. **`b:changedtick` DOES increment**
(`:help b:changedtick`) — so do NOT key refresh off changedtick; key it off `TextChangedI`
(which the refresh autocmds already do, S22/S30).

**⇒ S32's accept CANNOT cause a `TextChangedI`→refresh→getSuggestions loop**, because the
buffer replace is an API call, not typed input. This is the critical simplification: **no
re-entrancy guard is REQUIRED for correctness.** (A defensive `state.accepting` flag is
OPTIONAL insurance for the async callback path — see §6.)

### Q3 — The reference confirm sequence (blink.cmp / nvim-cmp)

Both apply a completion by **buffer-API text edit + cursor set, staying in Insert mode — NO
`feedkeys("<Esc>")`/`("i")`, NO `<C-g>U`/`<C-r>` dance** for the primary path:
- **blink.cmp** (`lua/blink/cmp/completion/accept/init.lua` + `accept/text_edits.lua`): applies
  the edit via `vim.api.nvim_buf_set_text` (or set_lines) then positions the cursor with
  `nvim_win_set_cursor`. No feedkeys/mode switch.
- **nvim-cmp** (`lua/cmp/core.lua` `confirm`): applies the entry's text edit via the buffer
  API; `feedkeys`/`<C-g>U` appears ONLY for undo-break grouping, NOT mode switching.

(Exact commit SHAs not pinned here — the behavior is authoritative via `:help`; pin SHAs
before quoting line numbers. The S32 PRP cites these as the design rationale, not line-precise
proof.) **S32's recommended sequence** (whole-buffer replace variant — pi returns ALL lines):
```lua
vim.api.nvim_buf_set_lines(buf, 0, -1, false, nv.lines)   -- replace ALL lines
vim.api.nvim_win_set_cursor(0, { nv.row, nv.col })         -- 0-based byte col (NO -1)
-- user stays in Insert mode. No redraw. No feedkeys.
```

### Q4 — Re-entrancy guard pattern

Idiomatic: a boolean flag (`accepting = true/false`) gating the refresh entry point. Because
TextChangedI does NOT fire from API changes (Q2), the guard is **defensive insurance**, not a
loop-prevention necessity. The realistic async race it guards: the user presses `<CR>`,
`accept` issues `applyCompletion`, the user types a char BEFORE the RPC callback lands → that
char's `TextChangedI` fires `refresh` → a `getSuggestions` is now in-flight alongside the
`applyCompletion` → the applyCompletion result then replaces the buffer; the now-stale
getSuggestions result may arrive and populate the menu with suggestions for PRE-accept text.
A `state.accepting` flag set on issue + cleared in the callback lets `refresh` (or the
getSuggestions cb) skip work during the accept window. **For v1 / S32 scope the flag is
OPTIONAL** (the race is narrow + self-corrects on the next keystroke); the PRP offers it as a
documented defensive refinement, not a required gate. (If added, gate `do_refresh`'s top:
`if state.accepting then return end`, set in `accept`, clear in the cb.)

### Q5 — Mode preservation + edge cases

`:help mode()` — `nvim_buf_set_lines` + `nvim_win_set_cursor` do NOT change `mode()`; the
user stays in Insert. Edge cases to guard in S32:
- **`modifiable=off`** → `nvim_buf_set_lines` throws `E21`. Guard: the pi-prompt buffer is
  writable (S22 does not set `nomodifiable`; `BufWritePre` is intentionally not overridden),
  so this won't arise — but `pcall` the set_lines anyway (never-throws contract).
- **byte `col`** — `nv.win_set_cursor` col is BYTES not chars; `pi_to_nvim_coords` returns
  bytes (via `utf16_to_byte` → `vim.str_byteindex`), so this is already correct. Do NOT pass a
  codepoint/UTF-16 index to `nvim_win_set_cursor`.
- **buffer not in current window** — `nvim_win_set_cursor(0, …)` targets the CURRENT window.
  S30's `do_refresh` guards `buf == nvim_get_current_buf()`; S32's `on_enter` mirrors it
  (one pi-prompt buffer per session, PRD §11). If the menu's buf isn't current, bail.

### What NOT to do
- ❌ Do NOT `feedkeys("<Esc>")` then `("i")` to "re-enter" Insert — you never left it (Q5).
- ❌ Do NOT use `vim.fn.cursor()` (1-based col) for the accept cursor — it mismatches the
  0-based byte `nvim_win_set_cursor`/coords contract. Use `nvim_win_set_cursor(0, {row,col})`.
- ❌ Do NOT add `bytecol - 1` (PRD §7.4 step 4) — SUPERSEDED by coords.lua (§3).
- ❌ Do NOT fire `TextChangedI` yourself / route the edit through `feedkeys` "to trigger
  refresh" — API edits don't fire it (Q2); the user's next typed char will, which is correct.
- ❌ Do NOT reimplement insertion (trailing space / quotes / dir-vs-file) — pi's
  `applyCompletion` returns the WHOLE new buffer; apply it wholesale (§2).

---

## §6 — The accept callback's async + the TWO-LAYER bridge

`bridge.request` (S26) is generic + TWO-LAYER: the `pending` map holds EVERY concurrent
outstanding request, so an `applyCompletion` racing a `getSuggestions` each resolve to their
OWN cb (bridge.lua header: "Do NOT collapse this to a single 'current id' — that would
mis-drop a legitimate applyCompletion response when a newer getSuggestions fires"). Supersession
is the CALLER's job (latest-id guard / `cancel(id)`). For S32's `applyCompletion`:
- It is a ONE-SHOT user action (CR), not continuously superseded like getSuggestions. No
  generation-id guard is needed — capture the buf in the closure; in the cb validate the buf
  is still valid + current; then apply. If the user typed between issue + cb, the accept
  result is AUTHORITATIVE (the user explicitly accepted) — overwriting their interim typing is
  the correct pi-faithful behavior (pi's TUI applies immediately on Enter/Tab).
- The per-request 2000ms timeout (bridge.lua `config.rpc_timeout_ms`) handles "response never
  comes" → cb("request timeout") → degrade (menu.close + the buffer is untouched; the user's
  interim text remains). On ANY cb error: do NOT mutate the buffer; `menu.close()` (the menu
  is stale) + return (silent degrade — S39's job to notify once).

**Stay-in-insert after a cb error:** the user is in Insert; on error we leave the buffer
untouched + close the menu. The user can re-type or re-trigger. No mode change.

---

## §7 — Test strategy (mirrors the S30/S31 spec + smoke discipline)

**Extend `plugin/tests/completion_spec.lua`** with a `describe("accept/on_enter", ...)`
block — accept lives in `completion.lua`, so it belongs in the completion spec (the repo's
"one spec per module" rule; S31's `menu_spec.lua` is for the separate `menu.lua` MODULE).
Reuse the EXISTING `fake_bridge(opts)` helper (controllable `request`/`cancel`/`is_connected`
+ `resolve(i,err,result)`/`resolve_last`). Cases:
1. `accept(item)` issues `applyCompletion` with params `{lines, cursorLine=row-1,
   cursorCol=<S29 utf16>, item=<the item table verbatim>, prefix=<menu prefix>}` (assert on
   `fake.requests[#].method == "applyCompletion"` + the params shape; mirror the S30 case 3).
2. cb success → `nvim_buf_set_lines(buf,0,-1,false,result.lines)` ran (assert buffer content)
   + `nvim_win_set_cursor(0,{row,col})` positioned the cursor (assert `nvim_win_get_cursor`)
   + `menu.close()` ran (`menu.is_open()==false`). Include a MULTIBYTE case (e.g. cursor after
   `日`) to prove the byte-col + NO-`-1` conversion.
3. cb error (`"rpc error -32603"` / `"request timeout"`) → buffer UNTOUCHED + `menu.is_open()==false`
   (degrade) + never throws.
4. `on_enter(buf)` with menu open+selected → returns `true` (CR consumed) + accept issued;
   with menu closed / no selected → returns `false` (fall-through; the ftplugin feeds `<CR>`).
5. `on_enter` / `accept` never-throws on bad args (nil item, wiped buf, bridge nil) + when
   menu/coords absent.

**CREATE `plugin/tests/completion_accept_smoke.lua`** (plenary-free; mirror `menu_smoke.lua`'s
fake-server bootstrap). Fake luv unix-socket server + REAL `bridge.handshake` + REAL
`completion` + `menu.attach()`; set buffer lines `{"/mo"}`; `completion.refresh(buf)` →
server sees `getSuggestions` → reply `{items={{value="/model",label="model"}}, prefix="/mo"}`
→ `vim.wait` → assert `menu.is_open()` + `get_selected().value=="/model"`; THEN
`completion.on_enter(buf)` → server sees `applyCompletion` with `{item=<the item>,
prefix="/mo", lines={"/mo"}, cursorLine=0, cursorCol=3}` → reply
`{lines={"/model "}, cursorLine=0, cursorCol=7}` → `vim.wait` → assert buffer ==
`{"/model "}` + cursor at `{1,7}` + `menu.is_open()==false`. Then `menu.reset()` +
`completion.reset()` + `bridge.close()` + server stop. Print `SMOKE_PASS` / exit 0.

**⚠️ AGENTS.md (the repo's hard rule):** the smoke writes Lua to a FILE then runs
`nvim … +"luafile tests/completion_accept_smoke.lua" +qa` — NEVER pipe a heredoc into nvim
stdin (it hangs the session). Wrap every nvim invocation in `timeout 60`.

---

## §8 — Non-regression + scope guards

- **Only ONE existing file MODIFIED:** `plugin/lua/pi-editor/completion.lua` (ADD `accept` +
  `on_enter` + update the [Mode A] header's forward-contracts list — the header currently says
  "the 6 keymaps (on_tab/on_enter/…) stay absent"; S32 lands `on_enter`). NO change to
  `menu.lua`, `bridge.lua`, `coords.lua`, `jsonlreader.lua`, `init.lua`, the ftplugin, or the
  shim. (The ftplugin ALREADY dispatches `on_enter` — S32 just makes it return truthy.)
- **One existing file EXTENDED:** `plugin/tests/completion_spec.lua` (additive
  `describe("accept/on_enter")` block; the S30 cases stay green — `reset()` before/after_each
  already clears `on_results` + state).
- **Two NEW files:** `plugin/tests/completion_accept_smoke.lua` (the plenary-free smoke).
  (No new module file — accept is a method on the EXISTING completion.lua.)
- **S33 stays intact:** S32 implements `on_enter` (CR) ONLY; it does NOT implement `on_tab`
  (Tab = trigger/accept/insert-\t — S33's contract). S32's `accept(item)` is the SHARED core
  S33 will call. The ftplugin's `on_tab` dispatch still returns false (fall-through → Tab
  indents) until S33 lands — CORRECT for S32's scope.
- **No menu WINDOW coupling:** S32 calls `menu.close()` (state) — NOT `nvim_win_close` (that
  is S34's job inside `menu`'s `render`). Until S34 lands, `menu.close()` is a state clear +
  no-op render; S32 is fully testable via state + buffer assertions (no floating window).