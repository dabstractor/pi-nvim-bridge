-- === tests/shell_ensure_spec.lua — plenary/busted spec (the Level-2 gate, P2.M1.T2.S3) ===
-- Covers every Success Criterion of shell.lua's SPAWN layer (M.ensure + M._feed +
-- M._reset stubs). MOCKS the bridge (sets require("pi-bridge").bridge = fake) +
-- descriptor + config + injects a FAKE driver into package.loaded + fake pipes — so it
-- tests the ensure lifecycle matrix FAST with no subprocess (the live fish seam was
-- proven by S1's spike; S3 is pure orchestration).
--
-- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
-- `pending` (the test-SKIP function). We use `got`/`cb` locals.
--
-- Run (from the repo root):
--   timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")'
local pi = require("pi-bridge")
local shell = require("pi-bridge.shell")

if pi.config == nil then pi.setup({}) end -- self-sufficient (mirror completion_spec.lua L18)

-- --- a fake bridge exposing the surface points ensure/resolve/session_cwd read FRESH:
-- get_shell_info() (controls the resolved shell) + server_info.cwd (session_cwd).
local function fake_bridge(shell_path, server_cwd)
	return {
		get_shell_info = function()
			if shell_path == nil then return nil end
			return { shell = shell_path }
		end,
		server_info = (server_cwd == nil) and {} or { cwd = server_cwd },
	}
end

-- --- the fake driver + fake pipes (mirrors the luv handle shape from
-- tests/shell_fish_spike.lua: read_start/write/close/read_stop/is_closing) so the
-- read_start wiring + the teardown-guard methods exist WITHOUT a real subprocess.
-- `start` calls cb SYNCHRONOUSLY (GOTCHA #10) — no vim.wait needed.
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

-- --- save/restore the globals the spec swaps per-case.
local orig_shell, orig_bridge, orig_desc, orig_shell_cfg

describe("pi-bridge.shell ensure (P2.M1.T2.S3)", function()
	before_each(function()
		orig_shell = vim.env.SHELL
		orig_bridge = pi.bridge
		orig_desc = pi.descriptor
		orig_shell_cfg = vim.deepcopy((pi.config and pi.config.shell) or nil)
		pi.bridge = nil
		pi.descriptor = nil
		vim.env.SHELL = nil
		package.loaded["pi-bridge.shell.fish"] = nil
		package.loaded["pi-bridge.shell.unknownshell"] = nil
		shell.reset()
	end)
	after_each(function()
		vim.env.SHELL = orig_shell
		pi.bridge = orig_bridge
		pi.descriptor = orig_desc
		package.loaded["pi-bridge.shell.fish"] = nil
		package.loaded["pi-bridge.shell.unknownshell"] = nil
		if pi.config then pi.config.shell = vim.deepcopy(orig_shell_cfg) end
		shell.reset()
	end)

	it("first ensure with a present driver spawns + caches + wires read_start + passes opts + cb(nil)", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.is_nil(got)
		assert.are.equals(1, fake.captured.calls)
		assert.are.equals("/usr/bin/fish", fake.captured.opts.shell)
		assert.are.equals(5000, fake.captured.opts.startup_timeout_ms)
		assert.is_nil(fake.captured.opts.cwd)
		assert.is_truthy(fake.captured.read_cb, "read_start callback should be captured")
	end)

	it("second ensure with state.proc set reuses — driver.start NOT re-called; cb(nil) immediately", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end) -- populate proc
		assert.are.equals(1, fake.captured.calls)
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.is_nil(got)
		assert.are.equals(1, fake.captured.calls, "driver.start must NOT be re-called on the cached path")
	end)

	it("spawn error (driver cb err) sets driver=nil + failed=true; cb(err)", function()
		local failfake = { calls = 0 }
		failfake.start = function(opts, cb)
			failfake.calls = failfake.calls + 1
			cb("spawn err: simulated", nil, nil, nil)
		end
		package.loaded["pi-bridge.shell.fish"] = failfake
		pi.bridge = fake_bridge("/usr/bin/fish")
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.are.equals("spawn err: simulated", got)
		assert.are.equals(1, failfake.calls)
		-- follow-up short-circuits via failed
		local got2 = "UNSET"
		shell.ensure(function(err) got2 = err end)
		assert.are.equals("daemon disabled", got2)
		assert.are.equals(1, failfake.calls, "follow-up must not re-call driver.start")
	end)

	it("driver.start that THROWS is caught → failed=true, driver=nil, cb(tostring(err))", function()
		local throwing = { calls = 0 }
		throwing.start = function(opts, cb)
			throwing.calls = throwing.calls + 1
			error("driver exploded")
		end
		package.loaded["pi-bridge.shell.fish"] = throwing
		pi.bridge = fake_bridge("/usr/bin/fish")
		local got = "UNSET"
		assert.has_no.errors(function()
			shell.ensure(function(err) got = err end)
		end)
		assert.is_truthy(got and got:find("driver exploded"), "cb should receive the thrown err string (got " .. tostring(got) .. ")")
		assert.are.equals(1, throwing.calls)
		-- follow-up short-circuits via failed
		local got2 = "UNSET"
		shell.ensure(function(err) got2 = err end)
		assert.are.equals("daemon disabled", got2)
	end)

	it("no driver (unknown shell) sets failed=true; cb('no driver for '..shell)", function()
		pi.bridge = fake_bridge("/bin/unknownshell")
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.are.equals("no driver for /bin/unknownshell", got)
		-- follow-up short-circuits via failed
		local got2 = "UNSET"
		shell.ensure(function(err) got2 = err end)
		assert.are.equals("daemon disabled", got2)
	end)

	it("disabled driver (config.shell.drivers.fish=false) degrades like no-driver", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake -- module IS loadable...
		pi.bridge = fake_bridge("/usr/bin/fish")
		pi.config.shell = pi.config.shell or {}
		pi.config.shell.drivers = { fish = false } -- ...but disabled
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.are.equals("no driver for /usr/bin/fish", got)
		assert.are.equals(0, fake.captured.calls, "disabled driver.start must NOT be called")
	end)

	it("preset state.failed short-circuits: cb('daemon disabled'); driver.start NOT called", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell._reset() -- mark unhealthy (the §17.12 EOF path)
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.are.equals("daemon disabled", got)
		assert.are.equals(0, fake.captured.calls)
	end)

	it("config pass-through: prefer honored + startup_timeout_ms passed (NOT the 5000 default)", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.config.shell = pi.config.shell or {}
		pi.config.shell.prefer = "/usr/bin/fish"
		pi.config.shell.startup_timeout_ms = 2500
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.is_nil(got)
		assert.are.equals("/usr/bin/fish", fake.captured.opts.shell)
		assert.are.equals(2500, fake.captured.opts.startup_timeout_ms)
	end)

	it("nil config does not throw — uses defaults (prefer='pi', timeout 5000)", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		local saved_config = pi.config
		pi.config = nil
		local got = "UNSET"
		local ok, err = pcall(function()
			shell.ensure(function(e) got = e end)
		end)
		pi.config = saved_config
		assert.is_truthy(ok, "ensure must not throw when pi.config is nil (got " .. tostring(err) .. ")")
		assert.is_nil(got)
		assert.are.equals(5000, fake.captured.opts.startup_timeout_ms)
		assert.are.equals("/usr/bin/fish", fake.captured.opts.shell)
	end)

	it("session_cwd pass-through: server_info.cwd → opts.cwd", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish", "/srv")
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.is_nil(got)
		assert.are.equals("/srv", fake.captured.opts.cwd)
	end)

	it("never throws on bad on_ready args (nil / 123)", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		assert.has_no.errors(function() shell.ensure(nil) end)
		assert.are.equals(1, fake.captured.calls)
		shell.reset()
		fake.captured.calls = 0
		assert.has_no.errors(function() shell.ensure(123) end)
	end)

	it("read_start _feed route: a stdout chunk appends to the rx buffer (stub)", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		assert.is_truthy(fake.captured.read_cb)
		-- drive two chunks (append-only): no throw
		assert.has_no.errors(function()
			fake.captured.read_cb(nil, "X")
			fake.captured.read_cb(nil, "YZ")
		end)
		-- EOF now proves _feed ran without erroring: _reset fires → follow-up ensure sees failed
		fake.captured.read_cb(nil, nil)
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.are.equals("daemon disabled", got)
	end)

	it("read_start _reset route: EOF (nil chunk) marks failed + nils proc; next ensure short-circuits", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		-- EOF
		assert.has_no.errors(function() fake.captured.read_cb(nil, nil) end)
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.are.equals("daemon disabled", got)
		assert.are.equals(1, fake.captured.calls, "driver.start must NOT be re-called after EOF")
	end)

	it("exposes _feed + _reset + ensure as functions", function()
		assert.are.equals("function", type(shell.ensure))
		assert.are.equals("function", type(shell._feed))
		assert.are.equals("function", type(shell._reset))
	end)

	it("_feed is append-only + never throws on nil / '' / chunk", function()
		assert.has_no.errors(function()
			shell._feed(nil)
			shell._feed("")
			shell._feed("abc")
		end)
	end)

	it("_reset sets failed + never throws; leaves failed true (does NOT call reset)", function()
		assert.has_no.errors(function() shell._reset() end)
		-- the proof _reset left failed=true (a reset() would have cleared it): follow-up ensure short-circuits
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.are.equals("daemon disabled", got)
	end)
end)