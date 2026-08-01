# Test Conventions — pi-nvim-bridge

## Test Harness

Two tiers (from AGENTS.md):

### Plenary Specs (`tests/*_spec.lua`)
```bash
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/<spec>.lua")'
```
Uses `plenary.busted`: `describe`/`it`/`before_each`/`after_each` +
`assert.are.equals/is_true/is_nil/is_same` + `assert.has_no.errors`.

### Smoke Tests (`tests/*_smoke.lua`, plenary-FREE)
```bash
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  +"luafile tests/<module>_smoke.lua" +qa
echo "exit=$?"   # 0 = pass (prints SMOKE_PASS), 1 = fail
```
Uses a hand-rolled `fails`/`check(cond,msg)` pattern. Prints `SMOKE_PASS` on success.

## Key Patterns for Shell-Layer Tests

### Fake Bridge (`fake_bridge(shell_path, server_cwd)`)
```lua
local function fake_bridge(shell_path, server_cwd)
  return {
    get_shell_info = function()
      if shell_path == nil then return nil end
      return { shell = shell_path }  -- controls the RESOLVED shell
    end,
    server_info = (server_cwd == nil) and {} or { cwd = server_cwd },
  }
end
pi.bridge = fake_bridge("/usr/bin/fish")
```
For Issue 5 tests, extend to return `shellSource`:
```lua
return { shell = shell_path, shellSource = shell_source or "pi" }
```

### Fake Driver Injection
```lua
local function inject_for(resolved_shell_path)
  local base = resolved_shell_path:gsub(".*/", "")
  local fake = make_fake_driver()
  package.loaded["pi-bridge.shell." .. base] = fake
  return fake
end
```
`make_fake_driver()` returns `{ start = function(opts, cb) cb(nil, proc, stdin, stdout) end }`.
The `start` callback fires SYNCHRONOUSLY (no `vim.wait` needed).

### Notice Assertion (Style A — fast boolean)
```lua
local notify = require("pi-bridge.notify")
notify.reset()  -- clear dedup set
shell.reset()   -- clear state.gen, state.proc, etc.
-- ... trigger ensure() ...
vim.wait(200, function() return notify.did_notify("shell-mismatch") end, 5)
assert.is_true(notify.did_notify("shell-mismatch"))
assert.is_false(notify.did_notify("shell-active"))
```

### Notice Assertion (Style B — full message/level spy)
```lua
local calls = {}
local orig = vim.notify
vim.notify = function(msg, level, opts)
  calls[#calls + 1] = { msg = msg, level = level, opts = opts }
end
-- ... trigger ...
vim.wait(200, function()
  for _, c in ipairs(calls) do
    if c.msg and c.msg:find("native zsh") then return true end
  end
  return false
end, 5)
vim.notify = orig  -- ALWAYS restore
```

### PATH-gate Stub (`vim.fn.executable`)
```lua
local function stub_executable(names_true)
  local orig = vim.fn.executable
  local set = {}; for _, n in ipairs(names_true) do set[n] = true end
  vim.fn.executable = function(name)
    if type(name) ~= "string" then return 0 end
    return set[name] and 1 or 0
  end
  return function() vim.fn.executable = orig end
end
```

### Save/Restore Harness (MUST restore all globals)
```lua
before_each(function()
  orig_shell = vim.env.SHELL
  orig_bridge = pi.bridge
  orig_desc = pi.descriptor
  orig_shell_cfg = (pi.config and pi.config.shell) or nil
end)
after_each(function()
  vim.env.SHELL = orig_shell
  pi.bridge = orig_bridge
  pi.descriptor = orig_desc
  if orig_shell_cfg then pi.config.shell = orig_shell_cfg end
  package.loaded["pi-bridge.shell.fish"] = nil  -- purge fake driver
  notify.reset()
  shell.reset()
end)
```

## Key Patterns for Completion-Layer Tests

### Fake Bridge (RPC surface)
```lua
local self = { connected=true, requests={}, cancels={}, last_id=0,
               auto_cancel_fires=true }
function self.request(method, params, cb)
  self.last_id = self.last_id + 1
  local id = tostring(self.last_id)
  self.requests[#self.requests+1] = { id=id, method=method, params=params, cb=cb }
  return id
end
function self.cancel(id)
  self.cancels[#self.cancels+1] = id
  if self.auto_cancel_fires then
    -- mirrors real bridge: fire cb with "cancelled"
  end
end
```
Pass `{auto_cancel_fires=false}` to assert two-layer supersession manually.

### Supersession Assertion (on_results seam counter)
```lua
local seam = 0
completion.on_results = function(...) seam = seam + 1 end
-- ... refresh (gen N); capture stale_cb = fake.requests[1].cb ...
-- ... refresh again (gen N+1) ...
-- ... fire stale_cb ...
assert.are.equals(1, seam, "stale response must NOT re-fire on_results")
```

### Menu State Assertion
```lua
menu.is_open()          -- boolean
menu.get_selected()     -- current item table
completion.current()    -- {items=..., prefix=...} (last_result) or nil
```

## ⛔ HARD RULE (from AGENTS.md)

NEVER pipe a heredoc into nvim's stdin (`nvim ... +"luafile /dev/stdin" +qa <<EOF`).
It HANGS the session. Write Lua to a real `.lua` file, then `:luafile` it.
Every nvim invocation MUST be wrapped in `timeout`.

## Gotchas

- `pi.bridge` is read FRESH at call time — set it AFTER require if needed.
- Do NOT name a spec-local table `pending` — it shadows plenary's skip function.
- `notify.once` is `vim.schedule`'d — `did_notify` is set synchronously, but the toast
  flush needs `vim.wait(ms, predicate, 5)`.
- `shell._test_*` seams are INTERNAL — reuse them, do not add new ones.
- `config.shell.prefer` is NOT exercised by `shell_notices_spec` for bare `"bash"` —
  the existing tests drive mismatch via `$SHELL` + resolved-shell basename.