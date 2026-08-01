# Research notes — P2.M2.T3.S2 (`do_refresh` + `force_fetch`/on_tab shell branch)

## Task (verbatim)
> Add shell branch to do_refresh + force_fetch with gen-guard + 0ms debounce.

S1 (COMPLETE) added the `"shell"` return value to `completion_context()`. S2 is the
**routing** layer that consumes it: when `ctx == "shell"`, route the fetch to the §17
shell daemon (`shell.complete_current`) instead of pi's bridge (`getSuggestions`). The
bridge path stays byte-identical for slash/path/plain. S3 (`shell.complete_current`)
and S4 (notices) are PLANNED, not done → S2 **forward-references** `shell.complete_current`.

## Current state of `completion.lua` (verified line numbers)
- `compute_debounce(lines, cursorLine, cursorCol)` — **line 339**. Pure. Returns 0 for
  non-attachment context, `config.debounce_ms` (default 20) for `@`/`#`/`@"` context.
- `completion_context(...)` — returns `"shell"|"slash"|"path"|nil` (S1). Exported as
  `M.completion_context` (line ~408) for direct unit testing.
- `do_refresh(buf)` — **line 416**. The debounced body. Current flow:
  ```
  417  guard buf valid + current
  422  READ BRIDGE FRESH; if not bridge.is_connected() → bail (return)      ← BEFORE lines read
  431  READ lines + cursor
  447  ctx = completion_context(...)
  448  if not ctx → close + return
  455  pi = coords.nvim_to_pi_coords(...)
  ...  supersede layer 1 (bridge.cancel(inflight_id)); layer 2 (state.gen++); bridge.request getSuggestions
  ```
  ⚠ The bridge-connected bail at 422 is BEFORE the ctx computation. Shell completion does
  NOT need the bridge (the daemon is a child of nvim — §17.3/§17.13). So S2 must move the
  lines/cursor read + ctx computation ABOVE the bridge check, and branch on shell first.
- `force_fetch(buf, pi, opts, on_items)` — **line 518**. The IMMEDIATE (0-debounce) Tab
  sibling of do_refresh. cancel_timer + bridge.cancel(inflight) + state.gen++ + bridge.request.
  Shares state.gen/inflight_id/debounce_timer with do_refresh (refresh↔Tab supersession).
  Called ONLY by on_tab (2a slash force=false; 2b file-force shouldTrigger→force=true).
- `on_tab(buf)` — **line 758**. BRANCH 1 (menu open+selected → M.accept) / BRANCH 2 (menu
  closed → slash or file-force). BRANCH 2 reads bridge at 768 (bail if not connected), reads
  lines+cursor at ~773-778, computes `pi`/`before`/`is_slash_ctx` inline (does NOT call
  completion_context today), then 2a/2b.

## `shell.complete_current` — FORWARD CONTRACT (S3, not yet defined)
`grep complete_current lua/pi-bridge/shell.lua` → only docstring/forward-contract references
(lines 420, 436, 642, 650). The function does NOT exist yet. S2 must:
- `require("pi-bridge.shell")` and call `shell.complete_current(buf, cb)` guarded by
  `if type(...) == "function"` so it is a silent no-op until S3 lands.
- The `cb` signature is `(err, items, prefix)` — `err` truthy = degrade; `items`/`prefix`
  mirror the bridge's `getSuggestions` result shape (already normalized to AutocompleteItem[]
  by shell.lua `_feed`, so the menu renders them identically).

## CRITICAL GOTCHA — the shell cb runs in libuv FAST context (NOT the main loop)
shell.lua:642/650 forward contracts (verbatim):
> "The user `cb` runs in libuv FAST context → the consumer (P2.M2.T3.complete_current /
> P2.M2.T3.S2) must `vim.schedule` its editor-touching work (`M.on_results` → the menu hop
> is NOT fast-safe; `state.last_result = {}` is). FLAG FOR P2.M2.T3.S2."

