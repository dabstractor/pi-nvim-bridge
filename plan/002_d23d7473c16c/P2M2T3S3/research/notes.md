# Research Notes — P2.M2.T3.S3: `shell.complete_current(buf, cb)`

> The buffer→daemon bridge function. Reads the pi-prompt buffer + cursor, strips the
> `!`/`!!` bangs, computes BYTE `line`/`cursor`/`after`, and calls `M.request`.
> Sits BETWEEN completion.lua's `do_shell_fetch` (the gen-guarded consumer) and
> shell.lua's `M.request` (the daemon-supersession layer). Owned by THIS task.

## 1. The exact contract S3 must fulfill (from S2's `do_shell_fetch` + shell.lua forward contracts)

`completion.lua:428` calls it EXACTLY like this (S2, COMPLETE):

```lua
pcall(shell.complete_current, buf, function(err, items, prefix)
  -- ⚠ runs in LIBUV FAST CONTEXT (M.request's pending_cb fires from _feed/timer)
  if gen ~= state.gen then return end        -- completion.lua's gen-guard (do_shell_fetch owns this)
  if err then ... return end                  -- silent degrade
  state.last_result = { items = its, prefix = pfx }
  vim.schedule(function() pcall(M.on_results, buf, its, pfx) end)  -- consumer schedules the menu hop
end)
```

