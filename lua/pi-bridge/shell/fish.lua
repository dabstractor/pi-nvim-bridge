--- fish.lua — the Tier-1 fish shell-completion driver (PRD §17.6.1 / §17.5.1).
--
-- Exposes `M.start(opts, on_ready)` + `M.cd(path)`, the per-shell driver seam
-- shell.lua's `M.pick_driver` resolves (`require("pi-bridge.shell.fish")`) and `M.ensure`
-- drives (`state.driver.start({shell,cwd,startup_timeout_ms}, cb)`). It is the FIRST
-- concrete driver (P2.M2.T4.S1); `zsh.lua`/`bash.lua` (P2.M3.T5) copy its shape.
--
-- [Mode A] header — read before editing:
--  * ROLE: spawn ONE persistent `fish -i` completion daemon per session, hand its live
--    luv proc + stdin + stdout handles to shell.lua via `on_ready`, and re-`cd` it over
--    the framed channel on demand. shell.lua owns the request/response framing
--    (`request`→`stdin:write("__PIREQ__\t{json}\n", cb)`, `_feed`→`stdout:read_start`);
--    fish.lua owns ONLY spawn + cold-start readiness + the daemon's startup script.
--
--  * START CONTRACT (the binding seam — shell.lua:696-712):
--      M.start(opts, on_ready)
--        opts = { shell="/usr/bin/fish", cwd="/srv"?, startup_timeout_ms=5000? }
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
--    `__PIREADY__\n` marker the daemon script emits after config sourcing. It CANNOT use
--    stdout for this — shell.lua wires `stdout:read_start` AFTER on_ready (shell.lua:707),
--    and two `read_start`'s on one pipe is ILLEGAL in luv. So stdout stays PRISTINE for
--    shell.lua; the driver owns + closes the stderr pipe (shell.lua's `close_handles`
--    EXPLICITLY does NOT close stderr — "the driver owns it"). (research §7)
--
--  * THE DAEMON SCRIPT: embedded below as `DAEMON_SCRIPT` (a fish long-string). It is
--    written to a temp file at start() time + sourced via
--    `fish -i --init-command="source <tmpfile>"`. It defines `__pi_json_str` (jq-free
--    manual JSON escape — fish 4.x has NO `--style=json` / `printf %j`, LIVE-VERIFIED
--    against 4.8.1), `__pi_handle` (extract `.line` via the SIMPLE `"line":"([^"]*)"`
--    regex — the fancy `(?:...)` PCRE variant COMPILE-ERRORS in fish, research §4 — run
--    `complete -C`, build ONE single-object JSON between sentinels — NOT per-line NDJSON,
--    which shell.lua `_feed` LIVE-VERIFIED FAILS to decode), silences `fish_prompt`,
--    emits `__PIREADY__` to stderr, then enters a persistent `while read` loop.
--
--  * DIVERGENCE FROM PRD §17.6.1 SKETCH (documented per §17.6.x doc inconsistency):
--      - manual JSON (`__pi_json_str`), NOT `string escape --style=json` (removed in 4.x).
--      - single-object response, NOT per-line NDJSON (shell.lua `_feed` decodes the whole
--        body as ONE object; NDJSON throws → parse_failure).
--      - SIMPLE `"([^"]*)"` regex, NOT the fancy `(?:[^"\\]|\\.)*` (fish compile-error).
--    KNOWN LIMITATION: a command line containing a literal `"` breaks `.line` extraction
--    → cmd resolves empty → `complete -C ""` returns all commands (graceful degrade, not
--    a crash; the gen-guard + empty-menu consumer handle it). A true JSON-string regex is
--    infeasible in fish without a JSON parser; v1 accepts this edge.
--
--  * NEVER-THROWS / FAST-CONTEXT-SAFE: every uv call is pcall'd; on_exit / timer /
--    stderr-read callbacks do NO `vim.api.*` (they run in libuv FAST context — E5560);
--    only luv calls + the single `on_ready` invocation. shell.lua's consumer already
--    vim.schedule's the eventual menu hop. No module-top `require("pi-bridge")` (the
--    handshake is async; fish.lua needs only `vim.uv`).
--
--  * HANDLE OWNERSHIP (the F3 leak): `uv.process_kill(proc,"sigkill")` does NOT close the
--    uv_process_t (`is_closing` stays false even after `on_exit`). Every PRE-on_ready
--    failure path in `start()` MUST `proc:close()` AFTER `process_kill` or the handle
--    LEAKS. shell.lua's `close_handles` owns the post-on_ready success-path close.
local M = {}
local uv = vim.uv

