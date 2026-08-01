-- === tests/shell_spec.lua — plenary/busted spec (the Level-2 gate, P2.M1.T2.S2) ===
-- Covers every Success Criterion of shell.lua's resolution + state layer. MOCKS the
-- bridge (sets require("pi-bridge").bridge = fake) + descriptor + vim.env.SHELL + injects
-- a fake driver into package.loaded — so it tests the §17.4 fallback chain + §17.4.2
-- driver selection + §17.5.2 cwd priority FAST with no subprocess (the live fish seam
-- was proven by S1's spike; S2 is pure resolution).
--
-- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
-- `pending` (the test-SKIP function). We use `got`/`results` locals.
--
-- Run (from the repo root):
--   nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'
local pi = require("pi-bridge")
local shell = require("pi-bridge.shell")

if pi.config == nil then pi.setup({}) end -- self-sufficient (mirror completion_spec.lua L18)

-- --- a fake bridge exposing the two surface points shell.lua reads FRESH:
-- get_shell_info() (S4 contract) + server_info.cwd (session_cwd). `shell_path` controls
-- the advertised descriptor shell (nil → no shell field; "" → malformed/unresolved).
local function fake_bridge(shell_path, server_cwd)
	return {
		get_shell_info = function()
			if shell_path == nil then return nil end
			return { shell = shell_path }
		end,
		server_info = (server_cwd == nil) and {} or { cwd = server_cwd },
	}
end

-- --- save/restore the globals the spec swaps per-case.
local orig_shell, orig_bridge, orig_desc, orig_drivers

describe("pi-bridge.shell resolve_shell (P2.M1.T2.S2)", function()
	before_each(function()
		orig_shell = vim.env.SHELL
		orig_bridge = pi.bridge
		orig_desc = pi.descriptor
		orig_drivers = (pi.config and pi.config.shell and pi.config.shell.drivers) or nil
		pi.bridge = nil
		pi.descriptor = nil
		vim.env.SHELL = nil
	end)
	after_each(function()
		vim.env.SHELL = orig_shell
		pi.bridge = orig_bridge
		pi.descriptor = orig_desc
		package.loaded["pi-bridge.shell.fish"] = nil
		if pi.config and pi.config.shell then pi.config.shell.drivers = orig_drivers end
		shell.reset()
	end)

	it("prefer=='pi' returns the descriptor shell when bridge advertises one (source 'pi')", function()
		pi.bridge = fake_bridge("/bin/zsh")
		local s, src = shell.resolve_shell("pi")
		assert.are.equals("/bin/zsh", s)
		assert.are.equals("pi", src)
	end)

	it("prefer=='pi' falls back to $SHELL when descriptor has no shell", function()
		pi.bridge = fake_bridge(nil)
		vim.env.SHELL = "/bin/zsh"
		local s, src = shell.resolve_shell("pi")
		assert.are.equals("/bin/zsh", s)
		assert.are.equals("$SHELL", src)
	end)

	it("prefer=='pi' falls back to /bin/bash when no descriptor shell and no $SHELL", function()
		pi.bridge = fake_bridge(nil)
		vim.env.SHELL = nil
		local s, src = shell.resolve_shell("pi")
		assert.are.equals("/bin/bash", s)
		assert.are.equals("default", src)
	end)

	it("prefer=='pi' uses pi.descriptor.shell directly when bridge==nil (pre-handshake)", function()
		pi.bridge = nil
		pi.descriptor = { shell = "/usr/local/bin/fish" }
		local s, src = shell.resolve_shell("pi")
		assert.are.equals("/usr/local/bin/fish", s)
		assert.are.equals("pi", src)
	end)

	it("prefer=='shell' returns $SHELL when set", function()
		pi.bridge = fake_bridge("/bin/ignored") -- descriptor shell MUST be ignored for prefer=='shell'
		vim.env.SHELL = "/bin/zsh"
		local s, src = shell.resolve_shell("shell")
		assert.are.equals("/bin/zsh", s)
		assert.are.equals("$SHELL", src)
	end)

	it("prefer=='shell' returns /bin/bash when $SHELL unset", function()
		vim.env.SHELL = nil
		local s, src = shell.resolve_shell("shell")
		assert.are.equals("/bin/bash", s)
		assert.are.equals("default", src)
	end)

	it("prefer=='bash' always returns /bin/bash (ignores SHELL + descriptor)", function()
		vim.env.SHELL = "/bin/zsh"
		pi.bridge = fake_bridge("/bin/ignored")
		local s, src = shell.resolve_shell("bash")
		assert.are.equals("/bin/bash", s)
		assert.are.equals("default", src)
	end)

	it("explicit path prefer returns that path (source 'config')", function()
		local s, src = shell.resolve_shell("/usr/bin/fish")
		assert.are.equals("/usr/bin/fish", s)
		assert.are.equals("config", src)
	end)

	it("prefer==nil defaults to 'pi' (follows the pi chain)", function()
		pi.bridge = fake_bridge("/bin/zsh")
		local s, src = shell.resolve_shell(nil)
		assert.are.equals("/bin/zsh", s)
		assert.are.equals("pi", src)
	end)

	it("never throws on bad prefer (nil/''/123/{})", function()
		assert.has_no.errors(function()
			shell.resolve_shell(123)
			shell.resolve_shell("")
			shell.resolve_shell({})
		end)
		-- a non-string / empty prefer lands on the safe default
		local s, src = shell.resolve_shell(123)
		assert.are.equals("/bin/bash", s)
		assert.are.equals("default", src)
	end)
end)

describe("pi-bridge.shell pick_driver (P2.M1.T2.S2)", function()
	before_each(function()
		orig_drivers = (pi.config and pi.config.shell and pi.config.shell.drivers) or nil
		package.loaded["pi-bridge.shell.fish"] = nil
	end)
	after_each(function()
		package.loaded["pi-bridge.shell.fish"] = nil
		package.loaded["pi-bridge.shell.bash"] = nil
		if pi.config and pi.config.shell then pi.config.shell.drivers = orig_drivers end
	end)

	it("returns the driver module for a loadable pi-bridge.shell.<base> with .start", function()
		package.loaded["pi-bridge.shell.fish"] = { start = function() end }
		local drv = shell.pick_driver("/usr/bin/fish")
		assert.is_truthy(drv)
		assert.are.equals("function", type(drv.start))
	end)

	it("returns nil for an unknown shell (no module)", function()
		assert.is_nil(shell.pick_driver("/bin/unknownshell"))
	end)

	it("returns nil when the module lacks a .start function", function()
		package.loaded["pi-bridge.shell.fish"] = { no_start = true }
		assert.is_nil(shell.pick_driver("/usr/bin/fish"))
	end)

	it("returns nil for a user-disabled driver (config.shell.drivers.<base>==false)", function()
		package.loaded["pi-bridge.shell.bash"] = { start = function() end } -- module IS loadable...
		pi.config.shell = pi.config.shell or {}
		pi.config.shell.drivers = { bash = false }                           -- ...but disabled
		assert.is_nil(shell.pick_driver("/bin/bash"))
	end)

	it("returns the module when the driver is explicitly enabled (true, not false)", function()
		package.loaded["pi-bridge.shell.fish"] = { start = function() end }
		pi.config.shell = pi.config.shell or {}
		pi.config.shell.drivers = { fish = true }
		local drv = shell.pick_driver("/usr/bin/fish")
		assert.is_truthy(drv)
	end)

	it("never throws on nil / '' / non-string resolved_shell", function()
		assert.has_no.errors(function()
			shell.pick_driver(nil)
			shell.pick_driver("")
			shell.pick_driver(123)
			shell.pick_driver({})
		end)
		assert.is_nil(shell.pick_driver(nil))
		assert.is_nil(shell.pick_driver(""))
	end)

	it("resolves the basename from a full path (s:gsub('.*/',''))", function()
		package.loaded["pi-bridge.shell.zsh"] = { start = function() end }
		local drv = shell.pick_driver("/usr/local/bin/zsh")
		assert.is_truthy(drv)
		package.loaded["pi-bridge.shell.zsh"] = nil
	end)
end)

describe("pi-bridge.shell session_cwd (P2.M1.T2.S2)", function()
	before_each(function()
		orig_bridge = pi.bridge
		orig_desc = pi.descriptor
		pi.bridge = nil
		pi.descriptor = nil
	end)
	after_each(function()
		pi.bridge = orig_bridge
		pi.descriptor = orig_desc
	end)

	it("prefers bridge.server_info.cwd when present", function()
		pi.bridge = fake_bridge(nil, "/srv/proj")
		assert.are.equals("/srv/proj", shell.session_cwd())
	end)

	it("falls back to descriptor.cwd when no server_info.cwd", function()
		pi.bridge = fake_bridge(nil, nil)
		pi.descriptor = { cwd = "/desc/path" }
		assert.are.equals("/desc/path", shell.session_cwd())
	end)

	it("returns nil when neither server_info.cwd nor descriptor.cwd", function()
		pi.bridge = nil
		pi.descriptor = nil
		assert.is_nil(shell.session_cwd())
	end)

	it("never throws when bridge + descriptor are both nil", function()
		pi.bridge = nil
		pi.descriptor = nil
		assert.has_no.errors(function() shell.session_cwd() end)
		assert.is_nil(shell.session_cwd())
	end)
end)

describe("pi-bridge.shell reset + exports (P2.M1.T2.S2)", function()
	it("exposes resolve_shell / pick_driver / session_cwd / reset as functions", function()
		assert.are.equals("function", type(shell.resolve_shell))
		assert.are.equals("function", type(shell.pick_driver))
		assert.are.equals("function", type(shell.session_cwd))
		assert.are.equals("function", type(shell.reset))
	end)

	it("reset() never throws + leaves the module callable", function()
		assert.has_no.errors(function() shell.reset() end)
		-- post-reset the pure helpers still work
		local s, src = shell.resolve_shell("bash")
		assert.are.equals("/bin/bash", s)
		assert.are.equals("default", src)
		assert.is_nil(shell.pick_driver("/bin/nope"))
	end)
end)

-- ===========================================================================
-- M.status() — the read-only snapshot accessor (P2.M3.T6.S2) for :checkhealth.
-- Mirrors M.get_shell()'s minimal-surface design: a plain table-field read returning a
-- FRESH table of plain values (never the raw `state` table or its luv handles). Driven
-- via a fake fish driver (the shell_ensure_spec pattern) so a successful ensure sets
-- state.proc; state.failed is exercised via a no-driver ensure.
-- ===========================================================================
local function fake_bridge_status(shell_path)
	return {
		get_shell_info = function() return { shell = shell_path } end,
		server_info = {},
	}
end

local function make_fake_driver_status()
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
		start = function(opts, cb)
			cb(nil, { is_closing = function() return false end }, fake_pipe(), fake_pipe())
		end,
	}
