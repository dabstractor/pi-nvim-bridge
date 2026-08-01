-- === tests/init_warm_on_enter_spec.lua — plenary/busted spec (the Level-2 gate, P2.M3.T6.S1) ===
-- Verifies the §17.11 warm_on_enter behavior driven from activate():
--   (1) warm_on_enter = true  + valid PI_NVIM_BRIDGE blob + fake driver → shell.ensure called once.
--   (2) warm_on_enter = false (default)                          → shell.ensure NOT called.
--   (3) enabled = false (master switch) gates warming            → shell.ensure NOT called.
--   (4) dormant (no PI_NVIM_BRIDGE)                              → shell.ensure NOT called (early return).
--   (5) warm spawn FAILURE → activate does NOT throw; shell.lua S4 emits "shell-degrade".
--   (6) warm path NEVER throws even if shell.ensure itself throws (pcall swallows).
--   (7) after a warm activate, pi.descriptor is non-nil (warm runs on the success path).
--
-- Harness REUSES tests/shell_ensure_spec.lua's fake_bridge + make_fake_driver + the
-- save/restore discipline, and ADDS: PI_NVIM_BRIDGE env-var save/restore, the ensure-call
-- spy (wrap, don't replace), + pi.descriptor reset.
--
-- NOTE: do NOT name a spec-local table `pending` (shadows plenary.busted's skip fn).
--
-- Run (from the repo root):
--   timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/init_warm_on_enter_spec.lua")'
local pi = require("pi-bridge")
local shell = require("pi-bridge.shell")
local notify = require("pi-bridge.notify")

if pi.config == nil then pi.setup({}) end -- self-sufficient

-- --- a fake bridge exposing get_shell_info (resolve_shell's prefer:"pi" source) ---
local function fake_bridge(shell_path)
	return {
		get_shell_info = function()
			if shell_path == nil then return nil end
			return { shell = shell_path }
		end,
		server_info = {},
	}
end

-- --- the fake driver (mirrors tests/shell_ensure_spec.lua make_fake_driver): synchronous
-- start cb so ensure completes within the call (no vim.wait needed for the spawn itself).
local function make_fake_driver()
	local captured = { calls = 0 }
	local function fake_pipe()
		return {
			read_start = function() end,
			write = function() end,
			close = function() end,
			read_stop = function() end,
			is_closing = function() return false end,
		}
	end
	return {
		captured = captured,
		start = function(opts, cb)
			captured.calls = captured.calls + 1
			if opts._fail then
				cb("spawn err: simulated", nil, nil, nil)
			else
				cb(nil, { is_closing = function() return false end }, fake_pipe(), fake_pipe())
			end
		end,
	}
end

-- --- a valid PI_NVIM_BRIDGE blob (transport=unix; §17.10 shell included for prefer:"pi") ---
local function blob(shell_path)
	return vim.json.encode({
		transport = "unix",
		path = "/tmp/fake.sock",
		token = "t",
		pid = 1,
		cwd = "/tmp",
		fdAvailable = true,
		serverVersion = "0.0.1",
		shell = shell_path,
		shellSource = "pi",
	})
end

-- === spec-wide state we swap per-case (restored in after_each) ===
local orig_ensure, orig_env, orig_bridge, orig_desc, orig_shell_cfg, ensure_calls

describe("pi-bridge warm_on_enter (P2.M3.T6.S1)", function()
	before_each(function()
		-- save the globals the spec swaps
		orig_ensure = shell.ensure
		orig_env = vim.env.PI_NVIM_BRIDGE
		orig_bridge = pi.bridge
		orig_desc = pi.descriptor
		orig_shell_cfg = (pi.config and pi.config.shell) or nil
		-- fresh baseline
		vim.env.PI_NVIM_BRIDGE = nil
		pi.bridge = nil
		pi.descriptor = nil
		notify.reset()
		shell.reset()
		package.loaded["pi-bridge.shell.fish"] = nil
		-- the ensure-call spy: wrap, don't replace (so shell.lua's real lifecycle still runs)
		ensure_calls = 0
		shell.ensure = function(cb)
			ensure_calls = ensure_calls + 1
			return orig_ensure(cb)
		end
	end)
	after_each(function()
		-- restore everything (order: spy first so later cases get the real ensure back)
		shell.ensure = orig_ensure
		vim.env.PI_NVIM_BRIDGE = orig_env
		pi.bridge = orig_bridge
		pi.descriptor = orig_desc
		if pi.config then pi.config.shell = orig_shell_cfg end
		package.loaded["pi-bridge.shell.fish"] = nil
		notify.reset()
		shell.reset()
	end)

	it("warm_on_enter=true + blob + fake driver → ensure called exactly once", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		pi.setup({ shell = { warm_on_enter = true } })
		vim.env.PI_NVIM_BRIDGE = blob("/usr/bin/fish")
		pi.activate()
		assert.are.equals(1, ensure_calls, "warm_on_enter=true → ensure called once")
	end)

	it("warm_on_enter=false (default) → ensure NOT called (lazy on first `!`)", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		pi.setup({}) -- default: warm_on_enter=false
		vim.env.PI_NVIM_BRIDGE = blob("/usr/bin/fish")
		pi.activate()
		assert.are.equals(0, ensure_calls, "default warm_on_enter=false → ensure NOT called")
	end)

	it("enabled=false gates warming even when warm_on_enter=true", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		pi.setup({ shell = { warm_on_enter = true, enabled = false } })
		vim.env.PI_NVIM_BRIDGE = blob("/usr/bin/fish")
		pi.activate()
		assert.are.equals(0, ensure_calls, "enabled=false (master switch) gates warming")
	end)

	it("dormant (no PI_NVIM_BRIDGE env var) → ensure NOT called (activate returns early)", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		pi.setup({ shell = { warm_on_enter = true } })
		-- vim.env.PI_NVIM_BRIDGE is nil (before_each baseline)
		local r = pi.activate()
		assert.is_nil(r, "dormant → activate returns nil")
		assert.are.equals(0, ensure_calls, "dormant → warm block never reached")
	end)

	it("warm spawn FAILURE → activate does NOT throw; shell.lua S4 emits shell-degrade", function()
		-- a driver whose start cb reports a spawn error → ensure sets failed + S4 emits the
		-- §17.12 "shell-degrade" notice. activate() must NOT throw + must NOT add its own notify.
		local failfake = make_fake_driver()
		failfake.start = function(opts, cb) cb("spawn err: simulated", nil, nil, nil) end
		package.loaded["pi-bridge.shell.fish"] = failfake
		pi.bridge = fake_bridge("/usr/bin/fish")
		pi.setup({ shell = { warm_on_enter = true } })
		vim.env.PI_NVIM_BRIDGE = blob("/usr/bin/fish")
		local r
		assert.has_no.errors(function() r = pi.activate() end)
		assert.is_not_nil(r, "activate returns the descriptor even on warm failure")
		assert.are.equals(1, ensure_calls, "ensure WAS called (the warm path ran)")
		-- shell.lua S4 emits the degrade notice (vim.schedule'd → flush before asserting)
		vim.wait(300, function() return notify.did_notify("shell-degrade") end, 5)
		assert.is_true(notify.did_notify("shell-degrade"), "shell.lua S4 owns the degrade notice")
	end)

	it("warm path NEVER throws even if shell.ensure itself throws (pcall swallows)", function()
		pi.setup({ shell = { warm_on_enter = true } })
		vim.env.PI_NVIM_BRIDGE = blob("/usr/bin/fish")
		-- replace the spy with a THROWING stub (the warm pcall must swallow it)
		shell.ensure = function() error("boom") end
		local r
		assert.has_no.errors(function() r = pi.activate() end)
		assert.is_not_nil(r, "activate still returns the descriptor (warm throw was swallowed)")
	end)

	it("warm runs on the success path: pi.descriptor is set after a warm activate", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		pi.setup({ shell = { warm_on_enter = true } })
		vim.env.PI_NVIM_BRIDGE = blob("/usr/bin/fish")
		pi.activate()
		assert.is_not_nil(pi.descriptor, "warm runs AFTER descriptor is set (success path)")
		assert.are.equals("/usr/bin/fish", pi.descriptor.shell)
	end)
end)