# Research Notes — P2.M1.T2.S2: shell.lua module state + resolve_shell + pick_driver + session_cwd

> Scope: create `lua/pi-bridge/shell.lua` with (a) module-level `state`, (b) `M.resolve_shell(prefer)`
> (PRD §17.4 fallback chain), (c) `pick_driver(resolved_shell)` (basename → driver module, §17.4.2),
> (d) `M.session_cwd()` (fresh descriptor/server_info cwd read). **NO spawn yet** — that is S3.
> Mirrors `completion.lua`'s gen-guard supersession + fresh-read patterns. Tests are PURE (no subprocess).

---

## 1. INPUT CONTRACT — what S2 consumes (all verified in-tree)

### 1a. `bridge.get_shell_info()` — produced by P2.M1.T1.S4 (PRP is a contract)
- Location: `lua/pi-bridge/bridge.lua`, exported after `M.is_connected()`.
- Signature: `M.get_shell_info() -> {shell:string?, shellSource:string?, shellPath:string?} | nil`.
- Source priority: `M.server_info` (live hello/ping result) → `require("pi-bridge").descriptor` → `nil`.
- Returns a **fresh table** (mutating it cannot touch module state). Never throws (defensive reads).
- `shell` is `nil` (NOT `""`) when unresolved — this is LOAD-BEARING: shell.lua's fallback chain
  (`descriptor.shell → $SHELL → /bin/bash`) MUST engage on nil. A `""` would be a bogus path.
- Access path in shell.lua: `require("pi-bridge").bridge` may be `nil` pre-handshake → must guard
  `if br and type(br.get_shell_info)=="function" then ...`. Fall back to `pi.descriptor.shell` directly
  when bridge is nil.

### 1b. `require("pi-bridge").descriptor` — init.lua `M.descriptor`
- Class `pi-bridge.BridgeDescriptor` (init.lua L98-110). Set by `activate()` from the `PI_NVIM_BRIDGE`
  env var. Fields: `transport, path, token, pid, cwd, fdAvailable, serverVersion` + OPTIONAL
  `shell?, shellSource?, shellPath?` (§17.10/S4 annotation).
- `.cwd` is REQUIRED (string, non-empty when transport=="unix") — the session cwd.
- `.shell` is OPTIONAL (nil on older clients). shell.lua reads it as the §17.4 `prefer:"pi"` first hop.

### 1c. `require("pi-bridge").config` — init.lua `M.config`
- `nil` until `setup()`. The §17.11 `shell = { prefer, drivers, ... }` config block does NOT exist yet
  (it is P2.M3.T6.S1). **shell.lua MUST default to `{prefer="pi"}` when `config.shell` is nil** and MUST
  NOT throw when `config` itself is nil. Defensive reads everywhere: `(pi.config and pi.config.shell) or {}`.
- `prefer` is a PARAMETER to `resolve_shell(prefer)` (the caller `ensure()` in S3 reads `config.shell.prefer`
  and passes it). resolve_shell itself does NOT read config — it takes `prefer` as an arg. This keeps it pure
  + directly unit-testable (the coords.lua / notify.lua idiom).
- `config.shell.drivers` (e.g. `{ bash = false }`) is read ONLY inside `pick_driver` (see §3 + design §6).

### 1d. `vim.env.SHELL`
- Read in resolve_shell for the `prefer=="shell"` arm + the `prefer=="pi"` fallback-through.
- In tests: `vim.env.SHELL = "/bin/zsh"` sets it for the process; `vim.env.SHELL = nil` unsets it.
  Save/restore around each test (the notify_spec before/after_each idiom).

---

## 2. THE MODULE TO MIRROR — completion.lua (verified in-tree)

