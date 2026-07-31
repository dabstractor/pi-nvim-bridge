# Research Notes — P2.M1.T2.S3: `ensure(on_ready)` — spawn via vim.uv.spawn + driver delegation

> Scope: implement `M.ensure(on_ready)` in `lua/pi-bridge/shell.lua` — the SPAWN layer of the §17 completion
> daemon. Calls `M.resolve_shell` + `M.pick_driver` + `M.session_cwd()` (S2), then **delegates the actual
> `vim.uv.spawn` to `state.driver.start(opts, on_ready)`** (the fish driver is P2.M2.T4.S1; not yet present).
> Caches the proc/pipes in `state`; wires `stdout:read_start`; sets `state.failed` on terminal failure. NO
> framed-request logic (S4), NO sentinel parsing (S5), NO teardown kill/close (S6). Tests use a FAKE driver
> (no real subprocess) — the live spawn seam was already proven by the S1 fish spike.

---

## 0. TASK BOUNDARY (what S3 owns vs siblings — the fence)

| Concern | Owner | S3's relationship |
|---|---|---|
| `state` literal + `M.resolve_shell` + `M.pick_driver` + `M.session_cwd` + `M.reset` | **S2** (the PRP this item consumes) | CALLS them. Treats S2's PRP as a contract. Does NOT redefine. |
| `M.ensure(on_ready)` — resolve + pick + delegate + cache + wire read_start | **S3** ← this item | OWNS it. |
| `state.driver.start(opts, on_ready)` — the uv.spawn + startup timer | **driver modules** (fish = P2.M2.T4.S1; zsh/bash = P2.M3.T5) | S3 CALLS it; S3 does NOT implement spawn. The `startup_timeout_ms` timer lives INSIDE the driver, not in ensure. |
| `M.request(line,cursor,after,cb)` — framed protocol + gen bump | **S4** | S4 calls `M.ensure(cb)` then writes stdin. |
| `M._feed(chunk)` — sentinel slicing + JSON decode + normalize | **S5** | S3 WIRES read_start to call `M._feed`; S3 ships a MINIMAL stub (append to rx_buf) S5 replaces. |
| `M.teardown()` / `M._reset()` — kill + close pipes + reset + mark unhealthy | **S6** | S3's read_start EOF branch calls `M._reset`; S3 ships a MINIMAL stub (mark unhealthy + nil proc) S6 replaces. |
| Notices (§17.4.3 / §17.9 / §17.6.4 / §17.12 one-time notify) | **P2.M2.T3.S4** | S3 sets `state.failed` (the FACT); S3 does NOT call `notify.once` (the UX). |
| `init.lua` `shell={}` config block | **P2.M3.T6.S1** | S3 defensive-reads `config.shell` (may be nil → defaults). |

