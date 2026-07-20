# PRP — P3.M10.T24.S39: Graceful failure — degrade to normal buffer with single notify

**Work item**: P3.M10.T24.S39 — "Graceful failure — degrade to normal buffer with single
notify" (1 point, module P3.M10 "Resilience & UX Polish"; parent task P3.M10.T24 "Silent
degradation — connect fail, bad handshake, process death").

**Scope**: Add a **one-time, deduplicated `vim.notify`** for the three hard-failure surfaces
named in PRD §11 (stale/missing socket → connect fail; bad handshake → bad token / timeout /
malformed; pi process death → socket EOF/ECONNRESET after a successful handshake), and ensure
the plugin **degrades to a normal, fully-editable buffer** (completion auto-bails today; S39
adds hiding a stale menu on disconnect). Concretely: **(a)** a new tiny `notify.lua` module
(context-safe + dedup'd), **(b)** a new `bridge.on_disconnect(handler)` hook on `bridge.lua`
(mirrors the existing `on_notification`), and **(c)** wiring both into `init.lua`'s activation
flow (replace the current no-op handshake callback + register a disconnect handler).

---

## Goal

**Feature Goal**: When pi launches Neovim as `$EDITOR` but the completion bridge is
unreachable (connect refused / socket missing), rejects the handshake (bad token / timeout /
malformed), or dies mid-session (socket EOF / read error after a successful handshake), the
plugin emits **at most one** `vim.notify` (WARN level, `title = "pi-editor"`) for the whole
session, hides any stale completion menu, and leaves the buffer as a normal editable prompt —
**never** blocking startup, **never** throwing, **never** spamming.

**Deliverable**:
1. **NEW** `plugin/lua/pi-editor/notify.lua` — a ≤20-line dedup'd, context-safe
   `M.once(category, level, msg)` helper (+ `M.reset()` / `M.did_notify(category)` for tests).
2. **EDIT** `plugin/lua/pi-editor/bridge.lua` — add `M.on_disconnect(handler)` (single-slot,
   last-wins, `schedule_wrap`'d, nil-removes — the exact shape of `M.on_notification`), a
   module-local `disconnect_handler`, a `fire_disconnect(reason)` local fired from `read_cb`'s
   EOF + read-error branches (gated so an unresolved handshake lets the handshake cb speak),
   and clear the slot in `M.close()` (hygiene, mirrors `notification_handlers = {}`).
3. **EDIT** `plugin/lua/pi-editor/init.lua` — replace the no-op handshake callback
   (`function(_err, _info) end`) in `M.activate()` with one that calls
   `notify.once("bridge", vim.log.levels.WARN, ...)`, and register a `bridge.on_disconnect`
   handler (notify + `menu.close()` + `completion.reset()`, all `pcall`-wrapped) **after**
   the `handshake()` call.
4. **NEW** `plugin/tests/notify_spec.lua` (plenary) + a plenary-free
   `plugin/tests/notify_smoke.lua`; **NEW** `plugin/tests/bridge_disconnect_spec.lua`
   (plenary, mirrors `bridge_notify_spec.lua`); **EXTEND** `plugin/tests/activate_spec.lua`
   with the bad-socket → single-notify case.

**Success Definition**:
- A pi-launched Neovim whose `PI_EDITOR_BRIDGE` points at a **non-existent / refused** socket
  emits exactly **one** WARN notify (first failure only) and the buffer remains a normal,
  editable pi-prompt (filetype set, keymaps active, completion silently inert).
- A pi-launched Neovim whose bridge **rejects the token** (`-32600`) / **times out** /
  **returns a malformed hello** emits exactly **one** WARN notify; `pi.bridge` stays `nil`.
- After a **successful handshake**, if the bridge socket drops (server `:close()` / pi killed
  → client `read_cb` sees EOF or a read error), the registered disconnect handler fires
  **once**, the menu is closed, completion state is reset, and **one** WARN notify is shown.
- Across **all three** surfaces in one session, the user sees **at most one** notify total
  (dedup by category `"bridge"`).
- No notify ever fires in an ordinary (non-pi) Neovim session (the env-var gate stays silent —
  dormant is normal, not a failure).
- No path throws; no path blocks startup; no path spams (repeated ECONNRESET / repeated
  keystrokes after disconnect each notify at most once).

---

## Why

- **PRD §11 (the load-bearing requirements):**
  - *"Stale/missing socket. If `connect()` fails or `hello` errors, the plugin must **degrade
    silently** to a normal buffer (no completion), **optionally with a single `vim.notify` the
    first time**. **Never block startup or spam.**"*
  - *"pi process dies while editor open. The socket closes; the plugin **detects EOF on the
    pipe, stops completion, and may notify once**."*
  This task is the user-facing realization of both bullet points. "Silently degrade" was the
  P1/P2 default (completion already bails); S39 adds the single notify + the process-death
  detection (currently a real gap — see Context).
- **Closes the explicit forward-contract left by S21/S25:** `init.lua`'s activation gate
  registers the handshake with a **no-op callback** and its comments say verbatim *"the
  one-time `vim.notify` on hard failure is task S39's job"* (twice — at the gate docstring
  `init.lua:110` and at the handshake wiring `init.lua:135`). Likewise `completion.lua`'s
  `do_refresh`/`accept`/`on_tab` each say *"silent degrade (S39 notifies once)"*. S39 is the
  named owner of the notify across the whole completion stack.
- **Process death is a genuine hole today:** after a successful handshake, the `on_close`
  closure registered by `M.handshake` (`function(reason) resolve_handshake(nil, reason) end`)
  **no-ops** because `handshake_state.pending` is already `false`. So a mid-session socket
  drop is currently invisible to the user (the menu could even stay open with stale items
  until the next keystroke). S39 adds the `on_disconnect` hook that surfaces it.

---

## What

**User-visible behavior**: the user opens the pi external editor (`Ctrl+G`). If the bridge
extension isn't running / the socket is stale / the token mismatches / pi crashes mid-edit,
the user sees a **single** unobtrusive warning (`pi-editor: completion unavailable — …` /
`pi-editor: bridge connection lost — completion disabled`) and can keep typing their prompt
normally; quitting still submits whatever they typed (S38 autosave is independent). No
repeated toasts, no errors, no hung UI.

**Technical requirements**:
1. **One new module** `notify.lua` with a single public `M.once(category, level, msg)`. It
   `vim.schedule`s the `vim.notify` (so it is callable from luv fast context — see Gotcha C)
   and dedups by `category` (default `"bridge"`) so all bridge failures collapse to one toast.
2. **One new hook** `bridge.on_disconnect(handler)` that fires when the transport pipe drops
   (EOF or read error in `read_cb`) **after** the handshake has resolved (gated on
   `not (handshake_state and handshake_state.pending)`). Identical shape/API to the existing
   `on_notification` (single slot, last-wins, `schedule_wrap`'d at registration, nil removes).
3. **init.lua wiring**: the handshake callback notifies on `err`; a disconnect handler
   (registered after `handshake()`) notifies + closes the menu + resets completion state.
4. **Degradation is NOT reimplemented** — it already works (completion gates on `pi.bridge` +
   `is_connected()`; `resolve_handshake` only publishes `pi.bridge` on success). S39 only
   verifies it and adds menu cleanup on disconnect.
5. Throw-free, block-free, spam-free on every path; dormant in every non-pi session.

### Success Criteria

- [ ] `notify.lua` exists and `require("pi-editor.notify").once` is a function.
- [ ] `notify.once("bridge", lvl, msg)` calls `vim.notify` **exactly once** per category per
      session; a 2nd call with the same category is a silent no-op (dedup).
- [ ] `notify.once` is safe to call from luv fast context (the `vim.notify` is `vim.schedule`d;
      calling `once` from inside a `uv.new_timer()` callback does NOT throw `E5560`).
- [ ] `bridge.on_disconnect(handler)` is a function; the handler is invoked when the transport
      pipe drops (EOF or read error) **after** a successful handshake.
- [ ] The disconnect handler runs on the nvim main loop (`vim.api.*` inside it does NOT throw
      `E5560` — it is `schedule_wrap`'d at registration, mirroring `on_notification`).
- [ ] `on_disconnect(nil)` removes the handler; re-registration is last-wins; bad args
      (non-function) never throw.
- [ ] Disconnect does NOT fire while a handshake is unresolved (`handshake_state.pending`) —
      the handshake callback owns that path (avoids a redundant/double notify; dedup covers
      the overlap anyway).
- [ ] `M.close()` clears the disconnect handler slot (no stale handler across reconnects;
      mirrors `notification_handlers = {}`).
- [ ] `activate()` with a descriptor whose `path` is a non-existent socket emits **one**
      `notify.once("bridge", …)` and leaves `pi.bridge == nil`.
- [ ] `activate()` with a descriptor whose bridge rejects the token / times out / returns
      malformed emits **one** `notify.once("bridge", …)`; `pi.bridge == nil`.
- [ ] After a successful handshake, a server-side `:close()` (EOF) or a read error fires the
      disconnect handler **once**, closes the menu, resets completion, and emits **one** notify.
- [ ] Across connect-fail + handshake-fail + process-death in one session, **at most one**
      notify reaches the user (dedup by category `"bridge"`).
- [ ] No notify fires when `PI_EDITOR_BRIDGE` is unset (ordinary nvim session — dormant).
- [ ] No path throws, blocks startup, or spams (repeated keystrokes after disconnect do not
      re-notify).
- [ ] New `notify_spec.lua` + `bridge_disconnect_spec.lua` pass; `activate_spec.lua` extended
      case passes; new `notify_smoke.lua` passes.
- [ ] Existing `bridge_notify_spec.lua`, `bridge_spec.lua`, `bridge_request_spec.lua`,
      `bridge_handshake_spec.lua`, `activate_spec.lua` (existing cases) still pass unchanged.

---

## All Needed Context

### Context Completeness Check

An implementer who knows nothing about this codebase can implement S39 from this PRP + the
four files it names (`init.lua`, `bridge.lua`, `notify.lua` [new], `completion.lua` [read]),
the PRD §11/§12 excerpts below, and the established test patterns (`bridge_notify_spec.lua`).
The exact wiring points, the luv-fast-context scheduling requirement, the dedup contract, and
the precise test runners are all specified below with line citations.

### Documentation & References

```yaml
# MUST READ — the PRD sections that govern this task (already merged into PRD.md)
- url: PRD.md §11 (Edge Cases, Failure Modes & Limitations)
  why: the three failure surfaces + the exact "single vim.notify" / "notify once" / "degrade silently" / "never block startup or spam" contract
  critical: (1) stale/missing socket → degrade silently + optional ONE notify, never block/spam; (2) process death → detect EOF on the pipe, stop completion, notify once; (3) NO-session/print-mode guard is the extension's job, NOT ours — but we must not notify when the env var is simply absent (dormant is normal).
- url: PRD.md §12 (Security)
  why: "Never log the token." Our notify messages MUST NOT include desc.token or any raw errno that could echo it (errno names like ENOENT are safe; the token never appears in RPC responses anyway — verified by the server tests).
  critical: the bridge's handshake error strings are already token-free ("handshake rejected (-32600)", "invalid descriptor", bare errno) — forward them VERBATIM into the notify; do NOT construct messages from desc.

# The file you EDIT — the activation gate + the no-op handshake callback (THE primary wiring point)
- file: plugin/lua/pi-editor/init.lua
  why: M.activate() currently calls `bridge.handshake(desc, function(_err,_info) end)` (no-op cb). Its comments (lines ~110 + ~135) EXPLICITLY name S39 as the owner of the one-time notify. This is where the handshake-failure notify + the disconnect-handler registration go.
  pattern: read the S21 gate logic (env-var → decode → transport check → set filetype → pcall handshake → pcall menu.attach). S39 replaces ONLY the no-op cb + adds the on_disconnect registration; the gate logic is unchanged.
  gotcha: register the disconnect handler AFTER `br.handshake(...)` returns — handshake() runs M.close() synchronously at its start (idempotent re-init), which clears the handler slot; registering after survives it.

# The file you EDIT — add M.on_disconnect + fire from read_cb + clear in close()
- file: plugin/lua/pi-editor/bridge.lua
  why: home of the transport (read_cb detects EOF/read-error), M.handshake (on_close wiring), M.close (the single teardown), and the existing M.on_notification (the EXACT template to clone for on_disconnect). The handshake on_result cb runs INLINE from luv callbacks (resolve_handshake is NOT schedule_wrap'd) — see Gotcha C.
  pattern: read the [Mode A] header GOTCHAs 2/4/5/9/10 + the S25/S26/S27 EXTENSION blocks. on_disconnect is a 4th protocol-consumer sibling of on_notification (S27): single-slot, schedule_wrap'd at registration, fired from read_cb, cleared in close().
  gotcha: read_cb fires on_close THEN M.close(). Fire disconnect BEFORE M.close() (close() will nil the handler slot — fire reads it first). Gate on `not (handshake_state and handshake_state.pending)` so an active handshake's drop is owned by the handshake cb.

# The file you CREATE — the dedup'd, context-safe notify helper
- file: plugin/lua/pi-editor/notify.lua   (NEW)
  why: centralizes (a) the dedup-by-category (so connect-fail + handshake-fail + process-death collapse to ONE toast) and (b) the vim.schedule wrapping (so the handshake cb — luv fast context — can call it without throwing E5560). A 15-line module; mirrors the repo's one-responsibility-per-module style.
  pattern: pure Lua + vim.schedule + vim.notify + vim.log.levels (all built in). No nvim buf/win state.

# READ-ONLY — confirms degradation already auto-bails (do NOT reimplement)
- file: plugin/lua/pi-editor/completion.lua
  why: do_refresh (S30), accept (S32), on_tab (S33) each gate on `pi.bridge ~= nil AND bridge.is_connected()` and return early / false. Comments say "silent degrade (S39 notifies once)". The menu cleanup on disconnect (menu.close + completion.reset) is the ONLY completion-side concern, and it is driven from init.lua's disconnect handler, NOT from completion.lua itself.
  gotcha: completion.reset() cancels the debounce timer + any in-flight RPC + clears last_result + sets gen=0 — call it from the disconnect handler so a stale do_refresh cannot re-open the menu after the drop.

# READ-ONLY — the menu cleanup target (menu.close hides the floating window)
- file: plugin/lua/pi-editor/menu.lua
  why: M.close() clears items/selected/open + closes the floating window via render(). Idempotent + never throws. The disconnect handler pcalls it so a stale menu (populated before the drop) is hidden.

# Test patterns to mirror EXACTLY
- file: plugin/tests/bridge_notify_spec.lua
  why: the canonical pattern for "spin a real luv Unix-socket server, run the hello handshake, observe a client-side event". S39's bridge_disconnect_spec.lua clones its `with_request_server(opts, spec)` + `with_handshaken_server(server_opts, spec)` + `descriptor(path)` + `reset_module()` harness verbatim.
  pattern: after with_handshaken_server, register on_disconnect, then `server_conn:close()` (server half-close → client read_cb sees EOF) and assert the handler fired once + is_connected()==false.
  gotcha: do NOT name a spec-local table `pending` (shadows plenary.busted's skip function — the file warns about this).
- file: plugin/tests/activate_spec.lua
  why: the gate-test pattern (`vim.env.PI_EDITOR_BRIDGE = …; pi.activate()`). S39 extends it with a bad-socket case → assert notify.did_notify("bridge") and pi.bridge == nil.
  pattern: `package.loaded["pi-editor"] = nil` per test for a fresh module; reset notify via `require("pi-editor.notify").reset()` in before_each.

# Neovim runtime facts (verified)
- docfile: plan/001_c56962b4fa17/P3M10T24S39/research/notes.md
  section: §3 (luv-fast-context gotcha) + §4 (design) + §6 (why not simpler)
  why: the handshake on_result cb is NOT schedule_wrap'd (unlike the request cb) → notify MUST schedule; the single-category dedup design; why a hook (not a direct notify from read_cb) preserves layering.
```

### Current Codebase tree (relevant slice)

```bash
plugin/
  lua/pi-editor/
    init.lua          # EDIT — replace no-op handshake cb + register on_disconnect (S39)
    bridge.lua        # EDIT — add M.on_disconnect + disconnect_handler + fire_disconnect + clear in close()
    notify.lua        # CREATE — dedup'd, context-safe M.once(category, level, msg)
    completion.lua    # READ-ONLY — already auto-bails (pi.bridge/is_connected gates); reset() is the cleanup seam
    menu.lua          # READ-ONLY — M.close() is the menu-hide target (pcall'd from the disconnect handler)
  plugin/pi-editor.lua # READ-ONLY — VimEnter → activate() (once); unchanged
  ftplugin/pi-prompt.lua # READ-ONLY — unchanged
  tests/
    notify_spec.lua           # CREATE — plenary (Level 2)
    notify_smoke.lua          # CREATE — plenary-free (Level 1)
    bridge_disconnect_spec.lua # CREATE — plenary, mirrors bridge_notify_spec.lua (Level 2)
    activate_spec.lua         # EXTEND — bad-socket → single-notify case
    bridge_notify_spec.lua    # READ-ONLY regression — must stay green
```

### Desired Codebase tree with files to be added/edited

```bash
plugin/lua/pi-editor/notify.lua              # CREATE (≈20 lines)
plugin/lua/pi-editor/bridge.lua              # MODIFY (≈ +35 lines: on_disconnect + disconnect_handler + fire_disconnect + 2 read_cb inserts + 1 close() line)
plugin/lua/pi-editor/init.lua                # MODIFY (replace ≈8-line no-op block with ≈20-line notify+disconnect block)
plugin/tests/notify_spec.lua                 # CREATE — plenary spec (Level 2 gate for notify.lua)
plugin/tests/notify_smoke.lua                # CREATE — plenary-free smoke (Level 1 gate)
plugin/tests/bridge_disconnect_spec.lua      # CREATE — plenary spec (Level 2 gate for on_disconnect)
plugin/tests/activate_spec.lua               # EXTEND — add the bad-socket → single-notify case(s)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- GOTCHA A (CRITICAL — drives the notify design): the handshake `on_result` cb runs INLINE
-- from luv callbacks (resolve_handshake calls cb(...) directly from read_cb / the handshake
-- timer / the connect cb — it is NOT schedule_wrap'd, UNLIKE resolve_request which stores
-- cb = vim.schedule_wrap(on_result) for regular requests). So calling vim.notify / vim.api.*
-- directly from init.lua's handshake cb throws E5560 (vim.api from libuv fast context).
-- ⇒ notify.once MUST vim.schedule the vim.notify internally so it is callable from ANY
--   context (luv fast OR nvim main loop). (bridge.lua [Mode A] header GOTCHA 5 documents the
--   identical rule for on_notification's dispatch.)

-- GOTCHA B (single notify / no spam): PRD §11 says "a single vim.notify the first time" /
-- "notify once". connect-fail, handshake-fail, and process-death must collapse to ONE toast
-- per session. Dedup by a single category "bridge" in notify.lua. Repeated ECONNRESET on a
-- dead pipe, or repeated keystrokes after disconnect (completion bails silently), MUST NOT
-- re-notify. (completion.lua's do_refresh/accept/on_tab already return early when
-- pi.bridge==nil OR is_connected()==false → they never reach notify.)

-- GOTCHA C (dormant is NORMAL, not a failure): in every ordinary (non-pi) nvim session
-- PI_EDITOR_BRIDGE is unset → activate() returns nil BEFORE touching the bridge → NO notify.
-- Do NOT notify on "no env var" / "malformed descriptor" / "wrong transport" — those are the
-- documented dormant paths (activate() treats them as "not a pi session"). Notify fires ONLY
-- when we genuinely TRIED to connect and failed (inside the handshake cb err path) or lost a
-- connection we had (the disconnect handler).

-- GOTCHA D (register on_disconnect AFTER handshake()): M.handshake() calls M.close()
-- synchronously at its start (idempotent re-init — "M.close() // idempotent; clears any prior
-- handshake_state / server_info"). M.close() clears the disconnect_handler slot (hygiene).
-- So if init.lua registers on_disconnect BEFORE calling handshake(), the registration is
-- wiped. Register it AFTER `br.handshake(...)` returns (handshake is async — the connect is
-- async — so by the time the pipe actually establishes/drops, the synchronous registration
-- is already in place).

-- GOTCHA E (fire disconnect from read_cb, NOT from close()): close() is also called by the
-- PLANNED on_exit (S38 teardown) and by reconnect. Firing disconnect from close() would
-- notify on a graceful :q (wrong). read_cb (the luv pipe-drop detector: EOF = data==nil, read
-- error = err~=nil) is the ONLY correct trigger for "the connection was lost".

-- GOTCHA F (gate disconnect during active handshake): while handshake_state.pending is true
-- (handshake unresolved), a pipe drop is a HANDSHAKE failure (connect-closed-during-handshake
-- / the server's -32600 + close), owned by the handshake cb. Gate fire_disconnect on
-- `not (handshake_state and handshake_state.pending)` so the handshake cb speaks first (its
-- message is more accurate). Dedup covers any overlap anyway (same category "bridge").

-- GOTCHA G (fire BEFORE close() in read_cb): M.close() nils disconnect_handler (hygiene).
-- read_cb must read+schedule the handler BEFORE calling M.close(). The existing read_cb
-- already captures `local cb = state.on_close` before close() for the same reason — mirror
-- that pattern: capture/fire disconnect right after `local cb = state.on_close`, before M.close().

-- GOTCHA H (security — never the token): PRD §12. The bridge's handshake error strings are
-- ALREADY token-free ("handshake rejected (-32600)", "invalid descriptor", "handshake
-- timeout", bare errno names like "ENOENT"/"ECONNREFUSED"). Forward them VERBATIM into the
-- notify message. Do NOT build messages from desc.token. (The token never appears in RPC
-- responses — verified by the extension's server tests.)

-- GOTCHA I (disconnect handler does API work — must run on the main loop): the handler calls
-- menu.close() + completion.reset() + notify.once (all nvim-API-ish). The bridge stores it
-- schedule_wrap'd at registration (mirrors on_notification), so it runs on the nvim main loop
-- → safe. notify.once ALSO schedules internally (belt-and-suspenders; harmless double-schedule).

-- GOTCHA J (no health.lua yet): S42 (:checkhealth) is PLANNED, not done — do NOT create or
-- reference health.lua. notify.lua is standalone.
```

---

## Implementation Blueprint

### Data models and structure

No new data models. `notify.lua` owns one module-local `seen = {}` (category → `true`).
`bridge.lua` gains one module-local `disconnect_handler` (a `schedule_wrap`'d fn or `nil`).
`init.lua`'s `M.activate()` gains two lambdas (the notify-on-error handshake cb + the
disconnect handler) — no new public API on `init.lua`.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE plugin/lua/pi-editor/notify.lua
  - IMPLEMENT (exact body — copy this; ≈20 lines):
      --- notify.lua — one-time, dedup'd, context-safe failure notification (S39).
      -- Centralizes (a) dedup-by-category so connect-fail + handshake-fail + process-death
      -- collapse to ONE toast per session (PRD §11 "a single vim.notify the first time" /
      -- "notify once"), and (b) the vim.schedule wrapping so the handshake `on_result` cb
      -- (which runs INLINE from luv fast context — bridge.lua resolve_handshake is NOT
      -- schedule_wrap'd, unlike resolve_request) can call once() WITHOUT throwing E5560.
      -- Mirrors the repo's one-responsibility-per-module style (cf. jsonlreader.lua).
      local M = {}
      local seen = {}  -- category -> true (the dedup set)
      --- Emit `vim.notify(msg, level, {title="pi-editor"})` AT MOST ONCE per `category` per
      --- session. Subsequent calls with the same category are silent no-ops (PRD §11 "never
      --- spam"). `vim.schedule`s the notify so this is safe to call from luv fast context
      --- (the handshake cb) OR the nvim main loop (the disconnect handler). Never throws
      --- (pcall the notify; bad args degrade to defaults). Default category "bridge"; default
      --- level WARN.
      ---@param category string? Dedup key (default "bridge" — all bridge failures collapse to one toast).
      ---@param level integer? vim.log.levels.* (default WARN).
      ---@param msg string The human-readable message.
      function M.once(category, level, msg)
        if type(category) ~= "string" or category == "" then category = "bridge" end
        if seen[category] then return end
        seen[category] = true
        local l = (type(level) == "number") and level or vim.log.levels.WARN
        vim.schedule(function()
          pcall(vim.notify, msg, l, { title = "pi-editor" })
        end)
      end
      --- Clear the dedup set (for tests + a future explicit re-arm). Never throws.
      function M.reset() seen = {} end
      --- Whether once() has already fired for `category` (default "bridge"). For tests.
      ---@param category string? 
      ---@return boolean
      function M.did_notify(category)
        return seen[(type(category)=="string" and category~="") and category or "bridge"] == true
      end
      return M
  - NAMING: snake_case locals/fields (matches the file's style — cf. jsonlreader.lua's `buffer`).
  - PLACEMENT: plugin/lua/pi-editor/ (alongside the other modules; required as "pi-editor.notify").

Task 2: EDIT plugin/lua/pi-editor/bridge.lua — add the on_disconnect hook
  - SUB-STEP 2a: add the module-local slot. FIND the `notification_handlers = {}` declaration
    (the S27 block) and ADD immediately after it:
        --- S39: single disconnect-handler slot (the pipe-drop event consumer). Mirrors
        --- `notification_handlers`/`on_notification` (S27) but a SINGLE slot (last-wins) since
        --- there is exactly one disconnect event. schedule_wrap'd at registration (GOTCHA 5/I —
        --- fired from the luv read_cb; raw vim.api.* throws E5560 there). nil'd by close()
        --- (hygiene — no stale handler across reconnects; mirrors notification_handlers = {}).
        --- Fired by the local `fire_disconnect` from read_cb's EOF + read-error branches.
        local disconnect_handler = nil
  - SUB-STEP 2b: add the `fire_disconnect` local. FIND the forward-declarations block
    (`local resolve_handshake ... local dispatch ... local autosave_if_modified`) and ADD:
        local fire_disconnect  -- (reason) — S39: fire the disconnect handler from read_cb (defined below).
    Then DEFINE it (place it just above `read_cb`, or alongside `dispatch`):
        --- S39: fire the registered disconnect handler when the transport pipe drops (EOF or
        --- read error) AFTER the handshake has resolved. Gated on `not (handshake_state and
        --- handshake_state.pending)` so an UNRESOLVED handshake's drop is owned by the handshake
        --- cb (its message is more accurate; dedup covers the overlap anyway — GOTCHA F). Runs
        --- INLINE from the luv read_cb; the handler itself is schedule_wrap'd at registration
        --- (GOTCHA 5/I) so its nvim-API work (menu.close/completion.reset/notify) defers to the
        --- safe nvim loop. Reads the module slot BEFORE close() nils it (GOTCHA G). Never throws.
        ---@param reason string? nil = clean EOF; bare errno string (e.g. "ECONNRESET") = read error.
        fire_disconnect = function(reason)
          if handshake_state and handshake_state.pending then return end -- active handshake owns it
          local h = disconnect_handler
          if type(h) == "function" then pcall(h, reason) end
        end
  - SUB-STEP 2c: fire it from read_cb. FIND the current read_cb body:
        if err then -- read error (e.g. "ECONNRESET")
          local cb = state.on_close
          M.close()
          if cb then cb(err) end
          return
        end
        if data == nil then -- EOF (err==nil && data==nil) — GOTCHA 4
          if state.rx then state.rx:flush() end -- deliver any trailing line via on_event FIRST
          local cb = state.on_close
          M.close()
          if cb then cb(nil) end
          return
        end
    REPLACE with (insert fire_disconnect right after `local cb = state.on_close`, BEFORE M.close()):
        if err then -- read error (e.g. "ECONNRESET")
          local cb = state.on_close
          fire_disconnect(err)  -- S39: pipe-drop notify (post-handshake); gated inside
          M.close()
          if cb then cb(err) end
          return
        end
        if data == nil then -- EOF (err==nil && data==nil) — GOTCHA 4
          if state.rx then state.rx:flush() end -- deliver any trailing line via on_event FIRST
          local cb = state.on_close
          fire_disconnect(nil)  -- S39: EOF disconnect (post-handshake); gated inside
          M.close()
          if cb then cb(nil) end
          return
        end
  - SUB-STEP 2d: add M.on_disconnect (public). PLACE immediately after M.on_notification (the
    S27 block). Mirror its docstring + guards EXACTLY (single-slot variant):
        --- Register (or replace / remove) the SINGLE disconnect handler — fired when the
        --- transport pipe drops (EOF or read error in read_cb) AFTER a successful handshake
        --- (process death / dropped connection; PRD §11). The sibling of `on_notification`
        --- (S27): same shape, but a single slot (last-wins) since there is one disconnect event.
        --- handler(reason) runs on the next nvim main-loop pass (`reason` is nil for clean EOF
        --- or a bare errno string for a read error). Pass nil to remove. Never throws.
        ---@param handler fun(reason:string?)|nil Called when the pipe drops post-handshake.
        function M.on_disconnect(handler)
          if handler == nil then disconnect_handler = nil; return end -- remove
          if type(handler) ~= "function" then return end              -- bad arg -> no-op
          disconnect_handler = vim.schedule_wrap(handler)             -- GOTCHA 5/I: safe from luv read_cb
        end
  - SUB-STEP 2e: clear the slot in M.close(). FIND the `notification_handlers = {}` line
    inside M.close() (the S27 hygiene line) and ADD immediately after it:
        disconnect_handler = nil  -- S39: clear the disconnect slot (hygiene; no stale handler across reconnects)
  - PRESERVE: every other line of bridge.lua (the transport, handshake, request, notification,
    on_exit are all COMPLETE — S24/S25/S26/S27/S38). Do NOT change read_cb's flush ordering,
    M.close()'s double-close guard, or resolve_handshake's exactly-once semantics.
  - NAMING: on_disconnect / disconnect_handler / fire_disconnect (mirrors on_notification /
    notification_handlers / dispatch).

Task 3: EDIT plugin/lua/pi-editor/init.lua — wire the notify + the disconnect handler
  - FIND the S25 handshake wiring block in M.activate() (the `pcall(function() ... br.handshake(desc,
    function(_err,_info) end) ... end)` block, ≈ lines 127–139, INCLUDING the 6-line comment
    above it that says "the one-time `vim.notify` is task S39's job").
  - REPLACE that whole block (comment + pcall) with:
        -- S25 + S39: connect + `hello` handshake (async), then surface a SINGLE notify on hard
        -- failure (connect refused / bad token / timeout / malformed — PRD §11). pcall so a
        -- bridge bug can NEVER break activation (the buffer still works as plain markdown).
        -- The handshake `on_result` cb runs INLINE from luv fast context (resolve_handshake is
        -- NOT schedule_wrap'd) → notify.once schedules the vim.notify internally (GOTCHA A/C).
        -- `bridge.handshake` sets `require("pi-editor").bridge` on success ONLY (stays nil on
        -- failure → completion auto-bails → degrade to a normal buffer). Register the disconnect
        -- handler AFTER handshake() (handshake() runs M.close() at its start which would clear
        -- an earlier registration — GOTCHA D).
        pcall(function()
          local ok, br = pcall(require, "pi-editor.bridge")
          if not ok or type(br.handshake) ~= "function" then return end
          br.handshake(desc, function(err, _info)
            if err == nil then return end -- success
            -- forward the bridge's token-free error string VERBATIM (GOTCHA H; PRD §12)
            require("pi-editor.notify").once("bridge", vim.log.levels.WARN,
              "pi-editor: completion unavailable — " .. tostring(err))
          end)
          -- S39: process-death (post-handshake socket drop) → single notify + hide stale menu +
          -- cancel pending completion. The handler is schedule_wrap'd by on_disconnect (runs on
          -- the nvim main loop → api-safe; GOTCHA I). notify.once dedups with the handshake cb
          -- (same category "bridge" → at most ONE toast per session; GOTCHA B).
          if type(br.on_disconnect) == "function" then
            br.on_disconnect(function(_reason)
              pcall(function() require("pi-editor.menu").close() end)
              pcall(function() require("pi-editor.completion").reset() end)
              require("pi-editor.notify").once("bridge", vim.log.levels.WARN,
                "pi-editor: bridge connection lost — completion disabled")
            end)
          end
        end)
  - PRESERVE: the rest of M.activate() (the env-var read, decode, transport check, filetype set,
    the menu.attach pcall). ONLY this handshake block changes. Update the gate docstring
    (init.lua ~line 110 "NEVER notifies … is task S39's job") to reflect that S39 is now wired:
    the gate STILL never throws, but it NOW emits the one-time notify on hard failure.
  - DO NOT: notify on dormant paths (no env var / malformed JSON / wrong transport — those
    return nil BEFORE this block; GOTCHA C).

Task 4: CREATE plugin/tests/notify_spec.lua (plenary — the Level 2 gate for notify.lua)
  - FOLLOW pattern: a simple `describe("pi-editor.notify (S39)", …)` with before_each resetting
    via `require("pi-editor.notify").reset()`. Stub vim.notify to capture calls:
        local notify = require("pi-editor.notify")
        local calls
        before_each(function()
          notify.reset()
          calls = {}
          -- stub vim.notify locally (save/restore in after_each)
          _G._orig_notify = vim.notify
          vim.notify = function(msg, level, opts) calls[#calls+1] = {msg=msg, level=level, opts=opts} end
        end)
        after_each(function() vim.notify = _G._orig_notify end)
    NOTE: because notify.once vim.schedule's, each case must `vim.wait(50, function() return #calls > 0 end)`
    or `vim.cmd("redraw")` / a short defer to let the scheduled notify flush before asserting.
  - CASES:
      a) "once() calls vim.notify exactly once for a category" — once("bridge", WARN, "x");
         wait; assert #calls==1 + calls[1].msg=="x" + level==WARN + opts.title=="pi-editor".
      b) "dedup: a 2nd once() with the same category is a silent no-op" — once("bridge",…,"a");
         once("bridge",…,"b"); wait; assert #calls==1 + calls[1].msg=="a".
      c) "distinct categories each notify once" — once("bridge",…); once("menu",…); wait;
         assert #calls==2.
      d) "default category is 'bridge' (nil/empty/non-string collapse)" — once(nil,…);
         once("",…); once(123,…); wait; assert #calls==1 (all defaulted to "bridge").
      e) "default level is WARN when level is nil/non-number" — once("bridge", nil, "x"); wait;
         assert calls[1].level == vim.log.levels.WARN.
      f) "context-safe: callable from a luv timer callback without throwing E5560" —
         local uv = vim.uv; local t = uv.new_timer(); local threw; t:start(0,0,function()
           local ok, err = pcall(notify.once, "bridge", vim.log.levels.WARN, "from luv")
           threw = not ok and tostring(err) or nil; t:stop(); t:close() end); vim.wait(100,
           function() return threw ~= nil or #calls > 0 end); assert.is_nil(threw).
      g) "reset() re-arms the dedup" — once("bridge",…); wait; reset(); once("bridge",…,"y");
         wait; assert #calls==2 (the 2nd fired after reset).
      h) "did_notify() reports the dedup state" — assert not did_notify(); once("bridge",…);
         wait; assert did_notify(); assert did_notify("bridge").
      i) "never throws on bad args (nil msg, non-string msg)" — assert.has_no.errors(function()
         notify.once("bridge", WARN, nil); notify.once("bridge", WARN, 123) end).
  - PLACEMENT: plugin/tests/notify_spec.lua.

