# S39 (PRP path P3M1T1S1) — Graceful failure / single-notify degrade — research notes

> Logical task **P3.M10.T24.S39** ("Graceful failure — degrade to normal buffer with single notify").
> PRP output dir `P3M1T1S1`. Component B (Neovim plugin), Lua side.

## 0. Scope + dependency snapshot (from plan_status + codebase read)

This is a **P3 Polish** task. Its consumers (the handshake S25 and the completion triggers
S30+) are NOT yet built — S25/S26/S27/S28-S37 are all `Planned`/`Implementing`. So S39 ships
the **degrade/notify MECHANISM + state + a documented forward contract**, fully tested in
isolation (and proven to integrate with the EXISTING bridge.lua callbacks). S25/S30 plug in
later by CALLING S39's API — correct dependency order (S39 does not call S25).

CONSUMED (exist NOW, READ VERBATIM):
- `plugin/lua/pi-editor/bridge.lua` (S24, DONE — 235 lines). Transport-only luv client.
  - `M.connect(path, on_ready, on_event, on_close)` — `on_ready(err)` called once (err==nil ok;
    bare errno `"ENOENT"`/`"ECONNREFUSED"`/`"EACCES"` on fail); `on_event(msg)` per decoded
    JSON-RPC msg; `on_close(reason)` on connection lost (`nil`=clean EOF; errno string=error).
    **on_ready/on_close fire on the libuv loop (fast event context)** — see §3.
  - `M.send(obj)->bool`, `M.close()` (idempotent), `M.is_connected()`, `M.on_exit(buf)`.
- `plugin/lua/pi-editor/init.lua` (S19+S21, DONE). Public `require("pi-editor")` module.
  Owns `M.defaults`, `M.config`, `M.bridge`, `M.descriptor`, `M.setup()`, `M.activate()`.
  Ends with `return M` (S21 block is the LAST thing before it). **S39 is ADDITIVE here** (see §1).
- `plugin/tests/minimal_init.lua` (S19) — plenary harness; reused unchanged.

PRODUCED (forward contracts — NOT this task's code, just documented seams):
- S25 handshake will call `bridge.connect(path, on_ready, on_event, on_close)` with hello logic.
  On connect-fail (on_ready err≠nil) / hello-error (on_event) / EOF (on_close) it calls **S39's
  degrade entry**; on hello-success it sets `M.active = true`.
- S30+ completion triggers gate with `if not require("pi-editor").is_active() then return end`.

## 1. WHERE the degrade logic lives — DECISION: extend `init.lua` (NOT a new session.lua)

Considered: (a) new `lua/pi-editor/session.lua`; (b) extend `init.lua`. Chose (b):

- **S21 explicitly grouped S39 with activate()'s resilience.** S21 PRP, repeated: "activate /
  S21+S39 own activate()'s internal resilience (silent degrade / one-time notify)" and "the
  optional one-time vim.notify on hard failure is task S39's job." S39 = the notify layer S21
  deferred. init.lua is activate()'s home → S39's natural home.
- **Stable public API.** Every consumer already does `require("pi-editor")`. completion (S30)
  reads config from there; reading `.active`/`.is_active()` from the SAME module is zero-friction.
  No new require path to invent/remember.
- **Respects the PRD module layout** (PRD §7.2 lists init/bridge/completion/menu/coords/health —
  no session.lua). Adding a surprise module would diverge from the documented surface for no gain.
- **`M.active`/`M.notified` are session-state** — same category as the existing `M.descriptor`
  (parsed-from-env session state). Minimal, additive: 2 fields + 2 small functions.

REJECTED session.lua: cleaner SoC in principle, but over-engineers a 3-field concern into a new
file + new require path that fights the PRD layout and the established "everything hangs off
`require('pi-editor')`" convention (S19/S21/S24/S38 all reference it).

## 2. API added to init.lua (additive, before `return M`)

```lua
-- S39 — graceful-degradation state (PRD §11). "completion disabled" UX.
M.active   = false   -- completion gates on this; set TRUE by the handshake (S25) on hello-ok.
M.notified = false   -- one-time vim.notify guard (PRD §11 "at most a single notify").

--- Degrade entry: ONE vim.notify (WARN) the first time, always set M.active=false. Safe from
--- ANY caller context (vim.schedule's the notify — see §3). Idempotent on the notify.
function M.notify_once() ... end

--- Completion gate: `if not pi.is_active() then return end`. Returns M.active==true.
function M.is_active() return M.active == true end
```

- `M.active` defaults **false** (completion must not run until the handshake confirms — S25 sets
  it true). The contract's "Set M.active = false" is the DEGRADE action; default-false is the
  correct pre-handshake baseline.
- `notify_once()` message is FIXED per contract: `"pi-editor: bridge unavailable, completion
  disabled"` at `vim.log.levels.WARN`. Deliberately stable/non-leaky (no reason text in the user
  message — different failure modes share one UX message; "no spam" + "stable UX" intent).
- `is_active()` is the documented completion gate (named intent > bare field read). `M.active`
  stays a settable field so the handshake does `require("pi-editor").active = true` directly
  (matches how `M.descriptor`/`M.config` are public settable fields on this module).

## 3. CRITICAL — vim.notify THROWS E5560 in a luv callback; MUST vim.schedule (LIVE-VERIFIED)

The bridge's `on_ready(err)` and `on_close(reason)` callbacks run **on the libuv loop (fast
event context)** — same rule S24's GOTCHA 5 documents for `vim.api.*`. Verified just now on
nvim 0.12.4:

