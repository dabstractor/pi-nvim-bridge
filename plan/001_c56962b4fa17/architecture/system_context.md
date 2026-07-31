# System Context & Architecture Validation

## Overview

This document records the architectural validation of the PRD against the actual
pi codebase at `~/projects/pi` and the Neovim 0.12 runtime. All major PRD claims
are **CONFIRMED**. Key refinements discovered during research are noted.

## Two-Component Architecture

```
┌─ pi process (Node) ─────────────────────────────────────────────────┐
│                                                                      │
│  InteractiveMode.openExternalEditor()                                │
│    └─ spawn($EDITOR, [tmpFile], { stdio: "inherit" })                │
│       (NO env: option → child INHERITS process.env)                  │
│                                                                      │
│  CombinedAutocompleteProvider ◄── captured by bridge extension       │
│  via pass-through addAutocompleteProvider factory                    │
│                                                                      │
│  pi-editor-bridge extension:                                         │
│    • session_start → capture provider + start Unix socket server     │
│    • sets process.env.PI_NVIM_BRIDGE = {json descriptor}           │
│    • JSONL RPC over Unix domain socket                               │
│    • session_shutdown → close server, unlink socket                  │
│                                                                      │
└──────────────────────────────────│───────────────────────────────────┘
                                   │ process.env.PI_NVIM_BRIDGE
                                   │ Unix domain socket (JSONL)
┌──────────────────────────────────▼───────────────────────────────────┐
│  Neovim ($EDITOR child process)                                      │
│    • plugin/pi-editor.lua: VimEnter → read PI_NVIM_BRIDGE env var  │
│    • If present → activate; if absent → dormant (no-op)             │
│    • bridge.lua: luv pipe client → connect, handshake, RPC dispatch  │
│    • completion.lua: triggers, debounce, accept flow                 │
│    • menu.lua: dependency-free floating popup                        │
│    • coords.lua: byte ↔ UTF-16 index conversion                     │
│    • ftplugin/pi-prompt.lua: buffer-local setup + autosave           │
└──────────────────────────────────────────────────────────────────────┘
```

## Key Validated Facts

### 1. Editor Launch — process.env Inheritance (CRITICAL)
- **CONFIRMED:** `interactive-mode.ts:3811-3816` spawns editor with
  `{ stdio: "inherit", shell: process.platform === "win32" }` — **no `env` option**.
- Node.js `spawn` defaults to inheriting `process.env` when `env` is omitted.
- Therefore: anything the bridge extension writes to `process.env.*` before the
  editor launch IS visible to the Neovim child.
- The editor runs while the TUI is stopped (`this.ui.stop()`), so no terminal contention.
- **Two temp-file patterns:**
  - Main editor: `pi-editor-<ts>.pi.md` (interactive-mode.ts:3786)
  - Modal/extension editor: `pi-extension-editor-<ts>.md` (extension-editor.ts)
  - The Neovim plugin's activation gate should match **both** patterns or rely
    primarily on the env var.

### 2. AutocompleteProvider Interface (CONFIRMED)
Path: `packages/tui/src/autocomplete.ts:121-144`
```ts
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
- `cursorLine` is **0-indexed**; `cursorCol` is a **UTF-16 code unit offset** (JavaScript string index).
- `applyCompletion` returns the **entire new line array + cursor** — the plugin never reimplements insertion.

### 3. Extension API — Lifecycle & addAutocompleteProvider (CONFIRMED)
Path: `packages/coding-agent/src/core/extensions/types.ts`
- `ExtensionAPI.on("session_start", (event, ctx) => void)` — handler is `(event, ctx: ExtensionContext)`.
- `SessionStartEvent.reason`: `"startup" | "reload" | "new" | "resume" | "fork"`
- `SessionShutdownEvent.reason`: `"quit" | "reload" | "new" | "resume" | "fork"`
- `ExtensionContext` has `.cwd` (string), `.mode` (`"tui" | "rpc" | "json" | "print"`), `.hasUI` (boolean).
- `ExtensionContext.ui.addAutocompleteProvider(factory)` — factory receives `current` provider, returns provider.
- **IMPORTANT:** `addAutocompleteProvider` is a **no-op in RPC mode**. Bridge must guard with `ctx.mode === "tui"` or at minimum handle TUI mode (the only mode where external editors are launched).
- **Background resource rule (from extensions.md):** Do NOT start sockets/processes in the factory body. Start them in `session_start`; tear down in `session_shutdown`.

### 4. Import Paths (CONFIRMED)
- Types: `import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"`
- Autocomplete types: `import type { AutocompleteProvider } from "@earendil-works/pi-tui"`
- Node builtins available: `node:net`, `node:crypto`, `node:fs`, `node:os`, `node:path`
- Extensions are loaded via jiti (TS works without compile).
- Canonical examples in `packages/coding-agent/examples/extensions/`:
  - `github-issue-autocomplete.ts` — autocomplete + session_start pattern
  - `auto-commit-on-exit.ts` — session_shutdown cleanup pattern

