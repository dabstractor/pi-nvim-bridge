---
name: "P3.M10.T24.S39 (PRP path P3M1T1S1) — Graceful failure: degrade to normal buffer with single notify"
description: |
  **IMPLEMENT the graceful-degradation MECHANISM + state** for `pi-bridge.nvim` (logical id
  **S39** / P3.M10.T24.S39; PRP output dir `P3M1T1S1`). PRD §11: "If `connect()` fails or `hello`
  errors, the plugin must degrade silently to a normal buffer (no completion), optionally with a
  single `vim.notify` the first time. Never block startup or spam." Also: "pi process dies while
  editor open: the socket closes; the plugin detects EOF on the pipe, stops completion, and may
  notify once." S39 OWNS the resilience layer S21 explicitly deferred: the S21 gate is SILENT
  ("NEVER notifies — the one-time `vim.notify` on hard failure is task S39's job"); S24's
  `bridge.lua` ships the transport callbacks (`on_ready(err)` / `on_close(reason)`) whose contract
  says "on_close = connection lost → S39 one-time notify". S39 is that notify.
  DELIVERABLE — **MODIFY `plugin/lua/pi-editor/init.lua`** (S19/S21 DONE; ADDITIVE, before
  `return M`): add (1) `M.active = false` (completion gates on this; set TRUE by the future
  handshake **S25** on a successful `hello`; default false = completion must not run until the
  handshake confirms), (2) `M.notified = false` (the one-time-notify guard — "at most a single
  notify"), (3) `M.notify_once()` — THE degrade entry: synchronously sets `M.active=false` +
  guards `M.notified`, then **`vim.schedule`s** the `vim.notify("pi-editor: bridge unavailable,
  completion disabled", vim.log.levels.WARN)` (see CRITICAL §Known Gotchas — `vim.notify` THROWS
  `E5560` when called from a luv callback, and the bridge's `on_ready`/`on_close` fire on the
  libuv loop), (4) `M.is_active()` → `return M.active == true` (the documented completion gate).
  Message is FIXED per contract (stable/non-leaky — every failure mode shares one UX message).
  NEW TESTS: `plugin/tests/degrade_smoke.lua` (Level-1 plenary-free) + `plugin/tests/degrade_spec.lua`
  (Level-2 plenary/busted: single-notify, idempotency, active toggling, **fast-context safety**
  (call from a `uv` timer cb → no throw + scheduled notify lands), and **integration with the
  EXISTING `bridge.connect` callbacks** — ENOENT on_ready → one notify; server-close EOF on_close
  → one notify; happy path → no notify).
  STATUS (planning): every nvim behavior is **LIVE-VERIFIED** on nvim 0.12.4 — the E5560-on-notify
  gotcha, `vim.schedule`-from-fast-ctx, `vim.log.levels.WARN` (=3), the `vim.notify` override-spy
  pattern, and the bridge.connect callback shapes were all READ from S24's landed `bridge.lua`.
  NARROW scope guard — S39 does NOT: connect to the bridge (S24 DONE), do the `hello` handshake
  (S25 — the consumer that calls `notify_once` on connect/handshake failure and sets `active=true`
  on success), correlate RPC by id (S26), implement completion triggers (S30+ — the consumer that
  gates on `is_active()`), or wire `connect()` into `activate()` (S25). S39 ships the tested
  degrade/notify mechanism + a documented forward contract S25/S30 consume. Touches ONLY
  `init.lua` (additive) + 2 new test files.
---

## Goal

**Feature Goal**: Add the graceful-failure / single-notify resilience layer to
`pi-bridge.nvim` so that **any** bridge connection failure (connect refused, bad handshake, or
the pi process dying mid-session → pipe EOF) degrades the buffer to a *normal, fully-editable*
markdown buffer with **no** completion and **at most one** `vim.notify(WARN)` the first time —
never blocking startup, never spamming. This is the PRD §11 "silent degradation" requirement,
and it is the notify S21's activation gate deliberately stayed silent for ("the optional
one-time `vim.notify` on hard failure is task S39's job").

**Deliverable** (3 files — 1 MODIFY + 2 NEW; NO change to any other source module):
- **MODIFY** `plugin/lua/pi-editor/init.lua` (S19/S21 DONE — extend, do NOT rewrite):
  ADD (before `return M`, after `M.activate()` — same GOTCHA-A splice rule as S21):
  - `M.active = false` — public field. Completion (S30+) gates on this; the handshake (S25)
    sets it `true` on a successful `hello`. Default `false` (completion must not run until the
    handshake confirms the bridge is live).
  - `M.notified = false` — public field. The "at most once" guard for the user-facing notify.
  - `M.notify_once()` — the **degrade entry**. Synchronously sets `M.active = false` (every call
    deactivates — a transient `active=true` never survives an error) and, **iff `not M.notified`**,
    sets `M.notified = true` and `vim.schedule`s the fixed `vim.notify` WARN. Idempotent on the
    notify. Safe to call from ANY context (luv callback OR main loop) because the notify is
    scheduled (see CRITICAL gotcha §Known Gotchas). Never throws.
  - `M.is_active()` → `return M.active == true` — the documented completion gate
    (`if not require("pi-editor").is_active() then return end`). Named intent > bare field read.
  - [Mode A] LuaCATS docstrings + a degradation-strategy header block (the DOCS requirement).
- **NEW** `plugin/tests/degrade_smoke.lua` — plenary-FREE standalone smoke (Level-1 gate;
  `:luafile`-sourced; asserts single-notify + idempotency + active toggle + the message/level).
- **NEW** `plugin/tests/degrade_spec.lua` — plenary/busted spec (Level-2 gate): the full matrix
  incl. **fast-context safety** (call `notify_once()` from a `uv.new_timer()` cb → no throw +
  scheduled notify lands) and **integration with `bridge.connect`'s real callbacks** (ENOENT
  `on_ready` → one notify; server-close EOF `on_close` → one notify; happy path → no notify).

> Reuses `plugin/tests/minimal_init.lua` (S19) unchanged. Reuses the EXISTING `bridge.lua`
> (S24, DONE) in the integration tests (spins the in-process luv server helper, mirror of
> `bridge_spec.lua`). NO change to `bridge.lua`, `init.lua`'s existing setup/defaults/config/
> bridge/descriptor/activate, the S20 shim, the ftplugin, jsonlreader, or any completion/menu/
> coords module. **S25 (handshake) and S30+ (completion) do not exist yet** — S39 ships the
> tested mechanism + a documented forward contract they will consume (S39 does not call them).

**Success Definition** (every assertion is LIVE-VERIFIED — see `research/notes.md` + Validation):
- **First degrade → exactly one notify:** a fresh module, `vim.notify` spy installed,
  `M.notify_once()` → the spy fires EXACTLY ONCE with `msg == "pi-editor: bridge unavailable,
  completion disabled"` and `level == vim.log.levels.WARN` (=3); `M.notified == true`;
  `M.is_active() == false`; `M.active == false`.
- **Idempotent notify:** a SECOND `notify_once()` (same session) → spy NOT called again
  (count stays 1); `notified` stays true; `active` stays false (no spam — PRD §11).
- **Deactivate is unconditional:** set `M.active = true`, then `notify_once()` (fresh module so
  notify fires) → `M.is_active()` is `false` after (every error deactivates, even if a prior
  handshake had set active true).
- **Defaults:** a freshly-required module has `active == false`, `notified == false`,
  `is_active() == false` (completion short-circuits until the handshake says otherwise).
