--- health.lua — the `:checkhealth pi-bridge` module (S42; PRD §13 step 14).
-- [Mode A]
--
-- LOADER CONTRACT (VERIFIED LIVE against runtime/lua/vim/health.lua on NVIM 0.12.4):
--   `:checkhealth pi-bridge` discovers this file via a runtimepath glob and runs the
--   literal expression `require("pi-bridge.health").check()` (health.lua:152). So `check`
--   MUST be a TABLE FIELD (`M.check`), never a `local function check()` — a local is
--   invisible to the loader and `:checkhealth` errors "report is empty". `M._check`
--   `loadstring`s that expression inside a `pcall` (health.lua:456-463) and resets its
--   output buffer per-check (health.lua:446), so ONE uncaught throw in `check()` blanks
--   the rest of the report. → EVERY probe below is pcall-wrapped; `check()` never throws.
--
-- API (NEOVIM 0.10+ NEW API; `report_*` REMOVED by 0.12 — we use the new API directly):
--   `vim.health.start(name)` — a section heading (call once per section; 4 here).
--   `vim.health.ok(msg)` / `.info(msg)` — positive / informational lines.
--   `vim.health.warn(msg, advice)` / `.error(msg, advice)` — `advice` is the 2nd arg,
--      `string|string[]`. Only the FIRST trailing arg is consumed, so for multi-line
--      advice pass a TABLE (`warn(msg, {"a","b"})`) — `warn(msg,"a","b")` DROPS `"b"`.
--   `vim.health` is a built-in GLOBAL (no `require`).
--
-- VERSION FLOOR = 0.11 (NOT PRD §10.1's "0.10+"): coords.lua GOTCHA 9 (:82) — the exact-
-- UTF-16 3-arg `vim.str_utfindex` overload was ADDED in Neovim 0.11 (News-0.11). Below 0.11
-- coords.lua would crash at runtime, so the gate `error`s (not warns). GATE IDIOM:
-- `vim.fn.has("nvim-0.11") == 1` — a vimscript builtin on EVERY version. Do NOT use
-- `vim.version.ge/le` (0.12-only, version.lua @since 12) or `cmp/eq/lt/gt` (0.11-only).
--
-- DORMANT ≠ ERROR (PRD §7.1/§11): in a normal nvim session `PI_NVIM_BRIDGE` is UNSET —
-- the plugin only activates when pi spawns the editor. A missing env var is the EXPECTED
-- state → emit an `info "dormant"`, NEVER an `error`/`warn`. The env-detail + connection
-- sections gate on the var (or a live descriptor) being set; the `fd` section runs ALWAYS.
--
-- TEST-FRIENDLY: read `vim.health` + `require("pi-bridge")`/`.config`/`.descriptor` +
-- `require("pi-bridge.bridge")`/`.version`/`.is_connected()`/`.server_info` INSIDE
-- `check()` (call-time, pcall-wrapped). Do NOT cache `vim.health` in a module-level local —
-- the unit test swaps `vim.health` in `before_each` (notify_spec.lua idiom) and a module-
-- level cache would freeze the real `vim.health` and defeat the stub.
--
-- FD IS OPTIONAL + CLIENT/SERVER NUANCE: `fd` (or `fdfind` on Debian) drives pi's `@file`
-- fuzzy search; without it `@file` silently returns nothing but path completion (readdir)
-- still works (PRD §11) → WARN (NOT error) with install advice when missing. Try BOTH
-- alternates `{ "fd", "fdfind" }`. The bridge's `descriptor.fdAvailable`/`server_info.fdAvailable`
-- is the SERVER's resolution (pi agent bin dir FIRST, then $PATH — pi-nvim-bridge.ts:327);
-- the nvim CLIENT only sees `$PATH` (`vim.fn.executable`). So server=true/client=false is
-- PLAUSIBLE + benign — report both + note it.
--
-- NON-GOAL: never issue a live `ping` RPC from `check()` — it is async/callback-based in
-- this bridge; driving it from a sync `check()` risks a hang on a dead server. The existing
-- `is_connected()` (set true only in the connect-success path; cleared on close/EOF) +
-- `server_info` (set by the handshake result) already reflect the real socket state.
--
-- Pure READ-ONLY consumer of state `init.lua` + `bridge.lua` already compute. Modifies
-- nothing; lazy (no startup cost; no wiring in init.lua / the VimEnter shim / package.json).
local M = {}

--- Minimum Neovim version the plugin can run on. coords.lua GOTCHA 9: the exact-UTF-16
--- 3-arg `vim.str_utfindex` overload was ADDED in 0.11 (PRD §10.1 "0.10+" is superseded).
--- 0.12.4 is the verified target. Read by the version gate below + asserted by tests.
M.min_nvim = "0.11"

--- The `:checkhealth pi-bridge` report. Run by the loader as
--- `require("pi-bridge.health").check()` (VERIFIED runtime/lua/vim/health.lua:152).
--- Never throws — every probe is pcall-wrapped (the loader pcall-wraps the WHOLE call at
--- :458; one uncaught throw blanks the rest of the report). Read-only consumer of EXISTING
--- plugin state (`init.lua` config/descriptor; `bridge.lua` version/is_connected/server_info).
--- Four sections: version / bridge-environment / bridge-connection / external-tools-fd.
function M.check()
  local health = vim.health -- built-in global; capture ONCE at top of check() (stub-friendly)
  local uv = vim.uv
  local pi ---@type table|nil
  pcall(function() pi = require("pi-bridge") end) -- nil-safe (broken install / minimal config)

  -- ===== Section 1: pi-bridge (version) =====
  health.start("pi-bridge")
  local pver
  pcall(function() pver = require("pi-bridge.bridge").version end)
  if pver then
    health.ok(("pi-bridge.nvim v%s"):format(tostring(pver)))
  else
    health.warn("could not read pi-bridge version (the bridge module failed to load)")
  end
  -- NOTE: vim.fn.has() needs the "nvim-" prefix for a VERSION check (has("0.11") probes a
  -- feature literally named "0.11" and returns 0). M.min_nvim is the bare "0.11" (asserted by
  -- tests + documents the floor), so build the feature string here.
  if vim.fn.has("nvim-" .. M.min_nvim) == 1 then -- cross-version-safe gate (NOT vim.version.ge — 0.12-only)
    health.ok(("Neovim %s (>= %s required)"):format(tostring(vim.version()), M.min_nvim))
  else
    health.error(("Neovim %s — pi-bridge requires >= %s"):format(tostring(vim.version()), M.min_nvim), {
      "Upgrade Neovim: https://github.com/neovim/neovim/releases",
      "The exact-UTF-16 cursor conversion (coords.lua) needs the 3-arg vim.str_utfindex overload added in 0.11.",
    })
  end

  -- ===== Section 2: pi-bridge bridge (environment) =====
  health.start("pi-bridge bridge (environment)")
  local env_name = "PI_NVIM_BRIDGE"
  pcall(function()
    if pi and pi.config and pi.config.env_var then env_name = pi.config.env_var end
  end)
  local raw = vim.env[env_name]
  local desc = (pi and pi.descriptor) or nil -- the descriptor activate() parsed (authoritative)
  if raw == nil and desc == nil then
    health.info(
      ("%s is not set — pi-bridge is dormant (this is normal outside a pi editor session)."):format(env_name)
    )
  else
    health.ok(("%s is set"):format(env_name))
    local d = desc
    if raw ~= nil and d == nil then
      -- var set but activate() hasn't run → parse it ourselves (validate against BridgeDescriptor)
      local ok, parsed = pcall(vim.json.decode, raw)
      if not ok or type(parsed) ~= "table" then
        health.error(("%s is not valid JSON"):format(env_name), {
          "The bridge extension writes this var when pi starts an editor. Restart pi.",
          "If it persists, the pi-nvim-bridge extension may be mis-installed.",
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
    desc = desc or d -- keep whichever we resolved for sections 3-4
  end

  -- ===== Section 3: pi-bridge bridge (connection) =====
  health.start("pi-bridge bridge (connection)")
  if raw == nil and desc == nil then
    health.info("not applicable — pi-bridge is dormant (no bridge to connect to).")
  else
    local bridge ---@type table|nil
    pcall(function() bridge = require("pi-bridge.bridge") end)
    local connected = false
    pcall(function()
      connected = (type(bridge) == "table" and type(bridge.is_connected) == "function")
          and bridge.is_connected()
        or false
    end)
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
      health.info(
        ("handshake ok — server %s, cwd %s"):format(tostring(sinfo.serverVersion), tostring(sinfo.cwd))
      )
    else
      health.info("no handshake result yet (handshake may still be in flight or failed).")
    end
    if desc and desc.path then
      local stat
      pcall(function() stat = uv.fs_stat(desc.path) end)
      if stat then
        health.ok(("socket file exists: %s"):format(tostring(desc.path)))
      else
        health.warn(("socket file missing: %s"):format(tostring(desc.path)), {
          "pi may have exited while the editor was open. Quit the editor and re-open from pi.",
        })
      end
    end
  end

  -- ===== Section 4: pi-bridge external tools (fd) — runs UNCONDITIONALLY =====
  health.start("pi-bridge external tools (fd)")
  local function first_exec(names)
    for _, n in ipairs(names) do
      if vim.fn.executable(n) == 1 then return n, vim.fn.exepath(n) end
    end
  end
  local fd, fpath = first_exec({ "fd", "fdfind" }) -- Debian=fdfind, Arch/others=fd
  if fd then
    health.ok(("`%s` found: %s"):format(fd, tostring(fpath)))
  else
    health.warn(
      "`fd`/`fdfind` not found on $PATH — pi's `@file` fuzzy search will be unavailable (path completion still works).",
      {
        "Optional. Install it: https://github.com/sharkdp/fd",
        "Debian/Ubuntu: `apt-get install fd-find` (the binary is `fdfind`).",
        "Note: the bridge resolves fd in pi's agent bin dir FIRST, then $PATH — @file may still work even if not on your $PATH.",
      }
    )
  end
  local server_fd
  pcall(function()
    local s = (bridge and bridge.server_info) or {}
    server_fd = (desc and desc.fdAvailable)
    if server_fd == nil then server_fd = s.fdAvailable end
  end)
  if server_fd == true and not fd then
    health.info(
      "the bridge reports `fd` IS available (resolved in pi's bin dir) though it is not on this editor's $PATH."
    )
  elseif server_fd == false and fd then
    health.info("`fd` is on your $PATH but the bridge reports it unavailable — `@file` completion may be limited.")
  end
end

return M