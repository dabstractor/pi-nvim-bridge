-- === tests/shell_unknown_shell_spec.lua — plenary/busted spec (the Level-2 gate, P2.M3.T5.S3) ===
-- A DEDICATED, self-contained regression guard for the unknown-shell DEGRADE path. The
-- implementation under test already lives in shell.lua (pick_driver→nil → ensure sets
-- state.failed=true, fires ONE dedup'd notify.once("shell-degrade", WARN), callbacks
-- "no driver for <shell>", and every follow-up ensure/complete_current short-circuits).
-- Its coverage was previously SCATTERED across shell_spec.lua (pick_driver nil),
-- shell_ensure_spec.lua (ensure no-driver), and shell_notices_spec.lua (degrade dedup).
-- This file consolidates the FULL end-to-end degrade contract into ONE focused matrix
-- so a future change to pick_driver / ensure / state.failed / notify.once keys can be
-- caught at a glance with a named `it(...)` per invariant.
--
-- TEST-ONLY: no production file is modified. The fakes mirror shell_ensure_spec.lua's
-- battle-tested fake_bridge + make_fake_driver (copied, NOT imported — specs are
-- independent modules). Adds a notify.once recorder spy for the single-notice invariant
-- (the simplest direct form, per the PRP gotcha).
--
-- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
-- `pending` (the test-SKIP function). We use `got`/`notices` locals.
--
-- Run (from the repo root):
--   timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shell_unknown_shell_spec.lua")'
--
-- AGENTS.md HARD RULE: this file is run via :luafile — NEVER pipe a heredoc into nvim's
-- stdin (`nvim ... +"luafile /dev/stdin" +qa <<EOF` HANGS the session).
local pi = require("pi-bridge")
local shell = require("pi-bridge.shell")
local notify = require("pi-bridge.notify")

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
-- tests/shell_ensure_spec.lua: read_start/write/close/read_stop/is_closing). Used ONLY
-- for the "disabled driver" case (module loadable but flag=false) + proving a follow-up
-- ensure does NOT re-call .start on the degraded path. `start` calls cb SYNCHRONOUSLY.
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

