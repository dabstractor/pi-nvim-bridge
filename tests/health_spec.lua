-- === tests/health_spec.lua — plenary/busted spec (the Level-2 gate for S42) ===
-- Covers every Success Criterion of health.lua's M.check(). Stubs the 5 vim.health.*
-- methods to a capturing table in before_each (EXACTLY how notify_spec.lua stubs
-- vim.notify), then asserts on the captured calls across dormant/active/malformed/fd
-- cases. Also stubs vim.fn.executable / vim.fn.has / vim.env.PI_NVIM_BRIDGE + the
-- module state on require("pi-bridge") / require("pi-bridge.bridge").
--
-- Run (from the repo root):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/health_spec.lua")'
--
-- NOTE: do NOT name a local `pending` (shadows plenary.busted's skip fn — cf. completion_spec.lua header).
local health = require("pi-bridge.health")

-- captured calls + saved originals (reset in before_each, restored in after_each)
local captured
local saved ---@type table<string, any>

--- Find the first captured call with `method` matching `predicate(msg, advice)`.
local function find(method, predicate)
  for _, c in ipairs(captured) do
    if c.method == method and predicate(c.msg, c.advice) then return c end
  end
  return nil
end

--- True if ANY captured call of `method` matches `predicate`.
local function has(method, predicate) return find(method, predicate) ~= nil end

--- True if ANY `error` was captured.
local function any_error() return has("error", function() return true end) end

--- True if ANY `info` msg contains `s` (substring).
local function any_info_substr(s)
  return has("info", function(msg) return tostring(msg):find(s, 1, true) ~= nil end)
end

--- True if ANY `ok` msg contains `s` (substring).
local function any_ok_substr(s)
  return has("ok", function(msg) return tostring(msg):find(s, 1, true) ~= nil end)
end

--- True if ANY `warn` msg contains `s` (substring).
local function any_warn_substr(s)
  return has("warn", function(msg) return tostring(msg):find(s, 1, true) ~= nil end)
end

--- Count captured calls of `method`.
local function count(method)
  local n = 0
  for _, c in ipairs(captured) do
    if c.method == method then n = n + 1 end
  end
  return n
end

describe("pi-bridge.health (S42)", function()
  before_each(function()
    captured = {}
    saved = {}
    -- build a fresh capturing vim.health stub (notify_spec.lua idiom, adapted)
    local function stub(method)
      return function(msg, advice)
        captured[#captured + 1] = { method = method, msg = msg, advice = advice }
      end
    end
    saved.vim_health = vim.health
    vim.health = {
      start = stub("start"),
      ok = stub("ok"),
      warn = stub("warn"),
      error = stub("error"),
      info = stub("info"),
    }
    -- env var
    saved.env = vim.env.PI_NVIM_BRIDGE
    vim.env.PI_NVIM_BRIDGE = nil
    -- vim.fn stubs (restorable)
    saved.fn_executable = vim.fn.executable
    saved.fn_has = vim.fn.has
    saved.fn_exepath = vim.fn.exepath
    -- default: fd absent so the fd section is deterministic unless a case opts in
    vim.fn.executable = function(_name) return 0 end
    vim.fn.exepath = function(_name) return "" end
    -- default: this nvim is >= 0.11 (cases can override to exercise the error branch)
    vim.fn.has = function(feature)
      if feature == "nvim-" .. health.min_nvim then return 1 end
      return saved.fn_has(feature)
    end
    -- module state on init.lua + bridge.lua (the read-only consumers)
    local pi = require("pi-bridge")
    local bridge = require("pi-bridge.bridge")
    saved.pi_config = pi.config
    saved.pi_descriptor = pi.descriptor
    saved.bridge_version = bridge.version
    saved.bridge_is_connected = bridge.is_connected
    saved.bridge_server_info = bridge.server_info
    -- default dormant state
    pi.config = nil
    pi.descriptor = nil
    bridge.server_info = nil
    bridge.is_connected = function() return false end
  end)

  after_each(function()
    vim.health = saved.vim_health
    vim.env.PI_NVIM_BRIDGE = saved.env
    vim.fn.executable = saved.fn_executable
    vim.fn.has = saved.fn_has
    vim.fn.exepath = saved.fn_exepath
    local pi = require("pi-bridge")
    local bridge = require("pi-bridge.bridge")
    pi.config = saved.pi_config
    pi.descriptor = saved.pi_descriptor
    bridge.version = saved.bridge_version
    bridge.is_connected = saved.bridge_is_connected
    bridge.server_info = saved.bridge_server_info
  end)

  -- (a) surface: the module exposes the loader contract
  it("exposes a table with M.check (function) + M.min_nvim == '0.11'", function()
    assert.is_true(type(health) == "table")
    assert.is_true(type(health.check) == "function")
    assert.are.equals("0.11", health.min_nvim)
  end)

  -- (b) dormant session (env unset, descriptor nil): info "dormant" + NO error
  it("dormant session emits an info 'dormant' and zero errors", function()
    local pi = require("pi-bridge")
    pi.config = nil
    pi.descriptor = nil
    vim.env.PI_NVIM_BRIDGE = nil

    local ok = pcall(health.check)
    assert.is_true(ok, "check() must not throw")
    assert.is_true(count("start") >= 4, "at least 4 start() sections")
    assert.is_false(any_error(), "dormant must emit ZERO error calls")
    assert.is_true(any_info_substr("dormant"), "dormant emits an info 'dormant'")
  end)

  -- (c) nvim version gate (>=0.11 here): an ok "Neovim"; no error for version
  it("nvim version >= floor emits an ok 'Neovim' and no error", function()
    local ok = pcall(health.check)
    assert.is_true(ok)
    assert.is_true(any_ok_substr("Neovim"), "an ok line mentions Neovim")
    -- no version-related error on a >= floor session
    assert.is_false(has("error", function(msg) return tostring(msg):find("requires", 1, true) ~= nil end))
  end)

  -- (c2) nvim version gate (< floor): an error with upgrade advice
  it("nvim version < floor emits an error with upgrade advice", function()
    vim.fn.has = function(_f) return 0 end
    local ok = pcall(health.check)
    assert.is_true(ok)
    local e = find("error", function(msg) return tostring(msg):find("requires", 1, true) ~= nil end)
    assert.is_not_nil(e, "an error mentions 'requires'")
    assert.is_true(type(e.advice) == "table", "advice is a string[] table")
    local advice = table.concat(e.advice, " ")
    assert.is_true(advice:find("neovim/neovim", 1, true) ~= nil, "advice points to neovim releases")
  end)

  -- (d) active session (valid descriptor + connected + server_info): ok connected, no errors
  it("active session emits ok connected + descriptor info + zero errors", function()
    local pi = require("pi-bridge")
    local bridge = require("pi-bridge.bridge")
    local desc = {
      transport = "unix",
      path = "/tmp/pi-nvim-bridge-fake.sock",
      token = "deadbeef",
      pid = 99999,
      cwd = "/home/u/proj",
      fdAvailable = true,
      serverVersion = "0.1.0",
    }
    pi.descriptor = desc
    bridge.is_connected = function() return true end
    bridge.server_info = { serverVersion = "0.1.0", cwd = "/home/u/proj", fdAvailable = true }

    local ok = pcall(health.check)
    assert.is_true(ok)
    assert.is_false(any_error(), "active + connected must emit ZERO errors")
    assert.is_true(any_ok_substr("connected"), "an ok 'connected' line")
    assert.is_true(any_info_substr("/tmp/pi-nvim-bridge-fake.sock"), "info line names the socket path")
    assert.is_true(any_info_substr("99999"), "info line names the pid")
    assert.is_true(any_info_substr("/home/u/proj"), "info line names the cwd")
    assert.is_true(any_info_substr("0.1.0"), "info line names the server version")
  end)

  -- (e) malformed env var (bad JSON): an error naming it; no throw
  it("malformed env var (bad JSON) emits an error", function()
    local pi = require("pi-bridge")
    pi.descriptor = nil
    vim.env.PI_NVIM_BRIDGE = "{not json"

    local ok = pcall(health.check)
    assert.is_true(ok)
    local e = find("error", function(msg) return tostring(msg):find("not valid JSON", 1, true) ~= nil end)
    assert.is_not_nil(e, "an error names the bad JSON")
    assert.is_true(type(e.advice) == "table", "advice is a string[] table")
  end)

  -- (e2) malformed env var (wrong transport): a warn naming it; no throw
  it("malformed env var (wrong transport) emits a warn", function()
    local pi = require("pi-bridge")
    pi.descriptor = nil
    vim.env.PI_NVIM_BRIDGE = '{"transport":"tcp","path":"/tmp/x","token":"t","pid":1,"cwd":"/","fdAvailable":false,"serverVersion":"0.1.0"}'

    local ok = pcall(health.check)
    assert.is_true(ok)
    local w = find("warn", function(msg) return tostring(msg):find("transport", 1, true) ~= nil end)
    assert.is_not_nil(w, "a warn names the wrong transport")
  end)

  -- (f) fd present: an ok naming fd
  it("fd present emits an ok naming fd", function()
    local pi = require("pi-bridge")
    pi.descriptor = nil
    vim.env.PI_NVIM_BRIDGE = nil
    vim.fn.executable = function(name) if name == "fd" then return 1 end; return 0 end
    vim.fn.exepath = function(name) if name == "fd" then return "/usr/bin/fd" end; return "" end

    local ok = pcall(health.check)
    assert.is_true(ok)
    assert.is_true(any_ok_substr("fd"), "an ok line names fd")
    assert.is_true(any_ok_substr("/usr/bin/fd"), "the ok line names the resolved path")
  end)

  -- (g) fd absent: a warn (NOT error) whose advice is a table containing "sharkdp/fd"
  it("fd absent emits a warn (not error) with string[] advice mentioning sharkdp/fd", function()
    local pi = require("pi-bridge")
    pi.descriptor = nil
    vim.env.PI_NVIM_BRIDGE = nil
    vim.fn.executable = function(_name) return 0 end

    local ok = pcall(health.check)
    assert.is_true(ok)
    local w = find("warn", function(msg) return tostring(msg):find("fd", 1, true) ~= nil end)
    assert.is_not_nil(w, "a warn names fd")
    assert.is_true(type(w.advice) == "table", "advice is a string[] table")
    local advice = table.concat(w.advice, " ")
    assert.is_true(advice:find("sharkdp/fd", 1, true) ~= nil, "advice links to sharkdp/fd")
    assert.is_false(any_error(), "missing fd must NOT be an error")
  end)

  -- (h) server=true/client=false fd nuance: warn for fd absent + info noting bridge has fd
  it("server=true/client=false fd nuance emits a warn + an info noting the bridge has fd", function()
    local pi = require("pi-bridge")
    local bridge = require("pi-bridge.bridge")
    local desc = {
      transport = "unix",
      path = "/tmp/pi-nvim-bridge-fake2.sock",
      token = "deadbeef",
      pid = 99999,
      cwd = "/home/u/proj",
      fdAvailable = true, -- SERVER says yes
      serverVersion = "0.1.0",
    }
    pi.descriptor = desc
    bridge.is_connected = function() return true end
    bridge.server_info = { serverVersion = "0.1.0", cwd = "/home/u/proj", fdAvailable = true }
    vim.fn.executable = function(_name) return 0 end -- CLIENT says no

    local ok = pcall(health.check)
    assert.is_true(ok)
    assert.is_not_nil(find("warn", function(msg) return tostring(msg):find("fd", 1, true) ~= nil end), "warn for fd absent")
    assert.is_true(any_info_substr("bin dir"), "info notes the bridge resolved fd in its bin dir")
  end)

  -- (i) never throws: force require("pi-bridge.bridge") to fail; check() still completes
  it("never throws when require('pi-bridge.bridge') fails", function()
    local pi = require("pi-bridge")
    pi.config = nil
    pi.descriptor = nil
    vim.env.PI_NVIM_BRIDGE =
      '{"transport":"unix","path":"/tmp/x.sock","token":"t","pid":1,"cwd":"/","fdAvailable":false,"serverVersion":"0.1.0"}'
    -- poison package.loaded so the pcall(require("pi-bridge.bridge")) inside check() fails
    local real_bridge = package.loaded["pi-bridge.bridge"]
    package.loaded["pi-bridge.bridge"] = nil
    package.preload["pi-bridge.bridge"] = function() error("forced load failure") end

    local ok = pcall(health.check)
    -- restore BEFORE asserting so after_each also gets a clean state
    package.preload["pi-bridge.bridge"] = nil
    package.loaded["pi-bridge.bridge"] = real_bridge
    assert.is_true(ok, "check() must not throw when the bridge module is broken")
    assert.is_true(count("start") >= 4, "still emits the 4 start() sections")
    -- version section still ran (a warn that the version could not be read OR an ok)
    assert.is_true(
      any_ok_substr("Neovim") or has("warn", function(msg) return tostring(msg):find("version", 1, true) ~= nil end),
      "version section still produced a line"
    )
  end)

  -- (j) socket file missing (active session): a warn whose msg contains "missing"
  it("active session with a missing socket file emits a warn 'missing'", function()
    local pi = require("pi-bridge")
    local bridge = require("pi-bridge.bridge")
    pi.descriptor = {
      transport = "unix",
      path = "/nonexistent/pi-bridge-sock-does-not-exist.sock",
      token = "t",
      pid = 1,
      cwd = "/",
      fdAvailable = false,
      serverVersion = "0.1.0",
    }
    bridge.is_connected = function() return false end
    bridge.server_info = nil

    local ok = pcall(health.check)
    assert.is_true(ok)
    local w = find("warn", function(msg) return tostring(msg):find("missing", 1, true) ~= nil end)
    assert.is_not_nil(w, "a warn names the missing socket file")
  end)

  -- (k) not connected (env set): a warn "not connected" (NOT error)
  it("active session that is not connected emits a warn 'not connected'", function()
    local pi = require("pi-bridge")
    local bridge = require("pi-bridge.bridge")
    pi.descriptor = {
      transport = "unix",
      path = "/tmp/pi-nvim-bridge-fake3.sock",
      token = "t",
      pid = 1,
      cwd = "/",
      fdAvailable = false,
      serverVersion = "0.1.0",
    }
    bridge.is_connected = function() return false end
    bridge.server_info = nil

    local ok = pcall(health.check)
    assert.is_true(ok)
    local w = find("warn", function(msg) return tostring(msg):find("not connected", 1, true) ~= nil end)
    assert.is_not_nil(w, "a warn says 'not connected'")
    assert.is_false(any_error(), "not-connected must NOT be an error")
  end)
end)

-- ===========================================================================
-- S2 (P2.M3.T6.S2): the "pi-bridge shell completion" 5th health section.
-- Stubs the shell module (status/resolve_shell/pick_driver) + notify.did_notify +
-- config.shell via package.loaded swap, then asserts the section renders the right
-- lines across dormant / active-not-spawned / proc_alive / failed / no-driver /
-- disabled-driver / config-disabled / did-notice / never-throws / never-spawns cases.
-- ===========================================================================
describe("pi-bridge.health shell section (S2)", function()
  local saved_shell, saved_notify, saved_ensure_spy
  local fake_shell, ensure_spy

  -- Build a fresh fake shell module each test. `overrides` may set status/resolve_shell/
  -- pick_driver/ensure. `ensure` is spied so the never-spawns assertion can observe it.
  local function mount_shell(overrides)
    overrides = overrides or {}
    ensure_spy = { called = 0 }
    fake_shell = {
      resolve_shell = overrides.resolve_shell or function(_prefer) return "/bin/zsh", "$SHELL" end,
      pick_driver = overrides.pick_driver or function(_r) return { start = function() end } end,
      status = overrides.status or function()
        return { shell = nil, driver_basename = "", proc_alive = false, inflight = false, failed = false, parse_failures = 0 }
      end,
      ensure = function(_cb) ensure_spy.called = ensure_spy.called + 1 end, -- the NEVER-spawn spy
    }
    saved_shell = package.loaded["pi-bridge.shell"]
    package.loaded["pi-bridge.shell"] = fake_shell
  end

  -- Mount a fake notify module whose did_notify returns the given per-category map.
  local function mount_notify(did)
    did = did or {}
    local fake_notify = {
      did_notify = function(cat) return did[cat] == true end,
      once = function() end,
    }
    saved_notify = package.loaded["pi-bridge.notify"]
    package.loaded["pi-bridge.notify"] = fake_notify
  end

  before_each(function()
    captured = {}
    saved = {}
    local function stub(method)
      return function(msg, advice)
        captured[#captured + 1] = { method = method, msg = msg, advice = advice }
      end
    end
    saved.vim_health = vim.health
    vim.health = {
      start = stub("start"), ok = stub("ok"), warn = stub("warn"), error = stub("error"), info = stub("info"),
    }
    -- default to an ACTIVE session (env var set) — individual cases may nil it for dormant.
    saved.env = vim.env.PI_NVIM_BRIDGE
    vim.env.PI_NVIM_BRIDGE =
      '{"transport":"unix","path":"/tmp/x.sock","token":"t","pid":1,"cwd":"/tmp","fdAvailable":false,"serverVersion":"0.1.0"}'
    saved.fn_executable = vim.fn.executable
    saved.fn_has = vim.fn.has
    saved.fn_exepath = vim.fn.exepath
    vim.fn.executable = function(_n) return 0 end
    vim.fn.exepath = function(_n) return "" end
    vim.fn.has = function(feature)
      if feature == "nvim-" .. health.min_nvim then return 1 end
      return 0
    end
    -- a populated config.shell so the effective-config line is deterministic.
    local pi = require("pi-bridge")
    saved.pi_config = pi.config
    pi.config = {
      shell = {
        enabled = true, prefer = "pi", warm_on_enter = false, max_parse_failures = 5,
        drivers = { fish = true, zsh = true, bash = true },
      },
    }
    saved.pi_descriptor = pi.descriptor
    pi.descriptor = nil
    local bridge = require("pi-bridge.bridge")
    saved.bridge_version = bridge.version
    saved.bridge_is_connected = bridge.is_connected
    saved.bridge_server_info = bridge.server_info
    bridge.is_connected = function() return false end
    bridge.server_info = nil
  end)

  after_each(function()
    vim.health = saved.vim_health
    vim.env.PI_NVIM_BRIDGE = saved.env
    vim.fn.executable = saved.fn_executable
    vim.fn.has = saved.fn_has
    vim.fn.exepath = saved.fn_exepath
    local pi = require("pi-bridge")
    pi.config = saved.pi_config
    pi.descriptor = saved.pi_descriptor
    local bridge = require("pi-bridge.bridge")
    bridge.version = saved.bridge_version
    bridge.is_connected = saved.bridge_is_connected
    bridge.server_info = saved.bridge_server_info
    -- restore the real shell/notify modules
    package.loaded["pi-bridge.shell"] = saved_shell
    package.loaded["pi-bridge.notify"] = saved_notify
  end)

  -- (a) surface: the 5th section start()s (in BOTH dormant and active sessions)
  it("renders the 'pi-bridge shell completion' section in an active session", function()
    mount_shell()
    mount_notify()
    local ok = pcall(health.check)
    assert.is_true(ok, "check() must not throw")
    assert.is_true(
      has("start", function(msg) return tostring(msg):find("shell completion", 1, true) ~= nil end),
      "start('pi-bridge shell completion') captured"
    )
    -- a resolved shell + source line is present
    assert.is_true(any_info_substr("resolved shell"), "info names the resolved shell")
    assert.is_false(any_error(), "active-not-spawned must emit ZERO errors")
  end)

  -- (b) dormant session: section renders info 'dormant' + skips daemon probes + NO spawn
  it("dormant session emits info 'dormant' + skips shell.status/ensure", function()
    vim.env.PI_NVIM_BRIDGE = nil
    mount_shell()
    mount_notify()
    local ok = pcall(health.check)
    assert.is_true(ok)
    assert.is_true(any_info_substr("shell completion is dormant"), "dormant info line")
    assert.is_false(any_error(), "dormant must NOT be an error")
    assert.is_false(any_warn_substr("shell"), "dormant must NOT emit a shell warn")
    -- the dormant gate returns BEFORE daemon probes → ensure() (the spawn path) was NOT called
    assert.are.equals(0, ensure_spy.called, "dormant gate must NOT call shell.ensure")
  end)

  -- (c) active + not spawned + not failed: info 'not spawned' + resolved shell/driver, no error
  it("active + daemon-not-spawned emits info 'not spawned' + resolved shell + driver", function()
    mount_shell({
      resolve_shell = function(_p) return "/bin/zsh", "$SHELL" end,
      pick_driver = function(_r) return { start = function() end } end,
      status = function()
        return { shell = nil, driver_basename = "", proc_alive = false, inflight = false, failed = false, parse_failures = 0 }
      end,
    })
    mount_notify()
    local ok = pcall(health.check)
    assert.is_true(ok)
    assert.is_true(any_info_substr("not spawned"), "info says daemon not spawned (lazy)")
    assert.is_true(any_info_substr("resolved shell"), "info names the resolved shell")
    assert.is_true(any_info_substr("/bin/zsh"), "info names the zsh path")
    assert.is_true(any_info_substr("driver: zsh"), "info names the driver + basename")
    assert.is_true(any_info_substr("tier-1"), "info names the tier")
    assert.is_false(any_error(), "not-spawned must NOT be an error")
  end)

  -- (d) active + proc_alive: ok 'daemon ready'
  it("active + proc_alive emits ok 'daemon ready' with the basename", function()
    mount_shell({
      status = function()
        return { shell = "/bin/bash", driver_basename = "bash", proc_alive = true, inflight = false, failed = false, parse_failures = 0 }
      end,
    })
    mount_notify()
    local ok = pcall(health.check)
    assert.is_true(ok)
    assert.is_true(any_ok_substr("daemon ready"), "ok says daemon ready")
    assert.is_true(any_ok_substr("bash"), "ok names the driver basename")
  end)

  -- (e) active + failed: warn 'daemon failed' with TABLE advice + parse_failures info
  it("active + failed emits warn 'daemon failed' with string[] advice + parse_failures info", function()
    mount_shell({
      status = function()
        return { shell = "/bin/zsh", driver_basename = "zsh", proc_alive = false, inflight = false, failed = true, parse_failures = 7 }
      end,
    })
    mount_notify()
    local ok = pcall(health.check)
    assert.is_true(ok)
    local w = find("warn", function(msg) return tostring(msg):find("daemon failed", 1, true) ~= nil end)
    assert.is_not_nil(w, "warn says daemon failed")
    assert.is_true(type(w.advice) == "table", "advice is a string[] table")
    local advice = table.concat(w.advice, " ")
    assert.is_true(advice:find(":messages", 1, true) ~= nil, "advice points at :messages")
    assert.is_true(advice:find("pi-bridge-shell", 1, true) ~= nil, "advice points at :help pi-bridge-shell")
    assert.is_true(any_info_substr("parse failures"), "info reports the parse_failures count")
    assert.is_true(any_info_substr("7"), "info names the count 7")
  end)

  -- (f) notify.did_notify('shell-degrade') → info mentioning the degrade notice
  it("surfaces a prior shell-degrade notice via an info line", function()
    mount_shell()
    mount_notify({ ["shell-degrade"] = true })
    local ok = pcall(health.check)
    assert.is_true(ok)
    assert.is_true(any_info_substr("shell-degrade"), "info mentions the degrade notice")
    assert.is_true(any_info_substr(":messages"), "info points at :messages")
  end)

  -- (g) config.shell.enabled == false → warn 'disabled in config'
  it("config.enabled=false emits a warn 'disabled in config'", function()
    local pi = require("pi-bridge")
    pi.config.shell.enabled = false
    mount_shell()
    mount_notify()
    local ok = pcall(health.check)
    assert.is_true(ok)
    assert.is_true(any_warn_substr("disabled in config"), "warn says shell completion is disabled in config")
  end)

  -- (h) no driver for the resolved shell (e.g. /bin/dash) → warn 'no driver'
  it("resolved shell with no driver (dash) emits a warn 'no driver'", function()
    mount_shell({
      resolve_shell = function(_p) return "/bin/dash", "default" end,
      pick_driver = function(_r) return nil end, -- dash unsupported
    })
    mount_notify()
    local ok = pcall(health.check)
    assert.is_true(ok)
    local w = find("warn", function(msg) return tostring(msg):find("no driver", 1, true) ~= nil end)
    assert.is_not_nil(w, "warn says no driver")
    assert.is_true(tostring(w.msg):find("dash", 1, true) ~= nil, "warn names dash")
  end)

  -- (i) user-disabled driver → warn mentioning the disabled driver
  it("user-disabled driver emits a warn naming config.drivers.<base> = false", function()
    local pi = require("pi-bridge")
    pi.config.shell.drivers.zsh = false
    mount_shell({
      resolve_shell = function(_p) return "/bin/zsh", "$SHELL" end,
      pick_driver = function(_r) return nil end, -- disabled → nil (mirrors shell.pick_driver)
    })
    mount_notify()
    local ok = pcall(health.check)
    assert.is_true(ok)
    assert.is_true(any_warn_substr("disabled in config"), "warn says driver is disabled in config")
    assert.is_true(any_warn_substr("drivers.zsh"), "warn names the disabled driver key")
  end)

  -- (j) never-throws: a throwing shell.status does NOT escape check()
  it("never throws when shell.status throws", function()
    mount_shell({
      status = function() error("boom") end,
      resolve_shell = function(_p) return "/bin/zsh", "$SHELL" end,
    })
    mount_notify()
    local ok = pcall(health.check)
    assert.is_true(ok, "check() must not throw when shell.status throws")
    -- the OTHER sections still rendered (4 + the shell section start)
    assert.is_true(count("start") >= 5, "all sections still started")
  end)

  -- (k) never-throws: a throwing resolve_shell does NOT escape check()
  it("never throws when shell.resolve_shell throws", function()
    mount_shell({ resolve_shell = function(_p) error("boom") end })
    mount_notify()
    local ok = pcall(health.check)
    assert.is_true(ok, "check() must not throw when resolve_shell throws")
    -- resolve_shell threw → the 'could not resolve a shell' warn path fires (never error)
    assert.is_false(any_error(), "a resolve throw must NOT become an error")
  end)

  -- (l) never-spawns: shell.ensure is NEVER called during check()
  it("never calls shell.ensure during check() (the never-spawn invariant)", function()
    mount_shell()
    mount_notify()
    pcall(health.check)
    assert.are.equals(0, ensure_spy.called, "check() must NEVER call shell.ensure (no live spawn)")
  end)
end)