-- === tests/shell_bash_spike.lua — Phase P2.M3.T5.S2 SPIKE (PRD §17.6.3 / §17.5.1) ===
-- Standalone (plenary-FREE) proof that the framed bash completion round-trip works:
-- spawns a NON-INTERACTIVE `bash <daemon_script>` over piped stdio via vim.uv.spawn,
-- sends a __PIREQ__ frame, parses the single-object JSON between __PIRESP_START__/
-- __PIRESP_END__ sentinels, and asserts `/tmp` appears for "ls /tm". This works even
-- with ZERO `bash-completion` infrastructure (the file/dir compgen fallback — §17.6.3's
-- "files/dirs always work" floor; LIVE on this box which has NO bash-completion).
--
-- BONUS: also asserts the §3 fix — `ls ` (trailing space, point=3) yields cwd file/dir
-- entries (cur=""), NOT command-name completion of "ls". This is the regression guard
-- for the LIVE-VALIDATED COMP_CWORD computation (the PRD §17.6.3 accumulation loop is
-- BUGGY for trailing-space inputs — research §3).
--
-- This is the GATE for writing bash.lua: the proven script becomes bash.lua's
-- DAEMON_SCRIPT verbatim.
--
-- Run from the REPO ROOT:
--   timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_bash_spike.lua" +qa
--   echo "exit=$?"   # 0 = SPIKE_PASS (or SPIKE_SKIP if bash absent — essentially never on Linux);
--                   # 1 = GATE FAILED — iterate the DAEMON_SCRIPT (the §3 computation, complete -p parse, compgen flags)
--
-- AGENTS.md HARD RULE: this IS a file on disk — run via :luafile. NEVER heredoc-to-nvim-stdin (it hangs).
-- Gated on `bash` being on $PATH; prints SPIKE_SKIP + exits 0 if absent (PRD §17.15: never fail CI for a missing shell).
local uv = vim.uv

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end

if vim.fn.executable("bash") == 0 then
	io.stdout:write("SPIKE_SKIP: bash not on PATH — gate deferred (exit 0)\n")
	return -- chunk-level return; the +qa exits 0
end