```
FASTCTX_NOTIFY_OK=false
FASTCTX_NOTIFY_ERR=[string "vim/_editor"]:550: E5560: nvim_echo must not be called in a fast event context
SCHEDULED_OK=true
```

So a `notify_once` that calls `vim.notify(...)` SYNCHRONOUSLY will THROW when invoked from a
luv callback (on_ready/on_close). A bare pcall would swallow it → the notify is LOST (silent
degrade, but no user message). The user-visible requirement ("a single vim.notify the first
time") would silently never fire in the real (post-S25) wiring.

**FIX (locked):** `notify_once` updates the FLAGS synchronously (`M.notified=true`,
`M.active=false` — plain table writes, safe everywhere) but `vim.schedule`s the
`vim.notify(...)` call to move it off the libuv loop onto the main loop. The flag set is
synchronous so a burst of errors before the scheduled notify runs still produces exactly ONE
notify (the guard fires immediately; the 2nd call sees `notified=true` and skips). The notify
is at-most-once AND actually delivered. `vim.schedule` is safe to call from fast context
(verified — it's a pure queue op, no nvim_echo).

This is THE subtlety that makes or breaks this task. Without it, tests that call
`notify_once` from the MAIN loop pass (vim.notify works there) but the REAL wiring (S25
handshake calling it from on_ready/on_close) silently drops every notify.

## 4. Single-notify / idempotency / flag semantics (from contract)

Contract: "On any bridge error ... if not notified yet → vim.notify(...) and set notified=true.
Set M.active = false."

So:
- The NOTIFY is guarded by `M.notified` (at-most-once across the whole session).
- `M.active = false` is NOT guarded — EVERY error deactivates (it's already false after the
  first, so re-setting is a harmless no-op; but it must run on every call so a transient
  active=true never survives an error).
- `M.notified`/`M.active` set SYNCHRONOUSLY before/at the vim.schedule (so the guard + the
  completion short-circuit take effect immediately, not after the scheduled cb).

Edge: a future "reload"/re-connect (S25 `session_start reason=reload`, or a manual retry)
would need to RESET `notified` so a new failure can notify again. Not in scope for S39 (S25
owns the connect lifecycle), but provide `M.reset_notify()`-style reset? — DECISION: keep
S39 minimal (no reset fn); document that S25 may set `M.notified=false` + `M.active=false`
directly at the top of a reconnect attempt if it wants per-attempt notify. Avoids speculative
API. (If tests need a reset, they set the fields directly — they're public.)

## 5. Test matrix (plenary/busted + a plenary-free smoke)

- `notify_once()` first call → vim.notify fires EXACTLY ONCE with the fixed WARN message.
- `notify_once()` second call → NO further notify (idempotent); `notified` stays true.
- `M.active` set true, then `notify_once()` → `active` becomes false (deactivate), notify
  fires iff not already notified.
- `is_active()` tracks `M.active` (false default, true after set, false after notify_once).
- **Fast-context safety (the §3 gotcha):** call `notify_once()` from inside a `uv.new_timer()`
  callback → NO throw (pcall ok=true), AND the scheduled notify still lands (assert via a
  notify-handler spy + `vim.wait`). This is the test that proves the real wiring will work.
- **Integration with bridge.connect's real callbacks (no S25 needed):** spin the S24 in-process
  luv server helper (mirror bridge_spec.lua), then:
  (a) `bridge.connect("/tmp/nope.sock", on_ready, ...)` with `on_ready=function(err) if err then
      pi.notify_once() end end` → ENOENT → exactly one notify, active=false, is_connected() false.
  (b) server closes the connection mid-session → `on_close=function(reason) pi.notify_once() end`
      fires (EOF, reason nil) → exactly one notify (first time) / none (second time).
  (c) happy path: server accepts, on_ready(nil) → do NOT call notify_once; (S25 would set
      active=true here) → manual `pi.active=true` → `is_active()` true, NO notify.
- Non-regression: init_spec / activate_spec / shim_spec / ftplugin_spec / jsonlreader_spec /
  bridge_spec all still pass (S39 is additive to init.lua; touches nothing else).

## 6. vim.notify capture in tests (the spy)

`vim.notify` is overridable: `local orig = vim.notify; local n=0; vim.notify = function(msg,lvl)
n=n+1; spy.msg=msg; spy.level=lvl end; ... ; vim.notify = orig`. This is the standard nvim test
pattern for asserting notifications (no plugin needed). Because notify_once vim.schedule's the
call, the spy assert must run AFTER `vim.wait` settles the schedule. (The smoke/spec wrap the
override in a pcall + finally-restore so a failing assert can't leak the override.)

## 7. Verified env facts (nvim 0.12.4, this box)

- `vim.notify(msg, vim.log.levels.WARN)` works headless (prints msg; WARN level int = 3).
- `vim.log.levels.WARN` is a stable integer (3).
- `vim.schedule(fn)` callable from a luv timer cb; fn runs on the main loop (verified §3).
- `package.loaded["pi-editor"]=nil; require("pi-editor")` reloads fresh (S21 spec pattern).
- `init.lua` ends with `return M`; the S21 block (descriptor+activate) is the last code before
  it. S39 inserts AFTER activate(), BEFORE `return M` (same GOTCHA-A rule as S21).