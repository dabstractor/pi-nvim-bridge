# PRP — P2.M2.T3.S3: `shell.complete_current(buf, cb)` — buffer→daemon bridge

**Parent:** P2.M2.T3 (completion.lua routing + shell.complete_current + notices)
**Component:** B (`pi-bridge.nvim`) — `lua/pi-bridge/shell.lua`
**PRD anchor:** §17.7 *Routing in the plugin* (the `shell.complete_current(buf, cb)` call), §17.5.1 *Framing protocol* (`line`/`cursor`/`after`), §17.14 *Coordinate & encoding notes (shell path)* (BYTE offsets — NOT UTF-16), §17.4.3/§17.9/§17.12 (NOT this task — S4)
**Size:** 1 pt — the **buffer→daemon** adapter that S2's routing consumes.
**Builds on:** P2.M1.T2.S4 (COMPLETE — `M.request(line, cursor, after, cb)` + `_test_invoke_pending` seam), P2.M2.T3.S1 (COMPLETE — `completion_context` returns `"shell"`), P2.M2.T3.S2 (COMPLETE — `do_shell_fetch` forward-guards + calls `shell.complete_current(buf, cb)`).

---

## Goal

**Feature Goal:** Implement `M.complete_current(buf, cb)` on `shell.lua` — the function S2's `do_shell_fetch` already calls (forward-guarded). It reads the pi-prompt buffer line 1 + the nvim cursor, strips the leading `!`/`!!` bangs, computes the BYTE-domain `line`/`cursor`/`after` triple (§17.14 — NO UTF-16/`coords` conversion), short-circuits on an empty command (§17 — don't spawn the daemon for a bare `!`), derives the completion `prefix` client-side (§17.6.1 — the daemon's prefix is advisory/ignored in v1), and delegates to the shipped `M.request(line, cursor, after, cb)`, forwarding its `(err, items, prefix)` result. The moment this lands, S2's forward-guard flips from silent-no-op to live and `!`/`!!` lines drive the shell-completion daemon end-to-end (modulo the drivers, P2.M2.T4).

**Deliverable:** Edited `lua/pi-bridge/shell.lua`:
1. A new public function **`M.complete_current(buf, cb)`** placed in the public-API section (after `M.teardown`, before the `_test_` seams, OR beside `M.request` — see Task 1 for placement). It: validates `buf`/`cb`; reads line 1 + cursor on the **main loop** (api-safe at call time); computes the bang-strip + byte offsets (VERIFIED math below); short-circuits an empty command to `cb(nil, {}, "")`; calls `M.request(line, cursor, after, wrapper_cb)` whose `wrapper_cb` runs in **libuv fast context** (M.request's `pending_cb` fires it) → does pure string math only (derives `prefix`, ignores the daemon prefix) → forwards `cb(nil, items, prefix)` / `cb(err)`. NEVER throws; pcall-wraps every `nvim.api`/`M.request` call.
2. A small pure helper **`shell_word_prefix(line)`** (the trailing non-whitespace run of `line` — §17.6.1 "last whitespace-delimited token of `line[1..cursor]`"). Exported as **`M.shell_word_prefix`** for direct unit testing (mirrors `completion.lua`'s `M.is_attachment_context` / `M.completion_context` pure-tested-export pattern).
3. New plenary spec **`tests/shell_complete_current_spec.lua`** — reuses the `fake_bridge` + `inject_fake_driver` + `make_fake_stdin` + `_test_invoke_pending` harness from `tests/shell_request_spec.lua`; sets up a REAL buffer + cursor (the `completion_spec.lua:105/109` pattern); asserts the EXACT wire frame + the cb shape + every edge case.
4. New plenary-free smoke **`tests/shell_complete_current_smoke.lua`** — load + one basic call against a fake daemon (no subprocess); the file-based Level-1 gate.

**Success Definition:**
- A buffer `{"!git ch"}` with cursor at byte col 7 (end): `complete_current(buf, cb)` writes the frame `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n` to the daemon stdin (asserted via the fake stdin's `.written[1]`) — EXACTLY the §17.5.1 example + the `shell_fish_spike.lua` wire shape.
- A `!!git ch` buffer (double bang) produces the SAME frame (bang-count strip is the only `!`/`!!` difference).
- `complete_current` calls `M.request` with `line`/`cursor`/`after` derived from BYTE offsets — it NEVER calls `coords.nvim_to_pi_coords` / `vim.str_utfindex` (§17.14; the shell path is byte-domain).
- The cb fires `cb(nil, items, prefix)` where `prefix` is the CLIENT-derived trailing word (e.g. `"ch"` for `line="git ch"`), NOT whatever the daemon returned (override — §17.6.1 / research §6).
- A bare `!` (empty command) → `cb(nil, {}, "")` fires immediately and the daemon is NEVER spawned (`M.request`/`M.ensure` NOT called — assert `state.proc` stays nil + zero frames written).
- A `!`/`!!` cursor positioned ON the bangs (byte_col < bang count) → clamped to `cursor=0`, `line=""`, `after=<full cmd>`; no throw (the `math.max(0, …)` clamp).
- `M.request` returns `err` (e.g. `"daemon disabled"`, `"write failed"`) → `cb(err)` forwarded; the wrapper cb does NOT derive prefix / call `cb(nil,…)` on the err path.
- `complete_current` NEVER throws on bad args (`buf` invalid/nil, `cb` non-function, `nvim_buf_get_lines` pcall-fail) — degrades to `cb("…")` or a guarded no-op.
- `tests/shell_complete_current_spec.lua` plenary run is green; `tests/shell_request_spec.lua` + `tests/completion_spec.lua` + `tests/shell_spec.lua` STILL green (no regression — additive only).

---

## User Persona

**Target User:** A pi user editing a prompt in the Neovim external editor (`Ctrl+G`) who types a `!`/`!!` line to run a shell command.

**Use Case:** The user types `!git ch` and — once the P2.M2.T4 fish/zsh/bash drivers land — gets their real shell's completions (`checkout`, `cherry`, …) in the floating menu. **S3 alone** does not yet render shell completions (no driver is built), but it is the LAST routing-layer piece: with S3, `complete_current` is live and a fake/injected driver produces real items end-to-end through the menu. S3 + a driver = visible shell completion; S3 without a driver = the daemon fails to spawn (no driver → `M.ensure` sets `state.failed`) → S2's silent-degrade path (S4's one-time notify).

**Pain Points Addressed:** Today (S1+S2 shipped, S3 not) `do_shell_fetch` forward-guards `complete_current` and is a **silent no-op** for `!` lines — no completion, no error, no daemon. S3 makes the seam live so the daemon path is exercisable; it removes the last "routing works but goes nowhere" gap before the drivers.

---

## Why

- **Business value:** The buffer→daemon adapter half of the §17 shell-completion seam. S2 wired the *routing* (`ctx=="shell"` → `complete_current`); S3 supplies the *body* — the function that actually reads the buffer, speaks the §17.14 byte-domain coordinate contract, and hands a well-formed §17.5.1 frame to `M.request`.
- **Integration with existing features:** Additive — one new function + one pure helper on `shell.lua`, plus tests. `M.request` (S4), `M.ensure` (S3 of P2.M1.T2), and `_feed` (S5) are all shipped and unchanged. completion.lua (S2) is unchanged (its forward-guard auto-activates). The bridge path (slash/path/plain) is untouched.
- **Problems this solves, for whom:** Establishes the deterministic, byte-correct translation from "what the user typed in the nvim buffer" to "the §17.5.1 frame the daemon expects", including the `!`/`!!` strip, the empty-command guard, and the client-side prefix. Centralizes the shell-path coordinate math in ONE function so the (forthcoming) drivers + accept logic can rely on it.

---

## What

### User-visible behavior
**None yet in S3 in isolation** (no driver — P2.M2.T4 — is built; with `prefer:"pi"` + no driver, `M.ensure` fails → S2's silent degrade). S3 changes only *internal* wiring: `complete_current` goes from undefined to a live, tested function. Visible shell completion arrives when a driver lands. Document this so the implementer does not over-build into S4 (notices) / P2.M2.T4 (drivers + accept) / S5 (menu `$` gutter).

### Technical requirements
1. **`M.complete_current(buf, cb)`** reads line 1 + cursor on the main loop, computes `line`/`cursor`/`after` in the BYTE domain (§17.14 — NO `coords`), and calls the shipped `M.request(line, cursor, after, wrapper_cb)`.
2. **Bang strip (§17.7):** `!!` → strip 2, else `!` → strip 1 (check `!!` FIRST). Both route identically; bang-count is the only difference.
3. **Byte offsets (§17.14):** `cursor` = 0-based BYTE offset into `line` (== `#line` by construction since `line` is "up to cursor"). Derived directly from `nvim_win_get_cursor(0)[2]` (already 0-based byte — coords.lua header "CURSOR-API COL IS 0-BASED BYTE"). NO `coords.byte_to_utf16` / `vim.str_utfindex`. Clamp `cursor` to `≥ 0` (a cursor on the bangs → 0).
4. **Empty-command guard (§17 edge case):** a wholly-empty/whitespace-only command (bare `!`, `!   `) → `cb(nil, {}, "")` WITHOUT calling `M.request` (don't cold-start the daemon for a bare bang). `!git ` (trailing space) is NOT empty → queries.
5. **Client-side prefix (§17.6.1, research §6):** the `wrapper_cb` DERIVES `prefix = shell_word_prefix(line)` (trailing non-whitespace run) and OVERRIDES the daemon's prefix field (advisory/ignored in v1). The daemon's `prefix` arg to the cb is discarded.
6. **Fast-context safety:** `wrapper_cb` runs in libuv fast context (M.request's `pending_cb`, fired by `_feed`/timer — shell.lua:642/650). It does PURE string math only (`shell_word_prefix`) + forwards to `cb`. NO `vim.api.*` in `wrapper_cb` (the consumer `do_shell_fetch` already `vim.schedule`s the menu hop — do NOT duplicate). `state.last_result` writes are the consumer's job, NOT complete_current's.
7. **Supersession:** complete_current does NOT add its own gen guard. Two layers already bookend it: completion.lua's `state.gen` (do_shell_fetch) above, shell.lua's `state.gen` (M.request) below. complete_current just forwards. (Adding a third would be redundant.)
8. **NEVER throws** (per-keystroke + autocmd contract): pcall every `nvim.api.*` + `M.request`; type-guard `buf`/`cb`; `nvim_buf_is_valid` guard; bad args → `cb(err)` or guarded no-op.
9. **Scope fence:** NO edits to completion.lua, menu.lua, accept paths, ftplugin, notices (S4), health, drivers (P2.M2.T4). NO spawn/read of the daemon from complete_current — `M.request`/`M.ensure` own that.

### Success Criteria
- [ ] `M.complete_current(buf, cb)` implemented on `shell.lua` (bang strip + byte offsets + empty-cmd guard + client prefix + M.request delegation + fast-safe wrapper_cb).
- [ ] `M.shell_word_prefix(line)` pure helper exported (directly unit-testable; mirrors `completion.M.is_attachment_context`).
- [ ] `!git ch` (cursor end) → frame `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n` (EXACT wire shape; §17.5.1 + fish spike).
- [ ] `!!git ch` → SAME frame (double-bang strip).
- [ ] Bare `!` → `cb(nil,{},")` immediate; daemon NOT spawned (`state.proc` nil; 0 frames).
- [ ] Cursor on bangs → clamped (`cursor=0`, `line=""`); no throw.
- [ ] Daemon `err` → `cb(err)` forwarded; `cb(nil,…)` NOT called on the err path.
- [ ] `cb` receives the CLIENT-derived prefix (`"ch"` for `line="git ch"`), NOT the daemon's.
- [ ] Multibyte line (e.g. `!日cmd`) → frame `cursor` == the BYTE length of the command (NOT the UTF-16 length); proves no coords/UTF-16 conversion (§17.14).
- [ ] Never throws on bad args (`buf` nil/invalid, `cb` nil/non-function, nvim pcall-fail).
- [ ] `tests/shell_complete_current_spec.lua` green; `shell_request_spec.lua` + `completion_spec.lua` + `shell_spec.lua` still green.

---

## All Needed Context

### Context Completeness Check
A reader who knows nothing of this repo can implement S3 from: this PRP + the cited `shell.lua` regions (`M.request` L~600-700, the `state` literal, the `_test_` seams) + `completion.lua:386-447` (`do_shell_fetch` — the exact caller) + PRD §17.7/§17.5.1/§17.14 (quoted inline) + the VERIFIED byte math below. No daemon-internals knowledge beyond "M.request takes (line, cursor, after, cb) and resolves cb(err, items, prefix) in fast context" is required.

### Documentation & References

```yaml
# MUST READ — the spec that defines this exact function + the frame + the byte contract
- url: PRD.md §17.7 "Routing in the plugin (completion.lua extension)"
  why: |
    names `shell.complete_current(buf, cb)` + states verbatim: "reads the buffer + cursor, strips the
    bangs, computes line/cursor/after, and calls shell.request(...)". Gives the `!`/`!!` strip rule
    ("strip 2 if line1 starts with !!, else 1") + line-1-only scoping.
  critical: |
    the `!` vs `!!` distinction is IRRELEVANT to completion — both route to "shell"; only the bang-COUNT
    stripped differs. Completion is scoped to line 1 (completion_context already gates cursorLine==0).
- url: PRD.md §17.5.1 "Framing protocol (transport-agnostic)"
  why: |
    defines the EXACT request payload complete_current must build: `{"line":..,"cursor":..,"after":..}`
    where `line` = command text after stripping `!`/`!!` UP TO THE CURSOR (UTF-8), `cursor` = 0-based BYTE
    offset into `line`, `after` = text after the cursor. Gives the worked example `{"line":"git ch","cursor":6}`.
  critical: |
    `line` is "up to the cursor" ⇒ `cursor == #line` by construction. `after` lets drivers that need the
    FULL line (zsh BUFFER/CURSOR, bash COMP_LINE/COMP_POINT) reconstruct it as `line .. after`. The frame
    is `__PIREQ__\t{json}\n` — M.request ALREADY builds + writes this; complete_current only supplies the 3 args.
- url: PRD.md §17.14 "Coordinate & encoding notes (shell path)"
  why: |
    the shell path does NOT use pi's UTF-16 cursor contract. "cursor sent in the request is a BYTE offset
    into the UTF-8 line — directly from vim.fn.col('.') semantics (no coords.lua conversion needed)."
  critical: |
    DO NOT call coords.nvim_to_pi_coords / coords.byte_to_utf16 / vim.str_utfindex for the shell path.
    nvim_win_get_cursor(0)[2] is ALREADY a 0-based byte offset — use it (minus the bang count) directly.
    Contrast §8 (the pi bridge path), which IS UTF-16. This asymmetry is the #1 correctness trap.
- url: PRD.md §17.6.1 "fish — Tier 1" (the prefix note) + §17.8 "Local acceptance & quoting"
  why: |
    §17.6.1: "The current word being completed (for prefix) is derivable client-side (last whitespace-
    delimited token of line[1..cursor]), so no extra round-trip." §17.8: shell accept uses its OWN
    word-boundary computation (shell/accept.lua, P2.M2.T4) — NOT pi's applyCompletion.
  critical: |
    the daemon's prefix field is advisory; complete_current DERIVES prefix client-side (research §6 —
    Option A: override). The prefix complete_current passes to cb is for menu display/record; accept
    recomputes boundaries independently, so a deterministic client prefix is correct + sufficient.
- url: PRD.md §11 "Edge Cases" + §17.1 (the empty-command line)
  why: "`!` with an empty command does not spawn the daemon (no completion until a word exists)."
  critical: short-circuit a wholly-empty/whitespace command to cb(nil,{},") WITHOUT calling M.request
            (avoids a cold-start daemon spawn on a bare bang). `!git ` (trailing space) is NOT empty → query.

# Codebase files to follow EXACTLY
- file: lua/pi-bridge/shell.lua
  why: the file being edited; M.request (the delegate) + state + the _test_ seams live here
  pattern: |
    M.request(line, cursor, after, cb) (L~600): ensure→supersede(gen)→encode→timer→write(cb). Resolves
      cb(err) on ensure/encode/write/timer-fail; cb(nil, items, prefix) on response/timeout(empty).
      The cb fires in libuv FAST context (pending_cb ← _feed's read_start cb OR the timer cb).
    _test_invoke_pending(items, prefix) (the test seam): invokes state.pending_cb — deliver a response
      in tests AS _feed will in prod. complete_current's wrapper_cb is what this fires (via M.request's
      pending_cb → wrapper_cb → user cb).
    M.ensure / M.reset / state.failed: complete_current does NOT touch these directly; M.request does.
  gotcha: |
    complete_current is ADDED to this module (M.complete_current = ...). It calls the module-local
    M.request DIRECTLY (no require). DO NOT re-implement framing/supersession/spawn — M.request owns all
    of that. complete_current is a THIN adapter: buffer → 3 args → M.request → forward cb.
- file: lua/pi-bridge/completion.lua   (READ-ONLY — the caller; NOT edited by S3)
  why: |
    confirms the EXACT call shape (L428) + the cb signature + the fast-context contract S3 must satisfy.
  pattern: |
    -- completion.lua:428 (do_shell_fetch, S2, COMPLETE):
    pcall(shell.complete_current, buf, function(err, items, prefix)
      -- ⚠ FAST CONTEXT. do_shell_fetch owns the gen-guard + state.last_result + vim.schedule(on_results).
      if gen ~= state.gen then return end
      if err then ...; return end
      state.last_result = { items = its, prefix = pfx }
      vim.schedule(function() pcall(M.on_results, buf, its, pfx) end)
    end)
  gotcha: |
    do_shell_fetch already wraps the call in pcall + checks gen + schedules the menu hop. complete_current
    must NOT duplicate any of that. Its wrapper_cb (passed to M.request) runs fast → pure string math +
    forward only. The user cb (do_shell_fetch's) is the one that touches completion state.
- file: lua/pi-bridge/coords.lua   (READ-ONLY — what NOT to call)
  why: confirms the shell path must NOT route through it (§17.14 byte-domain vs §8 UTF-16)
  pattern: nvim_to_pi_coords is for the BRIDGE (getSuggestions) path only.
  gotcha: calling coords.byte_to_utf16 / nvim_to_pi_coords in complete_current is an Anti-Pattern — it
          would UTF-16-convert a byte-domain offset and corrupt the frame's `cursor` for multibyte text.
- file: tests/shell_request_spec.lua   (the test-harness TEMPLATE — copy its fakes)
  why: |
    the established fake-daemon pattern: fake_bridge(shell_path) + inject_fake_driver(fake_stdin) +
    make_fake_stdin() (captures .written frames) + _test_invoke_pending (deliver a response) +
    count_open_timers() (no-leak assert). complete_current's spec reuses ALL of these verbatim.
  pattern: |
    -- wire a fake "fish" daemon WITHOUT a subprocess:
    pi.bridge = fake_bridge("/usr/bin/fish"); local stdin = make_fake_stdin(); inject_fake_driver(stdin)
    shell.ensure(function() end)        -- cache the fake proc/stdin into state
    shell.complete_current(buf, cb)     -- writes the frame to stdin.written[1]
    shell._test_invoke_pending(items, prefix)   -- deliver the daemon's response → cb fires
  gotcha: |
    the driver is injected via package.loaded["pi-bridge.shell.fish"] (M.pick_driver requires it by
    basename). Reset MUST clear it in after_each (shell.reset() + package.loaded[...] = nil) so cases
    don't leak. buf setup uses nvim_buf_set_lines + nvim_win_set_cursor (completion_spec.lua:105/109).
- file: tests/completion_spec.lua   (the buffer-setup pattern + the S2 mock shape)
  why: |
    L105/109 show the buffer+cursor setup; L751+ show how S2 MOCKED complete_current (a fake storing
    (buf,cb)). S3 REPLACES that mock with the real function — S2's cases stay green because they assert
    the ROUTING (complete_current called), not complete_current's internals.
  pattern: |
    local buf = vim.api.nvim_create_buf(false,true); vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "!git ch" })
    vim.api.nvim_win_set_cursor(win, { 1, 7 })    -- row 1, 0-based byte col 7 (past 'h')
  gotcha: |
    byte col is 0-based (coords.lua header). For "!git ch" (7 bytes), cursor-at-end = col 7 (NOT 6).
    After bang strip: cursor_in_cmd = 7 - 1 = 6 = #("git ch"). VERIFIED (research §4).

# Sibling PRPs (the immediate predecessor contracts — read for the seam, do not re-derive)
- file: plan/002_d23d7473c16c/P2M2T3S2/PRP.md
  why: S2 defined do_shell_fetch + the forward-guard + the exact cb signature + the fast-context trap
  pattern: do_shell_fetch is the SOLE consumer; its forward-guard flips to live when S3 lands.
  gotcha: S2's tests MOCK complete_current — they do NOT constrain S3's internals (S3's own spec does).
```

### Current codebase tree (relevant slice)

```bash
pi-nvim-bridge/
├── lua/pi-bridge/
│   ├── shell.lua          # ← EDIT (add M.complete_current + M.shell_word_prefix)
│   ├── completion.lua     # do_shell_fetch is the SOLE caller (L428) — READ-ONLY (S2 done)
│   └── coords.lua         # NOT used by the shell path (§17.14) — READ-ONLY reference
├── tests/
│   ├── shell_request_spec.lua        # the fake-daemon harness TEMPLATE (copy its fakes)
│   ├── shell_fish_spike.lua          # the VERIFIED wire shape (frame + word⇥desc parse)
│   ├── completion_spec.lua           # buffer+cursor setup pattern (L105/109) — READ-ONLY
│   ├── shell_complete_current_spec.lua   # ← CREATE (plenary; the Level-2 gate)
│   ├── shell_complete_current_smoke.lua  # ← CREATE (plenary-free; the Level-1 gate)
│   └── minimal_init.lua              # plenary harness bootstrap (read-only)
└── PRD.md  (§17.7, §17.5.1, §17.14, §17.6.1, §17.8, §11 — read-only reference)
```

### Desired codebase tree with files changed

```bash
lua/pi-bridge/shell.lua                          # MODIFIED — +M.complete_current +M.shell_word_prefix
tests/shell_complete_current_spec.lua            # CREATED — plenary spec (fake daemon; frame + cb + edges)
tests/shell_complete_current_smoke.lua           # CREATED — plenary-free load + basic call smoke
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: AGENTS.md ⛔ HARD RULE — NEVER pipe a heredoc / stdin into nvim (it HANGS the session).
-- Write any ad-hoc test snippet to a .lua FILE, then run  +"luafile <file>" +qa . Always wrap in `timeout`.

-- CRITICAL: the shell path is BYTE-domain (§17.14); the pi bridge path is UTF-16 (§8). complete_current
-- must NOT call coords.nvim_to_pi_coords / coords.byte_to_utf16 / vim.str_utfindex. nvim_win_get_cursor(0)[2]
-- is ALREADY a 0-based byte offset (coords.lua header "CURSOR-API COL IS 0-BASED BYTE"). For multibyte text
-- (e.g. "!日cmd" — 日 is 3 bytes but 1 UTF-16 unit) the byte offset is CORRECT for the shell + for
-- nvim_buf_set_text (P2.M2.T4 accept). UTF-16-converting it would SHRINK the frame's `cursor` (3→1 for 日)
-- and corrupt completion. This asymmetry is the #1 trap — test case 9 asserts the gap explicitly.

-- CRITICAL: the wrapper_cb (passed to M.request) runs in LIBUV FAST CONTEXT (M.request's pending_cb fires
-- it from _feed's read_start cb OR the timer cb — shell.lua:642/650). It does PURE string math only
-- (shell_word_prefix) + forwards to cb. NO vim.api.* (E5560). The consumer (do_shell_fetch) ALREADY
-- vim.schedule's the menu hop — do NOT add a second schedule. Contrast: M.request's own chain also does
-- no vim.api.* (only state writes + luv + vim.json.encode) — complete_current's wrapper_cb is the same kind.

-- GOTCHA: `line` is "up to the cursor" ⇒ `cursor == #line` by construction (§17.5.1). Do NOT compute
-- cursor independently of line; derive `line = cmd:sub(1, cin)` then `cursor = cin` (= #line). The frame
-- example {"line":"git ch","cursor":6} has cursor=6 == #("git ch"). VERIFIED (research §4).

-- GOTCHA: Lua string.sub(1, n) returns the first n BYTES (byte-correct for UTF-8; sub(1,0) = "").
--   cmd = line1:sub(bangs + 1)          -- command after bangs
--   cin = math.max(0, byte_col - bangs) -- cursor offset into cmd (CLAMP ≥ 0; cursor on bangs → 0)
--   line  = cmd:sub(1, cin)             -- up to cursor (cin bytes)
--   after = cmd:sub(cin + 1)           -- after cursor
-- A NEGATIVE cin (cursor before the bangs) would make sub(1,-1) = the WHOLE string (WRONG) — the
-- math.max(0, …) clamp is MANDATORY.

-- GOTCHA: check "!!" BEFORE "!" in the bang count (line1:sub(1,2)=="!!" → 2; else if sub(1,1)=="!" → 1).
-- "!!" also starts with "!", so the wrong order strips only 1.

-- GOTCHA: the daemon's `prefix` (decoded.prefix, §17.5.1) is ADVISORY — complete_current OVERRIDES it
-- with the client-derived shell_word_prefix(line) (research §6 / §17.6.1). Do NOT pass the daemon prefix
-- through. (The drivers P2.M2.T4/M3.T5 are not built; their prefix quality is TBD. Client derivation is
-- deterministic + correct for plain whitespace-delimited words. shell/accept.lua recomputes boundaries.)

-- GOTCHA: complete_current is called on the nvim MAIN LOOP (do_refresh/force_fetch/on_tab are main-loop
-- callers). So nvim_buf_get_lines + nvim_win_get_cursor are api-safe THERE (no vim.schedule needed for the
-- READ). Only the ASYNC wrapper_cb (fast context) is restricted to pure string math.

-- GOTCHA: complete_current does NOT add its own gen guard. completion.lua's state.gen (do_shell_fetch)
-- + shell.lua's state.gen (M.request) already bookend it. complete_current just forwards cb. (M.request's
-- own pending_cb is gen-guarded + one-shot — a stale daemon response is dropped before wrapper_cb fires.)

-- GOTCHA: read NOTHING at module load. complete_current reads buf/cursor from its ARGS + nvim at call
-- time. (shell.lua's other functions already follow the fresh-read rule for config/bridge/descriptor.)

-- GOTCHA: the SOLE consumer is completion.lua:428 (do_shell_fetch). Its forward-guard
-- `if type(shell.complete_current) ~= "function"` means S3 is INERT until this lands — adding the function
-- cannot break the live plugin even if a detail is off (S2's mocked tests still pass; they don't call the
-- real one). But S3's OWN spec + the shell_request/completion regression suites are the real gate.

-- GOTCHA: the injected fake driver is package.loaded["pi-bridge.shell.fish"]; the spec's after_each MUST
-- nil it + shell.reset() so cases don't leak. shell.reset() clears state.failed/state.proc/etc.
```

---

## Implementation Blueprint

### Data models and structure
N/A — S3 adds no data model. `M.complete_current` operates on the EXISTING `state` (via `M.request`) + the EXISTING `AutocompleteItem` shape (already normalized by `_feed`). The `line`/`cursor`/`after` triple is computed inline + passed to `M.request`; it is not stored.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lua/pi-bridge/shell.lua — add M.shell_word_prefix + M.complete_current
  - LOCATE: the public-API section. PLACE M.complete_current + M.shell_word_prefix AFTER M.request
    (they delegate to it) and BEFORE the `_test_` seams block (the "TEST SEAMS" header ~L720). Keep
    them as `function M.X(...)` declarations (the module's public-API style).
  - NAMING: `M.shell_word_prefix(line)` (pure helper; mirrors completion.M.is_attachment_context) +
    `M.complete_current(buf, cb)` (the entry; mirrors the §17.7 name + the do_shell_fetch call).
  - IMPLEMENT (NEVER throws; pcall every nvim/M.request call; fast-safe wrapper_cb):

      --- §17.6.1 client-side prefix: the trailing non-whitespace run of `line` (the current shell word
      --- being completed). PURE (no nvim, no state) → directly unit-testable (the coords.lua /
      --- completion.is_attachment_context style). Used by complete_current to OVERRIDE the daemon's
      --- advisory prefix (research §6). Returns "" for an empty/whitespace line.
      ---@param line string The command text up to the cursor (after bang strip).
      ---@return string prefix The trailing word ("" if none).
      function M.shell_word_prefix(line)
        if type(line) ~= "string" then return "" end
        return line:match("[%S]+$") or ""
      end

      --- §17.7 shell.complete_current(buf, cb) — the buffer→daemon bridge. Reads pi-prompt line 1 +
      --- the nvim cursor, strips the `!`/`!!` bangs (§17.7), computes the BYTE-domain line/cursor/after
      --- triple (§17.14 — NO coords/UTF-16), short-circuits an empty command (§17), derives prefix
      --- client-side (§17.6.1), and delegates to M.request(line, cursor, after, wrapper_cb). The
      --- wrapper_cb runs in LIBUV FAST CONTEXT (M.request's pending_cb) → pure string math + forward ONLY.
      ---
      --- Called by completion.lua's do_shell_fetch (the SOLE consumer; forward-guarded there). Runs on
      --- the nvim MAIN LOOP at call time (do_refresh/force_fetch/on_tab) → the buffer/cursor READ is
      --- api-safe; only the async wrapper_cb is fast-context-restricted. NEVER throws (per-keystroke +
      --- autocmd contract): pcall every nvim.api/M.request; type-guard buf/cb; bad args → cb(err).
      ---@param buf integer The pi-prompt buffer handle (current — guarded by the caller).
      ---@param cb  pi-bridge.shell.RequestCb Resolved EXACTLY ONCE: cb(nil, items, prefix) on success;
      ---           cb(err) on a read/ensure/write/encode failure.
      function M.complete_current(buf, cb)
        if type(cb) ~= "function" then cb = function() end end  -- never-throws on a bad arg
        -- (1) GUARD buf. A wiped/non-buffer → cb(err) (silent degrade; the consumer's err path).
        if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
          return cb("invalid buf")
        end
        -- (2) READ line 1 (only line 1 — completion_context gates cursorLine==0). pcall (a wiped buf
        --     mid-call → cb). nvim_buf_get_lines(buf, 0, 1, false) returns {line1} (UTF-8 Lua string).
        local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, 1, false)
        if not ok or type(lines) ~= "table" or type(lines[1]) ~= "string" then
          return cb("read failed")
        end
        local line1 = lines[1]
        -- (3) READ cursor (current window — buf is current per the caller's currency guard). pcall.
        local cur
        ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
        if not ok or type(cur) ~= "table" or type(cur[2]) ~= "number" then
          return cb("read failed")
        end
        local byte_col = cur[2]  -- 0-based BYTE offset (coords.lua header; §17.14)
        -- (4) BANG STRIP (§17.7): "!!" → 2, else "!" → 1, else 0 (defensive; completion_context already
        --     gated line1[1]=="!", but be robust). Check "!!" FIRST (it also starts with "!").
        local bangs = 0
        if line1:sub(1, 2) == "!!" then bangs = 2
        elseif line1:sub(1, 1) == "!" then bangs = 1 end
        -- (5) COMPUTE the BYTE-domain triple (§17.14 — NO coords/UTF-16). Clamp cin ≥ 0 (a cursor ON
        --     the bangs → 0; a negative cin would make sub(1,-1) = the WHOLE string — WRONG).
        local cmd   = line1:sub(bangs + 1)            -- full command after bangs
        local cin   = math.max(0, byte_col - bangs)   -- cursor offset into cmd (0-based byte)
        local line  = cmd:sub(1, cin)                 -- up to cursor (cin bytes; sub(1,0)="")
        local after = cmd:sub(cin + 1)                -- after cursor
        -- (6) EMPTY-COMMAND GUARD (§17 edge case): a bare `!` / `!   ` does NOT spawn the daemon.
        --     `!git ` (trailing space) is NOT empty → queries. Match wholly-empty/whitespace.
        if cmd == "" or cmd:match("^%s*$") then
          return cb(nil, {}, "")
        end
        -- (7) DELEGATE to M.request. The wrapper_cb runs in LIBUV FAST CONTEXT (M.request's pending_cb
        --     ← _feed/timer) → PURE string math + forward ONLY. Derive prefix CLIENT-SIDE (§17.6.1 /
        --     research §6: OVERRIDE the daemon's advisory prefix). err → cb(err) (no prefix derivation).
        M.request(line, cin, after, function(rerr, ritems, _rprefix)
          if rerr then return cb(rerr) end
          cb(nil, ritems or {}, M.shell_word_prefix(line))  -- OVERRIDE prefix (line captured in closure)
        end)
      end

  - NOTE: `cin` is passed as `cursor` (it IS the 0-based byte offset into `line` == #line). The frame
    M.request builds: `__PIREQ__\t{"line":<line>,"cursor":<cin>,"after":<after>}\n` — VERIFIED shape.
  - DEPENDENCIES: M.request (shipped, S4). NONE new.

Task 2: CREATE tests/shell_complete_current_smoke.lua — the plenary-free Level-1 gate
  - PATTERN: tests/shell_request_spec.lua's fakes (fake_bridge / make_fake_stdin / inject_fake_driver) +
    a REAL buffer (completion_spec.lua:105/109). NO plenary, NO subprocess. Prints a parseable verdict.
  - IMPLEMENT:
      local pi = require("pi-bridge"); local shell = require("pi-bridge.shell")
      if pi.config == nil then pi.setup({}) end
      local fails = 0
      local function check(c, m) if not c then io.stderr:write("FAIL: "..m.."\n"); fails=fails+1 end end
      -- fake "fish" daemon (inject_fake_driver equivalent)
      local stdin = { written = {}, write = function(s, d, wcb) s.written[1]=d; if wcb then wcb(nil) end end,
                      is_closing=function() return false end, close=function() end, read_stop=function() end }
      package.loaded["pi-bridge.shell.fish"] = { start = function(opts, cb)
        cb(nil, { is_closing=function() return false end }, stdin,
               { read_start=function() end, is_closing=function() return false end, close=function() end })
      end }
      pi.bridge = { get_shell_info=function() return {shell="/usr/bin/fish"} end, server_info={} }
      shell.reset()
      -- REAL buffer: "!git ch", cursor at byte col 7 (end)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "!git ch" })
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf); vim.api.nvim_win_set_cursor(win, { 1, 7 })
      shell.ensure(function() end)  -- cache the fake proc/stdin
      local got; shell.complete_current(buf, function(err, items, prefix) got = {err=err, items=items, prefix=prefix} end)
      check(stdin.written[1] == '__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n', "frame shape")
      -- deliver a response (as _feed will in prod) → wrapper_cb → user cb
      shell._test_invoke_pending({ {value="checkout"}, {value="cherry"} }, "IGNORED")
      check(got and got.err == nil, "cb nil err")
      check(got and got.prefix == "ch", "client-derived prefix (ch), NOT the daemon's 'IGNORED'")
      check(got and got.items and got.items[1].value == "checkout", "items forwarded")
      -- bare "!" → empty-cmd guard (no spawn, no frame)
      shell.reset(); stdin.written = {}
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "!" })
      vim.api.nvim_win_set_cursor(win, { 1, 1 })
      local got2; shell.complete_current(buf, function(err, items, prefix) got2={err=err,items=items,prefix=prefix} end)
      check(got2 and got2.err == nil and (got2.items or {})[1] == nil, "bare ! → empty items, no err")
      check(#stdin.written == 0, "bare ! → daemon NOT spawned (0 frames)")
      -- teardown
      package.loaded["pi-bridge.shell.fish"] = nil; pi.bridge = nil; shell.reset()
      if fails > 0 then io.stderr:write(fails.." smoke check(s) FAILED\n"); vim.cmd("cquit 1") end
      io.stdout:write("S3_SMOKE_OK\n")
  - RUN: timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_complete_current_smoke.lua" +qa
  - DEPENDENCIES: Task 1.

Task 3: CREATE tests/shell_complete_current_spec.lua — the plenary Level-2 gate (THE gate)
  - PATTERN: copy tests/shell_request_spec.lua's fakes (fake_bridge / make_fake_stdin / inject_fake_driver)
    + count_open_timers + the before_each/after_each save-restore shape. Buffer setup per completion_spec.
  - HELPERS (copy verbatim from shell_request_spec.lua): fake_bridge(shell_path), make_fake_stdin(),
    make_fake_stdout(), inject_fake_driver(fake_stdin, opts), count_open_timers().
  - RESET (before_each/after_each): save/restore vim.env.SHELL, pi.bridge, pi.descriptor, pi.config.shell;
    package.loaded["pi-bridge.shell.fish"]=nil; shell.reset(). (Mirror shell_request_spec.lua's block.)
  - LOCAL helper: set up a buffer + cursor (returns buf, win):
      local function buf_with(line_text, byte_col)
        local buf = vim.api.nvim_create_buf(false, true)
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line_text })
        vim.api.nvim_win_set_cursor(win, { 1, byte_col })
        return buf, win
      end
  - CASES (each wires fake_bridge("/usr/bin/fish") + inject_fake_driver + shell.ensure first):
      1. "!git ch" cursor@7 → complete_current → stdin.written[1] == '__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n';
         _test_invoke_pending({{value="checkout"}},"x") → cb(nil, items, "ch") (CLIENT prefix, NOT "x").
      2. "!!git ch" cursor@8 (byte col 8 = past 'h' of "!!git ch"; #line1=8) → SAME frame
         (bangs=2 → cmd="git ch", cin=8-2=6). Asserts the !! strip.
      3. cursor MID-word: "!git ch" cursor@5 (on the 'c' of "ch"; byte col 5) → cmd="git ch",
         cin=5-1=4, line="git ", after="ch". Frame {"line":"git ","cursor":4,"after":"ch"}.
         prefix = shell_word_prefix("git ") = "" (trailing space → no word). cb(nil, items, "").
      4. bare "!" cursor@1 → cb(nil, {}, ""); stdin.written EMPTY (0 frames); state.proc stays nil
         (no spawn). (Assert #stdin.written == 0.)
      5. "!   " (bang + spaces) cursor@4 → empty-cmd guard fires; cb(nil,{},"); 0 frames.
      6. cursor ON the bangs: "!!git" cursor@1 → clamped: cmd="git", cin=max(0,1-2)=0, line="",
         after="git". Frame {"line":"","cursor":0,"after":"git"}. No throw. (cmd="git" non-empty → NOT
         the empty-cmd guard; M.request IS called with the clamped triple.)
      7. daemon err path: complete_current → _test_ does NOT deliver (OR deliver via a driver that fails):
         simplest — set state.failed=true via shell._reset() before complete_current → M.request's ensure
         short-circuits → cb("daemon disabled"). Assert got.err == "daemon disabled"; wrapper_cb did NOT
         derive prefix / call cb(nil,…).
      8. write-fail: make_fake_stdin({write_err="EPIPE"}) → complete_current → cb("write failed").
      9. multibyte (BYTE correctness — the §17.14 anti-coords guard). Use a CJK char so the byte↔UTF-16
         gap is unmistakable: 日 = U+65E5 = 3 bytes (E6 97 A5) but only 1 UTF-16 code unit. Buffer
         "!日cmd" (bang + 日 + c + m + d). Compute the byte lengths IN THE TEST (do NOT hardcode — a shell
         literal can re-encode): `local cmd = "日cmd"; local bangs = 1; local col = bangs + #cmd` (col = end).
         set the buffer to "!"..cmd, cursor at `col`. complete_current → assert the frame's `cursor` field
         == `#cmd` (here 3+3=6 BYTES), NOT the UTF-16 length (which would be 1+3=4 via coords). Assert
         `line` (the JSON "line" value) byte-decodes to exactly `cmd`. prefix == "日cmd" (the trailing word).
         This is the single case that PROVES complete_current did not route through coords/UTF-16 (§17.14):
         if it had, `cursor` would be 4, not 6. (A BMP é works too — byte 2 vs UTF-16 1 — but the 3-byte
         CJK gap is harder to mis-read. Build cmd from a Lua literal in the test FILE, never via shell -e.)
      10. never-throws: complete_current(nil, cb) → cb("invalid buf"); complete_current(buf, nil) → no throw;
          complete_current(123, cb) with buf 123 invalid → cb("invalid buf").
      11. M.shell_word_prefix direct unit tests: ("git ch")=="ch"; ("git ")==""; ("")==""; ("a")=="a";
          (nil)==""; ("  leading")=="leading".
      12. no leak: after a full complete_current + _test_invoke_pending cycle, count_open_timers()==0
          (M.request's per-request timer closed on finalize).
  - PLACEMENT: a top-level describe("pi-bridge.shell complete_current (P2.M2.T3.S3)", function() … end).
  - DEPENDENCIES: Task 1.

Task 4: VERIFY — run the gates (no file changes)
  - RUN Level 1 (smoke): timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_complete_current_smoke.lua" +qa
  - RUN Level 2 (the new spec): timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_complete_current_spec.lua")'
  - RUN REGRESSION (S2/S4 must stay green):
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_request_spec.lua")'
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'
  - EXPECT: all green. If completion_spec.lua fails, it is almost certainly because a case set
    shell_mod.complete_current to a fake AND S3's real function interfered — RE-CHECK that the case
    restores complete_current to nil in reset() (S2 already does this at L82). S3 must NOT break S2's mock.
```

### Implementation Patterns & Key Details

```lua
-- === M.complete_current(buf, cb): the buffer→daemon adapter (Task 1) ===
-- Key invariants:
--   * MAIN-LOOP at call time → nvim_buf_get_lines/nvim_win_get_cursor are api-safe (no schedule).
--   * BYTE-domain (§17.14): cursor = 0-based byte offset; NO coords/UTF-16. nvim_win_get_cursor[2] is
--     already 0-based byte.
--   * wrapper_cb runs FAST (libuv) → pure string math (shell_word_prefix) + forward ONLY. The consumer
--     (do_shell_fetch) schedules the menu hop.
--   * OVERRIDE prefix client-side (§17.6.1); the daemon's prefix arg is discarded.
--   * empty-cmd guard (§17) → cb(nil,{},") WITHOUT M.request (no cold-start spawn on a bare `!`).
--   * NEVER throws (pcall nvim + M.request; type-guard buf/cb; clamp cin ≥ 0).
function M.complete_current(buf, cb)
  if type(cb) ~= "function" then cb = function() end end
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return cb("invalid buf") end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, 1, false)
  if not ok or type(lines) ~= "table" or type(lines[1]) ~= "string" then return cb("read failed") end
  local line1 = lines[1]
  local cur
  ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok or type(cur) ~= "table" or type(cur[2]) ~= "number" then return cb("read failed") end
  local byte_col = cur[2]
  local bangs = (line1:sub(1,2) == "!!") and 2 or (line1:sub(1,1) == "!" and 1 or 0)
  local cmd   = line1:sub(bangs + 1)
  local cin   = math.max(0, byte_col - bangs)   -- CLAMP (cursor on bangs → 0)
  local line  = cmd:sub(1, cin)
  local after = cmd:sub(cin + 1)
  if cmd == "" or cmd:match("^%s*$") then return cb(nil, {}, "") end   -- §17 empty-cmd guard
  M.request(line, cin, after, function(rerr, ritems, _rprefix)
    if rerr then return cb(rerr) end
    cb(nil, ritems or {}, M.shell_word_prefix(line))   -- FAST ctx: pure math + forward. OVERRIDE prefix.
  end)
end

-- === M.shell_word_prefix(line): the pure prefix helper (Task 1) ===
function M.shell_word_prefix(line)
  if type(line) ~= "string" then return "" end
  return line:match("[%S]+$") or ""
end

-- === The VERIFIED byte math (the ONE non-obvious correctness point) ===
-- "!git ch" cursor@7: bangs=1, cmd="git ch", cin=6, line="git ch", after="".
-- Frame: __PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n  ← EXACTLY §17.5.1 + the fish spike.
-- "!!git ch" cursor@8: bangs=2, cmd="git ch", cin=6 → SAME frame (the !! strip).
-- The cursor is ALWAYS == #line (line is "up to cursor" by construction). Do NOT compute it separately.

-- === Why the wrapper_cb is fast-safe (the #1 trap, per S2's PRP) ===
-- M.request's pending_cb (which invokes wrapper_cb) fires from _feed's read_start cb OR the timer cb —
-- BOTH libuv fast context. wrapper_cb does: a type-guard (rerr), a table-or (ritems or {}), + ONE pure
-- string match (shell_word_prefix). NO vim.api.*. The menu hop (M.on_results → the floating window) is
-- the CONSUMER's (do_shell_fetch) job — it vim.schedules it. complete_current must NOT add a schedule.
```

### Integration Points

```yaml
ROUTING (S3 is the body S2's routing calls):
  - completion.lua:428 (do_shell_fetch): `pcall(shell.complete_current, buf, cb)` — UNCHANGED. S2's
    forward-guard `type(shell.complete_current) ~= "function"` flips from silent-no-op to LIVE the
    moment S3 lands. No completion.lua edit.

DAEMON DELEGATION (S3 → S4):
  - shell.lua M.request(line, cursor, after, cb): UNCHANGED (shipped, P2.M1.T2.S4). complete_current
    supplies the 3 args (BYTE-domain) + a fast-safe wrapper_cb. M.request owns framing, supersession
    (its own state.gen), the timer, the write, + the one-shot pending_cb.

COORDINATE CONTRACT (§17.14 — the shell path's defining rule):
  - BYTE-domain throughout. nvim_win_get_cursor(0)[2] is 0-based byte (coords.lua header). NO
    coords.nvim_to_pi_coords / coords.byte_to_utf16 / vim.str_utfindex. Contrast §8 (UTF-16, bridge).

PREFIX (§17.6.1):
  - M.shell_word_prefix(line): client-side derivation; OVERRIDES the daemon's advisory prefix. The
    daemon's decoded.prefix (§17.5.1) is discarded by complete_current's wrapper_cb.

FORWARD CONTRACTS (do NOT implement in S3):
  - §17.4.3 mismatch notice / §17.9 first-run hint / §17.12 degrade notify → S4 (P2.M2.T3.S4).
  - menu visual_cue ($ gutter) for shell context → S5 (P2.M2.T3.S5).
  - shell accept (local word-replacement + per-shell quoting via nvim_buf_set_text) → P2.M2.T4
    (shell/accept.lua). It recomputes word boundaries itself — does NOT read complete_current's prefix.
  - fish/zsh/bash drivers → P2.M2.T4 / P2.M3.T5. complete_current is driver-agnostic (it only frames).

CONFIG:
  - complete_current reads NONE (no config dependency). timeout_ms / debounce_ms / prefer are M.request's
    (S4) / completion.compute_debounce's (S2) / M.resolve_shell's (S2 of P2.M1.T2) jobs.
```

---

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# From the repo root. Confirm the edited module LOADS + complete_current is a function + the pure helper.
# ⛔ NEVER heredoc→nvim stdin (AGENTS.md HARD RULE). Write to a FILE, then :luafile it.
cat > /tmp/s3_loadcheck.lua <<'LUA'
local ok, m = pcall(require, "pi-bridge.shell")
assert(ok, "require failed: " .. tostring(m))
assert(type(m.complete_current) == "function", "complete_current is a function")
assert(type(m.shell_word_prefix) == "function", "shell_word_prefix is a function")
-- pure helper direct checks (no nvim, no state)
assert(m.shell_word_prefix("git ch") == "ch", "prefix 'ch'")
assert(m.shell_word_prefix("git ") == "", "prefix '' for trailing space")
assert(m.shell_word_prefix("") == "", "prefix '' for empty")
assert(m.shell_word_prefix(nil) == "", "prefix '' for nil (never throws)")
-- M.request surface intact (regression)
assert(type(m.request) == "function" and type(m.ensure) == "function")
print("S3_LOAD_OK")
LUA
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/s3_loadcheck.lua" +qa
echo "exit=$?   # 0 = pass (prints S3_LOAD_OK)"

# Then the plenary-free smoke (Task 2): the file-based end-to-end gate (fake daemon, no subprocess).
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_complete_current_smoke.lua" +qa
echo "exit=$?   # 0 = pass (prints S3_SMOKE_OK)"

# stylua formatting check (if the repo uses it — matches CI in PRD §14):
# stylua --check lua/pi-bridge/shell.lua tests/shell_complete_current_spec.lua tests/shell_complete_current_smoke.lua
```

### Level 2: Unit Tests (Component Validation) — THE GATE

```bash
# The new plenary spec for complete_current (Task 3). This is S3's primary validation gate.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_complete_current_spec.lua")'
echo "exit=$?   # 0 = all green (12 case groups: frame, !! strip, mid-word, empty-cmd, cursor-on-bangs,
#        err path, write-fail, multibyte BYTE, never-throws, prefix unit, no-leak)"

# (Optional, fast feedback) the existing shell smoke — confirms no load regression:
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_smoke.lua" +qa
echo "exit=$?"
```

### Level 3: Integration Testing (System Validation)

```bash
# REGRESSION — S2 (routing) + S4 (request) + the shell module must stay green. S3 is additive; if any
# of these fail, S3 broke a shared seam (most likely the injected fake-driver leak or a state mutation).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_request_spec.lua")'   # M.request (the delegate)
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'      # S2 routing (do_shell_fetch)
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'           # resolve_shell/pick_driver/reset
echo "all exit 0 = no regression"

# REAL-daemon integration (OPTIONAL follow-on; NOT required for S3 sign-off — the drivers are P2.M2.T4).
# Once a fish driver exists, a tests/completion_shell_smoke.lua driving a real `fish -i` daemon through
# complete_current → M.request → the menu is the natural end-to-end proof. For S3, the mocked fake-daemon
# spec (Task 3) IS the integration proof at the adapter layer (it exercises the REAL complete_current +
# REAL M.request + REAL M.ensure against an injected fake stdin — every layer except the subprocess).
# Per AGENTS.md: the plenary spec + file-based smoke cover the end-to-end surface; do NOT invent a
# stdin-based nvim E2E (the ⛔ HARD RULE heredoc trap).
```

### Level 4: Creative & Domain-Specific Validation
N/A for S3 (no UI, no daemon subprocess, no health-check, no docs to ship — those are S4/S5 + P2.M2.T4 + P2.M3.T6).

---

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load-check prints `S3_LOAD_OK`, exit 0; `M.complete_current` + `M.shell_word_prefix` are functions.
- [ ] `tests/shell_complete_current_smoke.lua` prints `S3_SMOKE_OK`, exit 0.
- [ ] `tests/shell_complete_current_spec.lua` plenary run exits 0 (all 12 case groups).
- [ ] Regression: `shell_request_spec.lua` + `completion_spec.lua` + `shell_spec.lua` all exit 0.
- [ ] No nvim command in this PRP pipes a heredoc into nvim stdin (AGENTS.md ⛔ HARD RULE); every nvim invocation is wrapped in `timeout`.

### Feature Validation
- [ ] `!git ch` (cursor end) → frame `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n` (case 1).
- [ ] `!!git ch` → SAME frame (case 2 — the `!!` strip).
- [ ] cursor mid-word → `line`/`after` split correctly; prefix is the trailing word or "" (case 3).
- [ ] bare `!` / `!   ` → `cb(nil, {}, "")`; daemon NOT spawned (0 frames) (cases 4, 5).
- [ ] cursor on bangs → clamped (`cursor=0`, `line=""`); no throw (case 6).
- [ ] daemon `err` → `cb(err)` forwarded; `cb(nil,…)` NOT called on err (case 7).
- [ ] write-fail → `cb("write failed")` (case 8).
- [ ] multibyte line → `cursor` is the BYTE count (NOT UTF-16/codepoint); confirms no coords conversion (case 9).
- [ ] never-throws on bad args (case 10); `M.shell_word_prefix` direct unit cases pass (case 11).
- [ ] no uv_timer_t leak across a complete_current cycle (case 12).

### Code Quality Validation
- [ ] `complete_current` is a THIN adapter: buffer read → 3 BYTE args → `M.request` → forward cb. No framing/supersession/spawn re-implementation.
- [ ] `wrapper_cb` is fast-safe (pure string math + forward; NO `vim.api.*`); the consumer schedules the menu hop.
- [ ] NO `coords.nvim_to_pi_coords` / `coords.byte_to_utf16` / `vim.str_utfindex` call (§17.14 byte-domain).
- [ ] Prefix is DERIVED client-side (`M.shell_word_prefix`); the daemon's prefix is overridden.
- [ ] Reads (buf/cursor) happen at call time on the main loop; nothing cached at module load.
- [ ] No edits to `completion.lua`, `menu.lua`, `accept`, `ftplugin`, notices, health, drivers.
- [ ] Comments reference PRD §17.7/§17.5.1/§17.14/§17.6.1 + the fast-context forward contract (shell.lua:642/650).

### Documentation & Deployment
- [ ] Code is self-documenting (the `-- §17.7`/`-- §17.14 BYTE`/`-- FAST CONTEXT` comments explain the strip + byte math + the schedule boundary).
- [ ] No new env vars, install steps, or config blocks (S3 reads no config).

---

## Anti-Patterns to Avoid

- ❌ **Do NOT call `coords.nvim_to_pi_coords` / `coords.byte_to_utf16` / `vim.str_utfindex` in complete_current.** The shell path is BYTE-domain (§17.14); the pi bridge path is UTF-16 (§8). `nvim_win_get_cursor(0)[2]` is ALREADY a 0-based byte offset. UTF-16-converting it corrupts the frame's `cursor` for any multibyte line (case 9 catches this).
- ❌ **Do NOT do `vim.api.*` in the `wrapper_cb`.** It runs in libuv FAST context (M.request's pending_cb ← `_feed`/timer). Pure string math (`shell_word_prefix`) + forward to `cb` only. The menu hop is the consumer's (`do_shell_fetch`) job — it `vim.schedule`s it. Adding a second schedule is redundant; calling `vim.api` directly throws E5560 / corrupts the UI.
- ❌ **Do NOT compute `cursor` independently of `line`.** `line` is "up to the cursor" (§17.5.1) ⇒ `cursor == #line` by construction. Derive `line = cmd:sub(1, cin)` then `cursor = cin`. The frame example `{"line":"git ch","cursor":6}` has cursor=6 == #("git ch").
- ❌ **Do NOT skip the `math.max(0, byte_col - bangs)` clamp.** A cursor ON the bangs (`byte_col < bangs`) gives a NEGATIVE `cin`; `cmd:sub(1, -1)` returns the WHOLE string (WRONG). The clamp forces `cin=0` → `line=""` (correct: nothing before the cursor in the command).
- ❌ **Do NOT check `"!"` before `"!!"` in the bang count.** `"!!"` also starts with `"!"`; the wrong order strips only 1. Check `line1:sub(1,2) == "!!"` FIRST.
- ❌ **Do NOT pass the daemon's `prefix` through to `cb`.** complete_current OVERRIDES it with the client-derived `M.shell_word_prefix(line)` (§17.6.1; research §6). The daemon's `decoded.prefix` is advisory + its quality is TBD (drivers are P2.M2.T4/M3.T5 — not built). Client derivation is deterministic + correct.
- ❌ **Do NOT add a third (complete_current-local) gen guard.** completion.lua's `state.gen` (do_shell_fetch) + shell.lua's `state.gen` (M.request) already bookend complete_current. Adding its own would be redundant + confusing. Just forward `cb`.
- ❌ **Do NOT spawn/read the daemon from complete_current.** `M.request`/`M.ensure`/`_feed` own all daemon I/O. complete_current only frames + delegates. (The empty-cmd guard is the ONE exception: it short-circuits BEFORE M.request to avoid a cold-start spawn on a bare `!` — and even that does NOT touch the daemon; it resolves `cb(nil,{},")` directly.)
- ❌ **Do NOT add a `vim.schedule` in complete_current.** The READ is on the main loop (api-safe); the wrapper_cb forwards to the consumer which already schedules. S3 has zero scheduling of its own.
- ❌ **Do NOT touch `completion.lua`.** S2's `do_shell_fetch` (the sole caller) is done; its forward-guard auto-activates when `complete_current` appears. Editing completion.lua risks S2's exhaustively-tested routing.
- ❌ **Do NOT pipe a heredoc into `nvim` stdin** (AGENTS.md ⛔ HARD RULE — it hangs the session). Write test snippets to a `.lua` file and run with `+"luafile <file>" +qa`. Never run a bare nvim without `timeout`.

---

## Confidence Score

**9/10** for one-pass success. The function is small + precisely specified: PRD §17.7 names it + states the bang-strip rule; §17.5.1 gives the EXACT frame + worked example; §17.14 mandates the BYTE domain; the VERIFIED byte math (research §4 — confirmed against the fish spike's literal wire shape) removes the off-by-one risk; the test harness (`fake_bridge` + `inject_fake_driver` + `_test_invoke_pending`) is copy-paste from the shipped `shell_request_spec.lua`; and the sole consumer (S2's `do_shell_fetch`) is forward-guarded so S3 is inert-until-landed (cannot break the live plugin even if a detail is off). The two residual risks, both fenced by Anti-Patterns + cases: (1) **the BYTE-vs-UTF-16 trap** (case 9 — a multibyte line asserts `cursor` is the byte count, not a UTF-16/codepoint count); (2) **the fast-context `wrapper_cb`** (must be pure-string-math-only — case 7 confirms the err path doesn't derive prefix, case 12 confirms no leak). No unbuilt dependency blocks S3 (the drivers are P2.M2.T4 — complete_current is driver-agnostic; an injected fake driver is the test surface).