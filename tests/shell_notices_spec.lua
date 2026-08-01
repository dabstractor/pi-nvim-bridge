-- === tests/shell_notices_spec.lua — plenary/busted spec (the Level-2 gate, P2.M2.T3.S4) ===
-- Covers every Success Criterion of shell.lua's NOTICE wiring (the §17.4.3 mismatch
-- notice, the §17.9 first-run hint, the §17.12 degrade notice — each emitted at most
-- once per session via notify.once). MOCKS the bridge (sets require("pi-bridge").bridge
-- = fake) + descriptor + config + injects a FAKE driver into package.loaded (under the
-- basename of the resolved shell) + stubs vim.fn.executable for the mismatch PATH check.
--
-- Reuses the fake_bridge + make_fake_driver + package.loaded injection + before_each/
-- after_each save-restore harness from tests/shell_ensure_spec.lua, ADDING notify.reset()
-- + vim.fn.executable save/restore. NO subprocess.
--
-- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
-- `pending` (the test-SKIP function). We use `got`/`cb` locals.
--
-- Run (from the repo root):
--   timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shell_notices_spec.lua")'
local pi = require("pi-bridge")
local shell = require("pi-bridge.shell")
local notify = require("pi-bridge.notify")

if pi.config == nil then pi.setup({}) end -- self-sufficient (mirror completion_spec.lua L18)

-- --- a fake bridge exposing the surface point ensure/resolve read FRESH:
-- get_shell_info() (controls the resolved shell).
local function fake_bridge(shell_path)
	return {
		get_shell_info = function()
			if shell_path == nil then return nil end
			return { shell = shell_path }
		end,
		server_info = {},
	}
end

-- --- the fake driver + fake pipes (mirrors shell_ensure_spec.lua). `start` calls cb
-- SYNCHRONOUSLY. opts._fail → cb("spawn err: simulated", ...) (the spawn-err case).
local function make_fake_driver()
	local captured = { opts = nil, calls = 0, read_cb = nil }
	local function fake_pipe()
		return {
			read_start = function(_, cb) captured.read_cb = cb end,
			write      = function() end,
			close      = function() end,
			read_stop  = function() end,
			is_closing = function() return false end,
		}
	end
	return {
		captured = captured,
		start = function(opts, cb)
			captured.calls = captured.calls + 1
			captured.opts = opts
			if opts._fail then
				cb("spawn err: simulated", nil, nil, nil)
			else
				cb(nil, { is_closing = function() return false end }, fake_pipe(), fake_pipe())
			end
		end,
	}
end

-- --- INJECT the fake driver under the basename of the resolved shell path so
-- pick_driver(resolved) finds it. Returns the fake for capture assertions.
local function inject_for(resolved_shell_path)
	local base = resolved_shell_path:gsub(".*/", "")
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell." .. base] = fake
	return fake
end

-- --- stub vim.fn.executable: returns 1 for names in `names_true`, 0 otherwise.
-- Returns a restore function.
local function stub_executable(names_true)
	local orig = vim.fn.executable
	local set = {}
	for _, n in ipairs(names_true) do set[n] = true end
	vim.fn.executable = function(name)
		if type(name) ~= "string" then return 0 end
		return set[name] and 1 or 0
	end
	return function() vim.fn.executable = orig end
end

-- --- wait for a notify category to register in the dedup set (did_notify is set
-- synchronously by notify.once BEFORE the vim.schedule flush).
local function wait_notify(category)
	return vim.wait(200, function() return notify.did_notify(category) end, 5)
end

-- --- save/restore the globals the spec swaps per-case.
local orig_shell, orig_bridge, orig_desc, orig_shell_cfg, orig_exec

