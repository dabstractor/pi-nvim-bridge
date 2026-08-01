---
name: "P2.M2.T4.S4 — shell/accept.lua BUFFER-MUTATION half: M.apply (nvim_buf_set_text range edit + cursor + directory re-trigger) + completion.M.accept shell routing"
why_this_prp: "The IMPURE consumer half of 17.8 (Local acceptance & quoting). S3 shipped the two PURE functions (current_shell_word + quote); S4 is the FIRST consumer — a new M.apply(buf, item) on accept.lua that composes them with nvim_buf_set_text (a WORD-RANGE edit on the current shell token, NOT the whole-buffer nvim_buf_set_lines the pi path uses), positions the cursor after the inserted text (still in Insert mode), closes the menu, and re-triggers a fetch iff the candidate is a directory (ends in /). Plus the routing glue so it is actually called: completion.M.accept detects a !/!! line 1 and delegates to accept.apply BEFORE the pi-bridge branch (so on_enter/on_tab/_route_or_accept all funnel through it unchanged). Every nvim API fact below is :help-VERIFIED (byte offsets end-exclusive; set_text does NOT move the cursor nor fire TextChangedI — which is WHY the directory re-trigger must be an explicit refresh; set_cursor is 0-based byte / 1-based row, insert-safe, synchronous). Additive: one new function + a 3-line shell.get_shell accessor + a ~6-line routing branch + extended tests. No daemon, no socket, no extension changes."
---

## Goal

**Feature Goal**: Ship the **buffer-mutation ACCEPT** path for shell-context completions
(PRD §17.8 steps 3-5) — the counterpart to `completion.M.accept`'s pi-bridge `applyCompletion`
path. Shell candidates are **plain words**, not pi `AutocompleteItem`s; pi's `applyCompletion`
(which computes pi-specific insertion: trailing space for files, `@`-mention quoting, `/cmd `
spacing, and returns the WHOLE new lines[]) **does not apply**. So the shell path uses its OWN
accept: a local **word-replacement** via `nvim_buf_set_text` (a range edit on the current shell
token) + cursor positioning + a directory re-trigger.

The deliverable is **`M.apply(buf, item)`** — a new function on `lua/pi-bridge/shell/accept.lua`
(the file S3 created) — that:
1. reads line 1 + the nvim cursor from `buf` (byte-domain, §17.14 — **no** coords/UTF-16);
2. strips the `!`/`!!` bangs (the SAME math `shell.complete_current` uses);
3. calls S3's **`M.current_shell_word(cmd, cmd_cursor)`** → `(word, start_byte)` (relative to the
   bang-stripped command);
4. calls S3's **`M.quote(item.value, shell)`** (the resolved shell read via a new
   `shell.get_shell()` accessor);
5. **`nvim_buf_set_text(buf, 0, bangs+start_byte, 0, bangs+cmd_cursor, { quoted })`** — the
   word-range edit on row 0;
6. **`nvim_win_set_cursor(0, { 1, bangs+start_byte+#quoted })`** — cursor right after the inserted
   text, still in Insert mode;
