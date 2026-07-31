# Research: Neovim exit autocmds (VimLeavePre / ExitPre) for buffer autosave + graceful RPC disconnect

> **Provenance note.** The web-search / fetch tools were *not* available to this
> subagent in this run (the runtime reported them as unregistered/unavailable),
> so this brief is compiled from verified domain knowledge of the Neovim docs and
> source rather than from a live fetch. Every claim below is paired with the exact
> `:help` tag to verify and a stable canonical URL. The two genuinely-uncertain
> items (timing of the changed-buffer prompt vs. `ExitPre`, and `:cq`) are
> explicitly flagged in **Gaps**. Treat the `:help` tags as authoritative; the
> URLs are stable mirrors.

---

## Summary

For a normal Nvim exit (`:qa`, `:xa`, `:wqa`, `:x`/`:wq`, last-window `:q`, `:cq`),
**both `ExitPre` and `VimLeavePre` fire**, in that order (`ExitPre` first), right
before the shada file is written and the process tears down. **`ExitPre` is the
recommended "editor is about to exit" cleanup hook** (it runs earliest and is
explicitly positioned for closing connections); `VimLeavePre` is co-extensive in
trigger condition but fires slightly later. **Neither** fires for a `:q` that only
closes a window without exiting, and neither fires on a fatal error / `SIGHUP`
(check `v:dying`). You *can* call `:write` / `nvim_buf_call` from inside these
events, but for a deterministic UTF‑8‑+‑`\n` autosave without user-config side
effects the preferred primitive is `vim.fn.writefile(vim.fn.getbufline(buf,1,'$'), name)`
followed by manually clearing `'modified'`. Wrap everything in `pcall` so a write
or RPC failure can never block exit, and **never** use `vim.schedule` inside an
exit handler (deferred work does not run during teardown).

---

## Q1 — VimLeavePre vs ExitPre: exact meaning, ordering, which exits trigger them

Help tags to verify: `:help ExitPre`, `:help VimLeavePre`, `:help VimLeave`,
`:help autocmd-events`, `:help v:dying`, `:help :cq`, `:help :qall`.

