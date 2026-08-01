-- === tests/shell_zsh_spike.lua — Phase P2.M3.T5.S1 SPIKE (PRD §17.6.2 / §17.5.1) ===
-- Standalone (plenary-FREE) proof that the framed zsh completion round-trip works:
-- spawns the OUTER `zsh -f <outer.zsh> <inner.zsh>` (which manages an INNER completion
-- zsh inside a zsh/zpty pseudo-terminal), sends one __PIREQ__ frame, parses the
-- single-object JSON between __PIRESP_START__/__PIRESP_END__ sentinels, and asserts
-- `checkout` + `cherry` appear for "git ch". This is the GATE for writing zsh.lua
-- (PRD: "the most fragile driver" — the version-sensitive pty plumbing MUST be proven
-- live before the driver module is written; the proven scripts become zsh.lua's
-- DAEMON_SCRIPT verbatim).
--
-- Run from the REPO ROOT:
--   timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_zsh_spike.lua" +qa
--   echo "exit=$?"   # 0 = SPIKE_PASS (or SPIKE_SKIP if zsh absent); 1 = gate FAILED
--
-- AGENTS.md HARD RULE: this IS a file on disk — run via :luafile. NEVER heredoc-to-nvim-stdin.
-- Gated on `zsh` being on $PATH; prints SPIKE_SKIP + exits 0 if absent (PRD §17.15).
local uv = vim.uv

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end

if vim.fn.executable("zsh") == 0 then
	io.stdout:write("SPIKE_SKIP: zsh not on PATH — gate deferred (exit 0)\n")
	return -- chunk-level return; the +qa exits 0
end

