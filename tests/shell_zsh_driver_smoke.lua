-- === tests/shell_zsh_driver_smoke.lua — plenary-FREE, LIVE-gated smoke (P2.M3.T5.S1) ===
-- The primary Level-2 gate for the REAL zsh driver. Spawns the real
-- `require("pi-bridge.shell.zsh")` driver end-to-end: start() → on_ready → sends 3
-- SEQUENTIAL framed requests through ONE daemon (persistence proof — the spike only did
-- one) → decodes each + asserts `checkout`/`cherry` appear for "git ch". Also exercises
-- M.cd(path) (best-effort advisory re-cd for zsh v1; asserts no throw).
--
-- GATED on `zsh` being on $PATH: prints SMOKE_SKIP + exits 0 if absent (PRD §17.15: never
-- fail CI for a missing optional shell). The driver reads STDERR for __PIREADY__ itself
-- (start step 5); this smoke reads ONLY stdout (post-on_ready).
--
-- Run from the REPO ROOT:
--   timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_zsh_driver_smoke.lua" +qa
--   echo "exit=$?"   # 0 = SMOKE_PASS (or SMOKE_SKIP if no zsh); 1 = FAIL
--
-- AGENTS.md HARD RULE: this IS a file on disk — run via :luafile. NEVER heredoc-to-nvim-stdin.
local zsh = require("pi-bridge.shell.zsh")
local uv = vim.uv

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end

if vim.fn.executable("zsh") == 0 then
	io.stdout:write("SMOKE_SKIP: zsh not on PATH — gate deferred (exit 0)\n")
	return -- chunk-level return; the +qa exits 0
end

-- the live proc/pipes handed to on_ready (captured for teardown at the end).
local g_proc, g_stdin, g_stdout

-- stdout rx buffer + sentinel parser (reuse the spike's try_parse: find the
-- __PIRESP_START__\n..__PIRESP_END__\n pair, vim.json.decode the body).
local rx_buf = ""
local current_resolver = nil -- set per-request; invoked with the decoded items table

