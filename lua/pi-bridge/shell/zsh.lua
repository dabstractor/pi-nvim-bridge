--- zsh.lua — the Tier-1 zsh shell-completion driver (PRD §17.6.2 / §17.5.1).
--
-- Exposes `M.start(opts, on_ready)` + `M.cd(path)`, the per-shell driver seam shell.lua's
-- `M.pick_driver` resolves (`require("pi-bridge.shell.zsh")`) and `M.ensure` drives
-- (`state.driver.start({shell,cwd,startup_timeout_ms}, cb)`). It is the SECOND concrete
-- driver (P2.M3.T5.S1); it mirrors fish.lua's Lua shape with a different DAEMON_SCRIPT.
--
-- [Mode A] header — read before editing:
--  * ROLE: spawn ONE persistent OUTER `zsh -f` completion daemon per session. The OUTER
--    zsh manages an INNER completion zsh inside a `zsh/zpty` pseudo-terminal (the proven
--    Valodim/zsh-capture-completion model). From Lua/luv the outer zsh looks EXACTLY like
--    the fish subprocess (plain stdin/stdout/stderr pipes) — ALL the pty complexity lives
--    in the OUTER's DAEMON_SCRIPT (zsh), NOT in Lua. The driver hands the live luv proc +
--    stdin + stdout handles to shell.lua via `on_ready`, and re-`cd` it (advisory for v1)
--    over the framed channel on demand. shell.lua owns the request/response framing
--    (`request`→`stdin:write("__PIREQ__\t{json}\n", cb)`, `_feed`→`stdout:read_start`);
--    zsh.lua owns ONLY spawn + cold-start readiness + the daemon's startup scripts.
--
--  * WHY A PTY (unlike fish): zsh completion is driven by ZLE widgets (`complete-word`,
--    bound to Tab) which ONLY activate on a real TTY. `vim.uv` (luv) has NO PTY API. So
--    the OUTER zsh does `zmodload zsh/zpty; zpty -b z zsh -f -i` to spawn the INNER zsh
--    inside a pseudo-terminal. The pty is INTERNAL to the outer zsh — invisible to nvim.
--    This is the canonical technique (used by fzf's zsh completion + Valodim's
--    capture.zsh). See plan/.../research/zsh_driver_findings.md §1.
--
--  * START CONTRACT (the binding seam — shell.lua:696-712; identical to fish.lua):
--      M.start(opts, on_ready)
--        opts = { shell="/usr/bin/zsh", cwd="/srv"?, startup_timeout_ms=5000? }
--        on_ready(err, proc, stdin, stdout)
--          err   = nil on success; an error string on EVERY failure.
--          proc  = the uv_process_t (shell.lua teardown process_kill's + close's it).
--          stdin = the uv_pipe_t → outer-zsh stdin (shell.lua request() writes frames).
--          stdout= the uv_pipe_t ← outer-zsh stdout (shell.lua wires read_start→_feed).
--    `proc` MUST be the uv_process_t; `stdin`/`stdout` MUST be uv_pipe_t. NEVER throws:
--    every luv call is pcall'd; a bad arg / spawn error / startup timeout / missing
--    zsh/zpty degrades to `on_ready(err, nil, nil, nil)`. Exactly ONE on_ready call.
--
--  * STDERR-READY-SIGNAL: the driver detects cold-start readiness by reading STDERR for
--    an `__PIREADY__\n` marker the OUTER emits after the INNER signals compinit-done. It
--    CANNOT use stdout (shell.lua wires `stdout:read_start` AFTER on_ready — two
--    read_start's on one pipe is ILLEGAL in luv). stdout stays PRISTINE for shell.lua;
--    the driver owns + closes the stderr pipe. (identical to fish.lua)
--
--  * THE DAEMON SCRIPTS: embedded below as `OUTER_SCRIPT` + `INNER_SCRIPT` (zsh
--    long-strings). Written to TWO temp files at start(); the outer is spawned as
--    `zsh -f <outer_tmp> <inner_tmp>` (the inner-init path is passed as $1). The INNER
--    mirrors Valodim's capture.zsh (compinit, the compadd capture override, a Tab wrapper
--    widget emitting PISTART/PIEND sentinels). The OUTER drives it per request
--    (^C reset, ^U clear, type cmd + Tab) + builds ONE single-object JSON between
--    sentinels (NOT per-line NDJSON — shell.lua `_feed` decodes ONE object).
--
--  * KNOWN LIMITATIONS (documented; v1 accepts — research §4/§7):
--      - `-f` skips ~/.zshrc → user ALIASES/functions are NOT loaded (CONSISTENT with the
--        prefer:"pi" stance: pi executes `!` cmds in bash by default — no zsh aliases
--        either; completing a zsh-only alias would suggest a command that FAILS). System
--        completion DEFINITIONS (_git etc.) ARE autoloadable → git/ls/etc. work. A future
--        config.shell.zsh.source_rc flag may unlock rc sourcing (risk: rc side-effects).
--      - cd(path) is ADVISORY (a documented no-op for v1): the INNER's Enter is bound to
--        a noop widget (NEVER execute — Valodim's safety), so a true inner `cd` needs a
--        dedicated control-char widget. v1 bakes the spawn cwd into the inner (opts.cwd)
--        and treats M.cd as best-effort. A future control-char widget can make cd real.
--      - A command line containing a literal `"` breaks the OUTER's crude `.line`
--        extraction → cmd resolves empty → an empty/all-commands result (graceful
--        degrade, not a crash). A true JSON parser in zsh is infeasible; v1 accepts this.
--
--  * NEVER-THROWS / FAST-CONTEXT-SAFE: every uv call is pcall'd; on_exit / timer /
--    stderr-read callbacks do NO `vim.api.*` (libuv FAST context — E5560); only luv calls
--    + the single `on_ready` invocation. No module-top `require("pi-bridge")` (needs only
--    `vim.uv`, like fish.lua).
--
--  * HANDLE OWNERSHIP (the F3 leak): `uv.process_kill(proc,"sigkill")` does NOT close the
--    uv_process_t. Every PRE-on_ready failure path MUST `proc:close()` AFTER
--    `process_kill` or the handle LEAKS. shell.lua's `close_handles` owns the
--    post-on_ready success-path close. Close order: stderr read_stop→close, proc
--    process_kill→close, stdin close, stdout close. os.remove BOTH temp files.
local M = {}
local uv = vim.uv

-- Module-local cache of the most-recently-handed-out stdin, so `M.cd(path)` (a DRIVER
-- method with no access to shell.lua's own state) can write a `__PICD__` frame to the
-- LIVE daemon. Safe because there is ONE daemon per session (shell.lua singleton state).
-- pcall + is_closing-guard every use (cd is advisory for zsh v1).
local last_stdin

-- ===========================================================================
-- The INNER init script (Valodim capture.zsh lineage; LIVE-VERIFIED against zsh 5.9.2)
-- ===========================================================================
-- Sourced by the outer via `zpty -w z "source $1"` (the inner-init path is passed as $1).
-- Sets up compsys (dedicated compdump — NEVER the user's ~/.zcompdump), binds Enter to a
-- noop widget (NEVER execute a typed command), redefines `compadd` to capture matches +
-- descriptions (delegating the -O/-A/-D array-storage forms + handling modern zsh combined
-- short opts like `-ld <descarray>`), and wraps the Tab widget to emit PISTART/PIEND
-- sentinels around EVERY completion (robust across requests — unlike compprefuncs/
-- comppostfuncs which only fire on the first). Emits __PIINNER_READY__ once at startup.
--
-- NB: written as a Lua `[=[ ... ]=]` long-string so NONE of its `\n`/`\t`/`\\` are
-- interpreted by Lua — they are LITERAL zsh source. The zsh script's OWN escapes
-- (e.g. `${s//\\/\\\\}`) are zsh parameter substitutions.
local INNER_SCRIPT = [=[
PROMPT=
# default TMPDIR (nvim's env often omits it) so the dedicated compdump path is always valid.
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

-- ===========================================================================
-- The OUTER daemon script (LIVE-VERIFIED against zsh 5.9.2)
-- ===========================================================================
-- Spawned by Lua as `zsh -f <this-file> <inner-init-path>`. -f skips zshenv/zshrc (the
-- outer needs no zle). Spawns the INNER in a non-blocking zpty (-b), waits for the inner's
-- __PIINNER_READY__ marker (polling with `zpty -r -t` so it never blocks), emits
-- __PIREADY__ to stderr once, drains residual pty output, then loops on stdin: each
-- __PIREQ__\t{json} → ^C reset + ^U clear + type cmd + Tab (fires the inner's PISTART/
-- compadd/PIEND) → capture between sentinels → build ONE single-object JSON → emit
-- between __PIRESP_START__/__PIRESP_END__. __PICD__ is recognized but advisory (v1 no-op).
local OUTER_SCRIPT = [=[
zmodload zsh/zpty || { echo "error: zsh/zpty missing" >&2; exit 1 }
__pi_json_str() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}
zpty -b z zsh -f -i
zpty -w z "source $1"$'\n'
# `_line` + `_l` declared ONCE here (not re-declared per request): zsh's `local` on an
# already-local var PRINTS its old value to stdout, corrupting the JSON stream.
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

-- ===========================================================================
-- M.parse(raw) — pure-Lua inner-compadd output parser (PRD §17.6.2 / §17.15)
-- ===========================================================================

--- Parse the INNER compadd override's raw `word⇥description` output (newline-delimited;
--- 0x09 = the first-tab delimiter) into the driver's raw-item wire shape
--- `{ value:string, description?:string }[]` — the exact input shell.lua `normalize_item`
--- consumes to build `AutocompleteItem {value, label=value, description?}` (PRD §17.6.2).
--- Pure Lua + never-throws + dependency-free (no `vim.*`/require) → fixture-testable
--- offline (PRD §17.15). Mirrors the daemon's compadd split semantics (first literal tab;
--- description optional; empty-word lines dropped). KNOWN LIMITATION: a candidate WORD
--- containing a literal 0x09 cannot round-trip (unescaped tab-delimited format) —
--- documented; do not add an escape scheme. NOT called by shell.lua `_feed` (the daemon
--- pre-builds single-object JSON; `M.parse` is the testable reference of the same spec).
--- The completion prefix is derived CLIENT-SIDE in shell.lua (which OVERRIDES the daemon's
--- advisory `"prefix":""`) — `M.parse` emits ONLY `{value, description?}`, never a prefix.
---@param raw string? Raw compadd stdout (UTF-8; non-string → {}).
---@return table[] items `{ value:string, description?:string }[]` (may be empty).
function M.parse(raw)
	if type(raw) ~= "string" then
		return {}
	end
	local items = {}
	for line in raw:gmatch("[^\r\n]+") do
		local tab = line:find("\t", 1, true)
		local value = tab and line:sub(1, tab - 1) or line
		if value ~= "" then
			local item = { value = value }
			local desc = tab and line:sub(tab + 1) or nil
			if desc and desc ~= "" then
				item.description = desc
			end
			items[#items + 1] = item
		end
	end
	return items
end

-- ===========================================================================
-- M.start(opts, on_ready) — spawn the outer zsh daemon + detect cold-start readiness
-- ===========================================================================

--- Spawn the zsh completion daemon + resolve `on_ready` with live luv handles (the
--- binding driver seam, shell.lua:696-712; structurally identical to fish.lua). Writes
--- OUTER_SCRIPT + INNER_SCRIPT to TWO temp files, creates three `uv.new_pipe(false)`
--- handles (stdin/stdout/stderr), spawns `zsh -f <outer_tmp> <inner_tmp>` with
--- `cwd=opts.cwd` (when non-nil), arms a `startup_timeout_ms` cold-start timer, reads
--- STDERR for the `__PIREADY__\n` marker (emitted by the OUTER after the INNER's compinit
--- signals readiness — the SLOW part, 100ms-1s+), and on readiness calls
--- `on_ready(nil, proc, stdin, stdout)` — handing stdout UNTOUCHED (shell.lua wires its
--- own `read_start` post-callback; two readers on one pipe is illegal).
---
--- FAILURE PATHS (each → `on_ready(err, nil, nil, nil)`, NEVER throws, NEVER leaks handles):
---   * script write failed (disk full / perms).
---   * spawn error (binary missing via a bogus `opts.shell` / luv refused the spawn).
---   * startup timeout (the inner's compinit hung past `startup_timeout_ms`).
---   * proc died pre-ready (stderr EOF before `__PIREADY__` — zsh/zpty missing, or the
---     inner crashed during compinit → the outer exits → on_exit fires → startup fail).
---
--- Exactly ONE `on_ready` call (a local `resolved` flag shared by the timer / stderr-read /
--- on_exit closures). stdout is handed off pristine (NEVER `read_start`'d by the driver).
--- stderr is `read_stop`'d + closed on readiness (the driver OWNS stderr — shell.lua never
--- stores it). The proc handle is `process_kill`'d + `close`'d on EVERY pre-on_ready failure
--- (the F3 leak). BOTH temp files are `os.remove`'d on every terminal path. NO `vim.api.*`
--- in any callback (libuv FAST context).
---
---@param opts table? { shell:string?, cwd:string?, startup_timeout_ms:integer? }.
---@param on_ready fun(err:string|nil, proc:userdata?, stdin:userdata?, stdout:userdata?) The ready cb.
function M.start(opts, on_ready)
	-- never-throws on a bad arg (mirrors shell.lua's discipline; a non-function cb is a noop).
	if type(on_ready) ~= "function" then
		return
	end
	opts = opts or {}
	local shell_bin = (type(opts.shell) == "string" and opts.shell ~= "") and opts.shell or "zsh"
	local cwd = (type(opts.cwd) == "string" and opts.cwd ~= "") and opts.cwd or nil
	local timeout_ms = (type(opts.startup_timeout_ms) == "number" and opts.startup_timeout_ms > 0)
			and opts.startup_timeout_ms
		or 5000

	-- the single exit point: exactly-one on_ready call (guards the timer/read/on_exit races).
	local resolved = false
	-- module-locals closed over by the teardown closures (set AFTER successful spawn so a
	-- pre-spawn failure can't reference a nil handle).
	local proc, stdin, stdout, stderr_pipe, timer, outer_path, inner_path

	local function done(err, p, si, so)
		if resolved then
			return
		end
		resolved = true
		on_ready(err, p, si, so)
	end

	-- kill + close every handle on a PRE-on_ready failure (the F3 leak fix: process_kill
	-- does NOT close uv_process_t). Mirror shell.lua close_handles order: stderr read_stop→close,
	-- proc process_kill→close, stdin close, stdout close. pcall + is_closing-guard EVERY call
	-- (double-close throws; a half-spawned state may have nil handles). NO vim.api.* (fast ctx).
	-- os.remove BOTH temp files on every terminal path.
	local function fail(errmsg)
		pcall(function()
			if timer and not timer:is_closing() then
				timer:stop()
				timer:close()
			end
		end)
		pcall(function()
			if stderr_pipe and not stderr_pipe:is_closing() then
				stderr_pipe:read_stop()
				stderr_pipe:close()
			end
		end)
		pcall(function()
			if proc and not proc:is_closing() then
				uv.process_kill(proc, "sigkill")
				proc:close()
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
		if outer_path then
			pcall(os.remove, outer_path)
		end
		if inner_path then
			pcall(os.remove, inner_path)
		end
		last_stdin = nil
		done(errmsg, nil, nil, nil)
	end

	-- (1) write OUTER_SCRIPT + INNER_SCRIPT to TWO temp files. pcall (disk full / perms → fail).
	outer_path = os.tmpname()
	inner_path = os.tmpname()
	local wok, werr = pcall(function()
		local f = assert(io.open(outer_path, "w"))
		f:write(OUTER_SCRIPT)
		f:close()
		local g = assert(io.open(inner_path, "w"))
		g:write(INNER_SCRIPT)
		g:close()
	end)
	if not wok then
		return fail("script write failed: " .. tostring(werr))
	end

	-- (2) create the three piped streams (false = not a TTY; the outer zsh is a plain script).
	stdin = uv.new_pipe(false)
	stdout = uv.new_pipe(false)
	stderr_pipe = uv.new_pipe(false)
	if not (stdin and stdout and stderr_pipe) then
		return fail("pipe alloc failed")
	end

	-- (3) spawn `zsh -f <outer_tmp> <inner_tmp>` with cwd when non-nil. pcall (a bad shell
	--     path / luv refusal → fail path). on_exit fires if the proc dies — if that happens
	--     BEFORE readiness, treat it as a startup failure (zsh/zpty missing / compinit crash).
	local spawn_ok, spawn_err = pcall(function()
		local spawn_opts = {
			args = { "-f", outer_path, inner_path },
			stdio = { stdin, stdout, stderr_pipe },
		}
		if cwd then
			spawn_opts.cwd = cwd
		end
		proc = uv.spawn(shell_bin, spawn_opts, function(exit_code, signal)
			-- proc died. If we already resolved (success), do nothing — shell.lua's stdout EOF
			-- → _reset handles the mid-session crash. If NOT yet ready, it's a startup failure.
			if not resolved then
				fail("zsh exited pre-ready (code=" .. tostring(exit_code) .. " sig=" .. tostring(signal) .. ")")
			end
		end)
	end)
	if not spawn_ok then
		return fail("spawn threw: " .. tostring(spawn_err))
	end
	if not proc then
		return fail("spawn returned no handle (binary missing?): " .. tostring(spawn_err))
	end

	-- (4) arm the cold-start timer (the driver OWNS it — shell.lua passes startup_timeout_ms
	--     THROUGH). One-shot (start(ms, 0, cb)); on fire → fail("startup timeout"). The SLOW
	--     part is the inner's compinit (it builds the dedicated compdump on first run).
	timer = uv.new_timer()
	if not timer then
		return fail("timer alloc failed")
	end
	local tok = pcall(function()
		timer:start(timeout_ms, 0, function()
			if not resolved then
				fail("startup timeout")
			end
		end)
	end)
	if not tok then
		return fail("timer start threw")
	end

	-- (5) read STDERR for the `__PIREADY__\n` marker (stdout stays PRISTINE for shell.lua —
	--     two read_start's on one pipe is illegal). Accumulate into ready_buf; on marker →
	--     read_stop stderr + stop/close the timer + remove BOTH tmps + cache last_stdin +
	--     done(nil). EOF on stderr before the marker → proc died during compinit → fail.
	local ready_buf = ""
	local rok = pcall(function()
		stderr_pipe:read_start(function(rerr, data)
			if resolved then
				return
			end
			if rerr then
				return fail("stderr read err: " .. tostring(rerr))
			end
			if data then
				ready_buf = ready_buf .. data
				if ready_buf:find("__PIREADY__\n", 1, true) then
					-- READY: stop + close stderr (the driver owns it), stop+close the timer,
					-- remove BOTH temp scripts, cache stdin for cd(), hand off stdout PRISTINE.
					pcall(function()
						stderr_pipe:read_stop()
					end)
					pcall(function()
						if not stderr_pipe:is_closing() then
							stderr_pipe:close()
						end
					end)
					pcall(function()
						if timer and not timer:is_closing() then
							timer:stop()
							timer:close()
						end
					end)
					if outer_path then
						pcall(os.remove, outer_path)
					end
					if inner_path then
						pcall(os.remove, inner_path)
					end
					last_stdin = stdin
					done(nil, proc, stdin, stdout)
				end
			else
				-- stderr EOF before the ready marker → the daemon died during startup.
				fail("stderr EOF pre-ready (zsh crashed during startup / zsh/zpty missing?)")
			end
		end)
	end)
	if not rok then
		return fail("stderr read_start threw")
	end
end

-- ===========================================================================
-- M.cd(path) — best-effort (advisory for zsh v1) re-cd over the framed channel
-- ===========================================================================

--- Re-`cd` the daemon to `path` by writing a `__PICD__\t<path>\n` frame to its stdin.
--- For zsh v1 this is **ADVISORY / a documented no-op**: the OUTER recognizes `__PICD__`
--- but the INNER's Enter is bound to a noop widget (NEVER execute — Valodim's safety),
--- so a true inner `cd` needs a dedicated control-char widget (a documented future
--- enhancement). v1 bakes the spawn cwd into the inner (via `opts.cwd`); path completions
--- are relative to that; a mid-session cwd change re-spawns. The method EXISTS (the
--- contract requires it) + never throws, but does not change the inner's cwd.
--- Best-effort + silent: a dead/closing pipe is a noop (NOT an error). pcall'd +
--- is_closing-guarded so a throwing/closed stdin can't escape. Writes via `last_stdin`
--- (cached by start(); ONE daemon per session — shell.lua singleton state).
---@param path string The target directory (tostring'd; nil/non-string → noop).
function M.cd(path)
	if type(path) ~= "string" or path == "" then
		return
	end
	if not last_stdin then
		return
	end
	-- is_closing may itself be missing on a malformed handle — pcall the whole guard.
	local alive = pcall(function()
		return not last_stdin:is_closing()
	end)
	if not alive then
		return
	end
	pcall(function()
		last_stdin:write(string.format("__PICD__\t%s\n", path), function() end)
	end)
end

return M
