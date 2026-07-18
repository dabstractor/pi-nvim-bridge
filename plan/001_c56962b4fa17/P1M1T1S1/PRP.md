---
name: "P1.M1.T1.S1 — Extension default factory with session_start/session_shutdown lifecycle"
description: |
  Create the foundational `extension/pi-editor-bridge.ts` skeleton: a pi
  extension default-export factory that registers a `session_start` handler
  (logs a startup message) and a `session_shutdown` handler (no-op
  placeholder), plus a Mode-A JSDoc header. This is the FIRST, NARROW
  scaffolding task — it wires ONLY the lifecycle hooks. Provider capture
  (S2), TUI guard (S3), socket server (M2), env advertisement (S16),
  commandsChanged (S17), and packaging/README (S18) are SEPARATE later tasks.
  Do NOT implement them here.
---

## Goal

**Feature Goal**: A valid, loadable single-file pi extension at
`extension/pi-editor-bridge.ts` whose default export is the factory
`(pi: ExtensionAPI) => void` that registers the two session lifecycle hooks —
verifiable by loading it through the real `pi` CLI with zero errors and
observing the startup log fire.

**Deliverable**: One file — `extension/pi-editor-bridge.ts` (~30–45 lines) —
containing:
1. A Mode-A JSDoc header documenting purpose, the `PI_EDITOR_BRIDGE` env var,
   and the Unix-socket / JSONL transport.
2. `import type { ExtensionAPI, ExtensionContext, SessionStartEvent, SessionShutdownEvent } from "@earendil-works/pi-coding-agent";`
3. `export default function (pi: ExtensionAPI): void { ... }` that calls
   `pi.on("session_start", handler)` and `pi.on("session_shutdown", handler)`.
4. `session_start` handler logs a startup message (e.g. `console.log`); the
   reason + mode may be included.
5. `session_shutdown` handler is a documented no-op placeholder.

**Success Definition**:
- `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` loads
  the file via jiti with **no load/parse error**, prints the startup message,
  and exits 0 (fires `session_shutdown` reason=`quit`).
- `tsc --noEmit` (with the dev `paths`-mapped tsconfig) reports **zero type
  errors**.
- No background resources (sockets/processes/timers) are started in the factory
  body — only `pi.on(...)` registrations.

## User Persona (if applicable)

**Target User**: `pi` core developers / the bridge-extension author (this task
is developer scaffolding, not end-user-facing).

**Use Case**: Establish the loadable extension entry point and lifecycle hooks
that every subsequent P1.M1–P1.M3 task will build upon (provider capture,
socket server, env advertisement all hang off these two hooks).

**Pain Points Addressed**: Without a valid default-export factory, pi refuses to
load the extension at all; this task de-risks the "can pi load our file?" gate
before any real logic is added.

## Why

- **Foundation for the entire P1 bridge**: §6.6 of the PRD specifies the default
  export shape; §6.2 maps `session_start` → (re)capture+start and
  `session_shutdown` → close+unlink. This task delivers exactly the hook
  scaffolding so downstream tasks (S2, S3, M2, S16, S17) only have to fill in
  handler bodies.
- **Validates the install/load path early**: confirms jiti resolves our
  type-only imports and the factory contract `(pi) => void` before we pile on
  socket/RPC logic.
- **Satisfies the pi extension contract verbatim**: factory must not start
  background resources (sockets) — defer to `session_start` (PRD §6.2 note;
  pi `extensions.md` "Long-lived resources and shutdown"). A handler-only
  skeleton is the correct, safe starting point.

## What

A TypeScript file that, when discovered/loaded by pi (via
`~/.pi/agent/extensions/` or `pi -e ./path.ts`), causes pi to print a startup
message on session start and to do nothing on session shutdown. No socket, no
provider capture, no env var writes, no TUI guard — those are explicitly out of
scope here.

### Success Criteria

- [ ] File exists at `extension/pi-editor-bridge.ts`.
- [ ] Default export is a function `(pi: ExtensionAPI) => void` (no `async`
      needed; only `pi.on(...)` calls).
- [ ] `pi.on("session_start", …)` registered; its handler logs a startup
      message at least once per session start.
- [ ] `pi.on("session_shutdown", …)` registered as a no-op placeholder.
- [ ] JSDoc header present (purpose + `PI_EDITOR_BRIDGE` env var + Unix
      socket/JSONL transport).
