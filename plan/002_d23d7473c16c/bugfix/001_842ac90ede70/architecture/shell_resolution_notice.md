# Shell Resolution & Notice — Issues 1, 2, 5

## The Resolution Chain (§17.4)

`M.resolve_shell(prefer)` (shell.lua:168–189) returns `(shell_path, source)`:

| prefer | Resolution | source label |
|--------|-----------|--------------|
| `"pi"` (default) | descriptor.shell → fall through to $SHELL → /bin/bash | `"pi"` (BUG: hard-coded) |
| `"shell"` | $SHELL → /bin/bash | `"$SHELL"` / `"default"` |
| `"bash"` | /bin/bash | `"default"` |
| `"/abs/path"` | that path verbatim | `"config"` |

`descriptor_shell()` (shell.lua:135–156) is the `"pi"` first hop:
```lua
local function descriptor_shell()
    local br = pi.bridge
    if br and br.get_shell_info then
        local si = br.get_shell_info()
        if si and si.shell ~= "" then return si.shell end   -- ⚠ shellSource IGNORED
    end
    if desc and desc.shell ~= "" then return desc.shell end  -- ⚠ shellSource IGNORED
    return nil
end
```

**Bug (Issue 5):** `descriptor_shell()` returns ONLY the path. `resolve_shell` line 177
hard-codes `"pi"` as the source: `if ds then return ds, "pi" end`. The descriptor's real
`shellSource` (`"pi"` | `"$SHELL"` | `"default"`) is discarded. So `health.lua` reports
`source: pi` even when the descriptor fell back to `$SHELL`.

### The Extension Side (pi-nvim-bridge.ts)

`resolveShell()` (ts:451–457):
```ts
export function resolveShell(): ShellInfo {
    const explicit = process.env.PI_NVIM_SHELL;
    if (explicit) return { shell: explicit, shellSource: "pi", shellPath: explicit };
    const sh = process.env.SHELL;
    if (sh) return { shell: sh, shellSource: "$SHELL" };
    return { shell: "/bin/bash", shellSource: "default" };
}
```
**Constraint (§17.10.2):** `settingsManager`/`getShellConfig()` are NOT on
`ExtensionContext` (confirmed against `types.d.ts:208-244`). The extension CANNOT read
pi's real `shellPath`. So `shellSource:"pi"` only happens when the user manually exports
`PI_NVIM_SHELL`. For a default zsh user who hasn't, `shellSource == "$SHELL"`.

---

## Issue 5 Fix: Expose Real shellSource

**Approach:** Make `descriptor_shell()` return `(path, source)` and have `resolve_shell`
propagate it.

```lua
local function descriptor_shell()
    local br = pi.bridge
    if br and br.get_shell_info then
        local si = br.get_shell_info()
        if si and si.shell ~= "" then
            return si.shell, si.shellSource   -- ← return source too
        end
    end
    local desc = pi.descriptor
    if desc and desc.shell ~= "" then
        return desc.shell, desc.shellSource   -- ← return source too
    end
    return nil
end

function M.resolve_shell(prefer)
    ...
    if prefer == "pi" then
        local ds, dsrc = descriptor_shell()
        if ds then return ds, dsrc or "pi" end  -- ← real source, default "pi"
    end
    ...
end
```

**Why safe:** `descriptor_shell()` is module-local, only called by `resolve_shell`.
`ensure()` uses only the first return value (resolved path). `health.lua:255` reads both
return values — it gets the accurate source automatically.

**Test:** `tests/shell_notices_spec.lua` pattern — inject `pi.bridge` with
`get_shell_info` returning `{shell="/bin/zsh", shellSource="$SHELL"}`, call
`shell.resolve_shell("pi")`, assert second return == `"$SHELL"`. Add a parallel
health.lua check (set descriptor, run health, assert source label).

---

## Issue 1 Fix: Gate Notice on prefer=="pi"

**Bug:** The notice block (shell.lua:384–396) calls `M.mismatch_target(resolved, vim.env.SHELL)`
unconditionally. Under `prefer="bash"`, resolved is `/bin/bash`, and if `$SHELL` is zsh,
the notice fires — telling the user to "set shellPath to /usr/bin/zsh" even though they
deliberately chose bash.

