# Research notes — P3.M10.T27.S42 `:checkhealth pi-editor` (`health.lua`)

> Goal: ship `plugin/lua/pi-editor/health.lua` (function `M.check`) so `:checkhealth pi-editor`
> reports **version / env / socket / fd** status. All facts below were verified LIVE against
> the installed runtime (NVIM v0.12.4) + this repo's source on 2025‑07‑20. A parallel
> subagent research report lives at
> `.pi-subagents/artifacts/outputs/5f7eb051/research.md` (533 lines) — these notes are the
> condensed, verified-for-this-PRP version.

---

## 1. Module discovery + the `check()` contract (VERIFIED)

- `:checkhealth pi-editor` → the loader (`/usr/share/nvim/runtime/lua/vim/health.lua:122`
  `filepath_to_healthcheck`) builds the literal string
  `require("pi-editor.health").check()` (`:152`) and runs it via
  `assert(loadstring(func))` wrapped in `pcall` (`:456-463`).
- **The function name `check` is HARDCODED.** It MUST be a table field `M.check`
  (`function M.check()`), NOT a file-soped `local function check()` (the loader would error
  "Failed to run healthcheck" / "report is empty").
- Accepted file locations for a plugin `foo`: `lua/foo/health.lua` OR `lua/foo/health/init.lua`.
  For this repo the runtimepath root is `plugin/` (existing `plugin/lua/pi-editor/init.lua`
  ⇒ `require("pi-editor")`), so the health module is **`plugin/lua/pi-editor/health.lua`**.
- **LIVE-VERIFIED discovery:** with a throwaway `plugin/lua/pi-editor/health.lua` on rtp,
  `vim.api.nvim_get_runtime_file("lua/pi-editor/health.lua", false)` returns it AND
  `require("pi-editor.health").check` resolves (ran from `plugin/` with `rtp += .`).
  (Cleaned up; the plugin source tree is intact + git-clean.)
- Bare `:checkhealth` (no args) auto-discovers ALL `*/health.lua` on rtp, so
  `pi-editor.health` shows up automatically too.
- **Load timing: LAZY** — discovered + `require`'d on demand by `:checkhealth` / a test; NOT
  sourced at startup. Top-level `require`s in health.lua do not slow startup.

## 2. The `vim.health` API (VERIFIED against `runtime/lua/vim/health.lua`)

```lua
function M.start(name)          -- :272  emits "\n<name> ~"  (a section heading; callable multiple times → subsections)
function M.info(msg)            -- :280  informational bullet
function M.ok(msg)              -- :288  "✅ OK"
function M.warn(msg, ...)       -- :297  "⚠️ WARNING" (increments warn summary counter)
function M.error(msg, ...)      -- :307  "❌ ERROR"   (increments error summary counter)
```
- `advice` (the optional 2nd arg of `warn`/`error`, via `format_report_message` `:233`):
  omitted/`nil` | a single `string` | a `string[]` array. **Only the FIRST trailing arg is
  consumed** (`local varargs = ...`) → pass multiple advice lines as a TABLE, not as extra
  string args (`warn(msg,"a","b")` DROPS `"b"`; use `warn(msg,{"a","b"})`).
- `vim.health` is a **built-in global** on 0.10/0.11/0.12 — NO `require("vim.health")` needed
  (lspconfig does `require('vim.health')` too — both resolve to the same module). Capture it
  ONCE at the top of `check()`: `local health = vim.health`.

## 3. Deprecation (VERIFIED against `runtime/doc/deprecated.txt` `*deprecated-0.10*`)

- The OLD `report_start/report_ok/report_warn/report_error/report_info` were **deprecated in
  0.10**; the NEW `start/ok/warn/error/info` were **introduced in 0.10**.
- On the installed **0.12** runtime `report_*` are **REMOVED** (not even defined). → This repo
  (floor 0.11 — see §5) uses the NEW API directly, NO `report_*` shim needed.

## 4. The "loader pcall-wraps the WHOLE check()" gotcha (VERIFIED `:458-463`)

```lua
local f = assert(loadstring(func))
local ok, output = pcall(f)        -- wraps the ENTIRE require(...).check()
if not ok then
  M.error(string.format('Failed to run healthcheck for "%s" plugin. Exception:\n%s', name, output))
end
```
- An **uncaught throw anywhere in `M.check()` blanks the REST of your report** (and, since
  `s_output` is reset per-check at `:446`, nothing from that check is emitted except the
  generic error line).
