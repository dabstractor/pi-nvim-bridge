# Research: Lua / Plugin Side of pi-nvim-bridge

Scout findings for the shell-completion delta PRD. Exact file paths + line numbers,
the public API surface, the data-flow seams, and the patterns a new feature must
follow. All line numbers verified against the current tree (completion.lua 943 lines,
bridge.lua 848 lines, menu.lua 677 lines).

---

## Files Retrieved

1. `lua/pi-bridge/completion.lua` (full, L1–943) — the per-keystroke completion TRIGGER
   module. Owns debounce → fetch → two-layer supersession → result→menu seam. This is
   the module a shell-completion delta most directly extends.
2. `lua/pi-bridge/bridge.lua` (full, L1–848) — the luv Unix-socket TRANSPORT + the
   JSON-RPC handshake/request/cancel/notification layers. `M.request` is the generic RPC
   primitive every downstream RPC calls.
3. `lua/pi-bridge/init.lua` (full, L1–end) — entry module: `M.config`/`M.defaults`,
   `M.setup()`, `M.activate()` (VimEnter gate), the `BridgeDescriptor` class, `M.bridge`
   publication point.
4. `lua/pi-bridge/menu.lua` (full, L1–677) — the windowless menu-STATE singleton +
   floating-window renderer. Consumes `completion.on_results`.
5. `lua/pi-bridge/notify.lua` (full) — dedup'd, `vim.schedule`-wrapped one-time notify.
6. `lua/pi-bridge/health.lua` (full) — the `:checkhealth pi-bridge` module (4 sections).
7. `ftplugin/pi-prompt.lua` (full) — buffer options, 9 keymaps, 5 buffer-local autocmds
   (incl. VimLeavePre/ExitPre teardown).