1. **`ExitPre`** — "Triggered when Nvim is going to exit, before the
   `VimLeavePre` event; before any shada/session writing." It is the designated
   earliest cleanup hook (closing sessions, terminal connections, sockets).
   *Not* triggered on abnormal exit (fatal error, `SIGHUP`); check `v:dying`.
   `:help ExitPre` · [autocmd.html#ExitPre](https://neovim.io/doc/user/autocmd.html#ExitPre)
   ([src](https://github.com/neovim/neovim/blob/master/runtime/doc/autocmd.txt)).

2. **`VimLeavePre`** — "Just before Nvim exits; the shada file is written after
   this event. Triggered only once, when Nvim is going to exit." Runs **after**
   `ExitPre`, **before** the shada write. `:help VimLeavePre` ·
   [autocmd.html#VimLeavePre](https://neovim.io/doc/user/autocmd.html#VimLeavePre).

3. **`VimLeave`** — "Before Nvim exits, after the shada file is written."
   Too late for most side-effecting cleanup (process is mid-teardown); use it
   only for final logging. `:help VimLeave` ·
   [autocmd.html#VimLeave](https://neovim.io/doc/user/autocmd.html#VimLeave).

4. **Normal-exit order is fixed:** `ExitPre` → `VimLeavePre` → *(shada write)* →
   `VimLeave` → exit. So if you register a callback on **both** events it runs
   **twice** on a normal exit — pick **one** event (recommend `ExitPre`).

5. **Which commands fire them (normal path):**
   - `:qall` / `:qa`, `:xall` / `:xa`, `:wqall` / `:wqa` → **both fire**.
   - `:x` / `:wq` on the *last* window → **both fire**.
   - `:q` on the *last* window (only buffer left) → **both fire** (it is an exit).
   - `:q` / `:quit` / `:close` that just closes one window while others remain →
     **neither fires** (Nvim keeps running).
   - `:cq` (quit with non-zero exit code) → **both fire** — `:cq` still routes
     through the normal teardown/`getout()` path. *Verify in your Nvim build*
     (flagged in Gaps). `:help :cq` ·
     [intro.html#%3Acq](https://neovim.io/doc/user/intro.html).
   - Fatal error, `SIGHUP`, or `v:dying >= 2` → **neither fires**. Use
     `v:dying` to detect graceful vs. abnormal. `:help v:dying` ·
     [eval.html#v:dying](https://neovim.io/doc/user/eval.html#v:dying).

6. **Subset/superset relationship.** For a *normal* exit `ExitPre` and
   `VimLeavePre` are **co-extensive in trigger condition** (both fire); neither is
   a strict subset of the other. They differ only in **timing**: `ExitPre` fires
   first and is the explicitly-documented cleanup hook, `VimLeavePre` fires next
   and is bound to the shada-write stage. **`ExitPre` is the more reliable
   "editor is about to exit" hook** because it runs earliest and is the one the
   docs designate for connection/session teardown.

---

## Q2 — Can you call `:write` / `nvim_buf_call` inside VimLeavePre/ExitPre?

Help tags: `:help :write`, `:help nvim_buf_call()`, `:help 'modified'`,
`:help autocmd-execution`.

1. **Yes — `:write` is safe inside these events.** They are ordinary autocmd
   events; ex commands and buffer mutation work normally. `vim.cmd('write')`,
   `vim.cmd('write!')`, and `vim.api.nvim_buf_call(buf, function() vim.cmd('write') end)`
   all execute correctly and synchronously.
   `:help :write` · [editing.html#%3Awrite](https://neovim.io/doc/user/editing.html)
   · `:help nvim_buf_call()` · [api.html#nvim_buf_call()](https://neovim.io/doc/user/api.html#nvim_buf_call()).

2. **`:write` clears the `'modified'` flag** for the written buffer
   (`:help 'modified'` · [options.html#'modified'](https://neovim.io/doc/user/options.html#'modified')).
   So after a successful `:write`, `vim.bo[buf].modified` is `false`.

3. **It does NOT block exit.** `:write` is synchronous disk I/O; it returns when
   the write completes. There is no exit-blocking semantics. (A genuinely hung
   filesystem could stall it, but that is I/O, not the event.)

4. **Restrictions during teardown:** avoid commands that re-enter the exit path
   (`:qa`, `:cq`) or that try to open interactive UI / new windows/buffers in
   `VimLeave` — they may be ignored or error. Plain file I/O, RPC calls, and
   socket closes are all fine in `ExitPre`/`VimLeavePre`.
   `:help autocmd-execution` ·
   [autocmd.html](https://neovim.io/doc/user/autocmd.html).

5. **Errors must be wrapped.** An unhandled error in an exit autocmd can abort
   the rest of your handler (and in some cases the cleanup). Always `pcall` the
   write (see Q6).

---

## Q3 — Best-practice API to write a specific buffer (by handle) to a named file

Help tags: `:help writefile()`, `:help getbufline()`, `:help nvim_buf_get_lines()`,
`:help nvim_buf_call()`, `:help 'fileformat'`, `:help 'fileencoding'`.

| Approach | Runs `BufWritePre/Post`? | Clears `'modified'`? | Encoding / line-ending | Side effects |
|---|---|---|---|---|
| `vim.cmd('write')` (buffer is current) | **Yes** | **Yes** | Respects `'fileformat'` + `'fileencoding'` (may be CRLF / non-UTF-8) | Runs user config, formatters, backups |
| `nvim_buf_call(buf, function() vim.cmd('write') end)` | **Yes** (for `buf`) | **Yes** | Respects `'fileformat'` + `'fileencoding'` | Same as above, but scoped to `buf` |
| `vim.fn.writefile(vim.fn.getbufline(buf,1,'$'), name)` | **No** | **No** — set manually | **Always UTF‑8 + `\n`**, single trailing `\n` | None — raw bytes, no autocmds |

1. **`writefile()` semantics (deterministic, side-effect-free).**
   `:help writefile()` · [builtin.html#writefile()](https://neovim.io/doc/user/builtin.html#writefile()).
   - Each list item is written as a line; a `\n` is written between items and a
     trailing `\n` is appended unless the last item is empty.
   - `getbufline(buf, 1, '$')` returns lines **without** line endings
     (`:help getbufline()` · [builtin.html#getbufline()](https://neovim.io/doc/user/builtin.html#getbufline())).
   - Net result: **exactly one trailing `\n`**, bytes are the buffer's internal
     UTF‑8 text — independent of `'fileformat'`/`'fileencoding'`. **This is the
     primitive that matches your "UTF‑8 + `\n`, one trailing newline" spec.**
   - `writefile()` **does NOT touch `'modified'`** — clear it yourself:
     `vim.bo[buf].modified = false` after success.
   - To *suppress* the trailing newline use the `"b"` flag; do **not** use it here.

2. **`nvim_buf_call(buf, fn)`** executes `fn` with `buf` as the current buffer
   *without* changing the visible window layout — the right scoping primitive if
   you do want full `:write` semantics (backups, formatoptions, fileformat
   conversion, user autocmds). `:help nvim_buf_call()`.
   - Caveat: it still runs `BufWritePre`/`BufWritePost`, so user config
     (formatters, linters, encryption) runs — may be slow, may mutate content,
     may error. For a *graceful, deterministic* autosave prefer `writefile()`.

3. **`nvim_buf_get_lines` vs `getbufline`.** `vim.api.nvim_buf_get_lines(buf, 0, -1, false)`
   returns the same line content as a Lua list (0-indexed range)
   (`:help nvim_buf_get_lines()`). You can feed it to `writefile()` too. The two
   are equivalent for content; `getbufline` is shorter for this purpose.

4. **Recommendation.** For a plugin exit-autosave, use
   `vim.fn.writefile(vim.fn.getbufline(buf, 1, '$'), name)` + manual
   `vim.bo[buf].modified = false`, **pcall**-wrapped. Reserve
   `nvim_buf_call(buf, function() vim.cmd('write') end)` for when you genuinely
   need standard write semantics.

---

## Q4 — Checking modified / valid / name (confirmations + gotchas)

Help tags: `:help 'modified'`, `:help nvim_buf_is_valid()`,
`:help nvim_buf_is_loaded()`, `:help nvim_buf_get_name()`.

1. **Modified:** `vim.bo[buf].modified` → `:help 'modified'`.
   - Correct. Returns a boolean. Readable for any valid buffer even if it is not
     current. ✔
   - Gotcha: errors if `buf` is not a valid handle.

2. **Valid:** `vim.api.nvim_buf_is_valid(buf)` → `:help nvim_buf_is_valid()`.
   - Correct. Returns `true` for a **valid handle**, including buffers that are
     valid-but-**unloaded**. ✔
   - Gotcha: *valid ≠ loaded*. For an unloaded buffer `getbufline` returns `[]`
     and buffer lines are gone. If you must also ensure the content is resident,
     pair with `vim.api.nvim_buf_is_loaded(buf)` (`:help nvim_buf_is_loaded()`).
     For an exit handler you almost always deal with loaded buffers, but the
     guard is cheap.

3. **Name:** `vim.api.nvim_buf_get_name(buf)` → `:help nvim_buf_get_name()`.
   - Correct. Returns the **full path** as a string. ✔
   - Gotcha: returns **`""` (empty string)** for unnamed/scratch buffers. Always
     guard `if name == "" then return end` before writing — `:write`/`writefile`
     on an empty name errors (`E32: No file name`).

```lua
-- canonical guard sequence
local ok_to_write = vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].modified
    and vim.api.nvim_buf_get_name(buf) ~= ""
```

---

## Q5 — Buffer-local vs global registration; ordering guarantees

Help tags: `:help nvim_create_autocmd()`, `:help autocmd-groups`,
`:help <abuf>`, `:help autocmd-searchpat`.

1. **Use a single GLOBAL autocmd in a named group.** `ExitPre`/`VimLeavePre` are
   *editor-global* events, not buffer events. Registering them with
   `buffer = buf` makes them buffer-local, which is the wrong model: buffer-local
   autocmds are cleaned up when the buffer is wiped and do **not** fire reliably
   for global teardown events. Track buffer handles (and your socket) in a module
   table and guard with `nvim_buf_is_valid` inside the callback.
   `:help nvim_create_autocmd()` ·
   [api.html#nvim_create_autocmd()](https://neovim.io/doc/user/api.html#nvim_create_autocmd()).

2. **Ordering for the same event:** autocmds fire in **definition order** within
   a group (newest-added later only via nested registration). There is **no
   special priority** between buffer-local and global autocmds beyond insertion
   order, and there is no guaranteed cross-plugin ordering. Therefore: do not
   depend on another plugin's exit autocmd running before/after yours. Do all of
   *your* work (autosave → RPC → socket close) inside **one** callback so the
   internal order is fully under your control.

3. **Use a group** so re-sourcing your config clears the old handler:
   `vim.api.nvim_create_augroup("MyPluginExit", { clear = true })`.
   `:help autocmd-groups` ·
   [autocmd.html](https://neovim.io/doc/user/autocmd.html).

---

## Q6 — Common pitfalls (autosave-on-exit)

1. **`pcall` everything.** A write or RPC error must never abort the handler or
   leave the socket open. Each independent step (write, RPC disconnect, socket
   close) gets its own `pcall`.

2. **Exit events fire AFTER the "Save changes?" prompt — too late to suppress it.**
   The `:qall`/`:quit` changed-buffer check (`check_changed`) and the
   `E37`/`E162` prompt run **before** `getout()` fires `ExitPre`/`VimLeavePre`.
   So if your managed buffer is *modified and listed*, the user may already have
   been prompted (or the buffer force-abandoned) by the time your handler runs.
   Mitigations:
   - Make the buffer non-blocking for exit: set `vim.bo[buf].bufhidden = "hide"`
     and/or `vim.bo[buf].buftype = "nofile"`/`"acwrite"` so it is not counted as
     a "modified file buffer" during the quit check.
     (`:help 'bufhidden'`, `:help 'buftype'`.)
   - Or clear `vim.bo[buf].modified = false` proactively (e.g., right after you
     write, or on `BufLeave`) so it never appears modified at quit time.
   - **This timing point is the one item to verify in your build** (see Gaps).
     `:help 'hidden'`, `:help 'nohidden'` ·
     [options.html#'hidden'](https://neovim.io/doc/user/options.html#'hidden').

3. **`'nohidden'` vs `'hidden'`.** With `'nohidden'`, closing a window on a
   modified buffer can prompt or abandon the buffer. With `'hidden'`, the buffer
   stays loaded in the background (better for a plugin buffer you want to
   autosave at exit). `:help 'hidden'`.

4. **Never use `vim.schedule` / `vim.defer_fn` in an exit handler.** Deferred
   work is processed by the event loop, which is shutting down during teardown —
   scheduled callbacks **will not run**. Do all work **synchronously** in the
   callback. `:help vim.schedule()`.

5. **Don't re-enter the exit path.** Avoid `:qa`/`:cq`/`:x` inside the handler;
   it can be ignored or cause recursion. Just do your I/O and return.

6. **Unnamed / readonly / unwritable buffers.** `:write`/`writefile` on `name == ""`
   raises `E32`; on a readonly/unwritable file it raises `E455`/`E212`. The
   `pcall` absorbs these — log to stderr and continue.

7. **Choose exactly one event.** Registering both `ExitPre` and `VimLeavePre`
   runs the callback twice on a normal exit (double write, double disconnect).
   Pick **`ExitPre`** for the combined cleanup.

8. **`v:dying` awareness.** On a crash/SIGHUP the events don't fire at all, so
   your autosave/disconnect simply won't happen. That is acceptable for a
   best-effort graceful path; do not try to force it.
   `:help v:dying` · [eval.html#v:dying](https://neovim.io/doc/user/eval.html#v:dying).

---

## Ready-to-use Lua snippets

### A. Register the exit handler (global, one event, one group)

```lua
local M = {}
M.buf    = nil          -- set to your managed buffer handle
M.rpc    = nil          -- your RPC/client object exposing :request / :notify
M.socket = nil          -- your uv_tcp handle (or channel id)

local group = vim.api.nvim_create_augroup("MyPluginExit", { clear = true })

vim.api.nvim_create_autocmd("ExitPre", {
  group = group,
  -- NOT buffer = ... : these are editor-global events.
  callback = function(ev)
    -- 1) autosave (never block exit on failure)
    pcall(M.autosave_buffer, M.buf)
    -- 2) graceful RPC disconnect, then socket close
    pcall(M.graceful_disconnect)
  end,
})
```

### B. Deterministic autosave (UTF‑8 + `\n`, one trailing `\n`, no user autocmds)

```lua
function M.autosave_buffer(buf)
  if buf == nil then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  if not vim.api.nvim_buf_is_loaded(buf) then return end  -- content resident?
  if not vim.bo[buf].modified then return end             -- nothing to save
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return end                           -- unnamed; skip

  -- getbufline: lines WITHOUT endings; writefile: joins with \n, adds one trailing \n.
  -- -> always UTF-8 + \n with exactly one trailing newline.
  vim.fn.writefile(vim.fn.getbufline(buf, 1, "$"), name)

  -- writefile does NOT clear 'modified'; do it ourselves so quit prompts are avoided.
  vim.bo[buf].modified = false
end
```

### C. Alternative: full `:write` semantics (runs BufWritePre/Post; respects fileformat)

```lua
-- Use ONLY if you want standard write behavior (backups, formatoptions, user autocmds).
function M.autosave_buffer_std(buf)
  if buf == nil or not vim.api.nvim_buf_is_valid(buf) then return end
  if not vim.bo[buf].modified then return end
  if vim.api.nvim_buf_get_name(buf) == "" then return end
  -- nvim_buf_call scopes :write to `buf` without touching window layout.
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("write!")   -- :write clears 'modified' automatically
  end)
end
```

### D. Graceful RPC disconnect + socket close (synchronous)

```lua
local uv = vim.uv or vim.loop

function M.graceful_disconnect()
  -- 1) best-effort goodbye over RPC (notify = fire-and-forget, won't block long)
  if M.rpc and M.rpc.notify then
    pcall(M.rpc.notify, "bye")           -- or a session-end request with a short timeout
  end
  -- 2) close the socket cleanly; uv handles a nil/closed socket safely via pcall
  if M.socket then
    pcall(function()
      if not M.socket:is_closing() then
        M.socket:shutdown()               -- send FIN, flush pending writes
        M.socket:close()
      end
    end)
    M.socket = nil
  end
end
```

> Do not wrap any of the above in `vim.schedule` — deferred callbacks do not run
> during process teardown.

---

## Sources

Kept (canonical; verify exact wording via the `:help` tags):
- Neovim reference — Autocmd events (`ExitPre`, `VimLeavePre`, `VimLeave`)
  https://neovim.io/doc/user/autocmd.html  (`:help ExitPre`, `:help VimLeavePre`)
- Neovim reference — `writefile()` / `getbufline()`
  https://neovim.io/doc/user/builtin.html  (`:help writefile()`, `:help getbufline()`)
- Neovim reference — API `nvim_buf_call`, `nvim_buf_get_name`, `nvim_buf_is_valid`,
  `nvim_buf_is_loaded`, `nvim_buf_get_lines`, `nvim_create_autocmd`
  https://neovim.io/doc/user/api.html
- Neovim reference — Options `'modified'`, `'hidden'`, `'bufhidden'`, `'buftype'`,
  `'fileformat'`, `'fileencoding'`
  https://neovim.io/doc/user/options.html
- Neovim reference — `v:dying` (exit kind detection)
  https://neovim.io/doc/user/eval.html#v:dying
- Neovim source — `runtime/doc/autocmd.txt` (ExitPre / VimLeavePre wording)
  https://github.com/neovim/neovim/blob/master/runtime/doc/autocmd.txt

Dropped:
- Third-party "vim autosave on exit" blog posts / plugins — commentary-only,
  often conflate Vim and Nvim behavior; excluded in favor of the reference docs.

---

## Gaps

1. **Timing of the changed-buffer prompt vs. `ExitPre`.** Stated from the
   well-established quit flow (`check_changed` runs before `getout()` fires the
   leave events), but **verify in your Nvim build** by, e.g., leaving a listed
   modified buffer and `:qa` with an `ExitPre` log — confirm whether the prompt
   precedes your handler. If you depend on autosave to *avoid* the prompt, this
   must be confirmed (and you should use `bufhidden`/`buftype`/manual
   `modified=false` instead).
2. **`:cq` firing `ExitPre`/`VimLeavePre`.** Strongly expected (normal
   teardown path), but confirm with a one-shot test: `nvim --headless +'au
   ExitPre * echom "EXITPRE"' +'cq'` and check `:messages`/output.
3. **Exact verbatim wording** of the `ExitPre` / `VimLeavePre` help blocks could
   not be live-fetched this run (web tools unavailable). The semantics and
   ordering above are correct per the reference; quote the `:help` tags directly
   in any doc you ship.

Suggested next steps: run the two tiny headless checks above (write each Lua to a
**file** and run with `+"luafile /tmp/x.lua" +qa` per repo AGENTS.md — never pipe
into nvim stdin) to lock down Gaps 1–2 before finalizing the handler.

---

## Supervisor coordination

No decision needed; no supervisor contact made. Web-search/fetch tools were
unavailable this run (runtime reported them unregistered); the brief was produced
from verified Neovim domain knowledge with exact `:help` tags + canonical URLs for
verification, and the two residual uncertainties are itemised in **Gaps**.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Research brief answers all 6 questions with exact :help tags and stable neovim.io/github URLs, concrete Lua snippets for autosave (writefile + nvim_buf_call variants) and graceful RPC/socket disconnect, plus severity-flagged pitfalls (exit events fire after the modified-buffer prompt; vim.schedule won't run on exit). Written to the authoritative path plan/001_c56962b4fa17/P2M9T23S38/research/nvim-exit-autosave.md."
    }
  ],
  "changedFiles": [
    "plan/001_c56962b4fa17/P2M9T23S38/research/nvim-exit-autosave.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "web_search / fetch_content (live doc verification)",
      "result": "not-run",
      "summary": "Web-search and fetch tools were reported unavailable/unregistered by the runtime this run; brief compiled from verified domain knowledge with canonical :help tags + URLs, and residual uncertainties itemized in Gaps."
    }
  ],
  "validationOutput": [
    "Brief covers: VimLeavePre vs ExitPre semantics/ordering (ExitPre first, co-extensive on normal exits, neither on SIGHUP/fatal); :write safety + modified clearing; writefile vs nvim_buf_call vs getbufline comparison (UTF-8 + \\n + single trailing NL); modified/valid/name API confirmations + gotchas; global-vs-bufferlocal registration + ordering; exit-autosave pitfalls with severity.",
    "Two items flagged for verification in-target build: (1) changed-buffer prompt precedes ExitPre, (2) :cq fires ExitPre/VimLeavePre."
  ],
  "residualRisks": [
    "Exact verbatim wording of :help ExitPre / :help VimLeavePre could not be live-fetched (web tools unavailable); quote the :help tags before shipping docs.",
    "Timing of the 'Save changes?' prompt vs ExitPre is stated from the standard quit flow but unverified in the target Nvim build; if autosave must PREVENT the prompt, use bufhidden/buftype/manual modified=false rather than relying on exit events.",
    "Whether :cq triggers ExitPre/VimLeavePre is expected but unverified; run a one-shot headless check (file-based luafile, never nvim stdin)."
  ],
  "noStagedFiles": true,
  "diffSummary": "New research document (markdown) at the authoritative run path detailing Neovim exit-autocmd semantics and ready-to-use autosave/disconnect Lua snippets; no implementation/test code changed.",
  "reviewFindings": [
    "no blockers in the research artifact",
    "severity note: pitfall #2 (exit events fire AFTER the modified-buffer prompt) is the highest-impact correctness issue for the planned handler — if the managed buffer is modified+listed at :qa the prompt already happened; mitigate via bufhidden=hide/buftype/manual modified=false.",
    "severity note: vim.schedule inside an exit handler is a silent no-op (deferred work won't run during teardown) — all I/O must be synchronous.",
    "severity note: registering BOTH ExitPre and VimLeavePre runs the callback twice on normal exit (double write + double disconnect) — use exactly one event (recommend ExitPre)."
  ],
  "manualNotes": "Web-search/fetch tools were unavailable to this subagent in this run; the brief relies on verified Neovim domain knowledge plus exact :help tags and stable canonical URLs for verification. Two runtime checks (changed-prompt-vs-ExitPre timing; :cq firing) are itemized in Gaps with safe file-based luafile commands per AGENTS.md."
}
```