--- shell.lua — the §17 completion-daemon manager (parent P2.M1.T2).
--
-- Owns the persistent completion-daemon for `!` / `!!` Bash Mode (PRD §17): a single
-- long-lived child shell process nvim spawns once per session, talks to over a framed
-- stdin/stdout protocol, and uses for tab-completion of shell words. This is the
-- fzf-tab / zsh-capture-completion / bash `bind -x` pattern — per-keystroke spawn is a
-- non-starter because rc + completion-library load costs 100 ms–1 s+.
--
-- S2 SCOPE (this task): the RESOLUTION + STATE layer ONLY. It declares the gen-guard
-- supersession scaffolding (mirrors completion.lua) + the three PURE, never-throws
-- resolution helpers the spawn (S3) + request (S4) layers call:
--   M.resolve_shell(prefer)  → (shell_path, source)   PRD §17.4 fallback chain
--   M.pick_driver(resolved)  → driver module | nil     PRD §17.4.2 basename → module
--   M.session_cwd()          → cwd string | nil        fresh server_info.cwd → descriptor.cwd
--   M.reset()                → restore state to init   (the S6 teardown seam)
--
-- [Mode A] header — read before editing:
--  * ROLE: the §17.5 persistent completion-daemon manager's RESOLUTION + STATE layer.
--    It does NOT spawn in S2 (ensure() is S3); it does NOT render the menu (menu.lua,
--    S31); it does NOT accept completions (shell/accept.lua, S32). It is the pure half
--    that S3/S4 build on.
--
--  * DAEMON LIFECYCLE: a persistent child of nvim for the session lifetime. rc +
--    completion-library load (100 ms–1 s+) makes per-keystroke spawn untenable, so S3's
--    ensure() spawns ONE daemon (on first `!` activation), keeps it, and reuses it for
--    every completion request. The daemon is torn down by S6's teardown() (process_kill
--    + pipe:close) on VimLeave / buffer close.
--
--  * FRAMED PROTOCOL: the daemon speaks a sentinel-framed line protocol over its
--    stdin/stdout to isolate completion payloads from the shell's prompt noise:
--        request:  __PIREQ__\t{json}\n
--        response: __PIRESP_START__\n{json}\n__PIRESP_END__\n
--    The daemon MUST always emit __PIRESP_END__ — even on error or empty results — so
--    S5's rx_buf slicing (which pairs START/END) can never wedge waiting for a close
--    sentinel that never arrives.
--
--  * GEN-GUARD SUPERSESSION (mirrors completion.lua's two-layer design, §17.5.2): a
--    monotonic `state.gen` is captured in the response cb closure; a newer request()
--    bumps gen → a late stale response hits the guard (`gen ~= state.gen`) and is
--    dropped. Only ONE request is in-flight at a time (state.inflight); a new request
--    supersedes the previous. S2 only declares the state (gen/inflight/pending_cb); S4
--    bumps + guards it.
--
--  * FRESH READS: config + descriptor + bridge are read INSIDE each function
--    (`require("pi-bridge")` lazy), NEVER cached at module load. The handshake is ASYNC
--    (pi.bridge is nil at first-require) and tests swap in fakes after require — caching
--    breaks both. Mirrors completion.lua's header note + bridge.lua L333/L559.
--
--  * SCOPE FENCE (S2): state + resolve_shell + pick_driver + session_cwd + reset ONLY.
--    Forward-contract seams (NOT implemented here):
--      M.ensure(on_ready)             → S3: spawn via vim.uv.spawn; calls resolve_shell +
--                                       pick_driver + session_cwd; sets state.shell/driver/cwd/proc.
--      M.request(line,cursor,after,cb)→ S4: framed protocol; bumps state.gen + sets
--                                       state.pending_cb (the gen-guarded response cb).
--      M._feed(chunk)                 → S5: rx_buf sentinel slicing + JSON decode +
--                                       AutocompleteItem normalize.
--      M.teardown()                   → S6: uv.process_kill("sigkill") + pipe:close ×3
--                                       THEN calls reset().
--      state.failed                   → S3 sets it on permanent spawn failure (§17.12)
--                                       so ensure() won't retry endlessly; health (§17.15) reports it.
--      state.pending_cb               → S4 sets it (the gen-guarded response cb).
--    S2 has ZERO `vim.uv.spawn` + ZERO `vim.notify` (ensure is S3; the §17.4.3/§17.9
--    notices are P2.M2.T3.S4). It references notify.lua + the daemon lifecycle in this
--    HEADER only (documentation).
--
local M = {}
local uv = vim.uv -- forward-contract: S3's ensure() spawns via uv (unused in S2).

-- [TEMP DEBUG] trace shell-daemon flow to /tmp/pi-bridge-shell-debug.log
-- (forward-contract stub for S3/S4 tracing; no-op today — S2 calls neither uv nor notify).
local function dbg(msg)
	pcall(function()
		local f = io.open("/tmp/pi-bridge-shell-debug.log", "a")
		if f then f:write(tostring(msg) .. "\n"); f:close() end
	end)
end

--- Singleton shell-daemon state. One daemon per session (PRD §17.5). Cleared by
--- `M.reset()`. Mirrors `completion.lua`'s two-layer `state` + `reset()` ownership shape
--- (PRD §17.5.2 says shell.lua "MIRRORS completion.lua's two-layer design").
---@class pi-bridge.ShellState
---@field proc        userdata?  luv process handle (S3 ensure). nil until spawn succeeds.
---@field stdin        userdata?  luv pipe → daemon stdin (S3). nil until spawn.
---@field stdout       userdata?  luv pipe ← daemon stdout (S3). nil until spawn.
---@field rx_buf       string     accumulating stdout buffer (S5 _feed slices sentinel pairs). "" when idle.
---@field gen          integer    Monotonic supersession guard (mirrors completion.lua; bumped in S4 request()).
---@field inflight     boolean    True iff a framed request is awaiting __PIRESP_END__ (S4).
---@field shell        string?    The resolved shell path (set by S3 ensure via resolve_shell).
---@field driver       table?     The resolved driver module (set by S3 ensure via pick_driver; has .start).
---@field cwd          string?    The session cwd at spawn (set by S3 ensure via session_cwd).
---@field pending_cb   fun(items:table?, prefix:string?)? The gen-guarded response cb (set by S4 request()).
---@field failed       boolean    True after a permanent spawn failure (S3/§17.12) — ensure() won't retry; health (§17.15) reports it.
---@type pi-bridge.ShellState
local state = {
	proc = nil,
	stdin = nil,
	stdout = nil,
	rx_buf = "",
	gen = 0,
	inflight = false,
	shell = nil,
	driver = nil,
	cwd = nil,
	pending_cb = nil,
	failed = false,
}

-- ===========================================================================
-- §17.4 shell resolution
-- ===========================================================================

--- §17.4 "pi" first hop (FRESH read): the resolved execution-shell pi advertises.
--- Returns the shell path or `nil` when unresolved (older bridge / pre-handshake).
--- Prefers `bridge.get_shell_info()` (which merges server_info→descriptor, P2.M1.T1.S4)
--- then falls back to `pi.descriptor.shell` directly (covers the bridge==nil
--- pre-handshake window). LAZY require (async handshake + test mocks; mirrors
--- completion.lua). NEVER throws (defensive type-checks). Treats `""` as unresolved.
---@return string|nil
local function descriptor_shell()
	local pi = require("pi-bridge")
	local br = pi.bridge
	if br and type(br.get_shell_info) == "function" then
		local si = br.get_shell_info()
		if type(si) == "table" and type(si.shell) == "string" and si.shell ~= "" then
			return si.shell
		end
	end
	local desc = pi.descriptor
	if type(desc) == "table" and type(desc.shell) == "string" and desc.shell ~= "" then
		return desc.shell
	end
	return nil
end

--- Resolve ONE shell for the session per PRD §17.4. Takes `prefer` as a PARAMETER
--- (the caller `ensure()` in S3 reads `config.shell.prefer` and passes it — keeping
--- this PURE + directly unit-testable). Returns `(shell_path, source)`:
---   prefer=="pi"    → descriptor.shell ("pi") else fall through → $SHELL ("$SHELL") → /bin/bash ("default")
---   prefer=="shell" → $SHELL ("$SHELL") else /bin/bash ("default")
---   prefer=="bash"  → /bin/bash ("default")
---   prefer=<path>   → that path ("config")           (§17.4 "/abs/path" row)
--- `source` aligns with descriptor.shellSource's union ("pi"|"$SHELL"|"default") + a
--- local "config" label for explicit-path prefer (used by the §17.4.3 notice / health
--- check / dbg). NEVER throws (defensive type-checks; nil/""/non-string prefer → the
--- safe "/bin/bash","default" default). Does NOT mutate state.
---@param prefer string? "pi" (default) | "shell" | "bash" | "/abs/path"
---@return string shell_path
---@return string source
function M.resolve_shell(prefer)
	prefer = prefer or "pi"
	-- explicit path (NOT one of the three keywords) → verbatim (§17.4 "/abs/path" row)
	if type(prefer) == "string" and prefer ~= ""
		and prefer ~= "pi" and prefer ~= "shell" and prefer ~= "bash" then
		return prefer, "config"
	end
	if prefer == "pi" then
		local ds = descriptor_shell()
		if ds then return ds, "pi" end             -- descriptor.shell (always consistent w/ execution)
		-- descriptor omitted shell → fall through to $SHELL → /bin/bash
	end
	if prefer == "pi" or prefer == "shell" then
		local env = vim.env.SHELL
		if type(env) == "string" and env ~= "" then return env, "$SHELL" end
		return "/bin/bash", "default"
	end
	if prefer == "bash" then
		return "/bin/bash", "default"
	end
	return "/bin/bash", "default"                  -- unknown/non-string prefer → safe default
end

-- ===========================================================================
-- §17.4.2 driver selection
-- ===========================================================================

--- Select the per-shell driver module (PRD §17.4.2) by the resolved shell's BASENAME:
--- `"/bin/zsh"`→`pi-bridge.shell.zsh`, `"/usr/bin/fish"`→`pi-bridge.shell.fish`. Returns
--- the module iff it is loadable AND exposes a `.start` function (the
--- `start(opts, on_ready)` seam, §17.6); else `nil` (unknown shell → silent no-op
--- degrade, §17.6.4). A user-disabled driver (`config.shell.drivers.<basename> == false`)
--- ALSO returns nil — disabling a driver means NO completion (degrade to a plain
--- buffer), NOT a different shell (the shell is what pi EXECUTES; you cannot change it
--- by disabling a completion driver). NEVER throws.
---@param resolved_shell string? The resolved shell path (from M.resolve_shell).
---@return table|nil drv The driver module (has `.start`), or nil to degrade.
function M.pick_driver(resolved_shell)
	if type(resolved_shell) ~= "string" or resolved_shell == "" then return nil end
	local base = resolved_shell:gsub(".*/", "")    -- basename ("/bin/zsh"→"zsh"); gsub returns 2, assignment→1
	if base == "" then return nil end
	-- user-disabled driver? (§17.4.2: setup({ shell = { drivers = { bash = false } } }))
	local pi = require("pi-bridge")
	local drv_cfg = (pi.config and pi.config.shell and pi.config.shell.drivers) or nil
	if type(drv_cfg) == "table" and drv_cfg[base] == false then return nil end
	local ok, drv = pcall(require, "pi-bridge.shell." .. base)
	if ok and type(drv) == "table" and type(drv.start) == "function" then return drv end
	return nil                                    -- unknown shell / no .start → degrade (§17.6.4)
end

-- ===========================================================================
-- §17.5.2 cwd tracking
-- ===========================================================================

--- The session cwd for the daemon (PRD §17.5.2 "cwd tracking"). FRESH read:
--- `bridge.server_info.cwd` (live, post-handshake) → `pi.descriptor.cwd` (the
--- PI_NVIM_BRIDGE env-var blob, available from activate()) → nil. Drivers use this as
--- the spawn cwd (S3 ensure passes it to driver.start); a driver may re-`cd` over the
--- framed channel if it changed since spawn. `nil` is acceptable (a driver may default
--- to the daemon's own cwd). NEVER throws (defensive reads). LAZY require (async
--- handshake + test mocks).
---@return string|nil
function M.session_cwd()
	local pi = require("pi-bridge")
	local br = pi.bridge
	if br and type(br.server_info) == "table"
		and type(br.server_info.cwd) == "string" and br.server_info.cwd ~= "" then
		return br.server_info.cwd
	end
	local desc = pi.descriptor
	if type(desc) == "table" and type(desc.cwd) == "string" and desc.cwd ~= "" then
		return desc.cwd
	end
	return nil
end

-- ===========================================================================
-- State seam (forward-contract teardown)
-- ===========================================================================

--- Restore `state` to its initial literal (mirrors completion.lua's M.reset). The
--- forward-contract TEARDOWN seam: S6's `teardown()` prepends
--- `uv.process_kill(proc, "sigkill")` + `:close()` on each pipe, THEN calls reset().
--- Also used by tests for state isolation. shell.lua has NO bridge.cancel (the daemon
--- is a local subprocess — there is no cancel wire method). NEVER throws (plain table
--- assignments).
function M.reset()
	state.proc       = nil
	state.stdin      = nil
	state.stdout     = nil
	state.rx_buf     = ""
	state.gen        = 0
	state.inflight   = false
	state.shell      = nil
	state.driver     = nil
	state.cwd        = nil
	state.pending_cb = nil
	state.failed     = false
end

-- ===========================================================================
-- §17.5.2 spawn layer (ensure + the read_start route stubs)
-- ===========================================================================

--- The §17.5.2 spawn layer of the completion daemon. Idempotent lifecycle entry point:
--- spawn-if-needed (via `state.driver.start`) then cache the proc/pipes for the session.
--- Called by S4's `request()` before every framed request (and by completion routing
--- P2.M2.T3 at first `!` activation).
---
--- Short-circuits on `state.failed` (daemon previously crashed / permanently disabled —
--- §17.12 "no auto-respawn in v1") and on `state.proc` (already running — the
--- "subsequent calls are instant" cache). On the spawn path: reads config FRESH (lazy
--- require — async handshake + test mocks), resolves the shell (§17.4 via M.resolve_shell),
--- picks the driver (§17.4.2 via M.pick_driver), and delegates the actual `vim.uv.spawn`
--- to `state.driver.start({ shell, cwd, startup_timeout_ms }, cb)`. The
--- `startup_timeout_ms` cold-start timer lives INSIDE the driver (S3 passes it THROUGH;
--- it does NOT build a uv timer).
---
--- Sets `state.failed = true` on BOTH terminal paths (no-driver AND spawn error) so a
--- broken daemon does not re-attempt resolve→pick→spawn on every keystroke (§17.12
--- "menu never opens for ! lines"). The §17.12 one-time degrade NOTIFY is P2.M2.T3.S4's
--- job — ensure sets only the FACT (`failed`).
---
--- NEVER throws: `pcall`s `state.driver.start` AND `stdout:read_start` (a buggy/
--- malformed driver or handle degrades to a spawn error); guards `on_ready`'s type; the
--- resolution helpers are already never-throws (S2). The driver's cb may fire from luv
--- fast context — ensure's cb touches NO `vim.api.*` (only state writes +
--- `stdout:read_start` + `on_ready`), so NO `vim.schedule` is needed here (the eventual
--- menu hop is S5's job — `:help E5560`). Returns NOTHING; communicates via
--- `on_ready(err|nil)` (node-style; S4 passes its own cb).
---@param on_ready fun(err:string|nil) Called with nil on success/cached-ready; an err string on every failure.
function M.ensure(on_ready)
	if type(on_ready) ~= "function" then on_ready = function() end end -- never-throws on a bad arg
	-- (1) Short-circuit: daemon previously crashed / permanently disabled (§17.12 no-respawn-in-v1).
	if state.failed then return on_ready("daemon disabled") end
	-- (2) Cache: already running (proc is set ONLY on a successful spawn — NOT state.driver,
	--     which is set before spawn). Contract point 4 ("subsequent calls are instant").
	if state.proc then return on_ready(nil) end
	-- (3) Read config FRESH (lazy require — async handshake + test mocks; defensive:
	--     config.shell may be nil until P2.M3.T6.S1). ⚠ NOT `pi.config.shell or {}`
	--     (throws if config nil) — use the AND-chain.
	local pi = require("pi-bridge")
	local cfg = (pi.config and pi.config.shell) or {}
	-- (4) Resolve ONE shell (§17.4; consistent with what pi EXECUTES). source is unused by
	--     ensure (health §17.15 reports it).
	local resolved = M.resolve_shell(cfg.prefer or "pi")
	state.shell = resolved
	-- (5) Pick the driver (§17.4.2). No driver → permanent degrade (§17.6.4): set failed so
	--     the next ensure short-circuits (do NOT retry resolve→pick per keystroke).
	state.driver = M.pick_driver(resolved)
	if not state.driver then
		state.failed = true
		return on_ready("no driver for " .. tostring(resolved))
	end
	-- (6) Build the driver opts (the spawn delegation contract; startup_timeout_ms passed
	--     THROUGH — the driver owns the cold-start timer). cwd nil is acceptable (a driver
	--     may default its own cwd).
	local opts = {
		shell              = resolved,
		cwd                = M.session_cwd(),
		startup_timeout_ms = cfg.startup_timeout_ms or 5000,
	}
	-- (7) Delegate spawn to the driver. pcall so a buggy driver.start (throws vs calls cb
	--     with err) degrades to a spawn error. The driver calls cb from its own (possibly
	--     luv) context — our cb is fast-context-safe.
	local ok, spawn_err = pcall(state.driver.start, opts, function(err, proc, stdin, stdout)
		-- (8a) FAILURE: driver reported err (binary missing / rc error / startup timeout).
		--     Mark permanently failed (§17.12) so the next ensure short-circuits.
		if err then
			state.driver = nil
			state.failed = true
			return on_ready(err)
		end
		-- (8b) SUCCESS: cache the handles + cwd; wire stdout:read_start to the _feed/_reset
		--     route (the §17.5.2 skeleton callback EXACTLY). pcall read_start (the handle
		--     the driver returned could be malformed).
		state.proc, state.stdin, state.stdout = proc, stdin, stdout
		state.cwd = opts.cwd
		pcall(function()
			stdout:read_start(function(_, chunk)
				if chunk then M._feed(chunk) else M._reset() end -- data → S5 stub; EOF → S6 stub
			end)
		end)
		on_ready(nil)
	end)
	-- (8c) driver.start ITSELF threw (not just called cb with err): treat as spawn error (D4).
	if not ok then
		state.driver = nil
		state.failed = true
		on_ready(tostring(spawn_err))
	end
end

--- Forward-contract stub for S5: append a stdout chunk to the rx buffer. S5 will REPLACE
--- this body with the full `__PIRESP_START__`/`__PIRESP_END__` sentinel slicing +
--- `vim.json.decode` + AutocompleteItem normalization → the gen-guarded
--- `state.pending_cb`. S3 ships append-only so the read_start wiring ensure installs is
--- complete + a stray chunk during S3's window (before S5 lands) degrades to a no-op,
--- never errors. Runs on the libuv loop (fast context) — S5 must `vim.schedule` the
--- final menu hop (`:help E5560`). NEVER throws (string concat + a table write). Exported
--- so S5 replaces via `M._feed = ...` + tests assert the read_start route.
---@param chunk string? A stdout chunk (nil/"" tolerated).
function M._feed(chunk)
	state.rx_buf = state.rx_buf .. (chunk or "")
end

--- Forward-contract stub for S6: the §17.12 EOF-on-daemon-pipe path (shell crashed
--- mid-session). Marks the daemon unhealthy (`state.failed = true`) + nils proc/pipes so
--- the next `ensure` short-circuits via the `failed` guard (no auto-respawn in v1). S6's
--- `teardown()` will REPLACE/EXTEND this: prepend `uv.process_kill(proc, "sigkill")` +
--- `pipe:read_stop()` + `pipe:close()`×3 THEN clear state (on EOF the proc is already
--- dead, so kill is moot; pipe-close matters for real handles — S6 owns it). Does NOT
--- call `M.reset()` (that clears `failed = false`; `_reset` must LEAVE `failed = true` —
--- a CRASH is not a clean exit). Runs on the libuv loop (fast context). NEVER throws
--- (plain table assignments). Exported so S6 replaces it.
function M._reset()
	state.failed = true
	state.proc   = nil
	state.stdin  = nil
	state.stdout = nil
	state.driver = nil
	state.rx_buf = ""
end

-- ===========================================================================
-- §17.5.1 framing protocol + §17.5.2 supersession layer (request)
-- ===========================================================================

-- The single per-request timeout timer slot (module-local). `nil` when disarmed. At
-- most ONE alive at a time: request() cancels the prior at its start; every terminal path
-- (pending_cb / write-fail / S6 teardown) closes it. Deliberately NOT a `state` field:
-- S2's PRP declared the state literal without it, and editing it would conflict with S3
-- (editing this file in parallel) + S2's reset() wouldn't clear it. S6's teardown() (same
-- file) calls cancel_req_timer() before uv.process_kill + pipe:close.
local req_timer

