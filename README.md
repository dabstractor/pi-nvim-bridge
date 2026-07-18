# pi-editor-bridge

> Bridge pi's in-prompt completion into the Neovim instance pi launches as `$EDITOR`.

`pi-editor-bridge` is a **pi extension** that captures pi's live autocomplete
engine and serves it over a local Unix socket to the external editor pi spawns.
A companion Neovim plugin — **`pi-editor.nvim`** (forthcoming, see Phase 2) —
connects to that socket and renders pi's completion inside Neovim: `/commands`,
`skill:` templates, argument completions, `@file` references, and filesystem
paths. Acceptance is delegated back to pi's `applyCompletion`, so insertion
behavior is byte-for-byte identical to the TUI.

## What it does

On `session_start` the extension registers a pass-through factory with
`pi.autocomplete.addAutocompleteProvider`, capturing pi's current
`AutocompleteProvider` (the same one the TUI uses). It then starts a
JSON-RPC server on a Unix-domain socket and advertises the socket path plus a
32-byte token to the process environment (`PI_EDITOR_BRIDGE`). Because pi
launches `$EDITOR` with inherited `process.env`, the Neovim it starts sees that
descriptor and can dial the bridge. The bridge stays alive for the whole session
and re-advertises on `/reload`.

> **Note:** the extension is complete and tested; the Neovim-side rendering
> plugin (`pi-editor.nvim`) ships separately under Phase 2. Until it lands, the
> bridge advertises correctly but there is nothing on the editor side to consume
> it.

## Prerequisites

- **pi** with extension support.
- **Neovim ≥ 0.10** (0.12 verified) for the companion plugin.
- **`fd`** *(optional)* — enables fuzzy `@file` search. Without it `@file`
  silently returns nothing, but path completion (directory listing) still works.
- The companion **`pi-editor.nvim`** plugin (Phase 2, forthcoming).

## Installation

```bash
# Preferred: install from git
pi install git:github.com/dabstractor/pi-nvim-bridge

# Or from a local clone
git clone https://github.com/dabstractor/pi-nvim-bridge
cd pi-nvim-bridge
pi install .
```

Verify:

```bash
pi list          # should show "pi-editor-bridge"
```

> ⚠️ **Multi-file package — no single-file drop-in.**
> This extension is composed of four interdependent `.ts` files
> (`pi-editor-bridge.ts`, `connection.ts`, `jsonl-reader.ts`, `protocol.ts`).
> You **cannot** install it by copying one file into
> `~/.pi/agent/extensions/`. The imported siblings would be unresolved.
> Install it as a pi package via one of the commands above.

**Companion plugin:** install `pi-editor.nvim` with your plugin manager
(e.g. lazy.nvim). See that plugin's README (Phase 2).

## Configuration (`$EDITOR`)

Tell pi to use Neovim as its external editor. Any one of:

```bash
export EDITOR=nvim
# or
export VISUAL=nvim
```

…or in pi's `settings.json` (this takes precedence over the env vars):

```json
{ "externalEditor": "nvim" }
```

Then in pi, press <kbd>Ctrl+G</kbd> (the `app.editor.external` keybinding) to
open the external editor. The bridge advertises `PI_EDITOR_BRIDGE` to the Neovim
process pi spawns, which the companion plugin keys on.

> **Optional startup optimization:** for a faster editor launch you may keep a
> minimal Neovim config at `~/.config/pi-editor/` and set
> `NVIM_APPNAME=pi-editor` in pi's environment so the editor instance loads only
> `pi-editor.nvim`. This is optional, not required.

## How it works

1. **Live-provider capture.** The extension registers a pass-through
   `AutocompleteProviderFactory` with pi. The factory simply captures the
   `current` provider pi hands it — so the bridge serves the *same* completion
   the TUI uses, not a snapshot.
2. **Process-local discovery.** pi spawns `$EDITOR` inheriting `process.env`
   (no `env:` override, `stdio: "inherit"`). The bridge writes a JSON descriptor
   to `process.env.PI_EDITOR_BRIDGE` *inside* pi, so the child Neovim sees it.
3. **JSON-RPC over a Unix socket.** The bridge speaks newline-delimited JSON-RPC
   with these methods: `getSuggestions`, `applyCompletion`, and
   `shouldTriggerFileCompletion`, plus `hello` (token handshake), `ping`, `bye`,
   and `getCommands`. Completion acceptance calls back into pi's own
   `applyCompletion`, guaranteeing identical insertion semantics.

