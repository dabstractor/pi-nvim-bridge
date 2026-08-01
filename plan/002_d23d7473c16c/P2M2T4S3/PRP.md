---
name: "P2.M2.T4.S3 — shell/accept.lua PURE half: current_shell_word + per-shell quote table"
why_this_prp: "The offline-testable, no-nvim half of 17.8 (Local acceptance & quoting). S3 ships the two PURE functions (`current_shell_word` = the quote-aware current-word computation; `quote` = the per-shell quoting table) that S4's buffer-mutation accept consumes. Every quoting rule + the word algorithm below was LIVE-VERIFIED (fish 4.8.1; the bash/zsh single-quote-with-embedded-quote idiom; the POSIX special-char set) and is pinned with table tests. S3 is additive + dependency-free (the coords.lua / shell_word_prefix / fish.parse pattern)."
---

## Goal

**Feature Goal**: Implement `lua/pi-bridge/shell/accept.lua` — the **PURE, offline-testable
half** of PRD §17.8 (Local acceptance & quoting) — exporting exactly two functions:
1. **`M.current_shell_word(line, cursor)`** — the quote-aware current-shell-word computation
   (PRD §17.8 step 1): the maximal substring of `line[1..cursor]` ending at the cursor,
   delimited by **unquoted** whitespace (a single-pass state machine over single-quote /
   double-quote / backslash-escape states). Returns `(word, start_byte)` where `start_byte` is
   the **0-based byte offset** where `word` begins (the range S4's `nvim_buf_set_text` will
   replace).
2. **`M.quote(word, shell)`** — the per-shell quoting table (PRD §17.8 step 2): returns the
   string to splice at the cursor — the original word UNCHANGED when it needs no quoting, else
   the shell-correct quoted form (`"…"` for fish when the word has a space; `'…'` for
   bash/zsh with the `'…'"'"'…'` idiom for an embedded single quote).

Both functions are **PURE** (no `vim.*`, no `require`, no state, no side effects) → directly
unit-testable offline with static fixtures (no live shell, no socket, no daemon, no nvim). This
mirrors the established repo pattern: `coords.lua`, `shell.shell_word_prefix`,
`shell.resolve_shell`/`mismatch_target`, `completion.is_attachment_context`, and
`shell.fish.parse`.

**Deliverable**:
1. `lua/pi-bridge/shell/accept.lua` — NEW module exporting `M.current_shell_word` + `M.quote`
   (+ a tiny module-local `basename` helper; ~110-150 lines).
2. `tests/shell_accept_spec.lua` — plenary/busted OFFLINE table tests (the §17.15
   `shell_accept_spec.lua` quoting table + the `current_shell_word` word/offset cases).
3. `tests/shell_accept_smoke.lua` — plenary-free offline smoke (load + representative cases →
   `SMOKE_PASS`).

**NO edits** to `shell.lua`, `completion.lua`, `menu.lua`, `fish.lua`, or any extension file —
S3 is purely additive. S4 (P2.M2.T4.S4) will consume these two functions from the
buffer-mutation accept it adds; S3 just ships the pure building blocks.

