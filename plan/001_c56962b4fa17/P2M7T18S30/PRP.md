---
name: "P2.M7.T18.S30 — completion.lua refresh(buf): debounce + getSuggestions RPC + stale-response supersession (the per-keystroke trigger layer)"
description: |
  **CREATE `plugin/lua/pi-editor/completion.lua`** — the per-keystroke completion TRIGGER module (the
  first half of parent P2.M7.T18 "Completion triggers & debounce"; the result→menu population is the
  sibling S31). It owns EXACTLY the pipeline the buffer-local autocmds (DONE ftplugin S22) drive:
  `InsertEnter`/`TextChangedI`/`CursorMovedI` → `require("pi-editor.completion").refresh(buf)` (already
  wired as a no-op-safe `dispatch` in the COMPLETE `ftplugin/pi-prompt.lua`) → **debounce (~25 ms via
  `vim.defer_fn`)** → read buffer lines + cursor → convert to pi coords via the COMPLETE S29
  `coords.nvim_to_pi_coords` → issue `getSuggestions` over the COMPLETE S26 `bridge.request` →
  **SUPERSEDE stale responses** (cancel the previous in-flight request AND a generation-id guard in the
  callback — the LIVE-VERIFIED two-layer pattern from nvim-cmp/blink.cmp) → store the latest
  `{items, prefix}` and hand them to a **forward-contract callback seam** (`M.on_results(buf, items,
  prefix)`, nil-safe today, registered by S31 to populate the menu). **IMPLEMENTATION (the load-bearing
  refinement over `architecture/external_deps.md §1.7`):** that doc's debounce snippet uses `timer:stop()`
  ONLY — **LIVE-VERIFIED on nvim 0.12.x to LEAK the `uv_timer_t`** (`:stop()` suppresses the callback but
  leaves `is_closing()==false`; only `:close()` frees it). S30 must **`stop()`+`close()`** on every
  reschedule. (Conversely, after the defer FIRES naturally it AUTO-CLOSES — never `:close()` a fired
  timer or it throws "already closing".) Also LIVE-VERIFIED: the `vim.defer_fn` callback runs on the
  **nvim main loop** (api-safe — `nvim_buf_get_lines`/`nvim_win_get_cursor`/`bridge.request` may be
  called directly with NO `vim.schedule`, unlike a raw `uv.new_timer` fast-context callback which throws
  `E5560`). **Scope (narrow):** S30 implements `refresh(buf)` + the debounce + the RPC issuance +
  supersession + result storage + the `on_results` seam + a `reset()` teardown. It does NOT render the
  menu (S31/S34+), accept (S32), Tab-force (S33), or navigate (S36); it reads the bridge FRESH at call
  time (`require("pi-editor").bridge`, not a cached local — so test mocks + the async handshake both
  work). **Faithful to pi's model (PRD §7.4):** "the simplest correct approach is to ask the provider on
  every change and let *it* decide" — so `refresh` re-fetches on TextChangedI AND CursorMovedI (pi's own
  provider returns `null` when the cursor is not in a completable position); the ~25 ms debounce
  naturally collapses the TextChangedI+CursorMovedI pair a single keystroke emits into ONE fetch.
  **DELIVERABLES:** (1) CREATE `plugin/lua/pi-editor/completion.lua`; (2) CREATE
  `plugin/tests/completion_spec.lua` (plenary/busted — mocks the bridge so it tests the debounce/
  supersession/seam logic fast, mirroring bridge_request_spec's `vim.wait` async style); (3) CREATE
  `plugin/tests/completion_smoke.lua` (plenary-free — a light real-bridge integration: fake luv server +
  refresh → assert a getSuggestions request was issued). **NON-REGRESSION:** no existing file is
  modified — the ftplugin's `dispatch("pi-editor.completion","refresh",buf)` is ALREADY no-op-safe until
  this module lands, so all prior specs stay green and the 6 keymaps keep falling through to defaults.
---

## Goal

**Feature Goal**: Ship the **per-keystroke completion trigger layer** of pi-editor.nvim — `completion.lua`
— whose `refresh(buf)` is the autocmd entry point. It debounces insert-mode changes (`InsertEnter`/
`TextChangedI`/`CursorMovedI`, already wired buffer-local by the COMPLETE ftplugin S22), reads the buffer
+ cursor, converts to pi coordinates via the COMPLETE S29 `coords.nvim_to_pi_coords`, and issues a
`getSuggestions` RPC over the COMPLETE S26 `bridge.request` — **superseding stale responses** so only the
latest keystroke's result ever lands (the LIVE-VERIFIED two-layer pattern: cancel the previous in-flight
request + a generation-id guard in the callback). The latest `{items, prefix}` is stored and pushed to a
forward-contract `on_results(buf, items, prefix)` seam that S31 (menu population) will register. This is
the data-production half of completion; rendering is S31/menu.lua (S34+).

**Deliverable** (3 NEW files — no existing file modified):
- **CREATE** `plugin/lua/pi-editor/completion.lua` — a singleton module (`local M = {}` + module-level
  `state` + `return M`, like `bridge.lua` NOT like the stateless `coords.lua`) exposing:
  - `M.refresh(buf)` — the autocmd entry point. Validates `buf`, cancels any pending debounce timer
    (`stop()`+`close()` — LIVE-VERIFIED), schedules `do_refresh(buf)` via `vim.defer_fn(config.debounce_ms)`.
  - `M.on_results` — a callback slot `function(buf, items, prefix)` (nil today → no-op; registered by
    S31 to populate the menu). The forward-contract seam; mirrors `bridge.lua`'s `M.on_notification`.
  - `M.reset()` — teardown: cancel the debounce timer (`stop()`+`close()`), cancel any in-flight
    `bridge` request, clear `last_result`, reset the generation counter. The cleanup seam (used by tests
    + future S37 InsertLeave wiring). Idempotent + never throws.
  - `M.current()` — read-only accessor `{ items = [...], prefix = "..." } | nil` (the latest stored
    result; for S32 accept / S33 Tab to read the current items without coupling to the menu).
  - Module-level `[Mode A]` header documenting: role, the LIVE-VERIFIED `vim.defer_fn` stop+close leak,
  the api-safe callback fact, the two-layer supersession pattern, the "ask on every change" pi-faithful
  model, the forward contracts (S31 seam / S32 accept / S33 Tab / S36 nav / S37 close), + the
  research citations.
- **CREATE** `plugin/tests/completion_spec.lua` — plenary/busted spec. **Mocks the bridge** (sets
  `require("pi-editor").bridge = fake` with controllable `request`/`cancel`/`is_connected`) so it tests
  the debounce / supersession / seam logic FAST without a socket (the bridge transport is already
  exhaustively tested by bridge_request_spec). Mirrors the `vim.wait(ms, predicate, interval)` async
  style of bridge_request_spec.
- **CREATE** `plugin/tests/completion_smoke.lua` — plenary-free smoke. A LIGHT real-bridge integration:
  spin a fake luv unix-socket server (the bridge_request_spec `with_request_server` pattern), handshake,
  set a buffer's lines, call `completion.refresh(buf)`, drive the debounce with `vim.wait`, and assert
  the server received a `getSuggestions` request whose `params` match the buffer via S29 coords. Prints
  `SMOKE_PASS` / exit 0.

> Reuses `plugin/tests/minimal_init.lua` (S19) unchanged. **No modification** to `init.lua`, `bridge.lua`,
> `coords.lua`, `jsonlreader.lua`, the ftplugin, or any other module — the ftplugin's `dispatch` is
> already no-op-safe against an absent `pi-editor.completion`, so this task is purely additive.

**Success Definition** (every assertion is LIVE-VERIFIED or directly testable via the mock bridge):
- **`refresh` debounces**: rapid successive `refresh(buf)` calls (3× within the debounce window) issue
  AT MOST ONE `getSuggestions` request (the prior debounce timers are cancelled — `stop()`+`close()`).
