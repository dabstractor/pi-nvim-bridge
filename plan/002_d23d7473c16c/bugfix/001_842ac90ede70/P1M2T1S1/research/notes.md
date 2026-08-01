# Research Notes — P1.M2.T4.S1: Bump state.gen + cancel inflight in do_refresh's ctx==nil branch (Issue 3)

Item: **"Bump state.gen and cancel inflight in do_refresh's ctx==nil branch"** — the
supersession race fix for Issue 3 (PRD §h3.3). All claims below are verified against the
current repo (`/home/dustin/projects/pi-nvim-bridge`, lua/pi-bridge/completion.lua) at the
cited lines.

---

## 1. The bug (precise)

`do_refresh(buf)` (completion.lua:507–599) classifies the buffer via
`completion_context(lines, row-1, byte_col)` → `"shell"|"slash"|"path"|nil`. Supersession
per branch:

| Branch | Bumps gen? | Cancels inflight? | Line refs |
|---|---|---|---|
| `ctx=="shell"` → `do_shell_fetch` | ✅ L419 `state.gen = state.gen + 1` | ✅ L414–416 cancel BRIDGE inflight | 411–445 |
| `ctx=="slash"/"path"` | ✅ L568 `state.gen = state.gen + 1` | ✅ L562–564 cancel | 543–600 |
| `force_fetch` (Tab) | ✅ L639 | ✅ | 610–690 |
| `on_commands_changed` | ✅ L1083 | — | 1072–1088 |
| **`ctx==nil` (plain)** | ❌ **NO** | ❌ **NO** | **543–548 ← BUG** |

The nil branch (current code, completion.lua ~543–548, 2-space indent):
```lua
  if not ctx then
    dbg(string.format("[do_refresh] ctx=nil (plain) line1=%q col=%s — close, no request", tostring((lines or {})[1] or ""), tostring(byte_col)))
    if type(M.on_results) == "function" then pcall(M.on_results, buf, {}, "", nil) end -- S5: explicit nil context (plain typing)
    return
  end
```
It closes the menu via `on_results(buf, {}, "", nil)` and returns WITHOUT bumping `state.gen`
or canceling inflight. So a late SHELL cb (whose closure captured `gen = N` at do_shell_fetch
time — L419–420) finds `state.gen == N` still true → the gen-guard `if gen ~= state.gen then
return end` (L431) PASSES → `vim.schedule(on_results(buf, items, prefix, "shell"))` (L438)
fires → **menu re-opens** for a buffer that no longer starts with `!`.

### Why the gen-guard is the SOLE protection for shell
Shell requests have NO cancel wire — `shell.lua` has no `cancel` method (the daemon is a
local subprocess that supersedes internally via its own gen + overwriting `pending_cb`).
So the completion.lua `state.gen` guard is the ONLY thing that can drop a late shell cb.
The BRIDGE path DOES have `bridge.cancel(id)` (bridge.lua:719) — but that only helps for a
late BRIDGE cb, not a late shell cb.

---

## 2. The fix (verbatim, from architecture/completion_drivers.md §"Issue 3")

Insert the two supersession layers BEFORE the existing `pcall(M.on_results, ...)` close call
in the `ctx==nil` branch:

```lua
  if not ctx then
    dbg(string.format("[do_refresh] ctx=nil (plain) line1=%q col=%s — close, no request", tostring((lines or {})[1] or ""), tostring(byte_col)))
    -- SUPERSEDE layer 1: cancel a pending BRIDGE inflight (mirrors do_shell_fetch L1 + the
    -- slash/path block). Shell has NO cancel wire; the gen-guard (layer 2) is the sole
    -- protection against a late shell cb.
    local b = require("pi-bridge").bridge
    if state.inflight_id and b and type(b.cancel) == "function" then
      pcall(b.cancel, state.inflight_id)
    end
    state.inflight_id = nil
    -- SUPERSEDE layer 2 (gen-guard — the CORRECTNESS boundary; Issue 3): bump so a late
    -- shell/bridge cb (closure captured gen=N) finds state.gen=N+1 → dropped by the guard.
    state.gen = state.gen + 1
    if type(M.on_results) == "function" then pcall(M.on_results, buf, {}, "", nil) end -- S5: explicit nil context (plain typing)
    return
  end
```

This is a faithful mirror of the slash/path block (L562–568) + do_shell_fetch (L414–419).
It uses the local name `b` (per contract) to avoid confusion with the `bridge` local
declared LATER in do_refresh (L~555, the slash/path branch — out of scope here, after the
early return).

**Indentation**: completion.lua uses **2-space** indentation (NOT tabs — contrast
shell.lua which uses tabs). The new lines sit at 4 spaces (the `if not ctx then` body
level), matching `dbg(...)` and the `on_results` call.

---

## 3. state fields consumed (verified)

- `state.gen` — `integer`, init `0` (completion.lua:263). Bumped per fetch; captured in cb
  closures. Cleared by `M.reset()` (726) which the test harness calls in before/after_each.
- `state.inflight_id` — `string?`, init `nil` (completion.lua:257). Set at the END of the
  slash/path branch (`if ok and type(id)=="string" then state.inflight_id = id end`, L~599)
  and cleared by `do_shell_fetch` (L417) + the cb resolvers. Set to `nil` by my fix.

---

## 4. bridge.cancel signature (verified — bridge.lua:719)

