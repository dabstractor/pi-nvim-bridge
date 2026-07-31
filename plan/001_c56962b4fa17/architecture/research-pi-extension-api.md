# Pi Extension API — Architectural Validation Findings

Repository: `~/projects/pi` (monorepo, package `@earendil-works/pi-coding-agent@0.80.10`).
Scope: verify extension lifecycle, types, RPC framing, settings, and import/export
surface for a bridge extension. All claims below are backed by exact file/line
references.

---

## Files Retrieved

1. `packages/coding-agent/src/core/extensions/types.ts` (lines 1-1683) — **the** extension type surface. `ExtensionAPI`, `ExtensionContext`, `ExtensionUIContext`, all event/result types, `ExtensionFactory`, `ExtensionMode`.
2. `packages/coding-agent/src/core/extensions/index.ts` (full) — re-export barrel for the extensions subsystem.
3. `packages/coding-agent/src/core/extensions/loader.ts` (lines 485-525) — `loadExtensionFromFactory()` confirming the `(pi: ExtensionAPI) => void | Promise<void>` factory invocation.
4. `packages/coding-agent/docs/extensions.md` (lines 1-2944) — full extension docs incl. Autocomplete Providers (2607-2650), Lifecycle Overview, `ctx.mode`, background-resources guidance.
5. `packages/coding-agent/docs/rpc.md` (full) — RPC JSONL protocol, extension UI sub-protocol.
6. `packages/coding-agent/src/core/settings-manager.ts` (lines 85-114, 854-871) — `externalEditor` setting + `getExternalEditorCommand()`.
7. `packages/coding-agent/src/core/slash-commands.ts` (full) — `BUILTIN_SLASH_COMMANDS`.
8. `packages/coding-agent/src/index.ts` (lines 1-360) — public package exports.
9. `packages/coding-agent/src/core/index.ts` (full) — core barrel.
10. `packages/tui/src/autocomplete.ts` (lines 219-293) — `AutocompleteProvider`, `AutocompleteItem`, `AutocompleteSuggestions`.
11. `packages/coding-agent/examples/extensions/github-issue-autocomplete.ts` (full) — canonical `addAutocompleteProvider` + `session_start` example.
12. `packages/coding-agent/examples/extensions/rpc-demo.ts` (full) — exercises all RPC-supported UI methods.
13. `packages/coding-agent/examples/extensions/auto-commit-on-exit.ts` (lines 1-60) — canonical `session_shutdown` resource-cleanup example.
14. `packages/coding-agent/src/modes/rpc/rpc-mode.ts` (lines 266-281) — RPC `addAutocompleteProvider` is a **no-op**.
15. `packages/coding-agent/src/modes/interactive/interactive-mode.ts` (lines 2138-2162) — TUI `addAutocompleteProvider` actually wires providers.

---

## 1. Extension Type Surface (`types.ts`)

### ExtensionUIContext.addAutocompleteProvider — CONFIRMED

`types.ts:209`
```ts
/** Wrap the current autocomplete provider with additional behavior. */
export type AutocompleteProviderFactory = (current: AutocompleteProvider) => AutocompleteProvider;
```

`types.ts` (inside `ExtensionUIContext`, ~line 320)
```ts
/** Stack additional autocomplete behavior on top of the built-in provider. */
addAutocompleteProvider(factory: AutocompleteProviderFactory): void;
```

`AutocompleteProvider` is imported from `@earendil-works/pi-tui`
(`packages/tui/src/autocomplete.ts:241`):
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
- `AutocompleteItem` (`tui/src/autocomplete.ts:219`): `{ value: string; label: string; description?: string }`
- `AutocompleteSuggestions` (`tui/src/autocomplete.ts:236`): `{ items: AutocompleteItem[]; prefix: string }`

