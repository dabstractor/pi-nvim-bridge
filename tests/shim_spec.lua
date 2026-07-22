-- === tests/shim_spec.lua — the spec (covers every Success Criterion) ===
-- Run (from the repo root):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shim_spec.lua")'
describe("pi-bridge VimEnter shim", function()
  local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  local shim_rel = "plugin/pi-bridge.lua"            -- runtimepath-relative

  before_each(function()
    -- fresh module each test (activate is nil on a fresh require)
    package.loaded["pi-bridge"] = nil
    require("pi-bridge")
    -- fresh once-autocmd each test (clear=true wipes + re-adds — GOTCHA #5/#6)
    vim.cmd("runtime " .. shim_rel)
    vim.g.pi_calls = 0
  end)

  local function vims()
    return vim.api.nvim_get_autocmds({ event = "VimEnter", group = "pi-bridge" })
  end

  it("registers exactly one fire-once VimEnter autocmd in the pi-bridge group", function()
    local a = vims()
    assert.are.equals(1, #a)
    assert.is_true(a[1].once)
    assert.are.equals("pi-bridge", a[1].group_name)
    assert.are.equals("function", type(a[1].callback))
  end)

  it("calls activate() exactly once when VimEnter fires once", function()
    require("pi-bridge").activate = function() vim.g.pi_calls = vim.g.pi_calls + 1 end
    vim.api.nvim_exec_autocmds("VimEnter", {})
    assert.are.equals(1, vim.g.pi_calls)
  end)

  it("does not call activate twice when VimEnter fires twice (once=true)", function()
    require("pi-bridge").activate = function() vim.g.pi_calls = vim.g.pi_calls + 1 end
    vim.api.nvim_exec_autocmds("VimEnter", {})
    vim.api.nvim_exec_autocmds("VimEnter", {})
    assert.are.equals(1, vim.g.pi_calls)
  end)

  it("degrades silently when activate is absent (no error, stays dormant)", function()
    -- activate is nil on the fresh require from before_each
    assert.has_no.errors(function()
      vim.api.nvim_exec_autocmds("VimEnter", {})
    end)
    assert.are.equals(0, vim.g.pi_calls)
  end)

  it("is idempotent under re-source (clear=true prevents duplicate autocmds)", function()
    vim.cmd("runtime " .. shim_rel)
    vim.cmd("runtime " .. shim_rel)
    assert.are.equals(1, #vims())
  end)

  it("contains the required structural tokens and does not read the environment", function()
    -- Robust literals only. The doc-comment header mentions "PI_NVIM_BRIDGE"/"setup()"
    -- by name to explain they are NOT used here, so a naive "does NOT contain those words"
    -- search would FALSE-POSITIVE on the comment. Instead: assert no env access
    -- (vim.env / os.getenv) + presence of the structural tokens. (No-setup-call /
    -- no-bridge-require are code-inspection checklist items — see Final Validation Checklist.)
    local src = table.concat(vim.fn.readfile(plugin_root .. "/plugin/pi-bridge.lua"), "\n")
    assert.is_true(src:find('nvim_create_autocmd("VimEnter"', 1, true) ~= nil)
    assert.is_true(src:find("once = true", 1, true) ~= nil)
    assert.is_true(src:find("clear = true", 1, true) ~= nil)
    assert.is_nil(src:find("vim.env", 1, true))   -- no env read (PI_NVIM_BRIDGE is S21)
    assert.is_nil(src:find("getenv", 1, true))    -- no os.getenv (S21)
  end)
end)
