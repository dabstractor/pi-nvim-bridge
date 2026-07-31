# System Context — Delta 002 (omp Host Compat + Shell Completion)

## Overview

This delta layers two changes onto the already-complete P1–P4 bridge:

- **Change A (omp host compat):** Code-complete. The dual-detection mode gate
  `isInteractiveSession(ctx)` at `extension/pi-nvim-bridge.ts:1134-1138` already accepts
  `ctx.mode === "tui"` OR `ctx.hasUI === true`. Residual work is documentation only.
- **Change B (shell completion for `!`/`!!`):** Large new additive subsystem
  (PRD §17). Adds a new Lua module tree (`lua/pi-bridge/shell*`) plus one enriched
  descriptor field-set on Component A (the extension).

## Verified Codebase State (current tree, session 002)

### Extension side (TypeScript)

| Site | Location | Current State |
|---|---|---|
| `BridgeDescriptor` | `extension/protocol.ts:83-91` | 7 REQUIRED fields, no shell fields. Needs 3 optional: `shell?`, `shellSource?`, `shellPath?` |
| `HelloResult` | `extension/protocol.ts:107-112` | `ok/serverVersion/cwd/fdAvailable`. May need shell mirror. |
| `PingResult` | `extension/protocol.ts:117-123` | `ok/pid/cwd/fdAvailable/serverVersion`. May need shell mirror. |
| Descriptor write | `extension/pi-nvim-bridge.ts:570-578` | Single site, guarded by `satisfies BridgeDescriptor`. The edit point. |
| `isInteractiveSession(ctx)` | `extension/pi-nvim-bridge.ts:1134-1138` | **DONE** — `ctx.mode === "tui" \|\| ctx.hasUI === true` |
| `session_start` guard | `extension/pi-nvim-bridge.ts:1167` | **DONE** — `if (!isInteractiveSession(ctx)) return;` |
| `resolveFdAvailable` pattern | `extension/pi-nvim-bridge.ts:346-361` | Cache + getter + `__set*ForTest` seam. **Mirror this for `resolveShell()`** |
| `makeHelloHandler` | `extension/pi-nvim-bridge.ts:623-649` | Deps-injected factory. Returns `HelloResult`. |
| `makePingHandler` | `extension/pi-nvim-bridge.ts:670-686` | Deps-injected factory. Returns `PingResult`. |
| `import type` usage | All `@earendil-works/*` imports | **CONFIRMED** — all type-only (Bun/jiti erased). New imports MUST follow. |
| `package.json` manifest | L28-32 | `"pi": { "extensions": [...] }` — omp's `(pkg.omp ?? pkg.pi).extensions` fallback discovers it. |
| Test framework | `extension/tests/*.test.ts` | `node:test` + `node:assert/strict` + jiti register. Deps-injection pattern. |

### Plugin side (Lua)

| Site | Location | Current State |
|---|---|---|
| `completion_context()` | `lua/pi-bridge/completion.lua:375` | Returns `"slash" \| "path" \| nil`. **Needs `"shell"` branch before slash/path checks.** |
| `do_refresh()` | `lua/pi-bridge/completion.lua:406` | Gen-guard at L454-468. **Needs shell branch calling `shell.complete_current`.** |
| `force_fetch()` | `lua/pi-bridge/completion.lua:508` | Tab path. **Needs shell branch (0-debounce immediate fetch).** |
| Gen-guard pattern | `completion.lua:454-468` | Monotonic `state.gen` captured in cb. **Shell.lua MUST mirror this.** |
| `M.server_info` | `lua/pi-bridge/bridge.lua:188` | Set at L332 in handshake success. **Needs shell fields extracted.** |
| `M.descriptor` | `lua/pi-bridge/init.lua:110` | Set by `activate()`. Has descriptor from `PI_NVIM_BRIDGE` env var. |
| `M.defaults` | `lua/pi-bridge/init.lua:31-40` | menu/debounce_ms/rpc_timeout_ms/autosave_on_exit/engine. **Needs `shell={}` block.** |
| `M.setup()` | `lua/pi-bridge/init.lua:67` | `vim.tbl_deep_extend("force", M.defaults, opts)`. |
| `notify.lua` API | `lua/pi-bridge/notify.lua` | `M.once(category, level, msg)` — dedup'd, vim.schedule'd. **Reuse for all shell notices.** |
| `menu.lua` | `lua/pi-bridge/menu.lua` | Renders `AutocompleteItem { value, label, description? }`. **Reused unchanged.** |
| `health.lua` | `lua/pi-bridge/health.lua` | `:checkhealth pi-bridge` with 4 sections. **Needs shell section.** |
| `coords.lua` | `lua/pi-bridge/coords.lua` | UTF-16 conversion. **NOT used by shell path** (byte offsets only). |
| VimLeavePre teardown | `ftplugin/pi-prompt.lua` | Calls `bridge.on_exit`. **Needs `shell.teardown()` added.** |
| Test framework | `tests/` | Plenary busted (spec) + plenary-free smoke (luafile). |

### External environment

| Shell | Path | Status |
|---|---|---|
| fish | `/usr/bin/fish` | Available — Tier 1 driver testable |
| zsh | `/usr/bin/zsh` | Available — Tier 1 driver testable |
| bash | `/usr/bin/bash` | Available — Tier 2 driver testable |
| nvim | v0.12.4 | LuaJIT 2.1, `vim.uv.spawn` available |

## Architectural Invariants (govern all of Phase D2)

1. **Daemon is a child of the nvim process** (`vim.uv.spawn`), NOT of pi. Never touches the bridge socket.
2. **Shell path uses byte offsets, not UTF-16.** No `coords.lua` conversion. Accept uses `nvim_buf_set_text` (range edit).
3. **Supersession mirrors `completion.lua`** — monotonic `state.gen` captured in response callback.
4. **Never blocks, never throws** — every `vim.uv` call and decode is `pcall`'d.
5. **`prefer:"pi"` is the default** — completion defaults to pi's resolved execution shell.
6. **`complete -C` / capture-widget / `compgen` never run inside nvim's stdin** — they run in the spawned shell subprocess over `vim.uv` pipes.

## Key Design Decisions

- **Shell resolution** cannot read `settingsManager`/`getShellConfig` (not on `ExtensionContext`). The extension replicates the resolution via `process.env.PI_NVIM_SHELL` → `process.env.SHELL` → `/bin/bash`.
- **Shell daemon** is persistent (spawned once, reused per keystroke). Sourcing rc files costs 100ms–1s+.
- **Framing protocol** uses sentinels: `__PIREQ__\t{json}\n` (request) and `__PIRESP_START__`/`__PIRESP_END__` (response) to isolate from shell prompt noise.
- **Accept is local** (word replacement + quoting), NOT pi's `applyCompletion` (which does whole-buffer rewrite with UTF-16 coords).

## Dependency Chain (PRD §17.16)

```
D2.T1 (descriptor fields) ─────────────────────────────┐
                                                        ▼
D2.T2 (daemon manager + spike) ────────────────┐       │
                                                ▼       │
D2.T3 (routing + complete_current + notices) ───┤       │
D2.T4 (fish driver + accept) ───────────────────┤       │
                                                ▼       │
D2.T5 (zsh + bash drivers) ─────────────────────┤       │
                                                ▼       │
D2.T6 (health + config + vimdoc) ───────────────┤       │
                                                ▼       │
Final (Mode B docs: README + cross-links) ◄─────┴───────┘
```