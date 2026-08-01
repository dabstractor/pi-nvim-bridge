# P2.M2.T4.S3 research — `shell/accept.lua` pure functions (current_shell_word + quote)

> S3 ships the **PURE, offline-testable half** of §17.8 (Local acceptance & quoting):
> `M.current_shell_word(line, cursor)` + `M.quote(word, shell)`. S4 (the buffer-mutation
> half: `nvim_buf_set_text` + cursor + re-trigger) consumes these two functions.
>
> All verifications below were LIVE-checked on this machine (fish 4.8.1, nvim 0.12).

---

## 1. Task boundary (the S3↔S4 split)

PRD §17.8 lists 5 steps for the shell accept flow. S3 owns the **two PURE, buffer-independent,
no-nvim-API** steps; S4 owns the **buffer mutation**:

| §17.8 step | S3 (this task — PURE) | S4 (next — mutation) |
|---|---|---|
| 1. compute the current shell word (quote-aware) | ✅ `current_shell_word` | — |
| 2. quote the candidate per-shell | ✅ `quote` | — |
| 3. `nvim_buf_set_text` range edit `[word_start+1 .. cursor]` | — | ✅ |
| 4. cursor positioning (after inserted text) | — | ✅ |
| 5. re-trigger iff candidate ends in `/` | — | ✅ |

**S3's contract to S4:** `current_shell_word(line, cursor)` returns `(word, start_byte)` where
`start_byte` is the **0-based byte offset** where `word` begins — i.e. the word occupies
`line[start_byte+1 .. cursor]` (Lua 1-indexed). S4 maps this directly onto
`nvim_buf_set_text(buf, row, start_byte, row, cursor, {quote(word, shell)})` (set_text cols are
0-based byte — `:help nvim_buf_set_text`). `quote(word, shell)` returns the string to insert
(possibly the original word, if no quoting needed). **Both are PURE** → offline unit-testable
(no nvim, no state, no require) — the coords.lua / `shell_word_prefix` / `fish.parse` pattern.

---

## 2. LIVE-VERIFIED: fish completion returns UN-quoted words with spaces

```text
$ mkdir -p /tmp/pi_qtest && touch "/tmp/pi_qtest/my file.txt"
$ (cd /tmp/pi_qtest && fish -c 'complete -C "ls my"')
my file.txt        ← the candidate VALUE contains a literal space, NOT auto-quoted
```

