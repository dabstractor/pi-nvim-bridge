# Code Behavior Spec — pi-bridge shell completion subsystem

Read of ACTUAL current code at `/home/dustin/projects/pi-nvim-bridge`. No modifications.
All strings quoted verbatim with file:line anchors. Precision over prose.

---

## 1. SHELL RESOLUTION (`shell.lua` `M.resolve_shell`)

File: `lua/pi-bridge/shell.lua:196-226`

```lua
function M.resolve_shell(prefer)
	prefer = prefer or "pi"
	-- explicit path (NOT one of the three keywords) → verbatim
	if type(prefer) == "string" and prefer ~= ""
		and prefer ~= "pi" and prefer ~= "shell" and prefer ~= "bash" then
		return prefer, "config"
	end
	if prefer == "pi" then
		local ds, dsrc = descriptor_shell()
		if ds then return ds, dsrc or "pi" end      -- descriptor.shell + real shellSource (Issue 5)
	end
	if prefer == "pi" or prefer == "shell" then
		local env = vim.env.SHELL
		if type(env) == "string" and env ~= "" then return env, "$SHELL" end
		return "/bin/bash", "default"
	end
	if prefer == "bash" then
		return "/bin/bash", "default"
	end
	return "/bin/bash", "default"
end
```

### Per-`prefer` behavior

| `prefer` value             | resolved shell path                          | `source` returned | notes |
|----------------------------|----------------------------------------------|-------------------|-------|
| `"pi"` (default)           | `descriptor.shell` if set; else `$SHELL`; else `/bin/bash` | `"pi"` (or real `shellSource`), then `"$SHELL"`, then `"default"` | falls through the chain |
| `"shell"`                  | `$SHELL` if set + non-empty; else `/bin/bash` | `"$SHELL"` or `"default"` | never touches the descriptor |
| `"bash"`                   | `/bin/bash`                                  | `"default"`       | |
| any other non-empty string (treated as `/abs/path`) | that path verbatim | `"config"` | the explicit-path row |

### `source` string returned per branch

- `"pi"` — the descriptor advertised shellSource (or the `or "pi"` back-compat fallback)
- `"$SHELL"` — resolved from `vim.env.SHELL`
- `"default"` — hard-coded `/bin/bash` fallback
- `"config"` — explicit user-supplied path

### `descriptor_shell()` — CONFIRMED returns `(path, source)`

File: `lua/pi-bridge/shell.lua:147-172`

```lua
local function descriptor_shell()
	local pi = require("pi-bridge")
	local br = pi.bridge
	if br and type(br.get_shell_info) == "function" then
		local si = br.get_shell_info()
		if type(si) == "table" and type(si.shell) == "string" and si.shell ~= "" then
			return si.shell, si.shellSource       -- ← 2nd return is the real source
		end
	end
	local desc = pi.descriptor
	if type(desc) == "table" and type(desc.shell) == "string" and desc.shell ~= "" then
		return desc.shell, desc.shellSource      -- ← 2nd return here too
	end
	return nil
end
```

Returns `(shell_path, shell_source)` where `shell_source` is `si.shellSource` (from
`bridge.get_shell_info()`) or `desc.shellSource`, or `nil` when no shell is advertised.

### CONFIRMED: `resolve_shell("pi")` propagates the real `shellSource` with `or "pi"` fallback

Line `shell.lua:213`:
```lua
if ds then return ds, dsrc or "pi" end
```
`dsrc` is the real `descriptor_shell()` 2nd return; `or "pi"` only kicks in when the
descriptor carries a shell but no `shellSource` (older bridge versions). The Issue 5
"propagate real shellSource" fix IS present.

---

## 2. MISMATCH NOTICE (Issue 1) — `"shell-mismatch"`

File: `lua/pi-bridge/shell.lua:432-448` (inside `M.ensure`, step 4)

```lua
	if (cfg.prefer or "pi") == "pi" then
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
	end
```