7. `menu.close()`;
8. **re-trigger**: iff `item.value` ends with `/` → `completion.refresh(buf)` (re-queries the
   daemon for the directory's contents; shell debounce is 0 ms → near-immediate).

Plus the **routing** so it is reachable: `completion.M.accept` (the single funnel for
`on_enter`/`on_tab`/`_route_or_accept`) gains a shell branch — after it reads `lines`, if
`lines[1]` starts with `!` it delegates to `accept.apply(buf, item)` BEFORE the pi-bridge
`applyCompletion` path.

**Deliverable**:
1. **`lua/pi-bridge/shell/accept.lua`** — ADD `M.apply(buf, item)` (the impure buffer-mutation
   consumer; ~50-70 lines). S3's two pure functions stay pure + unchanged.
2. **`lua/pi-bridge/shell.lua`** — ADD `M.get_shell()` (a 3-line public accessor returning
   `state.shell` or nil; `accept.apply` reads the resolved shell through it).
3. **`lua/pi-bridge/completion.lua`** — ADD the shell branch to `M.accept` (~6 lines; the pi
   path after it is byte-identical to today). `on_enter`/`on_tab`/`_route_or_accept` UNCHANGED.
4. **`tests/shell_accept_spec.lua`** — ADD a `describe("M.apply (§17.8 step 3-5 — buffer
   mutation)")` block (plenary; reuses the `buf_with(line, byte_col)` helper pattern from
   `tests/shell_complete_current_spec.lua`).
5. **`tests/shell_accept_smoke.lua`** — ADD a small buffer-mutation section (headless nvim under
   `-u NORC` has `vim.api`; ~3 representative cases).

**Success Definition**:
- `require("pi-bridge.shell.accept").apply` and `require("pi-bridge.shell").get_shell` are
  functions; `require("pi-bridge.shell.accept")` still loads under `nvim --headless --clean -u
  NORC -c 'set rtp+=.'` (the pure smoke still runs — `vim.api.*` is referenced INSIDE `M.apply`,
  not at module load).
- **`!git ch`** (cursor end) accept `checkout` → buffer becomes **`!git checkout `** with the
  cursor positioned right after `checkout`; menu closed.
- **`!cd my`** accept `my file.txt` (bash) → **`!cd 'my file.txt'`** (single-quoted; the bash
  idiom applied). Same with fish → **`!cd "my file.txt"`** (double-quoted).
- **`!cd /tm`** accept `/tmp/` → **`!cd /tmp/`** + `completion.refresh(buf)` called + the menu
  re-opens with `/tmp/`'s contents (the directory re-trigger).
- **byte-correct**: `!日cmd` accept `日result` → the byte offsets are correct (the multibyte
  word is replaced whole; cursor lands on a char boundary).
- **cursor mid-word**: `!git check` cursor@6 (on the `c` of `check`) accept `checkout` → replaces
  only `ch` (the word up to cursor) → `!git checkout|eck` (the `after` text `eck` is preserved;
  cursor between `checkout` and `eck`).
- **routing**: `completion.M.accept(item)` on a `!` line delegates to `accept.apply` and does
  NOT issue a bridge `applyCompletion`; on a `/` line the pi path is byte-identical (regression).
- **never-throws**: `apply(nil, item)` / `apply(buf, nil)` / invalid buf / non-current buf →
  returns `false`, no throw (the routing returns it → `<Tab>`/`<CR>` fall through).
- `tests/shell_accept_spec.lua` passes (plenary); `tests/shell_accept_smoke.lua` prints
  `SMOKE_PASS` + exit 0; the pre-existing shell/completion/menu/accept tests stay green.

## User Persona (if applicable)

**Target User**: the `pi-bridge.nvim` maintainer / CI runner (the direct consumer is the
`completion.M.accept` routing). Indirect user: a pi user whose resolved shell is fish/zsh/bash
who types `!cd "my di<Tab>` (or `!git ch<Tab>`, or `!cd /tm<Tab>`) in the pi-prompt buffer and
accepts a completion.

**Use Case**: the user types `!cd "my di` in the pi-prompt buffer → the shell menu offers
`my dir`. On `<Tab>`/`<CR>`, `completion.M.accept` sees line 1 starts with `!` → delegates to
`accept.apply(buf, item)`, which calls `current_shell_word('cd "my di', 8)` → `('"my di', 3)`,
then `quote("my dir", "/bin/bash")` → `'my dir'`, then replaces the buffer word range with
`'my dir'` via `nvim_buf_set_text` and positions the cursor after it. The bangs, the rest of the
line, and the `after`-cursor text are all preserved.

**User Journey**: (1) user enters a `!`/`!!` line in the external Neovim editor → (2) the shell
menu populates (S3-T3, COMPLETE) → (3) user navigates + accepts → **S4 splices the quoted word
into the buffer + re-queries for directories** → (4) user `:wq` → pi re-reads the temp file →
pi executes the (correctly-quoted) bash command.

**Pain Points Addressed**: today (pre-S4) accepting a shell-completion menu item falls through
to the pi-bridge `applyCompletion` path — which is WRONG for shell words (pi returns pi-specific
insertion semantics that do not match the `!` command, and may issue a meaningless RPC). S4
makes shell accept actually work: local word-replacement with correct per-shell quoting, cursor
positioning, and directory expansion.

## Why

- **PRD §17.8 explicitly mandates** a shell-local accept (`shell/accept.lua`) that does
  word-replacement via `nvim_buf_set_text` (step 3), cursor positioning (step 4), and the
  directory re-trigger (step 5) — precisely because "shell candidates are plain words, not pi
  AutocompleteItems — pi's `applyCompletion` … does not apply." S4 ships exactly that.
- **Closes the shell-completion vertical slice**: P2.M2.T3 (routing the FETCH) + T4.S1-S3 (fish
  driver + pure accept helpers) are COMPLETE but produce a menu that **cannot be accepted**.
  S4 is the last piece — without it the shell subsystem is a read-only novelty.
- **Additive + low-risk**: one new function, one 3-line accessor, one ~6-line routing branch
  (the pi path after the branch is unchanged). No daemon, no socket, no extension, no new state.
  The routing's safety rests on re-deriving context from line 1 (the source of truth), not on
  menu state (which is visual-cue-only).

## What

### The new function — `M.apply(buf, item)` on `lua/pi-bridge/shell/accept.lua`

A buffer-mutation orchestrator (impure — uses `vim.api.*` + lazy `require`s of `shell`/`menu`/
`completion`, all INSIDE the function so the module still loads under `-u NORC`). Signature:
`M.apply(buf, item) → boolean` (true iff the edit was applied; false on any guard/never-throws
failure). It:

1. **validates** `buf` (number + `nvim_buf_is_valid` + is the current buf) and `item` (table
   with a string `.value`); returns `false` on any miss (never throws).
2. **reads** line 1 (`nvim_buf_get_lines(buf, 0, 1, false)`) + cursor (`nvim_win_get_cursor(0)`
   → `{row, byte_col}`, `byte_col` is 0-based byte).
3. **strips bangs**: `bangs = 2 if line1:sub(1,2)=="!!" else 1` (check `!!` FIRST — it also
   starts with `!`); `cmd = line1:sub(bangs+1)`; `cmd_cursor = math.max(0, byte_col - bangs)`.
4. **computes the word range** via S3: `word, start_byte = M.current_shell_word(cmd, cmd_cursor)`.
5. **quotes** via S3: `quoted = M.quote(item.value, require("pi-bridge.shell").get_shell())`
   (nil shell → POSIX default; harmless).
6. **range-edit** (VERIFIED §2.3): `nvim_buf_set_text(buf, 0, bangs+start_byte, 0,
   bangs+cmd_cursor, { quoted })` — replaces buffer bytes `[bangs+start_byte, bangs+cmd_cursor)`
   on row 0 with `quoted`. Does NOT move the cursor (step 7 does); does NOT fire TextChangedI
   (so the directory re-trigger must be explicit, step 8).
7. **position cursor** (VERIFIED §2.2): `nvim_win_set_cursor(0, { 1, bangs+start_byte+#quoted })`
   — row 1 (1-based), col = 0-based byte offset right after the inserted text. Insert-safe
   (`mode()` stays `"i"`); synchronous (no re-trigger race).
8. **close menu**: `pcall(require("pi-bridge.menu").close)`.
9. **directory re-trigger**: `if item.value:sub(-1) == "/" then
   pcall(require("pi-bridge.completion").refresh, buf) end` — refresh re-derives ctx=="shell" →
   `do_shell_fetch` → re-queries the daemon → re-opens the menu iff the dir is non-empty.
10. **return `true`** (the routing returns it → `<Tab>`/`<CR>` consumed).

Every nvim call is `pcall`'d; on any failure return `false` (never throw — per-keystroke +
accept contract). The lazy `require`s keep the module NORC-load-safe + test-mock-friendly.

### The accessor — `M.get_shell()` on `lua/pi-bridge/shell.lua`

```lua
--- The resolved execution shell for the session (for accept.apply's quoting). Returns the
--- cached `state.shell` (set on first ensure()/spawn; guaranteed set whenever a shell MENU
--- exists, since the menu is populated only via do_shell_fetch→complete_current→request→ensure)
--- or nil (daemon never spawned — quote degrades to the POSIX default, harmless). NEVER throws.
---@return string|nil
function M.get_shell()
  return state.shell
end
```

### The routing — shell branch in `completion.M.accept`

After `M.accept` reads `lines` (which it already does today at L790, `nvim_buf_get_lines(buf,
0, -1, false)`), insert BEFORE the bridge-availability check:

```lua
-- SHELL ROUTE (§17.8): a `!`/`!!` line accepts via the LOCAL word-replacement path, NOT the
-- pi bridge (pi's applyCompletion does not apply to shell words). Re-derive from line 1 (the
-- source of truth; NOT menu.state.context, which is the visual-cue's source only).
if type(lines[1]) == "string" and lines[1]:sub(1, 1) == "!" then
  return require("pi-bridge.shell.accept").apply(buf, item) == true
end
-- …existing pi-bridge applyCompletion path, byte-identical to today…
```

The ONLY structural change to the pi path: the `lines` read moves ABOVE the bridge check (it is
currently below). The pi path reuses the already-read `lines`. `on_enter`/`on_tab`/
`_route_or_accept` are UNCHANGED (they funnel through `M.accept`). `prefix_override` is IGNORED
on the shell path (shell accept recomputes the word from the buffer).

### Success Criteria

- [ ] `require("pi-bridge.shell.accept").apply` is a function; `require("pi-bridge.shell").get_shell`
      is a function; `require("pi-bridge.shell.accept")` loads under `-u NORC -c 'set rtp+=.'`.
- [ ] `apply(buf, item)` on `!git ch` (cursor end) with item.value `"checkout"` → buffer line 1
      becomes `!git checkout ` (note: the candidate is spliced verbatim; a trailing space is NOT
      added by the shell path — shells do not add one) + cursor right after `checkout` + menu
      closed + `refresh` NOT called (does not end in `/`).
- [ ] `apply` on `!cd my` with item.value `"my file.txt"` (shell=bash) → `!cd 'my file.txt'`
      + cursor after the closing `'`; (shell=fish) → `!cd "my file.txt"`.
