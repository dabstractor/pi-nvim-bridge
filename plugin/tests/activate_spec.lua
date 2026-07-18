-- === plugin/tests/activate_spec.lua — the spec (covers every Success Criterion) ===
-- Run (from the plugin/ directory):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/activate_spec.lua")'
describe("pi-editor.activate gate", function()
  local pi

  before_each(function()
    package.loaded["pi-editor"] = nil   -- fresh module per test
    pi = require("pi-editor")
    vim.env.PI_EDITOR_BRIDGE = nil      -- clean dormant baseline
    pi.descriptor = nil
    vim.bo[0].filetype = ""             -- deterministic "untouched" assertion
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
    vim.env.PI_EDITOR_BRIDGE = valid_desc()
    local r = pi.activate()
    assert.is_not_nil(r)
    assert.are.equals("/tmp/a.sock", pi.descriptor.path)
    assert.are.equals("unix", pi.descriptor.transport)
    assert.are.equals("t", pi.descriptor.token)
    assert.are.equals("pi-prompt", vim.bo[0].filetype)
  end)

  it("malformed JSON -> dormant, no throw (pcall ok)", function()
    vim.env.PI_EDITOR_BRIDGE = "{not json"
    local ok, r = pcall(pi.activate)
    assert.is_true(ok)          -- proves activate did not throw
    assert.is_nil(r)
    assert.is_nil(pi.descriptor)
  end)

  it("valid-JSON-number (123) -> dormant via the type guard, no throw", function()
    vim.env.PI_EDITOR_BRIDGE = "123"
    local ok, r = pcall(pi.activate)
    assert.is_true(ok)          -- the type() guard prevented desc.transport from throwing
    assert.is_nil(r)
    assert.is_nil(pi.descriptor)
  end)

  it("transport=tcp -> dormant (v1 is Unix-only)", function()
    vim.env.PI_EDITOR_BRIDGE = '{"transport":"tcp","path":"x","token":"t"}'
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
    vim.env.PI_EDITOR_BRIDGE = valid_desc()
    local r = pi.activate()
    assert.is_not_nil(r)
    assert.is_not_nil(pi.config)          -- setup({}) ran inside activate()
    assert.are.equals("pi-prompt", vim.bo[0].filetype)
  end)
end)
