# Completion Supersession & Drivers — Issues 3, 4, 6

## Issue 3: Supersession Race (ctx==nil branch doesn't bump gen)

**File:** `lua/pi-bridge/completion.lua`
**Bug location:** `do_refresh(buf)` lines 543–548 (the `ctx == nil` plain-typing branch)

### The Race

`do_refresh` classifies the buffer context via `completion_context()` →
`"shell"` | `"slash"` | `"path"` | `nil`. Each branch handles supersession differently:

| Branch | Bumps gen? | Cancels inflight? | Issue? |
|--------|-----------|-------------------|--------|
| `ctx == "shell"` (via `do_shell_fetch`) | ✅ line 419 | ✅ bridge only | No |
| `ctx == "slash"/"path"` | ✅ line 568 | ✅ | No |
| `ctx == nil` (plain typing) | ❌ **NO** | ❌ **NO** | **BUG** |

The nil branch (543–548) closes the menu via `on_results(buf, {}, "", nil)` and returns
WITHOUT bumping `state.gen`. So a late shell response (whose cb captured `gen = N`) finds
`state.gen == N` still true → the gen guard passes → `vim.schedule(on_results(buf, items, prefix, "shell"))`
fires → **menu re-opens** for a buffer that no longer starts with `!`.

### Reproduction (deterministic)

1. Buffer `"!git c"`, cursor after `c` → `ctx == "shell"` → `do_shell_fetch` (gen=1, cb deferred).
2. Buffer → `"git c"` (deleted `!`) → `ctx == nil` → menu closes via `on_results({}, "", nil)`
   (gen NOT bumped, still 1).
3. Fire deferred shell response `cb(nil, {checkout}, "c")` → gen(1)==state.gen(1) → guard passes
   → `menu.on_results(buf, {checkout}, "c", "shell")` → **menu re-opens**.

### Fix

Bump `state.gen` + cancel any in-flight bridge request in the nil branch, BEFORE closing:

```lua
-- completion.lua ~543, the `if not ctx then` block:
if not ctx then
    dbg(...)
    -- SUPERSEDE layer 1: cancel a pending BRIDGE inflight (shell has no cancel wire).
    local b = require("pi-bridge").bridge
    if state.inflight_id and b and type(b.cancel) == "function" then
        pcall(b.cancel, state.inflight_id)
    end
    state.inflight_id = nil
    -- SUPERSEDE layer 2: gen-guard — drop a late shell/bridge cb (the ! → delete-! race).
    state.gen = state.gen + 1
    if type(M.on_results) == "function" then
        pcall(M.on_results, buf, {}, "", nil)
    end
    return
end
```

**Why layer 2 (gen bump) is essential:** Shell requests have NO cancel wire (shell.lua
has no cancel method — it's a local subprocess that supersedes internally via its own gen
+ overwriting pending_cb). The completion.lua gen-guard is the SOLE protection against a
late shell response. Without the bump, the shell cb's captured gen matches → it fires.

**Test pattern:** Use the completion_spec.lua fake-bridge + `on_results` seam counter:
```lua
local seam = 0
completion.on_results = function() seam = seam + 1 end
-- refresh with "!git c" → do_shell_fetch (gen=1, capture stale_cb)
-- edit buffer to "git c" → refresh → ctx==nil → close (gen bumped to 2)
-- fire stale_cb → gen(1) != state.gen(2) → dropped
assert.are.equals(1, seam, "stale shell cb must NOT re-fire on_results")
```

---

## Issue 4: Daemon cwd Re-Tracking — Dead Code

**Files:** `lua/pi-bridge/shell.lua` + `lua/pi-bridge/shell/{fish,zsh,bash}.lua`

### Current State

- `M.session_cwd()` (shell.lua:259–271) reads `bridge.server_info.cwd` → `descriptor.cwd`.
  Called ONCE at spawn time (shell.lua:419, `opts.cwd`). Cached into `state.cwd` (line 443).
- All 3 drivers define `M.cd(path)` that writes `__PICD__\t<path>\n` to `last_stdin`.
- **NO caller of `driver.cd()` anywhere** (grep -rn '\.cd(' across lua/ ftplugin/ plugin/ →
  only the driver definitions + tests).
- The daemon scripts:
  - **fish**: honors `__PICD__` with `builtin cd` (functional).
  - **bash**: honors `__PICD__` with `builtin cd` (functional).
  - **zsh**: matches `__PICD*` in OUTER_SCRIPT but does NOTHING (empty case body, zsh.lua:219).
    Doc-comment says "ADVISORY / a documented no-op for v1."

### Fix: Wire Re-cd in `complete_current`