Task 5: CREATE plugin/tests/bridge_disconnect_spec.lua (plenary — the Level 2 gate for on_disconnect)
  - FOLLOW pattern: COPY the harness from bridge_notify_spec.lua VERBATIM — `with_request_server(opts, spec)`,
    `with_handshaken_server(server_opts, spec)`, `descriptor(path)`, `reset_module()`, the
    `TOKEN`/`DESC_CWD` constants, and the server's hello-reply. The server needs a NEW mode to
    simulate process death: after hello, close the server-side connection (`srv_conn:close()`)
    on demand (expose a `kill()` from the spec args) OR just close it immediately after a short
    defer to trigger client read_cb EOF.
  - CASES:
      a) "exposes on_disconnect as a function" — assert.are.equals("function", type(bridge.on_disconnect)).
      b) "fires the handler on server-side close (EOF) after a successful handshake, reason==nil"
         — with_handshaken_server; register on_disconnect capturing (reason); `srv_conn:close()`
         (or the harness `kill()`); vim.wait(500, fired); assert fired + reason==nil +
         is_connected()==false.
      c) "fires on a read error path too" — harder to simulate cleanly; OPTIONAL. If included,
         bind the server then unbind/`uv_pipe_close` the socket file to force ECONNRESET; OR
         skip and rely on the EOF case + the read_cb code symmetry. (Mark OPTIONAL.)
      d) "runs the handler on the nvim main loop (vim.api.* does not throw E5560)" — register
         a handler that does nvim_buf_set_var; assert it ran without throwing (clone case 3 of
         bridge_notify_spec.lua).
      e) "does NOT fire while a handshake is unresolved (handshake cb owns it)" — register
         on_disconnect; point the descriptor at a socket the server closes BEFORE replying to
         hello (so read_cb EOF fires while pending); assert the disconnect handler did NOT fire
         (the handshake cb fired instead — capture hs_err).
      f) "last-wins re-registration (A then B; only B fires)" — clone case 5 of bridge_notify_spec.
      g) "on_disconnect(nil) removes — subsequent drop does not fire" — clone case 6.
      h) "no handler registered — a drop is silently swallowed (no throw)" — clone case 7.
      i) "close() clears the slot — a handler registered then close()'d does not fire across a
         reconnect" — clone case 9 of bridge_notify_spec (register, handshake, close, reconnect
         WITHOUT re-registering, drop; assert old handler did not fire).
      j) "never throws on bad args (non-function handler)" — clone case 10.
      k) "regression: handshake + request still resolve with the disconnect branch present"
         — clone case 13 (handshake then a ping request; assert both resolve).
  - NAMING: `describe("pi-editor.bridge on_disconnect (S39)", …)`.
  - PLACEMENT: plugin/tests/bridge_disconnect_spec.lua.

