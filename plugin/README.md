# pi-editor.nvim

> Bring pi's in-prompt completion into the Neovim instance pi launches as `$EDITOR`.

`pi-editor.nvim` renders pi's **live** autocomplete — slash commands (`/model`,
`/compact`, `/skill:...`), prompt templates, extension commands, argument
completions, `@file` mentions, and filesystem paths — through a dependency-free
floating menu, inside the Neovim process pi spawns when you press
<kbd>Ctrl+G</kbd>. Because acceptance is delegated back to pi's own
`applyCompletion`, insertion behavior (trailing space for files, no space for
directories, quote handling, `/cmd ` for commands) is **byte-for-byte identical
to pi's TUI**.

This is the **Neovim half** of a two-component design:

- **`pi-editor-bridge`** — a pi **extension** (TypeScript) that captures pi's
  live `AutocompleteProvider` and serves it over a local Unix socket.
  ([installed separately](../README.md) via `pi install`).
- **`pi-editor.nvim`** *(this plugin)* — a Neovim (Lua) plugin that activates
  **only** inside a pi-launched editor session, connects to the bridge, and
  renders completion through Neovim's own UI.

> **Dormant by design.** This plugin is **inert** in every ordinary Neovim
> session. It activates only when pi spawned the editor with the
> `PI_EDITOR_BRIDGE` environment variable set (see
> [The `PI_EDITOR_BRIDGE` environment variable](#the-pi_editor_bridge-environment-variable)).
> If nothing happens when you open nvim normally, that is **expected** — see
> [Troubleshooting / FAQ](#troubleshooting--faq).

---

## What it does

- Renders pi's live `AutocompleteProvider` (the same one the TUI uses) — not a
  reimplementation — over the local Unix socket the bridge extension opens.
- A dependency-free floating popup menu (no `nvim-cmp` / `blink.cmp` dependency).
- Pi-faithful **Tab** behavior, `/cmd` argument completion, `@file` fuzzy
  (`fd`), and path completion — all delegated to pi's authoritative logic.
- **Autosaves** the pi temp file on quit so you never lose your prompt.
- Optional **opt-in** adapters for [`blink.cmp`](https://github.com/Saghen/blink.cmp)
  and [`nvim-cmp`](https://github.com/hrsh7th/nvim-cmp) users (see
  [Optional completion-engine sources](#optional-completion-engine-sources)).

## Requirements

- **Neovim >= 0.11** *(not 0.10)* — the exact-UTF-16 cursor conversion in
  `coords.lua` needs the 3-arg `vim.str_utfindex` overload added in 0.11.
  `:checkhealth pi-editor` enforces this floor.
- The **`pi-editor-bridge`** pi extension installed and enabled (`pi list`
  shows `pi-editor-bridge`). It writes `PI_EDITOR_BRIDGE` when pi starts an
  editor.
- **`fd`** *(optional)* — enables pi's fuzzy `@file` search. Without it `@file`
  silently returns nothing, but path completion (directory listing) still works.
  Debian/Ubuntu ship it as `fdfind` (`apt-get install fd-find`).

## Quick start

**1. Install the bridge extension** (the pi side):

```bash
pi install git:github.com/dabstractor/pi-nvim-bridge
pi list      # should show "pi-editor-bridge"
```

**2. Install this plugin** (lazy.nvim) — **NOTE `lazy = false`** so the
VimEnter startup shim sources **before** the VimEnter event that triggers
activation:

```lua
{
  "dabstractor/pi-nvim-bridge",
  dir = "/path/to/pi-nvim-bridge",   -- or use the git url above; the plugin/ dir is the rtp root
  lazy = false,
  sub = "plugin",                     -- point lazy at the plugin/ subdirectory
  config = function() require("pi-editor").setup({}) end,
}
```

> If you are NOT using a plugin manager, simply ensure the `plugin/` directory
> is on your `runtimepath` (e.g. `set rtp+=/path/to/pi-nvim-bridge/plugin` in
> your config). The startup shim (`plugin/pi-editor.lua`) auto-sources on
> VimEnter.

**3. Tell pi to use Neovim as its external editor** — any ONE of:

```bash
export EDITOR=nvim        # or:
export VISUAL=nvim        # or, in pi settings.json (takes precedence):
```

```json
{ "externalEditor": "nvim" }
```

**4. Use it.** In pi, press <kbd>Ctrl+G</kbd> (the `app.editor.external`
keybinding) to open the external editor. Completion appears as you type.
**Submit by SAVE + QUIT** — pi re-reads the temp file only after the editor
**exits** (see [Autosave](#submit-your-prompt--autosave)).

## Configuration

Call `setup()` once from your config. Options are merged over the shipped
defaults (so you only set what you want to change):

```lua
require("pi-editor").setup({
  menu            = { max_height = 12, border = "rounded" },
  debounce_ms     = 20,   -- @/# attachment-context; slash/typing use 0 ms (pi-faithful)
  rpc_timeout_ms  = 2000, -- MUST exceed the bridge fd-abort (1500); warns at setup if <= 1500
  autosave_on_exit = true,
  engine          = "builtin", -- "builtin" (shipped) | "blink" | "cmp" (opt-in sources)
  -- env_var = "PI_EDITOR_BRIDGE", -- override the bridge-descriptor env var name
})
```

**Defaults** (mirror `lua/pi-editor/init.lua` `M.defaults` byte-for-byte):

| Option             | Default             | Notes                                                                                                   |
| ------------------ | ------------------- | ------------------------------------------------------------------------------------------------------- |
| `menu.max_height`  | `12`                | Max visible rows in the floating popup.                                                                 |
| `menu.border`      | `"rounded"`         | `nvim_open_win` border style (`"none"`\|`"single"`\|`"double"`\|`"rounded"`\|`"solid"`\|`"shadow"`\|`string[]`). |
| `debounce_ms`      | `20`                | `@`/`#` attachment-context window. Slash commands and plain typing use `0` ms (pi-faithful, hardcoded). |
| `rpc_timeout_ms`   | `2000`              | Ms before a pending RPC is stale. **MUST exceed the bridge fd-abort (`1500`)**; warns at `setup()` if `<= 1500`. |
| `autosave_on_exit` | `true`              | Write the pi temp file on `VimLeavePre`/`ExitPre` if modified (see [Autosave](#submit-your-prompt--autosave)). |
| `engine`           | `"builtin"`         | `"builtin"` = the shipped floating menu. `"blink"`/`"cmp"` name the **opt-in** adapter sources you register (see [Optional sources](#optional-completion-engine-sources)). **`engine` does NOT auto-switch the UI today** (forward-contract); the builtin menu always runs unless you suppress it yourself. |
| `env_var`          | `"PI_EDITOR_BRIDGE"`| Override the bridge-descriptor env var name (read from `config.env_var`, defaulting to `PI_EDITOR_BRIDGE` when unset). |

`setup()` returns the resolved config and also stores it as
`require("pi-editor").config`. The seven keys above are the full public
configuration surface.

## Completion behavior

Completion is produced by pi's **live** `AutocompleteProvider` (captured by the
bridge extension) — so what you get is exactly what the TUI gets:

- **Slash commands**: `/model`, `/compact`, `/skill:<name>` (when skill commands
  are on), plus prompt templates (`.pi/prompts`, …) and registered extension
  commands (`pi.registerCommand(...)`), each with a description + argument hint.
- **Command-argument completion** where pi supports it (e.g.
  `/model <provider/id>`, `/login <provider>`).
- **`@file` mention completion**: pi's exact fuzzy/`fd` logic (gitignore-aware,
  scored, scoped). Needs `fd` (see [Requirements](#requirements)).
- **Path completion**: bare paths, `./...`, `~/...`, `/abs/...` — identical to pi.
- **`<Tab>`** to force file completion, matching pi's
  `shouldTriggerFileCompletion`.

**Debounce.** Pi does not apply a flat debounce. The window is computed per
request: slash commands and plain typing use `0` ms (immediate); `@...`/`#...`
attachment context uses `debounce_ms` (default `20`). This mirrors pi's TUI
`getAutocompleteDebounceMs`.

**Acceptance.** When you accept an item, the plugin delegates to pi's
`applyCompletion`, which returns the **new full buffer lines** + the final
cursor. The plugin replaces the buffer + positions the cursor. Insertion rules
are therefore identical to the TUI — the plugin never reimplements them.

## Keymaps

These are **buffer-local**, **insert-mode** mappings installed only in
`pi-prompt` buffers (by `ftplugin/pi-prompt.lua`). They do not leak into other
buffers. Each **falls through** to its normal insert-mode default when
completion is inactive or signals "not handled" (e.g. `<Tab>` still indents,
`<CR>` still inserts a newline, when the bridge is not connected).

| Key      | Action                                                                                                              |
| -------- | ------------------------------------------------------------------------------------------------------------------- |
| `<Tab>`  | Trigger or accept the menu (pi-faithful Tab). Menu open + item selected → accept; menu closed → trigger file/slash completion. |
| `<S-Tab>`| Previous completion item.                                                                                           |
| `<C-N>`  | Next completion item.                                                                                               |
| `<Down>` | Next completion item (mirrors `<C-N>`).                                                                             |
| `<C-P>`  | Previous completion item.                                                                                           |
| `<Up>`   | Previous completion item (mirrors `<C-P>`).                                                                         |
| `<C-Y>`  | Accept if the menu is open; otherwise fall through to `i_CTRL-Y`.                                                   |
| `<C-E>`  | Dismiss the completion menu.                                                                                        |
| `<CR>`   | **Accept if the menu is open; otherwise INSERT A NEWLINE.** There is **no Enter-to-submit** (see [Autosave](#submit-your-prompt--autosave)). |

## Submit your prompt / Autosave

There is **no Enter-to-submit** in the external editor — pi re-reads the temp
file **only after the editor exits** (with status 0). So `<CR>` accepts a
completion if the menu is open, otherwise it inserts a newline.

The plugin **autosaves** the buffer on `VimLeavePre`/`ExitPre` when modified
(`autosave_on_exit`, default `true`) — a plain UTF-8 + `\n` write that matches
pi's wire format and does **not** run user `BufWritePre`/`Post` autocmds (no
formatter risk on prompt text). It also sends a best-effort `bye` RPC + closes
the socket on the same events. So `:x` / `ZZ` / a plain save+quit all persist
your prompt.

## Optional completion-engine sources

The builtin floating menu above is the shipped UI and has **no** completion-engine
dependency. If you already drive [**blink.cmp**](https://github.com/Saghen/blink.cmp)
or [**nvim-cmp**](https://github.com/hrsh7th/nvim-cmp), this plugin ships
**opt-in adapter sources** that expose the same live provider through your
engine's UI. They are SHIPPED (P4 is complete); they are **alternatives to the
builtin menu** for users who already use those engines.

> ⚠️ **Additive today.** Registering an adapter source **and** keeping the
> builtin menu yields **double UI**. To use blink/cmp as the *sole* UI, suppress
> the builtin menu yourself (a forward-contract — `engine = "blink"`/`"cmp"`
> does **not** auto-disable the builtin menu today; the builtin menu always
> runs). The adapter sources expose trigger characters `{"/", "@"}` and delegate
> acceptance to pi's `applyCompletion`.

### blink.cmp source (SHIPPED, opt-in)

Register it in **your** blink.cmp config (snippet verbatim from
`lua/pi-editor/blink_source.lua`):

```lua
{
  "Saghen/blink.cmp",
  opts = {
    sources = {
      default = { "pi" },
      providers = {
        pi = { name = "pi", module = "pi-editor.blink_source" },
      },
    },
  },
}
```

The source never requires `blink.cmp` at runtime (it is *your* plugin), so it
stays dormant-safe when blink isn't installed.

### nvim-cmp source (SHIPPED, opt-in)

Register it in **your** nvim-cmp config (snippet verbatim from
`lua/pi-editor/cmp_source.lua`):

```lua
require("cmp").setup({
  sources = cmp.config.sources({ { name = "pi" } }),
})
-- register ONCE (e.g. in the cmp config or a lazy.nvim `config` fn):
require("cmp").register_source("pi", require("pi-editor.cmp_source").new())
```

The source never requires `cmp` at runtime, so it stays dormant-safe when
nvim-cmp isn't installed.

## The `PI_EDITOR_BRIDGE` environment variable

The bridge extension writes a single-line JSON descriptor to the process
environment **inside pi**; the child `$EDITOR` pi spawns inherits it. THIS
PLUGIN keys activation on it.

```jsonc
{
  "transport": "unix",
  "path": "/tmp/pi-editor-bridge-<uuid>.sock",
  "token": "<32-byte hex>",
  "pid": 12345,
  "cwd": "/your/project",
  "fdAvailable": true,
  "serverVersion": "0.1.0"
}
```

> **`echo $PI_EDITOR_BRIDGE` shows NOTHING in your shell — this is expected.**
> The variable is written to `process.env` *inside* the pi process and is only
> visible to the child `$EDITOR` pi spawns. It is **never** exported to your
> shell. This is the #1 source of install confusion; it is not a bug. Inspect
> it from inside the **launched** Neovim:

```vim
:lua print(vim.env.PI_EDITOR_BRIDGE)
```

…or just run `:checkhealth pi-editor` (see [Health & diagnostics](#health--diagnostics)).

> 🔒 **Never paste the live descriptor — especially `token`** — into a bug
> report. `token` is the real auth boundary (see [Security](#security)).

## Health & diagnostics

```vim
:checkhealth pi-editor   " 4 sections: version / env / connection / fd — never throws
:messages                " the one-time "completion unavailable" notify (connect refused / bad token / timeout)
:help pi-editor          " this plugin's vimdoc (after :helptags)
```

A missing `PI_EDITOR_BRIDGE` is reported as **INFO "dormant"** (the expected
normal-session state), **not** an error.

## Troubleshooting / FAQ

**Q: "I installed it and nothing happens in nvim."**
**A: EXPECTED.** The plugin is dormant unless pi launched the editor. Run
`:checkhealth pi-editor` — it will say "dormant" if the env var is unset.

**Q: "Completion doesn't appear when pi opens nvim."**
**A:** Check, in order: (1) the bridge extension loaded — `pi list` shows
`pi-editor-bridge`; (2) `EDITOR`/`VISUAL`/`externalEditor` is `nvim`; (3) this
plugin is installed with `lazy = false` (so the VimEnter shim sources before
activation); (4) read `:messages` for the one-time "completion unavailable"
notify (connect refused / bad token / timeout).

**Q: "`@file` finds nothing."**
**A:** Install [`fd`](https://github.com/sharkdp/fd) (Debian: `fdfind`).
Without it `@file` is empty, but path completion (directory listing) still
works. The bridge may still have `fd` in pi's bin dir even if it is not on your
`$PATH` — see `:checkhealth pi-editor`.

**Q: "I typed, then `:q`, and lost my prompt."**
**A:** pi reads the temp file only after the editor exits with status 0. The
plugin **autosaves** on `VimLeavePre` when modified (`autosave_on_exit`,
default `true`). To be safe, `:w` before `:q`, or quit with `:x`/`ZZ`.

**Q: "I ran `/reload` while the editor was open."**
**A:** The bridge re-captures the provider + re-advertises the descriptor; your
open connection stays valid, and a `commandsChanged` notification refreshes it.

**Q: "Another extension's custom trigger (e.g. `#issues`) doesn't complete."**
**A: KNOWN LIMITATION.** The bridge captures the provider at its own
registration time, so wrappers registered **after** it do not appear. The
**base** provider — slash commands, `/skill:`, templates, paths — is always
captured.

**Q: "Nothing happens in non-interactive mode (`pi -p`)."**
**A:** Correct. `openExternalEditor` is TUI-only, so the bridge no-ops outside
TUI.

**Q: "I set `rpc_timeout_ms` to 1000 and got a warning."**
**A:** It must **exceed** the bridge's fd-abort (`1500`). Setting it lower would
cut off `@file` searches client-side. Leave it at `2000` (default).

## Security

- The Unix socket lives in `os.tmpdir()` with **`0600`** permissions.
- A **32-byte random token** prevents another local process from impersonating
  the editor. It is delivered via `process.env` (process-local, never on disk)
  and validated in the `hello` handshake.
- The server **rejects any method before a valid `hello`**.
- **Never log or echo the token.** Treat the `PI_EDITOR_BRIDGE` descriptor as
  sensitive — don't paste it (especially `token`) into bug reports.

## Development

From the repo root (`pi-nvim-bridge/`):

```bash
# Plenary spec (headless):
timeout 90 nvim --headless --clean -u plugin/tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("plugin/tests/<spec>.lua")'

# Plenary-free smoke (headless, no plenary dep):
timeout 60 nvim --headless --clean -u NORC +"luafile plugin/tests/<module>_smoke.lua" +qa

# Full project validator (5 phases):
./validate.sh
```

The bridge extension (TypeScript) side has its own `node:test` + jiti suites
under `extension/tests/` — see the [root README](../README.md#development).

## Links

- **Vimdoc:** `:help pi-editor` ([`doc/pi-editor.txt`](doc/pi-editor.txt)).
- **PRD:** [`../PRD.md`](../PRD.md) — full design document.
- **Bridge extension README:** [`../README.md`](../README.md) (the `pi install` face).
- [blink.cmp](https://github.com/Saghen/blink.cmp) · [nvim-cmp](https://github.com/hrsh7th/nvim-cmp)
  · [nvim-cmp source-development docs](https://github.com/hrsh7th/nvim-cmp/blob/main/doc/cmp.txt)
- pi docs: [packages](https://pi.dev/docs/packages) · [extensions](https://pi.dev/docs/extensions)

---

**License:** the package manifest declares `"license": "MIT"`, but no `LICENSE`
file is committed yet. Adding one is a separate human decision.