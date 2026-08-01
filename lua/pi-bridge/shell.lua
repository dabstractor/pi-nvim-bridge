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

-- Forward declaration of `close_handles` (the S6 shared kill+close routine). It is
-- DEFINED later (near `cancel_req_timer`) but CALLED earlier — by `M._reset()` (the EOF
-- path). Without this forward `local`, `_reset` would resolve `close_handles` to the
-- GLOBAL (nil) at parse time. The body is assigned later as `close_handles = function()`
-- (NOT `local function`, which would create a fresh shadowing local) so both `_reset` and
-- `teardown` close over the SAME upvalue and see the real function at call time.
local close_handles

-- [TEMP DEBUG] trace shell-daemon flow to /tmp/pi-bridge-shell-debug.log
-- (forward-contract stub for S3/S4 tracing; no-op today — S2 calls neither uv nor notify).
local function dbg(msg)
	pcall(function()
		local f = io.open("/tmp/pi-bridge-shell-debug.log", "a")
		if f then f:write(tostring(msg) .. "\n"); f:close() end
	end)
end

--- The basename of a shell path ("/bin/zsh" → "zsh"). Module-local so the §17 notice messages +
--- the existing pick_driver inline idiom share ONE definition. nil/non-string → "?"
--- (a defensive sentinel so a toast never reads "active (`nil`)"). NEVER throws.
local function basename(p)
	if type(p) ~= "string" or p == "" then return "?" end
	local b = p:gsub(".*/", "")
	return b == "" and "?" or b
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
---@field parse_failures integer Consecutive decode-failure count (§17.12; set by S5 _feed). Reset to 0 on a successful decode + by M.reset(). At threshold (default 5) → state.failed=true.
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
	parse_failures = 0,
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

--- §17.4.3 mismatch condition (PURE — no nvim, no vim.fn, no state, no notify; directly
--- unit-testable, the completion.M.is_attachment_context / M.shell_word_prefix style).
--- Returns the richer shell's basename ("zsh"|"fish") when the mismatch condition's
--- RESOLUTION parts hold: resolved basename == "bash" (tier-2) AND env_shell basename ∈
--- {"zsh","fish"} (tier-1). The PATH check (`vim.fn.executable`) is INTENTIONALLY at the
--- CALL SITE (ensure step 4) so this helper stays deterministic + vim.fn-free for unit
--- tests.
---
--- SELF-GATING: under prefer:"pi" it is true ONLY when descriptor.shell is bash AND
--- $SHELL is zsh/fish; under prefer:"shell" (resolved==$SHELL) it is structurally false;
--- under prefer:"pi" with a descriptor that omits shell (resolve falls through to
--- $SHELL) resolved==$SHELL → false. NO explicit prefer check is needed (do NOT
--- double-gate — it risks drifting from resolve_shell).
---
--- NEVER throws: non-string/empty resolved → nil; non-string/empty env_shell → nil;
--- basename via the shared helper. Returns nil (not false) so the call site reads
--- `if M.mismatch_target(...) then`.
---@param resolved_shell string The resolved execution shell path (state.shell / M.resolve_shell result).
---@param env_shell string? The raw $SHELL env var (vim.env.SHELL; nil → no mismatch possible).
---@return string|nil richer_basename "zsh"|"fish" if the mismatch's resolution parts hold, else nil.
function M.mismatch_target(resolved_shell, env_shell)
	if type(resolved_shell) ~= "string" or resolved_shell == "" then return nil end
	if basename(resolved_shell) ~= "bash" then return nil end   -- only bash (tier-2) can be "poorer"
	if type(env_shell) ~= "string" or env_shell == "" then return nil end
	local ebase = basename(env_shell)
	if ebase ~= "zsh" and ebase ~= "fish" then return nil end   -- tier-1 richer shells only
	return ebase
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
	local base = basename(resolved_shell)                 -- "/bin/zsh"→"zsh" (shared helper)
	if base == "?" or base == "" then return nil end
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

--- The resolved execution shell for the session (for `pi-bridge.shell.accept`'s
--- quoting). Returns the cached `state.shell` (set on first ensure()/spawn; guaranteed
--- set whenever a shell MENU exists, since the menu is populated only via
--- do_shell_fetch → complete_current → request → ensure) or nil (the daemon was never
--- spawned — `quote` then degrades to the POSIX single-quote default, harmless).
--- NEVER throws (a plain table-field read). This is the PUBLIC read seam for the one
--- field `accept.apply` needs — the full `state` table is NOT exposed (minimal surface).
---@return string|nil state.shell The resolved shell PATH (e.g. "/bin/zsh"), or nil.
function M.get_shell()
	return state.shell
