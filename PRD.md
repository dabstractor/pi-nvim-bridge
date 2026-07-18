# Pi External‑Editor Completion — Spec & Implementation Guide

> Bring pi's in‑prompt completion (slash commands, `skill:` commands, prompt
> templates, command argument completion, `@file` mentions, and path completion)
> into the **Neovim instance pi launches as `$EDITOR`**, using Neovim's own
> completion UI conventions and pi's live autocomplete engine.

This document specifies two cooperating components:

1. **`pi-editor-bridge`** — a pi **TypeScript extension** that exposes pi's live
   `AutocompleteProvider` over a local socket.
2. **`pi-editor.nvim`** — a **Neovim (Lua) plugin** that activates only inside a
   pi editor session, connects to the bridge, and renders completion through a
   dependency‑free floating menu (with optional blink.cmp / nvim‑cmp sources).

---

## Table of Contents

1. [Goals & Non‑Goals](#1-goals--non-goals)
2. [Background: How pi Launches `$EDITOR` and Does Completion](#2-background-how-pi-launches-editor-and-does-completion)
3. [Architecture Overview](#3-architecture-overview)
4. [The Core Technique](#4-the-core-technique)
5. [IPC Protocol](#5-ipc-protocol)
6. [Component A — `pi-editor-bridge` (pi extension)](#6-component-a--pi-editor-bridge-pi-extension)
7. [Component B — `pi-editor.nvim` (Neovim plugin)](#7-component-b--pi-editornvim-neovim-plugin)
8. [Coordinate & Encoding Contract](#8-coordinate--encoding-contract)
9. [File Layouts](#9-file-layouts)
10. [Installation & Configuration](#10-installation--configuration)
11. [Edge Cases, Failure Modes & Limitations](#11-edge-cases-failure-modes--limitations)
12. [Security](#12-security)
13. [Implementation Plan (Phased)](#13-implementation-plan-phased)
14. [Testing Strategy](#14-testing-strategy)
15. [Future Enhancements](#15-future-enhancements)
16. [Reference: Key pi Source Locations](#16-reference-key-pi-source-locations)

---

## 1. Goals & Non‑Goals

### Goals

- When pi opens `$EDITOR` (Neovim) to edit a prompt, that Neovim instance gets:
  - **Slash command** completion: `/model`, `/compact`, `/skill:…`, prompt
    templates, and registered extension commands — with descriptions and
    argument hints.
  - **Command argument** completion where pi supports it (e.g. `/model
    <provider/id>`, `/login <provider>`).
  - **`@file` mention** completion using pi's exact fuzzy/`fd` logic
    (gitignore‑aware, scored, scoped).
  - **Path** completion (bare paths, `./…`, `~/…`, `/abs`) identical to pi.
  - **Tab to force file completion**, matching pi's `shouldTriggerFileCompletion`.
- Completion behavior in Neovim is **byte‑for‑byte identical** to pi's TUI,
  because the *same live provider* produces and applies the suggestions.
- **No third‑party Neovim dependencies required** for the primary experience
  (self‑contained floating menu). Integration with the user's existing
  completion engine is optional.
- The Neovim plugin is **dormant** in normal Neovim use and activates only when
  pi launches the editor.

### Non‑Goals (v1)

- Replacing pi's TUI editor itself.
- Providing completions in editors other than Neovim.
- Streaming pi events / chat UI into Neovim (that is RPC mode's job).
- Syntax highlighting or rendering of pi's chat (the buffer is plain markdown).
- Submitting the prompt from Neovim by any means other than **save + quit**
  (pi re‑reads the temp file only after the editor exits — see §2).

---

## 2. Background: How pi Launches `$EDITOR` and Does Completion

This is the established behavior the design builds on. All verified against
`~/projects/pi` (pi monorepo, `packages/coding-agent` + `packages/tui`).

### 2.1 Editor launch (interactive TUI mode)

`InteractiveMode.openExternalEditor()` (bound to the `app.editor.external`
keybinding, default **`Ctrl+G`**):

```ts
const editorCmd = this.settingsManager.getExternalEditorCommand(); // settings.externalEditor || $VISUAL || $EDITOR
const tmpFile = path.join(os.tmpdir(), `pi-editor-${Date.now()}.pi.md`);
fs.writeFileSync(tmpFile, currentText, "utf-8");
this.ui.stop();                                  // release terminal (alt screen)
const [editor, ...editorArgs] = editorCmd.split(" ");
const child = spawn(editor, [...editorArgs, tmpFile], {
  stdio: "inherit",
  shell: process.platform === "win32",
});
// ...waits for exit...
if (status === 0) {
  const newContent = fs.readFileSync(tmpFile, "utf-8").replace(/\n$/, "");
  this.editor.setText(newContent);
}
```

Critical facts this gives us:

1. The child editor **inherits `process.env`** (no `env:` option). Anything an
   extension writes to `process.env.*` **before** the launch is visible to the
   editor. **This is the discovery that makes the whole design work.**
2. The editor runs only **while the TUI is stopped** (alternate screen), so there
   is no terminal‑input contention. A background socket server in pi's process is
   free to run concurrently.
3. The temp file is named **`pi-editor-<ts>.pi.md`** (main editor) or
   **`pi-extension-editor-<ts>.md`** (the modal editor from `ctx.ui.editor()`).
   Both code paths inherit `process.env` and both launch via the same pattern.
4. pi **reads the file back only after the editor exits with status 0**, trimming
   one trailing newline. There is no live sync — see §11 for the "autosave on
   quit" implication.

### 2.2 The autocomplete engine

pi's completion lives in `packages/tui/src/autocomplete.ts`:

```ts
export interface AutocompleteItem { value: string; label: string; description?: string; }

export interface AutocompleteSuggestions { items: AutocompleteItem[]; prefix: string; }

export interface AutocompleteProvider {
  triggerCharacters?: string[];
  getSuggestions(
    lines: string[], cursorLine: number, cursorCol: number,
    options: { signal: AbortSignal; force?: boolean },
  ): Promise<AutocompleteSuggestions | null>;
  applyCompletion(
    lines: string[], cursorLine: number, cursorCol: number,
    item: AutocompleteItem, prefix: string,
  ): { lines: string[]; cursorLine: number; cursorCol: number };
  shouldTriggerFileCompletion?(lines: string[], cursorLine: number, cursorCol: number): boolean;
}
```

`CombinedAutocompleteProvider` is the concrete provider pi builds in
`InteractiveMode.createBaseAutocompleteProvider()`. It is constructed from:

- **builtin** slash commands (`BUILTIN_SLASH_COMMANDS`: `/model`, `/compact`, …),
- **prompt templates** (`.pi/prompts`, …),
- **extension commands** (`pi.registerCommand(...)`, with their
  `getArgumentCompletions`),
- **skill commands** (`/skill:<name>` when `enableSkillCommands` is on),
- the session **cwd**,
- the **`fd`** binary path (for fuzzy `@file` search),

and it owns all the `@`/path/`fd` logic. After construction it is wrapped by any
`addAutocompleteProvider` factories and assigned to the editor via
`setupAutocompleteProvider()`.

### 2.3 The public hook we exploit

`ExtensionUIContext.addAutocompleteProvider(factory)` — the factory receives
`current: AutocompleteProvider` (the live, fully‑built chain) and returns a
provider. A pass‑through factory lets us **capture a reference to the live
provider without changing any behavior**:

```ts
ctx.ui.addAutocompleteProvider((current) => { liveProvider = current; return current; });
```

This is the single cleanest public seam to reach pi's completion logic from an
extension. It gives us **everything** the TUI sees — slash commands, skills,
templates, dynamic argument completions, and `@file`/path logic — for free.

---

## 3. Architecture Overview

```
 ┌──────────────────────── pi process (Node) ─────────────────────────┐
 │                                                                     │
 │  InteractiveMode  ──► openExternalEditor()  ──► spawn($EDITOR …)    │
 │         ▲                                       (inherits process.env)│
 │         │                                                           │
 │   CombinedAutocompleteProvider  ◄── captured by ──┐                 │
 │                                                    │                 │
 │   pi-editor-bridge (extension)  ──────────────────┘                 │
 │     • session_start  ──► net.createServer on Unix socket            │
 │     • sets process.env.PI_EDITOR_BRIDGE = {path, token, pid, …}     │
 │     • JSONL RPC: getSuggestions / applyCompletion / shouldTrigger…  │
 │     • session_shutdown ──► server.close() + unlink socket           │
 │                                                                     │
 └───────────────────────────│─────────────────────────────────────────┘
                              │ Unix domain socket (or TCP loopback)
                              │ newline-delimited JSON (JSONL) with id correlation
 ┌───────────────────────────▼─────────────────────────────────────────┐
 │  nvim (the $EDITOR child)  ◄── loads pi-editor.nvim                  │
 │     • VimEnter: vim.env.PI_EDITOR_BRIDGE present? → activate         │
 │     • bridge.lua: luv pipe client, handshake (token), RPC dispatch   │
 │     • completion.lua: triggers, debounce, accept flow                │
 │     • menu.lua: dependency-free floating completion popup            │
 │     • ExitPre/VimLeavePre: autosave (so pi reads the latest prompt)  │
 └──────────────────────────────────────────────────────────────────────┘
```

Two processes, one local socket, one JSONL protocol. No shared state beyond the
temp file pi already manages.

---

## 4. The Core Technique

Step‑by‑step, this is how the two halves cooperate:

1. **Bridge captures the live provider.** On `session_start`, the extension
   registers a pass‑through `addAutocompleteProvider` factory that stashes
   `current` in a module‑level variable (`liveProvider`). Because the bridge
   registers early (during `session_start`), `current` is at minimum the
   `CombinedAutocompleteProvider` — i.e. slash commands + skills + templates +
   paths. (Wrappers registered *after* ours won't be visible; see §11.)

2. **Bridge opens a local server and advertises it via `process.env`.** It binds
   a Unix domain socket at `os.tmpdir()/pi-editor-bridge-<rand>.sock`, generates
   a random secret token, and writes a single‑line JSON descriptor to
   `process.env.PI_EDITOR_BRIDGE`:

   ```json
   {"transport":"unix","path":"/tmp/pi-editor-bridge-xxxx.sock","token":"<32 hex>","pid":12345,"cwd":"/home/u/proj","fdAvailable":true,"version":"0.0.1"}
   ```

   Because the editor is spawned with `stdio:"inherit"` and no `env`, the child
   Neovim **sees `PI_EDITOR_BRIDGE`**.

3. **Neovim activates only when the env var is set.** On `VimEnter`, the plugin
   reads & `vim.json.decode`s `PI_EDITOR_BRIDGE`. If absent/unparseable → do
   nothing (plugin stays dormant — this is why it is safe to ship in a normal
   config). If present → start the bridge client for the current buffer.

4. **Neovim queries the live provider.** As the user types, the plugin sends
   `getSuggestions(lines, cursorLine, cursorCol)` over the socket. The bridge
   forwards to `liveProvider.getSuggestions(...)` and returns the result. The
   plugin renders the items in a floating menu.

5. **Accept delegates to pi.** When the user accepts an item, the plugin sends
   `applyCompletion(...)`; the bridge forwards to
   `liveProvider.applyCompletion(...)`, which returns the **new full buffer lines
   + cursor**. The plugin replaces the buffer and positions the cursor.
   Insertion rules (trailing space for files, no space for directories, quote
   handling, `/cmd ` for commands) are therefore exactly pi's.

6. **Teardown.** Neovim closes the socket on `VimLeavePre`. pi closes + unlinks
   the socket on `session_shutdown` (and on process exit).

---

## 5. IPC Protocol

### 5.1 Transport

- **Primary: Unix domain socket** (`net.createServer` + `listen(path)` on the pi
  side; `vim.uv.new_pipe()` + `:connect(path)` on the Lua side).
  - Socket path: `${os.tmpdir()}/pi-editor-bridge-${crypto.randomUUID()}.sock`
  - Created with restrictive permissions (`0o600`); the token (§12) is the real
    auth boundary.
- **Future/Windows: TCP loopback.** Same JSONL framing; descriptor
  `"transport":"tcp","host":"127.0.0.1","port":…`. Out of scope for v1 on Linux
  but the protocol is transport‑agnostic.

### 5.2 Framing

**Newline‑delimited JSON (JSONL).** Exactly one JSON object per line, delimited
by `\n` only. (Mirror pi RPC's framing rules: split on `\n`, strip an optional
trailing `\r`, do **not** use readers that split on U+2028/U+2029.) Both sides
must buffer partial lines and decode on `\n`.

### 5.3 Connection lifecycle & handshake

1. Client connects.
2. Client sends the **hello** line immediately:
   `{"jsonrpc":"2.0","method":"hello","id":"h1","params":{"token":"…","client":"pi-editor.nvim","clientVersion":"…"}}`
3. Server validates `token` against its own; replies
   `{"jsonrpc":"2.0","id":"h1","result":{"ok":true,"serverVersion":"…","cwd":"…","fdAvailable":true}}`.
   On mismatch → `{"jsonrpc":"2.0","id":"h1","error":{"code":-32600,"message":"bad token"}}`
   then close.
4. After a successful handshake, normal request/response RPC proceeds. A second
   client may connect to the same socket; the server must support **at least
   one** concurrent connection (multiplex by `id`). (Two simultaneous editors are
   rare; supporting one robustly is the bar.)

Use JSON‑RPC 2.0 envelopes for future‑proofing:

```jsonc
// Request
{"jsonrpc":"2.0","id":"<string>","method":"<name>","params":{…}}
// Response (success)
{"jsonrpc":"2.0","id":"<string>","result":{…}}
// Response (error)
{"jsonrpc":"2.0","id":"<string>","error":{"code":<int>,"message":"<str>"}}
// Notification (server→client, no id, no reply expected)
{"jsonrpc":"2.0","method":"<name>","params":{…}}
```

### 5.4 Methods

| Method | Direction | Params | Result |
|---|---|---|---|
| `hello` | C→S | `{token, client?, clientVersion?}` | `{ok, serverVersion, cwd, fdAvailable}` |
| `ping` | C→S | `{}` | `{ok, pid, cwd, fdAvailable, serverVersion}` |
| `getSuggestions` | C→S | `{lines:string[], cursorLine:int, cursorCol:int, force?:bool}` | `AutocompleteSuggestions \| null` |
| `applyCompletion` | C→S | `{lines, cursorLine, cursorCol, item, prefix}` | `{lines, cursorLine, cursorCol}` |
| `shouldTriggerFileCompletion` | C→S | `{lines, cursorLine, cursorCol}` | `bool` |
| `getCommands` | C→S | `{}` | `{commands: CommandInfo[]}` *(optional, for richer docs menus)* |
| `commandsChanged` | S→C | `{}` *(notification)* | — |
| `bye` | C→S | `{}` | `{ok:true}` *(graceful disconnect)* |

`AutocompleteSuggestions` and `AutocompleteItem` match pi's types exactly:

```jsonc
// AutocompleteItem
{ "value": "@/src/comp.ts", "label": "comp.ts", "description": "src/comp.ts" }
// AutocompleteSuggestions
{ "items": [ /* AutocompleteItem[] */ ], "prefix": "@/src/comp" }
```

### 5.5 Timing & cancellation

- The server creates an `AbortController` per `getSuggestions` request and aborts
  it if the client sends a newer request with a different `id` (or sends an
  explicit `cancel`). The client should simply supersede stale requests: when a
  new keystroke arrives, increment `id`, ignore any response whose `id` is not
  the latest.
- A per‑request timeout (e.g. 1500 ms) on the server aborts runaway `fd` runs.
- The client applies a **debounce** (default 25 ms for slash/path; 0 ms extra for
  `@` since `fd` is already async) and an overall RPC timeout (e.g. 2000 ms).

---

## 6. Component A — `pi-editor-bridge` (pi extension)

### 6.1 Responsibilities

- Capture the live `AutocompleteProvider`.
- Run a JSONL socket server for the session lifetime.
- Advertise the socket + token via `process.env.PI_EDITOR_BRIDGE`.
- Implement §5.4 methods by delegating to the captured provider.
- Clean up the socket on `session_shutdown` / process exit.
- Best‑effort `commandsChanged` notifications when the provider is rebuilt
  (reload/new/resume/fork).

### 6.2 Events used

| Event | Action |
|---|---|
| `session_start` (`startup`,`reload`,`new`,`resume`,`fork`) | (Re)capture provider, (re)start server, refresh env var, emit `commandsChanged` if already running. |
| `session_shutdown` (`quit`,`reload`,`new`,`resume`,`fork`) | Close server, unlink socket, clear env var. |

> Per pi docs: **do not start background resources (sockets) from the factory
> body**. Start them in `session_start`; tear them down in `session_shutdown`.

### 6.3 Capturing the provider (reference skeleton)

```ts
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { AutocompleteProvider } from "@earendil-works/pi-tui";

let liveProvider: AutocompleteProvider | undefined;

function captureProvider(ctx: ExtensionContext) {
  ctx.ui.addAutocompleteProvider((current) => {
    liveProvider = current;   // capture the live chain (base CombinedAutocompleteProvider at minimum)
    return current;           // pass-through — zero behavior change
  });
}
```

> Re‑registering a pass‑through factory on each `session_start` is safe:
> `addAutocompleteProvider` re‑runs `setupAutocompleteProvider()`, which re‑applies
> all factories, so `liveProvider` always points at the current chain. If pi
> guarantees your factory persists across reloads you may register once; the spec
> recommends re‑capturing on each `session_start` for robustness and to refresh on
> `/reload`.

### 6.4 Server lifecycle (reference skeleton)

```ts
import { createServer, type Socket } from "node:net";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const BRIDGE_ENV = "PI_EDITOR_BRIDGE";
let server: ReturnType<typeof createServer> | undefined;
let socketPath: string | undefined;
let token: string | undefined;

function startBridge(ctx: ExtensionContext, cwd: string) {
  stopBridge(); // idempotent
  token = randomUUID().replace(/-/g, "").slice(0, 32);
  socketPath = join(tmpdir(), `pi-editor-bridge-${randomUUID()}.sock`);
  server = createServer((sock) => onConnection(sock, cwd));
  server.listen(socketPath);
  if (process.platform !== "win32") chmod(socketPath, 0o600);
  process.env[BRIDGE_ENV] = JSON.stringify({
    transport: "unix", path: socketPath, token, pid: process.pid,
    cwd, fdAvailable: !!fdPathAvailable(), serverVersion: "0.1.0",
  });
}

function stopBridge() {
  try { server?.close(); } catch {}
  try { if (socketPath) rmSync(socketPath, { force: true }); } catch {}
  server = undefined; socketPath = undefined; token = undefined;
  delete process.env[BRIDGE_ENV];
}
```

### 6.5 Request handling (reference skeleton)

```ts
const handlers = {
  async getSuggestions({ lines, cursorLine, cursorCol, force }) {
    requireProvider();
    const ac = new AbortController();
    pendingAbort?.abort();           // supersede any in-flight call
    pendingAbort = ac;
    const t = setTimeout(() => ac.abort(), 1500);
    try {
      return await liveProvider!.getSuggestions(lines, cursorLine, cursorCol,
        { signal: ac.signal, force: !!force });
    } finally { clearTimeout(t); }
  },
  applyCompletion({ lines, cursorLine, cursorCol, item, prefix }) {
    requireProvider();
    return liveProvider!.applyCompletion(lines, cursorLine, cursorCol, item, prefix);
  },
  shouldTriggerFileCompletion({ lines, cursorLine, cursorCol }) {
    requireProvider();
    return liveProvider!.shouldTriggerFileCompletion?.(lines, cursorLine, cursorCol) ?? true;
  },
  // ping, getCommands (optional), bye …
};
```

### 6.6 Default export

```ts
export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_e, ctx) => {
    captureProvider(ctx);
    startBridge(ctx, ctx.cwd);
  });
  pi.on("session_shutdown", () => stopBridge());
}
```

### 6.7 Requirements checklist (extension)

- [ ] Single‑file extension installable at `~/.pi/agent/extensions/pi-editor-bridge.ts` (or as a pi package directory).
- [ ] No npm runtime dependencies (Node builtins only: `net`, `crypto`, `fs`, `os`, `path`).
- [ ] Never throws from handlers (wrap in try/catch, return JSON‑RPC `error`).
- [ ] Never blocks pi's event loop synchronously (all `getSuggestions` are awaited; `fd` is async inside the provider).
- [ ] Survives multiple editor open/close cycles within one session (server stays up; each editor is just a new connection).
- [ ] Idempotent start/stop; safe across `session_start`/`session_shutdown` churn.
- [ ] `/reload` re‑captures the provider and emits `commandsChanged` to connected clients.

---

## 7. Component B — `pi-editor.nvim` (Neovim plugin)

### 7.1 Activation gate

On `VimEnter` (once), read `vim.env.PI_EDITOR_BRIDGE`:

```lua
local raw = vim.env.PI_EDITOR_BRIDGE
if not raw then return end                       -- dormant in normal nvim use
local ok, desc = pcall(vim.json.decode, raw)
if not ok or desc.transport ~= "unix" then return end
-- activate for the first buffer (the pi temp file)
```

Optional secondary signal: the buffer name matches
`pi-editor-%d+%.pi%.md$` or `pi-extension-editor-%d+%.md$`. Require **either**
the env var **or** the filename (env var alone is sufficient and precise).

Set the buffer up as a pi prompt buffer:

- `vim.bo[buf].filetype = "pi-prompt"` (or `"markdown"` for built‑in highlighting;
  ship a tiny `ftdetect`/`after/ftplugin/pi-prompt.lua` if desired).
- `vim.wo[win].wrap = true; vim.wo.conceallevel = 0`.
- Buffer‑local keymaps & autocmds scoped to this buffer (see §7.6).

### 7.2 Module layout

```
lua/pi-editor/        init.lua       setup() + VimEnter activation
                     bridge.lua      socket client, JSONL framing, RPC dispatch
                     completion.lua  triggers, debounce, accept flow
                     menu.lua        dependency-free floating completion popup
                     coords.lua      byte<->utf16 / char-index conversion
                     health.lua      :checkhealth pi-editor
ftplugin/pi-prompt.lua  buffer-local opts/keymaps/autocmds
plugin/pi-editor.lua    VimEnter auto-activation shim
lua/pi-editor/blink_source.lua   OPTIONAL blink.cmp source
lua/pi-editor/cmp_source.lua     OPTIONAL nvim-cmp source
doc/pi-editor.txt               vimdoc
```

### 7.3 `bridge.lua` — socket client (reference skeleton)

Uses only `vim.uv` (luv) + `vim.json`, both built into Neovim (verified on 0.12):

```lua
local uv = vim.uv
local M = {}
function M.connect(path, token, on_ready, on_event)
  local pipe = uv.new_pipe(false)
  local rx = require("pi-editor.jsonlreader").new(function(msg) on_event(msg) end)
  pipe:connect(path, function(err)
    if err then return on_ready(err) end
    -- handshake
    M.send({ jsonrpc="2.0", id="h1", method="hello", params={ token=token, client="pi-editor.nvim" } })
    on_ready(nil)
  end)
  pipe:read_start(function(err, chunk)
    if err or not chunk then return end
    rx:feed(chunk)            -- splits on \n, vim.json.decode each line
  end)
  -- M.send(obj): pipe:write(vim.json.encode(obj).."\n")
  return pipe
end
return M
```

Correlate responses by `id`; expose `request(method, params, cb)` that auto‑assigns
monotonic ids and **drops responses whose id is not the current pending id** (this
naturally implements supersession / cancellation).

### 7.4 `completion.lua` — trigger & accept flow

**Triggers (mirror pi's provider semantics):** the simplest correct approach is to
ask the provider on every change and let *it* decide. Debounce and supersede:

- `InsertEnter`, `InsertCharPre`/`TextChangedI`, `CursorMovedI` (insert) →
  schedule a debounced `getSuggestions` with the current buffer lines + cursor.
- **Tab with no menu open** → call `shouldTriggerFileCompletion`; if true, call
  `getSuggestions(..., { force = true })` and show results (matches pi's Tab).
- **Tab / `<C-Y>` / `<CR>` with menu open** → accept (see below).

**Accept flow (faithful to pi):**

1. Read current `lines` (0‑indexed) + `cursorLine`/`cursorCol` (§8).
2. `applyCompletion(lines, cursorLine, cursorCol, selectedItem, prefix)` →
   `{lines, cursorLine, cursorCol}`.
3. Replace buffer lines: `vim.api.nvim_buf_set_lines(0, 0, -1, false, result.lines)`.
4. Position cursor: convert `result.cursorCol` (char index) → byte col
   (`vim.str_byteindex`), then
   `vim.api.nvim_win_set_cursor(0, { result.cursorLine + 1, bytecol - 1 })`.
5. Close menu; stay in insert mode so the user can type args / continue.

> Because pi's `applyCompletion` returns the **entire** line array and the final
> cursor, the plugin never has to reimplement insertion edge cases (trailing
> spaces, directory vs file, quotes, `/cmd `).

**Slash‑command nuance:** in pi, Tab on a command *accepts without submitting*;
the prompt submits only on Enter in the TUI. In the external editor there is **no
Enter‑to‑submit** — quitting submits. So: `<CR>` in the buffer should **insert a
newline** (or accept‑then‑newline if the menu is open). Document this clearly in
the buffer's statusline / first‑run hint.

### 7.5 `menu.lua` — dependency‑free floating popup

A small completion menu with **zero plugins**:

- A borderless (or `BorderChars`) floating window via `vim.api.nvim_open_win`.
- Rendered from `items`: two columns — `label` (left) and `description` (right,
  truncated). Use `vim.api.nvim_buf_set_lines` + extmarks/`nvim_buf_add_highlight`
  for the selected row.
- Keys (buffer‑local, active while menu is up): `<C-N>`/`<Down>` next,
  `<C-P>`/`<Up>` prev, `<C-E>` dismiss, `<Tab>`/`<C-Y>`/`<CR>` accept. These can
  be mapped via a tiny modal‑ish feedkeys dance or an `insert`‑mode expression;
  the cleanest is to handle them in the `InsertCharPre`/`TextChangedI` flow and a
  buffer‑local `on_key`/`CursorMovedI` caret tracker. Keep the implementation
  conservative and well‑tested (see §14).
- Auto‑position near the cursor with clamping to window edges; close on
  `InsertLeave`, `CursorMoved` out of prefix, or buffer write.

> This menu is the **primary** UX. It must work with a stock Neovim and no plugin
> manager.

### 7.6 Buffer‑local setup (`ftplugin/pi-prompt.lua`)

- Options: `formatoptions-=t`, `textwidth=0`, `wrap`, `spell=false`.
- Keymaps: `<Tab>` (trigger/accept), `<S-Tab>`, `<C-N>/<C-P>`, `<C-E>`, `<CR>`
  (newline or accept), optional `<C-G>` hint.
- Autocmds (buffer‑local):
  - `InsertEnter`, `TextChangedI`, `CursorMovedI` → completion refresh.
  - `ExitPre`, `VimLeavePre`, `BufWriteCmd` → **autosave if modified** (§11) and
    close the bridge connection.
  - `BufWritePre` → no‑op normal write (the temp file is writable).
- Optional statusline marker (e.g. `PI` + cwd) so the user knows completion is
  active.

### 7.7 Optional completion‑engine sources

Ship **opt‑in** modules the user can register if they prefer their engine:

- `lua/pi-editor/blink_source.lua` — a
  [`blink.cmp`](https://github.com/Saghen/blink.cmp) source: `get_trigger_characters`
  = `["/", "@"]`, `get_completions(ctx, cb)` calls `bridge.getSuggestions(...)` and
  maps items to blink's `Completion`.
- `lua/pi-editor/cmp_source.lua` — an `nvim-cmp` source with
  `trigger_characters = { "/", "@" }` and `complete(request, callback)`.

Both reuse the same bridge + accept‑via‑`applyCompletion` path. The plugin should
expose `require("pi-editor").bridge` so these (and user code) can issue RPCs.

---

## 8. Coordinate & Encoding Contract

This is the single most error‑prone area; spec it precisely.

**pi's model:** `lines` is a `string[]`; `cursorLine` is **0‑indexed**;
`cursorCol` is a **JavaScript string index** (UTF‑16 code unit offset) into
`lines[cursorLine]`, measured from the start of the line.

**Neovim's model:** lines from `nvim_buf_get_lines` are 0‑indexed Lua strings
(UTF‑8); cursor row is 1‑indexed (`vim.fn.line(".")`); cursor column is **1‑indexed
byte offset** (`vim.fn.col(".")`).

**Conversion the plugin must perform on every request:**

| From (nvim) | To (pi) | How |
|---|---|---|
| row `r` (1‑indexed) | `cursorLine` (0‑indexed) | `cursorLine = r - 1` |
| byte col `c` (1‑indexed) | `cursorCol` (0‑indexed char/UTF‑16) | `codepoint = vim.str_utfindex(line, c - 1)`; for full correctness convert codepoint→UTF‑16 units (surrogates for astral plane) — see below |
| `nvim_buf_get_lines(0,0,-1,false)` | `lines` | direct (Lua strings ↔ JSON strings are UTF‑8 ↔ JS string; identical content) |

**On apply (pi → nvim):** invert — `result.cursorCol` (UTF‑16) → codepoint → byte
via `vim.str_byteindex(line, codepoint)`; cursor row = `result.cursorLine + 1`.

**UTF‑16 vs codepoint:** `vim.str_utfindex` returns a **codepoint** index, but JS
string indexing is **UTF‑16 code units**. They differ only for astral‑plane
characters (emoji, some CJK extensions) which use surrogate pairs in JS. For v1
it is acceptable to approximate by treating codepoint index == UTF‑16 index
(correct for the entire BMP and most real prompt text). Document this; provide a
`coords.lua` helper `utf16_len_of_prefix(line, byte_end)` that counts surrogate
pairs for full correctness as a v1.1 refinement. **MUST** be centralized so the
fix is one place.

> Reuse `vim.str_byteindex` / `vim.str_utfindex` (both confirmed present on
> Neovim 0.12). Do **not** reimplement UTF‑8 walking by hand.

---

## 9. File Layouts

### 9.1 Extension (pi side)

Simplest (single file):

```
~/.pi/agent/extensions/pi-editor-bridge.ts        # the whole extension
```

Or as a pi package (for sharing/`pi install`):

```
pi-editor-bridge/
  package.json          # { "name":"pi-editor-bridge", "main":"./index.ts", "pi":{ "extensions":["./index.ts"] } }
  index.ts              # default factory
  server.ts             # JSONL server + framing
  protocol.ts           # shared types/enums (optional)
  README.md
```

### 9.2 Plugin (Neovim side)

```
pi-editor.nvim/
  lua/pi-editor/
    init.lua  bridge.lua  completion.lua  menu.lua  coords.lua  health.lua
    blink_source.lua  cmp_source.lua          # optional
  plugin/pi-editor.lua                        # VimEnter auto-activation
  ftplugin/pi-prompt.lua                      # buffer-local setup
  doc/pi-editor.txt                           # :help pi-editor
  README.md
  .github/workflows/                          # plenary tests + selene/stylua (optional)
  stylua.toml  selene.yml                     # lint config
```

---

## 10. Installation & Configuration

### 10.1 Prerequisites

- pi (with extension support; current monorepo `~/projects/pi`).
- Neovim **0.10+** (0.12 verified). No plugin manager required for core features.

### 10.2 Install the bridge extension

```bash
# Option A: drop‑in single file
cp pi-editor-bridge.ts ~/.pi/agent/extensions/pi-editor-bridge.ts
# Option B: pi package
pi install <git-or-npm-source>
```

Verify: start pi; `:env`/`echo $PI_EDITOR_BRIDGE` won't be visible from a shell
(it's process‑local), but `/reload` and opening the editor should "just work". Add
a `notify("pi-editor-bridge ready", "info")` on `session_start` during development.

### 10.3 Install the Neovim plugin

**lazy.nvim:**

```lua
{
  "you/pi-editor.nvim",
  lazy = false,           -- must load before VimEnter in the editor instance
  config = function() require("pi-editor").setup({}) end,
}
```

**vim.pack / manual:** clone into `~/.local/share/nvim/site/pack/...`.

Because activation is gated on `PI_EDITOR_BRIDGE`, leaving `lazy=false` is fine —
the plugin no‑ops in every other Neovim session.

### 10.4 `$EDITOR` wiring

Set Neovim as pi's external editor (any of):

- `export EDITOR=nvim` / `export VISUAL=nvim`, **or**
- in pi `settings.json`: `{ "externalEditor": "nvim" }`
  (`externalEditor` takes precedence over `$VISUAL`/`$EDITOR`).

For faster editor startup with a minimal config, the bridge extension may
**additionally** set `process.env.NVIM_APPNAME = "pi-editor"` (documented
opt‑in), and the user maintains a tiny `~/.config/pi-editor/` that loads only
`pi-editor.nvim`. This is an **optional optimization**, not required.

### 10.5 Default `setup()` options

```lua
require("pi-editor").setup({
  menu = { max_height = 12, border = "rounded" },
  debounce_ms = 25,
  rpc_timeout_ms = 2000,
  autosave_on_exit = true,      -- write the temp file on VimLeavePre if modified
  engine = "builtin",           -- "builtin" | "blink" | "cmp" (auto-detect if unset)
  -- optional: override how the bridge descriptor is read
  -- env_var = "PI_EDITOR_BRIDGE",
})
```

---

## 11. Edge Cases, Failure Modes & Limitations

- **Forgotten save → lost prompt.** pi reads the file only after the editor
  exits with status 0. The plugin **MUST** autosave the buffer on `VimLeavePre`/
  `ExitPre` when modified (and on a `BufWriteCmd` that maps `:w`). Without this a
  user who types and quits with `:q` silently loses their prompt. Document it
  prominently and enable `autosave_on_exit = true` by default.
- **Stale/missing socket.** If `connect()` fails or `hello` errors, the plugin
  must **degrade silently** to a normal buffer (no completion), optionally with a
  single `vim.notify` the first time. Never block startup or spam.
- **pi process dies while editor open.** The socket closes; the plugin detects
  EOF on the pipe, stops completion, and may notify once.
- **Two buffers / split windows.** v1 supports completion in the buffer that was
  active at `VimEnter` (the temp file). Completion is buffer‑local; other windows
  are unaffected.
- **Other extensions' custom autocomplete.** Because the bridge captures `current`
  at registration time, **wrappers registered after** the bridge (e.g. a
  `github-issue-autocomplete` `#`‑trigger) will **not** appear in the external
  editor. The base provider (slash/skill/template/path) — the user's stated goal —
  is always captured. Mitigation: the bridge can re‑register its capture factory
  on `session_start` *after* other extensions, but load order isn't guaranteed;
  document this as a known limitation. (Future: request a pi API to access the
  final provider — see §15.)
- **Astral‑plane characters** (emoji) in the buffer: cursor column conversion is
  codepoint‑approximate in v1 (see §8). Practical impact is tiny for prompts.
- **`force` file completion on empty line** must respect
  `shouldTriggerFileCompletion` (pi returns `false` while typing a bare command
  like `/set`). The plugin must not bypass it.
- **`fd` not installed.** pi's `@file` fuzzy search silently returns nothing; path
  completion (readdir) still works. The bridge reports `fdAvailable` in `hello`.
- **No‑session / print mode.** `openExternalEditor` is TUI‑only; the bridge
  should no‑op when `ctx.mode ~= "tui"` (guard in `session_start`).
- **Reload during an open editor.** `session_start {reason:"reload"}` re‑captures
  the provider and re‑advertises (same socket path is fine; just refresh the
  captured reference and emit `commandsChanged`). The open editor's existing
  connection stays valid.

---

## 12. Security

- The socket lives in `os.tmpdir()` with `0600` perms.
- **Token handshake** (32‑byte random) prevents another local process from
  impersonating the editor. The token is delivered via `process.env` (process‑
  local, not on disk) and validated in `hello`.
- Optionally, the server can `getpeercred`/`SO_PEERCRED` (Linux) to verify the
  connecting PID is a descendant of pi — nice‑to‑have, not required.
- Never log the token. Treat `PI_EDITOR_BRIDGE` as sensitive (it's already
  process‑local, but don't echo it in completion descriptions / status).
- The bridge must reject any method before a valid `hello`.

---

## 13. Implementation Plan (Phased)

**Phase 0 — Spike (prove the seam).**
1. Write a 40‑line extension that captures `current` and logs
   `await current.getSuggestions(["/mo"], 0, 3, {signal})`. Confirm it returns the
   `/model…` items.
2. Add `process.env.PI_EDITOR_BRIDGE = "hello"` and confirm a launched `nvim` sees
   it (`:lua print(vim.env.PI_EDITOR_BRIDGE)`).
3. ✔ Gate passed → proceed.

**Phase 1 — Bridge core.**
4. Implement the JSONL Unix‑socket server with `hello`/`ping`/`getSuggestions`/
   `applyCompletion`/`shouldTriggerFileCompletion`.
5. Env var advertisement + `session_start`/`session_shutdown` lifecycle.
6. Test with `nc -U <socket>` or a 20‑line Node client.

**Phase 2 — Plugin core (builtin menu).**
7. `bridge.lua` luv client + handshake + JSONL reader + id correlation.
8. `coords.lua` byte↔char conversion.
9. `completion.lua` triggers/accept using the bridge.
10. `menu.lua` floating popup.
11. `ftplugin/pi-prompt.lua` buffer setup + autosave.

**Phase 3 — Polish.**
12. Debounce, supersession, timeouts, silent degradation.
13. `commandsChanged` notification handling (clear caches).
14. `:checkhealth pi-editor`.
15. Docs (`doc/pi-editor.txt`, README) + keybinding/help hints.

**Phase 4 — Optional integrations.**
16. blink.cmp source.
17. nvim‑cmp source.
18. `NVIM_APPNAME` minimal‑config optimization.

**Phase 5 — Tests & packaging.**
19. plenary tests for `coords.lua` and `menu.lua` (see §14).
20. Package the extension as a pi package; publish the nvim plugin.

---

## 14. Testing Strategy

**Extension (TS):**
- Unit‑test the JSONL framing (partial chunks, multi‑line, `\r\n`).
- Integration: run pi in RPC/print mode with the extension loaded via `pi -e`,
  spawn the server, connect a fake client, assert `getSuggestions("/m")` returns
  `/model`.
- Lifecycle: assert socket unlinked after `session_shutdown`.

**Plugin (Lua, plenary.nvim):**
- `coords_spec.lua`: round‑trip `byte→char→byte` for ASCII, multibyte BMP
  (`é`, `日`), and document the emoji (astral) approximation.
- `menu_spec.lua`: item rendering, selection movement, clamping, open/close.
- `bridge_spec.lua`: JSONL reader splits correctly; id correlation drops stale
  responses; handshake rejects bad token.
- End‑to‑end (manual + scripted): launch a real pi + real `nvim --headless`
  editing a temp file, type `/mo<Tab>`, assert the buffer contains `/model `.

**CI:** selene + stylua (lint/format), plenary on stable + nightly Neovim
(follow the neovim‑plugin‑development skill conventions).

---

## 15. Future Enhancements

- **Upstream pi API** to access the *final* wrapped provider (so post‑bridge
  extension autocomplete triggers also appear). Would be a tiny, well‑justified
  public‑API addition (e.g. `ctx.ui.getAutocompleteProvider()`); propose upstream
  per the extending‑pi patch policy only if the capture limitation bites real
  users.
- **Live buffer sync / preview** (optional): have the editor periodically echo
  the draft into pi's inline editor so the user sees it reflected — out of scope;
  the file‑on‑quit model is simpler and matches current pi behavior.
- **Submission without quitting**: a Neovim command (`:PiSubmit`) that writes the
  file and `:cq`/quits to hand control back to pi. Convenience only.
- **Skill/template *argument* completion** beyond what
  `getArgumentCompletions` already provides (already covered for builtin commands
  like `/model`, `/login`).
- **Hover docs** for a selected command (`/model` → its description/help) using
  `getCommands`.
- **Themes**: tint the menu with the active pi theme colors by having the bridge
  expose a small palette in `hello`.

---

## 16. Reference: Key pi Source Locations

All under `~/projects/pi`:

| Concern | Path |
|---|---|
| Editor launch (main) | `packages/coding-agent/src/modes/interactive/interactive-mode.ts` — `openExternalEditor()` (search `pi-editor-${Date.now()}.pi.md`) |
| Editor launch (modal) | `packages/coding-agent/src/modes/interactive/components/extension-editor.ts` — `openExternalEditor()` (`pi-extension-editor-${Date.now()}.md`) |
| Provider construction | `interactive-mode.ts` — `createBaseAutocompleteProvider()` / `setupAutocompleteProvider()` |
| `addAutocompleteProvider` impl | `interactive-mode.ts` — `ui.addAutocompleteProvider` pushes to `autocompleteProviderWrappers` and re‑runs `setupAutocompleteProvider()` |
| Autocomplete engine | `packages/tui/src/autocomplete.ts` — `AutocompleteProvider`, `AutocompleteItem`, `CombinedAutocompleteProvider` |
| Editor's autocomplete call sites | `packages/tui/src/components/editor.ts` — `applyCompletion(...)` / Tab handling (search `getSuggestions`) |
| Slash commands (builtin) | `packages/coding-agent/src/core/slash-commands.ts` — `BUILTIN_SLASH_COMMANDS` |
| Extension UI types | `packages/coding-agent/src/core/extensions/types.ts` — `ExtensionUIContext.addAutocompleteProvider`, `AutocompleteProviderFactory` |
| Extension lifecycle docs | `packages/coding-agent/docs/extensions.md` (Autocomplete Providers section) |
| Settings (editor) | `packages/coding-agent/src/core/settings-manager.ts` — `getExternalEditorCommand()` / `settings.externalEditor` |
| Keybinding | `packages/coding-agent/src/core/keybindings.ts` — `app.editor.external` default `ctrl+g` |
| RPC framing reference | `packages/coding-agent/docs/rpc.md` (JSONL / `\n`‑only rules) |

---

### TL;DR

A pi extension captures pi's **live** `AutocompleteProvider` via a pass‑through
`addAutocompleteProvider` factory, serves it over a **Unix socket advertised
through `process.env.PI_EDITOR_BRIDGE`** (which the spawned `$EDITOR` inherits),
and a dormant Neovim plugin connects to that socket whenever the env var is
present — rendering `/commands`, `skill:` templates, argument completions,
`@files`, and paths through a dependency‑free floating menu, with acceptance
delegated back to pi's `applyCompletion` so insertion behavior is identical to
the TUI.
