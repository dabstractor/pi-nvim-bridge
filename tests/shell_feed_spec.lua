-- === tests/shell_feed_spec.lua — plenary/busted spec (the Level-2 gate, P2.M1.T2.S5) ===
-- Covers every Success Criterion of shell.lua's RESPONSE-PARSE layer (M._feed: §17.5.1
-- sentinel slicing + §17.5.2 normalize → AutocompleteItem[] + §17.12 parse-failure counter).
-- MOCKS the bridge + injects a FAKE driver (so the REAL M.ensure resolves "fish" + caches
-- the FAKE stdin into state) + feeds CANNED response strings to M._feed. NO subprocess.
--
-- Response delivery: state.pending_cb is module-local, so delivery tests ARM it via the
-- REAL M.request (S4) backed by the fake-driver-backed ensure (state is module-local — no
-- direct setter). Parse-FAILURE tests feed malformed directly (no request needed) + assert
-- via the ensure→"daemon disabled" probe (the observable for state.failed).
--
-- NOTE: do NOT name a spec-local table `pending` — it shadows plenary.busted's global
-- `pending` (the test-SKIP function). We use `got`/`cb`/`captured` locals.
--
-- Run (from the repo root):
--   timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shell_feed_spec.lua")'
local pi = require("pi-bridge")
local shell = require("pi-bridge.shell")

if pi.config == nil then pi.setup({}) end -- self-sufficient (mirror completion_spec.lua L18)

-- --- a fake bridge exposing get_shell_info() (controls the resolved shell) so the REAL
-- M.ensure resolves a "fish" basename → the injected fake driver.
local function fake_bridge(shell_path)
	return {
		get_shell_info = function()
			if shell_path == nil then return nil end
			return { shell = shell_path }
		end,
		server_info = {},
	}
end

-- --- the fake driver + fake pipes (mirrors the luv handle shape from
-- tests/shell_fish_spike.lua: read_start/write/close/read_stop/is_closing) so the
-- read_start wiring + the teardown-guard methods exist WITHOUT a real subprocess.
-- `start` calls cb SYNCHRONOUSLY — no vim.wait needed.
local function make_fake_driver()
	local captured = { opts = nil, calls = 0, read_cb = nil }
	local function fake_pipe()
		return {
			read_start = function(_, cb) captured.read_cb = cb end, -- ensure wires this; tests invoke it
			write      = function(_, _data, wcb) if wcb then wcb(nil) end end, -- request() writes the frame; cb(nil)=OK
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
			cb(nil, { is_closing = function() return false end }, fake_pipe(), fake_pipe())
		end,
	}
end

-- --- DELIVERY helper: arm pending_cb via request() (S4) + feed a canned response, capture cb.
-- feeds: a string → one _feed; a TABLE of chunk strings → sequential _feeds (split-across).
-- Returns the captured {err, items, prefix} + the fake driver.
local function feed_and_capture(feeds, extra_cfg)
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	if extra_cfg then
		pi.config.shell = vim.tbl_extend("keep", extra_cfg, pi.config.shell or {})
	end
	shell.ensure(function() end) -- caches fake stdin/stdout + wires read_cb
	local captured = { err = "UNSET", items = nil, prefix = nil }
	shell.request("git ch", 6, "", function(err, items, prefix)
		captured = { err = err, items = items, prefix = prefix }
	end)                        -- ARMS state.pending_cb (S4); writes the frame
	local list = (type(feeds) == "table") and feeds or { feeds }
	for _, chunk in ipairs(list) do shell._feed(chunk) end
	return captured, fake
end

-- --- save/restore the globals the spec swaps per-case.
local orig_shell, orig_bridge, orig_desc, orig_shell_cfg