**CRITICAL for bridge design:** In RPC mode `addAutocompleteProvider` is a no-op
(`modes/rpc/rpc-mode.ts:271-273`). It only actually layers providers in TUI
mode (`modes/interactive/interactive-mode.ts:2143-2146` — pushes to
`this.autocompleteProviderWrappers` then `setupAutocompleteProvider()`).
A bridge extension that wants completions surfaced must target TUI mode
(`ctx.mode === "tui"`) or expose its own UI.

### ExtensionContext — CONFIRMED (`types.ts:437-473`)

```ts
export type ExtensionMode = "tui" | "rpc" | "json" | "print";

export interface ExtensionContext {
  ui: ExtensionUIContext;
  /** Current run mode. Use "tui" to guard terminal-only UI such as custom components. */
  mode: ExtensionMode;
  /** Whether dialog-capable UI is available (true in TUI and RPC modes) */
  hasUI: boolean;
  /** Current working directory */
  cwd: string;
  sessionManager: ReadonlySessionManager;
  modelRegistry: ModelRegistry;
  model: Model<any> | undefined;
  isIdle(): boolean;
  isProjectTrusted(): boolean;
  signal: AbortSignal | undefined;
  abort(): void;
  hasPendingMessages(): boolean;
  shutdown(): void;
  getContextUsage(): ContextUsage | undefined;
  compact(options?: CompactOptions): void;
  getSystemPrompt(): string;
}
```
- `ctx.cwd` ✓ present (`types.ts:444`).
- `ctx.mode` ✓ present; `ExtensionMode = "tui" | "rpc" | "json" | "print"`. Docs confirm: *"Use `ctx.mode === "tui"` to guard terminal-only features such as `custom()`"* (`extensions.md`, "ctx.mode" section).
- `ctx.hasUI` is `true` in TUI **and** RPC modes (`extensions.md` ctx.hasUI section; `false` only in print + json).

There is no separate `ExtensionAPI`-vs-`ExtensionContext` confusion: `ExtensionContext`
is the per-event/per-tool `ctx`, while `ExtensionAPI` is the `pi` object passed to
the factory (see §8).

### Lifecycle event types — CONFIRMED

`types.ts` Session Events block (lines ~640-760):

```ts
export interface SessionStartEvent {
  type: "session_start";
  /** Why this session start happened. */
  reason: "startup" | "reload" | "new" | "resume" | "fork";
  /** Previously active session file. Present for "new", "resume", and "fork". */
  previousSessionFile?: string;
}

export interface SessionShutdownEvent {
  type: "session_shutdown";
  reason: "quit" | "reload" | "new" | "resume" | "fork";
  /** Destination session file when shutting down due to session replacement. */
  targetSessionFile?: string;
}
```
- `session_start.reason`: `"startup" | "reload" | "new" | "resume" | "fork"`.
- `session_shutdown.reason`: `"quit" | "reload" | "new" | "resume" | "fork"`.

Other session events available: `session_info_changed`, `session_before_switch`,
`session_before_fork`, `session_before_compact` / `session_compact`,
`session_before_tree` / `session_tree`. Full lifecycle diagram is in
`extensions.md` "Lifecycle Overview" section.

### Background resources / sockets guidance — CONFIRMED

`extensions.md` (section "Long-lived resources and shutdown"):
> "Extension factories may run in invocations that never start a session.
> **Do not start background resources such as processes, sockets, file watchers,
> or timers from the factory.** Defer background resource startup until
> `session_start` or the command/tool/event that needs the resource. Register an
> **idempotent `session_shutdown` handler** to close any session-scoped
> resources you start."

This directly validates a bridge extension pattern: open the socket in
`session_start`, close it in `session_shutdown`. Reference example:
`examples/extensions/auto-commit-on-exit.ts` (cleanup work in `session_shutdown`).

---

## 2. Extension Docs (`extensions.md`)

### Autocomplete Providers section — CONFIRMED (`extensions.md:2607-2650`)

