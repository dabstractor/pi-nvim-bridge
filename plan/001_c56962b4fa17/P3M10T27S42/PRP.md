---
name: "P3.M10.T27.S42 — `:checkhealth pi-editor` module (`health.lua` — version/env/socket/fd checks)"
description: |
  Ship the **`plugin/lua/pi-editor/health.lua`** module so `:checkhealth pi-editor` works
  (PRD §13 Phase 3 step 14: "`:checkhealth pi-editor`"). Neovim's health loader runs
  `require("pi-editor.health").check()` (VERIFIED LIVE: `runtime/lua/vim/health.lua:122`
  `filepath_to_healthcheck` builds that literal string at `:152`; `M._check` `loadstring`s it
  inside a `pcall` at `:456`). So the file MUST be `plugin/lua/pi-editor/health.lua` and the
  function MUST be a **table field `M.check`** (NOT a `local` — the loader would error "report
  is empty" / "Failed to run healthcheck"). The module is **LAZY** (discovered + `require`'d on
  demand; NOT sourced at startup), so it adds zero startup cost and needs NO wiring in
  `init.lua` / the VimEnter shim — `:checkhealth pi-editor` discovers it automatically.

  **THE FOUR CHECK AREAS (the task title — "version, env, socket, fd"):**
    (1) **VERSION** — plugin version (`require("pi-editor.bridge").version` = `"0.1.0"`, mirrors
        `package.json`) + a **Neovim version GATE**. **CRITICAL**: the effective floor is **0.11**,
        NOT 0.10 — `plugin/lua/pi-editor/coords.lua` GOTCHA 9 (`:82-86`) documents that the exact-
        UTF-16 3-arg overload of `vim.str_utfindex` was **ADDED in Neovim 0.11** (News-0.11); PRD
        §10.1's "0.10+" text is superseded (0.12.4 is the verified target). Gate with the
        cross-version-safe `vim.fn.has("nvim-0.11") == 1` (a vimscript builtin present on EVERY
        version — NOT `vim.version.ge/le`, which are **0.12-only**, `version.lua @since 12`). Below
        0.11 → `error` (coords.lua would crash at runtime on older nvim), not warn.
    (2) **ENV** — read `vim.env[env_name]` (`env_name = config.env_var or "PI_EDITOR_BRIDGE"`).
        **DORMANT BY DESIGN**: in a normal nvim session the var is UNSET (PRD §7.1/§11 — the plugin
        only activates when pi spawns the editor). A missing var is **NOT an error** → emit an
        `info` ("dormant — completion is only active inside a pi-launched editor"). When SET → parse
        + validate (`vim.json.decode`, pcall; `transport=="unix"`; report path/pid/cwd/
        serverVersion/fdAvailable via `info`/`ok`); malformed → `error` with restart advice.
    (3) **SOCKET** — **ONLY meaningful when the env var is set** (dormant → `info` "not applicable").
        When active: read the EXISTING live connection state — `require("pi-editor.bridge").is_connected()`
        (`:845`, `state.connected and not state.closed`) → `ok` connected / `warn` not connected;
        `bridge.server_info` (`:188`) → `info` the handshake result (serverVersion/cwd/fdAvailable);
        `vim.uv.fs_stat(descriptor.path)` → `ok` socket file exists / `warn` missing (stale descriptor
        from a dead pi). A live `ping` RPC is a **documented NON-GOAL** (it is async/callback-based in
        this bridge; driving it from a sync `check()` risks a hang on a dead server — `is_connected()`
        already reflects the real socket state).
    (4) **FD** — **runs UNCONDITIONALLY** (the user wants to know whether `@file` completion will work
        when they DO use pi-editor). Client `$PATH` check via `vim.fn.executable` + try BOTH alternates
        `{ "fd", "fdfind" }` (Debian=`fdfind`, Arch/others=`fd`); `vim.fn.exepath` to report the path.
        `fd` is **OPTIONAL** (pi's `@file` fuzzy search silently returns nothing without it, but path
        completion / readdir still works — PRD §11) → report a **`warn` (NOT `error`)** with install
        advice as a `string[]`. Cross-ref the bridge's `descriptor.fdAvailable` / `server_info.fdAvailable`
        (the SERVER's resolution — pi's agent bin dir FIRST then PATH, `extension/pi-editor-bridge.ts:327`)
        and note a server=true/client=false mismatch is PLAUSIBLE + NOT an error.

  **API**: use `vim.health.start/ok/warn/error/info` DIRECTLY (NEW in 0.10; `report_*` REMOVED by
  0.12). `start(name)` = a section heading (call once per section — 4 sections here); `advice` = the
  2nd arg of `warn`/`error`, `string | string[]` (only the FIRST trailing arg is consumed → pass a
  TABLE for multiple advice lines). `vim.health` is a built-in GLOBAL (no `require`).

  **DELIVERABLES (CREATE-ONLY, read-only consumer of EXISTING state — NO module edit, NO TS change):**
    (1) **CREATE** `plugin/lua/pi-editor/health.lua` — `M.check()` with the 4 `health.start()` sections
        above. Reads `vim.health`/`require("pi-editor")`/`require("pi-editor.bridge")` INSIDE `check()`
        (pcall-wrapped) so a broken install / a test swapping globals never throws out of `check()`.
        Every probe is pcall-wrapped (the loader pcall-wraps the WHOLE `check()` — one uncaught throw
        blanks the rest of the report). Export `M.min_nvim = "0.11"` (read by the version gate + tests).
    (2) **CREATE** `plugin/tests/health_spec.lua` — plenary/busted. Stubs the 5 `vim.health.*` to a
        capturing table in `before_each` (EXACTLY how `plugin/tests/notify_spec.lua` stubs `vim.notify`),
        then asserts on captured calls across: dormant session (no env var → no `error`, an `info`
        "dormant"); active session (valid descriptor + connected + server_info → `ok` connected, no
        errors); malformed env var → `error`; fd present → `ok`; fd absent → `warn` + advice; never
        throws on broken bridge/config; nvim-version `ok` line emitted. Also stubs `vim.fn.executable`.
    (3) **CREATE** `plugin/tests/health_smoke.lua` — plenary-FREE smoke (the Level-3 gate per AGENTS.md):
        require the module, call `M.check()` with a stubbed `vim.health`, assert no throw + ≥1 `start`.

  **NON-GOALS:** no live `ping` RPC (sync health, no async/hang risk — `is_connected()` suffices). No
  edits to `init.lua` / the VimEnter shim / `bridge.lua` / any TS (health is a pure read-only consumer).
  No `vimdoc` (that is task S43 — `doc/pi-editor.txt`). No `blink`/`cmp` engine checks (P4, future).
  No `<0.10` `report_*` fallback shim (this repo's floor is 0.11; the new API is guaranteed there).

  **NON-REGRESSION:** `:checkhealth pi-editor` is a NEW entry point that was a no-op before (no
  health.lua existed). All existing specs/smokes are untouched. `init_spec`/`activate_spec`/
  `bridge_*`/`completion_*`/`menu_*` still pass (health requires none of them to have run).
---

# Goal

**Feature Goal**: Make `:checkhealth pi-editor` (PRD §13 Phase 3 step 14) produce a useful,
never-throwing diagnostic report covering the four areas named in the task — **version**,
**env** (the bridge descriptor), **socket** (live connection state), and **fd** (the optional
`@file` binary). The report must be correct in BOTH a dormant normal-config session (no
`PI_EDITOR_BRIDGE`) and an active pi-launched-editor session, and must guide the user toward
the likely fix when something is off — without raising false alarms for the dormant case
(which is the expected state for someone auditing their config).

**Deliverable** (CREATE-ONLY — 1 new module + 2 new test files; NO edit to any existing
source, NO TS change):
- **`plugin/lua/pi-editor/health.lua`** — `M.check()` with 4 `vim.health.start()` sections
  (pi-editor / bridge-environment / bridge-connection / external-tools-fd). Export
  `M.min_nvim = "0.11"`. Read-only consumer of `init.lua` (`config`, `descriptor`) +
  `bridge.lua` (`version`, `is_connected()`, `server_info`). Never throws.
- **`plugin/tests/health_spec.lua`** — plenary/busted unit tests (stub-capture pattern).
- **`plugin/tests/health_smoke.lua`** — plenary-free smoke (no-throw + ≥1 `start`).

**Success Definition**:
- `:checkhealth pi-editor` runs (the loader finds `plugin/lua/pi-editor/health.lua` and calls
  `require("pi-editor.health").check()`) and produces a 4-section report with NO "Failed to run
  healthcheck" / "report is empty" error.
- The Neovim version gate reports `error` below 0.11 (with upgrade advice) and `ok` at/above.
- In a **dormant** session (`PI_EDITOR_BRIDGE` unset) the report emits an `info` "dormant" and
  **zero** `error` lines.
- In an **active** session (valid descriptor + connected bridge + handshake result) the report
  emits `ok` "connected" + `info` the descriptor fields, and **zero** `error` lines.
- A malformed `PI_EDITOR_BRIDGE` (bad JSON / wrong transport) → an `error`/`warn` naming it.
- `fd` present → `ok` (with the resolved path); `fd` absent → a `warn` (NOT error) with install
  advice, and a note that the bridge may still have `fd` in its bin dir.
- `M.check()` **never throws** (broken/missing bridge or init module, nil config, nil
  descriptor, bad env var) — every probe is pcall-wrapped.
- The module is discovered by bare `:checkhealth` (auto-discovery) too.
- No existing test changes; the plugin source tree is otherwise untouched.

## User Persona

**Target User**: a pi user installing / configuring / debugging `pi-editor.nvim` — either
auditing their normal Neovim config (`:checkhealth pi-editor` from their daily nvim) or
troubleshooting a pi editor session where completion isn't appearing.

**Use Case**: "I installed pi-editor.nvim but I don't see `/model` completion when pi opens
nvim — what's wrong?" They run `:checkhealth pi-editor` and get a structured report telling
them (a) their nvim is too old, (b) completion is dormant (expected — they're in normal nvim),
(c) the bridge didn't connect / handshake failed, or (d) `fd` isn't installed (so `@file`
won't work) — each with a concrete next step.

**Pain Points Addressed**: today there is no `:checkhealth` for this plugin (PRD §13 step 14
is not done), so debugging is `:messages` + guesswork. The health report consolidates the four
most common failure modes (version, dormant-vs-active confusion, connection, fd) into one view.

## Why

- **PRD fidelity**: PRD §13 (Implementation Plan, Phase 3 — Polish) step 14 literally lists
  "`:checkhealth pi-editor`" as a ship item. This task delivers it.
- **Closes the diagnostics gap**: every other Neovim plugin a user has ships a `health.lua`;
  the absence of one here is a visible quality/UX gap for a plugin that depends on an external
  socket + an optional binary + a specific nvim version.
- **Dormant-by-design clarity**: the plugin's #1 support confusion is "I installed it but
  nothing happens in nvim" — because it is dormant outside a pi session. The health report's
  explicit `info "dormant"` line teaches the user the activation model in one read.
- **Read-only, zero-risk**: health is a pure consumer of state the plugin already computes
  (`descriptor`, `is_connected()`, `server_info`). It cannot regress any feature.

## What

`:checkhealth pi-editor` (or bare `:checkhealth`, which auto-discovers it) loads
`plugin/lua/pi-editor/health.lua` and calls `M.check()`. The report has four `start()`
sections:

1. **`pi-editor`** — plugin version (`bridge.version`) + a Neovim `>= 0.11` gate
   (`vim.fn.has("nvim-0.11")`).
2. **`pi-editor bridge (environment)`** — `PI_EDITOR_BRIDGE` present? Absent → `info "dormant"`.
   Present → parse/validate + report the descriptor fields.
3. **`pi-editor bridge (connection)`** — dormant → `info "n/a"`. Active → `is_connected()` +
   `server_info` + `fs_stat(socket path)`.
4. **`pi-editor external tools (fd)`** — `fd`/`fdfind` on `$PATH` (always), cross-ref the
   server's `fdAvailable`.

### Success Criteria

- [ ] `:checkhealth pi-editor` runs `require("pi-editor.health").check()` (file at
      `plugin/lua/pi-editor/health.lua`; function is `M.check`, NOT a local).
- [ ] Report has the 4 `start()` sections; no "report is empty" / "Failed to run healthcheck".
- [ ] Neovim version: `error` below 0.11 (advice: upgrade); `ok` at/above (shows the version).
- [ ] Dormant session (`PI_EDITOR_BRIDGE` unset): an `info` "dormant"; **zero** `error` calls.
- [ ] Active session (valid unix descriptor + connected + server_info): `ok` connected + `info`
      fields; **zero** `error` calls.
- [ ] Malformed env var (bad JSON / wrong transport): an `error`/`warn` naming it.
- [ ] Socket section (active only): `is_connected()` → `ok`/`warn`; `server_info` → `info`;
      `fs_stat(path)` → `ok` exists / `warn` missing. Dormant → `info "n/a"`.
- [ ] `fd` section runs always: present → `ok` (with path); absent → `warn` (NOT error) with
      `string[]` install advice; cross-refs `descriptor.fdAvailable`/`server_info.fdAvailable`.
- [ ] `M.check()` never throws (broken bridge/init, nil config/descriptor, bad env) — every
      probe pcall-wrapped.
- [ ] Reads `vim.health`/`require("pi-editor")`/`require("pi-editor.bridge")` INSIDE `check()`
      (call-time) so tests can stub `vim.health` + swap module state.
- [ ] Exports `M.min_nvim = "0.11"` (read by the gate + asserted by tests).
- [ ] No existing test/source changes; no TS change; no `init.lua`/shim wiring.

## All Needed Context

### Context Completeness Check

_Passed._ A reader who knows nothing of this codebase gets: the exact loader contract (file
path + the hardcoded `M.check` name + the pcall-scope gotcha — all VERIFIED against the 0.12.4
runtime), the exact `vim.health` API (signatures + advice arity), the exact version floor (0.11
— NOT 0.10 — with the coords.lua evidence), the exact existing-state accessors to consume
(`config`/`descriptor`/`bridge.version`/`is_connected()`/`server_info` with line numbers), the
exact dormant-vs-active design + why a missing env var is `info` not `error`, the exact test
pattern (stub `vim.health` exactly like `notify_spec.lua` stubs `vim.notify`), the gold-standard
`fd`/`fdfind` WARN pattern (telescope), and copy-ready code. No pi-source knowledge required.

### Documentation & References

```yaml
# MUST READ — the Neovim health loader + API (VERIFIED LIVE on NVIM 0.12.4)
- url: https://github.com/neovim/neovim/blob/master/runtime/lua/vim/health.lua
  why: |
    The authoritative source for BOTH the loader + the API. `filepath_to_healthcheck` (:122)
    builds `func = 'require("pi-editor.health").check()'` (:152); `M._check` `loadstring`s it
    inside a `pcall` (:456-463) — an UNCAUGHT throw in check() blanks the rest of the report.
    API fns: `M.start(name)` (:272), `M.info(msg)` (:280), `M.ok(msg)` (:288), `M.warn(msg,...)`
    (:297), `M.error(msg,...)` (:307). `format_report_message` (:233) shows `advice` = the 2nd
    arg, `string|string[]` (only the FIRST trailing arg is consumed → pass a TABLE for multi-line).
  critical: |
    (1) `check` is HARDCODED — must be `M.check`, not a `local`. (2) `:458` pcall wraps the WHOLE
    check() → pcall EACH probe. (3) `vim.health` is a built-in GLOBAL (no require). (4) `:446`
    resets `s_output` per-check → a throw means nothing from THAT check is emitted except the
    generic error line.
  tag: ":help health-dev", ":help :checkhealth"

- file: /usr/share/nvim/runtime/lua/vim/health.lua   # the locally-installed 0.12.4 copy
  why: Identical to the upstream URL above but LOCAL — read it to confirm the API/loader facts.
  pattern: mirror the doc-comment sample `M.check = function() ... vim.health.start(...) ... end`.

- url: https://github.com/neovim/neovim/blob/master/runtime/doc/deprecated.txt
  why: "*deprecated-0.10* CHECKHEALTH subsection — `report_*` deprecated, replaced by
        `start/ok/warn/error/info` in 0.10 (and REMOVED by 0.12). → use the NEW API directly;
        NO `report_*` fallback shim (this repo's floor is 0.11)."

- url: https://github.com/neovim/neovim/blob/master/runtime/lua/vim/version.lua
  why: "`@since` tags prove `vim.version.ge/le` are 0.12-ONLY and `cmp/eq/lt/gt` are 0.11-only.
        → the cross-version-safe gate idiom is `vim.fn.has('nvim-0.11')` (a vimscript builtin on
        EVERY version), NOT `vim.version.ge`."

# MUST READ — the EXISTING state health consumes (read-only; do NOT modify)
- file: plugin/lua/pi-editor/init.lua
  why: |
    `M.config` (:39, nil until setup()) — read `config.env_var or "PI_EDITOR_BRIDGE"` for the env
    var name. `M.descriptor` (:107, nil until activate() succeeds) — the parsed descriptor; fields
    `.transport/.path/.token/.pid/.cwd/.fdAvailable/.serverVersion` (the `pi-editor.BridgeDescriptor`
    class doc :99-105). `M.defaults` (:33) — the shipped defaults (for reference). Read FRESH inside
    check() (config may be nil → fall back to the literal default env name).
  gotcha: config can be nil (user never called setup()) → pcall + default the env name.

- file: plugin/lua/pi-editor/bridge.lua
  why: |
    `M.version = "0.1.0"` (:176, mirrors package.json) — the plugin version line. `M.is_connected()`
    (:845, `state.connected and not state.closed`) — the live connection gate. `M.server_info`
    (:188, nil until handshake succeeds; `{serverVersion,cwd,fdAvailable}`) — the handshake result.
  gotcha: `require("pi-editor.bridge")` may FAIL in a broken install → pcall the require; a nil
    `bridge` table must not throw downstream (guard `type(bridge.is_connected)=="function"`).

# MUST READ — the test pattern to mirror EXACTLY (the global-stub idiom)
- file: plugin/tests/notify_spec.lua
  why: |
    THE pattern: `before_each` saves + replaces a global (`vim.notify` there; `vim.health` here)
    with a capturing stub, each test flushes + asserts on the captured calls, `after_each` restores.
    Mirror its structure for `health_spec.lua`: stub `vim.health.start/ok/warn/error/info` to a
    table of `{method, msg, advice}` records, call `health.check()`, assert on the captured table.
  pattern: `local calls; before_each(function() calls={}; orig=vim.X; vim.X=stub end); after_each(...)`.
  gotcha: the module reads `vim.health` at CALL time (inside check()) so the stub wins WITHOUT
    `package.loaded` surgery — KEEP that property (do NOT cache `vim.health` in a module-level local).

- file: plugin/tests/notify_smoke.lua
  why: |
    THE smoke pattern (plenary-free): set `rtp += plugin_root`, require the module, stub the global,
    drive the public fn, assert + `print("SMOKE_PASS")` / `vim.cmd("cquit 1")` on fail. Mirror it
    for `health_smoke.lua` (stub `vim.health`, call `health.check()`, assert no throw + ≥1 start).

# MUST READ — the fd/fdfind optional-WARN gold standard
- url: https://github.com/nvim-telescope/telescope.nvim/blob/master/lua/telescope/health.lua
  why: |
    The canonical "optional binary missing → WARN (not error) with install advice" pattern. Tries
    alternate binary names in order, gates on `vim.fn.executable`, reports `vim.fn.exepath`, passes
    multi-line advice. Model the health.lua `fd` section directly on this.
  critical: try BOTH `{ "fd", "fdfind" }` (Debian ships `fdfind`); WARN (optional), not error.

# MUST READ — the version-gate idiom
- url: https://github.com/mason-org/mason.nvim/blob/main/lua/mason/health.lua
  why: "`check_neovim` uses `vim.fn.has("nvim-0.10.0") == 1` → `report_ok`/`report_error`. Copy the
        `vim.fn.has` gate (NOT `vim.version.ge`). (Ignore mason's `report_*` shim — this repo is 0.11+.)"

# Reference — the BridgeDescriptor wire shape (health validates the env var against it)
- file: extension/protocol.ts
  section: "§B — BridgeDescriptor"
  why: The env var is `JSON.stringify` of this interface (`{transport:"unix",path,token,pid,cwd,
        fdAvailable,serverVersion}`). health's parse/validate mirrors these fields. Read-only.

# Reference — the fd resolver the BRIDGE uses (the server-side resolution health cross-refs)
- file: extension/pi-editor-bridge.ts
  section: "`resolveFdAvailable` (:327) — pi agent bin dir FIRST, then $PATH"
  why: Explains WHY a server=true/client=false `fdAvailable` mismatch is PLAUSIBLE (server found fd
        in its bin dir, not on the editor's $PATH) + NOT an error. health documents this in its fd
        section. Read-only; no TS change.

# PRD anchors
- url: (in-repo) PRD §7.1 (dormant-by-design activation gate), §10.1 (Neovim 0.10+ / 0.12 verified —
        superseded to 0.11 by coords.lua GOTCHA 9), §11 (silent degradation; fd missing → @file empty),
        §13 step 14 (:checkhealth pi-editor)
  why: the spec S42 implements.
```

### Current Codebase tree (relevant slice)

```bash
plugin/
  lua/pi-editor/
    init.lua          # M.config (.env_var), M.descriptor — health READS these (do NOT modify)
    bridge.lua        # M.version, M.is_connected(), M.server_info — health READS these (do NOT modify)
    coords.lua  completion.lua  jsonlreader.lua  menu.lua  notify.lua   # unchanged (coords.lua: floor=0.11)
    # health.lua  ← NEW (this task)
  plugin/pi-editor.lua   # VimEnter shim (unchanged — health needs NO wiring; :checkhealth discovers it)
  ftplugin/pi-prompt.lua # buffer-local setup (unchanged)
  tests/
    minimal_init.lua        # plenary harness (unchanged)
    notify_spec.lua         # THE global-stub test pattern to MIRROR (vim.notify → vim.health)
    notify_smoke.lua        # THE smoke pattern to MIRROR
    # health_spec.lua   ← NEW (this task)
    # health_smoke.lua  ← NEW (this task)
extension/                  # NO TS change (health is client-only, read-only)
```

### Desired Codebase tree with files to be added and responsibility

```bash
plugin/lua/pi-editor/health.lua    # NEW — M.check() (:checkhealth pi-editor): 4 sections (version/env/socket/fd).
                                   #       Read-only consumer of init.lua config/descriptor + bridge.lua
                                   #       version/is_connected/server_info. Never throws; pcall each probe.
                                   #       Export M.min_nvim="0.11". Lazy (no startup cost; no wiring).
plugin/tests/health_spec.lua       # NEW — plenary/busted. Stub vim.health.* (mirror notify_spec.lua),
                                   #       assert captured calls across dormant/active/malformed/fd cases.
plugin/tests/health_smoke.lua      # NEW — plenary-free smoke: stub vim.health, call check(), no throw + ≥1 start.
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (loader): `require("pi-editor.health").check()` is run by the loader VERBATIM
-- (runtime/lua/vim/health.lua:152). `check` MUST be `M.check` (a table field), NEVER a
-- `local function check()`. A local is invisible to the loader → "report is empty".

-- CRITICAL (loader pcall scope): M._check pcall-wraps the ENTIRE check() (:458). ONE uncaught
-- throw blanks the rest of the report + resets s_output (:446). → pcall EACH probe
-- (vim.json.decode, fs_stat, executable, require's). Never let one bad probe hide the others.

-- CRITICAL (version floor = 0.11, NOT 0.10): coords.lua GOTCHA 9 (:82) — the exact-UTF-16
-- 3-arg `vim.str_utfindex` overload was ADDED in 0.11. PRD §10.1 "0.10+" is superseded.
-- Gate with `vim.fn.has("nvim-0.11") == 1` (cross-version-safe vimscript builtin). Do NOT use
-- `vim.version.ge/le` (0.12-only) or `cmp/eq/lt/gt` (0.11-only). Below 0.11 → `error` (coords
-- would crash on older nvim at runtime), NOT warn.

-- CRITICAL (API): use `vim.health.start/ok/warn/error/info` DIRECTLY (NEW in 0.10; `report_*`
-- REMOVED by 0.12). NO `report_*` shim (floor is 0.11). `advice` = the 2nd arg of warn/error,
-- `string|string[]` — pass a TABLE for multiple lines (`warn(msg,"a","b")` DROPS "b").

-- CRITICAL (dormant ≠ error): in a normal nvim session PI_EDITOR_BRIDGE is UNSET (PRD §7.1/§11).
-- A missing env var is the EXPECTED state. Emit an `info` "dormant", NOT an `error`/`warn`.
-- Gate the env-DETAIL + socket sections on the env var being set. The fd section runs ALWAYS.

-- CRITICAL (test-friendly): read `vim.health` + `require("pi-editor")`/`.config`/`.descriptor` +
-- `require("pi-editor.bridge")`/`.version`/`.is_connected()`/`.server_info` INSIDE check()
-- (call-time, pcall-wrapped) — do NOT cache `vim.health` in a module-level local. The test
-- swaps `vim.health` in before_each (exactly notify_spec.lua's idiom); a module-level cache
-- would freeze the real `vim.health` and defeat the stub.

-- GOTCHA (client/server fd nuance): the bridge's `descriptor.fdAvailable`/`server_info.fdAvailable`
-- is the SERVER's resolution (pi agent bin dir FIRST, then PATH). The nvim CLIENT only sees $PATH
-- (`vim.fn.executable`). server=true/client=false is PLAUSIBLE + NOT an error — report BOTH + note it.

-- GOTCHA (fd optional): `fd` is OPTIONAL — `warn` (NOT error) when missing. pi's @file fuzzy
-- search silently returns nothing, but path completion (readdir) still works (PRD §11). Try BOTH
-- alternates `{ "fd", "fdfind" }` (Debian=fdfind).

-- GOTCHA (config may be nil): the user may never have called setup() (NVIM_APPNAME minimal config).
-- `require("pi-editor").config` can be nil → default the env name to the literal "PI_EDITOR_BRIDGE".

-- GOTCHA (server_info may be nil): handshake is ASYNC. server_info is nil until hello succeeds
-- (and nil again after close()). Treat nil as `info "handshake in flight or failed"`, never error.

-- NEVER issue a live `ping` RPC from check() — it is async/callback-based in this bridge; driving
-- it from a sync check() risks a hang on a dead server. `is_connected()` already reflects the real
-- socket state (set true ONLY in the connect-success path; cleared on close/EOF). Documented non-goal.

-- NEVER pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — it hangs). Write test snippets to a
-- FILE and run with `+"luafile <path>"`. Wrap EVERY nvim invocation in `timeout`.
```

## Implementation Blueprint

### Data models and structure

No new data model. The module exports a singleton table `M` with:
- `M.min_nvim = "0.11"` (a `string` constant — read by the version gate + asserted by tests; also
  documents the floor in one place so a future floor bump is a one-line change).
- `M.check()` (the loader entry point; takes no args, returns nothing; never throws).

All probe results are transient LOCALS inside `check()`. No module-level mutable state (mirrors
`notify.lua` / `jsonlreader.lua`'s one-responsibility-per-module style). The report's state lives
entirely in Neovim's `vim.health` module-local `s_output` (health appends to it; we never touch it).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/lua/pi-editor/health.lua — M.check() with 4 sections
  - FILE: plugin/lua/pi-editor/health.lua (the runtimepath-relative lua/pi-editor/health.lua;
          rtp root is plugin/ — VERIFIED `require("pi-editor")` resolves there).
  - EXPORT: `M.min_nvim = "0.11"` (string) ABOVE `M.check`; document the coords.lua GOTCHA 9 basis.
  - EXPORT: `function M.check()` (a TABLE FIELD — never `local function check()`).
  - HEADER: a [Mode A] comment block covering the loader contract + the API + the pcall-scope gotcha
            + the 0.11 floor + dormant≠error + read-at-call-time + fd-optional + client/server nuance.
  - BODY (EXACT shape — copy-ready skeleton in "Implementation Patterns" below):
      local health = vim.health                         -- capture ONCE at top of check() (stub-friendly)
      local uv = vim.uv
      local pi; pcall(function() pi = require("pi-editor") end)   -- nil-safe (broken install)
      SECTION 1 "pi-editor":
        plugin version: pcall require("pi-editor.bridge").version → ok("pi-editor.nvim v%s") / warn(failed)
        nvim gate: if vim.fn.has(M.min_nvim)==1 then ok("Neovim %s (>= %s required)") else error(...,advice[])
      SECTION 2 "pi-editor bridge (environment)":
        env_name = "PI_EDITOR_BRIDGE"; pcall inherit config.env_var if present
        raw = vim.env[env_name]; desc = pi and pi.descriptor or nil
        if raw==nil and desc==nil → info("dormant — ...")
        else → parse raw (pcall vim.json.decode + type check); bad → error(...); transport!="unix" → warn
               else desc = pi.descriptor or decoded; info() path/pid/cwd/serverVersion/fdAvailable
      SECTION 3 "pi-editor bridge (connection)":
        if dormant (raw==nil and desc==nil) → info("not applicable — dormant")
        else: bridge = pcall require; connected = pcall bridge.is_connected() → ok/warn
              sinfo = bridge.server_info (type-check) → info / info("no handshake result yet")
              if desc.path: pcall uv.fs_stat → ok(exists) / warn(missing, advice)
      SECTION 4 "pi-editor external tools (fd)":
        first_exec{"fd","fdfind"} via vim.fn.executable + exepath → ok("`fd` found: %s") / warn(missing, advice[])
        cross-ref: server_fd = desc.fdAvailable or bridge.server_info.fdAvailable (pcall)
                   server_fd==true and not fd → info("bridge has fd in bin dir")
                   server_fd==false and fd     → info("on $PATH but bridge says unavailable")
  - FOLLOW pattern: the doc-comment sample in runtime/lua/vim/health.lua (start → ok/error); telescope's
            fd WARN; mason's `vim.fn.has` gate; this repo's never-throws + pcall-everything style.
  - NAMING: `M.check` (loader-fixed); `M.min_nvim` (snake_case const); local fns `first_exec` etc.
  - PLACEMENT: top-level module (plugin/lua/pi-editor/health.lua); `return M` at the end.
  - DO NOT: issue a live `ping` RPC; cache `vim.health` in a module-level local; use `report_*`;
            use `vim.version.ge` (0.12-only); error on a missing env var; error on a missing `fd`;
            edit any other file.

Task 2: CREATE plugin/tests/health_spec.lua — plenary/busted unit tests
  - FILE: plugin/tests/health_spec.lua.
  - HARNESS: reuse tests/minimal_init.lua (plenary). Header comment with the run command (mirror notify_spec.lua).
  - STUB (before_each): save + replace `vim.health` with a capturing table:
        local captured = {}
        local function stub(method) return function(msg, advice) captured[#captured+1] = {method=method, msg=msg, advice=advice} end end
        vim.health = { start=stub("start"), ok=stub("ok"), warn=stub("warn"), error=stub("error"), info=stub("info") }
    (after_each restores the original `vim.health`). ALSO save/restore `vim.env.PI_EDITOR_BRIDGE`,
    `vim.fn.executable`, `require("pi-editor").descriptor`, `require("pi-editor").config`,
    `require("pi-editor.bridge").is_connected`/`.server_info` per-case (table of saved originals).
  - HELPERS:
      local function has(method, predicate) ... — `vim.iter`/loop over captured for a method matching predicate
      local function any_error() return has("error") end ; local function any_info_substr(s) ... end
  - CASES (mirror notify_spec.lua's one-line `it("…")` grammar):
      (a) surface: `require("pi-editor.health")` is a table; `.check` is a function; `.min_nvim == "0.11"`.
      (b) dormant (env unset, descriptor nil): `check()` runs; `start` called ≥4×; NO `error` calls;
          at least one `info` msg contains "dormant".
      (c) nvim version (>=0.11 here): at least one `ok` whose msg contains "Neovim"; no `error` for version.
          (Stub `vim.fn.has`→0 in a sub-case to exercise the error branch + advice; restore after.)
      (d) active session (set a VALID descriptor on `require("pi-editor").descriptor`; stub
          bridge.is_connected→true; server_info={serverVersion="0.1.0",cwd="/x",fdAvailable=true};
          set vim.env.PI_EDITOR_BRIDGE to JSON of the descriptor): an `ok` "connected"; `info` lines for
          path/pid/cwd/serverVersion; NO `error` calls.
      (e) malformed env var (set vim.env.PI_EDITOR_BRIDGE="{not json" or `"123"` or a JSON object with
          transport!="tcp"): an `error` (bad JSON) OR a `warn` (wrong transport); NO throw.
      (f) fd present (stub vim.fn.executable→1 for "fd"): an `ok` whose msg contains "fd".
      (g) fd absent (stub vim.fn.executable→0 for ALL names): a `warn` (NOT error) whose advice is a
          table (string[]) containing "sharkdp/fd"; NO error.
      (h) server=true/client=false fd nuance (descriptor.fdAvailable=true; vim.fn.executable→0): a `warn`
          for fd absent AND an `info` noting the bridge has fd in its bin dir.
      (i) never throws: break `require("pi-editor.bridge")` (force the pcall require to fail via a
          package.loaded trick OR a nil descriptor + nil bridge): `check()` does not throw (pcall it;
          assert ok); still emits a `start` + a version `warn`/`ok`.
      (j) socket file missing (descriptor.path="/nonexistent/sock"; fs_stat returns nil): a `warn` whose
          msg contains "missing" (active session).
      (k) not connected (bridge.is_connected→false; env set): a `warn` "not connected" (NOT error).
  - NAMING: `it("…", …)`; `describe("pi-editor.health (S42)", …)`.
  - PLACEMENT: a top-level `describe` (the file's only one).
  - NOTE: do NOT name a local `pending` (shadows plenary.busted's skip fn — cf. completion_spec.lua header).

Task 3: CREATE plugin/tests/health_smoke.lua — plenary-free smoke (the Level-3 gate per AGENTS.md)
  - FILE: plugin/tests/health_smoke.lua. Header with the run command (mirror notify_smoke.lua).
  - BODY:
      set rtp += plugin_root (debug.getinfo :h:h)
      stub vim.health to a capturing table (start/ok/warn/error/info)
      local ok, err = pcall(require("pi-editor.health").check)
      check(ok, "check() does not throw") ; check(#captured.start >= 1, "≥1 start section")
      print a couple of captured lines for human eyeballing (optional)
      on fail: io.stderr:write + vim.cmd("cquit 1"); on pass: io.stdout:write("SMOKE_PASS\n")
  - FOLLOW pattern: notify_smoke.lua (the `fails`/`check`/`SMOKE_PASS` skeleton).
  - This is the plenary-free Level-3 gate. NO `:lua <<HEREDOC` in a -c arg (AGENTS.md — source via :luafile).
```

### Implementation Patterns & Key Details

```lua
-- === plugin/lua/pi-editor/health.lua — copy-ready skeleton (Task 1) ===
--- health.lua — the `:checkhealth pi-editor` module (S42; PRD §13 step 14).
--- [Mode A header — loader contract + API + pcall-scope gotcha + 0.11 floor + dormant≠error +
---  read-at-call-time + fd-optional + client/server nuance. SEE the PRP Gotchas section verbatim.]
local M = {}

--- Minimum Neovim version the plugin can run on. coords.lua GOTCHA 9: the exact-UTF-16 3-arg
--- `vim.str_utfindex` overload was ADDED in 0.11 (PRD §10.1 "0.10+" is superseded). 0.12.4 verified.
M.min_nvim = "0.11"

--- The `:checkhealth pi-editor` report. Run by the loader as `require("pi-editor.health").check()`
--- (VERIFIED runtime/lua/vim/health.lua:152). Never throws — every probe is pcall-wrapped (the
--- loader pcall-wraps the WHOLE call at :458; one uncaught throw blanks the rest of the report).
--- Read-only consumer of EXISTING plugin state (init.lua config/descriptor; bridge.lua version/
--- is_connected/server_info). Four sections: version / bridge-environment / bridge-connection / fd.
function M.check()
  local health = vim.health                       -- built-in global; capture ONCE (stub-friendly)
  local uv = vim.uv
  local pi ---@type table|nil
  pcall(function() pi = require("pi-editor") end) -- nil-safe (broken install / minimal config)

  -- ===== Section 1: pi-editor (version) =====
  health.start("pi-editor")
  local pver
  pcall(function() pver = require("pi-editor.bridge").version end)
  if pver then
    health.ok(("pi-editor.nvim v%s"):format(pver))
  else
    health.warn("could not read pi-editor version (bridge module failed to load)")
  end
  if vim.fn.has(M.min_nvim) == 1 then             -- cross-version-safe gate (NOT vim.version.ge — 0.12-only)
    health.ok(("Neovim %s (>= %s required)"):format(tostring(vim.version()), M.min_nvim))
  else
    health.error(("Neovim %s — pi-editor requires >= %s"):format(tostring(vim.version()), M.min_nvim), {
      "Upgrade Neovim: https://github.com/neovim/neovim/releases",
      "The exact-UTF-16 cursor conversion (coords.lua) needs the 3-arg vim.str_utfindex overload added in 0.11.",
    })
  end

  -- ===== Section 2: pi-editor bridge (environment) =====
  health.start("pi-editor bridge (environment)")
  local env_name = "PI_EDITOR_BRIDGE"
  pcall(function() if pi and pi.config and pi.config.env_var then env_name = pi.config.env_var end end)
  local raw = vim.env[env_name]
  local desc = (pi and pi.descriptor) or nil      -- the descriptor activate() parsed (authoritative)
  if raw == nil and desc == nil then
    health.info(("%s is not set — pi-editor is dormant (this is normal outside a pi editor session)."):format(env_name))
  else
    health.ok(("%s is set"):format(env_name))
    local d = desc
    if raw ~= nil and d == nil then               -- var set but activate() hasn't run → parse it
      local ok, parsed = pcall(vim.json.decode, raw)
      if not ok or type(parsed) ~= "table" then
        health.error(("%s is not valid JSON"):format(env_name), {
          "The bridge extension writes this var when pi starts. Restart pi.",
          "If it persists, the pi-editor-bridge extension may be mis-installed.",
        })
        d = nil
      elseif parsed.transport ~= "unix" then
        health.warn(("bridge transport is %q (expected \"unix\")"):format(tostring(parsed.transport)))
        d = parsed
      else
        d = parsed
      end
    end
    if d then
      health.info(("socket: %s"):format(tostring(d.path)))
      health.info(("pi pid: %s"):format(tostring(d.pid)))
      health.info(("session cwd: %s"):format(tostring(d.cwd)))
      health.info(("bridge server version: %s"):format(tostring(d.serverVersion)))
      health.info(("server reports fd available: %s"):format(tostring(d.fdAvailable)))
    end
    desc = desc or d                               -- keep whichever we resolved for sections 3-4
  end

  -- ===== Section 3: pi-editor bridge (connection) =====
  health.start("pi-editor bridge (connection)")
  if raw == nil and desc == nil then
    health.info("not applicable — pi-editor is dormant (no bridge to connect to).")
  else
    local bridge ---@type table|nil
    pcall(function() bridge = require("pi-editor.bridge") end)
    local connected = false
    pcall(function() connected = (type(bridge) == "table" and type(bridge.is_connected) == "function") and bridge.is_connected() or false end)
    if connected then
      health.ok("bridge socket connected (completion active)")
    else
      health.warn("bridge socket not connected — completion is inactive (the buffer still works as plain markdown).", {
        "Save+quit and re-open the editor from pi (default key: Ctrl+G).",
        "If it persists: run `:messages` and look for a handshake error (bad token / connection refused).",
      })
    end
    local sinfo
    pcall(function() sinfo = bridge and bridge.server_info end)
    if type(sinfo) == "table" then
      health.info(("handshake ok — server %s, cwd %s"):format(tostring(sinfo.serverVersion), tostring(sinfo.cwd)))
    else
      health.info("no handshake result yet (handshake may still be in flight or failed).")
    end
    if desc and desc.path then
      local stat
      pcall(function() stat = uv.fs_stat(desc.path) end)
      if stat then
        health.ok(("socket file exists: %s"):format(desc.path))
      else
        health.warn(("socket file missing: %s"):format(desc.path), {
          "pi may have exited while the editor was open. Quit the editor and re-open from pi.",
        })
      end
    end
  end

  -- ===== Section 4: pi-editor external tools (fd) — runs UNCONDITIONALLY =====
  health.start("pi-editor external tools (fd)")
  local function first_exec(names)
    for _, n in ipairs(names) do
      if vim.fn.executable(n) == 1 then return n, vim.fn.exepath(n) end
    end
  end
  local fd, fpath = first_exec { "fd", "fdfind" }   -- Debian=fdfind, Arch/others=fd
  if fd then
    health.ok(("`%s` found: %s"):format(fd, fpath))
  else
    health.warn("`fd`/`fdfind` not found on $PATH — pi's `@file` fuzzy search will be unavailable (path completion still works).", {
      "Optional. Install it: https://github.com/sharkdp/fd",
      "Debian/Ubuntu: `apt-get install fd-find` (the binary is `fdfind`).",
      "Note: the bridge resolves fd in pi's agent bin dir FIRST, then $PATH — @file may still work even if not on your $PATH.",
    })
  end
  local server_fd
  pcall(function()
    local s = (bridge and bridge.server_info) or {}
    server_fd = (desc and desc.fdAvailable)
    if server_fd == nil then server_fd = s.fdAvailable end
  end)
  if server_fd == true and not fd then
    health.info("the bridge reports `fd` IS available (resolved in pi's bin dir) though it is not on this editor's $PATH.")
  elseif server_fd == false and fd then
    health.info("`fd` is on your $PATH but the bridge reports it unavailable — `@file` completion may be limited.")
  end
end

return M

-- KEY DETAIL (why `vim.fn.has`, not `vim.version.ge`): `ge`/`le` are 0.12-only (`version.lua @since 12`);
-- `has('nvim-0.11')` is a vimscript builtin on EVERY version. The floor itself is 0.11 (coords.lua
-- GOTCHA 9), NOT the PRD §10.1 text's 0.10.

-- KEY DETAIL (why capture `local health = vim.health` INSIDE check, not at module top): the unit
-- test swaps `vim.health` in before_each (exactly notify_spec.lua's idiom). A module-level
-- `local health = vim.health` would freeze the REAL vim.health and defeat the stub. Reading it
-- inside check() (call-time) keeps the module stub-friendly.

-- KEY DETAIL (why `server_info`/`is_connected` and NOT a live `ping`): handshake is async; a live
-- ping from a sync check() risks a hang on a dead server. is_connected() + server_info are the
-- EXISTING live state (set/cleared by the real connect/handshake/close paths) — sufficient + safe.
```

### Integration Points

```yaml
NEOVIM HEALTH LOADER: discovers plugin/lua/pi-editor/health.lua automatically (nvim_get_runtime_file
  glob lua/**/pi-editor/health.lua); runs require("pi-editor.health").check(). NO registration needed
  in init.lua / the VimEnter shim / package.json. (VERIFIED: a throwaway health.lua on rtp was found +
  resolved with `:checkhealth pi-editor`'s exact loader path.)
AUTOCMDS / EVENTS: NONE. `:checkhealth` is a user command, not an autocmd. health.lua is lazy.
STATE (init.lua / bridge.lua): READ-ONLY. health reads config.env_var, descriptor, bridge.version,
  bridge.is_connected(), bridge.server_info. It modifies NOTHING (no set_state, no reconnect).
CONFIG (init.lua defaults): NONE new. min_nvim is a module-local const on health.lua (not a config opt).
EXTENSION (TS): NONE. health is client-only + read-only. descriptor.fdAvailable / server_info.fdAvailable
  are CONSUMED (not changed).
DOC: NONE in this task (vimdoc is S43). A `:checkhealth pi-editor` mention in doc/pi-editor.txt is S43's job.
```

## Validation Loop

> **AGENTS.md HARD RULE:** NEVER pipe a heredoc into `nvim` stdin (it hangs). Write test snippets to a
> FILE and run with `+"luafile <path>"`. Wrap EVERY nvim invocation in `timeout`.

### Level 1: Load + lint (no selene/luacheck/stylua config in-repo → the load IS the gate)

```bash
cd plugin
# The module must require() without error + expose M.check (the loader contract) + M.min_nvim.
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua local h=require("pi-editor.health"); assert(type(h)=="table"); assert(type(h.check)=="function"); assert(h.min_nvim=="0.11"); print("load ok")' \
  -c 'qa'
echo "exit=$?"   # Expected: exit=0, prints "load ok"
```

### Level 2: Unit tests (plenary/busted — the real gate)

```bash
cd plugin
# The new health spec (Task 2):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/health_spec.lua")'
echo "exit=$?"   # Expected: exit=0, all cases pass (0 failures)

# Non-regression spot-checks (health is additive; these must still pass untouched):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/init_spec.lua")'
echo "exit=$?"
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/notify_spec.lua")'   # the pattern we mirrored
echo "exit=$?"
# Expected: all pass. If failing, READ the output and fix root cause (do not skip).
```

### Level 3: Smoke (plenary-free, file-based — the E2E gate per AGENTS.md)

```bash
cd plugin
timeout 60 nvim --headless --clean -u NORC +"luafile tests/health_smoke.lua" +qa
echo "exit=$?"   # Expected: exit=0, prints "SMOKE_PASS"
```

### Level 4: Live `:checkhealth` (the real end-user path — manual / scripted)

```bash
cd plugin
# Drive the ACTUAL loader path (require("pi-editor.health").check()) headless, capturing the report.
# Write the driver to a FILE (AGENTS.md — NEVER heredoc→nvim stdin).
cat > /tmp/checkhealth_live.lua <<'LUA'
vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1,"S").source:sub(2), ":p:h:h"))
-- stub vim.health to print each line (so we can eyeball the report headless; no buffer UI)
local real = vim.health
local lines = {}
for _, m in ipairs({"start","ok","warn","error","info"}) do
  vim.health[m] = function(msg, advice)
    lines[#lines+1] = string.format("[%s] %s", m:upper(), tostring(msg):gsub("\n"," "))
  end
end
require("pi-editor.health").check()
for _, l in ipairs(lines) do io.stdout:write(l .. "\n") end
LUA
# Dormant case (no env var):
env -u PI_EDITOR_BRIDGE timeout 30 nvim --headless --clean -u NORC +"luafile /tmp/checkhealth_live.lua" +qa \
  | tee /tmp/dormant_report.txt
echo "--- expect a [INFO] ... dormant line + no [ERROR] above ---"
# Active case (fake a descriptor via the env var — JSON of a BridgeDescriptor):
export PI_EDITOR_BRIDGE='{"transport":"unix","path":"/tmp/pi-editor-bridge-fake.sock","token":"deadbeef","pid":99999,"cwd":"/home/u/proj","fdAvailable":true,"serverVersion":"0.1.0"}'
timeout 30 nvim --headless --clean -u NORC +"luafile /tmp/checkhealth_live.lua" +qa | tee /tmp/active_report.txt
echo "--- expect [OK] env set, [INFO] socket/pid/cwd/version lines, [WARN] not-connected/missing-socket ---"
unset PI_EDITOR_BRIDGE; rm -f /tmp/checkhealth_live.lua /tmp/dormant_report.txt /tmp/active_report.txt
# Expected (both): exit 0; no "Failed to run healthcheck"; dormant has zero [ERROR]; active shows the descriptor fields.
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load passes (`require("pi-editor.health")` → table; `.check` is a function; `.min_nvim=="0.11"`).
- [ ] Level 2 `health_spec.lua` passes (all cases: dormant/active/malformed/fd/never-throws/version).
- [ ] Level 2 `init_spec.lua` + `notify_spec.lua` still pass (additive; non-regression).
- [ ] Level 3 `health_smoke.lua` passes (no throw + ≥1 `start`).
- [ ] Level 4 live `:checkhealth` path: dormant report has zero `[ERROR]`; active report shows the descriptor fields.
- [ ] No edits outside the 3 new files; NO TS change; NO `init.lua`/shim/`bridge.lua` change.

### Feature Validation
- [ ] `:checkhealth pi-editor` runs `require("pi-editor.health").check()` (file + `M.check` name correct).
- [ ] 4 `start()` sections render; no "report is empty" / "Failed to run healthcheck".
- [ ] Neovim gate: `error` (<0.11, with upgrade advice) / `ok` (≥0.11, shows version).
- [ ] Dormant session: `info "dormant"`; **zero** `error`.
- [ ] Active session (valid unix descriptor + connected + server_info): `ok` connected + `info` fields; **zero** `error`.
- [ ] Malformed env var (bad JSON / wrong transport): `error`/`warn` naming it.
- [ ] Socket section (active): `is_connected()`→`ok`/`warn`; `server_info`→`info`; `fs_stat`→`ok`/`warn`. Dormant→`info "n/a"`.
- [ ] `fd` (always): present→`ok` (path); absent→`warn` (NOT error) + `string[]` advice; server/client cross-ref noted.

### Code Quality Validation
- [ ] `M.check` is a TABLE FIELD (not a `local`) — the loader requires it.
- [ ] Every probe is pcall-wrapped (loader pcall-wraps the whole `check()`).
- [ ] `vim.health` + module state read INSIDE `check()` (call-time) → stub-friendly.
- [ ] Uses `vim.health.start/ok/warn/error/info` directly (no `report_*`; floor is 0.11).
- [ ] Version gate uses `vim.fn.has("nvim-0.11")` (not `vim.version.ge`); advice passed as `string[]`.
- [ ] Luadoc on `M.check` + `M.min_nvim`; [Mode A] header explains every gotcha.
- [ ] Anti-patterns avoided (see below).

### Documentation
- [ ] [Mode A] header + luadoc explain the loader contract, the 0.11 floor, dormant≠error, the
      client/server fd nuance, and why no live `ping`.
- [ ] (Cross-task, NOT this PRP's deliverable) `doc/pi-editor.txt` (S43) should later mention
      `:checkhealth pi-editor`.

---

## Anti-Patterns to Avoid

- ❌ Don't name the function `local function check()` — the loader calls `require("pi-editor.health").check()`; it MUST be `M.check` (a table field) or `:checkhealth` errors "report is empty".
- ❌ Don't cache `local health = vim.health` at MODULE top-level — the unit test swaps `vim.health` in `before_each` (notify_spec.lua idiom); a module-level cache freezes the real one and breaks the stub. Capture it INSIDE `check()`.
- ❌ Don't use `vim.health.report_*` — REMOVED by 0.12. Use `start/ok/warn/error/info` (this repo's floor is 0.11).
- ❌ Don't use `vim.version.ge/le` for the version gate — 0.12-ONLY. Use `vim.fn.has("nvim-0.11")` (every version).
- ❌ Don't gate on 0.10 — the floor is **0.11** (coords.lua GOTCHA 9: the UTF-16 overload). Below 0.11 must `error` (coords crashes on older nvim), not warn.
- ❌ Don't raise an `error` for a MISSING `PI_EDITOR_BRIDGE` — dormant is the expected normal-session state (PRD §7.1/§11). Emit an `info "dormant"`.
- ❌ Don't raise an `error` for a missing `fd` — it is OPTIONAL (`warn` with install advice; @file silently no-ops, path completion still works — PRD §11).
- ❌ Don't pass multiple advice strings as separate args (`warn(msg,"a","b")` DROPS `"b"`) — pass a TABLE: `warn(msg,{"a","b"})`.
- ❌ Don't let one probe throw and hide the others — the loader pcall-wraps the WHOLE `check()` (one throw blanks the rest). pcall EACH probe.
- ❌ Don't issue a live `ping` RPC — it is async/callback-based; driving it from a sync `check()` risks a hang. Use the existing `is_connected()`/`server_info` (live state already maintained by the real connect/handshake/close paths).
- ❌ Don't wire anything in `init.lua` / the VimEnter shim / `package.json` — `:checkhealth` discovers `health.lua` automatically. No startup cost (lazy load).
- ❌ Don't treat a server=true/client=false `fdAvailable` mismatch as an error — the server resolves `fd` in pi's bin dir FIRST (not on the editor's `$PATH`); it is plausible + benign.
- ❌ Don't pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — it hangs). Write test/driver snippets to a file; run with `+"luafile <path>"`. Wrap every nvim call in `timeout`.

---

## Confidence Score: 9/10

A clean CREATE-only task (1 new lazy module + 2 test files) that is a pure read-only consumer of
state the plugin already computes — zero risk to existing features, zero TS change, zero wiring.
The external knowledge (the `:checkhealth` loader contract + the `vim.health` API + the version-gate
idiom) is VERIFIED LIVE against the installed NVIM 0.12.4 runtime + 5 real plugin health.lua files,
and a drop-in copy-ready skeleton is provided. The one judgment call worth flagging: the version
**floor is 0.11 (not PRD's 0.10)** — sourced from coords.lua GOTCHA 9, so the gate `error`s below
0.11 (defensible: coords would crash on older nvim). Residual 1/10 = the plenary stub test's
`vim.fn.has`/`vim.fn.executable` stubbing can be fiddly to restore cleanly between cases (mitigated
by the `before_each`/`after_each` save-restore discipline modeled on `notify_spec.lua`, and by the
smoke as an independent backstop).