| field | exact value |
|-------|-------------|
| category key | `"shell-mismatch"` |
| level | `vim.log.levels.WARN` |
| message (template) | `"pi-bridge: pi runs commands in bash; using bash completion to match. For your native " .. richer .. " completions, set pi's shellPath to " .. (vim.env.SHELL or richer) .. " (then completion and execution both use it). :help pi-bridge-shell"` |
| dedup | `notify.once(...)` — once-per-session |
| example rendered (richer="zsh", SHELL="/bin/zsh") | `pi-bridge: pi runs commands in bash; using bash completion to match. For your native zsh completions, set pi's shellPath to /bin/zsh (then completion and execution both use it). :help pi-bridge-shell` |

### Gate condition — CONFIRMED wrapped in `if (cfg.prefer or "pi") == "pi"`

The mismatch block is gated by exactly:
```lua
if (cfg.prefer or "pi") == "pi" then
```
It does NOT fire under `prefer="bash"` or an explicit `/abs/path` — those resolve to a
non-`"pi"` value, so the gate is false. CONFIRMED: under `prefer="bash"` (and explicit
path) the mismatch notice is suppressed.

### Inner condition (`M.mismatch_target`)

File: `shell.lua:240-252`. Returns the richer shell's basename (`"zsh"` or `"fish"`) iff:
- `basename(resolved_shell) == "bash"`, AND
- `basename(env_shell)` ∈ `{ "zsh", "fish" }`
The PATH check (`vim.fn.executable(richer) == 1`) is at the call site (shell.lua:437),
deliberately NOT inside the pure helper.

---

## 3. CONSISTENCY NOTICE (Issue 2) — `"shell-consistency"`

File: `lua/pi-bridge/shell.lua:449-467` (inside `M.ensure`, immediately after the mismatch block)

```lua
	if (cfg.prefer or "pi") == "pi" and source == "$SHELL" then
		local env_base = basename(vim.env.SHELL or "")
		if env_base == "zsh" or env_base == "fish" then
			pcall(function()
				local ok, ex = pcall(vim.fn.executable, env_base)
				if ok and ex == 1 then
					require("pi-bridge.notify").once("shell-consistency", vim.log.levels.WARN,
						"pi-bridge: completions use " .. env_base
						.. " (from $SHELL) but pi may execute commands in bash. "
						.. "For guaranteed consistency set PI_NVIM_SHELL=" .. (vim.env.SHELL or env_base)
						.. " (or pi's shellPath). :help pi-bridge-shell")
				end
			end)
		end
	end
```

| field | exact value |
|-------|-------------|
| category key | `"shell-consistency"` — **DISTINCT** from `"shell-mismatch"` (separate dedup set) |
| level | `vim.log.levels.WARN` |
| message (template) | `"pi-bridge: completions use " .. env_base .. " (from $SHELL) but pi may execute commands in bash. For guaranteed consistency set PI_NVIM_SHELL=" .. (vim.env.SHELL or env_base) .. " (or pi's shellPath). :help pi-bridge-shell"` |
| example rendered (env_base="zsh", SHELL="/bin/zsh") | `pi-bridge: completions use zsh (from $SHELL) but pi may execute commands in bash. For guaranteed consistency set PI_NVIM_SHELL=/bin/zsh (or pi's shellPath). :help pi-bridge-shell` |

### Trigger (CONFIRMED)

The notice fires iff ALL hold:
1. `(cfg.prefer or "pi") == "pi"` — prefer is "pi" (or nil/unset)
2. `source == "$SHELL"` — the descriptor did NOT advertise a shell (so `resolve_shell`
   fell through to `$SHELL`)
3. `basename(vim.env.SHELL)` ∈ `{ "zsh", "fish" }`
4. `vim.fn.executable(env_base) == 1` — the richer shell is on PATH

The two notices (Issue 1 / Issue 2) are structurally mutually exclusive in practice:
- Issue 1 (`shell-mismatch`) requires `resolved == bash`.
- Issue 2 (`shell-consistency`) requires `resolved == $SHELL` (i.e. zsh/fish) — they
  never both fire for the same `(prefer, descriptor)` combo.

---

## 4. HEALTH (`health.lua` + Issue 5) — `:checkhealth pi-bridge`

File: `lua/pi-bridge/health.lua`, Section 5 "pi-bridge shell completion" (starts ~line 138).

