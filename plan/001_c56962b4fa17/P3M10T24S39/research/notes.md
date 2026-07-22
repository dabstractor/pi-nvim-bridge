# Research notes — P3.M10.T24.S39: Graceful failure (single notify + degrade)

Parent task: **P3.M10.T24 — Silent degradation (connect fail, bad handshake, process death)**.
This subtask S39: the **user-facing** half — a single `vim.notify` on hard failure + ensure
the plugin degrades to a normal buffer (completion already auto-bails; S39 adds the notify +
menu cleanup on disconnect).

## 1. The two failure surfaces S39 must cover (from PRD §11)

| Failure | Where detected today | Current behavior | S39 target |
|---|---|---|---|
| **Connect fail** (`ENOENT`/`ECONNREFUSED`/`EACCES`) | `bridge.handshake` → `resolve_handshake(nil, connerr)` → `on_result(errno)` | **swallowed** by the no-op cb in `init.lua` `M.activate()` | one `vim.notify` |
| **Bad handshake** (bad token `-32600`, timeout, malformed, conn-closed-during-handshake) | `bridge.handshake` → `resolve_handshake` → `on_result(emsg)` | **swallowed** by the no-op cb | one `vim.notify` |
| **Process death** (EOF / `ECONNRESET` AFTER a successful handshake) | `bridge.lua` `read_cb` → `on_close` (handshake closure) → `resolve_handshake` **no-ops** (`handshake_state.pending` already false) | **silently dropped** (no notify, stale menu) | one `vim.notify` + `menu.close()` + `completion.reset()` |

The first two are already reachable via the handshake `on_result` cb — init.lua just ignores
it. The third is a **real gap**: after handshake success the connection can drop (pi killed,
socket removed) and nothing surfaces it.

## 2. Degradation to a "normal buffer" is ALREADY automatic (verify, don't reimplement)

`completion.lua` gates EVERY path on `pi.bridge ~= nil AND bridge.is_connected()`:
- `do_refresh` (S30), `accept` (S32), `on_tab` (S33) — each returns early / `false` when the
  bridge is absent or disconnected. Comments literally say "silent degrade (S39 notifies once)".
- `resolve_handshake` (bridge.lua) publishes `require("pi-editor").bridge = M` **only** on
  `result.ok == true` → a failed handshake leaves `pi.bridge == nil` → completion bails.
- `M.close()` sets `state.connected = false` → `is_connected()` returns false → completion bails
  on the next keystroke after process death.

So the buffer already stays editable as plain text. S39's job is the **notify** (UX) + hiding
a **stale menu** on disconnect (a menu populated before the drop would otherwise linger).

## 3. CRITICAL gotcha — the handshake `on_result` cb runs in LUV FAST CONTEXT

Unlike the regular `request` cb (stored `vim.schedule_wrap(on_result)` at `request()` time —
see `resolve_request`), the handshake resolver `resolve_handshake` calls `cb(...)` **inline**
from luv callbacks (the `read_cb`, the handshake `timer` cb, the `connect` cb). It is NOT
schedule-wrapped. So calling `vim.notify` / `vim.api.*` directly from init.lua's handshake cb
throws `E5560` (vim.api from libuv fast context).

⇒ The notify helper MUST `vim.schedule` the `vim.notify` internally so it is callable from
**any** context (luv fast OR nvim main loop). Mirrors how `bridge.on_notification` stores its
handlers `schedule_wrap`d (bridge.lua GOTCHA 5).

## 4. Design — a tiny `notify.lua` + a `bridge.on_disconnect` hook (mirrors `on_notification`)

**`plugin/lua/pi-editor/notify.lua`** (NEW): dedup'd one-shot notify.
```lua
local M = {}
local seen = {}
function M.once(category, level, msg)     -- category defaults to "bridge"
  category = (type(category)=="string" and category~="") and category or "bridge"
  if seen[category] then return end
  seen[category] = true
  vim.schedule(function()                 -- schedule => safe from luv fast context
    pcall(vim.notify, msg, level or vim.log.levels.WARN, { title = "pi-editor" })
  end)
end
function M.reset() seen = {} end          -- tests
function M.did_notify(category) return seen[category or "bridge"] == true end
return M
```
Single category `"bridge"` collapses connect-fail + bad-handshake + process-death to **ONE**
notify per session (PRD §11 "a single vim.notify the first time" / "notify once").

**`plugin/lua/pi-editor/bridge.lua`** (EDIT): add `M.on_disconnect(handler)` — the EXACT shape
of `M.on_notification` (single slot, last-wins, schedule_wrap'd, nil removes). Fire it from
`read_cb`'s EOF + read-error branches, gated on `not (handshake_state and handshake_state.pending)`
(so an active-handshake drop lets the handshake cb speak; a post-success drop fires
disconnect). `M.close()` clears the slot (hygiene, mirrors `notification_handlers = {}`).

**`plugin/lua/pi-editor/init.lua`** (EDIT): replace the no-op handshake cb
(`function(_err,_info) end`) with one that calls `notify.once("bridge", WARN, ...)`, and
register a `bridge.on_disconnect` handler AFTER `handshake()` (notify + `menu.close()` +
`completion.reset()`, all pcall-wrapped). Register AFTER `handshake()` because `handshake()`
runs `M.close()` synchronously at its start (idempotent re-init) which would clear an
earlier registration.

## 5. Test harness — mirror `bridge_notify_spec.lua` exactly

`plugin/tests/bridge_notify_spec.lua` is the perfect template:
- `with_request_server(opts, spec)` spins a REAL luv Unix-socket server (unique path), decodes
  client traffic via the jsonlreader, replies a valid `hello` HelloResult.
- `with_handshaken_server(server_opts, spec)` runs the handshake FIRST so dispatch is wired +
  `state.connected`, then hands control to the inner spec.
- `reset_module()` between cases (close + clear `pi.bridge`).
- Do NOT name a spec-local `pending` (shadows plenary's skip fn).

For S39's process-death case: after `with_handshaken_server`, register `on_disconnect`,
then `server_conn:close()` (server-side half-close → client `read_cb` sees EOF) and assert the
disconnect handler fired + `pi.bridge` is still the module but `is_connected()` is false.

`activate_spec.lua` shows the gate-test pattern (`vim.env.PI_NVIM_BRIDGE = ...; pi.activate()`).
Extend it with: a descriptor whose `path` points at a non-existent socket → `activate()` fires
exactly one `notify.once("bridge", ...)` (assert via `notify.did_notify("bridge")`).

## 6. Why NOT a simpler design

- **No `on_disconnect`, notify straight from `read_cb`?** Breaks layering — `bridge.lua` is the
  transport layer; it must not `require("pi-editor.notify")` (UI). The hook keeps bridge an
  event emitter + lets init.lua own UX — exactly the `on_notification`/S41 split.
- **No notify module, inline `vim.notify` in init.lua?** Then dedup logic lives in init.lua and
  the luv-fast-context scheduling must be remembered at each call site. A 15-line `notify.lua`
  centralizes both + is unit-testable. Matches the repo's "one responsibility per module" style.
- **Fire disconnect from `close()` instead of `read_cb`?** `close()` is also called by the
  PLANNED `on_exit` (S38 teardown) + reconnect — firing there would notify on a graceful quit
  (wrong). `read_cb` (the pipe-drop detector) is the only correct trigger.

## 7. Out of scope (other P3.M10 subtasks)

- S40 (configurable debounce/timeout/supersession tuning) — separate.
- S41 (commandsChanged cache invalidation) — consumes `on_notification`, unrelated.
- S42 (`:checkhealth`) — `health.lua` does not exist yet; out of scope.