describe("pi-bridge.shell notices (P2.M2.T3.S4)", function()
	before_each(function()
		orig_shell = vim.env.SHELL
		orig_bridge = pi.bridge
		orig_desc = pi.descriptor
		orig_shell_cfg = (pi.config and pi.config.shell) or nil
		orig_exec = vim.fn.executable
		pi.bridge = nil
		pi.descriptor = nil
		vim.env.SHELL = nil
		for _, base in ipairs({ "fish", "bash", "zsh", "noshell", "unknownshell" }) do
			package.loaded["pi-bridge.shell." .. base] = nil
		end
		notify.reset()
		shell.reset()
	end)
	after_each(function()
		vim.env.SHELL = orig_shell
		pi.bridge = orig_bridge
		pi.descriptor = orig_desc
		for _, base in ipairs({ "fish", "bash", "zsh", "noshell", "unknownshell" }) do
			package.loaded["pi-bridge.shell." .. base] = nil
		end
		if pi.config then pi.config.shell = orig_shell_cfg end
		vim.fn.executable = orig_exec
		notify.reset()
		shell.reset()
		-- drain any pending vim.schedule'd vim.notify from the case (no leak into the next)
		vim.wait(60, function() return false end, 5)
	end)

	-- (1) HAPPY: resolved fish (==$SHELL) → first-run hint, NO mismatch, NO degrade
	it("first-run hint fires (INFO, 'shell-active') on a healthy spawn; no mismatch/degrade", function()
		inject_for("/usr/bin/fish")
		pi.bridge = fake_bridge("/usr/bin/fish")
		vim.env.SHELL = "/usr/bin/fish"
		shell.ensure(function() end)
		assert.is_true(wait_notify("shell-active"), "shell-active fired within vim.wait")
		assert.is_true(notify.did_notify("shell-active"))
		assert.is_false(notify.did_notify("shell-mismatch"), "no mismatch when resolved==$SHELL")
		assert.is_false(notify.did_notify("shell-degrade"), "no degrade on healthy spawn")
	end)

	-- (2) MISMATCH: resolved bash + $SHELL=/bin/zsh + zsh on PATH → mismatch AND active
	it("mismatch notice fires (bash resolved + zsh $SHELL + on PATH); active ALSO fires", function()
		inject_for("/bin/bash")
		pi.bridge = fake_bridge("/bin/bash")
		vim.env.SHELL = "/bin/zsh"
		local restore_exec = stub_executable({ "zsh" })
		shell.ensure(function() end)
		assert.is_true(wait_notify("shell-mismatch"), "shell-mismatch fired within vim.wait")
		assert.is_true(notify.did_notify("shell-mismatch"))
		-- mismatch is resolution-time (independent of spawn success) → active ALSO fires
		assert.is_true(notify.did_notify("shell-active"), "mismatch + healthy spawn → active also fires")
		assert.is_false(notify.did_notify("shell-degrade"), "no degrade (healthy spawn)")
		restore_exec()
	end)

	-- (2b) mismatch MESSAGE names the richer shell + advises shellPath
	it("mismatch message names the richer shell + advises pi's shellPath", function()
		local calls = {}
		local orig_vnotify = vim.notify
		vim.notify = function(msg, level, opts)
			calls[#calls + 1] = { msg = msg, level = level, opts = opts }
		end
		inject_for("/bin/bash")
		pi.bridge = fake_bridge("/bin/bash")
		vim.env.SHELL = "/bin/zsh"
		local restore_exec = stub_executable({ "zsh" })
		shell.ensure(function() end)
		-- flush the scheduled notify
		vim.wait(200, function()
			for _, c in ipairs(calls) do
				if c.msg and c.msg:find("shell%-mismatch") then return true end
				if c.msg and c.msg:find("native zsh completions") then return true end
			end
			return false
		end, 5)
		vim.notify = orig_vnotify
		restore_exec()
		-- find the mismatch toast
		local found
		for _, c in ipairs(calls) do
			if c.msg and c.msg:find("native zsh completions") then found = c; break end
		end
		assert.is_truthy(found, "mismatch toast fired")
		assert.is_truthy(found.msg:find("zsh"), "message names the richer shell (zsh)")
		assert.is_truthy(found.msg:find("shellPath"), "message advises pi's shellPath")
		assert.is_truthy(found.msg:find("/bin/zsh"), "message names $SHELL (/bin/zsh)")
		assert.are.equals(vim.log.levels.WARN, found.level)
		assert.are.equals("pi-bridge", found.opts.title)
	end)

	-- (2c) ISSUE-1: prefer="bash" + resolved=/bin/bash + $SHELL=/bin/zsh → NO mismatch
	it("ISSUE-1: prefer='bash' does NOT fire the mismatch notice (user chose bash)", function()
		pi.config.shell = { prefer = "bash" }
		inject_for("/bin/bash")           -- REQUIRED: pick_driver("/bin/bash") looks up .shell.bash
		pi.bridge = fake_bridge("/bin/bash")
		vim.env.SHELL = "/bin/zsh"
		local restore_exec = stub_executable({ "zsh" })
		shell.ensure(function() end)
		assert.is_false(wait_notify("shell-mismatch"), "mismatch MUST NOT fire under prefer='bash'")
		assert.is_false(notify.did_notify("shell-mismatch"))
		-- SCOPE guard: the gate suppresses ONLY the mismatch notice — active still fires
		assert.is_true(notify.did_notify("shell-active"), "shell-active still fires (gate is scoped)")
		assert.is_false(notify.did_notify("shell-degrade"), "no degrade (healthy bash spawn)")
		restore_exec()
	end)

	-- (2d) ISSUE-1: prefer="/bin/bash" (explicit path) + $SHELL=/bin/zsh → NO mismatch
	it("ISSUE-1: prefer='/bin/bash' (explicit path) does NOT fire the mismatch notice", function()
		pi.config.shell = { prefer = "/bin/bash" }
		inject_for("/bin/bash")
		pi.bridge = fake_bridge("/bin/bash")
		vim.env.SHELL = "/bin/zsh"
		local restore_exec = stub_executable({ "zsh" })
		shell.ensure(function() end)
		assert.is_false(wait_notify("shell-mismatch"), "mismatch MUST NOT fire under explicit prefer='/bin/bash'")
		assert.is_false(notify.did_notify("shell-mismatch"))
		assert.is_true(notify.did_notify("shell-active"), "scope guard: active still fires")
		restore_exec()
	end)

	-- (2e) ISSUE-1 REGRESSION: prefer="pi" (explicit) + descriptor bash + $SHELL=/bin/zsh → STILL fires
	it("ISSUE-1 regression: prefer='pi' (explicit) STILL fires the mismatch notice", function()
		pi.config.shell = { prefer = "pi" }
		inject_for("/bin/bash")
		pi.bridge = fake_bridge("/bin/bash")
		vim.env.SHELL = "/bin/zsh"
		local restore_exec = stub_executable({ "zsh" })
		shell.ensure(function() end)
		assert.is_true(wait_notify("shell-mismatch"), "mismatch MUST fire under prefer='pi' (regression)")
		assert.is_true(notify.did_notify("shell-mismatch"))
		restore_exec()
	end)

	-- (3) MISMATCH no-PATH: zsh NOT on PATH (executable returns 0) → no mismatch
	it("mismatch does NOT fire when the richer shell is absent from PATH", function()
		inject_for("/bin/bash")
		pi.bridge = fake_bridge("/bin/bash")
		vim.env.SHELL = "/bin/zsh"
		local restore_exec = stub_executable({}) -- nothing on PATH
		shell.ensure(function() end)
		assert.is_true(wait_notify("shell-active")) -- healthy spawn → active fires
		assert.is_false(notify.did_notify("shell-mismatch"), "no mismatch (PATH gate failed)")
		restore_exec()
	end)

	-- (4) MISMATCH self-gate: resolved == $SHELL → no mismatch
	it("mismatch does NOT fire when resolved == $SHELL (self-gating)", function()
		inject_for("/bin/zsh")
		pi.bridge = fake_bridge("/bin/zsh")
		vim.env.SHELL = "/bin/zsh"
		local restore_exec = stub_executable({ "zsh" })
		shell.ensure(function() end)
		assert.is_true(wait_notify("shell-active"))
		assert.is_false(notify.did_notify("shell-mismatch"), "resolved==$SHELL → structurally false")
		restore_exec()
	end)

	-- (5) DEGRADE no-driver: unknown shell → degrade, NO first-run hint (suppression)
	it("degrade fires on no-driver (unknown shell); first-run hint SUPPRESSED", function()
		pi.bridge = fake_bridge("/bin/noshell") -- unknown basename, no driver module
		shell.ensure(function() end)
		assert.is_true(wait_notify("shell-degrade"))
		assert.is_true(notify.did_notify("shell-degrade"))
		assert.is_false(notify.did_notify("shell-active"), "active SUPPRESSED (no spawn reached 8b)")
		assert.is_false(notify.did_notify("shell-mismatch"), "no mismatch (not bash)")
	end)

	-- (6) DEGRADE spawn-err: fake driver cb(err) → degrade, NO first-run hint
	it("degrade fires on a spawn error; first-run hint SUPPRESSED", function()
		local failfake = { calls = 0 }
		failfake.start = function(opts, cb)
			failfake.calls = failfake.calls + 1
			opts._fail = true
			local inner = make_fake_driver()
			inner.start(opts, cb) -- drives _fail → cb("spawn err: simulated", ...)
		end
		package.loaded["pi-bridge.shell.fish"] = failfake
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		assert.is_true(wait_notify("shell-degrade"))
		assert.is_true(notify.did_notify("shell-degrade"))
		assert.is_false(notify.did_notify("shell-active"), "active SUPPRESSED (8b not reached)")
	end)

	-- (7) DEGRADE driver-threw: start THROWS → degrade (pcall catches), NO active
	it("degrade fires when driver.start THROWS; first-run hint SUPPRESSED", function()
		local throwing = { calls = 0 }
		throwing.start = function(_opts, _cb)
			throwing.calls = throwing.calls + 1
			error("driver exploded")
		end
		package.loaded["pi-bridge.shell.fish"] = throwing
		pi.bridge = fake_bridge("/usr/bin/fish")
		assert.has_no.errors(function() shell.ensure(function() end) end)
		assert.is_true(wait_notify("shell-degrade"))
		assert.is_true(notify.did_notify("shell-degrade"))
		assert.is_false(notify.did_notify("shell-active"), "active SUPPRESSED (8c threw-guard)")
	end)

	-- (8) DEGRADE mid-session EOF (_reset): healthy spawn then _reset → degrade once
	it("degrade fires on mid-session _reset (EOF); dedups with no earlier degrade", function()
		inject_for("/usr/bin/fish")
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		assert.is_true(wait_notify("shell-active"))
		assert.is_false(notify.did_notify("shell-degrade"), "no degrade yet (healthy spawn)")
		shell._reset() -- simulate EOF crash
		assert.is_true(wait_notify("shell-degrade"))
		assert.is_true(notify.did_notify("shell-degrade"))
	end)

	-- (9) DEGRADE mid-session parse-threshold (_feed): 5 garbage pairs → degrade
	it("degrade fires on _feed parse-threshold (N consecutive garbage responses)", function()
		inject_for("/usr/bin/fish")
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		assert.is_true(wait_notify("shell-active"))
		-- 5 _feed calls each carrying a complete-but-undecodable START/END pair
		local garbage = "__PIRESP_START__\n{NOT JSON}\n__PIRESP_END__\n"
		for _ = 1, 5 do
			shell._feed(garbage)
		end
		assert.is_true(wait_notify("shell-degrade"))
		assert.is_true(notify.did_notify("shell-degrade"))
	end)

	-- (10) DEDUP: each category fires AT MOST once per session
	it("dedup: a 2nd trigger of the SAME category is a silent no-op (count == 1)", function()
		local active_calls, degrade_calls = 0, 0
		local orig_vnotify = vim.notify
		vim.notify = function(msg, _lvl, _opts)
			if type(msg) ~= "string" then return end
			if msg:find("shell completion active") then active_calls = active_calls + 1 end
			if msg:find("shell completion unavailable") then degrade_calls = degrade_calls + 1 end
		end
		inject_for("/usr/bin/fish")
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end) -- first spawn → 1 active
		vim.wait(150, function() return active_calls >= 1 end, 5)
		assert.are.equals(1, active_calls, "first spawn fires the hint exactly once")
		-- 2nd ensure: proc-cache hit → no re-fire (active stays 1)
		shell.ensure(function() end)
		vim.wait(50, function() return false end, 5)
		assert.are.equals(1, active_calls, "2nd ensure (cache hit) does NOT re-fire the hint")
		-- _reset twice → degrade fires EXACTLY once (category dedup)
		shell._reset()
		shell._reset()
		vim.wait(150, function() return degrade_calls >= 1 end, 5)
		assert.are.equals(1, degrade_calls, "degrade fires exactly once across two _reset triggers")
		vim.notify = orig_vnotify
	end)

	-- (11) SUPPRESSION (§17.9): on a failed spawn, active is false AND degrade is true
	it("suppression (§17.9): failed spawn → active false, degrade true (the EITHER/OR)", function()
		local failfake = { calls = 0 }
		failfake.start = function(opts, cb)
			failfake.calls = failfake.calls + 1
			opts._fail = true
			local inner = make_fake_driver()
			inner.start(opts, cb)
		end
		package.loaded["pi-bridge.shell.fish"] = failfake
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		assert.is_true(wait_notify("shell-degrade"))
		assert.is_true(notify.did_notify("shell-degrade"))
		assert.is_false(notify.did_notify("shell-active"), "active MUST be false on a failed spawn")
	end)

	-- (12) MISMATCH_TARGET pure unit cases (no daemon, no nvim)
	it("M.mismatch_target: pure unit cases (self-gating across every prefer)", function()
		assert.are.equals("zsh", shell.mismatch_target("/bin/bash", "/bin/zsh"))
		assert.are.equals("fish", shell.mismatch_target("/bin/bash", "/usr/bin/fish"))
		assert.is_nil(shell.mismatch_target("/bin/bash", "/bin/sh"))  -- sh not tier-1
		assert.is_nil(shell.mismatch_target("/bin/zsh", "/bin/zsh"))   -- resolved != bash
		assert.is_nil(shell.mismatch_target("/bin/bash", "/bin/bash")) -- both bash
		assert.is_nil(shell.mismatch_target("/bin/bash", nil))         -- nil $SHELL
		assert.is_nil(shell.mismatch_target(nil, "/bin/zsh"))          -- nil resolved
		assert.is_nil(shell.mismatch_target("", "/bin/zsh"))           -- empty resolved
		assert.is_nil(shell.mismatch_target("/bin/bash", ""))          -- empty env_shell
	end)

	-- (13) never-throws: nil config + throwing vim.fn.executable + bad inputs
	it("never throws: nil config, throwing vim.fn.executable, bad mismatch_target args", function()
		inject_for("/usr/bin/fish")
		pi.bridge = fake_bridge("/usr/bin/fish")
		-- (13a) nil config → the AND-chain default {}; ensure does NOT throw
		local saved_config = pi.config
		pi.config = nil
		local ok1, err1 = pcall(function() shell.ensure(function() end) end)
		pi.config = saved_config
		assert.is_true(ok1, "ensure must not throw when pi.config is nil (got " .. tostring(err1) .. ")")
		-- (13b) a THROWING vim.fn.executable is pcall'd → mismatch degrades to no-fire, no throw
		shell.reset()
		notify.reset()
		inject_for("/bin/bash")
		pi.bridge = fake_bridge("/bin/bash")
		vim.env.SHELL = "/bin/zsh"
		vim.fn.executable = function(_name) error("exec boom") end
		local ok2, err2 = pcall(function() shell.ensure(function() end) end)
		assert.is_true(ok2, "ensure must not throw when vim.fn.executable throws (got " .. tostring(err2) .. ")")
		-- mismatch MUST NOT have fired (the pcall around executable failed)
		assert.is_false(notify.did_notify("shell-mismatch"), "throwing executable → mismatch suppressed")
		-- (13c) bad mismatch_target args never throw
		assert.has_no.errors(function()
			shell.mismatch_target(nil, nil)
			shell.mismatch_target(123, 456)
			shell.mismatch_target({}, {})
		end)
	end)

	-- (14) exposes M.mismatch_target as a function (+ the notice wiring is in place)
	it("exposes M.mismatch_target as a function", function()
		assert.are.equals("function", type(shell.mismatch_target))
		assert.are.equals("function", type(shell.ensure))
		assert.are.equals("function", type(shell._feed))
		assert.are.equals("function", type(shell._reset))
	end)
end)