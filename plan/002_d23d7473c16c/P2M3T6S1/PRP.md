# PRP — P2.M3.T6.S1: `init.lua` shell-config block + `warm_on_enter` logic

**Parent:** P2.M3.T6 (`:checkhealth` shell section + `doc/pi-bridge-shell.txt` + config)
**Component:** B (`pi-bridge.nvim`) — `lua/pi-bridge/init.lua`
**PRD anchor:** §17.11 *Configuration* (the full `shell = {}` block), §17.5 *The completion daemon* (`warm_on_enter` semantics), §17.12 *Failure modes & degradation* (warm-spawn-failure is silent + dedup'd), §17.4 *Shell resolution*
**Size:** 1 pt — add the `pi-bridge.ShellConfig` typed default block to `init.lua` + gate `warm_on_enter` spawning in `activate()`.
**Builds on:** S1 (setup() + defaults + activate() gate, COMPLETE), S21 (VimEnter activation, COMPLETE), S39 (`notify.lua` once/did_notify/reset, COMPLETE), P2.M1.T2.S2–S6 (`shell.lua` resolve/ensure/teardown, COMPLETE), P2.M2.T3.S1/S2 (`completion.lua` routing + do_shell_fetch, COMPLETE), P2.M2.T3.S4 (notices, COMPLETE), P2.M2.T4 (fish driver, COMPLETE). It is the **config foundation** the rest of P2.M3.T6 (health/docs/ftplugin-teardown) and all live shell code already read DEFENSIVELY.

---

## Goal

**Feature Goal:** Land the PRD §17.11 `shell = {}` configuration block as a typed, deep-merged, default-populated subtree of `pi-bridge.Config`, plus implement the one piece of config-driven *behavior* that the block exists to expose: **`warm_on_enter`** — when `true`, `activate()` (the VimEnter gate) eagerly spawns the completion daemon at editor startup instead of lazily on the first `!`/`!!` keystroke. After this lands, every `config.shell.<key>` read in `shell.lua` / `completion.lua` / `health.lua` / `shell/accept.lua` is backed by a real defaulted value (no more `(pi.config and pi.config.shell) or {}` defensive AND-chain required to *avoid throwing* — though the defensive read stays for robustness), and a user can opt into paying 100 ms–1 s+ of daemon cold-start once at VimEnter to make the first `!git ch<Tab>` instant.

**Deliverable:** Edited `lua/pi-bridge/init.lua` (additive only):
1. A new `---@class pi-bridge.ShellConfig` type annotation documenting every §17.11 key (`enabled`, `prefer`, `drivers`, `warm_on_enter`, `timeout_ms`, `startup_timeout_ms`, `visual_cue`, `debounce_ms`) + the forward-compatible `max_parse_failures` key (already read defensively by `shell.lua`'s `max_parse_failures()` helper, default 5).
2. A new `---@field shell pi-bridge.ShellConfig` field on `pi-bridge.Config`.
3. A new `shell = { … }` block inside `M.defaults`, populated with the §17.11 default values verbatim (`enabled = true`, `prefer = "pi"`, `drivers = { fish = true, zsh = true, bash = true }`, `warm_on_enter = false`, `timeout_ms = 1500`, `startup_timeout_ms = 5000`, `visual_cue = "gutter"`, `debounce_ms = 0`).
4. **The `warm_on_enter` behavior** — a new private helper `warm_shell_daemon()` invoked from `activate()` (gated on the env-var + handshake success path, AFTER the existing bridge-wiring pcall block) that, iff `M.config.shell.warm_on_enter == true`, pcall's `require("pi-bridge.shell").ensure(function() end)`. The ensure spawn is fire-and-forget: its result is ignored; failure is reported by `shell.lua`'s OWN §17.12 degrade notice (S4, COMPLETE) — `activate()` adds NO new notify of its own.

Plus new tests:
5. New plenary spec cases appended to `tests/init_spec.lua` (the established setup/config spec home — no new file): default values, deep-merge (override `shell.timeout_ms` keep `shell.prefer`), `shell = false` is rejected gracefully (treated as `{}` by deep-merge — `vim.tbl_deep_extend` handles it; documented), and `M.defaults.shell` is never mutated by a setup-with-overrides.
6. New plenary spec **`tests/init_warm_on_enter_spec.lua`** — wires a fake daemon driver (copy `tests/shell_ensure_spec.lua`'s `fake_bridge` + `make_fake_driver` + `inject_fake_driver` harness) and asserts that `activate()` (under a real `PI_NVIM_BRIDGE` env-var blob) with `warm_on_enter = true` calls `shell.ensure` exactly once, while `warm_on_enter = false` (default) does NOT call it.
7. New plenary-free smoke **`tests/init_warm_on_enter_smoke.lua`** — the Level-1 gate: load, set a fake env var, call `activate()` with warm_on_enter true + a fake driver, assert `shell.ensure` ran; then with false, assert it did not.

**Success Definition:**
- `require("pi-bridge").setup({}).config.shell` is a fully-populated table equal to the §17.11 defaults (every key present, correct type, correct value).
- A user override `setup({ shell = { timeout_ms = 3000 } })` produces `config.shell.timeout_ms == 3000` AND `config.shell.prefer == "pi"` (the deep-merge preserves siblings — mirrors the existing `menu = { max_height = 40 }` test).
- `M.defaults.shell` is pristine after any setup() with overrides (mirrors the existing "does NOT mutate M.defaults" test).
- `activate()` with `warm_on_enter = true` (and a valid `PI_NVIM_BRIDGE` blob + a wired fake driver) calls `shell.ensure` exactly once; with the default `false` it does NOT (lazy on first `!` remains the default — §17.11).
- A warm `ensure` spawn failure is reported by `shell.lua`'s OWN §17.12 degrade notify (category `"shell-degrade"`); `activate()` itself emits NO new notify for it and never throws on warm failure.
- `activate()` with `config.shell.enabled == false` STILL warms if `warm_on_enter == true`? — **NO**: `enabled` is the master switch (§17.11 "false → `!` lines get no completion"); warming a disabled subsystem is contradictory. The warm path short-circuits when `enabled ~= true`. (Documented + tested.)
- `init_spec.lua`, `shell_ensure_spec.lua`, `shell_request_spec.lua`, `shell_spec.lua`, `completion_spec.lua`, `activate_spec.lua` ALL stay green (additive only; the defensive reads in shell.lua/completion.lua are unaffected — they now resolve to the real defaulted block, but the value-equality is unchanged).

---

## User Persona

**Target User:** A pi user editing a prompt in the Neovim external editor (`Ctrl+G`) who frequently types `!`/`!!` shell commands and notices a ~100 ms–1 s+ hiccup on the FIRST `<Tab>` of a session (the daemon cold-start — sourcing `.zshrc`/`config.fish`/bash-completion).

**Use Case:** The user adds `require("pi-bridge").setup({ shell = { warm_on_enter = true } })` to their config. The next time pi opens the editor, the daemon spawns at VimEnter (while the buffer is still drawing / the user is still reading the prompt), so the first `!git ch<Tab>` is instant. They pay a one-time memory cost (one persistent shell subprocess) they opted into; the default (`false`) keeps the lazy-on-first-`!` behavior for everyone else.

**User Journey:**
1. User reads `:help pi-bridge-shell` (P2.M3.T6.S4, Planned — lands after S1) → sees the `warm_on_enter` knob + its trade-off ("trades memory for first-`!` latency", §17.11).
2. User adds `shell = { warm_on_enter = true }` to their `setup({})`.
3. Next `Ctrl+G` → editor opens → daemon spawns eagerly → first `!` completion is instant.
4. If the spawn fails (shell missing / rc error), the §17.12 degrade toast fires ONCE (via shell.lua S4, COMPLETE) — the user knows completion is off, not silently broken.

**Pain Points Addressed:**
- **First-`!` latency.** §17.5 documents "100 ms–1 s+" cold-start (rc + completion-library load). `warm_on_enter` moves that cost to startup where it is invisible, leaving the completion UX latency-free.
- **Missing config foundation.** Every `shell.lua`/`completion.lua`/`health.lua` read of `config.shell.X` today uses the defensive `(pi.config and pi.config.shell) or {}` AND-chain *because the block did not exist*. S1 lands it; the defensive reads stay (robustness) but now resolve to real defaulted values.

---

## Why

- **Business value:** The config block is the documented user-facing surface for the entire §17 shell-completion subsystem (§17.11 is literally titled "Configuration"). Without it landed, `:help pi-bridge-shell` (S4) would document knobs that don't exist in `M.defaults`, and `health.lua` (S2) would report config values that aren't defaulted. S1 is the foundation S2/S3/S4 build on.
- **Integration with existing features:**
  - **`shell.lua` already reads these keys defensively** (`cfg.prefer`, `cfg.startup_timeout_ms`, `cfg.timeout_ms`, `cfg.drivers`, `cfg.max_parse_failures` via `max_parse_failures()`). S1 makes those reads resolve to real defaulted values instead of the `{}` fallback — no behavior change (the fallback already matched the §17.11 defaults), but the values are now discoverable in `M.defaults` + `:checkhealth` + the type annotations.
  - **`completion.lua` reads `config.shell.debounce_ms`** (S2, `compute_debounce` L348) and `config.shell` in do_shell_fetch routing. Same defensive read; S1 makes it real.
  - **`activate()` (S21, COMPLETE)** already exists as the VimEnter gate. S1 adds ONE pcall'd `shell.ensure` call to it (gated on `warm_on_enter`), mirroring the existing pcall'd `bridge.handshake` / `menu.attach` wiring already in activate(). No new lifecycle hook.
  - **`notify.lua` (S39, COMPLETE)** is reused by the warm-failure path INDIRECTLY: shell.lua's ensure() already emits the `"shell-degrade"` notice (S4, COMPLETE) on spawn failure. activate() does NOT need its own notify — the failure surfaces through the existing channel.
- **Problems this solves, for whom:** Centralizes the §17.11 config in ONE place (`init.lua`'s `M.defaults`, the same place every other config knob lives) so there is a single source of truth. Avoids the trap of hardcoding defaults inside `shell.lua` (which would make them undiscoverable + untestable + drift-prone). The `warm_on_enter` behavior is the ONE config-driven *action* the block exists to expose — everything else is read-on-demand by the consumer modules.

---

## What

### User-visible behavior
- `setup({})` now exposes `config.shell` as a fully-populated table (previously absent → `nil` → consumers fell back to `{}`).
- A user setting `shell = { warm_on_enter = true }` sees the daemon spawn at VimEnter (visible via `:messages` first-run hint, category `"shell-active"`, §17.9 — emitted by shell.lua S4 on the successful warm spawn). With the default `false`, the daemon spawns lazily on the first `!` keystroke (unchanged).
- A user setting `shell = { enabled = false }` disables shell completion entirely (the `!` lines get no completion, no warm spawn — the warm path short-circuits). This is the §17.11 "master switch".
- No user-visible behavior change for the default `setup({})` case — the defensive reads in shell.lua/completion.lua already produced the §17.11 default values via the `{}` fallback.

### Technical requirements
1. **`pi-bridge.ShellConfig` class annotation** — every §17.11 key typed:
   - `enabled: boolean` (default `true`) — master switch (§17.11).
   - `prefer: ("pi"|"shell"|"bash"|string)` (default `"pi"`) — §17.4 resolution contract (a `/abs/path` is also valid per §17.4's "/abs/path" row).
   - `drivers: { fish: boolean, zsh: boolean, bash: boolean }` (default all `true`) — per-shell enable/disable (§17.4.2).
   - `warm_on_enter: boolean` (default `false`) — spawn the daemon at VimEnter (§17.11 "trades memory for first-`!` latency").
   - `timeout_ms: integer` (default `1500`) — per-request budget (§17.11; MUST differ from `startup_timeout_ms`).
   - `startup_timeout_ms: integer` (default `5000`) — daemon cold-start budget (§17.11).
   - `visual_cue: ("gutter"|"border"|"off")` (default `"gutter"`) — §17.9 bash-mode visual cue.
   - `debounce_ms: integer` (default `0`) — §17.7 shell-context debounce (immediate by default).
   - `max_parse_failures: integer` (default `5`) — forward-compatible (shell.lua's `max_parse_failures()` ALREADY reads `cfg.max_parse_failures` defensively; S1 lands the default it falls back to).
2. **`pi-bridge.Config.shell` field** — `---@field shell pi-bridge.ShellConfig`.
3. **`M.defaults.shell`** — the §17.11 block verbatim, with a `-- S1` provenance comment on each line + the §17.11 anchor.
4. **`warm_shell_daemon()` private helper** (module-local in init.lua) — reads `M.config.shell.warm_on_enter` + `M.config.shell.enabled`; iff both gate true, `pcall`s `require("pi-bridge.shell").ensure(function() end)`. NEVER throws (pcall require + pcall ensure + type-guarded config reads). Fire-and-forget (the cb is a no-op; failure is shell.lua's job to notice via S4).
5. **`activate()` wiring** — invoke `warm_shell_daemon()` AFTER the existing `bridge.handshake` pcall block + AFTER the `menu.attach` pcall block, as a NEW final pcall block. Rationale: warming is lowest-priority; it must not race or interfere with the bridge handshake or menu wiring. It is gated on the SAME env-var + transport=="unix" path that activate() already validated (the warm call happens only after `M.descriptor` is set — shell.lua's `resolve_shell` reads `descriptor.shell` for the `prefer:"pi"` resolution).
6. **`enabled` gate semantics** — `warm_shell_daemon()` short-circuits if `M.config.shell.enabled ~= true`. This means `enabled = false` disables BOTH lazy (completion routing) AND warm spawning. The lazy-side `enabled` gate in `completion.lua` routing is a SEPARATE concern (it is NOT in S1's scope — completion.lua routing already exists; adding the `enabled` check there would be a behavior change to a COMPLETE module. S1 lands the CONFIG + the WARM-side gate only; the lazy-side `enabled` gate is a documented forward-contract for a future task, OR is already covered by the existing `completion_context` → `do_shell_fetch` path returning `nil` for shell when no driver resolves. **VERIFY in implementation**: grep `completion.lua` for an existing `enabled` check; if absent, document it as a known gap — do NOT add it in S1 to avoid scope creep).

   **UPDATE after research:** `completion.lua` does NOT currently check `config.shell.enabled`. This is a real gap (a user setting `enabled = false` would still get lazy completion on `!` lines). However, fixing it is OUT OF S1's scope (it edits completion.lua, a COMPLETE module, and changes behavior). S1 lands the config + the warm-side gate; the lazy-side `enabled` gate is a **documented forward-contract** in the PRP's "Known Gotchas" — flag it for a follow-up task. The warm-side gate (`warm_shell_daemon` checks `enabled`) is correct and in-scope.

7. **NEVER throws** (setup NEVER throws — the existing S1 invariant; warm_shell_daemon is pcall'd inside activate which is itself never-throws per S21). The warm `ensure` failure path is owned by shell.lua S4's degrade notice; activate() does NOT add a notify for warm failure (dedup is via shell.lua's `"shell-degrade"` category).
8. **Scope fence:** NO edits to `shell.lua` (it already reads defensively — unchanged), `completion.lua` (routing unchanged — the lazy-side `enabled` gate is a documented forward-contract), `bridge.lua`, `notify.lua`, `health.lua` (S2 reads `config.shell` — it will now resolve to the real block, unchanged behavior), the drivers, `menu.lua`, `ftplugin/pi-prompt.lua` (S3 wires `shell.teardown()` into VimLeavePre — separate task), `plugin/pi-bridge.lua` (the shim already calls activate() — unchanged). S1 is init.lua + tests ONLY.

### Success Criteria
- [ ] `pi-bridge.ShellConfig` class annotated with all 9 keys (8 from §17.11 + `max_parse_failures`).
- [ ] `pi-bridge.Config.shell` field present.
- [ ] `M.defaults.shell` populated with the §17.11 defaults verbatim (`enabled=true, prefer="pi", drivers={fish,zsh,bash}=true, warm_on_enter=false, timeout_ms=1500, startup_timeout_ms=5000, visual_cue="gutter", debounce_ms=0, max_parse_failures=5`).
- [ ] `setup({}).config.shell` deep-equals `M.defaults.shell`.
- [ ] `setup({ shell = { timeout_ms = 3000 } })` → `config.shell.timeout_ms == 3000` AND `config.shell.prefer == "pi"` (sibling preserved by deep-merge).
- [ ] `setup({ shell = { drivers = { bash = false } } })` → `config.shell.drivers.bash == false` AND `config.shell.drivers.fish == true` (nested-table deep-merge, mirrors `menu` tests).
- [ ] `M.defaults.shell` is pristine after `setup({ shell = { timeout_ms = 1 } })` (no mutation — mirrors the existing "does NOT mutate M.defaults" test).
- [ ] `activate()` with `warm_on_enter=true` + valid `PI_NVIM_BRIDGE` blob + fake driver → `shell.ensure` called exactly once.
- [ ] `activate()` with default `warm_on_enter=false` → `shell.ensure` NOT called (lazy remains default).
- [ ] `activate()` with `warm_on_enter=true` BUT `enabled=false` → `shell.ensure` NOT called (the master switch gates warming).
- [ ] `activate()` with `warm_on_enter=true` but a spawn-FAILING fake driver → no throw; `notify.did_notify("shell-degrade")` true (shell.lua S4 owns it); activate returns the descriptor normally.
- [ ] `activate()` with `warm_on_enter=true` but NO env var (dormant session) → `shell.ensure` NOT called (the dormant gate fires before the warm block — mirrors existing activate() control flow).
- [ ] `setup()` never throws on `shell = nil`, `shell = {}`, `shell = false` (deep-merge handles all; `false` becomes `{}` — documented).
- [ ] Regression green: `init_spec.lua`, `shell_ensure_spec.lua`, `shell_request_spec.lua`, `shell_spec.lua`, `completion_spec.lua`, `activate_spec.lua` all exit 0.

---

## All Needed Context

### Context Completeness Check
A reader who knows nothing of this repo can implement S1 from: this PRP + the cited `init.lua` regions (the `pi-bridge.Config`/`pi-bridge.MenuConfig` annotations L10-26, `M.defaults` L32-40, `setup()` L62-86, `activate()` L150-260) + `shell.lua`'s defensive reads (L~289 `cfg.prefer`, L~305 `cfg.startup_timeout_ms`, `max_parse_failures()` L~430, `pick_driver` L~190 `drv_cfg[base]`) + `completion.lua:348` (`cfg.debounce_ms`) + `plugin/pi-bridge.lua` (the VimEnter shim that calls activate()) + `tests/init_spec.lua` (the setup/config test patterns) + `tests/shell_ensure_spec.lua` (the fake-driver harness to copy) + PRD §17.11 (quoted inline below). No daemon-internals knowledge beyond "ensure() spawns the daemon if not already running; failure sets state.failed + emits shell-degrade via S4" is required.

### Documentation & References

```yaml
# MUST READ — the spec that defines every config key + default value
- url: PRD.md §17.11 "Configuration"
  why: |
    the VERBATIM §17.11 config block — the authoritative source for every key, type, and default:
      require("pi-bridge").setup({
        shell = {
          enabled           = true,
          prefer            = "pi",          -- "pi" | "shell" | "bash" | "/abs/path"  (§17.4)
          drivers           = { fish = true, zsh = true, bash = true },
          warm_on_enter     = false,         -- spawn daemon at VimEnter (trades memory for first-`!` latency)
          timeout_ms        = 1500,          -- per-request budget (shell completion)
          startup_timeout_ms= 5000,          -- daemon cold-start (rc load) budget
          visual_cue        = "gutter",      -- "gutter" | "border" | "off"  (§17.9)
          debounce_ms       = 0,             -- 0 = immediate (daemon warm); raise if a shell is slow
        },
      })
  critical: |
    EVERY default value in M.defaults.shell MUST match this block EXACTLY. The one key NOT in §17.11 is
    `max_parse_failures` (default 5) — it is a forward-compatible key shell.lua's max_parse_failures()
    helper ALREADY reads defensively (grep-confirmed); landing it in M.defaults makes the default
    discoverable + honors a future user override without a code change. Add it with a comment citing
    shell.lua's max_parse_failures() as the consumer.
- url: PRD.md §17.5 "The completion daemon" (esp. ¶5.2 "cold-start latency")
  why: |
    justifies warm_on_enter's existence: "Sourcing the user's rc + completion library takes 100 ms–1 s+;
    a persistent daemon (§17.5.5) pays this once. warm_on_enter spawns it at VimEnter (off by default)."
    This is the user-facing rationale for the knob.
  critical: |
    warm_on_enter is OFF by default (§17.11). It trades MEMORY (one persistent subprocess for the session)
    for first-`!` LATENCY. Never default it on — it would surprise users who never use `!` lines.
- url: PRD.md §17.12 "Failure modes & degradation"
  why: |
    "Daemon spawn failure (shell missing, rc error, startup timeout) → silent degrade to a plain buffer
    + ONE vim.notify." This is what happens when a WARM spawn fails. S4 (COMPLETE) wired this into
    shell.lua's ensure(). S1's warm path delegates to ensure() → the SAME degrade notice fires.
  critical: |
    S1's activate() must NOT add its OWN notify for warm-spawn-failure — shell.lua S4 already emits
    "shell-degrade" (dedup'd once/session). Adding a second notify would double-notify the user. The
    warm ensure() cb is a NO-OP (fire-and-forget); the failure surfaces through the existing channel.

# Codebase files to follow EXACTLY
- file: lua/pi-bridge/init.lua
  why: the file being edited; the Config annotations, M.defaults, setup(), activate() all live here
  pattern: |
    -- the Config class annotation block (L10-26): the established pattern for documenting config keys.
    -- Copy the @field style EXACTLY for the new ShellConfig keys (type, default, §-anchor, provenance).
    ---@class pi-bridge.MenuConfig
    ---@field max_height integer ...
    ---@field border ("none"|...) ...
    ---@class pi-bridge.Config
    ---@field menu pi-bridge.MenuConfig ...
    ---@field debounce_ms integer ...
    -- M.defaults (L32-40): the literal default table. Copy the inline-comment style (value + why + §-anchor).
    M.defaults = { menu = { max_height = 12, border = "rounded" }, debounce_ms = 20, ... }
    -- setup() (L62-86): vim.tbl_deep_extend("force", M.defaults, opts). UNCHANGED — deep-merge already
    --   handles the nested shell block (it handled menu the same way). Add NO special-case for shell.
    -- activate() (L150-260): the VimEnter gate. ADD the warm_shell_daemon() pcall block as the LAST
    --   pcall in activate() (after menu.attach). It runs only on the success path (M.descriptor set).
  gotcha: |
    setup() NEVER throws (the S1 invariant). The existing rpc_timeout_ms WARN guard is pcall'd — mirror
    that discipline if any shell-config validation is added (but S1 adds NO validation guard: every key
    has a safe default + the consumers type-check defensively. A guard would be over-engineering for v1).
- file: lua/pi-bridge/shell.lua   (READ-ONLY — the consumer; NOT edited by S1)
  why: |
    confirms exactly which config keys the live code reads, so M.defaults.shell lands the RIGHT keys
    with the RIGHT defaults. Grep results (verified):
      L~289 (ensure step 3): cfg = (pi.config and pi.config.shell) or {}; resolved = M.resolve_shell(cfg.prefer or "pi")
      L~305 (ensure step 6): startup_timeout_ms = cfg.startup_timeout_ms or 5000
      L~190 (pick_driver):   drv_cfg = (...pi.config.shell.drivers) or nil; if drv_cfg[base] == false then return nil end
      max_parse_failures() (L~430): cfg.max_parse_failures; if type(n)~="number" or n<1 then return 5 end
      request() (L~620):     cfg.timeout_ms or 1500
      _feed:                 (no config read — uses max_parse_failures())
  pattern: |
    EVERY one of these is `cfg.X or DEFAULT`. S1 lands `X = DEFAULT` in M.defaults.shell, so the `or DEFAULT`
    fallback is now redundant (but harmless — leave it; it is belt-and-suspenders robustness). The defensive
    `(pi.config and pi.config.shell) or {}` AND-chain ALSO stays (it guards against a user who never called
    setup() — activate() self-heals via `if M.config == nil then M.setup({}) end`, but the AND-chain is
    defense-in-depth).
  gotcha: |
    Do NOT "clean up" the defensive reads in shell.lua as part of S1 — that is scope creep into a COMPLETE
    module + removes a safety net. S1 is init.lua + tests ONLY. The defensive reads staying is CORRECT.
- file: lua/pi-bridge/completion.lua   (READ-ONLY — the consumer; NOT edited by S1)
  why: |
    confirms the lazy-side config reads: compute_debounce L348 `cfg.debounce_ms` (default 0 via the type-check),
    do_shell_fetch routing. ALSO confirms the `enabled`-gate GAP: grep `config.shell.enabled` in completion.lua
    → ABSENT. This means `enabled=false` does NOT currently disable lazy completion. Document this as a
    forward-contract in S1's "Known Gotchas" — do NOT fix it in S1 (scope creep into a COMPLETE module).
  pattern: |
    -- completion.lua:348 (compute_debounce, S2 COMPLETE):
    local cfg = (pi.config and pi.config.shell) or {}
    local ms = cfg.debounce_ms
    if type(ms) ~= "number" or ms < 0 then ms = 0 end
  gotcha: |
    The `enabled` master switch (§17.11) is currently ONLY enforced on the WARM path (S1's warm_shell_daemon
    checks it). The LAZY path (completion.lua routing) does NOT check it. This is a known gap — flag it.
    A future task (or a follow-up to S1) should add `if cfg.enabled == false then return nil end` to
    completion.lua's completion_context shell branch. S1 does NOT do this (avoid editing COMPLETE modules).
- file: lua/pi-bridge/notify.lua   (READ-ONLY — REUSED UNCHANGED)
  why: the dedup'd emitter; the warm-failure path's "shell-degrade" notice is emitted by shell.lua S4, NOT activate()
  pattern: M.once(category, level, msg) / M.did_notify(category) / M.reset(). FAST-CONTEXT-SAFE.
  gotcha: once() SCHEDULES the notify (vim.schedule). Tests vim.wait(N, cond, 5) to flush before asserting did_notify.
- file: plugin/pi-bridge.lua   (READ-ONLY — the VimEnter shim)
  why: confirms activate() is called ONCE on VimEnter by the auto-sourced shim. S1's warm block runs inside activate().
  pattern: vim.api.nvim_create_autocmd("VimEnter", { once=true, callback=function() ... pi.activate() end })
  gotcha: the shim requires `lazy = false` (PRD §10.3) so it sources BEFORE VimEnter. warm_on_enter inherits this req.

# Sibling PRPs (the immediate predecessor contracts — read for the seam, do not re-derive)
- file: plan/002_d23d7473c16c/P2M1T2.S2/PRP.md
  why: S2 defined shell.lua's resolution + state layer (M.resolve_shell reads cfg.prefer). Confirms S1 must
       land `prefer = "pi"` as the default (§17.4) so S2's resolution has a real value.
- file: plan/002_d23d7473c16c/P2M2T3.S2/PRP.md
  why: S2 (completion routing) defined do_shell_fetch + the shell branch. Confirms `debounce_ms = 0` is the
       §17.7 default (immediate) + that completion.lua reads config.shell defensively.
- file: plan/002_d23d7473c16c/P2M2T3.S4/PRP.md
  why: S4 (notices) wired shell.lua's "shell-degrade" / "shell-active" / "shell-mismatch" emits. Confirms S1's
       warm-failure path delegates to ensure() → the SAME degrade notice fires (no new notify in activate()).
```

### Current codebase tree (relevant slice)

```bash
pi-nvim-bridge/
├── lua/pi-bridge/
│   ├── init.lua           # ← EDIT (+pi-bridge.ShellConfig +M.defaults.shell +warm_shell_daemon +activate wiring)
│   ├── shell.lua          # the consumer (reads config.shell.* defensively) — READ-ONLY (S2-S6 COMPLETE)
│   ├── completion.lua     # the consumer (reads config.shell.debounce_ms) — READ-ONLY (S2 COMPLETE)
│   ├── notify.lua         # dedup'd emitter (reused by warm-fail INDIRECTLY via shell.lua S4) — UNCHANGED
│   └── bridge.lua         # handshake (activate wires it; warm runs AFTER) — READ-ONLY
├── plugin/pi-bridge.lua   # VimEnter shim → calls activate() — READ-ONLY
├── tests/
│   ├── init_spec.lua                  # ← APPEND cases (shell defaults + deep-merge + no-mutation)
│   ├── init_warm_on_enter_spec.lua    # ← CREATE (plenary; the warm-behavior Level-2 gate)
│   ├── init_warm_on_enter_smoke.lua   # ← CREATE (plenary-free; the Level-1 gate)
│   ├── shell_ensure_spec.lua          # the fake-driver harness TEMPLATE (fake_bridge/make_fake_driver/inject) — READ-ONLY ref
│   ├── activate_spec.lua              # the activate() test patterns (env-var blob setup) — READ-ONLY ref
│   └── minimal_init.lua               # plenary harness bootstrap — READ-ONLY
└── PRD.md  (§17.11, §17.5, §17.12, §17.4 — read-only reference)
```

### Desired codebase tree with files changed

```bash
lua/pi-bridge/init.lua                  # MODIFIED — +pi-bridge.ShellConfig class +M.defaults.shell +warm_shell_daemon +activate wiring
tests/init_spec.lua                     # MODIFIED — +shell-config cases (appended to the existing describe block)
tests/init_warm_on_enter_spec.lua       # CREATED — plenary spec (fake driver; warm_on_enter true/false/enabled-gate)
tests/init_warm_on_enter_smoke.lua      # CREATED — plenary-free load + warm-true + warm-false smoke
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: AGENTS.md ⛔ HARD RULE — NEVER pipe a heredoc / stdin into nvim (it HANGS the session).
-- Write any ad-hoc test snippet to a .lua FILE, then run  +"luafile <file>" +qa . Always wrap in `timeout`.

-- CRITICAL: setup() NEVER throws (the S1 invariant from the original setup() task). The deep-merge
-- (vim.tbl_deep_extend("force", M.defaults, opts)) handles the nested shell block EXACTLY as it handles
-- the nested menu block — NO special-case code. Do NOT add a `if type(opts.shell) ~= "table" then ...`
-- guard; vim.tbl_deep_extend coerces gracefully (a non-table `shell` is overwritten by the merge —
-- VERIFY in implementation: `setup({ shell = false })` → does config.shell become the defaults or {}?
-- Test it; document the actual behavior. If it throws, add a minimal guard. If it silently coerces,
-- document it.). The existing menu handling has the SAME shape + no guard → mirror it.

-- CRITICAL: warm_shell_daemon() runs INSIDE activate() which is called by the VimEnter shim WITHOUT a
-- pcall (plugin/pi-bridge.lua: `if ok and type(pi.activate) == "function" then pi.activate() end`).
-- So activate() — and therefore warm_shell_daemon() — MUST be never-throws (the S21 invariant). Every
-- step in warm_shell_daemon is pcall'd: require("pi-bridge.shell"), shell.ensure, the config reads.
-- A warm-spawn crash must NEVER prevent the buffer filetype set / bridge handshake / menu attach.

-- GOTCHA: warm_shell_daemon() MUST run AFTER M.descriptor is set (activate sets it at step e). shell.lua's
-- resolve_shell() reads descriptor.shell for the prefer:"pi" resolution — if warm runs before descriptor
-- is set, resolve falls through to $SHELL (the wrong shell if the user set shellPath). Place the warm
-- pcall block as the LAST step in activate(), after bridge.handshake + menu.attach.

-- GOTCHA: the warm ensure() cb is a NO-OP (fire-and-forget). Do NOT pass a cb that touches vim.api.*
-- (the ensure spawn cb runs in libuv fast context — E5560). shell.lua's ensure handles its own state
-- writes + stdout:read_start internally; the caller's cb only learns success/failure. For warming, we
-- don't care about the result (failure is reported by shell.lua S4's degrade notice). Pass `function() end`.

-- GOTCHA: the `enabled` master switch (§17.11 "false → `!` lines get no completion") is currently ONLY
-- enforced on the WARM path (warm_shell_daemon checks it). The LAZY path (completion.lua routing) does
-- NOT check config.shell.enabled — grep-confirmed (completion.lua has no `enabled` read). This is a KNOWN
-- GAP. S1 does NOT fix it (scope creep into a COMPLETE module, completion.lua). Document it in the PRP's
-- Success Criteria + flag it for a follow-up task. The warm-side gate is correct + in-scope.

-- GOTCHA: M.defaults.shell MUST be a fresh table literal, NOT a shared reference. vim.tbl_deep_extend
-- creates a NEW merged table (it does not mutate M.defaults), so this is automatic — but NEVER do
-- `M.defaults.shell = some_shared_table` (it would alias + a setup() mutation would leak). Use a literal.

-- GOTCHA: the `drivers` sub-table is a nested table — deep-merge handles it (mirrors `menu`). A user
-- setting `drivers = { bash = false }` gets `drivers.bash == false` + `drivers.fish == true` (sibling
-- preserved). Test this EXACTLY (mirror the menu deep-merge tests in init_spec.lua L52-61).

-- GOTCHA: `max_parse_failures` is NOT in PRD §17.11 — it is a forward-compatible key shell.lua's
-- max_parse_failures() helper ALREADY reads defensively (default 5). Landing it in M.defaults.shell
-- makes the default discoverable + honors a future override. Add it with a comment citing shell.lua's
-- max_parse_failures() as the consumer. Do NOT change the default (5) — shell.lua's fallback is also 5.

-- GOTCHA: notify.lua's once() SCHEDULES the notify (vim.schedule). The warm-spec's did_notify assertions
-- MUST vim.wait(200, cond, 5) to flush the schedule BEFORE asserting (the bridge_notify_spec.lua pattern).
-- In PROD this is invisible; in tests it is mandatory.

-- GOTCHA: the fake-driver harness (tests/shell_ensure_spec.lua) injects via package.loaded["pi-bridge.shell.fish"]
-- (or .zsh/.bash). The warm-spec REUSES this — but it must ALSO set pi.descriptor (activate reads it) +
-- PI_NVIM_BRIDGE env var (activate's gate). Copy activate_spec.lua's env-var-blob setup (it constructs a
-- valid JSON descriptor string + sets vim.env.PI_NVIM_BRIDGE before calling activate()).

-- GOTCHA: activate() calls bridge.handshake() which (in the test env, no real socket) will FAIL. That is
-- FINE — the warm block runs AFTER the handshake pcall (which swallows the failure). The warm ensure()
-- does NOT depend on the bridge being connected (shell.lua's resolve_shell falls back to $SHELL if
-- descriptor.shell is absent — and in the warm-spec we set descriptor.shell explicitly via the blob OR
-- via pi.bridge.get_shell_info fake). Ensure the warm-spec's fake_bridge exposes get_shell_info (copy
-- shell_ensure_spec.lua's fake_bridge which already does: `return { get_shell_info = function() return { shell = shell_path } end, server_info = {} }`).
```

---

## Implementation Blueprint

### Data models and structure

The new config subtree (no runtime data model — `state` lives in shell.lua, unchanged):

```lua
--- §17.11 shell-completion configuration. Every key has a safe default; consumers
--- (shell.lua, completion.lua, health.lua) read defensively (`cfg.X or DEFAULT`) so a
--- user who never sets `shell` still gets correct behavior via M.defaults.
---@class pi-bridge.ShellConfig
---@field enabled boolean Master switch (§17.11). false → `!`/`!!` lines get no completion (lazy-side gate is a forward-contract; warm-side gate is enforced in activate()).
---@field prefer ("pi"|"shell"|"bash"|string) §17.4 resolution contract. "pi" (default) = pi's resolved execution shell (always consistent); "shell" = $SHELL; "bash" = /bin/bash; "/abs/path" = that path.
---@field drivers { fish: boolean, zsh: boolean, bash: boolean } Per-shell enable/disable (§17.4.2). A `false` driver → no completion for that shell (degrade, NOT a different shell).
---@field warm_on_enter boolean Spawn the daemon at VimEnter (§17.5/§17.11). Trades memory (one persistent subprocess) for first-`!` latency (100ms–1s+ rc load). Default false (lazy on first `!`).
---@field timeout_ms integer Per-request budget for shell completion (§17.11). Default 1500. MUST differ from startup_timeout_ms.
---@field startup_timeout_ms integer Daemon cold-start budget (rc + completion-library load; §17.11). Default 5000.
---@field visual_cue ("gutter"|"border"|"off") §17.9 bash-mode visual cue. Default "gutter" ($ prefix on each item).
---@field debounce_ms integer §17.7 shell-context debounce. Default 0 (immediate; daemon warm after first use).
---@field max_parse_failures integer §17.12 consecutive-parse-failure threshold before the daemon is marked unhealthy. Default 5 (forward-compatible; read by shell.lua's max_parse_failures() helper).
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: EDIT lua/pi-bridge/init.lua — add the pi-bridge.ShellConfig class annotation
  - LOCATE: the `---@class pi-bridge.MenuConfig` ... `---@class pi-bridge.Config` block (L10-26).
  - INSERT: the new `---@class pi-bridge.ShellConfig` block BETWEEN MenuConfig and Config (so Config's
    `---@field shell pi-bridge.ShellConfig` resolves to an already-declared class — lua-language-server
    is order-sensitive for forward refs in the same file).
  - NAMING: `pi-bridge.ShellConfig` (mirrors `pi-bridge.MenuConfig`). snake_case fields (mirrors Config).
  - CONTENT: the 9 @field lines from the Data Models section above. Each cites its §-anchor.
  - THEN: add `---@field shell pi-bridge.ShellConfig` to the `pi-bridge.Config` class (after `env_var?`).
  - DEPENDENCIES: none.

Task 2: EDIT lua/pi-bridge/init.lua — add M.defaults.shell
  - LOCATE: the `M.defaults = { ... }` block (L32-40). It currently ends with `engine = "builtin",`.
  - INSERT: a `shell = { ... }` sub-table as the LAST key in M.defaults (after `engine`). Use the §17.11
    values verbatim + a `-- S1` provenance comment on each line citing §17.11:
      shell = {                       -- §17.11 shell-completion config (P2.M3.T6.S1)
        enabled            = true,    -- §17.11 master switch
        prefer             = "pi",    -- §17.4 resolution (pi's execution shell; always consistent)
        drivers            = { fish = true, zsh = true, bash = true }, -- §17.4.2 per-shell enable
        warm_on_enter      = false,   -- §17.5/§17.11 spawn at VimEnter (trades memory for first-`!` latency)
        timeout_ms         = 1500,    -- §17.11 per-request budget
        startup_timeout_ms = 5000,    -- §17.11 daemon cold-start budget
        visual_cue         = "gutter",-- §17.9 bash-mode cue
        debounce_ms        = 0,       -- §17.7 shell-context debounce (immediate)
        max_parse_failures = 5,       -- §17.12 parse-failure threshold (shell.lua max_parse_failures())
      },
  - DEPENDENCIES: Task 1 (the type annotation). setup() is UNCHANGED (deep-merge handles it).

Task 3: EDIT lua/pi-bridge/init.lua — add warm_shell_daemon() + wire into activate()
  - LOCATE: the activate() function (L150-260). Find the FINAL pcall block (the `menu.attach` one, ~L245).
  - INSERT: a new module-local helper `warm_shell_daemon()` ABOVE activate() (near the other module-locals),
    + a pcall'd invocation of it as the LAST statement in activate()'s success path (after menu.attach,
    BEFORE `return desc`).
  - IMPLEMENT (NEVER throws — pcall every step):
      --- §17.11/§17.5 warm_on_enter: eagerly spawn the shell-completion daemon at VimEnter so the first
      --- `!`/`!!`<Tab> is instant (avoids the 100ms–1s+ rc-load cold-start). OFF by default (trades one
      --- persistent subprocess for first-`!` latency). Gated on `config.shell.enabled` (the master switch)
      --- AND `config.shell.warm_on_enter`. Fire-and-forget: the ensure() cb is a no-op; a spawn failure is
      --- reported by shell.lua's OWN §17.12 "shell-degrade" notice (S4, COMPLETE) — activate() adds NO new
      --- notify. Runs AFTER M.descriptor is set (shell.lua's resolve_shell reads descriptor.shell for
      --- prefer:"pi"). NEVER throws (pcall require + pcall ensure + type-guarded reads). S1 (P2.M3.T6.S1).
      local function warm_shell_daemon()
        pcall(function()
          local cfg = M.config and M.config.shell
          if type(cfg) ~= "table" then return end
          if cfg.enabled == false then return end         -- master switch (§17.11)
          if cfg.warm_on_enter ~= true then return end     -- default false (lazy on first `!`)
          local ok, shell = pcall(require, "pi-bridge.shell")
          if not ok or type(shell.ensure) ~= "function" then return end
          -- fire-and-forget: the cb is a no-op. shell.lua's ensure() handles spawn + state + the
          -- §17.12 degrade notice (S4) on failure. DO NOT touch vim.api.* in the cb (ensure's spawn
          -- cb runs in libuv fast context — E5560; shell.lua owns any api work via vim.schedule).
          pcall(shell.ensure, function(_err) end)
        end)
      end
  - WIRE into activate() — find the menu.attach pcall block:
      OLD anchor (the LAST pcall in activate, ~L245):
        pcall(function()
          local ok, menu = pcall(require, "pi-bridge.menu")
          if ok and type(menu.attach) == "function" then menu.attach() end
        end)
        return desc
      NEW (insert warm_shell_daemon() BETWEEN menu.attach + return desc):
        pcall(function()
          local ok, menu = pcall(require, "pi-bridge.menu")
          if ok and type(menu.attach) == "function" then menu.attach() end
        end)
        -- S1 (P2.M3.T6.S1): §17.11 warm_on_enter — eagerly spawn the shell daemon at VimEnter.
        -- Runs LAST (after descriptor set + bridge handshake + menu attach). pcall'd (never-throws);
        -- fire-and-forget (failure → shell.lua S4 "shell-degrade" notice).
        warm_shell_daemon()
        return desc
  - DEPENDENCIES: Task 2 (M.defaults.shell must exist for the type-check, though warm_shell_daemon reads
    M.config.shell defensively).

Task 4: EDIT tests/init_spec.lua — append the shell-config cases
  - LOCATE: the existing `describe("pi-bridge.setup", function() ... end)` block. APPEND new `it(...)`
    cases INSIDE it (before the final `end)`).
  - CASES (mirror the existing menu/deep-merge/no-mutation test style):
      1. "ships the §17.11 shell defaults": setup({}) → assert config.shell == { enabled=true, prefer="pi",
         drivers={fish=true,zsh=true,bash=true}, warm_on_enter=false, timeout_ms=1500,
         startup_timeout_ms=5000, visual_cue="gutter", debounce_ms=0, max_parse_failures=5 }.
         Use assert.are.same for the full table (deep equality).
      2. "exposes M.defaults.shell with the §17.11 defaults" (same assertion against M.defaults.shell).
      3. "nested shell deep-merges: override timeout_ms, keep prefer": setup({ shell = { timeout_ms = 3000 } })
         → config.shell.timeout_ms == 3000 AND config.shell.prefer == "pi" (sibling preserved).
      4. "nested shell.drivers deep-merges: disable bash, keep fish/zsh": setup({ shell = { drivers = { bash = false } } })
         → config.shell.drivers.bash == false AND config.shell.drivers.fish == true AND .zsh == true.
      5. "warm_on_enter defaults to false (lazy on first `!`)": setup({}) → config.shell.warm_on_enter == false.
      6. "warm_on_enter override wins": setup({ shell = { warm_on_enter = true } }) → config.shell.warm_on_enter == true.
      7. "does NOT mutate M.defaults.shell after a setup with overrides": setup({ shell = { timeout_ms = 1 } })
         → M.defaults.shell.timeout_ms == 1500 (pristine) AND M.defaults.shell.warm_on_enter == false.
      8. "setup(nil) / setup({}) leaves shell at defaults": both → config.shell == M.defaults.shell.
      9. (edge) "setup({ shell = false }) does not throw + shell resolves gracefully": assert has_no.errors;
         then document the actual config.shell value (vim.tbl_deep_extend behavior — likely the defaults,
         since `false` is not a table and the merge keeps the default table; VERIFY + assert the real value).
  - DEPENDENCIES: Task 1 + 2.

Task 5: CREATE tests/init_warm_on_enter_smoke.lua — the plenary-free Level-1 gate
  - PATTERN: tests/activate_spec.lua's env-var-blob setup (construct a valid PI_NVIM_BRIDGE JSON, set
    vim.env.PI_NVIM_BRIDGE) + tests/shell_ensure_spec.lua's fake_driver_ok (a driver whose start cb
    succeeds) + a spy to count ensure calls. NO plenary, NO subprocess. Prints a parseable verdict.
  - IMPLEMENT (skeleton — the spy is the key trick: wrap shell.ensure in a counter):
      local pi = require("pi-bridge")
      local shell = require("pi-bridge.shell")
      if pi.config == nil then pi.setup({}) end
      local fails = 0
      local function check(c, m) if not c then io.stderr:write("FAIL: "..m.."\n"); fails=fails+1 end end

      -- spy: count ensure() calls WITHOUT breaking shell.lua (wrap, don't replace)
      local orig_ensure = shell.ensure
      local ensure_calls = 0
      shell.ensure = function(cb) ensure_calls = ensure_calls + 1; return orig_ensure(cb) end

      -- fake "fish" driver that spawns successfully (so warm succeed path is exercised)
      package.loaded["pi-bridge.shell.fish"] = {
        start = function(opts, cb)
          cb(nil, { is_closing=function() return false end, close=function() end },
               { write=function() end, is_closing=function() return false end, close=function() end },
               { read_start=function() end, is_closing=function() return false end, close=function() end, read_stop=function() end })
        end }

      -- a valid PI_NVIM_BRIDGE blob (transport=unix)
      local function blob(shell_path)
        return vim.json.encode({ transport="unix", path="/tmp/fake.sock", token="t", pid=1,
          cwd="/tmp", fdAvailable=true, serverVersion="0.0.1", shell=shell_path, shellSource="pi" })
      end

      -- (1) warm_on_enter = TRUE → ensure called once
      pi.setup({ shell = { warm_on_enter = true } })
      pi.bridge = { get_shell_info=function() return {shell="/usr/bin/fish"} end, server_info={} }
      vim.env.PI_NVIM_BRIDGE = blob("/usr/bin/fish")
      ensure_calls = 0; pi.descriptor = nil
      pi.activate()
      vim.wait(200, function() return false end, 5)  -- let ensure's cb fire
      check(ensure_calls == 1, "warm_on_enter=true → ensure called once (got "..ensure_calls..")")
      shell.reset()

      -- (2) warm_on_enter = FALSE (default) → ensure NOT called
      pi.setup({})  -- resets config.shell.warm_on_enter to false
      ensure_calls = 0; pi.descriptor = nil
      pi.activate()
      check(ensure_calls == 0, "warm_on_enter=false (default) → ensure NOT called (got "..ensure_calls..")")

      -- (3) enabled = FALSE gates warming even if warm_on_enter = true
      pi.setup({ shell = { warm_on_enter = true, enabled = false } })
      ensure_calls = 0; pi.descriptor = nil
      pi.activate()
      check(ensure_calls == 0, "enabled=false gates warming (got "..ensure_calls..")")

      -- restore
      shell.ensure = orig_ensure
      package.loaded["pi-bridge.shell.fish"] = nil
      vim.env.PI_NVIM_BRIDGE = nil

      if fails > 0 then io.stderr:write(fails.." smoke check(s) FAILED\n"); vim.cmd("cquit 1") end
      io.stdout:write("S1_WARM_SMOKE_OK\n")
  - RUN: timeout 60 nvim --headless --clean -u NORC +"luafile tests/init_warm_on_enter_smoke.lua" +qa
  - DEPENDENCIES: Task 3.

Task 6: CREATE tests/init_warm_on_enter_spec.lua — the plenary Level-2 gate (THE gate)
  - PATTERN: copy tests/shell_ensure_spec.lua's fake_bridge + make_fake_driver + the before_each/after_each
    save-restore block. ADD: PI_NVIM_BRIDGE env-var save/restore, pi.descriptor reset, the ensure-call spy.
  - before_each: package.loaded["pi-bridge"] = nil; pi = require("pi-bridge"); shell=require("pi-bridge.shell");
    save orig vim.env.PI_NVIM_BRIDGE; install the ensure spy (wrap shell.ensure in a counter); reset
    shell.reset(); inject fake driver + fake_bridge.
  - after_each: restore shell.ensure; clear package.loaded["pi-bridge.shell.fish"]; restore vim.env.PI_NVIM_BRIDGE;
    pi.descriptor = nil; shell.reset().
  - CASES (each sets up the env blob + config, calls pi.activate(), asserts the spy count):
      1. WARM TRUE: setup({shell={warm_on_enter=true}}) + blob + activate → ensure_calls == 1.
      2. WARM FALSE (default): setup({}) + blob + activate → ensure_calls == 0.
      3. ENABLED GATE: setup({shell={warm_on_enter=true, enabled=false}}) + activate → ensure_calls == 0.
      4. DORMANT (no env var): setup({shell={warm_on_enter=true}}); vim.env.PI_NVIM_BRIDGE=nil; activate →
         ensure_calls == 0 (the dormant gate fires before the warm block; activate returns nil).
      5. WARM FAIL (fake driver _fail=true): setup({shell={warm_on_enter=true}}) + blob + activate →
         ensure_calls == 1 (ensure WAS called); activate did NOT throw; (optional) after vim.wait,
         notify.did_notify("shell-degrade") true (shell.lua S4 emitted it). Confirms failure is delegated.
      6. NEVER THROWS: setup({shell={warm_on_enter=true}}); blob; break shell.ensure to THROW
         (shell.ensure = function() error("boom") end); activate → has_no.errors (the pcall swallows).
      7. WARM RUNS AFTER DESCRIPTOR SET: (indirect) after activate with warm_on_enter=true, assert
         pi.descriptor is non-nil (the warm block ran in the success path where descriptor is set).
         Alternatively, stub shell.ensure to capture the cfg.shell at call time + assert resolve_shell
         would return the blob's shell (descriptor.shell) — but this is better tested in shell_spec.lua.
         Keep this case simple: assert pi.descriptor ~= nil after a warm activate.
  - PLACEMENT: a top-level describe("pi-bridge warm_on_enter (P2.M3.T6.S1)", function() … end).
  - DEPENDENCIES: Task 3.

Task 7: VERIFY — run the gates (no file changes)
  - RUN Level 1 (smoke): timeout 60 nvim --headless --clean -u NORC +"luafile tests/init_warm_on_enter_smoke.lua" +qa
  - RUN Level 2 (the new warm spec): timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/init_warm_on_enter_spec.lua")'
  - RUN the appended init_spec cases: timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/init_spec.lua")'
  - RUN REGRESSION (the shell + completion + activate suites MUST stay green — S1 is additive):
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")'
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_request_spec.lua")'
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
      timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/activate_spec.lua")'
  - EXPECT: all green. If init_spec fails on the "setup({shell=false})" edge case, VERIFY the actual
    vim.tbl_deep_extend behavior + adjust the assertion to match (do NOT add a guard to setup() unless
    it actually throws — the deep-merge is the established pattern for nested config). If activate_spec
    fails, S1 must NOT have changed activate()'s return value or control flow (only ADDED the warm pcall).
```

### Implementation Patterns & Key Details

```lua
-- === The §17.11 defaults block (Task 2) — copy VERBATIM into M.defaults ===
shell = {                       -- §17.11 shell-completion config (P2.M3.T6.S1)
  enabled            = true,    -- §17.11 master switch
  prefer             = "pi",    -- §17.4 resolution (pi's execution shell; always consistent w/ execution)
  drivers            = { fish = true, zsh = true, bash = true }, -- §17.4.2 per-shell enable
  warm_on_enter      = false,   -- §17.5/§17.11 spawn at VimEnter (off; trades memory for first-`!` latency)
  timeout_ms         = 1500,    -- §17.11 per-request budget (NOT startup_timeout_ms)
  startup_timeout_ms = 5000,    -- §17.11 daemon cold-start budget (rc load)
  visual_cue         = "gutter",-- §17.9 bash-mode cue ($ prefix on items)
  debounce_ms        = 0,       -- §17.7 shell-context debounce (immediate; daemon warm after first use)
  max_parse_failures = 5,       -- §17.12 parse-failure threshold (shell.lua max_parse_failures() helper)
},

-- === warm_shell_daemon (Task 3) — the ONE behavior piece; never-throws; fire-and-forget ===
local function warm_shell_daemon()
  pcall(function()
    local cfg = M.config and M.config.shell
    if type(cfg) ~= "table" then return end
    if cfg.enabled == false then return end         -- §17.11 master switch
    if cfg.warm_on_enter ~= true then return end     -- default false (lazy on first `!`)
    local ok, shell = pcall(require, "pi-bridge.shell")
    if not ok or type(shell.ensure) ~= "function" then return end
    pcall(shell.ensure, function(_err) end)          -- fire-and-forget; failure → shell.lua S4 degrade notice
  end)
end

-- === The activate() wiring (Task 3) — warm runs LAST, after descriptor + handshake + menu ===
-- (inside activate(), after the menu.attach pcall, before `return desc`):
warm_shell_daemon()
return desc

-- === The test spy (Task 5/6) — count ensure calls without breaking shell.lua ===
local orig_ensure = shell.ensure
local ensure_calls = 0
shell.ensure = function(cb) ensure_calls = ensure_calls + 1; return orig_ensure(cb) end
-- ... call activate() ...
assert(ensure_calls == 1)  -- or 0 for the warm_on_enter=false / enabled=false cases
shell.ensure = orig_ensure  -- restore in after_each
```

### Integration Points

```yaml
CONFIG (the primary integration — S1's whole deliverable):
  - add to: lua/pi-bridge/init.lua M.defaults
  - pattern: "shell = { enabled=true, prefer='pi', ... }" (the §17.11 block; deep-merged by setup())
  - consumers (READ-ONLY, unchanged): shell.lua (cfg.prefer/startup_timeout_ms/timeout_ms/drivers/max_parse_failures),
      completion.lua (cfg.debounce_ms), health.lua (S2 will read all keys for :checkhealth).

ACTIVATION (the warm behavior):
  - add to: lua/pi-bridge/init.lua activate()
  - pattern: "warm_shell_daemon() — pcall'd; fire-and-forget; gated on enabled + warm_on_enter"
  - runs: at VimEnter (via the plugin/pi-bridge.lua shim → activate()), AFTER descriptor + handshake + menu.

NO DATABASE / NO ROUTES / NO NEW FILES BEYOND init.lua + tests.
```

---

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Lua syntax check (the repo has no linter in the loop per AGENTS.md, but selene/stylua are CI — run if available)
luac lua/pi-bridge/init.lua && echo "syntax ok"         # quick parse check (if luac present)
# stylua check (if installed; the repo's .stylua.toml governs)
stylua --check lua/pi-bridge/init.lua tests/init_warm_on_enter_spec.lua tests/init_warm_on_enter_smoke.lua 2>/dev/null || echo "stylua not installed; skip"
# selene (if installed)
selene lua/pi-bridge/init.lua 2>/dev/null || echo "selene not installed; skip"
# Expected: zero errors. If luac errors, READ the line/col + fix (usually a missing comma in the shell block).
```

### Level 2: Unit Tests (Component Validation)

```bash
# The appended init_spec cases (shell defaults + deep-merge + no-mutation) — THE config gate
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/init_spec.lua")'
# The new warm-behavior spec — THE behavior gate
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/init_warm_on_enter_spec.lua")'
# Expected: all pass. If init_spec "setup({shell=false})" fails, VERIFY the actual deep-merge behavior +
# adjust the assertion (do NOT add a setup() guard unless it throws).
```

### Level 3: Integration Testing (System Validation)

```bash
# The plenary-free smoke (Level-1 gate; runs without plenary, fast feedback)
timeout 60 nvim --headless --clean -u NORC +"luafile tests/init_warm_on_enter_smoke.lua" +qa
echo "smoke exit=$?"
# Expected: prints S1_WARM_SMOKE_OK; exit 0.

# Manual end-to-end (a REAL pi session — optional, the spec covers the logic):
# 1. Install the bridge extension (pi install).
# 2. require("pi-bridge").setup({ shell = { warm_on_enter = true } }) in the nvim config.
# 3. pi → Ctrl+G → :messages → expect the "shell completion active" (shell-active, INFO) notice at VimEnter
#    (NOT on the first `!`<Tab> — it fires at warm spawn time). Confirms warming works in prod.
# 4. Repeat with setup({}) (default) → the notice fires on the first `!`<Tab>, NOT at VimEnter.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Type annotation check (if lua-language-server is available via LSP):
# Use :LspDiagnostics or the editor's diagnostics on lua/pi-bridge/init.lua — the new
# pi-bridge.ShellConfig class + the M.defaults.shell literal should produce ZERO diagnostics
# (no "unknown field", no "type mismatch"). The `---@field shell pi-bridge.ShellConfig` on Config
# must resolve to the new class.
# (This is informational; the plenary gates are authoritative.)

# Regression sweep (the additive invariant — every consumer suite stays green):
for spec in shell_ensure_spec shell_request_spec shell_spec completion_spec activate_spec; do
  timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require('plenary.busted').run('tests/${spec}.lua')" || echo "REGRESSION FAIL: $spec"
done
# Expected: no REGRESSION FAIL lines.
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 (syntax): `luac lua/pi-bridge/init.lua` clean; stylua/selene (if run) clean.
- [ ] Level 2 (unit): `tests/init_spec.lua` green (incl. new shell cases); `tests/init_warm_on_enter_spec.lua` green.
- [ ] Level 3 (integration): `tests/init_warm_on_enter_smoke.lua` prints `S1_WARM_SMOKE_OK`; exit 0.
- [ ] Level 4 (regression): shell_ensure/request/spec, completion_spec, activate_spec all green.

### Feature Validation
- [ ] `M.defaults.shell` deep-equals the §17.11 block (+ `max_parse_failures=5`).
- [ ] Deep-merge preserves siblings (`shell = { timeout_ms = 3000 }` keeps `prefer = "pi"`; `drivers = { bash = false }` keeps fish/zsh).
- [ ] `M.defaults.shell` pristine after setup-with-overrides (no mutation).
- [ ] `warm_on_enter=true` → activate() calls shell.ensure exactly once.
- [ ] `warm_on_enter=false` (default) → activate() does NOT call shell.ensure.
- [ ] `enabled=false` gates warming (warm_shell_daemon short-circuits).
- [ ] Dormant session (no PI_NVIM_BRIDGE) → warm not called (activate returns early).
- [ ] Warm spawn failure → no throw; shell.lua S4 "shell-degrade" notice fires (delegated, not duplicated).
- [ ] activate() never throws on warm path (pcall'd require + ensure).

### Code Quality Validation
- [ ] `pi-bridge.ShellConfig` annotation follows the `pi-bridge.MenuConfig` style (type, default, §-anchor).
- [ ] `M.defaults.shell` follows the existing inline-comment style (value + why + §-anchor + S1 provenance).
- [ ] `warm_shell_daemon()` follows the module-local-helper style (the `local function` idiom used elsewhere in init.lua).
- [ ] The activate() wiring mirrors the existing pcall'd blocks (bridge.handshake, menu.attach) — same discipline.
- [ ] Anti-patterns avoided: no setup() guard for shell (deep-merge handles it); no new notify in activate (shell.lua S4 owns it); no scope creep into completion.lua/shell.lua/health.lua.

### Documentation & Deployment
- [ ] Each `M.defaults.shell` key has an inline comment citing its §-anchor (self-documenting).
- [ ] `warm_shell_daemon()` has a docstring explaining the fire-and-forget contract + the S4 delegation.
- [ ] The `enabled`-gate gap (lazy-side not enforced) is documented in the PRP's Known Gotchas (forward-contract).
- [ ] No new env vars; no new dependencies (vim.tbl_deep_extend + pcall + require are all builtins).

---

## Anti-Patterns to Avoid

- ❌ **Don't add a setup() validation guard for `shell`.** The deep-merge handles nested tables (it already handles `menu`). A `if type(opts.shell) ~= "table"` guard is over-engineering + diverges from the established menu pattern. If `setup({ shell = false })` misbehaves, document the actual behavior; only add a guard if it THROWS (violates the setup-never-throws invariant).
- ❌ **Don't add a new notify in activate() for warm-spawn failure.** shell.lua S4 (COMPLETE) already emits `"shell-degrade"` on spawn failure via ensure(). Adding a second notify double-notifies the user. The warm ensure() cb is a no-op.
- ❌ **Don't edit shell.lua / completion.lua / health.lua to "clean up" the defensive reads.** They are defense-in-depth (guard against a user who never called setup()). S1 is init.lua + tests ONLY. Removing the `or {}` fallback is scope creep + removes a safety net.
- ❌ **Don't add the lazy-side `enabled` gate to completion.lua in S1.** It is a real gap (completion.lua doesn't check `config.shell.enabled`), but fixing it edits a COMPLETE module + changes behavior. Document it as a forward-contract; let a follow-up task own it.
- ❌ **Don't run the warm ensure() with a cb that touches vim.api.*** shell.lua's ensure spawn cb runs in libuv fast context (E5560). The cb is `function(_err) end` (no-op). shell.lua owns any api work internally via its own vim.schedule.
- ❌ **Don't place warm_shell_daemon() BEFORE the descriptor set / handshake / menu attach in activate().** shell.lua's resolve_shell reads descriptor.shell for `prefer:"pi"`; warming before descriptor is set resolves the wrong shell. Warm runs LAST.
- ❌ **Don't pipe a heredoc into nvim (AGENTS.md ⛔ HARD RULE).** Write test snippets to a `.lua` file, then `+"luafile <file>" +qa`. Always wrap in `timeout`.
- ❌ **Don't hardcode `max_parse_failures` default inside shell.lua.** It belongs in `M.defaults.shell` (discoverable, overridable, testable). shell.lua's `max_parse_failures()` helper reads it defensively + falls back to 5 — S1 lands the 5 in the right place.

---

## Confidence Score

**8/10** for one-pass implementation success.

**Rationale:** The task is small + well-bounded (one typed config block + one ~10-line helper + one activate() wiring line + tests). The codebase patterns are crystal-clear (the `menu` config block is a 1:1 template for `shell`; the activate() pcall'd blocks are a 1:1 template for the warm call). The ONE risk is the `setup({ shell = false })` edge case (vim.tbl_deep_extend's exact coercion behavior) — the PRP tells the implementer to VERIFY it + adjust the assertion rather than guess. The second minor risk is the fake-driver test harness (copying shell_ensure_spec.lua's fakes correctly) — the PRP cites the exact source file + the spy trick. No external research needed; no daemon-internals knowledge beyond "ensure spawns + fails via S4". Deducted 2 points for the edge-case verification burden + the test-harness fidelity risk.