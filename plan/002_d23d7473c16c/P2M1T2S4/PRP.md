# PRP — P2.M1.T2.S4: `request(line, cursor, after, cb)` — framed protocol + gen-guard supersession

> **Plan mapping:** task `P2.M1.T2.S4` ("`request(line, cursor, after, cb)` — framed protocol + gen-guard
> supersession"). Fourth subtask of **P2.M1.T2** ("shell.lua daemon manager + fish spike") within the **Shell
> Completion for !/!! Bash Mode** epic (PRD §17). This is the **REQUEST layer** of `shell.lua`: it implements
> the single public completion-request entry point — `M.request(line, cursor, after, cb)` — that sends a framed
> `__PIREQ__\t{json}\n` line to the daemon's stdin and resolves `cb(err, items, prefix)` on the response. It
> CALLS S3's `M.ensure(cb)` (spawn-if-needed) FIRST, then bumps `state.gen` + sets `state.pending_cb` (the
> gen-guarded, ONE-SHOT response cb) + arms a one-shot luv per-request timeout + writes the frame.
>
> **Critical scope fact:** S4 does NOT parse the response (S5's `_feed` slices `__PIRESP_*` + decodes +
> normalizes + invokes `state.pending_cb`). S4 does NOT spawn (S3 `ensure`, delegated to the driver). S4 does
> NOT teardown (S6). S4 is the SEND + supersession + timeout layer. Tests use a FAKE driver / stubbed `ensure`
> + a FAKE stdin whose `write(data, cb)` captures the frame — NO real subprocess.
>
> **Sibling context (running in PARALLEL with S3):** S3 is implementing `ensure` + `_feed`/`_reset` stubs in
> the SAME file (`lua/pi-bridge/shell.lua`). **This PRP treats S3's PRP as a CONTRACT** — S4 APPENDS `request`
> + a local `cancel_req_timer()` + a module-local `req_timer` to the module S2/S3 produce, inserted BEFORE
> `return M`. S4 CALLS `M.ensure(function(err) ...)`. S4 SETS `state.gen`/`state.inflight`/`state.pending_cb`;
> S5 will INVOKE `state.pending_cb`. P2.M1.T2.S5 (`_feed`) is the NEXT consumer. The fish driver
> (P2.M2.T4.S1) produces the daemon that reads the frame S4 writes.

---

## Goal

**Feature Goal**: Implement `M.request(line, cursor, after, cb)` in `lua/pi-bridge/shell.lua` — the §17.5.1
framing protocol + the §17.5.2 `request()` supersession layer of the completion-daemon manager. On call it
(1) calls `M.ensure(cb)` to guarantee the daemon is up (short-circuits with `cb(err)` if the daemon is down);
(2) on ready, superseds any prior request (cancels its timer), bumps `state.gen` + captures it, sets
`state.inflight=true`, installs a ONE-SHOT gen-guarded `state.pending_cb`; (3) encodes the
`__PIREQ__\t{"line","cursor","after"}\n` frame + writes it to `state.stdin` (with a write-completion cb that
routes EPIPE → `cb("write failed")`); (4) arms a one-shot luv timer for `config.shell.timeout_ms` (default
1500) that, on fire, resolves the cb with an empty result (`cb(nil, {}, "")`, soft-degrade) — gen-guarded so a
superseded timeout is a silent no-op. Late responses for stale keystrokes are dropped by the gen-guard; a
double-fire (timeout-then-response or response-then-timeout) is a no-op via the null-slot-first finalize.

**Deliverable** (ONE source file EDITED + 2 new test files — nothing else is touched):
- **`lua/pi-bridge/shell.lua`** — APPEND to the module S2/S3 produced: a module-local `local req_timer` + a
  local `cancel_req_timer()` helper (~7 lines) + `M.request(line, cursor, after, cb)` (~45-60 lines), inserted
  BEFORE `return M` (AFTER S3's `ensure`/`_feed`/`_reset`). Zero edits to S2's state literal / functions /
  [Mode A] header; zero `vim.uv.spawn`; zero `vim.notify`/`notify.once`.
- **`tests/shell_request_smoke.lua`** — plenary-FREE smoke (mirror `tests/shell_smoke.lua`/S3's
  `shell_ensure_smoke.lua`): exercises request's matrix (happy-path response, sequential reqs, late-response
  dropped, timeout soft-degrade, timeout-superseded-dropped, write-fail async + sync, ensure-fails,
  config-timeout pass, nil-config, never-throws, exact wire shape, pending_cb one-shot, no timer leak) with a
  STUBBED `M.ensure` + a FAKE stdin. Prints `SMOKE_PASS`; exit 0.
- **`tests/shell_request_spec.lua`** — plenary/busted spec (mirror `tests/shell_spec.lua`/S3's
  `shell_ensure_spec.lua`): the same matrix as focused `it(...)` cases with field-by-field asserts +
  before/after_each save/restore.

**Success Definition**:
- `require("pi-bridge.shell").request` is a function. `request("git ch", 6, "", cb)` with the daemon ready
  writes EXACTLY `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n` to `state.stdin` (asserted on the fake
  stdin's captured `.written[1]`), bumps `state.gen`, sets `state.inflight=true`, sets `state.pending_cb` (a
  function), arms a one-shot timer for `config.shell.timeout_ms` (default 1500).