### Resolved-shell line — EXACT format string

File: `lua/pi-bridge/health.lua:172-174`:

```lua
        health.info(
          ("resolved shell: %s (source: %s, prefer: %s)"):format(tostring(resolved), tostring(source), tostring(prefer))
        )
```

So `:checkhealth pi-bridge` prints (example):
```
resolved shell: /bin/zsh (source: $SHELL, prefer: pi)
```
The three values come from (health.lua:163-169):
```lua
local resolved, source = nil, nil
if shell_mod and type(shell_mod.resolve_shell) == "function" then
  pcall(function() resolved, source = shell_mod.resolve_shell(prefer) end)
end
```
**CONFIRMED**: `source` is the REAL `shellSource` returned by `resolve_shell` (which since
Issue 5 propagates `descriptor.shellSource`). The line does NOT hard-code `"pi"`.

### Fields health reads (from `M.status()` — `shell.lua:307-322`)

```lua
return {
  shell = state.shell,
  driver_basename = base,
  proc_alive = state.proc ~= nil,
  inflight = state.inflight,
  failed = state.failed,
  parse_failures = state.parse_failures,
}
```
The Section 5 branches on these:
- `st.failed` → warn "daemon failed — shell completion is disabled for `!`/`!!` lines this session."
  (advice: `:messages` for the `shell-degrade` notice; `:help pi-bridge-shell`)
  plus an `info` line `consecutive parse failures: N (threshold M)` when `st.parse_failures > 0`
  (threshold = `cfg.max_parse_failures or 5`).
- `st.proc_alive` → `health.ok(("daemon ready (%s)"):format(...))`
- else → `health.info("daemon not spawned yet (lazy — starts on the first `!`/`!!`; or enable shell.warm_on_enter).")`

Health ALSO reads, in Section 5:
- `cfg.enabled`, `cfg.prefer`, `cfg.warm_on_enter`, `cfg.drivers[base]`, `cfg.max_parse_failures`
- `pick_driver(resolved)` to distinguish "disabled" vs "no driver"
- `notify_mod.did_notify(cat)` for categories `{"shell-degrade", "shell-mismatch", "shell-active"}`
- `bridge.get_shell_info()` advertised shell → advisory cross-check note when `advertised ~= resolved`

### Driver tier line

health.lua:179-182:
```lua
local tier = SHELL_TIER[base] or "unknown"
health.info(("driver: %s (%s)"):format(base, tier))
```
where `SHELL_TIER = { fish = "tier-1", zsh = "tier-1", bash = "tier-2" }` (health.lua:36).

---

## 5. CWD RE-TRACKING (Issue 4) — `complete_current`

File: `lua/pi-bridge/shell.lua:1027-1090` (`M.complete_current`), step 6.5 at lines 1057-1070:

```lua
	-- (6.5) CWD RE-TRACKING (Issue 4 / PRD §17.5.2 "cwd tracking")
	if state.proc and state.driver and type(state.driver.cd) == "function" then
		local cur_cwd = M.session_cwd()
		if type(cur_cwd) == "string" and cur_cwd ~= state.cwd then
			pcall(state.driver.cd, cur_cwd)
			state.cwd = cur_cwd
		end
	end
```

### Preconditions (CONFIRMED)

- `state.proc` is non-nil — the daemon was already spawned (the `M.ensure` in `M.request`
  populates `state.proc` on first spawn; this block runs BEFORE `M.request` so on the very
  first request `state.proc` is nil → the block is skipped, and `M.ensure` seeds
  `state.cwd = opts.cwd` = `session_cwd()` at spawn).
- `state.driver.cd` is a function — `pick_driver` only requires `.start`; a custom driver
  may lack `cd`.
- `cur_cwd ~= state.cwd` — only fires on an actual cwd change.

### Behavior