Task 6: EXTEND plugin/tests/activate_spec.lua — the handshake-failure notify
  - ADD a before_each reset: `require("pi-editor.notify").reset()` (and clear pi.bridge).
  - ADD CASES:
      a) "bad socket path → activate() fires one notify, pi.bridge stays nil" — set
         PI_EDITOR_BRIDGE to a descriptor whose path is "/tmp/pi-editor-NOPE-<rand>.sock"
         (non-existent); call pi.activate(); vim.wait(300, function() return
         require("pi-editor.notify").did_notify("bridge") end); assert did_notify("bridge");
         assert.is_nil(pi.bridge). (The handshake connect fails ENOENT → handshake cb → notify.)
      b) "dormant (no env var) → NO notify" — clear env var; activate(); assert NOT did_notify().
      c) "dedup: a second activate()-time failure does not re-notify" — call activate() twice
         with the bad-socket descriptor; assert did_notify() and (via a vim.notify stub or by
         counting) only ONE notify fired.
  - PRESERVE all existing activate_spec.lua cases (they must stay green).

Task 7: CREATE plugin/tests/notify_smoke.lua (plenary-free — the Level 1 gate)
  - FOLLOW pattern: the existing `*_smoke.lua` files (e.g. coords_smoke.lua / bridge_smoke.lua):
    a `check(cond, msg)` helper that prints "N check(s) … failed" on stderr + sets a fail flag,
    run via `+"luafile tests/notify_smoke.lua" +qa`.
  - CHECKS: (1) require("pi-editor.notify") loads; (2) once is a function; (3) stub vim.notify,
    call once("bridge", WARN, "hi"), flush via `vim.wait(50, …)`, assert called once; (4) call
    once again, assert NOT called again (dedup); (5) reset(), call once, assert called (re-arm);
    (6) assert no throw on bad args.
  - RUNNER (from plugin/): `timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/notify_smoke.lua" +qa`