- **Signature:** `M.complete_current(buf, cb)` where `cb(err, items, prefix)`.
- `items` = `AutocompleteItem[]` (ALREADY normalized by `_feed`/`normalize_item`); `prefix` = string (may be `""`).
- **Fast context:** the cb M.request resolves runs in libuv fast context (`_feed`'s `read_start` cb or the timer cb — shell.lua:642/650 forward contract). complete_current's OWN cb wrapper (passed to M.request) also runs fast. So: NO `vim.api.*` in complete_current's cb. Pure string math + forward to user cb only. The consumer (`do_shell_fetch`) already `vim.schedule`s the menu hop — do NOT duplicate.
- complete_current itself runs on the **nvim main loop** when CALLED (do_refresh/force_fetch/on_tab are all main-loop callers), so the buffer/cursor READ (`nvim_buf_get_lines` + `nvim_win_get_cursor`) is api-safe THERE.

## 2. Sole consumer (confirmed via grep) — no other callers

`grep -rn complete_current lua/ tests/` → the ONLY call site is `completion.lua:428` (`do_shell_fetch`). Everything else is docstrings/tests. So S3 has exactly one integration seam; S2's forward-guard (`type(...) == "function"`) flips from silent-no-op to live the moment S3 lands.

## 3. Coordinate contract — §17.14 (shell uses BYTE offsets, NOT UTF-16)

- `nvim_win_get_cursor(0)` → `{row 1-indexed, col 0-indexed BYTE}` (coords.lua header "CURSOR-API COL IS 0-BASED BYTE", LIVE-VERIFIED; external_deps.md §1.2).
- line 1 = `nvim_buf_get_lines(buf, 0, 1, false)[1]` (only line 1 — completion_context gates `cursorLine == 0`).
- **NO `coords.nvim_to_pi_coords` call** (that's UTF-16 for the pi bridge path; shell is plain bytes — §17.14). This is the key difference from the slash/path path.
- Lua strings are byte buffers; `string.sub` / `#line` are byte-correct; multibyte reassembles naturally (no streaming-decoder needed — mirrors jsonlreader GOTCHA 1).

## 4. Bang-strip + line/cursor/after math (VERIFIED against the fish spike)

PRD §17.7: "strip 2 if `line1` starts with `!!`, else 1." (Check `!!` FIRST — it also starts with `!`.)

Let `line1` = buffer line 1, `byte_col` = nvim 0-based byte col:
- `bangs   = line1:sub(1,2) == "!!" and 2 or (line1:sub(1,1) == "!" and 1 or 0)`
- `cmd     = line1:sub(bangs + 1)`                       — full command after bangs
- `cin     = math.max(0, byte_col - bangs)`              — cursor offset into cmd (CLAMP ≥0; a cursor ON the bangs → 0)
- `line    = cmd:sub(1, cin)`                            — up to cursor (Lua sub(1,n) = first n bytes; sub(1,0)="" )
- `cursor  = cin`                                         — 0-based byte offset into `line` (== #line by construction)
- `after   = cmd:sub(cin + 1)`                           — text after cursor

**VERIFIED:** `"!git ch"` cursor-at-end → byte_col=7, bangs=1, cmd="git ch", cin=6, line="git ch", cursor=6, after="".
Frame: `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n` — EXACTLY the §17.5.1 example + the `shell_fish_spike.lua` wire shape. ✓

**`!!` case:** `"!!git ch"` → bangs=2, cmd="git ch", same frame. ✓ (bang-count is the only difference; both route to "shell".)

**Cursor-on-bangs edge:** `"!!git"` cursor byte_col=1 → cin=max(0,1-2)=0 → line="", cursor=0, after="git". Daemon gets empty prefix → returns per its shell's empty-prefix rules. Acceptable (cursor on the bangs is a degenerate position).

## 5. The empty-command guard (§17 edge case)

PRD §11/§17: "`!` with an empty command does not spawn the daemon (no completion until a word exists)."
→ If `cmd` is empty OR whitespace-only (`cmd == "" or cmd:match("^%s*$")`), resolve `cb(nil, {}, "")` WITHOUT calling M.request (avoids a cold-start daemon spawn on a bare `!`).
NOTE: `!git ` (trailing space, cursor after) has cmd="git " (non-empty) → DOES query (fish `complete -C "git "` returns subcommands). So the guard is ONLY a wholly-empty command, NOT an empty trailing word.

## 6. prefix derivation — RECOMMEND client-side override (Option A)

§17.6.1: "The current word being completed (for `prefix`) is derivable client-side (last whitespace-delimited token of `line[1..cursor]`)." The daemon's `decoded.prefix` (§17.5.1) is advisory and its quality is TBD (drivers are P2.M2.T4 / P2.M3.T5 — not built; the fish spike emits NO prefix field).

**Decision (v1):** complete_current DERIVES prefix client-side and OVERRIDES the daemon's:
```lua
local function shell_word_prefix(line) return line:match("[%S]+$") or "" end
```
- Pro: deterministic; no dependency on unbuilt drivers; matches §17.6.1; shell/accept.lua (P2.M2.T4) recomputes word boundaries for accept independently anyway.
- The daemon prefix passed through M.request's cb is IGNORED (forward-compat: a future good driver's prefix could be honored via "if non-empty" — Option B — noted as alternative).

complete_current's cb wrapper:
```lua
M.request(line, cursor, after, function(rerr, ritems, _rprefix)
  if rerr then return cb(rerr) end
  cb(nil, ritems or {}, shell_word_prefix(line))   -- OVERRIDE prefix client-side
end)
```
`line` is captured in the closure (immutable local — safe across the async cb fire).

## 7. Supersession layers — complete_current does NOT add its own gen guard

Two layers already exist; complete_current sits between them and just forwards:
- **completion.lua `state.gen`** (SHARED, do_shell_fetch bumps + checks) — completion-level supersession.
- **shell.lua `state.gen`** (M.request bumps + pending_cb checks) — daemon-level supersession.

complete_current's cb is invoked by M.request's pending_cb (fast ctx) → forwards to do_shell_fetch's cb (which checks completion's gen). No third layer needed. (If complete_current bumped its own gen, it would be redundant + confusing.)

## 8. Test harness (from shell_request_spec.lua — the established pattern)

- `fake_bridge(shell_path)` — `get_shell_info()` returns `{shell=...}` so the REAL `M.ensure` resolves "fish" basename.
- `inject_fake_driver(fake_stdin)` — `package.loaded["pi-bridge.shell.fish"] = drv`; drv.start hands the fake stdin to ensure → `state.stdin` = fake.
- `make_fake_stdin()` — `.written[]` captures frames; `.write(data, wcb)` calls `wcb(nil)`.
- `shell._test_invoke_pending(items, prefix)` — delivers a response as `_feed` will in prod (pending_cb is module-local).
- Buffer setup (from completion_spec.lua:105/109): `nvim_buf_set_lines(buf,0,-1,false,{"!git ch"})` + `nvim_win_set_cursor(win,{1,7})`.
- count_open_timers() — the no-leak assertion (uv.walk filter).

## 9. Never-throws + fresh-reads (codebase mandates)

- `pcall` every `nvim.api.*` + `M.request`; guard `buf` validity + type; bad args → `cb(err)` (never throw — per-keystroke/autocmd contract).
- Read `require("pi-bridge.shell")` is the SAME module (complete_current is added TO it) — no lazy-require needed for self. But `M.request` / `M.ensure` are module-local `M.X` — call directly.
- complete_current is called from completion.lua via `require("pi-bridge.shell")` (already lazy there).

## 10. Files touched (scope fence)

- EDIT `lua/pi-bridge/shell.lua` — add `M.complete_current` (+ the `shell_word_prefix` local helper; optionally exported pure for unit tests).
- CREATE `tests/shell_complete_current_spec.lua` — plenary spec (fake daemon; frame + cb assertions; edge cases).
- CREATE `tests/shell_complete_current_smoke.lua` — plenary-free load + basic call smoke.
- DO NOT touch: completion.lua (S2 done), menu.lua, accept (P2.M2.T4), ftplugin, notices (S4), health, drivers (P2.M2.T4/M3.T5).