### 5. Coordinate Conversion — REFINEMENT OVER PRD (IMPORTANT)
The PRD §8 suggests using `vim.str_utfindex` (2-arg, returns codepoint index) and
approximating codepoint≈UTF-16. **Research found a better approach:**

Neovim 0.12 provides **3-argument forms** with explicit encoding:
- `vim.str_utfindex(str, 'utf-16', byte_index)` → exact **UTF-16 code unit index**
- `vim.str_byteindex(str, 'utf-16', utf16_index)` → exact **byte index from UTF-16**

Verified behavior on Neovim 0.12.4:
```
héllo: byte 3 → utf16 index 2 (via str_utfindex(s, 'utf-16', 3))
héllo: utf16 index 2 → byte 3 (via str_byteindex(s, 'utf-16', 2))
日本語: byte 3 → utf16 index 1
日本語: utf16 index 1 → byte 3
```

This means `coords.lua` can do **exact** byte↔UTF-16 conversion with zero
approximation, even for astral-plane characters (emoji). The conversion:
- **nvim → pi:** `cursorCol = vim.str_utfindex(line, 'utf-16', byte_col - 1)` (byte_col is 1-indexed)
- **pi → nvim:** `byte_col = vim.str_byteindex(line, 'utf-16', utf16_col) + 1` (utf16_col is 0-indexed)

### 6. Neovim Runtime Environment (CONFIRMED)
- Neovim **0.12.4** installed.
- `vim.uv.new_pipe` — available (function)
- `vim.api.nvim_open_win` — available (function)
- `vim.str_utfindex` / `vim.str_byteindex` — available with 3-arg encoding forms
- `vim.json.decode` / `vim.json.encode` — available
- No external Lua dependencies required for core plugin

### 7. Completion Engine Source APIs (CONFIRMED)

**blink.cmp** (from source-boilerplate.md):
```lua
local source = {}
function source.new(opts) ... end  -- constructor, called by require('module').new(opts)
function source:enabled() return true end  -- optional
function source:get_trigger_characters() return { '/', '@' } end  -- optional
function source:get_completions(ctx, callback)
  callback({ items = { { label = '...', kind = ... } }, is_incomplete_backward = false, is_incomplete_forward = false })
  return function() end  -- optional cancel function
end
function source:resolve(item, callback) ... end  -- optional
function source:execute(ctx, item, callback, default_implementation) ... end  -- optional
return source
```
- Items are LSP CompletionItem-shaped (`label`, `kind`, `filterText`, `sortText`, `textEdit`, `insertText`, etc.)
- Callback may be called multiple times for streaming results.
- `ctx` contains keyword, cursor position, bufnr.
- IMPORTANT: blink.cmp will mutate items; deepcopy if caching.

**nvim-cmp** (from cmp.txt):
```lua
local source = {}
source.new = function() return setmetatable({}, { __index = source }) end
function source:is_available() return true end  -- optional
function source:get_trigger_characters() return { '/', '@' } end  -- optional
function source:complete(params, callback)
  callback({ { label = 'January' }, { label = 'February' } })  -- LSP CompletionItem[]
end
function source:resolve(completion_item, callback) callback(completion_item) end  -- optional
function source:execute(completion_item, callback) callback(completion_item) end  -- optional
```
- `params` is `cmp.SourceCompletionApiParams` with `context`, `offset`, `completion_context`.
- `callback` must always be called.

## Project Structure

The repo at `/home/dustin/projects/pi-nvim-bridge` is a fresh git repo with:
- `PRD.md` — the merged PRD
- `plan/001_c56962b4fa17/` — planning artifacts (this directory)

The output will be two components, which can live in this monorepo:
1. `extension/` — the pi-editor-bridge TypeScript extension
2. `plugin/` — the pi-bridge.nvim Neovim plugin (Lua)

## Residual Risks

1. **Extension load order:** The bridge captures `current` at registration time.
   Wrappers registered *after* the bridge won't be captured. Re-registering on
   each `session_start` mitigates this for pi's own reload cycle.
2. **`addAutocompleteProvider` is a no-op in RPC mode:** Bridge must guard with
   `ctx.mode === "tui"` (external editors only launch in TUI mode).
3. **Autosave on exit:** pi reads the temp file only after editor exit with
   status 0. The plugin MUST write the buffer on `VimLeavePre`/`ExitPre` when
   modified. Without this, `:q` after typing silently loses the prompt.
4. **Provider chain reset:** `autocompleteProviderWrappers` is cleared on session
   reset (interactive-mode.ts:1952). Bridge must re-register on each `session_start`.
5. **Two temp-file naming patterns:** Plugin activation should match both
   `pi-editor-<ts>.pi.md` and `pi-extension-editor-<ts>.md`, or rely primarily
   on the env var (which is set for both code paths).