```

### Implementation Patterns & Key Details

```lua
-- (1) notify.lua — the COMPLETE module (copy verbatim; see Task 1):
local M = {}
local seen = {}
function M.once(category, level, msg)
  if type(category) ~= "string" or category == "" then category = "bridge" end
  if seen[category] then return end
  seen[category] = true
  local l = (type(level) == "number") and level or vim.log.levels.WARN
  vim.schedule(function() pcall(vim.notify, msg, l, { title = "pi-editor" }) end)
end
function M.reset() seen = {} end
function M.did_notify(category)
  return seen[(type(category)=="string" and category~="") and category or "bridge"] == true
end
return M

-- (2) bridge.lua read_cb — the ONLY two insertions (fire BEFORE close(); gated inside fire_disconnect):
--   err branch:   local cb = state.on_close ; fire_disconnect(err) ; M.close() ; if cb then cb(err) end
--   EOF branch:   (rx:flush) ; local cb = state.on_close ; fire_disconnect(nil) ; M.close() ; if cb then cb(nil) end

-- (3) init.lua — the handshake cb forwards the bridge's token-free error VERBATIM (GOTCHA H):
--   br.handshake(desc, function(err, _info)
--     if err == nil then return end
--     require("pi-editor.notify").once("bridge", vim.log.levels.WARN,
--       "pi-editor: completion unavailable — " .. tostring(err))
--   end)
--   br.on_disconnect(function(_reason)
--     pcall(function() require("pi-editor.menu").close() end)
--     pcall(function() require("pi-editor.completion").reset() end)
--     require("pi-editor.notify").once("bridge", vim.log.levels.WARN,
--       "pi-editor: bridge connection lost — completion disabled")
--   end)
```

### Integration Points

```yaml
ACTIVATION (EDIT — init.lua M.activate()):
  - replace the no-op handshake cb with the notify-on-error cb; add the on_disconnect registration
    AFTER handshake(). No new public API on init.lua; no new config keys; no new env vars.

