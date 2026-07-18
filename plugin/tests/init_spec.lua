-- === plugin/tests/init_spec.lua — the spec (covers every Success Criterion) ===
describe("pi-editor.setup", function()
  local pi

  before_each(function()
    package.loaded["pi-editor"] = nil   -- force a fresh module per test
    pi = require("pi-editor")
  end)

  it("exposes a module table with setup()", function()
    assert.are.equals("table", type(pi))
    assert.are.equals("function", type(pi.setup))
  end)

  it("ships the exact PRD §10.5 defaults", function()
    assert.are.same({ max_height = 12, border = "rounded" }, pi.defaults.menu)
    assert.are.equals(25, pi.defaults.debounce_ms)
    assert.are.equals(2000, pi.defaults.rpc_timeout_ms)
    assert.is_true(pi.defaults.autosave_on_exit)
    assert.are.equals("builtin", pi.defaults.engine)
  end)

  it("config is nil before setup()", function()
    assert.is_nil(pi.config)
  end)

  it("setup({}) stores defaults verbatim in config", function()
    pi.setup({})
    assert.is_not_nil(pi.config)
    assert.are.same(pi.defaults, pi.config)
  end)

  it("setup(nil) does not error (the opts-or-{} guard)", function()
    assert.has_no.errors(function() pi.setup(nil) end)
    assert.are.same(pi.defaults, pi.config)
  end)

  it("scalar overrides win and un-overridden defaults are preserved", function()
    pi.setup({ debounce_ms = 99, rpc_timeout_ms = 5000, engine = "blink" })
    assert.are.equals(99, pi.config.debounce_ms)
    assert.are.equals(5000, pi.config.rpc_timeout_ms)
    assert.are.equals("blink", pi.config.engine)
    assert.is_true(pi.config.autosave_on_exit)             -- default preserved
    assert.are.same({ max_height = 12, border = "rounded" }, pi.config.menu) -- default preserved
  end)

  it("a user 'false' overrides a default 'true' (autosave_on_exit)", function()
    pi.setup({ autosave_on_exit = false })
    assert.is_false(pi.config.autosave_on_exit)
  end)

  it("nested menu deep-merges: override one key, keep the sibling", function()
    pi.setup({ menu = { max_height = 40 } })
    assert.are.equals(40, pi.config.menu.max_height)
    assert.are.equals("rounded", pi.config.menu.border)    -- default sibling preserved
  end)

  it("nested menu deep-merges: override the other key too", function()
    pi.setup({ menu = { border = "none" } })
    assert.are.equals("none", pi.config.menu.border)
    assert.are.equals(12, pi.config.menu.max_height)       -- default sibling preserved
  end)

  it("does NOT mutate M.defaults after a setup with overrides", function()
    pi.setup({ debounce_ms = 1, menu = { max_height = 99 } })
    assert.are.equals(25, pi.defaults.debounce_ms)
    assert.are.equals(12, pi.defaults.menu.max_height)
    assert.are.equals("rounded", pi.defaults.menu.border)
  end)

  it("re-calling setup() re-merges and overwrites config", function()
    pi.setup({ debounce_ms = 10 })
    assert.are.equals(10, pi.config.debounce_ms)
    pi.setup({ debounce_ms = 70 })
    assert.are.equals(70, pi.config.debounce_ms)
    assert.are.equals(25, pi.defaults.debounce_ms)         -- defaults still pristine
  end)

  it("exposes M.bridge as a nil placeholder (PRD §7.7)", function()
    pi.setup({})
    assert.is_nil(pi.bridge)
  end)

  it("setup() returns the merged config (same ref as M.config)", function()
    local cfg = pi.setup({ debounce_ms = 33 })
    assert.are.equals(33, cfg.debounce_ms)
    assert.are.equals(cfg, pi.config)                      -- shallow: same table object
  end)
end)
