# pi-editor-bridge

> Bridge pi's in-prompt completion into the Neovim instance pi launches as `$EDITOR`.

This repository ships **two components** that work together:

- **`pi-editor-bridge`** *(this README's focus — a **pi extension**)* captures
  pi's live autocomplete engine and serves it over a local Unix socket to the
  external editor pi spawns.
- **`pi-editor.nvim`** *(the companion **Neovim plugin**, under [`plugin/`](./plugin) —
  see [`plugin/README.md`](./plugin/README.md) and `:help pi-editor`)* connects
  to that socket and renders pi's completion inside Neovim: `/commands`,
  `skill:` templates, argument completions, `@file` references, and filesystem
  paths.

Acceptance is delegated back to pi's `applyCompletion`, so insertion behavior
is byte-for-byte identical to the TUI. Both components are **complete and
shipped**.

## What it does

It brings pi's autocomplete into Neovim. When you launch your external editor
from pi, it behaves just like pi's prompt box — same `/` slash commands, same
`skill:` templates, same `@file` references and path suggestions, same argument
completions. Whatever pi would suggest inline, you get here, inside Neovim.

The idea is simple: write your prompt in a real editor without giving up any of
pi's autocomplete. You get a comfortable editing surface and the full set of
completions pi already offers.

> **Note:** the companion `pi-editor.nvim` plugin is **complete** (under
> [`plugin/`](./plugin)). The bridge and plugin work together to deliver
> pi-faithful completion in the external editor.

## Prerequisites

- **pi** with extension support.
- **Neovim ≥ 0.11** (0.12 verified) for the companion plugin — see
  [`plugin/README.md`](./plugin/README.md#requirements).
- **`fd`** *(optional)* — enables fuzzy `@file` search. Without it `@file`
  silently returns nothing, but path completion (directory listing) still works.
- The companion **`pi-editor.nvim`** plugin (see [`plugin/README.md`](./plugin/README.md)).

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
(e.g. lazy.nvim — note `lazy = false` so the VimEnter startup shim sources
**before** activation). See [`plugin/README.md`](./plugin/README.md) and
`:help pi-editor` (`plugin/doc/pi-editor.txt`).

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

### Optional startup optimization

A heavy daily-driver Neovim config (LSP servers, lazy-loaded plugins, plugin-
manager boot) can add hundreds of milliseconds-to-seconds to every `Ctrl+G`
launch. You can keep a tiny dedicated config that loads **only** `pi-editor.nvim`
so the external-editor round-trip feels instant. Two ways to opt in:

**Recommended — the bridge opt-in (`PI_EDITOR_NVIM_APPNAME`):**

```bash
export PI_EDITOR_NVIM_APPNAME=1
```

The extension sets `NVIM_APPNAME` inside pi's process for the session (so the
pi-spawned Neovim boots from `~/.config/pi-editor/` instead of
`~/.config/nvim/`) and **restores your prior value on exit** — so a global
`NVIM_APPNAME`, if you have one, is left untouched. Value table:

| `PI_EDITOR_NVIM_APPNAME` | resulting `NVIM_APPNAME` |
| --- | --- |
| _(unset)_ | _(feature off — nothing changes)_ |
| `""`, `1`, `true`, `yes`, `on` (case-insensitive) | `pi-editor` (default) |
| _any other non-empty string_ | that literal appname |

**The minimal config** (any of the opt-in paths above) — create
`~/.config/pi-editor/init.lua` that loads only `pi-editor.nvim` (stock Neovim,
no plugin manager required):

```lua
-- ~/.config/pi-editor/init.lua
require("pi-editor").setup({})
```

Neovim starts cleanly even before you create this file (it just has no user
config), so the opt-in is safe to enable first and configure at your leisure.

> ⚠️ The appname must be a **simple directory name** (no `/`). Neovim rejects an
> appname containing a path separator; we don't validate it in the bridge — nvim
> surfaces a clear error in the launched editor.

**Manual alternative:** users who prefer not to use the extension opt-in can
`export NVIM_APPNAME=pi-editor` in the shell that launches pi — the child editor
inherits it the same way (note: unlike the bridge opt-in, this does not restore
a prior value because pi never owned the var).

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
  companion plugin **autosaves** the buffer on `VimLeavePre` when modified
  (`autosave_on_exit`, default `true`). To be explicit, quit with `:x`/`ZZ`.
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
├── README.md                 # this file (the EXTENSION README)
├── plugin/                   # the pi-editor.nvim Neovim plugin (P2 + P4 — complete)
│   ├── README.md             # the PLUGIN README (end-user landing page)
│   ├── plugin/pi-editor.lua  # VimEnter auto-activation shim
│   ├── lua/pi-editor/        # init/bridge/completion/menu/coords/health/blink_source/cmp_source/...
│   ├── ftplugin/pi-prompt.lua# 9 buffer-local keymaps + ft opts + autocmds
│   ├── doc/pi-editor.txt     # the vimdoc (`:help pi-editor`)
│   └── tests/                # plenary specs + plenary-free smokes
└── extension/                # the pi-editor-bridge pi extension (P1 — complete)
    ├── pi-editor-bridge.ts   # entry: default-export factory
    ├── connection.ts         # JSON-RPC server + dispatch + registry
    ├── jsonl-reader.ts       # newline-delimited JSON framing
    ├── protocol.ts           # type-only: descriptor + RPC envelopes
    ├── tsconfig.json
    └── tests/                # node:test + jiti suites
```

> **LICENSE:** the manifest declares `"license": "MIT"` and an
> [`LICENSE`](./LICENSE) file is committed at the repo root.

## Links

- [PRD](./PRD.md) — full design document for the bridge + Neovim plugin.
- pi docs: [packages.md](https://pi.dev/docs/packages) ·
  [extensions.md](https://pi.dev/docs/extensions)
- Companion plugin: [plugin/README.md](./plugin/README.md) ·
  `:help pi-editor` ([`plugin/doc/pi-editor.txt`](./plugin/doc/pi-editor.txt)).

## Releasing

Releases are **tag-driven**. The git tag is the single source of truth for the
published version — you never hand-edit `package.json`'s `"version"`.

```bash
git tag v1.2.3
 git push origin v1.2.3
```

Pushing a `v*` tag triggers [`.github/workflows/release.yml`](./.github/workflows/release.yml),
which:

1. extracts the version from the tag (strips the leading `v`, validates it as
   semver),
2. writes that version into `package.json` **inside the ephemeral runner
   checkout only** (`npm version … --no-git-tag-version`) — nothing is committed
   back to the repo,
3. publishes `pi-editor-bridge` to npm with [provenance](https://docs.npmjs.com/generating-provenance-statements)
   attestation, and
4. opens a GitHub Release with auto-generated notes (prereleases are auto-marked
   when the version contains a `-`, e.g. `v1.0.0-beta.1`).

**One-time setup:** add an npm access token (Automation or Granular, with
publish rights for `pi-editor-bridge`) as the repo secret `NPM_TOKEN`.
Provenance also relies on the workflow's `id-token: write` permission, which is
already declared in the workflow. If your token type can't do provenance, set
`publishConfig.provenance` to `false` in `package.json` (and drop
`--provenance` from the publish step).

The repo's `package.json` `"version"` stays at a placeholder (currently
`0.1.0`) on purpose — it is always overridden at publish time by the tag.
