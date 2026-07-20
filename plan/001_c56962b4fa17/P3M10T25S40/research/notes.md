# Research Notes — P3.M10.T25.S40 (Configurable debounce, RPC timeout, stale-response supersession)

> Consolidated findings for the S40 PRP. All pi-source claims are **verified by direct read**
> of `~/projects/pi/packages/tui/src/components/editor.ts` + the in-tree
> `extension/pi-editor-bridge.ts`. Neovim claims cite stable `:help` topics. The external
> best-practices survey (nvim-cmp / blink.cmp / JSON-RPC timeouts) was run via a researcher
> subagent (output: `.pi-subagents/artifacts/a2f7df5d_researcher_0_output.md`).

---

## 1. THE GAP — pi's debounce is TRIGGER-AWARE; the plugin is FLAT (divergent)

pi's TUI does **not** apply a flat debounce. `Editor.getAutocompleteDebounceMs` (editor.ts:2214)
computes the window **per request** from the text before the cursor:

```ts
// editor.ts:2214 (VERIFIED)
private getAutocompleteDebounceMs(options: { force: boolean; explicitTab: boolean }): number {
    if (options.explicitTab || options.force) {
        return 0;                                     // Tab / force → IMMEDIATE
    }
    const currentLine = this.state.lines[this.state.cursorLine] || "";
    const textBeforeCursor = currentLine.slice(0, this.state.cursorCol);
    return this.autocompleteDebouncePattern.test(textBeforeCursor)
        ? ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS         // file/attachment ctx → 20ms
        : 0;                                          // slash / normal typing → IMMEDIATE
}
```

Constants (editor.ts:236-237, VERIFIED):
- `ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS = 20`  ← **NOT 25** (the plugin's current default).
- `DEFAULT_AUTOCOMPLETE_TRIGGER_CHARACTERS = ["@", "#"]`.

The "file/attachment context" detector (editor.ts:247, VERIFIED):
```ts
function buildDebouncePattern(triggerCharacters: string[]): RegExp {
    const escapedWithoutAt = triggerCharacters.filter((c) => c !== "@").map(escapeCharacterClass);
    return new RegExp(`(?:^|[ \\t])(?:@(?:"[^"]*|[^\\s]*)|[${escapedWithoutAt.join("")}][^\\s]*)$`);
}
// for ["@","#"] → /(?:^|[ \t])(?:@(?:"[^"]*|[^\s]*)|[#][^\s]*)$/
```

Decoded: the **last whitespace-delimited token before the cursor starts with `@` or `#`**
→ debounce 20ms. The `@` arm has a **special `@"..."` quoted-path-with-spaces case**
(`@(?:"[^"]*|[^\s]*)`) so typing inside an *unclosed* quoted mention (`@"src/my dir`) is also
debounced even though it contains spaces. Slash commands (`/model`) and plain text do **not**
match → **0ms (immediate)**.

**Plugin today (completion.lua):** a flat `debounce_ms()` (default 25) for *every* refresh —
slash, typing, AND `@`-context all get 25ms. This **diverges from the TUI** in three ways:
1. slash/typing: plugin 25ms vs pi **0ms** (the plugin adds a perceptible lag pi does not have).
2. `@`/`#` context: plugin 25ms vs pi **20ms** (a 5ms divergence + wrong default value).
3. the `@"..."` quoted-path case is not detected at all (plugin treats `@"src/my dir` as
   non-file because the last token is `dir`).

PRD §1 (Goals): *"Completion behavior in Neovim is **byte-for-byte identical** to pi's TUI,
because the same live provider produces and applies the suggestions."* Timing is part of
behavior. **S40 closes this gap** — this is exactly "Timing refinement — debounce … tuning".