BRIDGE (EDIT — bridge.lua):
  - add M.on_disconnect (public, mirrors on_notification); add disconnect_handler module-local;
    add fire_disconnect local; fire from read_cb EOF + read-error branches; clear in M.close().
  - No change to connect/handshake/request/on_notification/on_exit signatures or behavior.

COMPLETION (READ-ONLY — completion.lua):
  - do_refresh/accept/on_tab already gate on pi.bridge + is_connected() (silent degrade). The
    disconnect handler calls completion.reset() (the existing cleanup seam) to cancel pending
    work + clear last_result so a stale do_refresh cannot re-open the menu.

MENU (READ-ONLY — menu.lua):
  - M.close() hides the floating window + clears state. The disconnect handler pcalls it.

NO DATABASE / NO ROUTES / NO NEW CONFIG KEYS / NO NEW ENV VARS.
```

---

## Validation Loop

> Run all commands from the `plugin/` directory. Wrap every nvim invocation in `timeout`
> (AGENTS.md). **NEVER pipe a heredoc into nvim's stdin** (AGENTS.md ⛔ HARD RULE) — write
> test snippets to a real `.lua` file and run with `+"luafile <path>"`.

### Level 1: Syntax & Smoke (Immediate Feedback)

```bash
# (a) Load each edited/new module in isolation — catches syntax errors / bad edits.
cd plugin
for m in notify bridge init; do
  timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' \
    -c "lua require('pi-editor.$m'); print('$m loaded')" -c 'qa' || echo "FAIL: $m"
