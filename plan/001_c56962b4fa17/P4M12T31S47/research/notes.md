# Research Notes — P4.M12.T31.S47: NVIM_APPNAME minimal-config optimization

## 0. Task statement (from plan_status)

> P4.M12.T31.S47: Document & implement optional NVIM_APPNAME env var in bridge
> extension — 0.5 points. Phase 4 step 18 of the PRD implementation plan.

PRD §10.4 (the spec line we implement):
> For faster editor startup with a minimal config, the bridge extension may
> **additionally** set `process.env.NVIM_APPNAME = "pi-editor"` (documented
> opt‑in), and the user maintains a tiny `~/.config/pi-editor/` that loads only
> `pi-bridge.nvim`. This is an **optional optimization**, not required.

So the EXTENSION sets NVIM_APPNAME (not the user manually exporting it), and it
must be **opt-in** (default OFF). Docs are part of the deliverable.

## 1. How should the opt-in be configured? (the key decision)

### 1.1 What pi exposes to extensions (verified against installed source)

- `ExtensionContext` (`dist/core/extensions/types.d.ts:208-231`) exposes:
  `ui`, `mode`, `hasUI`, `cwd`, `sessionManager`, `modelRegistry`, `model`,
  `isIdle()`, `isProjectTrusted()`, `signal`, `abort()`, `hasPendingMessages()`,
  `shutdown()`, `getContextUsage()`, `compact()`, `getSystemPrompt()`.
  **There is NO `settings` / `getSettings` / `config` on the context.**
- `ExtensionAPI` (`types.d.ts:839+`) exposes event `on(...)`, `registerTool`,
  `registerCommand`, `registerShortcut`, `registerFlag(name, {type, default,
  description})`, `getFlag(name)`, `registerProvider`, `sendMessage`, `exec`, …
  `registerFlag`/`getFlag` are **CLI flags** (consumed via `pi --<flag>`), and
  `agent-session.js:2051` shows flags are snapshotted per agent session
  (`getFlagValues()`). They are a per-invocation mechanism, not "enable once in
  settings.json". Not a clean fit for "user opts in once".
- `Settings` interface (`dist/core/settings-manager.ts`, `export interface
  Settings`) is a **fixed** set of named fields (`externalEditor`, `compaction`,
  `retry`, `extensions`, `packages`, …). There is **no generic
  extension-config bag** and no `ctx.settings`. An extension cannot cleanly read
  a custom `{ "piEditorBridge": { "nvimAppname": true } }` field — it would be
  an untyped unknown key, and `migrateSettings` / `deepMergeSettings` don't
  surface arbitrary keys via any typed getter.

**Conclusion: pi gives extensions no settings-based config channel.** The only
clean, idiomatic, "set once" opt-in surface available to an extension is a
**dedicated environment variable** the user sets in their shell/rc (or in the
launch wrapper). The bridge already relies on `process.env` for its core
discovery (`PI_NVIM_BRIDGE`), so this is consistent.

### 1.2 pi's own env-var-toggle precedent (the clincher)

pi's `SettingsManager` itself reads `PI_*` env vars as opt-in toggles alongside
typed settings — this is the established pi pattern:

