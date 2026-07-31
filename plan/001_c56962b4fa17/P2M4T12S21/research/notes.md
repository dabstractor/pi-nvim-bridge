# S21 — VimEnter activation gate: research & LIVE verification notes

> Subtask **P2.M4.T12.S21** — implement `M.activate()` in
> `plugin/lua/pi-editor/init.lua`: read `PI_NVIM_BRIDGE`, validate, activate or
> stay dormant. Target runtime **Neovim 0.12.4** (verified), plenary.nvim present.
>
> **Method**: all logic, the smoke-test invocation form, the plenary invocation
> form, and the end-to-end S20-shim → S21-activate wiring were exercised against a
> scratch copy of the real `init.lua` + the real `plugin/pi-editor.lua` shim under
> `/tmp/s21_verify`. The real source tree (`plugin/`) was NOT modified (research
> only). Every claim below is backed by a green run reproduced in this transcript.

## 1. The contract (from tasks.json `context_scope`)

`M.activate()` in `init.lua` must:
- (a) read `vim.env.PI_NVIM_BRIDGE`
- (b) nil → **return (dormant)**
- (c) `pcall(vim.json.decode, raw)` — fail → **return silently** (single notify is S39)
- (d) `desc.transport ~= "unix"` → **return**
- (e) **store descriptor**
- (f) **set buffer-local filetype to "pi-prompt"**
- (g) trigger ftplugin setup — **via S22** (not this task)
- (h) initiate bridge connection — **placeholder, wired in M5 (S24)** (not this task)

OUTPUT: activated only when env var present+valid; buffer marked pi-prompt;
descriptor stored for the bridge client. MOCKING: valid JSON, invalid JSON,
missing env var, non-unix transport. DOCS: [Mode A] Lua docstring (dormant-by-design).

## 2. Reference implementation shape (verified to pass all gates)

Inserted into `plugin/lua/pi-editor/init.lua` **BEFORE** the final `return M`
(GOTCHA A). Adds a `pi-editor.BridgeDescriptor` LuaCATS class, `M.descriptor`
(nil placeholder), and `M.activate()`:

```lua
---@class pi-editor.BridgeDescriptor
---@field transport "unix"
---@field path string
---@field token string
---@field pid integer
---@field cwd string
---@field fdAvailable boolean
---@field serverVersion string

---@type pi-editor.BridgeDescriptor|nil
M.descriptor = nil

function M.activate()
  if M.config == nil then M.setup({}) end                       -- self-init if user skipped setup()
  local env_name = M.config.env_var or "PI_NVIM_BRIDGE"
  local raw = vim.env[env_name]
  if raw == nil then return nil end                             -- (b) no env var -> dormant
  local ok, desc = pcall(vim.json.decode, raw)                  -- (c) THROWS -> pcall
  if not ok or type(desc) ~= "table" then return nil end        -- malformed / non-object -> dormant
  if desc.transport ~= "unix" then return nil end               -- (d) wrong transport -> dormant
  M.descriptor = desc                                           -- (e) store for S24/S30+
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "pi-prompt"                            -- (f) activate -> triggers S22 ftplugin
  return desc
end
```

The `type(desc) ~= "table"` guard is THE load-bearing non-obvious line — see §3.

## 3. LIVE verification — the activate() logic (6 cases)

Scratch runner `/tmp/s21_flow.lua` drove a stand-in module mirroring the above
through every branch (env var set via `vim.env.PI_NVIM_BRIDGE`):

| Case | env var value | expected | result |
|---|---|---|---|
| 1 valid unix | full descriptor JSON | activate, descriptor set, filetype=`pi-prompt` | ✓ `path=/tmp/x.sock token=abc123 filetype=pi-prompt` |
| 2 no env var | nil | dormant, descriptor nil | ✓ returned nil, descriptor nil |
| 3 malformed JSON | `{not json` | dormant, no throw | ✓ pcall ok=true, returned nil |
| 4 **valid-JSON-NUMBER** | `123` | dormant via type guard, no throw | ✓ pcall ok=true, returned nil (**`desc.transport` did NOT throw**) |
| 5 transport=tcp | `{"transport":"tcp",...}` | dormant | ✓ returned nil |
| 6 custom env_var | `MY_BRIDGE` set, `config.env_var="MY_BRIDGE"` | activate via custom name | ✓ path=/c.sock |