done
echo "exit=$?"   # expect each to print "<m> loaded"; no FAIL

# (b) Plenary-free smoke (the new notify module).
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/notify_smoke.lua" +qa
echo "exit=$?"   # expect 0; any "N check(s) failed" on stderr = failure
```

### Level 2: Unit / Component Tests (plenary)

```bash
cd plugin

# The NEW specs (the primary gates for S39).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/notify_spec.lua")'
echo "exit=$?"   # expect 0

timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_disconnect_spec.lua")'
echo "exit=$?"   # expect 0

# The EXTENDED activate spec (the handshake-failure-notify cases).
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/activate_spec.lua")'
echo "exit=$?"   # expect 0

# REGRESSION — every spec S39 touches or neighbors must stay green.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_notify_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_request_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_handshake_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_on_exit_spec.lua")'
echo "exit=$?"   # expect 0 for all six

# (No selene/stylua config in this repo — confirmed: `ls selene* stylua*` finds none.
#  If one is added later, run: selene --config selene.yml plugin/lua/pi-editor/{notify,bridge,init}.lua
#  and stylua --check on the same files.)
```

### Level 3: Integration (real bridge ↔ real nvim)

The plenary `bridge_disconnect_spec.lua`'s "fires on server-side close (EOF)" case IS the
integration proof (real luv Unix socket + real handshake + a real server `:close()` → real
client `read_cb` EOF → real disconnect handler). To re-confirm the extension-side failure
modes (the server our client handshake talks to) are unchanged:

```bash
# From repo root — the extension's handshake-gate integration test (bad token → -32600 then close).
timeout 90 npx tsx --test extension/tests/handshake-gate.test.ts
echo "exit=$?"   # expect 0 (confirms the server still rejects a bad token + half-closes —
                #   the exact sequence our handshake cb turns into "handshake rejected (-32600)")
