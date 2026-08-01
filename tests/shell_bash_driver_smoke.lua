-- === tests/shell_bash_driver_smoke.lua — plenary-FREE, LIVE smoke (P2.M3.T5.S2) ===
-- The primary Level-2 gate for the REAL bash driver. Spawns the real
-- `require("pi-bridge.shell.bash")` driver end-to-end: start() → on_ready → sends 3
-- SEQUENTIAL framed requests through ONE daemon (persistence proof — the spike only did
-- two) → decodes each + asserts:
--   * "ls /tm" → /tmp (the §5 files/dirs floor — works with NO bash-completion).
--   * "gi"    → git (the §4 cword==0 command-name completion branch).
--   * "ls "   → cwd entries (the §3 trailing-whitespace fix — cur="", NOT command completion).
-- Also exercises REAL cd (research §6 — unlike zsh v1's advisory no-op): writes
-- `__PICD__\t<other_dir>` then a "ls " request + asserts the entries CHANGED (the cwd
-- actually moved). bash is UNIVERSAL on Linux CI → this runs UNCONDITIONALLY (no skip).
--
-- The driver reads STDERR for __PIREADY__ itself (start step 5); this smoke reads ONLY
-- stdout (post-on_ready).
--
-- Run from the REPO ROOT:
--   timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_bash_driver_smoke.lua" +qa
--   echo "exit=$?"   # 0 = SMOKE_PASS (or SMOKE_SKIP if no bash — essentially never on Linux); 1 = FAIL
--
-- AGENTS.md HARD RULE: this IS a file on disk — run via :luafile. NEVER heredoc-to-nvim-stdin.
local bash = require("pi-bridge.shell.bash")
local uv = vim.uv

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end

if vim.fn.executable("bash") == 0 then
	io.stdout:write("SMOKE_SKIP: bash not on PATH — gate deferred (exit 0)\n")
	return -- chunk-level return; the +qa exits 0
end

-- the live proc/pipes handed to on_ready (captured for teardown at the end).
local g_proc, g_stdin, g_stdout

-- stdout rx buffer + sentinel parser (find the __PIRESP_START__\n..__PIRESP_END__\n pair,
-- vim.json.decode the body — single-object, shell.lua _feed contract).
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
local results = { req1 = nil, req2 = nil, req3 = nil, post_cd = nil, pre_cd = nil }

local function run_sequential()
	-- req1: "ls /tm" → /tmp (the §5 files/dirs floor — works with NO bash-completion).
	request("ls /tm", 6, "", function(items)
		results.req1 = items
		-- req2: "gi" → git (the §4 cword==0 command-name completion branch).
		request("gi", 2, "", function(items2)
			results.req2 = items2
			-- req3: "ls " (trailing space) → cwd entries (the §3 fix — cur="", NOT command completion of "ls").
			request("ls ", 3, "", function(items3)
				results.req3 = items3
			end)
		end)
	end)
end

-- (1) start the driver. on_ready fires after the stderr __PIREADY__ marker arrives (bash
--     cold-start is FAST — only the best-effort bash-completion sourcing; this box has none).
local ready = false
local start_err = "UNSET"
bash.start({
	shell = "bash",
	cwd = vim.fn.getcwd(),
	startup_timeout_ms = 5000,
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

-- drive the loop until on_ready fires (bounded by startup_timeout_ms + slack).
vim.wait(8000, function()
	return ready
end, 20)
check(start_err == nil, "start on_ready err=" .. tostring(start_err))

-- drive the loop until all 3 sequential requests resolve (persistence: the daemon must
-- survive across them — if it died after req1, req2/req3 would hang → timeout → nil).
vim.wait(12000, function()
	return results.req3 ~= nil
end, 20)

-- (2) core assertions.
check(results.req1 ~= nil, "req1 (ls /tm) never resolved (persistence/decode failure)")
if results.req1 then
	local found_tmp = false
	for _, it in ipairs(results.req1) do
		if it.value == "/tmp" then
			found_tmp = true
		end
	end
	check(#results.req1 > 0, "req1 (ls /tm) decoded but empty (compgen -f -d returned nothing?)")
	check(found_tmp, "req1 (ls /tm) missing /tmp (the §5 files/dirs floor)")
end

check(results.req2 ~= nil, "req2 (gi) never resolved — daemon did NOT persist past req1")
if results.req2 then
	local found_git = false
	for _, it in ipairs(results.req2) do
		if it.value == "git" then
			found_git = true
		end
	end
	check(#results.req2 > 0, "req2 (gi) decoded but empty (compgen -abck returned nothing?)")
	check(found_git, "req2 (gi) missing git (the §4 cword==0 command-name branch)")
end

check(results.req3 ~= nil, "req3 (ls trailing-space) never resolved — daemon did NOT persist past req2")
if results.req3 then
	-- §3 fix: "ls " (trailing space) → cur="" → cwd file/dir completion (NOT command-name
	-- completion of "ls"). Assert cwd entries + NO "ls"/"lsof" (which would mean the fix FAILED).
	local found_ls = false
	for _, it in ipairs(results.req3) do
		if it.value == "ls" or it.value == "lsof" then
			found_ls = true
		end
	end
	check(#results.req3 > 0, "req3 (ls trailing-space) decoded but empty (cwd has no entries?)")
	check(
		not found_ls,
		"req3 (ls trailing-space) returned ls/lsof — the §3 COMP_CWORD fix FAILED (got command-name completion instead of cwd entries)"
	)
end

-- (3) REAL cd (research §6 — unlike zsh v1's advisory no-op): send "ls " to capture the
--     spawn cwd's entries, then __PICD__\t/tmp, then "ls " again → assert the entries
--     CHANGED (the cwd actually moved). /tmp has MANY entries (the research's chosen target).
local cd_done = false
request("ls ", 3, "", function(items)
	results.pre_cd = items
	-- cd to /tmp then request "ls " again.
	bash.cd("/tmp")
	-- tiny defer so the cd frame is written before the request (best-effort ordering; the
	-- daemon processes frames sequentially so cd always lands before the next request).
	vim.defer_fn(function()
		request("ls ", 3, "", function(items2)
			results.post_cd = items2
			cd_done = true
		end)
	end, 50)
end)
vim.wait(8000, function()
	return cd_done
end, 20)

check(results.pre_cd ~= nil, "pre-cd (ls ) never resolved")
check(results.post_cd ~= nil, "post-cd (ls after __PICD__) never resolved — cd broke the daemon?")
if results.pre_cd and results.post_cd then
	-- collect the value sets for comparison.
	local function toset(items)
		local s = {}
		for _, it in ipairs(items) do
			s[it.value] = true
		end
		return s
	end
	local pre, post = toset(results.pre_cd), toset(results.post_cd)
	-- assert the sets DIFFER (cd moved the cwd → at least one entry is unique to /tmp or to the spawn cwd).
	local changed = false
	for v, _ in pairs(post) do
		if not pre[v] then
			changed = true
			break
		end
	end
	if not changed then
		for v, _ in pairs(pre) do
			if not post[v] then
				changed = true
				break
			end
		end
	end
	check(
		changed,
		"REAL cd FAILED — entries did NOT change after __PICD__ /tmp (bash cd should be REAL, unlike zsh v1)"
	)
	-- /tmp always contains "tmp.*"-style tmpfiles (os.tmpname) — assert at least one /tmp-specific entry.
	local has_tmp_entry = false
	for v, _ in pairs(post) do
		if v:find("tmp%.", 1) ~= nil or v:find("^tmp%.") ~= nil then
			has_tmp_entry = true
			break
		end
	end
	check(has_tmp_entry, "post-cd entries missing tmp.*-style entries (expected from os.tmpname files in /tmp)")
end

-- (4) never-throws on bad args (the contract).
check(
	pcall(function()
		bash.cd(nil)
	end),
	"bash.cd(nil) threw"
)
check(
	pcall(function()
		bash.cd(123)
	end),
	"bash.cd(123) threw"
)
check(
	pcall(function()
		bash.cd("")
	end),
	"bash.cd('') threw"
)

-- (5) teardown — kill + close every handle (spike idiom; shell.lua owns this in prod).
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
package.loaded["pi-bridge.shell.bash"] = nil

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed — bash driver smoke GATE FAILED\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS: bash driver spawned, 3 sequential requests decoded, REAL cd proven\n")
