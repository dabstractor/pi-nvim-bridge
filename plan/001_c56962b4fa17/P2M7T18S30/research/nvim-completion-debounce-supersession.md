# Research: Debounce + Stale-Response Supersession in Neovim Completion Plugins

Source-of-truth implementations studied (commit on `main` at fetch time):
- nvim-cmp — `lua/cmp/core.lua`, `lua/cmp/source.lua`, `lua/cmp/utils/async.lua`, `lua/cmp/context.lua`, `lua/cmp/init.lua`, `lua/cmp/config/default.lua`
- blink.cmp — `lua/blink/cmp/sources/lib/queue.lua`, `lua/blink/cmp/sources/lib/init.lua`, `lua/blink/cmp/sources/lib/provider/list.lua`, `lua/blink/cmp/completion/trigger/init.lua`, `lua/blink/cmp/lib/buffer_events.lua`

> Note on blink.cmp: its core completion engine is **pure Lua** today. The only Rust crate (`blink-cmp-fuzzy`, `Cargo.toml` → `lua/blink/cmp/fuzzy/rust/lib.rs`) is the fuzzy matcher, not the fetch/debounce pipeline. All supersession logic below is Lua.

---

## TL;DR — the idiomatic battle-tested pattern

Both plugins combine **two independent mechanisms**, and you need both:

1. **Per-source debounce / coalescing of the *fetch*** (timer or one-coalesce-per-tick) so a fast typist doesn't issue one RPC per keystroke.
2. **A generation id that monotonically increases on every new request**; the async callback captures the id-at-issue-time and **early-returns if the live id no longer matches**. This is the real supersession guard — debounce alone is racy because an in-flight slow RPC can resolve after newer keystrokes.

Neither plugin *only* cancels. Both **id-check inside the callback AND cancel/replace the previous in-flight request**. For your bridge (`bridge.request` returns an id; `bridge.cancel(id)` fires `on_result('cancelled')`), the cleanest mapping is: keep a `current_request_id`, bump it on each new fetch, and in `on_result` ignore unless `id == current_request_id`. The explicit `bridge.cancel(prev_id)` is a nice-to-have optimization (frees the socket round-trip) but the **id check is the correctness boundary**.

---

## 1. How nvim-cmp debounces per-keystroke async completion

nvim-cmp splits "fetch from source" and "filter/render" into two async primitives in `lua/cmp/utils/async.lua`:

### `async.throttle(fn, timeout)` — the debounce/coalesce timer
`https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/utils/async.lua`