8. `lua/pi-bridge/coords.lua` (full) — centralized byte↔UTF-16 + nvim↔pi cursor API.
9. `lua/pi-bridge/jsonlreader.lua` (L1–50) — framing/decode (read by bridge transport).
10. `lua/pi-bridge/cmp_source.lua` (L1–60) + `lua/pi-bridge/blink_source.lua` (L1–60) —
    the two OPT-IN engine adapters (mirror completion's RPC path, no builtin-menu coupling).
11. `plugin/pi-bridge.lua` (full) — the VimEnter auto-activation shim.
12. `extension/protocol.ts` (full) — the TYPES-ONLY wire contract (the source of truth
    for params/result shapes the Lua side mirrors).
13. `tests/minimal_init.lua`, `tests/completion_smoke.lua`, `tests/completion_spec.lua`
    (L1–120), `tests/notify_spec.lua`, `tests/bridge_request_spec.lua` (L1–70) — test
    patterns.

---

## 1. `completion.lua` — the completion TRIGGER module

### The singleton state (L253–267) — `pi-bridge.CompletionState`
```lua
---@class pi-bridge.CompletionState
---@field buf            integer?    The pi-prompt buffer refresh() is debouncing for.
---@field debounce_timer userdata?   The vim.defer_fn handle (tracked for stop+close — NEVER stop-only; leaks).
---@field gen            integer     Monotonic supersession guard (bumped per fetch; captured in the cb closure).
---@field inflight_id    string?     The bridge.request id string of the current in-flight getSuggestions (for bridge.cancel).
---@field last_result    {items:pi-bridge.AutocompleteItem[], prefix:string}?  Latest non-stale result (for current()).
local state = { buf=nil, debounce_timer=nil, gen=0, inflight_id=nil, last_result=nil }
```
`state.gen` (an int) is the **layer-2 CORRECTNESS guard**; `state.inflight_id` (a string
from `bridge.request`) feeds **layer-1 cancel**. Named distinctly on purpose (header L72).

### `completion_context(lines, cursorLine, cursorCol)` — L375 (local, NOT exported)
The CLIENT-SIDE completion gate. Returns `"slash" | "path" | nil`. **This is the single
function that decides whether a keystroke issues a `getSuggestions` RPC at all.** A
shell-completion delta likely needs a new return value / branch here:
```lua
local function completion_context(lines, cursorLine, cursorCol)   -- L375
  local line = (type(lines)=="table") and (lines[cursorLine+1] or "") or ""
  local before = line:sub(1, cursorCol)                            -- 0-based byte col → bytes [1..cursorCol]
  local token = before:match("[%S]+$") or ""                       -- trailing non-whitespace run
  local token_start = #before - #token
  -- (1) "/" at col 0 of line 1 → "slash"; a "/" elsewhere → "path"
  if token ~= "" and token:sub(1,1)=="/" then
    if cursorLine==0 and token_start==0 then return "slash" end
    return "path"
  end
  -- (2) line 1 starts with "/" but cursor past the command name → slash ARGUMENT
  if cursorLine==0 and before:sub(1,1)=="/" then return "slash" end
  -- (3) file/path/attachment triggers
  if token=="" then return nil end
  local c1 = token:sub(1,1)
  if c1=="@" or c1=="#" then return "path" end
  if c1=="." then return "path" end
  if token:sub(1,2)=="~/" then return "path" end
  return nil
end
```
**Severity note:** `completion_context` is the hard gate. Today plain prose / a `$` /
shell metachars return `nil` → no RPC → no menu. A shell-completion feature that should
fire on, e.g., a `$VAR` or `|` or shell-operator context must add a branch HERE, plus it
must be reflected in `compute_debounce` (L344) and the `force=` param (L461) logic.

### `do_refresh(buf)` — L406 (local; the debounced body)
Runs inside the api-safe `vim.defer_fn` cb. The full pipeline a new feature must mirror:
1. **Guard** buf valid + current (L407–410).
2. **Read bridge FRESH** at call time — `local bridge = require("pi-bridge").bridge` (NOT a
   module-load local; handshake resolves async). Bail silently if not connected (L411–417).
3. Read buffer lines + cursor (L419–426).
4. **`completion_context` gate** — `if not ctx then on_results(buf,{},""); return end` (L456–460).
5. **coords convert** — `local pi = require("pi-bridge.coords").nvim_to_pi_coords(lines, row, byte_col)` (L445).
6. **Supersede layer 1** — `bridge.cancel(state.inflight_id)` (L447–451).
7. **Supersede layer 2** — `state.gen = state.gen + 1; local gen = state.gen` captured in cb (L454–455).
8. **Issue** `bridge.request("getSuggestions", params, cb)` with `force=(ctx=="path")` (L461–484).
9. **cb gen-guard** — `if gen ~= state.gen then return end` drops stale (L466).

### The gen-guard supersession pattern (the load-bearing correctness seam)
```lua
-- do_refresh body (L454–468):
state.gen = state.gen + 1
local gen = state.gen
...
local ok, id = pcall(bridge.request, "getSuggestions", params, function(err, result)
  if gen ~= state.gen then           -- STALE (superseded) — drop, touch nothing
    return end
  state.inflight_id = nil
  if err then return end             -- cancelled/timeout/error → touch nothing (no flicker)
  local items  = (result and type(result.items)=="table")  and result.items  or {}
  local prefix = (result and type(result.prefix)=="string") and result.prefix or ""
  state.last_result = { items=items, prefix=prefix }
  if type(M.on_results)=="function" then pcall(M.on_results, buf, items, prefix) end
end)
if ok and type(id)=="string" then state.inflight_id = id end
```
**ERROR/CANCELLED/TIMEOUT → TOUCH NOTHING** (header L56): never clear `last_result`, never
call `on_results` on a failed fetch (would flicker). **NULL RESULT → EMPTY** (L57):
`cb(nil,nil)` normalizes to `{items={}, prefix=""}` and DOES fire `on_results` (close path).

### `force_fetch(buf, pi, opts, on_items)` — L508 (local; the 0-debounce Tab sibling)
The IMMEDIATE (no `vim.defer_fn`) path used by `on_tab` (S33). **DUPLICATES do_refresh's
supersession block intentionally** (additive over refactor; header L484–490). **Shares**
`state.gen` / `state.inflight_id` / `state.debounce_timer` so refresh↔Tab supersession is
correct. Calls `cancel_timer()` first (L510). Identical gen-guard + null-normalize (L529–537).

### `compute_debounce(lines, cursorLine, cursorCol)` — L344 (local)
Trigger-aware debounce (mirrors pi's `getAutocompleteDebounceMs`): **0 ms for slash/typing**,
`config.debounce_ms` (default 20) for `@`/`#` attachment context. Calls `M.is_attachment_context`
(L297, the only EXPORTED pure helper here — testable like coords).

### Public API (all exported on `M`)
| Function | Line | Purpose |
|---|---|---|
| `M.refresh(buf)` | L572 | autocmd entry point (InsertEnter/TextChangedI/CursorMovedI). cancel_timer → compute_debounce → `vim.defer_fn(do_refresh, ms)`. |
| `M.reset()` | L602 | teardown: cancel_timer + bridge.cancel(inflight) + gen=0 + clear state. The S37 InsertLeave/BufLeave seam. |
| `M.current()` | L620 | read-only shallow copy of `last_result` (for accept/Tab WITHOUT menu coupling). |
| `M.accept(item, prefix_override?)` | L655 | the 5-step applyCompletion flow (nvim→pi coords → `bridge.request("applyCompletion",…)` → pi→nvim coords + `nvim_buf_set_lines` whole buffer + `nvim_win_set_cursor` (NO -1) + `menu.close`). Returns true iff RPC issued. |
| `M.on_enter(buf)` | L711 | `<CR>`: accept iff menu open+selected, else fall through to newline (no Enter-to-submit). |
| `M.on_tab(buf)` | L748 | pi `handleTabCompletion`: BRANCH 1 menu-open→accept; BRANCH 2 menu-closed→slash `force_fetch(force=false)` OR `shouldTriggerFileCompletion` RPC → `force_fetch(force=true)`. |
| `M.on_next/on_prev/on_dismiss(buf)` | L812/L825/L842 | navigation (delegate to `menu.next/prev/dismiss`). |
| `M.on_insert_leave/on_buf_leave(buf)` | L876/L885 | autocmd-driven auto-close (`hide_and_cancel` local). |
| `M.on_commands_changed(buf?)` | L925 | S41: clear cache + close menu + (iff was_open) re-query via `M.refresh`. Preserves `state.buf` (NOT `reset`). |
| `M.on_results` | L281 | the result→menu SEAM (set by `menu.attach`; nil today). `fun(buf, items, prefix)\|nil`. |
| `M.is_attachment_context(text)` | L297 | PURE exported helper (the only pure fn exported). |

### AutocompleteItem shape (Lua mirror, L246–252)
```lua
---@class pi-bridge.AutocompleteItem
---@field value string The text to insert on accept (the canonical value).
---@field label string Human-readable label shown in the menu.
---@field [string] any Extra fields (detail/description/kind/filterText).
```
The bridge delivers these as `result.items` from `getSuggestions`. S30/S31 are
**shape-agnostic** — they store + forward the array verbatim. menu.lua reads `.label` +
`.description`; accept forwards the whole table to `applyCompletion`.

---

## 2. `bridge.lua` — TRANSPORT + PROTOCOL

### Module-level singleton state
| Symbol | Line | Role |
|---|---|---|
| `local state = {...}` (BridgeState) | L164 | `pipe`/`rx`/`on_ready`/`on_event`/`on_close`/`connected`/`closed`. |
| `M.version` | L176 | `"0.1.0"` (sent as hello `clientVersion`). |
| `M.server_info` | L188 | `pi-bridge.ServerInfo\|nil` (set ONLY on handshake success; cleared by `close()`). |
| `local handshake_state` | L200 | the exactly-once handshake race-guard (`pending` bool + luv timer + desc + cb). |
| `local next_id` | L205 | monotonic int counter; `tostring(next_id)` → numeric strings; reset to 0 by `close()`. |
| `local pending = {}` | L221 | **id → PendingRequest MAP** (the two-layer transport: holds EVERY concurrent request). |
| `local notification_handlers = {}` | L231 | method → schedule_wrap'd handler. |

### The descriptor type (defined in `init.lua`, L98–108; mirrored in `extension/protocol.ts` §B)
```lua
---@class pi-bridge.BridgeDescriptor
---@field transport "unix"
---@field path string    -- Unix domain socket path (${tmpdir}/pi-nvim-bridge-<uuid>.sock)
---@field token string   -- 32-byte hex secret — the REAL auth boundary (PRD §12)
---@field pid integer
---@field cwd string     -- pi session cwd (ctx.cwd)
---@field fdAvailable boolean
---@field serverVersion string
M.descriptor = nil   -- L110 (set by activate())
```

### `M.server_info` (L183–188) — ServerInfo class
```lua
---@class pi-bridge.ServerInfo
---@field serverVersion string
---@field cwd string          -- falls back to descriptor.cwd
---@field fdAvailable boolean -- True ONLY if result.fdAvailable == true
M.server_info = nil
```
Extracted defensively inside `resolve_handshake` success branch (bridge.lua L~410–418). Read
by `:checkhealth` (health.lua) + completion uses `.cwd`.

### `M.request(method, params, on_result) -> string|nil` — L653 (THE generic RPC primitive)
Every downstream RPC (`getSuggestions`/`applyCompletion`/`shouldTriggerFileCompletion`/
`getCommands`/`ping`/`bye`) goes through this. **A new RPC method needs NO bridge change —
just call `bridge.request("<method>", params, cb)`.**
1. Validate `method`+`on_result` up front (never throws; bad method → `cb("invalid method")`).
2. If `not M.is_connected()` → `cb("not connected")` (scheduled) + return nil.
3. `next_id += 1; id = tostring(next_id)`; `pending[id] = {method, cb=vim.schedule_wrap(on_result), timer}`.
4. Arm a per-request `uv.new_timer` (default `rpc_timeout_ms`=2000; `:close()` REQUIRED on resolve — leaks).
5. `M.send({jsonrpc="2.0", id, method, params})`; dropped → `resolve_request(id,"send failed",nil)`.
6. Return `id` so the caller can `M.cancel(id)` / supersede.

### `M.cancel(id)` — L697
Local supersession only — fires `cb("cancelled")`, stops+closes timer, deletes entry. **NO
wire cancel** (protocol.ts `BridgeMethod` has no `cancel`; server self-supersedes via its own
`AbortController`). Reuses `resolve_request` (the single exit; exactly-once via delete-entry).

### `resolve_request(id, err, msg)` — the exactly-once exit (L~440)
Delete-entry guard: `pending[id]=nil` FIRST, then timer :stop()+:close(), then cb. Branches:
`msg==nil` → `cb(err)`; `type(msg.error)=="table"` → `cb("rpc error <code>: <msg>")`;
`rawget(msg,"result")~=nil` → normalize `vim.NIL→nil`, `cb(nil, result)`; else malformed.
**`rawget`** distinguishes present-null (`vim.NIL`, getSuggestions empty = success) from
absent key (`nil`, malformed).

### `dispatch(msg)` — the single `on_event` (L~404)
Three mutually-exclusive branches by wire shape:
1. `id=="h1"` → `resolve_handshake` (STAYS FIRST).
2. `type(msg.id)=="string"` && `pending[msg.id]` → `resolve_request`.
3. `method` present + no string `id` → notification → `notification_handlers[method](params)`.

### `M.send(obj)` — L601
`vim.json.encode(obj).."\n"` → `pipe:write`. Returns false if not `connected`/closing/closed.
Write cb ALWAYS routes `EPIPE` → `on_close` (never swallow).

### Connection lifecycle
- `M.connect(path, on_ready, on_event, on_close)` — L462. Idempotent re-init (closes prior).
- `M.handshake(desc, on_result)` — L549. Sends `hello` envelope
  `{jsonrpc="2.0", id="h1", method="hello", params={token, client="pi-bridge.nvim", clientVersion=M.version}}`.
  On success publishes `require("pi-bridge").bridge = M` (the gate completion keys on).
- `M.close()` — L743. Idempotent (shadow `state.closed` flag defends double-close THROW).
  Drains ALL pending with `"connection closed"`, clears `server_info`, `notification_handlers={}`, `next_id=0`.
- `M.on_exit(buf)` — L832. VimLeavePre/ExitPre handler: (1) `autosave_if_modified(buf)`,
  (2) best-effort `bye` RPC iff connected, (3) `M.close()`.
- `M.is_connected()` — L845. `state.connected and not state.closed`.

### `M.on_notification(method, handler)` — L716 + `M.on_disconnect(handler)` — L733
Registration APIs. `on_notification` last-wins into the method map; `on_disconnect` is a
single slot. Both store the handler `vim.schedule_wrap`'d (GOTCHA 5: dispatch runs inline
from luv `read_start`). `nil` removes. Both cleared by `close()`.

---

## 3. `init.lua` — entry module

### `M.defaults` — L31–40 (the shipped config)
```lua
---@class pi-bridge.Config
---@field menu pi-bridge.MenuConfig          -- {max_height, border}
---@field debounce_ms integer                -- 20 (file/attachment window; slash/typing use 0; S40)
---@field rpc_timeout_ms integer             -- 2000 (MUST exceed server fd-abort 1500; S40)
---@field autosave_on_exit boolean
---@field engine ("builtin"|"blink"|"cmp")
---@field env_var? string                    -- default "PI_NVIM_BRIDGE"
M.defaults = { menu={max_height=12, border="rounded"}, debounce_ms=20,
               rpc_timeout_ms=2000, autosave_on_exit=true, engine="builtin" }
```
### `M.config` — L44 (`nil` until `setup()`). `M.bridge` — L51 (nil until handshake success).

### `M.setup(opts)` — L67
`vim.tbl_deep_extend("force", M.defaults, opts)` → `M.config`. Re-mergeable. Emits a dedup'd
WARN (via `notify.once`) if `rpc_timeout_ms <= 1500`. **Never throws.**

### `M.activate()` — L134 (the VimEnter gate; called by `plugin/pi-bridge.lua`)
DORMANT BY DESIGN: returns nil unless `PI_NVIM_BRIDGE` env var is set + valid JSON + `transport=="unix"`.
Flow: self-`setup({})` if needed → decode env → store `M.descriptor` →
`vim.bo[buf].filetype="pi-prompt"` (fires the ftplugin S22) → `bridge.handshake(desc, cb)`
(async, pcall'd; on hard-failure emits ONE `notify.once("bridge", WARN, …)`) → registers
`on_disconnect` (menu.close + completion.reset + notify) + `on_notification("commandsChanged",…)`
(→ `completion.on_commands_changed`) → `menu.attach()`.
**Order matters:** disconnect/notification handlers registered AFTER `handshake()` (it runs
`M.close()` first which clears the registries — GOTCHA D).

---

## 4. `menu.lua` — windowless menu-STATE + floating renderer

### AutocompleteItem mirror (menu.lua L234–239) — identical to completion.lua's.
Adds `.description` (used by the two-column render).

### MenuState singleton (L268–279)
```lua
local state = { attached=false, prev_on_results=nil, buf=nil, items={}, prefix="",
                selected=0, open=false, win=nil, menu_buf=nil }
```

### Public API
| Function | Purpose |
|---|---|
| `M.attach()` | idempotently sets `completion.on_results = M.on_results` (guarded by `attached`; saves `prev_on_results`). |
| `M.detach()` | restores prior `on_results`. |
| `M.on_results(buf, items, prefix)` | the seam consumer: empty→`close()`; non-empty→store ctx+`open(items)`. WIPE-guard only (NO staleness re-derive — trusts S30's two-layer supersession). |
| `M.open(items)` | store + `selected=1` + `open=true` + `render(state)`. |
| `M.close()` | `items={}; selected=0; open=false` + `render` hide. |
| `M.next()/M.prev()/M.dismiss()` | navigation mutators (1-indexed wraparound). |
| `M.get_selected()` / `M.get_items()` / `M.get_prefix()` / `M.get_buf()` | state accessors (shallow copy for items). |
| `M.is_open()` / `M.has_items()` | booleans. |
| `M.reset()` | full teardown (close + detach + clear buf/prefix/win/menu_buf). |
| `M._compute_width/_compute_height/_compute_geometry/_column_metrics/_truncate/_state` | internal test seams (underscore-prefixed). |

`render(state)` (local, L~535) is the S34 floating-window lifecycle: scratch buffer
(create-once, reuse), `nvim_open_win`/`nvim_win_set_config` (in-place reposition, no flicker),
two-column layout + 3-layer highlights (`Pmenu` base → `Comment` desc → `PmenuSel` LAST).

---

## 5. `notify.lua` — dedup notification

```lua
function M.once(category, level, msg)   -- default category "bridge", default level WARN
  if seen[category] then return end
  seen[category] = true
  vim.schedule(function() pcall(vim.notify, msg, l, { title="pi-bridge" }) end)
end
function M.reset() seen = {} end
function M.did_notify(category) return seen[...]=="bridge"] == true end
```
`vim.schedule`-wrapped → safe from luv fast context (the handshake `on_result` cb runs
inline). Dedup collapses connect-fail + handshake-fail + process-death to ONE toast/session.

---

## 6. `health.lua` — `:checkhealth pi-bridge`

`M.check()` (run by the loader as `require("pi-bridge.health").check()`). **MUST be a table
field `M.check`** (not a local — loader can't see locals). Four sections via `vim.health.start`:
1. **pi-bridge** (version): reads `bridge.version`; gate `vim.fn.has("nvim-0.11")==1` (NOT
   `vim.version.ge` — 0.12-only); `M.min_nvim = "0.11"` (coords.lua needs 3-arg `vim.str_utfindex`).
2. **bridge (environment)**: env var + descriptor (path/pid/cwd/serverVersion/fdAvailable).
3. **bridge (connection)**: `bridge.is_connected()` + `server_info` + `uv.fs_stat(path)`.
4. **external tools (fd)**: `vim.fn.executable({"fd","fdfind"})` (UNCONDITIONAL; WARN not error).

DORMANT ≠ ERROR (no env var → `info "dormant"`). NEVER issues a live `ping` (async/hang risk).
Every probe pcall-wrapped (one throw blanks the whole report).

---

## 7. `ftplugin/pi-prompt.lua` — buffer wiring + teardown

Auto-sourced on `FileType pi-prompt`. Touches ONLY the matched buffer.

### Options: `formatoptions` (strip `t`), `textwidth=0`, `wrap`, `spell=false`.

### Engine suppression (avoid double UI)
`vim.b[buf].completion = false` (blink honors it) + `cmp.setup.buffer({enabled=false})` (pcall).
Opt out via `vim.g.pi_bridge_suppress_engines = false`.

### Keymaps (insert-mode, buffer-local) — via `map_dispatch(mode, lhs, modname, fnname)`
```
<Tab>→on_tab   <S-Tab>→on_prev   <C-N>→on_next   <C-P>→on_prev
<C-E>→on_dismiss   <CR>→on_enter   <Down>→on_next   <Up>→on_prev   <C-Y>→on_enter
```
`dispatch(modname, fnname, buf)` returns true ONLY if module+fn exist AND returned truthy;
else `feedkey(lhs)` falls through to the default (`feedkeys` with `"n"` flag = not-remappable).

### Autocmds (buffer-local, shared "pi-bridge" augroup, `clear=false` + per-buf `nvim_clear_autocmds`)
- **Refresh:** `InsertEnter`/`TextChangedI`/`CursorMovedI` → `completion.refresh(buf)`.
- **Auto-close:** `InsertLeave`→`on_insert_leave`, `BufLeave`→`on_buf_leave`.
- **VimLeavePre/ExitPre teardown** — the requested item:
```lua
if config.autosave_on_exit ~= false then
  for _, ev in ipairs({ "VimLeavePre", "ExitPre" }) do
    vim.api.nvim_create_autocmd(ev, {
      group = group, buffer = buf,
      desc = "pi-bridge: autosave + bridge teardown on " .. ev,
      callback = function() dispatch("pi-bridge.bridge", "on_exit", buf) end,
    })
  end
end
```
`on_exit(buf)` (bridge.lua L832): autosave-if-modified → best-effort `bye` RPC → `M.close()`.
Safe across the ExitPre→VimLeavePre double-fire (gated on `modified`/`is_connected`/`state.closed`).

---

## 8. `coords.lua` — centralized byte↔UTF-16 + nvim↔pi API

PURE stateless library. **EVERY nvim↔pi coordinate translation MUST route through here**
(PRD §8 "MUST be centralized so the fix is one place"). Uses Neovim 0.11+'s 3-arg
`vim.str_utfindex`/`str_byteindex` (`"utf-16"` overload) — EXACT (surrogate pairs counted as 2),
SUPERSEDES PRD §8's codepoint-approximation.

| Function | Signature | Notes |
|---|---|---|
| `M.byte_to_utf16(line, byte_idx)` | 0-based byte → 0-based UTF-16 | clamp `[0,#line]`; EOL legal; never throws. |
| `M.utf16_to_byte(line, utf16_idx)` | inverse | clamp `[0,utf16_len]`; never throws. |
| `M.nvim_to_pi_coords(lines, row, byte_col)` | → `{lines, cursorLine=row-1, cursorCol=UTF16}` | pass-through `lines` (same ref). COLUMN ±0; only ROW ±1. |
| `M.pi_to_nvim_coords(lines, cursorLine, cursorCol)` | → `{lines, row=cl+1, col=byte}` | **NO `-1`** (PRD §7.4's `bytecol-1` is superseded — would nudge cursor left on multibyte). |

`cursorCol` (pi's unit) = a 0-indexed UTF-16 code-unit offset (a JS string index).
`nvim_win_get_cursor(0)` → `{row 1-based, col 0-based BYTE}` (NO ±1 on the column).

---

## 9. Test patterns (`tests/`)

Two flavors per module, both headless:
- **`*_spec.lua`** — plenary/busted (Level-2). Run:
  `nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/<spec>.lua")'`
- **`*_smoke.lua`** — plenary-FREE real-bridge integration (Level-2a). Run:
  `nvim --headless --clean -u NORC +"luafile tests/<module>_smoke.lua" +qa`
  Prints `SMOKE_PASS` / exits 0.

### Common patterns
- **Bootstrap:** `debug.getinfo(1,"S").source` → resolve repo root → `runtimepath:append`.
  `minimal_init.lua` also prepends plenary (default `/home/dustin/.local/share/nvim/lazy/plenary.nvim`).
- **Self-sufficient setup:** `if pi.config==nil then pi.setup({debounce_ms=…}) end` (GOTCHA D).
- **Fake bridge (spec):** `fake_bridge()` mock with controllable `request`/`cancel`/`is_connected` +
  `resolve(i,err,result)`/`resolve_last(err,result)`. Injected via `pi.bridge = fake`.
- **Real server (smoke + bridge_request_spec):** spin a luv `uv.new_pipe` server on a unique
  socket path, decode via `jsonlreader`, reply `hello`→`HelloResult`, then per-call replies.
  Observed requests captured in a `seen[]` array (order-preserving).
- **Async drive:** `vim.wait(ms, predicate, 5)` (interval 5ms) for debounce + RPC round-trip.
- **Reset discipline:** `before_each`/`after_each` → `pi.bridge=nil; completion.on_results=nil;
  completion.reset(); menu.reset()`. (Never name a spec-local table `pending` — shadows
  plenary's skip fn.)
- **Notify tests** stub `vim.notify` locally + `flush()` via `vim.wait` (once() `vim.schedule`s).

---

## Architecture — how the pieces connect

```
plugin/pi-bridge.lua (VimEnter shim)
  └─> init.M.activate()                          [reads PI_NVIM_BRIDGE env]
        ├─ sets filetype="pi-prompt" ────────────► ftplugin/pi-prompt.lua
        │     ├─ 9 keymaps ─► completion.on_tab/on_enter/...
        │     ├─ refresh autocmds ─► completion.refresh
        │     ├─ auto-close autocmds ─► completion.on_insert_leave/on_buf_leave
        │     └─ VimLeavePre/ExitPre ─► bridge.on_exit
        ├─ bridge.handshake(desc, cb)  ─► publishes require("pi-bridge").bridge
        ├─ bridge.on_disconnect(...)   ─► menu.close + completion.reset + notify
        ├─ bridge.on_notification("commandsChanged",…) ─► completion.on_commands_changed
        └─ menu.attach()  ─► sets completion.on_results = menu.on_results

Per keystroke (InsertEnter/TextChangedI/CursorMovedI):
  completion.refresh(buf)
    └─ cancel_timer + compute_debounce ─► vim.defer_fn(do_refresh, ms)
         do_refresh(buf)
           ├─ completion_context gate  (nil → on_results(buf,{},""); return)
           ├─ coords.nvim_to_pi_coords
           ├─ supersede layer1: bridge.cancel(state.inflight_id)
           ├─ supersede layer2: state.gen++ (captured in cb)
           └─ bridge.request("getSuggestions", {lines,cursorLine,cursorCol,force}, cb)
                cb (gen-guard) ─► completion.on_results(buf, items, prefix)
                    └─ menu.on_results ─► open(items)/close() ─► render (floating window)

Accept (on_enter/on_tab): completion.accept(item)
    ├─ coords.nvim_to_pi_coords
    └─ bridge.request("applyCompletion", {lines,cursorLine,cursorCol,item,prefix}, cb)
         cb ─► coords.pi_to_nvim_coords + nvim_buf_set_lines(whole) + nvim_win_set_cursor + menu.close
```

**Key data-flow invariants for a delta:**
- The bridge is read **FRESH** at call time (`require("pi-bridge").bridge`), never cached.
- `completion.on_results(buf, items, prefix)` is the SINGLE result→menu seam (set by `menu.attach`).
- coords is the SINGLE coordinate-translation seam (never call `vim.str_*index` directly).
- The two-layer supersession (cancel + gen-guard) guarantees `on_results` fires ONLY for the
  latest non-stale success — menu TRUSTS it (no re-guard).

---

## Start Here

**`lua/pi-bridge/completion.lua` → `completion_context` at L375.** This local function is the
hard gate that decides whether a keystroke issues a `getSuggestions` RPC. Any new completion
context (shell commands, `$VAR` expansion, etc.) must add a branch here AND be reflected in:
1. `compute_debounce` (L344) — the trigger-aware debounce window.
2. The `force=` param in `do_refresh` (L461) and `force_fetch` (L526).
3. The client-side gate's interaction with pi's server-side provider (which returns null for
   non-completable positions — see header "PI-FAITHFUL ASK ON EVERY CHANGE MODEL", L~128).

Then read **`extension/protocol.ts`** (§C/§D) for the exact wire method/params/result shapes —
if the delta needs a NEW RPC method, `bridge.request(method, params, cb)` already supports it
generically (no bridge change); if it reuses `getSuggestions`, the server-side provider decides.

## Constraints, Risks & Open Questions
- **`completion_context` is NOT exported** (local). A delta that needs to test context
  detection in isolation (like `is_attachment_context` is) may want to export a pure helper.
- **Gen-guard is trigger-agnostic by design** (header L135): do NOT add trigger-awareness to
  the gen-guard — it keys on the monotonic `gen` int only.
- **`[TEMP DEBUG]` traces** (`dbg()` writing to `/tmp/pi-bridge-menu-debug.log`) exist in
  completion.lua (L~167) and menu.lua (L~216). Marked "remove after diagnosing" — flag if
  cleanup is in scope.
- **rpc_timeout_ms invariant** (S40): client 2000ms MUST exceed server fd-abort 1500ms
  (`GET_SUGGESTIONS_TIMEOUT_MS`). A delta adding long-running completions must respect this
  cascade or the client abandons before the server.
- **No `cancel` wire method** (protocol.ts §D): server self-supersedes via AbortController;
  client cancel is local-only. A delta cannot rely on a wire-level cancel.
- **`on_results` is the only extension seam today**: there is no per-context-type menu channel;
  all contexts (slash/path/shell) would share the same single menu + `on_results` slot.
- **Health version floor is 0.11** (coords.lua's 3-arg str_utfindex), NOT PRD §10.1's "0.10+".