- [ ] `apply` on `!cd /tm` with item.value `"/tmp/"` → `!cd /tmp/` + `completion.refresh(buf)`
      called (ends in `/`).
- [ ] byte-correct: `apply` on `!日cmd` (日 = 3 UTF-8 bytes) with a value → the start_byte +
      cursor land on char boundaries (no split multibyte). Proven by `current_shell_word`'s
      byte-domain scan (continuation bytes ≥0x80 never match whitespace/quote/escape).
- [ ] cursor-mid-word: `apply` on `!git check` cursor on byte 6 (`c`) with value `"checkout"` →
      replaces bytes `[5,7)` (`ch`) only → `!git checkout` + the `after` text (`eck`) preserved.
- [ ] never-throws + returns false: `apply(nil,item)`, `apply(buf,nil)`, `apply(<invalid>,item)`,
      `apply(<non-current-buf>,item)` → `false`, no throw.
- [ ] routing: `completion.M.accept(item)` with a `!` line → `accept.apply` called, NO bridge
      `applyCompletion` issued; with a `/` line → the pi path runs unchanged (regression).
- [ ] `tests/shell_accept_spec.lua` passes (plenary); `tests/shell_accept_smoke.lua` prints
      `SMOKE_PASS` + exit 0; `shell_spec.lua`/`shell_fish_spec.lua`/`completion_spec.lua`/
      `completion_accept_spec.lua`/`menu_spec.lua` stay green.

## All Needed Context

### Context Completeness Check

_Pass_: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?" — **Yes.** The PRD excerpts (§17.8 steps 3-5, §17.14 byte-domain),
the `:help`-VERIFIED nvim API facts (§2 of the research), the exact byte-offset mapping + worked
examples, the S3 pure-function contract (already shipped, with the full algorithm + quoting
table in `P2M2T4S3/PRP.md`), the verified test-harness structure (`shell_complete_current_spec`
`buf_with` helper), and the verified validation commands are all below. The implementer adds ONE
function + ONE accessor + ONE routing branch + extended tests, and touches nothing else.

### Documentation & References