### 2a. State table shape (completion.lua L248-265)
```lua
---@class pi-bridge.CompletionState
---@field gen integer  Monotonic supersession guard ...
---@type pi-bridge.CompletionState
local state = { buf=nil, debounce_timer=nil, gen=0, inflight_id=nil, last_result=nil }
```
- Singleton, module-local, cleared by `M.reset()`. **shell.lua mirrors this**: a `state` table +
  an `M.reset()` that restores initial values. S2's state is DECLARED but the S2 functions (resolve_shell,
  pick_driver, session_cwd) are PURE (they don't mutate state — only ensure/request/_feed do, in S3-S6).
  reset() is still included as the forward-contract teardown seam (S6 teardown() will call it) + test hygiene.

### 2b. The gen-guard (completion.lua L454-468 — THE pattern shell.lua must mirror)
```lua
state.gen = state.gen + 1; local gen = state.gen      -- bump + capture
...
if gen ~= state.gen then return end                    -- STALE — drop, touch nothing
```
- Monotonic `state.gen` captured in the response-cb closure; a newer `request()` bumps gen → late stale
  response dropped at the guard. shell.lua's §17.5.2 skeleton uses the SAME `state.gen` int + `pending_cb`.
- S2 only DECLARES `state.gen=0` + `state.inflight=false` + `state.pending_cb=nil` (the fields the gen-guard
  needs). The actual bump+guard lives in `request()` (S4). S2 sets up the scaffolding + documents it.

### 2c. "Read bridge FRESH at call time" (completion.lua header, the load-bearing idiom)
- `local bridge = require("pi-bridge").bridge` INSIDE the function, NOT at module top.
- Reason: handshake is ASYNC; at first-require `pi.bridge` is still nil; tests swap in a fake bridge after
  `require`. Caching breaks both. **shell.lua does the same**: `require("pi-bridge")` INSIDE
  resolve_shell/session_cwd/pick_driver. Lazy require is also REQUIRED to avoid a circular-load hazard
  (init.lua does not require shell.lua at top; shell.lua requiring init at top would be safe but pointless
  since the values change — GOTCHA mirrors bridge.lua's lazy `require("pi-bridge")` at L333/L559).

### 2d. M.reset() (completion.lua L602) — the cleanup seam shell.lua mirrors
```lua
function M.reset()
  cancel_timer()
  local b = require("pi-bridge").bridge
  if state.inflight_id and b and type(b.cancel)=="function" then pcall(b.cancel, state.inflight_id) end
  state.debounce_timer=nil; state.inflight_id=nil; state.last_result=nil; state.gen=0; state.buf=nil
end
```
- shell.lua's reset() is simpler (no timer/inflight in S2): restore `proc/stdin/stdout/rx_buf/gen/inflight/
  shell/driver/cwd/pending_cb/failed` to initial. S6 teardown() will prepend kill+close THEN call reset().

### 2e. dbg() helper (completion.lua L235) — optional debug-log
- `local function dbg(msg) ... end` (vim.schedule_wrap'd vim.notify or a no-op). shell.lua can include a
  stub `dbg` for parity (forward-contract for S4/S5 tracing). Keep minimal; this repo has no real logger.

---

## 3. pick_driver — basename → driver module (PRD §17.4.2 + §17.5.2 skeleton)

### 3a. The PRD skeleton (verbatim, research-prd-section-17.md L152-158)
```lua
local function pick_driver(resolved_shell)        -- basename → driver module
  local base = resolved_shell:gsub(".*/","")
  local ok, drv = pcall(require, "pi-bridge.shell."..base)
  if ok and drv and type(drv.start)=="function" then return drv end
  return nil                                      -- unknown → degrade (§17.6.4)
end
```
- `gsub(".*/","")` strips the directory prefix → basename: `"/bin/zsh"`→`"zsh"`, `"/usr/bin/fish"`→`"fish"`.
  NOTE: `string.gsub` returns 2 values (str, n); `local base = s:gsub(...)` adjusts to 1 (the str). Safe.
- `pcall(require, "pi-bridge.shell."..base)` — the driver modules do NOT exist yet (fish=P2.M2.T4.S1,
  zsh/bash=P2.M3.T5). So pcall returns `false` → `nil` (degrade). Correct for S2. Tests inject a FAKE
  module into `package.loaded["pi-bridge.shell.fish"]` (require checks package.loaded FIRST) to exercise
  the "driver present + has .start → return it" path.
- A driver is valid iff `type(drv.start)=="function"` (the `start(opts, on_ready)` seam, §17.6). A module
  without `.start` → nil (degrade). This is the seam S3's ensure() calls.

### 3b. The drivers-disabled check (PRD §17.4.2)
> "The user may disable a driver explicitly: `setup({ shell = { drivers = { bash = false } } })`."
- Semantically this is DRIVER selection (§17.4.2), so it belongs in **pick_driver**, NOT resolve_shell
  (the shell is what pi EXECUTES — you cannot change it; disabling a driver means NO completion, i.e. degrade).
- The item-description bullet lists it under resolve_shell, but placing it in pick_driver is the correct
  layering (resolve_shell stays a pure §17.4 resolution; pick_driver owns all driver-selection concerns).
  See Design Decision §6. Honor: `cfg[base] == false` (explicitly disabled) → return nil. `nil`/`true`/absent
  → not disabled (proceed to require).

### 3c. pick_driver is exported as `M.pick_driver` (deviation from skeleton's `local` — justified)
- The contract's MOCKING explicitly requires "Test ... pick_driver selection." A `local` is unreachable from
  tests. completion.lua exports ALL testable units on `M` (e.g. `M.is_attachment_context`, `M.compute_debounce`).
- Decision: export `M.pick_driver` (promote from local). Documented deviation; matches the repo's testing idiom.

---

## 4. resolve_shell — PRD §17.4 fallback chain (the core logic)

### 4a. The §17.4 table + fallback chain (research-prd-section-17.md L82-88)
| `prefer` | Resolved shell | source |
|---|---|---|
| `"pi"` | `descriptor.shell` if advertised; else fall through `"shell"` | `"pi"` (from descriptor) |
| `"shell"` | `$SHELL` | `"$SHELL"` |
| `"bash"` | `/bin/bash` | `"default"` |
| `"/abs/path"` | that path | `"config"` |
- Fallback when `prefer=="pi"` + descriptor omits shell: `descriptor.shell → $SHELL → /bin/bash`.

### 4b. The `source` return string — aligns with descriptor.shellSource union ("pi"|"$SHELL"|"default")
- `"pi"` — came from descriptor.shell (pi's resolved execution shell). Matches descriptor.shellSource="pi".
- `"$SHELL"` — came from `vim.env.SHELL`. Matches descriptor.shellSource="$SHELL".
- `"default"` — the `/bin/bash` last-resort fallback. Matches descriptor.shellSource="default".
- `"config"` — came from `prefer` being an explicit path (a 4th value; the union has no "explicit" member, so
  this is a local-only source label for health-check/logging — documented).
- Used by: §17.4.3 educational notice (P2.M2.T3.S4), health check (P2.M3.T6.S2), dbg logging.

### 4c. Reference logic (the resolve_shell contract #3b, encoded)
```lua
local function descriptor_shell()                 -- FRESH read; nil when unresolved
  local pi = require("pi-bridge")
  local br = pi.bridge
  if br and type(br.get_shell_info) == "function" then
    local si = br.get_shell_info()
    if type(si) == "table" and type(si.shell) == "string" and si.shell ~= "" then return si.shell end
  end
  local desc = pi.descriptor
  if type(desc) == "table" and type(desc.shell) == "string" and desc.shell ~= "" then return desc.shell end
  return nil
end

function M.resolve_shell(prefer)
  prefer = prefer or "pi"
  if type(prefer) == "string" and prefer ~= "" and prefer ~= "pi" and prefer ~= "shell" and prefer ~= "bash" then
    return prefer, "config"                       -- explicit path → verbatim (§17.4 "/abs/path" row)
  end
  if prefer == "pi" then
    local ds = descriptor_shell()
    if ds then return ds, "pi" end                 -- descriptor.shell (always consistent w/ execution)
    -- fall through to $SHELL → /bin/bash
  end
  if prefer == "pi" or prefer == "shell" then
    local env = vim.env.SHELL
    if type(env) == "string" and env ~= "" then return env, "$SHELL" end
    return "/bin/bash", "default"
  end
  if prefer == "bash" then return "/bin/bash", "default" end
  return "/bin/bash", "default"                    -- unknown prefer → safe default
end
```
- Note: `descriptor_shell()` prefers `bridge.get_shell_info()` (which itself merges server_info→descriptor),
  then falls back to `pi.descriptor.shell` directly (covers the bridge==nil pre-handshake window).
- `si.shell ~= ""` guard: get_shell_info() returns nil (not "") per its contract, but defend anyway.

---

## 5. session_cwd — fresh cwd read (PRD §17.5.2 "cwd tracking")

```lua
function M.session_cwd()
  local pi = require("pi-bridge")
  local br = pi.bridge
  if br and type(br.server_info) == "table"
     and type(br.server_info.cwd) == "string" and br.server_info.cwd ~= "" then
    return br.server_info.cwd                      -- live, post-handshake
  end
  local desc = pi.descriptor
  if type(desc) == "table" and type(desc.cwd) == "string" and desc.cwd ~= "" then
    return desc.cwd                                -- env-var blob, available from activate()
  end
  return nil                                       -- unresolved (ensure()/drivers handle nil cwd)
end
```
- Contract #3d: "reads descriptor.cwd (from require('pi-bridge').descriptor or bridge.server_info.cwd)".
  Prefer `server_info.cwd` (live); fall back to `descriptor.cwd`. server_info.cwd is REQUIRED (non-empty).
- `nil` return is acceptable — ensure() (S3) passes cwd to driver.start; a driver may default to the daemon's
  own cwd. PRD §17.5.2: "if it changed since spawn, the driver re-cd's the daemon."

---

## 6. DESIGN DECISIONS (locked)

1. **`pick_driver` is exported `M.pick_driver`** (not `local` as in the skeleton). Reason: the contract's
   MOCKING requires testing it directly; completion.lua exports all testable units on M. Deviation documented.
2. **The drivers-disabled check lives in `pick_driver`, not `resolve_shell`.** Reason: §17.4.2 is about DRIVER
   selection (disabling = no completion = degrade), and pick_driver IS driver selection. resolve_shell stays a
   pure §17.4 shell resolution (the shell is what pi executes — you cannot change it by disabling a driver).
   The item bullet lists it under resolve_shell, but correct layering puts it in pick_driver. This honors the
   intent (drivers ARE checked) at the right layer. See Anti-Patterns.
3. **`M.reset()` is included** (mirrors completion.lua). It's the forward-contract teardown seam (S6
   teardown() prepends kill+close then calls reset()) + test hygiene. The S2 functions are pure (don't mutate
   state), so reset() isn't strictly required for S2 correctness, but state-ownership implies a reset seam
   and completion.lua (the mirrored module) has one. Low cost, consistent.
4. **`state.failed` is included** (contract state literal). Purpose (forward-contract): set `true` when spawn
   fails permanently (S3 ensure()/§17.12) so ensure() doesn't retry endlessly + health check (§17.15) reports
   it. S2 only initializes it `false`; documents the seam.
5. **`state.pending_cb` is included** (contract state literal; the skeleton's request() sets it). S2 declares
   it `nil`; S4's request() assigns the gen-guarded cb. Forward-contract scaffolding.
6. **resolve_shell takes `prefer` as a PARAMETER** (does not read config). Reason: keeps it pure + directly
   unit-testable (pass prefer, assert output). The caller ensure() (S3) reads `config.shell.prefer` and passes
   it. This is the coords.lua/notify.lua pure-function idiom.
7. **`source` strings**: `"pi"` | `"$SHELL"` | `"default"` | `"config"`. First three match descriptor.
   shellSource's union; `"config"` is local-only (explicit-path prefer; documented).

---

## 7. SCOPE FENCE — what S2 does NOT do

- **NO `ensure(on_ready)`** (spawn) — that is S3. shell.lua has NO vim.uv.spawn in S2.
- **NO `request(line,cursor,after,cb)`** (framed protocol + gen-guard bump) — S4. (state.gen/pending_cb are
  DECLARED + documented but not yet bumped.)
- **NO `_feed(chunk)`** (rx_buf sentinel slicing) — S5. (state.rx_buf is declared.)
- **NO `teardown()`** (kill+close) — S6. (M.reset() is the state-clear seam teardown will call.)
- **NO driver modules** (shell/fish.lua etc.) — those are P2.M2.T4 / P2.M3.T5. pick_driver pcall-requires
  them; they're absent → nil (degrade) until those tasks land. Tests inject fakes into package.loaded.
- **NO §17.4.3 educational notice, NO §17.9 first-run hint, NO §17.6.4 degrade notify** — those are
  P2.M2.T3.S4 (notices). shell.lua in S2 has NO vim.notify (the Module docstring references notify.lua as the
  future mechanism, but S2 does not call it).
- **NO config.shell block** in init.lua — that's P2.M3.T6.S1. shell.lua defaults config.shell → `{prefer="pi"}`.
- **NO completion.lua / bridge.lua / init.lua edits** — S2 is additive (ONE new file + 2 test files).
- **NO real shell subprocess in tests** — S2 tests are PURE (inject fake bridge/descriptor + stub vim.env.SHELL
  + inject fake driver into package.loaded). The fish spike (S1) already proved the live subprocess; S2 doesn't
  re-prove it.

---

## 8. TEST STRATEGY (PURE — mirrors notify_smoke.lua + notify_spec.lua)

### 8a. Injection idiom (verified: completion_spec.lua L79-101 uses `pi.bridge = fake`)
- `local pi = require("pi-bridge"); if pi.config == nil then pi.setup({}) end` (self-sufficient, mirror
  completion_spec L18 / smoke GOTCHA D).
- `pi.bridge = { get_shell_info = function() return {shell=..., shellSource=..., shellPath=...} end,
  server_info = {cwd=...} }` — the fake bridge.
- `pi.descriptor = { cwd=..., shell=... }` — the fake descriptor.
- `pi.config = vim.tbl_deep_extend("force", pi.config or {}, { shell = { prefer=..., drivers={...} } })`.
- `vim.env.SHELL = "/bin/zsh"` to set; `vim.env.SHELL = nil` to unset. Save/restore in before/after_each.
- `package.loaded["pi-bridge.shell.fish"] = { start = function() end }` to inject a fake driver (require checks
  package.loaded FIRST); `package.loaded["pi-bridge.shell.fish"] = nil` to remove.

### 8b. shell_smoke.lua (plenary-FREE, `+"luafile" +qa`, prints SMOKE_PASS) — mirrors notify_smoke.lua
Cases (each a `check(cond,msg)`):
- require loads + resolve_shell/pick_driver/session_cwd/reset are functions.
- resolve_shell("pi") + bridge advertises "/bin/zsh" → ("/bin/zsh","pi").
- resolve_shell("pi") + no descriptor shell + SHELL="/bin/zsh" → ("/bin/zsh","$SHELL").
- resolve_shell("pi") + no descriptor shell + SHELL=nil → ("/bin/bash","default").
- resolve_shell("shell") + SHELL="/bin/zsh" → ("/bin/zsh","$SHELL").
- resolve_shell("shell") + SHELL=nil → ("/bin/bash","default").
- resolve_shell("bash") → ("/bin/bash","default").
- resolve_shell("/usr/bin/fish") → ("/usr/bin/fish","config").
- resolve_shell(nil) → defaults to "pi" chain.
- pick_driver("/usr/bin/fish") + fake fish module present → returns the fake.
- pick_driver("/bin/unknownshell") → nil (no module).
- pick_driver("/bin/bash") + config.shell.drivers.bash=false → nil (disabled).
- pick_driver("/bin/bash") + no fake module → nil (module absent, degrade).
- session_cwd(): server_info.cwd="/srv" → "/srv"; no server_info + descriptor.cwd="/desc" → "/desc"; neither → nil.
- never throws on bad args (resolve_shell(123), resolve_shell(""), pick_driver(nil), pick_driver(""), session_cwd() w/ nil everything).

### 8c. shell_spec.lua (plenary/busted) — mirrors notify_spec.lua (before_each reset / after_each restore)
Same matrix as 8b, expressed as `it(...)` cases with field-by-field `assert.are.equals` on the (shell, source)
tuple + truthy/nil on pick_driver + session_cwd strings. ~14-16 cases.

### 8d. Validation gates (run from repo root, wrap in `timeout` per AGENTS.md)
- L1 byte-compile: `timeout 30 nvim --headless --clean -u NORC -c 'lua assert(loadfile("lua/pi-bridge/shell.lua"))' -c 'qa'`.
- L2 smoke: `timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_smoke.lua" +qa`.
- L2 spec: `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'`.
- L3 regression: completion_spec / bridge_handshake_spec stay green (S2 adds a NEW file; touches nothing else).
- NO real-subprocess gate (S2 is pure; the live fish seam is S1's job, already gated).

---

## 9. GOTCHAS

- G1 — **lazy `require("pi-bridge")` INSIDE functions**, never at module top (async handshake + test mocks +
  circular-load avoidance; mirrors completion.lua header + bridge.lua L333/L559).
- G2 — **`config` / `config.shell` may be nil** (config block is P2.M3.T6.S1). Defensive: `(pi.config and
  pi.config.shell) or {}`. resolve_shell takes `prefer` as a param so it never reads config; pick_driver reads
  `(pi.config and pi.config.shell and pi.config.shell.drivers)`.
- G3 — **`bridge` may be nil** pre-handshake. Guard `if br and type(br.get_shell_info)=="function"`. Fall back
  to `pi.descriptor.shell` / `pi.descriptor.cwd` directly.
- G4 — **`string.gsub` returns 2 values**; `local base = s:gsub(".*/","")` adjusts to 1 (the string). Safe in
  assignment; but NEVER use a bare `:gsub(...)` as a function arg or concat operand (would pass 2 values).
  Assign to a local first, then concat — exactly as the skeleton does.
- G5 — **TIB indentation** throughout the repo (verified bridge.lua/init.lua/completion.lua). Match tabs.
- G6 — **no lua linter/formatter** (no luacheck/selene/stylua/.luarc). Validation = the smoke + spec. The only
  "type" surface is luaemmy `---@field` annotations (lua-language-server, not runtime-enforced).
- G7 — **AGENTS.md HARD RULE**: run tests via `+"luafile tests/shell_smoke.lua" +qa` (file on disk). NEVER
  heredoc→nvim stdin (`nvim ... +"luafile /dev/stdin" +qa <<EOF` HANGS the session). The smoke IS a file. Wrap
  every nvim in `timeout` (a hung headless nvim blocks the whole turn).
- G8 — **pick_driver's require path is `pi-bridge.shell.<basename>`** (dotted → `lua/pi-bridge/shell/<base>.lua`).
  That dir/file does not exist in S2 → pcall returns false → nil. Tests inject `package.loaded[...]` to test
  the present-driver path (require checks package.loaded FIRST).
- G9 — **M.pick_driver export** (deviation from skeleton's `local`) is REQUIRED for the contract's MOCKING
  ("Test ... pick_driver selection"). Documented in Design Decision §3c/§6.1.
- G10 — **resolve_shell is pure** (no config read, no state mutation). prefer is a param. This makes it directly
  unit-testable AND keeps the §17.4 resolution decoupled from config-wiring (ensure() in S3 does the wiring).