-- === tests/init_spec.lua — the spec (covers every Success Criterion) ===
describe("pi-bridge.setup", function()
  local pi

  before_each(function()
    package.loaded["pi-bridge"] = nil   -- force a fresh module per test
    pi = require("pi-bridge")
  end)

  it("exposes a module table with setup()", function()
    assert.are.equals("table", type(pi))
    assert.are.equals("function", type(pi.setup))
  end)

  it("ships the pi-faithful defaults (debounce_ms=20 supersedes PRD §10.5's 25; editor.ts:236)", function()
    assert.are.same({ max_height = 12, border = "rounded" }, pi.defaults.menu)
    assert.are.equals(20, pi.defaults.debounce_ms)   -- S40: pi ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS (was 25)
    assert.are.equals(2000, pi.defaults.rpc_timeout_ms) -- S40: MUST exceed server fd-abort 1500
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
    assert.are.equals(20, pi.defaults.debounce_ms)  -- S40: was 25
    assert.are.equals(12, pi.defaults.menu.max_height)
    assert.are.equals("rounded", pi.defaults.menu.border)
  end)

  it("re-calling setup() re-merges and overwrites config", function()
    pi.setup({ debounce_ms = 10 })
    assert.are.equals(10, pi.config.debounce_ms)
    pi.setup({ debounce_ms = 70 })
    assert.are.equals(70, pi.config.debounce_ms)
    assert.are.equals(20, pi.defaults.debounce_ms)         -- S40: defaults still pristine (was 25)
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

  -- S40: document the trigger-aware debounce model — slash/typing use 0 ms (pi-faithful).
  it("documents the trigger-aware debounce model (slash/typing use 0 ms; @/# use debounce_ms)", function()
    -- the @---@field debounce_ms doc states the pi-faithful semantics; verify the shipped
    -- default + the (testable) completion.is_attachment_context mirror the model.
    assert.are.equals(20, pi.defaults.debounce_ms)
    local completion = require("pi-bridge.completion")
    assert.are.equals("function", type(completion.is_attachment_context))
    assert.is_true(completion.is_attachment_context("@src"))   -- attachment → debounce_ms
    assert.is_false(completion.is_attachment_context("/mod"))  -- slash → 0 ms (immediate)
    assert.is_false(completion.is_attachment_context("hello")) -- typing → 0 ms (immediate)
  end)

  -- === P2.M3.T6.S1 — the §17.11 shell-config block (defaults + deep-merge + no-mutation) ===
  local shell_defaults = {
    enabled            = true,
    prefer             = "pi",
    drivers            = { fish = true, zsh = true, bash = true },
    warm_on_enter      = false,
    timeout_ms         = 1500,
    startup_timeout_ms = 5000,
    visual_cue         = "gutter",
    debounce_ms        = 0,
    max_parse_failures = 5,
  }

  it("ships the §17.11 shell defaults in M.defaults", function()
    assert.are.same(shell_defaults, pi.defaults.shell)
  end)

  it("setup({}) stores the §17.11 shell defaults verbatim in config.shell", function()
    pi.setup({})
    assert.are.same(shell_defaults, pi.config.shell)
  end)

  it("nested shell deep-merges: override timeout_ms, keep prefer (sibling preserved)", function()
    pi.setup({ shell = { timeout_ms = 3000 } })
    assert.are.equals(3000, pi.config.shell.timeout_ms)
    assert.are.equals("pi", pi.config.shell.prefer)         -- default sibling preserved
  end)

  it("nested shell.drivers deep-merges: disable bash, keep fish/zsh", function()
    pi.setup({ shell = { drivers = { bash = false } } })
    assert.is_false(pi.config.shell.drivers.bash)
    assert.is_true(pi.config.shell.drivers.fish)             -- default sibling preserved
    assert.is_true(pi.config.shell.drivers.zsh)              -- default sibling preserved
  end)

  it("warm_on_enter defaults to false (lazy on first `!`)", function()
    pi.setup({})
    assert.is_false(pi.config.shell.warm_on_enter)
  end)

  it("warm_on_enter override wins", function()
    pi.setup({ shell = { warm_on_enter = true } })
    assert.is_true(pi.config.shell.warm_on_enter)
  end)

  it("does NOT mutate M.defaults.shell after a setup with overrides", function()
    pi.setup({ shell = { timeout_ms = 1 } })
    assert.are.equals(1500, pi.defaults.shell.timeout_ms)    -- pristine
    assert.is_false(pi.defaults.shell.warm_on_enter)         -- pristine
  end)

  it("setup(nil) / setup({}) leaves shell at the §17.11 defaults", function()
    pi.setup(nil)
    assert.are.same(shell_defaults, pi.config.shell)
    pi.setup({})
    assert.are.same(shell_defaults, pi.config.shell)
  end)

  it("setup({ shell = false }) does not throw (deep-merge coercion; downstream `or {}` keeps it safe)", function()
    -- vim.tbl_deep_extend("force", {shell={...}}, {shell=false}) → config.shell == false (boolean).
    -- setup() NEVER throws (the S1 invariant). Downstream shell.lua/completion.lua read
    -- `(pi.config and pi.config.shell) or {}` → `false or {}` → `{}` → safe defaults.
    -- No guard is added (mirrors the menu pattern; only a THROW would warrant one).
    assert.has_no.errors(function() pi.setup({ shell = false }) end)
    assert.is_false(pi.config.shell)                         -- the documented actual behavior
    -- M.defaults.shell stays pristine (deep-merge does not mutate the source)
    assert.are.same(shell_defaults, pi.defaults.shell)
  end)
end)