```yaml
# MUST READ — the spec that defines the exact steps
- url: PRD.md §17.8 "Local acceptance & quoting (NOT pi's applyCompletion)"
  why: |
    defines steps 3-5 S4 owns. Step 3: "Replace bytes [word_start+1 .. cursor] (Lua 1-indexed)
    with the quoted candidate, via nvim_buf_set_text (range edit, not whole-buffer rewrite —
    shell mode edits only the current word, unlike pi-mode's wholesale nvim_buf_set_lines)."
    Step 4: "Position the cursor immediately after the inserted text. Stay in Insert mode."
    Step 5: "Re-trigger a completion fetch only if the candidate is a directory (candidate ends
    in /) — mirrors shells' behavior of expanding a dir and continuing; otherwise close the menu."
  critical: |
    the explicit "why nvim_buf_set_text, not nvim_buf_set_lines" note: pi-mode accepts rewrite
    the WHOLE buffer (pi returns the complete new lines[]); shell-mode accepts rewrite a WORD
    RANGE. nvim_buf_set_text(buf,row,start_col,row,end_col,{text}) is the precise API. like
    set_lines, it does NOT fire TextChangedI — so no re-entrancy loop, BUT the directory
    re-trigger MUST be an explicit refresh (the autocmd will not fire from the API edit).

- url: PRD.md §17.14 "Coordinate & encoding notes (shell path)"
  why: |
    "Unlike pi-mode (§8), the shell path does NOT use pi's UTF-16 cursor contract … Accept uses
    nvim_buf_set_text with BYTE column offsets (Lua 0-based via the API), again no UTF-16
    conversion … nvim_buf_set_text … is byte-indexed."
  critical: |
    start_byte (from S3 current_shell_word) + cmd_cursor are BYTE offsets. nvim_buf_set_text
    cols are 0-based BYTE offsets, end-exclusive. nvim_win_set_cursor col is 0-based BYTE, row
    1-based. NEVER call coords.byte_to_utf16 / vim.str_utfindex / coords.nvim_to_pi_coords (the
    §8 UTF-16 bridge path). The byte math is UTF-8-safe because whitespace/quote/escape are all
    ASCII (<0x80); S3's scan never splits a multibyte char.

- url: PRD.md §17.15 "Testing strategy (shell-specific)"
  why: |
    "shell_accept_spec.lua — table tests for quoting: … assert the inserted byte range and
    cursor position." + "shell_accept_spec.lua — … assert the inserted byte range and cursor."
  critical: |
    the buffer-mutation cases (assert the inserted byte range + cursor position) are S4's — they
    are ADDED to the SAME tests/shell_accept_spec.lua file S3 created (the S3 spec header says
    so verbatim). Reuse the buf_with(line, byte_col) helper from shell_complete_current_spec.lua.

- url: https://neovim.io/doc/user/api.html  (nvim_buf_set_text, nvim_win_set_cursor)
  why: |
    the VERIFIED API contract. nvim_buf_set_text: "Starting column (byte offset)" / "Ending
    column … exclusive"; start_row==end_row valid; does NOT move cursor; does NOT synchronously
    fire TextChangedI (only bumps b:changedtick). nvim_win_set_cursor: col is 0-based byte, row
    is 1-based (api-indexing); works in Insert mode (mode() stays "i"); synchronous from Lua;
    does NOT fire CursorMovedI.
  critical: |
    the two load-bearing facts: (1) set_text does NOT fire TextChangedI → the directory
    re-trigger MUST be an explicit completion.refresh(buf) (else accepting a dir silently does
    nothing more). (2) the row ASYMMETRY: set_text row is 0-based, set_cursor row is 1-based →
    pass {1, col} for line 1. #quoted (Lua byte length) is correct for the byte-indexed cursor
    col. (Verified against /usr/share/nvim/runtime/doc/api.txt + autocmd.txt, Neovim ≥0.11.)

# Codebase files to follow EXACTLY
- file: plan/002_d23d7473c16c/P2M2T4S4/research/accept_apply_findings.md
  why: "S4's OWN research. §2 = the :help-VERIFIED nvim API semantics (the load-bearing facts).
        §3 = the byte-offset MAPPING (bangs + start_byte) + 2 worked examples (the quote-aware
        word + the directory re-trigger). §4 = the 6 design decisions (where apply lives, where
        the shell comes from, how routing works, the re-trigger mechanism, never-throws, menu
        close). §5 = the test plan (which cases land where)."
  pattern: "the byte-mapping + worked examples are the reference implementation — match them."
  gotcha: "§3: start_byte from current_shell_word is RELATIVE TO THE BANG-STRIPPED COMMAND — add
        `bangs` to get the buffer byte offset. Forgetting `bangs` shifts the edit/cursor by 1-2
        bytes (the #1 off-by-N trap)."

- file: lua/pi-bridge/shell/accept.lua   (S3 — the two PURE fns to consume; NOT rewritten)
  why: |
    the file S4 EXTENDS. S3 exports `M.current_shell_word(line, cursor) → (word, start_byte)`
    + `M.quote(word, shell) → quoted`. S4 ADDS `M.apply(buf, item)` as a third export. The two
    pure fns STAY pure + unchanged (their exhaustive table tests stay green).
  pattern: |
    S3's header [Mode A] notes the contract: PURE + dependency-free (no vim.*, no require) for
    the TWO pure fns. S4's M.apply is the IMPURE consumer — it MAY use vim.* + lazy require, but
    ONLY INSIDE the function body (NOT at module load), so the module still loads under -u NORC
    and the existing pure plenary-free smoke still runs. Mirror how completion.lua keeps pure
    `completion_context`/`is_attachment_context` alongside impure `do_refresh`/`accept`.
  gotcha: "do NOT add `local foo = require(...)` at module top in accept.lua (breaks -u NORC
        loading + the pure smoke). All requires INSIDE M.apply. `vim.api.*` is fine to reference
        inside the fn (it exists under NORC headless; just not called by the pure smoke)."

- file: lua/pi-bridge/shell.lua   (ADD M.get_shell; mirror complete_current's bang math)
  why: |
    the sibling module. L945-1010 `M.complete_current(buf, cb)` is the EXACT template for the
    buffer-read + bang-strip + byte-offset math M.apply mirrors (steps 1-3 of M.apply ARE
    complete_current's steps 1-5). L~283 `M.reset()` shows `state.shell` is a field. L329
    `M.ensure()` sets `state.shell` on spawn.
  pattern: |
    L987-990 bang strip (copy verbatim into M.apply):
      `local bangs = 0`
      `if line1:sub(1,2)=="!!" then bangs=2 elseif line1:sub(1,1)=="!" then bangs=1 end`
    L994-998 byte triple (the cmd/cmd_cursor M.apply needs):
      `local cmd = line1:sub(bangs+1)`
      `local cmd_cursor = math.max(0, byte_col - bangs)`
    Add `M.get_shell()` returning `state.shell` (3 lines) near the other public accessors.
  gotcha: "`state` is module-local in shell.lua — M.get_shell is the PUBLIC read seam. Do NOT
        expose the whole state table (M._state-style) just for the shell; a 1-field accessor is
        the minimal surface. `state.shell` is guaranteed set at accept time (the menu only
        populates after ensure() sets it)."

- file: lua/pi-bridge/completion.lua   (ADD the shell branch to M.accept; READ-ONLY elsewhere)
  why: |
    the routing point. L~770 `M.accept(item, prefix_override)` is the single funnel for
    on_enter/on_tab/_route_or_accept. It ALREADY reads `lines` (L~790 nvim_buf_get_lines). S4
    inserts the shell branch AFTER the lines read, BEFORE the bridge check. The pi path after
    the branch is byte-identical (the lines read just moved up).
  pattern: |
    the branch (3 lines + the delegate):
      `if type(lines[1]) == "string" and lines[1]:sub(1, 1) == "!" then`
      `  return require("pi-bridge.shell.accept").apply(buf, item) == true`
      `end`
    Re-derive context from line 1 (the source of truth) — NOT menu.state.context (which is the
    visual-cue's source only + may be stale). on_enter/on_tab/_route_or_accept are UNCHANGED.
  gotcha: "the lines read currently sits AFTER the `if not bridge ... return false` guard
        (L~780). Moving it ABOVE the bridge guard is REQUIRED (a `!` line must route to the
        shell path even when the bridge is disconnected — shell completion is bridge-independent,
        §17.3/§17.13). The pi path reuses the already-read `lines`; no double-read. pcall the
        get_lines (a wiped buf mid-call → return false, never throw)."

- file: lua/pi-bridge/menu.lua   (M.close — the only menu call M.apply makes)
  why: "M.apply calls `require('pi-bridge.menu').close()` after the edit (clears the candidate
        list + hides the popup; the directory re-trigger's refresh re-opens it iff non-empty).
        `close()` is idempotent + never throws (pcall it anyway). No `get_context` exists (S4
        does NOT add one — routing re-derives from line 1)."
  pattern: "menu.close() sets items={}, selected=0, open=false, context=nil, + render (hide)."
  gotcha: "do NOT add menu.get_context() — state.context is the visual-cue source (set by
        on_results' 4th arg). Accept re-derives from line 1 for correctness + to avoid staleness."

- file: tests/shell_complete_current_spec.lua   (the buf_with helper + plenary structure — COPY)
  why: |
    the CLOSEST analog to M.apply's tests (complete_current ALSO reads a buffer + strips bangs +
    computes byte offsets). L86-93 `buf_with(line_text, byte_col)` is the helper to copy: create
    a scratch buf + `vim.wo[win].virtualedit = "onemore"` (REQUIRED to place the cursor at EOL
    else nvim clamps col to #line-1) + set lines + cursor. The `before_each`/`after_each`
    save/restore of globals + `shell.reset()` is the pattern.
  pattern: |
    local function buf_with(line_text, byte_col)
      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
      vim.wo[win].virtualedit = "onemore"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line_text })
      vim.api.nvim_win_set_cursor(win, { 1, byte_col })
      return buf, win
    end
  gotcha: "virtualedit=onemore is REQUIRED for the cursor-at-EOL cases (else the cursor col is
        clamped to #line-1, shifting every byte-math assertion by 1). Do NOT name a spec-local
        table `pending` (shadows plenary.busted's skip fn — the S3 spec header warns of this)."

- file: tests/completion_accept_smoke.lua   (the fake-server smoke structure — reference only)
  why: |
    M.apply is the shell analog of completion's pi-accept. completion_accept_smoke spins a fake
    luv server + drives the REAL bridge+completion+menu through an accept round-trip. S4's shell
    accept does NOT need the bridge (the daemon is separate) — but the smoke STRUCTURE (header
    comment + run command + `fails=0`/`check(cond,msg)` + final `cquit 1`/`SMOKE_PASS`) is the
    template. S4's smoke sets up a real buffer + calls M.apply directly (no daemon needed — the
    pure quote/word fns + nvim_buf_set_text are the whole path).
  pattern: "extend tests/shell_accept_smoke.lua with a buffer-mutation section (it runs under
        -u NORC which HAS vim.api — the coords_smoke/menu_smoke create buffers under NORC)."
  gotcha: "the existing shell_accept_smoke is the PURE smoke (current_shell_word + quote). S4's
        cases need a buffer — ADD them as a new section in the same file (the header already
        says S4 adds buffer-mutation cases to the same files), OR a separate
        tests/shell_accept_apply_smoke.lua. Either is acceptable; extending is DRY-er."
```

### Current Codebase tree (relevant slice)

```bash
pi-nvim-bridge/
├── lua/pi-bridge/
│   ├── shell/accept.lua          # S3: current_shell_word + quote (PURE). S4 ADDS M.apply (impure consumer)
│   ├── shell.lua                 # complete_current (bang-math template), state.shell. S4 ADDS M.get_shell
│   ├── completion.lua            # M.accept (routing point — S4 adds the shell branch). on_enter/on_tab UNCHANGED
│   ├── menu.lua                  # M.close (the only menu call M.apply makes). NO get_context (do not add)
│   ├── shell/fish.lua            # the driver (unchanged)
│   ├── coords.lua bridge.lua init.lua notify.lua health.lua …
├── tests/
│   ├── shell_accept_spec.lua     # S3 pure table tests. S4 ADDS a describe("M.apply …") block
│   ├── shell_accept_smoke.lua    # S3 pure smoke. S4 ADDS a buffer-mutation section
│   ├── shell_complete_current_spec.lua  # buf_with(line,byte_col) helper — COPY into the apply spec
│   ├── shell_fish_spec.lua completion_spec.lua menu_spec.lua completion_accept_spec.lua …
│   └── minimal_init.lua          # plenary harness bootstrap (read-only)
└── PRD.md  (§17.8 steps 3-5, §17.14 byte-domain, §17.15 — read-only reference)
```

