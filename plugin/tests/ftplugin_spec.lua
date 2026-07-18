-- === plugin/tests/ftplugin_spec.lua — plenary/busted spec for ftplugin/pi-prompt.lua ===
-- Level-2 gate. Covers every Success Criterion in the PRP.
-- Run from the plugin/ directory:
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/ftplugin_spec.lua")'

describe("pi-editor ftplugin/pi-prompt", function()
  -- before_each: start each test from a clean module + config state so the filetype set
  -- re-sources the ftplugin against the current resolved config (autosave_on_exit etc.).
  before_each(function()
    package.loaded["pi-editor"] = nil
    require("pi-editor")
  end)

  -- helper: make a fresh scratch buffer the current and set filetype=pi-prompt (sources ftplugin).
  local function fresh_prompt_buf()
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(b)
    vim.bo[b].formatoptions = "tcqj"   -- deterministic baseline (t present)
    vim.bo[b].textwidth = 80
    vim.bo[b].filetype = "pi-prompt"   -- -> sources ftplugin/pi-prompt.lua
    return b
  end

  it("is auto-sourced on filetype=pi-prompt (textwidth applied)", function()
    local b = fresh_prompt_buf()
    assert.are.equals(0, vim.bo[b].textwidth)
  end)

  it("removes the 't' flag from formatoptions", function()
    local b = fresh_prompt_buf()
    assert.is_false(string.find(vim.bo[b].formatoptions or "", "t") ~= nil)
  end)

  it("sets wrap=true, spell=false", function()
    local _ = fresh_prompt_buf()
    assert.is_true(vim.wo[0].wrap)
    assert.is_false(vim.wo[0].spell)
  end)

  it("registers the 6 insert keymaps with 'pi-editor:' desc", function()
    local b = fresh_prompt_buf()
    local kms = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, "i")) do kms[m.lhs] = m.desc end
    for _, k in ipairs({ "<Tab>", "<S-Tab>", "<C-N>", "<C-P>", "<C-E>", "<CR>" }) do
      -- NOTE: use `sub` not `find("^pi-editor:")` — `-` is a Lua pattern metachar so the
      -- anchored find silently fails. `sub(1,11) == "pi-editor: " is literal & robust.
      assert.is_truthy(kms[k], "missing keymap " .. k)
      assert.is_truthy(kms[k]:sub(1, 11) == "pi-editor: ", "bad desc for " .. k)
    end
  end)

  it("registers completion autocmds (InsertEnter/TextChangedI/CursorMovedI)", function()
    local b = fresh_prompt_buf()
    local evs = {}
    for _, a in ipairs(vim.api.nvim_get_autocmds({ buffer = b, group = "pi-editor" })) do evs[a.event] = true end
    for _, ev in ipairs({ "InsertEnter", "TextChangedI", "CursorMovedI" }) do
      assert.is_true(evs[ev], "missing autocmd " .. ev)
    end
  end)

  it("registers VimLeavePre/ExitPre autosave autocmds by default", function()
    local b = fresh_prompt_buf()
    local evs = {}
    for _, a in ipairs(vim.api.nvim_get_autocmds({ buffer = b, group = "pi-editor" })) do evs[a.event] = true end
    assert.is_true(evs["VimLeavePre"])
    assert.is_true(evs["ExitPre"])
  end)

  it("skips exit autocmds when autosave_on_exit=false", function()
    package.loaded["pi-editor"] = nil
    local pi = require("pi-editor"); pi.setup({ autosave_on_exit = false })
    local b = fresh_prompt_buf()
    local evs = {}
    for _, a in ipairs(vim.api.nvim_get_autocmds({ buffer = b, group = "pi-editor" })) do evs[a.event] = true end
    assert.is_nil(evs["VimLeavePre"])
    assert.is_nil(evs["ExitPre"])
  end)

  it("does not throw when firing completion autocmds with completion.lua absent", function()
    local b = fresh_prompt_buf()
    assert.has_no.errors(function()
      vim.api.nvim_exec_autocmds("TextChangedI", { buffer = b })
      vim.api.nvim_exec_autocmds("InsertEnter", { buffer = b })
    end)
  end)

  it("does not touch a sibling buffer", function()
    local b1 = fresh_prompt_buf()
    local b2 = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(b2)
    assert.are_not_equals("pi-prompt", vim.bo[b2].filetype)
    local n = 0
    for _ in ipairs(vim.api.nvim_buf_get_keymap(b2, "i")) do n = n + 1 end
    assert.are.equals(0, n)   -- sibling has no pi-editor keymaps
    _ = b1
  end)

  it("is idempotent on re-source (no duplicate autocmds)", function()
    local b = fresh_prompt_buf()
    local function cnt()
      local n = 0
      for _ in ipairs(vim.api.nvim_get_autocmds({ buffer = b, group = "pi-editor" })) do n = n + 1 end
      return n
    end
    local before = cnt()
    vim.bo[b].filetype = ""        -- reset
    vim.bo[b].filetype = "pi-prompt"  -- re-source
    assert.are.equals(before, cnt())
  end)

  it("preserves S20's VimEnter autocmd in the shared group", function()
    fresh_prompt_buf()
    local ve = vim.api.nvim_get_autocmds({ event = "VimEnter", group = "pi-editor" })
    assert.is_true(#ve >= 1)
  end)
end)