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