**Fix:** Gate the notice on `(cfg.prefer or "pi") == "pi"` at the call site in `ensure()`.
Keep `mismatch_target` pure (no prefer arg).

```lua
-- shell.lua ~384, inside ensure():
if (cfg.prefer or "pi") == "pi" then
    pcall(function()
        local richer = M.mismatch_target(resolved, vim.env.SHELL)
        if richer then
            local ok, ex = pcall(vim.fn.executable, richer)
            if ok and ex == 1 then
                require("pi-bridge.notify").once("shell-mismatch", ...)
            end
        end
    end)
end
```

**Test:** `tests/shell_notices_spec.lua` — add a case: `pi.config.shell.prefer = "bash"`,
`$SHELL=/bin/zsh`, fake bash driver injected → assert `notify.did_notify("shell-mismatch")`
is FALSE. Also test `prefer="/usr/bin/bash"` (explicit path) → no notice.

**Important:** This fix depends on T1 landing first ONLY if we want the notice block to
also use `source` for Issue 2 detection. T1 and T2 touch DIFFERENT code regions
(resolve_shell:168–189 vs notice block:384–396) so they can be developed in parallel, but
T3 (Issue 2) depends on T1 for the `source == "$SHELL"` signal.

---

## Issue 2 Fix: Detect & Warn on prefer:"pi" Consistency Footgun

**Bug:** For a default zsh user (`$SHELL=/bin/zsh`, no `PI_NVIM_SHELL`):
- The extension sets `descriptor.shell="/bin/zsh", descriptor.shellSource="$SHELL"`.
- `resolve_shell("pi")` returns `("/bin/zsh", ...)` — zsh, NOT bash.
- pi still EXECUTES `!`/`!!` in bash (pi's default), so completions (zsh) ≠ execution (bash).
- The §17.4.3 mismatch notice NEVER fires because `mismatch_target` checks
  `basename(resolved)=="bash"` — but resolved is zsh → returns nil.

**Fix:** Add a NEW detection condition in `ensure()` for the footgun case:
`prefer=="pi"` AND `source=="$SHELL"` AND `basename($SHELL)∈{zsh,fish}`.

This is a DIFFERENT condition from Issue 1's mismatch_target (which checks
resolved==bash). The footgun is resolved==zsh (from $SHELL fallback), while the existing
mismatch is resolved==bash. They're complementary.

```lua
-- After the existing mismatch_target notice block, add:
if (cfg.prefer or "pi") == "pi" and source == "$SHELL" then
    local env_base = basename(vim.env.SHELL or "")
    if env_base == "zsh" or env_base == "fish" then
        local ok, ex = pcall(vim.fn.executable, env_base)
        if ok and ex == 1 then
            require("pi-bridge.notify").once("shell-consistency", vim.log.levels.WARN,
                "pi-bridge: completions use " .. env_base
                .. " (from $SHELL) but pi may execute commands in bash. "
                .. "For guaranteed consistency, set PI_NVIM_SHELL or pi's shellPath. "
                .. ":help pi-bridge-shell")
        end
    end
end
```

**Requires:** `source` from `resolve_shell` — which T1 fixes to return the real
`descriptor.shellSource`. Without T1, `source` is always `"pi"` for the descriptor branch,
and the `source == "$SHELL"` check would never match.

**Notice category:** Use `"shell-consistency"` (distinct from `"shell-mismatch"`) so the
dedup set doesn't conflate the two conditions.

**Docs (Mode A):** Update `doc/pi-bridge-shell.txt` §3 "THE MISMATCH" (lines 74–119):
- Add a paragraph explaining that under the DEFAULT config (`prefer="pi"`, `$SHELL` is
  zsh/fish, `PI_NVIM_SHELL` unset), completions use `$SHELL` but pi executes in bash —
  they may NOT be consistent.
- Document the `PI_NVIM_SHELL` env var as the opt-in fix.
- Add a forward-contract note: once pi exposes `ctx.getShellConfig()` (PRD §17.17), the
  extension will advertise the real execution shell, making `prefer:"pi"` correct by
  default. Until then, set `PI_NVIM_SHELL`.

**Upstream constraint:** The extension CANNOT read pi's `shellPath` (§17.10.2 —
`getShellConfig` not on `ExtensionContext`). This fix is a DETECTION + DOCUMENTATION
mitigation, not a correctness fix. The real fix requires the upstream API.