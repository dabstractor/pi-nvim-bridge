# Research Notes — P1.M1.T1S1 (Issue 5: expose real descriptor.shellSource)

Surgical Lua fix in `lua/pi-bridge/shell.lua`. Goal: `descriptor_shell()` returns
`(path, source)`; `resolve_shell` propagates the real `descriptor.shellSource`
instead of a hard-coded `"pi"`. health.lua auto-benefits (reads both values).

## Verified current state (exact content + line numbers)

### `descriptor_shell()` — shell.lua:138-156 (returns ONLY path)
```lua
local function descriptor_shell()
	local pi = require("pi-bridge")
	local br = pi.bridge
	if br and type(br.get_shell_info) == "function" then
		local si = br.get_shell_info()
		if type(si) == "table" and type(si.shell) == "string" and si.shell ~= "" then
			return si.shell                       -- L146 ← ignores si.shellSource
		end
	end
	local desc = pi.descriptor
	if type(desc) == "table" and type(desc.shell) == "string" and desc.shell ~= "" then
		return desc.shell                        -- L151 ← ignores desc.shellSource
	end
	return nil
end
```

### `resolve_shell` pi-branch — shell.lua:175-177
```lua
if prefer == "pi" then
	local ds = descriptor_shell()                -- L176
	if ds then return ds, "pi" end               -- L177 ← HARD-CODED "pi"
	-- descriptor omitted shell → fall through to $SHELL → /bin/bash
end
```

### The fix (from architecture/shell_resolution_notice.md §"Issue 5 Fix")
- L146: `return si.shell` → `return si.shell, si.shellSource`
- L151: `return desc.shell` → `return desc.shell, desc.shellSource`
- L176: `local ds = descriptor_shell()` → `local ds, dsrc = descriptor_shell()`
- L177: `if ds then return ds, "pi" end` → `if ds then return ds, dsrc or "pi" end`

The `or "pi"` fallback is REQUIRED — see "existing tests" below.

## Verified: descriptor_shell's ONLY caller is resolve_shell
`grep -rn descriptor_shell lua/ tests/` → def at shell.lua:138, single call at
shell.lua:176. Changing 1→2 return values is SAFE (no other consumer).
`ensure()` (the runtime caller of resolve_shell) uses ONLY the first value
(the resolved path); the source is read by health.lua only.

## Verified: health.lua consumer ALREADY reads both return values — NO change needed
`health.lua:254-256`:
```lua
local resolved, source = nil, nil
if shell_mod and type(shell_mod.resolve_shell) == "function" then
	pcall(function() resolved, source = shell_mod.resolve_shell(prefer) end)
```
After the fix, `source` = real `descriptor.shellSource` automatically. health.lua
formats it at L260 (`"resolved shell: %s (source: %s ..."`). No health.lua edit.

## Verified: bridge.get_shell_info() returns {shell, shellSource, shellPath}
`bridge.lua:902-915`, returns table with `shell` (L909), `shellSource` (L910),
`shellPath` (L911). The `---@field shellSource` is typed `("pi"|"$SHELL"|"default")?`
(bridge.lua:188; init.lua:135). So `si.shellSource` is the value to propagate.

## CRITICAL FINDING — existing tests assert src=="pi"; the `or "pi"` fallback preserves them
`descriptor_shell()` callers' tests that set a descriptor shell WITHOUT shellSource
expect `source == "pi"` today. After the fix, `shellSource` is `nil` in those fakes
→ `dsrc or "pi"` evaluates to `"pi"` → tests still pass. DO NOT drop the `or "pi"`.

Affected existing tests (must stay green):
- `tests/shell_spec.lua:54-59` — `fake_bridge("/bin/zsh")` (returns `{shell="/bin/zsh"}`,
  no shellSource) → asserts `src == "pi"`. After fix: `nil or "pi"` = "pi". ✓
- `tests/shell_smoke.lua` case 1 (L74-82) — same fake_bridge, asserts `src == "pi"`. ✓
- `tests/shell_smoke.lua` case 4 (L104-111) — `pi.descriptor = { shell = ".../fish" }`
  (no shellSource) → asserts `src == "pi"`. After fix: `desc.shellSource` nil → "pi". ✓

## Best test home: tests/shell_spec.lua (NOT shell_notices_spec.lua)
The contract mentions shell_notices_spec.lua's pattern, BUT the natural home is
`tests/shell_spec.lua`:
- `describe("pi-bridge.shell resolve_shell (P2.M1.T2.S2)")` at shell_spec.lua:35
- Its own `fake_bridge(shell_path, server_cwd)` at shell_spec.lua:22-33
- Its own before_each/after_each save/restore (shell_spec.lua:36-52)
- The existing "source 'pi'" case at L54-59 is the EXACT sibling for the new
  "$SHELL"-source case.

shell_spec.lua's fake_bridge currently returns `{ shell = shell_path }`. For the
new case, either (a) extend fake_bridge to accept shell_source, or (b) set
`pi.bridge` inline with a get_shell_info returning shellSource. test_conventions.md
shows the extend pattern: `return { shell = shell_path, shellSource = shell_source or "pi" }`.

## New test cases to add (shell_spec.lua, in the resolve_shell describe, after L59)
1. `pi.bridge = { get_shell_info = function() return { shell="/bin/zsh", shellSource="$SHELL" } end }`
   → `shell.resolve_shell("pi")` → assert `src == "$SHELL"`.
2. (keep/confirm) existing L54 case with no shellSource → `src == "pi"` (fallback).
3. (optional symmetry) descriptor-source: `pi.descriptor = { shell="/bin/zsh", shellSource="default" }`
   with bridge==nil → assert `src == "default"`.

## Validation commands (verified-canonical from AGENTS.md / test_conventions.md)
Plenary spec:
```
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'
```
Smoke (plenary-free, the resolve_shell matrix):
```
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_smoke.lua" +qa; echo "exit=$?"
```
Also re-run the CONSUMER spec (health reads source) + notices spec (unaffected, but cheap):
```
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/health_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_notices_spec.lua")'
```
All must be green. No TS change → `npm run typecheck` unaffected (skip or run as no-op sanity).

## Mode A doc-comment update (shell.lua:157-166)
The resolve_shell doc-comment L161 says: `source aligns with descriptor.shellSource's
union ("pi"|"$SHELL"|"default")`. This is CURRENTLY VIOLATED (hard-coded "pi") and
BECOMES ACCURATE after the fix. Update the comment to note the pi-branch now
PROPAGATES descriptor.shellSource (with an `or "pi"` fallback for descriptors that
carry a shell but no shellSource). No user-facing/config/API surface change.

## Scope discipline
This is Issue 5 ONLY. Do NOT touch:
- the §17.4.3 mismatch notice block (Issue 1 — P1.M1.T2.S1)
- the prefer:"pi" consistency footgun detection (Issue 2 — P1.M1.T3.S1, which
  DEPENDS on this fix's `source == "$SHELL"` signal)
- supersession race (Issue 3), cwd re-tracking (Issue 4), quoted-command flood (Issue 6)
Those are separate tasks; Issue 2 explicitly consumes this fix's output.