## The `PI_EDITOR_BRIDGE` environment variable

The descriptor is a single-line JSON object:

```jsonc
{
  "transport": "unix",
  "path": "/tmp/pi-editor-bridge-<pid>.sock",
  "token": "<32-byte hex>",
  "pid": 12345,
  "cwd": "/your/project",
  "fdAvailable": true,
  "serverVersion": "0.1.0"
}
```

> **`echo $PI_EDITOR_BRIDGE` shows nothing in your shell — this is expected.**
> The variable is written to `process.env` *inside* the pi process and is only
> visible to the child `$EDITOR` pi spawns. It is never exported to your shell.
> This is the #1 source of confusion; it is not a bug. To inspect it from
> inside the launched Neovim: `:lua print(vim.env.PI_EDITOR_BRIDGE)`.

## Troubleshooting

- **"I typed, then `:q`, and lost my prompt."**
  pi only reads the temp file after the editor exits with status 0. The
  companion plugin autosaves the buffer on `VimLeavePre` when modified. Until
  Phase 2 ships, remember to `:w` before `:q`.
- **"Completion doesn't appear in Neovim."**
  Confirm the extension loaded (`pi list` shows `pi-editor-bridge`), confirm
  `EDITOR=nvim` (or `externalEditor` in settings), and confirm the companion
  `pi-editor.nvim` plugin is installed and that it gated itself on the presence
  of `PI_EDITOR_BRIDGE`.
- **"`@file` finds nothing."**
  Install [`fd`](https://github.com/sharkdp/fd). The bridge reports `fdAvailable`
  in `hello`; without `fd`, `@file` is empty but path completion (directory
  listing) still works.
- **"I ran `/reload` while the editor was open."**
  The bridge re-captures the provider and re-advertises the descriptor; the open
  editor's existing connection stays valid, and a `commandsChanged` notification
  fires so it can refresh.
- **"Another extension's custom trigger (e.g. `#issues`) doesn't complete."**
  **Known limitation.** The bridge captures the provider at its own registration
  time, so wrappers registered *after* it won't appear. The base provider —
  slash commands, `skill:`, templates, and paths — is always captured.
- **"Nothing happens in non-interactive mode (`pi -p`)."**
  Correct: `openExternalEditor` is TUI-only, so the bridge no-ops when
  `ctx.mode !== "tui"`.

## Security

- The Unix socket lives in `os.tmpdir()` with **`0600`** permissions.
- A **32-byte random token** prevents another local process from impersonating
  the editor. It is delivered via `process.env` (process-local, never on disk)
  and validated in the `hello` handshake.
- The server **rejects any method before a valid `hello`**.
- **Never log or echo the token.** Treat the `PI_EDITOR_BRIDGE` descriptor as
  sensitive — don't paste it into bug reports or completion descriptions.

## Development

This is a packaging-and-docs repository; the extension source lives under
`extension/`.

```bash
# Type-check (portable, reproducible gate)
npm run typecheck
# …or directly:
npx tsc --noEmit -p extension/tsconfig.json
```

Tests use **`node:test`** with **jiti** (not vitest). Run a single suite:

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/bridge-env.test.ts
# Run all suites:
for f in extension/tests/*.test.ts; do
  node --import "$JITI_REG" "$f" >/dev/null 2>&1 || echo "FAIL: $f"
done
```

> The `JITI_REG` path above is machine-specific (it points at pi's bundled
> jiti). Adjust it to your own pi install. This is why the `test` npm script is
> a pointer rather than a hardcoded command.

**Repository layout:**

```
pi-nvim-bridge/
├── package.json              # pi package manifest (pi.extensions → entry)
├── README.md                 # this file
└── extension/
    ├── pi-editor-bridge.ts   # entry: default-export factory
    ├── connection.ts         # JSON-RPC server + dispatch + registry
    ├── jsonl-reader.ts       # newline-delimited JSON framing
    ├── protocol.ts           # type-only: descriptor + RPC envelopes
    ├── tsconfig.json
    └── tests/                # node:test + jiti suites
```

> **LICENSE:** the manifest declares `"license": "MIT"`, but no `LICENSE` file is
> committed yet. Adding one is a separate human decision (out of scope for the
> packaging task).

## Links

- [PRD](./PRD.md) — full design document for the bridge + Neovim plugin.
- pi docs: [packages.md](https://pi.dev/docs/packages) ·
  [extensions.md](https://pi.dev/docs/extensions)
- Companion plugin: **`pi-editor.nvim`** (Phase 2, forthcoming).