describe("pi-bridge.shell _feed (P2.M1.T2.S5)", function()
	before_each(function()
		orig_shell = vim.env.SHELL
		orig_bridge = pi.bridge
		orig_desc = pi.descriptor
		orig_shell_cfg = (pi.config and pi.config.shell) or nil
		pi.bridge = nil
		pi.descriptor = nil
		vim.env.SHELL = nil
		package.loaded["pi-bridge.shell.fish"] = nil
		-- give each test a FRESH shell config table. Tests that set
		-- `pi.config.shell.max_parse_failures` mutate the table IN PLACE; capturing the
		-- ref above + restoring it in after_each would NOT undo an in-place mutation
		-- (the restored ref still carries the old threshold → leaks into later tests,
		-- causing false "daemon disabled" observations). A fresh {} per test isolates them.
		if pi.config then pi.config.shell = {} end
		shell.reset()
	end)
	after_each(function()
		vim.env.SHELL = orig_shell
		pi.bridge = orig_bridge
		pi.descriptor = orig_desc
		package.loaded["pi-bridge.shell.fish"] = nil
		if pi.config then pi.config.shell = orig_shell_cfg end
		shell.reset()
	end)

	it("parses a single complete pair → pending_cb(items, prefix); rx_buf drained", function()
		local c = feed_and_capture(
			"__PIRESP_START__\n"
			.. '{"items":[{"value":"checkout","description":"Checkout a branch"}],"prefix":"ch"}'
			.. "\n__PIRESP_END__\n"
		)
		assert.is_nil(c.err)
		assert.are.equals(1, #c.items)
		assert.are.equals("checkout", c.items[1].value)
		assert.are.equals("checkout", c.items[1].label) -- label defaults to value
		assert.are.equals("Checkout a branch", c.items[1].description)
		assert.are.equals("ch", c.prefix)
	end)

	it("drains TWO pairs in ONE chunk (drain loop); first delivered, second no-op'd (one-shot)", function()
		local pair1 = "__PIRESP_START__\n" .. '{"items":[{"value":"a"}],"prefix":""}' .. "\n__PIRESP_END__\n"
		local pair2 = "__PIRESP_START__\n" .. '{"items":[{"value":"b"}],"prefix":""}' .. "\n__PIRESP_END__\n"
		local c = feed_and_capture(pair1 .. pair2)
		assert.is_nil(c.err)
		assert.are.equals(1, #c.items)
		assert.are.equals("a", c.items[1].value) -- first pair; second no-op'd by one-shot slot
	end)

	it("reassembles a pair split across two _feed calls (1st buffers, 2nd delivers)", function()
		local c = feed_and_capture({
			"__PIRESP_START__\n" .. '{"items":[{"value":"x"}],"prefix":""}\n', -- partial (no END yet)
			"__PIRESP_END__\n",                                               -- completes the pair
		})
		assert.is_nil(c.err)
		assert.are.equals(1, #c.items)
		assert.are.equals("x", c.items[1].value)
	end)

	it("discards noise outside the sentinels (prompt before/after); payload parses", function()
		local c = feed_and_capture(
			"prompt$ __PIRESP_START__\n" .. '{"items":[]}' .. "\n__PIRESP_END__\n trail$ "
		)
		assert.is_nil(c.err)
		assert.are.equals(0, #c.items) -- empty items (NOT a parse failure)
		assert.are.equals("", c.prefix)
	end)

	it("empty items array {\"items\":[]} → pending_cb({}, ''); NOT a parse failure", function()
		local c = feed_and_capture("__PIRESP_START__\n" .. '{"items":[]}' .. "\n__PIRESP_END__\n")
		assert.is_nil(c.err)
		assert.are.same({}, c.items)
		assert.are.equals("", c.prefix)
		-- daemon NOT disabled (empty array is success)
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.is_nil(got)
	end)

	it("malformed JSON → parse_failures++; pending_cb NOT called; 1 failure NOT yet disabled", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		-- arm pending_cb (so we can assert it was NOT called)
		shell.ensure(function() end)
		local calls = 0
		shell.request("x", 1, "", function() calls = calls + 1 end)
		shell._feed("__PIRESP_START__\n{bad json}\n__PIRESP_END__\n")
		assert.are.equals(0, calls, "pending_cb must NOT be called on malformed JSON")
		-- NOT disabled after 1 (threshold 5)
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.is_nil(got)
	end)

	it("N=5 consecutive malformed → state.failed=true → ensure 'daemon disabled'", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		local malformed = "__PIRESP_START__\n{bad json}\n__PIRESP_END__\n"
		for _ = 1, 5 do shell._feed(malformed) end
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.are.equals("daemon disabled", got)
	end)

	it("threshold via config.shell.max_parse_failures=3 → disabled after 3 (NOT 5)", function()
		-- 3 with config=3 → disabled
		pi.config.shell = pi.config.shell or {}
		pi.config.shell.max_parse_failures = 3
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		local malformed = "__PIRESP_START__\n{bad json}\n__PIRESP_END__\n"
		for _ = 1, 3 do shell._feed(malformed) end
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.are.equals("daemon disabled", got)
	end)

	it("threshold default 5: 3 failures do NOT disable", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		local malformed = "__PIRESP_START__\n{bad json}\n__PIRESP_END__\n"
		for _ = 1, 3 do shell._feed(malformed) end
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.is_nil(got, "3 failures with default threshold 5 must NOT disable (got " .. tostring(got) .. ")")
	end)

	it("a mid-stream SUCCESS resets parse_failures (4 fail + 1 success + 4 fail → NOT disabled)", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		local malformed = "__PIRESP_START__\n{bad json}\n__PIRESP_END__\n"
		local valid = "__PIRESP_START__\n" .. '{"items":[]}' .. "\n__PIRESP_END__\n"
		for _ = 1, 4 do shell._feed(malformed) end -- parse_failures = 4
		shell._feed(valid)                         -- SUCCESS → reset to 0
		for _ = 1, 4 do shell._feed(malformed) end -- parse_failures = 4 (not yet 5)
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.is_nil(got, "4+1success+4 must NOT disable (consecutive counter reset)")
	end)

	it("prefix read from decoded.prefix (honored); missing prefix → ''", function()
		-- explicit prefix
		local c1 = feed_and_capture("__PIRESP_START__\n" .. '{"items":[],"prefix":"git"}' .. "\n__PIRESP_END__\n")
		assert.are.equals("git", c1.prefix)
		-- no prefix key → default ""
		local c2 = feed_and_capture("__PIRESP_START__\n" .. '{"items":[]}' .. "\n__PIRESP_END__\n")
		assert.are.equals("", c2.prefix)
	end)

	it("label = item.label or item.value (defensive; description-less items get label==value)", function()
		local c = feed_and_capture(
			"__PIRESP_START__\n"
			.. '{"items":[{"value":"x"},{"value":"y","label":"Y"}]}' .. "\n__PIRESP_END__\n"
		)
		assert.are.equals(2, #c.items)
		assert.are.equals("x", c.items[1].label) -- defaults to value
		assert.are.equals("Y", c.items[2].label) -- explicit honored
	end)

	it("malformed items are DROPPED (non-table / non-string-value / empty-value)", function()
		local c = feed_and_capture(
			"__PIRESP_START__\n"
			.. '{"items":[{"value":"ok"},42,{"value":""},{"description":"no value"},null]}' .. "\n__PIRESP_END__\n"
		)
		assert.is_nil(c.err)
		assert.are.equals(1, #c.items, "only the well-formed {value:'ok'} survives")
		assert.are.equals("ok", c.items[1].value)
	end)

	it("never throws on nil / '' / garbage / bare-number / non-array-items", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		assert.has_no.errors(function()
			shell._feed(nil) -- EOF → _reset (no throw)
		end)
		-- after _reset (failed=true), reset + re-ensure for the rest
		shell.reset()
		shell.ensure(function() end)
		assert.has_no.errors(function()
			shell._feed("")                                            -- no-op
			shell._feed("garbage no sentinels")                       -- buffers, no throw
			shell._feed("__PIRESP_START__\n42\n__PIRESP_END__\n")      -- bare number → parse_failure (no throw)
			shell._feed('__PIRESP_START__\n{"items":"notarray"}\n__PIRESP_END__\n') -- non-array items → {} (no throw)
		end)
	end)

	it("pending_cb nil-safe: _feed(valid pair) with no request does not throw + does not disable", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		-- NO request() call → pending_cb is nil
		assert.has_no.errors(function()
			shell._feed("__PIRESP_START__\n" .. '{"items":[{"value":"z"}]}' .. "\n__PIRESP_END__\n")
		end)
		-- daemon still healthy (a nil cb delivery is not a failure)
		local got = "UNSET"
		shell.ensure(function(e) got = e end)
		assert.is_nil(got)
	end)

	it("EOF: _feed(nil) → M._reset → ensure 'daemon disabled'", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		shell._feed(nil)
		local got = "UNSET"
		shell.ensure(function(err) got = err end)
		assert.are.equals("daemon disabled", got)
	end)

	it("rx_buf drained: after one valid pair, a second valid pair parses cleanly (not wedged)", function()
		local c1 = feed_and_capture("__PIRESP_START__\n" .. '{"items":[{"value":"first"}]}' .. "\n__PIRESP_END__\n")
		assert.are.equals(1, #c1.items)
		assert.are.equals("first", c1.items[1].value)
		-- second pair (pending_cb nil'd by one-shot → no delivery, but must parse without throw)
		assert.has_no.errors(function()
			shell._feed("__PIRESP_START__\n" .. '{"items":[{"value":"second"}]}' .. "\n__PIRESP_END__\n")
		end)
		-- daemon still healthy
		local got = "UNSET"
		shell.ensure(function(e) got = e end)
		assert.is_nil(got)
	end)

	it("read_cb route: feed via the S3 fake-driver captured read_cb (the prod caller path)", function()
		local fake = make_fake_driver()
		package.loaded["pi-bridge.shell.fish"] = fake
		pi.bridge = fake_bridge("/usr/bin/fish")
		shell.ensure(function() end)
		assert.is_truthy(fake.captured.read_cb)
		local captured = { err = "UNSET" }
		shell.request("git ch", 6, "", function(err, items, prefix)
			captured = { err = err, items = items, prefix = prefix }
		end)
		-- deliver via the SAME path the real luv read_start uses
		fake.captured.read_cb(nil, "__PIRESP_START__\n"
			.. '{"items":[{"value":"checkout"}],"prefix":"ch"}' .. "\n__PIRESP_END__\n")
		assert.is_nil(captured.err)
		assert.are.equals(1, #captured.items)
		assert.are.equals("checkout", captured.items[1].value)
		assert.are.equals("ch", captured.prefix)
	end)

	it("exposes M._feed as a function (signature unchanged from S3)", function()
		assert.are.equals("function", type(shell._feed))
	end)
end)