**Net**: S3 edits ONE file (`lua/pi-bridge/shell.lua` — APPENDS `ensure` + the two stubs to S2's module),
adds ONE smoke + ONE spec. NOTHING else.

---

## 1. INPUT CONTRACT — what S3 consumes (verified in-tree)

### 1a. From S2 — the resolution helpers (the immediate dependency; PRP is a contract)
- `M.resolve_shell(prefer) -> (shell_path:string, source:string)`. `prefer` is a PARAM (does not read config).
  Source ∈ `{"pi","$SHELL","default","config"}`. Never throws.
- `M.pick_driver(resolved_shell) -> table|nil`. Basename → `require("pi-bridge.shell.<base>")`; returns the
  module iff it has `.start`; nil for unknown/disabled. **EXPORTED on M** (S2 Design Decision §1). Never throws.
- `M.session_cwd() -> string|nil`. `bridge.server_info.cwd` → `descriptor.cwd` → nil. Never throws.
- `M.reset()` — restores `state` to its initial literal (S3 does NOT call this in ensure; S6 teardown does).
- `state` literal (S2 Data models): `{ proc, stdin, stdout, rx_buf="", gen=0, inflight=false, shell, driver,
  cwd, pending_cb=nil, failed=false }`. S3 SETS proc/stdin/stdout/shell/driver/cwd/failed; leaves rx_buf/gen/
  inflight/pending_cb to S4/S5.

### 1b. The DRIVER contract — `start(opts, on_ready)` (the NEW seam S3 introduces)
- `opts = { shell=<resolved_path:string>, cwd=<session_cwd:string|nil>, startup_timeout_ms=<int> }`.
- `on_ready = function(err:string|nil, proc:userdata|nil, stdin:userdata|nil, stdout:userdata|nil)`.
- The driver INTERNALLY does `uv.new_pipe(false)`×3 + `uv.spawn(shell, {args=..., stdio={stdin,stdout,stderr}},
  on_exit)` + a `uv.new_timer()` startup guard (the `startup_timeout_ms` budget). On success it calls
  `on_ready(nil, proc_handle, stdin_pipe, stdout_pipe)`. On failure (binary missing / rc error / timeout) it
  calls `on_ready(err_msg, nil, nil, nil)` AND tears down its own half-spawned handles.
- **S3 does NOT build the timer.** It passes `startup_timeout_ms` THROUGH to the driver. (Verified: the §17.5.2
  skeleton passes `startup_timeout_ms=cfg.startup_timeout_ms or 5000` inside the `start()` opts table.)
- The fish driver (P2.M2.T4.S1) is the reference implementation of this contract — proven end-to-end by the
  S1 spike (`tests/shell_fish_spike.lua`), which IS a working `start()`-shaped spawn.

### 1c. `require("pi-bridge").config.shell` (init.lua; may be nil)
- `M.config` is nil until `setup()`. The `shell={}` block is P2.M3.T6.S1 — **NOT yet present**. S3 MUST
  defensive-read: `local pi = require("pi-bridge"); local cfg = (pi.config and pi.config.shell) or {}`.
- ⚠️ The §17.5.2 skeleton writes `require("pi-bridge").config.shell or {}` — this **THROWS** if `config` is
  nil (indexing nil). S3 uses the defensive form (S2 GOTCHA #2). `cfg.prefer` and `cfg.startup_timeout_ms`
  are nil-safe via `or "pi"` / `or 5000`.

### 1d. notify.lua — `M.once(category, level, msg)` (S3 does NOT call it; forward reference)
- Already exists (`lua/pi-bridge/notify.lua:1-37`). `vim.schedule`-wrapped → safe from luv fast context.
  Dedup by category. **S3 references it in the header only** (documentation); the §17.12 one-time degrade
  notify is P2.M2.T3.S4's job. (Mirrors S2 GOTCHA #12.)

---

## 2. THE CANONICAL REAL EXAMPLE — `tests/shell_fish_spike.lua` (verified working, in-repo)

The spike IS a working `vim.uv.spawn` + pipe + read + teardown sequence. It is the **single best reference**
for the luv API shape. S3's DRIVER will look like this; S3's `ensure()` is the ORCHESTRATION around it.

```lua
local uv = vim.uv
local stdin  = uv.new_pipe(false)          -- false = non-IPC stream pipe
local stdout = uv.new_pipe(false)
local stderr = uv.new_pipe(false)
local handle, spawn_err
pcall(function()
  handle, spawn_err = uv.spawn("fish", {
    args = { "-i", "--init-command=..." },
    stdio = { stdin, stdout, stderr },      -- array of the 3 pipe handles
  }, function() end)                         -- on_exit(code, signal); no-op for the spike
end)

stdout:read_start(function(rerr, data)      -- (err, chunk); data==nil ⇒ EOF (NOT an error)
  if rerr then ...; return end               -- rerr set only on a read error
  if data then rx_buf = rx_buf .. data; try_parse()
  else -- EOF: child exited/crashed; finalize end
end)

stdin:write('__PIREQ__\t{"line":"git ch",...}\n')

-- teardown (kill + close each, guarded by is_closing()):
pcall(function() if handle and not handle:is_closing() then uv.process_kill(handle, "sigkill") end end)
pcall(function() if stdin   and not stdin:is_closing()   then stdin:close()   end end)
pcall(function() if stdout  and not stdout:is_closing()  then stdout:close()  end end)
pcall(function() if stderr  and not stderr:is_closing()  then stderr:close()  end end)
```

**Key verified facts from the spike + luvref.txt (researcher, sourced from `/usr/share/nvim/runtime/doc/luvref.txt`):**
- `uv.new_pipe(false)` — `false` = a normal stream pipe (NOT an IPC pipe; `:help uv-new_pipe`).
- `uv.spawn(path, opts, on_exit)` — `opts.stdio` is the array of pipe handles; `on_exit = function(code, signal)`.
  Returns `(handle, err)`; `err` is non-nil on failure (e.g. binary not found). `:help uv-spawn`.
- `pipe:read_start(function(err, chunk))` — `chunk` is a string per read OR `nil` at EOF. `err` non-nil only
  on a genuine read error. `:help uv-read_start`.
- `pipe:write(data, cb)` — `cb = function(err)` (optional). Async/buffered. `:help uv-write`.
- `uv.process_kill(handle, signum)` — accepts the STRING `"sigkill"` OR the integer `9`. `:help uv-process_kill`.
- `pipe:close()` / `handle:close()` — frees the uv handle. `handle:is_closing()` → true once close initiated.
  Closing an already-closing handle THROWS → guard with `is_closing()` + `pcall`. `:help uv-close`.
- `read_stop()` before `close()` on an ACTIVE read_start'd pipe is the safe order (avoids a stray cb after
  close). S6 teardown owns this; S3's `_reset` stub does not (proc already dead on EOF). `:help uv-read_stop`.

**Researcher correction (authoritative):**
1. The spike is ALREADY E5560-safe: it calls only `io.stderr:write` + string ops inside `read_start`'s cb
   (NOT `vim.api.*`). `nvim_echo` runs post-`vim.wait` on the main loop. ⇒ luv callbacks that touch `vim.api`
   MUST be `vim.schedule`'d (`:help E5560`), but pure-string/state ops (like S5's `_feed`) are fine in-place.