**Case 4 is the critical finding.** `vim.json.decode("123")` succeeds and returns
a **number** (not a table). `decode("true")`→bool, `decode('"x"')`→string,
`decode("[]")`→table. Indexing a number/boolean with `.transport` **throws**
(`attempt to index a number value`). So `pcall` success alone is insufficient —
the `type(desc) == "table"` check MUST come before any field access. Verified
directly:

```
decode bad json  ok=false  err=Expected value but found invalid token at character 1
decode good      transport=unix path=/tmp/x.sock
decode number    ok=true   type=number      <-- would throw on .transport without the guard
decode empty     ok=false  err=Expected value but found T_END at character 1
```

## 4. LIVE verification — smoke + plenary invocation patterns

Built a scratch tree (`/tmp/s21_verify/{lua/pi-editor/init.lua, plugin/pi-editor.lua,
tests/{minimal_init,activate_spec,activate_smoke}.lua}`) mirroring the real
deliverables. Both gates ran green:

- **Smoke (plenary-free):**
  `nvim --headless --clean -u NORC +"lua vim.opt.runtimepath:append('$SCRATCH')" +"luafile tests/activate_smoke.lua" +qa`
  → `SMOKE_PASS`, exit 0.
- **Plenary:** `cd $SCRATCH && nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/activate_spec.lua")'`
  → **Success: 9  Failed: 0  Errors: 0**. The 9 `it` blocks cover: activate is a
  fn; descriptor nil pre-activate; no-env→dormant+filetype-untouched; valid→activates+
  descriptor+filetype; malformed→dormant+no-throw; number→dormant via guard; tcp→dormant;
  env_var override; self-init config.

## 5. LIVE verification — end-to-end S20 shim → S21 activate (Level 3)

Copied the **real** completed `plugin/pi-editor.lua` shim (S20) into the scratch
tree, set `runtimepath` via `--cmd` (step 3, GOTCHA C), and fired `VimEnter`:

| Scenario | result |
|---|---|
| (a) no env var | `filetype=[] descriptor=nil` — dormant, no error ✓ |
| (b) valid env var | `filetype=[pi-prompt] path=/tmp/real.sock token=sekret` — **real shim callback ran real activate()** ✓ |
| (c) malformed env var | `ok=true filetype=[] descriptor=nil` — dormant silently, no throw ✓ |

This proves the full S20→S21 contract: the auto-sourced shim's fire-once VimEnter
autocmd invokes `require("pi-editor").activate()`, which reads+validates the env
var, stores `M.descriptor`, and sets the filetype. `M.descriptor` is reachable as
`require("pi-editor").descriptor` — the public surface S24 will consume.

## 6. LIVE verification — S21's contract to S22 (filetype → FileType event)

```
vim.api.nvim_create_autocmd("FileType",{pattern="pi-prompt", callback=...})
vim.bo[buf].filetype = "pi-prompt"
→ FileType fired count=1
```
Setting `vim.bo[buf].filetype` fires the `FileType` event. So S21 setting filetype
= "pi-prompt" IS the handshake: when S22 ships `plugin/ftplugin/pi-prompt.lua`, it
is auto-sourced on that event (provided `:filetype plugin on`, which is on by
default in real user configs; S22 owns ensuring that). S21 does NOT need to do
anything beyond setting the filetype.

## 7. API facts confirmed on Neovim 0.12.4

- `vim.json.decode` is a function; **throws** on invalid JSON (pcall required).
- `vim.env[NAME]` returns **nil** for unset vars (no error); assignable via
  `vim.env.NAME = x`; clearable via `vim.env.NAME = nil`.