- [ ] Loads via `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
      with zero load errors; startup log appears; exit 0.
- [ ] `tsc --noEmit` (paths-mapped tsconfig) → zero errors.
- [ ] No `node_modules` required to load (only `import type`, erased at runtime).

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo can create the file, run the
two validation commands exactly as written, and see green. All type shapes,
import paths, handler signatures, reference examples, and verified validation
commands are listed below with file:line citations.

### Documentation & References

```yaml
# MUST READ — the type source of truth (installed dist)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts
  why: exact handler + event + context types for the two hooks
  section: "ExtensionHandler (L835), on() overloads (L842,L848), SessionStartEvent (L405), SessionShutdownEvent (L457), ExtensionContext (L208-216), ExtensionMode (L207)"
  critical: |
    on(event:"session_start", handler: ExtensionHandler<SessionStartEvent>): void
    on(event:"session_shutdown", handler: ExtensionHandler<SessionShutdownEvent>): void
    ExtensionHandler<E> = (event: E, ctx: ExtensionContext) => Promise<void>|void  (sync void is allowed)
    SessionStartEvent.reason   = "startup"|"reload"|"new"|"resume"|"fork"
    SessionShutdownEvent.reason= "quit"|"reload"|"new"|"resume"|"fork"
    ExtensionContext.mode = "tui"|"rpc"|"json"|"print";  .cwd:string; .hasUI:boolean; .ui.addAutocompleteProvider(...)

# MUST READ — the two canonical reference examples (copy their structure)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/auto-commit-on-exit.ts
  why: canonical session_shutdown + default-export-factory pattern; shows import line & TAB indentation
  pattern: "export default function (pi: ExtensionAPI) { pi.on(\"session_shutdown\", async (_event, ctx) => { ... }); }"
  gotcha: uses TABS for indentation; unused params prefixed with underscore (_event, _e)

- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/github-issue-autocomplete.ts
  why: canonical session_start + default-export-factory pattern (autocomplete part is OUT OF SCOPE — do NOT copy it)
  pattern: "pi.on(\"session_start\", async (_event, ctx) => { ... });  ...  ctx.ui.addAutocompleteProvider(...)  <-- OMIT THIS LINE (S2)"
  gotcha: only copy the factory skeleton + the pi.on(\"session_start\") registration shape; the addAutocompleteProvider body belongs to S2

# MUST READ — architecture validation (project-local, pre-researched)
- docfile: plan/001_c56962b4fa17/architecture/research-pi-extension-api.md
  why: every PRD claim verified against pi source with file:line refs; residual risks
  section: "§1 Extension Type Surface; §6 Existing Example Extensions; §8 ExtensionAPI.on() signature; Residual Risks #3 (factory must not open sockets)"
- docfile: plan/001_c56962b4fa17/architecture/system_context.md
  why: two-component architecture + where this extension fits; lifecycle mapping
  section: "#3 Extension API — Lifecycle; #4 Import Paths"
- docfile: plan/001_c56962b4fa17/architecture/external_deps.md
  why: §4 pi Extension API factory pattern recap; §5 Node builtins (NOT needed in S1)
  section: "§4 pi Extension API"

# SUPPORTING — pi's own extension docs (for the 'do not start resources in factory' rule)
- url: file:///home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/docs/extensions.md
  why: confirms jiti load (TS works without compile), extension locations, lifecycle/shutdown guidance
  critical: "Loaded via jiti (line 179). Locations: ~/.pi/agent/extensions/*.ts (global), -e ./path.ts (quick test). 'Do not start background resources from the factory; defer to session_start.'"
```

### Current Codebase tree

```bash
$ (cd /home/dustin/projects/pi-nvim-bridge && find . -not -path './.git/*' -not -path './.pi-subagents/*' -not -path './plan/*' | sort)
.
./.gitignore
./PRD.md
# (plan/ holds planning artifacts only — no source code exists yet)
```

There is **no `extension/` directory yet** and **no existing TS tooling**
(no tsconfig, no package.json, no node_modules). `pi`, `tsc` (5.9.3), `npx`,
and `node` v26 are on PATH. The package
`@earendil-works/pi-coding-agent@0.80.10` is globally installed at
`/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent`.

### Desired Codebase tree with files to be added

```bash
extension/
├── pi-editor-bridge.ts     # (CREATE) default-export factory + 2 lifecycle hooks + JSDoc header
└── tsconfig.json           # (CREATE, dev-only) paths-mapped config for `tsc --noEmit` type check
# NOTE: NO package.json, NO README in this task — packaging is S18.
# The tsconfig.json is dev tooling (not runtime packaging) and does not conflict with S18.
```

**File responsibilities**
- `extension/pi-editor-bridge.ts` — the extension entry point. Installable at
  `~/.pi/agent/extensions/pi-editor-bridge.ts` or loadable via `pi -e`.
- `extension/tsconfig.json` — **dev-only** (never consumed by pi at runtime).
  Exists solely so `tsc --noEmit` can resolve the global `@earendil-works/pi-coding-agent`
  type declarations. May be removed or folded into a repo-wide tsconfig later.

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL: factory body must NOT start background resources (sockets/processes/timers).
//   S1 satisfies this trivially because it only calls pi.on(...) — keep it that way.
//   (PRD §6.2 note; pi docs "Long-lived resources and shutdown".)

// CRITICAL: use `import type` (NOT `import`). Type-only imports are ERASED at runtime,
//   so the file loads via jiti with zero node_modules present (PRD §6.7 "no npm runtime deps").

// STYLE: pi's own example extensions indent with TABS (auto-commit-on-exit.ts,
//   github-issue-autocomplete.ts). Match TABS for consistency.

// GOTCHA: in interactive TUI mode, console.log writes to stdout and can corrupt the
//   terminal render. The pi idiom is ctx.ui.notify(msg, "info"). For the S1 skeleton,
//   console.log is acceptable (and is what we validate against in --print mode), but a
//   future task should switch startup messaging to ctx.ui.notify when ctx.hasUI.

// GOTCHA: `pi.on()` is overloaded PER-EVENT and fully typed, so TS infers the handler
//   param types. The work-item contract nonetheless REQUIRES explicit annotations
//   `(event: SessionStartEvent, ctx: ExtensionContext)` — keep them explicit.

// SCOPE DISCIPLINE: do NOT add ctx.ui.addAutocompleteProvider(...) (that's S2),
//   ctx.mode !== "tui" guard (S3), createServer/socket (M2), process.env writes (S16),
//   or commandsChanged (S17). Leave clearly-marked TODOs referencing those tasks.
```

## Implementation Blueprint

### Data models and structure

Not applicable for S1 — no data structures are created. The file only imports
type aliases already defined by the pi package and registers callbacks.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE extension/pi-editor-bridge.ts
  - IMPLEMENT: Mode-A JSDoc header (purpose / PI_EDITOR_BRIDGE env var / Unix socket + JSONL transport / current skeleton state)
  - IMPLEMENT: single `import type { ExtensionAPI, ExtensionContext, SessionStartEvent, SessionShutdownEvent } from "@earendil-works/pi-coding-agent";`
  - IMPLEMENT: `export default function (pi: ExtensionAPI): void { ... }`
  - IMPLEMENT: `pi.on("session_start", (event: SessionStartEvent, ctx: ExtensionContext) => { console.log("pi-editor-bridge: session_start reason=" + event.reason); });`
  - IMPLEMENT: `pi.on("session_shutdown", () => { /* no-op placeholder; S6 will close socket + clear env, S15 will wrap cleanup */ });`
  - FOLLOW pattern: examples/extensions/auto-commit-on-exit.ts (factory + session_shutdown) and github-issue-autocomplete.ts (session_start registration shape ONLY)
  - NAMING: file snake/kebab `pi-editor-bridge.ts`; default export anonymous function is fine (examples use anonymous)
  - INDENTATION: TABS (match examples)
  - PLACEMENT: extension/ at repo root
  - DO NOT: addAutocompleteProvider, ctx.mode guard, createServer, process.env writes, randomUUID, fs/os/net imports

Task 2: CREATE extension/tsconfig.json  (dev-only, for `tsc --noEmit`)
  - IMPLEMENT: strict TS config, noEmit, moduleResolution "Bundler", paths mapping for @earendil-works/pi-coding-agent → global dist index.d.ts
  - INCLUDE: only ["pi-editor-bridge.ts"]
  - JUSTIFICATION: lets tsc resolve the globally-installed type declarations; not a runtime artifact
  - PLACEMENT: extension/ (dev tooling; separate from S18 packaging)

Task 3: VALIDATE — run the two validation commands below; fix until both green
  - RUN: `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | grep -E "pi-editor-bridge|error|cannot"`  (expect the startup log, no error)
  - RUN: `tsc --noEmit -p extension/tsconfig.json`  (expect exit 0, no output)
```

### Implementation Patterns & Key Details

```typescript
// === extension/pi-editor-bridge.ts (reference shape — implement to match) ===
/**
 * pi-editor-bridge — bridges pi's autocomplete engine to an external $EDITOR
 * (e.g. Neovim) by running a JSONL-over-Unix-domain-socket RPC server for the
 * session lifetime.
 *
 * Transport:  Unix domain socket, strict JSONL framing (LF-delimited records).
 * Env var:    process.env.PI_EDITOR_BRIDGE  (JSON BridgeDescriptor: { transport,
 *             path, token, pid, cwd, ... }) — written in a later task (S16).
 *
 * STATUS (P1.M1.T1.S1): lifecycle scaffolding only.
 *   - session_start: logs a startup message. (Provider capture = S2, socket
 *     server = M2, env advertisement = S16.)
 *   - session_shutdown: no-op placeholder. (Socket teardown/cleanup = S6/S15.)
 *
 * Loaded by pi via jiti (TypeScript works without compilation). Install at
 * ~/.pi/agent/extensions/pi-editor-bridge.ts or load with `pi -e ./path.ts`.
 */
import type {
  ExtensionAPI,
  ExtensionContext,
  SessionStartEvent,
  SessionShutdownEvent,
} from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  pi.on("session_start", (event: SessionStartEvent, ctx: ExtensionContext) => {
    // Skeleton: just log. Real startup (capture provider, open socket, set env)
    // is added in S2 / M2 / S16. console.log is fine in --print/--rpc; a later
    // task will prefer ctx.ui.notify when ctx.hasUI (TUI mode).
    console.log(
      `pi-editor-bridge: session_start (reason=${event.reason}, mode=${ctx.mode})`,
    );
  });

  pi.on("session_shutdown", (_event: SessionShutdownEvent) => {
    // No-op placeholder. Socket close + unlink + env clear land in S6/S15.
  });
}
```

```jsonc
// === extension/tsconfig.json (dev-only type-check config) ===
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true,
    "types": [],
    "baseUrl": ".",
    "paths": {
      "@earendil-works/pi-coding-agent": [
        "/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/index.d.ts"
      ]
    }
  },
  "include": ["pi-editor-bridge.ts"]
}
```

### Integration Points

```yaml
NO integration points for S1.
  - No database, no config file, no routes, no env writes, no package manifest.
  - The ONLY consumer is `pi` itself, which loads the file via jiti and invokes
    the default export with the ExtensionAPI object. That invocation happens
    automatically on `pi` startup / `pi -e ./path.ts`.