2. There is **no nvim-0.12.x-specific timer leak**: `stop()` ≠ `close()` is fundamental libuv design. The
   `stop()`-then-`close()` pattern (completion.lua's cancel_timer) is required in ALL versions (luv's own
   `setTimeout` example demonstrates it). S3 doesn't build a timer (the driver does), but S6 teardown reuses
   this discipline for any timer it touches.
3. `vim.uv` is the canonical alias in 0.10+ (`vim.loop` is the deprecated synonym; both work). The repo uses
  `vim.uv` (spike L13, completion.lua, bridge.lua). S3 uses `vim.uv`.

**API-safety conclusion for S3:** `ensure()` itself runs on the nvim main loop (called from S4's request,
which is called from completion routing → a vim.keymap/autocmd cb). The driver's `on_ready` cb may fire from
luv fast context (inside the spawn/read_start event). S3's on_ready body does: store state (table writes —
fine), `stdout:read_start(cb)` (a luv call — fine in fast context), call the user's `on_ready` (S4's cb —
string/table ops, fine). NO `vim.api.*` in S3's chain ⇒ no `vim.schedule` needed. (The eventual menu call is
S5's `_feed` → `pending_cb` → cb → menu; S5 must `vim.schedule` THAT hop — forward-contract note.)

---

## 3. DESIGN DECISIONS (locked)

### D1. S3 DELEGATES spawn to `state.driver.start`; it does NOT call `vim.uv.spawn` itself.
The §17.5.2 skeleton's `ensure` calls `state.driver.start({...}, cb)`. The driver does the spawn (per-shell:
fish/zsh/bash differ in args + rc sourcing + the capture mechanism — §17.6). Centralizing spawn in ensure
would force per-shell branching into shell.lua (wrong layer). `startup_timeout_ms` is passed THROUGH to the
driver (the timer lives in the driver, which owns the spawn lifecycle). **S3 has zero `uv.spawn` calls.**
Verified against the skeleton + the item contract point 1 ("delegates to driver.start() which spawns").

