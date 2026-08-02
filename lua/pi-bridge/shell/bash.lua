--- bash.lua — the Tier-2 bash shell-completion driver (PRD §17.6.3 / §17.5.1).
--
-- Exposes `M.start(opts, on_ready)` + `M.cd(path)`, the per-shell driver seam shell.lua's
-- `M.pick_driver` resolves (`require("pi-bridge.shell.bash")`) and `M.ensure` drives
-- (`state.driver.start({shell,cwd,startup_timeout_ms}, cb)`). It is the THIRD concrete
-- driver (P2.M3.T5.S2); it mirrors fish.lua's Lua shape with a different DAEMON_SCRIPT.
--
-- [Mode A] header — read before editing:
--  * ROLE: spawn ONE persistent `bash <daemon_script>` completion daemon per session, hand
--    its live luv proc + stdin + stdout handles to shell.lua via `on_ready`, and re-`cd` it
--    over the framed channel on demand. shell.lua owns the request/response framing
--    (`request`→`stdin:write("__PIREQ__\t{json}\n", cb)`, `_feed`→`stdout:read_start`);
--    bash.lua owns ONLY spawn + cold-start readiness + the daemon's startup script.
--
--  * WHY PLAIN PIPES (≈ fish; UNLIKE zsh): bash's `compgen` + `complete -F fn` dispatch are
--    ORDINARY builtins callable NON-interactively over plain stdin/stdout pipes. NO TTY,
--    NO PTY, NO outer/inner split. So bash.lua is structurally IDENTICAL to fish.lua (one
--    process, one temp file, stderr-ready-signal, REAL cd). The ONLY difference from fish
--    is the spawn args (`bash <tmp>` instead of `fish -i --init-command=...`) and the
--    DAEMON_SCRIPT contents (bash with COMP_*/compgen dispatch instead of fish's
--    `complete -C`). See plan/.../research/bash_driver_findings.md §1.
--
--  * START CONTRACT (the binding seam — shell.lua:696-712; identical to fish.lua):
--      M.start(opts, on_ready)
--        opts = { shell="/usr/bin/bash", cwd="/srv"?, startup_timeout_ms=5000? }
--        on_ready(err, proc, stdin, stdout)
--          err   = nil on success; an error string on EVERY failure.
--          proc  = the uv_process_t (shell.lua teardown process_kill's + close's it).
--          stdin = the uv_pipe_t → daemon stdin (shell.lua request() writes frames to it).
--          stdout= the uv_pipe_t ← daemon stdout (shell.lua wires read_start→_feed on it).
--    `proc` MUST be the uv_process_t; `stdin`/`stdout` MUST be uv_pipe_t. NEVER throws:
--    every luv call is pcall'd; a bad arg / spawn error / startup timeout degrades to
--    `on_ready(err, nil, nil, nil)`. Exactly ONE on_ready call (a local `resolved` flag).
--
--  * STDERR-READY-SIGNAL: the driver detects cold-start readiness by reading STDERR for an
--    `__PIREADY__\n` marker the daemon script emits after best-effort bash-completion
--    sourcing. It CANNOT use stdout for this — shell.lua wires `stdout:read_start` AFTER
--    on_ready (shell.lua:707), and two `read_start`'s on one pipe is ILLEGAL in luv. So
--    stdout stays PRISTINE for shell.lua; the driver owns + closes the stderr pipe
--    (shell.lua's `close_handles` EXPLICITLY does NOT close stderr — "the driver owns it").
--    (identical to fish.lua; research §7)
--
--  * THE DAEMON SCRIPT: embedded below as `DAEMON_SCRIPT` (a bash long-string, level-1
--    `[=[ ... ]=]` brackets — bash's `[[:space:]]` regex contains `]]` which would
--    terminate a plain `[[ ]]` Lua long-string early). It is written to a temp file at
--    start() time + spawned as `bash <tmp>` (NON-interactive script mode — research §7).
--    It best-effort sources `bash-completion` (the 4 canonical paths, `[ -r ]`-guarded;
--    NEVER depends on it — §5), defines `__pi_json_str` (pure-bash parameter-substitution
--    JSON escape — NO `python3`/`jq` dependency, research §2), defines `__pi_complete`
--    (sets COMP_* via the LIVE-VALIDATED trailing-whitespace-aware computation — research
--    §3, NOT the PRD §17.6.3 buggy accumulation loop; dispatches `complete -F fn` if a
--    compspec exists, else `compgen -abck` for COMP_CWORD==0 else `compgen -f -d`),
--    recognizes `__PIREQ__`/`__PICD__` frames, emits `__PIREADY__` to stderr once at
--    startup, then enters a persistent `while IFS= read -r req` loop wrapping each request
--    in `__PIRESP_START__`/`__PIRESP_END__` sentinels (single-object JSON — the shell.lua
--    `_feed` contract).
--
--  * DIVERGENCE FROM PRD §17.6.3 SKETCH (documented per §17.6.x doc inconsistency):
--      - pure-bash JSON escape (`__pi_json_str`), NOT `python3 -c 'json.dumps'` (python3
--        is NOT guaranteed on the user's box — research §2; bash + zsh share the
--        `${var//from/to}` substitution syntax, mirroring zsh.lua's OUTER_SCRIPT).
--      - single-object response, NOT per-line NDJSON (shell.lua `_feed` decodes the whole
--        body as ONE object; NDJSON throws → parse_failure).
--      - the §3 COMP_CWORD computation (truncated-prefix + trailing-whitespace detection),
--        NOT the PRD sketch's accumulation loop (which is BUGGY for trailing-space inputs
--        like `ls ` — `read -ra` strips trailing ws → cword=0 → completing the command
--        AGAIN instead of the argument; research §3b).
--      - a cword==0 → `compgen -abck -A function` branch (command-name completion —
--        research §4); the PRD sketch had none (would fall through to `compgen -f -d`
--        files for a command name — wrong).
--    GRACEFUL DEGRADE (Issue 6): a command line containing a literal `"` (or an empty
--      line) breaks the crude `.line` extraction (`git \"feature` → `line` `git \\`, a
--      DANGLING backslash — NOT empty). `__pi_handle`'s `(__PIREQ__*)` branch now GUARDS
--      `line` BEFORE the completion subshell: an empty `line` (→ `compgen -abck -- ""`
--      FLOOD) or one ending in an ODD run of backslashes (the dangling-`\\` case) emits a
--      clean EMPTY `{"items":[],"prefix":""}` instead. An EVEN run (`echo \\`) is a valid
--      escaped backslash, kept. A true JSON-string parse is infeasible in pure bash
--      without `jq`/`python3`; the guard converts the edge into a graceful no-results.
--
--  * REAL cd (NOT advisory like zsh v1): bash's daemon is a plain script loop; nothing
--    constrains `builtin cd`. The `__PICD__\t<path>\n` frame does a REAL `builtin cd` and
--    subsequent path completions are relative to the new cwd (research §6 — a genuine
--    quality advantage over zsh v1). Mirrors fish.lua's `cd()` verbatim.
--
--  * NEVER-THROWS / FAST-CONTEXT-SAFE: every uv call is pcall'd; on_exit / timer /
--    stderr-read callbacks do NO `vim.api.*` (they run in libuv FAST context — E5560);
--    only luv calls + the single `on_ready` invocation. No module-top `require("pi-bridge")`
--    (the handshake is async; bash.lua needs only `vim.uv`, like fish.lua).
--
--  * HANDLE OWNERSHIP (the F3 leak): `uv.process_kill(proc,"sigkill")` does NOT close the
--    uv_process_t (`is_closing` stays false even after `on_exit`). Every PRE-on_ready
--    failure path in `start()` MUST `proc:close()` AFTER `process_kill` or the handle
--    LEAKS. shell.lua's `close_handles` owns the post-on_ready success-path close. Close
--    order: stderr read_stop→close, proc process_kill→close, stdin close, stdout close.
--    os.remove the temp file on every terminal path.
local M = {}
local uv = vim.uv

-- Module-local cache of the most-recently-handed-out stdin, so `M.cd(path)` (a DRIVER
-- method with no access to shell.lua's own state) can write a `__PICD__` frame to the
-- LIVE daemon. Safe because there is ONE daemon per session (shell.lua singleton state) —
-- `last_stdin` is always the live one. pcall + is_closing-guard every use (cd is REAL
-- for bash — but still best-effort/silent on a dead pipe).
local last_stdin

-- ===========================================================================
-- The bash DAEMON SCRIPT (LIVE-VALIDATED against bash 5.3.15 — research §2/§3/§4/§5/§6/§7/§9/§10)
-- ===========================================================================
-- Spawned by Lua as: `bash <this-file>` (NON-interactive script mode; NO -i; research §7).
-- Best-effort sources bash-completion (system compspecs); NEVER depends on it (research §5).
-- Reads framed `__PIREQ__\t{json}\n` (and `__PICD__\t<path>\n`) lines from stdin; for a
-- request it sets COMP_* (the §3 trailing-whitespace-aware computation), dispatches
-- `complete -F fn` if a compspec exists else `compgen -abck`/`compgen -f -d`, builds ONE
-- single-object JSON, and emits it between `__PIRESP_START__\n` / `__PIRESP_END__\n`
-- sentinels (the §17.5.1 wire frame). Emits `__PIREADY__\n` to stderr once at startup
-- (the cold-start signal the Lua start() reads BEFORE handing stdout off to shell.lua).
--
-- NB: written as a Lua `[=[ ... ]=]` long-string (level-1 brackets) so NONE of its
-- `\n`/`\t`/`\\` escapes are interpreted by Lua — they are LITERAL bash source. Level-1
-- brackets are REQUIRED because bash's `[[:space:]]` regex class contains `]]`, which
-- would terminate a plain `[[ ... ]]` Lua long-string early. The bash script's OWN
-- escapes (e.g. `${s//\\/\\\\}`) are bash parameter substitutions.
local DAEMON_SCRIPT = [=[
trap '' PIPE                                # a closed stdout must not SIGPIPE-kill us (research §10)

# (0) Best-effort source bash-completion (the system _git/_ls compspecs). Each path
#     [ -r ]-guarded; if NONE exist (no bash-completion, e.g. this box) → no compspecs
#     register → §5 file/dir fallback governs. NEVER depends on it.
for _bc in /usr/share/bash-completion/bash_completion \
           /usr/local/share/bash-completion/bash_completion \
           /etc/bash_completion /usr/local/etc/bash_completion ; do
    [ -r "$_bc" ] && { . "$_bc" || true; break; }
done
unset _bc

# Pure-bash JSON string escape (python3-free; mirrors zsh.lua OUTER_SCRIPT; research §2).
# Escapes \, ", \n, \r, \t (backslash FIRST). Outputs the double-quoted JSON string.
__pi_json_str() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

# The COMP_* + compgen/complete -F dispatch (research §3/§4/§5). Sets COMP_LINE/COMP_POINT/
# COMP_WORDS/COMP_CWORD via the LIVE-VALIDATED trailing-whitespace-aware computation (NOT
# the PRD sketch's buggy accumulation loop), then dispatches: compspec -F fn → call it;
# cword==0 → compgen -abck (command names); else compgen -f -d (files/dirs — ALWAYS works).
__pi_complete() {
    local line="$1" point="$2"
    COMP_LINE="$line"; COMP_POINT="$point"
    # THE §3 FIX: truncate at point, detect trailing whitespace, append an empty word so
    # cur="" for `ls ` (trailing space). `read -ra` STRIPS trailing ws otherwise.
    local prefix="${line:0:point}"
    local trailing_ws=0
    [[ "$prefix" =~ [[:space:]]$ ]] && trailing_ws=1
    COMP_WORDS=()
    read -ra COMP_WORDS <<< "$prefix"
    (( ${#COMP_WORDS[@]} == 0 )) && COMP_WORDS+=("")        # empty line → one empty word (guards cword=-1)
    (( trailing_ws )) && COMP_WORDS+=("")                   # cursor in trailing ws → new empty word
    COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ))
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local cmd="${COMP_WORDS[0]}"
    COMPREPLY=()
    if (( COMP_CWORD == 0 )); then
        # completing the COMMAND name itself (research §4): commands/aliases/builtins/keywords/functions.
        COMPREPLY=( $(compgen -abck -A function -- "$cur" 2>/dev/null) )
    else
        # cword>0: look for the command's registered compspec (research §5). `complete -p`
        # prints the registration line; parse the -F function. If found, call it (it
        # populates COMPREPLY).
        #
        # LAZY-LOADING (NEW-1 fix): modern bash-completion (2.11+, the default on current
        # Ubuntu/Debian/Fedora/Arch) registers per-command completions LAZILY via a
        # default handler `complete -D -F _completion_loader` that sources
        # completions/<cmd> on first use. The per-command `complete -F _git git` is
        # therefore NOT registered until that default handler fires — so a bare
        # `complete -p "$cmd"` returns empty for every lazy command and we silently fall
        # through to the file/dir fallback (argument completion broken). To match a real
        # interactive bash (which invokes the -D handler on Tab), explicitly invoke the
        # default loader for the command to force-load its compspec, THEN re-check
        # `complete -p "$cmd"`. Best-effort + silent (no bash-completion → no -D handler →
        # spec stays empty → file/dir fallback, unchanged behavior).
        local _def_loader
        _def_loader=$(complete -p -D 2>/dev/null | sed -n 's/.*-F[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p')
        if [ -n "$_def_loader" ] && ! complete -p "$cmd" >/dev/null 2>&1; then
            # the -D handler expects COMP_LINE/COMP_POINT/COMP_WORDS/COMP_CWORD set (it
            # may dispatch on $1==$cmd). Invoke it IN THIS SHELL (NOT a subshell) so its
            # side effect — registering `complete -F <fn> <cmd>` — PERSISTS for the
            # `complete -p "$cmd"` re-check below. (A subshell would discard the reg.)
            # The loader itself does no completion (it only registers); errors are ignored.
            "$_def_loader" "$cmd" "$cur" "${COMP_WORDS[COMP_CWORD-1]}" 2>/dev/null || true
        fi
        local spec
        spec=$(complete -p "$cmd" 2>/dev/null) || spec=""
        if [[ "$spec" == *-F\ * ]]; then
            local fn; fn=$(printf '%s' "$spec" | sed -n 's/.*-F[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p')
            if [ -n "$fn" ] && type "$fn" >/dev/null 2>&1; then
                "$fn" "$cmd" "$cur" "${COMP_WORDS[COMP_CWORD-1]}" 2>/dev/null || true
            fi
        fi
        # if the -F fn produced nothing (or no compspec existed) → files+dirs fallback (ALWAYS works).
        if [ ${#COMPREPLY[@]} -eq 0 ]; then
            COMPREPLY=( $(compgen -f -d -- "$cur" 2>/dev/null) )
        fi
    fi
}

# Handle ONE __PIREQ__ / __PICD__ line (argv[1]). Extracts .line/.cursor (crude parameter
# substitution — research §9), dispatches, builds single-object JSON. cd is REAL (research §6).
__pi_handle() {
    local line_in="$1"
    case "$line_in" in
        (__PICD__*)
            local p="${line_in#__PICD__	}"      # strip "__PICD__\t" (literal tab)
            builtin cd "$p" 2>/dev/null           # REAL cd (research §6); silent on failure
            return
            ;;
        (__PIREQ__*)
            local payload="${line_in#__PIREQ__	}"   # strip "__PIREQ__\t" (literal tab)
            local line="${payload#*\"line\":\"}"; line="${line%%\"*}"   # crude .line (research §9)
            local cursor="${payload#*\"cursor\":}"; cursor="${cursor%%[!0-9]*}"
            cursor="${cursor:-0}"
            # === GRACEFUL-DEGRADE GUARD (Issue 6 / PRD §17.6.x) ===
            # The crude `.line` extraction cannot parse a JSON-escaped `\"`, so a line
            # containing a literal `\"` leaves a DANGLING backslash at the end of `line`
            # (e.g. `git \"feature` → `line` `git \\`, a DANGLING backslash — NOT empty).
            # __pi_handle's `(__PIREQ__*)` branch now GUARDS `line` BEFORE the completion
            # subshell: an empty `line` (→ `compgen -abck -- ""` FLOOD) or one ending
            # in an ODD run of backslashes (the dangling-`\\` case) emits a clean EMPTY
            # `{"items":[],"prefix":""}` instead. An EVEN run (`echo \\`) is a valid
            # escaped backslash, kept.
            local _tail="${line##*[^\\]}"
            echo __PIRESP_START__
            if [[ -z "$line" ]] || (( ${#_tail} % 2 )); then
                printf '{"items":[],"prefix":""}\n'
            else
                (
                    # run completion dispatch in a subshell so a buggy compspec fn can't kill us (research §10)
                    __pi_complete "$line" "$cursor"
                    local _items="" _first=1 w
                    for w in "${COMPREPLY[@]}"; do
                        [ -z "$w" ] && continue
                        local _it="{\"value\":$(__pi_json_str "$w")}"     # bash: {value} ONLY (no description, §8)
                        if ((_first)); then _items="$_it"; _first=0; else _items="${_items},${_it}"; fi
                    done
                    printf '{"items":[%s],"prefix":""}\n' "$_items"
                ) 2>/dev/null
            fi
            echo __PIRESP_END__                  # ALWAYS emit END (so shell.lua _feed never hangs; §10)
            ;;
    esac
}

# Announce readiness on STDERR (fd 2) — the Lua start() reads stderr for this marker
# (stdout is owned by shell.lua post-on_ready; two read_start's on one pipe is illegal).
printf '__PIREADY__\n' >&2

# Persistent request loop (the spike did one request; production loops for the session).
while IFS= read -r req; do
    __pi_handle "$req"
done
]=]

-- ===========================================================================
-- M.parse(raw) — pure-Lua compgen/COMPREPLY output parser (PRD §17.6.3 / §17.15)
-- ===========================================================================

--- Parse raw bash `compgen`/`COMPREPLY` output (newline-delimited BARE WORDS — no
--- descriptions; bash's completion protocol has no description channel, Tier-2 §8) into
--- the driver's raw-item wire shape `{ value:string }[]` — the exact input shell.lua
--- `normalize_item` consumes to build `AutocompleteItem {value, label=value}` (PRD
--- §17.6.3). Pure Lua + never-throws + dependency-free (no `vim.*`/require) →
--- fixture-testable offline (PRD §17.15 "no live bash needed for the parser"). Mirrors
--- the daemon's `__pi_handle` semantics (each non-empty line IS a value; no tab-split —
--- bash emits bare words). NOT called by shell.lua `_feed` (the daemon pre-builds
--- single-object JSON; `M.parse` is the testable reference of the same spec). The
--- completion prefix is derived CLIENT-SIDE in shell.lua (which OVERRIDES the daemon's
--- advisory `"prefix":""`) — `M.parse` emits ONLY `{value}`, never a prefix/description.
---@param raw string? Raw compgen/COMPREPLY stdout (UTF-8; non-string → {}).
---@return table[] items `{ value:string }[]` (may be empty).
function M.parse(raw)
	if type(raw) ~= "string" then
		return {}
	end
	local items = {}
	for line in raw:gmatch("[^\r\n]+") do -- split lines; gmatch skips empty lines
		if line ~= "" then -- drop empty-word lines (parity with normalize_item, which drops empty-value items)
			items[#items + 1] = { value = line } -- bash: bare words, {value} ONLY (no description — Tier-2, §8)
		end
	end
	return items
end

-- ===========================================================================
-- M.start(opts, on_ready) — spawn the bash daemon + detect cold-start readiness
-- ===========================================================================

--- Spawn the bash completion daemon + resolve `on_ready` with live luv handles (the
--- binding driver seam, shell.lua:696-712; structurally identical to fish.lua). Writes
--- `DAEMON_SCRIPT` to a temp file, creates three `uv.new_pipe(false)` handles
--- (stdin/stdout/stderr), spawns `bash <tmp>` (NON-interactive script mode — the script
--- as a positional arg; NO -i, research §7) with `cwd=opts.cwd` (when non-nil), arms a
--- `startup_timeout_ms` cold-start timer, reads STDERR for the `__PIREADY__\n` marker,
--- and on readiness calls `on_ready(nil, proc, stdin, stdout)` — handing stdout UNTOUCHED
--- (shell.lua wires its own `read_start` post-callback; two readers on one pipe is illegal).
---
--- FAILURE PATHS (each → `on_ready(err, nil, nil, nil)`, NEVER throws, NEVER leaks handles):
---   * script write failed (disk full / perms).
---   * spawn error (binary missing via a bogus `opts.shell` / luv refused the spawn).
---   * startup timeout (bash-completion sourcing hung past `startup_timeout_ms`; the ready
---     marker never arrived — the timer fires).
---   * proc died pre-ready (stderr EOF before `__PIREADY__`; bash crashed during sourcing —
---     `on_exit` fires + the readiness guard treats it as a startup fail).
---
--- Exactly ONE `on_ready` call (a local `resolved` flag shared by the timer / stderr-read /
--- on_exit closures). stdout is handed off pristine (NEVER `read_start`'d by the driver).
--- stderr is `read_stop`'d + closed on readiness (the driver OWNS stderr — shell.lua never
--- stores it). The proc handle is `process_kill`'d + `close`'d on EVERY pre-on_ready failure
--- (the F3 leak: `process_kill` alone does NOT close `uv_process_t`). The temp file is
--- `os.remove`'d on every terminal path. NO `vim.api.*` in any callback (libuv FAST context).
--- bash cold-start is FAST vs zsh (only the best-effort bash-completion sourcing; 5000ms default ample).
---
---@param opts table? { shell:string?, cwd:string?, startup_timeout_ms:integer? }.
---@param on_ready fun(err:string|nil, proc:userdata?, stdin:userdata?, stdout:userdata?) The ready cb.
function M.start(opts, on_ready)
	-- never-throws on a bad arg (mirrors shell.lua's discipline; a non-function cb is a noop).
	if type(on_ready) ~= "function" then
		return
	end
	opts = opts or {}
	local shell_bin = (type(opts.shell) == "string" and opts.shell ~= "") and opts.shell or "bash"
	local cwd = (type(opts.cwd) == "string" and opts.cwd ~= "") and opts.cwd or nil
	local timeout_ms = (type(opts.startup_timeout_ms) == "number" and opts.startup_timeout_ms > 0)
			and opts.startup_timeout_ms
		or 5000

	-- the single exit point: exactly-one on_ready call (guards the timer/read/on_exit races).
	local resolved = false
	-- module-locals closed over by the teardown closures (set AFTER successful spawn so a
	-- pre-spawn failure can't reference a nil handle).
	local proc, stdin, stdout, stderr_pipe, timer, tmp_path

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
		if tmp_path then
			pcall(os.remove, tmp_path)
		end
		last_stdin = nil
		done(errmsg, nil, nil, nil)
	end

	-- (1) write DAEMON_SCRIPT to a temp file. pcall (disk full / perms → fail path).
	tmp_path = os.tmpname()
	local wok, werr = pcall(function()
		local f = assert(io.open(tmp_path, "w"))
		f:write(DAEMON_SCRIPT)
		f:close()
	end)
	if not wok then
		return fail("script write failed: " .. tostring(werr))
	end

	-- (2) create the three piped streams (false = not a TTY; bash is a plain non-interactive script).
	stdin = uv.new_pipe(false)
	stdout = uv.new_pipe(false)
	stderr_pipe = uv.new_pipe(false)
	if not (stdin and stdout and stderr_pipe) then
		return fail("pipe alloc failed")
	end

	-- (3) spawn `bash <tmp>` (NON-interactive; the script is a positional arg — NO -i, research §7)
	--     with cwd when non-nil. pcall (a bad shell path / luv refusal → fail path). on_exit fires
	--     if the proc dies — if that happens BEFORE readiness, treat it as a startup failure.
	local spawn_ok, spawn_err = pcall(function()
		local spawn_opts = {
			args = { tmp_path },
			stdio = { stdin, stdout, stderr_pipe },
		}
		if cwd then
			spawn_opts.cwd = cwd
		end
		proc = uv.spawn(shell_bin, spawn_opts, function(exit_code, signal)
			-- proc died. If we already resolved (success), do nothing — shell.lua's stdout EOF
			-- → _reset handles the mid-session crash. If NOT yet ready, it's a startup failure.
			if not resolved then
				fail("bash exited pre-ready (code=" .. tostring(exit_code) .. " sig=" .. tostring(signal) .. ")")
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
	--     THROUGH). One-shot (start(ms, 0, cb)); on fire → fail("startup timeout").
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
	--     read_stop stderr + stop/close the timer + remove tmp + cache last_stdin + done(nil).
	--     EOF on stderr before the marker → proc died during sourcing → fail.
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
					-- remove the temp script, cache stdin for cd(), hand off stdout PRISTINE.
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
					if tmp_path then
						pcall(os.remove, tmp_path)
					end
					last_stdin = stdin
					done(nil, proc, stdin, stdout)
				end
			else
				-- stderr EOF before the ready marker → the daemon died during sourcing.
				fail("stderr EOF pre-ready (bash crashed during startup)")
			end
		end)
	end)
	if not rok then
		return fail("stderr read_start threw")
	end
end

-- ===========================================================================
-- M.cd(path) — REAL re-cd over the framed channel (unlike zsh v1's advisory no-op)
-- ===========================================================================

--- Re-`cd` the daemon to `path` by writing a `__PICD__\t<path>\n` frame to its stdin.
--- For bash this is **REAL** (research §6 — unlike zsh v1's advisory no-op): the daemon's
--- `__PICD__` branch does `builtin cd "$path"` and subsequent path completions are relative
--- to the new cwd. A genuine quality advantage over the zsh driver for v1 (real cwd tracking).
---
--- WIRED (Issue 4 / §17.5.2): `shell.complete_current` calls this whenever pi's session
--- cwd (`M.session_cwd()`) changed since spawn — bash honors `__PICD__` with a real
--- `builtin cd`, so completions track the new cwd on the very next keystroke (submitted
--- synchronously BEFORE the `__PIREQ__` frame so libuv FIFO write order guarantees the
--- daemon `cd`s before it completes).
---
--- Best-effort + silent: a dead/closing pipe is a noop (NOT an error — cd is best-effort;
--- the next request's completions use the prior cwd). pcall'd + is_closing-guarded so a
--- throwing/closed stdin can't escape. Writes via `last_stdin` (cached by start(); there is
--- ONE daemon per session — shell.lua singleton state — so last_stdin is always the live one).
--- NEVER throws. Mirrors shell.lua request()'s write-cb discipline (a callback-less write
--- silently swallows EPIPE; we pass a noop cb so the write is fire-and-forget but luv-clean).
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