> **PRD §5.5 wording is misleading.** It says "default 25 ms for slash/path; 0 ms extra for `@`".
> The verified pi source is the *opposite* (slash=0, `@`=20). The PRD §5.5 sentence was a design
> sketch; editor.ts:2214 is the truth. S40 follows the source (the codebase's "supersede PRD with
> verified pi source" pattern — exactly what coords.lua did to PRD §7.4's `bytecol-1`).

---

## 2. `vim.defer_fn(fn, 0)` is async, cancellable, and collapses N→1 (VERIFIED)

- `vim.defer_fn` creates a libuv one-shot `uv_timer_t`, fires on the **next event-loop
  iteration**, then wraps `fn` in `vim.schedule`. `:help vim.defer_fn`, `:help vim.loop`.
  So `defer_fn(fn, 0)` is **NOT synchronous** — it still defers to the loop (≈1-2ms).
- It returns the timer handle → cancellable via `:stop()` / `:close()` (guard `:is_closing()`).
- **Collapse proof:** N rapid synchronous `cancel_timer()` → `defer_fn(fn, <any-ms>)` calls
  (including `0`) collapse to **exactly ONE** callback. All N run in one event-loop iteration;
  each stops the previous timer before it fires; only the last survives. **The cancel path —
  NOT the timeout duration — is what collapses rapid refreshes.**

**Implication for existing tests (NON-REGRESSION):** `completion_spec.lua` test (2) issues 3
rapid `refresh("/mod")` and asserts `#fake.requests == 1`. With the trigger-aware model `/mod`
is slash → 0ms. `defer_fn(fn, 0)` still collapses the 3 calls → still **1 request**. ✓ Test (2)
survives unchanged. Same for test (3). The **only** hard assertion change is `init_spec.lua:17`
(`defaults.debounce_ms 25 → 20`).

> pi calls `startAutocompleteRequest` **directly** when `debounceMs === 0` (editor.ts:2155, no
> `setTimeout`). The plugin keeps `defer_fn(fn, 0)` because the free coalescing of rapid
> TextChangedI+CursorMovedI pairs is desirable (the plugin's [Mode A] header already relies on
> it) and the ~1ms cost is imperceptible.

---

## 3. Porting `buildDebouncePattern` to Lua — TWO options (both VERIFIED viable)

Lua patterns (`:help lua-pattern`) have **NO `|` alternation** and **NO `(?:...)` non-capturing
groups**, so the JS regex cannot be a single Lua pattern. Two faithful ports:

### Option A — explicit Lua logic (RECOMMENDED; matches coords.lua style)
Pure logic, trivially unit-testable per case, no regex-dialect risk. Handles the `@"..."`
quoted-path case by scanning for an **unclosed** `@"`:

```lua
-- Mirror pi buildDebouncePattern(["@","#"]): the last whitespace-delimited token before the
-- cursor starts with '@' or '#' (with the '@"..." quoted-path special case). Lua has no '|',
-- so this is explicit logic (not a single pattern). Pure + directly unit-testable.
---@param text_before_cursor string  the substring of the cursor line from col 0 to the cursor.
---@return boolean is_attachment true iff pi would debounce here (attachment/file context).
local function is_attachment_context(text_before_cursor)
  local t = text_before_cursor or ""
  if t == "" then return false end
  -- (1) UNCLOSED @"...  quoted-path-with-spaces case (pi @(?:"[^"]*|...)).
  --     Find the last '@"' ; if the run of chars after it has an ODD number of '"' it is
  --     unclosed → we are inside a quoted mention → attachment context.
  local atq = t:reverse():find('"@', 1, true)   -- last '@"' (plain search on reversed str)
  if atq then
    local after = t:sub(#t - atq + 2)           -- chars after the last '@"'
    local _, nq = after:gsub('"', '"')
    if nq % 2 == 1 then return true end          -- odd quotes after '@"' → inside quote
  end
  -- (2) PLAIN token: trailing non-whitespace run starts with '@' or '#'.
  local last = t:match("[%S]+$") or ""
  if last ~= "" then
    local c = last:sub(1, 1)
    if c == "@" or c == "#" then return true end
  end
  return false
end
```

Case table (verified against the JS regex semantics):
| text-before-cursor | last token | match? | why |
|---|---|---|---|
| `@src/comp` | `@src/comp` | ✅ | starts `@` |
| `#tag` | `#tag` | ✅ | starts `#` |
| `@"my dir` | (unclosed `@"`) | ✅ | quoted-path arm |
| `/model` | `/model` | ❌ | starts `/` (slash = 0ms) |
| `hello world` | `world` | ❌ | plain text |
| `foo@bar` | `foo@bar` | ❌ | `@` mid-token (not at boundary) |
| `` (empty) | — | ❌ | nothing |

### Option B — `vim.regex` (built-in nvim regex engine; `:help vim.regex()`)
A 1:1 port, but in **vim "magic" dialect** (error-prone to review):
```lua
local RE = vim.regex([[\%(^\|[ \t]\)\(@\("[^"]*\|[^ \t]*\)\|#[ \t]*\)$]])  -- compile ONCE
-- NOTE: use [^ \t] NOT [^\s] (\s inside [] is unreliable in this nvim build).
local function is_attachment_context(t) return RE:match_str(t or "") ~= nil end
```
Gotchas: vim regex uses `\%(...\)` for non-capturing, `\|` for alternation; `\s` inside `[...]`
is unreliable → use `[^ \t]` or `[^[:space:]]`; compile ONCE at module level (compile cost is
non-trivial); `:match_str` returns a byte offset or `nil`.

**Recommendation for THIS codebase:** **Option A** (explicit Lua). Rationale: coords.lua is the
established model — pure, explicit, exhaustively unit-tested helpers. A vim.regex string is a
cryptic "magic incantation" hard to review; the explicit logic is trivially testable per case
(mirrors `coords_spec.lua`'s round-trip table). The PRP specifies Option A in full + lists
Option B as a documented alternative.

---

## 4. Config shape — keep `debounce_ms` (additive), retune default 25 → 20

`debounce_ms` (int) is already a public config key (init.lua `M.defaults`) + already user-
overridable via `setup({})`. The trigger-aware model **reinterprets** it (no breaking shape
change):

- `debounce_ms` = **the file/attachment-context window** (default **20** = pi's
  `ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS`). Slash commands + plain typing use **0ms (immediate)**,
  matching pi's TUI (NOT separately configurable — pi hardcodes 0).
- This is the **minimal-churn + backward-compatible + pi-faithful** choice. The only hard test
  change is `init_spec.lua:17` (and the two "defaults pristine" echoes at init_spec.lua:66/76):
  `25 → 20`.

**Considered + rejected:** a table config `debounce = { default_ms = 0, attachment_ms = 20 }`.
Rejected because (a) it BREAKS the existing public `debounce_ms` key + 6 `init_spec` assertions
(against the codebase's additive discipline — every prior task was non-breaking), and (b)
`default_ms` would always be 0 (pi-faithful) so the key is dead weight. The flat `debounce_ms`
reinterpreted as "the attachment window" is cleaner.

**Validation/clamp (additive, optional):** the existing `debounce_ms()` local in completion.lua
already falls back to 25 when the value is non-number/`<0`. S40 updates the fallback to **20**
and adds a one-line `math.max(0, math.floor(ms))` clamp so a fractional/negative user value
degrades sanely (mirrors the defensive-read discipline in bridge.lua's `rpc_timeout_ms` lookup).

---

## 5. RPC timeout — ALREADY configurable + ALREADY correct (2000 > 1500)

- Client per-request + handshake timeout: `rpc_timeout_ms` (default **2000**), read defensively
  in bridge.lua `M.handshake` + `M.request` (`((cfg.config or cfg.defaults or {}).rpc_timeout_ms) or 2000`).
- Server `fd`-abort: `GET_SUGGESTIONS_TIMEOUT_MS = 1500` (extension/pi-editor-bridge.ts:289,
  VERIFIED) — the extension arms a `setTimeout(1500, () => ac.abort())` per `getSuggestions`
  because pi's provider has NO internal fd timeout.
- **Invariant (VERIFIED correct):** client 2000 **>** server 1500 (33% headroom). If the client
  timeout were **<** the server abort, the client would abandon first while the server's `fd`
  scan keeps running (orphaned work, wasted CPU). With client > server, the server aborts at
  1500ms, returns, and the client receives it inside its 2000ms window. **Timeouts cascade
  outward.** (LSP/JSON-RPC best practice: client timeout ≈ server-worst-case × 1.2-1.5.)

**S40's timeout contribution (DOCUMENT, do not re-engineer):** the value is already configurable
+ already correct. S40 (a) documents the `2000 > 1500` invariant in the `rpc_timeout_ms` type
annotation + bridge.lua header, (b) optionally adds a **setup-time guard**: if a user sets
`rpc_timeout_ms <= 1500`, emit a single WARN via the S39 `notify.lua` ("rpc_timeout_ms below the
bridge fd-abort (1500ms) — @file searches may be cut off client-side"). This is a one-liner,
additive, and protects the invariant. (A hard `error` is wrong — setup must never throw.)

> NOTE on a *separate* handshake timeout: pi's `hello` is a fast in-process call; a handshake
> should resolve in tens of ms. Giving it the same 2000ms as a slow `fd` `getSuggestions` is
> generous but harmless. A distinct `handshake_timeout_ms` (e.g. 1000) is a *possible* future
> refinement but is **out of scope** for S40 — keep one knob (`rpc_timeout_ms`) to match the
> PRD §10.5 config surface. The PRP notes it as a non-goal.

---

## 6. Stale-response supersession — ALREADY correct (two-layer); S40 EXTENDS tests

The two-layer supersession (LIVE-VERIFIED nvim-cmp/blink.cmp pattern) is COMPLETE in
completion.lua (S30):
- **Layer 1 (optimization):** `bridge.cancel(state.inflight_id)` when a newer refresh fires
  while a request is in-flight.
- **Layer 2 (correctness):** a generation-id guard in the callback — `if gen ~= state.gen then
  return end`.

The gen-guard is **trigger-agnostic** (it keys on a monotonic int, not the trigger char), so the
trigger-aware debounce does NOT weaken it: a fast-typed `@src/a` → `@src/ab` still bumps `gen`
per fetch and drops the stale `@src/a` result. `force_fetch` (S33, the 0-debounce Tab path)
SHARES `state.gen`/`state.inflight_id`/`state.debounce_timer`, so refresh↔Tab supersession is
already correct.

**S40's supersession contribution (TEST, do not re-engineer):** EXTEND `completion_spec.lua`
with file-context supersession cases — confirm a stale `@`-context result is dropped at the
gen-guard when the user keeps typing in a file context (the regression that would arise if the
debounce window change ever desynchronized the gen bump). No core supersession code change.

---

## 7. Test impact summary (for the PRP's non-regression section)

| File | Change | Why |
|---|---|---|
| `plugin/lua/pi-editor/init.lua` | `M.defaults.debounce_ms` 25 → **20**; `---@field debounce_ms` doc: "file/attachment-context window; slash/typing use 0ms (pi-faithful)". | Retune to pi's `ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS`. |
| `plugin/lua/pi-editor/completion.lua` | ADD `M.is_attachment_context(text)` (pure, exported for tests) + `compute_debounce(lines, cursorLine, cursorCol)`; `M.refresh` reads the cursor line + computes the window (0 / `debounce_ms`) before `vim.defer_fn`. | The trigger-aware debounce (the core gap). |
| `plugin/tests/init_spec.lua` | lines 17, 66, 76: `25 → 20`; ADD a doc-string assertion that slash/typing use 0ms. | Default retune. |
| `plugin/tests/completion_spec.lua` | NEW describe block "S40 trigger-aware debounce": (a) `@src/` uses the attachment window; (b) `/mod` uses 0ms (collapse still → 1 req); (c) `@"quoted path` detected; (d) mid-word `foo@bar` NOT detected; (e) file-context stale-result supersession at the gen-guard. ADD direct `is_attachment_context` unit cases (the §3 table). | Cover the new logic. |
| `plugin/tests/completion_smoke.lua` | ADD a file-context fetch case (buffer `@sr`, refresh, fake server receives a `getSuggestions`). | Light end-to-end of the trigger path. |

**Unchanged (verified non-regressed):** `bridge.lua` (timeout already correct), `coords.lua`,
`menu.lua`, the ftplugin, all bridge/handshake/notify/menu/coords specs. The 6 keymaps (Tab/CR/
nav/dismiss) are untouched. completion_spec tests (2)/(3) (slash `/mod`) still pass — collapse
is via `cancel_timer`, which works at 0ms (§2).

---

## 8. Validation commands (THIS repo — per AGENTS.md; NEVER pipe heredoc into nvim stdin)

- Plenary spec (from `plugin/`):
  `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'`
  (and `tests/init_spec.lua`).
- Smoke (plenary-free, from `plugin/`):
  `timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_smoke.lua" +qa`
- TypeScript extension tests (if touched — S40 does NOT touch the extension): out of scope.

---

## 9. Open questions / risks

- **Multibyte + the `reverse():find('"@')` trick (Option A):** reversing a UTF-8 string slices
  mid-byte. BUT the search target `"@` is pure ASCII (2 bytes), and `string.find(..., true)`
  (plain search) matches byte sequences — an ASCII 2-byte needle in a reversed UTF-8 haystack
  still matches only at real `"`+`@` byte boundaries (a mid-byte slice cannot form `"@`). Safe,
  but the PRP's unit cases must include a multibyte-before-`@"` case (e.g. `日@"x`) to prove it.
  (If review is uneasy, the alternative is a forward scan counting `"` parity after each `@"` —
  equally simple; the PRP offers the forward-scan as the canonical form to avoid the reverse
  question entirely.)
- **`engine = "blink"|"cmp"` (P4):** the trigger-aware debounce lives in `completion.lua`
  (the builtin engine). The optional blink/cmp sources (P4.M12) drive the bridge directly and
  will need their OWN debounce (or reuse `is_attachment_context`). Out of scope for S40 —
  noted as a forward contract.