It is a leading-edge-ish throttle that **restarts the timer on every call** and keeps `time` anchored to the first call (so the deadline doesn't drift). Key body:

```lua
__call = function(self, ...)
  if time == nil then time = vim.loop.now() end
  self.stop(false)
  self.running = true
  timer:start(math.max(1, self.timeout - (vim.loop.now() - time)), 0, function()
    vim.schedule(function()
      time = nil
      local ret = fn(unpack(args))
      ...
    end)
  end)
end
```

So each call *cancels* the pending timer and arms a fresh one → many rapid calls collapse into one `fn` execution ~`timeout` ms after the first. The whole thing is `vim.schedule`-wrapped (timer callbacks fire on the libuv loop, not the main loop — see Gotcha 4.2).

Defaults from `lua/cmp/config/default.lua` (`https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/config/default.lua`):

```lua
performance = {
  debounce = 60,          -- ms, used as filter.timeout AFTER a source returns
  throttle = 30,          -- ms, the inter-keystroke coalesce window for filter/render
  fetching_timeout = 500, -- ms, how long to keep waiting for a slow source before rendering partial
  ...
}
```

Important nuance: the **fetch itself is not throttled per-keystroke.** Look at `core.complete` (`https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/core.lua`):

```lua
core.complete = function(self, ctx)
  ...
  local sources = self:get_sources()
  for _, s in ipairs(sources) do
    local callback = (function(s_) ... end)(s)
    s:complete(ctx, callback)          -- <-- fires source.complete immediately, no timer
  end
  if not self.view:get_active_entry() then
    self.filter.timeout = self.view:visible() and config.get().performance.throttle or 1
    self:filter()                       -- <-- throttle is applied to the FILTER/render, not the fetch
  end
end
```

What actually collapses per-keystroke fetches is `source.complete`'s own logic: it only issues a new `self.source:complete(...)` when the offset actually moved past `self.request_offset`/`self.offset`, and it reuses the previous fetch while a source is still `FETCHING` (the LSP `isIncomplete` / `TriggerForIncompleteCompletions` path). So for nvim-cmp, "debounce" is achieved by **(a) skipping redundant requests when the keyword offset hasn't changed** + **(b) throttling the *render* path**, not by a timer on the RPC.

The fetch entry point `source.complete` (`https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/source.lua`) wraps the completion callback in **two** supersession mechanisms at once (see §2):

```lua
self.source:complete(params, self.complete_dedup(vim.schedule_wrap(function(response)
  if self.context ~= ctx then return end     -- <-- stale-response guard (context identity)
  ...
end)))
```

### How nvim-cmp wires autocmds (`lua/cmp/init.lua`)
`https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/init.lua`

```lua
-- InsertEnter is deferred to next tick (mode is misreported as normal inside the autocmd)
autocmd.subscribe({ 'InsertEnter' }, async.debounce_next_tick_by_keymap(on_insert_enter))

-- TextChangedI: only fires on_change if cursor advanced by exactly one col on same line (own mini-dedup)
autocmd.subscribe({ 'TextChangedI', 'TextChangedP' }, function(s)
  local pos = vim.api.nvim_win_get_cursor(0)
  ... if not (lp[1]==pos[1] and lp[2]+1==pos[2]) then return end
  on_text_changed()
end)

-- CursorMovedI does NOT fetch — it only re-filters existing entries
autocmd.subscribe('CursorMovedI', function() cmp.core:on_moved() end)  -- core.on_moved -> self:filter()

-- InsertLeave: synchronous reset + close
autocmd.subscribe({ 'InsertLeave', 'CmdlineLeave', 'CmdwinEnter' }, function()
  cmp.core:reset(); cmp.core.view:close()
end)
```

`on_moved` → `core.on_moved` only calls `self:filter()` (re-filter the entries already in hand). It deliberately does **not** re-issue `source.complete`. So for your plugin: on `CursorMovedI` you should usually **re-filter / re-position, not re-fetch**, unless the cursor left the current keyword bounds.

---

## 2. Stale-response handling: id-check, cancel, or BOTH? → **BOTH**

### nvim-cmp: capture-by-closure + a dedup id
`async.dedup()` in `lua/cmp/utils/async.lua` (`https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/utils/async.lua`):

```lua
async.dedup = function()
  local id = 0
  return function(callback)
    id = id + 1
    local current = id
    return function(...)
      if current == id then callback(...) end   -- only the LATEST wrapped callback runs
    end
  end
end
```

`source.complete` calls `self.complete_dedup(vim.schedule_wrap(cb))` per request. Because `complete_dedup` is **one shared dedup per source** (created in `source.new`, reset in `source.reset`), bumping its internal `id` on each wrap means **only the most recently wrapped callback ever fires** — older in-flight responses are silently dropped at the callback boundary.

On top of that, the callback also captures the request-time `ctx` and bails if `self.context ~= ctx`:

```lua
self.complete_dedup(vim.schedule_wrap(function(response)
  if self.context ~= ctx then return end
  ...
```

So nvim-cmp uses **TWO layers**: (a) dedup-id (only latest callback fires) and (b) context-identity capture (belt-and-suspenders). It does **not** call an explicit `cancel` on the LSP request — LSP `textDocument/completion` has no cancel in nvim-cmp's source interface; it just drops late responses. `core.reset()` (called on `InsertLeave`, on `TriggerOnly` mismatch, etc.) bumps `revision` and re-seeds `complete_dedup`, invalidating everything.

### blink.cmp: monotonic `context.id` + explicit in-flight cancel + a queued fallback
`lua/blink/cmp/sources/lib/queue.lua` (`https://github.com/Saghen/blink.cmp/blob/main/lua/blink/cmp/sources/lib/queue.lua`):

```lua
function queue:get_completions(context)
  assert(context.id == self.id, '...different context ID')

  if self.request ~= nil then
    if self.request.status == task.STATUS.RUNNING then
      self.queued_request_context = context   -- remember latest; drop intermediate ones
      return
    else
      self.request:cancel()                   -- <-- explicit cancel of finished-but-unconsumed
    end
  end

  self.request = tree:get_completions(context, function(items_by_provider)
    self.cached_items_by_provider = items_by_provider
    self.on_completions_callback(context, items_by_provider)
    -- drain the one queued request, if any:
    local queued_context = self.queued_request_context
    if queued_context ~= nil then
      self.queued_request_context = nil
      if self.request ~= nil then self.request:cancel() end
      self:get_completions(queued_context)
    end
  end)
end
```

And the queue is **recreated whenever the context id changes** (`lua/blink/cmp/sources/lib/init.lua`, `https://github.com/Saghen/blink.cmp/blob/main/lua/blink/cmp/sources/lib/init.lua`):

```lua
function sources.request_completions(context)
  if sources.completions_queue == nil or context.id ~= sources.completions_queue.id then
    if sources.completions_queue ~= nil then sources.completions_queue:destroy() end  -- destroy => request:cancel()
    sources.completions_queue = require('blink.cmp.sources.lib.queue').new(context, sources.emit_completions)
  ...
  end
  sources.completions_queue:get_completions(context)
end
```

The id is a monotonic per-trigger counter in `lua/blink/cmp/completion/trigger/init.lua`:

```lua
-- update the context id to indicate a new context, and not an update to an existing context
if not ctx or opts.providers ~= nil then trigger.current_context_id = trigger.current_context_id + 1 end
```

So blink's recipe is: **(a) bump a generation id on every new fetch; (b) cancel the previous in-flight task; (c) keep exactly one "latest pending" context to run after the current one finishes (coalescing).** The `destroy()` path (`sources.cancel_completions` / `queue:destroy`) neuters `on_completions_callback` to a no-op AND cancels the task — so even a late callback can't render.

### Concrete recommendation for your bridge
Given `bridge.request(method, params, on_result)` returns an id and `bridge.cancel(id)` fires `on_result('cancelled')`:

```lua
-- pseudocode
local current_id = 0
local pending = {}   -- id -> true

local function fetch(ctx)
  -- cancel anything still outstanding before issuing the new one (frees the socket round-trip)
  for id in pairs(pending) do bridge.cancel(id); pending[id] = nil end

  current_id = current_id + 1
  local my_id = current_id

  local req = bridge.request('getSuggestions', { ctx = ctx }, function(result)
    pending[req] = nil
    -- SUPPRESSION GUARD — this is the real correctness boundary
    if my_id ~= current_id then return end   -- stale: a newer fetch has started
    render(result)
  end)
  pending[req] = true
end
```

The `if my_id ~= current_id then return end` is the **mandatory** guard (mirrors nvim-cmp's `self.context ~= ctx` and blink's `context.id == self.id` assert). The explicit `bridge.cancel(prev)` mirrors blink's `request:cancel()` and is worth doing because your transport is a single Unix socket (in-flight requests can block or serialize) — but it is an optimization, not the correctness boundary.

---

## 3. On a cancelled / error response: clear menu, keep stale, or ignore?

Consensus across both: **silently ignore; do not clear and do not keep rendering stale results as if fresh.** Menu clearing is driven by *separate* signals (leaving the keyword, `InsertLeave`), not by a failed/cancelled fetch.

- **nvim-cmp** — the cancelled/error path never touches the menu. In `async.throttle`, errors that are `'abort'` are swallowed (`if error and error ~= 'abort' then vim.notify(...) end`); non-abort errors `vim.notify` at ERROR level but don't close the view. A dropped/late response simply leaves whatever was already rendered in place until the next `filter()`/`complete()` decides otherwise. `core.on_change`/`on_moved` guard with `ignore = ignore or (vim.fn.pumvisible() == 1 and (vim.v.completed_item).word)` so an already-accepted item isn't disturbed.

- **blink.cmp** — `queue:destroy()` replaces `on_completions_callback` with `function() end` (a hard no-op) **and** cancels the task. So a cancelled fetch produces no menu change at all. `list:destroy()` likewise nulls `on_items`. The menu is closed by `trigger.hide()` (called on `InsertLeave`, on `on_complete_changed` when `pumvisible()`, and when the char under cursor is non-keyword), not by the cancel path. Provider-level errors in blink's `lib/task` propagate as rejected Tasks; the provider's `list.lua` `append` ignores empty responses once completed (`if self.has_completed and #response.items == 0 then return end`).

**For your bridge:** in `on_result`, treat `'cancelled'` and errors as **no-ops** (return early; do not clear the menu, do not render). Separately, drive menu-clear from `InsertLeave`, from "cursor left the keyword range," and from "non-keyword char typed." Your `bridge.cancel(id)` firing `on_result('cancelled')` lines up perfectly with this — just make the `'cancelled'` branch of `on_result` a `return` that touches nothing.

One subtlety worth copying from blink: when you supersede a request, **don't blank the menu between the cancel and the new response arriving** — that causes a visible flicker. Keep the previous results visible (or a cached copy) until the newer response lands. blink codifies this as `async_initial_items` in `list.new` (the "HACK: flash of no items" comment in `lua/blink/cmp/sources/lib/provider/list.lua`).

---

## 4. Real gotchas (battle-tested, with citations)

### 4.1 TextChangedI vs CursorMovedI redundancy — handle them differently
- `InsertCharPre` fires *before* the char is inserted; `TextChangedI` fires *after*. The char you want to complete on is only available post-`TextChangedI`. blink reads the char in `InsertCharPre` (`self.last_char = vim.v.char`) and consumes it in `TextChangedI` (`buffer_events.lua`). This avoids double-handling.
- blink **deliberately suppresses the `CursorMoved` half of the pair** during typing: `if ev.event == 'CursorMoved' and (mode ~= 'v' or not in_snippet_context) then return end` — i.e. only `CursorMovedI` (insert-mode moves) matter; plain `CursorMoved` is for snippet tab-stop jumps. (`buffer_events.lua`, `make_cursor_moved`.)
- nvim-cmp notes that `TextChangedI` + `CursorMovedI` can both fire for the same keystroke. Its `core.on_moved` (the `CursorMovedI` handler) **does not fetch** — it only re-filters existing entries. Fetching on `CursorMovedI` is almost always wrong (it's the same logical edit as the preceding `TextChangedI`); use it only to re-filter/re-position.
- Takeaway for your plugin: on `TextChangedI` → debounce + fetch; on `CursorMovedI` → re-filter existing suggestions in-place (or hide if cursor left the keyword), **no new RPC**.

### 4.2 You almost always need `vim.schedule` in RPC/libuv callbacks
- nvim-cmp wraps its source callback in `vim.schedule_wrap(...)` (`source.complete`). Its throttle runs `fn` inside `vim.schedule`. `init.lua` even has a literal comment: *"In InsertEnter autocmd, vim will detect mode=normal unexpectedly"* → it defers InsertEnter to next tick via `debounce_next_tick`.
- blink's `InsertLeave` handler is `vim.schedule`-wrapped specifically because expanding a snippet flips modes `insert → normal → visual → select` and the intermediate modes would falsely trigger leave (`buffer_events.lua`, `make_insert_leave`, comment: *"vim.snippet.expand switches mode … so we schedule to ignore the intermediary modes"*).
- blink also guards `source:enabled()` with `if vim.in_fast_event() then return false end` because *provider* callbacks may call buffer/window APIs (`nvim_get_current_buf`, `win_gettype`) that are **forbidden in fast callbacks and crash with `E5560`** (`provider/init.lua`). Your `on_result` runs in whatever thread your socket reader lives on — if it's a libuv/`vim.loop` callback or a separate process reader, you **must** `vim.schedule` before touching any Neovim API or the menu.
- `CompleteChanged` is wrapped in `vim.schedule_wrap` in blink; resolve/signature callbacks end in `vim.schedule(function() resolve(...) end)`.

### 4.3 InsertLeave cleanup — and the `Ctrl-C` trap
- nvim-cmp: synchronous `cmp.core:reset(); cmp.core.view:close()` on `InsertLeave`/`CmdlineLeave`/`CmdwinEnter`. `core.reset` calls `s:reset()` on every source (bumps `revision`, reseeds dedup, clears entries) — i.e. it **invalidates all in-flight callbacks at once**.
- blink: `trigger.hide()` on `on_insert_leave`; `sources.cancel_completions()` destroys the queue + cancels the task. Crucially, **`Ctrl-C` does not fire `InsertLeave`** — blink installs a `vim.on_key` watcher that detects `<C-c>` and schedules a leave check (`buffer_events.lua`). nvim-cmp works around the same class of problem by also keying off `ModeChanged`/`BufLeave`. For your plugin: hook `InsertLeave` **and** `ModeChanged` (or a `<C-c>` `on_key` watcher) and on leave, cancel the pending request + close the menu + reset `current_id`.
- Also: on `BufLeave`/window switch, the same cleanup must run; otherwise a response for buffer A can render into buffer B.

### 4.4 Paste / auto-indent / undo edge cases
- **Auto-indent (`indentkeys`):** nvim-cmp's `core.autoindent` checks `vim.bo.indentkeys` and calls `self:reset()` + `set_context(context.empty())` when the typed char matches an indent key (e.g. typing `{` then Enter triggers reindent). If you don't reset on indent, you'll offer completions for the pre-indent column and render at the wrong offset. (`core.lua`, `core.autoindent`.)
- **Undo breaks:** nvim-cmp inserts `keymap.undobreak()` around its text edits so accepting a completion doesn't merge with the user's typing in the undo tree. Relevant if your accept path mutates buffer text.
- **Accept/suppress event flicker:** accepting a completion immediately fires a `CursorMovedI`; blink tracks `did_accept` and ignores the *first* `CursorMovedI` after an accept to avoid re-triggering a fetch (`buffer_events.lua`, `make_cursor_moved`, comment: *"accepting will immediately fire a CursorMovedI … we ignore the first CursorMovedI after accepting"*). It also has `suppress_events_for_callback` that compares `changedtick` + cursor pos before/after a programmatic edit and sets `ignore_next_text_changed`/`ignore_next_cursor_moved` flags — this is how it avoids feedback loops when *it* writes text.
- **Keyword-length / min-chars:** both gate fetches on a minimum keyword length (nvim-cmp `keyword_length` default 1 in `config/default.lua`; blink `min_keyword_length` in `sources/lib/provider/init.lua` → `should_show_items`). Before issuing the RPC, bail if the current word is shorter than your threshold — saves a lot of pointless round-trips on leading whitespace / single chars.
- **`pumvisible()` guard:** nvim-cmp's `on_change`/`on_moved` short-circuit when `vim.fn.pumvisible() == 1 and (vim.v.completed_item).word` — if the user already selected/accepted an item from the *native* pum (or another plugin), don't fight it.

---

## Mapping to your bridge API (cheat sheet)

| Concern | nvim-cmp | blink.cmp | Your bridge |
|---|---|---|---|
| Debounce/coalesce per keystroke | `async.throttle` (timer restart) + offset-change skip | one pending context + `InsertCharPre`/`TextChangedI` consume | `vim.defer_fn`/`uv.new_timer` restart on each `TextChangedI`, ~25–60ms |
| Supersession of stale responses | `async.dedup` (latest id wins) **and** `self.context ~= ctx` capture | monotonic `context.id`; `assert(ctx.id == self.id)`; recreate queue | bump `current_id` per fetch; in `on_result` `if my_id ~= current_id then return end` |
| Cancel previous in-flight | not explicitly (drops late resp) | explicit `request:cancel()` + `queue:destroy()` no-ops the cb | `bridge.cancel(prev_id)` before `bridge.request` (optimization; id-check is the real guard) |
| Cancelled/error response | swallow (`'abort'`); `vim.notify` non-abort; menu untouched | cb replaced with no-op; menu untouched | `on_result('cancelled')`/error → `return`, touch nothing |
| Flicker on supersede | caches entries; re-renders from cache | `async_initial_items` keeps prev list until new lands | keep last good results rendered until newer response lands |
| `CursorMovedI` | re-filter only, no fetch | `trigger.show({trigger_kind='keyword'})` reuses context | re-filter/re-position; new fetch only if cursor left keyword bounds |
| `vim.schedule` in cb | yes, everywhere (`vim.schedule_wrap`, `debounce_next_tick`) | yes (`vim.schedule`, `vim.in_fast_event` guard) | mandatory: `vim.schedule` your render in `on_result` |
| InsertLeave / Ctrl-C | `reset()`+`close()` on InsertLeave/CmdlineLeave/CmdwinEnter | `hide()`+`cancel_completions()`; `<C-c>` `on_key` watcher | hook InsertLeave + ModeChanged; cancel pending; reset id; close menu |
| Auto-indent | `core.autoindent` resets on `indentkeys` match | (snippet mode guards) | reset context when typed char ∈ `indentkeys` |
| Min keyword length | `keyword_length` (default 1) | `min_keyword_length` + `should_show_items` | bail before RPC if word too short |

### Reference URLs
- nvim-cmp source: https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/source.lua
- nvim-cmp core: https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/core.lua
- nvim-cmp async (throttle/dedup): https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/utils/async.lua
- nvim-cmp context (abort/changed/id): https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/context.lua
- nvim-cmp init (autocmds): https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/init.lua
- nvim-cmp default config (debounce/throttle): https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/config/default.lua
- blink.cmp sources queue (cancel + pending): https://github.com/Saghen/blink.cmp/blob/main/lua/blink/cmp/sources/lib/queue.lua
- blink.cmp sources init (recreate queue on id change): https://github.com/Saghen/blink.cmp/blob/main/lua/blink/cmp/sources/lib/init.lua
- blink.cmp provider list (cancel_completions, async_initial_items flicker fix): https://github.com/Saghen/blink.cmp/blob/main/lua/blink/cmp/sources/lib/provider/list.lua
- blink.cmp provider (vim.in_fast_event guard, min_keyword_length): https://github.com/Saghen/blink.cmp/blob/main/lua/blink/cmp/sources/lib/provider/init.lua
- blink.cmp trigger (context.id counter, CursorMovedI handling): https://github.com/Saghen/blink.cmp/blob/main/lua/blink/cmp/completion/trigger/init.lua
- blink.cmp buffer_events (InsertCharPre/TextChangedI/Ctrl-C/suppress): https://github.com/Saghen/blink.cmp/blob/main/lua/blink/cmp/lib/buffer_events.lua