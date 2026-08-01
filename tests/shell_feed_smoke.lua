-- === tests/shell_feed_smoke.lua — standalone (plenary-FREE) smoke test (P2.M1.T2.S5) ===
-- The Level-2 gate for the shell.lua RESPONSE-PARSE layer (M._feed: §17.5.1 sentinel
-- slicing + §17.5.2 normalize → AutocompleteItem[] + §17.12 parse-failure counter):
-- instant, dependency-free feedback (no plenary). Exercises the full parse matrix
-- (happy-path single/multi-pair, split-across-chunks, noise-outside-discarded,
-- empty-items, malformed→parse_failure, threshold→disabled, threshold-config,
-- consecutive-reset, prefix-passthrough, label-from-value, never-throws,
-- pending_cb-nil-safe, EOF) with CANNED response strings fed to M._feed (+ the S3
-- fake-driver read_cb). ZERO subprocess (the live fish seam was proven by S1's spike;
-- S5 is pure string+table work).
--
-- Run from the repo root:
--   timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_feed_smoke.lua" +qa
--   echo "exit=$?"   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed
--
-- AGENTS.md HARD RULE: this is a FILE on disk run via :luafile — NEVER pipe a heredoc
-- into nvim's stdin (`nvim ... +"luafile /dev/stdin" +qa <<EOF` HANGS the session).
local me = debug.getinfo(1, "S").source:sub(2)
me = vim.fn.fnamemodify(me, ":p")
local plugin_root = vim.fn.fnamemodify(me, ":h:h") -- .../<repo-root> (the runtimepath entry)
vim.opt.runtimepath:append(plugin_root)

local pi = require("pi-bridge")
if pi.config == nil then pi.setup({}) end -- self-sufficient (mirror smoke.lua GOTCHA D)
local shell = require("pi-bridge.shell")

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end

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
			captured.opts = opts -- assert shell/startup_timeout_ms
			cb(nil, { is_closing = function() return false end }, fake_pipe(), fake_pipe())
		end,
	}
end

-- --- save/restore the globals the smoke swaps per-case.
local orig_shell = vim.env.SHELL
local orig_bridge = pi.bridge
local orig_desc = pi.descriptor
local orig_shell_cfg = (pi.config and pi.config.shell) or nil

local function restore()
	vim.env.SHELL = orig_shell
	pi.bridge = orig_bridge
	pi.descriptor = orig_desc
	package.loaded["pi-bridge.shell.fish"] = nil
	if pi.config then pi.config.shell = orig_shell_cfg end -- nil restores "no shell cfg"
	shell.reset()
end

-- ===========================================================================
-- DELIVERY helper: arm pending_cb via request() (S4) + feed a canned response, capture cb.
-- feeds: a string → one _feed; a TABLE of chunk strings → sequential _feeds (split-across).
-- Returns the captured {err, items, prefix} + the fake driver.
-- ===========================================================================
local function feed_and_capture(feeds, extra_cfg)
	restore()
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

-- ===========================================================================
-- PARSE-FAILURE helper: feed malformed N times (no request needed), probe state.failed
-- via ensure. Returns the ensure-probe err string ("daemon disabled" if threshold tripped).
-- ===========================================================================
local function feed_malformed_and_probe(payload, n, extra_cfg)
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	if extra_cfg then
		pi.config.shell = vim.tbl_extend("keep", extra_cfg, pi.config.shell or {})
	end
	for _ = 1, n do shell._feed(payload) end -- parse_failures += 1 each (pending_cb nil → no delivery)
	local got = "UNSET"
	shell.ensure(function(err) got = err end) -- if failed → "daemon disabled"; else nil (spawns fake)
	return got, fake
end