-- Module-local cache of the most-recently-handed-out stdin, so `M.cd(path)` (a DRIVER
-- method with no access to shell.lua's own state) can write a `__PICD__` frame to the
-- LIVE daemon. Safe because there is ONE daemon per session (shell.lua singleton state) —
-- `last_stdin` is always the live one. pcall + is_closing-guard every use (cd is advisory).
local last_stdin

-- ===========================================================================
-- The fish DAEMON SCRIPT (LIVE-VERIFIED against fish 4.8.1 — research §3/§4/§5/§6/§7/§8)
-- ===========================================================================
-- Sourced by: `fish -i --init-command="source <this file>"`.
-- Reads framed `__PIREQ__\t{json}\n` (and `__PICD__\t<path>\n`) lines from stdin; for a
-- request it runs `complete -C "<cmd>"`, builds ONE single-object JSON, and emits it
-- between `__PIRESP_START__\n` / `__PIRESP_END__\n` sentinels (the §17.5.1 wire frame).
-- Emits `__PIREADY__\n` to stderr once at startup (the cold-start signal the Lua start()
-- reads BEFORE handing stdout off to shell.lua).
--
-- NB: written as a Lua `[[ ... ]]` long-string so NONE of its `\n` / `\t` / `\\` escapes
-- are interpreted by Lua — they are LITERAL fish source. The fish script's OWN escapes
-- (e.g. `'\\\\'`) are fish string escapes.
local DAEMON_SCRIPT = [[
# === pi-bridge fish completion daemon (PRD §17.6.1 / §17.5.1) ===
# Sourced by: fish -i --init-command="source <this file>"
# Reads framed __PIREQ__ lines from stdin; emits ONE single-object JSON between
# __PIRESP_START__/__PIRESP_END__ sentinels. Emits __PIREADY__ to stderr once at startup.

# jq-free JSON string escape (fish 4.x has NO --style=json / printf %j — LIVE-VERIFIED).
# Escapes \, ", \n, \r, \t. Outputs the double-quoted JSON string.
function __pi_json_str
    set -l s "$argv"
    set -l s (string replace --all '\\' '\\\\' -- $s)   # backslash FIRST (before re-escaping)
    set -l s (string replace --all '"'  '\\"'  -- $s)
    set -l s (string replace --all \n '\\n' -- $s)
    set -l s (string replace --all \r '\\r' -- $s)
    set -l s (string replace --all \t '\\t' -- $s)
    printf '"%s"' "$s"
end

# Handle ONE __PIREQ__ line (argv[1]). Extracts .line via the SIMPLE regex (the fancy
# (?:...) PCRE variant FAILS in fish — LIVE-VERIFIED), runs `complete -C`, builds the
# items array, emits START / single-object-JSON / END.
function __pi_handle
    set -l line "$argv[1]"
    if test -z "$line"; or not string match -q '__PIREQ__*' -- $line; return; end

    # CD frame: __PICD__\t<path> → builtin cd, no response (best-effort, silent).
    if string match -q '__PICD__*' -- $line
        set -l p (string replace -r '^__PICD__\t' '' -- $line)
        builtin cd "$p" 2>/dev/null
        return
    end

    # Strip the __PIREQ__\t prefix, then extract .line with the SIMPLE regex.
    set -l payload (string replace -r '^__PIREQ__\t' '' -- $line)
    set -l cmd ""
    set -l m (string match -r '"line":"([^"]*)"' -- $payload)
    if test (count $m) -ge 2
        set cmd $m[2]
    end

    # Run fish's completion engine (the Tier-1 API). Build the items JSON array.
    set -l items_json ""
    set -l first 1
    complete -C "$cmd" | while read -l raw
        test -z "$raw"; and continue
        # Robust split on the FIRST tab (handles spaces in words/descriptions — fish's
        # `read word desc` IFS-split would mis-split a filename with a space).
        set -l word (string replace -r '\t.*$' '' -- $raw)
        set -l desc ""
        if string match -q '*\t*' -- $raw
            set desc (string replace -r '^[^\t]*\t' '' -- $raw)
        end
        set -l item "{\"value\":$(__pi_json_str $word)"
        if test -n "$desc"
            set item "$item,\"description\":$(__pi_json_str $desc)"
        end
        set item "$item}"
        if test $first -eq 1
            set items_json "$item"; set first 0
        else
            set items_json "$items_json,$item"
        end
    end

    # Emit the single-object JSON (NOT NDJSON — shell.lua _feed decodes the WHOLE body).
    echo __PIRESP_START__
    printf '{"items":[%s],"prefix":""}\n' "$items_json"
    echo __PIRESP_END__
end

# Silence the prompt (sentinel framing isolates any residual noise anyway).
function fish_prompt; end

# Announce readiness on STDERR (fd 2) — the Lua start() reads stderr for this marker
# (stdout is owned by shell.lua post-on_ready; two read_start's on one pipe is illegal).
printf '__PIREADY__\n' >&2

# Persistent request loop (the spike did one request; production loops for the session).
while read -l line
    __pi_handle $line
end
]]

-- ===========================================================================
-- M.parse(raw) — pure-Lua complete -C parser (PRD §17.6.1 / §17.15)
-- ===========================================================================

--- Parse raw fish `complete -C` output (newline-delimited `word⇥description` lines,
--- 0x09 = the first-tab delimiter) into the driver's raw-item wire shape
--- `{ value:string, description?:string }[]` — the exact input shell.lua `normalize_item`
--- consumes to build `AutocompleteItem {value, label=value, description?}` (PRD §17.6.1).
--- Pure Lua + never-throws + dependency-free (no `vim.*`/require) → fixture-testable
--- offline (PRD §17.15 "no live fish needed for the parser"). Mirrors the S1 daemon's
--- `__pi_handle` split semantics (first literal tab; description optional; empty-word
--- lines dropped). KNOWN LIMITATION: a candidate WORD containing a literal 0x09 cannot
--- round-trip (the format is unescaped tab-delimited; first tab = delimiter) — documented
--- in the spec; do not add an escape scheme. NOT called by shell.lua `_feed` (the daemon
--- pre-builds single-object JSON; `M.parse` is the testable reference of the same spec).
--- The completion prefix is derived CLIENT-SIDE in shell.lua (`shell_word_prefix` /
--- `complete_current`, which OVERRIDES the daemon's advisory `"prefix":""`) — `M.parse`
--- emits ONLY `{value, description?}`, never a prefix or label.
---@param raw string? Raw `complete -C` stdout (UTF-8; non-string → {}).
---@return table[] items `{ value:string, description?:string }[]` (may be empty).
function M.parse(raw)
	if type(raw) ~= "string" then
		return {}
	end
	local items = {}
	for line in raw:gmatch("[^\r\n]+") do -- split lines; empty lines skipped by gmatch
		local tab = line:find("\t", 1, true) -- FIRST literal tab, PLAIN find (4th arg = plain; no pattern)
		local value = tab and line:sub(1, tab - 1) or line
		if value ~= "" then -- drop empty-word lines (parity with normalize_item, which drops empty-value items)
			local item = { value = value }
			local desc = tab and line:sub(tab + 1) or nil
			if desc and desc ~= "" then
				item.description = desc
			end -- description OPTIONAL (omit if absent/empty)
			items[#items + 1] = item
		end
	end
	return items
end

-- ===========================================================================
-- M.start(opts, on_ready) — spawn the fish daemon + detect cold-start readiness
-- ===========================================================================

--- Spawn the fish completion daemon + resolve `on_ready` with live luv handles (the
--- binding driver seam, shell.lua:696-712). Writes `DAEMON_SCRIPT` to a temp file, creates
--- three `uv.new_pipe(false)` handles (stdin/stdout/stderr), spawns
--- `fish -i --init-command="source <tmp>"` with `cwd=opts.cwd` (when non-nil), arms a
--- `startup_timeout_ms` cold-start timer, reads STDERR for the `__PIREADY__\n` marker, and
--- on readiness calls `on_ready(nil, proc, stdin, stdout)` — handing stdout UNTOUCHED
--- (shell.lua wires its own `read_start` post-callback; two readers on one pipe is illegal).
---
--- FAILURE PATHS (each → `on_ready(err, nil, nil, nil)`, NEVER throws, NEVER leaks handles):
---   * script write failed (disk full / perms).
---   * spawn error (binary missing via a bogus `opts.shell` / luv refused the spawn).
---   * startup timeout (config.fish hung past `startup_timeout_ms`; the ready marker never
---     arrived — the timer fires).
---   * proc died pre-ready (stderr EOF before `__PIREADY__`; the daemon crashed during
---     config sourcing — `on_exit` fires + the readiness guard treats it as a startup fail).
---
--- Exactly ONE `on_ready` call (a local `resolved` flag shared by the timer / stderr-read /
--- on_exit closures). stdout is handed off pristine (NEVER `read_start`'d by the driver).
--- stderr is `read_stop`'d + closed on readiness (the driver OWNS stderr — shell.lua never
--- stores it). The proc handle is `process_kill`'d + `close`'d on EVERY pre-on_ready failure
--- (the F3 leak: `process_kill` alone does NOT close `uv_process_t`). The temp file is
--- `os.remove`'d on every terminal path. NO `vim.api.*` in any callback (libuv FAST context).
---
---@param opts table? { shell:string?, cwd:string?, startup_timeout_ms:integer? }.
---@param on_ready fun(err:string|nil, proc:userdata?, stdin:userdata?, stdout:userdata?) The ready cb.
function M.start(opts, on_ready)
	-- never-throws on a bad arg (mirrors shell.lua's discipline; a non-function cb is a noop).
	if type(on_ready) ~= "function" then
		return
	end
	opts = opts or {}
	local shell_bin = (type(opts.shell) == "string" and opts.shell ~= "") and opts.shell or "fish"
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

	-- (2) create the three piped streams (false = not a TTY; matches the spike L57-59).
	stdin = uv.new_pipe(false)
	stdout = uv.new_pipe(false)
	stderr_pipe = uv.new_pipe(false)
	if not (stdin and stdout and stderr_pipe) then
		return fail("pipe alloc failed")
	end

	-- (3) spawn `fish -i --init-command="source <tmp>"` with cwd when non-nil. pcall (a bad
	--     shell path / luv refusal → fail path). on_exit fires if the proc dies — if that
	--     happens BEFORE readiness, treat it as a startup failure (the read loop never starts).
	local spawn_ok, spawn_err = pcall(function()
		local spawn_opts = {
			args = { "-i", "--init-command=source " .. tmp_path },
			stdio = { stdin, stdout, stderr_pipe },
		}
		if cwd then
			spawn_opts.cwd = cwd
		end
		proc = uv.spawn(shell_bin, spawn_opts, function(exit_code, signal)
			-- proc died. If we already resolved (success), do nothing — shell.lua's stdout EOF
			-- → _reset handles the mid-session crash. If NOT yet ready, it's a startup failure.
			if not resolved then
				fail("fish exited pre-ready (code=" .. tostring(exit_code) .. " sig=" .. tostring(signal) .. ")")
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
	--     EOF on stderr before the marker → proc died during config sourcing → fail.
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
				-- stderr EOF before the ready marker → the daemon died during config sourcing.
				fail("stderr EOF pre-ready (fish crashed during startup)")
			end
		end)
	end)
	if not rok then
		return fail("stderr read_start threw")
	end
end

-- ===========================================================================
-- M.cd(path) — best-effort re-cd over the framed channel
-- ===========================================================================

--- Re-`cd` the daemon to `path` by writing a `__PICD__\t<path>\n` frame to its stdin.
--- The daemon script recognizes `__PICD__` + `builtin cd`s (no response — cd is advisory).
---
--- WIRED (Issue 4 / §17.5.2): `shell.complete_current` calls this whenever pi's session
--- cwd (`M.session_cwd()`) changed since spawn — the daemon honors `__PICD__` with a
--- real `builtin cd`, so fish path/relative completions track the new cwd on the very
--- next keystroke (submitted synchronously BEFORE the `__PIREQ__` frame so libuv FIFO
--- write order guarantees the daemon `cd`s before it completes).
---
--- Best-effort + silent: a dead/closing pipe is a noop (NOT an error — cd is advisory; the
--- next request's completions simply use the prior cwd). pcall'd + is_closing-guarded so a
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