`M.complete_current(buf, cb)` (shell.lua:984) is the per-keystroke entry point called by
`completion.lua`'s `do_shell_fetch`. Add cwd re-tracking BEFORE `M.request`:

```lua
function M.complete_current(buf, cb)
    ...
    -- CWD RE-TRACKING (§17.5.2): re-cd the daemon if the session cwd changed since spawn.
    local cwd_now = M.session_cwd()
    if cwd_now and state.cwd and cwd_now ~= state.cwd
       and state.driver and type(state.driver.cd) == "function" then
        pcall(state.driver.cd, cwd_now)
        state.cwd = cwd_now  -- update cache so we don't re-cd every keystroke
    end
    ...
    M.request(line, cin, after, wrapper_cb)
end
```

**Why safe:** `complete_current` calls `M.request` AFTER the cd call. Both write to the
daemon's stdin pipe sequentially → the daemon processes the `__PICD__` frame BEFORE the
`__PIREQ__` frame. Frame ordering is guaranteed by sequential pipe writes.

**zsh limitation:** zsh's daemon script swallows `__PICD__` (no-op). So zsh completions
won't track cwd changes. This is a known limitation of the zsh pty architecture (the
INNER's Enter is bound to a noop widget). The zsh driver doc-comment already hedges this.

**Docs (Mode A):** Update the `M.cd` doc-comments in all 3 drivers to accurately reflect
post-wiring status:
- fish.lua: "cd is WIRED — called by complete_current when session cwd changes."
- bash.lua: same.
- zsh.lua: "cd is WIRED but ADVISORY — the daemon script matches __PICD__ but the inner
  zsh doesn't cd. Known limitation for v1."

**Test:** Use the shell_request_spec.lua fake-driver pattern. Inject a fake driver with
a `cd` spy. Set `bridge.server_info.cwd = "/old"`. Call `ensure` (spawns daemon,
`state.cwd = "/old"`). Change `bridge.server_info.cwd = "/new"`. Call `complete_current`.
Assert `fake_driver.cd` was called with `"/new"` and `state.cwd` updated.

---

## Issue 6: Literal `"` Floods All Commands

**Files:** `lua/pi-bridge/shell/{fish,zsh,bash}.lua` (embedded DAEMON_SCRIPT / OUTER_SCRIPT)

### The Bug

Each driver extracts the `.line` field from the JSON request using a crude regex/param-sub
that stops at the first `"`:

| Driver | Extraction | Location |
|--------|-----------|----------|
| fish | `string match -r '"line":"([^"]*)"'` | fish.lua:121 |
| zsh | `${${payload#*\"line\":\"}%%\"*}` | zsh.lua:194 |
| bash | `${payload#*\"line\":\"}` then `${line%%\"*}` | bash.lua:194 |

A command containing a literal `"` (e.g. `!echo "feat` or `!git commit -m "wip`) resolves
`cmd` to empty/truncated. An empty `cmd` makes the completion engine return ALL commands:
- fish: `complete -C ""` → all commands
- zsh: zpty sends empty line → full command completion
- bash: `compgen -abck -- ""` → all commands/aliases/builtins

### Fix: Empty-cmd Guard in Each Driver Script

After extracting `cmd`/`line`, if it's empty, emit an empty items array and return early
(NOT passing `""` to the completion engine):

**fish.lua** (inside `__pi_handle`, after line ~127 extraction):
```
if test -z "$cmd"
    echo __PIRESP_START__
    echo '{"items":[]}'
    echo __PIRESP_END__
    return
end
```

**bash.lua** (inside `(__PIREQ__*)` case, after line ~194 extraction):
```bash
if [[ -z "$line" ]]; then
    echo __PIRESP_START__
    echo '{"items":[]}'
    echo __PIRESP_END__
    return
fi
```

**zsh.lua** (inside `(__PIREQ__*)` case, after line ~194 extraction):
```zsh
if [[ -z "$cmd" ]]; then
    echo __PIRESP_START__
    echo '{"items":[]}'
    echo __PIRESP_END__
    return 0
fi
```

**Why this works:** The daemon ALWAYS emits `__PIRESP_START__\n{json}\n__PIRESP_END__\n`
(even on error/empty), so the `_feed` rx_buf slicer in shell.lua can pair START/END
correctly. An empty `{"items":[]}` is a valid response that results in no completions
(clean empty menu) rather than a flood.

**Test:** The driver smoke tests (`tests/shell_*_driver_smoke.lua`) test the driver in
isolation. Add a case: send a `__PIREQ__` with a line containing a `"`, assert the
response has 0 items (not 158+).