-- ===========================================================================
-- (1) HAPPY-PATH-SINGLE: one complete pair → items parsed + prefix "ch" + label==value + description
-- ===========================================================================
do
	local captured = feed_and_capture(
		"__PIRESP_START__\n"
		.. '{"items":[{"value":"checkout","description":"Checkout a branch"}],"prefix":"ch"}'
		.. "\n__PIRESP_END__\n"
	)
	check(captured.err == nil, "happy-single: err==nil (got " .. tostring(captured.err) .. ")")
	check(captured.items ~= nil and #captured.items == 1,
		"happy-single: 1 item (got " .. tostring(captured.items and #captured.items) .. ")")
	if captured.items and captured.items[1] then
		check(captured.items[1].value == "checkout",
			"happy-single: value=='checkout' (got " .. tostring(captured.items[1].value) .. ")")
		check(captured.items[1].label == "checkout",
			"happy-single: label=='checkout' (label defaults to value) (got " .. tostring(captured.items[1].label) .. ")")
		check(captured.items[1].description == "Checkout a branch",
			"happy-single: description passed through (got " .. tostring(captured.items[1].description) .. ")")
	end
	check(captured.prefix == "ch", "happy-single: prefix=='ch' (got " .. tostring(captured.prefix) .. ")")
	-- rx_buf drained: a SECOND valid pair in a new _feed parses cleanly (proves rx_buf advanced)
	-- (covered separately in case 13)
end

-- ===========================================================================
-- (2) MULTI-PAIR-ONE-CHUNK: TWO complete pairs in ONE _feed → drain loop; FIRST delivered
-- (the 2nd is a no-op because S4 nil'd the slot one-shot)
-- ===========================================================================
do
	local pair1 = "__PIRESP_START__\n" .. '{"items":[{"value":"a"}],"prefix":""}' .. "\n__PIRESP_END__\n"
	local pair2 = "__PIRESP_START__\n" .. '{"items":[{"value":"b"}],"prefix":""}' .. "\n__PIRESP_END__\n"
	local captured = feed_and_capture(pair1 .. pair2)
	check(captured.err == nil, "multi-pair: err==nil (got " .. tostring(captured.err) .. ")")
	check(captured.items ~= nil and #captured.items == 1,
		"multi-pair: first pair delivered (1 item) (got " .. tostring(captured.items and #captured.items) .. ")")
	if captured.items and captured.items[1] then
		check(captured.items[1].value == "a",
			"multi-pair: first item value=='a' (2nd pair no-op'd by one-shot) (got " .. tostring(captured.items[1].value) .. ")")
	end
end

-- ===========================================================================
-- (3) SPLIT-ACROSS-CHUNKS: a pair split across two _feed calls → 1st buffers, 2nd delivers
-- ===========================================================================
do
	local captured = feed_and_capture({
		"__PIRESP_START__\n" .. '{"items":[{"value":"x"}],"prefix":""}\n', -- partial (no END yet)
		"__PIRESP_END__\n",                                               -- completes the pair
	})
	check(captured.err == nil, "split: err==nil (got " .. tostring(captured.err) .. ")")
	check(captured.items ~= nil and #captured.items == 1,
		"split: 1 item reassembled across chunks (got " .. tostring(captured.items and #captured.items) .. ")")
	if captured.items and captured.items[1] then
		check(captured.items[1].value == "x",
			"split: value=='x' (got " .. tostring(captured.items[1].value) .. ")")
	end
end

-- ===========================================================================
-- (4) NOISE-OUTSIDE-DISCARDED: prompt before/after sentinels → payload parses; empty items;
-- no parse_failure (noise outside is buffered-then-discarded)
-- ===========================================================================
do
	local captured = feed_and_capture(
		"prompt$ __PIRESP_START__\n" .. '{"items":[]}' .. "\n__PIRESP_END__\n trail$ "
	)
	check(captured.err == nil, "noise-outside: err==nil (got " .. tostring(captured.err) .. ")")
	check(captured.items ~= nil and #captured.items == 0,
		"noise-outside: empty items {} (NOT a parse failure) (got " .. tostring(captured.items and #captured.items) .. ")")
	check(captured.prefix == "", "noise-outside: prefix defaults to '' (got " .. tostring(captured.prefix) .. ")")
end

-- ===========================================================================
-- (5) EMPTY-ITEMS-ARRAY: {"items":[]} → pending_cb({}, "") (NOT a parse_failure)
-- ===========================================================================
do
	local captured = feed_and_capture("__PIRESP_START__\n" .. '{"items":[]}' .. "\n__PIRESP_END__\n")
	check(captured.err == nil, "empty-items: err==nil (got " .. tostring(captured.err) .. ")")
	check(captured.items ~= nil and #captured.items == 0,
		"empty-items: items=={} (got " .. tostring(captured.items and #captured.items) .. ")")
	check(captured.prefix == "", "empty-items: prefix=='' (got " .. tostring(captured.prefix) .. ")")
	-- after empty-items, ensure still works (NOT failed — empty array is success)
	local got = "UNSET"
	shell.ensure(function(err) got = err end)
	check(got == nil, "empty-items: daemon NOT disabled (empty items is success) (got " .. tostring(got) .. ")")
end

-- ===========================================================================
-- (6) MALFORMED-INCREMENTS-parse_failures: ONE malformed → NOT yet disabled (parse_failures==1)
-- ===========================================================================
do
	local got = feed_malformed_and_probe("__PIRESP_START__\n{bad json}\n__PIRESP_END__\n", 1)
	check(got == nil,
		"malformed-1: NOT disabled after 1 failure (threshold 5) (got " .. tostring(got) .. ")")
end

-- ===========================================================================
-- (7) THRESHOLD-5-DISABLES: 5 malformed → ensure → "daemon disabled" (failed=true; teardown fwd-guard no-op)
-- ===========================================================================
do
	local got = feed_malformed_and_probe("__PIRESP_START__\n{bad json}\n__PIRESP_END__\n", 5)
	check(got == "daemon disabled",
		"threshold-5: disabled after 5 consecutive failures (got " .. tostring(got) .. ")")
end

-- ===========================================================================
-- (8) THRESHOLD-CONFIG: cfg.max_parse_failures=3 → disabled after 3 (NOT 5)
-- ===========================================================================
do
	local got = feed_malformed_and_probe(
		"__PIRESP_START__\n{bad json}\n__PIRESP_END__\n", 3, { max_parse_failures = 3 }
	)
	check(got == "daemon disabled",
		"threshold-config: disabled after 3 (cfg.max_parse_failures=3) (got " .. tostring(got) .. ")")
	-- sanity: 3 with the DEFAULT (5) does NOT disable
	local got2 = feed_malformed_and_probe("__PIRESP_START__\n{bad json}\n__PIRESP_END__\n", 3)
	check(got2 == nil,
		"threshold-config: 3 with default 5 does NOT disable (got " .. tostring(got2) .. ")")
end

-- ===========================================================================
-- (9) CONSECUTIVE-RESET: 4 fail + 1 SUCCESS (resets) + 4 fail → NOT yet disabled
-- (proves success resets parse_failures to 0)
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	local malformed = "__PIRESP_START__\n{bad json}\n__PIRESP_END__\n"
	local valid = "__PIRESP_START__\n" .. '{"items":[]}' .. "\n__PIRESP_END__\n"
	for _ = 1, 4 do shell._feed(malformed) end -- parse_failures = 4 (pending_cb nil → silent)
	shell._feed(valid)                         -- SUCCESS → parse_failures resets to 0
	for _ = 1, 4 do shell._feed(malformed) end -- parse_failures = 4 (not yet 5)
	local got = "UNSET"
	shell.ensure(function(err) got = err end)
	check(got == nil,
		"consecutive-reset: 4+1success+4 NOT disabled (success reset the counter) (got " .. tostring(got) .. ")")
end

-- ===========================================================================
-- (10) PREFIX-PASSTHROUGH: decoded.prefix honored; a payload WITHOUT prefix → prefix==""
-- ===========================================================================
do
	-- (10a) explicit prefix
	local c1 = feed_and_capture(
		"__PIRESP_START__\n" .. '{"items":[],"prefix":"git"}' .. "\n__PIRESP_END__\n"
	)
	check(c1.prefix == "git", "prefix-passthrough: explicit 'git' (got " .. tostring(c1.prefix) .. ")")
	-- (10b) no prefix key → default ""
	local c2 = feed_and_capture("__PIRESP_START__\n" .. '{"items":[]}' .. "\n__PIRESP_END__\n")
	check(c2.prefix == "", "prefix-passthrough: missing prefix → '' (got " .. tostring(c2.prefix) .. ")")
end

-- ===========================================================================
-- (11) LABEL-FROM-VALUE: {value} (no label) → label==value; {value,label="Y"} → label=="Y"
-- ===========================================================================
do
	local c = feed_and_capture(
		"__PIRESP_START__\n"
		.. '{"items":[{"value":"x"},{"value":"y","label":"Y"}]}' .. "\n__PIRESP_END__\n"
	)
	check(c.items ~= nil and #c.items == 2, "label-from-value: 2 items (got " .. tostring(c.items and #c.items) .. ")")
	if c.items and c.items[1] then
		check(c.items[1].label == "x",
			"label-from-value: item1 label=='x' (defaults to value) (got " .. tostring(c.items[1].label) .. ")")
	end
	if c.items and c.items[2] then
		check(c.items[2].label == "Y",
			"label-from-value: item2 label=='Y' (explicit honored) (got " .. tostring(c.items[2].label) .. ")")
	end
end

-- ===========================================================================
-- (12) NEVER-THROWS: _feed(nil)/("")/("garbage")/(bare-number)/(non-array-items) — no throw
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	local ok, err = pcall(function()
		shell._feed(nil)                                            -- EOF → _reset (no throw)
	end)
	-- after _reset, failed=true; re-ensure + re-drive for the rest
	shell.reset()
	shell.ensure(function() end)
	local ok2 = pcall(function()
		shell._feed("")                                            -- no-op
		shell._feed("garbage no sentinels")                       -- buffers, no throw
		shell._feed("__PIRESP_START__\n42\n__PIRESP_END__\n")      -- bare number → parse_failure (no throw)
		shell._feed('__PIRESP_START__\n{"items":"notarray"}\n__PIRESP_END__\n') -- non-array items → {} (no throw)
	end)
	check(ok, "never-throws: _feed(nil) does not throw (got " .. tostring(err) .. ")")
	check(ok2, "never-throws: _feed('')/garbage/bare-number/non-array-items do not throw")
	-- after bare-number: parse_failures==1 (NOT disabled)
	local got = "UNSET"
	shell.ensure(function(e) got = e end)
	check(got == nil, "never-throws: bare-number was 1 parse_failure (not disabled) (got " .. tostring(got) .. ")")
end

-- ===========================================================================
-- (13) PENDING-CB-NIL-SAFE: no request armed → _feed(valid pair) parses silently (no throw)
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	-- NO request() call → pending_cb is nil
	local ok = pcall(function()
		shell._feed("__PIRESP_START__\n" .. '{"items":[{"value":"z"}]}' .. "\n__PIRESP_END__\n")
	end)
	check(ok, "pending_cb-nil-safe: _feed(valid) with no request does not throw")
	-- daemon still healthy (a nil cb delivery is not a failure)
	local got = "UNSET"
	shell.ensure(function(e) got = e end)
	check(got == nil, "pending_cb-nil-safe: daemon NOT disabled (got " .. tostring(got) .. ")")
end

-- ===========================================================================
-- (14) EOF: _feed(nil) → M._reset → ensure "daemon disabled"
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	shell._feed(nil) -- EOF → _reset → failed=true
	local got = "UNSET"
	shell.ensure(function(err) got = err end)
	check(got == "daemon disabled", "EOF: _feed(nil) → _reset → 'daemon disabled' (got " .. tostring(got) .. ")")
end

-- ===========================================================================
-- (15) RX_BUF-DRAINED: after one valid pair, a SECOND valid pair parses cleanly
-- (proves rx_buf was advanced past the first — not wedged concatenating)
-- ===========================================================================
do
	local c1 = feed_and_capture("__PIRESP_START__\n" .. '{"items":[{"value":"first"}]}' .. "\n__PIRESP_END__\n")
	check(c1.items ~= nil and #c1.items == 1 and c1.items[1].value == "first",
		"rx_buf-drained-1: first pair delivered")
	-- now feed a second pair (pending_cb was nil'd by the one-shot → no delivery, but must parse)
	local ok = pcall(function()
		shell._feed("__PIRESP_START__\n" .. '{"items":[{"value":"second"}]}' .. "\n__PIRESP_END__\n")
	end)
	check(ok, "rx_buf-drained-2: second pair parsed without throw (rx_buf was advanced, not wedged)")
	-- daemon still healthy after a second valid parse
	local got = "UNSET"
	shell.ensure(function(e) got = e end)
	check(got == nil, "rx_buf-drained-3: daemon NOT disabled after second valid parse (got " .. tostring(got) .. ")")
end

-- ===========================================================================
-- (16) READ_CB route: feed via the S3 fake-driver captured read_cb (the prod caller path)
-- ===========================================================================
do
	restore()
	local fake = make_fake_driver()
	package.loaded["pi-bridge.shell.fish"] = fake
	pi.bridge = fake_bridge("/usr/bin/fish")
	shell.ensure(function() end)
	check(fake.captured.read_cb ~= nil, "read_cb-route: read_cb captured by read_start")
	local captured = { err = "UNSET" }
	shell.request("git ch", 6, "", function(err, items, prefix)
		captured = { err = err, items = items, prefix = prefix }
	end)
	-- deliver via the SAME path the real luv read_start uses
	fake.captured.read_cb(nil, "__PIRESP_START__\n"
		.. '{"items":[{"value":"checkout"}],"prefix":"ch"}' .. "\n__PIRESP_END__\n")
	check(captured.err == nil, "read_cb-route: err==nil (got " .. tostring(captured.err) .. ")")
	check(captured.items ~= nil and #captured.items == 1 and captured.items[1].value == "checkout",
		"read_cb-route: item delivered via read_cb (got " .. tostring(captured.items and captured.items[1] and captured.items[1].value) .. ")")
end

restore()

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS\n")