end

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
	state.pending_cb   = nil
	state.failed       = false
	state.parse_failures = 0
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
	-- §17.4.3 one-time mismatch notice: prefer:"pi" resolved bash while $SHELL is a richer
	-- zsh/fish on PATH. PURE condition (M.mismatch_target) + the PATH check
	-- (vim.fn.executable, pcall'd). notify.once dedups to once-per-session. Fires here ONLY
	-- on the first spawn (steps 4-8 run once per session — subsequent ensures hit the proc cache).
	pcall(function()
		local richer = M.mismatch_target(resolved, vim.env.SHELL)
		if richer then
			local ok, ex = pcall(vim.fn.executable, richer)
			if ok and ex == 1 then
				require("pi-bridge.notify").once("shell-mismatch", vim.log.levels.WARN,
					"pi-bridge: pi runs commands in bash; using bash completion to match. For your native "
					.. richer .. " completions, set pi's shellPath to " .. (vim.env.SHELL or richer)
					.. " (then completion and execution both use it). :help pi-bridge-shell")
			end
		end
	end)
	-- (5) Pick the driver (§17.4.2). No driver → permanent degrade (§17.6.4): set failed so
	--     the next ensure short-circuits (do NOT retry resolve→pick per keystroke).
	state.driver = M.pick_driver(resolved)
	if not state.driver then
		state.failed = true
		-- §17.12 degrade notify (no driver: unknown shell OR user-disabled driver). notify.once
		-- dedups with any earlier degrade → ONE toast/session. The message names the resolved shell.
		pcall(function()
			require("pi-bridge.notify").once("shell-degrade", vim.log.levels.WARN,
				"pi-bridge: shell completion unavailable for `" .. basename(resolved)
				.. "`; :help pi-bridge-shell")
		end)
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
			-- §17.12 degrade notify (spawn err: binary missing / rc error / startup timeout).
			-- notify.once dedups with any earlier degrade → ONE toast/session.
			pcall(function()
				require("pi-bridge.notify").once("shell-degrade", vim.log.levels.WARN,
					"pi-bridge: shell completion unavailable for `" .. basename(state.shell)
					.. "`; :help pi-bridge-shell")
			end)
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
		-- §17.9 first-run hint (INFO): fires ONCE on the first successful daemon spawn.
		-- Suppressed on a failed spawn STRUCTURALLY (steps 5/8a/8c return before reaching
		-- here → the hint CANNOT fire). notify.once dedups to once-per-session.
		pcall(function()
			require("pi-bridge.notify").once("shell-active", vim.log.levels.INFO,
				"pi-bridge: shell completion active (`" .. basename(state.shell)
				.. "`); :help pi-bridge-shell")
		end)
		on_ready(nil)
	end)
	-- (8c) driver.start ITSELF threw (not just called cb with err): treat as spawn error (D4).
	if not ok then
		state.driver = nil
		state.failed = true
		-- §17.12 degrade notify (driver.start threw). notify.once dedups with any earlier degrade.
		pcall(function()
			require("pi-bridge.notify").once("shell-degrade", vim.log.levels.WARN,
				"pi-bridge: shell completion unavailable for `" .. basename(state.shell)
				.. "`; :help pi-bridge-shell")
		end)
		on_ready(tostring(spawn_err))
	end
end

--- Normalize ONE raw daemon item `{ value, description? }` (§17.6 driver wire shape) into
--- an `AutocompleteItem { value, label, description? }` (completion.lua L244-250). Defensive:
--- a non-table item, or a non-string/empty `value`, returns `nil` (the item is DROPPED — a
--- single malformed item among many must NOT fail the whole response; mirrors jsonlreader's
--- never-throws + completion.lua's `result.items or {}`). `label` defaults to `value` (the
--- §17.6 drivers emit no label); a future driver's explicit label is honored if it is a
--- non-empty string. `description` is carried through iff present + non-empty, else omitted
--- (nil). NEVER throws (pure table reads).
---@param raw table? A raw daemon item `{ value:string, description?:string, label?:string }`.
---@return table|nil item The normalized AutocompleteItem, or nil to drop.
local function normalize_item(raw)
	if type(raw) ~= "table" then return nil end
	local value = raw.value
	if type(value) ~= "string" or value == "" then return nil end
	return {
		value = value,
		label = (type(raw.label) == "string" and raw.label ~= "" and raw.label) or value,
		description = (type(raw.description) == "string" and raw.description ~= "") and raw.description or nil,
	}
