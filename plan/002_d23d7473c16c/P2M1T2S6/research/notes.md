# Research notes — P2.M1.T2.S6 `teardown()`

> **Scope:** the §17.5.2 / §17.12 daemon **teardown** layer of `lua/pi-bridge/shell.lua`.
> Kills the completion daemon (SIGKILL), closes stdin/stdout/proc handles, finalizes the
> in-flight request, then resets state. IDEMPOTENT (safe VimLeavePre + ExitPre double-call).
> Called by ftplugin VimLeavePre/ExitPre (P2.M3.T6.S3) + S5's parse-failure threshold.
> ADDS `M.teardown()` + a shared `close_handles()` local + extends S3's `M._reset()` to close
> the pipes on EOF (the leak S3 deferred to S6 in its [Mode A] header).

---

## §0 Task-boundary fence (what S6 OWNS vs siblings)

| Layer | Owner | S6 touches? |
|---|---|---|
| `state` literal + `M.reset()` | **S2 (DONE)** | NO (S6 CALLS `reset()`; adds no field) |
| `M.ensure` + read_start wiring + `M._reset` (EOF) | **S3 (DONE)** | YES — extends `_reset` to close pipes (S3's forward-contract header) |
| `M.request` + `state.pending_cb` + `req_timer` + `cancel_req_timer` | **S4 (parallel → contract)** | NO (S6 CALLS `cancel_req_timer()` + invokes `pending_cb`) |
| `M._feed` + `state.parse_failures` + the threshold forward-guard | **S5 (parallel → contract)** | NO (S5 is the CALLER of teardown on the threshold; S6 just exists + is safe to call from `_feed`'s luv context) |
| `M.teardown()` + shared `close_handles()` | **S6 (THIS)** | CREATES |
| fish/zsh/bash drivers (`.start`/`cd`) | **P2.M2.T4 / P2.M3.T5** | NO (the driver owns stderr — see §7) |
| completion routing (`complete_current`, the menu) | **P2.M2.T3** | NO (the consumer of pending_cb) |
| ftplugin VimLeavePre/ExitPre → `shell.teardown()` | **P2.M3.T6.S3** | NO (the CALLER) |
| `:checkhealth` (reads `state.failed`) | **P2.M3.T6.S2** | NO |

**S6's deliverable:** `M.teardown()` + the `close_handles()` local helper + the `_reset` extension.
TWO new test files. Nothing else.

---

## §1 INPUT contracts (treat as immutable)

### §1a — S2's `state` + `M.reset()` (the reset target)
From `lua/pi-bridge/shell.lua` (S2, DONE). The `state` literal S6 reads/writes:
```lua
local state = {
  proc = nil, stdin = nil, stdout = nil, rx_buf = "",
  gen = 0, inflight = false, shell = nil, driver = nil, cwd = nil,
  pending_cb = nil, failed = false,
  parse_failures = 0,   -- added by S5 (parallel → S6 does NOT re-add; assumes present)
}
```
S2's `M.reset()` (the clean-slate S6 calls at teardown's end):
```lua
function M.reset()
  state.proc=nil; state.stdin=nil; state.stdout=nil; state.rx_buf=""
  state.gen=0; state.inflight=false; state.shell=nil; state.driver=nil
  state.cwd=nil; state.pending_cb=nil; state.failed=false
  state.parse_failures = 0   -- added by S5
end
```
**KEY:** `reset()` clears `failed=false` + `pending_cb=nil`. So teardown MUST (a) deliver
`pending_cb` BEFORE `reset()` (else reset nils it → never delivered), and (b) the parse-failure
caller (S5) re-asserts `failed=true` AFTER teardown (S5's D7/GOTCHA #7).

### §1b — S3's read_start wiring + `_reset` (the EOF seam S6 extends)
S3's `ensure` wires `stdout:read_start(function(_, chunk) if chunk then M._feed(chunk) else M._reset() end end)`.
S3's `_reset` (the EOF path) currently:
```lua
function M._reset()
  state.failed = true
  state.proc=nil; state.stdin=nil; state.stdout=nil; state.driver=nil; state.rx_buf=""
end
```
S3's [Mode A] header ANTICIPATES S6: *"S6's `teardown()` will REPLACE/EXTEND this: prepend
`uv.process_kill(proc,'sigkill')` + `pipe:read_stop()` + `pipe:close()`×3 THEN clear state
(on EOF the proc is already dead, so kill is moot; **pipe-close matters for real handles —
S6 owns it**)."* → S6 adds the close to `_reset` via the shared `close_handles()` helper.
**On EOF the proc is dead** (the daemon crashed/exited → libuv delivered `data==nil`), so
`process_kill` is moot there but harmless (pcall); the pipe-close is the real leak fix.

### §1c — S4's `pending_cb` + `req_timer` + `cancel_req_timer` (the finalize contract)
From `lua/pi-bridge/shell.lua` (S4, parallel → treat as contract):
```lua
local req_timer   -- module-local; nil when disarmed. S6 calls cancel_req_timer() FIRST.
local function cancel_req_timer()  -- stop+close the one-shot timer; idempotent; is_closing-guarded
  pcall(function() if req_timer and not req_timer:is_closing() then req_timer:stop(); req_timer:close() end end)
  req_timer = nil
end
...
state.pending_cb = function(items, prefix)   -- S4's gen-guarded ONE-SHOT response cb
  if gen ~= state.gen then return end        -- STALE → drop (slot NOT nil'd)
  cancel_req_timer(); state.pending_cb = nil  -- NULL THE SLOT FIRST (exactly-once)
  state.inflight = false; cb(nil, items, prefix)  -- success-shape
end
```
**THE CONFLICT (see D-conflict below):** the item description says call
`state.pending_cb("teardown", {}, "")`. But S4's pending_cb signature is `(items, prefix)` —
2 params. Passing `("teardown", {}, "")` makes `items="teardown"` (a STRING, not a table) → the
user `cb` receives `cb(nil, "teardown", {})` (items is a string). That is a TYPE BUG. S4 is a
parallel contract S6 MUST NOT modify. → **Resolution (D-conflict): teardown calls
`pcall(state.pending_cb, {}, "")`** (empty items + empty prefix) → user `cb(nil, {}, "")`
(soft-degrade, IDENTICAL to S4's timeout path). The "teardown" err-signal is undeliverable
through S4's closure without modifying it; semantically empty-result == teardown for the
consumer per §17.12. §17.12 does NOT require distinguishing teardown from timeout/degrade.

### §1d — S5's forward-guard + re-assert (S6's caller on the parse-failure threshold)
S5's `_feed`, on N consecutive parse failures (default 5), does:
```lua
state.parse_failures = (state.parse_failures or 0) + 1
if state.parse_failures >= max_parse_failures() then
  state.failed = true
  pcall(function() if type(M.teardown)=="function" then M.teardown() end end)  -- forward-guard
  state.failed = true   -- RE-ASSERT (teardown's reset() cleared it; daemon is DEAD → stay failed)
end
```
So S6's `teardown()` is called from S5's `_feed` (which runs in the `stdout:read_start` luv
callback — FAST context). **FLAG:** teardown must be safe to call from luv fast context (no
`vim.api.*`, all luv calls pcall'd). And S5 re-asserts `failed` after → teardown calling
`reset()` (which clears `failed=false`) is CORRECT (S5 restores it).

---

## §2 Canonical in-repo references

### §2a — `tests/shell_fish_spike.lua` (the REAL luv teardown idiom — with a leak S6 fixes)
Lines 131-148 (the spike's teardown):
```lua
pcall(function() if handle and not handle:is_closing() then uv.process_kill(handle, "sigkill") end end)
pcall(function() if stdin  and not stdin:is_closing()  then stdin:close()  end end)
pcall(function() if stdout and not stdout:is_closing() then stdout:close() end end)
pcall(function() if stderr_pipe and not stderr_pipe:is_closing() then stderr_pipe:close() end end)
```
**Pattern to extract:** `is_closing()` guard + `pcall` on EVERY luv call; `"sigkill"` string;
kill THEN close-pipes. **GOTCHA:** the spike does NOT close the PROC handle (`handle`) — only
`process_kill`s it. §3 proves that LEAKS the `uv_process_t` (is_closing stays false). S6 fixes
this: `close_handles()` ALSO calls `proc:close()` after kill.

### §2b — `lua/pi-bridge/bridge.lua` `M.close()` (THE idempotent-close reference; GOTCHA 2)
`M.close()` (L765+): `if state.closed then return end` (shadow flag set FIRST) + `is_closing()` +
`pcall`. Header GOTCHA 2: *"DOUBLE-CLOSE THROWS: `pipe:close()` on an already-closing handle
raises 'handle 0x.. is already closing'. `close()` is guarded by a shadow `state.closed` flag
(set FIRST) + `is_closing()` + `pcall`. Idempotent across on_close / on_exit / ..."*
→ S6's `close_handles()` mirrors this: each handle guarded by `if h and not h:is_closing()` +
`pcall`. teardown needs NO shadow flag (it nils `state.proc/stdin/stdout` in `reset()` so a 2nd
call sees nil → the `if state.proc` guard is the idempotency; the `is_closing()` guard covers
the window between kill and reset). See D-idempotent.

### §2c — `lua/pi-bridge/completion.lua` `cancel_timer()` L350-360 (the stop-then-close leak fix)
```lua
local function cancel_timer()
  pcall(function()
    if state.debounce_timer and not state.debounce_timer:is_closing() then
      state.debounce_timer:stop(); state.debounce_timer:close()
    end
  end)
  state.debounce_timer = nil
end
```
**Pattern:** `:stop()` THEN `:close()` (NEVER stop-only — leaks the `uv_timer_t`); `is_closing()`
guard + `pcall`. **S6 applies the SAME order to the stdout pipe:** `:read_stop()` THEN
`:close()`. (The item description says `close` then `read_stop` — REVERSED; D-order.)

### §2d — `lua/pi-bridge/notify.lua` (S6 does NOT call — matches S3 `_reset` / S4 `request`)
`M.once(category, level, msg)` — the §11/§17.12 one-time dedup'd notify. **S6 has ZERO
`notify.once` calls** (it sets only `state.failed`/calls `reset()`). The §17.12 one-time
degrade notify is **P2.M2.T3.S4's** job (the routing layer that knows the UX context). Matches
S3's `_reset` (no notify) + S4's `request` (no notify).

### §2e — `tests/shell_ensure_spec.lua` (the test convention + fake-driver/fake-pipe recipe)
`make_fake_driver()` + `fake_pipe()` (read_start/write/close/read_stop/is_closing) + the
`before_each`/`after_each` save/restore (SHELL/bridge/descriptor/config/package.loaded +
`shell.reset()`). S6's tests mirror this for the unit cases. The fake pipes have
`is_closing = function() return false end` + `close = function() end` → they absorb
`close_handles()` calls (S3's `_reset` extension is zero-risk to S3's tests).

---

## §3 LIVE-VERIFIED facts (the `/tmp/teardown_probe.lua` + `/tmp/leak_probe.lua` results)

Run on THIS Neovim (the implementer's environment):

| # | Fact | Proof |
|---|---|---|
| **F1** | `uv.spawn(...)` returns a `uv_process_t` handle (a `uv_handle_t`). | probe: `proc=uv_process_t: 0x..` |
| **F2** | **`uv.process_kill(proc, "sigkill")` does NOT close the handle.** `proc:is_closing()` is `false` BEFORE kill AND `false` AFTER kill. | probe: `is_closing() before kill=false`; `after kill (before close)=false` |
| **F3** | **Even AFTER `on_exit` fires (the process is dead), `proc:is_closing()` is STILL `false`.** The handle is NOT auto-closed. → **MUST call `proc:close()` or it LEAKS.** | probe: `after wait: on_exit_fired=true proc:is_closing()=false` |
| **F4** | `proc:close()` succeeds AFTER kill+on_exit; `proc:is_closing()` becomes `true`. | probe: `proc:close() ok=true`; `is_closing() after close=true` |
| **F5** | **Double-close THROWS:** `proc:close()` twice → `ok=false err="handle 0x.. is already closing"`. Same for `stdout:close()`. → MUST guard `if not h:is_closing()` + `pcall`. | probe: `double proc:close ok=false err=...already closing` |
| **F6** | `read_stop()` THEN `close()` on a read_start-active pipe: both succeed cleanly. | probe: `read_stop stdout ok=true`; `close stdout (after read_stop) ok=true` |
| **F7** | `close()` on a pipe with NO read_start (stdin) also succeeds. So close-order vs read_stop is not fatal for stdin — but `read_stop`-then-`close` is the SAFE order for stdout (the read_start'd pipe). | probe: `close stdin (no read_start) ok=true` |
| **F8** | **`"sigkill"` (lowercase string) is accepted** by `uv.process_kill`. on_exit fires with `sig=9` (SIGKILL). | probe: `process_kill ok=true`; `on_exit fired: code=0 sig=9` |
| **F9** | **`vim.uv.loop` is `nil`** (both as a field and a call). `stdin._loop` is `nil`. `uv.walk(...)` FAILS ("bad argument #1"). `loop:gc_collect()` N/A. `uv.gcollect` doesn't exist. → **§17.15's `vim.uv.loop():gc_collect()` / handle-count-via-walk is UNAVAILABLE in this luv build.** The leak assertion MUST be `is_closing()` on the created handles. | leak_probe: `type(uv.loop)=nil`; `walk ok=false` |
| **F10** | `handle:is_closing()` is `true` after `:close()` → **the robust leak assertion is `assert(proc:is_closing() and stdin:is_closing() and stdout:is_closing())`.** | leak_probe: `after close: stdin:is_closing()=true` |

---

## §4 Design decisions (LOCKED)

**D1 — proc:close() is REQUIRED (not optional).** F2/F3: `process_kill` does NOT close the
`uv_process_t`; it leaks even after on_exit. The fish spike omits this (acceptable in a spike —
nvim exits). **Production teardown MUST `proc:close()`.** This is the headline correctness fix
vs the item description (which only says `process_kill` + pipe-close).

**D2 — close order is `read_stop` → `process_kill` → close pipes → close proc.** The item
description says `state.stdout.close` THEN `state.stdout.read_stop` (reversed). completion.lua's
`cancel_timer` (§2c) + libuv idiom: stop the active op THEN close. S6 reads_stop stdout FIRST
(stops the read cb from re-entering `_feed`/`_reset` mid-teardown), THEN kills, THEN closes pipes,
THEN closes proc.

**D3 — `is_closing()` guard + `pcall` on EVERY luv call (idempotency + double-close safety).** F5:
double-close throws "already closing". bridge.lua GOTCHA 2 (§2b). teardown's idempotency has TWO
layers: (a) `if state.proc` / `if state.stdin` / `if state.stdout` (nil after `reset()` → a 2nd
call skips); (b) `if not h:is_closing()` (covers the window between kill and reset, + the EOF
path where `_reset` already ran). No shadow `closed` flag needed (unlike bridge.lua's persistent
socket — teardown nils the state refs).

**D-conflict — pending_cb invocation: `pcall(state.pending_cb, {}, "")` (NOT `("teardown",{},")`).**
§1c: S4's pending_cb is `(items, prefix)` (2 params); the item's `pending_cb("teardown",{},")`
makes `items="teardown"` (a string — type bug) because S6 must NOT modify S4. Resolution:
`pcall(state.pending_cb, {}, "")` → user `cb(nil, {}, "")` (soft-degrade, identical to S4's
timeout path). §17.12 does not require distinguishing teardown from degrade. pcall'd so a
throwing consumer cb can't escape teardown (never-throws invariant; teardown runs from VimLeave +
luv fast context). Delivered BEFORE `reset()` (reset nils pending_cb).

**D4 — finalize the in-flight request (deliver pending_cb) for the parse-failure path; on VimLeave
it's harmless.** On S5's parse-failure threshold there IS an in-flight request whose cb hasn't
fired (S5 only calls pending_cb on SUCCESS). teardown delivering `{}` finalizes it (the menu
clears instead of dangling). On VimLeave, delivering is harmless (VimLeavePre fires while the
editor is still alive; the consumer cb is the nvim main loop). teardown's pending_cb call runs in
the SAME context S5's `_feed` already invokes it from (luv fast context) — no WORSE than S5; the
consumer schedules its editor work per S4's forward contract.

**D5 — `cancel_req_timer()` FIRST (S4's forward contract).** S4's `request` forward-contract note
(§1c): *"S6's teardown() calls `cancel_req_timer()` BEFORE `uv.process_kill` + `pipe:close`×3 THEN
`reset()`."* Stops the per-request timer from firing mid-teardown (a fire would call pending_cb →
a race with teardown's own deliver). Idempotent (nil-guarded).

**D6 — teardown calls `M.reset()` (full clean slate), NOT the item's subset.** The item lists a
subset (proc/stdin/stdout/rx_buf/gen/inflight/driver). `M.reset()` (S2) clears ALL of those PLUS
shell/cwd/pending_cb/failed/parse_failures — ALL of which SHOULD be cleared on teardown (a stale
shell/cwd/pending_cb would be wrong). reset() clears `failed=false`; S5 re-asserts failed on the
parse-failure path (§1d); on VimLeave failed is moot.

**D7 — extend S3's `_reset()` to close the pipes (the EOF leak S3 deferred to S6).** S3's [Mode A]
header (§1b) explicitly assigns the EOF pipe-close to S6. Without it, a daemon crash mid-session
(EOF) leaves the stdin/stdout/proc handles open for the session (a leak). S6's shared
`close_handles()` local serves BOTH teardown AND `_reset`. ZERO risk to S3's tests (the fake pipes
absorb read_stop/close; S3's assertions — `failed=true`, nil proc, "does NOT call reset" — all hold
since `close_handles()` touches neither `failed` nor calls `reset()`).

**D8 — NEVER throws; runs from luv fast context AND the nvim main loop (VimLeave).** Every luv call
pcall'd + is_closing-guarded; pending_cb pcall'd; state writes are plain assignments. NO `vim.api.*`
(teardown is lifecycle, not UI). NO `vim.schedule` (teardown is synchronous cleanup; the consumer's
cb-scheduling is its own concern per S4). NO notify (§2d).

**D9 — shared `close_handles()` local (DRY; serves teardown + _reset).** One idempotent
kill+read_stop+close×N+close-proc routine. Both teardown (active kill + reset) and _reset (EOF;
proc dead; failed=true; partial clear) call it. Differs only in what they do AROUND it.

---

## §5 The teardown algorithm (+ the shared `close_handles()` helper)

```lua
-- (module-local; declared near cancel_req_timer; used by teardown + _reset)
local function close_handles()
    -- (1) stdout: read_stop THEN close (stop the read cb re-entering _feed/_reset mid-teardown).
    if state.stdout and not state.stdout:is_closing() then
        pcall(function() state.stdout:read_stop() end)
        pcall(function() state.stdout:close() end)
    end
    -- (2) proc: kill THEN close (F2/F3: process_kill does NOT close the uv_process_t — it LEAKS).
    if state.proc and not state.proc:is_closing() then
        pcall(function() uv.process_kill(state.proc, "sigkill") end)  -- unconditional (daemon may be wedged)
        pcall(function() state.proc:close() end)                       -- F3: REQUIRED (the spike omits this)
    end
    -- (3) stdin: close (no read_start on it; is_closing-guarded).
    if state.stdin and not state.stdin:is_closing() then
        pcall(function() state.stdin:close() end)
    end
end

function M.teardown()
    -- (1) cancel the per-request timer FIRST (S4 forward contract: stop a fire racing teardown).
    cancel_req_timer()
    -- (2) finalize the in-flight request (soft-degrade empty; gen-guarded inside pending_cb;
    --     pcall'd so a throwing cb can't escape teardown). BEFORE reset() (reset nils pending_cb).
    if type(state.pending_cb) == "function" then pcall(state.pending_cb, {}, "") end
    -- (3) kill + close the handles (idempotent; is_closing-guarded; pcall'd).
    close_handles()
    -- (4) full clean slate. (S5 re-asserts failed=true after on the parse-failure path; on
    --     VimLeave failed is moot — editor closing.)
    M.reset()
end
```
`_reset` (S3, EXTENDED by S6 — insert `close_handles()` as the FIRST line, before the existing
`state.failed=true` + nil-proc/pipes/driver/rx_buf):
```lua
function M._reset()
    close_handles()               -- S6: close the real handles (the EOF pipe leak S3 deferred here)
    state.failed = true           -- S3 (unchanged): a crash is NOT a clean exit
    state.proc=nil; state.stdin=nil; state.stdout=nil; state.driver=nil; state.rx_buf=""
end
```
Note: `_reset` does NOT call `reset()` (S3's contract — leaves `failed=true`; does NOT clear
shell/cwd/gen/inflight/pending_cb). teardown DOES call `reset()` (clean exit). Both call
`close_handles()`.

---

## §6 Gotchas

1. **(F3) process_kill does NOT close the proc handle — `proc:close()` is REQUIRED.** The fish
   spike omits it (nvim exits). Production MUST close it or the `uv_process_t` leaks for the
   session. D1.
2. **(F5) double-close throws "already closing"** → guard `if not h:is_closing()` + `pcall`
   (bridge.lua GOTCHA 2). D3.
3. **(item vs libuv) close order: `read_stop` THEN `close`, not `close` then `read_stop`.** D2.
4. **(item vs S4) pending_cb signature is `(items, prefix)`, NOT `(err, items, prefix)`.** Call
   `pending_cb({}, "")` (soft-degrade), NOT `pending_cb("teardown",{},")`. D-conflict. pcall it.
5. **(F9) `vim.uv.loop()`/`gc_collect()`/`uv.walk` are UNAVAILABLE** → §17.15's leak assertion is
   `is_closing()` on the created handles, NOT loop walk/gc. F10.
6. **teardown runs from luv FAST context (S5's `_feed` caller) AND the nvim main loop (VimLeave).**
   NO `vim.api.*`; all luv pcall'd; pending_cb pcall'd. D8.
7. **Deliver pending_cb BEFORE `reset()`** (reset nils the slot). D-conflict/D4.
8. **`cancel_req_timer()` FIRST** (S4's forward contract; stops a fire racing teardown). D5.
9. **`M.reset()` clears `failed=false`; S5 re-asserts it after on the parse-failure path.** On
   VimLeave, failed is moot. D6/§1d.
10. **`_reset` (EOF) must NOT call `reset()`** (S3 contract — leaves `failed=true`). S6 only
    PREPENDS `close_handles()`. D7.
11. **TAB indentation** throughout (match shell.lua/completion.lua/bridge.lua).
12. **No lua linter/formatter** (no luacheck/selene/stylua). Validation = smoke + spec.
13. **The fake pipes in shell_ensure_spec absorb close/read_stop** (`is_closing=()=>false`,
    `close=()=>end`) → extending `_reset` is zero-risk to S3's tests. §2e.
14. **stderr is NOT state.stdin/stdout** — the driver owns it (P2.M2.T4). shell.lua only has
    proc/stdin/stdout (S3's ensure stores exactly those). A driver that creates stderr must close
    it itself (or leak one pipe). FORWARD CONTRACT for the driver (§7). Do NOT try to close a
    stderr shell.lua never stored.
15. **`on_exit` is the DRIVER's cb** (the driver's `start` passed it to `uv.spawn`). shell.lua does
    not control it. teardown's `proc:close()` frees the handle regardless of what on_exit does.
16. **Don't shadow `pending`** as a spec-local (plenary.busted's skip fn). Use `got`/`cb`/`captured`.
17. **state is module-local** — teardown tests reach `state.proc` etc. only via the EFFECTS (ensure
    short-circuit "daemon disabled" after failed; is_closing on real handles; fake-pipe call counts).
18. **AGENTS.md HARD RULE:** run tests via `+"luafile tests/shell_teardown_smoke.lua" +qa` (a FILE
    on disk). NEVER heredoc→nvim stdin (hangs). Wrap every nvim in `timeout`.

---

## §7 Forward contracts (do NOT implement; document)

- **P2.M3.T6.S3** (ftplugin VimLeavePre/ExitPre): the CALLER. `autocmd VimLeavePre,ExitPre <buffer>
  lua require("pi-bridge.shell").teardown()`. teardown is IDEMPOTENT for the double-fire
  (VimLeavePre + ExitPre). **S6 guarantees idempotency; the caller just calls it.**
- **S5** (parse-failure threshold): forward-GUARDS `M.teardown` (`if type(M.teardown)=="function"
  then pcall(M.teardown) end`) + re-asserts `failed=true` after. S6 just needs to EXIST + be safe
  from luv fast context.
- **The drivers (P2.M2.T4 fish / P2.M3.T5 zsh/bash):** own stderr (if created). shell.lua's
  teardown closes only proc/stdin/stdout (what S3 stored). A driver that opens a stderr pipe must
  close it on its own exit path (or it leaks ONE pipe on teardown). FLAG for the driver PRP.
- **`:checkhealth` (P2.M3.T6.S2):** reads `state.failed` (cleared by reset; re-asserted by S5 on
  parse-failure; moot on VimLeave). No teardown change needed.

---

## §8 References

- **PRD §17.5.2** (skeleton: "teardown()/on_exit(): kill proc (uv.process_kill SIGKILL), close
  pipes, reset state") + **§17.12** (failure modes: "EOF on the daemon pipe → M._reset(), mark
  unhealthy"; "N consecutive parse failures → daemon killed + marked unhealthy") + **§17.15**
  (shell_daemon_spec: "spawn → 3 sequential requests → teardown (no leaked uv handles)") —
  `prd_snapshot.md` §17 / `architecture/research-prd-section-17.md`.
- **`lua/pi-bridge/shell.lua`** (S2 state+reset; S3 ensure+read_start+_reset; S4 request+pending_cb
  +req_timer+cancel_req_timer; S5 _feed+parse_failures+threshold) — the file S6 edits.
- **`tests/shell_fish_spike.lua`** — the REAL luv teardown idiom (kill+close×N; leaks proc handle —
  S6 fixes). §2a.
- **`lua/pi-bridge/bridge.lua`** `M.close()` + header GOTCHA 2 — idempotent close (shadow flag +
  is_closing + pcall). §2b.
- **`lua/pi-bridge/completion.lua`** `cancel_timer` L350-360 — stop-then-close leak fix. §2c.
- **`tests/shell_ensure_spec.lua`** — test convention + fake-driver/fake-pipe recipe. §2e.
- **`/tmp/teardown_probe.lua`** + **`/tmp/leak_probe.lua`** (this session) — the LIVE-VERIFIED facts §3.