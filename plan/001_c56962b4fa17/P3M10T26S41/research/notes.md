# S41 Research Notes — Clear caches + re-query on `commandsChanged`

> Parent: **P3.M10.T26 — `commandsChanged` cache invalidation** (Phase 3 polish, PRD §13
> step 13: "`commandsChanged` notification handling (clear caches)"). 0.5 points.
> Mechanism = **S27 (DONE)**; Behavior = **S41 (this task)**.

## §0 — What S41 actually is

S27 shipped the **MECHANISM**: `bridge.on_notification(method, handler)` — a
`schedule_wrap`'d handler registry + a `dispatch(msg)` branch that routes a
`{"jsonrpc":"2.0","method":"commandsChanged"}` message (no `id`, no `params`) to the
registered handler, plus `M.close()` clearing the registry. **S27 does NOT clear any
cache** — its own research (`P2M5T16S27/research/notes.md` §5) explicitly defers the
*behavior* to S41:

> **Downstream contract (for S41):**
> ```lua
> require("pi-editor").bridge.on_notification("commandsChanged", function(_params)
>   cached_commands = nil  -- clear the cached command list; the next getSuggestions/getCommands re-queries pi.
> end)
> ```

**S41 ships the BEHAVIOR** that consumes that API: register a `commandsChanged` handler
that **clears the completion cache** and **re-queries** so a live menu reflects the
rebuilt provider (PRD §11: "`session_start {reason:"reload"}` re-captures the provider …
emit `commandsChanged`. The open editor's existing connection stays valid.").

## §1 — The caches S41 must invalidate (verified in `plugin/lua/pi-editor/completion.lua`)

`completion.lua` is a **singleton** with one `local state = {…}` (lines 252–259):

| field | meaning | stale after commandsChanged? |
|---|---|---|
| `state.last_result` | `{items, prefix}` — latest non-stale result; read by `current()`/accept/Tab | **YES** — items were computed against the OLD command set |
| `state.inflight_id` | the `bridge.request` id of the in-flight `getSuggestions` | **YES** — its result will be stale |
| `state.gen` | monotonic supersession guard (bumped per fetch; captured in cb closure) | bump it to drop a late stale cb |
| `state.debounce_timer` | the `vim.defer_fn` handle | **YES** — its `do_refresh` would compute against stale state |
| `state.buf` | the buf `refresh()` is debouncing for | **PRESERVE** (re-query needs it) |

The **menu** (`plugin/lua/pi-editor/menu.lua`) holds its OWN copy of the items
(`state.selected`, rendered rows). Clearing `completion.last_result` does NOT clear the
menu — so S41 **must explicitly call `menu.close()`** (clears `selected=0`, `open=false`;
idempotent + never throws — `menu.lua:542`, verified).

`M.reset()` (completion.lua:526) already does: `cancel_timer` + `cancel(inflight_id)` +
`last_result=nil` + `gen=0` + **`buf=nil`**. **S41 can NOT reuse `reset()` directly**
because it nils `state.buf` (the re-query needs it) AND sets `gen=0` rather than bumping.
S41 needs a **targeted invalidate** that preserves `state.buf`.

## §2 — The re-query: WHEN (the `was_open` guard)

Unconditionally re-querying is **wrong**: in NORMAL mode (user just opened the editor /
is reviewing), a `getSuggestions` for the cursor line WOULD return items and the menu
WOULD pop — annoying + diverges from "only complete while actively editing" (pi completes
only on insert-mode keystrokes).

The cleanest, most-faithful, most-testable guard is **"was the menu open?"** (captured
BEFORE we close it). Rationale:
- `menu.is_open()` (menu.lua:614) is an existing, tested public accessor.
- "menu open" precisely means "the user is looking at a live completion menu" — the ONE
  case where a live update matters. The empty-result case (menu closed, `last_result`
  set to `{items={},prefix}`) does NOT re-query — accepted minor edge (the next keystroke
  fetches fresh; documented as a non-goal).
- No dependency on `vim.fn.mode()` (which is fiddly to drive deterministically in a
  headless plenary test) — `was_open` is trivially observable via `populated_menu()`.

So the re-query fires **iff** `was_open AND buf valid AND buf == current buf`. The
provider itself returns `null` (→ empty items → `on_results` → `menu.close`) when the
cursor isn't in a trigger context, so a re-query never spuriously re-opens the menu.

## §3 — Where to register the handler: `init.lua M.activate()` (after handshake)

`plugin/lua/pi-editor/init.lua:134 M.activate()` is where handlers are wired, in a
`pcall(function() … end)` block that:
1. calls `br.handshake(desc, cb)` (async connect + `hello`),
2. THEN registers `br.on_disconnect(function(_reason) menu.close(); completion.reset(); notify.once(...) end)`.

**S41 registers in the SAME block, right after `on_disconnect`.** Two verified GOTCHAs:
- **GOTCHA D (S25, applies to S41 too):** `handshake()` runs `M.close()` at its start,
  which CLEARS `notification_handlers`. So registration MUST come AFTER `handshake()`
  (the existing `on_disconnect` registration already follows this order — mirror it
  exactly). Registering before would be wiped.
- The handler is `schedule_wrap`'d by `on_notification` (S27) → runs on the nvim main
  loop → **api-safe** (can touch `vim.api.*` / buffers / menus). The dispatch runs
  inline from the luv `read_start` callback (luv fast context) — `schedule_wrap` is the
  documented fix (S27 research §4; bridge.lua GOTCHA 5).

## §4 — Design: a dedicated `completion.M.on_commands_changed(buf?)` (Option B)

Two placement options: (A) inline the logic in `init.lua`'s closure; (B) add a public
`completion.M.on_commands_changed(buf?)` and have `init.lua` just register it.

**Option B** (chosen): matches the codebase's cohesion discipline (every module owns its
behavior; `init.lua` only wires) and — critically — gives the logic its OWN plenary spec
(the codebase gives every public function a `_spec.lua` case). `on_disconnect`'s handler
in `init.lua` is a thin orchestration closure (calls `menu.close()` + `completion.reset()`
+ `notify.once`); S41's `on_commands_changed` is the completion module's own method.