Pattern:
```ts
pi.on("session_start", (_event, ctx) => {
  ctx.ui.addAutocompleteProvider((current) => ({
    triggerCharacters: ["#"],
    async getSuggestions(lines, cursorLine, cursorCol, options) {
      // inspect text before cursor; return your suggestions or
      // delegate to current.getSuggestions(...)
    },
    applyCompletion(lines, cursorLine, cursorCol, item, prefix) {
      return current.applyCompletion(lines, cursorLine, cursorCol, item, prefix);
    },
    shouldTriggerFileCompletion(lines, cursorLine, cursorCol) {
      return current.shouldTriggerFileCompletion?.(lines, cursorLine, cursorCol) ?? true;
    },
  }));
});
```
Canonical example: `examples/extensions/github-issue-autocomplete.ts` — preloads
issues via `gh issue list` in `session_start`, uses `fuzzyFilter` from
`@earendil-works/pi-tui` to filter locally, returns `null`/delegates to
`current` when not relevant.

### How extensions register / APIs available

- Export a **default factory** `(pi: ExtensionAPI) => void | Promise<void>`.
  Loaded via jiti (TS works without compile). If factory returns a `Promise`,
  pi awaits it **before** `session_start`, `resources_discover`, and before
  queued `registerProvider()` calls flush (`extensions.md`, "Writing an
  Extension" / "Async factory functions").
- Locations: `~/.pi/agent/extensions/*.ts` (or `*/index.ts`), `.pi/extensions/*.ts`
  (project-local, **only after project trust**), plus `settings.json`
  `extensions: [...]` and `packages: [...]` arrays, or `-e ./path.ts` (`extensions.md`,
  "Extension Locations"). `CONFIG_DIR_NAME` (defaults to `.pi`, `config.ts:491`)
  should be used instead of hardcoding `.pi`.
- Importable packages (`extensions.md` "Available Imports"):
  - `@earendil-works/pi-coding-agent` — extension types + helpers.
  - `typebox` — tool parameter schemas.
  - `@earendil-works/pi-ai` — e.g. `StringEnum`.
  - `@earendil-works/pi-tui` — TUI components, `AutocompleteItem/Provider/Suggestions`, `fuzzyFilter`.
  - Node built-ins (`node:fs`, `node:path`, `node:net`, …) and npm deps in a
    sibling `package.json` resolved automatically.

### `ctx.mode` for TUI detection — CONFIRMED

`extensions.md` ("ctx.mode"): values `"tui" | "rpc" | "json" | "print"`. Use
`ctx.mode === "tui"` to guard terminal-only features (`custom()`, component
factories, terminal input, direct TUI rendering). In RPC mode some
TUI-specific `ExtensionUIContext` methods are no-ops / return defaults
(see `rpc.md` "Extension UI Protocol" and §3 below).

---

## 3. RPC Protocol (`rpc.md`) — JSONL Framing — CONFIRMED

`rpc.md` "Framing" section:
> RPC mode uses **strict JSONL semantics with LF (`\n`) as the only record
> delimiter.** … Split records on `\n` only. Accept optional `\r\n` input by
> stripping a trailing `\r`. **Do not use generic line readers that treat
> Unicode separators as newlines.** In particular, Node `readline` is **not
> protocol-compliant** because it also splits on `U+2028`/`U+2029`, valid
> inside JSON strings.

Start RPC mode: `pi --mode rpc [options]`. Commands: JSON objects to stdin, one
per line. Responses: `{"type":"response","command":...,"success":...[, "data":..., "error":...]}`.
Events: streamed to stdout as JSON lines (no `id` field). Optional request `id`
echoed in matching response.

### Extension UI sub-protocol (relevant for a bridge)
- **Dialog methods** (`select`, `confirm`, `input`, `editor`): emit
  `extension_ui_request` on stdout, **block** until client replies with
  `extension_ui_response` on stdin with matching `id`. `timeout` (ms) is
  handled agent-side (auto-resolves default).
- **Fire-and-forget** (`notify`, `setStatus`, `setWidget`, `setTitle`,
  `set_editor_text`): emit request, no response expected.
- RPC-degraded methods (`rpc.md` "Extension UI Protocol"): `custom()` →
  `undefined`; `setWorkingMessage`, `setWorkingIndicator`, `setFooter`,
  `setHeader`, `setEditorComponent`, `setToolsExpanded` → no-ops;
  `getEditorText()` → `""`; `getToolsExpanded()` → `false`; `pasteToEditor` →
  delegates to `setEditorText`; `getAllThemes()` → `[]`; `getTheme()` →
  `undefined`; `setTheme()` → `{ success: false }`. `addAutocompleteProvider`
  is a no-op (confirmed in §1).

---

## 4. Settings — `getExternalEditorCommand()` / `externalEditor` — CONFIRMED

`src/core/settings-manager.ts`:
- Setting field (`:97`):
  ```ts
  externalEditor?: string; // Command for Ctrl+G external editor; takes precedence over VISUAL/EDITOR
  ```
- Method (`:854-866`):
  ```ts
  getExternalEditorCommand(): string | undefined {
    const configuredEditor = this.settings.externalEditor;
    if (typeof configuredEditor === "string" && configuredEditor.trim() !== "") {
      return configuredEditor;
    }
    const environmentEditor = process.env.VISUAL || process.env.EDITOR;
    if (environmentEditor) {
      return environmentEditor;
    }
    return process.platform === "win32" ? "notepad" : "nano";
  }
  ```
Resolution order: `settings.externalEditor` → `$VISUAL` → `$EDITOR` → `notepad`/`nano`.
`SettingsManager` is exported from the package (`src/index.ts`, near line ~230) as
`SettingsManager` + `type SettingsManagerCreateOptions`.

---

## 5. Slash Commands — `BUILTIN_SLASH_COMMANDS` — CONFIRMED

`src/core/slash-commands.ts` (full file, 23 commands). Type:
```ts
export interface BuiltinSlashCommand {
  name: string;
  description: string;
  argumentHint?: string;
}
export const BUILTIN_SLASH_COMMANDS: ReadonlyArray<BuiltinSlashCommand> = [ ... ];
```
Built-in names: `settings, model, scoped-models, export, import, share, copy,
name, session, changelog, hotkeys, fork, clone, tree, trust, login, logout,
new, compact, resume, reload, quit`. Also exported:
`SlashCommandSource = "extension" | "prompt" | "skill"`,
`SlashCommandInfo { name; description?; source; sourceInfo: SourceInfo }`.
`SlashCommandInfo` and `SlashCommandSource` are re-exported from the package
(see `src/index.ts` extensions block).

**Note:** These are interactive-mode only; built-ins are **excluded** from
`get_commands` RPC output and `pi.getCommands()` (`rpc.md` "get_commands" and
`extensions.md` pi.getCommands()).

---

## 6. Existing Example Extensions — CONFIRMED

`packages/coding-agent/examples/extensions/` contains ~70 examples. Relevant to a bridge:
- `github-issue-autocomplete.ts` — `addAutocompleteProvider` + `session_start`
  + `pi.exec` + `fuzzyFilter` (from `@earendil-works/pi-tui`). Best reference
  for autocomplete wiring.
- `rpc-demo.ts` — exercises every RPC-supported `ctx.ui` method; pairs with
  `examples/rpc-extension-ui.ts` client.
- `auto-commit-on-exit.ts` — canonical `session_shutdown` cleanup pattern.
- `interactive-shell.ts` — `user_bash` event hooking.
- `event-bus.ts`, `ssh.ts`, `handoff.ts` (`withSession` lifecycle).

### `pi.on()` event subscription — CONFIRMED

Factory form (`extensions.md` Quick Start + examples):
```ts
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async (event, ctx) => { /* ... */ });
  pi.on("session_shutdown", async (event, ctx) => { /* cleanup */ });
}
```
No return value needed; some events accept a result object (see
`ExtensionHandler<E,R>` below). Handlers may be `async`; `pi` awaits
per-event (the runner drains one event across extensions).

---

## 7. Package Exports — CONFIRMED

### `@earendil-works/pi-coding-agent` (`packages/coding-agent/package.json`)
```jsonc
"main": "./dist/index.js",
"types": "./dist/index.d.ts",
"exports": {
  ".":        { "types": "./dist/index.d.ts", "import": "./dist/index.js" },
  "./rpc-entry": { "import": "./dist/rpc-entry.js" }
}
```
Single flat entrypoint `.` — import types/values from
`@earendil-works/pi-coding-agent`. Key **type** exports (from `src/index.ts`):
`ExtensionAPI, ExtensionContext, ExtensionCommandContext, ExtensionUIContext,
ExtensionFactory, InlineExtension, ExtensionMode, ExtensionEvent,
ExtensionHandler, ExtensionUIDialogOptions, ExtensionWidgetOptions,
AutocompleteProviderFactory, TerminalInputHandler, EditorFactory,
WorkingIndicatorOptions, WidgetPlacement, ContextUsage, CompactOptions`,
every `Session*Event` + `*Result`, every `ToolCallEvent`/`ToolResultEvent`
family, `InputEvent`/`InputEventResult`, `ProviderConfig`/`ProviderModelConfig`,
`SlashCommandInfo`, `SourceInfo`, `ReplacedSessionContext`, `ToolDefinition`,
`ToolInfo`, `ToolExecutionMode`, etc.

Key **value** exports: `createExtensionRuntime`, `discoverAndLoadExtensions`,
`loadExtensions`/`loadExtensionFromFactory` (via extensions index),
`ExtensionRunner`, `defineTool`, `isToolCallEventType`, `isBashToolResult`…,
`wrapRegisteredTool(s)`, `SessionManager`, `SettingsManager`, `ModelRegistry`,
`createEventBus`/`EventBus`, `createLocalBashOperations`,
`withFileMutationQueue`, `CustomEditor`, `CONFIG_DIR_NAME`, `VERSION`,
`RpcClient`, `RpcExtensionUIRequest`, `RpcExtensionUIResponse`, `RpcResponse`,
`main`.

### `@earendil-works/pi-tui` (`packages/tui/package.json`)
```jsonc
"main": "./dist/index.js", "types": "./dist/index.d.ts"
```
Exports (via `src/index.ts:5-8`): `AutocompleteItem`, `AutocompleteProvider`,
`AutocompleteSuggestions`, `CombinedAutocompleteProvider`, plus `Component`,
`TUI`, `Text`, `Box`, `KeyId`, `OverlayHandle`, `OverlayOptions`,
`EditorComponent`, `EditorTheme`, `fuzzyFilter`, etc.

### `@earendil-works/pi-ai`
Provides `Model`, `Provider`, `Api`, `Context`, `StringEnum`,
`TextContent`/`ImageContent`, `AssistantMessageEvent`, `OAuthCredentials`,
etc. (used heavily in `types.ts` imports).

### `@earendil-works/pi-agent-core`
Provides `AgentMessage`, `AgentToolResult`, `AgentToolUpdateCallback`,
`ThinkingLevel`, `ToolExecutionMode`.

All four packages are version-locked at `^0.80.10` and live in the monorepo.

---

## 8. `ExtensionAPI` / `.on()` Signature — CONFIRMED (`types.ts:1007-1683`)

Handler type:
```ts
// types.ts (ExtensionAPI section, ~line 1011)
/** Handler function type for events */
export type ExtensionHandler<E, R = undefined> =
  (event: E, ctx: ExtensionContext) => Promise<R | void> | R | void;
```
So every handler is `(event, ctx) => void` (sync) or `async (event, ctx) => R | void`.

`ExtensionAPI.on()` is **overloaded per-event** (fully typed). Excerpt of the
lifecycle-relevant overloads (`types.ts` ExtensionAPI block):
```ts
export interface ExtensionAPI {
  on(event: "project_trust",      handler: ProjectTrustHandler): void;
  on(event: "resources_discover", handler: ExtensionHandler<ResourcesDiscoverEvent, ResourcesDiscoverResult>): void;
  on(event: "session_start",      handler: ExtensionHandler<SessionStartEvent>): void;
  on(event: "session_info_changed", handler: ExtensionHandler<SessionInfoChangedEvent>): void;
  on(event: "session_before_switch", handler: ExtensionHandler<SessionBeforeSwitchEvent, SessionBeforeSwitchResult>): void;
  on(event: "session_before_fork",   handler: ExtensionHandler<SessionBeforeForkEvent, SessionBeforeForkResult>): void;
  on(event: "session_before_compact",handler: ExtensionHandler<SessionBeforeCompactEvent, SessionBeforeCompactResult>): void;
  on(event: "session_compact",     handler: ExtensionHandler<SessionCompactEvent>): void;
  on(event: "session_shutdown",    handler: ExtensionHandler<SessionShutdownEvent>): void;
  on(event: "session_before_tree", handler: ExtensionHandler<SessionBeforeTreeEvent, SessionBeforeTreeResult>): void;
  on(event: "session_tree",        handler: ExtensionHandler<SessionTreeEvent>): void;
  on(event: "context",             handler: ExtensionHandler<ContextEvent, ContextEventResult>): void;
  on(event: "before_provider_request", handler: ExtensionHandler<BeforeProviderRequestEvent, BeforeProviderRequestEventResult>): void;
  on(event: "before_provider_headers", handler: ExtensionHandler<BeforeProviderHeadersEvent>): void;
  on(event: "after_provider_response", handler: ExtensionHandler<AfterProviderResponseEvent>): void;
  on(event: "before_agent_start",  handler: ExtensionHandler<BeforeAgentStartEvent, BeforeAgentStartEventResult>): void;
  on(event: "agent_start" | "agent_end" | "agent_settled", ...): void;
  on(event: "turn_start" | "turn_end", ...): void;
  on(event: "message_start" | "message_update" | "message_end", ...): void;
  on(event: "tool_execution_start" | "tool_execution_update" | "tool_execution_end", ...): void;
  on(event: "model_select" | "thinking_level_select", ...): void;
  on(event: "tool_call",  handler: ExtensionHandler<ToolCallEvent, ToolCallEventResult>): void;
  on(event: "tool_result",handler: ExtensionHandler<ToolResultEvent, ToolResultEventResult>): void;
  on(event: "user_bash",  handler: ExtensionHandler<UserBashEvent, UserBashEventResult>): void;
  on(event: "input",      handler: ExtensionHandler<InputEvent, InputEventResult>): void;

  registerTool(tool: ToolDefinition): void;
  registerCommand(name: string, options: Omit<RegisteredCommand, "name" | "sourceInfo">): void;
  registerShortcut(shortcut: KeyId, options: {...}): void;
  registerFlag(name: string, options: {...}): void;
  getFlag(name: string): boolean | string | undefined;
  registerMessageRenderer / registerEntryRenderer ...
  sendMessage / sendUserMessage / appendEntry ...
  setSessionName / getSessionName / setLabel ...
  exec(command, args, options?): Promise<ExecResult>;
  getActiveTools / getAllTools / setActiveTools / getCommands ...
  setModel / getThinkingLevel / setThinkingLevel ...
  registerProvider(provider | name, config) / unregisterProvider(name) ...
  events: EventBus; // shared bus for inter-extension comms
}
```
Factory invocation confirmed (`loader.ts:485-498`): `await factory(api)` where
`api = createExtensionAPI(extension, runtime, resolvedCwd, eventBus)`.

---

## Architecture / Data Flow

```
┌─ pi CLI boots ─────────────────────────────────────────────┐
│  args parsed → mode chosen (tui | rpc | json | print)        │
│  SettingsManager loads (~/.pi/agent/ + project)              │
│  extensions discovered (global/project/-e/settings.packages) │
│  for each ext: loadExtensionFromFactory(factory) →           │
│      api = createExtensionAPI(ext, runtime, cwd, eventBus)   │
│      await factory(api)  // pi.on(...) registrations happen  │
│  runner.initialize() binds actions + mode-specific ctx       │
└──────────────────────────────────────────────────────────────┘
        │
        ▼
session_start { reason: "startup" }
resources_discover { reason: "startup" }   ← safe to open sockets/processes HERE
   …user turn cycle (input → before_agent_start → agent_* → turn_* → tool_* → agent_settled)…
session_shutdown { reason: "quit"|"reload"|"new"|"resume"|"fork" }  ← close resources HERE
```

- `ExtensionUIContext` is **mode-specific**: interactive-mode wires real TUI;
  RPC-mode wires the extension-UI JSON sub-protocol (and no-ops TUI-only APIs);
  print/json modes have no UI (`hasUI === false`).
- `ExtensionContext` is rebuilt per event/tool/command and carries the same
  `ui`, `cwd`, `mode`, `hasUI`, `sessionManager`, `model`, `signal`.
- The `events: EventBus` on `ExtensionAPI` is a shared bus for cross-extension
  messaging (`events.on/emit`), separate from pi lifecycle events.

---

## Start Here

Open `packages/coding-agent/src/core/extensions/types.ts` — it is the single
source of truth for every type in this report. For lifecycle design, read the
`SessionStartEvent` / `SessionShutdownEvent` (lines ~640-760) and the
`ExtensionHandler` + `ExtensionAPI.on` overloads (lines ~1007-1100). For the
autocomplete contract, read `AutocompleteProviderFactory` (line 209) plus
`packages/tui/src/autocomplete.ts:219-293`.

For a concrete extension skeleton, copy
`examples/extensions/github-issue-autocomplete.ts` (autocomplete +
`session_start` pattern) and
`examples/extensions/auto-commit-on-exit.ts` (`session_shutdown` cleanup
pattern).

---

## Residual Risks / Open Questions for the Bridge

1. **`addAutocompleteProvider` is a no-op in RPC mode.** If the bridge runs pi
   in `--mode rpc`, custom completions cannot be layered via the extension API —
   the bridge client must implement completion UI itself (or pi must be run in
   TUI mode / the client consumes the rpc-extension-ui protocol directly).
   Severity: high if the bridge is RPC-based and needs completions.
2. **TUI-only methods** (`custom()`, component factories, terminal input,
   `onTerminalInput`, `setFooter/Header/EditorComponent`) are unavailable or
   degraded outside TUI. Guard with `ctx.mode === "tui"`.
3. **Factory must not open sockets/processes.** Per docs, background resources
   must start in `session_start` and be cleaned in `session_shutdown`. The
   factory may run in invocations that never start a session.
4. **`session_shutdown` reasons include session replacement** (`new`/`resume`/
   `fork`/`reload`) — not only process exit. Cleanup handlers must be
   idempotent and re-open resources on the next `session_start`.
5. **Project-local extensions require trust.** `.pi/extensions/*` load only
   after trust resolves; use `~/.pi/agent/extensions/` or `-e` for guaranteed
   load. Respect `ctx.isProjectTrusted()` before reading project-local config.
6. **`ctx.signal` is usually `undefined` outside active turns** — do not assume
   it exists in `session_start`/`session_shutdown`/commands fired while idle.
7. **RPC JSONL framing is strict LF-only.** A Node bridge must NOT use
   `readline` (it splits on U+2028/U+2029); split on `\n` and strip optional
   trailing `\r`.
8. **`getExternalEditorCommand()` can fall back to `nano`/`notepad`** — a
   bridge relying on it for an external editor must handle a bare `nano` result
   (no args) when no `externalEditor`/`$VISUAL`/`$EDITOR` is configured.

---