- **Fast-context safe (CRITICAL — §Known Gotchas):** call `notify_once()` from inside a
  `uv.new_timer()` callback (simulating the bridge's `on_ready`/`on_close` libuv-loop context):
  `pcall(notify_once)` returns `ok=true` (NO `E5560` throw), AND the scheduled `vim.notify`
  still lands (spy fires after `vim.wait` settles). This is the test that proves the REAL
  post-S25 wiring will not silently drop the notify.
- **Integration — connect-fail (ENOENT):** spin the S24 in-process luv server helper, then
  `bridge.connect("/tmp/nope-<ts>.sock", function(err) if err then require("pi-editor").notify_once() end end, ...)`:
  the `on_ready` fires with `err == "ENOENT"` → `notify_once()` runs → exactly one WARN notify,
  `is_active() == false`, `bridge.is_connected() == false`.
- **Integration — EOF (pi process dies):** server accepts, client connects, then the SERVER
  closes its connection → the client's `on_close` fires with `reason == nil` (clean EOF);
  wire `on_close = function() require("pi-editor").notify_once() end` → exactly one notify
  (first time). A second EOF/close in the same session → no additional notify (idempotent).
- **Integration — happy path → no notify:** server accepts, `on_ready(nil)` fires; do NOT call
  `notify_once`; instead set `M.active = true` (what S25 will do on hello-ok) → `is_active()`
  true, spy NOT called, `notified` false.
- **No throw ever:** `pcall(M.notify_once)` is `ok=true` from both the main loop AND a luv cb.
- **Non-regression:** `init_spec` (S19), `shim_spec` (S20), `activate_spec` (S21),
  `ftplugin_spec` (S22), `jsonlreader_spec` (S23), `bridge_spec` (S24) all still pass unchanged.
- Smoke prints `SMOKE_PASS` / exit 0; `degrade_spec.lua` exits 0.
- [Mode A] header + per-field/per-method LuaCATS docstrings present.

## User Persona (if applicable)

**Target User**: A pi user who opens the external editor (`Ctrl+G`) to draft a prompt. They
expect: (a) the buffer is **always** a usable markdown editor, and (b) when completion can't
work (pi's bridge died, the socket is stale, the handshake failed), they get **one** gentle
warning — not a crash, not a spam of errors, not a hung editor. They never see this code; they
experience it as "the editor still works, and it told me once that completion is off."

**Use Case**: The resilience layer of the prompt-editor lifecycle. S21 (gate) → S22 (buffer) →
S24 (transport) → S25 (handshake) → … → S30+ (completion). **S39** is what every failure path
funnels into: connect refused, bad token, EOF. Without S39, a dead bridge either (a) spams
errors on every keystroke (completion retries), (b) crashes the libuv callback (`E5560`), or
(c) silently does nothing (the user never learns why completion is gone). S39 makes the
degrade **graceful + communicated once**.

**Pain Points Addressed**:
1. **Error spam** (PRD §11 "Never block startup or spam"): repeated completion retries against
   a dead bridge would notify on every keystroke. S39's `notified` guard caps it at one.
2. **Crash on notify from a luv callback** (the §Known Gotchas E5560 trap): the bridge's
   `on_ready`/`on_close` run on the libuv loop; a naive `vim.notify` there throws `E5560` and
   the notify is lost. S39 `vim.schedule`s it (LIVE-VERIFIED).
3. **Hung editor**: S39 sets `M.active=false` so completion short-circuits instead of retrying
   a dead socket forever.
4. **Lost-prompt confusion**: even when completion is off, the buffer is still a normal file —
   the user can still type, `:w`, and quit (S38's autosave still works). S39 only disables
   *completion*, never editing.

## Why

- **PRD §11 is explicit and was deferred to S39.** "degrade silently ... optionally with a single
  `vim.notify` the first time. Never block startup or spam." S21's gate STAYED silent precisely
  so S39 could own the notify without double-notifying ("S21's baseline is SILENT (return nil);
  S39 layers the notify later"). S24's `bridge.lua` callback contract explicitly names S39
  ("on_close = connection lost → S39 one-time notify"). S39 fulfills both forward contracts.
- **The notify has a non-obvious correctness trap (E5560).** The bridge callbacks run on the
  libuv loop; `vim.notify` there throws `E5560: nvim_echo must not be called in a fast event
  context` (LIVE-VERIFIED — see §Known Gotchas). A naive impl passes main-loop tests but
  silently drops every notify in the real wiring. S39 `vim.schedule`s the notify — the one
  detail that makes the "single notify" actually reach the user. Nailing it now (with a
  fast-context test) de-risks S25.
- **Completion needs a clean off-switch.** PRD §11: "stops completion." S39's `M.active=false`
  (default false; handshake sets true) gives S30+ a one-line gate (`if not is_active() then
  return end`). Without it, every trigger would have to re-derive "is the bridge alive?"
- **Integrates with the (complete) foundation, additively.** Consumes S24's `bridge.lua`
  callbacks (in tests, today) and S21's `init.lua` (the public module). Touches nothing else.
  Establishes the forward contract S25 (handshake → calls `notify_once` on failure / sets
  `active=true` on success) and S30 (completion → gates on `is_active()`) will consume.

## What

User-visible behavior:
- The pi-prompt buffer is **always** a normal editable markdown buffer. Completion is an
  *enhancement* layered on top, never a requirement for editing.
- When the bridge can't be used (connect refused / handshake failed / pi process died → EOF),
  the user sees **at most one** notification: `pi-editor: bridge unavailable, completion
  disabled` (WARN level). Subsequent failures in the same session are silent.
- Completion never appears (and never retries) while `is_active()` is false.
- The editor never crashes, never hangs, never spams.

Technical requirements (exact, LIVE-VERIFIED; READ from S24's landed `bridge.lua` + S21's
`init.lua` — seam names are real, not assumed):
- **`init.lua`** gains, before `return M` (after `M.activate()`), an additive S39 block:
  `M.active = false`, `M.notified = false`, `M.notify_once()`, `M.is_active()`. NO change to
  `setup`/`defaults`/`config`/`bridge`/`descriptor`/`activate` (additive only — §Non-regression).
- **`M.notify_once()`** body (LIVE-VERIFIED pattern — see Implementation Patterns):
  synchronously: `M.active = false`; if `not M.notified` then `M.notified = true` and
  `vim.schedule(function() pcall(vim.notify, "<fixed msg>", vim.log.levels.WARN) end)`.
  The flag writes are plain table ops (safe in any context); the `vim.notify` is scheduled
  (E5560-safe — the callbacks that call this run on the libuv loop). Never throws.
- **`M.is_active()`** → `return M.active == true`.
- **Fixed message** per contract: `"pi-editor: bridge unavailable, completion disabled"`,
  `vim.log.levels.WARN` (=3, verified). No per-reason text in the user message (stable UX,
  non-leaky; every failure mode shares one message — "no spam" + "stable UX" intent).
- **[Mode A]**: a degradation-strategy header block (why one notify, why scheduled, why
  `active` defaults false, the S21/S24 forward contracts S39 fulfills) + per-field/per-method
  LuaCATS docstrings.

### Success Criteria
- [ ] `require("pi-editor").notify_once` is a function; `.is_active` is a function; `.active` and
      `.notified` are boolean fields defaulting `false` on a fresh module.
- [ ] First `notify_once()` (fresh module, spy installed) → spy fires EXACTLY ONCE with the fixed
      WARN message; `notified==true`; `active==false`; `is_active()==false`.
- [ ] Second `notify_once()` (same session) → spy NOT called again (idempotent); flags unchanged.
- [ ] `notify_once()` sets `active=false` unconditionally (set `active=true`, call it on a fresh
      module → `is_active()==false` after).
- [ ] `notify_once()` from a luv timer callback → `pcall` ok=true (no E5560); scheduled notify
      lands (spy fires after `vim.wait`).
- [ ] `notify_once()` never throws from any context (pcall ok=true).
- [ ] Integration: `bridge.connect` ENOENT → `on_ready("ENOENT")` → `notify_once()` → one notify,
      `is_active()==false`, `bridge.is_connected()==false`.
- [ ] Integration: server-close EOF → `on_close(nil)` → `notify_once()` → one notify (first) /
      none (second, idempotent).
- [ ] Integration: happy path (`on_ready(nil)`, set `active=true`) → NO notify; `is_active()==true`.
- [ ] Non-regression: `init_spec`, `shim_spec`, `activate_spec`, `ftplugin_spec`,
      `jsonlreader_spec`, `bridge_spec` all still pass.
- [ ] `degrade_smoke.lua` prints `SMOKE_PASS` / exit 0; `degrade_spec.lua` exits 0.
- [ ] [Mode A] header + LuaCATS docstrings present.

## All Needed Context

### Context Completeness Check
_Passes "No Prior Knowledge":_ an implementer who has never seen this repo needs only this PRP +
`research/notes.md` + the verified commands. `init.lua` (S19/S21) was READ VERBATIM — the
existing public surface (`setup`/`defaults`/`config`/`bridge`/`descriptor`/`activate`/`return M`)
and the exact splice point (after `activate()`, before `return M`) are quoted, not assumed.
`bridge.lua` (S24) was READ VERBATIM — the real `connect(path, on_ready, on_event, on_close)`
signature, `is_connected()`, and the `on_ready(err)`/`on_close(reason)` callback contracts
(err==nil ok; bare errno `"ENOENT"`/`"ECONNREFUSED"` on connect-fail; `reason==nil`=clean EOF)
are the REAL seam names the integration tests wire. The ONE subtlety that makes or breaks this
task — `vim.notify` THROWS `E5560` from a luv callback (the bridge callbacks' context), so
`notify_once` MUST `vim.schedule` the notify — is LIVE-VERIFIED (`research/notes.md` §3) with the
exact error string, and embedded in the reference implementation + a dedicated test.

### Documentation & References
```yaml
# MUST READ — PRD (read-only; the source of truth for behavior)
- url: "PRD.md §11 (heading:h2.11) — Edge Cases: 'Stale/missing socket' + 'pi process dies'"
  why: "THE requirement. 'If connect() fails or hello errors, the plugin must degrade silently to
        a normal buffer (no completion), optionally with a single vim.notify the first time. Never
        block startup or spam.' And: 'pi process dies while editor open: the socket closes; the
        plugin detects EOF on the pipe, stops completion, and may notify once.' S39 IS this."
  critical: "'single vim.notify the first time' = the `notified` guard. 'stops completion' =
             `M.active=false`. 'never spam' = idempotent notify. Copy the degrade strategy into
             the [Mode A] header (DOCS requirement)."
- url: "PRD.md §7.2 (heading:h3.18) — Module layout"
  why: "init.lua = 'setup() + VimEnter activation'; completion.lua = 'triggers, debounce, accept
        flow'. Confirms `active`/`notify_once` belong on the init module (the public API completion
        already requires), NOT a new file. S39 is additive to init.lua."
- url: "PRD.md §7.4 (heading:h3.20) — completion.lua triggers"
  why: "The future consumer of `is_active()`. 'InsertEnter/TextChangedI/CursorMovedI → schedule a
        debounced getSuggestions' — S30+ will prefix each trigger with `if not
        require('pi-editor').is_active() then return end`. S39 provides that gate."

# MUST READ — codebase (the files S39 touches + the seams it consumes, READ VERBATIM)
- file: "plugin/lua/pi-editor/init.lua   (S19/S21 DONE — the file S39 EXTENDS)"
  why: "The public `require('pi-editor')` module. Contains setup/defaults/config/bridge/descriptor/
        activate, and ENDS WITH `return M`. The S21 block (descriptor + activate) is the LAST code
        before `return M`. S39 splices in AFTER activate(), BEFORE return M (same GOTCHA-A rule as
        S21: appending after `return M` is a syntax error)."
  pattern: |
    -- existing tail of init.lua:
    function M.activate() ... return desc end
    return M
    -- S39 splices the degrade block BETWEEN activate() and `return M`.
  critical: "ADDITIVE only. Do NOT touch setup/defaults/config/bridge/descriptor/activate. The new
    fields (active/notified) + functions (notify_once/is_active) are plain additions on M."
- file: "plugin/lua/pi-editor/bridge.lua   (S24 DONE — CONSUMED by the integration tests)"
  why: "The transport whose callbacks S39's notify will be wired to (by S25). READ the REAL seam:"
  pattern: |
    function M.connect(path, on_ready, on_event, on_close)   -- on_ready(err) once; on_close(reason)
      ... pipe:connect(path, function(connerr)
        if connerr then local cb=state.on_ready; M.close(); if cb then cb(connerr) end; return end
        ... state.connected=true; if state.on_ready then state.on_ready(nil) end
      end) ...
    end
    -- read_cb: err -> on_close(err)+teardown; data==nil (EOF) -> rx:flush()+on_close(nil)+teardown.
    function M.is_connected() return state.connected and not state.closed end
  critical: "on_ready/on_close fire on the LIBUV LOOP (fast event context). That is WHY notify_once
    must vim.schedule the notify (E5560 — see Known Gotchas). The integration tests wire these
    callbacks to `notify_once()` to PROVE the real post-S25 path works."
- file: "plugin/tests/bridge_spec.lua   (S24 spec — the in-process luv SERVER helper to MIRROR)"
  why: "Shows the `with_server(spec)` helper that spins a real luv unix-socket server in-process
        (the ONLY way to exercise connect/on_ready/on_close without the real bridge extension).
        S39's integration tests REUSE that exact helper pattern. Mirror its per-test unique socket
        path + stop-hook structure."
- file: "plugin/tests/activate_spec.lua   (S21 spec — non-regression + the vim.notify spy PATTERN)"
  why: "Shows the `before_each` reset (`package.loaded['pi-editor']=nil; require fresh`) + the
        env-var injection pattern. For the notify spy, override `vim.notify` (see notes §6) —
        activate_spec doesn't (S21 is silent), but the override-and-restore pattern is standard."
- file: "plugin/tests/minimal_init.lua   (S19 — plenary harness; REUSED unchanged)"

# Research (this PRP's own notes — LIVE-VERIFIED)
- docfile: "plan/001_c56962b4fa17/P3M1T1S1/research/notes.md"
  why: "Codebase analysis + the E5560-on-notify LIVE-VERIFIED probe + the locked API design +
        test matrix + the fast-context safety rationale."
  section: "§1 (why init.lua not session.lua), §2 (the API), §3 (the E5560 gotcha — CRITICAL),
            §5 (test matrix), §6 (the vim.notify spy)."
```

### Current Codebase tree (run `tree -L 3 plugin`)
```bash
plugin
├── ftplugin
│   └── pi-prompt.lua          # S22 (DONE) — untouched
├── lua
│   └── pi-editor
│       ├── init.lua           # S19/S21 (DONE) — S39 EXTENDS (add M.active/notified/notify_once/is_active)
│       ├── bridge.lua         # S24 (DONE) — CONSUMED by integration tests (connect callbacks)
│       └── jsonlreader.lua    # S23 (DONE) — untouched
├── plugin
│   └── pi-editor.lua          # S20 (DONE) — untouched
└── tests
    ├── minimal_init.lua       # S19 (DONE) — plenary harness; reused unchanged
    ├── init_spec.lua          # S19 spec (non-regression)
    ├── shim_spec.lua          # S20 spec (non-regression)
    ├── activate_spec.lua      # S21 spec (non-regression) + spy/reset PATTERN to mirror
    ├── ftplugin_spec.lua      # S22 spec (non-regression)
    ├── jsonlreader_spec.lua   # S23 spec (non-regression)
    ├── bridge_spec.lua        # S24 spec (non-regression) + in-process luv server helper to MIRROR
    └── smoke.lua              # S19 generic smoke (Level-1 helper pattern)
```

### Desired Codebase tree with files to be added/modified
```bash
plugin
├── lua
│   └── pi-editor
│       └── init.lua           # MODIFY: +M.active, +M.notified, +M.notify_once(), +M.is_active() (additive, before return M)
└── tests
    ├── degrade_smoke.lua      # NEW — Level-1 headless smoke (prints SMOKE_PASS)
    └── degrade_spec.lua       # NEW — Level-2 plenary/busted spec (matrix + fast-ctx + bridge integration)
```

### Known Gotchas of our codebase & Library Quirks
```lua
-- CRITICAL (E5560 — LIVE-VERIFIED research/notes.md §3): vim.notify THROWS when called from a
--   luv callback (fast event context). Verified on nvim 0.12.4:
--     FASTCTX_NOTIFY_OK=false
--     FASTCTX_NOTIFY_ERR=[string "vim/_editor"]:550: E5560: nvim_echo must not be called in a fast event context
--   The bridge's on_ready(err) / on_close(reason) callbacks fire ON THE LIBUV LOOP (S24 GOTCHA 5
--   documents the same rule for vim.api.*). So a notify_once() that calls vim.notify(...) SYNCHRONOUSLY
--   will throw there; a bare pcall swallows it -> the notify is LOST (silent degrade, no user message).
--   FIX: notify_once sets the FLAGS synchronously (plain table writes — safe everywhere) but
--   vim.schedule(function() pcall(vim.notify, msg, lvl) end) the notify. vim.schedule is callable
--   from fast context (verified — pure queue op). The flag set is synchronous so a burst of errors
--   before the scheduled cb runs still yields EXACTLY ONE notify (the guard fires immediately).
--   THIS IS THE LOAD-BEARING DETAIL OF THE WHOLE TASK. A main-loop-only test passes either way;
--   the dedicated fast-context test (call from a uv timer cb) is what catches a naive impl.

-- GOTCHA 1 (splice BEFORE return M — same as S21 GOTCHA A): init.lua ends with `return M`. Lua
--   requires `return` to be the FINAL statement of a chunk. Appending after it is a syntax error
--   ("'<eof>' expected near 'M'"). Splice the S39 block AFTER M.activate()'s `end`, BEFORE `return M`.

-- GOTCHA 2 (default active=false, not true): M.active defaults FALSE. Completion must NOT run
--   until the handshake (S25) confirms the bridge (it sets active=true on hello-ok). The contract's
--   "Set M.active=false" is the DEGRADE action (what notify_once does on error); default-false is the
--   correct PRE-handshake baseline. Do NOT default it true (that would run completion before connect).

-- GOTCHA 3 (deactivate is UNCONDITIONAL; notify is GUARDED): notify_once sets M.active=false on EVERY
--   call (so a transient active=true from a half-successful handshake never survives a later error).
--   Only the vim.notify is guarded by M.notified ("at most once"). Do NOT guard the active=false.

-- GOTCHA 4 (fixed message, no per-reason text): the contract specifies the EXACT message
--   "pi-editor: bridge unavailable, completion disabled" at vim.log.levels.WARN. Do NOT inject the
--   errno/reason into the user message (leaky, unstable UX). Different failure modes share one
--   message — that's the "no spam + stable UX" intent. (A future task may add debug logging of the
--   reason; S39 keeps the user message fixed.)

-- GOTCHA 5 (vim.schedule defers the notify — assert AFTER it settles): because notify_once schedules
--   the notify, a test that asserts the spy fired must `vim.wait` (or loop) for the schedule to run
--   before asserting. Asserting immediately after notify_once() will see spy count == 0 (the cb hasn't
--   run yet). Pattern: `pi.notify_once(); vim.wait(50, function() return spy.count>=1 end, 5)`.

-- GOTCHA 6 (vim.notify override-restore in tests): to assert the notify, override vim.notify with a
--   spy, run the scenario, wait for the schedule, assert, then RESTORE the original in a finally/pcall
--   so a failing assert can't leak the override into other tests. `local orig=vim.notify; vim.notify=
--   function(m,l) ... end; local ok=pcall(...); vim.notify=orig`. (Field is public + overridable.)

-- GOTCHA 7 (notified is per-SESSION, not per-call): once notified==true it STAYS true for the session.
--   A reload/reconnect (future S25 session_start reason=reload) that wants per-attempt notify would
--   reset M.notified=false (and M.active=false) at the top of a reconnect attempt. S39 does NOT add a
--   reset function (speculative API; S25 owns the connect lifecycle and can set the public fields
--   directly). Tests reset by reloading the module (`package.loaded['pi-editor']=nil`) or setting the
--   fields directly (they're public).

-- GOTCHA 8 (do NOT wire connect() into activate() — S25's job): S39 ships the MECHANISM + state + a
--   documented forward contract. It does NOT call bridge.connect from activate() (S25 does, with the
--   hello handshake) and does NOT implement completion triggers (S30+). The integration TESTS wire
--   notify_once to bridge.connect's callbacks to PROVE the mechanism works end-to-end; the shipped
--   code only adds the fields/functions to init.lua. Do not pre-empt S25/S30.

-- GOTCHA 9 (reuse bridge_spec's server helper, don't reinvent): the integration tests need a real luv
--   unix-socket server in-process. bridge_spec.lua (S24) already has the `with_server(spec)` pattern
--   (unique socket path, listen, accept, read_start->jsonlreader, echo responses, stop-hook). Mirror
--   it; do not invent a second server harness.

-- GOTCHA 10 (no vim.api.* in notify_once's synchronous path): the flag writes are plain Lua table
--   ops (safe everywhere). The ONLY nvim-touching call is the scheduled vim.notify (safe on the main
--   loop). Do NOT add nvim_buf/nvim_win calls (none are needed; degrade touches NO buffer — the buffer
--   is already a normal editable file, S39 just disables completion).
```

## Implementation Blueprint

### Data models and structure
No new data models. S39 adds two boolean fields (`M.active`, `M.notified`) and two functions
(`M.notify_once()`, `M.is_active()`) to the existing `init.lua` module table. State is
module-level singleton (one pi editor session = one bridge connection — PRD §11 "v1 supports
completion in the buffer active at VimEnter"; same singleton rationale as S24's bridge.lua).
No tables, no classes, no ORM.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY plugin/lua/pi-editor/init.lua  (THE deliverable — the degrade mechanism)
  - The file EXISTS (S19/S21). LOCATE the final `return M` (GOTCHA 1 — splice BEFORE it).
  - INSERT (immediately AFTER M.activate()'s `end`, BEFORE `return M`):
      (1) a [Mode A] degradation-strategy header comment block (why one notify; why scheduled
          (E5560); why active defaults false; the S21/S24 forward contracts S39 fulfills; the
          S25/S30 forward contracts S39 establishes);
      (2) M.active = false  + LuaCATS;
      (3) M.notified = false + LuaCATS;
      (4) function M.notify_once() ... end + LuaCATS (see Implementation Patterns);
      (5) function M.is_active() return M.active == true end + LuaCATS.
  - notify_once BODY (exact — LIVE-VERIFIED):
        M.active = false                                  -- GOTCHA 3: unconditional deactivate
        if not M.notified then                            -- GOTCHA: at-most-once notify
          M.notified = true
          local msg, lvl = "pi-editor: bridge unavailable, completion disabled", vim.log.levels.WARN  -- GOTCHA 4
          vim.schedule(function() pcall(vim.notify, msg, lvl) end)   -- CRITICAL: E5560-safe (§Known Gotchas)
        end
  - DOCSTRINGS: [Mode A] LuaCATS on every field/function. The header block must explain:
      * PRD §11 ("single vim.notify the first time", "never spam", "stops completion");
      * why the notify is vim.schedule'd (the bridge callbacks run on the libuv loop; vim.notify
        throws E5560 there — without scheduling the notify is silently lost);
      * why active defaults false (the handshake S25 sets it true on hello-ok; completion must not
        run until then);
      * the FORWARD CONTRACT: S25 calls notify_once() on connect-fail/handshake-fail/EOF and sets
        M.active=true on hello-success; S30+ gates triggers with `if not is_active() then return end`.
  - FOLLOW pattern: S21's activate() docstring style + the `local M = {}`/`return M` module shape.
  - NAMING: keep the contract's exact names — `M.active`, `M.notified`, `M.notify_once`, `M.is_active`.
  - DO NOT touch setup/defaults/config/bridge/descriptor/activate (additive only — §Non-regression).
  - DO NOT add a reset function (GOTCHA 7 — speculative; S25 sets the public fields directly).
  - DO NOT call bridge.connect or vim.api.* (GOTCHA 8/10).
  - PLACEMENT: plugin/lua/pi-editor/init.lua (splice before return M).

Task 2: CREATE plugin/tests/degrade_smoke.lua  (plenary-FREE fast smoke — the Level-1 gate)
  - CONTENT (see Implementation Patterns): standalone script. Computes plugin_root from its own
        path (debug.getinfo + fnamemodify ':p'/':h:h'), appends to runtimepath, requires "pi-editor"
        fresh (package.loaded=nil), installs a vim.notify spy (count+msg+level), runs:
        (a) defaults: active==false, notified==false, is_active()==false;
        (b) first notify_once -> after vim.wait, spy.count==1, msg+level correct, notified==true,
            active==false, is_active()==false;
        (c) second notify_once -> spy.count STILL 1 (idempotent);
        (d) set active=true, reload fresh module, notify_once -> is_active()==false after.
        Prints SMOKE_PASS; cquit(1) on any check failure (reliable exit). RESTORE vim.notify finally.
  - WHY: instant, dependency-free feedback (no plenary). degrade_spec.lua is the formal suite.
  - GOTCHA: source via :luafile, NOT a :lua <<HEREDOC in a -c/+ arg (inherited S19 GOTCHA #10).
  - GOTCHA: assert the spy AFTER vim.wait (the notify is scheduled — GOTCHA 5).
  - PLACEMENT: plugin/tests/degrade_smoke.lua.
  - DEPENDENCIES: Task 1 (the modified init.lua).

Task 3: CREATE plugin/tests/degrade_spec.lua  (plenary/busted spec — the Level-2 gate)
  - CONTENT (see Implementation Patterns): a describe("pi-editor degrade / notify_once", ...).
        before_each: package.loaded["pi-editor"]=nil; require fresh; install+restore vim.notify spy;
        reset active/notified to false. Cover ALL Success Criteria as `it` blocks:
        (1) defaults (active/notified false, is_active false);
        (2) first notify_once -> exactly one WARN notify with the fixed message; notified/active/is_active;
        (3) second notify_once -> spy NOT called again (idempotent);
        (4) deactivate unconditional (set active=true -> notify_once -> is_active false);
        (5) **fast-context safety**: call notify_once from a uv.new_timer() cb -> pcall ok=true (no
            E5560) AND scheduled notify lands (spy fires after vim.wait);
        (6) notify_once never throws (pcall ok=true from main loop AND luv cb);
        (7) **integration — ENOENT**: bridge.connect("/tmp/nope-<ts>.sock", on_ready=notify_on_err,
            ...) -> on_ready("ENOENT") -> notify_once -> one notify, is_active false, is_connected false;
        (8) **integration — EOF**: with_server -> connect -> server closes -> on_close(nil) ->
            notify_once -> one notify (first) / none (second, idempotent);
        (9) **integration — happy path**: with_server -> connect -> on_ready(nil) -> do NOT notify;
            set active=true -> is_active true, spy NOT called.
  - ASSERTIONS: assert.are.equals (msg/level/count), assert.is_true/is_false, assert.has_no.errors
        for the no-throw checks (and pcall-ok asserts for the luv-cb cases). Use the with_server
        helper (mirror bridge_spec.lua S24) for the integration cases.
  - FOLLOW pattern: plugin/tests/bridge_spec.lua (S24) for the in-process luv server + the
        async vim.wait pacing; plugin/tests/activate_spec.lua (S21) for the before_each reset.
  - NAMING: describe("pi-editor degrade / notify_once"); it("…") per case.
  - PLACEMENT: plugin/tests/degrade_spec.lua.
  - DEPENDENCIES: Task 1 + the S19 harness (plugin/tests/minimal_init.lua) + the S24 bridge.lua
        (DONE — consumed by the integration cases).
```

### Implementation Patterns & Key Details
```lua
-- ===== plugin/lua/pi-editor/init.lua (S39 — ADD the degrade block before `return M`) =====
-- Splice this AFTER M.activate()'s closing `end` and BEFORE the final `return M`. ADDITIVE.

-- ===========================================================================
-- S39 — Graceful failure / single-notify degradation (PRD §11). The resilience
-- layer S21's gate stayed silent for ("NEVER notifies — the one-time vim.notify on
-- hard failure is task S39's job") and S24's bridge callback contract names
-- ("on_close = connection lost -> S39 one-time notify"). Any bridge failure
-- (connect refused, bad handshake, pi process died -> pipe EOF) funnels here.
--
-- STRATEGY:
--  * ONE notify, ever (per session): the `notified` guard caps the WARN message at
--    a single delivery (PRD §11 "never spam"). The fixed message —
--    "pi-editor: bridge unavailable, completion disabled" — is stable/non-leaky;
--    every failure mode shares it.
--  * STOP completion: `M.active = false` (set on EVERY error + default-false) so
--    the completion triggers (S30+) short-circuit via `is_active()` instead of
--    retrying a dead socket forever. The handshake (S25) sets `active=true` on a
--    successful `hello`; until then completion stays off.
--  * NEVER crash / never block: `notify_once` sets the flags synchronously (plain
--    table writes — safe in any context) but `vim.schedule`s the `vim.notify`,
--    because the bridge's `on_ready`/`on_close` callbacks run on the libuv loop
--    (fast event context) and `vim.notify` THROWS `E5560: nvim_echo must not be
--    called in a fast event context` there. Without scheduling the notify is
--    silently LOST (verified nvim 0.12.4). The scheduled cb is pcall'd so a
--    misbehaving notify handler can never throw either.
--  * The buffer is ALWAYS a normal editable markdown buffer — S39 disables
--    *completion* only; editing/autosave (S38) are unaffected.
--
-- FORWARD CONTRACT (consumers — NOT implemented by S39):
--  * S25 handshake: on connect-fail (on_ready err!=nil) / hello-error (on_event) /
--    EOF (on_close) -> call `require("pi-editor").notify_once()`. On hello-success
--    -> `require("pi-editor").active = true`.
--  * S30+ completion triggers: prefix each trigger with
--    `if not require("pi-editor").is_active() then return end`.
-- ===========================================================================

--- Completion-active flag. `false` by default and after any bridge error; the
--- handshake (S25) sets it `true` on a successful `hello`. Completion triggers
--- (S30+) gate on |is_active()|. PRD §11 "stops completion".
---@type boolean
M.active = false

--- One-time-notify guard. `true` once |notify_once()| has fired its single WARN
--- message; stays `true` for the session so a burst of errors yields exactly one
--- notify (PRD §11 "a single vim.notify the first time", "never spam"). A future
--- reconnect (S25 reload) may reset it to `false` to re-enable per-attempt notify.
---@type boolean
M.notified = false

--- Degrade to a no-completion buffer with at most ONE `vim.notify` (WARN).
---
--- Call this from ANY bridge-failure path: connect refused (S24 `on_ready` errno),
--- a bad `hello` handshake (S25), or pipe EOF / pi-process-death (S24 `on_close`).
--- It (1) sets |active| to `false` UNCONDITIONALLY (so completion short-circuits
--- via |is_active()| and never retries a dead bridge), and (2) the FIRST time only,
--- emits the fixed WARN message `"pi-editor: bridge unavailable, completion
--- disabled"` (subsequent calls are silent — "never spam", PRD §11).
---
--- SAFE FROM ANY CALLER CONTEXT: the flag writes are plain Lua table ops (safe on
--- the libuv loop); the `vim.notify` is `vim.schedule`d because the bridge
--- callbacks fire in a fast event context where a direct `vim.notify` throws
--- `E5560` (verified nvim 0.12.4) and would be silently lost. The scheduled notify
--- is `pcall`d so a broken notify handler cannot throw either. This function NEVER
--- throws. The buffer remains a normal editable markdown buffer — only completion
--- is disabled.
function M.notify_once()
  M.active = false                                       -- GOTCHA 3: unconditional deactivate
  if not M.notified then                                 -- at-most-once (PRD §11)
    M.notified = true
    local msg = "pi-editor: bridge unavailable, completion disabled"  -- GOTCHA 4: fixed message
    local lvl = vim.log.levels.WARN                      -- =3 (verified)
    vim.schedule(function() pcall(vim.notify, msg, lvl) end)          -- CRITICAL: E5560-safe
  end
end

--- Completion gate. The handshake (S25) sets |active| `true` on a successful
--- `hello`; any bridge error (|notify_once()|) sets it `false`. Completion
--- triggers (S30+) prefix each trigger with `if not is_active() then return end`.
---@return boolean active `true` iff completion may run.
function M.is_active()
  return M.active == true
end

return M   -- (unchanged — the S39 block splices in just ABOVE this line)
```

```lua
-- ===== plugin/tests/degrade_smoke.lua — standalone (plenary-FREE) smoke =====
-- Run from the REPO ROOT:
--   nvim --headless --clean -u NORC +"luafile plugin/tests/degrade_smoke.lua" +qa ; echo exit=$?
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h")           -- .../plugin (rtp entry)
vim.opt.runtimepath:append(plugin_root)

local fails = 0
local function check(cond, msg) if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); fails = fails + 1 end end

-- fresh module
package.loaded["pi-editor"] = nil
local pi = require("pi-editor")

-- vim.notify spy (override + restore)
local orig_notify = vim.notify
local spy = { count = 0, msg = nil, level = nil }
vim.notify = function(m, l) spy.count = spy.count + 1; spy.msg = m; spy.level = l end
local function restore() vim.notify = orig_notify end

-- (a) defaults
check(pi.active == false, "active defaults false")
check(pi.notified == false, "notified defaults false")
check(pi.is_active() == false, "is_active() false by default")

-- (b) first notify_once -> exactly one WARN notify with the fixed message (after the schedule settles)
pi.notify_once()
vim.wait(50, function() return spy.count >= 1 end, 5)        -- GOTCHA 5: notify is scheduled
check(spy.count == 1, "first notify_once -> exactly 1 notify (got " .. spy.count .. ")")
check(spy.msg == "pi-editor: bridge unavailable, completion disabled", "notify message is the fixed contract message")
check(spy.level == vim.log.levels.WARN, "notify level is WARN")
check(pi.notified == true, "notified true after first notify_once")
check(pi.active == false, "active false after notify_once")
check(pi.is_active() == false, "is_active() false after notify_once")

-- (c) second notify_once -> idempotent (no further notify)
pi.notify_once()
vim.wait(30, function() return spy.count >= 2 end, 5)        -- should NOT reach 2
check(spy.count == 1, "second notify_once -> NO further notify (idempotent; got " .. spy.count .. ")")

-- (d) deactivate is unconditional: set active true, reload, notify_once -> is_active false
package.loaded["pi-editor"] = nil; pi = require("pi-editor")
pi.active = true
check(pi.is_active() == true, "active true after manual set")
pi.notify_once()
check(pi.is_active() == false, "notify_once deactivates even when active was true")

restore()
if fails > 0 then io.stderr:write(fails .. " check(s) failed\n"); vim.cmd("cquit 1") end
io.stdout:write("SMOKE_PASS\n")
```

```lua
-- ===== plugin/tests/degrade_spec.lua — the spec (covers every Success Criterion) =====
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/degrade_spec.lua")'
local uv = vim.uv
local bridge = require("pi-editor.bridge")
local jreader = require("pi-editor.jsonlreader")

-- in-process luv unix-socket server helper (mirror bridge_spec.lua S24)
local function with_server(spec)
  return function()
    local path = "/tmp/pi-degrade-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
    os.remove(path)
    local srv = uv.new_pipe(false); srv:bind(path)
    local srv_rx, srv_conn
    srv_rx = jreader.new(function(req) if req.id and srv_conn then
      srv_conn:write(vim.json.encode({jsonrpc="2.0", id=req.id, result={ok=true}}) .. "\n") end end)
    srv:listen(128, function()
      srv_conn = uv.new_pipe(false); srv:accept(srv_conn)
      srv_conn:read_start(function(rerr, data) if rerr or data == nil then return end; srv_rx:feed(data) end)
    end)
    local function stop()
      if srv_conn and not srv_conn:is_closing() then pcall(function() srv_conn:close() end) end
      if srv and not srv:is_closing() then pcall(function() srv:close() end) end
      os.remove(path); bridge.close()
    end
    spec(path, stop)
  end
end

describe("pi-editor degrade / notify_once", function()
  local pi, spy, orig_notify

  before_each(function()
    package.loaded["pi-editor"] = nil
    pi = require("pi-editor")
    spy = { count = 0, msg = nil, level = nil }
    orig_notify = vim.notify
    vim.notify = function(m, l) spy.count = spy.count + 1; spy.msg = m; spy.level = l end
  end)
  after_each(function() vim.notify = orig_notify; bridge.close() end)

  it("defaults: active/notified false, is_active() false", function()
    assert.is_false(pi.active); assert.is_false(pi.notified); assert.is_false(pi.is_active())
  end)

  it("first notify_once -> exactly one WARN notify with the fixed message", function()
    pi.notify_once()
    assert.is_nil(vim.wait(50, function() return spy.count >= 1 end, 5))
    assert.are.equals(1, spy.count)
    assert.are.equals("pi-editor: bridge unavailable, completion disabled", spy.msg)
    assert.are.equals(vim.log.levels.WARN, spy.level)
    assert.is_true(pi.notified); assert.is_false(pi.active); assert.is_false(pi.is_active())
  end)

  it("second notify_once is idempotent (no further notify)", function()
    pi.notify_once(); vim.wait(30, function() return spy.count >= 1 end, 5)
    pi.notify_once(); vim.wait(30, function() return spy.count >= 2 end, 5)
    assert.are.equals(1, spy.count)   -- still 1
  end)

  it("notify_once deactivates unconditionally (active was true)", function()
    pi.active = true
    assert.is_true(pi.is_active())
    pi.notify_once()
    assert.is_false(pi.is_active())
  end)

  it("is safe + effective from a luv callback (fast context — no E5560)", function()
    local done = false
    local t = uv.new_timer()
    t:start(5, 0, function()
      local ok = pcall(pi.notify_once)          -- must NOT throw E5560
      assert.is_true(ok, "notify_once threw from a luv cb (E5560?)")
      vim.schedule(function() done = true end)
    end)
    assert.is_nil(vim.wait(100, function() return done end, 5))
    t:close()
    -- the scheduled notify must still land
    assert.is_nil(vim.wait(50, function() return spy.count >= 1 end, 5))
    assert.are.equals(1, spy.count)
  end)

  it("never throws from the main loop", function()
    assert.has_no.errors(function() pi.notify_once() end)
  end)

  it("integration: bridge.connect ENOENT -> on_ready('ENOENT') -> notify_once -> one notify, inactive",
  function()
    local got
    bridge.connect("/tmp/pi-degrade-nope-" .. os.time() .. ".sock",
      function(err) got = err; if err then pi.notify_once() end end,
      function() end, function() end)
    assert.is_nil(vim.wait(150, function() return got ~= nil end, 5))
    assert.are.equals("ENOENT", got)
    assert.is_nil(vim.wait(50, function() return spy.count >= 1 end, 5))
    assert.are.equals(1, spy.count)
    assert.is_false(pi.is_active())
    assert.is_false(bridge.is_connected())
  end)

  it("integration: server-close EOF -> on_close(nil) -> one notify (first), none (second)",
  with_server(function(path, stop)
    local closed = 0
    bridge.connect(path, function() end, function() end,
      function() closed = closed + 1; pi.notify_once() end)
    assert.is_nil(vim.wait(120, function() return bridge.is_connected() end, 5))
    stop()                                                    -- server closes -> client on_close(nil)
    assert.is_nil(vim.wait(100, function() return closed >= 1 end, 5))
    assert.is_nil(vim.wait(50, function() return spy.count >= 1 end, 5))
    assert.are.equals(1, spy.count)                           -- first EOF -> one notify
    -- simulate a second failure in the same session (e.g. a retry hitting EOF again)
    pi.notify_once(); vim.wait(30, function() return spy.count >= 2 end, 5)
    assert.are.equals(1, spy.count)                           -- idempotent: still 1
  end))

  it("integration: happy path -> on_ready(nil), active=true -> NO notify, is_active true",
  with_server(function(path, stop)
    local ready
    bridge.connect(path, function(err) ready = err end, function() end, function() end)
    assert.is_nil(vim.wait(120, function() return ready ~= nil end, 5))
    assert.is_nil(ready)                                      -- connected ok
    pi.active = true                                          -- what S25 does on hello-success
    assert.is_true(pi.is_active())
    vim.wait(20)
    assert.are.equals(0, spy.count)                           -- NO notify on the happy path
    stop()
  end))
end)
```

### Integration Points
```yaml
MODULE SURFACE (public API — what this task ADDS to init.lua):
  - require("pi-editor").active          -> boolean   (default false; S25 sets true on hello-ok)
  - require("pi-editor").notified        -> boolean   (default false; the one-time guard)
  - require("pi-editor").notify_once()   -> void      (the degrade entry; idempotent notify + active=false)
  - require("pi-editor").is_active()     -> boolean   (the completion gate)
  # UNCHANGED by this task: setup, defaults, config, bridge, descriptor, activate (additive).

FORWARD CONTRACTS (do NOT implement here — just don't break them; documented in the [Mode A] header):
  - S25 (handshake): the consumer that CALLS notify_once() on connect-fail/handshake-fail/EOF and
        sets M.active=true on hello-success. S39 does NOT call S25 (correct dependency order).
  - S30+ (completion triggers): the consumer that gates each trigger with is_active().
  - S38 (autosave/on_exit): unaffected — the buffer is always editable; S39 disables completion only.

CALLER TODAY (tests only — no shipped wiring until S25):
  - plugin/tests/degrade_spec.lua wires notify_once to bridge.connect's on_ready/on_close to PROVE
    the real post-S25 path works (ENOENT -> notify; EOF -> notify; happy -> no notify).

AUGROUP / AUTOCMDS: NONE. S39 creates no autocmds (the S20 VimEnter shim + S22 ftplugin own those).
  The degrade is event-driven only insofar as S25 will call notify_once from bridge callbacks.

NO: database / routes / migrations / new env vars / package.json / config options. Pure Lua on the
  existing public module. The ONLY side effects are: two boolean fields + (at most once) a scheduled
  vim.notify. No buffer mutation, no file I/O, no socket (S39 consumes S24's socket in tests only).
```

## Validation Loop

> Run all commands from the REPO ROOT (`/home/dustin/projects/pi-nvim-bridge`). The plugin root is
> `$(pwd)/plugin`. Judge pass/fail by our markers (`SMOKE_PASS`, the plenary `Success:/Failed:` line,
> the `VERDICT`/spy counts) and `$?`. NOTE: `nvim --headless --clean -u NORC` may print a benign
> `E216: No such group or event: filetypedetect BufRead` (an nvim filetype/syntax init artifact,
> NOT from our code; exit stays 0 — inherited S19 GOTCHA #11).

### Level 1: Syntax & Load (Immediate Feedback)
```bash
# Headless parse + load check (loads the module — catches syntax/require errors immediately):
nvim --headless --clean -u NORC \
  -c "set rtp+=$(pwd)/plugin" \
  -c "lua local pi=require('pi-editor'); assert(type(pi.notify_once)=='function'); assert(type(pi.is_active)=='function'); print('INIT_LOADS_OK active='..tostring(pi.active)..' notified='..tostring(pi.notified))" +qa
# Expected: INIT_LOADS_OK active=false notified=false. Fix any error before proceeding.

# (Optional) Lua lint if available (NOT a hard gate — inherited S19 GOTCHA #8):
command -v luacheck >/dev/null && luacheck plugin/lua/pi-editor/init.lua --no-config 2>/dev/null \
  || echo "(luacheck not installed — relying on nvim parser via smoke/spec below)"
```

### Level 2: Unit Tests (Component Validation)
```bash
# Level-1 smoke (plenary-FREE; fastest signal):
nvim --headless --clean -u NORC +"luafile plugin/tests/degrade_smoke.lua" +qa ; echo "exit=$?"
# Expected: prints SMOKE_PASS, exit 0.

# Level-2 plenary/busted spec (the full matrix + fast-ctx + bridge integration):
cd plugin
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/degrade_spec.lua")' ; echo "exit=$?"
cd ..
# Expected: exit 0, all `it` blocks green (defaults, single-notify, idempotency, unconditional
# deactivate, fast-context safety, no-throw, ENOENT integration, EOF integration, happy path).

# Non-regression — every prior spec STILL passes (S39 is additive to init.lua):
cd plugin
for s in init shim activate ftplugin jsonlreader bridge; do
  nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require('plenary.busted').run('tests/${s}_spec.lua')" >/dev/null 2>&1 \
    && echo "$s: OK" || echo "REGRESSION: $s"
done
cd ..
# Expected: every line "OK"; no "REGRESSION:" lines. (activate_spec especially — S39 extends the
# same module; if it regresses, S39 clobbered setup/defaults/config/descriptor/activate — fix it.)
```

### Level 3: Integration & Adversarial (System Validation)
```bash
# A) The E5560 trap, LIVE — the WHOLE POINT of the vim.schedule design (§Known Gotchas CRITICAL).
#    Prove a NAIVE (direct vim.notify) degrade throws from a luv cb, but S39's scheduled one doesn't.
cat > /tmp/s39_e5560.lua <<'LUA'
  local uv = vim.uv
  local pi = (package.loaded["pi-editor"]=nil; require("pi-editor"))
  local ok_naive, ok_s39 = false, false
  -- naive: direct vim.notify in a luv cb THROWS E5560
  local t1 = uv.new_timer(); t1:start(5,0,function()
    ok_naive = pcall(vim.notify, "x", vim.log.levels.WARN)          -- false (E5560)
    vim.schedule(function()
      -- S39: scheduled notify in a luv cb is SAFE
      local t2 = uv.new_timer(); t2:start(5,0,function()
        ok_s39 = pcall(pi.notify_once)                              -- true (no throw)
        vim.schedule(function()
          io.stdout:write("VERDICT naive_ok="..tostring(ok_naive).." s39_ok="..tostring(ok_s39).."\n")
          assert(ok_naive==false and ok_s39==true, "E5560 assertion failed")
          io.stdout:write("E5560_GUARDED\n")
        end)
      end)
    end)
  end)
  vim.wait(200, function() return ok_s39 end, 5)
LUA
nvim --headless --clean -u NORC -c "set rtp+=$(pwd)/plugin" -c "luafile /tmp/s39_e5560.lua" +qa
# Expected: VERDICT naive_ok=false s39_ok=true  +  E5560_GUARDED. (If naive_ok=true, the env changed;
#   if s39_ok=false, S39 is NOT scheduling the notify — the headline bug. Fix before shipping.)
rm -f /tmp/s39_e5560.lua

# B) End-to-end degrade via the REAL bridge transport (no S25 needed): a connect failure produces
#    exactly one WARN notify and leaves the buffer editable (completion off).
cat > /tmp/s39_degrade_e2e.lua <<'LUA'
  local pi = (package.loaded["pi-editor"]=nil; require("pi-editor"))
  local bridge = require("pi-editor.bridge")
  local n, msg, lvl = 0, nil, nil
  local orig = vim.notify; vim.notify = function(m,l) n=n+1; msg=m; lvl=l end
  -- simulate S25's on_ready wiring on connect failure:
  bridge.connect("/tmp/pi-s39-nope-"..os.time()..".sock",
    function(err) if err then pi.notify_once() end end, function()end, function()end)
  vim.wait(150, function() return n>=1 end, 5)
  vim.notify = orig
  assert(n==1, "expected exactly 1 notify, got "..n)
  assert(msg=="pi-editor: bridge unavailable, completion disabled", "wrong message: "..tostring(msg))
  assert(lvl==vim.log.levels.WARN, "wrong level")
  assert(pi.is_active()==false, "completion not deactivated")
  assert(bridge.is_connected()==false, "bridge should be disconnected")
  io.stdout:write("DEGRADE_E2E_PASS\n")
LUA
nvim --headless --clean -u NORC -c "set rtp+=$(pwd)/plugin" -c "luafile /tmp/s39_degrade_e2e.lua" +qa
# Expected: DEGRADE_E2E_PASS.
rm -f /tmp/s39_degrade_e2e.lua

# C) "No spam" adversarial: a flurry of failures (e.g. completion retrying a dead bridge) yields ONE notify.
cat > /tmp/s39_nospam.lua <<'LUA'
  local pi = (package.loaded["pi-editor"]=nil; require("pi-editor"))
  local n = 0; local orig = vim.notify; vim.notify = function() n=n+1 end
  for _=1,50 do pi.notify_once() end                -- 50 rapid failures
  vim.wait(50, function() return n>=1 end, 5)
  vim.notify = orig
  assert(n==1, "SPAM: got "..n.." notifies (expected 1)")   -- PRD §11 "never spam"
  io.stdout:write("NO_SPAM_PASS count="..n.."\n")
LUA
nvim --headless --clean -u NORC -c "set rtp+=$(pwd)/plugin" -c "luafile /tmp/s39_nospam.lua" +qa
# Expected: NO_SPAM_PASS count=1.
rm -f /tmp/s39_nospam.lua
```

### Level 4: Creative & Domain-Specific Validation
```bash
# D) The buffer is STILL a normal editable buffer after degrade (PRD §11 "degrade to a normal buffer").
#    Degrade must NOT touch the buffer (no filetype change, no option reset, no read-only). Editing/:w
#    still work (S38 autosave is independent).
cat > /tmp/s39_buffer_intact.lua <<'LUA'
  local pi = (package.loaded["pi-editor"]=nil; require("pi-editor"))
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {"hello prompt"})
  vim.bo[b].filetype = "pi-prompt"
  local ft_before = vim.bo[b].filetype
  pi.notify_once()                                  -- degrade
  vim.wait(30, function() return pi.notified end, 5)
  assert(vim.bo[b].filetype == ft_before, "degrade changed filetype (it must not)")
  assert(vim.bo[b].modified == false, "degrade dirtied the buffer (it must not)")
  -- the buffer is still fully editable:
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {"edited after degrade"})
  assert(vim.api.nvim_buf_get_lines(b, 0, -1, false)[1] == "edited after degrade")
  io.stdout:write("BUFFER_INTACT_PASS\n")
LUA
nvim --headless --clean -u NORC -c "set rtp+=$(pwd)/plugin" -c "luafile /tmp/s39_buffer_intact.lua" +qa
# Expected: BUFFER_INTACT_PASS. (S39 disables completion only; the buffer is a normal markdown file.)
rm -f /tmp/s39_buffer_intact.lua
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: `INIT_LOADS_OK active=false notified=false`; luacheck clean (or n/a).
- [ ] Level 2: `degrade_smoke.lua` prints SMOKE_PASS / exit 0.
- [ ] Level 2: `degrade_spec.lua` exits 0 (full matrix incl. fast-context + bridge integration).
- [ ] Level 2: non-regression loop — every prior spec (`init`/`shim`/`activate`/`ftplugin`/
      `jsonlreader`/`bridge`) prints OK; no `REGRESSION:` lines.
- [ ] Level 3: `E5560_GUARDED` (naive throws, S39 scheduled doesn't — the headline test).
- [ ] Level 3: `DEGRADE_E2E_PASS` (real bridge.connect ENOENT → one WARN notify, inactive).
- [ ] Level 3: `NO_SPAM_PASS count=1` (50 failures → one notify).

### Feature Validation
- [ ] First `notify_once()` → exactly one WARN notify with the fixed message; `notified`/`active`/`is_active()` correct.
- [ ] Second `notify_once()` → no further notify (idempotent — PRD §11 "never spam").
- [ ] `notify_once()` sets `active=false` unconditionally (deactivate even when active was true).
- [ ] Defaults: `active=false`, `notified=false`, `is_active()=false`.
- [ ] `notify_once()` from a luv callback → no throw (E5560-safe) + scheduled notify lands.
- [ ] `notify_once()` never throws from any context.
- [ ] Integration: ENOENT `on_ready` → one notify; EOF `on_close` → one notify (idempotent on 2nd);
      happy path → no notify, `active=true` → `is_active()` true.
- [ ] The buffer remains a normal editable markdown buffer after degrade (BUFFER_INTACT_PASS).

### Code Quality Validation
- [ ] ADDITIVE to `init.lua` — spliced BEFORE `return M`, AFTER `M.activate()` (GOTCHA 1).
- [ ] setup/defaults/config/bridge/descriptor/activate UNCHANGED (non-regression).
- [ ] `notify_once` `vim.schedule`s the notify (the E5560 fix — the load-bearing detail).
- [ ] Flags set synchronously; notify guarded by `notified`; deactivate unconditional.
- [ ] Follows existing patterns: `local M`/`return M` module shape, [Mode A] LuaCATS docstrings,
      the S21 `before_each` reset + the S24 `with_server` integration helper.
- [ ] Anti-patterns avoided: no direct `vim.notify` in the synchronous path; no per-reason user
      message text; no `vim.api.*` calls; no `connect()` wiring (S25's job); no buffer mutation.

### Documentation & Deployment
- [ ] [Mode A] degradation-strategy header block (PRD §11 intent + the E5560 rationale + the
      S25/S30 forward contract).
- [ ] LuaCATS on `M.active`, `M.notified`, `M.notify_once()`, `M.is_active()`.
- [ ] The fixed message + WARN level documented; the "at most once" + "stops completion" + "buffer
      stays editable" guarantees stated.

---

## Anti-Patterns to Avoid
- ❌ Don't call `vim.notify(...)` synchronously inside `notify_once` — the bridge's `on_ready`/
  `on_close` run on the libuv loop and `vim.notify` throws `E5560` there (LIVE-VERIFIED); the notify
  is silently lost. ALWAYS `vim.schedule` it (and `pcall` the scheduled call).
- ❌ Don't guard the `active=false` on `notified` — deactivate is UNCONDITIONAL (every error turns
  completion off); only the NOTIFY is "at most once".
- ❌ Don't default `M.active=true` — it must be `false` until the handshake (S25) confirms the bridge.
- ❌ Don't inject the errno/reason into the user message — the contract fixes the message; per-reason
  text is leaky/unstable. (Debug logging of the reason is a future task, not S39.)
- ❌ Don't add a `reset_notify()`/`reset_session()` function — speculative API; S25 owns the connect
  lifecycle and can set the public `M.notified`/`M.active` fields directly on a reconnect.
- ❌ Don't wire `bridge.connect()` into `activate()` or ship a connect-with-degrade wrapper — that
  pre-empts S25 (handshake). S39 ships the MECHANISM + state + tests + a documented contract;
  the integration TESTS wire `notify_once` to the callbacks to PROVE it, but the shipped code only
  adds fields/functions to `init.lua`.
- ❌ Don't mutate the buffer on degrade — the buffer is ALWAYS a normal editable markdown file (PRD
  §11 "degrade to a normal buffer"); S39 disables completion only (via `active=false`), never editing.
- ❌ Don't touch `setup`/`defaults`/`config`/`bridge`/`descriptor`/`activate` — S39 is purely additive
  (spliced before `return M`). The activate_spec/init_spec non-regression is the proof.
- ❌ Don't assert the notify spy immediately after `notify_once()` — the notify is `vim.schedule`d;
  `vim.wait` for it to land first (GOTCHA 5).