-- === plugin/tests/activate_spec.lua — the spec (covers every Success Criterion) ===
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/activate_spec.lua")'
describe("pi-bridge.activate gate", function()
  local pi

  before_each(function()
    package.loaded["pi-bridge"] = nil   -- fresh module per test
    pi = require("pi-bridge")
    require("pi-bridge.notify").reset()  -- S39: clear the dedup set so each case starts clean
    vim.env.PI_NVIM_BRIDGE = nil      -- clean dormant baseline
    pi.descriptor = nil
    pi.bridge = nil                     -- S39: clear any stale bridge publication
    vim.bo[0].filetype = ""             -- deterministic "untouched" assertion
  end)

  -- S39: an async handshake started by a prior case can leak across the module reload
  -- (package.loaded["pi-bridge"]=nil reloads the entry module but NOT pi-bridge.bridge /
  -- pi-bridge.notify). Close the bridge + reset the notify dedup so no stale connect/timer/
  -- scheduled notify bleeds into the next case.
  after_each(function()
    pcall(function() require("pi-bridge.bridge").close() end)
    require("pi-bridge.notify").reset()
  end)

  local function valid_desc()
    return '{"transport":"unix","path":"/tmp/a.sock","token":"t","pid":1,"cwd":"/p",'
      .. '"fdAvailable":true,"serverVersion":"0.1.0"}'
  end

  it("exposes activate as a function", function()
    assert.are.equals("function", type(pi.activate))
  end)

  it("descriptor is nil before activation", function()
    assert.is_nil(pi.descriptor)
  end)

  it("no env var -> dormant (nil return, descriptor nil, filetype untouched)", function()
    local r = pi.activate()
    assert.is_nil(r)
    assert.is_nil(pi.descriptor)
    assert.are.equals("", vim.bo[0].filetype)
  end)

  it("valid unix descriptor -> activates (descriptor fields set, filetype=pi-prompt)", function()
    vim.env.PI_NVIM_BRIDGE = valid_desc()
    local r = pi.activate()
    assert.is_not_nil(r)
    assert.are.equals("/tmp/a.sock", pi.descriptor.path)
    assert.are.equals("unix", pi.descriptor.transport)
    assert.are.equals("t", pi.descriptor.token)
    assert.are.equals("pi-prompt", vim.bo[0].filetype)
  end)

  it("malformed JSON -> dormant, no throw (pcall ok)", function()
    vim.env.PI_NVIM_BRIDGE = "{not json"
    local ok, r = pcall(pi.activate)
    assert.is_true(ok)          -- proves activate did not throw
    assert.is_nil(r)
    assert.is_nil(pi.descriptor)
  end)

  it("valid-JSON-number (123) -> dormant via the type guard, no throw", function()
    vim.env.PI_NVIM_BRIDGE = "123"
    local ok, r = pcall(pi.activate)
    assert.is_true(ok)          -- the type() guard prevented desc.transport from throwing
    assert.is_nil(r)
    assert.is_nil(pi.descriptor)
  end)

  it("transport=tcp -> dormant (v1 is Unix-only)", function()
    vim.env.PI_NVIM_BRIDGE = '{"transport":"tcp","path":"x","token":"t"}'
    local r = pi.activate()
    assert.is_nil(r)
    assert.is_nil(pi.descriptor)
  end)

  it("config.env_var override reads the custom env-var name", function()
    pi.setup({ env_var = "MY_BRIDGE" })
    vim.env.MY_BRIDGE = '{"transport":"unix","path":"/c.sock","token":"z"}'
    local r = pi.activate()
    assert.is_not_nil(r)
    assert.are.equals("/c.sock", pi.descriptor.path)
  end)

  it("self-initializes config when setup() was not called (no error)", function()
    pi.config = nil             -- simulate user never calling setup()
    vim.env.PI_NVIM_BRIDGE = valid_desc()
    local r = pi.activate()
    assert.is_not_nil(r)
    assert.is_not_nil(pi.config)          -- setup({}) ran inside activate()
    assert.are.equals("pi-prompt", vim.bo[0].filetype)
  end)

  -- === S39 — the one-time notify on hard failure (handshake-failure surface) ===
  -- The bridge handshake runs async + pcall-wrapped in activate(); on a connect
  -- refused / bad-token / timeout it calls the S39 handshake cb which fires a SINGLE
  -- dedup'd notify.once("bridge", …). pi.bridge stays nil (silent degrade).

  it("bad socket path -> activate() fires ONE notify, pi.bridge stays nil", function()
    local path = "/tmp/pi-bridge-NOPE-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
    os.remove(path) -- ensure non-existent
    vim.env.PI_NVIM_BRIDGE = '{"transport":"unix","path":"' .. path
      .. '","token":"t","pid":1,"cwd":"/p","fdAvailable":true,"serverVersion":"0.1.0"}'
    local r = pi.activate()
    assert.is_not_nil(r) -- activated (valid unix descriptor) — the handshake fails async
    -- the handshake connect fails ENOENT -> handshake cb -> notify.once("bridge", …)
    local notify = require("pi-bridge.notify")
    vim.wait(500, function() return notify.did_notify("bridge") end, 5)
    assert.is_true(notify.did_notify("bridge"), "a bad-socket handshake must fire ONE notify")
    assert.is_nil(pi.bridge, "pi.bridge must stay nil after a failed handshake")
  end)

  it("dormant (no env var) -> NO notify ever", function()
    local notify = require("pi-bridge.notify")
    local r = pi.activate()
    assert.is_nil(r)
    vim.wait(50) -- give any (must-not-exist) scheduled notify a chance
    assert.is_false(notify.did_notify(), "dormant must NEVER notify")
  end)

  it("dedup: a second activate()-time failure does not re-notify", function()
    local path = "/tmp/pi-bridge-NOPE2-" .. tostring(os.time()) .. "-" .. math.random(1e6) .. ".sock"
    os.remove(path)
    local desc = '{"transport":"unix","path":"' .. path
      .. '","token":"t","pid":1,"cwd":"/p","fdAvailable":true,"serverVersion":"0.1.0"}'
    local notify = require("pi-bridge.notify")
    -- stub vim.notify to COUNT actual toasts (the dedup collapses to one)
    local calls = 0
    local orig = vim.notify
    vim.notify = function(_msg, _level, _opts) calls = calls + 1 end
    vim.env.PI_NVIM_BRIDGE = desc
    pi.activate()
    -- wait for the dedup flag (set synchronously in once()) AND for the scheduled toast
    vim.wait(500, function() return notify.did_notify("bridge") end, 5)
    vim.wait(300, function() return calls >= 1 end, 5) -- flush the 1st scheduled toast
    local first = calls
    -- a second activate() (the gate re-runs the handshake) must NOT add a second toast
    package.loaded["pi-bridge"] = nil
    pi = require("pi-bridge")
    vim.env.PI_NVIM_BRIDGE = desc
    pi.activate()
    vim.wait(300, function() return calls > first end, 5)
    assert.are.equals(first, calls, "a second failure must NOT re-notify (dedup by category)")
    vim.notify = orig
  end)
end)
