# Research notes — P2.M1.T2.S4: `request(line, cursor, after, cb)`

> The framed-protocol + gen-guard supersession layer of `shell.lua` (PRD §17.5.1 + §17.5.2
> `request()`). S4 is the **request half**: it calls S3's `ensure()` (spawn-if-needed),
> bumps `state.gen`, sets `state.pending_cb` (the gen-guarded, ONE-SHOT response cb),
> encodes the `__PIREQ__\t{json}\n` frame, writes it to `state.stdin`, and arms a one-shot
> luv timer for the per-request timeout (`config.shell.timeout_ms`, default 1500). It does
> NOT parse the response (S5's `_feed`) or teardown (S6).

---

## §0 — task-boundary fence (what S4 owns vs siblings)

| Layer | Owner | S4's relationship |
|---|---|---|
| state literal (`gen`, `inflight`, `pending_cb`, `stdin`, `proc`, …) | **S2** (created) | READS `gen`/`inflight`/`pending_cb`/`stdin`; WRITES them. Does NOT edit S2's state literal (adds a module-local `req_timer` instead — parallel-safe). |
| `resolve_shell` / `pick_driver` / `session_cwd` / `reset` | **S2** | not used by S4 (ensure owns resolution). |
| `ensure(on_ready)` | **S3** (implementing now) | **CALLS** `M.ensure(function(err) ...)`. Treat S3's PRP as the CONTRACT: on success `cb(nil)` with `state.proc`/`stdin`/`stdout` set; on failure `cb(err)` (and `state.failed=true`). |
| `request(line,cursor,after,cb)` | **S4** (this PRP) | THE deliverable. |
| `_feed(chunk)` (sentinel slicing → `pending_cb`) | **S5** | S4 SETS `state.pending_cb`; S5 INVOKES it. S5 must guard `if state.pending_cb then state.pending_cb(items, prefix) end` (FORWARD CONTRACT — S4 documents it). |
| `_reset()` / `teardown()` | **S6** | S4's module-local `req_timer` + `cancel_req_timer()` are in-scope to S6 (same file); S6's teardown will call `cancel_req_timer()` before kill+close. |
| fish/zsh/bash drivers | **P2.M2.T4 / P2.M3.T5** | not used by S4 (ensure owns the driver). |
| routing (`complete_current`, `do_refresh` shell branch) | **P2.M2.T3** | the CONSUMER of `M.request`. Its cb runs in libuv fast context (S4's pending_cb) → P2.M2.T3 must `vim.schedule` its menu hop (FORWARD CONTRACT). |
| `notify.once` degrade | **P2.M2.T3.S4** | S4 has ZERO notify calls. |

**S4 EDITS `lua/pi-bridge/shell.lua` (APPENDS `request` + `cancel_req_timer` + a `req_timer`
local BEFORE `return M`); does NOT touch S2's functions/state literal/[Mode A] header.**
2 new test files. Nothing else.

---

## §1 — INPUT contracts (consumed verbatim)

### 1a — S3's `M.ensure(on_ready)` (THE dependency; treat S3's PRP as a contract)
```lua
-- S3 produces this. S4 calls it.
function M.ensure(on_ready)          -- on_ready: fun(err:string|nil)
  -- short-circuits: state.failed → on_ready("daemon disabled"); state.proc → on_ready(nil)
  -- on spawn: resolves shell + picks driver + delegates driver.start + caches proc/pipes
  --   + wires stdout:read_start → M._feed / M._reset
  -- sets state.failed=true on no-driver / spawn-error
end
```
On success: `state.proc`/`state.stdin`/`state.stdout` are set (luv handles), `state.failed==false`.
On failure: `on_ready(err)` AND `state.failed==true` (so a follow-up ensure short-circuits).
**S4's request calls `M.ensure(function(err) if err then return cb(err) end ... end)` — the
ensure-failed path short-circuits request with `cb(err)` before touching state.gen/stdin/timer.**

### 1b — S2's `state` (the fields S4 reads/writes)
```lua
local state = {
  proc=nil, stdin=nil, stdout=nil, rx_buf="",
  gen=0, inflight=false,            -- ← S4 bumps gen; sets/clears inflight
  shell=nil, driver=nil, cwd=nil,
  pending_cb=nil,                   -- ← S4 sets this (the gen-guarded one-shot response cb)
  failed=false,
}
```
S4 does NOT add a `state.req_timer` field (that would require editing S2's literal — parallel
conflict with S3). Instead S4 declares a **module-local `local req_timer`** (visible to S6's
teardown, same file) + a local `cancel_req_timer()` helper. See §3 D3.

### 1c — config (read FRESH inside request; S2 GOTCHA #2 inherited)
```lua
local pi  = require("pi-bridge")                              -- LAZY (handshake async + test mocks)
local cfg = (pi.config and pi.config.shell) or {}             -- defensive (config nil until setup; shell={} block is P2.M3.T6.S1)
local timeout_ms = cfg.timeout_ms or 1500                     -- §17.11: per-request budget (NOT startup_timeout_ms=5000)
```
⚠️ `pi.config.shell or {}` THROWS if `config` is nil. Use the AND-chain.

### 1d — the framing protocol (PRD §17.5.1; EXACT wire shape)
```
request:  __PIREQ__\t{json}\n            # one line; \t-separated; json is the payload
response: __PIRESP_START__\n{json}\n__PIRESP_END__\n   # S5 slices this; S4 only SENDS the request
```
payload json = `{ line=<string>, cursor=<byte offset int>, after=<string> }`.
```lua
local payload = vim.json.encode({ line = line, cursor = cursor, after = after or "" })
local frame   = string.format("__PIREQ__\t%s\n", payload)
```
`vim.json.encode` is fast-context-safe (researcher Q4). `cursor` is a 0-based BYTE offset (§17.5.1;
Lua strings are UTF-8 — no UTF-16 conversion, unlike §8's pi path).

---

## §2 — the CANONICAL in-repo references (live-verified; stronger than external docs)

### 2a — `lua/pi-bridge/bridge.lua` `resolve_request` (L374-449) — THE exactly-once + timer pattern
S4 mirrors this. Key facts (LIVE-VERIFIED on Neovim 0.12.4 per bridge.lua comments):
- **delete/null the slot FIRST, then fire cb** → a late second resolver no-ops:
  ```lua
  local entry = pending[id]
  if not entry then return end          -- EXACTLY-ONCE guard (delete-entry)
  pending[id] = nil                     -- delete FIRST so a racing resolver (timeout vs response) no-ops
  ```
  S4's analogue: `state.pending_cb = nil` BEFORE calling the user cb. Single-threaded luv loop ⇒
  this is a sequenced-event guard, not a lock (bridge.lua L392 comment).
- **timer cleanup = stop() + close(), guarded by is_closing(), pcall'd** (L399-403):
  ```lua
  if entry.timer then
    pcall(function()
      if not entry.timer:is_closing() then entry.timer:stop() end
      if not entry.timer:is_closing() then entry.timer:close() end
    end)
  end
  ```
  Comment L399: *"luv timer `:close()` is REQUIRED (not just `:stop()`)"*. NEVER stop-only (leaks).
- **one-shot timer arm** (L587-589 handshake, L695-697 request):
  ```lua
  local timer = uv.new_timer()
  timer:start(timeout_ms, 0, function() resolve_request(id, "request timeout", nil) end)
  ```
  `repeat=0` = one-shot. The timer cb calls the resolver (which deletes the slot → no-op if already resolved).

### 2b — `lua/pi-bridge/bridge.lua` `M.send` (L619-636) — THE write-callback pattern
```lua
pipe:write(data, function(werr)
  if werr then                          -- GOTCHA 3: "EPIPE" etc. (the call does NOT throw; only the cb sees it)
    ... route to on_close ...
  end
end)
```
Comment L625: *"The write callback ALWAYS routes a broken-pipe `err` to `on_close` (GOTCHA 3 — EPIPE
is reported ONLY in the callback; a callback-less write silently swallows it and completion hangs forever)."*
**S4's `state.stdin:write(frame, function(werr) if werr then ... cb("write failed") ... end)` mirrors this EXACTLY.**

### 2c — `lua/pi-bridge/completion.lua` `do_refresh` (L406-490) — THE gen-guard supersession pattern
```lua
state.gen = state.gen + 1
local gen = state.gen
...
bridge.request("getSuggestions", params, function(err, result)
  if gen ~= state.gen then return end   -- STALE (superseded) — drop, touch nothing
  ...
end)
```
**S4's `state.pending_cb` captures `local gen = state.gen` and guards `if gen ~= state.gen then return end`.**
This is the §17.5.2 "supersession MIRRORS completion.lua's two-layer design" contract.

### 2d — `lua/pi-bridge/completion.lua` `cancel_timer` (L350-360) — THE local timer-cleanup helper
```lua
local function cancel_timer()
  pcall(function()
    if state.debounce_timer and not state.debounce_timer:is_closing() then
      state.debounce_timer:stop()
      state.debounce_timer:close()
    end
  end)
end
```
**S4's `cancel_req_timer()` mirrors this** (operating on the module-local `req_timer`).

### 2e — `tests/shell_fish_spike.lua` — the luv handle shape S4's fake stdin mirrors
- `uv.new_pipe(false)`, `stdin:write(data)` (the spike omits the cb — S4 ADDS it), `stdout:read_start`,
  `pipe:is_closing()`, `pipe:close()`, `uv.process_kill` (S6). S4's fake stdin in tests needs a
  `write(data, cb)` that captures the frame + can invoke `cb` synchronously (success) or with an err.

---

## §3 — the LOCKED DESIGN DECISIONS (read these before implementing)

### D1 — request calls `M.ensure` FIRST; the ensure-failed path short-circuits before any state mutation
```lua
M.ensure(function(err)
  if err then return cb(err) end   -- daemon down → cb(err); do NOT bump gen / arm timer / write
  ... bump gen, set pending_cb, arm timer, write ...
end)
```
Rationale: if `state.failed` (S3 set it), ensure returns `cb("daemon disabled")` immediately; request
must NOT bump gen (would corrupt supersession for a never-sent request) or arm a timer (leak). This
matches the §17.5.2 skeleton (`M.ensure(function(err) if err then return cb(err) end ...)`).

### D2 — `state.pending_cb` is ONE-SHOT + gen-guarded (the heart of S4)
```lua
state.pending_cb = function(items, prefix)
  if gen ~= state.gen then return end   -- (A) STALE — superseded by a newer request → drop, touch nothing
  cancel_req_timer()                    -- (B) response arrived (or timeout fired): stop+close the timer
  state.pending_cb = nil                -- (C) NULL THE SLOT FIRST (exactly-once; mirrors resolve_request)
  state.inflight = false                -- (D) clear inflight
  cb(nil, items, prefix)                -- (E) deliver (success-shape; err path is separate)
end
```
- **(A) gen-guard** = supersession (mirrors completion.lua do_refresh). A late response for a stale
  keystroke hits this and returns. `gen` was captured in the closure at bump time.
- **(C) null-slot-first** = exactly-once (mirrors bridge.lua resolve_request's `pending[id]=nil` first).
  This is what prevents a DOUBLE cb when BOTH the timeout AND a late response fire: whichever runs first
  nils `state.pending_cb`; the second finds it nil → S5's guard (`if state.pending_cb then ...`) + the
  timer's guard (`if state.pending_cb then ...`) make it a no-op. Single-threaded luv loop ⇒ no race.
- pending_cb is invoked by **S5's `_feed`** (response path: `if state.pending_cb then state.pending_cb(items, prefix) end`)
  AND by **the timer cb** (timeout path: `if state.pending_cb then state.pending_cb({}, "") end`).

### D3 — module-local `local req_timer` + local `cancel_req_timer()` (NOT a state field)
Rationale: S2's PRP declared the `state` literal WITHOUT a timer field. Adding `state.req_timer`
would require editing S2's literal (parallel conflict with S3, which is implementing now) AND S2's
`reset()` wouldn't clear it (S2 doesn't know about it). A **module-local** keeps S4 self-contained,
parallel-safe, and is in-scope to S6's `teardown()` (same file) — S6 will call `cancel_req_timer()`.
This mirrors completion.lua's `cancel_timer` local helper (operating on `state.debounce_timer` there;
here on a module-local — same idiom, different slot).
```lua
local req_timer                        -- module-local; at most ONE alive at a time (request cancels the prior)
local function cancel_req_timer()
  pcall(function()
    if req_timer and not req_timer:is_closing() then req_timer:stop(); req_timer:close() end
  end)
  req_timer = nil
end
```

### D4 — supersession cancels the prior timer at the START of request (prevent leak)
```lua
-- at the top of request's ensure-success cb, BEFORE bumping gen:
cancel_req_timer()                     -- drop the prior request's timer (it was gen-guarded anyway, but the HANDLE leaks)
```
Rationale: the gen-guard drops a stale timer *fire*, but an un-`close()`d `uv_timer_t` LEAKS (researcher
Q1/Q5: repeat=0 only auto-STOPS; `:close()` is REQUIRED to free the handle; libuv owns the C struct — not
GC'd until closed). So every new `request()` closes the prior timer. This is the completion.lua
`cancel_timer()` discipline applied to the per-request timeout.

### D5 — the per-request timeout is a one-shot luv timer (NOT vim.defer_fn)
```lua
req_timer = uv.new_timer()
req_timer:start(timeout_ms, 0, function()      -- repeat=0 → one-shot; fast-context cb
  if state.pending_cb then state.pending_cb({}, "") end   -- soft-degrade (see D6)
end)
```
Rationale: bridge.lua GOTCHA 5 (L97) + the spike both use `uv.new_timer`, NEVER `vim.defer_fn`, for
per-request timeouts over luv pipes. `vim.defer_fn` would also work but the codebase standard is the
luv timer (consistency with bridge.lua's request timeout). The timer cb runs in fast context — it does
only `if state.pending_cb then ... end` (a table read + a call into pending_cb, which does only state
writes + cb) → fast-safe (researcher Q4; the FINAL user cb's editor work is the consumer's scheduling
responsibility — see §7 FORWARD CONTRACT).

### D6 — timeout = SOFT-DEGRADE: `pending_cb({}, "")` → `cb(nil, {}, "")` (NOT an error)
The item description literally writes `pending_cb("timeout", {}, "")` — but `pending_cb` has a
2-param signature `function(items, prefix)` (S5 calls it as `pending_cb(items, prefix)`). Passing
3 args drops the 3rd; `items="timeout"` (a string) would corrupt the caller's `items or {}`. So S4
REFINES the literal text to the type-safe call: **`state.pending_cb({}, "")`** (empty items = no result),
with "timeout" recorded only as a `dbg("timeout")` trace marker.
- Effect: `cb(nil, {}, "")` → routing stores `last_result = {items={}, prefix=""}` → `on_results(buf, {}, "")`
  → the menu empties/closes. §17.12 explicitly allows timeout to "leave the menu as-is **or close**" — this
  is the "close" branch.
- Alternative considered: pass an error `cb("timeout", ...)` → routing bails (`if err then return end`) →
  menu stays as-is. ALSO valid per §17.12, but it BYPASSES `pending_cb` (the item wants the timeout to flow
  THROUGH pending_cb so the gen-guard is reused) and diverges from pending_cb's success-shape body
  (`cb(nil, items, prefix)`). The empty-items path is consistent with the item's pending_cb design. LOCKED.

### D7 — write failure (sync pcall throw OR async EPIPE cb) → `cb("write failed")`
Mirrors bridge.lua `M.send` GOTCHA 3 (L625): the write cb receives `werr`; EPIPE is reported ONLY in the cb
(the call does not throw). So TWO failure surfaces, BOTH gen-guarded + both cancel the timer + null the slot:
```lua
local wok, werr = pcall(function()
  state.stdin:write(frame, function(write_err)
    if not write_err then return end        -- write OK → await the response (S5 _feed → pending_cb)
    if gen ~= state.gen then return end     -- superseded → drop
    cancel_req_timer(); state.pending_cb = nil; state.inflight = false
    cb("write failed")                      -- async write failure (EPIPE / broken pipe)
  end)
end)
if not wok then                             -- stdin:write THREW (e.g. stdin nil/closed — shouldn't happen post-ensure, but defensive)
  cancel_req_timer(); state.pending_cb = nil; state.inflight = false
  cb("write failed")
end
```
The `cb("write failed")` is the ERROR-shape cb (first arg = err string), distinct from pending_cb's
success-shape `cb(nil, items, prefix)`. The routing cb's `if err then return end` bails silently. ✓

### D8 — request returns NOTHING (cb-only); guards `cb` type
Mirrors S3's ensure (Design Decision §7). `if type(cb) ~= "function" then cb = function() end end`.
S4 never throws: `M.ensure` is never-throws (S3); `vim.json.encode` is pcall'd (a malformed table could
throw — see GOTCHA); `uv.new_timer` + `stdin:write` are pcall'd.

---

## §4 — the `req_timer` lifecycle (who sets / who closes / who reads)

```
                ┌─ request() START (ensure-success cb) ─────────────────────────┐
                │  cancel_req_timer()   ← closes any PRIOR req_timer (supersede) │
                │  ... bump gen, set pending_cb ...                              │
                │  req_timer = uv.new_timer(); req_timer:start(timeout,0,cb)     │
                └────────────────────────────────────────────────────────────────┘
                                   │
            ┌──────────────────────┼──────────────────────┐
            ▼ (response arrives)                          ▼ (timeout fires)
   S5 _feed → state.pending_cb(items,prefix)      timer cb → state.pending_cb({}, "")
            │                                          │
            └──► pending_cb body: gen-guard → cancel_req_timer() → pending_cb=nil → cb(...)
                          (cancel_req_timer closes req_timer — safe even from INSIDE the
                           timer's own cb; researcher Q2 + is_closing() guard)
            ▲
            │ (write fails: pcall throw OR async EPIPE cb)
   write-fail path → cancel_req_timer() → pending_cb=nil → cb("write failed")

S6 teardown() (same file, future) → cancel_req_timer()   ← closes any still-armed req_timer
                                    then uv.process_kill + pipe:close ×3 + reset()
health (P2.M3.T6.S2) → reads state.failed (S3/S5/S6 set it), NOT req_timer
```
**Invariant: at most ONE `req_timer` is alive at any time** (request cancels the prior; every terminal
path closes it). Tests MUST drive every `request()` to a terminal state (response / timeout /
write-fail / ensure-fail) so no timer is left armed across cases.

---

## §5 — testing strategy (fake driver + fake stdin; NO real subprocess)

The live spawn seam was proven by S1's spike; S4 is pure orchestration over `state.stdin:write` +
`uv.new_timer`. Tests inject a **fake driver** (so `ensure` succeeds synchronously + caches fake pipes)
+ a **fake stdin** whose `write(data, cb)` captures the frame + lets the test invoke `cb` (success or err).

### 5a — fake stdin (mirrors the luv pipe shape; captures the frame)
```lua
local function make_fake_stdin(opts)
  opts = opts or {}
  return {
    written = {},                                   -- captured frames (assert wire shape)
    write = function(self, data, cb)
      self.written[#self.written+1] = data
      if opts.write_err then                        -- simulate async EPIPE
        if cb then cb(opts.write_err) end
      elseif cb then cb(nil) end                    -- write OK → await response
    end,
    is_closing = function() return false end,
    close = function() end,
    read_stop = function() end,                     -- (stdout uses read_start; stdin doesn't, but be safe)
  }
end
```

### 5b — fake driver (so ensure succeeds + caches proc/stdin/stdout)
Mirror S3's PRP Block H `make_fake_driver`, but the proc/stdin/stdout it hands to ensure's cb are the
FAKE stdin (above) + a fake proc + a fake stdout with a no-op `read_start`. Because ensure's fake driver
calls cb SYNCHRONOUSLY, `request()`'s inner body runs synchronously in the test — NO `vim.wait` needed.
**To inject the fake stdin:** override `pick_driver`'s result via `package.loaded["pi-bridge.shell.fish"]`
whose `start(opts, cb)` calls `cb(nil, fake_proc, fake_stdin, fake_stdout)`. OR (simpler, since S4 only
needs `state.stdin`): set `state.stdin`/`state.proc` directly + stub `M.ensure` to call its cb with nil.
The latter is cleaner for S4-only tests (decouples from S3's ensure matrix): **stub `M.ensure`** to
`function(self, cb) cb(nil) end` after priming `state.stdin`/`state.proc`/`state.failed=false`. (S3's
ensure is its own matrix; S4 re-tests it only for the "ensure fails → cb(err)" path.)

### 5c — the mandated test matrix (~12-16 cases)
| Case | Setup | Assert |
|---|---|---|
| HAPPY-PATH-RESPONSE | stub ensure→ok; fake stdin; prime state.stdin | `request(line,6,"",cb)` writes `"__PIREQ__\t{...}\n"` to stdin.written[1]; cb NOT yet called; invoke `state.pending_cb({{value="checkout"}}, "ch")` → `cb(nil, items, "ch")` called once; state.inflight==false; state.pending_cb==nil |
| SEQUENTIAL-REQS | two requests, each resolved via pending_cb | req1→cb1(items1,p1); req2→cb2(items2,p2); no cross-talk |
| LATE-RESPONSE-DROPPED | req1 (gen=1); req2 (gen=2, supersedes); THEN invoke req1's pending_cb | req1's cb NOT called (gen-guard); req2's cb called on its response |
| TIMEOUT-SOFT-DEGRADE | stub ensure→ok; request with `cfg.timeout_ms` tiny (e.g. 5); drive loop briefly (`vim.wait(50,...)`) | cb(nil, {}, "") called (empty result); state.inflight==false; pending_cb==nil; timer closed (no leak) |
| TIMEOUT-SUPERSEDED-DROPPED | req1 armed w/ tiny timeout; req2 supersedes BEFORE timeout fires | req1's timeout fires → pending_cb stale → no cb; req2's cb called on its response; req1's timer was closed by req2's cancel_req_timer |
| WRITE-FAIL-ASYNC | fake stdin write_err="EPIPE" | cb("write failed"); timer closed; pending_cb==nil; inflight==false |
| WRITE-FAIL-SYNC | state.stdin = nil (write throws) | cb("write failed"); timer closed (pcall caught the throw) |
| ENSURE-FAILS | stub ensure→cb("daemon disabled") | cb("daemon disabled"); gen NOT bumped (still prior value); NO timer armed; NO write |
| CONFIG-TIMEOUT-PASS | cfg.shell.timeout_ms=2500 | (capture the timer:start ms — expose via fake-timer spy OR assert via behavior) the 2500 is used (not 1500 default) |
| NIL-CONFIG | pi.config=nil | no throw; timeout defaults to 1500 |
| NEVER-THROWS | request(nil,6,"",nil); request(nil,6,"",123); a payload table vim.json.encode can't encode | no error; bad cb→no-op |
| FRAME-WIRE-SHAPE | request("git ch",6,"",cb) | stdin.written[1] == `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n` (EXACT) |
| PENDING-CB-ONESHOT | invoke pending_cb TWICE with the same (non-stale) gen | cb called ONCE (2nd is no-op — slot was nil'd) |
| TIMER-NO-LEAK | after each terminal case | `vim.uv.loop()` walk / handle-count assert: no stray uv_timer_t (mirror bridge.lua's leak discipline) |

### 5d — timer spy (to assert timeout_ms without a real leak)
A real `uv.new_timer()` armed with a tiny timeout + `vim.wait` drain is the most faithful (it proves
the luv path). To assert the EXACT ms passed to `:start`, wrap `uv.new_timer` with a spy in the test:
```lua
local orig_new_timer = uv.new_timer
local spy = { starts = {} }
uv.new_timer = function()
  local t = orig_new_timer()
  local real_start = t.start
  t.start = function(_, ms, rep, cb) spy.starts[#spy.starts+1] = ms; return real_start(t, ms, rep, cb) end
  return t
end
-- ... after_each: uv.new_timer = orig_new_timer ...
```
Then assert `spy.starts[1] == 2500`. (This is a test-only override; S4 calls the REAL `uv.new_timer` in prod.)

---

## §6 — gotchas (the landmines)

1. **AGENTS.md HARD RULE** — run smoke via `+"luafile tests/shell_request_smoke.lua" +qa` (a FILE on disk).
   NEVER pipe a heredoc into nvim stdin. Wrap every nvim in `timeout`.
2. **ONE-SHOT TIMER DOES NOT AUTO-CLOSE.** `start(ms, 0, cb)` only auto-STOPs; `:close()` is REQUIRED to free
   the `uv_timer_t` (researcher Q1/Q5; libuv owns the C struct — not GC'd until closed). `cancel_req_timer()`
   does stop()+close() guarded by `is_closing()`. NEVER stop-only.
3. **WRITE CALLBACK IS `function(err)` — ALWAYS invoked (incl. EPIPE).** A callback-less write SILENTLY
   swallows broken-pipe errors (researcher Q3; bridge.lua GOTCHA 3). S4 ALWAYS passes a cb to `stdin:write`.
4. **E5560 — pending_cb + the timer cb + the write cb all run in libuv FAST context.** They do NO `vim.api.*`
   (only state writes + `vim.json.encode` + luv calls + the user cb) → fast-safe (researcher Q4). The user
   cb's editor work is the CONSUMER's scheduling responsibility (§7 FORWARD CONTRACT). Do NOT `vim.schedule`
   inside S4 (matches the §17.5.2 skeleton + the item description's `cb(nil, items, prefix)` direct call).
5. **NULL THE SLOT FIRST, THEN FIRE.** `state.pending_cb = nil` BEFORE `cb(...)` (D2-C). If you fire first,
   a re-entrant/scheduled completion can double-invoke. Mirrors bridge.lua resolve_request `pending[id]=nil` first.
6. **TIMEOUT GOES THROUGH pending_cb (gen-guard reuse) — call it `({}, "")` NOT `("timeout", {}, "")`.**
   `pending_cb` is 2-param; the 3-arg literal over-passes + would make `items="timeout"` (a string). D6.
7. **MODULE-LOCAL `req_timer` (NOT state.req_timer).** Avoids editing S2's state literal (parallel-safe with
   S3). S6's teardown (same file) can call `cancel_req_timer()`. D3.
8. **SUPERSEDE CANCELS THE PRIOR TIMER at request START** (D4) — the gen-guard drops the stale FIRE, but the
   HANDLE leaks without `:close()`. `cancel_req_timer()` at the top of request's success cb.
9. **LAZY `require("pi-bridge")` INSIDE request** (S2 GOTCHA #1 inherited). NEVER at module top (async
   handshake + test mocks swap fakes after require; also avoids a circular-load hazard).
10. **DEFENSIVE config read** `(pi.config and pi.config.shell) or {}` (S2 GOTCHA #2). `pi.config.shell or {}`
    THROWS if config nil.
11. **`pcall` `vim.json.encode`** — a malformed table (e.g. a function value) throws. Wrap it; on failure call
    `cb("encode failed")` (mirrors the write-fail discipline). Researcher Q4 confirms encode is fast-safe, but
    it CAN throw on non-encodable input.
12. **TAB indentation** throughout (match S2's shell.lua / completion.lua / bridge.lua).
13. **NO lua linter/formatter** (S2 GOTCHA #6). The smoke + spec ARE the gate. `luaemmy` `---@` annotations are
    NOT runtime-enforced.
14. **S4 APPENDS to shell.lua** (insert `request` + `cancel_req_timer` + `req_timer` local BEFORE `return M`).
    Do NOT touch S2's state literal / functions / [Mode A] header (parallel with S3 which is editing the same
    file — S3 appends ensure/_feed/_reset; S4 appends request. If S3 hasn't landed, treat its PRP as the
    contract for `ensure`'s existence + `state.stdin`/`proc` being set on success).
15. **NO `notify.once` / `vim.uv.spawn` CALL in S4.** The degrade notify is P2.M2.T3.S4; spawn is S3's ensure
    (delegated to the driver). S4 has only `uv.new_timer` + `stdin:write` + `vim.json.encode` + state writes.
16. **NO real subprocess in tests.** Stub `M.ensure` (or inject a fake driver per S3's recipe) + fake stdin.
    Drive every request to a terminal state so no timer leaks across cases.
17. **TESTS: drive the loop for the timeout case.** A real `uv.new_timer` armed with `timeout_ms=5` needs a
    brief `vim.wait(50, ...)` (or `vim.uv.run`/loop drain) for the timer cb to fire. `vim.wait` runs the loop
    (it's NOT fast-context — researcher Q4). The timeout cb then fires pending_cb → cb. Assert exactly-once.

---

## §7 — FORWARD CONTRACTS (do NOT implement in S4; document them in the module header + pending_cb JSDoc)

1. **S5's `_feed(chunk)`** must invoke the response via: `if state.pending_cb then state.pending_cb(items, prefix) end`
   (the `if state.pending_cb` guard is what makes pending_cb ONE-SHOT — a late duplicate response after the slot
   was nil'd is a no-op). S5 must also `vim.schedule` the final menu hop (E5560) — but NOT the pending_cb call
   itself (pending_cb is fast-safe; the schedule belongs at the menu boundary).
2. **The user `cb` runs in libuv fast context** (it's invoked from pending_cb, which runs in the read_start cb
   via S5 _feed, OR in the timer cb). `cb` (P2.M2.T3's `complete_current` routing cb) must NOT call `vim.api.*`
   directly (E5560). Its fast-safe part (`state.last_result = {...}`) is fine; its menu hop (`M.on_results`)
   must be `vim.schedule`'d by P2.M2.T3 (mirrors how completion.lua's do_refresh relies on bridge's
   schedule_wrap'd cb). **FLAG THIS FOR P2.M2.T3.S2.**
3. **S6's `teardown()`** (same file) must call `cancel_req_timer()` (the module-local is in scope) BEFORE
   `uv.process_kill` + `pipe:close ×3` + `reset()`, so a still-armed per-request timer is freed on VimLeavePre.
4. **`state.inflight`** is SET by S4 (request start) + CLEARED by S4 (pending_cb / write-fail). S5 does NOT
   touch it. Health (P2.M3.T6.S2) may read it.

---

## §8 — references (all verified)

### in-repo (LIVE-VERIFIED — primary)
- `lua/pi-bridge/bridge.lua` L374-449 (`resolve_request` — the exactly-once + stop+close-timer pattern),
  L619-636 (`M.send` — the write-cb/EPIPE pattern), L587-589 & L695-697 (one-shot `uv.new_timer` arm),
  L97-101 (GOTCHA 5: luv timer, never defer_fn; `:close()` required).
- `lua/pi-bridge/completion.lua` L406-490 (`do_refresh` — the gen-guard supersession), L350-360 (`cancel_timer`
  — the local stop+close helper), L255-262 (`state.debounce_timer` field — the timer-tracking precedent).
- `lua/pi-bridge/shell.lua` (S2 — the `state` literal + the resolution helpers S4 reads; S3 appends `ensure`).
- `tests/shell_fish_spike.lua` (the luv handle shape: new_pipe/write/read_start/is_closing/close/process_kill).
- `tests/shell_spec.lua` + `tests/shell_smoke.lua` (S2 — the test conventions to mirror).
- `plan/002_d23d7473c16c/P2M1T2S3/PRP.md` (S3 — `ensure` contract; the fake-driver/fake-pipe recipe in Block H).
- `plan/002_d23d7473c16c/architecture/research-prd-section-17.md` §17.5.1 (framing), §17.5.2 (skeleton +
  request body), §17.11 (config: `timeout_ms=1500`), §17.12 (timeout → abort+drop, leave as-is or close).

### external (VERIFIED against Neovim's installed runtime docs by the researcher subagent; URLs are canonical)
- Neovim `luvref.txt` `*uv.new_timer()*` / `*uv.timer_start()*` (repeat=0 one-shot, NO auto-close) →
  https://neovim.io/doc/user/luvref.html#uv.new_timer()
- Neovim `luvref.txt` `*uv.write()*` (cb is `function(err)`, always invoked incl. errors) →
  https://neovim.io/doc/user/luvref.html#uv.write()
- Neovim `luvref.txt` `*uv.close()*` ("MUST be called on each handle before memory is released") + `*uv.is_closing()*` →
  https://neovim.io/doc/user/luvref.html#uv.close()
- Neovim `lua.txt` `*E5560* *lua-loop-callbacks*` (vim.api forbidden in vim.uv cbs; fast context) →
  https://neovim.io/doc/user/lua.html#E5560
- Neovim `api.txt` `*api-fast*` (fast fns allowed; editor state deferred) → https://neovim.io/doc/user/api.html#api-fast
- libuv v1.x `uv_timer_start` / `uv_write` / `uv_close` (handle lifecycle) → https://docs.libuv.org/en/v1.x/
- luv `docs.md` → https://github.com/luvit/luv/blob/master/docs.md
- Full researcher brief: `.pi-subagents/artifacts/outputs/abd7103e/research.md`