# P2.M2.T4.S4 — accept.lua buffer-mutation accept: research findings

> Scope: the BUFFER-MUTATION half of PRD §17.8 (Local acceptance & quoting). S3 shipped the
> two PURE functions (`current_shell_word` + `quote`); **S4 is the consumer** — it composes
> them with `nvim_buf_set_text` (a range edit on the current shell word) + cursor positioning +
> the directory re-trigger. This file captures the verified facts + the design decisions.

---

## 1. The task in one paragraph (what S4 ships)

A new impure function on `lua/pi-bridge/shell/accept.lua` — call it **`M.apply(buf, item)`** —
that is the shell-context ACCEPT path (the counterpart to `completion.M.accept`'s pi-bridge
`applyCompletion` path). On accept it:

1. reads line 1 + the nvim cursor from `buf` (byte-domain, §17.14);
2. strips the `!`/`!!` bangs (the SAME math `shell.complete_current` uses, L945–1010);
3. calls S3's **`M.current_shell_word(cmd, cmd_cursor)`** → `(word, start_byte)` (relative to
   the bang-stripped command);
4. calls S3's **`M.quote(item.value, shell)`** (shell read via a new `shell.get_shell()`);
5. **`nvim_buf_set_text(buf, 0, bangs+start_byte, 0, bangs+cmd_cursor, { quoted })`** — the
   word-range edit on row 0 (line 1);
6. **`nvim_win_set_cursor(0, { 1, bangs+start_byte+#quoted })`** — cursor right after the
   inserted text, still in Insert mode;
7. `menu.close()`;
8. **re-trigger**: iff `item.value` ends with `/` → `completion.refresh(buf)` (re-queries the
   daemon for the directory's contents; 0 ms shell debounce → near-immediate).

Plus the ROUTING glue so it is actually called: `completion.M.accept` (or `on_enter`/`on_tab`)
detects a `!`/`!!` line 1 and delegates to `accept.apply` BEFORE the pi-bridge branch.

---

## 2. VERIFIED nvim API semantics (the load-bearing facts — researcher brief, `:help`-cited)

All verified against `/usr/share/nvim/runtime/doc/api.txt` + `autocmd.txt` (Neovim ≥ 0.11;
identical to neovim.io). These are the facts S4 depends on:

### 2.1 `nvim_buf_set_text(buf, start_row, start_col, end_row, end_col, lines)`
- `start_col` / `end_col` are **0-indexed BYTE offsets, end-EXCLUSIVE** (verbatim
  *"Starting column (byte offset)"* / *"Ending column … exclusive"*).
- **`start_row == end_row` is explicitly valid** → a single-line word-range edit is the intended
  use (our case: row 0, `[start_byte, cursor_byte)`).
- **Does NOT move the cursor** (a separate `nvim_win_set_cursor` is required — step 6).
- **Does NOT synchronously fire `TextChangedI` / `TextChanged`** — it only increments
  `b:changedtick`. This is EXACTLY why the directory re-trigger MUST be an EXPLICIT
  `completion.refresh(buf)` (the autocmd will NOT fire from the API edit). This is the #1
  correctness reason the re-trigger exists as a separate step.

### 2.2 `nvim_win_set_cursor(win, {row, col})`
- `col` is a **0-based BYTE offset**; `row` is **1-based** (mark-like indexing, `:help api-indexing`).
  → the **row asymmetry**: `nvim_buf_set_text` row is 0-based, `nvim_win_set_cursor` row is
  1-based → pass `{ 1, col }` for line 1. **`#quoted` (a Lua byte length) is correct** for the
  byte-indexed cursor column.
- Works in **Insert mode** (`mode()` stays `"i"`) — no `<Esc>`/`<i>` dance. ✓
- **Synchronous** from in-process Lua (cursor is committed before the next Lua line). →
  **No re-trigger race**: `completion.refresh(buf)` after it reads committed state.
- Does NOT synchronously fire `CursorMovedI`. → no accidental refresh from the cursor move.

### 2.3 The accept sequence (verified idiomatic)
```lua
vim.api.nvim_buf_set_text(buf, 0, start_byte, 0, cursor_byte, { quoted })
vim.api.nvim_win_set_cursor(0, { 1, start_byte + #quoted })   -- row 1 (1-based); col 0-based byte
```
Mirrors blink.cmp's word-range accept (NOT nvim-cmp's feedkeys/`<C-g>U` confirm path, and NOT
`nvim_buf_set_lines` which is the pi-mode WHOLE-buffer rewrite). The codebase's own
`completion.M.accept` (L770) uses `nvim_buf_set_lines` because pi returns the ENTIRE new lines[];
shell returns a plain word → the range edit is correct.