--- Stop + close the per-request timer (the leak-safe finalize; mirrors completion.lua
--- `cancel_timer` L350-360 + bridge.lua `resolve_request` timer cleanup L399-403). A
--- one-shot `uv_timer_t` (start(ms, 0, cb)) only auto-STOPs after firing — `:close()` is
--- REQUIRED to free the handle, or it leaks across editor open/close cycles (libuv owns
--- the C struct; not GC'd until closed). NEVER stop-only. `pcall`'d + `is_closing()`-guarded
--- so it is safe to call from INSIDE the timer's own callback + idempotent on an
--- already-closed handle. Runs in libuv fast context (plain luv calls — no vim.api).
--- Called at request START (supersede the prior timer), inside pending_cb (response/
--- timeout arrived), in the write-fail paths, and (future) by S6's teardown().
local function cancel_req_timer()
	pcall(function()
		if req_timer and not req_timer:is_closing() then
			req_timer:stop()
			req_timer:close()
		end
	end)
	req_timer = nil
end

--- The §17.5.1 framing-protocol + §17.5.2 supersession layer of the completion daemon.
--- Sends a framed `__PIREQ__\t{json}\n` request to the daemon's stdin and resolves
--- `cb(err, items, prefix)` on the response (via S5's `_feed` → `state.pending_cb`) OR
--- the per-request timeout.
---
--- Flow:
---   1. call `M.ensure` FIRST (spawn-if-needed, S3). If the daemon is down
---      (`state.failed`) ensure reports `err` → short-circuit with `cb(err)` BEFORE any
---      state mutation (no gen bump / timer / write).
---   2. on ready: SUPERSEDE — `cancel_req_timer()` (drop the prior request's timer; the
---      gen-guard drops its stale fire, but the un-closed HANDLE leaks). Bump `state.gen`
---      + capture `local gen`; set `inflight=true`.
---   3. install the ONE-SHOT gen-guarded `state.pending_cb`: `if gen ~= state.gen then
---      return end` (supersession, mirrors completion.lua do_refresh) → `cancel_req_timer()`
---      + `state.pending_cb = nil` (null-slot-FIRST exactly-once, mirrors bridge.lua
---      resolve_request) + `inflight=false` + `cb(nil, items, prefix)`.
---   4. `pcall(vim.json.encode, {line, cursor, after})` — on failure `cb("encode failed")`.
---   5. arm a one-shot `uv.new_timer()` for `config.shell.timeout_ms` (default 1500); on
---      fire call `state.pending_cb({}, "")` (soft-degrade empty result → `cb(nil, {}, "")`;
---      §17.12 "or close").
---   6. `state.stdin:write("__PIREQ__\t{json}\n", cb)` — the write cb routes EPIPE →
---      `cb("write failed")` (bridge.lua M.send GOTCHA 3: a callback-less write SILENTLY
---      swallows broken-pipe errors). pcall the write (a sync throw, e.g. nil stdin →
---      `cb("write failed")`).
---
--- NEVER throws (guard cb type; pcall encode/new_timer/write; M.ensure is never-throws
--- per S3). Returns NOTHING (cb-only). The `cb` is invoked from libuv FAST context
--- (pending_cb runs in the read_start cb via S5 `_feed`, OR in the timer cb) → the
--- consumer (P2.M2.T3.complete_current) must `vim.schedule` any editor-touching work
--- (`:help E5560`); S4's own chain does NO `vim.api.*` (only state writes + luv calls +
--- `vim.json.encode`).
---
--- FORWARD CONTRACTS (do NOT implement here):
---   * S5's `_feed(chunk)` MUST invoke `if state.pending_cb then state.pending_cb(items,
---     prefix) end` (the `if` guard is what makes pending_cb ONE-SHOT — a late duplicate
---     response after the slot was nil'd is a no-op).
---   * The user `cb` runs in libuv FAST context → the consumer (P2.M2.T3.complete_current)
---     must `vim.schedule` its editor work (`M.on_results` → the menu hop is NOT fast-safe;
---     `state.last_result = {}` is). FLAG FOR P2.M2.T3.S2.
---   * S6's `teardown()` calls `cancel_req_timer()` BEFORE `uv.process_kill` + `pipe:close`×3
---     THEN `reset()`.
---
---@param line   string  The command text up to the cursor (UTF-8; §17.5.1 — no UTF-16 conversion).
---@param cursor integer The 0-based BYTE offset into `line`.
---@param after  string? The text after the cursor (drivers that need the full line reconstruct it; default "").
---@param cb     pi-bridge.shell.RequestCb Resolved EXACTLY ONCE: cb(nil, items, prefix) on
---              success/timeout(empty); cb(err) on ensure-fail / write-fail / encode-fail.
function M.request(line, cursor, after, cb)
	if type(cb) ~= "function" then cb = function() end end -- never-throws on a bad arg
	-- (1) spawn-if-needed (S3). The ensure-failed path short-circuits BEFORE any state mutation
	--     (no gen bump / timer / write) so a never-sent request cannot corrupt supersession.
	M.ensure(function(err)
		if err then return cb(err) end -- daemon down (state.failed) → cb(err)
		-- (2) read config FRESH (lazy require — async handshake + test mocks; defensive:
		--     config.shell may be nil until P2.M3.T6.S1). ⚠ NOT `pi.config.shell or {}`
		--     (throws if config nil) — use the AND-chain.
		local pi = require("pi-bridge")
		local cfg = (pi.config and pi.config.shell) or {}
		local timeout_ms = cfg.timeout_ms or 1500 -- §17.11 per-request budget (NOT startup_timeout_ms=5000)
		-- (3) SUPERSEDE: cancel the prior request's timer at START, BEFORE bumping gen. The
		--     gen-guard drops the prior timer's stale FIRE, but the un-closed uv_timer_t HANDLE
		--     leaks (one-shot only auto-STOPs; :close() required — bridge.lua GOTCHA 5).
		cancel_req_timer()
		-- (4) bump + capture the gen-guard (mirrors completion.lua do_refresh). One request
		--     in-flight at a time (§17.5.2: "shell completion is fast + the sentinel protocol
		--     is sequential").
		state.gen = state.gen + 1
		local gen = state.gen
		state.inflight = true
		-- (5) the ONE-SHOT gen-guarded response cb. Invoked by S5's _feed (response) AND the
		--     timer cb (timeout). S5 MUST guard `if state.pending_cb then state.pending_cb(...)
		--     end` (the `if` is what makes this ONE-SHOT — a late duplicate after the slot was
		--     nil'd is a no-op).
		state.pending_cb = function(items, prefix)
			if gen ~= state.gen then return end -- STALE (superseded by a newer request) → drop
			cancel_req_timer()                  -- response (or timeout) arrived → stop+close the timer
			state.pending_cb = nil              -- NULL THE SLOT FIRST (exactly-once; mirrors resolve_request)
			state.inflight = false
			cb(nil, items, prefix)              -- success-shape (err path is ensure/write/encode-fail)
		end
		-- (6) encode the payload (pcall — vim.json.encode throws on a non-encodable value,
		--     e.g. a function/userdata). On failure tear down + cb("encode failed")
		--     (mirrors the write-fail discipline). The payload is {line,cursor,after} in
		--     that EXACT key order (§17.5.1 framing) — vim.json.encode sorts keys
		--     alphabetically, so build the ordered JSON string field-by-field, encoding each
		--     VALUE (handles quote/backslash/control escaping) + the integer cursor directly.
		local l_ok, l_str = pcall(vim.json.encode, line)
		local a_ok, a_str = pcall(vim.json.encode, after or "")
		local c_ok = type(cursor) == "number" and cursor == math.floor(cursor)
		local payload
		if l_ok and a_ok and c_ok then
			payload = string.format("{\"line\":%s,\"cursor\":%d,\"after\":%s}", l_str, cursor, a_str)
		end
		if not payload then
			cancel_req_timer(); state.pending_cb = nil; state.inflight = false
			return cb("encode failed")
		end
		-- (7) arm the one-shot per-request timeout (luv timer, NEVER vim.defer_fn — bridge.lua
		--     GOTCHA 5 + the fish spike both use uv.new_timer). The cb calls pending_cb({},"")
		--     → cb(nil, {}, "") (soft-degrade empty; §17.12 "or close"). The gen-guard +
		--     null-slot make a superseded / double fire a no-op. Runs in fast context (a table
		--     read + a call). pcall'd (uv.new_timer is a genuine luv call).
		local tok = pcall(function()
			req_timer = uv.new_timer()
			req_timer:start(timeout_ms, 0, function()
				dbg("[shell.request] timeout (gen=" .. tostring(gen) .. ")") -- trace marker only (GOTCHA #5)
				if state.pending_cb then state.pending_cb({}, "") end
			end)
		end)
		if not tok then -- uv.new_timer / :start THREW (defensive — a malformed luv)
			cancel_req_timer(); state.pending_cb = nil; state.inflight = false
			return cb("timer failed")
		end
		-- (8) write the frame WITH a cb (bridge.lua M.send GOTCHA 3: a callback-less write
		--     SILENTLY swallows EPIPE → completion hangs until the timeout). pcall the write
		--     (a sync throw, e.g. nil stdin → cb("write failed")). The write cb: werr nil →
		--     await response; werr truthy → cb("write failed").
		local frame = string.format("__PIREQ__\t%s\n", payload)
		local wok = pcall(function()
			state.stdin:write(frame, function(write_err)
				if not write_err then return end -- write OK → await the response (S5 _feed → pending_cb)
				if gen ~= state.gen then return end -- superseded → drop
				cancel_req_timer(); state.pending_cb = nil; state.inflight = false
				cb("write failed") -- async write failure (EPIPE / broken pipe)
			end)
		end)
		if not wok then -- stdin:write THREW (e.g. stdin nil/closed — defensive)
			cancel_req_timer(); state.pending_cb = nil; state.inflight = false
			cb("write failed")
		end
	end)
end

-- ===========================================================================
-- TEST SEAMS (NOT public API — internal, _test_ prefixed; used by tests/shell_request_*)
-- ===========================================================================
-- `state.pending_cb` is module-local, so tests cannot reach it directly. The S4 test
-- matrix (research §5c) MUST invoke `state.pending_cb(items, prefix)` to deliver the
-- response (S5's `_feed` will be the prod invocation point once landed; until then these
-- seams let S4's request layer be exercised end-to-end). Mirrors the pattern other test
-- suites use to observe module-local state. These do NOT touch state beyond what
-- request()/reset() already do + are no-ops when pending_cb is nil (one-shot safe).

--- Deliver a response as if S5's `_feed` had parsed it: invokes `state.pending_cb(items,
--- prefix)` if set (the `if` guard mirrors S5's forward contract — a nil slot is a no-op,
--- so this is safe to call before request sets it or after a response resolved it).
---@param items  table?  The AutocompleteItem[] (or {} for timeout soft-degrade).
---@param prefix string? The completion prefix.
function M._test_invoke_pending(items, prefix)
	if state.pending_cb then state.pending_cb(items or {}, prefix or "") end
end

--- TEST seam: read `state.inflight` (assert it flips true at request start, false at finalize).
---@return boolean
function M._test_inflight()
	return state.inflight
end

--- TEST seam: is `state.pending_cb` nil? (assert the one-shot slot was nulled post-finalize).
---@return boolean
function M._test_pending_is_nil()
	return state.pending_cb == nil
end

--- TEST seam: read `state.gen` (assert supersession bumps it + ensure-fail does NOT).
---@return integer
function M._test_gen()
	return state.gen
end

--- TEST seam: return the current `state.pending_cb` closure (read-only). Used by the
--- late-response-drop test to SAVE req1's closure into a local, then supersede with
--- req2, then invoke the STALE closure to prove the gen-guard drops it (mirrors how the
--- PRP's research §5c LATE-RESPONSE-DROPPED case captures req1's pending_cb).
---@return function?
function M._test_get_pending()
	return state.pending_cb
end

return M