### Desired Codebase tree with files to be added/modified

```bash
lua/pi-bridge/shell/accept.lua    # MODIFY: ADD M.apply(buf, item) (impure buffer-mutation consumer; ~50-70 lines). Pure fns unchanged.
lua/pi-bridge/shell.lua           # MODIFY: ADD M.get_shell() (3-line public accessor → state.shell | nil)
lua/pi-bridge/completion.lua      # MODIFY: ADD shell branch to M.accept (~6 lines; pi path unchanged after it)
tests/shell_accept_spec.lua       # MODIFY: ADD describe("M.apply (§17.8 step 3-5 — buffer mutation)") block (plenary; buf_with helper)
tests/shell_accept_smoke.lua      # MODIFY: ADD a buffer-mutation section (~3 cases) — runs under -u NORC (vim.api available)
# (no new files required; S4 EXTENDS the S3 files the spec header already earmarked for it)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (research §3 — the #1 off-by-N trap): start_byte from current_shell_word is
--   RELATIVE TO THE BANG-STRIPPED COMMAND. The BUFFER byte offset = bangs + start_byte. Same
--   for the cursor end: bangs + cmd_cursor. Forgetting `bangs` shifts the edit + cursor by 1-2.
-- → nvim_buf_set_text(buf, 0, bangs+start_byte, 0, bangs+cmd_cursor, { quoted })
--   nvim_win_set_cursor(0, { 1, bangs + start_byte + #quoted })

-- CRITICAL (VERIFIED §2.1): nvim_buf_set_text does NOT fire TextChangedI (only bumps
--   b:changedtick). So the directory re-trigger MUST be an EXPLICIT completion.refresh(buf) —
--   the TextChangedI autocmd will NOT fire from the API edit. This is WHY step 8 exists.

-- CRITICAL (VERIFIED §2.2): the row ASYMMETRY. nvim_buf_set_text row is 0-BASED; nvim_win_set_cursor
--   row is 1-BASED. For line 1: set_text row=0, set_cursor row={1, col}. #quoted (Lua byte length)
--   is correct for the 0-based byte cursor col. Both calls are synchronous + Insert-safe (mode()
--   stays "i"); no feedkeys/<C-g>U dance (that is nvim-cmp's path; blink.cmp + this codebase use
--   the two-API-call sequence — research/completion-debounce notes).

-- CRITICAL (§17.14): BYTE-domain, NOT UTF-16. NEVER call coords.byte_to_utf16 / vim.str_utfindex
--   / coords.nvim_to_pi_coords (those are §8's bridge path). current_shell_word is byte-domain by
--   construction (continuation bytes ≥0x80 never match whitespace/quote/escape) → its start_byte
--   IS a char-boundary byte offset. nvim_buf_set_text cols are byte-indexed + end-EXCLUSIVE.

-- CRITICAL (§17.8 step 3 + the S3 PRP): shell accept uses nvim_buf_set_text (a WORD-RANGE edit),
--   NOT nvim_buf_set_lines (the pi path's WHOLE-buffer rewrite). pi's applyCompletion returns the
--   complete new lines[]; shell returns a plain word → splice ONLY the [start_byte, cursor] range.

-- GOTCHA: the routing must re-derive context from line 1 (`lines[1]:sub(1,1)=="!"`), NOT from
--   menu.state.context. menu.state.context is the VISUAL-CUE's source (set by on_results' 4th arg)
--   + may be stale at accept time. Re-deriving from the buffer is the source of truth + needs NO
--   new menu accessor. (Verified: no menu.get_context() exists; do NOT add one.)

-- GOTCHA: M.apply's lazy requires (shell/menu/completion) MUST be INSIDE the function, NOT at
--   module top. accept.lua's module-load must stay NORC-safe (the pure plenary-free smoke runs
--   under -u NORC). vim.api.* referenced INSIDE the fn is fine (exists under NORC headless).

-- GOTCHA: shell.get_shell() returns state.shell, which is guaranteed set at accept time ONLY
--   because the menu populates via do_shell_fetch→complete_current→request→ensure (which sets
--   state.shell on spawn). If nil (daemon never spawned), M.quote(nil-shell) degrades to the
--   POSIX single-quote default — harmless. Do NOT call resolve_shell per-accept (state.shell is
--   the cached resolution).

-- GOTCHA: bang strip — check "!!" FIRST (it also starts with "!"). complete_current L987-990:
--   `if line1:sub(1,2)=="!!" then bangs=2 elseif line1:sub(1,1)=="!" then bangs=1 end`. The wrong
--   order strips only 1 for a "!!" line, shifting every offset by 1.

-- GOTCHA: virtualedit=onemore is REQUIRED in the apply spec's buf_with helper to place the cursor
--   at EOL (else nvim clamps col to #line-1, shifting every byte-math assertion by 1). Copy the
--   exact helper from shell_complete_current_spec.lua L86-93.

-- GOTCHA: prefix_override is IGNORED on the shell path. on_enter calls M.accept(item) (no
--   override); _route_or_accept calls M.accept(item, prefix) (single-item auto-apply). A `!` line
--   with a single shell item auto-applies via the LOCAL word-replace (correct — shell items are
--   plain words). The shell branch runs in BOTH cases before the pi path.

-- GOTCHA: NEVER throws (per-keystroke + accept contract). pcall EVERY nvim call (get_lines,
--   get_cursor, set_text, set_cursor, menu.close, completion.refresh); type-guard buf/item;
--   validate buf is valid+current. Return false (not throw) on any failure.

-- CRITICAL (AGENTS.md ⛔ HARD RULE): NEVER pipe a heredoc / stdin into nvim (it HANGS the session).
--   Write ad-hoc check snippets to a .lua FILE, then +"luafile <file>" +qa. One-liners via
--   `-c 'lua ...'` are fine. ALWAYS wrap nvim invocations in `timeout`.
```

## Implementation Blueprint

### Data models and structure

No persistent data models. `M.apply` consumes/produces simple Lua values + buffer state:

```lua
-- M.apply(buf, item) — the buffer-mutation orchestrator
--   buf  : integer  (the pi-prompt buffer handle; must be valid + current)
--   item : table    (the selected AutocompleteItem; MUST have a string .value)
-- returns:
--   applied : boolean (true iff the edit was applied; false on any guard/never-throws failure)
--
-- composes S3's two pure fns + nvim_buf_set_text (range edit) + nvim_win_set_cursor + re-trigger:
local ok = require("pi-bridge.shell.accept").apply(buf, { value = "checkout" })
-- → on "!git ch" (cursor end): buffer → "!git checkout "; cursor after "checkout"; menu closed

-- M.get_shell() — the resolved-shell accessor (shell.lua)
--   returns: string|nil  (state.shell — set on first ensure/spawn; nil if daemon never spawned)
local shell = require("pi-bridge.shell").get_shell()   -- "/bin/zsh" | nil
```