### 2.4 Flagged traps
- **`start_byte`/`cursor_byte` must be UTF-8 byte offsets at char boundaries.** S3's
  `current_shell_word` is byte-domain by construction (continuation bytes ≥0x80 never match
  whitespace/quote/escape), so its `start_byte` IS a char-boundary byte offset. ✓ No
  `vim.str_byteindex` needed on the shell path (contrast §8's UTF-16 bridge path).
- `b:changedtick` IS bumped → a TextChangedI could fire on the NEXT keystroke. That is
  DESIRED (the next keystroke is legitimate typing → re-fetch). No guard needed.

---

## 3. The byte-offset MAPPING (the subtle part — `bangs`)

`current_shell_word` operates on the BANG-STRIPPED command. Its `start_byte` is relative to
`cmd = line1:sub(bangs+1)`. To map to BUFFER byte offsets (what `nvim_buf_set_text` needs),
add `bangs`:

| quantity | shell-domain (cmd) | buffer-domain (line 1) |
|---|---|---|
| word start | `start_byte` (from S3) | `bangs + start_byte` |
| cursor end | `cmd_cursor` (= `byte_col - bangs`) | `byte_col` (= `bangs + cmd_cursor`) |
| row | — | `0` (0-indexed for set_text) / `1` (1-indexed for set_cursor) |

`bangs` = 2 if `line1:sub(1,2)=="!!"`, else 1 if `line1:sub(1,1)=="!"` (check `!!` FIRST —
`complete_current` L987-990). `byte_col` = `nvim_win_get_cursor(0)[2]` (0-based byte).

Worked example — `!cd "my di` (cursor at end, byte_col=10):
- bangs=1; cmd=`cd "my di`; cmd_cursor=10-1=9
- `current_shell_word('cd "my di', 9)` → `('"my di', 3)` (the open `"` is part of the word;
  the space inside the double-quote is non-breaking)
- item.value = `my dir`; shell=bash → `quote("my dir","bash")` = `'my dir'` (8 bytes)
- `nvim_buf_set_text(buf, 0, 1+3, 0, 1+9, { "'my dir'" })` → replaces buffer bytes [4..10)
  (`"my di`) with `'my dir'` → `!cd 'my dir'`
- `nvim_win_set_cursor(0, { 1, 1+3+8 })` = `{1, 12}` → cursor right after `'my dir'`. ✓

Worked example (directory re-trigger) — `!cd /tm` (cursor end, byte_col=7), accept `/tmp/`:
- bangs=1; cmd=`cd /tm`; cmd_cursor=6
- `current_shell_word('cd /tm', 6)` → `('/tm', 3)`
- `quote("/tmp/","bash")` = `/tmp/` (no special char → unchanged)
- set_text(buf,0,1+3,0,1+6,{"/tmp/"}) → `!cd /tmp/`; set_cursor(0,{1,1+3+5=9})
- item.value ends with `/` → `completion.refresh(buf)` → do_refresh → ctx=="shell" →
  do_shell_fetch → complete_current → daemon → `/tmp/`'s contents → menu re-opens. ✓

---

## 4. Design decisions

### D1 — WHERE does `M.apply` live? → `lua/pi-bridge/shell/accept.lua` (S3's file)
The task title names accept.lua, and S3's header explicitly says "S4 is the FIRST consumer: its
buffer-mutation accept composes these two + `nvim_buf_set_text`". So S4 ADDS a third export to
accept.lua (`M.apply`). The two S3 pure functions stay pure; `M.apply` is the impure consumer.
This mirrors the codebase's own layering (`completion.lua` has pure `completion_context` +
impure `do_refresh`/`accept` in one module). The MODULE still loads under `-u NORC` —
`vim.api.*` is referenced INSIDE `M.apply`'s body, not at module load; the existing pure
plenary-free smoke still works (it only calls the pure fns).