### D2. `state.failed=true` is set on BOTH terminal paths (no-driver AND spawn error).
§17.12: "menu simply never opens for `!` lines" + "no auto-respawn in v1". A broken spawn (missing binary,
bad rc) or a permanently-driverless shell (unknown shell / user-disabled) will NOT fix itself mid-session.
Without `failed=true`, EVERY keystroke on a `!` line re-runs resolve→pick→(spawn→5s timeout) — catastrophic
UX. So `ensure` sets `state.failed=true` on:
  (a) no driver (`pick_driver` returned nil), AND
  (b) spawn error (`driver.start`'s cb got a non-nil err, OR `driver.start` itself threw).
The `if state.failed then return on_ready("daemon disabled") end` short-circuit at the TOP of ensure is the
fast no-op path thereafter. This matches S2's `state.failed` doc ("set by S3 ensure() on permanent spawn
failure ... ensure() won't retry; health reports it") + §17.12. The degrade NOTIFY (§17.12 "one vim.notify")
is P2.M2.T3.S4 — S3 only sets the FACT (`failed=true`); it does not call `notify.once` (header-only ref).

### D3. S3 WIRES `stdout:read_start` with the LITERAL skeleton callback; declares `_feed` + `_reset` stubs.
The skeleton's read_start cb is `function(_, chunk) if chunk then M._feed(chunk) else M._reset() end end`.
`_feed` is S5; `_reset`/teardown is S6. S3 ships MINIMAL stubs so the wiring is complete + safe (a stray
chunk/EOF during S3's window before S5/S6 land degrades to a no-op, never errors):
  - `M._feed(chunk)` — append to `state.rx_buf` (`state.rx_buf = state.rx_buf .. (chunk or "")`). S5 replaces
    with full sentinel slicing + JSON decode + normalize.
  - `M._reset()` — the EOF path: set `state.failed=true` (mark unhealthy, §17.12) + nil proc/stdin/stdout/
    driver + clear rx_buf. S6's `teardown()` will prepend `uv.process_kill` + `pipe:read_stop()`+`close()`
    (on EOF the proc is already dead, so kill is moot; pipe-close matters for real handles — S6 owns it).
Both stubs are EXPORTED on M (so S5/S6 replace them by reassigning `M._feed = ...`; and tests can assert the
read_start cb routes to them). Documented as forward-contract seams. (Mirrors S2's "declare the field +
document the seam" pattern for state.gen/pending_cb/failed.)

### D4. `pcall` discipline — ensure pcalls `driver.start` AND `stdout:read_start`.
Contract point 3: "Every uv call pcall'd." In ensure the uv-ish calls are: `state.driver.start(...)` (a Lua
fn, but a buggy driver must not abort ensure) and `stdout:read_start(cb)` (a genuine luv call on the handle
the driver returned — the handle could be a malformed userdata). Both pcall'd. A throw from either is treated
as a spawn error (D2: set failed + driver=nil + on_ready(err)). The resolution helpers (resolve_shell/
pick_driver/session_cwd) are already never-throws (S2).

### D5. `state.proc` is the "already running" cache key (NOT state.driver).
The skeleton: `if state.proc then return on_ready(nil) end` (proc is set ONLY on a successful spawn). Using
state.driver as the cache key would be WRONG (driver is set BEFORE spawn; a mid-spawn second call would
falsely report "ready"). `state.proc` is nil until the spawn cb stores it. Contract point 4 ("subsequent
calls are instant") = this guard. Verified against the skeleton.

### D6. ensure re-reads `config` + `bridge` + `descriptor` FRESH (never caches at module load).
Mirrors completion.lua + S2. `require("pi-bridge")` INSIDE ensure (async handshake; tests swap fakes after
require). The descriptor/server_info may resolve AFTER the first `!` activation; a stale module-top cache
would miss it. (S2 GOTCHA #1, inherited.)

### D7. ensure returns nothing; communicates via `on_ready(err)`.
Node-style cb: `on_ready(nil)` on success / cached-ready; `on_ready(err_string)` on every failure. No return
value (mirrors the skeleton + completion.lua's fire-and-forget cb style). S4's `request` passes its own cb
as ensure's on_ready.

---

## 4. THE `state.failed` LIFECYCLE (reconciled across §17.12 + S2 + S3 + S5 + S6)

```
                          ┌──────────────────────────────────────────────┐
  first ! activation ───▶ │ M.ensure(on_ready)                           │
                          │  if state.failed → on_ready("daemon disabled")│ ◀── short-circuit (S3)
                          │  if state.proc   → on_ready(nil) [cached]     │
                          │  resolve + pick                               │
                          │  no driver?    → failed=true; on_ready(err)   │ ◀── S3 sets (D2a)
                          │  driver.start(opts, cb)                       │
                          │    cb(err)  → failed=true; driver=nil;        │ ◀── S3 sets (D2b)
                          │                on_ready(err)                  │
                          │    cb(nil,p,in,o) → store; read_start(_feed); │
                          │                      on_ready(nil)            │
                          └────────────┬─────────────────────────────────┘
                                       │ daemon up (proc set)
                          ┌────────────▼─────────────────────────────────┐
           later EOF ───▶ │ stdout read_start cb: chunk==nil → M._reset() │ ◀── S3 stub / S6 real
  (shell crashed)         │   _reset: failed=true; nil proc/pipes         │ ◀── marks unhealthy (§17.12)
                          └──────────────────────────────────────────────┘
           later N parse  │ M._feed: N consecutive decode fails → kill +   │ ◀── S5 (future)
              fails ───▶  │   failed=true (disabled for session)          │
                          └──────────────────────────────────────────────┘
           VimLeavePre ─▶ │ M.teardown(): process_kill + pipe:close×3 +    │ ◀── S6 (future)
                          │   reset()  (does NOT set failed — clean exit)  │
                          └──────────────────────────────────────────────┘
```
- `failed` is set by: S3 (no-driver, spawn error), S3-stub/S6 (EOF), S5 (N parse fails).
- `failed` is NOT set by clean teardown (VimLeavePre) — that's a normal exit, not a crash.
- Once `failed=true`, ensure short-circuits for the rest of the session (§17.12 "no auto-respawn in v1").
- The health check (P2.M3.T6.S2) READS `state.failed` + `state.shell`/source to report status.

---

## 5. TESTING STRATEGY — FAKE driver + FAKE pipes (no real subprocess)

S3 tests NEVER spawn a real shell (the live seam is S1's spike, already gated). The fake driver is injected
via `package.loaded["pi-bridge.shell.fish"] = { start = fn }` (S2 GOTCHA #8: require checks package.loaded
FIRST). resolve_shell must resolve to a `fish`-basename path so pick_driver finds the fake — set
`bridge.get_shell_info` to return `{shell="/usr/bin/fish"}` OR pass `prefer="/usr/bin/fish"`.

**Fake driver + fake pipes shape:**
```lua
local captured_opts, read_cb
local fake_stdout = { read_start = function(_, cb) read_cb = cb end, close = function() end, is_closing = function() return false end }
local fake_stdin  = { write = function() end, close = function() end, is_closing = function() return false end }
local fake_proc   = { is_closing = function() return false end }
local fake_driver = {
  start = function(opts, cb)
    captured_opts = opts                       -- assert shell/cwd/startup_timeout_ms passed through
    if opts._fail then cb("spawn err", nil, nil, nil)
    else cb(nil, fake_proc, fake_stdin, fake_stdout) end
  end,
}
package.loaded["pi-bridge.shell.fish"] = fake_driver
```

**The 3 contract-mandated cases (contract point 5):**
1. **first call spawns** — after `ensure(cb)`: `state.proc == fake_proc`, `state.stdin == fake_stdin`,
   `state.stdout == fake_stdout`, `state.shell == "/usr/bin/fish"`, `state.driver == fake_driver`,
   `captured_opts.shell == "/usr/bin/fish"`, `captured_opts.startup_timeout_ms == 5000` (default),
   `read_cb` captured (read_start wired), `cb` called with nil. `state.failed == false`.
2. **second call reuses** — second `ensure(cb2)` with `state.proc` set: `fake_driver.start` NOT called again
   (no re-spawn); `cb2` called with nil IMMEDIATELY. (The cache key is `state.proc` — D5.)
3. **spawn error sets driver=nil (+ failed=true per D2)** — `ensure(cb)` with `opts._fail=true`:
   `state.driver == nil`, `state.failed == true`, `state.proc == nil`, `cb` called with the err string.
   A FOLLOW-UP `ensure(cb2)` short-circuits via `failed` → `cb2("daemon disabled")`, no resolve/pick/start.

**Additional cases (exhaustive, mirror S2's matrix):**
4. **no driver** — resolve to `/bin/unknownshell` (no `package.loaded["pi-bridge.shell.unknownshell"]`):
   `state.failed == true`, `state.driver == nil`, `cb("no driver for /bin/unknownshell")`. Follow-up
   short-circuits on `failed`.
5. **user-disabled driver** — `config.shell.drivers.fish=false`: pick_driver returns nil → same as no-driver
   (failed=true, cb err). (S2's pick_driver handles the disable; ensure sees nil driver.)
6. **failed short-circuit** — preset `state.failed=true`; `ensure(cb)` calls `cb("daemon disabled")` WITHOUT
   calling resolve/pick/start (assert start was NOT called). No state mutation.
7. **config pass-through** — `config.shell.prefer="/usr/bin/fish"`, `config.shell.startup_timeout_ms=2500`:
   `captured_opts.startup_timeout_ms == 2500` (NOT the 5000 default). And prefer honored.
8. **nil config** — `pi.config=nil` (no setup): ensure does NOT throw (defensive read); uses defaults
   (prefer="pi", startup_timeout_ms=5000).
9. **session_cwd pass-through** — `bridge.server_info.cwd="/srv"`: `captured_opts.cwd == "/srv"`.
10. **never-throws** — `ensure(nil)`, `ensure(123)`, ensure with a driver whose `start` THROWS: ensure
    catches (pcall D4) → failed=true, on_ready NOT called when on_ready is non-function (guard type).
11. **read_start wiring routes to M._feed / M._reset** — invoke the captured `read_cb` with a chunk →
    `state.rx_buf` grew (M._feed stub). Invoke with nil → `state.failed==true` (M._reset stub, EOF path).
12. **stub exports** — `type(shell._feed)=="function"`, `type(shell._reset)=="function"` (forward-contract
    seams present + replaceable).

**Note on `vim.wait`**: the fake driver's `start` calls `cb` SYNCHRONOUSLY (inside the ensure call), so no
event-loop driving is needed — `ensure(cb)` completes fully before returning. (A deferred fake would need
`vim.wait`; prefer the sync fake for determinism — mirror completion_spec's synchronous fakes.)

---

## 6. GOTCHAS

- **G1 (HARD RULE, AGENTS.md):** tests run via `+"luafile tests/shell_ensure_smoke.lua" +qa` (a FILE on disk).
  NEVER heredoc→nvim stdin (hangs the session). Wrap every nvim in `timeout`.
- **G2 (defensive config):** `require("pi-bridge").config.shell or {}` THROWS if `config` is nil. Use
  `(pi.config and pi.config.shell) or {}`. (S2 GOTCHA #2.)
- **G3 (cache key):** the "already running" guard keys on `state.proc` (set only on success), NOT
  `state.driver` (set before spawn). Using driver would false-positive "ready" mid-spawn. (D5.)
- **G4 (pcall read_start):** `stdout:read_start` is a luv call on a handle the DRIVER returned; the handle
  could be malformed. pcall it; a throw = spawn error (failed=true). (D4.)
- **G5 (no uv.spawn in S3):** ensure delegates to `driver.start`. Adding a `vim.uv.spawn` in ensure would
  bypass the per-shell driver layer (wrong) + break the fake-driver tests. (D1.)
- **G6 (no timer in S3):** `startup_timeout_ms` is passed THROUGH to the driver. S3 does NOT build a
  `uv.new_timer`. (D1 + contract point 1.)
- **G7 (stubs are forward contracts):** `_feed`/`_reset` are MINIMAL in S3 (append / mark-unhealthy). S5
  replaces `_feed` (full parsing); S6 replaces/extends `_reset` into `teardown` (kill+close). Do NOT
  implement sentinel parsing or pipe-close in S3. (D3.)
- **G8 (no notify in S3):** the §17.12 one-time degrade notify is P2.M2.T3.S4. S3 sets `failed` (the fact)
  only; references notify.lua in the HEADER (documentation). (S2 GOTCHA #12.)
- **G9 (E5560):** luv callbacks (read_start's cb, driver's on_ready) run on the libuv loop (fast context).
  S3's chain touches NO `vim.api.*` (only state writes + luv calls + string ops) → no `vim.schedule` needed.
  The eventual menu call is S5's `_feed`→`pending_cb`→cb→menu — S5 must `vim.schedule` that hop.
  (`:help E5560`; researcher correction §2.)
- **G10 (TAB indentation):** match completion.lua/bridge.lua/init.lua/S2's shell.lua. Every new line tabs.
- **G11 (no lua linter):** no luacheck/selene/stylua. Validation = the smoke + spec. luaemmy `---@` annotations
  are NOT runtime-enforced. (S2 GOTCHA #6.)
- **G12 (lazy require):** `require("pi-bridge")` INSIDE ensure (config/bridge/descriptor resolve async; tests
  swap fakes after require). NOT at module top. (S2 GOTCHA #1.)
- **G13 (appending to S2's module):** S3 EDITS `lua/pi-bridge/shell.lua` (which S2 created). APPEND ensure +
  the two stubs AFTER S2's functions, BEFORE `return M`. Do NOT touch S2's resolve_shell/pick_driver/
  session_cwd/reset/state. (The file already ends with `return M` — insert before it.)

---

## 7. FORWARD CONTRACTS (S3 ships stubs/seams; later tasks implement)

| Seam | S3 ships | Implemented by |
|---|---|---|
| `M._feed(chunk)` | stub: append to rx_buf | **S5** (sentinel slice + JSON decode + normalize → pending_cb) |
| `M._reset()` | stub: failed=true + nil proc/pipes (EOF path) | **S6** (`teardown()`: process_kill + read_stop + close×3 + reset) |
| `M.request(line,cursor,after,cb)` | (not referenced by S3) | **S4** (calls ensure, bumps gen, writes stdin) |
| `state.failed` | S3 SETS it (no-driver/spawn-error/EOF) | read by **health** (P2.M3.T6.S2); set by S5 (N parse fails) |
| `state.pending_cb` / `state.gen` / `state.inflight` | (S2 declared; S3 doesn't touch) | **S4** |
| `notify.once("shell-daemon", ...)` | header reference only | **P2.M2.T3.S4** |

---

## 8. REFERENCES (file:line / :help tag)

- `tests/shell_fish_spike.lua` — the canonical real `uv.spawn`+pipe+read+teardown sequence (in-repo, verified).
- `lua/pi-bridge/completion.lua` — the module to MIRROR (state shape L248-265; gen-guard L454-468; reset L602;
  the `[Mode A]` header; the "Read bridge FRESH at call time" idiom; the `cancel_timer` stop+close leak fix).
- `plan/002_d23d7473c16c/P2M1T2S2/PRP.md` — the IMMEDIATE contract (state literal, resolve_shell/pick_driver/
  session_cwd/reset signatures + behavior; GOTCHAs #1/#2/#6/#7/#12; Design Decisions §1-§5).
- `plan/002_d23d7473c16c/P2M1T2S2/research/notes.md` — the INPUT contracts (get_shell_info/descriptor/config).
- `plan/002_d23d7473c16c/architecture/research-prd-section-17.md` §17.5.2 (L138-185 the skeleton + ensure);
  §17.12 (L413-419 failure modes); §17.16 (L448+ phasing, step 22).
- `:help uv-spawn` `:help uv-new_pipe` `:help uv-read_start` `:help uv-write` `:help uv-process_kill`
  `:help uv-close` `:help uv-read_stop` `:help E5560` — luv API (researcher, from installed nvim runtime).
- `lua/pi-bridge/notify.lua:1-37` — the dedup `M.once` (S3 header-only ref).
- `lua/pi-bridge/bridge.lua:884-899` — `M.get_shell_info()` (S4; consumed by resolve_shell via session helpers).
- `lua/pi-bridge/init.lua:42-82,94-149` — `M.config` (nil until setup) + `M.descriptor` + `M.activate()`.