The byte-offset mapping (the reference — match exactly):

```lua
-- INPUT (from the buffer):  line1, byte_col (0-based byte, nvim_win_get_cursor[2])
-- STEP 1 — bang strip (complete_current L987-990):
local bangs = 0
if line1:sub(1, 2) == "!!" then bangs = 2
elseif line1:sub(1, 1) == "!" then bangs = 1 end
local cmd        = line1:sub(bangs + 1)        -- command after bangs
local cmd_cursor = math.max(0, byte_col - bangs) -- cursor offset into cmd (0-based byte)
-- STEP 2 — S3 word range (relative to cmd):
local word, start_byte = M.current_shell_word(cmd, cmd_cursor)   -- start_byte: 0-based byte into cmd
-- STEP 3 — S3 quote:
local quoted = M.quote(item.value, require("pi-bridge.shell").get_shell())
-- STEP 4 — buffer-domain offsets (ADD BANGS):
local buf_start = bangs + start_byte            -- 0-based byte into line1
local buf_end   = bangs + cmd_cursor            -- 0-based byte into line1 (end-exclusive)
-- STEP 5 — range edit (row 0; set_text does NOT move cursor nor fire TextChangedI):
vim.api.nvim_buf_set_text(buf, 0, buf_start, 0, buf_end, { quoted })
-- STEP 6 — cursor after inserted text (row 1 = 1-based; col 0-based byte):
vim.api.nvim_win_set_cursor(0, { 1, buf_start + #quoted })
-- STEP 7 — close menu; STEP 8 — re-trigger iff directory:
require("pi-bridge.menu").close()
if item.value:sub(-1) == "/" then require("pi-bridge.completion").refresh(buf) end
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD M.get_shell() to lua/pi-bridge/shell.lua
  - IMPLEMENT: a 3-line public accessor returning `state.shell` (or nil). NEVER throws (plain read).
  - PLACEMENT: near the other public accessors (after M.session_cwd / before M.reset, ~L283).
  - DOC-COMMENT: a `---` luadoc block stating it returns the cached resolved execution shell
    (set on first ensure/spawn; nil if daemon never spawned — quote degrades to POSIX default).
  - NAMING: `M.get_shell` (mirrors M.get_buf / M.get_prefix naming on menu.lua).
  - DEPENDENCIES: none (reads module-local `state.shell`, already a field).

Task 2: ADD M.apply(buf, item) to lua/pi-bridge/shell/accept.lua
  - IMPLEMENT: the buffer-mutation orchestrator (the blueprint above). Signature
    `M.apply(buf, item) → boolean`. Steps: validate buf/item → read line1+cursor → bang strip →
    M.current_shell_word → M.quote(get_shell) → nvim_buf_set_text (range) → nvim_win_set_cursor →
    menu.close → directory re-trigger (refresh) → return true.
  - VALIDATE (never-throws, return false on miss):
      * `if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end`
      * `if buf ~= vim.api.nvim_get_current_buf() then return false end`  (one buf/session)
      * `if type(item) ~= "table" or type(item.value) ~= "string" then return false end`
  - PCALL EVERY nvim call (get_lines, get_cursor, set_text, set_cursor, menu.close, refresh);
    on any pcall failure return false (never throw).
  - LAZY REQUIRES (INSIDE the fn, NOT module top): `require("pi-bridge.shell").get_shell()`,
    `require("pi-bridge.menu").close`, `require("pi-bridge.completion").refresh`. (Keeps the
    module NORC-load-safe + the pure smoke running.)
  - PLACEMENT: after the two pure S3 functions, before `return M`.
  - NAMING: `M.apply` (NOT `M.accept` — avoids shadowing completion.M.accept in the routing;
    "apply" reads as "apply the candidate to the buffer"). Acceptable alternative: `M.accept_item`.
  - DOC-COMMENT: a `---` luadoc block stating: input/output; the §17.8 steps 3-5 contract; the
    byte-domain note (§17.14); the VERIFIED nvim facts (set_text ≠ TextChangedI → explicit
    refresh for dirs; set_cursor row asymmetry); never-throws; lazy-require rationale.

Task 3: ADD the shell branch to completion.M.accept (lua/pi-bridge/completion.lua)
  - REORDER: move the `nvim_buf_get_lines(buf, 0, -1, false)` read ABOVE the bridge-availability
    guard (it is currently below it, ~L780 vs ~L790). pcall it (wiped buf → return false).
  - INSERT the branch AFTER the lines read, BEFORE the bridge check:
      `if type(lines[1]) == "string" and lines[1]:sub(1, 1) == "!" then`
      `  return require("pi-bridge.shell.accept").apply(buf, item) == true`
      `end`
  - PRESERVE: the pi-bridge applyCompletion path AFTER the branch is byte-identical to today
    (it reuses the already-read `lines`). on_enter/on_tab/_route_or_accept UNCHANGED.
  - NEVER-THROWS: pcall the get_lines; the delegate is pcall-safe by construction (M.apply never
    throws). prefix_override is IGNORED on the shell path (documented in the branch comment).
  - VALIDATION: a `!` line with NO bridge still routes to accept.apply (shell completion is
    bridge-independent, §17.3/§17.13); a `/` line runs the pi path unchanged.

Task 4: EXTEND tests/shell_accept_spec.lua (plenary) with the M.apply block
  - ADD: `describe("pi-bridge.shell.accept M.apply (§17.8 step 3-5 — buffer mutation)", function() … end)`
  - COPY the `buf_with(line_text, byte_col)` helper from tests/shell_complete_current_spec.lua
    L86-93 (scratch buf + virtualedit=onemore + set lines + cursor). Add a before_each/after_each
    that saves/restores globals + calls shell.reset().
  - CASES (assert buffer line 1 + cursor col after apply):
      * plain word: "!git ch" (cursor end, col 7) apply "checkout" → "!git checkout " + cursor col 12.
      * trailing-space empty word: "!git " (col 5) apply "git" → "!git " + cursor after.
      * directory re-trigger: "!cd /tm" apply "/tmp/" → "!cd /tmp/" + completion.refresh called
        (spy/mock) + cursor after. Assert refresh is NOT called for a non-dir value.
      * bash quote (space): "!cd my" apply "my file.txt" → "!cd 'my file.txt'" + cursor after.
      * fish quote (space): same → "!cd \"my file.txt\"".
      * embedded-quote idiom: apply "a'b" (bash) → "'a'\"'\"'b'" spliced.
      * cursor mid-word: "!git check" cursor@6 apply "checkout" → replaces "ch" only; "after" (eck) preserved.
      * multibyte byte-correct: "!日cmd" apply → offsets on char boundaries.
      * never-throws + false: apply(nil,item), apply(buf,nil), apply(<invalid>,item),
        apply(<non-current>,item) → false, no throw.
      * routing: completion.M.accept(item) on a "!" buf → accept.apply called (mock/spy) + NO
        bridge applyCompletion; on a "/model " buf → pi path (regression).
      * surface: M.apply + M.get_shell are functions; no uv_timer_t leaked.
  - RUN: `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_accept_spec.lua")'`