### D2 — WHERE does the shell come from? → new `shell.get_shell()` accessor (3 lines)
`accept.apply` needs the resolved shell for `quote`. shell.lua already owns `state.shell`
(set on first `ensure()`/spawn; guaranteed set whenever a shell MENU exists, since the menu is
only populated via do_shell_fetch → complete_current → request → ensure). **S4 adds a tiny
public `M.get_shell()` returning `state.shell` (or nil)**. `accept.apply` reads it lazily
(`require("pi-bridge.shell").get_shell()`); `quote` already degrades nil → POSIX default, so a
nil (daemon never spawned) is harmless. (Alternative considered: pass `shell` as a param; rejected
— the routing caller `completion.M.accept` doesn't know the shell, so accept.apply reading it
itself keeps the caller simple. Alternative considered: re-run `resolve_shell`; rejected — it
re-reads descriptor each call + `state.shell` is already the cached resolution.)

### D3 — HOW is the shell-context ROUTED? → re-derive from line 1 in `completion.M.accept`
No `menu.get_context()` exists (verified — `state.context` is internal, set by `on_results`'s
4th arg for the VISUAL CUE only). Re-deriving from line 1 (`lines[1]:sub(1,1)=="!"`) is the
source of truth + avoids a new accessor + avoids menu-state staleness. The DRY routing point is
**inside `completion.M.accept`**: after it reads `lines` (which it already does, L790), add a
shell branch BEFORE the bridge check — `if lines[1] and lines[1]:sub(1,1)=="!" then return
require("pi-bridge.shell.accept").apply(buf, item) end`. This keeps `on_enter`/`on_tab`/
`_route_or_accept` UNCHANGED (they all funnel through `M.accept`). The pi-bridge path after the
branch is byte-identical to today (the only change is the lines-read moves ABOVE the bridge
check — safe; the pi path reuses the already-read `lines`).

  NOTE on `prefix_override`: `on_enter` calls `M.accept(item)` (no override); `_route_or_accept`
  calls `M.accept(item, prefix)` (single-item auto-apply). The shell branch runs in BOTH cases
  (a `!` line with a single shell item auto-applies via the local word-replace — correct, since
  shell items are plain words). `prefix_override` is IGNORED on the shell path (shell accept
  recomputes the word from the buffer, not a stored prefix) — documented.

### D4 — re-trigger mechanism → `completion.refresh(buf)` (public, 0 ms shell debounce)
`do_shell_fetch` is a LOCAL fn in completion.lua (not exported). `completion.refresh(buf)` IS
public + is the autocmd entry point; for shell context `compute_debounce` returns
`config.shell.debounce_ms` (default 0) → `vim.defer_fn(do_refresh, 0)` → near-immediate async
re-query. This re-opens the menu with the directory's contents. (Alternative considered: export
a `force_shell`; rejected — refresh's 0 ms is snappy enough + avoids new public API. Acceptable
async flicker matches real-shell dir expansion.)

### D5 — NEVER-THROWS + return contract → mirrors `completion.M.accept`
`M.apply` pcall's every nvim call; type-guards `buf`/`item`; validates `buf` is valid+current.
Returns `true` iff the edit was applied (the routing returns it verbatim so `<Tab>`/`<CR>` are
CONSUMED); `false` on bad args / wiped buf / non-current buf (fall through to indent/newline).
The lazy requires (`shell`/`menu`/`completion`) are inside the fn (handshake-async + test mocks
+ NORC-load-safe).

### D6 — menu.close() always; re-trigger re-opens iff results
`menu.close()` runs unconditionally after the edit (clear the candidate list + hide the popup).
The directory re-trigger then calls `refresh` which re-opens the menu iff the dir is non-empty
(empty → `on_results` → `menu.close()` again → stays closed). No special "keep menu open" path.

---

## 5. Test plan (where the cases land)

The S3 spec header EXPLICITLY says: *"The S4 buffer-mutation cases (nvim_buf_set_text range +
cursor) will be ADDED to this SAME file by P2.M2.T4.S4"*. So:

