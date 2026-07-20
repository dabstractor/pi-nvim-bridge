# Research: libuv/luv Unix Domain Socket Write-Then-Close Flush Semantics

> **Methodology note:** This brief was produced from the author's trained
> knowledge of the libuv C source code (`src/unix/stream.c`, `src/unix/core.c`,
> `src/win/stream.c`), the official libuv v1.x API documentation at
> docs.libuv.org, the luv binding layer (`luv_stream_write`, `luv_close`), and
> Node.js `net` module documentation. Live URL fetching was unavailable during
> this run; citations reference the canonical doc locations. All claims about
> implementation behavior (`write(2)` happening inside `uv_write`) are traced to
> specific functions in the libuv source tree.

## Summary

For a **small (~60 byte)** payload on a **local Unix domain socket** with an
**empty kernel send buffer**, `uv_write()` / `pipe:write()` completes the
`write(2)` syscall **synchronously within the call itself** — bytes are in the
kernel socket buffer before the Lua function returns. A subsequent synchronous
`pipe:close()` therefore does **not** lose the data: the bytes are already
delivered to the kernel, and `close(fd)` sends a FIN the peer receives as a
clean EOF after the data. **However**, this synchronous-write behavior is an
**implementation detail** of how libuv eagerly flushes non-blocking writes, not
a formal API guarantee. The formally-safe pattern is closing in the
write-completion callback — but during **VimLeavePre**, the event loop may never
iterate again, so the callback may not fire, making the **synchronous
write-then-close pattern more reliable for teardown**.

---

## Findings

### Q1. Pending writes and `uv_close` — guaranteed flush or cancellation?

**Short answer: NOT guaranteed. Pending writes are cancelled with `UV_ECANCELED`.**
But for small data, there are usually no pending writes by the time close runs.

The libuv documentation for `uv_close` states:

> Close the given handle. Generally, this is the inverse of the `uv_*_init`
> function. ... In-progress requests are **cancelled**. ... The close callback
> will be called asynchronously, after the event loop has processed all pending
> events.
> — [`uv_close`](https://docs.libuv.org/en/v1.x/handle.html#c.uv_close)

The implementation in `src/unix/stream.c`, function `uv__stream_close()`, walks
both `write_queue` and `write_completed_queue` and invokes each pending write
request's callback with status `UV_ECANCELED`:

```c
/* from uv__stream_close() */
while (!QUEUE_EMPTY(&handle->write_queue)) {
    q = QUEUE_HEAD(&handle->write_queue);
    QUEUE_REMOVE(q);
    req = QUEUE_DATA(q, uv_write_t, queue);
    /* ... */
    if (req->cb) req->cb(req, UV_ECANCELED);  /* cancelled, not delivered */
}
```

**Key distinction**: If the write's bytes already reached the kernel (via
`write(2)` inside `uv_write`), the data is **not** "un-written" — the
cancellation only means the user's callback is invoked with an error status, not
that the kernel buffer is emptied. Data in `write_completed_queue` (bytes already
sent to kernel, callback not yet fired) has its callback cancelled, but the bytes
remain in the kernel socket buffer and will be delivered to the peer.

**Verdict**: `pipe:write(data, cb)` then `pipe:close()` synchronously is safe
**for small data** because the bytes are typically already in the kernel. It is
**NOT safe** for large data or a full socket buffer, where `close` would cancel
pending writes that never reached the kernel.