```

### Level 4: Creative / Domain-Specific Validation

```bash
# Manual end-to-end (optional, human-driven): with the bridge extension installed + nvim as
# $EDITOR, in a real pi session:
#   (1) connect-fail:   set PI_EDITOR_BRIDGE to a bogus socket via a throwaway extension (or
#                       kill the bridge before Ctrl+G) → open the editor → expect ONE warn toast,
#                       buffer editable, no spam on typing.
#   (2) process death:  open the editor (handshake succeeds), then `kill -9` the pi process →
#                       expect ONE warn toast ("bridge connection lost"), menu (if open) hidden,
#                       buffer still editable, quitting still submits the typed text (S38 autosave).
#   (3) dormant:        launch plain `nvim` (no PI_EDITOR_BRIDGE) → expect NO toast ever.
# (Not fully automatable from this PRP — needs a live pi TUI. The Level 2 specs cover the logic.)
```

---

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 smoke passes (`notify_smoke.lua` exit 0; each module loads in isolation).
- [ ] Level 2: `notify_spec.lua` passes (exit 0).
- [ ] Level 2: `bridge_disconnect_spec.lua` passes (exit 0).
- [ ] Level 2: extended `activate_spec.lua` passes (exit 0).
- [ ] Level 2 regression: `bridge_notify_spec.lua`, `bridge_spec.lua`,
      `bridge_request_spec.lua`, `bridge_handshake_spec.lua`, `bridge_on_exit_spec.lua` all
      pass unchanged (exit 0).
- [ ] Level 3: `extension/tests/handshake-gate.test.ts` still passes (exit 0).

### Feature Validation

- [ ] Connect fail (non-existent/refused socket) → exactly one WARN notify; `pi.bridge == nil`;
      buffer editable.
- [ ] Bad handshake (bad token / timeout / malformed) → exactly one WARN notify; `pi.bridge == nil`.
- [ ] Process death (EOF/read-error after success) → disconnect handler fires once; menu closed;
      completion reset; one WARN notify.
- [ ] All three in one session → at most ONE notify total (dedup by category `"bridge"`).
- [ ] Dormant (no env var) → NO notify ever.
- [ ] Never throws; never blocks startup; never spams (repeated keystrokes / repeated ECONNRESET).
- [ ] Disconnect does NOT fire during an unresolved handshake (handshake cb owns it).
- [ ] `on_disconnect` runs the handler on the nvim main loop (vim.api.* does not throw E5560).
- [ ] `close()` clears the disconnect slot (no stale handler across reconnects).

### Code Quality Validation

- [ ] `notify.lua` is a standalone ≤20-line module (one responsibility: dedup'd context-safe notify).
- [ ] `bridge.on_disconnect` mirrors `on_notification` exactly (shape, schedule_wrap, nil-remove,
      clear-in-close) — no new pattern invented.
- [ ] No new config keys / env vars / public API beyond `M.on_disconnect` + `notify.once/reset/did_notify`.
- [ ] `init.lua` edits are confined to the handshake-wiring block (+ the one stale docstring line).
- [ ] `bridge.lua` edits are confined to: the slot decl, the fire_disconnect local, the 2 read_cb
      inserts, the `M.on_disconnect` fn, the 1 close() line.
- [ ] Doc-comments cite PRD §11/§12 + the GOTCHAs (A–J) for the next reader.
- [ ] No token ever appears in a notify message (forward bridge error strings verbatim).

### Documentation & Deployment

- [ ] The stale `init.lua` docstrings ("the one-time vim.notify is task S39's job") are updated to
      reflect that S39 is now wired.
- [ ] `bridge.lua` [Mode A] header gains a short S39 EXTENSION note (on_disconnect sibling of
      on_notification) so the next reader understands the disconnect slot.
- [ ] No new env vars / config keys (the notify is unconditional on hard failure; a future
      `config.silent` opt is out of scope for this 1-point task).

---

## Anti-Patterns to Avoid

- ❌ Don't call `vim.notify` / `vim.api.*` directly from init.lua's handshake callback — it runs
  inline from luv fast context and throws `E5560`. Route through `notify.once` (which schedules)
  (GOTCHA A).
- ❌ Don't notify on dormant paths (no env var / malformed descriptor / wrong transport) — those
  are the NORMAL non-pi-session cases, not failures (GOTCHA C).
- ❌ Don't fire disconnect from `M.close()` — close() is also the planned `on_exit`/reconnect path
  and would notify on a graceful `:q`. Fire from `read_cb` only (GOTCHA E).
- ❌ Don't skip the `not handshake_state.pending` gate on `fire_disconnect` — without it an
  active-handshake drop would fire disconnect in addition to the handshake cb (dedup saves the
  toast count, but the handshake cb's message is more accurate; the gate keeps it authoritative)
  (GOTCHA F).
- ❌ Don't register `on_disconnect` BEFORE `br.handshake()` in init.lua — handshake() runs
  `M.close()` at its start which clears the slot. Register AFTER (GOTCHA D).
- ❌ Don't read `disconnect_handler` AFTER `M.close()` in `read_cb` — close() nils it. Fire
  before close (GOTCHA G).
- ❌ Don't include `desc.token` (or any raw value derived from it) in a notify message — PRD §12.
  Forward the bridge's already-token-free error strings verbatim (GOTCHA H).
- ❌ Don't reimplement "degrade to normal buffer" — completion.lua already auto-bails on
  `pi.bridge==nil` / `is_connected()==false`. S39 only adds the notify + menu cleanup.
- ❌ Don't add per-failure distinct notify categories in v1 — PRD §11 wants ONE toast; collapse to
  category `"bridge"` (GOTCHA B). (Distinct categories remain POSSIBLE via the API for future use.)
- ❌ Don't reference or create `health.lua` — that's S42 (planned, not done) (GOTCHA J).

---

## Confidence Score

**9/10** for one-pass implementation success.

Rationale: this is a small, surgical change — one ≤20-line new module, a `bridge.on_disconnect`
hook that is a literal clone of the already-shipped `on_notification` (same shape, same test
harness, same GOTCHA-5 scheduling), and a confined init.lua wiring swap (replacing an explicitly
S39-deferred no-op callback). Degradation to a normal buffer is already automatic (verified:
completion.lua gates every path on `pi.bridge` + `is_connected()`; `resolve_handshake` only
publishes `pi.bridge` on success) — S39 only adds the user-facing notify + menu cleanup. The one
subtlety (the handshake cb running in luv fast context → notify must schedule) is explicitly
specified (GOTCHA A) and mirrored from the existing `on_notification` discipline. The −1 is for
the residual uncertainty in cleanly simulating a read-error (vs EOF) disconnect in the plenary
spec (case 5c is marked OPTIONAL) and the manual end-to-end (Level 4) needing a live pi TUI —
but neither blocks the logic gates (Levels 1–3), which fully cover the contract.