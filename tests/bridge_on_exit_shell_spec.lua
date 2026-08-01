-- === tests/bridge_on_exit_shell_spec.lua — plenary/busted spec (P2.M3.T6.S3) ===
-- Regression gate for the §17 completion-daemon teardown wiring: proves bridge.on_exit(buf)
-- invokes shell.teardown() (P2.M3.T6.S3), mirroring the discipline of bridge_on_exit_spec.lua
-- (S38) + the package.loaded fake-injection idiom proven in shell_teardown_spec.lua (S6).
--
-- Scope (the WIRING ONLY — teardown's own idempotency / leak-proofing is shell_teardown_spec's
-- job; we do NOT re-prove it here). This spec asserts:
--   (a) on_exit calls shell.teardown() exactly ONCE per call (spied via a package.loaded fake).
--   (b) a second on_exit (the ExitPre→VimLeavePre double-fire) calls teardown a SECOND time
--       (the wiring fires on every exit; idempotency of the *effect* is shell.teardown's job,
--       already proven in shell_teardown_spec.lua — here we only assert the wiring fires).
--   (c) on_exit NEVER throws (a throwing teardown cannot abort exit — pcall-guarded step (4)).
--   (d) on_exit fires teardown EVEN when never connected (the daemon path is INDEPENDENT of the
--       bridge socket — PRD §17.13; never-connected is the common "the user never hit a !-line"
--       no-op case where teardown must still be a safe no-op wiring).
--
-- Approach: inject an INSTRUMENTED fake into package.loaded["pi-bridge.shell"] BEFORE requiring
-- bridge (so bridge.on_exit's lazy `pcall(require, "pi-bridge.shell")` resolves OUR fake). The
-- fake is `{ teardown = spy, get_shell_info = function() end }` where `spy` increments a
-- counter. package.loaded is RESTORED in after_each so other specs see the REAL module.
--
-- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global `pending`
-- (the test-SKIP function). We use `calls` locals.
--
-- Run (from the repo root, AGENTS.md plenary runner):
--   timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/bridge_on_exit_shell_spec.lua")'

-- Build an instrumented fake for package.loaded["pi-bridge.shell"]. The teardown spy counts
-- its invocations so the spec can assert call counts. get_shell_info is included for parity
-- with the real module shape (bridge never calls it from on_exit, but cheap to include).
local function fake_shell()
  local calls = { teardown = 0 }
  return {
    calls = calls, -- exported so the spec can read it without capturing the closure
    teardown = function()
      calls.teardown = calls.teardown + 1
    end,
    get_shell_info = function() return nil end,
  }
end

-- Install the fake into package.loaded BEFORE requiring bridge (so the lazy require inside
-- on_exit resolves OUR instrumented module, never the real one). Returns the fake for
-- in-test observation. Pairs with restore_shell() in after_each.
local saved_shell
local function install_fake_shell()
  saved_shell = package.loaded["pi-bridge.shell"]
  local fake = fake_shell()
  package.loaded["pi-bridge.shell"] = fake
  return fake
end

local function restore_shell()
  if saved_shell == nil then
    package.loaded["pi-bridge.shell"] = nil -- was absent before we touched it
  else
    package.loaded["pi-bridge.shell"] = saved_shell
  end
  saved_shell = nil
end

describe("bridge.on_exit → shell.teardown wiring (P2.M3.T6.S3)", function()
  local bridge
  local tmp_paths = {}

  before_each(function()
    -- Inject the fake shell FIRST so the subsequent `require("pi-bridge.bridge")` (and the
    -- lazy require inside on_exit) resolve our instrumented module.
    install_fake_shell()
    -- Force a fresh require of bridge so it never inherits a previously-cached reference
    -- whose on_exit might have captured a different module graph (defense in depth; the
    -- wiring is lazy, so this is belt-and-suspenders).
    package.loaded["pi-bridge.bridge"] = nil
    bridge = require("pi-bridge.bridge")
    local pi = require("pi-bridge")
    if pi.config == nil then pi.setup({}) end -- self-sufficient (mirror bridge_on_exit_spec GOTCHA D)
    -- ensure a clean transport slate (never connected in these cases)
    pcall(function() bridge.close() end)
  end)

  after_each(function()
    for _, p in ipairs(tmp_paths) do os.remove(p) end
    tmp_paths = {}
    pcall(function() bridge.close() end)
    restore_shell()
    -- drop the bridge require cache so a later spec / suite re-requires fresh
    package.loaded["pi-bridge.bridge"] = nil
  end)

  -- (a) on_exit calls shell.teardown() exactly ONCE per call (the core wiring assertion).
  it("calls shell.teardown() exactly once per on_exit invocation", function()
    local buf = vim.api.nvim_create_buf(true, false) -- unnamed scratch; autosave no-ops, that's fine
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "irrelevant" })
    local fake = package.loaded["pi-bridge.shell"]
    assert.are.equals(0, fake.calls.teardown, "precondition: teardown not yet called")
    assert.has_no.errors(function() bridge.on_exit(buf) end)
    assert.are.equals(1, fake.calls.teardown, "on_exit must call shell.teardown exactly ONCE")
  end)

  -- (b) double-fire (ExitPre then VimLeavePre) calls teardown TWICE — the wiring fires on
  --     every exit; idempotency of the *effect* is shell.teardown's own job (proven in
  --     shell_teardown_spec.lua). Here we only assert the wiring is not gated off on a 2nd fire.
  it("double-fire (ExitPre+VimLeavePre) calls teardown on BOTH fires", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x" })
    local fake = package.loaded["pi-bridge.shell"]
    assert.has_no.errors(function() bridge.on_exit(buf) end)
    assert.has_no.errors(function() bridge.on_exit(buf) end)
    assert.are.equals(2, fake.calls.teardown, "wiring fires teardown on EACH on_exit (2 fires → 2 calls)")
  end)

  -- (c) on_exit NEVER throws even if shell.teardown throws (the outer pcall + inner
  --     type-guard must shield exit). This proves the "never aborts exit" guarantee of step (4).
  it("never throws even when shell.teardown raises", function()
    package.loaded["pi-bridge.shell"] = {
      teardown = function() error("boom: simulated teardown failure") end,
      get_shell_info = function() return nil end,
    }
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "y" })
    assert.has_no.errors(function() bridge.on_exit(buf) end,
      "a throwing shell.teardown must NOT abort exit (outer pcall guards it)")
  end)

  -- (d) on_exit fires teardown EVEN when never connected (the daemon path is INDEPENDENT of
  --     the bridge socket — PRD §17.13). This is the common "user never hit a !-line" case:
  --     the daemon was never spawned, teardown is a safe no-op wiring, but it MUST still be
  --     invoked (proving the wiring is not gated on is_connected()).
  it("fires shell.teardown even when never connected (daemon path independent of bridge socket)", function()
    pcall(function() bridge.close() end)
    assert.is_false(bridge.is_connected(), "precondition: not connected")
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "z" })
    local fake = package.loaded["pi-bridge.shell"]
    assert.are.equals(0, fake.calls.teardown)
    assert.has_no.errors(function() bridge.on_exit(buf) end)
    assert.are.equals(1, fake.calls.teardown,
      "on_exit must fire shell.teardown even when never connected (independent of bridge socket)")
  end)

  -- (e) defensive: on_exit is a safe no-op when shell.teardown is ABSENT (the type-guard
  --     `type(shell.teardown)=="function"` short-circuits). Free future-proofing for a
  --     half-loaded module; mirrors the S5 forward-guard idiom.
  it("is a safe no-op when the resolved shell module lacks a teardown function", function()
    package.loaded["pi-bridge.shell"] = { get_shell_info = function() return nil end } -- no teardown
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "w" })
    assert.has_no.errors(function() bridge.on_exit(buf) end,
      "absent shell.teardown must not throw (type-guard short-circuits the call)")
  end)

  -- (f) defensive: on_exit is a safe no-op when require("pi-bridge.shell") itself fails
  --     (the INNER pcall guards a broken/missing module). Belt-and-suspenders.
  it("is a safe no-op when require('pi-bridge.shell') itself errors", function()
    package.loaded["pi-bridge.shell"] = nil -- drop any cache
    -- Install a shim package loader that makes the require throw.
    local loader_err = "simulated broken shell module"
    local shim = function() return error(loader_err) end
    package.loaders = package.loaders or package.searchers or {}
    table.insert(package.loaders, 1, function(modname)
      if modname == "pi-bridge.shell" then return shim end
    end)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "v" })
    local ok = pcall(function() bridge.on_exit(buf) end)
    -- remove the shim loader regardless of outcome
    for i = #package.loaders, 1, -1 do
      if package.loaders[i] == shim then table.remove(package.loaders, i); break end
    end
    assert.is_true(ok, "a failing require must NOT abort exit (inner pcall guards it)")
  end)

  -- (g) sanity: on_exit handles a non-number / invalid buf without throwing (autosave guard
  --     short-circuits; teardown still fires). Mirrors bridge_on_exit_spec.lua's (d) case.
  it("does not throw on an invalid buf handle and still fires teardown", function()
    local fake = package.loaded["pi-bridge.shell"]
    assert.has_no.errors(function() bridge.on_exit(999999) end)
    assert.has_no.errors(function() bridge.on_exit(nil) end)
    assert.has_no.errors(function() bridge.on_exit("x") end)
    assert.are.equals(3, fake.calls.teardown,
      "teardown fires on EACH on_exit regardless of buf validity (independent step)")
  end)
end)