-- === tests/shell_fish_spike.lua — Phase 6, step 21 SPIKE (PRD §17.16 step 21 / §17.6.1 / §17.5.1) ===
-- Standalone (plenary-FREE) proof that the framed fish completion round-trip works: spawns an INTERACTIVE
-- `fish` over piped stdio via vim.uv.spawn, sends one __PIREQ__ frame, parses word<TAB>desc lines between
-- __PIRESP_START__/__PIRESP_END__ sentinels, echoes them via nvim_echo, and prints a parseable verdict.
-- GATE for the rest of P2.M1.T2 (shell.lua): proceed iff `checkout` + `cherry` appear.
--
-- Run from the REPO ROOT:
--   timeout 30 nvim --headless --clean -u NORC +"luafile tests/shell_fish_spike.lua" +qa
--   echo "exit=$?"   # 0 = SPIKE_PASS (or SPIKE_SKIP if fish absent); 1 = gate FAILED
--
-- AGENTS.md HARD RULE: this IS a file on disk — run via :luafile. NEVER heredoc-to-nvim-stdin (it hangs).
-- Gated on `fish` being on $PATH; prints SPIKE_SKIP + exits 0 if absent (PRD §17.15: never fail CI for a missing shell).
local uv = vim.uv

local fails = 0
local function check(cond, msg)
	if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); fails = fails + 1 end
end

if vim.fn.executable("fish") == 0 then
	io.stdout:write("SPIKE_SKIP: fish not on PATH — gate deferred (exit 0)\n")
	return -- chunk-level return; the +qa exits 0
end

-- (1) The daemon's startup script (PRD §17.6.1): written to a temp file, sourced via `fish -i --init-command`.
--     jq-free JSON: fish has no builtin JSON parser (jq not guaranteed on PATH), so `string match -r` extracts .line.
local fish_script = [[
function __pi_handle
    set -l line ""
    read -l line
    if test -z "$line"; return; end
    set -l payload (string replace -r '^__PIREQ__\t' '' -- "$line")
    set -l cmd (string match -r '"line":"([^"]*)"' -- "$payload")[2]
    echo __PIRESP_START__
    complete -C "$cmd" | while read -l word desc
        test -n "$desc"; and printf '%s\t%s\n' "$word" "$desc"; or printf '%s\n' "$word"
    end
    echo __PIRESP_END__
end
function fish_prompt; end
__pi_handle
]]
local script_path = os.tmpname()
local f = io.open(script_path, "w")
f:write(fish_script)
f:close()

-- (2) Spawn `fish -i` with 3 piped streams. pcall EVERY uv call (PRD §17.5.2: never blocks, never throws).
local stdin = uv.new_pipe(false)
local stdout = uv.new_pipe(false)
local stderr_pipe = uv.new_pipe(false)
local handle, spawn_err
pcall(function()
	handle, spawn_err = uv.spawn("fish", {
		args = { "-i", "--init-command=" .. "source " .. script_path },
		stdio = { stdin, stdout, stderr_pipe },
	}, function() end) -- on_exit no-op for the spike (we teardown on sentinel/timeout)
end)
check(handle ~= nil, "uv.spawn(fish) returned no handle; err=" .. tostring(spawn_err))

local rx_buf, done = "", false
local items = {}

-- try_parse: scan rx_buf for a __PIRESP_START__\n .. __PIRESP_END__ pair; slice + parse word(\tdesc)? lines.
local function try_parse()
	local s = rx_buf:find("__PIRESP_START__\n", 1, true)
	local e = rx_buf:find("__PIRESP_END__", (s or 1) + 1, true)
	if not (s and e) then return end
	local body = rx_buf:sub(s + #"__PIRESP_START__\n", e - 1)
	for line in body:gmatch("([^\n\r]+)") do
		local word, desc = line:match("^([^\t]+)\t(.+)$")
		table.insert(items, { word = word or line, desc = desc or "" })
	end
	done = true
end

-- (3) Read stdout; buffer + scan each chunk. data == nil ⇒ EOF (finalize), NOT an error.
local read_ok = pcall(function()
	stdout:read_start(function(rerr, data)
		if rerr then
			io.stderr:write("FAIL: stdout read_start err=" .. tostring(rerr) .. "\n")
			done = true
			return
		end
		if data then
			rx_buf = rx_buf .. data
			try_parse()
		else
			done = done or (#items > 0) -- EOF: finalize if we already parsed
		end
	end)
end)
check(read_ok, "stdout:read_start threw")

-- (4) Send the framed request (PRD §17.5.1 EXACT wire shape).
pcall(function()
	stdin:write('__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n')
end)

-- (5) Drive the event loop until done OR a hard timeout (safety net; AGENTS.md).
local waited = vim.wait(10000, function() return done end, 20)
local timed_out = not done

-- (6) Gate verdict + :messages echo (PRD §17.16 step 21). nvim_echo records to message history (headless-safe).
local words = {}
for _, it in ipairs(items) do words[it.word] = true end
vim.api.nvim_echo({ { "[shell-fish-spike] parsed " .. #items .. " item(s):", "Title" } }, false, {})
for _, it in ipairs(items) do
	vim.api.nvim_echo({ { "  " .. it.word .. "  =>  " .. it.desc } }, false, {})
end

check(#items > 0,
	"no items parsed (done=" .. tostring(done) .. ", waited=" .. tostring(waited) .. ", timed_out=" .. tostring(timed_out) .. ")")
check(words["checkout"] ~= nil, "expected `checkout` in results (complete -C \"git ch\")")
check(words["cherry"] ~= nil, "expected `cherry` in results (complete -C \"git ch\")")
-- bonus (do NOT hard-fail on this — it's informational; some fish installs order differently):
if words["cherry-pick"] ~= nil then
	vim.api.nvim_echo({ { "[shell-fish-spike] bonus: cherry-pick present" } }, false, {})
end

-- (7) Teardown — kill + close every handle (mirrors shell.lua teardown(); §17.5.2). pcall each.
pcall(function()
	if handle and not handle:is_closing() then uv.process_kill(handle, "sigkill") end
end)
pcall(function()
	if stdin and not stdin:is_closing() then stdin:close() end
end)
pcall(function()
	if stdout and not stdout:is_closing() then stdout:close() end
end)
pcall(function()
	if stderr_pipe and not stderr_pipe:is_closing() then stderr_pipe:close() end
end)
os.remove(script_path)

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed — fish spike GATE FAILED\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SPIKE_PASS: fish framed round-trip proven (checkout+cherry present)\n")