-- (1) The bash DAEMON SCRIPT (LIVE-VALIDATED against bash 5.3.15; research §2/§3/§4/§5/§6/§7/§9/§10).
--     Spawned NON-INTERACTIVELY as `bash <this-file>`. Best-effort sources bash-completion
--     (the 4 canonical paths); NEVER depends on it (§5 degrade). Reads framed __PIREQ__
--     lines from stdin; emits ONE single-object JSON between __PIRESP_START__/__PIRESP_END__
--     sentinels. Emits __PIREADY__ to stderr once at startup (the spike ignores it — it
--     reads stdout directly, standing in for shell.lua).
--
-- NB: written as a Lua [[ ... ]] long-string so NONE of its \n/\t/\\ are interpreted by
-- Lua — they are LITERAL bash source. The bash script's OWN escapes (e.g. ${s//\\/\\\\})
-- are bash parameter substitutions.
local DAEMON_SCRIPT = [=[
trap '' PIPE
for _bc in /usr/share/bash-completion/bash_completion \
           /usr/local/share/bash-completion/bash_completion \
           /etc/bash_completion /usr/local/etc/bash_completion ; do
    [ -r "$_bc" ] && { . "$_bc" || true; break; }
done
unset _bc

__pi_json_str() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

__pi_complete() {
    local line="$1" point="$2"
    COMP_LINE="$line"; COMP_POINT="$point"
    local prefix="${line:0:point}"
    local trailing_ws=0
    [[ "$prefix" =~ [[:space:]]$ ]] && trailing_ws=1
    COMP_WORDS=()
    read -ra COMP_WORDS <<< "$prefix"
    (( ${#COMP_WORDS[@]} == 0 )) && COMP_WORDS+=("")
    (( trailing_ws )) && COMP_WORDS+=("")
    COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local cmd="${COMP_WORDS[0]}"
    COMPREPLY=()
    if (( COMP_CWORD == 0 )); then
        COMPREPLY=( $(compgen -abck -A function -- "$cur" 2>/dev/null) )
    else
        local spec
        spec=$(complete -p "$cmd" 2>/dev/null) || spec=""
        if [[ "$spec" == *-F\ * ]]; then
            local fn; fn=$(printf '%s' "$spec" | sed -n 's/.*-F[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p')
            if [ -n "$fn" ] && type "$fn" >/dev/null 2>&1; then
                "$fn" "$cmd" "$cur" "${COMP_WORDS[COMP_CWORD-1]}" 2>/dev/null || true
            fi
        fi
        if [ ${#COMPREPLY[@]} -eq 0 ]; then
            COMPREPLY=( $(compgen -f -d -- "$cur" 2>/dev/null) )
        fi
    fi
}

__pi_handle() {
    local line_in="$1"
    case "$line_in" in
        (__PICD__*)
            local p="${line_in#__PICD__	}"
            builtin cd "$p" 2>/dev/null
            return
            ;;
        (__PIREQ__*)
            local payload="${line_in#__PIREQ__	}"
            local line="${payload#*\"line\":\"}"; line="${line%%\"*}"
            local cursor="${payload#*\"cursor\":}"; cursor="${cursor%%[!0-9]*}"
            cursor="${cursor:-0}"
            echo __PIRESP_START__
            (
                __pi_complete "$line" "$cursor"
                local _items="" _first=1 w
                for w in "${COMPREPLY[@]}"; do
                    [ -z "$w" ] && continue
                    local _it="{\"value\":$(__pi_json_str "$w")}"
                    if ((_first)); then _items="$_it"; _first=0; else _items="${_items},${_it}"; fi
                done
                printf '{"items":[%s],"prefix":""}\n' "$_items"
            ) 2>/dev/null
            echo __PIRESP_END__
            ;;
    esac
}

printf '__PIREADY__\n' >&2

while IFS= read -r req; do
    __pi_handle "$req"
done
]=]

local script_path = os.tmpname()
local f = io.open(script_path, "w")
f:write(DAEMON_SCRIPT)
f:close()

-- (2) Spawn `bash <script>` (NON-interactive — script as positional arg; research §7)
--     with 3 piped streams. pcall EVERY uv call (PRD §17.5.2: never blocks, never throws).
local stdin = uv.new_pipe(false)
local stdout = uv.new_pipe(false)
local stderr_pipe = uv.new_pipe(false)
local handle, spawn_err
pcall(function()
	handle, spawn_err = uv.spawn("bash", {
		args = { script_path },
		stdio = { stdin, stdout, stderr_pipe },
	}, function() end) -- on_exit no-op for the spike (we teardown on sentinel/timeout)
end)
check(handle ~= nil, "uv.spawn(bash) returned no handle; err=" .. tostring(spawn_err))

-- the spike reads STDOUT directly (it stands in for shell.lua — the DRIVER reads stderr
-- for __PIREADY__; the spike does not need the ready signal, just the responses).
local rx_buf = ""
local pending = {} -- queue of {matcher=fn, resolver=fn} for sequential requests
local current = nil -- the matcher/resolver pair currently in flight

-- try_parse: drain every complete __PIRESP_START__\n..__PIRESP_END__\n pair from rx_buf;
-- each is vim.json.decode'd (single-object — shell.lua _feed contract) + handed to the
-- current request's resolver.
local function try_parse()
	while true do
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
		local items = {}
		if dok and type(decoded) == "table" and type(decoded.items) == "table" then
			for _, it in ipairs(decoded.items) do
				if type(it) == "table" and it.value ~= nil then
					table.insert(items, tostring(it.value))
				end
			end
		end
		local r = current and current.resolver
		current = nil
		if r then
			r(items, not dok)
		end
		-- pump the next queued request (if any).
		if pending[1] then
			current = table.remove(pending, 1)
			pcall(function()
				stdin:write(current.frame)
			end)
		end
	end
end

-- (3) Read stdout; buffer + scan each chunk. data == nil ⇒ EOF (finalize), NOT an error.
local read_ok = pcall(function()
	stdout:read_start(function(rerr, data)
		if rerr then
			io.stderr:write("FAIL: stdout read_start err=" .. tostring(rerr) .. "\n")
			current = nil
			return
		end
		if data then
			rx_buf = rx_buf .. data
			try_parse()
		end
	end)
end)
check(read_ok, "stdout:read_start threw")

-- send ONE framed request + invoke cb(items, decode_failed) on the decoded response.
-- Requests are queued so only ONE is in flight at a time (the daemon is sequential).
local function request(frame, cb)
	local entry = { frame = frame, resolver = cb }
	if current then
		table.insert(pending, entry)
	else
		current = entry
		pcall(function()
			stdin:write(frame)
		end)
	end
end

-- (4) Send the GATE request: "ls /tm" → /tmp (works with NO bash-completion — §5 floor).
local got1, got2 = false, false
local items1, items2 = {}, {}
request('__PIREQ__\t{"line":"ls /tm","cursor":6,"after":""}\n', function(items)
	items1 = items
	got1 = true
	-- (5) BONUS (the §3 fix): "ls " (trailing space, point=3) → cwd entries (cur=""),
	-- NOT command-name completion of "ls". Assert cwd files/dirs, NOT ls/lsof/etc.
	request('__PIREQ__\t{"line":"ls ","cursor":3,"after":""}\n', function(items_b)
		items2 = items_b
		got2 = true
	end)
end)

-- (6) Drive the event loop until both requests resolve OR a hard timeout (AGENTS.md).
vim.wait(10000, function()
	return got2
end, 20)

-- (7) GATE verdict: "ls /tm" → /tmp.
vim.api.nvim_echo({ { "[shell-bash-spike] req1 (ls /tm) parsed " .. #items1 .. " item(s):", "Title" } }, false, {})
check(got1, "req1 (ls /tm) never resolved")
local found_tmp = false
for _, v in ipairs(items1) do
	if v == "/tmp" then
		found_tmp = true
	end
end
check(found_tmp, "req1 (ls /tm) did NOT yield /tmp (the §5 files/dirs floor)")

-- (8) §3-fix verdict: "ls " → cwd entries (NOT command-name completion of "ls").
vim.api.nvim_echo(
	{ { "[shell-bash-spike] req2 (ls <trailing-space>) parsed " .. #items2 .. " item(s):", "Title" } },
	false,
	{}
)
check(got2, "req2 (ls trailing-space) never resolved")
local found_ls = false
for _, v in ipairs(items2) do
	if v == "ls" or v == "lsof" then
		found_ls = true
	end
end
check(#items2 > 0, "req2 (ls trailing-space) decoded but empty (cwd has no entries?)")
check(
	not found_ls,
	"req2 (ls trailing-space) returned `ls`/`lsof` — the §3 COMP_CWORD fix FAILED (got command-name completion instead of cwd entries)"
)

-- (9) Teardown — kill + close every handle (mirrors shell.lua teardown; §17.5.2). pcall each.
pcall(function()
	if handle and not handle:is_closing() then
		uv.process_kill(handle, "sigkill")
	end
end)
pcall(function()
	if handle and not handle:is_closing() then
		handle:close()
	end
end)
pcall(function()
	if stdin and not stdin:is_closing() then
		stdin:close()
	end
end)
pcall(function()
	if stdout and not stdout:is_closing() then
		stdout:read_stop()
		stdout:close()
	end
end)
pcall(function()
	if stderr_pipe and not stderr_pipe:is_closing() then
		stderr_pipe:close()
	end
end)
os.remove(script_path)

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed — bash spike GATE FAILED\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SPIKE_PASS: bash framed round-trip proven (ls /tm→/tmp + §3 trailing-space fix)\n")