Contrast the BRIDGE path: bridge.lua `schedule_wrap`s its cb, so the getSuggestions cb runs
on the nvim MAIN LOOP (api-safe — completion.lua header L80: "the bridge's OWN cb is ALSO
pre-`schedule_wrap`d"). menu.lua L66 confirms: "NO schedule_wrap ON on_results: S30 fires
`on_results` on the nvim MAIN LOOP."

⇒ The SHELL cb is DIFFERENT: it lands in fast context. So completion.lua's shell cb must:
  1. gen-guard (`if gen ~= state.gen then return end`) — fast-safe (table read).
  2. `state.last_result = {...}` — fast-safe (Lua table write; single-threaded, no reentrancy).
  3. `M.on_results(buf, items, prefix)` → **wrap in `vim.schedule`** (it drives the menu —
     NOT fast-safe; `:help E5560`). The bridge path does NOT need this (it's pre-scheduled);
     the shell path DOES.
Re-checking gen INSIDE the scheduled on_results is optional (the bridge path checks once at
the cb top; matching it is acceptable — a keystroke during the ~1-tick schedule window re-fetches).

## The gen-guard is SHARED (the "gen-guard" deliverable)
`state.gen` is a single module-local monotonic int (completion.lua:223). Both the bridge path
(do_refresh/force_fetch) and the shell branch (S2) bump + capture it. This makes shell↔bridge
supersession CORRECT:
- A `!` line (shell) then a `/` line (slash): the slash do_refresh bumps gen → the stale shell
  cb is dropped at the gen-guard; the shell branch's layer-1 ALSO `bridge.cancel`s nothing (no
  shell inflight to cancel — shell.lua supersedes internally via its own gen + pending_cb slot).
- A `/` line (slash, bridge inflight) then a `!` line (shell): the shell branch must
  `bridge.cancel(state.inflight_id)` (layer 1 — free the bridge round-trip) THEN bump gen.
shell.lua has NO cancel wire method (it's a local subprocess; supersession is gen-guard +
overwriting `state.pending_cb`). So completion.lua's shell branch only needs: bump state.gen +
cancel any pending BRIDGE inflight (if the ctx switched slash→shell).

## The "0ms debounce" mechanism
`compute_debounce` (line 339) is called by `refresh()` (line 582) to pick the defer window.
For a `!` line, `is_attachment_context` returns false (the trailing token is a bare word like
`ch`, not `@`/`#`) → compute_debounce ALREADY returns 0. BUT PRD §17.11 defines a config knob
`shell.debounce_ms` (default 0). To honor it explicitly, make `compute_debounce` shell-aware:
return `config.shell.debounce_ms` (default 0) for line-1 `!` BEFORE the attachment check. Safe
even though the `shell={}` config block is P2.M3.T6.S1 (not done) — read defensively via
`(pi.config and pi.config.shell) or {}` (mirrors shell.lua's existing idiom).

## on_tab shell force (the "force_fetch" part)
PRD §17.9: "The `<Tab>`-closed path (`force_fetch`) forces an immediate fetch in `"shell"`
context, mirroring the existing file-force behavior." So Tab on a `!` line (menu closed) →
immediate shell.fetch → menu shows shell completions. The result routes to `on_results` (menu
population), NOT `_route_or_accept` (shell items are NOT pi items — pi's single-item auto-apply
editor.ts:2253 does not apply; shell accept is P2.M2.T4's local word-replacement).
⇒ on_tab BRANCH 2 must: read lines+cursor, compute ctx, and `if ctx=="shell" then do_shell_fetch(buf); return true end`
BEFORE the bridge-connected check (shell doesn't need the bridge). The existing slash/file logic
stays untouched.

## Design: shared `do_shell_fetch(buf)` helper (DRY)
Both do_refresh and on_tab route shell ctx to ONE helper (mirrors the codebase's helper-extraction
pattern: `_route_or_accept`, `cancel_timer`, `compute_debounce`, `hide_and_cancel`). It:
1. cancels any in-flight BRIDGE request (`bridge.cancel(state.inflight_id)` — slash→shell switch).
2. bumps + captures `state.gen` (layer 2).
3. forward-guards + calls `shell.complete_current(buf, cb)`.
4. cb: gen-guard → `state.last_result = {...}` (fast-safe) → `vim.schedule(on_results)` (fast→main).
Never throws (pcall every external call; type-guards). forward-guard `type(shell.complete_current)=="function"`
makes S2 a silent no-op until S3 lands (matches S1's inert intermediate-state posture).

force_fetch gains a one-line `if opts.shell then do_shell_fetch(buf); return end` at the top so the
literal "force_fetch" name is covered (and a future caller can use it); on_tab calls do_shell_fetch
directly for clarity (it has buf in scope, not a meaningful `pi` for shell — shell uses byte offsets,
§17.14, not pi's UTF-16 coords).

## Intermediate state (S2 shipped, S3/S4 not) — EXPECTED + harmless
- A `!` line: do_refresh/on_tab forward-guard `shell.complete_current` (not a function yet) →
  silent no-op (no menu, no RPC). Once S3 lands `complete_current`, the menu populates.
- A `!` line with the bridge disconnected: no bridge.request (S2 routes to shell); correct.
- Tab on an OPEN shell menu (after S3) would hit on_tab BRANCH 1 → M.accept (pi applyCompletion) —
  WRONG for shell items. That is P2.M2.T4's (accept.lua) job to fix; S2 does NOT touch accept.
  (Same atomic-split posture as S1 documented.)

## No existing-test collision
`grep -rn '!\|bang' tests/completion_spec.lua` → the only `!` cases are the S1 direct-unit
`completion_context` gate cases (lines 1057+). The do_refresh/force_fetch/on_tab integration cases
all use `/`/`@`/plain inputs. S2 adds NEW `!`-line integration cases (mocking shell.complete_current)
and leaves the existing ones green (regression guard: slash/path/plain still use the bridge).

## Test design — mock shell.complete_current (forward contract)
`require("pi-bridge.shell")` caches the module table; the test sets
`require("pi-bridge.shell").complete_current = function(buf, cb) ... end` with a controllable
fake (store cb → resolve via `fake.resolve(err, items, prefix)`), mirroring `fake_bridge`. The
spec's `reset()` must restore `complete_current` to its prior value (nil until S3) so cases
don't leak. Cases:
1. `!` line → do_refresh calls shell.complete_current; bridge.request NOT called (zero requests).
2. `!` line with bridge==nil → still calls shell.complete_current (shell is bridge-independent).
3. gen-guard: 2 shell keystrokes → stale cb dropped at gen-guard (on_results fires once).
4. slash→shell switch → bridge.cancel(prev inflight) called + shell.complete_current called.
5. on_tab `!` line (menu closed) → shell.complete_current called immediately; Tab consumed (true).
6. shell err → silent degrade (on_results NOT called; no throw).
7. 0ms debounce: rapid `!` refreshes → at most one shell.complete_current (collapse).
8. REGRESSION: `/mod`, `@app`, `hello` → bridge.getSuggestions (unchanged; shell NOT called).

## Validation commands (AGENTS.md-safe; NEVER heredoc→nvim stdin)
- Plenary (the gate): `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'`
- Load-check (file-based; NEVER /dev/stdin): write a `/tmp/s2_loadcheck.lua`, run `+"luafile /tmp/s2_loadcheck.lua" +qa`.

## Out of scope (S3/S4/S5 + P2.M2.T4)
- S3: `shell.complete_current(buf, cb)` (read buf, strip bangs, byte offsets, call shell.request).
- S4: §17.4.3 mismatch notice + §17.9 first-run hint + §17.12 degrade notify.
- S5: menu `visual_cue` for shell context (`$` gutter).
- P2.M2.T4: shell/accept.lua (local word-replacement + per-shell quoting) — on_tab BRANCH 1 accept.