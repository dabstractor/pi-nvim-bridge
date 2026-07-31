# `vim.defer_fn` Semantics — LIVE-VERIFIED on Neovim 0.12.x

Headless runs (`nvim --headless --clean -u NORC +"luafile …"`). This is the
load-bearing correctness item for S30's debounce: `external_deps.md §1.7`
prescribes `timer:stop()`-only, which **leaks** the handle.

## Verified facts (printed output)

### 1. Return value
`vim.defer_fn(fn, timeout)` returns a **`userdata` timer** (the libuv `uv_timer_t`)
with `:stop()`, `:close()`, `:is_closing()` (same surface as `uv.new_timer()`).
```
type=userdata   has_stop=true   has_close=true   isclosing_before=false
```

### 2. Calling `vim.defer_fn` twice WITHOUT cancelling → **BOTH fire**
Manual cancellation is required (defer does not auto-supersede prior defers).
```
both_fired_without_cancel=true order=A,B
```

### 3. `:stop()` PREVENTS the callback BUT LEAKS the handle — `:close()` is REQUIRED
```
after stop: isclosing=false        ← handle STILL OPEN (LEAKED)
fired_after_stop_only=nil          ← callback correctly suppressed
STILL_OPEN_after_stop=true
after close: isclosing=true        ← only after :close() is it freed
```
**This contradicts `external_deps.md §1.7`** (`if timer then timer:stop() end`),
which leaks a `uv_timer_t` on every reschedule. S30 must **`stop()`+`close()`**.

### 4. After the defer FIRES naturally, the timer **AUTO-CLOSES** (no manual close)
```
fired=true   is_closing_INSIDE_cb=true   is_closing_AFTER_return=true
```
So the only path that needs `:close()` is the **cancel-before-fire** path. A fired
defer is already freed — do NOT `:close()` it again (it would throw "already closing").

### 5. The callback runs on the **nvim MAIN LOOP** — `vim.api.*` is safe (no `vim.schedule`)
```
api_call_OK_in_cb=true   api_err=nil
```
`vim.defer_fn` internally wraps the user fn in `vim.schedule`, so unlike a raw
`uv.new_timer()` callback (libuv fast context, where `vim.api.*` throws `E5560`),
the defer fn may call `nvim_buf_get_lines` / `nvim_win_get_cursor` / `bridge.request`
**directly**. This is the rule that lets S30's `do_refresh` read the buffer + cursor
+ issue the RPC inline (no extra `vim.schedule`).

### 6. Cancel-previous-then-schedule idiom — verified correct
```
t1:stop(); t1:close();  local t2 = vim.defer_fn(fn2, ms)
→ debounce_order=SECOND_FIRED   t1_closing=true t2_closing=true
```
Only the NEW defer fires; both handles end closed (no leak).

## Minimal correct debounce snippet for S30

```lua
-- module-level:
local debounce_timer

local function schedule(fn, ms)
  -- cancel any PENDING defer FIRST (stop+close — stop alone leaks, §3).
  if debounce_timer and not debounce_timer:is_closing() then
    debounce_timer:stop()
    debounce_timer:close()
  end
  debounce_timer = vim.defer_fn(fn, ms)   -- auto-closes after it fires (§4); api-safe cb (§5)
end
```

**Key points for the PRP:**
- `stop()` + `close()` on reschedule (NEVER `stop()`-only — leaks per §3).
- Do NOT `:close()` a timer that already fired (it auto-closed; re-closing throws).
- The defer fn can call `vim.api.*` + `bridge.request` directly (main-loop, §5).
- The "no leak across editor open/close cycles" mandate (PRD §6.7) is about the
  **extension** (pi side, long-lived). The nvim process dies on quit, so an
  unfired defer at quit is NOT a cross-cycle leak — but a *stopped-not-closed*
  defer DOES leak within a session (accumulate per keystroke) → use stop+close.