end

--- The §17.12 consecutive-parse-failure threshold. PRD §17.11 config defines NO parse-failure
--- key (grep-confirmed: zero matches repo-wide) → default `5`. Reads
--- `config.shell.max_parse_failures` DEFENSIVELY (forward-compatible — a future config key
--- works without a code change): a non-number or `<1` falls back to 5. Lazy
--- `require("pi-bridge")` (async handshake + test mocks swap fakes after require — mirrors
--- S2/S4). Called ONLY on the decode-failure path (cheap). NEVER throws.
---@return integer n The threshold (>=1; default 5).
local function max_parse_failures()
	local pi = require("pi-bridge")
	local cfg = (pi.config and pi.config.shell) or {}
	local n = cfg.max_parse_failures
	if type(n) ~= "number" or n < 1 then return 5 end
	return math.floor(n)
end

-- The sentinel delimiters (§17.5.1). Module-locals so the plain `find` reuses them without
-- re-allocating. The trailing `\n` is part of the delimiter (§17.5.1:
-- `__PIRESP_START__\n` / `__PIRESP_END__\n`) — searching WITH the `\n` ensures the FULL
-- sentinel arrived before slicing (a half-arrived `__PIRESP_END` does not falsely match;
-- we wait for the close newline).
local START = "__PIRESP_START__\n"
local END   = "__PIRESP_END__\n"

