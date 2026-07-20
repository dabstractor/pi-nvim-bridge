-- === plugin/tests/health_spec.lua — plenary/busted spec (the Level-2 gate for S42) ===
-- Covers every Success Criterion of health.lua's M.check(). Stubs the 5 vim.health.*
-- methods to a capturing table in before_each (EXACTLY how notify_spec.lua stubs
-- vim.notify), then asserts on the captured calls across dormant/active/malformed/fd
-- cases. Also stubs vim.fn.executable / vim.fn.has / vim.env.PI_EDITOR_BRIDGE + the
-- module state on require("pi-editor") / require("pi-editor.bridge").
--
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/health_spec.lua")'
--
-- NOTE: do NOT name a local `pending` (shadows plenary.busted's skip fn — cf. completion_spec.lua header).
local health = require("pi-editor.health")

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

--- Count captured calls of `method`.
local function count(method)
  local n = 0
  for _, c in ipairs(captured) do
    if c.method == method then n = n + 1 end
  end
  return n
end

describe("pi-editor.health (S42)", function()
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
    saved.env = vim.env.PI_EDITOR_BRIDGE
    vim.env.PI_EDITOR_BRIDGE = nil
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
    local pi = require("pi-editor")
    local bridge = require("pi-editor.bridge")
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
    vim.env.PI_EDITOR_BRIDGE = saved.env
    vim.fn.executable = saved.fn_executable
    vim.fn.has = saved.fn_has
    vim.fn.exepath = saved.fn_exepath
    local pi = require("pi-editor")
    local bridge = require("pi-editor.bridge")
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
    local pi = require("pi-editor")
    pi.config = nil
    pi.descriptor = nil
    vim.env.PI_EDITOR_BRIDGE = nil

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
    local pi = require("pi-editor")
    local bridge = require("pi-editor.bridge")
    local desc = {
      transport = "unix",
      path = "/tmp/pi-editor-bridge-fake.sock",
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
    assert.is_true(any_info_substr("/tmp/pi-editor-bridge-fake.sock"), "info line names the socket path")
    assert.is_true(any_info_substr("99999"), "info line names the pid")
    assert.is_true(any_info_substr("/home/u/proj"), "info line names the cwd")
    assert.is_true(any_info_substr("0.1.0"), "info line names the server version")
  end)

  -- (e) malformed env var (bad JSON): an error naming it; no throw
  it("malformed env var (bad JSON) emits an error", function()
    local pi = require("pi-editor")
    pi.descriptor = nil
    vim.env.PI_EDITOR_BRIDGE = "{not json"

    local ok = pcall(health.check)
    assert.is_true(ok)
    local e = find("error", function(msg) return tostring(msg):find("not valid JSON", 1, true) ~= nil end)
    assert.is_not_nil(e, "an error names the bad JSON")
    assert.is_true(type(e.advice) == "table", "advice is a string[] table")
  end)

  -- (e2) malformed env var (wrong transport): a warn naming it; no throw
  it("malformed env var (wrong transport) emits a warn", function()
    local pi = require("pi-editor")
    pi.descriptor = nil
    vim.env.PI_EDITOR_BRIDGE = '{"transport":"tcp","path":"/tmp/x","token":"t","pid":1,"cwd":"/","fdAvailable":false,"serverVersion":"0.1.0"}'

    local ok = pcall(health.check)
    assert.is_true(ok)
    local w = find("warn", function(msg) return tostring(msg):find("transport", 1, true) ~= nil end)
    assert.is_not_nil(w, "a warn names the wrong transport")
  end)

  -- (f) fd present: an ok naming fd
  it("fd present emits an ok naming fd", function()
    local pi = require("pi-editor")
    pi.descriptor = nil
    vim.env.PI_EDITOR_BRIDGE = nil
    vim.fn.executable = function(name) if name == "fd" then return 1 end; return 0 end
    vim.fn.exepath = function(name) if name == "fd" then return "/usr/bin/fd" end; return "" end

    local ok = pcall(health.check)
    assert.is_true(ok)
    assert.is_true(any_ok_substr("fd"), "an ok line names fd")
    assert.is_true(any_ok_substr("/usr/bin/fd"), "the ok line names the resolved path")
  end)

  -- (g) fd absent: a warn (NOT error) whose advice is a table containing "sharkdp/fd"
  it("fd absent emits a warn (not error) with string[] advice mentioning sharkdp/fd", function()
    local pi = require("pi-editor")
    pi.descriptor = nil
    vim.env.PI_EDITOR_BRIDGE = nil
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
    local pi = require("pi-editor")
    local bridge = require("pi-editor.bridge")
    local desc = {
      transport = "unix",
      path = "/tmp/pi-editor-bridge-fake2.sock",
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

  -- (i) never throws: force require("pi-editor.bridge") to fail; check() still completes
  it("never throws when require('pi-editor.bridge') fails", function()
    local pi = require("pi-editor")
    pi.config = nil
    pi.descriptor = nil
    vim.env.PI_EDITOR_BRIDGE =
      '{"transport":"unix","path":"/tmp/x.sock","token":"t","pid":1,"cwd":"/","fdAvailable":false,"serverVersion":"0.1.0"}'
    -- poison package.loaded so the pcall(require("pi-editor.bridge")) inside check() fails
    local real_bridge = package.loaded["pi-editor.bridge"]
    package.loaded["pi-editor.bridge"] = nil
    package.preload["pi-editor.bridge"] = function() error("forced load failure") end

    local ok = pcall(health.check)
    -- restore BEFORE asserting so after_each also gets a clean state
    package.preload["pi-editor.bridge"] = nil
    package.loaded["pi-editor.bridge"] = real_bridge
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
    local pi = require("pi-editor")
    local bridge = require("pi-editor.bridge")
    pi.descriptor = {
      transport = "unix",
      path = "/nonexistent/pi-editor-sock-does-not-exist.sock",
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
    local pi = require("pi-editor")
    local bridge = require("pi-editor.bridge")
    pi.descriptor = {
      transport = "unix",
      path = "/tmp/pi-editor-bridge-fake3.sock",
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