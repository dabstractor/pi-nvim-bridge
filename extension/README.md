# pi-nvim-bridge (extension)

> The **pi-side half** of the two-component bridge. It captures pi's live
> autocomplete provider and serves it over a local Unix socket to the external
> `$EDITOR` (Neovim) pi spawns. The companion **Neovim plugin** (`pi-bridge.nvim`,
> shipped in this same repo at the root) connects to that socket and renders the
> completion inside Neovim.

This file documents the **extension's own surface** — what it is, how it
activates, what the `PI_NVIM_BRIDGE` descriptor contains (including the
optional `shell`/`shellSource`/`shellPath` advisory fields), and the
`PI_NVIM_SHELL` opt-in that mirrors pi's `shellPath` setting. For the whole
repo (extension **+** Neovim plugin install/config), read the **root
[`README.md`](../README.md)** and `:help pi-bridge`
([`doc/pi-bridge.txt`](../doc/pi-bridge.txt)).

> 📦 **npm tarball vs. git repo.** The published `pi-nvim-bridge` package
> ships only `extension/*.ts` + the root `README.md` + `LICENSE`
> (`package.json` `files`). This `extension/README.md` lives in the **git
> repo** (source browsers, GitHub) and is **not** part of the npm tarball —
> that is intentional (the npm page shows the root README). Do not widen
> `files` to ship it.

## Installation

```bash
# Preferred: install from npm
pi install npm:pi-nvim-bridge

# Or from a local clone
git clone https://github.com/dabstractor/pi-nvim-bridge
cd pi-nvim-bridge
pi install .
```

Verify:

```bash
pi list          # should show "pi-nvim-bridge"
```

### oh-my-pi (`omp`)