- **`tests/shell_accept_spec.lua`** (plenary) — ADD a new `describe("M.apply (§17.8 step 3-5 —
  buffer mutation)", ...)` block. Reuse the `buf_with(line, byte_col)` helper pattern from
  `tests/shell_complete_current_spec.lua` (L86-93: create buf + `vim.wo[virtualedit=onemore]` +
  set lines + cursor). Inject a fake shell via `pi.config.shell` / a stubbed `shell.get_shell`
  OR set `state.shell` directly. Cases:
    * plain word: `!git ch` accept "checkout" → buffer `!git checkout `, cursor after.
    * trailing-space empty word: `!git ` accept "git" → `!git `, cursor after.
    * directory re-trigger: `!cd /tm` accept "/tmp/" → `!cd /tmp/`, refresh called, menu reopens.
    * space-needing quote (bash): `!cd my` accept "my file.txt" → `!cd 'my file.txt'`.
    * fish double-quote: same → `"my file.txt"`.
    * embedded-quote idiom: accept "a'b" → `'a'"'"'b'`.
    * cursor mid-word: `!git ch` cursor@5 accept "checkout" → `!git checkout`, `after`... wait
      `!git ch` has no `after`; use `!git check` cursor@6 → replaces "ch" → `!git checkout`.
      (assert `after` text preserved.)
    * multibyte byte-correctness: `!日cmd` accept → byte offsets correct.
    * never-throws: nil buf, invalid buf, non-current buf, non-table item → false, no throw.
    * routing: `completion.M.accept(item)` on a `!` line → delegates to shell.apply (NOT the
      bridge); on a `/` line → pi path unchanged (regression).
    * no-leak / surface: `M.apply` is a function; no `uv_timer_t` leaked.

- **`tests/shell_accept_smoke.lua`** (plenary-free, `-u NORC`) — ADD a small buffer-mutation
  section at the end (headless nvim under NORC HAS `vim.api`; `menu_smoke.lua`/`coords_smoke`
  create buffers under NORC). ~3 representative cases (plain word + quote + directory) → still
  prints `SMOKE_PASS`. (If keeping the pure smoke pristine is preferred, create a separate
  `tests/shell_accept_apply_smoke.lua` — either is acceptable; extending the existing file is
  DRY-er.)

- **Regression**: `shell_spec.lua`, `shell_fish_spec.lua`, `completion_spec.lua`,
  `menu_spec.lua`, `completion_accept_spec.lua`/`_smoke.lua` stay green (the pi path is
  unchanged after the shell branch).

---

## 6. Sources

- `/usr/share/nvim/runtime/doc/api.txt` — `nvim_buf_set_text` (byte offsets, end-exclusive,
  cursor-unchanged, changedtick-only), `nvim_win_set_cursor` (0-based byte col, 1-based row,
  insert-safe, synchronous).
- `/usr/share/nvim/runtime/doc/autocmd.txt` — `TextChangedI` (fires on TYPED input, not API
  mutations).
- neovim.io canonical refs: https://neovim.io/doc/user/api.html (nvim_buf_set_text,
  nvim_win_set_cursor), https://neovim.io/doc/user/usr_41.html (api-indexing: 0-based vs
  mark-based).
- `lua/pi-bridge/shell/accept.lua` (S3 — the two pure fns to consume).
- `lua/pi-bridge/shell.lua` L945-1010 (`complete_current` — the bang-strip + byte-offset math
  to mirror; L283 `reset`, L329 `ensure` set `state.shell`).
- `lua/pi-bridge/completion.lua` L770-840 (`M.accept` / `on_enter` / `on_tab` — the routing
  point; L408 `do_shell_fetch`, L305 `compute_debounce` returns 0 for shell).
- `lua/pi-bridge/menu.lua` (no `get_context` — `state.context` is internal/visual-cue-only).
- `tests/shell_complete_current_spec.lua` L86-93 (`buf_with` helper — copy for the apply spec).
- PRD §17.8 (steps 3-5: replace/cursor/re-trigger), §17.14 (byte-domain), §17.15 (quoting table).