```lua
function M.cancel(id)
  ...
  resolve_request(id, "cancelled", nil)  -- fires cb("cancelled"), stops+closes timer, deletes entry
end
```
`M.cancel(id)` takes the request id string, fires the matching cb with `"cancelled"`,
stops+closes its timer, and deletes the pending entry (exactly-once). It NEVER throws.
The ctx==nil fix wraps it in `pcall` (defensive, mirrors do_shell_fetch). The
`type(b.cancel)=="function"` guard makes the cancel a safe no-op if `pi.bridge` is nil or
lacks cancel (e.g. a test stub) — never throws.

---

## 5. Test design (completion_spec.lua — plenary; the on_results seam-counter)

The spec's existing case **(4)** "supersedes via cancel(prev_id) AND drops a stale response
at the gen-guard" (tests/completion_spec.lua:180) is the EXACT model. It uses:
- `fake_bridge({ auto_cancel_fires = false })` — `request()` stores the cb (returns a
  numeric-string id); `cancel(id)` records the id and (because auto_cancel_fires=false)
  does NOT auto-fire the cb, so the spec drives cbs manually via `fake.resolve` /
  `vim.schedule_wrap(cb)(err, result)`.
- `local seam = 0; completion.on_results = function() seam = seam + 1 end` — the seam counter.
- `completion.refresh(buf)` (the public debounced API; debounce_ms=10 in minimal_init/setup).
- `wait_for(ms, predicate)` = `vim.wait(ms, predicate, 5)` to pump the debounce + schedules.
- Buffer setup: `nvim_create_buf` + `nvim_buf_set_lines` + make it the current window's buf
  (`nvim_win_set_buf(win, buf)`, win=current) + `virtualedit=onemore` + `nvim_win_set_cursor`.

### The shell path is the wrinkle (vs case 4)
Case (4) is slash→slash (two `bridge.request`s). The **shell** path does NOT call
`bridge.request` — `do_shell_fetch` calls `shell.complete_current(buf, cb)` (L427). In the
spec, `shell_mod.complete_current` is **nil by default** (reset() sets it nil, L82) →
do_shell_fetch hits the "NOT defined (S3)" early-return (L425) and NEVER captures a cb.
So to test the shell→nil race I must **inject a fake `shell.complete_current` that captures
the cb**:
```lua
local stale_shell_cb
shell_mod.complete_current = function(_b, cb) stale_shell_cb = cb end
```
(do_shell_fetch calls it as `pcall(shell.complete_current, buf, function(err, items, prefix) ...)`,
so the captured cb is the gen-guarded closure with `gen=N` in scope.)

### Debounce ordering (critical — or the two refreshes collapse)
`completion.refresh` DEBOUNCES (~10ms). Two refreshes back-to-back collapse into the LAST
one. So to capture the shell cb from refresh #1, I MUST `wait_for` for do_shell_fetch to
actually run BEFORE editing the buffer + refresh #2:
1. refresh("!git c") → wait_for(stale_shell_cb ~= nil)  [do_shell_fetch ran, gen=N, cb captured]
2. set seam counter
3. edit buffer → "git c" → refresh → wait_for(seam >= 1)  [ctx==nil close fired on_results once; gen=N+1]
4. fire stale_shell_cb(nil, {items}, prefix) → gen(N)!=state.gen(N+1) → dropped
5. assert seam == 1 (the stale cb did NOT re-fire on_results)

### Two cases (cover BOTH supersession layers in ctx==nil)
- **Case A — shell→nil** (the exact Issue-3 repro): proves layer 2 (gen-guard drops the late
  SHELL cb — the sole protection, since shell has no cancel).
- **Case B — slash→nil**: proves layer 1 (cancel(prev BRIDGE id) is called in ctx==nil) +
  layer 2 (stale BRIDGE cb dropped). This is NEW coverage — case (4) is slash→SLASH (within
  the slash branch), never the ctx==nil arm.

Both use `fake_bridge({auto_cancel_fires=false})` so cbs are driven manually (no auto-fire).

---

## 6. Scope boundaries (do NOT touch)

- ONLY the `if not ctx then` block (completion.lua ~543–548). No other branch.
- Do NOT touch `do_shell_fetch`, the slash/path branch, `force_fetch`, `on_commands_changed`,
  `completion_context`, `M.refresh`, `M.reset`, `bridge.lua`, `shell.lua`, `menu.lua`.
- Do NOT add a shell cancel (none exists; not this task).
- No config/env/API/doc surface change (internal supersession fix — contract DOCS: none).
- Parallel task P1.M1.T3.S1 (Issue 2, in-flight) edits `shell.lua` `M.ensure()` + tests
  `shell_notices_spec.lua` + `doc/pi-bridge-shell.txt`. **DISJOINT** from this task
  (completion.lua + completion_spec.lua). Zero conflict either order.

---

## 7. Validation commands (verified patterns)

- Plenary spec (the gate): `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'`
- Regression (siblings unaffected): run `tests/completion_*_spec.lua`, `tests/menu_*_spec.lua`,
  `tests/shell_*_spec.lua` via the same plenary runner.
- AGENTS.md HARD RULE: the plenary runner uses a FILE path (`"tests/completion_spec.lua"`),
  NOT nvim stdin. ✅ Wrapped in `timeout`. ✅

---

## 8. One-pass risk assessment

The fix is a 9-line mirror of two existing blocks (do_shell_fetch L414–419 + slash/path
L562–568). The two test cases are near-copies of existing case (4) + (7), reusing the
file's `fake_bridge`/`wait_for`/buffer-setup helpers verbatim. The ONLY non-obvious bit is
injecting the fake `shell.complete_current` (because the shell path bypasses `bridge.request`)
and the debounce `wait_for` ordering between the two refreshes — both documented above and in
the PRP's test skeleton. Confidence: 9/10.