- → **Be defensive: wrap each individually-risky probe in its OWN `pcall`** (binary check,
  `vim.json.decode`, `fs_stat`, module `require`s). This mirrors lspconfig/treesitter/which-key
  (all pcall-guard their probes).

## 5. Neovim minimum version = **0.11** (NOT 0.10) — VERIFIED

- PRD §10.1 (h3.26) text says "Neovim 0.10+ (0.12 verified)". BUT
  `plugin/lua/pi-editor/coords.lua` GOTCHA 9 (`:82-86`): the 3-arg `"utf-16"` overload of
  `vim.str_utfindex` was **ADDED in Neovim 0.11** (News-0.11); the exact-UTF-16 conversion
  path **raises the effective floor to 0.11**. 0.12.4 is the verified target.
- → The health version-gate MUST check for **0.11**, and it should `error` (not merely warn)
  below 0.11, since older nvim would crash `coords.lua` at runtime.
- **Cross-version-safe idiom: `vim.fn.has("nvim-0.11") == 1`.** Do NOT use `vim.version.ge/le`
  (those are **0.12-only**, per `runtime/lua/vim/version.lua` `@since 12`), nor
  `vim.version.cmp/eq/lt/gt` (**0.11-only**, `@since 11`). `vim.fn.has('nvim-X')` is a
  vimscript builtin present on EVERY version. (mason.nvim uses the same `vim.fn.has` gate.)
- For display: `vim.version()` returns the current nvim version (a `vim.Version` object with
  `.major/.minor/.patch`); format `tostring(vim.version())` (e.g. `"0.12.4"`) for an `info` line.

## 6. Executable checks — the `fd`/`fdfind` optional-WARN pattern (gold standard: telescope)

- `vim.fn.executable(name)` → `1` if found on `$PATH` + executable, else `0` (the yes/no GATE).
- `vim.fn.exepath(name)` → the resolved full path (e.g. `/usr/bin/fd`), else `""` (for REPORTING).
- pi/Debian ship `fdfind`; Arch/others ship `fd`. Try BOTH alternates in order.
- `fd` is **OPTIONAL**: pi's `@file` fuzzy search silently returns nothing without it, but
  path completion (readdir) still works (PRD §11). → report a **`warn` (NOT `error`)** with
  install advice as a `string[]` when missing.
- Pattern (mirror telescope.nvim `lua/telescope/health.lua`):
  ```lua
  local function first_executable(names)
    for _, n in ipairs(names) do
      if vim.fn.executable(n) == 1 then return n, vim.fn.exepath(n) end
    end
  end
  local fd, path = first_executable { "fd", "fdfind" }
  ```