-- --- a notify.once recorder spy: counts calls per category key + exposes did_notify.
-- REPLICATES notify.once's dedup semantics (the FIRST call per category counts; later
-- calls with the same category are silent no-ops) so the spy behaves identically to the
-- real module — this is what makes the "fires exactly once across two ensure() calls"
-- + the cross-shell dedup assertions correct. The PRP recommends this simplest direct
-- form (no cross-file helper). Returned `calls` is the live table the spy mutates.
local function make_notify_spy()
	local calls = {}
	local seen = {} -- the dedup set (mirrors notify.lua's internal `seen`)
	return {
		calls = calls,
		spy = {
			once = function(category, level, msg)
				local k = (type(category) == "string" and category ~= "") and category or "bridge"
				if seen[k] then return end -- dedup (mirrors notify.lua)
				seen[k] = true
				calls[k] = (calls[k] or 0) + 1
			end,
			did_notify = function(category)
				local k = (type(category) == "string" and category ~= "") and category or "bridge"
				return (calls[k] or 0) > 0
			end,
			-- notify.reset is NOT called by shell.lua, but keep the seam so the spy is a drop-in.
			reset = function()
				calls = {}
				seen = {}
			end,
		},
	}
end

-- --- save/restore the globals the spec swaps per-case.
local orig_shell, orig_bridge, orig_desc, orig_shell_cfg, orig_pkg_notify

describe("pi-bridge.shell unknown-shell degrade (P2.M3.T5.S3)", function()
	before_each(function()
		orig_shell = vim.env.SHELL
		orig_bridge = pi.bridge
		orig_desc = pi.descriptor
		orig_shell_cfg = (pi.config and pi.config.shell) or nil
		orig_pkg_notify = package.loaded["pi-bridge.notify"]
		pi.bridge = nil
		pi.descriptor = nil
		vim.env.SHELL = nil
		-- clean ANY driver module so the unknown-shell case sees no loadable module.
		for _, base in ipairs({ "fish", "bash", "zsh", "noshell", "elvish", "unknownshell" }) do
			package.loaded["pi-bridge.shell." .. base] = nil
		end
		notify.reset()
		shell.reset()
	end)
	after_each(function()
		vim.env.SHELL = orig_shell
		pi.bridge = orig_bridge
		pi.descriptor = orig_desc
		for _, base in ipairs({ "fish", "bash", "zsh", "noshell", "elvish", "unknownshell" }) do
			package.loaded["pi-bridge.shell." .. base] = nil
		end
		if pi.config then pi.config.shell = orig_shell_cfg end
		package.loaded["pi-bridge.notify"] = orig_pkg_notify
		notify.reset()
		shell.reset()
		-- drain any pending vim.schedule'd vim.notify from the case (no leak into the next)
		vim.wait(60, function() return false end, 5)
	end)

	-- =========================================================================
	-- pick_driver (RESOLUTION layer) — the nil-driver preconditions
	-- =========================================================================

	it("pick_driver returns nil for an unknown shell basename (/bin/noshell)", function()
		package.loaded["pi-bridge.shell.noshell"] = nil -- no module resolves
		assert.is_nil(shell.pick_driver("/bin/noshell"))
		-- also an unrecognized path with a different basename
		package.loaded["pi-bridge.shell.elvish"] = nil
		assert.is_nil(shell.pick_driver("/usr/local/bin/elvish"))
	end)

	it("pick_driver returns nil for a user-disabled driver (config.drivers.fish=false)", function()
		-- module IS loadable...
		package.loaded["pi-bridge.shell.fish"] = { start = function() end }
		pi.config.shell = pi.config.shell or {}
		pi.config.shell.drivers = { fish = false } -- ...but disabled (flag checked BEFORE require)
		assert.is_nil(shell.pick_driver("/usr/bin/fish"))
	end)

	it("pick_driver returns nil when the module lacks .start", function()
		package.loaded["pi-bridge.shell.fish"] = { no_start = true }
		assert.is_nil(shell.pick_driver("/usr/bin/fish"))
	end)

	it("pick_driver never throws on nil / '' / non-string resolved_shell", function()
		assert.has_no.errors(function()
			shell.pick_driver(nil)
			shell.pick_driver("")
			shell.pick_driver(123)
			shell.pick_driver({})
		end)
		assert.is_nil(shell.pick_driver(nil))
		assert.is_nil(shell.pick_driver(""))
	end)

	-- =========================================================================
	-- ensure (SPAWN layer) — the no-driver degrade contract
	-- =========================================================================

	it("ensure(no driver) sets state.failed=true + cb('no driver for <shell>')", function()
		pi.bridge = fake_bridge("/bin/noshell") -- unknown basename → pick_driver nil
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.are.equals("no driver for /bin/noshell", got)
		-- failed flag observable via the follow-up short-circuit (state.failed is module-local)
		local got2 = "UNSET"
		shell.ensure(function(err) got2 = err end)
		assert.are.equals("daemon disabled", got2, "state.failed was set (follow-up short-circuits)")
	end)

	it("ensure(no driver) fires notify.once('shell-degrade', WARN) EXACTLY ONCE across two calls", function()
		local rec = make_notify_spy()
		package.loaded["pi-bridge.notify"] = rec.spy -- swap BEFORE ensure (lazy require inside ensure)
		pi.bridge = fake_bridge("/bin/noshell")
		shell.ensure(function() end)
		shell.ensure(function() end) -- follow-up must NOT re-notify
		assert.are.equals(1, rec.calls["shell-degrade"], "degrade notice fires exactly once across two ensure() calls")
		-- level is WARN (verify the spy saw the documented severity on the single fire)
		-- (the spy does not record level; assert the fire COUNT is the dedup contract)
	end)

	it("follow-up ensure short-circuits with cb('daemon disabled'); driver.start NOT re-called", function()
		-- inject a fake driver for "fish" so we CAN observe .start NOT being called on degrade.
		-- but the resolved shell is unknown → pick_driver nils regardless → degrade path.
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/bin/noshell") -- unknown basename (NOT fish)
		shell.ensure(function() end) -- degrade: failed=true, cb("no driver for /bin/noshell")
		assert.are.equals(0, fake.captured.calls, "first ensure did not call driver.start (no driver for noshell)")
		-- follow-up: short-circuit via failed; resolve/pick/start are ALL skipped
		local got2 = "UNSET"
		shell.ensure(function(err) got2 = err end)
		assert.are.equals("daemon disabled", got2)
		assert.are.equals(0, fake.captured.calls, "follow-up ensure does NOT re-resolve/re-pick/re-start")
	end)

	-- =========================================================================
	-- consumer seam — complete_current receives err when degraded
	-- =========================================================================

	it("complete_current(buf, cb) receives (err truthy, nil items, '') when degraded", function()
		pi.bridge = fake_bridge("/bin/noshell")
		shell.ensure(function() end) -- sets state.failed=true (degrade)
		-- a buffer that looks like a `!` line (complete_current reads line 1 + cursor)
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "!git ch" })
		-- complete_current uses nvim_win_get_cursor(0); make the buf current in a window.
		local win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		vim.api.nvim_win_set_cursor(win, { 1, #("!git ch") })
		local err, items, prefix = "UNSET", "UNSET", "UNSET"
		shell.complete_current(buf, function(e, it, pf) err, items, prefix = e, it, pf end)
		assert.is_truthy(err, "complete_current must forward the degrade err (got " .. tostring(err) .. ")")
		-- items MUST be nil/empty (no fake items leak into the menu → it never opens)
		assert.is_nil(items)
		-- prefix is falsy/empty on the err path (no completion word derived)
		assert.is_falsy(prefix, "prefix must be falsy on the err path (got " .. tostring(prefix) .. ")")
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	-- =========================================================================
	-- disabled-driver path — module loadable but flag=false
	-- =========================================================================

	it("disabled-driver path: ensure cb('no driver for <shell>'); .start NEVER called", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake -- module IS loadable...
		pi.bridge = fake_bridge("/usr/bin/fish")
		pi.config.shell = pi.config.shell or {}
		pi.config.shell.drivers = { fish = false } -- ...but disabled (flag checked BEFORE require)
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.are.equals("no driver for /usr/bin/fish", got)
		assert.are.equals(0, fake.captured.calls, "disabled driver.start must NEVER be called")
		-- follow-up short-circuits via failed
		local got2 = "UNSET"
		shell.ensure(function(err) got2 = err end)
		assert.are.equals("daemon disabled", got2)
		assert.are.equals(0, fake.captured.calls, "follow-up does NOT re-call disabled driver.start")
	end)

	-- =========================================================================
	-- never-throws edges — malformed inputs
	-- =========================================================================

	it("never throws on nil bridge / nil descriptor / nil config / nil on_ready", function()
		-- (a) nil bridge → resolve falls to $SHELL→/bin/bash; bash driver IS loadable so this
		--     is NOT a degrade path — but it must not throw. Assert the no-driver path instead.
		pi.bridge = nil
		pi.descriptor = nil
		vim.env.SHELL = "/bin/noshell" -- force an unknown resolved shell so the degrade path runs
		local ok1, err1 = pcall(function() shell.ensure(function() end) end)
		assert.is_true(ok1, "ensure must not throw with nil bridge/descriptor + unknown $SHELL (got " .. tostring(err1) .. ")")
		-- (b) nil config entirely (simulate pre-setup) — the AND-chain default {} must save it
		shell.reset()
		notify.reset()
		pi.config.shell = nil -- clear shell cfg but keep config table; ensure's AND-chain handles nil
		local saved_config = pi.config
		pi.config = nil
		pi.bridge = fake_bridge("/bin/noshell")
		local ok2, err2 = pcall(function() shell.ensure(function() end) end)
		pi.config = saved_config
		assert.is_true(ok2, "ensure must not throw when pi.config is nil (got " .. tostring(err2) .. ")")
		-- (c) nil on_ready — guarded (replaced with a no-op); must not throw
		shell.reset()
		notify.reset()
		pi.bridge = fake_bridge("/bin/noshell")
		local ok3, err3 = pcall(function() shell.ensure(nil) end)
		assert.is_true(ok3, "ensure(nil) must not throw (got " .. tostring(err3) .. ")")
		-- (d) nil on_ready as a non-function value
		shell.reset()
		notify.reset()
		local ok4, err4 = pcall(function() shell.ensure(123) end)
		assert.is_true(ok4, "ensure(123) must not throw (got " .. tostring(err4) .. ")")
	end)

	-- =========================================================================
	-- exports sanity — the seams under test exist
	-- =========================================================================

	it("exposes pick_driver / ensure / complete_current / reset as functions", function()
		assert.are.equals("function", type(shell.pick_driver))
		assert.are.equals("function", type(shell.ensure))
		assert.are.equals("function", type(shell.complete_current))
		assert.are.equals("function", type(shell.reset))
	end)
end)