--- The §17.5.1/§17.5.2 response PARSE layer of the completion daemon. Appends a stdout
--- `chunk` to `state.rx_buf`, then DRAINS every complete `__PIRESP_START__\n`…`__PIRESP_END__\n`
--- pair present: trims the payload between them, `pcall(vim.json.decode)`s it as ONE
--- `{ items, prefix }` object (§17.5.1 — NOT NDJSON; the §17.6 driver sketches' per-line
--- format is a doc inconsistency the drivers must reconcile), normalizes each raw
--- `{ value, description? }` item into an `AutocompleteItem { value, label, description? }`
--- (dropping malformed items), and invokes the gen-guarded `state.pending_cb(items, prefix)`
--- (set by S4 `request`) — guarded by `if type(...)=="function"` so a late/duplicate
--- delivery after S4 nil'd the slot is a no-op. Anything OUTSIDE the sentinels (prompts,
--- async segments, stray output) is buffered-then-discarded. Leftover (a partial pair)
--- stays in `rx_buf`.
---
--- §17.12 parse-failure handling: a decode failure (or a non-table decode) increments
--- `state.parse_failures`; at the threshold (`config.shell.max_parse_failures`, default 5)
--- the daemon is marked unhealthy (`state.failed = true` — `ensure()` then short-circuits,
--- no new requests) + `M.teardown()` is forward-GUARDED (no-op until S6 lands) + `failed`
--- re-asserted (S6's teardown may `reset()`; the daemon is DEAD → must stay failed — §17.12
--- "no auto-respawn in v1"). The one-time degrade NOTIFY is P2.M2.T3.S4's job (S5 sets only
--- the FACT — mirrors S3 `_reset` / S4 `request`). A SUCCESSFUL decode resets
--- `parse_failures` to 0 (§17.12 "consecutive").
---
--- `prefix` is READ from `decoded.prefix` (§17.5.1; default "") — NOT derived from
--- `line[1..cursor]`, because `_feed` receives ONLY the chunk (the `read_start` cb passes
--- no line/cursor; see S3's wiring). The consumer `complete_current` (P2.M2.T3.S3), which
--- has the buffer, may refine prefix.
---
--- Runs in the libuv `read_start` callback (FAST context) but does NO `vim.api.*` (string
--- + `vim.json` + state writes + the `pending_cb` call only) → fast-safe WITHOUT
--- `vim.schedule` (E5560); the menu hop is the CONSUMER's (P2.M2.T3) scheduling
--- responsibility. NEVER throws (`pcall` decode; type-guarded `decoded`/`.items`/`.prefix`/
--- `pending_cb`; `ipairs` over `.items`; nil/"" `chunk` guarded).
---
--- FORWARD CONTRACTS (do NOT implement here):
---   * S4's `state.pending_cb` → this invokes `if type(state.pending_cb)=="function" then
---     state.pending_cb(items, prefix) end`. The `if type(...)` guard is what makes a
---     late/duplicate delivery a no-op (S4 nil's the slot first — one-shot).
---   * S6's `M.teardown()` → forward-GUARDED on the parse-failure threshold (`if type(
---     M.teardown)=="function" then pcall(M.teardown) end`) + `failed` re-asserted after.
---   * P2.M2.T3.S4 → the §17.12 one-time degrade `notify.once`.
---   * P2.M2.T3.S2/S3 → `complete_current(buf, cb)` receives `(err, items, prefix)` from
---     S5→S4's cb; it may RE-DERIVE prefix from the buffer + must `vim.schedule` the menu hop.
---   * P2.M2.T4 / P2.M3.T5 drivers → MUST emit the §17.5.1 single-object format
---     `__PIRESP_START__\n{"items":[...],"prefix":"..."}\n__PIRESP_END__\n`, NOT the §17.6.x
---     per-item NDJSON sketch (NDJSON fails to decode — LIVE-VERIFIED).
---
---@param chunk string? A stdout chunk from the daemon pipe (nil ⇒ EOF ⇒ `M._reset`; "" ⇒ no-op).
function M._feed(chunk)
	-- (0) EOF guard (D8). S3's read_start routes EOF to _reset directly, so _feed(nil)
	--     shouldn't occur via the loop — but a direct _feed(nil) call (e.g. a test) also
	--     marks the daemon unhealthy (idempotent with _reset). Empty chunk → no-op (avoid
	--     a useless concat + drain loop).
	if chunk == nil then M._reset(); return end
	if chunk == "" then return end
	-- (1) APPEND (byte-safe — Lua strings are byte buffers; split-multibyte chars reassemble
	--     on the next chunk, NO UTF-8 streaming decoder needed; mirrors jsonlreader GOTCHA 1).
	state.rx_buf = state.rx_buf .. chunk
	-- (2) DRAIN: while a complete __PIRESP_START__\n .. __PIRESP_END__\n pair is present,
	--     slice + decode + normalize + deliver. A single chunk may carry MANY pairs (drain
	--     loop) or a PARTIAL pair (left buffered). Mirrors jsonlreader.feed's drain loop.
	while true do
		-- plain byte scan (4th `true` arg — jsonlreader GOTCHA 3: pattern matching OFF, so
		-- literal '%'/'+.'/etc in the JSON payload never corrupts the sentinel search).
		local s = state.rx_buf:find(START, 1, true)
		if not s then break end                         -- no START → noise-only; wait for more
		local ps = s + #START                           -- payload starts AFTER "__PIRESP_START__\n"
		local e = state.rx_buf:find(END, ps, true)      -- END\n AFTER the START
		if not e then break end                         -- START but no END yet → wait for more
		-- (3) EXTRACT the payload (bytes between START\n and END\n) + trim surrounding
		--     whitespace. vim.json.decode tolerates whitespace (LIVE-VERIFIED) but trim is
		--     deterministic + makes the empty-payload edge explicit (empty → "" → decode
		--     throws → parse_failure; §17.5.1 mandates {"items":[]} so empty is a protocol
		--     violation — do NOT special-case it to success).
		local payload = state.rx_buf:sub(ps, e - 1):gsub("^%s+", ""):gsub("%s+$", "")
		-- (4) ADVANCE rx_buf PAST this response (keep the remainder for the next iteration /
		--     chunk; trailing noise after END\n stays buffered, inert until the next START).
		state.rx_buf = state.rx_buf:sub(e + #END)
		-- (5) DECODE (pcall'd — never throws; mirrors jsonlreader GOTCHA 6). The payload MUST
		--     be a single {items,prefix} object (§17.5.1; NDJSON throws — D1). A bare
		--     number/string decodes to a non-table → treated as a parse failure (no .items).
		local dok, decoded = pcall(vim.json.decode, payload)
		if not dok or type(decoded) ~= "table" then
			-- (6a) PARSE FAILURE: increment the §17.12 consecutive counter. At threshold →
			--     disable + forward-guard teardown (S6) + re-assert failed. NO notify
			--     (P2.M2.T3.S4).
			state.parse_failures = (state.parse_failures or 0) + 1
			if state.parse_failures >= max_parse_failures() then
				state.failed = true
				-- Forward-guard: kill the daemon IF S6's teardown() has landed (no-op today).
				-- Re-assert failed AFTER (S6's teardown may reset(); the daemon is dead → must
				-- STAY failed so ensure() short-circuits instead of re-spawning a known-broken
				-- daemon — §17.12 "no auto-respawn in v1").
				pcall(function() if type(M.teardown) == "function" then M.teardown() end end)
				state.failed = true
				-- §17.12 degrade notify (N consecutive parse failures). notify.once dedups with
				-- any earlier degrade → ONE toast/session. Fast-context-safe.
				pcall(function()
					require("pi-bridge.notify").once("shell-degrade", vim.log.levels.WARN,
						"pi-bridge: shell completion unavailable for `" .. basename(state.shell)
						.. "`; :help pi-bridge-shell")
				end)
			end
		else
			-- (6b) SUCCESS: reset the consecutive counter (§17.12 "consecutive"). Extract
			--     items + prefix DEFENSIVELY (mirrors completion.lua do_refresh L465-470:
			--     type-guarded, default {} / ""). Normalize each item → AutocompleteItem[]
			--     (drop malformed — D5).
			state.parse_failures = 0
			local raw_items = (type(decoded.items) == "table") and decoded.items or {}
			local prefix     = (type(decoded.prefix) == "string") and decoded.prefix or ""
			local items = {}
			for _, raw in ipairs(raw_items) do           -- ipairs: ordered + nil-hole-safe; non-array → {}
				local norm = normalize_item(raw)
				if norm then items[#items + 1] = norm end
			end
			-- (7) DELIVER via the gen-guarded ONE-SHOT pending_cb (set by S4 request). The
			--     `if type(...)=="function"` guard is MANDATORY (pending_cb may be nil — no
			--     request in flight, or S4 already fired+nil'd it). S5 INVOKES it; S4 OWNS
			--     setting/niling it. Do NOT vim.schedule (fast context; the consumer P2.M2.T3
			--     schedules the menu hop — D9).
			if type(state.pending_cb) == "function" then
				state.pending_cb(items, prefix)
			end
		end
	end
end

--- The §17.12 EOF-on-daemon-pipe path (shell crashed mid-session). Marks the daemon
--- unhealthy (`state.failed = true`) + nils proc/pipes so the next `ensure` short-
--- circuits via the `failed` guard (no auto-respawn in v1).
---
--- S6 EXTENSION: `close_handles()` is prepended as the FIRST line (the EOF pipe-close
--- S3's [Mode A] header explicitly assigned to S6). Without it, a daemon crash mid-
--- session leaves the stdin/stdout/proc handles open for the rest of the session (a
--- `uv_handle_t` leak — libuv owns the C structs; not GC'd until closed). On EOF the proc
--- is already dead (libuv delivered `data==nil`), so `process_kill` is moot-but-harmless
--- (pcall); the PIPE-close is the real fix. ZERO risk to S3's tests (the fake pipes
--- absorb read_stop/close; S3's assertions — `failed=true`, nil proc, "does NOT call
--- reset" — all hold since `close_handles()` touches neither `failed` nor `reset()`).
---
--- Does NOT call `M.reset()` (that clears `failed = false`; `_reset` must LEAVE
--- `failed = true` — a CRASH is not a clean exit). Runs on the libuv loop (fast context).
--- NEVER throws (close_handles pcall's every luv call; plain table assignments).
function M._reset()
	close_handles()               -- S6: close the real handles (the EOF pipe leak S3 deferred here)
	state.failed = true           -- S3 (unchanged): a crash is NOT a clean exit
	-- §17.12 degrade notify (mid-session EOF crash). notify.once dedups with any earlier
	-- degrade → ONE toast/session. Fast-context-safe (notify.once schedules the notify).
	pcall(function()
		require("pi-bridge.notify").once("shell-degrade", vim.log.levels.WARN,
			"pi-bridge: shell completion unavailable for `" .. basename(state.shell)
			.. "`; :help pi-bridge-shell")
	end)
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

--- close_handles() — the SHARED, idempotent, never-throws kill+close routine (used by BOTH
--- `M.teardown()` — active kill + reset — AND `M._reset()` — the EOF path, where the proc is
--- already dead). Mirrors bridge.lua `M.close()` (GOTCHA 2: is_closing-guard + pcall; the
--- double-close "already closing" throw) + completion.lua `cancel_timer` (L350-360: stop the
--- active op THEN close) + the fish spike teardown idiom (is_closing + pcall + "sigkill").
---
--- Order: (1) stdout `read_stop` THEN `close` (stop the read cb from re-entering `_feed`/
--- `_reset` mid-teardown — completion.lua `cancel_timer` order; NOT the reversed close-then-
--- read_stop); (2) proc `process_kill("sigkill")` THEN `close` — F3 LIVE-VERIFIED:
--- `process_kill` does NOT close the `uv_process_t` (`is_closing()` stays false even after
--- `on_exit` fires); `proc:close()` is REQUIRED or the handle LEAKS for the session. The fish
--- spike omits `proc:close()` (acceptable — nvim exits); production teardown does NOT.
--- (3) stdin `close` (no read_start on it).
---
--- IDEMPOTENT + never-throws: every `:close()`/`:read_stop()`/`process_kill` is guarded by
--- `if state.X and not state.X:is_closing()` AND `pcall`'d (F5: double-close throws). A 2nd call
--- sees `state.X == nil` (reset nil'd the refs) → every `if` skips → all no-ops; the
--- `is_closing()` guard covers the narrow kill→reset window AND the EOF path where `_reset`
--- already closed them. NO `vim.api.*`; NO notify; NO `vim.schedule` (runs from libuv FAST
--- context — S5's `_feed` caller — AND the nvim main loop — VimLeave). Does NOT touch
--- `state.failed` and does NOT call `reset()` (handle-only; `_reset` owns failed; teardown
--- owns reset). Does NOT close stderr — shell.lua never stores it (the driver owns it).
close_handles = function()
	-- (1) stdout: read_stop THEN close (stops the read cb re-entering _feed/_reset mid-teardown).
	if state.stdout and not state.stdout:is_closing() then
		pcall(function() state.stdout:read_stop() end)
		pcall(function() state.stdout:close() end)
	end
	-- (2) proc: process_kill("sigkill") THEN close. F3: process_kill does NOT close the
	--     uv_process_t (is_closing stays false even after on_exit) — proc:close() is REQUIRED
	--     or it LEAKS. "sigkill" is unconditional (the daemon may be wedged).
	if state.proc and not state.proc:is_closing() then
		pcall(uv.process_kill, state.proc, "sigkill")
		pcall(function() state.proc:close() end)
	end
	-- (3) stdin: close (no read_start on it; is_closing-guarded + pcall'd).
	if state.stdin and not state.stdin:is_closing() then
		pcall(function() state.stdin:close() end)
	end
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

--- teardown() — §17.5.2 + §17.12 daemon teardown. Kill the daemon (`uv.process_kill`
--- SIGKILL), close the stdin/stdout/proc handles, finalize the in-flight request
--- (soft-degrade empty result → the user `cb(nil, {}, "")`), then `M.reset()` (full clean
--- slate). The §17.5.2 skeleton's `teardown()/on_exit()` comment verbatim: "kill proc
--- (uv.process_kill SIGKILL), close pipes, reset state."
---
--- Callers (do NOT implement here — S6 is called BY these):
---   * ftplugin VimLeavePre/ExitPre (P2.M3.T6.S3): `autocmd VimLeavePre,ExitPre <buffer>
---     lua require("pi-bridge.shell").teardown()`. BOTH fire on exit → teardown MUST tolerate
---     the double-call (idempotent).
---   * S5's parse-failure threshold (§17.12): after N (default 5) consecutive garbage daemon
---     responses, S5 forward-GUARDS `if type(M.teardown)=="function" then pcall(M.teardown)
---     end` THEN re-asserts `state.failed=true` (S6's `reset()` clears failed; S5 re-asserts
---     so the dead daemon stays failed — §17.12 "no auto-respawn in v1").
---
--- IDEMPOTENT: a 2nd call sees `state.proc/stdin/stdout == nil` (reset nil'd them) →
--- every `if state.X` guard in `close_handles()` skips → all no-ops; the `is_closing()`
--- guard covers the narrow kill→reset window. Needs NO shadow flag (unlike bridge.lua's
--- persistent socket) — it nils the state refs in `reset()`.
---
--- pending_cb soft-degrade resolution (the D-conflict): the item description says call
--- `state.pending_cb("teardown", {}, "")`, but S4's `pending_cb` signature is
--- `(items, prefix)` — 2 params. Passing `("teardown", {})` makes `items="teardown"` (a
--- string — type bug). S6 invokes `pcall(state.pending_cb, {}, "")` → through S4's
--- gen-guarded closure → user `cb(nil, {}, "")` (soft-degrade empty, IDENTICAL to S4's
--- timeout path). "teardown" vs "degrade" is not distinguishable through S4's closure;
--- §17.12 does not require distinguishing (both = "no completion this keystroke").
--- Delivered BEFORE `reset()` (reset nils the slot → if reset-first, the in-flight cb
--- never fires → the menu dangles on the parse-failure path).
---
--- NEVER throws: every luv call pcall'd + is_closing-guarded (F5: double-close throws);
--- pending_cb pcall'd + type-guarded; state writes are plain assignments. NO `vim.api.*`
--- (teardown is lifecycle, not UI). NO `vim.schedule` (synchronous cleanup; the consumer's
--- cb-scheduling is its concern per S4). NO notify (the §17.12 one-time degrade notify is
--- P2.M2.T3.S4). Runs from libuv FAST context (S5's `_feed` caller) AND the nvim main loop
--- (VimLeavePre) — never-throws is a luv-callback + VimLeave safety requirement.
---
--- Forward contracts (do NOT implement; documented):
---   * `cancel_req_timer()` (S4) is called FIRST (stops the per-request timer from firing
---     mid-teardown — a fire would race teardown's own pending_cb deliver).
---   * The proc:close() leak fix (F3) — `process_kill` alone LEAKS the uv_process_t.
---   * S5 re-asserts `state.failed=true` AFTER teardown on the parse-failure path.
---   * The driver owns stderr — shell.lua stores only proc/stdin/stdout (S3); teardown
---     cannot close a handle it never stored.
function M.teardown()
	-- (1) cancel the per-request timer FIRST (S4 forward contract: stop a fire racing
	--     teardown). Idempotent (nil-guarded + is_closing-guarded).
	cancel_req_timer()
	-- (2) finalize the in-flight request (soft-degrade empty). pcall'd + type-guarded so
	--     a throwing/absent cb can't escape teardown. BEFORE reset() — reset() nils pending_cb.
	--     D-conflict: invoke ({}, "") NOT ("teardown",...) — S4's pending_cb is (items, prefix).
	if type(state.pending_cb) == "function" then pcall(state.pending_cb, {}, "") end
	-- (3) kill + close the handles (idempotent; is_closing-guarded; pcall'd). Also closes
	--     the proc handle (the F3 leak fix — process_kill alone does NOT close it).
	close_handles()
	-- (4) full clean slate. (S5 re-asserts state.failed=true AFTER teardown on the
	--     parse-failure path; on VimLeave failed is moot — editor closing.)
	M.reset()
end

-- ===========================================================================
-- §17.7 buffer→daemon adapter (complete_current + the client-side prefix helper)
-- ===========================================================================
--- §17.6.1 client-side prefix: the trailing non-whitespace run of `line` (the current shell
--- word being completed). PURE (no nvim, no state) → directly unit-testable (the
--- coords.lua / completion.is_attachment_context style). Used by complete_current to OVERRIDE
--- the daemon's advisory prefix (research §6 — the daemon's decoded.prefix is ignored in v1;
--- shell/accept.lua recomputes word boundaries independently, so a deterministic client
--- prefix is correct + sufficient). Returns "" for an empty/whitespace-only line, "" on a
--- non-string (never throws). Byte-safe: `[%S]+$` operates on bytes (ASCII \S class), so
--- a multibyte trailing word (e.g. `"日cmd"`) is returned whole (UTF-8 continuation bytes
--- are NOT ASCII whitespace — they match `%S`).
---@param line string? The command text up to the cursor (after bang strip).
---@return string prefix The trailing word ("" if none).
function M.shell_word_prefix(line)
	if type(line) ~= "string" then return "" end
	return line:match("[%S]+$") or ""
end

--- §17.7 shell.complete_current(buf, cb) — the buffer→daemon bridge. Reads pi-prompt line
--- 1 + the nvim cursor, strips the `!`/`!!` bangs (§17.7), computes the BYTE-domain
--- line/cursor/after triple (§17.14 — NO coords.nvim_to_pi_coords / coords.byte_to_utf16 /
--- vim.str_utfindex; the shell path is byte-domain, unlike §8's UTF-16 bridge path),
--- short-circuits an empty command (§17 edge case — do NOT cold-start the daemon for a
--- bare `!`), derives prefix client-side (§17.6.1), and delegates to M.request(line,
--- cursor, after, wrapper_cb). The wrapper_cb runs in LIBUV FAST CONTEXT (M.request's
--- pending_cb, fired by S5 `_feed`'s read_start cb OR the per-request timer — shell.lua:642/650)
--- → PURE string math (shell_word_prefix) + forward to `cb` ONLY (NO vim.api.* — E5560; the
--- consumer `do_shell_fetch` already vim.schedule's the menu hop, so do NOT duplicate).
---
--- The client-side prefix OVERRIDES the daemon's `prefix` field (advisory/ignored in v1).
--- complete_current does NOT add its own gen guard (completion.lua's state.gen
--- `do_shell_fetch` + shell.lua's state.gen `M.request` already bookend it — just forward).
---
--- Called by completion.lua's do_shell_fetch (the SOLE consumer; forward-guarded there).
--- Runs on the nvim MAIN LOOP at call time (do_refresh/force_fetch/on_tab are main-loop
--- callers) → the buffer/cursor READ is api-safe (NO vim.schedule needed for the READ).
--- NEVER throws (per-keystroke + autocmd contract): pcall every nvim.api/M.request;
--- type-guard buf/cb; `nvim_buf_is_valid` guard; bad args → cb(err) or a guarded no-op.
---@param buf integer The pi-prompt buffer handle (current — guarded by the caller).
---@param cb  pi-bridge.shell.RequestCb Resolved EXACTLY ONCE: cb(nil, items, prefix) on
---           success; cb(err) on a read/ensure/write/encode failure.
function M.complete_current(buf, cb)
	if type(cb) ~= "function" then cb = function() end end -- never-throws on a bad arg
	-- (1) GUARD buf. A wiped/non-buffer → cb(err) (silent degrade; the consumer's err path).
	if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
		return cb("invalid buf")
	end
	-- (2) READ line 1 (only line 1 — completion_context already gates cursorLine==0). pcall
	--     (a wiped buf mid-call → cb). nvim_buf_get_lines(buf, 0, 1, false) returns {line1}
	--     (a UTF-8 Lua string — byte-correct for the sub() math below).
	local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, 1, false)
	if not ok or type(lines) ~= "table" or type(lines[1]) ~= "string" then
		return cb("read failed")
	end
	local line1 = lines[1]
	-- (3) READ cursor (current window — buf is current per the caller's currency guard). pcall.
	local cur
	ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
	if not ok or type(cur) ~= "table" or type(cur[2]) ~= "number" then
		return cb("read failed")
	end
	local byte_col = cur[2] -- 0-based BYTE offset (coords.lua header; §17.14)
	-- (4) BANG STRIP (§17.7): "!!" → 2, else "!" → 1, else 0 (defensive; completion_context
	--     already gated line1[1]=="!", but be robust). Check "!!" FIRST — it also starts with
	--     "!", so the wrong order strips only 1.
	local bangs = 0
	if line1:sub(1, 2) == "!!" then bangs = 2
	elseif line1:sub(1, 1) == "!" then bangs = 1 end
	-- (5) COMPUTE the BYTE-domain triple (§17.14 — NO coords/UTF-16). Clamp cin ≥ 0 (a cursor
	--     ON the bangs → 0; a NEGATIVE cin would make sub(1,-1) = the WHOLE string — WRONG).
	--     `line` is "up to the cursor" (§17.5.1) ⇒ cursor == #line by construction.
	local cmd   = line1:sub(bangs + 1)           -- full command after bangs
	local cin   = math.max(0, byte_col - bangs)  -- cursor offset into cmd (0-based byte)
	local line  = cmd:sub(1, cin)                -- up to cursor (cin bytes; sub(1,0)="")
	local after = cmd:sub(cin + 1)               -- after cursor
	-- (6) EMPTY-COMMAND GUARD (§17 edge case): a bare `!` / `!   ` does NOT spawn the daemon
	--     (no completion until a word exists). `!git ` (trailing space) is NOT empty → query.
	--     Match wholly-empty/whitespace. Resolves cb DIRECTLY (M.request/ensure NOT called).
	if cmd == "" or cmd:match("^%s*$") then
		return cb(nil, {}, "")
	end
	-- (7) DELEGATE to M.request. The wrapper_cb runs in LIBUV FAST CONTEXT (M.request's
	--     pending_cb ← _feed/timer) → PURE string math + forward ONLY. Derive prefix CLIENT-
	--     SIDE (§17.6.1 / research §6: OVERRIDE the daemon's advisory prefix). err → cb(err)
	--     (NO prefix derivation / cb(nil,…) on the err path).
	M.request(line, cin, after, function(rerr, ritems, _rprefix)
		if rerr then return cb(rerr) end
		cb(nil, ritems or {}, M.shell_word_prefix(line)) -- OVERRIDE prefix (line captured)
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