On a mid-session cwd change it `pcall(state.driver.cd, cur_cwd)` (writes a `__PICD__\t<path>\n`
frame to `state.driver`'s cached stdin, which is the SAME `uv_pipe_t` as `state.stdin`) and
optimistically updates `state.cwd`. Submitted SYNCHRONOUSLY before `M.request` so the
`__PICD__` frame is queued ahead of the `__PIREQ__` frame on the same pipe (libuv FIFO
write order).

### New test seam `M._test_cwd()`

File: `lua/pi-bridge/shell.lua:1144-1146`:

```lua
function M._test_cwd()
	return state.cwd
end
```
Reads `state.cwd` (the spawn/tracked cwd) — used to assert complete_current's re-cd fires.

### Driver `cd()` semantics (per shell)

- **fish** (`fish.lua`): REAL `builtin cd` (script's `__PICD__` branch → `builtin cd "$p"`).
- **bash** (`bash.lua`): REAL `builtin cd` (script's `__PICD__*` branch → `builtin cd "$p"`).
- **zsh** (`zsh.lua`): SENT but EATEN (the OUTER case branch is `(__PICD*) ;;` — a literal
  no-op). v1 path completions stay relative to the spawn cwd for the session
  (documented limitation). The Lua `M.cd` write is harmless (a no-op write).

---

## 6. GRACEFUL DEGRADE (Issue 6) — driver `DAEMON_SCRIPT` guards

All three drivers guard the extracted command word BEFORE invoking the completion engine.
Empty cmd (→ all-commands FLOOD) OR a cmd ending in an ODD run of backslashes (a dangling
backslash that would panic/abort) emits a clean EMPTY result `{"items":[],"prefix":""}`.
An EVEN run (a valid escaped backslash) is kept.

### fish.lua — guard in `__pi_handle` (the `DAEMON_SCRIPT` long-string)

File: `lua/pi-bridge/shell/fish.lua`, inside the `DAEMON_SCRIPT` `[[ ... ]]` block.
The guard (after `set cmd $m[2]` extraction):

```fish
    set -l malformed 0
    if test -z "$cmd"
        set malformed 1
    else
        set -l n (__pi_trailing_bs "$cmd")
        if test (math $n % 2) -eq 1
            set malformed 1
        end
    end
    if test $malformed -eq 1
        echo __PIRESP_START__
        printf '{"items":[],"prefix":""}\n'
        echo __PIRESP_END__
        return
    end
```
`__pi_trailing_bs` (a regex-free char-chop helper, defined earlier in the same script)
counts trailing backslashes; odd count → malformed.

### zsh.lua — guard in `OUTER_SCRIPT`, `(__PIREQ__*)` case branch

File: `lua/pi-bridge/shell/zsh.lua`, inside the `OUTER_SCRIPT` `[=[ ... ]=]` block:

```zsh
            local _tail="${cmd##*[^\\]}"
            echo __PIRESP_START__
            local _items=""
            if [[ -n "$cmd" ]] && (( ${#_tail} % 2 == 0 )); then
                ... # completion via zpty
            fi
            printf '{"items":[%s],"prefix":""}\n' "$_items"
            echo __PIRESP_END__
```
When `cmd` is empty OR `_tail` (the trailing backslash run) has odd length, `_items`
stays `""` → `{"items":[],"prefix":""}` is emitted (the `__PIRESP_START__`/`__PIRESP_END__`
wrappers are ALWAYS emitted).

### bash.lua — guard in `DAEMON_SCRIPT`, `__pi_handle` `(__PIREQ__*)` branch

File: `lua/pi-bridge/shell/bash.lua`, inside the `DAEMON_SCRIPT` `[=[ ... ]=]` block:

```bash
            local _tail="${line##*[^\\]}"
            echo __PIRESP_START__
            if [[ -z "$line" ]] || (( ${#_tail} % 2 )); then
                printf '{"items":[],"prefix":""}\n'
            else
                ... # completion dispatch in a subshell
            fi
            echo __PIRESP_END__
```
Empty `line` OR odd trailing-backslash count → `{"items":[],"prefix":""}`.

### Summary: which file guards what

| file | guarded variable | empty check | odd-trailing-backslash check | emits on guard |
|------|------------------|-------------|------------------------------|----------------|
| `shell/fish.lua` | `$cmd` | `test -z "$cmd"` (via `__pi_trailing_bs`) | `__pi_trailing_bs` count `% 2 == 1` | `{"items":[],"prefix":""}` |
| `shell/zsh.lua` | `$cmd` | `[[ -n "$cmd" ]]` (negated) | `${#_tail} % 2 == 0` (negated) | `{"items":[],"prefix":""}` |
| `shell/bash.lua` | `$line` | `[[ -z "$line" ]]` | `(( ${#_tail} % 2 ))` | `{"items":[],"prefix":""}` |

All three ALWAYS emit `__PIRESP_START__` and `__PIRESP_END__` around the (possibly empty)
payload, so shell.lua `_feed`'s sentinel pairing never wedges.

---

## 7. ISSUE 3 CONFIRMATION — completion.lua plain-typing close branch

File: `lua/pi-bridge/completion.lua:542-546`

```lua
  if not ctx then
    dbg(string.format("[do_refresh] ctx=nil (plain) line1=%q col=%s — close, no request", tostring((lines or {})[1] or ""), tostring(byte_col)))
    if type(M.on_results) == "function" then pcall(M.on_results, buf, {}, "", nil) end -- S5: explicit nil context (plain typing)
    return
  end
```

### Verdict: NO — the supersession-race fix is NOT present in this branch.

This branch:
- does **NOT** bump `state.gen` (no `state.gen = state.gen + 1`).
- does **NOT** cancel an in-flight request (no `bridge.cancel(state.inflight_id)` call,
  no `state.inflight_id = nil`).

It only calls `M.on_results(buf, {}, "", nil)` (the S5 menu-close seam with explicit
`nil` context) and returns. Contrast with the active-request path just below
(completion.lua:574-585) which DOES do both:
```lua
  if state.inflight_id and type(bridge.cancel) == "function" then
    pcall(bridge.cancel, state.inflight_id)
  end
  state.inflight_id = nil
  ...
  state.gen = state.gen + 1
  local gen = state.gen
```
So a plain-typing keystroke (after a `slash`/`path` request was in flight) does NOT
supersede it via this branch. The gen-guard inside the in-flight cb closure would still
drop a stale result IF something else bumped `state.gen`, but this branch alone does not.

---

## Architecture summary (how the pieces connect)

```
ensure() [shell.lua:393]
  ├─ resolve_shell(cfg.prefer or "pi") → (resolved, source)   [§17.4]
  │     └─ descriptor_shell() → (path, shellSource)           [Issue 5]
  ├─ (Issue 1) shell-mismatch notify.once   [gate: prefer=="pi", resolved==bash, $SHELL=zsh/fish on PATH]
  ├─ (Issue 2) shell-consistency notify.once [gate: prefer=="pi", source=="$SHELL", $SHELL=zsh/fish on PATH]
  ├─ pick_driver(resolved) → driver|nil     [§17.4.2; config.shell.drivers.<base>==false → nil]
  ├─ driver.start({shell, cwd=session_cwd(), startup_timeout_ms}, cb)  [driver owns spawn+timer]
  │     └─ stderr ready-marker __PIREADY__\n → on_ready(nil, proc, stdin, stdout)
  └─ stdout:read_start → _feed / _reset      [§17.5.1 framing; §17.12 EOF→failed]

complete_current(buf, cb) [shell.lua:1027]
  ├─ read line1 + cursor, strip bangs, byte-domain triple
  ├─ (Issue 4) if state.proc && driver.cd && cur_cwd~=state.cwd → driver.cd(cur_cwd); state.cwd=cur_cwd
  └─ M.request(line, cursor, after, wrapper_cb)
        └─ ensure() → bump gen → encode → arm timer → stdin:write("__PIREQ__\t{json}\n")

_feed(chunk) [shell.lua: ~530]
  ├─ append + drain __PIRESP_START__\n … __PIRESP_END__\n pairs
  ├─ pcall(vim.json.decode) → {items, prefix}
  ├─ (Issue 6 handled INSIDE each driver's script — _feed only decodes)
  └─ pending_cb(items, prefix)  [gen-guarded, one-shot]

health.check() [health.lua M.check]
  └─ Section 5 "pi-bridge shell completion": resolve_shell(prefer) →
       "resolved shell: <path> (source: <source>, prefer: <prefer>)"
     + driver tier + pick_driver + status() + did_notify + config knobs + advisory cross-check
```

## Start here
Open `lua/pi-bridge/shell.lua` — `M.resolve_shell` (line 196), `M.ensure` (line 393,
esp. the two notify blocks at 432-467), and `M.complete_current` (line 1027, step 6.5
cwd re-track at 1057). For health open `lua/pi-bridge/health.lua` Section 5 (~line 140).

---

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "All 7 topics answered with exact file:line anchors and verbatim quoted strings. resolve_shell branch table (shell.lua:196-226); mismatch category 'shell-mismatch' + message (shell.lua:432-448) gated by (cfg.prefer or 'pi')=='pi'; consistency category 'shell-consistency' (DISTINCT) + message (shell.lua:449-467); health format 'resolved shell: %s (source: %s, prefer: %s)' (health.lua:172-174); complete_current cwd re-track (shell.lua:1057-1070) + _test_cwd seam (1144-1146); graceful-degrade guards quoted per driver (fish/zsh/bash DAEMON_SCRIPT); Issue 3 = NO gen bump / NO cancel inflight in completion.lua:542-546."
    }
  ],
  "changedFiles": [],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "read shell.lua, health.lua, shell/fish.lua, shell/zsh.lua, shell/bash.lua, completion.lua (grep + read)",
      "result": "passed",
      "summary": "Read-only inspection of all 6 source files; no commands executed, no mutations. All quoted strings verified verbatim against file contents."
    }
  ],
  "validationOutput": [
    "shell.lua resolve_shell (196-226): prefer branch table + descriptor_shell 2-return (147-172) + 'or \"pi\"' propagation at line 213 — CONFIRMED",
    "shell-mismatch (432-448): category 'shell-mismatch', gate if (cfg.prefer or 'pi')=='pi' — CONFIRMED inert under prefer='bash'/explicit path",
    "shell-consistency (449-467): category 'shell-consistency' DISTINCT from 'shell-mismatch'; trigger prefer=='pi' AND source=='$SHELL' AND basename($SHELL) in {zsh,fish} AND executable==1 — CONFIRMED",
    "health.lua (172-174): format 'resolved shell: %s (source: %s, prefer: %s)' reads resolve_shell(prefer) — shows real shellSource — CONFIRMED",
    "complete_current (1057-1070): cwd re-track requires state.proc + state.driver.cd is fn + cur_cwd~=state.cwd; _test_cwd seam at 1144-1146 — CONFIRMED",
    "fish/zsh/bash DAEMON_SCRIPT graceful-degrade guards: empty OR odd trailing backslash → {\"items\":[],\"prefix\":\"\"} — CONFIRMED in all three",
    "completion.lua:542-546: if not ctx then — NO state.gen bump, NO bridge.cancel, NO inflight_id=nil — supersession-race fix NOT present in this branch"
  ],
  "residualRisks": [
    "completion.lua plain-typing branch (Issue 3) does NOT bump state.gen / cancel inflight — if the documentation sweep claims it does, that is inaccurate; the active-request path (completion.lua:574-585) is the ONLY place supersession is applied.",
    "zsh.lua cd() is a SENT-but-EATEN no-op (OUTER_SCRIPT case branch '(__PICD*) ;;') — documented v1 limitation; path completions stay relative to spawn cwd for zsh. fish/bash cd() are REAL.",
    "All three graceful-degrade guards use a crude non-JSON '.line' extraction; a line containing a literal '\"' still leaves a dangling backslash that the odd-count check catches, but a fully-malformed JSON payload that does NOT end in a backslash is NOT guarded (relies on the completion engine tolerating it)."
  ],
  "noStagedFiles": true,
  "diffSummary": "No diff — read-only scouting task; no files modified.",
  "reviewFindings": [
    "no blockers: this is a read-only behavior-extraction report; all findings are quoted from current source."
  ],
  "manualNotes": "Output written to the authoritative runtime path. The report is structured 1:1 against the 7 task topics with exact quoted strings + file:line anchors, suitable to feed a documentation sweep directly."
}
```