-- (1) The INNER init script (the Valodim capture.zsh lineage): compinit, a noop Enter
--     widget (never execute), the compadd override (captures matches + descriptions;
--     handles modern zsh combined short opts like `-ld`), and a Tab wrapper widget that
--     emits PISTART/PIEND sentinels around EVERY completion (robust across requests,
--     unlike compprefuncs/comppostfuncs which only fire on the first).
local INNER_SCRIPT = [=[
PROMPT=
[[ -z "$TMPDIR" ]] && TMPDIR=/tmp
autoload -Uz compinit
compinit -d "$TMPDIR/pi-zcompdump-$$" -u
_pi_noop() { :; }
zle -N _pi_noop
bindkey '^M' _pi_noop
bindkey '^J' _pi_noop
zstyle ':completion:*' list-grouped false
zstyle ':completion:*' insert-tab false
zstyle ':completion:*' list-separator ''
zstyle ':completion:*' menu no
zmodload zsh/zutil
compadd () {
    setopt localoptions extendedglob
    local _a
    for _a in "$@"; do
        [[ "$_a" == -* ]] || continue
        local _s="${_a#-}"; _s="${_s#-}"
        [[ "$_s" == *[OAD]* ]] && { builtin compadd "$@"; return $?; }
    done
    local _dname="" _mname="" _prev=""
    for _a in "$@"; do
        if [[ -n "$_prev" ]] && [[ "$_prev" == -[a-zA-Z]## ]]; then
            local _pb="${_prev#-}"
            if [[ "$_pb" == *d* ]] && [[ -z "$_dname" ]]; then _dname="$_a"; fi
            if [[ "$_pb" == *a* ]] && [[ -z "$_mname" ]]; then _mname="$_a"; fi
        fi
        _prev="$_a"
    done
    typeset -a __hits
    builtin compadd -A __hits "$@"
    [[ -n $__hits ]] || return
    typeset -A _descmap
    if [[ -n "$_dname" ]] && [[ -n "$_mname" ]]; then
        local _marr=( "${(@P)_mname}" ) _darr=( "${(@P)_dname}" ) n
        for n in {1..$#_marr}; do (( n > $#_darr )) && break; _descmap[$_marr[$n]]="$_darr[$n]"; done
    fi
    local dscr i hit
    for i in {1..$#__hits}; do
        hit="${__hits[$i]}"; dscr="${_descmap[$hit]}"
        if [[ -n "$dscr" ]] && [[ "$dscr" == "$hit"* ]]; then
            dscr="${dscr#$hit}"; dscr="${dscr## #}"; [[ "$dscr" == "-- "* ]] && dscr="${dscr#-- }"
        elif [[ -n "$dscr" ]] && [[ "$dscr" == *"-- "* ]]; then dscr="${dscr#*-- }"; fi
        printf '%s\t%s\n' "$hit" "$dscr"
    done
}
_pi_complete() {
    echo -E - $'\002''PISTART'
    zle complete-word
    echo -E - $'\002''PIEND'
}
zle -N _pi_complete
bindkey '^I' _pi_complete
echo __PIINNER_READY__
]=]

-- (2) The OUTER daemon script: spawns the INNER in a non-blocking zpty (-b), waits for
--     the inner readiness marker, emits __PIREADY__ to stderr, then loops on stdin
--     driving the inner per request (^C reset, ^U clear, type cmd + Tab) and capturing
--     the compadd output between PISTART/PIEND, building ONE single-object JSON.
local OUTER_SCRIPT = [=[
zmodload zsh/zpty || { echo "error: zsh/zpty missing" >&2; exit 1 }
__pi_json_str() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}
zpty -b z zsh -f -i
zpty -w z "source $1"$'\n'
local _line _l _ready=0 _repeat=200
while (( _repeat-- > 0 )); do
    if zpty -r -t z _line; then
        [[ "$_line" == *"__PIINNER_READY__"* ]] && { _ready=1; break; }
    else sleep 0.05; fi
done
(( _ready )) || { echo "error: inner never ready (compinit timeout?)" >&2; exit 2 }
printf '__PIREADY__\n' >&2
_repeat=30
while (( _repeat-- > 0 )); do zpty -r -t z _line || { sleep 0.02; } done
local _SOPEN=$'\002PISTART' _SCLOSE=$'\002PIEND'
while IFS= read -r req; do
    case "$req" in
        (__PIREQ__*)
            local payload="${req#__PIREQ__	}"
            local cmd="${${payload#*\"line\":\"}%%\"*}"
            echo __PIRESP_START__
            zpty -w z $'\003'$'\025'"$cmd"$'\t'
            local _items="" _first=1 _cap=0 _drained=0 _tries=0
            while (( _tries++ < 1000 )); do
                if zpty -r -t z _l; then
                    _l="${_l//$'\r'/}"; _l="${_l//$'\n'/}"
                    [[ "$_l" == *"$_SCLOSE"* ]] && { _cap=0; _drained=1; _tries=$((1000 - 20)); continue; }
                    if [[ "$_l" == *"$_SOPEN"* ]]; then _cap=1; continue; fi
                    ((_cap)) || continue
                    local _w="${_l%%$'\t'*}" _d=""
                    [[ "$_l" == *$'\t'* ]] && _d="${_l#*$'\t'}"
                    [[ -z "$_w" ]] && continue
                    local _it="{\"value\":$(__pi_json_str "$_w")"
                    [[ -n "$_d" ]] && _it="${_it},\"description\":$(__pi_json_str "$_d")"
                    _it="${_it}}"
                    if ((_first)); then _items="$_it"; _first=0; else _items="${_items},${_it}"; fi
                else
                    ((_drained)) && break
                    sleep 0.01
                fi
            done
            printf '{"items":[%s],"prefix":""}\n' "$_items"
            echo __PIRESP_END__
            ;;
        (__PICD*) ;;
    esac
done
zpty -d z
]=]

-- write both scripts to temp files.
local outer_path = os.tmpname()
local inner_path = os.tmpname()
local of = assert(io.open(outer_path, "w"))
of:write(OUTER_SCRIPT)
of:close()
local inf = assert(io.open(inner_path, "w"))
inf:write(INNER_SCRIPT)
inf:close()

-- (3) Spawn `zsh -f <outer> <inner>` with 3 piped streams. pcall EVERY uv call.
local stdin = uv.new_pipe(false)
local stdout = uv.new_pipe(false)
local stderr_pipe = uv.new_pipe(false)
local handle, spawn_err
pcall(function()
	handle, spawn_err = uv.spawn("zsh", {
		args = { "-f", outer_path, inner_path },
		stdio = { stdin, stdout, stderr_pipe },
	}, function() end)
end)
check(handle ~= nil, "uv.spawn(zsh) returned no handle; err=" .. tostring(spawn_err))

local rx_buf, done = "", false
local items = {}

-- try_parse: scan rx_buf for a __PIRESP_START__\n .. __PIRESP_END__ pair; vim.json.decode
-- the body (single-object — shell.lua _feed contract).
local function try_parse()
	local s = rx_buf:find("__PIRESP_START__\n", 1, true)
	local e = s and rx_buf:find("__PIRESP_END__", (s or 1) + 1, true)
	if not (s and e) then
		return
	end
	local payload = rx_buf:sub(s + #"__PIRESP_START__\n", e - 1)
	local dok, decoded = pcall(vim.json.decode, payload)
	if dok and type(decoded) == "table" and type(decoded.items) == "table" then
		for _, it in ipairs(decoded.items) do
			table.insert(items, { word = it.value, desc = it.description or "" })
		end
	end
	done = true
end

-- (4) Read stdout; buffer + scan each chunk. data == nil ⇒ EOF.
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
			done = done or (#items > 0)
		end
	end)
end)
check(read_ok, "stdout:read_start threw")

-- (5) Send the framed request (PRD §17.5.1 EXACT wire shape).
pcall(function()
	stdin:write('__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n')
end)

-- (6) Drive the event loop until done OR a hard timeout (compinit cold-start can exceed 1s).
local waited = vim.wait(15000, function()
	return done
end, 20)

-- (7) Gate verdict.
local words = {}
for _, it in ipairs(items) do
	words[it.word] = true
end
vim.api.nvim_echo({ { "[shell-zsh-spike] parsed " .. #items .. " item(s):", "Title" } }, false, {})
for _, it in ipairs(items) do
	vim.api.nvim_echo({ { "  " .. it.word .. "  =>  " .. it.desc } }, false, {})
end

check(#items > 0, "no items parsed (done=" .. tostring(done) .. ", waited=" .. tostring(waited) .. ")")
check(words["checkout"] ~= nil, 'expected `checkout` in results (zsh compsys _git for "git ch")')
check(words["cherry"] ~= nil, 'expected `cherry` in results (zsh compsys _git for "git ch")')
if words["cherry-pick"] ~= nil then
	vim.api.nvim_echo({ { "[shell-zsh-spike] bonus: cherry-pick present" } }, false, {})
end

-- (8) Teardown — kill + close every handle (mirrors shell.lua teardown; §17.5.2).
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
		stdout:close()
	end
end)
pcall(function()
	if stderr_pipe and not stderr_pipe:is_closing() then
		stderr_pipe:close()
	end
end)
os.remove(outer_path)
os.remove(inner_path)

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed — zsh spike GATE FAILED\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SPIKE_PASS: zsh framed round-trip proven (checkout+cherry present)\n")