Task 5: EXTEND tests/shell_accept_smoke.lua (plenary-free, -u NORC) with a buffer-mutation section
  - ADD: a section that creates a scratch buffer (nvim_create_buf + nvim_win_set_buf) + calls
    M.apply directly (no daemon needed — the pure quote/word fns + nvim_buf_set_text are the path)
    + asserts the buffer line + cursor. ~3 representative cases (plain word + bash quote + dir).
  - headless nvim under -u NORC HAS vim.api (coords_smoke/menu_smoke create buffers under NORC);
    set virtualedit=onemore for the cursor-at-EOL case.
  - the existing pure-function cases (1-13) STAY; the buffer-mutation section APPENDS before the
    final `if fails>0 then cquit 1 end` / `SMOKE_PASS`.
  - RUN: `timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_accept_smoke.lua" +qa`
```

### Implementation Patterns & Key Details

```lua
-- The M.apply orchestrator (the reference shape — match the structure):
function M.apply(buf, item)
  -- (1) validate (never-throws; return false on miss)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end
  if type(item) ~= "table" or type(item.value) ~= "string" then return false end
  -- (2) read line 1 + cursor (pcall every nvim call)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, 1, false)
  if not ok or type(lines) ~= "table" or type(lines[1]) ~= "string" then return false end
  local line1 = lines[1]
  local cok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
  if not cok or type(cur) ~= "table" or type(cur[2]) ~= "number" then return false end
  local byte_col = cur[2]
  -- (3) bang strip (complete_current L987-990 — check "!!" FIRST)
  local bangs = 0
  if line1:sub(1, 2) == "!!" then bangs = 2
  elseif line1:sub(1, 1) == "!" then bangs = 1 end
  local cmd = line1:sub(bangs + 1)
  local cmd_cursor = math.max(0, byte_col - bangs)
  -- (4) S3 word range + quote
  local _word, start_byte = M.current_shell_word(cmd, cmd_cursor)
  local shell = require("pi-bridge.shell").get_shell()   -- lazy (NORC-safe); nil → POSIX default
  local quoted = M.quote(item.value, shell)
  -- (5) range edit (row 0; ADD BANGS to the cmd-relative offsets; set_text ≠ TextChangedI)
  local buf_start, buf_end = bangs + start_byte, bangs + cmd_cursor
  local tok = pcall(vim.api.nvim_buf_set_text, buf, 0, buf_start, 0, buf_end, { quoted })
  if not tok then return false end
  -- (6) cursor after inserted text (row 1 = 1-based; col 0-based byte; Insert-safe + synchronous)
  pcall(vim.api.nvim_win_set_cursor, 0, { 1, buf_start + #quoted })
  -- (7) close menu (idempotent; pcall'd)
  pcall(require("pi-bridge.menu").close)
  -- (8) directory re-trigger (EXPLICIT — set_text did NOT fire TextChangedI)
  if item.value:sub(-1) == "/" then pcall(require("pi-bridge.completion").refresh, buf) end
  return true
end

-- The routing branch in completion.M.accept (the ONLY structural change to the pi path):
--   move the get_lines ABOVE the bridge guard, then:
if type(lines[1]) == "string" and lines[1]:sub(1, 1) == "!" then
  return require("pi-bridge.shell.accept").apply(buf, item) == true
end
-- …existing pi-bridge applyCompletion path (byte-identical; reuses `lines`)…
```

### Integration Points

```yaml
ROUTING (completion.lua M.accept):
  - add the shell branch BEFORE the bridge-availability check (a `!` line routes to accept.apply
    even when the bridge is disconnected — shell completion is bridge-independent, §17.3/§17.13).
  - the get_lines read moves ABOVE the bridge guard (reused by the pi path — no double-read).
  - on_enter / on_tab / _route_or_accept are UNCHANGED (they funnel through M.accept).

ACCESSOR (shell.lua):
  - add M.get_shell() near the public accessors (~L283). Returns state.shell | nil.

ACCEPT MODULE (shell/accept.lua):
  - add M.apply(buf, item) as a third export (after the two pure S3 fns). Lazy requires INSIDE.
  - the two pure fns (current_shell_word, quote) are UNCHANGED.

MENU (menu.lua):
  - NO change. M.apply calls the existing M.close(). NO get_context added (routing re-derives
    from line 1).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Lua lint/format (the repo uses selene + stylua — run if configured; else a load check).
stylua --check lua/pi-bridge/shell/accept.lua lua/pi-bridge/shell.lua lua/pi-bridge/completion.lua 2>/dev/null || true
selene lua/pi-bridge/shell/accept.lua lua/pi-bridge/shell.lua lua/pi-bridge/completion.lua 2>/dev/null || true

# Load check (the module MUST load under -u NORC — accept.lua stays NORC-safe):
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua local a = require("pi-bridge.shell.accept"); assert(type(a.apply)=="function"); assert(type(a.current_shell_word)=="function"); assert(type(a.quote)=="function")' \
  -c 'lua assert(type(require("pi-bridge.shell").get_shell)=="function")' -c 'qa'
echo "exit=$?"   # 0 = loads + the 3 exports exist; NORC-safe (pure smoke still runs)

# LSP diagnostics (if available):
# (use the lsp_diagnostics tool on the 3 edited files)
# Expected: Zero errors on the edited files. Fix before proceeding.
```

### Level 2: Unit Tests (Component Validation)

```bash
# The PRIMARY gate — the S4 buffer-mutation cases (plenary):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_accept_spec.lua")'
echo "exit=$?"   # 0 = all apply + pure cases pass

# The plenary-free smoke (pure cases + the S4 buffer-mutation section; -u NORC):
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_accept_smoke.lua" +qa
echo "exit=$?   # 0 + SMOKE_PASS = good"

# Regression: the shell/completion/menu/accept suites stay green:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_fish_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_accept_smoke.lua")' 2>/dev/null || true
# Expected: all pass (S4 is additive; the pi path is unchanged after the shell branch).
```

### Level 3: Integration Testing (System Validation)

```bash
# A headless end-to-end: drive M.apply through a real buffer + assert the splice + cursor + re-trigger.
# Write the check to a FILE (AGENTS.md ⛔ HARD RULE: NEVER heredoc-to-nvim-stdin):
cat > /tmp/shell_apply_e2e.lua <<'LUA'
local accept = require("pi-bridge.shell.accept")
local shell  = require("pi-bridge.shell")
local fails = 0
local function check(c, m) if not c then io.stderr:write("FAIL: "..m.."\n"); fails = fails + 1 end end

-- plain word: "!git ch" cursor end (col 7) accept "checkout"
do
  local buf = vim.api.nvim_create_buf(false, true); local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf); vim.wo[win].virtualedit = "onemore"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "!git ch" })
  vim.api.nvim_win_set_cursor(win, { 1, 7 })
  -- stub get_shell → "bash"
  package.loaded["pi-bridge.shell"] = setmetatable({ get_shell = function() return "bash" end,
    reset = function() end }, { __index = function() return function() end end })
  local r = accept.apply(buf, { value = "checkout" })
  local got = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  local col = vim.api.nvim_win_get_cursor(0)[2]
  check(r == true, "apply returned true")
  check(got == "!git checkout ", "buffer = "..got)
  check(col == 12, "cursor col = "..tostring(col).." (after 'checkout')")
