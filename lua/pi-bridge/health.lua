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

--- Per-shell driver quality tiers (PRD §17.6). Drivers do NOT export `M.tier` (verified:
--- fish/zsh/bash expose only `.start`/`.cd`/`.return`). The §17.6 "shell completion" health
--- section derives the tier from the resolved-shell basename via this map (tier-1 for
--- fish/zsh — clean/capture-completion; tier-2 for bash — best-effort; else "unknown").
local SHELL_TIER = { fish = "tier-1", zsh = "tier-1", bash = "tier-2" }

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

  -- ===== Section 5: pi-bridge shell completion =====
  -- Read-only diagnostics for the §17 shell-completion subsystem (PRD §17.4 resolution /
  -- §17.6 driver tiers / §17.12 failure flags / §17.15 health surface). NEVER spawns a live
  -- daemon: `vim.uv.spawn` is ASYNC — its cb fires AFTER `check()` returns → an incomplete
  -- report or a hang on a dead server (the SAME reason sections 2-3 never issue a live
  -- `ping`). This section reads ONLY state `shell.lua`/`init.lua`/`bridge.lua` already compute
  -- (table reads + the PURE `resolve_shell`/`pick_driver` helpers + `notify.did_notify`).
  -- PRD §17.15's "live-spawns each available shell driver for a 1-shot smoke" is ASPIRATIONAL
  -- + OUT OF SCOPE for v1 (it conflicts with the sync `check()` invariant); the in-variant
  -- behavior is state-only reporting. Dormant (no `PI_NVIM_BRIDGE`) is the EXPECTED state
  -- outside a pi session → `info`, NEVER `error`/`warn` (mirrors sections 2-3).
  do
    health.start("pi-bridge shell completion")

    -- Dormant gate (mirrors sections 2-3): if the bridge env var is unset AND no descriptor
    -- was parsed, the shell subsystem is dormant — emit info + skip the daemon probes.
    local raw_env = vim.env[env_name]
    local s_desc = (pi and pi.descriptor) or nil
    if raw_env == nil and s_desc == nil then
      health.info(
        "shell completion is dormant (no pi editor session — `!`/`!!` completion only runs inside a pi-launched editor)."
      )
    else
      -- Lazy-load the shell + notify modules INSIDE check() (call-time, pcall-wrapped so a
      -- broken/missing module degrades to a graceful skip — never throws).
      local shell_mod = nil ---@type table|nil
      pcall(function() shell_mod = require("pi-bridge.shell") end)
      local notify_mod = nil ---@type table|nil
      pcall(function() notify_mod = require("pi-bridge.notify") end)
      -- Effective config (S1 COMPLETE — config.shell is populated; defensive AND-chain so a
      -- nil config does NOT throw).
      local cfg = (pi and pi.config and pi.config.shell) or {}
      local prefer = cfg.prefer or "pi"

      -- Resolved shell + source (PURE resolve_shell — never mutates state; safe in check();
      -- shows the WOULD-BE resolution even pre-spawn, unlike state.shell which is nil until
      -- the first ensure()).
      local resolved, source = nil, nil
      if shell_mod and type(shell_mod.resolve_shell) == "function" then
        pcall(function() resolved, source = shell_mod.resolve_shell(prefer) end)
      end
      if resolved then
        health.info(
          ("resolved shell: %s (source: %s, prefer: %s)"):format(tostring(resolved), tostring(source), tostring(prefer))
        )
        -- tier from the basename via the module-local SHELL_TIER map (§17.6).
        local base = tostring(resolved):gsub(".*/", "")
        local tier = SHELL_TIER[base] or "unknown"
        health.info(("driver: %s (%s)"):format(base, tier))
      else
        health.warn("could not resolve a shell (resolve_shell returned nil — check config.shell.prefer).")
      end

      -- Driver picked? (PURE pick_driver — returns nil for unknown shells OR user-disabled
      -- drivers; §17.4.2). Distinguish the two cases for actionable advice.
      if shell_mod and type(shell_mod.pick_driver) == "function" and resolved then
        local drv_ok, has_driver = pcall(function() return shell_mod.pick_driver(resolved) ~= nil end)
        if drv_ok and not has_driver then
          local base = tostring(resolved):gsub(".*/", "")
          local disabled = type(cfg.drivers) == "table" and cfg.drivers[base] == false
          if disabled then
            health.warn(("driver for %s is disabled in config (shell.drivers.%s = false) — no completion for this shell."):format(
              base, base
            ))
          else
            health.warn(("no driver for %s (unsupported shell — only fish/zsh/bash are supported; degrades to no completion)."):format(
              base
            ))
          end
        end
      end

      -- Daemon health via M.status() (read-only snapshot; never spawns). Branch on failed
      -- (§17.12 permanent disable) → warn+advice; proc_alive → ok; else → info (lazy).
      local st = nil ---@type table|nil
      if shell_mod and type(shell_mod.status) == "function" then
        pcall(function() st = shell_mod.status() end)
      end
      if type(st) == "table" then
        if st.failed then
          health.warn("daemon failed — shell completion is disabled for `!`/`!!` lines this session.", {
            "Run `:messages` for the degrade notice (category `shell-degrade`).",
            "See `:help pi-bridge-shell` (P2.M3.T6.S4) for resolution / config.",
          })
          if type(st.parse_failures) == "number" and st.parse_failures > 0 then
            health.info(
              ("consecutive parse failures: %d (threshold %d)"):format(st.parse_failures, cfg.max_parse_failures or 5)
            )
          end
        elseif st.proc_alive then
          health.ok(("daemon ready (%s)"):format(st.driver_basename ~= "" and st.driver_basename or "?"))
        else
          health.info(
            "daemon not spawned yet (lazy — starts on the first `!`/`!!`; or enable shell.warm_on_enter)."
          )
        end
        if st.inflight then
          health.info("a completion request is in flight (daemon busy).")
        end
      end

      -- Last notice (sync surrogate for "last error" — notify.did_notify is a table read;
      -- the actual last-error string is NOT stored, the category conveys it).
      if notify_mod and type(notify_mod.did_notify) == "function" then
        for _, cat in ipairs({ "shell-degrade", "shell-mismatch", "shell-active" }) do
          local fired = false
          pcall(function() fired = notify_mod.did_notify(cat) == true end)
          if fired then
            health.info(
              ("a `%s` notice fired earlier this session (run `:messages` to see it)."):format(cat)
            )
          end
        end
      end

      -- Effective config (S1 COMPLETE — config.shell is populated). Report enabled=false as
      -- a warn (the master switch is OFF). Otherwise report the effective knobs.
      if cfg.enabled == false then
        health.warn("shell completion is disabled in config (shell.enabled = false).")
      else
        health.info(("config: enabled=%s, prefer=%s, warm_on_enter=%s"):format(
          tostring(cfg.enabled ~= false), tostring(prefer), tostring(cfg.warm_on_enter)
        ))
      end

      -- Cross-check the descriptor's advertised shell vs the resolved one (advisory). A
      -- mismatch (e.g. resolve picked /bin/bash via $SHELL but the descriptor advertises
      -- /bin/zsh) is the §17.4.3 footgun — surface it.
      local advertised = nil
      pcall(function()
        local br = require("pi-bridge.bridge")
        if type(br) == "table" and type(br.get_shell_info) == "function" then
          local si = br.get_shell_info()
          advertised = (si and si.shell) or (s_desc and s_desc.shell) or nil
        end
      end)
      if advertised and resolved and advertised ~= resolved then
        health.info(("note: descriptor advertises shell %q but resolve_shell picked %q (prefer=%s)."):format(
          tostring(advertised), tostring(resolved), tostring(prefer)
        ))
      end
    end
  end
end

return M