Sketch (final shape in PRP §Implementation Blueprint):
```lua
--- Clear the completion cache + close the stale menu; if a menu WAS open (actively
--- completing), re-query so it reflects the rebuilt provider. Called by init.lua's
--- commandsChanged registration (S41). Idempotent + never throws. Preserves state.buf.
---@param buf integer? The pi-prompt buffer (defaults to state.buf).
function M.on_commands_changed(buf)
  buf = buf or state.buf
  local was_open = false
  pcall(function() was_open = require("pi-editor.menu").is_open() end)
  cancel_timer()
  local b = require("pi-editor").bridge
  if state.inflight_id and b and type(b.cancel) == "function" then
    pcall(b.cancel, state.inflight_id)
  end
  state.inflight_id = nil
  state.last_result = nil
  state.gen = state.gen + 1                  -- drop a late stale cb (captured gen won't match)
  pcall(function() require("pi-editor.menu").close() end)
  if not was_open then return end            -- not actively completing — next keystroke fetches fresh
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  if buf ~= vim.api.nvim_get_current_buf() then return end
  pcall(M.refresh, buf)                      -- re-fetch against the rebuilt provider (debounced; provider gates context)
end
```

`init.lua` wiring (in `M.activate()`, same pcall block, after `on_disconnect`):
```lua
-- S41: clear caches + re-query on `commandsChanged` (server rebuilt the provider on
-- /reload/new/resume/fork — PRD §11). Registered AFTER handshake() (handshake() runs
-- M.close() which clears the registry — GOTCHA D). schedule_wrap'd by on_notification
-- (api-safe). Never throws.
if type(br.on_notification) == "function" then
  br.on_notification("commandsChanged", function(_params)
    pcall(function() require("pi-editor.completion").on_commands_changed() end)
  end)
end
```

## §5 — Test conventions (verified `plugin/tests/completion_spec.lua:1–130`)

- `fake_bridge(opts)` — controllable `request`/`cancel`/`is_connected`; cbs fired via
  `fake.resolve_last(err, result)`; `cancel` records + (optionally) fires the cb with
  `"cancelled"` (mirrors real bridge → exercises the gen-guard).
- `reset()` between cases: `pi.bridge=nil; completion.on_results=nil; completion.reset();
  menu.reset(); restore debounce_ms`.
- `wait_for(ms, predicate)` = `vim.wait(ms, predicate, 5)`.
- `populated_menu(line, byte_col, items, prefix)` (shared helper) → real menu via the
  seam (`menu.attach()` → `completion.refresh(buf)` → resolve → `menu.is_open()`). Reuse
  for the "re-query when was_open" cases.
- `bridge_notify_spec.lua` (S27) already covers the MECHANISM end-to-end (real luv
  socket + the exact wire form `{"jsonrpc":"2.0","method":"commandsChanged"}`). S41
  extends it with ONE assertion that the registered S41 handler runs on the notification
  (closes the stale menu — observable) — most behavior is covered by `completion_spec`.

**Runner commands (AGENTS.md §test runner; ALL wrapped in `timeout`):**
- plenary spec: `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/<spec>.lua")'` (run from `plugin/`).
- smoke (no plenary): `timeout 60 nvim --headless --clean -u NORC +"luafile tests/<module>_smoke.lua" +qa`.

No selene/luacheck/stylua config exists in-repo → Level-1 "lint" = the module
`require()`s without error (the smoke IS the load gate). No TS changes (S17 server side
is DONE; the wire form + trigger are unchanged).

## §6 — Non-regression / interactions

- **gen-guard interaction:** bumping `state.gen` (not zeroing) is the drop-a-late-cb
  mechanism shared with `do_refresh`/`force_fetch`. A stale cb captured `gen=N`; after
  bump `state.gen=N+1` → `gen ~= state.gen` → dropped. ✓ (mirrors the existing idiom;
  `reset()` uses `gen=0` which also drops — either works; bump is "forward" + clearer.)
- **refresh↔on_commands_changed re-entrancy:** `M.refresh` just schedules a `vim.defer_fn`
  → no re-entrancy. The re-query's result routes through the SAME `on_results` seam →
  menu reopens with FRESH items (or closes if empty). ✓
- **close() clears the registry (S27):** on `VimLeavePre`/reconnect the old handler is
  dropped; `activate()` re-registers after the next successful handshake. ✓ (matches S27's
  defense-in-depth; the bridge_notify_spec case (9) already proves no leak.)
- **`menu.attach()` idempotency:** `activate()` calls `menu.attach()` (guarded by
  `state.attached`) so a `/reload` re-`activate()` does NOT double-register `on_results`. ✓
- **Other extensions' autocomplete (PRD §11 known limitation):** unchanged — the bridge
  captures `current` at registration; S41 only reacts to the bridge's own `commandsChanged`.

## §7 — Confidence

**9/10.** Pure additive edit (1 new public fn + 1 registration block + tests) onto a
DONE mechanism (S27) with an explicit downstream contract. The only design judgment call
(the `was_open` re-query guard) is well-justified + cleanly testable. Risk: low.