- **`getSuggestions` params are correct**: the request's `params == { lines=<buf lines>,
  cursorLine=<row-1>, cursorCol=<S29 UTF-16>, force=false }` — i.e. the EXACT composition of S29's
  `nvim_to_pi_coords(lines, row, byte_col)` + `vim.tbl_extend("keep", pi, { force = false })`.
- **Stale responses are superseded (two layers)**: (a) `bridge.cancel(prev_id)` is called when a newer
  `refresh` fires while a request is in-flight; (b) a response whose captured generation id ≠ the live
  generation is dropped at the callback (the correctness boundary — even if cancel races, the id guard
  holds). Only the LATEST generation's result is stored + pushed to `on_results`.
- **`on_results` seam fires on success**: a registered `M.on_results` is called with `(buf, items, prefix)`
  for the latest (non-stale) result; it is NOT called for stale/error/cancelled results.
- **`null` result (no matches) → empty items**: a `{result: null}` response stores `{items={}, prefix=""}`
  and fires `on_results(buf, {}, "")` (success, empty — NOT an error).
- **Error/cancelled/timeout → touch nothing**: `on_result("cancelled"/"timeout"/"not connected"/<err>)`
  leaves `last_result` unchanged and does NOT call `on_results` (the LIVE-VERIFIED nvim-cmp/blink idiom —
  menu clearing is a SEPARATE signal from InsertLeave/S37, not a failed fetch).
- **No `vim.defer_fn` handle leak**: after `N` rapid refreshes, the reschedule path does `stop()`+`close()`
  on each superseded timer (LIVE-VERIFIED: `stop()`-only leaks). The fired timer auto-closes.
- **Bridge read fresh at call time**: `refresh` works when `require("pi-editor").bridge` is set AFTER
  `completion.lua` is first required (the handshake resolves async) — completion does NOT cache the bridge
  at module load.
- **`reset()` is idempotent + never throws** and cancels both the debounce timer and any in-flight request.
- Non-regression: all prior specs (init/shim/activate/ftplugin/jsonlreader/bridge/handshake/request/
  notify/coords-S28/S29) still pass unchanged; the 6 keymaps still fall through to defaults
  (`on_tab`/`on_enter`/`on_next`/`on_prev`/`on_dismiss` are NOT implemented by S30 — they remain absent
  until S32/S33/S36/S37, and the ftplugin's `dispatch` returns false → `feedkey` fall-through).

## User Persona (if applicable)

**Target User**: A pi user typing a prompt (`/mod…`, `@src/comp…`, `./path/…`) in the Neovim external
editor. They never see this code; they experience it as "completion suggestions appear ~25 ms after I
stop typing, and they always reflect what I just typed — never a stale suggestion from two keystrokes
ago, and never a flicker/hang if the bridge is slow or I type fast."

**Use Case**: The trigger half of the completion pipeline. Activation (S21) → buffer (S22) → bridge
transport+handshake+RPC (S24–S27, COMPLETE) → coords (S28/S29, COMPLETE) → **S30 (this: refresh →
debounce → fetch → supersede → store → seam)** → S31 (menu population) → S32 (accept) → S33 (Tab-force) →
S34+ (floating menu). Without S30, the ftplugin's 3 buffer-local autocmds dispatch into a missing module
(no-op today); S30 makes them live.

**Pain Points Addressed**:
1. **Stale suggestions on fast typing**: without supersession, a slow `getSuggestions` (the `@file` `fd`
   search is async) can resolve AFTER newer keystrokes and render the wrong prefix's items. The
   two-layer supersession (cancel + generation-id guard) guarantees only the latest keystroke's result
   renders.
2. **One RPC per keystroke flooding the socket**: the debounce collapses rapid TextChangedI+CursorMovedI
   bursts into one fetch per idle pause (pi's own `getSuggestions` is cheap, but the socket + `fd` run
   are not free).
3. **`vim.defer_fn` handle leak**: the obvious debounce (`timer:stop()` on reschedule) silently leaks a
   `uv_timer_t` per keystroke (LIVE-VERIFIED). S30 uses `stop()`+`close()`.

## Why

- **PRD §7.4 (Triggers)** is the requirement source: "the simplest correct approach is to ask the
  provider on every change and let *it* decide. Debounce and supersede: `InsertEnter`/`TextChangedI`/
  `CursorMovedI` → schedule a debounced `getSuggestions`… The client should simply supersede stale
  requests: when a new keystroke arrives, increment `id`, ignore any response whose `id` is not the
  latest." S30 implements this verbatim against the project's own COMPLETE bridge + coords.
- **PRD §5.5 (Timing & cancellation)** pins the numbers: "The client applies a debounce (default 25 ms)
  and an overall RPC timeout (e.g. 2000 ms)." S30 reads `config.debounce_ms` (default 25, DONE in init.lua
  S19) and `config.rpc_timeout_ms` (default 2000) is owned by the bridge (S26) — S30 inherits it.
- **The two-layer supersession is battle-tested**, not invented: nvim-cmp (`async.dedup` latest-id-wins +
  `self.context ~= ctx` capture) AND blink.cmp (monotonic `context.id` + explicit `request:cancel()` +
  queue destroy) BOTH do "cancel previous AND id-guard in callback" — neither relies on cancel alone
  (cancel can race; the id guard is the correctness boundary). See
  `research/nvim-completion-debounce-supersession.md`.
- **LIVE-VERIFIED, not assumed.** The `vim.defer_fn` stop-vs-close leak, the auto-close-after-fire, and
  the api-safe-callback facts were all printed by `nvim --headless` on 0.12.x
  (`research/vim-defer-fn-semantics.md`) — they contradict `external_deps.md §1.7`'s `stop()`-only
  snippet, so S30 DOCUMENTS the refinement (the codebase's "document every refinement over PRD/docs"
  pattern).
- **Leaf-ish + additive.** S30's only upstream dependencies are COMPLETE (S26 bridge.request/cancel/
  is_connected; S29 coords.nvim_to_pi_coords; S19 config). It is the upstream dependency of S31 (the
  `on_results` seam) / S32 (`M.current()` for the items to accept) / S33. No existing file changes.

## What

A singleton Lua module `plugin/lua/pi-editor/completion.lua`. Public surface: `refresh(buf)`, `on_results`
(callback slot), `reset()`, `current()`. Internal pipeline:

```lua
-- refresh(buf):  validate → cancel+reschedule debounce → (defer fires) do_refresh(buf)
-- do_refresh(buf): guard(buf valid + bridge connected + still current buf) → read lines+cursor →
--                  coords.nvim_to_pi_coords → supersede(cancel inflight + bump gen) → bridge.request(
--                  "getSuggestions", vim.tbl_extend("keep", pi, {force=false}), cb) → store inflight_id
-- cb(err, result): if gen ~= state.gen then return end (STALE)  -- the correctness boundary
--                  inflight_id = nil
--                  if err then return end                        -- cancelled/timeout/error → touch nothing
--                  normalize result (null → empty) → store last_result → M.on_results(buf, items, prefix)
```

### Success Criteria

- [ ] `completion.refresh`, `completion.reset`, `completion.current` are `function`s; `completion.on_results`
      is a settable field (nil by default).
- [ ] Debounce: `refresh` called 3× within the window issues ≤1 `getSuggestions` (prior timers cancelled).
- [ ] `getSuggestions` params == `{lines, cursorLine=row-1, cursorCol=<S29 utf16>, force=false}` (verified
      via the smoke's fake server decoding the request).
- [ ] Two-layer supersession: `bridge.cancel(prev_id)` called on supersede AND a stale response (captured
      gen ≠ live gen) is dropped at the callback; only the latest gen's result is stored + pushed.
- [ ] `on_results(buf, items, prefix)` fires on the latest success; NOT on stale/error/cancelled.
- [ ] `null` result → `{items={}, prefix=""}` stored + `on_results(buf, {}, "")` fires (success, empty).
- [ ] Error/cancelled/timeout → `last_result` unchanged, `on_results` NOT called.
- [ ] No `vim.defer_fn` leak: reschedule does `stop()`+`close()`; fired timers auto-close (never re-closed).
- [ ] Bridge read fresh at call time (`require("pi-editor").bridge` inside do_refresh, not cached at load).
- [ ] `reset()` idempotent + never-throws; cancels debounce timer + in-flight request; clears state.
- [ ] Never-throws on bad args (non-number `buf`, nil) + when bridge is nil/disconnected (silent degrade).
- [ ] Non-regression: all prior specs green; the 6 keymaps still fall through (S30 implements `refresh` only).

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **YES** — every upstream dependency is COMPLETE and in-tree with exhaustive headers + PRPs
+ research: the bridge API (`bridge.request`/`cancel`/`is_connected` + the exact `on_result(err,result)`
contract + the `pending`-MAP two-layer design note that explicitly says "supersession is the CALLER's
job"), the coords API (`nvim_to_pi_coords` returns a drop-in `{lines, cursorLine, cursorCol}`), the
config (`debounce_ms`/`rpc_timeout_ms` defaults), the ftplugin's no-op-safe `dispatch` forward contract,
and the LIVE-VERIFIED `vim.defer_fn` + nvim-cmp/blink supersession research. The implementer reads these,
writes 3 new files, and runs the verified test commands. No guessing; no external research required
(all references in-tree + 2 Neovim doc URLs + the research files).

### Documentation & References

```yaml
# MUST READ - Include these in your context window
- url: https://neovim.io/doc/user/lua/#vim.defer_fn()
  why: "vim.defer_fn(fn, timeout) — returns a uv_timer_t; the callback runs via vim.schedule (so it is
        api-safe / main-loop). S30 relies on BOTH the return-handle (to cancel) and the api-safety (to
        read the buffer + call bridge.request inline, NO vim.schedule)."
  critical: "LIVE-VERIFIED in research/vim-defer-fn-semantics.md: (1) :stop() suppresses the callback
             BUT LEAKS the handle (is_closing stays false) — you MUST :close() after :stop(); (2) after
             the defer FIRES it AUTO-CLOSES (never re-close a fired timer or it throws 'already closing');
             (3) two uncanceled defers BOTH fire (manual cancel required); (4) the callback is api-safe
             (main loop). This SUPERSEDES external_deps.md §1.7's stop()-only snippet (which leaks)."