end

-- directory re-trigger: assert completion.refresh is called for a "/" value
do
  local refreshed = false
  package.loaded["pi-bridge.completion"] = setmetatable({ refresh = function() refreshed = true end },
    { __index = function() return function() end end })
  local buf = vim.api.nvim_create_buf(false, true); local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf); vim.wo[win].virtualedit = "onemore"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "!cd /tm" })
  vim.api.nvim_win_set_cursor(win, { 1, 8 })
  accept.apply(buf, { value = "/tmp/" })
  local got = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  check(got == "!cd /tmp/", "dir buffer = "..got)
  check(refreshed == true, "completion.refresh called for a directory value")
end

if fails > 0 then io.stderr:write(fails.." check(s) failed\n"); vim.cmd("cquit 1") end
io.stdout:write("E2E_PASS: shell.accept.apply (plain word + directory re-trigger) OK\n")
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/shell_apply_e2e.lua" +qa
echo "exit=$?   # 0 + E2E_PASS = good"
# (This is a one-off integration check; the authoritative gates are Level 2. Levels 3b heredoc-to-
#  nvim-stdin from older PRPs are the trap — DO NOT use them; this writes to a FILE then :luafile's.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# (No MCP/server/Docker surface for this task — it is pure Lua buffer mutation.)
# Optional: a LIVE fish round-trip IF fish is on PATH (gated; skip silently otherwise):
if command -v fish >/dev/null 2>&1; then
  # spin the real fish daemon, populate a "!git ch" menu, accept "checkout", assert the buffer.
  # (the shell_fish_spec.lua live test already covers the daemon; S4's accept is exercised by
  #  the Level 2/3 cases above with a stubbed shell. A live end-to-end is a nice-to-have, not a gate.)
  echo "fish present — a live accept round-trip is feasible but optional (Level 2 is the gate)."
else
  echo "fish absent — skipping the live round-trip (Level 2 stubbed-shell cases are the gate)."
fi
# Expected: Level 2 (plenary + smoke) is the authoritative gate; Levels 3-4 are confirmatory.
```

## Final Validation Checklist

### Technical Validation
- [ ] `lua/pi-bridge/shell/accept.lua` loads under `-u NORC`; `M.apply` + the 2 pure fns exist.
- [ ] `lua/pi-bridge/shell.lua` `M.get_shell` is a function; returns `state.shell` | nil.
- [ ] `completion.M.accept` routes `!` lines to `accept.apply`; the pi path is unchanged on `/` lines.
- [ ] `tests/shell_accept_spec.lua` passes (plenary); `tests/shell_accept_smoke.lua` prints `SMOKE_PASS`.
- [ ] Regression suite green (`shell_spec`/`shell_fish_spec`/`completion_spec`/`completion_accept_*`/`menu_spec`).

### Feature Validation
- [ ] `!git ch` accept `checkout` → `!git checkout ` + cursor after + menu closed (no refresh).
- [ ] `!cd my` accept `my file.txt` (bash→`'my file.txt'`; fish→`"my file.txt"`).
- [ ] `!cd /tm` accept `/tmp/` → `!cd /tmp/` + `completion.refresh(buf)` called (directory re-trigger).
- [ ] cursor mid-word preserves the `after`-cursor text.
- [ ] byte-correct on multibyte (`!日cmd`).
- [ ] never-throws: bad buf/item → `false`, no throw; routing falls through cleanly.

### Code Quality Validation
- [ ] `M.apply`'s requires are INSIDE the fn (NORC-safe module load; pure smoke runs).
- [ ] Every nvim call in `M.apply` is `pcall`'d; buf validated valid+current.
- [ ] The byte-offset mapping adds `bangs` to the cmd-relative `start_byte`/`cmd_cursor`.
- [ ] No new menu accessor (routing re-derives context from line 1).
- [ ] `nvim_buf_set_text` (range) used — NOT `nvim_buf_set_lines` (whole buffer).

### Documentation & Deployment
- [ ] `M.apply` / `M.get_shell` have `---` luadoc blocks (input/output, §17.8 steps, byte-domain,
      the VERIFIED nvim facts, never-throws, lazy-require rationale).
- [ ] The routing branch comment explains why it runs before the bridge guard + why it re-derives
      from line 1 (not menu state).

---

## Anti-Patterns to Avoid

- ❌ **Don't use `nvim_buf_set_lines` for the shell accept** — that's the pi path's WHOLEbuffer
  rewrite. Shell accept is a WORD-RANGE edit → `nvim_buf_set_text` (PRD §17.8 step 3 is explicit).
- ❌ **Don't forget `bangs`** in the byte-offset mapping — `start_byte`/`cmd_cursor` are relative to
  the bang-stripped command; the buffer offset is `bangs + offset` (the #1 off-by-N trap).
- ❌ **Don't rely on TextChangedI for the directory re-trigger** — `nvim_buf_set_text` does NOT
  fire it (VERIFIED). The re-trigger MUST be an explicit `completion.refresh(buf)`.
- ❌ **Don't add `menu.get_context()`** — `state.context` is the visual-cue's source + may be stale.
  Re-derive from line 1 (`lines[1]:sub(1,1)=="!"`) for correctness.
- ❌ **Don't put `require(...)` at module top in accept.lua** — breaks `-u NORC` loading + the pure
  smoke. All requires INSIDE `M.apply`.
- ❌ **Don't route in `on_enter`/`on_tab` separately** — that duplicates the check 3×. Route ONCE in
  `M.accept` (the single funnel).
- ❌ **Don't move the bridge check BELOW the lines read carelessly** — a `!` line MUST route to the
  shell path even when the bridge is disconnected (shell completion is bridge-independent). The
  shell branch runs BEFORE the bridge guard; the pi path (after it) reuses the already-read `lines`.
- ❌ **Don't catch all exceptions silently** — be specific; pcall + return `false` (never throw), but
  the routing returns it so `<Tab>`/`<CR>` fall through to indent/newline (the user sees the default).
- ❌ **Don't pipe a heredoc into nvim stdin** (AGENTS.md ⛔ HARD RULE) — write the e2e check to a FILE,
  then `+"luafile <file>" +qa`. Always wrap in `timeout`.

---

## Confidence Score: 9/10

**Why 9, not 10**: the design is fully grounded — S3's pure fns are shipped + exhaustively tested
(the word algorithm + the quoting table are locked); the nvim API facts are `:help`-VERIFIED (byte
offsets, end-exclusive, set_text ≠ TextChangedI, set_cursor row asymmetry, Insert-safe, synchronous);
the byte-offset mapping is pinned with 2 worked examples; the routing re-derives from the buffer
(no menu-state staleness); and the test harness (`buf_with` helper) is copied from a passing sibling
spec. The -1 is for the routing reorder in `completion.M.accept` (moving the lines read above the
bridge guard) — it is a safe, minimal change, but it touches the live pi-accept path, so the
regression suite (`completion_accept_spec`/`_smoke`) is the proof it didn't drift.