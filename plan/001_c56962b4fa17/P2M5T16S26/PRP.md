---
name: "P2.M5.T16.S26 — request(method, params, cb): auto-id, correlation, stale drop"
description: >
  Add the GENERIC JSON-RPC request layer to the pi-editor.nvim bridge client (`plugin/lua/pi-editor/bridge.lua`):
  a `request(method, params, on_result)` that auto-assigns monotonic string ids, correlates each
  response by id via a module-level `pending` map, drops stale/late/duplicate/stray responses, fires
  a per-request luv timeout, and resolves EVERY outstanding callback on `close()` (LSP invariant:
  never leave a cb hanging). Plus a local `cancel(id)` helper for caller-side supersession. This is
  the SECOND protocol consumer of the S24 transport (after the S25 handshake) and the SEAM the
  completion flow (S30+) calls — it EXTENDS the existing single `dispatch(msg)` branch (the S25
  `id=="h1"` handshake resolver) with a `pending[msg.id]` lookup, NOT a fork.
---

# Goal

**Feature Goal**: Implement the generic RPC dispatch half of parent task P2.M5.T16 ("RPC dispatch
with id correlation & supersession") on the Neovim side of the bridge: extend `bridge.lua`'s
`dispatch(msg)` (the singleton `on_event` S25 owns) with a `pending[id]` map so every post-handshake
JSON-RPC **response** is routed to the exact callback that sent the matching **request**, and expose
`request(method, params, on_result)` + `cancel(id)` on the module surface. Auto-ids are monotonic
integers-as-strings (trivially distinct from the handshake's literal `"h1"`). Each outstanding request
gets its own luv timeout timer; a response/timer/cancel resolves the cb EXACTLY ONCE (the
delete-the-entry guard makes a late duplicate a silent no-op); `close()` drains the whole map. This
makes out-of-order AND concurrent requests (e.g. `getSuggestions` racing `applyCompletion`) safe —
correlation is by id, a spec-guaranteed property (JSON-RPC §6 / LSP).

**Deliverable**:
1. New module state in `plugin/lua/pi-editor/bridge.lua`: a `pending` map (id → entry), a monotonic
   `next_id` counter, and a documented `pi-editor.PendingRequest` class.
2. A `local resolve_request(id, err, msg)` resolver (the exactly-once exit point for regular requests —
   the sibling of S25's `resolve_handshake`).
3. An EXTENDED `dispatch(msg)` (one added branch AFTER the `id=="h1"` handshake branch).
4. Public `M.request(method, params, on_result)` (returns the id so the caller can cancel/supersede)
   and `M.cancel(id)` (local cleanup — fires cb with "cancelled").
5. A `M.close()` extension that drains `pending` (resolve each cb with "connection closed", stop+close
   each timer) and resets `next_id`.
6. A plenary/busted spec `plugin/tests/bridge_request_spec.lua` (real luv socket server).

**Success Definition**:
- Every `request()` is resolved EXACTLY ONCE — by response, timeout, cancel, or close (never 0, never 2).
- Out-of-order and concurrent requests each resolve to their OWN cb (verified by a spec that fires two
  requests and replies in reverse order).
- A stale/late/duplicate/stray response (one whose id is not in `pending`) is SILENTLY DROPPED — no cb
  re-fire, no throw (PRD §11 silent-degrade).
- `getSuggestions`'s legitimate `{"result": null}` (no matches) resolves `cb(nil, nil)` — distinguished
  from a malformed response via `rawget` (see §Gotchas).
- `close()` resolves every outstanding cb with "connection closed" and leaves NO live luv timer (no leak
  across the many editor open/close cycles one session sees — PRD §6.7).
- The S24 transport spec, the S23 jsonlreader spec, the S25 handshake spec, and `smoke.lua` all pass
  UNCHANGED (`connect()`/`handshake()` public signatures untouched; `dispatch` only gains a branch).

## User Persona

**Target User**: The downstream completion module (`plugin/lua/pi-editor/completion.lua`, S30+) — its
triggers call `bridge.request("getSuggestions", {lines, cursorLine, cursorCol, force}, cb)` on every
(debounced) keystroke, its accept flow calls `bridge.request("applyCompletion", …, cb)`, and its Tab
handler calls `bridge.request("shouldTriggerFileCompletion", …, cb)`. Secondary: the optional
blink.cmp / nvim-cmp sources (S45/S46) which call `require("pi-editor").bridge.request(...)` per
PRD §7.7.

**Use Case**: Once the S25 handshake sets `require("pi-editor").bridge`, completion needs a single,
robust primitive to fire pi's completion RPCs and get the result (or a clean failure) back — without
reimplementing framing, ids, timeouts, or stale-dropping each time. `request()` is that primitive; the
completion layer only adds its own latest-id guard for supersession (PRD §5.5).

**User Journey**: handshake ok → `pi.bridge` live → user types → completion debounces →
`bridge.request("getSuggestions", …, cb)` → `next_id++` → id `"1"` registered in `pending["1"]` + a luv
timer armed → `M.send({jsonrpc,id:"1",method:"getSuggestions",params})` → server echoes `{id:"1",result}`
→ `dispatch` → `resolve_request("1", nil, msg)` → entry deleted, timer closed, `cb(nil, result)` (deferred
via the stored `schedule_wrap`) → menu populated. Next keystroke: id `"2"`, supersession handled by the
caller's latest-id check (it ignores the now-stale `"1"` response if one is still in flight) OR
`bridge.cancel("1")`. User accepts → `request("applyCompletion", …)` (its own id) → `cb(nil, {lines,cursor})`.

**Pain Points Addressed**: Without `request()`, every caller would hand-roll id generation + a pending
table + timeouts + stale-dropping — duplicating fragile luv-timer/correlation logic (the exact bug
surface S25 centralized for the handshake). A single, tested RPC primitive is the foundation S30+ keys on.

## Why

- **The dispatch seam already exists (S25).** `bridge.lua:dispatch(msg)` has the literal comment
  `-- S26 EXTENSION POINT: if pending[msg.id] then ... end` right after the `id=="h1"` handshake branch.
  S26 fills that one branch — no refactor, no new module.
- **Foundation for every downstream task.** S27 (commandsChanged notification), S30 (triggers),
  S32 (accept), S33 (Tab), S38 (bye/autosave), S41 (cache invalidation), S42 (:checkhealth ping),
  S45/S46 (blink/cmp sources) ALL call `request()`. This task is the prerequisite that makes them trivial.
- **Correctness over convenience.** A naive "only the latest id matters" transport (PRD §7.3's loose
  phrasing) would mis-drop a legitimate `applyCompletion` response when a newer `getSuggestions` supersedes
  it — corrupting the accept flow. The validated design is TWO layers: transport = id-keyed `pending` MAP
  (correlation, every request gets its own cb); caller = latest-id guard (supersession). See research/notes.md §1.
- **LSP invariant, honored.** "Every request must eventually get a response." A connection close while
  requests are outstanding MUST resolve each cb (with "connection closed"), not strand them — otherwise
  completion hangs forever waiting on a dead socket. `close()` draining `pending` is load-bearing.
- **Resource hygiene.** Per-request luv timers MUST be `:close()`d (not just `:stop()`d) or they leak
  across the many editor open/close cycles one session sees (PRD §6.7). Centralizing timer lifecycle in
  the resolver + close-drain makes this correct in ONE place.

## What

User-visible: nothing directly (this is a library layer). The observable effect is that
`require("pi-editor").bridge` gains `request`/`cancel` methods once the S25 handshake publishes it; a
dormant session (no `PI_EDITOR_BRIDGE`) still has `pi.bridge == nil` and never touches this code.

Technical requirements:
- `request(method, params, on_result)`: validate args (never throws); if not connected, fire `on_result("not connected")`
  (scheduled) and return `nil`; else assign a fresh monotonic string id, register `pending[id]`, arm a luv
  timeout, `M.send` the envelope, return the id.
- `dispatch(msg)`: AFTER the `id=="h1"` handshake branch, if `type(msg.id)=="string"` and `pending[msg.id]`
  exists, `resolve_request(msg.id, nil, msg)`. Unknown/absent ids are silently dropped.
- `resolve_request(id, err, msg)`: the exactly-once exit — delete `pending[id]` FIRST (the guard), stop+close
  the timer, then fire the stored cb (success → `cb(nil, result)`; error → `cb(err)`; timeout/cancel/close → `cb(err)`).
- `cancel(id)`: local-only — `resolve_request(id, "cancelled", nil)` (fires cb, stops timer, deletes entry).
  No wire message (the server self-supersedes `getSuggestions`; no `cancel` method is registered — protocol.ts).
- `close()`: snapshot `pending` ids; for each, delete the entry, stop+close its timer, fire `cb("connection closed")`;
  reset `next_id = 0`.
- cb is stored as `vim.schedule_wrap(on_result)` so it is safe to invoke from BOTH the `read_start` cb and
  the luv timer cb (both run in libuv/fast context where `vim.api.*` would throw `E5560`).

### Success Criteria

- [ ] `bridge.request` and `bridge.cancel` exist and are functions.
- [ ] `request()` returns a unique monotonic string id per call (`"1"`, `"2"`, …); the id is NEVER `"h1"`
      (numeric strings only — can never collide with the handshake's literal `"h1"`).
- [ ] The wire envelope is exact: `{"jsonrpc":"2.0","id":"<n>","method":"<method>","params":<params>}` (LF-terminated).
- [ ] A success response (`{id, result}`) fires `on_result(nil, result)` EXACTLY ONCE.
- [ ] An error response (`{id, error:{code,message}}`) fires `on_result("<err>")` EXACTLY ONCE (the err string
      includes the code; never the token — the token never appears in any RPC response, verified by the server).
- [ ] A `{"result": null}` response (getSuggestions empty) fires `on_result(nil, nil)` — distinguished from a
      malformed response (no `result`/`error`) via `rawget` (LIVE-VERIFIED: vim.NIL ≠ nil).
- [ ] Out-of-order: two requests outstanding; server replies in reverse order; each cb gets its OWN result.
- [ ] Concurrent: `getSuggestions` + `applyCompletion` outstanding resolve independently (the pending MAP, not a
      single latest-id).
- [ ] A stale/late response (its id already resolved/timed-out/cancelled → not in `pending`) is SILENTLY DROPPED
      (no cb re-fire, no throw).
- [ ] A duplicate response (server sends the same id twice) fires the cb ONCE.
- [ ] A stray response (id never sent) is silently dropped.
- [ ] A `msg` with `id == null` (server malformed-request reply) does NOT index `pending[nil]` (guarded by `type=="string"`).
- [ ] Per-request timeout: a slow server + `rpc_timeout_ms` shrunk to ~40ms → `on_result(<err with "timeout">)`; the
      timer is `:close()`d (not leaked); a late response after the timeout does NOT re-fire cb.
- [ ] `cancel(id)` fires `on_result("cancelled")`, stops+closes the timer, deletes the entry; a subsequent response
      for that id is dropped.
- [ ] `close()` resolves every outstanding cb with "connection closed", closes every timer, resets `next_id = 0`, and
      leaves `pending` empty.
- [ ] `request()` when not connected fires `on_result("not connected")` (scheduled) and returns `nil`.
- [ ] `request()`/`cancel()` NEVER throw (pcall-wrapped luv; bad args degrade via the cb / a nil return).
- [ ] The handshake still routes `id=="h1"` FIRST (a handshake followed by a request works end-to-end).
- [ ] `bridge_spec.lua` (S24), `jsonlreader_spec.lua` (S23), `bridge_handshake_spec.lua` (S25), `smoke.lua` pass UNCHANGED.

## All Needed Context

### Context Completeness Check

> "If someone knew nothing about this codebase, would they have everything needed to implement this successfully?"

Yes — this PRP names every authoritative file (with line refs), quotes the exact wire envelopes, specifies
the Lua/luv exactly-once + timer-lifecycle rules (LIVE-VERIFIED on Neovim 0.12.4), pins the `vim.NIL`/`rawget`
result-discrimination, and gives the copy-pasteable resolver/dispatch/request/cancel code and the real-socket
test pattern. The implementer needs only Neovim + `vim.uv`/`vim.json` knowledge (both built in) and the paths below.

### Documentation & References

```yaml
# MUST READ — the contracts this task consumes / extends (all DONE, read before editing)
- file: plugin/lua/pi-editor/bridge.lua
  why: The module to EXTEND (not replace). Holds the S24 transport (connect/send/close/on_exit/is_connected,
    GOTCHAs 1-12) + the S25 handshake (handshake/resolve_handshake/dispatch + handshake_state/M.server_info).
    The dispatch SEAM is at ~L237-244: dispatch(msg) has the `id=="h1"` handshake branch FIRST, then the literal
    `-- S26 EXTENSION POINT: if pending[msg.id] then ... end`. S26 adds the pending[msg.id] branch AFTER the
    handshake branch (so handshake responses are never mis-routed). close() (~L453) is the drain target.
  pattern: module-level `state` table + forward-declared locals (resolve_handshake, dispatch) assigned later;
    pcall-wrap luv; route every teardown through M.close(); the exactly-once guard = delete-the-entry (handshake
    uses a `pending` BOOL flag; request() uses DELETE-from-map — both make a later resolver a no-op).
  gotcha: connect()/send()/handshake() PUBLIC SIGNATURES MUST NOT CHANGE. The S24/S25 specs call them directly;
    keep them passing. GOTCHA 5 (NO vim.api from luv cbs → store schedule_wrap(cb)). GOTCHA 2 (double-close
    safe via state.closed). GOTCHA 6 (send() gated on state.connected). GOTCHA 10 (SINGLETON — one on_event
    per session; request() shares dispatch with handshake).

- file: extension/connection.ts
  why: handleLine() (the server dispatcher). The REQUEST branch proves the server ECHOES the client's string id
    verbatim: `const reqId = id as string; … sendResponse(sock, reqId, result)`. A request ALWAYS gets exactly one
    response (success result OR error -32603/-32602). Notifications (no id) get NO response. So client correlation
    by id is sound. Also: `id` is RESTRICTED to string (PRD §5.3); a numeric/null id → -32600 (so guard
    type(msg.id)=="string" on the client).
  gotcha: a fatal-close (bad token) delivers the error line THEN graceful EOF (sock.end = FIN). For non-handshake
    requests this never happens (only hello is fatal); a normal error is just `{id, error:{code,message}}`.

- file: extension/protocol.ts
  why: The wire TYPES. JsonRpcResponse = {jsonrpc,id,result?}|{jsonrpc,id,error:{code,message}}. BridgeMethod has
    NO `cancel` (so cancel(id) is LOCAL-only). commandsChanged is the ONLY notification (no id) — that's S27's branch.
    RequestMethod = everything except commandsChanged (the 7 methods request() may carry).
  gotcha: result MAY be null (GetSuggestionsResult = AutocompleteSuggestions | null). The client MUST treat a null
    result as success-with-no-matches, not an error (see the vim.NIL/ rawget gotcha).

- file: extension/pi-editor-bridge.ts
  why: makeGetSuggestionsHandler (~the server side) keeps ONE in-flight AbortController per connection; a NEWER
    getSuggestions request ABORTS the prior (supersession SIGKILLs fd). So sending the newer request IS the cancel
    — there is NO separate cancel wire method. cancel(id) is local cleanup only.
  pattern: the server's per-request timeout (1500ms) + supersession mirrors what the client expects (PRD §5.5).

- file: extension/tests/get-suggestions-handler.test.ts
  why: The server contract — the exact result/error envelopes + supersession semantics the Lua client consumes.
    Mirror its result/error shapes in the Lua spec.

- file: plugin/lua/pi-editor/init.lua
  why: `config.rpc_timeout_ms` (default 2000) — the SAME knob the handshake reads; request() reads it for its
    per-request timeout. `M.bridge` is the placeholder S25 sets to the bridge module on handshake success; request()
    lives ON that module so `require("pi-editor").bridge.request(...)` works (PRD §7.7).
  gotcha: NO change to init.lua in this task — request() is called by completion (S30+), not wired into activate().

- file: plugin/tests/bridge_spec.lua
  why: The plenary/busted test PATTERN to mirror — its with_server(spec) helper spins a REAL luv unix-socket server
    (unique path), decodes client requests via the S23 jsonlreader, and echoes JSONL responses BY ID. The echo-by-id
    is EXACTLY the correlation machinery request() needs. S26's server generalizes it (mode-keyed behavior).
  pattern: vim.wait(budget, predicate_fn, 5) — the tight 5ms poll interval is load-bearing for deterministic async
    asserts; unique socket path per case; stop() closes server+conn and calls bridge.close().

- file: plugin/tests/bridge_handshake_spec.lua
  why: The closest sibling spec (the S25 gate). Its reset_module() (close + nil pi.bridge) is the reset pattern to
    EXTEND — S26's close() draining pending + resetting next_id makes it sufficient as-is (no new reset hook needed).
    Its with_hello_server(opts, spec) mode-keyed HOF is the template for with_request_server.

- file: plugin/tests/minimal_init.lua
  why: The plenary harness bootstrap (prepends plenary + appends plugin root). plenary at
    /home/dustin/.local/share/nvim/lazy/plenary.nvim (verified).

- docfile: plan/001_c56962b4fa17/P2M5T16S26/research/notes.md
  why: Consolidated deep-dive: the two-layer design (pending MAP transport + caller latest-id supersession), the
    JSON-RPC §6 out-of-order guarantee, the luv timer :close()-is-required / is_closing-guard rules, the vim.NIL
    result-discrimination, and the 16-case test matrix.
  section: §1 (two-layer design), §3 (luv timers), §4 (result:null), §5 (test strategy).

- url: https://www.jsonrpc.org/specification#batch
  why: §6 authorizes out-of-order responses: "The Server MAY process [requests] in any order… Responses MAY be
    returned in any order… The Client SHOULD match contexts based on the id member." → our pending[msg.id] lookup
    is the spec-blessed correlation mechanism (so concurrent getSuggestions + applyCompletion is safe).
  critical: do NOT assume response order matches request order — correlate by id (this codebase's server can
    legitimately reorder a slow getSuggestions behind a fast applyCompletion).

- url: https://www.jsonrpc.org/specification#request_object
  why: §4 — id is String|Number|NULL; NULL discouraged (reserved for unknown-id responses); numbers SHOULD NOT
    contain fractional parts. → monotonic-int→string ids ("1","2",…) are the safest choice and never equal "h1".
  critical: guard type(msg.id)=="string" before indexing pending[msg.id] — a server id:null would be a Lua
    pending[nil] index error otherwise.

- url: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#request-notification-and-response-ordering
  why: second authority for out-of-order safety + the "a cancelled request must still return a response" invariant
    (we honor it: every outstanding request resolves exactly once via response/timeout/cancel/close).

- url: https://github.com/luvit/luv/blob/master/docs.md
  why: luv uv_timer_t + uv_handle_t: timer:start(timeout,0,cb) one-shot; :stop() makes inactive but does NOT free;
    :close() is REQUIRED to free the handle ("MUST be called on each handle before memory is released"); :close() on
    a closing handle THROWS → guard with :is_closing().
  critical: store vim.schedule_wrap(cb) in the pending entry (mirrors vim/lsp/rpc.lua:324) so BOTH the read_start cb
    and the timer cb can invoke it safely from libuv context (vim.api.* would throw E5560 there — :help lua-loop-callbacks).
```

### Current Codebase tree (the plugin edit surface)

```bash
plugin/
  lua/pi-editor/
    init.lua          # setup()/defaults/activate() (S21) — config.rpc_timeout_ms; M.bridge placeholder. UNCHANGED.
    bridge.lua        # S24 transport + S25 handshake — EXTEND (this task): +pending map, +next_id,
                      #   +resolve_request, +dispatch branch, +request(), +cancel(), +close() drain.
    jsonlreader.lua   # S23 (DONE) — feeds decoded tables to on_event. UNCHANGED.
  plugin/pi-editor.lua   # VimEnter shim (S20) — UNCHANGED.
  ftplugin/pi-prompt.lua # S22 — UNCHANGED (its bridge.on_exit forward contract is already S24; S38 fills the body).
  tests/
    minimal_init.lua       # plenary bootstrap — UNCHANGED.
    smoke.lua              # zero-dep smoke — UNCHANGED (pi.bridge==nil pre-handshake still holds).
    bridge_spec.lua        # S24 spec — UNCHANGED (regression).
    jsonlreader_spec.lua   # S23 spec — UNCHANGED (regression).
    bridge_handshake_spec.lua  # S25 spec — UNCHANGED (regression).
    bridge_request_spec.lua    # NEW (this task) — the Level-2 gate.
```

### Desired Codebase tree with files to be added/modified

```bash
plugin/lua/pi-editor/bridge.lua        # MODIFY — add pending map + next_id + resolve_request + dispatch branch + request()/cancel() + close() drain
plugin/tests/bridge_request_spec.lua   # CREATE — plenary spec (real socket server; 16 cases: auto-id, correlation, out-of-order, concurrent, error, null-result, stale-drop, dup, stray, timeout, cancel, close-drain, not-connected, never-throws, handshake-first)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: bridge.lua is a SINGLETON transport (S24 GOTCHA 10): one pipe, ONE on_event per session.
-- S25 owns dispatch(msg) and passes it as connect()'s on_event. S26 EXTENDS that SAME dispatch with a
-- second branch (pending[msg.id]) AFTER the id=="h1" handshake branch — do NOT fork dispatch into a
-- per-request closure. The handshake branch MUST stay first (a handshake response has id "h1", never a
-- numeric string, so the two branches are mutually exclusive — but order defends against any future change).

-- CRITICAL: the EXACTLY-ONCE guard for request() is DELETE-THE-ENTRY (sibling of handshake's `pending` bool).
-- resolve_request does `pending[id] = nil` FIRST, then stops the timer, then fires cb. A LATE resolver
-- (e.g. the timeout firing after the response already arrived) looks up pending[id], finds nil, no-ops.
-- Single-threaded nvim/luv loop ⇒ this is a sequenced-event guard, not a lock.

-- CRITICAL: store vim.schedule_wrap(on_result) as entry.cb. The resolver runs INLINE from either the
-- read_start callback (the response path) OR the luv timer callback (the timeout path) — BOTH are libuv/fast
-- context where vim.api.* throws E5560 (:help lua-loop-callbacks). schedule_wrap defers the user's cb to the
-- safe nvim loop. (Mirrors /usr/share/nvim/runtime/lua/vim/lsp/rpc.lua:324 — production nvim LSP does exactly this.)

-- CRITICAL: luv timer :close() is REQUIRED to free the handle; :stop() alone is NOT enough. A repeat=0 one-shot
-- auto-stops after firing but is NOT closed. Every resolver path (response/timeout/cancel/close) must :close()
-- the entry's timer, guarded by :is_closing() (a double-:close() THROWS). Pattern:
--   if timer and not timer:is_closing() then timer:stop() end
--   if timer and not timer:is_closing() then timer:close() end

-- CRITICAL: NEVER use vim.defer_fn for the per-request timeout — bridge.lua is pure vim.uv (S24 GOTCHA 5).
-- Use uv.new_timer() + timer:start(timeout_ms, 0, cb). The cb runs in fast context; it calls resolve_request
-- (pure Lua writes + timer :stop()/:close() — luv-safe) which then fires the schedule_wrap'd cb.

-- CRITICAL: result MAY be null. getSuggestions legitimately returns {"result": null} (no matches). After
-- vim.json.decode, JSON null → vim.NIL (NOT Lua nil) when the KEY is present; an absent key decodes to nil.
-- LIVE-VERIFIED (Neovim 0.12.4): rawget(msg,"result") returns vim.NIL for {"result":null} and nil for {}.
-- So discriminate: has_result = rawget(msg,"result") ~= nil ; has_error = type(msg.error)=="table". Normalize
-- vim.NIL → nil before handing result to cb (cb(nil, nil) = "success, no result", NOT an error).
--   vim.NIL ~= nil  --> true   (so the rawget check works)

-- CRITICAL: guard type(msg.id)=="string" before indexing pending[msg.id]. The server may send id:null on a
-- malformed request (JSON-RPC §5.1) — pending[nil] is a Lua "table index is nil" ERROR. Also: the handshake's
-- literal "h1" is a string, so it would match a numeric-only counter ONLY if the counter could emit "h1" — it
-- can't (tostring(n) for integer n is always a numeric string). Documented; no collision.

-- CRITICAL: close() must DRAIN pending (resolve each cb with "connection closed", stop+close each timer, reset
-- next_id). A closed transport can NEVER deliver more responses, so every outstanding cb MUST be finalized
-- (LSP invariant: never leave a cb hanging). Snapshot the ids first (for _,id in ipairs(snapshot)) then delete
-- — clearer than delete-during-pairs (legal in LuaJIT but snapshot is unambiguous). This is the DIFFERENCE from
-- handshake_state: close() does NOT clear handshake_state (resolve_handshake owns it via the pending bool, and
-- on_close fires AFTER close() in read_cb); but close() DOES drain pending (no other resolver will fire for them).

-- CRITICAL: NEVER put the token value in any error string (PRD §12). It never appears in RPC responses anyway
-- (verified by extension/tests/get-suggestions-handler.test.ts SECURITY sweep), but the client must likewise
-- never echo desc.token — request() error strings are generic ("rpc error -32603", "timeout", "cancelled",
-- "connection closed", "not connected", "malformed response").

-- CRITICAL: NEVER add a wire "cancel" notification. protocol.ts BridgeMethod has NO cancel; the server
-- self-supersedes getSuggestions (a newer request aborts the prior AbortController). cancel(id) is LOCAL cleanup
-- only (fire cb "cancelled" + stop timer + delete entry). Adding a wire cancel would hit the server's -32601
-- "method not found" (harmless but pointless) — keep it local.

-- GOTCHA: request() reads config.rpc_timeout_ms EACH call (cheap). Tests shrink it to ~40ms for the timeout
-- case and restore it (or rely on after_each reset). Do NOT cache it at module load (config can change via setup()).

-- GOTCHA: do NOT name a spec-local table `pending` in bridge_request_spec.lua — it shadows plenary.busted's
-- global `pending` (the test-SKIP function). The module's pending is a local upvalue (no collision in the module);
-- in the SPEC, observe behavior (capture cbs into locals) or name the table `pending_reqs`/`got`.
```

## Implementation Blueprint

### Data models and structure (Lua tables — no ORM/pydantic; this is a Neovim plugin)

```lua
-- ── Added to bridge.lua (module-level singleton state, all cleared in close()) ───────

--- Monotonic request-id counter. Incremented by request(); reset to 0 by close() so each
--- connection starts at "1" (testability: the "first request gets id 1" assertion is
--- order-independent across cases that each reset_module()). Numeric strings only → can
--- NEVER equal the handshake's literal "h1". Single-threaded luv loop ⇒ no locking.
local next_id = 0

--- In-flight RPC requests keyed by id (string). Each entry is created by request() and
--- deleted by the FIRST resolver (response / timeout / cancel / close) — the delete IS the
--- exactly-once guard (a later resolver finds nil and no-ops). Cleared wholesale by close().
---@class pi-editor.PendingRequest
---@field method string The RPC method (for cancel routing / debugging; never sent on cancel wire).
---@field cb fun(err:string?, result:any?) The user callback, wrapped in vim.schedule_wrap at store
---   time so it is safe to invoke from BOTH the read_start cb and the luv timer cb (libuv/fast
---   context — vim.api.* would throw E5560 there).
---@field timer userdata? luv one-shot timer for the per-request timeout (nil if disarmed). MUST be
---   :close()'d (not just :stop()'d) on resolve or it leaks across editor open/close cycles.
---@type table<string, pi-editor.PendingRequest>
local pending = {}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: ADD module state to plugin/lua/pi-editor/bridge.lua
  - ADD: `local next_id = 0` (top-level, near `local handshake_state = nil`).
  - ADD: `local pending = {}` (documented class pi-editor.PendingRequest — see Blueprint).
  - CLEAR in M.close(): set `pending = {}` (or drain — see Task 6) and `next_id = 0` ALONGSIDE the
    existing state wipe + `M.server_info = nil`. Documented: close() drains pending (resolve cbs)
    THEN resets next_id; it does NOT clear handshake_state (resolve_handshake owns that).
  - FOLLOW pattern: the existing `state = {...}` singleton + `handshake_state`.
  - NAMING: snake_case; `local` for internal (next_id, pending, resolve_request); `M.` for public.
  - DEPENDENCIES: none (pure additions; no behavior change yet).
  - PLACEMENT: bridge.lua — right after the `local handshake_state = nil` block / before the
    S25 forward declarations.

Task 2: ADD the forward declaration + the resolver `resolve_request(id, err, msg)` to bridge.lua
  - ADD: `local resolve_request` to the S25 forward-declaration block (alongside resolve_handshake, dispatch).
  - IMPLEMENT: `resolve_request = function(id, err, msg)` — the SINGLE exit point for regular requests.
    Logic:
      if type(id) ~= "string" then return end
      local entry = pending[id]
      if not entry then return end      -- EXACTLY-ONCE guard: already resolved / unknown id
      pending[id] = nil                 -- delete FIRST (the guard for any racing resolver)
      -- stop+close the luv timer (REQUIRED to free the handle; guard the double-close THROW)
      if entry.timer then
        pcall(function()
          if not entry.timer:is_closing() then entry.timer:stop() end
          if not entry.timer:is_closing() then entry.timer:close() end
        end)
      end
      -- fire the stored cb (schedule_wrap'd -> deferred to the safe nvim loop)
      local cb = entry.cb
      if not cb then return end
      if msg == nil then
        -- timeout / cancel / close path: err carries the reason
        cb(err or "request failed")
        return
      end
      -- response path: success (result, possibly null) vs error vs malformed
      if type(msg.error) == "table" then
        local code = (type(msg.error.code) == "number") and msg.error.code or nil
        local emsg = code and ("rpc error " .. code) or "rpc error"
        if type(msg.error.message) == "string" and msg.error.message ~= "" then
          emsg = emsg .. ": " .. msg.error.message   -- server messages are generic codes; safe (no token)
        end
        cb(emsg)
      elseif rawget(msg, "result") ~= nil then      -- LIVE-VERIFIED: vim.NIL (present-null) ≠ nil (absent)
        local result = msg.result
        if result == vim.NIL then result = nil end   -- normalize: getSuggestions null result = nil (no matches)
        cb(nil, result)
      else
        cb("malformed response: no result or error")
      end
  - GOTCHA: runs INLINE from a luv callback (read_start cb / timer cb) — does NO vim.api work (GOTCHA 5).
    The cb is schedule_wrap'd so the USER's nvim work is deferred; resolve_request itself is pure Lua +
    M.send/M.close (luv-safe). require("pi-editor") is NOT needed here (no pi.bridge write — that's S25's job).
  - DEPENDENCIES: Task 1 (pending).

Task 3: EXTEND `dispatch(msg)` with the pending[msg.id] branch (the S26 SEAM)
  - FIND: the existing `dispatch = function(msg)` (~L237-244) with the `id=="h1"` handshake branch + the
    `-- S26 EXTENSION POINT` comment.
  - ADD (AFTER the handshake branch, BEFORE the S27 comment):
      -- S26: correlate a regular JSON-RPC response by id.
      if msg and type(msg.id) == "string" then
        if pending[msg.id] then
          resolve_request(msg.id, nil, msg)
          return
        end
        -- no matching entry: stale / late / duplicate / stray -> drop silently (PRD §11)
      end
  - PRESERVE: the `id=="h1"` handshake branch stays FIRST (mutually exclusive with numeric ids, but order
    defends against future changes). The S27 `commandsChanged` comment stays (S27 adds the notification branch).
  - GOTCHA: the `type(msg.id)=="string"` guard defends a server id:null (JSON-RPC §5.1) — pending[nil] is a
    Lua error. Notifications (no id) fall through to the S27 branch.
  - DEPENDENCIES: Tasks 1-2.

Task 4: ADD `M.request(method, params, on_result)` to bridge.lua
  - IMPLEMENT: the public entry. Signature: request(method, params, on_result) → string|nil (the id).
      method:   string  (a RequestMethod — getSuggestions/applyCompletion/shouldTriggerFileCompletion/ping/getCommands/bye).
      params:   table|nil (sent as-is; nil → omitted from the JSON envelope; the server reads params as unknown).
      on_result:fun(err:string?, result:any?) — resolved EXACTLY ONCE (response/timeout/cancel/close).
    Body:
      -- (a) validate UP FRONT — never throw on bad args (the caller is completion/S30+; a bug must degrade)
      if type(on_result) ~= "function" then return nil end
      if type(method) ~= "string" or method == "" then
        vim.schedule_wrap(on_result)("invalid method") return nil
      end
      -- (b) not connected -> fire cb (scheduled) + return nil (no id, no pending entry, no timer)
      if not M.is_connected() then
        vim.schedule_wrap(on_result)("not connected")
        return nil
      end
      -- (c) assign a fresh monotonic id + register the entry (cb stored schedule_wrap'd)
      next_id = next_id + 1
      local id = tostring(next_id)
      pending[id] = { method = method, cb = vim.schedule_wrap(on_result), timer = nil }
      -- (d) arm the per-request luv timeout (NEVER vim.defer_fn — GOTCHA 5)
      local cfg = require("pi-editor")
      local timeout_ms = ((cfg.config or cfg.defaults or {}).rpc_timeout_ms) or 2000
      local timer = uv.new_timer()
      pending[id].timer = timer
      timer:start(timeout_ms, 0, function()
        resolve_request(id, "request timeout", nil)   -- delete-entry guard: no-op if already resolved
      end)
      -- (e) send the envelope; if the write was dropped (not connected / closing), resolve with an error
      local ok = M.send({ jsonrpc = "2.0", id = id, method = method, params = params })
      if not ok then
        resolve_request(id, "send failed", nil)        -- transport dropped the write (GOTCHA 6/7)
      end
      return id
  - GOTCHA: wrap the luv setup (new_timer/start) defensively? uv.new_timer can throw on a programming error;
    mirror S25's handshake pcall discipline if desired. The dominant failure (not connected) is handled at (b).
    A pcall around (c)-(e) routing throws to on_result is the safest; keep it.
  - GOTCHA: params may be nil for empty-params methods (ping/bye). M.send encodes it; vim.json.encode omits a
    nil-valued key (or encodes null — server reads params as unknown, ignores for ping). Fine.
  - DEPENDENCIES: Tasks 1-3.

Task 5: ADD `M.cancel(id)` to bridge.lua
  - IMPLEMENT: local-only supersession cleanup.
      function M.cancel(id)
        if type(id) ~= "string" then return end
        local entry = pending[id]
        if not entry then return end          -- already resolved / unknown -> no-op
        resolve_request(id, "cancelled", nil)  -- fires cb("cancelled"), stops+closes timer, deletes entry
        -- NO wire notification: the server self-supersedes getSuggestions (a newer request aborts the prior);
        -- protocol.ts has NO cancel method. Adding one would hit -32601 "method not found" (pointless).
      end
  - GOTCHA: resolve_request is the SINGLE exit; cancel reuses it (exactly-once guaranteed by the delete-entry guard).
  - DEPENDENCIES: Tasks 1-2.
  - PLACEMENT: right after M.request.

Task 6: EXTEND `M.close()` to drain pending + reset next_id
  - FIND: the existing M.close() (~L453-481) — the shadow state.closed flag + pipe close + state clear + server_info=nil.
  - ADD (BEFORE the existing `state.on_close = nil` / AFTER the pipe close — order vs handshake_state matters):
      -- S26: drain ALL pending requests — a closed transport can NEVER deliver more responses, so every
      -- outstanding cb MUST be finalized (LSP invariant: never leave a cb hanging). Resolve each with a
      -- closed error, stop+close its timer, then clear the map + reset the id counter.
      -- NOTE: handshake_state is NOT cleared here (resolve_handshake owns it via the pending bool; on_close
      -- fires AFTER close() in read_cb). pending has no such post-close resolver, so close() owns its drain.
      local ids = {}
      for k in pairs(pending) do ids[#ids + 1] = k end   -- snapshot (clearer than delete-during-pairs)
      for _, k in ipairs(ids) do
        local entry = pending[k]
        pending[k] = nil
        if entry.timer then
          pcall(function()
            if not entry.timer:is_closing() then entry.timer:stop() end
            if not entry.timer:is_closing() then entry.timer:close() end
          end)
        end
        if entry.cb then entry.cb("connection closed") end   -- schedule_wrap'd -> deferred to safe loop
      end
      next_id = 0   -- fresh ids on the next connection (testability: "first request gets id 1")
  - PRESERVE: the existing close() body (state.closed flag, pipe close, state clear, server_info=nil). Do NOT
    add handshake_state clearing (the existing comment explains why).
  - GOTCHA: the drained cbs are schedule_wrap'd, so they fire on the NEXT nvim loop pass — in a test,
    `vim.wait` after close() pumps them. close() itself returns promptly (it does not block on the cbs).
  - DEPENDENCIES: Tasks 1-5.

Task 7: CREATE plugin/tests/bridge_request_spec.lua (plenary/busted — the Level-2 gate)
  - IMPLEMENT: a `with_request_server(opts, spec)` HOF mirroring bridge_handshake_spec.lua's with_hello_server,
    with mode-keyed behavior:
        "echo"    — reply {id, result={ok=true, n=<seq>}} for each request (correlation + ordering).
        "error"   — reply {id, error:{code:-32603, message:"boom"}}.
        "null"    — reply {id, result: vim.NIL} (JSON null) — wait, the SERVER writes JSON: write the literal
                    `'"result":null'` so the client decodes vim.NIL. (In Lua: srv_conn:write(vim.json.encode({jsonrpc="2.0", id=req.id, result=vim.NIL}).."\n") — verify vim.json.encode(vim.NIL) emits "null".)
        "slow"    — accept, never reply (per-request timeout).
        "stale"   — reply to an OLD id only AFTER a newer request arrives (drop-stale).
        "dup"     — reply twice to the same id (exactly-once).
        "stray"   — send a response with an id the client never requested.
    - Cases (mirror research/notes.md §5 — at minimum the 16 Success Criteria):
        expose request+cancel; auto-id monotonic+unique+distinct-from-"h1"; exact wire envelope;
        correlation success; out-of-order (r2 before r1); concurrent (getSuggestions+applyCompletion);
        error response; null result; stale-drop (timeout wins, late response no-op); duplicate (once);
        stray (dropped); per-request timeout (rpc_timeout_ms=40); cancel(id); close() drains pending +
        resets next_id; request-when-not-connected; never-throws; handshake-first (h1 then a request).
    - FOLLOW pattern: plugin/tests/bridge_handshake_spec.lua's with_hello_server + reset_module + vim.wait(budget, predicate, 5).
    - NAMING: describe("pi-editor.bridge request", …); it("…", with_request_server({mode=…}, function(path, opts, stop) … end)).
    - COVERAGE: every Success Criterion checkbox has a matching `it`.
    - PLACEMENT: plugin/tests/ (alongside bridge_handshake_spec.lua).
    - GOTCHA: reset_module() (close + nil pi.bridge) in before_each/after_each AND inside with_request_server.
      S26's close() draining pending + resetting next_id makes it sufficient (no new reset hook needed).
    - GOTCHA: do NOT name a spec-local table `pending` (shadows busted's global skip fn). Use `got`/`results`.
    - GOTCHA: for the null-result case, confirm `vim.json.encode({result = vim.NIL})` emits `"result":null`
      (LIVE-CHECK in the test setup; if not, write the raw JSON string). The assertion is `cb(nil, nil)`.
    - DEPENDENCIES: Tasks 1-6.
```

### Implementation Patterns & Key Details

```lua
-- === The resolver: the SINGLE exit point for regular requests (race-safe) =============
resolve_request = function(id, err, msg)
  if type(id) ~= "string" then return end
  local entry = pending[id]
  if not entry then return end            -- EXACTLY-ONCE guard (delete-entry); unknown id dropped
  pending[id] = nil                       -- delete FIRST so a racing resolver (timeout vs response) no-ops
  if entry.timer then                     -- luv timer :close() is REQUIRED (not just :stop())
    pcall(function()
      if not entry.timer:is_closing() then entry.timer:stop() end
      if not entry.timer:is_closing() then entry.timer:close() end
    end)
  end
  local cb = entry.cb
  if not cb then return end
  if msg == nil then                      -- timeout / cancel / close path
    cb(err or "request failed")
    return
  end
  if type(msg.error) == "table" then      -- error response
    local code = (type(msg.error.code) == "number") and msg.error.code or nil
    local emsg = code and ("rpc error " .. code) or "rpc error"
    if type(msg.error.message) == "string" and msg.error.message ~= "" then
      emsg = emsg .. ": " .. msg.error.message  -- server messages are generic; NEVER the token (PRD §12)
    end
    cb(emsg)
  elseif rawget(msg, "result") ~= nil then -- LIVE-VERIFIED: present-null (vim.NIL) ≠ absent (nil)
    local result = msg.result
    if result == vim.NIL then result = nil end  -- normalize getSuggestions null -> nil
    cb(nil, result)
  else
    cb("malformed response: no result or error")
  end
end

-- === The dispatch SEAM (S26 extends S25's single on_event) ===========================
dispatch = function(msg)
  if handshake_state and handshake_state.pending and msg and msg.id == "h1" then
    resolve_handshake(msg, nil)           -- S25 handshake branch (STAYS FIRST)
    return
  end
  -- S26: correlate a regular response by id.
  if msg and type(msg.id) == "string" then  -- guard: server id:null (§5.1) must not index pending[nil]
    if pending[msg.id] then
      resolve_request(msg.id, nil, msg)
      return
    end
    -- stale / late / duplicate / stray -> silently dropped (PRD §11)
  end
  -- S27 EXTENSION POINT: notifications (commandsChanged) go here.
end

-- === The public request() entry ======================================================
function M.request(method, params, on_result)
  if type(on_result) ~= "function" then return nil end          -- programming bug; degrade
  if type(method) ~= "string" or method == "" then
    vim.schedule_wrap(on_result)("invalid method"); return nil
  end
  if not M.is_connected() then                                  -- not connected -> no id, no entry, no timer
    vim.schedule_wrap(on_result)("not connected"); return nil
  end
  local id
  local ok, setup_err = pcall(function()                       -- pcall luv setup (S24/S25 discipline)
    next_id = next_id + 1
    id = tostring(next_id)                                      -- numeric string; NEVER "h1"
    pending[id] = { method = method, cb = vim.schedule_wrap(on_result), timer = nil }
    local cfg = require("pi-editor")
    local timeout_ms = ((cfg.config or cfg.defaults or {}).rpc_timeout_ms) or 2000
    local timer = uv.new_timer()
    pending[id].timer = timer
    timer:start(timeout_ms, 0, function()                       -- luv timer cb (fast ctx); resolve_request is luv-safe
      resolve_request(id, "request timeout", nil)
    end)
    local sent = M.send({ jsonrpc = "2.0", id = id, method = method, params = params })
    if not sent then resolve_request(id, "send failed", nil) end
  end)
  if not ok then
    if id then resolve_request(id, "request setup error: " .. tostring(setup_err), nil)
    else vim.schedule_wrap(on_result)("request setup error: " .. tostring(setup_err)) end
    return nil
  end
  return id                                                     -- so the caller can cancel(id) / supersede
end

-- === The local cancel(id) (no wire — server self-supersedes getSuggestions) ==========
function M.cancel(id)
  if type(id) ~= "string" then return end
  if not pending[id] then return end                           -- already resolved / unknown -> no-op
  resolve_request(id, "cancelled", nil)                        -- exactly-once via the delete-entry guard
end

-- === close() drain (added to the existing M.close(), before state.on_close=nil) ======
  -- (S26) drain ALL pending — resolve each cb ("connection closed"), stop+close each timer, clear map.
  local ids = {}
  for k in pairs(pending) do ids[#ids + 1] = k end
  for _, k in ipairs(ids) do
    local entry = pending[k]; pending[k] = nil
    if entry.timer then
      pcall(function()
        if not entry.timer:is_closing() then entry.timer:stop() end
        if not entry.timer:is_closing() then entry.timer:close() end
      end)
    end
    if entry.cb then entry.cb("connection closed") end         -- schedule_wrap'd -> next nvim loop pass
  end
  next_id = 0
```

### Integration Points

```yaml
MODULE STATE (bridge.lua):
  - add: "local next_id = 0"            # monotonic request-id counter (reset in close())
  - add: "local pending = {}"           # id → {method, cb(schedule_wrap'd), timer}; drained in close()

INTERNAL (bridge.lua):
  - add: "local resolve_request" (forward decl) + the resolver fn   # the exactly-once exit for regular requests

DISPATCH SEAM (bridge.lua):
  - extend: "dispatch(msg)" — add the `pending[msg.id]` branch AFTER the `id=="h1"` handshake branch

PUBLIC API (bridge.lua):
  - add: "M.request(method, params, on_result) -> string|nil"  # the generic RPC primitive (S30+ calls it)
  - add: "M.cancel(id)"                                         # local supersession cleanup (no wire)

TEARDOWN (bridge.lua):
  - extend: "M.close()" — drain pending (resolve cbs "connection closed", stop+close timers) + reset next_id
  - preserve: handshake_state is NOT cleared here (resolve_handshake owns it; see existing comment)

ACTIVATION (init.lua):
  - NO CHANGE — request() is called by completion (S30+), not activate(). The handshake (S25) already
    publishes `require("pi-editor").bridge = M`, so `bridge.request` is live post-handshake.

PLUGIN SURFACE (for downstream — PRD §7.7):
  - require("pi-editor").bridge.request(method, params, cb)   # blink/cmp sources + completion call this
  - require("pi-editor").bridge.cancel(id)                    # supersession / cleanup

CONFIG (already exists — S19):
  - read: "config.rpc_timeout_ms" (default 2000)  # the per-request timeout; no new option needed

NO NEW DEPENDENCIES:
  - only vim.uv (luv) + vim.json + vim.schedule_wrap + the S23 jsonlreader — all built into Neovim 0.10+ (0.12 verified)
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Lua is interpreted at load — a syntax error breaks the WHOLE plugin. Load-check every edit.
cd plugin && nvim --headless --clean -u NORC \
  -c 'luafile lua/pi-editor/bridge.lua' \
  -c 'luafile lua/pi-editor/init.lua' \
  -c 'qa' ; echo "load-exit=$?"   # expect 0

# luacheck (if installed — the repo currently has NO selene/stylua config; PRD §9.2 lists them
# as optional/future). If luacheck is available, run it for unused-var / globals hygiene:
luacheck lua/pi-editor/bridge.lua --std luajit 2>/dev/null || true

#stylua (optional formatting — no config yet; skip unless the repo adopts stylua.toml):
#stylua --check lua/pi-editor/bridge.lua tests/bridge_request_spec.lua 2>/dev/null || true
# Expected: load-exit 0; lint clean (or skipped). If load fails, READ the nvim stderr and fix.
```

### Level 2: Unit Tests (Component Validation — the formal gate)

```bash
# The NEW request spec (real luv socket server; every Success Criterion case):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_request_spec.lua")' \
  -c 'qa' ; echo "request-exit=$?"
# Expected: Success N / Failed 0 / Errors 0. (Exit 0 = pass; 1 = ≥1 assert fail; 2 = load error.)

# REGRESSION — the S25 handshake spec MUST still pass (dispatch only GAINED a branch):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_handshake_spec.lua")' \
  -c 'qa' ; echo "handshake-exit=$?"   # expect all green

# REGRESSION — the S24 transport spec (connect()'s signature is unchanged):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_spec.lua")' \
  -c 'qa' ; echo "bridge-exit=$?"   # expect Success 11 / Failed 0

# REGRESSION — the S23 jsonlreader spec (unchanged):
cd plugin && nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/jsonlreader_spec.lua")' \
  -c 'qa' ; echo "jsonlreader-exit=$?"

# The zero-dependency smoke (dormant-session + setup() invariants — pi.bridge still nil pre-handshake):
cd plugin && nvim --headless --clean -u NORC +"luafile tests/smoke.lua" +qa ; echo "smoke-exit=$?"
# Expected: stdout "SMOKE_PASS", exit 0.
```

### Level 3: Integration Testing (System Validation)

```bash
# End-to-end: a REAL bridge server (the DONE extension) + a headless nvim request round-trip.
# 1. Start pi with the bridge extension so the socket server is up and PI_EDITOR_BRIDGE is set in
#    pi's process. (Manual / scripted — see extension README; the handshake auto-runs on VimEnter.)
# 2. From that pi process's env, launch headless nvim on a temp pi-editor file, let the handshake
#    complete, then fire a `ping` request and assert the result:
TMP=$(mktemp --suffix=.pi.md); echo "hello world" > "$TMP"
PI_EDITOR_BRIDGE='<descriptor-from-pi>' nvim --headless --clean -u plugin/tests/minimal_init.lua \
  +"luafile plugin/plugin/pi-editor.lua" \
  -c 'lua vim.defer_fn(function()
        local pi=require("pi-editor")
        assert(pi.bridge ~= nil, "handshake did not set pi.bridge")
        assert(type(pi.bridge.request)=="function", "request missing")
        pi.bridge.request("ping", {}, function(err, result)
          assert(err == nil, "ping errored: " .. tostring(err))
          assert(type(result)=="table" and result.ok == true, "ping result not ok")
          assert(type(result.pid)=="number", "ping result missing pid")
          print("E2E_OK pid=" .. tostring(result.pid))
          vim.cmd("qa")
        end)
      end, 500)' \
  "$TMP" ; echo "e2e-exit=$?"
# Expected: stdout "E2E_OK pid=<n>", exit 0. (The 500ms defer lets the async handshake + RPC complete.)

# NEGATIVE e2e — request() before the handshake completes (pi.bridge still nil) must not crash:
PI_EDITOR_BRIDGE='' nvim --headless --clean -u plugin/tests/minimal_init.lua +"luafile plugin/plugin/pi-editor.lua" \
  -c 'lua vim.defer_fn(function()
        local pi=require("pi-editor")
        assert(pi.bridge == nil, "no-env bridge must be nil")
        print("NEG_OK"); vim.cmd("qa")
      end, 200)' ; echo "neg-exit=$?"
# Expected: "NEG_OK", exit 0.

# getSuggestions round-trip (the dominant caller): fire getSuggestions("/m") and assert items:
# (same harness as above, but the request is getSuggestions with {lines={"/m"}, cursorLine=0, cursorCol=2})
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Race-safety stress: fire many getSuggestions rapidly against a slow server; assert each cb fires
# EXACTLY ONCE (never 0, never 2) and the pending map drains to empty after the timeouts. Drive via a
# plenary case that counts callbacks and inspects the (observable) close()-drain. (Covered by the
# "stale-drop" + "duplicate" + "close drains pending" cases in bridge_request_spec.lua.)

# Timer-leak check: after a test that fires N requests and lets them all resolve (response/timeout/cancel),
# confirm no luv timer handles are left open. (Neovim's dev test harness has leak detection; the close()
# drain + per-resolve :close() guarantee this. A leaked timer would keep the event loop alive — observable
# as nvim not exiting promptly in the headless run.)

# :checkhealth stub (the FULL health module is S42; here just confirm bridge.request is callable after a
# successful handshake so S42 can ping through it):
nvim --headless --clean -u plugin/tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_request_spec.lua")' -c 'qa'

# (selene + stylua CI — OPTIONAL; the repo has no config yet. If adopted later, add a
# .github/workflows per PRD §9.2. Not blocking for this task.)
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 load-check: `bridge.lua` loads with exit 0 (no syntax error in the new resolver/dispatch/request/cancel/close code).
- [ ] Level 2: `bridge_request_spec.lua` → Success N / Failed 0 / Errors 0 (exit 0).
- [ ] Level 2 REGRESSION: `bridge_handshake_spec.lua` → all green (dispatch only gained a branch; handshake routes `id=="h1"` first).
- [ ] Level 2 REGRESSION: `bridge_spec.lua` → Success 11 / Failed 0 (connect()/send()/close() unchanged).
- [ ] Level 2 REGRESSION: `jsonlreader_spec.lua` → all green (unchanged).
- [ ] Level 2: `smoke.lua` → `SMOKE_PASS`, exit 0 (pi.bridge still nil pre-handshake; request() never runs dormant).

### Feature Validation
- [ ] Every Success Criterion checkbox in §What is covered by a spec case.
- [ ] E2E (Level 3): real bridge server → `ping` request returns `{ok, pid, cwd, …}`.
- [ ] Out-of-order + concurrent requests each resolve to their OWN cb (the pending MAP, not latest-id).
- [ ] `getSuggestions` `{"result":null}` resolves `cb(nil, nil)` (success, no matches) — NOT an error.
- [ ] Stale / duplicate / stray responses are silently dropped (no cb re-fire, no throw).
- [ ] Per-request timeout fires (`rpc_timeout_ms` shrunk in the test); timer `:close()`d (no leak).
- [ ] `cancel(id)` fires `cb("cancelled")`; a late response for that id is dropped.
- [ ] `close()` resolves every outstanding cb with "connection closed" + closes every timer + resets `next_id`.
- [ ] No exception escapes `request()`/`cancel()` (pcall-guarded luv; bad args degrade via cb/nil-return).

### Code Quality Validation
- [ ] `connect()`/`send()`/`handshake()` public signatures UNCHANGED (request/cancel are ADDED, not a refactor).
- [ ] bridge.lua stays pure `vim.uv` + `vim.json` + `vim.schedule_wrap` + jsonlreader (no new runtime deps; no `vim.api` from luv cbs).
- [ ] The dispatcher has ONE added branch (the S27 notification seam stays documented for S27).
- [ ] The token value NEVER appears in any request/error string (PRD §12 — it never appears in RPC responses anyway).
- [ ] Module state (`pending`, `next_id`) is drained/reset in `M.close()` (no leak across reconnects; no stale-entry reuse).
- [ ] Per-request luv timers are `:close()`d on EVERY resolve path (response/timeout/cancel/close) — no handle leak.
- [ ] Field naming matches the repo (`snake_case`, `M.` public, `local` internal; matches bridge/handshake style).

### Documentation & Deployment
- [ ] bridge.lua `[Mode A]` header gains an S26 note: `request()`/`cancel()` + the `pending` map + the dispatch branch + the close() drain.
- [ ] No new env vars / config options introduced (reuses `rpc_timeout_ms`).
- [ ] The "two-layer" design (transport pending-map + caller latest-id supersession) is documented in the header so S30+ knows to add its own latest-id guard.

---

## Anti-Patterns to Avoid

- ❌ Don't collapse the transport to a single "current pending id" — it would mis-drop a legitimate `applyCompletion`/`getCommands` response when a newer `getSuggestions` supersedes it. Use the `pending` MAP; supersession is the CALLER's job (latest-id guard or `cancel(id)`).
- ❌ Don't fork `dispatch()` into a per-request closure — it's a SINGLETON on_event (S24 GOTCHA 10). Add ONE branch after the handshake branch.
- ❌ Don't put the `pending[msg.id]` branch BEFORE the `id=="h1"` handshake branch — handshake responses must route to `resolve_handshake`, not `pending` (they're mutually exclusive today, but order defends against future changes).
- ❌ Don't index `pending[msg.id]` without `type(msg.id)=="string"` — a server `id:null` (JSON-RPC §5.1) would be a Lua `pending[nil]` index error.
- ❌ Don't `:stop()` a luv timer without `:close()` — `:stop()` makes it inactive but does NOT free the handle (it leaks across editor open/close cycles). Always `:close()`, guarded by `:is_closing()` (a double-`:close()` THROWS).
- ❌ Don't use `vim.defer_fn` for the per-request timeout — bridge.lua is pure `vim.uv` (S24 GOTCHA 5). Use `uv.new_timer()`.
- ❌ Don't call the user's `on_result` directly from a luv callback (read_start cb / timer cb) — those run in libuv/fast context where `vim.api.*` throws `E5560`. Store `vim.schedule_wrap(on_result)` in the entry and call `entry.cb(...)` (mirrors `vim/lsp/rpc.lua:324`).
- ❌ Don't resolve a request more than once — the delete-the-entry guard (`pending[id] = nil` FIRST) is load-bearing; every resolver (response/timeout/cancel/close) checks it via the `if not entry then return end` lookup.
- ❌ Don't treat `msg.result == nil` as "no result" without `rawget` — `{"result": null}` decodes to `result = vim.NIL` (present), distinct from `{}` (absent). getSuggestions' null result is a SUCCESS, not an error.
- ❌ Don't add a wire `cancel` notification — protocol.ts has NO cancel method; the server self-supersedes getSuggestions. cancel(id) is LOCAL cleanup only (a wire cancel would hit -32601 "method not found").
- ❌ Don't leave pending cbs hanging on `close()` — a closed transport never delivers more responses, so close() MUST drain the map (resolve each cb with "connection closed"). This is the LSP "never leave a cb hanging" invariant.
- ❌ Don't cache `rpc_timeout_ms` at module load — read it per request() (config can change via setup(); tests shrink it per-case).
- ❌ Don't name a spec-local table `pending` in the test file — it shadows plenary.busted's global `pending` (the test-skip function). Observe behavior into `got`/`results` locals instead.

---

## Confidence Score: 9/10

**Why 9, not 10:** every contract is pinned to a DONE, tested source file (the S24 transport, the S25
handshake/dispatch seam, the server's id-echoing dispatcher, the wire types). The design is the lowest-risk
extension of the existing module (one added dispatch branch + added request/cancel functions + a close() drain;
no public-signature change; the dispatch singleton stays intact for S27). The luv timer lifecycle, the
exactly-once delete-entry guard, and the `schedule_wrap(cb)` convention are all LIVE-VERIFIED against Neovim
0.12.4 + nvim's own LSP rpc.lua. The one residual uncertainty is the `vim.json.encode({result = vim.NIL})`
behavior in the null-result test case (the spec must LIVE-CHECK it emits `"result":null`; if not, write the
raw JSON string) — a mechanical test-authoring detail, not a design risk. If the E2E (Level 3) reveals a
timing flake, the fix is mechanical (the close() drain + delete-entry guard already centralize correctness).

**Implementer's fastest path:** read `research/notes.md` §1-4 (the two-layer design + the luv timer rules +
the vim.NIL result-discrimination), then implement Tasks 1-6 by pasting the Blueprint code into bridge.lua
(state block, resolve_request, the dispatch branch, request(), cancel(), the close() drain), then Task 7
(copy `bridge_handshake_spec.lua`'s `with_hello_server` and add the mode-keyed server behaviors). Run the
Level-2 gates (the new spec + the 3 regressions + smoke). Confirm the null-result case emits `"result":null`.