- When `state.pending_cb(items, prefix)` is invoked (by S5's `_feed`, or by the test), the user `cb(nil, items,
  prefix)` is called EXACTLY ONCE; `state.inflight==false`; `state.pending_cb==nil`; the timer is closed (no
  leak). A SECOND invocation of `pending_cb` (same gen) is a no-op (slot was nil'd).
- A NEW `request()` supersedes a prior one: the prior timer is cancelled (`cancel_req_timer()`); a late
  `pending_cb` invocation for the OLD gen hits `if gen ~= state.gen then return end` and is dropped (the OLD
  cb is NEVER called); the NEW request's cb is called on its OWN response.
- On timeout (timer fires, no supersession): `cb(nil, {}, "")` is called (empty result = soft-degrade); timer
  closed; `pending_cb==nil`. If superseded before firing, the timer's `pending_cb({}, "")` call is stale → no-op.
- A write failure (async EPIPE in the write cb, OR a sync throw pcall'd): `cb("write failed")`; timer closed;
  `pending_cb==nil`; `inflight==false`. Gen-guarded (a superseded write-fail cb is dropped).
- `M.ensure` reporting `err` (daemon down): `request` calls `cb(err)` and does NOT bump gen / arm a timer /
  write (short-circuit). Never throws.
- `shell_request_smoke` prints `SMOKE_PASS` (exit 0); `shell_request_spec` green (0 fail, 0 error).
- `shell_spec` (S2), S3's `shell_ensure_spec`/`_smoke` (if landed), `completion_spec`, `bridge_handshake_spec`,
  `init_spec`, `notify_smoke` stay green (S4 is purely additive over S2/S3's module).
- NO file under `extension/`, `doc/`, `ftplugin/`, `plugin/`, `completion.lua`, `bridge.lua`, `init.lua`,
  `notify.lua`, or `README.md` is modified. NO `shell/*.lua` driver is created (P2.M2/P2.M3). NO real
  subprocess is spawned (fake stdin / stubbed ensure in tests).

## User Persona (if applicable)

**Target User**: the implementer of **P2.M1.T2.S5** (`_feed(chunk)` — rx_buf sentinel slicing + JSON decode +
normalize → `pending_cb`). S5's `_feed` must invoke `state.pending_cb(items, prefix)` (guarded by
`if state.pending_cb then ...`), and S4's `pending_cb` (this PRP) is the gen-guarded one-shot cb S5 calls.
Secondary consumers: **P2.M2.T3.S2/S3** (`completion.lua` shell branch + `shell.complete_current(buf, cb)`) —
the routing that calls `M.request(line, cursor, after, cb)` and supplies the `cb(err, items, prefix)` that
stores `last_result` + pushes `on_results` (the menu hop, which P2.M2.T3 must `vim.schedule` — see FORWARD
CONTRACT §2). Also: the eventual `:checkhealth pi-bridge` (P2.M3.T6.S2) reads `state.inflight`/`state.failed`;
S6's `teardown()` (P2.M1.T2.S6) calls `cancel_req_timer()` (the module-local is in scope — same file).

**Use Case**: per keystroke on a `!`-line, completion routing needs to ask the daemon for completions. Because
the daemon is already warm (spawned once by S3's `ensure`), each `request()` is a fast framed round-trip:
encode the line/cursor/after, write `__PIREQ__\t{json}\n`, await `__PIRESP_*`. The gen-guard + one-shot
pending_cb ensure that fast typing (many keystrokes → many `request()`s) never delivers a stale result to the
menu — exactly completion.lua's two-layer supersession (§17.5.2), ported to the framed daemon channel.

**Pain Points Addressed**: without S4, S5's `_feed` would have nowhere to deliver the parsed result, and
routing (P2.M2.T3) would have to inline gen-bumping + timer-arming + frame-encoding + write-cb plumbing — one
tangled, untestable function. S4 isolates the SEND + supersession + timeout (trivially testable with a stubbed
ensure + fake stdin) from the PARSE (S5) and the SPAWN (S3) and the ROUTE (P2.M2.T3). The timeout + write-cb
discipline (mirrors bridge.lua `resolve_request`/`M.send`) prevents (a) a hung completion when a shell is slow
(`compinit` runaway), (b) a silent EPIPE swallow when the daemon dies mid-request, and (c) a `uv_timer_t`
handle leak on every superseded request.

## Why

- **It is the explicit §17.16 step-22 request half.** PRD §17.16 orders Phase 6: *(22) `shell.lua` daemon
  manager: resolution, spawn/teardown, framed protocol, gen-guard supersession*. S2 = resolution+state; S3 =
  spawn; **S4 = framed protocol + gen-guard supersession (the request half)**; S5 = feed/parse; S6 = teardown.
  The gen-guard + one-shot pending_cb design is exactly what the §17.5.2 skeleton specifies ("supersession
  mirrors completion.lua's two-layer design").
- **Consumes the S3 contract cleanly, ZERO file conflict.** S3 OWNS `ensure`/`_feed`/`_reset`. S4 APPENDS
  `request` + `cancel_req_timer` + the `req_timer` local to the SAME file (the only edit is insertion before
  `return M`, after S3's functions). S4 CALLS `M.ensure`; S5 will call `state.pending_cb`. No overlap with
  S2/S3's owned surface. (The module-local `req_timer` deliberately avoids editing S2's `state` literal —
  parallel-safe with S3, which is editing the same file now.)
- **The gen-guard + one-shot pending_cb is a correctness requirement.** §17.5.2: "a newer `request()` bumps
  `gen`, so a late response for a stale keystroke is dropped at the guard." Without it, fast typing would
  deliver stale completions (the menu would flicker to an old result). The ONE-SHOT null-slot-first finalize
  (mirrors bridge.lua `resolve_request`) additionally prevents a DOUBLE cb when BOTH the timeout and a late
  response fire — a subtle but real bug the literal §17.5.2 skeleton does not address (it has no timeout).
- **The per-request timeout is a UX + correctness requirement.** §17.12: "Per-request timeout (slow
  completion, runaway `compinit`) → abort + drop (gen-guard), leave the menu as-is or close. Never blocks the
  cursor." Without the luv timer, a slow/hung daemon would leave the completion promise hanging forever.
  §17.5.1 robustness: "the daemon MUST emit `__PIRESP_END__` even on error/empty … so the plugin's
  request-timeout + supersession never hang waiting for a missing sentinel." S4's timeout is the backstop.
- **The write-cb EPIPE discipline prevents a silent hang.** bridge.lua GOTCHA 3 (L625): a callback-less
  `pipe:write` SILENTLY swallows broken-pipe errors (the daemon died mid-request); completion would then hang
  until the timeout instead of failing fast with `cb("write failed")`. S4 ALWAYS passes a write cb (mirrors
  `M.send`). (research §2b.)
- **Fake-stdin tests give full request coverage WITHOUT a real shell.** The live spawn + framed round-trip was
  proven by S1's spike. S4's logic (gen-bump, frame encode, write-cb routing, timer arm/cancel, exactly-once
  finalize) is pure orchestration over `state.stdin:write` + `uv.new_timer` — exhaustively testable with a
  stubbed `ensure` + a fake stdin + a timer spy. (research §5.)

## What

**User-visible behavior**: none at runtime (no caller wires `shell.lua` into the plugin yet — completion
routing is P2.M2.T3). The observable artifact is the module's `request` API + the test verdicts:

```bash
$ timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_request_smoke.lua" +qa
SMOKE_PASS
$ echo "exit=$?"
exit=0
```

**Technical requirements** (all in `lua/pi-bridge/shell.lua` unless noted):
- **Module-local `local req_timer`** (declared near the top of S4's appended block, OR alongside S2's
  `local uv = vim.uv`): the single per-request timer slot. `nil` when disarmed. **NOT a `state` field** (S2's
  literal is the contract; S4 does not edit it — parallel-safe with S3). Visible to S6's `teardown()` (same file).
- **`local function cancel_req_timer()`** (mirrors completion.lua `cancel_timer` L350-360 + bridge.lua
  `resolve_request` timer cleanup L399-403): `pcall(function() if req_timer and not req_timer:is_closing() then
  req_timer:stop(); req_timer:close() end end); req_timer = nil`. NEVER stop-only (leaks the `uv_timer_t`).
- **`M.request(line, cursor, after, cb)`** (the §17.5.2 skeleton + the S4 hardening):
  1. `if type(cb) ~= "function" then cb = function() end end` — never-throws on a bad arg.
  2. `M.ensure(function(err) if err then return cb(err) end ... end)` — spawn-if-needed (S3). The ensure-failed
     path short-circuits request with `cb(err)` BEFORE any state mutation (no gen bump, no timer, no write).
  3. In ensure's SUCCESS cb: read config FRESH (defensive — S2 GOTCHA #2): `local pi = require("pi-bridge");
     local cfg = (pi.config and pi.config.shell) or {}; local timeout_ms = cfg.timeout_ms or 1500`.
  4. SUPERSEDE: `cancel_req_timer()` — drop the prior request's timer (the gen-guard drops its stale fire, but
     the un-closed HANDLE leaks — see GOTCHA #2/#8).
  5. Bump + capture: `state.gen = state.gen + 1; local gen = state.gen; state.inflight = true`.
  6. Install the ONE-SHOT gen-guarded `state.pending_cb`:
     ```lua
     state.pending_cb = function(items, prefix)
       if gen ~= state.gen then return end          -- STALE (superseded) → drop, touch nothing
       cancel_req_timer()                           -- response (or timeout) arrived → stop+close the timer
       state.pending_cb = nil                       -- NULL THE SLOT FIRST (exactly-once; mirrors resolve_request)
       state.inflight = false
       cb(nil, items, prefix)                       -- success-shape (err path is the write-fail / ensure-fail)
     end
     ```
  7. Encode: `local eok, payload = pcall(vim.json.encode, { line = line, cursor = cursor, after = after or "" })`.
     If `not eok` → `cancel_req_timer(); state.pending_cb = nil; state.inflight = false; return cb("encode failed")`.
  8. Arm the one-shot timer: `req_timer = uv.new_timer(); req_timer:start(timeout_ms, 0, function() if
     state.pending_cb then state.pending_cb({}, "") end end)`. (`repeat=0` = one-shot; the cb calls pending_cb
     with EMPTY items = soft-degrade → `cb(nil, {}, "")`; the gen-guard + null-slot make a superseded /
     double fire a no-op.)
  9. Write (pcall'd; WITH a write-completion cb — NEVER callback-less, bridge.lua GOTCHA 3):
     ```lua
     local frame = string.format("__PIREQ__\t%s\n", payload)
     local wok = pcall(function()
       state.stdin:write(frame, function(write_err)
         if not write_err then return end           -- write OK → await the response (S5 _feed → pending_cb)
         if gen ~= state.gen then return end        -- superseded → drop
         cancel_req_timer(); state.pending_cb = nil; state.inflight = false
         cb("write failed")                         -- async write failure (EPIPE / broken pipe)
       end)
     end)
     if not wok then                                -- stdin:write THREW (e.g. stdin nil/closed — defensive)
       cancel_req_timer(); state.pending_cb = nil; state.inflight = false
       cb("write failed")
     end
     ```
  10. NEVER throws: guard `cb` type; `M.ensure` is never-throws (S3); `vim.json.encode` + `uv.new_timer` +
      `stdin:write` are pcall'd. The ensure cb / timer cb / write cb all run in libuv FAST context and touch
      NO `vim.api.*` (only state writes + luv calls + `vim.json.encode` + the user cb) → fast-safe (E5560).
      The user cb's editor work is the CONSUMER's scheduling responsibility (FORWARD CONTRACT §2).

### Success Criteria

- [ ] `lua/pi-bridge/shell.lua` exposes `M.request` as a function (appended after S3's `ensure`/`_feed`/`_reset`);
      `return M` is preserved at EOF; a module-local `req_timer` + local `cancel_req_timer()` exist.
- [ ] `request("git ch", 6, "", cb)` with the daemon ready (stubbed `ensure`→ok + fake `state.stdin`) writes
      EXACTLY `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n` to `state.stdin` (asserted on the fake
      stdin's captured `.written[1]`); `state.gen` bumped; `state.inflight==true`; `state.pending_cb` is a
      function; a one-shot timer armed for `config.shell.timeout_ms` (default 1500).
- [ ] Invoking `state.pending_cb(items, prefix)` (the response) calls `cb(nil, items, prefix)` EXACTLY ONCE;
      `state.inflight==false`; `state.pending_cb==nil`; the timer is closed (no `uv_timer_t` leak).
- [ ] A SECOND `state.pending_cb(...)` invocation (same gen) is a NO-OP (the slot was nil'd → `cb` NOT called again).
- [ ] A NEW `request()` supersedes a prior one: the prior timer is cancelled; a LATE `pending_cb` for the OLD
      gen is dropped (`gen ~= state.gen`); the NEW cb is called on its OWN response; the OLD cb is NEVER called.
- [ ] On timeout (timer fires, no supersession): `cb(nil, {}, "")` (empty result = soft-degrade); timer closed;
      `pending_cb==nil`. If superseded before firing, the timer's `pending_cb({}, "")` is stale → no-op.
- [ ] Write failure (async EPIPE in the write cb): `cb("write failed")`; timer closed; `pending_cb==nil`;
      `inflight==false`. Gen-guarded (superseded → dropped).
- [ ] Write failure (sync throw — `state.stdin` nil): `cb("write failed")`; timer closed (pcall caught it).
- [ ] `M.ensure` reporting `err`: `request` calls `cb(err)` + does NOT bump gen / arm a timer / write.
- [ ] Config: `config.shell.timeout_ms` honored (NOT 1500 default when set); nil `config` does not throw.
- [ ] `request` NEVER throws (`request(nil,6,"",nil)`, `request(nil,6,"",123)`, a non-encodable payload).
- [ ] `shell_request_smoke` prints `SMOKE_PASS` (exit 0); `shell_request_spec` green (0 fail, 0 error).
- [ ] `shell_spec` (S2), S3's `shell_ensure_*` (if landed), `completion_spec`, `bridge_handshake_spec`,
      `init_spec`, `notify_smoke` stay green.
- [ ] NO edit to `extension/*`, `doc/*`, `ftplugin/*`, `plugin/*`, `completion.lua`, `bridge.lua`, `init.lua`,
      `notify.lua`, or `README.md`. NO `shell/*.lua` created. NO real subprocess spawned. NO `vim.uv.spawn` /
      `vim.notify` / `notify.once` CALL in S4 (only `uv.new_timer` + `stdin:write` + `vim.json.encode`).

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo gets (a) the verbatim §17.5.2
reference skeleton (the `request()` body: ensure → bump gen → capture → set pending_cb → encode → write) +
§17.5.1 (the EXACT `__PIREQ__\t{json}\n` wire shape + the `line`/`cursor`/`after` payload semantics), (b) the
EXACT S2 `state` fields this PRP reads/writes + the EXACT S3 `M.ensure(on_ready)` contract this PRP calls
(treats both PRPs as contracts), (c) the canonical in-repo references for EVERY non-obvious mechanic —
bridge.lua `resolve_request` (exactly-once + stop+close timer), bridge.lua `M.send` (the write-cb/EPIPE
discipline), completion.lua `do_refresh` (the gen-guard) + `cancel_timer` (the local timer-cleanup helper),
the fish spike (the luv handle shape), (d) the externally-verified luv facts (one-shot timer does NOT
auto-close; write cb is `function(err)` always invoked incl. EPIPE; E5560 fast-context rules; un-closed handles
leak; single-threaded ⇒ null-slot-first = exactly-once) with URLs, (e) the two test files to mirror
(`shell_smoke.lua`/S3's `shell_ensure_smoke.lua` + `shell_spec.lua`/S3's `shell_ensure_spec.lua`) with the
fake-stdin + stubbed-ensure + timer-spy recipes, (f) the locked design decisions (one-shot pending_cb with
null-slot-first; module-local req_timer; supersession cancels the prior timer; timeout = soft-degrade empty
result NOT an error; write-fail = `cb("write failed")`; never-throws pcall discipline; cb-only return), and
(g) the scope fence (what NOT to build: no parsing, no spawn, no teardown, no notify, no routing). The genuine
judgment calls (does timeout pass an err or empty items? module-local vs state field for the timer? does S4
vim.schedule the user cb? does write-fail route through pending_cb or call cb directly?) are decided in Design
Decisions §1-§8 + Anti-Patterns.

### Documentation & References

```yaml
# MUST READ — the spec (reproduced in this PRP's <selected_prd_content>)
- docfile: PRD.md
  why: "§17.5.1 gives the framing protocol (the EXACT __PIREQ__\\t{json}\\n wire shape + the line/cursor/after payload semantics). §17.5.2 gives the shell.lua request() skeleton (ensure → bump gen → capture → set pending_cb → encode → write) + the 'supersession mirrors completion.lua' contract. §17.11 gives config.shell.timeout_ms=1500 (per-request budget; NOT startup_timeout_ms=5000). §17.12 gives the timeout failure model ('abort + drop (gen-guard), leave the menu as-is or close'). §17.7 shows the routing cb that CONSUMES M.request's cb(err, items, prefix) (the if-err-bail + last_result + on_results shape — P2.M2.T3's job; informs the cb contract)."
  section: "h3.34 (§17.5 + §17.5.2 skeleton), h4.3 (§17.5.1 framing), h4.4 (§17.5.2 request skeleton), h3.36 (§17.7 routing), h3.40 (§17.11 config), h3.41 (§17.12 failure modes)"
  critical: "The skeleton's request() LITERALLY writes `state.stdin:write(string.format(\"__PIREQ__\\t%s\\n\", payload))` — but it has NO timeout timer + a callback-less write. S4 ADDS both (the per-request luv timer + the write-cb EPIPE discipline) per the item description + §17.12. The skeleton's pending_cb is `function(items, prefix) if gen ~= state.gen then return end; state.inflight = false; cb(nil, items, prefix) end` — S4 ADDS the null-slot-first (`state.pending_cb = nil` BEFORE cb) + cancel_req_timer() for exactly-once + leak-safety (mirrors bridge.lua resolve_request, which the skeleton predates). The item description's `pending_cb(\"timeout\", {}, \"\")` is a 3-arg call to a 2-param fn — S4 refines it to `pending_cb({}, \"\")` (empty items; D6)."

# MUST READ — the IMMEDIATE contract (S3 produces ensure; S4 calls it). Treat as a contract.
- file: plan/002_d23d7473c16c/P2M1T2S3/PRP.md
  why: "defines M.ensure(on_ready) EXACTLY: short-circuits on state.failed (→ cb('daemon disabled')) + state.proc (→ cb(nil)); on spawn delegates driver.start + caches state.proc/stdin/stdout + wires stdout:read_start → M._feed/M._reset; sets state.failed=true on no-driver/spawn-error; never-throws (pcall driver.start + read_start); returns nothing (cb-only). S4's request calls M.ensure(function(err) if err then return cb(err) end ... end). S3's Block H make_fake_driver() + fake_pipe() recipe is the basis for S4's fake stdin (S4 adds a write(data,cb) that captures the frame)."
  critical: "S3 is editing shell.lua IN PARALLEL with S4. S4 APPENDS request + cancel_req_timer + req_timer AFTER S3's ensure/_feed/_reset, BEFORE return M. If S3 hasn't landed, treat its PRP as the contract for ensure's existence (request CALLS M.ensure). For S4-ONLY tests, STUB M.ensure (function(self, cb) cb(nil) end) after priming state.stdin/proc/failed — decouples S4's matrix from S3's ensure matrix (re-test ensure only for the ensure-fails → cb(err) path)."

# MUST READ — the canonical in-repo EXACTLY-ONCE + timer pattern (LIVE-VERIFIED on Neovim 0.12.4)
- file: lua/pi-bridge/bridge.lua
  why: "L374-449 resolve_request: the delete/null-slot-FIRST exactly-once guard (`pending[id]=nil` before firing cb) + the stop+close timer cleanup (pcall + is_closing guard; ':close() is REQUIRED not just :stop()'). L619-636 M.send: the write-cb EPIPE discipline (pipe:write(data, function(werr) if werr then ... end) — the call does NOT throw; only the cb sees EPIPE; a callback-less write SILENTLY swallows it = GOTCHA 3). L587-589 + L695-697: the one-shot uv.new_timer arm (timer:start(timeout_ms, 0, cb)). L97-101: GOTCHA 5 (luv timer, NEVER vim.defer_fn; :close() required or leaks across cycles)."
  pattern: "resolve_request = delete-slot-first + stop+close-timer + fire-cb-once; M.send = write WITH a cb that routes werr."
  gotcha: "S4's state.pending_cb is the single-slot analogue of bridge.lua's pending[id] map (shell.lua is one-in-flight-at-a-time per §17.5.2). The null-slot-first (`state.pending_cb = nil` before cb) is the exactly-once invariant — WITHOUT it, a timeout-then-response or response-then-timeout double-fires cb."

# MUST READ — the canonical in-repo GEN-GUARD pattern (the §17.5.2 'MIRRORS completion.lua' contract)
- file: lua/pi-bridge/completion.lua
  why: "L406-490 do_refresh: the gen-guard supersession (`state.gen = state.gen + 1; local gen = state.gen` captured in the cb closure; `if gen ~= state.gen then return end` at the top of the cb). L350-360 cancel_timer: the local stop+close helper S4's cancel_req_timer mirrors (operating on a module-local req_timer here vs state.debounce_timer there — same idiom). L255-262 state.debounce_timer: the timer-tracking-in-state precedent (S4 uses a module-local instead to avoid editing S2's literal — D3)."
  pattern: "bump gen → capture local gen → guard `if gen ~= state.gen then return end` in the async cb. cancel_timer = pcall stop+close with is_closing guard."
  gotcha: "completion.lua's cb runs via bridge's schedule_wrap'd cb (already in the safe nvim loop). shell.lua has NO bridge — pending_cb runs in the libuv read_start cb (fast context). So the user cb's editor work must be scheduled by the CONSUMER (P2.M2.T3), NOT by S4 (FORWARD CONTRACT §2)."

# MUST READ — the canonical REAL luv handle shape (the fake stdin mirrors it)
- file: tests/shell_fish_spike.lua
  why: "the SINGLE best reference for the luv pipe API shape S4's fake stdin mirrors: uv.new_pipe(false); stdin:write(data) [the spike omits the cb — S4 ADDS it per bridge.lua M.send]; stdout:read_start(function(rerr,data)); pipe:is_closing(); pipe:close(); uv.process_kill (S6). Confirms write/read_start run on the libuv loop (fast context) + the teardown stop+close sequence."
  pattern: "the pipe:write + read_start + is_closing + close method set the fake stdin must expose."
  gotcha: "the spike is ALREADY E5560-safe (io.stderr:write + string ops only inside read_start). ⇒ S4's chain (state writes + stdin:write + uv.new_timer + vim.json.encode + the user cb) is fast-context-safe WITHOUT vim.schedule; the menu hop is the consumer's (P2.M2.T3) scheduling responsibility."

# MUST READ — local research notes (verified facts + the 8 locked design decisions + the req_timer lifecycle + the test matrix)
- docfile: plan/002_d23d7473c16c/P2M1T2S4/research/notes.md
  why: "§0 the task-boundary fence (S4 vs S2/S3/S5/S6/drivers/routing). §1 the INPUT contracts (S3 ensure, S2 state, config, framing). §2 the canonical in-repo references (bridge.lua resolve_request/M.send, completion.lua do_refresh/cancel_timer, the spike) + the researcher's verified facts. §3 the 8 locked design decisions (D1 ensure-first; D2 one-shot gen-guarded pending_cb; D3 module-local req_timer; D4 supersession cancels prior timer; D5 one-shot luv timer; D6 timeout=soft-degrade empty; D7 write-fail=cb('write failed'); D8 cb-only + never-throws). §4 the req_timer lifecycle diagram. §5 the testing strategy + fake-stdin/stubbed-ensure/timer-spy recipes + the 14-case matrix. §6 the 17 gotchas. §7 the forward contracts (S5's `if state.pending_cb` guard; the user cb runs in fast ctx → P2.M2.T3 schedules; S6 teardown calls cancel_req_timer). §8 references (in-repo + external URLs)."

# SUPPORTING — the dedup notify mechanism (S4 references in HEADER only; does NOT call)
- file: lua/pi-bridge/notify.lua
  why: "M.once(category, level, msg). S4's header documents that the §17.12 one-time degrade notify (category e.g. 'shell-daemon') is P2.M2.T3.S4's job; S4 has ZERO notify.once calls. Confirms S4 sets only the gen/inflight/pending_cb state, never notifies."

# SUPPORTING — the config source (S4 defensive-reads config.shell.timeout_ms)
- file: lua/pi-bridge/init.lua
  why: "L42-44 M.config (nil until setup(); the shell={} block is P2.M3.T6.S1 — NOT yet present). S4 reads (pi.config and pi.config.shell) defensively; cfg.timeout_ms defaults to 1500."

# SUPPORTING — architecture research (confirms the skeleton + framing + config + failure model)
- docfile: plan/002_d23d7473c16c/architecture/research-prd-section-17.md
  why: "§17.5.1 (L116-136) the framing protocol + the line/cursor/after semantics. §17.5.2 (L176-186) the request() skeleton + pending_cb. §17.11 (L395-411) config.shell.timeout_ms=1500. §17.12 (L415-416) the timeout failure model (abort+drop, leave as-is or close). Confirms the one-in-flight-at-a-time + sequential-sentinel contract."
  section: "§17.5.1, §17.5.2, §17.11, §17.12"
```

### Current Codebase tree (relevant slice)

```bash
lua/pi-bridge/
├── shell.lua          # ← S2 CREATED (state + resolve/pick/cwd/reset); S3 APPENDS ensure/_feed/_reset.
│                      #   S4 APPENDS request + cancel_req_timer + req_timer local here (before `return M`,
│                      #   after S3's functions). Does NOT touch S2's state literal / functions / [Mode A] header.
├── completion.lua     # READ-ONLY — the module to MIRROR (gen-guard in do_refresh; cancel_timer local helper).
├── bridge.lua         # READ-ONLY — resolve_request (exactly-once + stop+close timer) + M.send (write-cb EPIPE).
├── init.lua           # READ-ONLY — M.config (nil until setup); S4 reads config.shell.timeout_ms defensively.
└── notify.lua         # READ-ONLY — M.once dedup (S4 header-only reference; NOT called in S4).
lua/pi-bridge/shell/   # DOES NOT EXIST YET — P2.M2.T4 (fish) / P2.M3.T5 (zsh/bash) create the drivers.
                      #   S4 writes the frame the fish daemon will READ; pick_driver (S2) pcall-requires them.
                      #   S4 tests STUB M.ensure (or inject a fake driver per S3's recipe) — no real subprocess.
tests/
├── shell_fish_spike.lua      # READ-ONLY — the canonical real uv.spawn + pipe write/read example (handle shape).
├── shell_smoke.lua           # READ-ONLY (S2) — the smoke convention S4's smoke mirrors.
├── shell_spec.lua            # READ-ONLY (S2) — the spec convention S4's spec mirrors.
├── (shell_ensure_smoke.lua, shell_ensure_spec.lua)   # S3's tests (if landed) — S4's tests are SIBLINGS.
└── (shell_request_smoke.lua, shell_request_spec.lua) # ← S4 CREATES both
```

### Desired Codebase tree with files to be added/edited

```bash
lua/pi-bridge/shell.lua             # EDIT — APPEND M.request + local cancel_req_timer + local req_timer
                                     #   (before `return M`, after S3's ensure/_feed/_reset). ~+55-75 lines.
tests/shell_request_smoke.lua       # NEW — plenary-FREE smoke (the request matrix; stubbed ensure + fake stdin). SMOKE_PASS.
tests/shell_request_spec.lua        # NEW — plenary/busted spec (the same matrix as it(...) cases).
# (NO other file is created or modified.)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (AGENTS.md HARD RULE): run tests via `+"luafile tests/shell_request_smoke.lua" +qa` (a FILE on disk).
-- NEVER pipe a heredoc into nvim's stdin (`nvim ... +"luafile /dev/stdin" +qa <<EOF` HANGS the session —
-- ~10 killed sessions in this repo). Wrap every nvim in `timeout` (a hung headless nvim blocks the turn).

-- GOTCHA #1 — ONE-SHOT TIMER DOES NOT AUTO-CLOSE. `req_timer:start(ms, 0, cb)` only auto-STOPs; `:close()` is
-- REQUIRED to free the uv_timer_t (libuv owns the C struct — not GC'd until closed). cancel_req_timer() does
-- stop()+close() guarded by is_closing(). NEVER stop-only (leaks across editor open/close cycles — bridge.lua
-- GOTCHA 5 / researcher Q1+Q5). (research §3 D4 / §6 G2.)

-- GOTCHA #2 — THE WRITE CALLBACK IS `function(err)` AND IS ALWAYS INVOKED (incl. EPIPE). A callback-less
-- `stdin:write(frame)` SILENTLY swallows broken-pipe errors (the daemon died mid-request) → completion hangs
-- until the timeout instead of failing fast. S4 ALWAYS passes a cb (mirrors bridge.lua M.send GOTCHA 3). The
-- write call itself does NOT throw on EPIPE — only the cb sees `werr`. (research §2b / §6 G3.)

-- GOTCHA #3 — NULL THE SLOT FIRST, THEN FIRE. `state.pending_cb = nil` BEFORE `cb(...)` (inside pending_cb).
-- If you fire first, a re-entrant completion can double-invoke. This is the exactly-once invariant (mirrors
-- bridge.lua resolve_request `pending[id]=nil` first). Without it, a timeout-then-response OR
-- response-then-timeout DOUBLE-fires the user cb. (research §3 D2-C / §6 G5.)

-- GOTCHA #4 — THE GEN-GUARD IS THE SUPERSESSION BOUNDARY. `state.gen = state.gen + 1; local gen = state.gen`
-- captured in the pending_cb closure; `if gen ~= state.gen then return end` at the TOP of pending_cb. A late
-- response for a stale keystroke is dropped (mirrors completion.lua do_refresh). One request in-flight at a
-- time (§17.5.2: "shell completion is fast and the sentinel protocol is sequential"). (research §2c / §3 D2-A.)

-- GOTCHA #5 — TIMEOUT = SOFT-DEGRADE EMPTY, NOT AN ERROR. The timer cb calls `state.pending_cb({}, "")` →
-- `cb(nil, {}, "")` (the caller stores empty items → menu degrades/closes per §17.12 "or close"). The item
-- description's literal `pending_cb("timeout", {}, "")` is a 3-arg call to a 2-param fn (the 3rd arg is
-- dropped + items would become the string "timeout" — a bug). S4 refines it to `({}, "")`; "timeout" is a
-- dbg() trace marker only. Do NOT pass `cb("timeout", ...)` (that bypasses pending_cb + diverges from its
-- success-shape body; §17.12 allows "or close" so empty-items is correct). (research §3 D6 / §6 G6.)

-- GOTCHA #6 — MODULE-LOCAL `req_timer` (NOT state.req_timer). S2's PRP declared the `state` literal WITHOUT a
-- timer field; editing it would conflict with S3 (editing the same file now) + S2's reset() wouldn't clear it.
-- A module-local keeps S4 self-contained, parallel-safe, and is in-scope to S6's teardown() (same file).
-- Mirrors completion.lua's cancel_timer local helper (operating on a module-local vs state.debounce_timer).
-- (research §3 D3 / §6 G7.)

-- GOTCHA #7 — SUPERSEDE CANCELS THE PRIOR TIMER AT REQUEST START. `cancel_req_timer()` at the top of request's
-- ensure-success cb, BEFORE bumping gen. The gen-guard drops the prior timer's stale FIRE, but the un-closed
-- HANDLE leaks. Every new request() closes the prior timer. (research §3 D4 / §6 G8.)

-- GOTCHA #8 — LAZY `require("pi-bridge")` INSIDE request, NEVER at module top. The handshake is ASYNC
-- (pi.bridge nil at first-require); tests swap fakes AFTER require. Also avoids a circular-load hazard.
-- (S2 GOTCHA #1 — inherited.)

-- GOTCHA #9 — DEFENSIVE config read `(pi.config and pi.config.shell) or {}`. `pi.config.shell or {}` THROWS
-- if config is nil (indexing nil; M.config nil until setup() + shell={} block is P2.M3.T6.S1 — NOT yet present).
-- `cfg.timeout_ms or 1500` (§17.11; NOT startup_timeout_ms=5000 which is ensure's). (S2 GOTCHA #2.)

-- GOTCHA #10 — pcall `vim.json.encode`. vim.json.encode is fast-context-safe BUT throws on a non-encodable
-- table (e.g. a function/userdata value). Wrap it; on failure call `cb("encode failed")` (mirrors the
-- write-fail discipline). (research §6 G11.)

-- GOTCHA #11 — E5560 — pending_cb + the timer cb + the write cb all run in libuv FAST context. They do NO
-- `vim.api.*` (only state writes + vim.json.encode + luv calls + the user cb) → fast-safe. Do NOT vim.schedule
-- inside S4 (matches the §17.5.2 skeleton + the item description's direct `cb(nil, items, prefix)`). The user
-- cb's editor work is the CONSUMER's (P2.M2.T3) scheduling responsibility (FORWARD CONTRACT §2). (research §6 G4.)

-- GOTCHA #12 — TAB indentation throughout (match S2's shell.lua / completion.lua / bridge.lua). Every new line
-- uses tabs. (S2 GOTCHA #5 — inherited.)

-- GOTCHA #13 — no lua linter/formatter (no luacheck/selene/stylua/.luarc). The ONLY "type" surface is the
-- luaemmy `---@` annotations (lua-language-server, NOT runtime-enforced). Validation = the smoke + spec.
-- (S2 GOTCHA #6 — inherited.)

-- GOTCHA #14 — S4 APPENDS to shell.lua (insert request + cancel_req_timer + req_timer BEFORE `return M`, AFTER
-- S3's ensure/_feed/_reset). Do NOT touch S2's state literal / functions / [Mode A] header. If S3 hasn't landed,
-- S4 still works (request calls M.ensure; ensure's existence is the S3 contract). (research §6 G14.)

-- GOTCHA #15 — NO notify.once / vim.uv.spawn CALL in S4. The §17.12 degrade notify is P2.M2.T3.S4; spawn is S3's
-- ensure (delegated to the driver). S4 has only uv.new_timer + stdin:write + vim.json.encode + state writes.
-- (research §6 G15.)

-- GOTCHA #16 — NO real subprocess in tests. STUB M.ensure (function(self, cb) cb(nil) end) after priming
-- state.stdin/proc/failed=false — decouples S4's matrix from S3's ensure matrix. Use a FAKE stdin whose
-- write(data, cb) captures the frame + can invoke cb(nil) or cb("EPIPE"). Drive every request to a terminal
-- state (response / timeout / write-fail / ensure-fail) so no timer leaks across cases. (research §5/§6 G16.)

-- GOTCHA #17 — TESTS MUST DRIVE THE LOOP for the timeout case. A real uv.new_timer armed with timeout_ms=5 needs
-- a brief `vim.wait(50, function() return done end, 10)` for the timer cb to fire (vim.wait runs the luv loop;
-- it is NOT fast-context). Then pending_cb({}, "") fires → cb(nil, {}, ""). Assert exactly-once + no leak.
-- (research §6 G17.)
```

## Implementation Blueprint

### Design Decisions (READ FIRST)

**1. request calls `M.ensure` FIRST; the ensure-failed path short-circuits before ANY state mutation.** The
§17.5.2 skeleton: `M.ensure(function(err) if err then return cb(err) end ... end)`. If `state.failed` (S3 set
it), ensure returns `cb("daemon disabled")` immediately; request must NOT bump gen (would corrupt supersession
for a never-sent request) or arm a timer (leak) or write. This is D1. (research §3 D1.)

**2. `state.pending_cb` is ONE-SHOT + gen-guarded (the heart of S4).** The closure captures `local gen` at
bump time; guards `if gen ~= state.gen then return end` (supersession — mirrors completion.lua do_refresh);
then `cancel_req_timer()` (stop+close the timer) + `state.pending_cb = nil` (null-slot-FIRST — mirrors bridge.lua
resolve_request) + `state.inflight = false` + `cb(nil, items, prefix)`. The null-slot-first is the exactly-once
invariant that prevents a DOUBLE cb when BOTH the timeout AND a late response fire. pending_cb is invoked by S5's
`_feed` (response) AND by the timer cb (timeout), both guarded by `if state.pending_cb then ...`. This is D2.
(research §3 D2.)

**3. Module-local `local req_timer` + local `cancel_req_timer()` (NOT a `state` field).** S2's PRP declared the
`state` literal without a timer field; editing it would conflict with S3 (parallel) + S2's `reset()` wouldn't
clear it. A module-local keeps S4 self-contained + is in-scope to S6's `teardown()` (same file). Mirrors
completion.lua's `cancel_timer` local helper. This is D3. (research §3 D3.)

**4. Supersession cancels the prior timer at request START.** `cancel_req_timer()` at the top of request's
ensure-success cb, BEFORE bumping gen. The gen-guard drops the prior timer's stale fire, but the un-closed
`uv_timer_t` HANDLE leaks (one-shot only auto-stop s; `:close()` required). Every new request closes the prior.
This is D4. (research §3 D4.)

**5. The per-request timeout is a one-shot luv timer (NOT `vim.defer_fn`).** `req_timer = uv.new_timer();
req_timer:start(timeout_ms, 0, function() if state.pending_cb then state.pending_cb({}, "") end end)`. bridge.lua
GOTCHA 5 + the spike both use `uv.new_timer` for per-request timeouts over luv pipes. `repeat=0` = one-shot; the
cb runs in fast context (only a table read + a call into pending_cb → fast-safe). This is D5. (research §3 D5.)

**6. Timeout = SOFT-DEGRADE: `pending_cb({}, "")` → `cb(nil, {}, "")` (empty result, NOT an error).** The item
description's literal `pending_cb("timeout", {}, "")` is a 3-arg call to a 2-param fn (the 3rd arg is dropped +
`items` would become the string `"timeout"` — a type bug). S4 refines it to `({}, "")` (empty items = no result →
routing stores `last_result={items={},prefix=""}` → menu empties/closes per §17.12 "or close"). "timeout" is a
`dbg()` trace marker only. The alternative (`cb("timeout", ...)`) bypasses pending_cb + diverges from its
success-shape body + the gen-guard reuse the item explicitly wants. LOCKED. This is D6. (research §3 D6.)

**7. Write failure (sync pcall throw OR async EPIPE cb) → `cb("write failed")`.** Mirrors bridge.lua `M.send`
GOTCHA 3: the write cb receives `werr`; EPIPE is reported ONLY in the cb (the call does not throw). So TWO
surfaces, BOTH gen-guarded + both `cancel_req_timer()` + null-slot + `inflight=false`: (a) the async write cb's
`if werr then ... cb("write failed") end`; (b) the sync pcall fail `if not wok then ... cb("write failed") end`.
The `cb("write failed")` is the ERROR-shape cb (first arg = err string), distinct from pending_cb's
success-shape. This is D7. (research §3 D7.)

**8. request returns NOTHING (cb-only); guards `cb` type; never-throws.** `if type(cb) ~= "function" then cb =
function() end end`. `M.ensure` is never-throws (S3); `vim.json.encode` + `uv.new_timer` + `stdin:write` are
pcall'd. This is D8. (research §3 D8.)

### Data models and structure

S4 does NOT introduce new runtime types — it consumes S2's `state` (a `pi-bridge.ShellState`) + S3's `M.ensure`
+ adds one function + one local helper + one module-local slot. The only NEW contract surface is the **user
`cb` signature** (what P2.M2.T3's routing will pass):

```lua
--- The cb M.request invokes. Mirrors the §17.7 routing cb shape (err → bail; else store items/prefix).
--- Invoked from libuv FAST context (pending_cb runs in the read_start cb via S5 _feed, OR in the timer cb) →
---   the consumer (P2.M2.T3.complete_current) must `vim.schedule` any editor-touching work (E5560).
---@alias pi-bridge.shell.RequestCb fun(err:string|nil, items:table?, prefix:string?)
--   err     nil on success / timeout(empty) ; a string ("daemon disabled" | "write failed" | "encode failed" | ensure's err) on failure
--   items   the AutocompleteItem[] on success ; {} on timeout(soft-degrade) ; nil on error
--   prefix  the completion prefix on success ; "" on timeout ; nil on error
```

S4 SETS these `state` fields (declared by S2): `gen` (bump), `inflight` (true at start, false at finalize),
`pending_cb` (the one-shot gen-guarded closure). S4 READS `state.stdin` (the luv pipe S3 cached). S4 does NOT
touch `proc`/`stdout`/`rx_buf`/`shell`/`driver`/`cwd`/`failed` (S3/S5/S6).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ the contracts + the canonical references
  - READ lua/pi-bridge/shell.lua (S2's output + S3's appended ensure/_feed/_reset if landed): confirm `local
    state = {...}` has gen/inflight/pending_cb/stdin; confirm M.ensure exists (S3) OR treat S3's PRP as the
    contract; confirm the file ends with `return M`.
  - READ lua/pi-bridge/bridge.lua L374-449 (resolve_request — exactly-once + stop+close timer) + L619-636
    (M.send — write-cb EPIPE): internalize the patterns S4 mirrors.
  - READ lua/pi-bridge/completion.lua L406-490 (do_refresh gen-guard) + L350-360 (cancel_timer local helper).
  - READ tests/shell_fish_spike.lua (the luv pipe shape the fake stdin mirrors).
  - READ tests/shell_spec.lua + tests/shell_smoke.lua (S2 — the test conventions) + S3's shell_ensure_spec/smoke
    (if landed — the sibling tests).

Task 2: APPEND the module-local `req_timer` + `cancel_req_timer()` to lua/pi-bridge/shell.lua
  - PLACE: after S3's `M._reset()` (or after S2's `M.reset()` if S3 hasn't landed), BEFORE `return M`. Declare
    `local req_timer` (nil initially) at the top of S4's appended block.
  - WRITE cancel_req_timer per Reference block F1 (pcall stop+close with is_closing guard; nil the slot). JSDoc:
    "Mirrors completion.lua cancel_timer + bridge.lua resolve_request timer cleanup. stop()+close() (NEVER
    stop-only — a one-shot uv_timer_t only auto-STOPs; :close() is REQUIRED to free the handle, or it leaks
    across editor cycles). Called at request START (supersede the prior) + in pending_cb (response/timeout
    arrived) + in the write-fail paths + (future) S6 teardown(). pcall'd + is_closing-guarded (safe to call from
    INSIDE the timer's own cb — researcher Q2)."
  - DO NOT: add a state.req_timer field (GOTCHA #6). Do NOT call this from module top.

Task 3: APPEND M.request(line, cursor, after, cb) (insert AFTER cancel_req_timer, BEFORE `return M`)
  - WRITE the JSDoc block (mirror completion.lua/bridge.lua function docs): "The §17.5.2 request layer. Sends a
    framed __PIREQ__\\t{json}\\n to the daemon stdin + resolves cb(err, items, prefix) on the response (via S5's
    _feed → state.pending_cb) or the per-request timeout. Calls M.ensure FIRST (spawn-if-needed; short-circuits
    with cb(err) if the daemon is down). Supersession via the gen-guard (mirrors completion.lua do_refresh) +
    a ONE-SHOT null-slot-first pending_cb (mirrors bridge.lua resolve_request — prevents a double cb on
    timeout-then-response). One-shot luv timer (config.shell.timeout_ms, default 1500) → soft-degrade
    cb(nil, {}, '') on fire. Write WITH a cb (EPIPE → cb('write failed') — mirrors bridge.lua M.send GOTCHA 3).
    NEVER throws (pcall encode/new_timer/write; guard cb type). Returns nothing (cb-only). The user cb runs in
    libuv FAST context — the consumer (P2.M2.T3) must vim.schedule its editor work (E5560)."
  - IMPLEMENT per Design Decisions §1-§8 + the What §technical-requirements steps 1-10. Use Reference block F2.
  - DO NOT: vim.uv.spawn (S3). notify.once (P2.M2.T3.S4). vim.schedule inside S4 (GOTCHA #11). A callback-less
    write (GOTCHA #2). Pass cb("timeout",...) (GOTCHA #5 — use pending_cb({}, "")). Edit S2's state literal.

Task 4: CREATE tests/shell_request_smoke.lua — plenary-FREE smoke (mirror shell_smoke.lua/S3's shell_ensure_smoke)
  - WRITE the header doc-comment with the run command: `timeout 60 nvim --headless --clean -u NORC -c 'set
    rtp+=.' +"luafile tests/shell_request_smoke.lua" +qa`. Note the AGENTS.md HARD RULE.
  - BOOTSTRAP: `local me = debug.getinfo(1,"S").source:sub(2); local root = vim.fn.fnamemodify(me, ":h:h");
    vim.opt.runtimepath:append(root)`; `local pi = require("pi-bridge"); if pi.config==nil then pi.setup({}) end`;
    `local shell = require("pi-bridge.shell")`; `local uv = vim.uv`.
  - STUB M.ensure: save `local orig_ensure = shell.ensure`; set `shell.ensure = function(cb) cb(nil) end` for the
    happy-path cases (restore in restore()). For the ensure-fails case, `shell.ensure = function(cb) cb("daemon
    disabled") end`. Prime `shell.reset()` then set `state` via a tiny helper OR expose state by requiring the
    module's internal — SIMPLEST: the smoke sets `shell.ensure` + injects a fake stdin by temporarily replacing
    `require("pi-bridge.shell")` is NOT possible (state is local). INSTEAD: inject the fake stdin via the FAKE
    DRIVER recipe (S3 Block H): `package.loaded["pi-bridge.shell.fish"] = fake_driver` whose start(opts,cb)
    calls `cb(nil, fake_proc, fake_stdin, fake_stdout)`; set `pi.bridge = { get_shell_info = function() return
    { shell = "/usr/bin/fish" } end }`. Then `shell.ensure(real_cb)` runs the REAL ensure (S3) which caches the
    fake stdin into state. (This reuses S3's ensure — tests it as a bonus.) OR stub ensure + reach state via a
    test seam. PREFER: stub ensure to `function(cb) cb(nil) end` AND add a tiny `_set_test_state` seam? NO —
    minimal surface. BEST: use the fake-driver injection (S3's recipe) so `state.stdin` becomes the fake stdin
    via the real ensure. See Reference block H for make_fake_stdin + make_fake_driver_with_stdin.
  - CASES (each a `check`; see Validation Loop §Level-2-smoke for the full matrix): happy-path-response (wire
    shape + cb-once), sequential-reqs, late-response-dropped, timeout-soft-degrade (drive loop via vim.wait),
    timeout-superseded-dropped, write-fail-async (fake stdin write_err="EPIPE"), write-fail-sync (state.stdin
    nil — set via a fake driver that hands a stdin whose write throws, OR prime state.stdin=nil + stub ensure),
    ensure-fails (stub ensure→cb(err)), config-timeout-pass (timer spy), nil-config, never-throws
    (request(nil,6,"",nil)/request(nil,6,"",123)/non-encodable payload), pending_cb-one-shot, timer-no-leak.
    Use `shell.reset()` between cases + restore shell.ensure/pi.bridge/package.loaded.
  - FOOTER: `if fails>0 then io.stderr:write(fails.." check(s) failed\n"); vim.cmd("cquit 1") end;
    io.stdout:write("SMOKE_PASS\n")`.
  - DO NOT: spawn a real subprocess. Do NOT leave a timer armed across cases (drive each request to a terminal
    state). Do NOT test _feed-parsing/teardown (S5/S6).

Task 5: CREATE tests/shell_request_spec.lua — plenary/busted spec (mirror shell_spec.lua/S3's shell_ensure_spec)
  - WRITE the header doc-comment with the run command (minimal_init + plenary.busted.run).
  - BOOTSTRAP + before_each (save orig shell.ensure/pi.bridge/pi.descriptor/pi.config/package.loaded[fish];
    shell.reset(); inject fake driver OR stub ensure) + after_each (restore all + shell.reset()).
  - CASES: the same matrix as `it(...)` with `assert.are.equals`/`assert.is_nil`/`assert.is_same`/
    `assert.is_true`/`assert.is_false`/`assert.has_no.errors`. Group under `describe("pi-bridge.shell request
    (P2.M1.T2.S4)", ...)`.
  - DO NOT: spawn subprocess. Do NOT name a spec-local `pending` (shadows plenary's skip fn — S2 note). Do NOT
    test _feed/teardown (S5/S6).
```

### Reference implementation

```lua
-- === Block F1: local req_timer + cancel_req_timer() — APPEND to shell.lua (S4 block, before `return M`) ===
-- (Tabs throughout. module-local req_timer (NOT state) — parallel-safe with S3 + in-scope to S6 teardown.)

-- The single per-request timeout timer slot (module-local). `nil` when disarmed. At most ONE alive at a time:
-- request() cancels the prior at its start; every terminal path (pending_cb / write-fail / S6 teardown) closes
-- it. Deliberately NOT a `state` field: S2's PRP declared the state literal without it, and editing it would
-- conflict with S3 (editing this file in parallel) + S2's reset() wouldn't clear it. S6's teardown() (same
-- file) calls cancel_req_timer() before uv.process_kill + pipe:close.
local req_timer

--- Stop + close the per-request timer (the leak-safe finalize; mirrors completion.lua `cancel_timer` +
--- bridge.lua `resolve_request` timer cleanup). A one-shot `uv_timer_t` (start(ms, 0, cb)) only auto-STOPs
--- after firing — `:close()` is REQUIRED to free the handle, or it leaks across editor open/close cycles
--- (libuv owns the C struct; not GC'd until closed). NEVER stop-only. `pcall`'d + `is_closing()`-guarded so it
--- is safe to call from INSIDE the timer's own callback (researcher Q2) and idempotent on a already-closed
--- handle. Runs in libuv fast context (plain luv calls — no vim.api).
local function cancel_req_timer()
	pcall(function()
		if req_timer and not req_timer:is_closing() then
			req_timer:stop()
			req_timer:close()
		end
	end)
	req_timer = nil
end
```

```lua
-- === Block F2: M.request(line, cursor, after, cb) — APPEND to shell.lua (after cancel_req_timer, before return M) ===
-- (Tabs throughout. Calls S3's M.ensure. Bumps state.gen + sets state.pending_cb (the one-shot gen-guarded
--  response cb). Encodes __PIREQ__\t{json}\n + writes to state.stdin (WITH a cb). Arms a one-shot luv timer.)

--- The §17.5.1 framing-protocol + §17.5.2 supersession layer of the completion daemon. Sends a framed
--- `__PIREQ__\t{json}\n` request to the daemon's stdin and resolves `cb(err, items, prefix)` on the response
--- (via S5's `_feed` → `state.pending_cb`) OR the per-request timeout.
---
--- Flow:
---   1. call `M.ensure` FIRST (spawn-if-needed, S3). If the daemon is down (`state.failed`) ensure reports
---      `err` → short-circuit with `cb(err)` BEFORE any state mutation (no gen bump / timer / write).
---   2. on ready: SUPERSEDE — `cancel_req_timer()` (drop the prior request's timer; the gen-guard drops its
---      stale fire, but the un-closed HANDLE leaks). Bump `state.gen` + capture `local gen`; set `inflight=true`.
---   3. install the ONE-SHOT gen-guarded `state.pending_cb`: `if gen ~= state.gen then return end` (supersession,
---      mirrors completion.lua do_refresh) → `cancel_req_timer()` + `state.pending_cb = nil` (null-slot-FIRST
---      exactly-once, mirrors bridge.lua resolve_request) + `inflight=false` + `cb(nil, items, prefix)`.
---   4. `pcall(vim.json.encode, {line, cursor, after})` — on failure `cb("encode failed")`.
---   5. arm a one-shot `uv.new_timer()` for `config.shell.timeout_ms` (default 1500); on fire call
---      `state.pending_cb({}, "")` (soft-degrade empty result → `cb(nil, {}, "")`; §17.12 "or close").
---   6. `state.stdin:write("__PIREQ__\t{json}\n", cb)` — the write cb routes EPIPE → `cb("write failed")`
---      (bridge.lua M.send GOTCHA 3: a callback-less write SILENTLY swallows broken-pipe errors). pcall the
---      write (a sync throw, e.g. nil stdin, → `cb("write failed")`).
---
--- NEVER throws (guard cb type; pcall encode/new_timer/write; M.ensure is never-throws per S3). Returns
--- NOTHING (cb-only). The `cb` is invoked from libuv FAST context (pending_cb runs in the read_start cb via
--- S5 `_feed`, OR in the timer cb) → the consumer (P2.M2.T3.complete_current) must `vim.schedule` any
--- editor-touching work (`:help E5560`); S4's own chain does NO `vim.api.*` (only state writes + luv calls +
--- `vim.json.encode`).
---
---@param line   string  The command text up to the cursor (UTF-8; §17.5.1 — no UTF-16 conversion).
---@param cursor integer The 0-based BYTE offset into `line`.
---@param after  string? The text after the cursor (drivers that need the full line reconstruct it; default "").
---@param cb     pi-bridge.shell.RequestCb Resolved EXACTLY ONCE: cb(nil, items, prefix) on success/timeout(empty);
---               cb(err) on ensure-fail / write-fail / encode-fail.
function M.request(line, cursor, after, cb)
	if type(cb) ~= "function" then cb = function() end end          -- never-throws on a bad arg
	-- (1) spawn-if-needed (S3). The ensure-failed path short-circuits BEFORE any state mutation.
	M.ensure(function(err)
		if err then return cb(err) end                              -- daemon down (state.failed) → cb(err)
		-- (2) read config FRESH (lazy require — async handshake + test mocks; defensive: config.shell may be
		--     nil until P2.M3.T6.S1). ⚠️ NOT `pi.config.shell or {}` (throws if config nil) — use the AND-chain.
		local pi = require("pi-bridge")
		local cfg = (pi.config and pi.config.shell) or {}
		local timeout_ms = cfg.timeout_ms or 1500                   -- §17.11 per-request budget (NOT startup_timeout_ms=5000)
		-- (3) SUPERSEDE: cancel the prior request's timer (the gen-guard drops its stale fire, but the un-closed
		--     uv_timer_t HANDLE leaks without :close()). Done BEFORE bumping gen so the prior is fully torn down.
		cancel_req_timer()
		-- (4) bump + capture the gen-guard (mirrors completion.lua do_refresh). One request in-flight at a time
		--     (§17.5.2: "shell completion is fast and the sentinel protocol is sequential").
		state.gen = state.gen + 1
		local gen = state.gen
		state.inflight = true
		-- (5) the ONE-SHOT gen-guarded response cb. Invoked by S5's _feed (response) AND the timer cb (timeout).
		--     S5 MUST guard `if state.pending_cb then state.pending_cb(items, prefix) end` (the `if` is what makes
		--     this ONE-SHOT — a late duplicate response after the slot was nil'd is a no-op).
		state.pending_cb = function(items, prefix)
			if gen ~= state.gen then return end                    -- STALE (superseded by a newer request) → drop
			cancel_req_timer()                                     -- response (or timeout) arrived → stop+close the timer
			state.pending_cb = nil                                 -- NULL THE SLOT FIRST (exactly-once; mirrors resolve_request)
			state.inflight = false
			cb(nil, items, prefix)                                 -- success-shape (err path is ensure/write/encode-fail)
		end
		-- (6) encode the payload (pcall — vim.json.encode throws on a non-encodable table). On failure tear down
		--     + cb("encode failed") (mirrors the write-fail discipline).
		local eok, payload = pcall(vim.json.encode, { line = line, cursor = cursor, after = after or "" })
		if not eok then
			cancel_req_timer(); state.pending_cb = nil; state.inflight = false
			return cb("encode failed")
		end
		-- (7) arm the one-shot per-request timeout (luv timer, NEVER vim.defer_fn — bridge.lua GOTCHA 5). The cb
		--     calls pending_cb({}, "") → cb(nil, {}, "") (soft-degrade empty; §17.12 "or close"). The gen-guard +
		--     null-slot make a superseded / double fire a no-op. Runs in fast context (a table read + a call).
		req_timer = uv.new_timer()
		req_timer:start(timeout_ms, 0, function()
			dbg("[shell.request] timeout (gen=" .. tostring(gen) .. ")")  -- trace marker only (GOTCHA #5)
			if state.pending_cb then state.pending_cb({}, "") end
		end)
		-- (8) write the frame WITH a cb (bridge.lua M.send GOTCHA 3: a callback-less write SILENTLY swallows
		--     EPIPE → completion hangs until the timeout). pcall the write (a sync throw, e.g. nil stdin →
		--     cb("write failed")). The write cb: werr nil → await response; werr truthy → cb("write failed").
		local frame = string.format("__PIREQ__\t%s\n", payload)
		local wok = pcall(function()
			state.stdin:write(frame, function(write_err)
				if not write_err then return end                    -- write OK → await the response (S5 _feed → pending_cb)
				if gen ~= state.gen then return end                 -- superseded → drop
				cancel_req_timer(); state.pending_cb = nil; state.inflight = false
				cb("write failed")                                  -- async write failure (EPIPE / broken pipe)
			end)
		end)
		if not wok then                                            -- stdin:write THREW (e.g. stdin nil/closed — defensive)
			cancel_req_timer(); state.pending_cb = nil; state.inflight = false
			cb("write failed")
		end
	end)
end
```

```lua
-- === Block H: the fake stdin + fake driver for tests (tests/shell_request_smoke.lua + _spec.lua) ===
-- The fake stdin mirrors the luv pipe shape (write/is_closing/close/read_stop) AND captures the written frame
-- so tests can assert the EXACT wire shape. The fake driver (S3 Block H variant) hands the fake stdin to the
-- real M.ensure so state.stdin becomes the fake — reusing S3's ensure as a bonus. (For S4-ONLY isolation, you
-- may instead STUB shell.ensure = function(cb) cb(nil) end + reach state via the fake-driver injection below.)

local function make_fake_stdin(opts)
	opts = opts or {}
	return {
		written = {},                                               -- captured frames (assert wire shape)
		write = function(self, data, wcb)
			self.written[#self.written + 1] = data
			if opts.write_err then if wcb then wcb(opts.write_err) end           -- simulate async EPIPE
			elseif wcb then wcb(nil) end                                          -- write OK → await response
		end,
		is_closing = function() return false end,
		close      = function() end,
		read_stop  = function() end,
	}
end

local function make_fake_stdout()
	return { read_start = function(_, cb) end, is_closing = function() return false end, close = function() end } -- no-op; S5 owns _feed
end

local function make_fake_driver(fake_stdin, opts)
	opts = opts or {}
	return {
		start = function(dopts, cb)
			if opts.spawn_err then cb(opts.spawn_err, nil, nil, nil); return end
			local fake_proc = { is_closing = function() return false end }
			cb(nil, fake_proc, fake_stdin, make_fake_stdout())       -- ensure caches these into state
		end,
	}
end

-- Inject (so the REAL M.ensure caches the fake stdin): package.loaded["pi-bridge.shell.fish"] = make_fake_driver(stdin)
--   + pi.bridge = { get_shell_info = function() return { shell = "/usr/bin/fish" } end }
--   (resolve_shell must yield a "fish" basename). Then shell.ensure(function(err) ... end) caches state.stdin = fake_stdin.
-- For the ensure-fails case: stub shell.ensure = function(cb) cb("daemon disabled") end (bypass the driver).
-- For write-fail-sync: a fake_stdin whose write THROWS: write = function() error("boom") end (pcall catches → cb("write failed")).
-- For the timeout case: prime a real uv timer (timeout_ms=5) + vim.wait(50, function() return done end, 10) to drain the loop.

-- Timer spy (assert the EXACT ms passed to :start without a real leak):
local function spy_new_timer()
	local orig = uv.new_timer
	local spy = { starts = {} }
	uv.new_timer = function()
		local t = orig()
		local real_start = t.start
		t.start = function(_, ms, rep, f) spy.starts[#spy.starts + 1] = ms; return real_start(t, ms, rep, f) end
		return t
	end
	return spy, function() uv.new_timer = orig end
end
```

### Integration Points

```yaml
MODULE STATE (lua/pi-bridge/shell.lua — EDIT, additive append):
  - local req_timer                 → NEW module-local slot (the per-request timer; nil when disarmed).
  - cancel_req_timer()              → NEW local helper (stop+close; mirrors completion.lua cancel_timer).
  - M.request(line,cursor,after,cb) → NEW public request entry (framed protocol + gen-guard + timeout).
  - state SET by request: gen (bump), inflight (true→false), pending_cb (set→nil).
  - state READ by request: stdin (the luv pipe S3 cached).

NO EDITS to any existing file:
  - lua/pi-bridge/* other than shell.lua are READ-ONLY (completion.lua = the gen-guard/cancel_timer mirror;
    bridge.lua = the resolve_request/M.send mirror; init.lua = config; notify.lua = header-only ref).
  - S2's functions + state literal + [Mode A] header inside shell.lua are UNTOUCHED — S4 appends AFTER S3's
    ensure/_feed/_reset, BEFORE `return M`.
  - extension/*, doc/*, ftplugin/*, plugin/* — all UNTOUCHED.
  - NO shell/*.lua driver created (P2.M2.T4 / P2.M3.T5). NO new config key, RPC method, env var, or helpdoc.

FORWARD CONTRACTS (do NOT implement in S4; just expose pending_cb + document them):
  - S5's _feed(chunk) → invokes `if state.pending_cb then state.pending_cb(items, prefix) end` (the `if`
    guard is what makes pending_cb ONE-SHOT). S5 must `vim.schedule` the final menu hop (E5560) — but NOT the
    pending_cb call itself.
  - The user `cb` runs in libuv FAST context (pending_cb runs in read_start via S5 _feed OR in the timer cb) →
    the consumer (P2.M2.T3.complete_current) must `vim.schedule` its editor work (state.last_result = {} is
    fast-safe; M.on_results → menu is NOT). FLAG FOR P2.M2.T3.S2.
  - S6's teardown() (same file) → calls cancel_req_timer() BEFORE uv.process_kill + pipe:close ×3 + reset().
  - state.inflight → SET/CLEARED by S4 only; health (P2.M3.T6.S2) may read it.
```

## Validation Loop

> Run from the repo root (`/home/dustin/projects/pi-nvim-bridge`). ALWAYS wrap nvim in `timeout`
> (AGENTS.md HARD RULE). No lua linter exists (GOTCHA #13) — the smoke + spec ARE the gate. S4 spawns NO real
> subprocess (stubbed ensure / fake driver + fake stdin) → no live-shell gate (the fish seam is S1's spike).

### Level 1: Syntax (the file parses; the symbols exist)

```bash
# 1a. Confirm request + cancel_req_timer + req_timer are appended (and S2/S3's exports are intact):
grep -n "function M.request\|local function cancel_req_timer\|local req_timer\|function M.ensure\|function M._feed\|function M._reset\|function M.resolve_shell\|function M.reset" lua/pi-bridge/shell.lua
# expect: request + cancel_req_timer + req_timer are NEW (plus S2's 4 + S3's 3 if landed).
grep -n "^return M" lua/pi-bridge/shell.lua              # expect 1 (the EOF; S4 inserted BEFORE it)
grep -n "vim.uv.spawn\|notify.once\|vim.schedule(" lua/pi-bridge/shell.lua | grep -v "^.*--"   # expect: 0 CALLS in S4's code
# (uv.new_timer + stdin:write + vim.json.encode ARE expected + present — those are S4's luv surface.)
# 1b. Byte-compile the module (catches a syntax error fast; no subprocess):
timeout 30 nvim --headless --clean -u NORC \
  -c 'lua assert(loadfile("lua/pi-bridge/shell.lua"))' -c 'qa' && echo "PARSE_OK exit=$?"
# Expected: PARSE_OK exit=0. If loadfile returns nil + err, READ it: likely a tab/space mix, an unbalanced
#   `end`/`function`, or a typo in request. (The `pcall(state.stdin:write, frame, function(write_err) ... end)`
#   passes frame + the cb as args to stdin:write — correct luv usage. cancel_req_timer is a local fn referenced
#   by request; ensure it is declared BEFORE request in the file, OR use a forward `local cancel_req_timer`
#   declaration at the top of the S4 block if you prefer request-first ordering.)
```

### Level 2-smoke: the plenary-FREE smoke (the full request matrix)

```bash
# 2a. THE gate — run the smoke (prints SMOKE_PASS + exit 0):
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_request_smoke.lua" +qa
echo "exit=$?"
# Expected: SMOKE_PASS, exit=0.
# The smoke MUST cover (mirror these `check(...)` cases — see Task 4 + research §5c):
#   HAPPY-PATH-RESPONSE: stub ensure→ok (or fake-driver); request("git ch",6,"",cb) → fake_stdin.written[1]
#                        == "__PIREQ__\t{\"line\":\"git ch\",\"cursor\":6,\"after\":\"\"}\n" (EXACT); state.gen
#                        bumped; inflight==true; type(state.pending_cb)=="function"; cb NOT yet called. Then
#                        invoke state.pending_cb({{value="checkout"}},"ch") → cb(nil, items, "ch") called ONCE;
#                        inflight==false; pending_cb==nil; (timer closed — assert via uv.walk no stray uv_timer_t).
#   SEQUENTIAL-REQS:     req1 → pending_cb(items1,p1) → cb1; req2 → pending_cb(items2,p2) → cb2; no cross-talk.
#   LATE-RESPONSE-DROP:  req1 (gen=N); req2 (gen=N+1, supersedes); THEN invoke req1's captured pending_cb closure
#                        → cb1 NOT called (gen-guard: the closure's gen==N != state.gen==N+1); cb2 called on its
#                        own response. (Capture req1's pending_cb by saving state.pending_cb into a local BEFORE req2.)
#   TIMEOUT-SOFT-DEGRADE: cfg.shell.timeout_ms=5; request(...,cb); vim.wait(50, function() return done end, 10)
#                        → cb(nil, {}, "") called (empty result); inflight==false; pending_cb==nil; timer closed.
#   TIMEOUT-SUPERSEDED:  req1 armed w/ timeout_ms=5; req2 supersedes BEFORE the 5ms fires → req1's timer was
#                        closed by req2's cancel_req_timer; req1's (never-fired) timeout → no cb; req2's cb on
#                        its own response. (If req1's timer somehow fires, its pending_cb is stale → no-op.)
#   WRITE-FAIL-ASYNC:    fake_stdin write_err="EPIPE" → cb("write failed"); timer closed; pending_cb==nil; inflight==false.
#   WRITE-FAIL-SYNC:     fake_stdin.write throws → cb("write failed"); timer closed (pcall caught it).
#   ENSURE-FAILS:        stub ensure→cb("daemon disabled") → cb("daemon disabled"); gen NOT bumped; NO timer; NO write.
#   CONFIG-TIMEOUT-PASS: spy_new_timer(); cfg.shell.timeout_ms=2500 → spy.starts[1]==2500 (NOT 1500 default).
#   NIL-CONFIG:          pi.config=nil → no throw; spy.starts[1]==1500 (default).
#   NEVER-THROWS:        request(nil,6,"",nil); request(nil,6,"",123); request({f=function()end},6,"",cb) → no error.
#   FRAME-WIRE-SHAPE:    (covered by HAPPY-PATH) the EXACT __PIREQ__\t{json}\n string.
#   PENDING-CB-ONESHOT:  invoke state.pending_cb twice (same gen) → cb called ONCE (2nd no-op — slot nil'd).
#   TIMER-NO-LEAK:       after each terminal case, assert no stray uv_timer_t: count handles via
#                        `local n=0; uv.walk(function(h) if h.get_async_type and h:get_async_type()=="timer" then n=n+1 end end)` (or a simpler handle-count baseline).
# If a check FAILS: re-read the FAIL line; the most common causes are (i) a callback-less stdin:write (GOTCHA #2),
#   (ii) firing cb before nil-ing pending_cb (GOTCHA #3 — null-slot-first), (iii) not cancelling the prior timer
#   on supersession (GOTCHA #7 — leak), (iv) passing cb("timeout",...) instead of pending_cb({}, "") (GOTCHA #5),
#   (v) state.req_timer instead of the module-local (GOTCHA #6), (vi) not pcall'ing vim.json.encode (GOTCHA #10).
```

### Level 2-spec: the plenary/busted spec (the same matrix, asserted)

```bash
# 2b. THE spec gate — run shell_request_spec (expect all pass, 0 fail, 0 error):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_request_spec.lua")' 2>&1 | tail -8
echo "exit=${PIPESTATUS[0]}"
# Expected: "Success: <N>", "Failed : 0", "Errors : 0", exit 0. (~12-16 cases.)
# If a case fails: re-read its body vs the smoke case it mirrors — the assertion shapes must match
#   (assert.are.equals on fake_stdin.written[1] / spy.starts[1]; assert.is_nil on pending_cb post-finalize;
#   assert.is_false on inflight; assert.has_no.errors on the never-throws cases). Verify before_each restores
#   shell.ensure + pi.bridge + package.loaded["pi-bridge.shell.fish"] AND calls shell.reset() (so gen/inflight/
#   pending_cb/req_timer don't leak across cases).
```

### Level 3: Regression (the additive append breaks nothing)

```bash
# 3a. S2 + S3's own tests stay green (S4 appends to shell.lua; if S2/S3 have landed, their specs must still pass):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(shell_spec / S2)"
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(shell_ensure_spec / S3)"
# Expected: green (S4 is additive — S2/S3's functions are untouched). If S2/S3 haven't landed yet, skip.
# 3b. The suites that read the files S4 is adjacent to stay green:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(completion_spec)"
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/bridge_handshake_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(bridge_handshake_spec)"
timeout 60 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/init_spec.lua")' 2>&1 | grep -E 'Success:|Failed :|Errors :' | tr '\n' ' '; echo "(init_spec)"
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/notify_smoke.lua" +qa 2>&1 | tail -1; echo "(notify_smoke)"
# Expected: completion_spec green; bridge_handshake_spec 15/0/0; init_spec 14/0/0; notify_smoke SMOKE_PASS.
# (S4 edits shell.lua + adds 2 tests; it touches NOTHING else — these can only fail if you accidentally
#   modified a sibling or S2/S3's functions inside shell.lua.)

# 3c. Isolation — confirm the 3 expected files changed (shell.lua EDITED + 2 tests NEW; no sibling touched):
git status --porcelain
# Expected: ` M lua/pi-bridge/shell.lua`, `?? tests/shell_request_smoke.lua`, `?? tests/shell_request_spec.lua`.
#   (If shell.lua shows as `??` instead of ` M`, S2/S3 haven't committed yet — that's fine; treat it as new.)
```

### Level 4: (none — no MCP/Docker/Playwright/web/real-subprocess surface; S4 is pure lua + a stubbed ensure + fake stdin)

## Final Validation Checklist

### Technical Validation

- [ ] Level 1a: `request` + `cancel_req_timer` + `req_timer` are present; S2's 4 + S3's 3 exports intact; `return
      M` at EOF; ZERO `vim.uv.spawn`/`notify.once`/`vim.schedule(` CALLS in S4's code (uv.new_timer +
      stdin:write + vim.json.encode ARE present + expected).
- [ ] Level 1b: `lua/pi-bridge/shell.lua` byte-compiles (`PARSE_OK exit=0`).
- [ ] Level 2a: `tests/shell_request_smoke.lua` prints `SMOKE_PASS` + `exit=0` (the ~14-case request matrix).
- [ ] Level 2b: `tests/shell_request_spec.lua` green (all cases pass, 0 fail, 0 error).
- [ ] Level 3a: `shell_spec` (S2) + `shell_ensure_spec` (S3, if landed) green.
- [ ] Level 3b: `completion_spec`, `bridge_handshake_spec` (15/0/0), `init_spec` (14/0/0), `notify_smoke` green.
- [ ] Level 3c: `git status --porcelain` shows shell.lua (edited/new) + the 2 new tests ONLY.

### Feature Validation

- [ ] `request("git ch", 6, "", cb)` writes EXACTLY `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n` to
      `state.stdin` (asserted on the fake stdin's `.written[1]`); gen bumped; inflight=true; pending_cb set;
      one-shot timer armed for `config.shell.timeout_ms` (default 1500).
- [ ] `state.pending_cb(items, prefix)` → `cb(nil, items, prefix)` EXACTLY ONCE; inflight=false; pending_cb=nil;
      timer closed. A 2nd invocation (same gen) is a no-op.
- [ ] A new `request()` supersedes: prior timer cancelled; late pending_cb for the old gen dropped (gen-guard);
      new cb called on its own response; old cb NEVER called.
- [ ] Timeout (no supersession): `cb(nil, {}, "")` (soft-degrade empty); timer closed; pending_cb=nil. If
      superseded before firing, the timer's pending_cb({}, "") is stale → no-op.
- [ ] Write-fail (async EPIPE cb OR sync throw): `cb("write failed")`; timer closed; pending_cb=nil; inflight=false.
- [ ] ensure-fails: `cb(err)` + NO gen bump / timer / write.
- [ ] Config: `timeout_ms` honored (NOT 1500 default when set); nil config no-throw.
- [ ] request NEVER throws (`request(nil,6,"",nil)`, `request(nil,6,"",123)`, non-encodable payload).
- [ ] request returns nothing (cb-only).

### Code Quality Validation

- [ ] TAB indentation throughout (match S2/S3's shell.lua / completion.lua / bridge.lua).
- [ ] `require("pi-bridge")` is LAZY (inside request), NOT at module top (GOTCHA #8).
- [ ] No `vim.uv.spawn` / `vim.notify` / `notify.once` / `vim.schedule(` CALL in S4.
- [ ] The write is NEVER callback-less (`stdin:write(frame, function(write_err) ... end)`) (GOTCHA #2).
- [ ] `state.pending_cb = nil` happens BEFORE `cb(...)` inside pending_cb (null-slot-first; GOTCHA #3).
- [ ] Timeout calls `state.pending_cb({}, "")` (NOT `cb("timeout",...)` / NOT `pending_cb("timeout",...)`) (GOTCHA #5).
- [ ] `req_timer` is a module-local, NOT `state.req_timer` (GOTCHA #6); `cancel_req_timer` declared before `request`.
- [ ] Supersession calls `cancel_req_timer()` at request START, before bumping gen (GOTCHA #7).
- [ ] `vim.json.encode` + `uv.new_timer` + `stdin:write` are pcall'd (GOTCHA #10 + D8).
- [ ] S2's functions + state literal + [Mode A] header inside shell.lua are UNTOUCHED (append before `return M`).
- [ ] No edit to `extension/*`, `doc/*`, `ftplugin/*`, `plugin/*`, `completion.lua`, `bridge.lua`, `init.lua`,
      `notify.lua`, or `README.md`. No `shell/*.lua` created. No real subprocess spawned.

### Documentation & Deployment

- [ ] JSDoc blocks on `request` + `cancel_req_timer` document: the ensure-first flow, the one-shot gen-guarded
      pending_cb (null-slot-first), the module-local req_timer (why not state), the supersession-cancel-prior-
      timer, the timeout soft-degrade (empty not error), the write-cb EPIPE discipline, the never-throws/pcall
      discipline, the fast-context safety (no vim.schedule in S4; the consumer schedules), and the forward
      contracts (S5's `if state.pending_cb` guard; P2.M2.T3 schedules the user cb; S6 teardown calls cancel_req_timer).
- [ ] No README / `doc/pi-bridge.txt` / `doc/pi-bridge-shell.txt` / `extension/README.md` change (Mode-B task
      P2.M4.T7 + vimdoc task P2.M3.T6.S4 own those; S4 is pre-doc).
- [ ] Inline comments cite PRD §17.5.1 / §17.5.2 / §17.11 / §17.12 + bridge.lua resolve_request/M.send +
      completion.lua do_refresh/cancel_timer so a future reader knows WHY each piece exists.

---

## Anti-Patterns to Avoid

- ❌ **Don't call `stdin:write(frame)` WITHOUT a callback.** bridge.lua M.send GOTCHA 3: a callback-less write
  SILENTLY swallows broken-pipe errors (the daemon died mid-request) → completion hangs until the timeout
  instead of failing fast. ALWAYS pass `function(write_err) if write_err then ... cb("write failed") ... end end`.
  (Design Decision §7 / GOTCHA #2.)
- ❌ **Don't fire `cb(...)` before nil-ing `state.pending_cb`.** The null-slot-FIRST invariant (mirrors bridge.lua
  `resolve_request` `pending[id]=nil` first) is what makes pending_cb ONE-SHOT. Firing first lets a
  re-entrant/double-fire (timeout-then-response) invoke cb twice. (Design Decision §2 / GOTCHA #3.)
- ❌ **Don't use `state.req_timer`; use the module-local `req_timer`.** S2's PRP declared the `state` literal
  without it; editing it conflicts with S3 (parallel) + S2's `reset()` wouldn't clear it. A module-local is
  self-contained, parallel-safe, and in-scope to S6's teardown (same file). (Design Decision §3 / GOTCHA #6.)
- ❌ **Don't forget to `cancel_req_timer()` at the START of request (supersession).** The gen-guard drops the
  prior timer's stale FIRE, but the un-closed `uv_timer_t` HANDLE leaks (one-shot only auto-STOPs; `:close()`
  required). Every new request must close the prior timer. (Design Decision §4 / GOTCHA #7.)
- ❌ **Don't use `vim.defer_fn` for the per-request timeout; use `uv.new_timer`.** bridge.lua GOTCHA 5 + the
  spike both use `uv.new_timer` for per-request timeouts over luv pipes (consistency). `start(ms, 0, cb)` =
  one-shot. (Design Decision §5.)
- ❌ **Don't pass `cb("timeout", ...)` or `pending_cb("timeout", {}, "")`.** The item description's literal
  3-arg call is a type bug (pending_cb is 2-param; items would become the string "timeout"). Timeout =
  SOFT-DEGRADE: call `state.pending_cb({}, "")` → `cb(nil, {}, "")` (empty result; §17.12 "or close"). "timeout"
  is a `dbg()` trace marker only. (Design Decision §6 / GOTCHA #5.)
- ❌ **Don't skip the gen-guard, and don't skip `cancel_req_timer()` inside pending_cb.** The gen-guard
  (`if gen ~= state.gen then return end`) is the supersession boundary (mirrors completion.lua do_refresh);
  `cancel_req_timer()` inside pending_cb closes the timer when the response arrives (otherwise it leaks until
  it fires + is gen-dropped — still a leak). (Design Decision §2/§4.)
- ❌ **Don't `vim.schedule` inside S4.** pending_cb + the timer cb + the write cb run in libuv fast context but
  do NO `vim.api.*` (only state writes + luv calls + vim.json.encode + the user cb) → fast-safe WITHOUT
  schedule. The user cb's editor work is the CONSUMER's (P2.M2.T3) scheduling responsibility (matches the
  §17.5.2 skeleton's direct `cb(nil, items, prefix)` + how completion.lua relies on bridge's schedule_wrap).
  (GOTCHA #11 / FORWARD CONTRACT §2.)
- ❌ **Don't read config at module top, and don't write `pi.config.shell or {}`.** `M.config` is nil until
  `setup()`; `pi.config.shell or {}` THROWS (indexing nil). Use `require("pi-bridge")` LAZILY inside request +
  `(pi.config and pi.config.shell) or {}`, then `cfg.timeout_ms or 1500` (§17.11; NOT `startup_timeout_ms`).
  (GOTCHA #8/#9 — inherited from S2.)
- ❌ **Don't forget to `pcall` `vim.json.encode`, `uv.new_timer`, and `stdin:write`.** `vim.json.encode` throws
  on a non-encodable table (function/userdata value); `uv.new_timer`/`stdin:write` are genuine luv calls (a
  malformed/nil stdin could throw). A throw from any is handled (encode → `cb("encode failed")`; write →
  `cb("write failed")`). `M.ensure` is already never-throws (S3). (Design Decision §8 / GOTCHA #10.)
- ❌ **Don't touch S2's state literal / functions / [Mode A] header, and don't touch S3's `ensure`/`_feed`/`_reset`.**
  S4 APPENDS `request` + `cancel_req_timer` + `req_timer` AFTER S3's functions, BEFORE `return M`. (GOTCHA #14.)
- ❌ **Don't spawn a real subprocess or call `notify.once` in S4.** S4 has only `uv.new_timer` + `stdin:write` +
  `vim.json.encode` + state writes. Spawn is S3's ensure (delegated to the driver); the degrade notify is
  P2.M2.T3.S4. (GOTCHA #15.)
- ❌ **Don't leave a timer armed across test cases.** Inject a fake driver / stub ensure + a fake stdin; drive
  EVERY `request()` to a terminal state (response via pending_cb, OR timeout via a tiny timeout_ms + vim.wait,
  OR write-fail, OR ensure-fail) so `cancel_req_timer()` closes the timer before the next case. (GOTCHA #16/#17.)
- ❌ **Don't heredoc lua into nvim's stdin** (AGENTS.md HARD RULE — it hangs the session). Write the smoke to
  `tests/shell_request_smoke.lua` and run `+"luafile tests/shell_request_smoke.lua" +qa` (as shown). Wrap every
  nvim in `timeout`.

---

## Confidence Score

**9/10** for one-pass implementation success. The design is a faithful port of two LIVE-VERIFIED in-repo
patterns (bridge.lua `resolve_request` exactly-once + `M.send` write-cb discipline; completion.lua `do_refresh`
gen-guard + `cancel_timer` helper) to the single-slot shell-daemon model — every non-obvious mechanic has a
concrete in-repo precedent the implementer can read. The item description is unusually precise (it gives the
exact gen-guard body, the exact payload, the exact timeout default). The two genuine ambiguities (the 3-arg
`pending_cb("timeout", {}, "")` type bug → refined to `({}, "")`; module-local vs state field for the timer →
module-local for parallel-safety) are resolved in Design Decisions §3/§6 with clear reasoning + the §17.12
failure-model backing. The remaining risk is the cross-cutting scheduling concern (the user cb runs in fast
context → P2.M2.T3 must schedule) — flagged loudly as a FORWARD CONTRACT but explicitly OUT of S4's scope
(matches the skeleton). The test matrix (stubbed ensure + fake stdin + timer spy) is fully specified with
copy-pasteable recipes. -1 for the inherent parallel-edit risk with S3 (both append to shell.lua) — mitigated
by S4 appending strictly AFTER S3's functions + treating S3's PRP as a contract.