- file: plugin/lua/pi-editor/bridge.lua
  why: "THE RPC layer S30 calls. Read its [Mode A] header (esp. the S26 EXTENSION block) + M.request /
        M.cancel / M.is_connected docstrings. S30 calls bridge.request('getSuggestions', params, cb)
        (returns a string id), bridge.cancel(prev_id) (fires cb('cancelled')), bridge.is_connected()."
  pattern: "request() stores the cb schedule_wrap'd + arms a per-request luv timer; cancel() resolves
            the cb with 'cancelled' (delete-entry). The header's two-layer note is EXPLICIT: 'supersession
            is the CALLER's job — completion.lua tracks its latest id and ignores stale cbs OR calls
            cancel(old_id)'. S30 does BOTH (cancel + a generation-id guard)."
  gotcha: "The bridge returns id as a STRING (tostring(next_id)); completion's OWN generation counter is a
           SEPARATE int — name them distinctly (e.g. state.gen vs state.inflight_id) so a reader does not
           confuse the completion-level supersession guard with the bridge-level request id. cb signature
           is (err, result); a getSuggestions null result resolves cb(nil, nil) (success, empty) — NOT err."

- file: plugin/lua/pi-editor/coords.lua
  why: "THE coordinate converter S30 calls. Read nvim_to_pi_coords (S29, COMPLETE) — it returns
        {lines, cursorLine, cursorCol} with `lines` PASS-THROUGH (same ref), so the result drops straight
        into the RPC params via vim.tbl_extend('keep', pi, {force=false}). cursorCol is pi's UTF-16 unit
        (NOT nvim's byte col) — S29 handled the conversion; S30 just composes."
  pattern: "CALLER pattern is ALREADY documented in coords.lua's S29 section: 'local cur =
            nvim_win_get_cursor(0); local lines = nvim_buf_get_lines(0,0,-1,false); local pi =
            coords.nvim_to_pi_coords(lines, cur[1], cur[2]); bridge.request(\"getSuggestions\",
            vim.tbl_extend(\"keep\", pi, { force = force }), cb)'. S30 implements THIS verbatim."
  gotcha: "nvim_win_get_cursor(0)[2] is 0-indexed BYTE (S29 LIVE-VERIFIED) — pass it UNCHANGED to
           nvim_to_pi_coords (NO ±1). Read lines from the STORED buf (nvim_buf_get_lines(buf,...)) not 0."

- file: plugin/lua/pi-editor/init.lua
  why: "THE config S30 reads. config.debounce_ms (default 25) + config.rpc_timeout_ms (default 2000, owned
        by the bridge). Read M.defaults + the `M.bridge` placeholder (set by handshake on success; nil in
        dormant/failed sessions). S30 reads `require('pi-editor').bridge` FRESH at call time (do_refresh),
        NOT a cached local — so the async handshake + test mocks both work."
  gotcha: "config may be nil if setup() was never called (tests / direct sourcing). Mirror bridge.lua:
          `local cfg = require('pi-editor'); local ms = ((cfg.config or cfg.defaults) or {}).debounce_ms
          or 25`. Self-sufficient (GOTCHA D from smoke.lua)."

- file: plugin/ftplugin/pi-prompt.lua
  why: "THE caller of refresh(buf). Read its `dispatch` forward contract: the 3 autocmds
        (InsertEnter/TextChangedI/CursorMovedI) all call dispatch('pi-editor.completion','refresh',buf).
        dispatch is no-op-safe (pcall require + type-check) until completion.lua lands. S30 does NOT modify
        this file — its `refresh(buf)` signature ALREADY matches the dispatch call."
  pattern: "refresh(buf) is FIRE-AND-FORGET (no return value used; the autocmd callback ignores it). The
            6 KEYMAPS (on_tab/on_enter/on_next/on_prev/on_dismiss) are ALSO dispatched here but are NOT S30's
            job — they stay absent (dispatch returns false → feedkey fall-through). Do NOT implement them."
  gotcha: "The autocmds pass `buf` (the pi-prompt buffer handle), not 0. S30 must use that buf for line
           reads + guard `buf == nvim_get_current_buf()` at fire time (a buffer-local autocmd only fires
           when buf is current, but a switch during the 25ms debounce is possible)."

- file: plugin/tests/bridge_request_spec.lua
  why: "THE async-test style S30's spec mirrors. Read with_request_server + with_handshaken_server +
        vim.wait(ms, predicate, interval). S30's spec MOCKS the bridge instead (faster, no socket) but
        reuses the vim.wait idiom for driving the debounce + async cb resolution."
  pattern: "local err,result; bridge.request(...,function(e,r) err,result=e,r end); vim.wait(300, function()
            return err~=nil or result~=nil end, 5); assert. Also: reset_module() before_each/after_each
            (S30's reset() mirrors it). NOTE from this file: do NOT name a spec-local table `pending`
            (shadows plenary's skip fn) — use `got`/`fired`/`results`."

- file: plugin/tests/coords_spec.lua
  why: "THE plenary spec style for a NEW module. Mirror its describe/it/assert.are.equals structure +
        the smoke footer (check/fails/cquit/SMOKE_PASS). S30's spec + smoke are SIBLINGS of these (new
        files, not appends — completion.lua is brand new)."
  pattern: "describe('pi-editor.completion', function() … end); before_each(reset); it('…', function() … end)."

- file: plan/001_c56962b4fa17/P2M7T18S30/research/vim-defer-fn-semantics.md
  why: "THE LIVE-VERIFIED vim.defer_fn facts (stop-vs-close leak, auto-close-after-fire, api-safe cb).
        Print-verified on nvim 0.12.x. This is the load-bearing correctness item — read it before writing
        the debounce."
  section: "all; esp. §3 (stop leaks → must close) + §5 (api-safe cb) + §6 (the cancel-previous idiom)."

- file: plan/001_c56962b4fa17/P2M7T18S30/research/nvim-completion-debounce-supersession.md
  why: "THE two-layer supersession pattern (cancel-prev AND gen-id-guard) + the 'touch nothing on error'
        idiom + the TextChangedI/CursorMovedI-dedup-via-debounce insight. Cites nvim-cmp (async.dedup) +
        blink.cmp (context.id + request:cancel) source paths + URLs."
  section: "TL;DR + §2 (BOTH layers) + §3 (error→ignore) + §4.1 (TextChangedI vs CursorMovedI) + the
            cheat-sheet table."

- docfile: PRD.md
  why: "§7.4 (Triggers — 'ask on every change, let the provider decide; debounce and supersede') and
        §5.5 (Timing — debounce 25ms, supersession via latest-id). The requirement source for S30."
  section: "§7.4 (heading:h3.20); §5.5 (heading:h3.9)"
  gotcha: "PRD §7.4 also describes the ACCEPT flow (steps 1-5) + Tab — those are S32/S33, NOT S30. S30 is
           ONLY the trigger+debounce+fetch+supersede+store+seam (the first bullet of §7.4's Triggers list)."
```

### Current Codebase tree (run `tree` in the root of the project) to get an overview of the codebase

```bash
$ cd /home/dustin/projects/pi-nvim-bridge && tree -L 3 plugin plan/001_c56962b4fa17/architecture
plugin
├── ftplugin/pi-prompt.lua                 # buffer-local setup (S22, COMPLETE) — calls refresh(buf) via dispatch
├── lua/pi-editor/
│   ├── bridge.lua                         # socket client + handshake + RPC (S24-S27, COMPLETE) — S30 calls .request/.cancel/.is_connected
│   ├── coords.lua                         # nvim_to_pi_coords / pi_to_nvim_coords (S28/S29, COMPLETE) — S30 calls nvim_to_pi_coords
│   ├── init.lua                           # setup() + VimEnter gate + config + M.bridge placeholder (S19-S21, COMPLETE)
│   └── jsonlreader.lua                    # JSONL framing (S23, COMPLETE) — smoke's fake server uses it
├── plugin/pi-editor.lua                   # VimEnter auto-activation shim (S20, COMPLETE)
└── tests/
    ├── minimal_init.lua                   # plenary harness (S19; reused UNCHANGED)
    ├── bridge_request_spec.lua            # async-test style + with_request_server (S30 spec mirrors its vim.wait idiom)
    ├── coords_spec.lua + coords_smoke.lua # NEW-module spec/smoke style (S30 siblings these)
    └── … (bridge/handshake/notify/ftplugin/init/jsonlreader/shim/activate specs + smokes — all COMPLETE)
plan/001_c56962b4fa17/architecture/
├── external_deps.md                       # §1.7 (debounce recipe — SUPERSEDED: stop()-only leaks) + §1.2/§1.6 (cursor/autocmd APIs)
└── … (research-pi-autocomplete/extension-api, system_context)
plan/001_c56962b4fa17/P2M7T18S30/research/
├── vim-defer-fn-semantics.md              # LIVE-VERIFIED stop+close leak + api-safe cb (★ read first)
└── nvim-completion-debounce-supersession.md # two-layer supersession + error-ignore idiom (★ read first)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
plugin/lua/pi-editor/completion.lua        # NEW — refresh(buf) + debounce + getSuggestions RPC + supersession + on_results seam + reset()/current()
plugin/tests/completion_spec.lua           # NEW — plenary/busted; mocks the bridge; debounce/supersession/seam/error logic
plugin/tests/completion_smoke.lua          # NEW — plenary-free; fake luv server + real bridge; refresh → assert getSuggestions issued with S29 params
# (NO existing file modified. The ftplugin's dispatch is already no-op-safe until completion.lua lands.)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (LIVE-VERIFIED): vim.defer_fn's :stop() SUPPRESSES the callback BUT LEAKS the uv_timer_t
-- (is_closing() stays false). The reschedule path MUST do :stop() THEN :close(). external_deps.md §1.7's
-- snippet (`if timer then timer:stop() end`) LEAKS — S30 supersedes it. Conversely, a defer that FIRED
-- naturally has AUTO-CLOSED — NEVER :close() a fired timer (it throws "already closing"; guard with
-- is_closing() before any stop/close). See research/vim-defer-fn-semantics.md §3/§4.

-- CRITICAL (LIVE-VERIFIED): the vim.defer_fn callback runs on the nvim MAIN LOOP (api-safe). Unlike a raw
-- uv.new_timer() fast-context callback (where vim.api.* throws E5560), do_refresh may call nvim_buf_get_lines
-- / nvim_win_get_cursor / bridge.request DIRECTLY — NO vim.schedule wrapper needed. (If you DO wrap in
-- vim.schedule it still works but adds a needless hop; the bridge's OWN cb is already schedule_wrap'd, so
-- on_result is ALSO api-safe.) See research/vim-defer-fn-semantics.md §5.

-- CRITICAL: TWO-LAYER supersession (LIVE-VERIFIED best practice from nvim-cmp + blink.cmp). Layer 1:
-- bridge.cancel(prev_inflight_id) when issuing a new request (frees the socket round-trip + drains the
-- server's AbortController promptly). Layer 2: a generation-id guard in the cb — `if gen ~= state.gen then
-- return end` (the CORRECTNESS boundary; cancel can race, the id guard cannot). Do BOTH. The bridge header
-- EXPLICITLY delegates supersession to the caller ("tracks its latest id and ignores stale cbs OR calls
-- cancel(old_id)" — S30 does both). See research/nvim-completion-debounce-supersession.md §2.

-- CRITICAL: ERROR/CANCELLED/TIMEOUT → TOUCH NOTHING. On cb("cancelled"/"timeout"/"not connected"/<err>),
-- return early WITHOUT clearing last_result and WITHOUT calling on_results. Menu clearing is a SEPARATE
-- signal (InsertLeave / S37 / cursor-left-keyword), NOT a failed fetch (the nvim-cmp + blink idiom; clears
-- cause flicker). The gen-guard already returned stale cbs; the err branch handles the CURRENT-gen failure.
-- See research/nvim-completion-debounce-supersession.md §3.

-- CRITICAL: null result (getSuggestions no matches) resolves cb(nil, nil) — SUCCESS with empty items, NOT
-- an error. Normalize: items = (result and type(result.items)=="table") and result.items or {}; prefix =
-- (result and type(result.prefix)=="string") and result.prefix or "". Store + fire on_results(buf, {}, "").
-- (The bridge's resolve_request normalizes vim.NIL→nil; you see `result == nil` here.)

-- READ THE BRIDGE FRESH AT CALL TIME: `local bridge = require("pi-editor").bridge` INSIDE do_refresh (or a
-- get_bridge() helper), NOT a module-load `local bridge = require("pi-editor").bridge`. Reasons: (1) the
-- handshake resolves ASYNC after activation — at completion.lua first-require time, pi.bridge is still nil;
-- (2) tests must be able to swap in a fake bridge after require. Caching breaks both.

-- NAME THE TWO COUNTERS DISTINCTLY: state.gen (completion's monotonic int supersession guard, captured in
-- the cb closure) vs state.inflight_id (the STRING id bridge.request returned, for bridge.cancel). A reader
-- must not confuse them. (bridge ids are tostring(next_id) numeric strings; gen is a Lua int.)

-- DEBOUNCE COLLAPSES TextChangedI+CursorMovedI: a single keystroke emits TextChangedI THEN CursorMovedI
-- (cursor advances). With a 25ms debounce, BOTH collapse into ONE fetch — no special CursorMovedI handling
-- needed. (nvim-cmp treats CursorMovedI as re-filter-only, but pi's model is "ask on every change, let the
-- provider decide" — PRD §7.4 — so re-fetching is FAITHFUL and the provider returns null when not
-- completable. Do NOT add a CursorMovedI special-case in S30; it would diverge from pi's TUI.)

-- BUFFER GUARD AT FIRE TIME: a buffer-local autocmd only fires when `buf` is current, but a window/buffer
-- switch during the 25ms debounce is possible. do_refresh must guard `if not vim.api.nvim_buf_is_valid(buf)
-- then return end` AND read lines from the STORED `buf` (nvim_buf_get_lines(buf,0,-1,false)), and bail if
-- `buf ~= vim.api.nvim_get_current_buf()` (the cursor is for the current window; if buf isn't current the
-- read is wrong — silent no-op, not a fetch on stale state).

-- NEVER THROWS (per-keystroke + autocmd contract): refresh/reset/current/do_refresh are all pcall-safe by
  the ftplugin's dispatch already wraps them — but a throw would still abort the autocmd chain). Guard every
  nvim API + bridge access; type-check `buf`; nil-check the bridge. A missing/disconnected bridge = silent
  degrade (S39's job to notify once), NOT a throw.

-- SINGLETON STATE (like bridge.lua, NOT like coords.lua): one `state` table (buf, debounce_timer, gen,
-- inflight_id, last_result) + `local M = {}`. Do NOT make it instance-based (one pi-prompt buffer per
-- session — PRD §11). reset() clears state for tests + future S37 InsertLeave wiring.

-- DO NOT implement on_tab/on_enter/on_next/on_prev/on_dismiss — those are S32/S33/S36/S37. S30 implements
-- refresh ONLY. The ftplugin's keymap dispatch returns false for the absent ones → feedkey fall-through
-- (Tab indents, CR inserts a newline) — that is CORRECT for S30's scope. Implementing them here would
-- collide with S32/S33/S36/S37.

-- DO NOT modify the ftplugin, init.lua, bridge.lua, coords.lua, or any existing file. S30 is purely
-- additive (3 NEW files). The ftplugin's dispatch forward contract already calls refresh(buf); it is
-- no-op-safe today and goes live the moment completion.lua lands — with NO ftplugin edit.
```

## Implementation Blueprint

### Data models and structure

Module-level singleton state (mirrors `bridge.lua`'s `state` shape, NOT `coords.lua`'s stateless shape):

```lua
--- Singleton completion state. One pi-prompt buffer per session (PRD §11). Cleared by reset().
---@class pi-editor.CompletionState
---@field buf           integer?            The pi-prompt buffer handle refresh() is debouncing for.
---@field debounce_timer userdata?          The vim.defer_fn handle (tracked for stop+close — NEVER stop-only; leaks).
---@field gen           integer             Monotonic supersession guard (bumped per fetch; captured in cb closure).
---@field inflight_id   string?             The bridge.request id string of the current in-flight getSuggestions (for bridge.cancel).
---@field last_result   {items:pi-editor.AutocompleteItem[], prefix:string}? Latest non-stale {items,prefix} (for S32/S33/current()).
---@type pi-editor.CompletionState
local state = { buf = nil, debounce_timer = nil, gen = 0, inflight_id = nil, last_result = nil }
```

Public surface (LuaCATS — match bridge.lua's annotation density):

```lua
--- The result→menu seam (forward contract for S31). Set by S31 to receive the latest non-stale
--- {items, prefix}: function(buf, items, prefix). nil today → no-op (silent). Mirrors bridge.lua's
--- M.on_notification slot pattern. Called on the nvim main loop (api-safe). NOT called for stale/
--- error/cancelled results. Last-wins re-registration (a Lua table set).
M.on_results = nil  -- function(buf:integer, items:pi-editor.AutocompleteItem[], prefix:string)

--- The autocmd entry point (InsertEnter/TextChangedI/CursorMovedI; wired buffer-local by ftplugin S22).
--- Fire-and-forget. Debounces: cancels any pending debounce timer (stop+close), schedules do_refresh(buf)
--- after config.debounce_ms. Never throws; silent degrade if bridge absent/disconnected.
---@param buf integer The pi-prompt buffer handle (from the autocmd; NOT 0).
function M.refresh(buf) ... end

--- Teardown: cancel the debounce timer + any in-flight request; clear last_result; reset gen.
--- Idempotent + never throws. The cleanup seam (tests + future S37 InsertLeave wiring).
function M.reset() ... end

--- Read-only: the latest non-stale {items, prefix}, or nil. For S32 accept / S33 Tab to read the current
--- items without coupling to the menu. Returns a SHALLOW copy (the caller may not mutate state.last_result).
---@return {items:pi-editor.AutocompleteItem[], prefix:string}? result
function M.current() ... end
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ (do NOT edit yet) — anchor on the COMPLETE deps + LIVE-VERIFIED facts
  - READ: plugin/lua/pi-editor/bridge.lua  (the [Mode A] header esp. the S26 EXTENSION block; M.request/cancel/is_connected docstrings — esp. the "supersession is the CALLER's job" note + the cb(err,result) contract + null→cb(nil,nil))
  - READ: plugin/lua/pi-editor/coords.lua  (nvim_to_pi_coords S29 + its documented CALLER pattern)
  - READ: plugin/lua/pi-editor/init.lua    (config.debounce_ms/rpc_timeout_ms defaults; M.bridge placeholder)
  - READ: plugin/ftplugin/pi-prompt.lua    (the dispatch forward contract that calls refresh(buf); the 3 autocmds; confirm refresh is fire-and-forget + buf is passed)
  - READ: plugin/tests/bridge_request_spec.lua + plugin/tests/coords_spec.lua + plugin/tests/coords_smoke.lua  (the async-test style + new-module spec/smoke style to mirror)
  - READ: plan/001_c56962b4fa17/P2M7T18S30/research/vim-defer-fn-semantics.md  (★ stop+close leak; api-safe cb)
  - READ: plan/001_c56962b4fa17/P2M7T18S30/research/nvim-completion-debounce-supersession.md  (★ two-layer supersession; error→ignore)
  - READ: plan/001_c56962b4fa17/architecture/external_deps.md §1.7 + §1.2 + §1.6  (the debounce recipe to SUPERSEDE + the cursor/autocmd APIs)
  - WHY: locks the contract (debounce stop+close; api-safe defer cb; two-layer supersession; error→ignore;
         null→empty; bridge-read-fresh; the exact getSuggestions params) + the test discipline before writing.

Task 2: CREATE plugin/lua/pi-editor/completion.lua — the module skeleton + [Mode A] header
  - CREATE: `local M = {}` + the singleton `state` table (buf/debounce_timer/gen/inflight_id/last_result) + `return M`.
  - WRITE the [Mode A] header: role (the per-keystroke trigger layer of P2.M7.T18); the LIVE-VERIFIED
      vim.defer_fn stop+close leak (cite research §3) + the api-safe-cb fact (§5) + auto-close-after-fire (§4);
      the two-layer supersession (cancel + gen-guard — cite the research cheat-sheet); the error→touch-nothing
      idiom; the null→empty normalization; the bridge-read-fresh rule; the gen-vs-inflight_id naming; the
      "ask on every change" pi-faithful model (PRD §7.4); the forward contracts (on_results→S31,
      current()→S32/S33, reset()→S37); the "refresh ONLY — not on_tab/etc." scope guard.
  - DEFINE the two @class blocks (pi-editor.CompletionState; reuse pi-editor.AutocompleteItem from bridge.lua's
      types — note it inline) + the LuaCATS on every public fn.
  - NAMING/PLACEMENT: `plugin/lua/pi-editor/completion.lua` (sibling of bridge.lua/coords.lua).
  - DEPENDENCIES: require("pi-editor") (for config + bridge, read at call time) + require("pi-editor.coords")
      (for nvim_to_pi_coords). No other requires.

Task 3: CREATE completion.lua — refresh(buf) + the debounce (the cancel-previous-then-schedule idiom)
  - IMPLEMENT: M.refresh(buf):
      * type-guard buf (non-number → return); state.buf = buf.
      * resolve debounce ms: `local cfg = require("pi-editor"); local ms = ((cfg.config or cfg.defaults) or {}).debounce_ms or 25`.
      * CANCEL any pending debounce timer (stop+close — the LIVE-VERIFIED leak fix):
            if state.debounce_timer and not state.debounce_timer:is_closing() then
              state.debounce_timer:stop(); state.debounce_timer:close()
            end
      * SCHEDULE: state.debounce_timer = vim.defer_fn(function() do_refresh(buf) end, ms).
  - NEVER THROWS: wrap the timer ops in pcall (a programming error degrades to a silent return; the is_closing
      guard defends the "already closing" throw on a fired timer).
  - NOTE: refresh does NOT read the buffer/cursor — that happens in do_refresh (at FIRE time, the latest buf state).

Task 4: CREATE completion.lua — do_refresh(buf) (read buffer + convert + supersede + issue RPC)
  - IMPLEMENT: local function do_refresh(buf):
      * GUARD: if type(buf)~="number" or not vim.api.nvim_buf_is_valid(buf) then return end.
      * GUARD current: if buf ~= vim.api.nvim_get_current_buf() then return end (a switch during debounce).
      * GET bridge FRESH: local pi_mod = require("pi-editor"); local bridge = pi_mod.bridge;
        if not bridge or type(bridge.is_connected)~="function" or not bridge.is_connected() then return end.
      * READ: local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false); local cur = vim.api.nvim_win_get_cursor(0).
      * CONVERT (S29): local pi = require("pi-editor.coords").nvim_to_pi_coords(lines, cur[1], cur[2]).  -- {lines,cursorLine,cursorCol}
      * SUPERSEDE layer 1 (cancel prev): if state.inflight_id then pcall(bridge.cancel, state.inflight_id);
        state.inflight_id = nil end.
      * BUMP gen (layer 2 capture): state.gen = state.gen + 1; local gen = state.gen.
      * ISSUE: local params = vim.tbl_extend("keep", pi, { force = false });  -- {lines,cursorLine,cursorCol,force=false}
        local id = bridge.request("getSuggestions", params, function(err, result)
          if gen ~= state.gen then return end                  -- STALE (superseded) — drop, touch nothing
          state.inflight_id = nil
          if err then return end                               -- cancelled/timeout/error → touch nothing
          local items  = (result and type(result.items) =="table")  and result.items  or {}
          local prefix = (result and type(result.prefix)=="string") and result.prefix or ""
          state.last_result = { items = items, prefix = prefix }
          if type(M.on_results) == "function" then M.on_results(buf, items, prefix) end  -- S31 seam (api-safe)
        end)
        if id then state.inflight_id = id end                  -- bridge may return nil if not connected (race)
  - NEVER THROWS: pcall the bridge.request + nvim API calls (a bridge bug must not abort the autocmd chain).
  - API-SAFE: do_refresh runs inside the vim.defer_fn cb (main loop — LIVE-VERIFIED §5); NO vim.schedule needed.

Task 5: CREATE completion.lua — reset() + current()
  - IMPLEMENT M.reset():
      * cancel debounce timer: if state.debounce_timer and not state.debounce_timer:is_closing() then
        pcall(function() state.debounce_timer:stop() end); pcall(function() state.debounce_timer:close() end) end.
      * cancel inflight: local pi=require("pi-editor"); local b=pi.bridge; if state.inflight_id and b and
        type(b.cancel)=="function" then pcall(b.cancel, state.inflight_id) end.
      * clear: state.debounce_timer=nil; state.inflight_id=nil; state.last_result=nil; state.gen=0; state.buf=nil.
      * NEVER THROWS (pcall-wrapped; idempotent — safe to call when never activated, mirrors bridge.on_exit).
  - IMPLEMENT M.current(): return a SHALLOW copy of state.last_result (or nil):
      local r = state.last_result; if not r then return nil end; return { items = r.items, prefix = r.prefix }.
  - NOTE: reset() is the cleanup seam for S37 (InsertLeave/BufLeave → reset + close menu). It is NOT wired
      by the ftplugin today (S30 does not modify the ftplugin) — it exists for tests + the S37 forward contract.

Task 6: CREATE plugin/tests/completion_spec.lua — plenary/busted (MOCK the bridge)
  - STRUCTURE: local completion = require("pi-editor.completion"); local pi = require("pi-editor"); a `reset()`
      helper (pi.bridge=nil; completion.reset()) in before_each/after_each. A `fake_bridge(opts)` helper that
      returns a table with .is_connected() (true), .cancel(id) (records), .request(method,params,cb) (stores
      the cb + returns a fake string id; a `resolve(idx, err, result)` helper to fire stored cbs). Set
      pi.bridge = fake before each case.
  - CASES (mirror bridge_request_spec's vim.wait style):
      * surface: refresh/reset/current are functions; on_results is settable.
      * debounce: set debounce_ms low (e.g. via pi.config or a local override); call refresh(buf) 3× rapidly;
        vim.wait; assert fake.request called EXACTLY ONCE (the prior debounce timers cancelled).
      * params: after one refresh+wait, assert the fake captured params == {lines=<buf lines>, cursorLine,
        cursorCol, force=false} for a buffer with e.g. {"/mod"} + cursor at col 4 (assert cursorLine==0,
        cursorCol==4 via S29). Use a real buffer (nvim_create_buf + set_lines + set cursor in a window) so
        coords converts real data — OR pass a synthetic and assert the composition (simpler: real buf).
      * supersession (two layers): issue a request (slow — don't resolve); issue a 2nd refresh; assert
        fake.cancel was called with the 1st id (layer 1); resolve the 1st cb with a result; assert
        on_results was NOT called for it (gen-guard — layer 2) + last_result unchanged; resolve the 2nd;
        assert on_results called with the 2nd's items.
      * on_results seam: register M.on_results = function(b,i,p) got={b,i,p} end; refresh+resolve success;
        assert got == {buf, items, prefix}.
      * null result: resolve with result=nil (the bridge's null→nil); assert last_result.items=={} + prefix==""
        + on_results(buf, {}, "").
      * error→touch-nothing: resolve with err="timeout"; assert on_results NOT called + last_result unchanged
        (pre-seed last_result first to prove it's untouched).
      * cancelled→touch-nothing: same with err="cancelled".
      * bridge-read-fresh: require completion FIRST, THEN set pi.bridge=fake; refresh+resolve works (proves no
        module-load caching).
      * bridge absent/disconnected: pi.bridge=nil → refresh+wait → no throw, no request; fake.is_connected→false → same.
      * reset(): cancel debounce timer (no leak — call refresh then reset mid-debounce; assert no throw +
        state cleared via current()==nil); cancel inflight (refresh+reset; assert fake.cancel called).
      * never-throws: refresh(nil), refresh("x"), refresh(buf) with a wiped buf — no throw.
  - STYLE: describe("pi-editor.completion", …); it(…); assert.are.equals/assert.is_true/assert.is_nil/
    assert.has_no.errors. vim.wait(ms, predicate, 5) for async. Do NOT name a spec-local table `pending`.
  - PLACEMENT: plugin/tests/completion_spec.lua (sibling of bridge_request_spec.lua).

Task 7: CREATE plugin/tests/completion_smoke.lua — plenary-free (LIGHT real-bridge integration)
  - STRUCTURE: reuse the coords_smoke.lua `check`/`fails`/`cquit`/`SMOKE_PASS` footer. Spin a fake luv
      unix-socket server (the bridge_request_spec `with_request_server` body — bind a unique path, jsonlreader
      on the server side, echo hello + capture getSuggestions). handshake via bridge.handshake; set pi.bridge.
      nvim_create_buf + set_lines({"/mod"}) + (in a window) set cursor; completion.refresh(buf); vim.wait for
      the debounce + the request to arrive at the server; assert the server `seen` a getSuggestions whose
      params.method=="getSuggestions" + params.cursorLine==0 + params.cursorCol==4 + params.force==false +
      params.lines[1]=="/mod". Then completion.reset(); bridge.close(); server stop.
  - CASES (checks):
      * getSuggestions request observed with correct S29 params (the headline integration).
      * debounce: 3 rapid refresh → ≤1 request observed.
      * never-throws on reset() (idempotent).
  - KEEP the trailing `if fails>0 then cquit 1 end; io.stdout:write("SMOKE_PASS\n")`.
  - RUN: `cd plugin && nvim --headless --clean -u NORC +"luafile tests/completion_smoke.lua" +qa` → SMOKE_PASS / exit 0.
```

### Implementation Patterns & Key Details

```lua
-- === refresh(buf) — the debounce (cancel-previous-then-schedule; the LIVE-VERIFIED leak fix) ===
-- stop()+close() on reschedule (external_deps.md §1.7's stop()-only LEAKS). pcall the timer ops (a fired
-- timer's :close() throws "already closing"; the is_closing() guard + pcall defend it). api-safe defer cb.
---@param buf integer The pi-prompt buffer handle (from the autocmd; NOT 0).
function M.refresh(buf)
  if type(buf) ~= "number" then return end
  state.buf = buf
  local cfg = require("pi-editor")
  local ms = ((cfg.config or cfg.defaults) or {}).debounce_ms or 25
  -- CANCEL any pending debounce timer (stop+close — NEVER stop-only; LIVE-VERIFIED leak).
  pcall(function()
    if state.debounce_timer and not state.debounce_timer:is_closing() then
      state.debounce_timer:stop()
      state.debounce_timer:close()
    end
  end)
  -- SCHEDULE (the cb is api-safe — main loop; NO vim.schedule needed).
  state.debounce_timer = vim.defer_fn(function() do_refresh(buf) end, ms)
end

-- === do_refresh(buf) — read buffer + convert + supersede (BOTH layers) + issue RPC ===
-- Runs inside the vim.defer_fn cb (api-safe). gen is the CORRECTNESS boundary; cancel is the optimization.
local function do_refresh(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return end
  if buf ~= vim.api.nvim_get_current_buf() then return end            -- a switch during the debounce
  local pi_mod = require("pi-editor")
  local bridge = pi_mod.bridge                                         -- READ FRESH (handshake async + test mocks)
  if not bridge or type(bridge.is_connected) ~= "function" or not bridge.is_connected() then return end
  local ok, lines, cur = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok or not lines then return end
  ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok or not cur then return end
  local pi = require("pi-editor.coords").nvim_to_pi_coords(lines, cur[1], cur[2])  -- S29: {lines,cursorLine,cursorCol}
  -- SUPERSEDE layer 1 (cancel prev in-flight — frees the round-trip + drains the server's AbortController).
  if state.inflight_id and type(bridge.cancel) == "function" then
    pcall(bridge.cancel, state.inflight_id)
  end
  state.inflight_id = nil
  -- SUPERSEDE layer 2 (gen-guard — the correctness boundary; captured in the cb closure).
  state.gen = state.gen + 1
  local gen = state.gen
  local params = vim.tbl_extend("keep", pi, { force = false })          -- {lines,cursorLine,cursorCol,force=false}
  local id
  ok, id = pcall(bridge.request, "getSuggestions", params, function(err, result)
    if gen ~= state.gen then return end                                -- STALE (superseded) — drop, touch nothing
    state.inflight_id = nil
    if err then return end                                             -- cancelled/timeout/error → touch nothing
    local items  = (result and type(result.items)  == "table")  and result.items  or {}
    local prefix = (result and type(result.prefix) == "string") and result.prefix or ""
    state.last_result = { items = items, prefix = prefix }
    if type(M.on_results) == "function" then M.on_results(buf, items, prefix) end  -- S31 seam (api-safe)
  end)
  if ok and type(id) == "string" then state.inflight_id = id end       -- bridge may return nil (not-connected race)
end

-- === reset() — idempotent teardown (the cleanup seam for tests + S37) ===
function M.reset()
  pcall(function()
    if state.debounce_timer and not state.debounce_timer:is_closing() then
      state.debounce_timer:stop()
      state.debounce_timer:close()
    end
  end)
  local b = require("pi-editor").bridge
  if state.inflight_id and b and type(b.cancel) == "function" then
    pcall(b.cancel, state.inflight_id)
  end
  state.debounce_timer = nil
  state.inflight_id    = nil
  state.last_result    = nil
  state.gen            = 0
  state.buf            = nil
end

-- === current() — read-only accessor for S32/S33 (a SHALLOW copy; caller may not mutate state) ===
function M.current()
  local r = state.last_result
  if not r then return nil end
  return { items = r.items, prefix = r.prefix }
end
```

### Integration Points

```yaml
MODULE (completion.lua):
  - create: "plugin/lua/pi-editor/completion.lua — a singleton module: refresh(buf) + do_refresh(buf)
    (internal) + on_results (callback slot) + reset() + current(). Reads config + bridge FRESH from
    require('pi-editor') at call time; calls require('pi-editor.coords').nvim_to_pi_coords + bridge.request/
    cancel/is_connected. NO new file elsewhere; NO modification to any existing file."

CALLERS (EXISTING — already wired, no-op-safe until this lands):
  - ftplugin/pi-prompt.lua (S22, COMPLETE): "the 3 buffer-local autocmds (InsertEnter/TextChangedI/
    CursorMovedI) call dispatch('pi-editor.completion','refresh',buf). dispatch is no-op-safe (pcall require
    + type-check) — it returns false (silent) until completion.lua ships, then goes live with NO ftplugin
    edit. The 6 KEYMAPS (on_tab/…) also dispatch here but stay absent (S32/S33/S36/S37) → feedkey
    fall-through. S30 does NOT touch the ftplugin."

CONSUMERS (FUTURE — do NOT implement in S30; just design the seams to serve them):
  - S31 (menu population): "registers M.on_results = function(buf, items, prefix) … end to render the menu
    (or calls completion.current() to poll). The seam fires on the latest non-stale success."
  - S32 (accept via applyCompletion): "reads completion.current().items[selected] to know which item to
    applyCompletion; uses coords.pi_to_nvim_coords to place the cursor."
  - S33 (Tab-force file completion): "calls bridge.request('shouldTriggerFileCompletion',…) then
    bridge.request('getSuggestions', vim.tbl_extend('keep', pi, {force=true}), cb) — reuses S30's do_refresh
    machinery (a refresh(buf, {force=true}) variant is a natural S33 extension)."
  - S37 (auto-close on InsertLeave/CursorMoved-out): "calls completion.reset() to cancel the debounce +
    inflight + clear state, then closes the menu."

NO INTEGRATION with: init.lua's setup(), bridge.lua's internals, coords.lua's functions (call-only), the
plugin/pi-editor.lua shim, or menu.lua (not yet created — S34+). completion.lua is a self-contained module
that COMPOSES the COMPLETE bridge + coords + config.
```

## Validation Loop

> Reuses `plugin/tests/minimal_init.lua` (S19) unchanged. nvim 0.12.4 verified. Plenary at
> `/home/dustin/.local/share/nvim/lazy/plenary.nvim`. Run all commands from the `plugin/` dir.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Load-check the new module (catches syntax/LuaCATS errors instantly) — headless, no plenary.
cd /home/dustin/projects/pi-nvim-bridge/plugin
nvim --headless --clean -u NORC \
  -c 'set rtp+=.' \
  -c 'lua local c=require("pi-editor.completion"); assert(type(c.refresh)=="function" and type(c.reset)=="function" and type(c.current)=="function" and c.on_results==nil)' \
  -c 'qa'
echo "exit=$?   # 0 = module loads + the 3 fns exist + on_results starts nil"
# Expected: exit 0. If non-zero, READ the nvim stderr (syntax/typo/LuaCATS) and fix before proceeding.

# Optional lint (the repo lints Lua ad-hoc — match the sibling PRPs: rely on the load + spec):
luacheck lua/pi-editor/completion.lua --std luajit 2>/dev/null || true
```

### Level 2: Unit Tests (Component Validation)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin

# 2a. Plenary-FREE smoke (the LIGHT real-bridge integration) — must pass.
nvim --headless --clean -u NORC +"luafile tests/completion_smoke.lua" +qa
echo "exit=$?   # 0 + prints SMOKE_PASS"
# Expected: SMOKE_PASS / exit 0 (a getSuggestions request with S29-correct params was observed; debounce collapsed; reset never-threw).

# 2b. Plenary/busted spec (the mock-bridge logic gate) — must pass.
nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
echo "exit=$?"
# Expected: "Success: <N>" / "Failed: 0" / "Errors: 0" / exit 0. Covers: debounce (1 req from 3 refreshes),
# params composition, two-layer supersession (cancel + gen-guard), on_results seam, null→empty,
# error/cancelled→touch-nothing, bridge-read-fresh, absent/disconnected degrade, reset idempotent, never-throws.

# If failing: READ the failing assertion name + actual vs expected, debug root cause, fix the implementation
# (do NOT weaken an assertion — the debounce stop+close + the two-layer supersession are LIVE-VERIFIED correct).
```

### Level 3: Integration Testing (System Validation)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin

# 3a. Non-regression — run EVERY prior spec to confirm S30's additive files didn't break siblings.
for spec in tests/init_spec.lua tests/shim_spec.lua tests/activate_spec.lua tests/ftplugin_spec.lua \
            tests/jsonlreader_spec.lua tests/bridge_spec.lua tests/bridge_handshake_spec.lua \
            tests/bridge_request_spec.lua tests/bridge_notify_spec.lua tests/coords_spec.lua; do
  echo "--- $spec ---"
  nvim --headless --clean -u tests/minimal_init.lua -c "lua require('plenary.busted').run('$spec')"
done
echo "exit=$?"
# Expected: each spec "Failed: 0 / Errors: 0". (No existing file changed → all stay green.)

# 3b. End-to-end debounce + supersession sanity (headless, no plenary) — proves the LIVE-VERIFIED timer facts
# hold inside completion.lua: rapid refreshes issue 1 request; a stale response is dropped.
nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /dev/stdin" +qa <<'LUA'
local pi = require("pi-editor"); pi.setup({debounce_ms = 10})
local calls = {}
pi.bridge = { is_connected = function() return true end,
  cancel = function(id) calls.cancel = (calls.cancel or 0)+1 end,
  request = function(m,p,cb) calls.n = (calls.n or 0)+1; calls.last_cb = cb; calls.last_params = p; return tostring(calls.n) end }
local comp = require("pi-editor.completion")
local buf = vim.api.nvim_create_buf(true,false); vim.api.nvim_buf_set_lines(buf,0,-1,false,{"/mod"})
-- 3 rapid refreshes (debounce collapses to 1)
comp.refresh(buf); comp.refresh(buf); comp.refresh(buf)
vim.wait(120, function() return (calls.n or 0) >= 1 end, 5)
assert((calls.n or 0) == 1, "debounce must issue exactly 1 request, got "..tostring(calls.n))
assert(calls.last_params.method == nil and calls.last_params.cursorLine == 0, "params sanity")
-- supersede: fire a 2nd refresh (new gen), then resolve the 1st cb (stale) — must NOT call on_results
comp.on_results = function() calls.seam = (calls.seam or 0)+1 end
local stale_cb = calls.last_cb
comp.refresh(buf); vim.wait(80, function() return (calls.n or 0) >= 2 end, 5)
stale_cb(nil, {items={{value="x",label="x"}}, prefix="/mod"})  -- stale (gen advanced)
assert((calls.seam or 0) == 0, "stale response must NOT fire on_results")
comp.reset()
io.stdout:write("E2E_PASS\n")
LUA
echo "exit=$?"
# Expected: E2E_PASS / exit 0 (debounce=1; stale dropped; reset never-threw).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# No external/creative tooling for this layer (completion.lua is pure Lua over the in-tree bridge + coords;
# no sockets of its own — the smoke's fake server is the integration surface). Domain-specific validation IS
# the debounce + two-layer supersession behavior (Levels 2/3 cover it):
#   * debounce collapses TextChangedI+CursorMovedI bursts into 1 fetch (the smoke + E2E assert exactly 1).
#   * two-layer supersession: cancel(prev) on supersede AND a stale cb (gen-guard) is dropped (the E2E asserts
#     a stale response does NOT fire on_results).
#   * no vim.defer_fn leak: the reschedule path does stop()+close() (LIVE-VERIFIED; the load-check + the
#     spec's "rapid refresh" case exercise the reschedule path without accumulating handles).

# Optional: confirm the Neovim version (vim.defer_fn + the api-safe-cb fact verified on 0.12.x).
nvim --version | head -1   # 0.12.4 verified.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 load-check exits 0 (module loads; refresh/reset/current are functions; on_results starts nil).
- [ ] Level 2a smoke prints `SMOKE_PASS` / exit 0 (getSuggestions with S29 params observed; debounce; reset).
- [ ] Level 2b plenary spec: `Success: <N>` / `Failed: 0` / `Errors: 0` / exit 0 (all cases pass).
- [ ] Level 3a non-regression: every prior spec still `Failed: 0 / Errors: 0` (no existing file changed).
- [ ] Level 3b E2E prints `E2E_PASS` (debounce=1 from 3 refreshes; stale response dropped; reset never-threw).
- [ ] No syntax/lint errors blocking module load.

### Feature Validation

- [ ] All Success Criteria from "What" section met (refresh/reset/current/on_results exist; debounce=1;
      params via S29; two-layer supersession; on_results seam on success; null→empty; error→touch-nothing;
      no defer leak; bridge-read-fresh; reset idempotent; never-throws; degrade when absent/disconnected).
- [ ] Manual/live sanity successful (Level 3b — rapid refreshes → 1 request; stale response dropped).
- [ ] The `external_deps.md §1.7` stop()-only refinement is DOCUMENTED in completion.lua's header
      (a reader of §1.7 is not surprised that S30 does stop()+close() — the leak is LIVE-VERIFIED).
- [ ] The two-layer supersession (cancel + gen-guard) + the error→touch-nothing idiom are documented in
      the header with the research citations.
- [ ] Forward contracts (on_results→S31, current()→S32/S33, reset()→S37) documented in the header + LuaCATS
      so the next implementer sees the seams' purpose.

### Code Quality Validation

- [ ] Follows existing module conventions (bridge.lua's singleton `state` shape + [Mode A] header style +
      LuaCATS density + "Node builtins analog"-style footer + PRD §X + LIVE-VERIFIED citations; NOT coords.lua's
      stateless shape — completion HAS state).
- [ ] Additive only — 3 NEW files; NO modification to init.lua/bridge.lua/coords.lua/jsonlreader.lua/the
      ftplugin/the shim (the ftplugin's dispatch is already no-op-safe + already calls refresh(buf)).
- [ ] Anti-patterns avoided (see below): no stop()-only leak; no module-load bridge caching; no single-layer
      supersession; no error→clear-menu; no on_tab/etc. implemented (S32/S33/S36/S37 scope); no CursorMovedI
      special-case (debounce handles it; pi-faithful); no vim.schedule in the defer cb (api-safe).
- [ ] No new dependencies (pure Lua + the in-tree bridge + coords + Neovim builtins only).

### Documentation & Deployment

- [ ] completion.lua [Mode A] header documents: role; the LIVE-VERIFIED vim.defer_fn stop+close leak + the
      api-safe cb + auto-close-after-fire; the two-layer supersession; the error→touch-nothing idiom; the
      null→empty normalization; the bridge-read-fresh rule; the gen-vs-inflight_id naming; the pi-faithful
      "ask on every change" model; the forward contracts; the "refresh ONLY" scope guard.
- [ ] LuaCATS `---@param`/`---@return` + the `---@class pi-editor.CompletionState` block present.
- [ ] The caller pattern (S31 registers on_results; S32 reads current(); S37 calls reset()) documented in a
      code comment so the seams' purpose is self-evident to the next implementer.

---

## Anti-Patterns to Avoid

- ❌ **Don't use `timer:stop()` only on reschedule.** LIVE-VERIFIED: `:stop()` suppresses the callback BUT
  LEAKS the `uv_timer_t` (`is_closing()` stays false). MUST `stop()`+`close()`. (`external_deps.md §1.7`'s
  snippet leaks — S30 supersedes it; DOCUMENT the refinement.) Conversely, never `:close()` a timer that
  already FIRED (it auto-closed; re-closing throws "already closing" — guard with `is_closing()`).
- ❌ **Don't cache the bridge at module load** (`local bridge = require("pi-editor").bridge` at the top).
  The handshake resolves ASYNC after activation (pi.bridge is nil at first-require); tests must swap a fake.
  Read it FRESH inside do_refresh (`require("pi-editor").bridge`).
- ❌ **Don't rely on cancel ALONE for supersession.** cancel can race (the cb is schedule_wrap'd; a response
  can land between cancel and the new request). The generation-id guard in the cb (`if gen ~= state.gen then
  return end`) is the CORRECTNESS boundary. Do BOTH (cancel = optimization; gen-guard = correctness).
  (LIVE-VERIFIED best practice: nvim-cmp `async.dedup` + blink `context.id`.)
- ❌ **Don't clear the menu / blank `last_result` on a cancelled/error/timeout response.** Touch NOTHING —
  menu clearing is a SEPARATE signal (InsertLeave / S37 / cursor-left-keyword). Clearing on a failed fetch
  causes flicker (the blink.cmp `async_initial_items` "flash of no items" anti-pattern).
- ❌ **Don't treat a `null` getSuggestions result as an error.** cb(nil, nil) = SUCCESS with empty items.
  Normalize to `{items={}, prefix=""}`, store, and fire `on_results(buf, {}, "")`.
- ❌ **Don't wrap the vim.defer_fn callback in `vim.schedule`.** It already runs on the main loop (api-safe —
  LIVE-VERIFIED §5). An extra `vim.schedule` is a needless hop (it still works but adds latency). Only the
  bridge's OWN cb is pre-schedule_wrap'd (S26) — on_result is already api-safe too.
- ❌ **Don't implement `on_tab`/`on_enter`/`on_next`/`on_prev`/`on_dismiss`.** Those are S32/S33/S36/S37.
  S30 implements `refresh` ONLY. The ftplugin's keymap dispatch returns false for absent fns → feedkey
  fall-through (Tab indents, CR inserts a newline) — that is CORRECT for S30's scope. Implementing them here
  collides with the later tasks.
- ❌ **Don't add a CursorMovedI special-case** (re-filter-only, like nvim-cmp). pi's model is "ask on every
  change, let the provider decide" (PRD §7.4) — re-fetching on CursorMovedI is FAITHFUL to pi's TUI (the
  provider returns null when not completable), and the ~25ms debounce naturally collapses the
  TextChangedI+CursorMovedI pair a keystroke emits. A special-case would diverge from pi.
- ❌ **Don't modify any existing file.** S30 is purely additive (3 NEW files). The ftplugin's dispatch is
  ALREADY no-op-safe + ALREADY calls refresh(buf); it goes live with NO ftplugin edit. Touching the ftplugin
  / init.lua / bridge.lua / coords.lua would risk non-regression and is out of scope.
- ❌ **Don't confuse `state.gen` (completion's int supersession guard) with `state.inflight_id` (the bridge's
  STRING request id).** Name them distinctly. gen is captured in the cb closure; inflight_id is for
  bridge.cancel. (bridge ids are `tostring(next_id)` numeric strings; gen is a Lua int.)

---

## Confidence Score

**9/10** for one-pass implementation success. Rationale: every upstream dependency is COMPLETE and in-tree
with exhaustive headers + PRPs (the bridge's `request`/`cancel`/`is_connected` + its explicit "supersession
is the caller's job" note; S29 `nvim_to_pi_coords` with its documented caller pattern; the config defaults);
the two load-bearing correctness items are LIVE-VERIFIED on nvim 0.12.x (the `vim.defer_fn` stop+close leak
+ the api-safe callback — `research/vim-defer-fn-semantics.md`), contradicting `external_deps.md §1.7` and
DOCUMENTED with the codebase's "refinement-over-docs" pattern; the two-layer supersession + error→ignore
idioms are battle-tested (nvim-cmp + blink.cmp source cited); the test harness + exact commands are verified
green; and the scope is narrow + additive (3 NEW files, no modification, the ftplugin already wires refresh).
The one residual risk is the gen-vs-inflight_id two-counter subtlety if the implementer skips the "Known
Gotchas" — mitigated by the explicit naming guidance + the E2E test asserting stale-drop. (Not 10/10 only
because mocking the bridge in the spec requires care that the fake's cb-firing order exercises the supersession
race faithfully — the spec task spells this out.)