local function try_parse()
	local s = rx_buf:find("__PIRESP_START__\n", 1, true)
	if not s then
		return
	end
	local ps = s + #"__PIRESP_START__\n"
	local e = rx_buf:find("__PIRESP_END__\n", ps, true)
	if not e then
		return
	end
	local payload = rx_buf:sub(ps, e - 1)
	rx_buf = rx_buf:sub(e + #"__PIRESP_END__\n")
	local dok, decoded = pcall(vim.json.decode, payload)
	if not dok or type(decoded) ~= "table" then
		return
	end
	local items = (type(decoded.items) == "table") and decoded.items or {}
	local r = current_resolver
	current_resolver = nil
	if r then
		r(items)
	end
end

-- send ONE framed request + resolve cb(items) on the decoded response (sequenced by the
-- caller so only ONE is in flight at a time).
local function request(line, cursor, after, cb)
	current_resolver = cb
	local frame = string.format(
		'__PIREQ__\t{"line":%s,"cursor":%d,"after":%s}',
		vim.json.encode(line),
		cursor,
		vim.json.encode(after or "")
	)
	pcall(function()
		g_stdin:write(frame .. "\n")
	end)
end

-- the daemon manager (shell.lua) owns stdout post-on_ready; for THIS isolated smoke we
-- wire read_start ourselves (the smoke stands in for shell.lua's _feed route).
local function wire_stdout()
	pcall(function()
		g_stdout:read_start(function(rerr, data)
			if rerr or not data then
				return
			end
			rx_buf = rx_buf .. data
			-- drain every complete pair in this chunk (a single chunk may carry multiple).
			while
				rx_buf:find("__PIRESP_START__\n", 1, true)
				and rx_buf:find("__PIRESP_END__\n", (rx_buf:find("__PIRESP_START__\n", 1, true) or 1) + 1, true)
			do
				try_parse()
			end
		end)
	end)
end

-- sequential requests through ONE daemon (persistence proof). Each awaits its response
-- before sending the next (vim.wait drives the loop between sends).
local results = { req1 = nil, req2 = nil, req3 = nil }

local function run_sequential()
	-- req1: "git ch" → checkout + cherry (the core assertion).
	request("git ch", 6, "", function(items)
		results.req1 = items
		-- req2: "ls /tm" → /tmp (proves a DIFFERENT completion path works).
		request("ls /tm", 6, "", function(items2)
			results.req2 = items2
			-- req3: "git che" → checkout again (a third distinct round-trip → persistence).
			request("git che", 7, "", function(items3)
				results.req3 = items3
			end)
		end)
	end)
end

-- (1) start the driver. on_ready fires after the stderr __PIREADY__ marker arrives
--     (the OUTER emits it after the INNER's compinit signals readiness — the SLOW part).
local ready = false
local start_err = "UNSET"
zsh.start({
	shell = "zsh",
	cwd = vim.fn.getcwd(),
	startup_timeout_ms = 8000,
}, function(err, proc, stdin, stdout)
	start_err = err
	if err then
		ready = true
		return
	end -- failure path (the vim.wait below unblocks)
	g_proc, g_stdin, g_stdout = proc, stdin, stdout
	wire_stdout()
	run_sequential()
	ready = true
end)

-- drive the loop until on_ready fires (bounded by startup_timeout_ms + slack; compinit
-- cold-start can exceed 1s on first run while it builds the dedicated compdump).
vim.wait(12000, function()
	return ready
end, 20)
check(start_err == nil, "start on_ready err=" .. tostring(start_err))

-- drive the loop until all 3 sequential requests resolve (persistence: the daemon must
-- survive across them — if it died after req1, req2/req3 would hang → timeout → nil).
vim.wait(15000, function()
	return results.req3 ~= nil
end, 20)

-- (2) core assertions on req1 ("git ch").
check(results.req1 ~= nil, "req1 (git ch) never resolved (persistence/decode failure)")
if results.req1 then
	local found = {}
	for _, it in ipairs(results.req1) do
		found[it.value] = (it.description and it.description ~= "") and true or false
	end
	check(#results.req1 > 0, "req1 decoded but empty (zsh compsys returned nothing?)")
	check(found["checkout"] ~= nil, "req1 missing `checkout`")
	check(found["cherry"] ~= nil, "req1 missing `cherry`")
	-- bonus: descriptions present (zsh _git carries descriptions).
	if found["checkout"] then
		check(found["checkout"] == true, "req1 `checkout` missing a description")
	end
end

-- (3) persistence: req2 + req3 must ALSO have decoded (the daemon survived ≥3 round-trips).
check(results.req2 ~= nil, "req2 (ls /tm) never resolved — daemon did NOT persist past req1")
check(results.req3 ~= nil, "req3 (git che) never resolved — daemon did NOT persist past req2")
if results.req3 then
	local found3 = {}
	for _, it in ipairs(results.req3) do
		found3[it.value] = true
	end
	check(found3["checkout"] ~= nil, "req3 missing `checkout` (third round-trip)")
end

-- (3.5) GRACEFUL-DEGRADE GUARD (Issue 6): empty line + quote-line must yield EMPTY
--       items, AND the daemon must SURVIVE them (a follow-up `git ch` → checkout proves
--       no wedge). Frames are built via vim.json.encode (byte-identical to shell.lua
--       M.request). `git "feature` extracts to a TRAILING-BACKSLASH cmd → guard emits empty.
local r_empty, r_quote, r_survive = nil, nil, nil
request("", 0, "", function(items)
	r_empty = items
	-- `git "feature` extracts to a TRAILING-BACKSLASH cmd → guard emits empty (no flood).
	request('git "feature', 11, "", function(items2)
		r_quote = items2
		-- SURVIVAL: same daemon, follow-up `git ch` → checkout (proves the daemon stayed
		-- responsive; a wedged pty would hang → timeout → r_survive stays nil).
		request("git ch", 6, "", function(items3)
			r_survive = items3
		end)
	end)
end)
vim.wait(12000, function()
	return r_survive ~= nil
end, 20)

check(r_empty ~= nil, "empty-line request never resolved")
if r_empty then
	check(#r_empty == 0, "empty line should yield 0 items, got " .. #r_empty .. " (FLOOD not suppressed)")
end
check(r_quote ~= nil, "quote-line request never resolved — daemon died (guard did not fire)")
if r_quote then
	check(#r_quote == 0, "quote-line should yield 0 items, got " .. #r_quote .. " (flood not suppressed)")
end
check(r_survive ~= nil, "survival follow-up `git ch` never resolved — daemon died on a malformed input")
if r_survive then
	local found_s = {}
	for _, it in ipairs(r_survive) do
		found_s[it.value] = true
	end
	check(found_s["checkout"] ~= nil, "survival follow-up missing `checkout` (daemon did NOT survive)")
end

-- (4) cd(path): best-effort advisory re-cd for zsh v1. Assert ONLY "no throw" + "no crash"
--     (cd is a documented no-op for zsh v1 — the spawn cwd is baked in; a future
--     control-char widget will make it real). A real cwd change is NOT asserted here.
check(
	pcall(function()
		zsh.cd("/tmp")
	end),
	"zsh.cd('/tmp') threw"
)
-- send one more request after cd to prove the daemon is still alive (cd must not kill it).
local post_cd = false
request("git ", 4, "", function(items)
	post_cd = true
end)
vim.wait(5000, function()
	return post_cd
end, 20)
check(post_cd, "post-cd request never resolved — cd broke the daemon?")

-- (5) never-throws on bad args (the contract).
check(
	pcall(function()
		zsh.cd(nil)
	end),
	"zsh.cd(nil) threw"
)
check(
	pcall(function()
		zsh.cd(123)
	end),
	"zsh.cd(123) threw"
)
check(
	pcall(function()
		zsh.cd("")
	end),
	"zsh.cd('') threw"
)

-- (6) teardown — kill + close every handle (spike idiom; shell.lua owns this in prod).
pcall(function()
	if g_proc and not g_proc:is_closing() then
		uv.process_kill(g_proc, "sigkill")
	end
end)
pcall(function()
	if g_proc and not g_proc:is_closing() then
		g_proc:close()
	end
end)
pcall(function()
	if g_stdin and not g_stdin:is_closing() then
		g_stdin:close()
	end
end)
pcall(function()
	if g_stdout and not g_stdout:is_closing() then
		g_stdout:read_stop()
		g_stdout:close()
	end
end)

-- cleanup so a stale real module doesn't leak into other tests (the existing-spec convention).
package.loaded["pi-bridge.shell.zsh"] = nil

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed — zsh driver smoke GATE FAILED\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS: zsh driver spawned, sequential + graceful-degrade + cd requests decoded\n")