- `vim.bo[buf].filetype = "x"` sets the option and fires `FileType`.
- `vim.api.nvim_get_current_buf()` is stable across the call (== itself).
- `luanil` decode option: NOT needed here — the descriptor has no null fields.
  Default null→`vim.NIL` mapping is irrelevant for a fully-populated object.

## 8. Gotchas captured (→ PRP §Known Gotchas)

- **A — `return M` must stay LAST.** The S19 module ends with `return M`. Lua
  requires `return` to be the final statement, so the new `M.descriptor` +
  `M.activate()` MUST be inserted **before** `return M`, never appended after it.
  (Hit this directly: appending after `return M` → `'<eof>' expected near 'M'`.)
- **B — pcall success ≠ table.** `decode("123")`→number. Guard `type(desc)=="table"`
  before ANY field access, or `desc.transport` throws on a bare number/bool. (§3.)
- **C — validation-command rtp timing.** For end-to-end VimEnter tests, set
  `runtimepath` via `--cmd` (step 3) so the shim auto-sources at step 12. Setting
  it in a `+` arg (step 17) is too late: the shim is never sourced → VimEnter has
  no pi-editor autocmd → activate never runs. (Inherited from S20 GOTCHA #3;
  essential for S21's Level-3 command.)
- **D — `M.config` may be nil at VimEnter** if the user's config never called
  `setup()` (e.g. the future NVIM_APPNAME minimal config, S47). activate() must
  self-init (`if M.config == nil then M.setup({}) end`) before reading
  `config.env_var`, else `config.env_var` throws on a nil index.
- **E — activate() must NEVER throw.** The S20 shim calls it WITHOUT a pcall
  (it only pcalls the `require`). So every failure path must return nil cleanly.
  The one-time `vim.notify` on hard failure is explicitly S39's job — S21 is
  silent. (S20 PRP: "activate / S21+S39 own activate()'s internal resilience".)
- **F — dormancy is SILENT in S21.** No notify. S39 layers the notify later.
- **G — scope: filetype is the ONLY buffer mutation.** S21 does NOT connect to
  the bridge (S24 reads `M.descriptor.path`+`.token`) and does NOT set buffer
  options/keymaps (S22's ftplugin). Setting filetype is the handshake to S22.
- **H — no filename matching needed.** Two temp-file patterns exist
  (`pi-editor-<ts>.pi.md`, `pi-extension-editor-<ts>.md`); the env var alone is
  sufficient + precise (tasks.json). Do NOT add buffer-name checks.

## 9. Non-regression: existing suites stay green

S21 is purely ADDITIVE to `init.lua`: it adds a class, a `nil` field, and a
function. It does not touch `setup`/`defaults`/`config`/`bridge`. So:
- S19 `tests/init_spec.lua` (13 `it`) — still passes (verified the additions load
  cleanly alongside the existing module).
- S20 `tests/shim_spec.lua` / `shim_smoke.lua` — still pass; their "no `vim.env`
  in shim" literal check targets `plugin/pi-editor.lua` (the shim, unchanged),
  NOT `init.lua`, so adding env reads to `init.lua` is no conflict.

## 10. External references (citable; from researcher brief + neovim docs)

- `:help vim.json` — https://neovim.io/doc/user/lua.html#vim.json (decode throws;
  `luanil` default → `vim.NIL`).
- `:help 'filetype'` — https://neovim.io/doc/user/options.html#'filetype'
- `:help FileType` — https://neovim.io/doc/user/autocmd.html#FileType
- `:help :filetype-plugin-on` — https://neovim.io/doc/user/filetype.html#:filetype-plugin-on
  (ftplugin auto-sourcing precondition; on by default in real configs).
- Env-var-gated precedents: smart-splits.nvim (`TMUX`/`WEZTERM_PANE`/…),
  aserowy/tmux.nvim (activates only when `$TMUX` set) — "read env var on startup,
  no-op if absent" is an established safe pattern.