**Success Definition**:
- `require("pi-bridge.shell.accept").current_shell_word` and `.quote` are functions; the module
  loads with `nvim --headless --clean -u NORC -c 'set rtp+=.'` (no `vim.*` at load — it's pure).
- `current_shell_word` correctly computes `(word, start_byte)` for: plain words, leading/multiple
  whitespace, empty command, cursor-on-whitespace (empty word), single-quoted regions, double-
  quoted regions, backslash-escaped spaces, and the realistic `!git ch` / `!cd "my dir` cases —
  byte-accurate (UTF-8 continuation bytes never count as whitespace/quote/escape).
- `quote` produces the EXACT expected string per shell (the §17.15 table): unchanged when no
  special char; `"…"` for fish when a space; `'…'` for bash/zsh with the `'"'"'` idiom for an
  embedded `'` — and crucially leaves `"`/`$`/`\`/backtick **untouched inside single quotes**
  (the whole point of single-quoting).
- Both NEVER throw (non-string `word`/`line` → `""`/`("",0)`; unknown/nil shell → the bash/zsh
  default; bad `cursor` clamped to `[0,#line]`).
- `tests/shell_accept_spec.lua` passes offline via plenary (exit 0); `tests/shell_accept_smoke.lua`
  prints `SMOKE_PASS` + exit 0. The pre-existing shell tests stay green (additive only).

## User Persona (if applicable)

**Target User**: the `pi-bridge.nvim` maintainer / CI runner (the direct consumer is S4's
`accept` function). Indirect user: a pi user whose `$SHELL`/resolved shell is fish/zsh/bash who
accepts a shell completion containing a space or shell metacharacter in the `!`/`!!` buffer.

**Use Case**: the user types `!cd "my di<Tab>` in the pi-prompt buffer → the menu offers
`my dir` (the value, with a space). On `<Tab>`/`<CR>` accept, S4 calls
`accept.current_shell_word(line, cursor)` → `('"my di', 3)`, then
`accept.quote("my dir", "/bin/bash")` → `"'my dir'"`, then replaces bytes `[4 .. cursor]` with
`'my dir'` via `nvim_buf_set_text`. S3 is the two pure calls; S4 is the splice.

**Pain Points Addressed**: today (pre-S3) there is NO shell-word boundary computation + NO
quoting helper. S4 cannot be written without them. Centralizing the quote-aware word math + the
per-shell quoting in ONE pure, table-tested module means the genuinely subtle part (tokenization
across quotes; the bash idiom; fish's lighter rule) is locked by fixtures, not discovered by a
buffer-corrupting bug at runtime.

## Why

- **PRD §17.8 explicitly mandates** a `shell/accept.lua` with a quote-aware word computation +
  a per-shell quoting table, and §17.15 mandates `shell_accept_spec.lua` quoting table tests.
  S3 creates both, scoped to the PURE (offline-testable) half.
- **S3 unblocks S4**: the buffer-mutation accept (`nvim_buf_set_text` + cursor + re-trigger) is
  meaningless without knowing WHICH bytes to replace (the word range) and WHAT to insert (the
  quoted word). Shipping those two as pure, locked functions lets S4 be a thin, testable
  orchestrator (read menu selection + buffer → call the two functions → `set_text` → cursor).
- **Additive + low-risk**: two pure functions + two test files. No socket, no daemon, no nvim
  API, no state mutation, no edits to any shipped file. Cannot regress the live completion path
  (which today routes shell lines to `do_shell_fetch` → `complete_current`; accept routing is
  S4's job, not landed yet).

## What

A new Lua module `lua/pi-bridge/shell/accept.lua`:

- **`M.current_shell_word(line, cursor)`** — a single-pass byte state machine. Input: `line`
  (UTF-8 string, the command text UP TO the cursor — `complete_current` already produced this
  with the `!`/`!!` bangs stripped), `cursor` (0-based byte offset into `line`, default `#line`).
  Output: `(word:string, start_byte:integer)` where `word = line:sub(start_byte+1, cursor)` and
  `start_byte` is the 0-based byte offset where the current word begins. Quote-aware: whitespace
  inside `'...'`, inside `"..."`, or after an unquoted `\` does **NOT** delimit.
- **`M.quote(word, shell)`** — returns the splice-safe string. Input: `word` (the candidate,
  e.g. `AutocompleteItem.value`), `shell` (the resolved shell PATH **or** basename — `quote`
  derives the basename internally). Output: the original `word` UNCHANGED when it needs no
  quoting; else the per-shell quoted form.

### Success Criteria

- [ ] `lua/pi-bridge/shell/accept.lua` exists; `require("pi-bridge.shell.accept")` loads under
      `nvim --headless --clean -u NORC -c 'set rtp+=.'`; `current_shell_word` + `quote` are functions.
- [ ] `current_shell_word("git ch", 6)` → `("ch", 4)`; `("git ", 4)` → `("", 4)` (trailing
      space → empty word); `("checkout", 8)` → `("checkout", 0)`; `("", 0)` → `("", 0)`.
- [ ] quote-aware: `current_shell_word('echo "hello', 11)` (open dquote) → `('"hello', 5)`;
      `current_shell_word('echo a\\ b', 9)` (escaped space) → `('a\\ b', 5)`.
- [ ] byte-correct: a multibyte trailing word (e.g. `"日cmd"`) → word returned WHOLE; `start_byte`
      reflects BYTE length, not codepoint/UTF-16 (continuation bytes ≥0x80 never match whitespace).
- [ ] `quote("checkout", "bash")` == `"checkout"` (unchanged); same for `"fish"`.
- [ ] `quote("my file.txt", "bash")` == `"'my file.txt'"`; `quote("my file.txt", "fish")`
      == `'"my file.txt"'`.
- [ ] `quote("a$b", "bash")` == `"'a$b'"`; `quote("a$b", "fish")` == `"a$b"` (fish lighter rule:
      no space → unchanged).
- [ ] `quote("a'b", "bash")` == `"'a'\"'\"'b'"` (the idiom); `quote('a"b', "bash")` == `"'a\"b'"`
      (a `"` inside single quotes is a literal — single quotes neutralize it, NO escaping needed).
- [ ] `quote("a\"b", "fish")` (a `"` + no space) → unchanged (`"a\"b"`) — fish rule is space-only.
      `quote("a \"b c", "fish")` (space) → `"\"a \\\"b c\""` (double-quote; escape `\` + `"` inside).
- [ ] shell accepts PATH **or** basename: `quote(word, "/bin/zsh")` == `quote(word, "zsh")`;
      unknown basename (e.g. `"nu"`) → the bash/zsh single-quote default.
- [ ] NEVER throws: `quote(nil, "bash")` → `""`; `current_shell_word(nil, 3)` → `("", 0)`;
      `current_shell_word("abc", -5)` → clamps to `("abc", 0)`; `current_shell_word("abc", 999)`
      → clamps to `("abc", 3)`.
- [ ] `tests/shell_accept_spec.lua` (plenary) passes offline (no live shell needed).
- [ ] `tests/shell_accept_smoke.lua` (plenary-free) prints `SMOKE_PASS` + exit 0.
- [ ] Regression: `shell_spec.lua` + `shell_fish_spec.lua` + `completion_spec.lua` stay green.

## All Needed Context

### Context Completeness Check

_Pass_: "If someone knew nothing about this codebase, would they have everything needed to
implement this successfully?" — **Yes.** The PRD excerpts (§17.8 step 1+2, §17.14 byte-domain,
§17.15 quoting table), the LIVE-VERIFIED findings (research/accept_findings.md), the exact
algorithm + worked examples + the canonical quoting reference table, the verified test-harness
structure (`tests/shell_fish_spec.lua` for plenary; `_smoke.lua` for plenary-free), and the
verified validation commands are all below. The implementer creates exactly ONE new module +
two test files, and touches nothing else.

### Documentation & References

```yaml
# MUST READ — the spec that defines these exact functions
- url: PRD.md §17.8 "Local acceptance & quoting (NOT pi's applyCompletion)"
  why: |
    defines the TWO pure steps S3 owns. Step 1: "the maximal substring of line[1..cursor]
    ending at the cursor, delimited by unquoted whitespace … v1 approximates client-side with a
    quote-aware splitter. \-continuations are v1-out." Step 2: "Quote the candidate IF it
    contains characters special to the resolved shell (spaces, and shell metacharacters
    $ \ ` " ' < > | & ; ( ) ~ for bash/zsh; fish has lighter rules). fish: … still wrap paths
    with spaces in double quotes. bash/zsh: single-quote unless the candidate contains a single
    quote (then use the '…'"'"'…' idiom)."
  critical: |
    step 1 is the QUOTE-AWARE splitter (NOT the naive trailing-non-whitespace run — that is
    shell.shell_word_prefix, which is quote-UNaware + coexists for menu DISPLAY). step 2's bash
    single-quote rule NEUTRALIZES " $ \ backtick for FREE (they are literal inside single quotes);
    ONLY ' needs the '"'"' idiom. fish's rule is SPACE-ONLY (lighter). These two facts are the
    #1 + #2 correctness traps; the quoting table in the spec pins both.
- url: PRD.md §17.14 "Coordinate & encoding notes (shell path)"
  why: |
    "the shell path does NOT use pi's UTF-16 cursor contract … cursor sent in the request is a
    BYTE offset into the UTF-8 line … Accept uses nvim_buf_set_text with BYTE column offsets."
  critical: |
    current_shell_word operates in BYTES. `cursor` is a 0-based BYTE offset; `start_byte` is a
    0-based BYTE offset. NEVER call coords.byte_to_utf16 / vim.str_utfindex / coords.nvim_to_pi_coords
    (those are the §8 UTF-16 bridge path). The byte scan is UTF-8-safe because whitespace/squote/
    dquote/backslash are all ASCII (< 0x80); UTF-8 continuation bytes (≥ 0x80) never match them.
- url: PRD.md §17.15 "Testing strategy (shell-specific)"
  why: |
    "shell_accept_spec.lua — table tests for quoting: spaces (my file.txt), $, backtick, single /
    double quote, combined; per shell; assert the inserted byte range and cursor position."
  critical: |
    the "inserted byte range and cursor position" assertions are S4's (nvim_buf_set_text).
    S3 owns the PURE quoting table + the word/offset cases (offline, no live shell). S4 will ADD
    the buffer-mutation cases to the SAME file later; S3 creates the file with the pure half.

# Codebase files to follow EXACTLY
- file: plan/002_d23d7473c16c/P2M2T4S3/research/accept_findings.md
  why: "S3's OWN research. §2 = LIVE-VERIFIED fish returns UN-quoted words with spaces
        (complete -C 'ls my' → 'my file.txt') → confirms the fish double-quote rule. §3 = the
        bash/zsh idiom verified (gsub-THEN-wrap, NOT wrap-then-sed). §4 = the parsed POSIX
        special-char set + the byte-scan recommendation (avoid Lua-pattern pitfalls). §5 = the
        current_shell_word algorithm + 7 worked examples + the v1 limitations. §7 = the quoting
        reference table (the spec's core) + the 2 decisions pinned."
  pattern: "the algorithm + the table are the reference implementation — match them exactly."
  gotcha: "§7 decision 2: bash single-quote + `\"` in word → the `\"` is a LITERAL inside single
        quotes (single quotes neutralize it); NEVER escape `\"` inside single quotes. Only `'`
        gets the idiom."

- file: lua/pi-bridge/shell.lua
  why: "the sibling module accept.lua coexists with. The PURE-function export pattern to mirror."
  pattern: |
    L917 `M.shell_word_prefix(line)` = `line:match("[%S]+$")` — the NAIVE (quote-unaware) trailing
      word used by complete_current for menu DISPLAY. accept.current_shell_word is the
      QUOTE-AWARE version for the EDIT. They COEXIST (do NOT replace shell_word_prefix).
    L~310 `M.resolve_shell(prefer)` returns `(shell_path, source)` — S4 passes shell_path to quote.
    L~145 `M.mismatch_target(resolved_shell, env_shell)` uses a module-local `basename(p)` helper —
      accept.lua gets its OWN tiny basename (it must not require shell.lua; it's pure / dependency-free).
  gotcha: "accept.lua must NOT `require(\"pi-bridge.shell\")` or any nvim API — it is PURE + dependency-free
        (the fish.parse contract). The basename helper is 2 lines; inline it. (Lazy require inside a
        function is still a require — avoid entirely; accept.lua needs none.)"

- file: lua/pi-bridge/shell/fish.lua
  why: "the SIBLING module under lua/pi-bridge/shell/. Module conventions to mirror + the pure-fn shape."
  pattern: |
    `local M = {}` … `---` luadoc … `function M.X(...)` … `return M`. `M.parse(raw)` (L~140) is the
      template: a pure, never-throws, dependency-free (no `vim.*`/require) function with a type-guard
      first line (`if type(raw) ~= \"string\" then return {} end`) + a doc-comment stating the
      contract + limitations.
  gotcha: "fish.lua is NOT a driver required by pick_driver (basename 'fish' is). accept.lua is NOT
        a driver either — basename 'accept' is not a shell; S4 requires it by absolute path
        `require(\"pi-bridge.shell.accept\")`. No registration needed; just the file."

- file: lua/pi-bridge/completion.lua   (READ-ONLY — the future S4 consumer; NOT edited by S3)
  why: |
    confirms where S4 will route. L~770 `M.accept(item, prefix_override)` is the PI bridge path
    (applyCompletion RPC — wholesale nvim_buf_set_lines). For SHELL context, S4 adds a NEW accept
    (in accept.lua) that does the local word-replacement (nvim_buf_set_text range edit). S3 ships
    the two pure functions that accept.lua's S4 M.accept will call.
  pattern: "on_enter (L~810) / on_tab (L~840) currently route menu-open+selected → M.accept (PI path).
    S4 adds: `if ctx == \"shell\" then require(\"pi-bridge.shell.accept\").accept(buf) end` BEFORE
    the M.accept branch. S3 is inert until S4 wires it (additive — cannot break the live plugin)."
  gotcha: "S3 does NOT touch completion.lua. The shell-context routing is S4's concern. Do not
        pre-wire it (it would duplicate S4 + risk a half-built accept path)."

- file: tests/shell_fish_spec.lua   (the plenary/busted TEMPLATE — copy its structure)
  why: |
    the established OFFLINE pure-function spec structure: header comment with the run command;
    `local m = require(...)` at top; `describe(...)`/`it(...)`/`assert.are.equals`;
    grouped `describe` blocks (golden fixtures, never-throws, shape contract); NO live shell.
  pattern: |
    -- === tests/shell_accept_spec.lua — plenary/busted OFFLINE quoting/word spec (P2.M2.T4.S3) ===
    -- Run: timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
    --        -c 'lua require("plenary.busted").run("tests/shell_accept_spec.lua")'
    local accept = require("pi-bridge.shell.accept")
    describe("pi-bridge.shell.accept (§17.8 / §17.15)", function() … end)
  gotcha: "pure-function specs need NO setup/teardown (no sockets/state). Group cases into
        `describe(\"current_shell_word …\")` + `describe(\"quote per-shell …\")` blocks."

- file: tests/shell_fish_smoke.lua   (the plenary-free smoke TEMPLATE — copy its structure)
  why: |
    the plenary-free smoke: header comment + run command; `local fails = 0 / check(cond,msg)`;
    representative cases; final `if fails>0 then cquit 1 end` + `io.stdout:write(\"SMOKE_PASS: …\")`.
  pattern: "NOT gated on any shell (the functions are pure). Runs under `-u NORC -c 'set rtp+=.'`."
```

### Current Codebase tree (relevant slice)

```bash
pi-nvim-bridge/
├── lua/pi-bridge/
│   ├── shell.lua                 # sibling: shell_word_prefix (NAIVE display prefix), resolve_shell, basename
│   ├── completion.lua            # S4's consumer (on_enter/on_tab → accept) — READ-ONLY (not done yet)
│   ├── coords.lua  menu.lua  bridge.lua  init.lua  notify.lua  health.lua  …
│   └── shell/
│       ├── fish.lua              # sibling: M.start/M.cd/M.parse — module-convention template
│       └── accept.lua            # ← CREATE (S3): M.current_shell_word + M.quote (PURE)
├── tests/
│   ├── shell_fish_spec.lua       # plenary offline-spec TEMPLATE (copy structure)
│   ├── shell_fish_smoke.lua      # plenary-free smoke TEMPLATE (copy structure)
│   ├── shell_accept_spec.lua     # ← CREATE (S3): offline quoting/word table tests
│   ├── shell_accept_smoke.lua    # ← CREATE (S3): plenary-free load + cases smoke
│   └── minimal_init.lua          # plenary harness bootstrap (read-only)
└── PRD.md  (§17.8, §17.14, §17.15 — read-only reference)
```

### Desired Codebase tree with files to be added

```bash
lua/pi-bridge/shell/accept.lua     # CREATE: M.current_shell_word(line,cursor) + M.quote(word,shell) (PURE, never-throws, dependency-free)
tests/shell_accept_spec.lua        # CREATE: plenary/busted OFFLINE table tests (quoting per shell + word/offset cases)
tests/shell_accept_smoke.lua       # CREATE: plenary-free offline smoke (load + representative cases → SMOKE_PASS)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (LIVE-VERIFIED, research §2): fish `complete -C` returns UN-quoted words with spaces.
--   `fish -c 'complete -C "ls my"'` → "my file.txt" (literal space, NOT auto-quoted).
-- → quote("my file.txt","fish") MUST double-quote it ("\"my file.txt\"") or the spliced token
--   splits on the space at execution. This is the PRD §17.8 fish rule, confirmed non-theoretical.

-- CRITICAL (LIVE-VERIFIED, research §3): the bash/zsh embedded-`'` idiom is gsub-THEN-wrap.
--   CORRECT:  "'" .. word:gsub("'", "'\"'\"'") .. "'"     (word="a'b" → "'a'\"'\"'b'")
--   WRONG:    wrap-in-quotes-then-sed-substitute           (over-quotes → '"'"'a'"'"'b'"'"'')
-- → use the Lua gsub-then-wrap form. bash parses 'a'"'"'b' = 'a' + "'" + 'b' = a'b. ✓

-- CRITICAL (research §7 decision 2): bash single-quote NEUTRALIZES " $ \ backtick.
--   A " inside single quotes is a LITERAL — do NOT escape it. quote('a"b','bash') → "'a\"b'"
--   (the " is untouched inside the single quotes). ONLY ' gets the idiom. This is WHY single-quoting
--   is the robust default. (A common bug: escaping " inside single quotes — unnecessary + WRONG.)

-- CRITICAL (§17.14): BYTE-domain, NOT UTF-16. cursor + start_byte are 0-based BYTE offsets.
--   NEVER call coords.byte_to_utf16 / vim.str_utfindex / coords.nvim_to_pi_coords (those are §8's
--   UTF-16 bridge path). The byte scan is UTF-8-safe: whitespace/squote/dquote/backslash are all
--   ASCII (<0x80); UTF-8 continuation bytes (≥0x80) never match → a multibyte trailing word like
--   "日cmd" is returned WHOLE + start_byte reflects its BYTE length.

-- CRITICAL (fish.parse discipline): avoid Lua-pattern pitfalls for the POSIX special-char set.
--   Do NOT use word:find("[%s$\\`\"'<>|&;()~]") — the pattern-class escaping of ` " \ is error-prone
--   (a mis-escape silently drops a special char from the set). Use a BYTE SCAN: iterate word:byte(i)
--   and check membership in a small lookup table {[36]=true,[92]=true,…} OR string.find over a
--   canonical set string with the 4th `true` arg (plain search). Provably correct.

-- GOTCHA: shell_word_prefix (shell.lua:917) is the NAIVE quote-UNaware trailing word for menu
--   DISPLAY. accept.current_shell_word is the QUOTE-AWARE word for the EDIT. They COEXIST — do NOT
--   modify or replace shell_word_prefix (complete_current's display prefix is fine being naive;
--   accept recomputes independently per §17.6.1 / §17.8).

-- GOTCHA: accept.lua must be PURE + dependency-free (no `vim.*`, no `require`). The plenary-free
--   smoke runs under `-u NORC`; a `require` of an nvim-only module at load would break it. The
--   basename helper is 2 lines — INLINE it (do not require shell.lua's module-local basename).

-- GOTCHA: shell may be a PATH ("/bin/zsh") OR a basename ("zsh"). quote derives the basename
--   internally (`(shell or ""):gsub(".*/","")`). Unknown basename ("nu","elvish","?") → the
--   bash/zsh single-quote default (the safe POSIX choice; matches how pick_driver degrades).

-- GOTCHA: NEVER throws (the per-keystroke + S4-orchestrator contract). Non-string word → "";
--   non-string line → ("",0); bad cursor clamped to [0,#line] (a NEGATIVE cursor would make
--   line:sub(1,-1) = the WHOLE string — WRONG; clamp with math.max(0,…)+math.min(#line,…)).

-- GOTCHA: §17.8 v1 limitations (DOCUMENT in the doc-comments, do NOT paper over):
--   * \-line-continuations out of scope (a trailing \ joining lines; the buffer is one logical line).
--   * Unclosed quotes: the word extends to the cursor (the quote is treated as still open — correct,
--     the user is mid-quote).
--   * Escaped space (\ ): treated as non-breaking (part of the word) — the quote-aware behavior.

-- CRITICAL (AGENTS.md ⛔ HARD RULE): NEVER pipe a heredoc / stdin into nvim (it HANGS the session).
--   Write ad-hoc check snippets to a .lua FILE, then +"luafile <file>" +qa. One-liners via
--   `-c 'lua …'` are fine. ALWAYS wrap nvim invocations in `timeout`.
```

## Implementation Blueprint

### Data models and structure

No persistent data models. The two functions consume/produce simple Lua values:

```lua
-- current_shell_word: input → output
--   line   : string  (UTF-8; the command text up to the cursor, bangs already stripped by complete_current)
--   cursor : integer (0-based BYTE offset into line; default #line)
-- returns:
--   word       : string  (the current shell word; "" if cursor is on/after unquoted whitespace)
--   start_byte : integer (0-based BYTE offset where word begins; word = line:sub(start_byte+1, cursor))
local word, start_byte = accept.current_shell_word("git ch", 6)
-- word == "ch", start_byte == 4   → the word occupies line[5..6] (Lua 1-indexed)

-- quote: input → output
--   word   : string (the candidate to splice — typically AutocompleteItem.value)
--   shell  : string (the resolved shell PATH ("/bin/zsh") OR basename ("zsh"); nil → default)
-- returns:
--   quoted : string (the ORIGINAL word if no quoting needed; else the shell-correct quoted form)
local q = accept.quote("my file.txt", "/bin/bash")   -- "'my file.txt'"
local q = accept.quote("checkout", "fish")           -- "checkout" (unchanged)
```

The consumer (S4) composes them:
`local word, start = accept.current_shell_word(line, cursor); local ins = accept.quote(sel.value, state.shell); vim.api.nvim_buf_set_text(buf, row, start, row, cursor, { ins })`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE lua/pi-bridge/shell/accept.lua — module skeleton + basename + current_shell_word
  - IMPLEMENT: `local M = {}`; a module-local `basename(p)` helper (2 lines: type-guard +
    `p:gsub(".*/","")`; nil/non-string → "?"); `M.current_shell_word(line, cursor)`;
    `return M` at the bottom.
  - ALGORITHM for current_shell_word (the §17.8 step-1 quote-aware splitter, research §5):
      * guard: `if type(line) ~= "string" then return "", 0 end`
      * clamp cursor: `cursor = math.max(0, math.min(#line, math.floor(tonumber(cursor) or #line)))`
      * `local word_start = 1`  (1-indexed; word begins here unless advanced past whitespace)
      * `local single, double, escaped = false, false, false`
      * `for i = 1, cursor do`
          `local b = line:byte(i)`
          `if escaped then escaped = false`                          -- consume the escaped byte
          `elseif single then if b == 39 then single = false end`     -- ' closes (no \ escape in single quotes)
          `elseif double then`
            `if b == 92 then escaped = true`                          -- \ escapes next (in double quotes)
            `elseif b == 34 then double = false end`                  -- " closes
          `else`                                                       -- NORMAL (unquoted)
            `if b == 39 then single = true`                           -- ' opens
            `elseif b == 34 then double = true`                       -- " opens
            `elseif b == 92 then escaped = true`                      -- \ escapes next
            `elseif b == 32 or b == 9 then word_start = i + 1 end`    -- UNQUOTED space/tab → boundary
          `end`
        `end`
      * `return line:sub(word_start, cursor), word_start - 1`         -- (word, 0-based start_byte)
  - NAMING: `M.current_shell_word` (the §17.8 name; mirrors `shell.shell_word_prefix` naming).
    Return ORDER `(word, start_byte)` — word first (the common need), offset second (S4's need).
  - PLACEMENT: `lua/pi-bridge/shell/accept.lua` (sibling of fish.lua; S4 requires it by absolute
    path `require("pi-bridge.shell.accept")`).
  - NEVER-THROWS: by construction (type-guard + clamp + byte math; no `vim.*`, no require).
  - DOC-COMMENT: a `---` luadoc block stating: input/output; the quote-aware contract (§17.8
    step 1); the byte-domain note (§17.14); the v1 limitations (line-continuations out; unclosed
    quotes extend to cursor; escaped space non-breaking); never-throws; pure/dependency-free.

Task 2: ADD M.quote(word, shell) to lua/pi-bridge/shell/accept.lua
  - SIGNATURE: `M.quote(word, shell)` → string.
  - STEPS (the §17.8 step-2 per-shell table, research §7):
      * `if type(word) ~= "string" then return "" end`
      * `local base = basename(shell)`   (nil/non-string shell → basename → "?")
      * `if base == "fish" then`
          -- fish rule: double-quote ONLY if the word contains a SPACE (lighter rule, PRD §17.8).
          -- Escape \ and " inside the double quotes (fish double-quote specials). No space → unchanged.
          `if word:find(" ", 1, true) then`                            -- PLAIN find (literal space; no pattern)
            `local esc = word:gsub("\\", "\\\\"):gsub('"', '\\"')`     -- escape \ FIRST then "
            `return '"' .. esc .. '"'`
          `end`
          `return word`
        `end`
      * -- bash / zsh / unknown → the POSIX single-quote rule (the safe default).
      * `-- the special set that TRIGGERS quoting (PRD §17.8): space, $, \, `, ", ', <, >, |, &, ;, (, ), ~`
      * `if needs_quote_posix(word) then`
          -- single-quote; only ' needs the '"'"' idiom (gsub-THEN-wrap). " $ \ backtick are
          -- LITERAL inside single quotes (neutralized for free) — DO NOT escape them.
          `return "'" .. word:gsub("'", "'\"'\"'") .. "'"`
        `end`
      * `return word`   (no special char → unchanged)
  - needs_quote_posix(word): a module-local helper. BYTE SCAN (avoid Lua-pattern pitfalls,
    research §4): iterate `word:byte(i)` and check membership in a lookup table keyed by the
    byte values: 32 (space), 9 (tab), 36 ($), 92 (\), 96 (`), 34 ("), 39 ('), 60 (<), 62 (>),
    124 (|), 38 (&), 59 (;), 40 ((), 41 ()), 126 (~). Return true on the FIRST match (short-circuit).
  - FOLLOW pattern: fish.lua `M.parse`'s pure/never-throws/dependency-free shape + doc-comment style.
  - NAMING: `M.quote` (short; the driver/accept namespace `accept.quote` is unambiguous).
  - GOTCHA: basename("nu")/"?" → NOT "fish" → falls through to the POSIX default. Correct (the
    safe choice for an unknown shell; matches pick_driver's degrade philosophy).
  - DEPENDENCIES: Task 1 (basename). NONE new.

Task 3: CREATE tests/shell_accept_spec.lua (plenary/busted, OFFLINE table tests)
  - PATTERN: `tests/shell_fish_spec.lua` (header comment + run command + `local m = require(...)`
    + grouped `describe`/`it`/`assert.are.equals`). NO live shell, NO nvim API, NO state.
  - CASES (group into describes):
      describe("current_shell_word (§17.8 step 1)", function()
        -- surface
        it("exports current_shell_word as a function", ...)
        -- plain words
        it("'git ch' cursor@6 → ('ch', 4)", ...)
        it("'checkout' cursor@8 → ('checkout', 0)", ...)
        it("'cd /tmp/foo' cursor@11 → ('/tmp/foo', 3)", ...)
        -- whitespace boundaries
        it("'git ' trailing-space cursor@4 → ('', 4)  (empty word)", ...)
        it("'git  ch' 2 spaces cursor@7 → ('ch', 6)", ...)
        it("'' empty → ('', 0)", ...)
        -- quote-aware (the §17.8 contract)
        it('echo "hello open-dquote cursor@11 → ("hello, 5)', ...)        -- word keeps the opening "
        it("echo 'a b' single-quoted-space cursor@10 → ('a b', 5 or 6)", ...) -- space inside '...' non-breaking
        it('echo a\\ b escaped-space cursor@9 → (a\\ b, 5)', ...)          -- \ space non-breaking
        -- BYTE correctness (UTF-8)
        it("'日cmd' cursor@6 (3+3 BYTES) → ('日cmd', 0)  (multibyte whole)", ...)
        -- never-throws + clamp
        it("non-string line → ('', 0)", ...)
        it("negative cursor clamps to 0", ...)
        it("oversize cursor clamps to #line", ...)
      end)
      describe("quote per-shell (§17.8 step 2 / §17.15 table)", function()
        -- surface
        it("exports quote as a function", ...)
        -- unchanged (no special char)
        it("bash: 'checkout' unchanged", ...)
        it("fish: 'checkout' unchanged", ...)
        -- spaces
        it("bash: 'my file.txt' → \"'my file.txt'\"", ...)
        it("fish: 'my file.txt' → '\"my file.txt\"'", ...)
        -- POSIX specials (bash triggers; fish does NOT — lighter rule)
        it("bash: 'a$b' → \"'a$b'\"", ...)
        it("fish: 'a$b' unchanged (no space)", ...)            -- the fish lighter rule
        it("bash: 'a;b' → \"'a;b'\"", ...)
        it("bash: 'a|b' → \"'a|b'\"", ...)
        it("bash: 'a~b' → \"'a~b'\"", ...)
        -- embedded single quote (the idiom) + double-quote-inside-single (neutralized)
        it("bash: \"a'b\" → \"'a'\"'\"'b'\"  (the idiom)", ...)
        it("bash: 'a\"b' → \"'a\"b'\"  (\" is literal inside single quotes; NOT escaped)", ...)
        -- fish double-quote escaping
        it("fish: 'a \"b c' (space) → \"\\\"a \\\\\\\"b c\\\"\"  (escape \\ and \" inside)", ...)
        -- shell accepts PATH or basename
        it("quote(word,'/bin/zsh') == quote(word,'zsh')", ...)
        it("unknown basename ('nu') → bash/zsh default", ...)
        -- never-throws
        it("quote(nil,'bash') → ''", ...)
        it("quote(word,nil) → POSIX default (no throw)", ...)
      end)
  - FOLLOW pattern: tests/shell_fish_spec.lua (the offline pure-fn spec — exact structure).
  - NAMING: tests/shell_accept_spec.lua (FLAT — matches sibling tests/shell_fish_spec.lua; PRD
    §17.15 mentions tests/shell/ but the repo's live convention is FLAT and S1/S2 set it — follow flat).
  - COVERAGE: all §17.15 quoting cases (spaces, $, backtick, single quote, double quote, combined)
    per shell + the word/offset cases + never-throws + UTF-8 byte correctness.
  - NO live shell required (pure fixtures). NO `vim.fn.executable` gate.

Task 4: CREATE tests/shell_accept_smoke.lua (plenary-free offline smoke)
  - PATTERN: tests/shell_fish_smoke.lua (header comment + run command + `local fails = 0 /
    check(cond,msg)` + final `if fails>0 then cquit 1 end` + `io.stdout:write("SMOKE_PASS: …")`).
  - IMPLEMENT: require accept; run ~8-10 representative cases through current_shell_word + quote;
    assert outputs; print SMOKE_PASS (or SMOKE_FAIL + stderr, cquit 1).
  - NOT gated on any shell (pure functions). Runs under `-u NORC -c 'set rtp+=.'`.
  - RUN: timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_accept_smoke.lua" +qa
  - DEPENDENCIES: Tasks 1+2.

Task 5: (NO shell.lua / completion.lua / menu.lua / fish.lua / extension changes)
  - VERIFY: accept.lua is a sibling module S4 will `require("pi-bridge.shell.accept")` by absolute
    path (basename "accept" is not a shell → pick_driver never loads it; no registration needed).
    completion.lua's on_enter/on_tab still route to M.accept (the PI path) — UNCHANGED. S3 is
    PURELY additive: one new module + two tests. Do NOT edit any existing file.
```

### Implementation Patterns & Key Details

```lua
-- === The canonical current_shell_word (reference; the implementer may align naming) ===
-- Pure Lua, never-throws, dependency-free. Byte-domain (§17.14); UTF-8-safe (continuation
-- bytes ≥0x80 never match whitespace/squote/dquote/backslash). The §17.8 step-1 quote-aware
-- splitter. Returns (word, start_byte) where start_byte is 0-based (S4 maps to nvim_buf_set_text).

--- Compute the current shell word (PRD §17.8 step 1): the maximal substring of `line` ending at
--- `cursor`, delimited by UNQUOTED whitespace. Quote-aware: whitespace inside single quotes
--- ('...'), double quotes ("..."), or after an unquoted backslash (\ ) does NOT delimit.
--- Returns `(word, start_byte)` where `start_byte` is the 0-based BYTE offset where `word`
--- begins (the word occupies `line:sub(start_byte+1, cursor)` in Lua 1-indexed) — the range
--- S4's `nvim_buf_set_text` replaces. Byte-domain throughout (§17.14 — NOT UTF-16; NEVER call
--- coords.byte_to_utf16 / vim.str_utfindex). Pure + never-throws + dependency-free → fixture-
--- testable offline (coords.lua / shell_word_prefix style).
---
--- v1 LIMITATIONS (PRD §17.8): \-line-continuations out of scope; unclosed quotes extend the
--- word to the cursor (the user is mid-quote — correct); an escaped space (\ ) is non-breaking
--- (part of the word). KNOWN: this is MORE sophisticated than shell.shell_word_prefix (the
--- naive quote-UNaware trailing word used for menu DISPLAY); the two COEXIST — do not replace it.
---@param line string? The command text up to the cursor (UTF-8; bangs already stripped).
---@param cursor integer? The 0-based BYTE offset into `line` (default #line; clamped to [0,#line]).
---@return string word The current shell word ("" if cursor is on/after unquoted whitespace).
---@return integer start_byte The 0-based BYTE offset where `word` begins.
function M.current_shell_word(line, cursor)
	if type(line) ~= "string" then return "", 0 end
	cursor = math.max(0, math.min(#line, math.floor(tonumber(cursor) or #line)))
	local word_start = 1
	local single, double, escaped = false, false, false
	for i = 1, cursor do
		local b = line:byte(i)
		if escaped then
			escaped = false
		elseif single then
			if b == 39 then single = false end          -- ' closes single-quote (NO \ escape inside)
		elseif double then
			if b == 92 then escaped = true               -- \ escapes next (inside double quotes)
			elseif b == 34 then double = false end       -- " closes double-quote
		else                                            -- NORMAL (unquoted)
			if b == 39 then single = true               -- ' opens
			elseif b == 34 then double = true           -- " opens
			elseif b == 92 then escaped = true          -- \ escapes next
			elseif b == 32 or b == 9 then word_start = i + 1 end  -- UNQUOTED space/tab → boundary
		end
	end
	return line:sub(word_start, cursor), word_start - 1
end

-- === The canonical quote (reference) ===
-- The §17.8 step-2 per-shell table. fish = double-quote iff a space (lighter rule; escape \ and "
-- inside). bash/zsh/unknown = single-quote iff any POSIX special char (only ' gets the '"'"' idiom;
-- " $ \ backtick are literal inside single quotes — neutralized for free, NEVER escaped).

--- Quote `word` per the resolved shell's rules (PRD §17.8 step 2). Returns the splice-safe
--- string: the ORIGINAL word when it needs no quoting, else the shell-correct quoted form.
---   fish      : double-quote iff the word contains a SPACE (escape \ and " inside); else unchanged.
---   bash/zsh  : single-quote iff the word contains any POSIX special char (space $ \ ` " ' < > | & ;
---                ( ) ~); ONLY ' is re-quoted via the '"'"' idiom (everything else is literal
---                inside single quotes). This is the safe default for an UNKNOWN shell too.
--- `shell` may be a PATH ("/bin/zsh") or a basename ("zsh") — derived internally. Pure +
--- never-throws + dependency-free → fixture-testable offline (§17.15 quoting table).
---@param word string? The candidate to splice (e.g. AutocompleteItem.value).
---@param shell string? The resolved shell path OR basename (nil/unknown → POSIX default).
---@return string quoted The (possibly quoted) string; "" on a non-string word.
function M.quote(word, shell)
	if type(word) ~= "string" then return "" end
	local base = basename(shell)   -- "/bin/zsh"→"zsh"; nil/"?"→"?"
	if base == "fish" then
		-- fish lighter rule: double-quote ONLY on a space (escape \ and " inside).
		if word:find(" ", 1, true) then              -- PLAIN find (literal space; no pattern pitfall)
			local esc = word:gsub("\\", "\\\\"):gsub('"', '\\"')   -- escape \ FIRST, then "
			return '"' .. esc .. '"'
		end
		return word
	end
	-- POSIX (bash/zsh/unknown): single-quote iff any special char.
	if needs_quote_posix(word) then
		return "'" .. word:gsub("'", "'\"'\"'") .. "'"   -- gsub-THEN-wrap (only ' gets the idiom)
	end
	return word
end

-- === needs_quote_posix (BYTE SCAN — avoid Lua-pattern pitfalls, research §4) ===
-- The POSIX special set (PRD §17.8): space, $, \, `, ", ', <, >, |, &, ;, (, ), ~. Built as a
-- lookup table keyed by byte value (provably correct; a mis-escaped Lua pattern class would
-- silently drop a char). Whitespace = space(32)+tab(9) (a completion word never has LF/CR).
local POSIX_SPECIALS = {
	[32] = true, [9] = true,   -- whitespace (space, tab)
	[36] = true,               -- $
	[92] = true,               -- \
	[96] = true,               -- `
	[34] = true,               -- "
	[39] = true,               -- '
	[60] = true, [62] = true,  -- < >
	[124] = true,              -- |
	[38] = true,               -- &
	[59] = true,               -- ;
	[40] = true, [41] = true,  -- ( )
	[126] = true,              -- ~
}
local function needs_quote_posix(word)
	for i = 1, #word do
		if POSIX_SPECIALS[word:byte(i)] then return true end
	end
	return false
end

-- === basename (module-local; accept.lua is dependency-free — do NOT require shell.lua's) ===
local function basename(p)
	if type(p) ~= "string" or p == "" then return "?" end
	local b = p:gsub(".*/", "")
	return b == "" and "?" or b
end

-- === KEY INVARIANTS the spec must pin ===
--  1. BYTE-domain (§17.14): start_byte + cursor are 0-based bytes; multibyte words whole.
--  2. quote-aware split: '...' / "..." / \-escaped whitespace never delimit.
--  3. fish lighter rule: SPACE-ONLY triggers double-quoting (no $/`/; etc.).
--  4. bash/zsh single-quote NEUTRALIZES " $ \ backtick (literal inside) — ONLY ' is re-quoted.
--  5. gsub-THEN-wrap for the embedded-' idiom (NOT wrap-then-sed).
--  6. never-throws + pure + dependency-free (no vim.*, no require).
```

### Integration Points

```yaml
NO RUNTIME INTEGRATION (pure additive module):
  - accept.lua is NOT required by any shipped file today. S4 (P2.M2.T4.S4) will be the FIRST
    consumer: it adds `M.accept(buf)` to accept.lua that reads the menu selection + buffer,
    calls `current_shell_word` + `quote`, and does the nvim_buf_set_text range edit + cursor +
    re-trigger. S4 also routes completion.lua's shell-context on_enter/on_tab to it.
  - DO NOT pre-wire S4 (no edits to completion.lua / menu.lua / accept.lua's accept fn). S3 ships
    ONLY the two pure functions + tests.

MODULE DISCOVERY (no registration):
  - pick_driver requires "pi-bridge.shell.<basename>" for shell basenames (fish/zsh/bash) only.
    "accept" is not a shell basename → pick_driver never loads accept.lua. S4 requires it by
    ABSOLUTE path `require("pi-bridge.shell.accept")` (resolves via &runtimepath /
    package.path → lua/pi-bridge/shell/accept.lua). Just the FILE at that path is sufficient.

COORDINATE CONTRACT (§17.14 — the defining rule, SAME as complete_current):
  - BYTE-domain throughout. current_shell_word's `cursor` arg == the 0-based byte col
    nvim_win_get_cursor(0)[2] returns (complete_current already uses this). `start_byte` is the
    0-based byte col S4 passes to nvim_buf_set_text(buf, row, start_byte, row, cursor, {ins}).
    NO coords/UTF-16 anywhere (contrast §8's bridge path).

QUOTING CONTRACT (§17.8 step 2):
  - quote(word, shell) is the single source of truth for splice-safety. S4 calls it ONCE per
    accept + inserts the result verbatim. S4 does NO additional escaping.

DOCUMENTATION (inform S4 + P2.M3.T5):
  - S4 (accept M.accept): compose current_shell_word + quote + nvim_buf_set_text; cursor after
    the inserted text; re-trigger iff word ends in "/". The two pure fns make S4 a thin orchestrator.
  - P2.M3.T5 (zsh/bash drivers): the drivers emit {value,description?} items; accept.quote is
    shell-agnostic (it keys on basename) so zsh/bash acceptance reuses the SAME quote() unchanged.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# From the repo root. Confirm the module LOADS + both functions exist (under -u NORC — proves
# it's pure / dependency-free; a require of an nvim-only module at load would fail here).
# ⛔ NEVER heredoc→nvim stdin (AGENTS.md HARD RULE). Write to a FILE, then :luafile it.
cat > /tmp/s3_loadcheck.lua <<'LUA'
local ok, m = pcall(require, "pi-bridge.shell.accept")
assert(ok, "require failed: " .. tostring(m))
assert(type(m.current_shell_word) == "function", "current_shell_word is a function")
assert(type(m.quote) == "function", "quote is a function")
-- spot-check the headline cases (proves the reference impl landed correctly)
local w, s = m.current_shell_word("git ch", 6)
assert(w == "ch" and s == 4, "git ch → (ch,4); got ("..tostring(w)..","..tostring(s)..")")
assert(m.quote("checkout", "bash") == "checkout", "checkout unchanged")
assert(m.quote("my file.txt", "bash") == "'my file.txt'", "bash single-quote space")
assert(m.quote("my file.txt", "fish") == '"my file.txt"', "fish double-quote space")
assert(m.quote("a'b", "bash") == "'a'\"'\"'b'", "the embedded-' idiom")
print("S3_LOAD_OK")
LUA
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/s3_loadcheck.lua" +qa
echo "exit=$?   # 0 + S3_LOAD_OK = pass"

# luac syntax check (fast, no nvim).
luac -p lua/pi-bridge/shell/accept.lua && echo "luac=ok"

# Then the plenary-free smoke (Task 4): the file-based end-to-end gate (no live shell).
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_accept_smoke.lua" +qa
echo "exit=$?   # 0 + SMOKE_PASS = pass"

# stylua formatting check (repo convention; matches CI in PRD §14) — informational.
# stylua --check lua/pi-bridge/shell/accept.lua tests/shell_accept_spec.lua tests/shell_accept_smoke.lua
```

### Level 2: Unit Tests (Component Validation) — THE GATE

```bash
# The new plenary spec for accept.lua (Task 3). This is S3's primary validation gate.
# OFFLINE — NO live shell required (the functions are pure).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_accept_spec.lua")'
echo "exit=$?   # 0 = all green (current_shell_word cases + the §17.15 quoting table per shell +
#        never-throws + UTF-8 byte correctness)"

# (Optional, fast feedback) the existing shell smoke — confirms no load regression:
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_smoke.lua" +qa
echo "exit=$?"
```

### Level 3: Integration Testing (System Validation)

```bash
# REGRESSION — the shell + completion modules must stay green. S3 is additive (a NEW module +
# tests, NO edits to shipped files); if any of these fail, something is wrong (most likely a
# stray edit to shell.lua/completion.lua, OR a module-load side effect from accept.lua).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'           # resolve_shell/pick_driver/reset
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_fish_spec.lua")'      # the sibling pure-fn spec
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'      # the routing consumer (do_shell_fetch)
echo "all exit 0 = no regression"

# LIVE shell-fidelity cross-check (OPTIONAL; only if fish/bash present): confirm quote()'s OUTPUT
# would actually tokenize the way the shell expects. This pins the quoting rules to REAL shell
# behavior (not just the PRD spec). Write to a FILE (AGENTS.md HARD RULE).
cat > /tmp/pi_quote_fidelity.lua <<'LUA'
local accept = require("pi-bridge.shell.accept")
-- fish: a path-with-spaces, double-quoted, should survive `complete -C` re-parsing round-trip.
-- (fish complete -C returns UN-quoted "my file.txt"; quote() must re-wrap it to "my file.txt"
-- so the spliced token is ONE word. We assert the output shape, not a live spawn, here.)
assert(accept.quote("my file.txt", "/usr/bin/fish") == '"my file.txt"', "fish double-quote space")
-- bash: the embedded-' idiom must, when fed to bash -c, reproduce the ORIGINAL word exactly.
-- This is the LIVE proof the idiom is correct (research §3 verified it conceptually; this EXECUTES it).
local word = "a'b"
local quoted = accept.quote(word, "bash")
local cmd = string.format("test '%s' = '%s' && echo MATCH", "%s", quoted)
-- run: bash -c "test 'a'\''b' = <quoted> && echo MATCH"  → expect MATCH
local uv = vim.uv
local function bash_eval(expr, cb)
  local stdout = uv.new_pipe(false)
  uv.spawn("bash", { args = { "-c", expr }, stdio = { nil, stdout, nil } }, function() end)
  local buf = ""
  stdout:read_start(function(err, data)
    if err or data == nil then cb(buf) return end
    buf = buf .. (data or "")
  end)
end
-- the canonical proof: bash -c "printf %s <quoted>" must print back the ORIGINAL word.
bash_eval("printf %s " .. quoted, function(out)
  out = out:gsub("%s+$", "")  -- trim trailing whitespace
  if out == word then print("BASH_IDIOM_OK: " .. quoted .. " → " .. out)
  else print("BASH_IDIOM_FAIL: got " .. out .. " (want " .. word .. ")") end
  vim.cmd("qa")
end)
vim.wait(5000, function() return false end, 50)  -- let the async spawn resolve before +qa
LUA
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/pi_quote_fidelity.lua" +qa
echo "exit=$?   # expect BASH_IDIOM_OK (bash single-quote idiom reproduces the original word)"
# (If bash is absent this errors harmlessly — skip; the offline quoting table in the spec is the real gate.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Direct cross-check: feed quote()'s output back through REAL fish/bash to prove round-trip fidelity.
# This is the single most valuable creative check — it EXECUTES the quoting rules against the shells
# they target (the spec asserts the STRING; this asserts the SEMANTICS). One-liner via the shell:
#   bash -c 'w="a'\''b"; q='"'"'a'"'"'b'"'"'"; [ "$(printf %s $q)" = "$w" ] && echo OK'
echo "=== bash embedded-quote round-trip (the idiom) ==="
bash -c 'w="a'"'"'b"; [ "$(printf %s '"'"'a'"'"'b'"'"')" = "$w" ] && echo BASH_OK || echo BASH_FAIL'
echo "=== fish path-with-space round-trip (double-quote) ==="
fish -c 'test (printf %s "\"my file.txt\"") = "my file.txt"; and echo FISH_OK; or echo FISH_FAIL'
# Expected: BASH_OK + FISH_OK. If either FAILS, quote()'s output does NOT round-trip — fix the rule
# BEFORE relying on it in S4. (These are the two rules most likely to have a subtle escaping bug.)
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: `/tmp/s3_loadcheck.lua` prints `S3_LOAD_OK`, exit 0 (proves pure/dependency-free load
      under `-u NORC` + the headline cases); `luac -p` clean.
- [ ] Level 2: `tests/shell_accept_spec.lua` plenary run exits 0 (all current_shell_word cases +
      the full §17.15 quoting table per shell + never-throws + UTF-8 byte correctness).
- [ ] Level 2: `tests/shell_accept_smoke.lua` prints `SMOKE_PASS`, exit 0.
- [ ] Level 3 regression: `shell_spec.lua` + `shell_fish_spec.lua` + `completion_spec.lua` all exit 0.
- [ ] Level 3 (optional): `/tmp/pi_quote_fidelity.lua` prints `BASH_IDIOM_OK` (the idiom reproduces the word).
- [ ] Level 4: the bash + fish round-trip one-liners print `BASH_OK` + `FISH_OK`.
- [ ] No nvim command in this PRP pipes a heredoc into nvim stdin (AGENTS.md ⛔ HARD RULE); every
      nvim invocation is wrapped in `timeout`.

### Feature Validation
- [ ] `current_shell_word` computes `(word, start_byte)` byte-correctly for: plain words, leading/
      multiple whitespace, empty command, cursor-on-whitespace (empty word), single/double-quoted
      regions, escaped spaces, multibyte trailing words (UTF-8).
- [ ] `quote` produces the EXACT §17.15 table per shell: unchanged when no special char; `"…"` for
      fish on a space; `'…'` for bash/zsh on any POSIX special; the `'"'"'` idiom for embedded `'`;
      `"`/`$`/`\`/backtick UNTOUCHED inside bash single quotes.
- [ ] Both NEVER throw (non-string inputs → safe defaults; bad cursor clamped).
- [ ] `quote` accepts shell as PATH or basename; unknown basename → POSIX default.
- [ ] S3 is purely additive — NO shipped file edited (shell.lua/completion.lua/menu.lua/fish.lua).

### Code Quality Validation
- [ ] `accept.lua` follows the `fish.lua` module shape (`local M = {}` / `---` luadoc / `return M`)
      + the pure/never-throws/dependency-free discipline (no `vim.*`, no `require`).
- [ ] File placement: `lua/pi-bridge/shell/accept.lua`; tests FLAT in `tests/` (sibling convention).
- [ ] Anti-patterns avoided: no coords/UTF-16; no Lua pattern for the POSIX special set (byte scan);
      no `require("pi-bridge.shell")` (inline basename); no wrap-then-sed (gsub-then-wrap); no
      escaping `"`/`$` inside bash single quotes; no edits to shell_word_prefix (coexists).
- [ ] The §17.8 v1 limitations (line-continuations; unclosed quotes; escaped space) are documented
      in the `current_shell_word` doc-comment, not papered over.

### Documentation & Deployment
- [ ] Both functions have `---` luadoc blocks (input/output/contract/byte-domain/limitations/never-throws).
- [ ] Spec + smoke header comments include the exact run command (mirror `shell_fish_spec/smoke` headers).
- [ ] (Forward note for S4 / P2.M2.T4.S4: compose current_shell_word + quote + nvim_buf_set_text;
      cursor after the inserted text; re-trigger iff word ends in "/". The two pure fns make S4 thin.)
- [ ] (Forward note for P2.M3.T5 zsh/bash drivers: accept.quote is shell-agnostic — zsh/bash
      acceptance reuses the SAME quote() unchanged; no per-driver quoting.)

---

## Anti-Patterns to Avoid

- ❌ Don't use a Lua PATTERN for the POSIX special-char set (`word:find("[%s$\\...]")`) — the
  pattern-class escaping of `` ` ``/`"`/`\` is error-prone + a mis-escape silently drops a char.
  Use a BYTE SCAN over a lookup table (research §4; the fish.parse PLAIN-find discipline).
- ❌ Don't escape `"`/`$`/`\`/backtick INSIDE bash single quotes — single quotes are OPAQUE;
  those chars are literal inside them (neutralized for free). ONLY `'` gets the `'"'"'` idiom
  (research §7 decision 2). Escaping them is unnecessary AND wrong (it inserts a literal `\`).
- ❌ Don't wrap-then-sed for the embedded-`'` idiom (over-quotes) — gsub-THEN-wrap is correct
  (`"'" .. word:gsub("'", "'\"'\"'") .. "'"`). (LIVE-VERIFIED, research §3.)
- ❌ Don't treat fish like bash/zsh — fish's rule is SPACE-ONLY (double-quote; escape `\`+`"`).
  `$`/`;`/`|` etc. do NOT trigger quoting for fish (PRD §17.8 "fish has lighter rules").
- ❌ Don't route the shell path through coords / UTF-16 (§17.14 — BYTE-domain). `cursor` + `start_byte`
  are 0-based bytes; `nvim_win_get_cursor(0)[2]` is already 0-based byte; `nvim_buf_set_text` takes
  0-based byte cols. UTF-16-converting would corrupt multibyte words.
- ❌ Don't replace or modify `shell.shell_word_prefix` — it's the NAIVE quote-UNaware trailing word
  for menu DISPLAY; `current_shell_word` is the QUOTE-AWARE word for the EDIT. They COEXIST.
- ❌ Don't `require("pi-bridge.shell")` or any nvim API in accept.lua — it must be PURE +
  dependency-free (the fish.parse contract) so it loads under `-u NORC` + is trivially unit-testable.
  Inline the 2-line `basename` (don't reuse shell.lua's module-local one).
- ❌ Don't pre-wire S4 (no `M.accept` buffer-mutation fn, no completion.lua shell-routing edits).
  S3 ships ONLY the two pure functions + tests. Pre-wiring duplicates S4 + risks a half-built path.
- ❌ Don't gate the OFFLINE spec/smoke on `vim.fn.executable("fish"/"bash")` — the functions are
  pure; §17.15 requires the quoting table run with NO live shell. (The Level-3/4 LIVE fidelity
  checks are OPTIONAL, separate, and skip cleanly when a shell is absent.)
- ❌ Don't pipe a heredoc into `nvim`'s stdin (AGENTS.md ⛔ HARD RULE) — write test snippets to a
  FILE then `+"luafile <file>" +qa`, or use a one-line `-c 'lua …'`. ALWAYS wrap in `timeout`.

---

## Confidence Score: 9/10

One-pass success is very likely: the deliverable is two pure functions + two offline test files,
fully specified with a reference implementation, exact worked examples, the LIVE-VERIFIED
quoting reference table (fish double-quote-on-space; bash/zsh single-quote with the idiom; the
POSIX special set), and verified validation commands. The −1 reserves for the two genuinely
subtle edges the implementer must get byte-exact: (a) the bash single-quote-NEUTRALIZES-`"`
invariant (a `"` inside single quotes is a literal — the most common quoting bug, pinned by a
dedicated spec case + the Level-4 round-trip), and (b) the UTF-8 byte-safety of
`current_shell_word` on a multibyte trailing word (the `[%S]`-on-bytes reasoning — pinned by the
`日cmd` case). Both are covered by explicit spec cases + a live round-trip check, so a slip
surfaces as a failed assertion, not a silent buffer corruption.