FUTURE (NOT this task):
  - process.env.PI_EDITOR_BRIDGE advertisement → S16
  - ctx.ui.addAutocompleteProvider pass-through factory → S2
  - ctx.mode === "tui" guard → S3
  - node:net server + node:crypto token → M2 (S5/S6)
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Type-check the new file in isolation (types resolve via paths mapping in the dev tsconfig)
tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, no output. If errors appear, READ them — they are almost always:
#   - a misspelled type name (ExtensionAPI/ExtensionContext/SessionStartEvent/SessionShutdownEvent)
#   - a wrong handler arity, or a non-type import that pulled in a value.

# (Optional) quick format sanity — pi examples use TABS; verify the file uses tabs:
grep -P '^    ' extension/pi-editor-bridge.ts && echo "WARNING: found spaces-indent lines" || echo "indent OK (tabs)"
```

### Level 2: Unit Tests (Component Validation)

```bash
# No unit-test harness exists in this fresh repo yet. For S1 the real-runtime
# load test (Level 3) IS the meaningful test. A jiti-based mock test is
# OPTIONAL and out of scope (no test framework chosen for TS yet — defer to a
# later tooling task). If you want a fast inline check:
node --input-type=module -e '
  const jiti = (await import("/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/dist/jiti.mjs")).createJiti(import.meta.url);
  // NOTE: jiti may live under pi-coding-agent or a shared location; if this path
  // is wrong, fall back to the Level-3 pi-load test which is authoritative.
'
# (If jiti cannot be located, SKIP this level — Level 3 is the gate.)
```

### Level 3: Integration Testing (System Validation) — THE GATE

```bash
# Load the extension through the REAL pi runtime via jiti. --print mode fires
# BOTH session_start (reason=startup) and session_shutdown (reason=quit) and
# exits, so this exercises the entire S1 contract in one command.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok" 2>&1 | tee /tmp/pi-editor-bridge-s1.log