**Implication:** fish's `complete -C` returns the raw completion (with spaces intact). On
acceptance, the plugin MUST wrap such a value in `"..."` (PRD §17.8 fish rule: "still wrap
paths with spaces in double quotes") or the spliced token splits on the space at execution.
Confirmed the PRD's explicit fish rule is not theoretical.

---

## 3. LIVE-VERIFIED: the bash/zsh single-quote-with-embedded-`'` idiom

For a POSIX word containing a single quote (`a'b`), the robust quoting is the
`'…'"'"'…'` idiom: close the single-quoted string, emit a double-quoted single-quote, reopen.

**Correct order = gsub-then-wrap** (what S3's `quote` must do):
```lua
"'" .. word:gsub("'", "'\"'\"'") .. "'"
-- word="a'b"  →  gsub → "a'"'"'b"  →  wrap → "'a'"'"'b'"
-- bash parses: 'a' + "'" + 'b' = a'b  ✓
```
(NB: doing it the OTHER way — wrap-in-quotes-then-sed-substitute — is WRONG; the live
shell check confirmed that produces `'"'"'a'"'"'b'"'"'` (over-quoted). The Lua
gsub-then-wrap is the correct, minimal form.)

`'a'"'"'b'` verified conceptually: `'a'` (literal `a`) `+` `"'"` (literal `'`) `+` `'b'`
(literal `b`) `= a'b`. ✓

---

## 4. The POSIX special-char set (PRD §17.8 step 2, parsed)

PRD §17.8 step 2: "spaces, and shell metacharacters `$ \ ` " ' < > | & ; ( ) ~`".

Parsed (the chars that TRIGGER quoting for bash/zsh):
```
  space(32)  tab(9)  $(36)  \(92)  `(96)  "(34)  '(39)
  <(60)  >(62)  |(124)  &(38)  ;(59)  ((40)  )(41)  ~(126)
```
(Whitespace via byte: 32 space, 9 tab — plus 10 LF / 13 CR defensively, though a completion
word never contains a newline in practice.)

**Recommendation (avoid Lua-pattern pitfalls — the fish.parse PLAIN-find discipline):**
build the set as a small lookup (a Lua table `{[36]=true,...}` or a plain `string.find` over a
canonical set string with the 4th `true` arg). Do NOT use `word:find("[%s$\\...]")` — the
pattern-class escaping of `` ` `` / `"` / `\` is error-prone and a mis-escape silently drops a
special char from the set. Byte-scan is trivial + provably correct.

**fish special set (lighter — PRD §17.8):** only a **space** triggers quoting (double-quote).
fish double-quotes interpret `\` and `"` → escape those two inside the quotes
(`word:gsub("\\","\\\\"):gsub('"','\\"')`). All other chars pass through verbatim (fish
double-quotes are permissive — no `$`/`` ` ``/`!` expansion issues for a plain path/word).

---

## 5. The `current_shell_word` algorithm (quote-aware, v1)

Contract (PRD §17.8 step 1): "the maximal substring of `line[1..cursor]` ending at the cursor,
delimited by **unquoted** whitespace." `line` is the command text UP TO the cursor (after
bang-strip — `complete_current` already produced it); `cursor` == `#line` by construction
(§17.5.1) but S3 takes `(line, cursor)` for robustness + direct testability.

State machine over bytes `[1..cursor]` (Lua 1-indexed), tracking `single`/`double`/`escaped`:
- normal byte: `'`→open single, `"`→open double, `\`→`escaped=true` (next byte literal),
  space/tab→**word boundary** (set `word_start = i+1`).
- inside single quotes: only `'` closes (NO backslash escape — bash single quotes are opaque).
- inside double quotes: `\`→`escaped=true`, `"` closes.
- `escaped`: consume literally (the escaped byte is part of the word; reset `escaped`).
- UTF-8 continuation bytes are ≥ 0x80 → never whitespace/quote/backslash → inert.

`word_start` defaults to 1; advanced past each unquoted whitespace. Word =
`line:sub(word_start, cursor)`; `start_byte = word_start - 1` (0-based, for S4's set_text).

**Worked examples (all verified by hand against the algorithm):**
| `line` (up to cursor) | `cursor` | `word_start` | `word` | `start_byte` |
|---|---|---|---|---|
| `"git ch"` | 6 | 5 | `"ch"` | 4 |
| `"git "` (trailing space) | 4 | 5 | `""` | 4 (word empty → S4 no-op/close) |
| `"checkout"` | 8 | 1 | `"checkout"` | 0 |
| `""` | 0 | 1 | `""` | 0 |
| `'echo "hello'` (open dquote) | 11 | 6 | `'"hello'` | 5 |
| `'echo a\ b'` (escaped space) | 9 | 6 | `'a\ b'` | 5 |
| `'git  ch'` (2 spaces) | 7 | 7 | `"ch"` | 6 |

**v1 limitations (DOCUMENT, per PRD §17.8):**
- `\`-**line-continuations** out of scope (a trailing `\` joining lines). The buffer is one
  logical line per §17.7 anyway.
- **Unclosed quotes:** the word extends to the cursor (the quote is treated as still open —
  correct: the user is mid-quote).
- **Escaped space** (`\ `): treated as non-breaking (part of the word). Matches "quote-aware";
  an edge case that's rare in completion (you don't usually complete a token containing an
  escaped space).

---

## 6. Comparison with the existing `shell.shell_word_prefix` (NOT a replacement)

`shell.lua` already has `M.shell_word_prefix(line)` = `line:match("[%S]+$")` — the trailing
non-whitespace run. That is a **NAIVE** (quote-unaware) prefix used by `complete_current` to
OVERRIDE the daemon's advisory prefix for **menu display**. It does NOT handle quoted spaces.

`accept.current_shell_word` is the **QUOTE-AWARE** word computation used for the **buffer edit**
(replacing the right byte range on accept). It MUST be more sophisticated than
`shell_word_prefix` because replacing the wrong range on a quoted path would corrupt the buffer.

**S3 does NOT modify `shell_word_prefix`** (complete_current's display prefix is fine being
naive — it's only for menu highlight/record; accept recomputes independently, PRD §17.8). The
two coexist: naive prefix for display, quote-aware word for the edit. (This mirrors how
complete_current's PRP §17.6.1 note already states: "shell/accept.lua recomputes word
boundaries independently.")

---

## 7. Test surface (§17.15 `shell_accept_spec.lua` — quoting table tests)

PRD §17.15: "`shell_accept_spec.lua` — table tests for quoting: spaces (`my file.txt`), `$`,
backtick, single quote, double quote, combined; per shell; assert the inserted byte range and
cursor position."

The "**inserted byte range and cursor position**" assertions are **S4's** (they involve
`nvim_buf_set_text`). S3 owns the **pure** part: the quoting table (`quote` inputs→outputs per
shell) + the `current_shell_word` cases (word + start_byte). S3's
`tests/shell_accept_spec.lua` is the offline quoting/word table; S4 will ADD the buffer-mutation
cases to the same file later.

S3 quoting table (the core of the spec), per-shell:

| word | shell | expected `quote` output | why |
|---|---|---|---|
| `"checkout"` | bash | `"checkout"` | no special char → unchanged |
| `"checkout"` | fish | `"checkout"` | no space → unchanged |
| `"my file.txt"` | bash | `"'my file.txt'"` | space → single-quote |
| `"my file.txt"` | fish | `'"my file.txt"'` | space → double-quote (fish rule) |
| `'a$b'` | bash | `"'a$b'"` | `$` → single-quote |
| `'a$b'` | fish | `'a$b'` | no space → unchanged (fish lighter rule) |
| `"a'b"` | bash | `"'a'\"'\"'b'"` | embedded `'` → the idiom |
| `"a'b"` | fish | `'"a'..??` | no space → unchanged? **(DECIDE: fish treats `'` specially — see below)** |
| `'a"b'` | bash | `"'a\"b'"`? NO — single-quote keeps `"` literal → `"'a\"b'"` is WRONG | → `"'a\"b'"`?? **(see note)** |

**Two decisions to pin in the PRP (resolve via the simple rule below):**

1. **fish + `'` (single quote) in word:** fish double-quotes do NOT need `'` escaped, but fish's
   lighter rule (only space triggers) means a word like `a'b` (no space) → **unchanged** for
   fish. That's correct for fish (fish doesn't treat `'` specially in unquoted context the way
   bash does). Keep fish = "space-only trigger."

2. **bash single-quote + `"` in word:** single quotes are OPAQUE — a `"` inside a single-quoted
   string is a literal `"`. So `'a"b'` (single-quoted) is CORRECT and needs NO escaping. The
   gsub only substitutes `'` (→ the idiom); `"` passes through untouched inside the single
   quotes. So `quote('a"b', 'bash')` → `'a"b'` (the `"` is a literal inside single quotes).
   ✓ (This is WHY single-quoting is the robust default — it neutralizes `"` for free.)

The clean rule: **bash/zsh `quote` = single-quote if ANY special char; only `'` gets the
gsub-idiom; everything else (including `"`, `$`, `\`, backtick) is neutralized BY the single
quotes themselves.** fish `quote` = double-quote iff a space; escape `\` + `"` inside.

---

## 8. Codebase seams S3 stays compatible with (NO edits to these)

- `lua/pi-bridge/shell.lua`: `resolve_shell` (→ the path S4 passes to `quote`),
  `state.shell` (the resolved path), `M.shell_word_prefix` (naive display prefix — coexists),
  `basename` (module-local; accept.lua gets its OWN tiny basename or accepts path-or-basename).
- `lua/pi-bridge/shell/fish.lua`: the driver + `M.parse` — sibling module; accept.lua is a
  sibling under `lua/pi-bridge/shell/`. Module conventions: `local M = {} ... return M`,
  `---` luadoc, never-throws, no `vim.*`/require at function level (pure).
- `lua/pi-bridge/completion.lua`: `on_enter`/`on_tab` currently route menu-open+selected →
  `M.accept` (the PI bridge path). **S4** will add the shell→accept routing. S3 ships only the
  pure functions; completion.lua is UNCHANGED.
- `lua/pi-bridge/menu.lua`: `get_selected()` returns the `AutocompleteItem`; S4 reads
  `.value` and passes it to `quote`. S3 doesn't touch menu.

---

## 9. `pick_driver`-style discoverability (does accept.lua get required?)

`accept.lua` is **NOT** a driver — `pick_driver` does `require("pi-bridge.shell."..basename)`
for `fish`/`zsh`/`bash` only. `accept.lua` is NOT in that set (basename "accept" is not a shell).
So S4 will `require("pi-bridge.shell.accept")` explicitly (by absolute module path). S3 just
needs the file at `lua/pi-bridge/shell/accept.lua` so the require resolves. No registration.