- `getClearOnShrink()` → `process.env.PI_CLEAR_ON_SHRINK === "1"`
  (`settings-manager.ts`, "Settings takes precedence, then env var, then default
  false").
- `getShowHardwareCursor()` → `process.env.PI_HARDWARE_CURSOR === "1"`
  (`getShowHardwareCursor(): boolean { return this.settings.showHardwareCursor
  ?? process.env.PI_HARDWARE_CURSOR === "1"; }`).

A `PI_EDITOR_NVIM_APPNAME` env var is the SAME idiom. **This is the chosen
opt-in mechanism.** It is:
- opt-in (absent ⇒ feature OFF, zero behavior change — S16/regression-safe),
- set once by the user in their shell/rc,
- readable inside the extension with no pi API beyond `process.env`,
- symmetric with the existing `PI_NVIM_BRIDGE` write/delete lifecycle.

### 1.3 Value semantics for PI_EDITOR_NVIM_APPNAME

To be both a simple boolean toggle AND allow a custom appname:

| `PI_EDITOR_NVIM_APPNAME` value | Resolved appname |
|---|---|
| unset / not present | `undefined` → feature OFF (do nothing) |
| `""` (empty) | default `"pi-editor"` |
| `1`, `true`, `yes`, `on` (case-insensitive) | default `"pi-editor"` |
| any other non-empty string (e.g. `pi-fast`) | that literal string |

This keeps the common case trivial (`=1`) while allowing a custom minimal
config dir name. Default constant `DEFAULT_NVIM_APPNAME = "pi-editor"`
(matches PRD §10.4 verbatim).

## 2. NVIM_APPNAME semantics (external, verified)

Source: Neovim `:help $NVIM_APPNAME`
(https://neovim.io/doc/user/starting.html#$NVIM_APPNAME) and the Neovim
`starting` docs:

> "For example, setting $NVIM_APPNAME to "foo" before starting will cause Nvim
> to look for configuration files in $XDG_CONFIG_HOME/foo instead of
> $XDG_CONFIG_HOME/nvim."

Key facts:

1. **Scope.** NVIM_APPNAME replaces the `"nvim"` segment in EVERY `stdpath()`
   path on all platforms: config, data, state, log, shada, undo, sessions.
   Linux: `~/.config/<appname>`, `~/.local/share/<appname>`,
   `~/.local/state/<appname>`. macOS: `~/Library/Application
   Support/<appname>` etc. Windows: `%LOCALAPPDATA%\<appname>`. So
   `NVIM_APPNAME=pi-editor` ⇒ nvim reads `~/.config/pi-editor/init.lua`.
2. **Missing config dir does NOT error.** nvim starts with defaults and an
   empty user config if `~/.config/pi-editor/` is absent (it does not create it
   eagerly either). This is the SAFE foundation: if a user opts in before
   creating the dir, the launched editor still works — just with no user
   config. (vi.stackexchange + widespread practice confirm.) The bridge must
   NOT pre-create or check the dir; that's the user's responsibility (docs).
3. **Invalid values.** nvim rejects an appname containing a path separator
   (`/` or `\`) or otherwise not a simple directory name. We do NOT validate
   this in the bridge (out of scope; nvim will surface the error). Documented
   as a gotcha.
4. **Last-writer-wins via inherited process.env.** The editor is a CHILD of
   pi (`spawn(editor, [tmpFile], { stdio:"inherit" })` with NO `env:` override
   — interactive-mode.ts:3811-3816, per S16 research). Whatever
   `process.env.NVIM_APPNAME` holds at spawn time is what nvim sees. So
   writing it inside pi before any Ctrl+G launch is sufficient.

## 3. SAVE/RESTORE — why this is NOT a plain write/delete like PI_NVIM_BRIDGE

CRITICAL asymmetry vs S16:

- `PI_NVIM_BRIDGE` is a name pi **invents and owns**. `delete` on stop is
  correct and harmless — no one else uses that var.
- `NVIM_APPNAME` is a **standard Neovim var the USER may already export**
  globally (e.g. `NVIM_APPNAME=work` in their shell for a daily-driver
  profile). If the bridge did `delete process.env.NVIM_APPNAME` on stop, it
  would **permanently clobber the user's global** for the rest of the pi
  process — a real bug, especially across `/reload`.

Therefore the bridge must **save the baseline and restore it**:

- On apply (startBridge): capture `process.env.NVIM_APPNAME` AS-IS into
  `nvimAppnameBaseline`, then set it to the resolved appname. Set
  `nvimAppnameApplied = true`.
- On restore (stopBridge): if applied, write the baseline back (or `delete`
  if the baseline was `undefined`). Reset flags.

Idempotency across reload/new/resume/fork: startBridge calls stopBridge FIRST
(existing pattern), so restore runs before re-apply ⇒ the baseline captured at
re-apply is the genuine environment baseline, not the bridge's own prior
override. Verified correct for the two-startBridge sequence (S16 TEST 3
analogue).

If opt-in is OFF, `applyNvimAppname()` is a pure no-op (returns immediately) —
so the existing `bridge-env.test.ts` suite is UNAFFECTED (no NVIM_APPNAME
mutation, descriptor still exactly 7 keys because NVIM_APPNAME is a SEPARATE
`process.env` entry, NOT a new BridgeDescriptor field).

## 4. TUI guard inheritance

The NVIM_APPNAME apply must live in `startBridge` (not a separate session_start
hook) so it inherits the existing `if (ctx.mode !== "tui") return;` guard at
the top of session_start — the editor is ONLY launched in TUI mode, so setting
NVIM_APPNAME headlessly would be pointless and surprising. stopBridge's restore
is unconditional (safe no-op when not applied). The bridge-env TEST 4
(non-tui modes never set the env) continues to hold because startBridge is
never reached in non-tui.

## 5. Testability seam

`process.env` IS the natural seam here (bridge-env.test.ts already manipulates
`process.env.PI_NVIM_BRIDGE` directly). No new `__deps` entry needed. Export
`resolveNvimAppname()` (pure parse of `PI_EDITOR_NVIM_APPNAME` →
`string | undefined`) so its value table (§1.3) can be unit-tested without
touching startBridge. Apply/restore state can be inspected via
`process.env.NVIM_APPNAME` before/after, mirroring how S16 inspects
`process.env.PI_NVIM_BRIDGE`. Provide
`__resetNvimAppnameStateForTest()` to zero the module's `nvimAppnameApplied`/
`nvimAppnameBaseline` between tests (parallels `__setFdAvailableForTest`).

## 6. Validation commands (verified from S16 PRP + repo)

- Type-check: `npx tsc --noEmit -p extension/tsconfig.json` (exits 0 today;
  must stay 0). No tsconfig edit — `include: ["tests/**/*.ts"]` auto-covers the
  new test file.
- Test runner: `node --import "$JITI_REG" extension/tests/nvim-appname.test.ts`
  where
  `JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs`.
  Reporter is `node:test` ("ℹ pass N / ℹ fail N").
- Regression suites that MUST stay green (they call startBridge/stopBridge):
  `bridge-env` (S16), `bridge-lifecycle` (S5), `bridge-lifecycle-wiring` (S6),
  `mode-guard` (S3).

## 7. Scope guards

- ONLY source file modified: `extension/pi-editor-bridge.ts` (add constants +
  resolveNvimAppname + apply/restore + wire into startBridge/stopBridge + [Mode
  A] JSDoc). `protocol.ts`, `connection.ts`, `jsonl-reader.ts`, handlers —
  UNTOUCHED. BridgeDescriptor stays 7 keys (NVIM_APPNAME is not a descriptor
  field).
- README.md: update the existing "Optional startup optimization" paragraph to
  document `PI_EDITOR_NVIM_APPNAME` (the opt-in the bridge reads) and keep the
  manual `NVIM_APPNAME=pi-editor` alternative. This is the "document" half of
  the deliverable, scoped to THIS feature (the full README rewrite is a
  separate task P3.M11.T28.S44 — NOT this one).
- Do NOT touch `PRD.md`, `plan/`, `tasks.json`, `prd_snapshot.md`.