# Assert the startup log fired and no load error occurred:
grep -E "pi-editor-bridge: session_start \(reason=startup" /tmp/pi-editor-bridge-s1.log \
  && echo "PASS: session_start fired" \
  || echo "FAIL: startup log missing"

grep -iE "error|cannot|fail|throw|unhandled|is not a function|TypeError" /tmp/pi-editor-bridge-s1.log \
  && echo "FAIL: load/runtime error present" \
  || echo "PASS: no errors"

# Expected: startup log present, no errors, pi exits 0.
# (In --print mode ctx.mode is "print"; the TUI guard for ctx.mode==="tui" is S3, not this task.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Confirm the file is loadable from the REAL install location (simulates end-user install)
mkdir -p ~/.pi/agent/extensions
cp extension/pi-editor-bridge.ts ~/.pi/agent/extensions/pi-editor-bridge.ts
pi --print "ok" 2>&1 | grep -E "pi-editor-bridge: session_start" && echo "PASS: global-load OK" || echo "FAIL"
rm -f ~/.pi/agent/extensions/pi-editor-bridge.ts   # clean up (don't leave it installed during dev)

# Confirm zero runtime npm deps: the file must reference ONLY node builtins
# (none in S1) and `import type` from the pi package.
grep -nE "^import [^{]" extension/pi-editor-bridge.ts \
  && echo "FAIL: found a non-type (value) import — S1 should be type-only" \
  || echo "PASS: only import type present"
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `tsc --noEmit -p extension/tsconfig.json` → exit 0.
- [ ] Level 3 (THE GATE): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"`
      prints the `pi-editor-bridge: session_start (reason=startup …)` log and exits 0.
- [ ] Level 3: no `error|cannot|fail|throw|unhandled|TypeError` lines in the run log.
- [ ] Level 4: loads identically from `~/.pi/agent/extensions/` (global install path).

### Feature Validation

- [ ] File at `extension/pi-editor-bridge.ts`; default export is `(pi: ExtensionAPI) => void`.
- [ ] `pi.on("session_start", …)` registered with explicitly-typed
      `(event: SessionStartEvent, ctx: ExtensionContext)` params; logs at startup.
- [ ] `pi.on("session_shutdown", …)` registered as a documented no-op.
- [ ] JSDoc header documents purpose, `PI_EDITOR_BRIDGE` env var, and Unix-socket + JSONL transport.
- [ ] No provider capture / TUI guard / socket / env writes / commandsChanged code present
      (those belong to S2/S3/M2/S16/S17).

### Code Quality Validation

- [ ] Matches pi example-extension structure (anonymous default export, `pi.on(...)`).
- [ ] Uses `import type` only (erased at runtime → loads with zero node_modules).
- [ ] Indentation = TABS (consistent with pi's examples).
- [ ] Unused params prefixed with `_` (e.g. `_event` in shutdown handler).
- [ ] No background resources started in factory body (only `pi.on(...)`).

### Documentation & Deployment

- [ ] JSDoc header is self-documenting (purpose / env var / transport / current S1 status).
- [ ] TODO comments in handler bodies reference the downstream tasks (S2, S6, S15, S16) so
      future implementers know exactly where to add logic.
- [ ] No new env vars are WRITTEN by this task (the JSDoc merely documents the future `PI_EDITOR_BRIDGE`).

---

## Anti-Patterns to Avoid

- ❌ Don't add `addAutocompleteProvider`, socket creation, `process.env` writes, or a
  `ctx.mode` guard — those are S2/S3/M2/S16. S1 is the bare lifecycle skeleton.
- ❌ Don't make the factory `async` or return a Promise — S1 only registers handlers;
  nothing to await. (Returning a Promise is legal but pointless here and adds a
  jiti-await before session_start for no reason.)
- ❌ Don't use a value `import` (`import { ExtensionAPI }`) — it must be `import type`
  so the file loads with zero node_modules and matches the "no runtime deps" rule.
- ❌ Don't start any background resource (timer/process/socket) in the factory body;
  pi explicitly forbids it and S1 should not need it anyway.
- ❌ Don't add `package.json` or `README.md` — packaging is S18.
- ❌ Don't write a fake/empty handler that swallows the startup log; the contract
  requires the message to actually print (it is the validation signal).
- ❌ Don't rely on `ctx.ui.notify` for the S1 startup message validation — it does not
  surface in `--print` mode output; use `console.log` so the Level-3 grep can see it.
  (Notify-vs-log nuance is revisited in a later TUI-aware task.)