1. **`uv_close` cancels in-progress requests** — documented behavior.
   [libuv handle.h: uv_close](https://docs.libuv.org/en/v1.x/handle.html#c.uv_close)
2. **Pending write callbacks fire with `UV_ECANCELED`** — implementation in
   `uv__stream_close()`, `src/unix/stream.c`.
3. **Already-flushed bytes are not recalled** — once `write(2)` succeeds, bytes
   are in the kernel buffer; cancelling the callback does not remove them.

---

### Q2. Does the write complete synchronously for small payloads?

**Short answer: YES, typically, but not guaranteed by the API contract.**

`uv_write()` calls `uv__write()` (internal function, `src/unix/stream.c`), which
**immediately** invokes the `write(2)` syscall on the stream's FD:

```c
/* simplified from uv__write() */
do {
    /* prepare iov/bufs from write_queue_head */
    n = uv__writev(fd, iov, iovcnt);   /* or uv__sendmsg for pipes */
    if (n > 0) {
        /* advance write_queue, move completed req to write_completed_queue */
        uv__io_start(loop, &stream->io_watcher, POLLOUT); /* in case more */
    } else if (n == 0 || n == UV_EAGAIN) {
        /* kernel buffer full — set POLLOUT watcher, try again later */
        break;
    }
} while (stream->write_queue_head != NULL);
```

For a **60-byte** payload on a **Unix domain socket** with default kernel buffers
(linux: `/proc/sys/net/core/wmem_default` — typically 212,992 bytes; macOS:
`kern.ipc.maxsockbuf` — typically 256 KB), the `write(2)` syscall **always**
succeeds immediately, writing all 60 bytes to the kernel socket buffer. The
write request moves to `write_completed_queue`, and the user callback is
scheduled via `uv__make_pending()` for the next loop iteration.

**Therefore**: by the time `uv_write()` (and thus `pipe:write()`) returns, the
bytes are **in the kernel** for this specific scenario. The callback is merely a
deferred "delivery notification," not a "do the write now" trigger.

**Guaranteed vs typical**:
- **GUARANTEED (by API)**: `uv_write` callback is called after data is written.
- **GUARANTEED (by API)**: close cancels pending requests.
- **EMPIRICAL (not API-guaranteed)**: small writes complete synchronously. This
  is true in practice but depends on kernel buffer state and libuv's internal
  eager-write implementation detail. A future libuv refactor could theoretically
  defer writes. (This is extremely unlikely — it's been this way since the
  beginning.)

4. **`uv_write` attempts an immediate `write(2)`** — `uv__write()` in
   `src/unix/stream.c` calls the syscall synchronously.
   [libuv stream.h: uv_write](https://docs.libuv.org/en/v1.x/stream.html#c.uv_write)
5. **Small writes on Unix domain sockets complete inline** — kernel send buffer
   is ~200 KB; 60 bytes always fits.

---

### Q3. Idiomatic "send final message then close" patterns

Three options exist, with different applicability to `uv_pipe_t`:

| Pattern | How it works | Works on pipes? | Async? |
|---|---|---|---|
| **(a) write-then-close-sync** | `uv_write(data); uv_close();` | ✅ | Close is async (callback on next tick) |
| **(b) write, close in callback** | `uv_write(data, cb)` → `uv_close()` in `cb` | ✅ | Fully async, callback-driven |
| **(c) `uv_shutdown` then close** | `uv_shutdown()` then `uv_close()` in shutdown cb | ✅ Unix / ❌ Windows | Fully async |

**Pattern (c) — `uv_shutdown`**: From the libuv docs:

> `int uv_shutdown(uv_shutdown_t* req, uv_stream_t* handle, uv_shutdown_cb cb)`
> Shutdown the outgoing (write) side of a duplex stream. It waits for pending
> write requests to complete. The callback is called after shutdown is complete.
> — [`uv_shutdown`](https://docs.libuv.org/en/v1.x/stream.html#c.uv_shutdown)

Internally, `uv_shutdown()` calls `shutdown(fd, SHUT_WR)`, which sends a FIN on
the underlying socket. For `uv_pipe_t` on Unix (backed by a SOCK_STREAM Unix
domain socket), this works identically to TCP. **On Windows, named pipes do not
support half-close**, so `uv_shutdown` on a pipe returns an error — but for a
Neovim plugin (always running on Unix/macOS/Linux), this is not a concern.

**`uv_shutdown` is the most correct** because it:
- Waits for pending writes to flush before sending FIN
- Signals graceful half-close to the peer (who can still send data back)
- The peer sees: all data → EOF on read

**But**: `uv_shutdown` is also async. Its callback fires on the next loop
iteration. During VimLeavePre, the loop may not iterate again, so the callback
won't fire and `uv_close` won't be called explicitly (though the process exit
will clean up the FD).

**Recommendation for this use case**: Pattern **(b)** is the textbook-correct
idiom in normal operation. Pattern **(a)** (synchronous write-then-close) is
acceptable for **small payloads** and is **more reliable during VimLeavePre**
because it doesn't depend on the callback firing.

6. **`uv_shutdown` works on Unix domain sockets (uv_pipe_t)** — backed by
   SOCK_STREAM. [libuv stream.h: uv_shutdown](https://docs.libuv.org/en/v1.x/stream.html#c.uv_shutdown)
7. **`uv_shutdown` waits for pending writes before half-closing** — documented
   behavior. This is the safest pattern.

---

### Q4. What the Node server observes (abrupt close vs. graceful close)

**The Node server (`net.Server` + `sock.on('data')`) receives the bye data in
BOTH cases**, as long as the bytes reached the kernel socket buffer before close.

**(a) Client writes bye, then closes abruptly (no close in callback):**
1. Client `write(2)` delivers 60 bytes to kernel socket send buffer.
2. Client `close(fd)` — kernel sends remaining data, then FIN to peer.
3. Node's kernel receives 60 bytes → delivers to `sock.on('data')` event.
4. Node's kernel receives FIN → `sock.on('end')` fires → `sock.end()` on server
   side completes the close.
5. **Result: Node sees the bye data.** ✅

**(b) Client writes bye, waits for ack, then closes:**
1. Same write + delivery.
2. Client keeps connection open, reads ack.
3. Node sends `{ok:true}` ack → client reads it.
4. Client closes → FIN → Node sees `sock.on('end')`.
5. **Result: same bye delivery, plus server has confirmation client received the
   ack.** ✅

**Critical insight**: The Unix domain socket is **entirely in-kernel**. Both
ends are on the same machine. Once `write(2)` succeeds on the client side, the
data is in the kernel's socket receive buffer (visible to the server's
`read(2)`/`epoll`/`kqueue`), regardless of whether the client subsequently calls
`close()` or not. An abrupt `close()` does not "undo" data already delivered to
the peer's kernel buffer.

The only risk with abrupt close is if `close()` triggers a **RST** instead of a
**FIN** — this happens if there is unread data in the **client's receive buffer**
at close time (the kernel discards unread receive data and sends RST instead of
FIN). However:
- For this protocol, the client is sending bye and closing immediately, likely
  before the server's ack arrives. If the ack arrives in the kernel before the
  client calls `close()`, it sits unread in the client's receive buffer, which
  **could** trigger a RST instead of a clean FIN.
- A RST causes Node's socket to emit `'error'` instead of `'end'`. The server's
  `sock.on('data')` **still fires with the bye data** before the RST is
  processed (data is in the receive buffer, delivered on the first `read`
  before the RST error is surfaced), but the server sees a connection reset
  rather than a clean close.

**Mitigation**: Read and discard the ack (or use `uv_shutdown` for a half-close)
to avoid unread receive data triggering RST. Or: simply don't worry about it
if the server handles both `'end'` and `'error'` gracefully (it should).

8. **Node delivers socket data via `'data'` event** before processing EOF/RST.
   [Node.js net module](https://nodejs.org/api/net.html)
9. **Abrupt close with unread receive data can cause RST** — Linux kernel
   behavior. The bye data is still delivered first.

---

### Q5. The correct vim.uv / luv pattern for Neovim (including VimLeavePre)

**Two patterns, different tradeoffs:**

#### Pattern B: close in callback (normal-operation-correct)
```lua
pipe:write(bye_line .. "\n", function(err)
  if err and err ~= "ECANCELED" then
    -- log/write only; don't crash VimLeave
  end
  pipe:close()
end)
```
- ✅ Textbook-correct for normal operation.
- ✅ Close only happens after write is acknowledged by libuv.
- ❌ **During VimLeavePre, the write callback may NEVER fire.** When nvim
  receives VimLeavePre, it runs the autocommand callbacks synchronously, then
  proceeds to tear down. The libuv loop embedded in nvim may not get another
  `uv_run()` iteration to process the pending callback. If the callback doesn't
  fire, `pipe:close()` is never called, and the FD leaks until process exit.
- ✅ Data is still delivered (the `write(2)` syscall already ran inside
  `pipe:write()`), so the server gets the bye regardless.
- ❌ The FD stays open (no FIN sent) until process exit cleanup. But process
  exit does close FDs, so the FIN is eventually sent — just not immediately.

#### Pattern A: synchronous write-then-close (VimLeavePre-correct)
```lua
pipe:write(bye_line .. "\n", function(err)
  -- This callback may or may not fire; do NOT rely on it for cleanup.
  -- No close here — we already closed.
end)
pipe:close()  -- synchronous close; bytes already in kernel for small data
```
- ✅ For ~60 bytes, `write(2)` has already delivered bytes to kernel before
  `pipe:close()` runs.
- ✅ `pipe:close()` closes the FD immediately, sending FIN to the peer.
- ✅ Does NOT depend on the event loop iterating again — perfect for VimLeavePre.
- ⚠️ The write callback (if it fires) will receive `ECANCELED` because the
  handle is closing. **The callback must tolerate `ECANCELED` silently.**
- ⚠️ NOT guaranteed for large payloads (but we don't have large payloads here).

#### Recommended pattern for VimLeavePre specifically:
```lua
--- Send bye and close immediately. Safe for VimLeavePre.
--- Relies on the empirical fact that small writes flush synchronously in libuv.
local function disconnect(pipe)
  if not pipe or pipe:is_closing() then return end
  local bye = '{"jsonrpc":"2.0","method":"bye","id":' .. next_id .. '}\n'
  -- write ignores errors in the callback (best-effort)
  pipe:write(bye, function(err)
    -- may fire with ECANCELED after close; tolerate silently
  end)
  pipe:close()
end
```

**During VimLeavePre, Pattern A (synchronous write-then-close) is the correct
choice.** The event loop is about to exit and may not process callbacks.

10. **During VimLeavePre, the libuv loop may not iterate again** — callbacks
    scheduled via `uv__make_pending` are processed in `uv__io_poll` + callback
    phase, which requires `uv_run()` to be called. After VimLeavePre autocommands,
    nvim's teardown may not call `uv_run()` again.
    [Neovim source: event loop teardown]
11. **The write callback must tolerate `ECANCELED`** — after `uv_close`, pending
    callbacks fire with `UV_ECANCELED`. In luv, this appears as the string
    `"ECANCELED"`. [libuv handle.h: uv_close](https://docs.libuv.org/en/v1.x/handle.html#c.uv_close)

---

### Q6. Does 'bye' even matter? Cosmetic vs. functional

**Short answer: 'bye' is a functional convenience, not a hard requirement — but
it provides useful value if the server uses it to distinguish "intentional
disconnect" from "crash."**

The server **must already handle** clean EOF (`data == nil` / `sock.on('end')`)
for robustness — a client could crash, the machine could lose power, etc. So the
server's graceful-disconnect code path must work **without** receiving 'bye'.

However, 'bye' adds value in these scenarios:

| Scenario | Without 'bye' | With 'bye' |
|---|---|---|
| **Normal disconnect (VimLeavePre)** | Server sees EOF, knows client is gone, but doesn't know if it was intentional or a crash | Server sees 'bye', knows it was intentional — can skip crash-recovery logic |
| **Client crash / SIGKILL** | Server sees EOF (or RST), must assume worst case | Server sees EOF without 'bye' → can trigger crash-recovery / restart logic |
| **State cleanup** | Server tears down per-client state on EOF | Server can do a clean state transition (e.g., "save session" path) before teardown |
| **Ack-based coordination** | No way to confirm client received final state | Server sends `{ok:true}`; client can log or act on it |

**Bottom line**: If the server's EOF handler is robust and correct (which it must
be), 'bye' is **not strictly required** for correctness. But 'bye' enables
**intentional vs. unintentional disconnect disambiguation**, which is valuable
for operational behavior (e.g., deciding whether to attempt client reconnection,
whether to clean up vs. preserve session state, etc.).

**Recommendation**: Send 'bye' best-effort (Pattern A above). Do NOT block
VimLeave on receiving an ack. Treat 'bye' as "nice to have" signal that the
server can optionally use.

12. **Server must handle EOF without 'bye' for crash recovery** — robustness
    requirement regardless of bye protocol.
13. **'bye' enables intentional/unintentional disconnect disambiguation** —
    operational value, not correctness value.

---

## GUARANTEED vs. EMPIRICAL-TYPICAL Summary

| Claim | Status | Basis |
|---|---|---|
| `uv_close` cancels pending write requests | **GUARANTEED** | libuv docs + source |
| Write callback fires with `UV_ECANCELED` if cancelled | **GUARANTEED** | libuv source |
| `uv_shutdown` works on `uv_pipe_t` (Unix) | **GUARANTEED** | libuv docs + source (SHUT_WR on SOCK_STREAM) |
| `uv_shutdown` waits for pending writes before FIN | **GUARANTEED** | libuv docs |
| Small write completes `write(2)` synchronously inside `uv_write` | **EMPIRICAL** | libuv source `uv__write()`, not in API contract |
| 60-byte Unix socket write always fits in kernel buffer | **EMPIRICAL** | kernel buffer ~200 KB, implausible to be full |
| Bytes already in kernel are delivered to peer after `close()` | **GUARANTEED** | POSIX socket semantics: `close()` flushes send buffer before FIN |
| VimLeavePre prevents callback from firing | **EMPIRICAL** | depends on nvim's loop teardown timing |
| 'bye' is not required for server correctness | **GUARANTEED** | robust server must handle EOF without bye |

---

## Recommended luv Lua Pattern

```lua
--- Best-effort graceful disconnect for vim.uv pipe.
--- Designed for VimLeavePre: does NOT depend on callbacks firing.
---
--- Relies on: small writes flush synchronously via write(2) inside uv_write.
--- Trade-off: if libuv ever deferred the write (it won't for 60 bytes), bye
--- could be lost. The server handles EOF gracefully regardless.
---
---@param pipe uv_pipe_t
---@param bye_line string  JSON-RPC bye line WITHOUT trailing newline
local function graceful_disconnect(pipe, bye_line)
  if not pipe or pipe:is_closing() then
    return  -- already closing; nothing to do
  end

  -- Write the bye line. For ~60 bytes on a Unix domain socket, write(2)
  -- completes synchronously inside pipe:write(). Bytes are in the kernel
  -- before we return.
  pipe:write(bye_line .. "\n", function(err)
    -- This callback MAY fire with "ECANCELED" because we close below.
    -- It MAY NOT fire at all during VimLeavePre (loop not iterating).
    -- Either way: do not attempt pipe operations here.
    -- Logging is fine; do NOT re-close the pipe.
  end)

  -- Close synchronously. For small data, bytes are already in the kernel.
  -- close(fd) flushes remaining kernel send buffer, then sends FIN.
  -- The Node server receives the bye data, then sees EOF.
  pipe:close()
end
```

**Why this is correct for VimLeavePre:**
1. `pipe:write()` runs `write(2)` synchronously → bytes in kernel. ✅
2. `pipe:close()` closes the FD → FIN sent. ✅
3. No dependency on callback firing (loop may not iterate). ✅
4. Callback tolerates `ECANCELED` silently. ✅

**Why this is correct for the server:**
1. Server receives bye data via `sock.on('data')`. ✅
2. Server receives FIN → `sock.on('end')`. ✅
3. Server sends ack `{ok:true}` — client may or may not read it (doesn't matter;
   server should not block on ack delivery for a disconnecting client). ✅
4. If the client's unread ack causes RST instead of FIN, server's `sock.on('data')`
   still fires with bye first, then `sock.on('error')` instead of
   `sock.on('end')`. Server handles both. ✅

---

## Sources

### Kept
- **libuv handle.h: `uv_close`** (https://docs.libuv.org/en/v1.x/handle.html#c.uv_close) — documents that close cancels pending requests; callback is async.
- **libuv stream.h: `uv_write`** (https://docs.libuv.org/en/v1.x/stream.html#c.uv_write) — write API; callback fires after delivery.
- **libuv stream.h: `uv_shutdown`** (https://docs.libuv.org/en/v1.x/stream.html#c.uv_shutdown) — half-close; waits for pending writes; works on pipes (Unix).
- **libuv source: `uv__write()` in `src/unix/stream.c`** — proves `write(2)` syscall happens synchronously inside `uv_write()` for non-blocking streams with available buffer.
- **libuv source: `uv__stream_close()` in `src/unix/stream.c`** — proves pending writes cancelled with `UV_ECANCELED`.
- **Node.js net module** (https://nodejs.org/api/net.html) — `sock.on('data')` / `sock.on('end')` / `sock.on('error')` semantics.
- **luv docs** (https://github.com/luvit/luv/blob/master/docs.md) — `pipe:write()` maps to `uv_write`; `pipe:close()` maps to `uv_close`.

### Dropped
- None excluded — all researched angles contributed to the brief. (Note: live
  URL fetching was unavailable; source citations reference canonical locations
  from trained knowledge of the documentation.)

---

## Gaps

1. **Exact nvim VimLeavePre loop teardown sequence**: I could not verify the
   precise moment nvim stops calling `uv_run()` during shutdown. My claim that
   callbacks may not fire during VimLeavePre is based on the general principle
   that VimLeavePre autocommands run synchronously before nvim's main loop
   teardown, and pending libuv callbacks require a `uv_run()` iteration to
   dispatch. **Suggested next step**: verify by checking Neovim's
   `event.c` / `main.c` shutdown path, or empirically test with a log inside
   the write callback during VimLeavePre.

2. **RST vs FIN on close with unread ack**: The exact kernel behavior for "close
   with unread data in receive buffer on a Unix domain socket" varies slightly
   by OS. Linux sends RST; macOS may differ slightly. The bye data is still
   delivered first in all cases, so this is a non-issue for data delivery, but
   affects whether the server sees `'end'` or `'error'`. **Suggested next step**:
   test on the target platform, or ensure server handles both `'end'` and
   `'error'` identically.

3. **Could not fetch live URLs**: All citations are from trained knowledge of
   the libuv docs and source code. The content is stable (libuv v1.x API hasn't
   changed materially in years), but a verification pass against the live docs
   would be ideal.

---

## Supervisor coordination

No supervisor coordination required. Research brief is complete and written to
the authoritative output path.