end

describe("pi-bridge.shell status (P2.M3.T6.S2)", function()
	local orig_shell, orig_bridge, orig_desc

	before_each(function()
		orig_shell = vim.env.SHELL
		orig_bridge = pi.bridge
		orig_desc = pi.descriptor
		pi.bridge = nil
		pi.descriptor = nil
		vim.env.SHELL = nil
		package.loaded["pi-bridge.shell.fish"] = nil
		shell.reset()
	end)

	after_each(function()
		vim.env.SHELL = orig_shell
		pi.bridge = orig_bridge
		pi.descriptor = orig_desc
		package.loaded["pi-bridge.shell.fish"] = nil
		shell.reset()
	end)

	it("exposes M.status as a function", function()
		assert.are.equals("function", type(shell.status))
	end)

	it("returns a table with the 6 status fields + correct types (no handle leakage)", function()
		local st = shell.status()
		assert.is_true(type(st) == "table")
		-- shell: string|nil (nil at reset is valid). driver_basename: string (never nil).
		assert.is_true(type(st.driver_basename) == "string", "driver_basename is a string")
		assert.is_true(type(st.proc_alive) == "boolean", "proc_alive is boolean")
		assert.is_true(type(st.inflight) == "boolean", "inflight is boolean")
		assert.is_true(type(st.failed) == "boolean", "failed is boolean")
		assert.is_true(type(st.parse_failures) == "number", "parse_failures is a number")
		-- if shell is present it MUST be a string
		if st.shell ~= nil then
			assert.is_true(type(st.shell) == "string", "shell is a string when present")
		end
		-- NO raw-state / handle leakage (minimal surface): the accessor returns ONLY plain values
		assert.is_nil(rawget(st, "proc"), "must NOT expose the proc handle")
		assert.is_nil(rawget(st, "stdin"), "must NOT expose the stdin handle")
		assert.is_nil(rawget(st, "stdout"), "must NOT expose the stdout handle")
		assert.is_nil(rawget(st, "driver"), "must NOT expose the driver module")
		assert.is_nil(rawget(st, "rx_buf"), "must NOT expose the rx buffer")
	end)

	it("initial/reset state: proc_alive=false, failed=false, parse_failures=0, shell=nil", function()
		shell.reset()
		local st = shell.status()
		assert.is_nil(st.shell)
		assert.are.equals("", st.driver_basename)
		assert.is_false(st.proc_alive)
		assert.is_false(st.inflight)
		assert.is_false(st.failed)
		assert.are.equals(0, st.parse_failures)
	end)

	it("after a successful ensure, proc_alive=true + shell/driver_basename reflect state", function()
		package.loaded["pi-bridge.shell.fish"] = make_fake_driver_status()
		pi.bridge = fake_bridge_status("/usr/bin/fish")
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.is_nil(got)
		local st = shell.status()
		assert.is_true(st.proc_alive, "proc is alive after a successful spawn")
		assert.are.equals("/usr/bin/fish", st.shell)
		assert.are.equals("fish", st.driver_basename, "driver_basename is the resolved shell's basename")
		assert.is_false(st.failed)
	end)

	it("after a no-driver ensure, failed=true (proc_alive stays false)", function()
		-- resolve to an unsupported shell so pick_driver returns nil → state.failed=true
		pi.bridge = fake_bridge_status("/bin/dash")
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.is_truthy(got, "ensure reported a no-driver err")
		local st = shell.status()
		assert.is_true(st.failed, "failed=true after a no-driver ensure")
		assert.is_false(st.proc_alive, "proc_alive stays false on the failed path")
	end)

	it("driver_basename derives from state.shell basename (zsh path)", function()
		package.loaded["pi-bridge.shell.zsh"] = make_fake_driver_status()
		pi.bridge = fake_bridge_status("/opt/homebrew/bin/zsh")
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.is_nil(got)
		assert.are.equals("zsh", shell.status().driver_basename)
		package.loaded["pi-bridge.shell.zsh"] = nil
	end)

	it("never throws (a plain table-field read)", function()
		assert.has_no.errors(function() shell.status() end)
		-- also safe after a reset (state at its initial literal)
		shell.reset()
		assert.has_no.errors(function() shell.status() end)
	end)

	it("returns a FRESH table each call (mutating one result does not affect the next)", function()
		local a = shell.status()
		a.shell = "MUTATED"
		a.failed = true
		local b = shell.status()
		assert.is_not_equal(a.shell, b.shell, "results are independent snapshots")
		assert.is_not_equal(a.failed, b.failed)
	end)
end)