- **Client/server nuance:** the BRIDGE reports `descriptor.fdAvailable` / `server_info.fdAvailable`
  (the SERVER's resolution). The server resolves `fd` in **pi's agent bin dir FIRST, then PATH**
  (`extension/pi-editor-bridge.ts:327-348` `resolveFdAvailable`). The nvim CLIENT can only check
  `$PATH` (`vim.fn.executable`). So a mismatch (server=`true`, client=`false`) is PLAUSIBLE and
  **NOT an error** — the server has `fd` in its bin dir. Health reports BOTH and notes this.

## 7. What health reads from this repo (VERIFIED — all are EXISTING, read-only consumers)

| Check | Source | Notes |
|---|---|---|
| Plugin version | `require("pi-editor.bridge").version` (`:176` = `"0.1.0"`, mirrors `package.json`) | pcall (a broken bridge must not break health) |
| Env var name | `require("pi-editor").config.env_var or "PI_EDITOR_BRIDGE"` | config may be nil if setup() never ran → default |
| Raw env var | `vim.env[env_name]` | absent ⇒ dormant (the EXPECTED normal-session state) |
| Parsed descriptor | `require("pi-editor").descriptor` (`:107`, set by `activate()`) | has `.transport/.path/.token/.pid/.cwd/.fdAvailable/.serverVersion` |
| Connection live? | `require("pi-editor.bridge").is_connected()` (`:845`) | `state.connected and not state.closed` |
| Server handshake result | `require("pi-editor.bridge").server_info` (`:188`) | `.serverVersion/.cwd/.fdAvailable`; nil until handshake |
| Socket file exists? | `vim.uv.fs_stat(descriptor.path)` | nil ⇒ socket gone (pi exited / stale) |

- **Dormant-vs-active design:** in a NORMAL nvim session (user running `:checkhealth` from
  their config), `PI_EDITOR_BRIDGE` is UNSET → the plugin is dormant BY DESIGN (PRD §7.1/§11).
  A missing env var is **NOT an error**; report an informational `info` ("dormant — completion
  is only active inside a pi-launched editor"). Gate the env-detail / socket sections on the
  env var being set. The **fd section runs UNCONDITIONALLY** (the user wants to know whether
  `@file` completion will work when they DO use pi-editor).

## 8. Testing `M.check()` — the stub-capture pattern (mirrors `plugin/tests/notify_spec.lua`)

- `M.check()` calls `vim.health.X` **at call time** (NOT module-load time), so a test can swap
  `vim.health` in `before_each` to a table of capturing stubs and assert on the captured calls —
  exactly how `notify_spec.lua` stubs `vim.notify`.
- **No buffer / no `:checkhealth` invocation needed** — `M.check()` only appends to the
  `vim.health` module-local `s_output` table; the report BUFFER is created by `_check` only when
  `:checkhealth` runs interactively. A direct `health.check()` call with a stubbed `vim.health`
  is the clean unit test.
- Stubs needed: `start/ok/warn/error/info` → each `function(...) t[#t+1] = {method=..., ...} end`.
- Also stub `vim.fn.executable` (for the fd present/absent cases) + set `vim.env.PI_EDITOR_BRIDGE`
  (for the dormant/active cases) + set `require("pi-editor").descriptor`/`.bridge.server_info`
  (for the active-session cases) per-case.
- Key cases: (a) module loads + `M.check` is a table field; (b) dormant session → NO `error`
  calls + an `info` "dormant"; (c) active session (valid descriptor + connected + server_info) →
  `ok` connected + `info` fields, no errors; (d) malformed env var → `warn`/`error` for bad
  descriptor; (e) fd present → `ok`; (f) fd absent → `warn` (not error) + advice; (g) never
  throws on broken bridge/config (pcall-wrapped probes); (h) nvim version `ok` line emitted.
- The smoke (`health_smoke.lua`, plenary-free) just requires the module + calls `M.check()` with
  a stubbed `vim.health` and asserts no throw + at least one `start` call.

## 9. Reference URLs (upstream, for online cross-check)

- Neovim `runtime/lua/vim/health.lua` (API + loader):
  https://github.com/neovim/neovim/blob/master/runtime/lua/vim/health.lua  (`:help health-dev`, `:help :checkhealth`, `:help g:health`)
- Neovim `runtime/doc/deprecated.txt` (`*deprecated-0.10*` CHECKHEALTH):
  https://github.com/neovim/neovim/blob/master/runtime/doc/deprecated.txt
- Neovim `runtime/lua/vim/version.lua` (`@since 11/12` tags):
  https://github.com/neovim/neovim/blob/master/runtime/lua/vim/version.lua
- telescope.nvim `lua/telescope/health.lua` (optional `fd`/`fdfind` WARN gold standard):
  https://github.com/nvim-telescope/telescope.nvim/blob/master/lua/telescope/health.lua
- mason.nvim `lua/mason/health.lua` (`vim.fn.has` version gate + advice-as-array):
  https://github.com/mason-org/mason.nvim/blob/main/lua/mason/health.lua
- nvim-treesitter `lua/nvim-treesitter/health.lua` (`executable`+`exepath`+`vim.version`):
  https://github.com/nvim-treesitter/nvim-treesitter/blob/master/lua/nvim-treesitter/health.lua

## 10. Open question (resolved by design)

- **Should health issue a live `ping` RPC?** NO (documented non-goal). `ping` is async in this
  bridge (`bridge.request(method, params, cb)` is callback-based); driving it from a synchronous
  `check()` is awkward + risks a hang (a dead server). Health relies on the EXISTING live state
  (`is_connected()` + `server_info`) instead — `is_connected()` already reflects the real socket
  state (set true only in the connect-success path; cleared on close/EOF). No new RPC.