The extension also runs under the **oh-my-pi** fork (`omp`, Bun runtime) with
**zero code change** (see [Host compatibility](#host-compatibility--pi-and-oh-my-pi-omp)):

```bash
omp plugin install npm:pi-nvim-bridge
omp plugin list        # should show "pi-nvim-bridge"
```

> The companion `pi-bridge.nvim` plugin install is **not** covered here — it
> is a Neovim plugin (lazy.nvim, etc.). See the root
> [`README.md`](../README.md#installation) for the lazy.nvim spec and the
> `$EDITOR`/`externalEditor` configuration.

## How it works

1. **Live-provider capture.** On `session_start`, the extension registers a
   **pass-through** `AutocompleteProviderFactory` with pi via
   `ctx.ui.addAutocompleteProvider`. pi hands the factory the current provider
   chain; the extension stashes it and returns it **unchanged** — so the bridge
   serves the *same* completion the TUI uses, not a snapshot. (Must re-run every
   `session_start` because pi clears the wrapper list on session reset.)
2. **Process-local discovery.** pi spawns `$EDITOR` with `stdio: "inherit"` and
   **no `env:` override**, so the child Neovim **inherits pi's `process.env`**.
   The bridge writes a JSON `BridgeDescriptor` to `process.env.PI_NVIM_BRIDGE`
   *inside* pi on `session_start`, before any `Ctrl+G` launch — so the spawned
   Neovim sees `vim.env.PI_NVIM_BRIDGE`. The companion plugin's `VimEnter` gate
   `vim.json.decode`s it to find the socket path + token; absent/unparseable ⇒
   the plugin stays dormant.
3. **JSON-RPC over a Unix socket.** The bridge listens on a `0600` Unix socket
   and speaks newline-delimited JSON-RPC 2.0. Methods: `hello` (token
   handshake), `ping`, `getSuggestions`, `applyCompletion`,
   `shouldTriggerFileCompletion`, `getCommands`, `bye`, plus the `commandsChanged`
   server→client notification. Completion acceptance delegates back into pi's
   own `applyCompletion`, so insertion is byte-for-byte identical to the TUI.

## The `PI_NVIM_BRIDGE` descriptor

The descriptor is a single-line JSON object written to `process.env.PI_NVIM_BRIDGE`.
The 7 base fields are **required**; the 3 `shell*` fields are **optional and
advisory** (added in §17.10; absent on older bridges is fine — the plugin falls
back to `$SHELL`, then `/bin/bash`).

| Field | Type | Required? | Source / meaning |
| --- | --- | --- | --- |
| `transport` | `"unix"` | yes | literal v1 marker (a future TCP variant is named in PRD §5.1). |
| `path` | string | yes | socket path — `/tmp/pi-nvim-bridge-<uuid>.sock`, mode `0600`. |
| `token` | string | yes | 32-byte hex secret; the **real** auth boundary (validated in `hello`). Never log it. |
| `pid` | number | yes | `process.pid` of the pi process running the bridge. |
| `cwd` | string | yes | `ctx.cwd` — the session working directory. |
| `fdAvailable` | boolean | yes | whether `fd`/`fdfind` is resolvable (gates rich `@file` search). |
| `serverVersion` | string | yes | bridge protocol version (`"0.1.0"`); **independent** of the npm package version. |
| `shell` | string | **no** | §17.10 advisory: the shell pi will execute `!`/`!!` commands in. |
| `shellSource` | `"pi" \| "$SHELL" \| "default"` | **no** | how `shell` was derived (see [PI_NVIM_SHELL](#pi_nvim_shell--matching-pis-execution-shell)). |
| `shellPath` | string | **no** | raw shell-path mirror; present **only** when `shellSource === "pi"`. |

A typical machine (no `PI_NVIM_SHELL`, `$SHELL=/bin/zsh`) emits — note
**no `shellPath` key** (it is `undefined`, and `JSON.stringify` drops it):

```jsonc
{
  "transport": "unix",
  "path": "/tmp/pi-nvim-bridge-<uuid>.sock",
  "token": "<32-byte hex>",
  "pid": 12345,
  "cwd": "/your/project",
  "fdAvailable": true,
  "serverVersion": "0.1.0",
  "shell": "/bin/zsh",
  "shellSource": "$SHELL"
}
```

The `hello` result and `ping` result **mirror** these `shell*` fields (so the
plugin can read the resolved shell post-handshake too). The plugin uses the
advisory `shell*` fields to match pi's execution shell for `!`/`!!` completion
(`prefer: "pi"`); for the full `prefer` contract + fallback chain see
`:help pi-bridge-shell` ([`doc/pi-bridge-shell.txt`](../doc/pi-bridge-shell.txt)).

> **`echo $PI_NVIM_BRIDGE` (and `echo $PI_NVIM_SHELL`) show nothing in your
> shell — this is expected.** `PI_NVIM_BRIDGE` is written to `process.env`
> *inside* pi and is only visible to the child `$EDITOR` pi spawns; it is never
> exported to your shell. `PI_NVIM_SHELL` is the reverse: **you** set it in the
> shell that launches pi so the extension can read it. To inspect the descriptor
> from inside the launched Neovim: `:lua print(vim.env.PI_NVIM_BRIDGE)`.

## `PI_NVIM_SHELL` — matching pi's execution shell

`PI_NVIM_SHELL` is an opt-in env var the extension reads to populate the
advisory `shell`/`shellSource`/`shellPath` descriptor fields. It is a
**bridge-local mirror** of pi's `shellPath` setting. The resolution order (in
`resolveShell()`, `extension/pi-nvim-bridge.ts`) is exactly three branches:

1. **If `PI_NVIM_SHELL` is set** → `shell = <that value>`,
   `shellSource = "pi"`, `shellPath = <that value>`.
   *(This is the "I want `prefer:"pi"` to resolve to a specific shell"
   branch.)*
2. **Else if `$SHELL` is set** → `shell = $SHELL`, `shellSource = "$SHELL"`,
   **no `shellPath`**. *(Typical machine default — advisory only.)*
3. **Else** → `shell = "/bin/bash"`, `shellSource = "default"`,
   **no `shellPath`**. *(pi's `getShellConfig` Unix default.)*

**Why it exists (the honesty note).** `settingsManager` / `getShellConfig()`
are **not** on pi's `ExtensionContext`, so this extension *cannot* read pi's
real `shellPath` setting through the public API. `PI_NVIM_SHELL` is the
workaround: the user sets it once to advertise the shell pi runs `!`/`!!` in,
so the plugin's `prefer:"pi"` resolver can match it instead of falling back to
`$SHELL`. (PRD §17.10.2 / §17.17 — a future upstream `ctx.getShellConfig()`
would retire this manual mirror.) From the plugin side, the same gap + the
one-time `:messages` warning are documented in `:help pi-bridge-shell` §3
([`doc/pi-bridge-shell.txt`](../doc/pi-bridge-shell.txt),
`pi-bridge-shell-prefer`).

**Worked example — a zsh user who wants native zsh `!` completions:**

```bash
# In the shell that launches pi:
export PI_NVIM_SHELL=/bin/zsh
```

```jsonc
// → the descriptor now gains all three shell.* fields:
{
  // …transport, path, token, pid, cwd, fdAvailable, serverVersion as above…
  "shell": "/bin/zsh",
  "shellSource": "pi",
  "shellPath": "/bin/zsh"
}
```

With that, the plugin's `prefer:"pi"` resolves to zsh → native zsh
completions, **and** (if you also point pi's `shellPath` at zsh) pi runs `!`
lines in zsh, so completion and execution agree.

## Host compatibility — pi and oh-my-pi (`omp`)

The extension runs unchanged under both **pi** (`@earendil-works/pi-coding-agent`)
and the **oh-my-pi** fork (`omp`, the `omp` binary):

- **Manifest fallback.** omp reads the same `"pi": { extensions }` field pi
  does, via `(pkg.omp ?? pkg.pi).extensions` — no manifest change is needed.
- **Interactive-session guard.** The bridge only activates in an interactive
  (TUI) session. pi signals this with `ctx.mode === "tui"`; omp **dropped**
  `ctx.mode` and exposes `ctx.hasUI: boolean` instead (true in TUI, false in
  print/RPC). The extension's `isInteractiveSession(ctx)` accepts **either**
  signal (`ctx.mode === "tui"` **OR** `ctx.hasUI === true`), so without the
  dual guard omp's `ctx.mode === undefined` would make the bridge silently
  no-op and never advertise `PI_NVIM_BRIDGE`.

In non-interactive modes (`pi -p` / `pi --rpc` / `pi --json`, or omp headless)
the bridge performs zero work — no provider capture, no socket bind, no env-var
advertisement.

## Development

```bash
# Type-check (the portable, reproducible gate)
npm run typecheck
# …or directly:
npx tsc --noEmit -p extension/tsconfig.json
```

Tests use **`node:test`** with **jiti** (TypeScript loaded directly, no build
step). Run a single suite:

```bash
JITI_REG=<path-to-pi's-bundled>/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/shell-resolver.test.ts
```

The `JITI_REG` path is machine-specific (it points at pi's bundled jiti);
adjust it to your own pi install. Suites live in
[`extension/tests/`](./tests) — notably
[`shell-resolver.test.ts`](./tests/shell-resolver.test.ts) is the executable
spec for the `resolveShell()` 3-branch chain documented above.

## See also

- **Root [`README.md`](../README.md)** — whole-repo docs (extension + Neovim
  plugin install, lazy.nvim spec, `$EDITOR` config, troubleshooting, security,
  releasing).
- **`:help pi-bridge`** ([`doc/pi-bridge.txt`](../doc/pi-bridge.txt)) — the
  Neovim plugin vimdoc.
- **`:help pi-bridge-shell`** ([`doc/pi-bridge-shell.txt`](../doc/pi-bridge-shell.txt))
  — the `!`/`!!` shell-completion guide; the `prefer` contract and the
  descriptor `shell*` fields from the plugin/consumer side.
- **[`PRD.md`](../PRD.md)** — full design document. Relevant sections:
  §2.1 (process.env inheritance discovery), §6.8 (pi-vs-omp host compat),
  §17.10 / §17.10.2 (the `shell*` descriptor fields + `PI_NVIM_SHELL`),
  §17.17 (the future upstream `ctx.getShellConfig()` that would retire the
  manual mirror).