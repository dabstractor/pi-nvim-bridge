# Research Notes — P1.M3.T8.S16 (Write BridgeDescriptor JSON to process.env.PI_EDITOR_BRIDGE)

> A precursor research pass landed under a mislabeled folder
> (`plan/001_c56962b4fa17/P1M3T1S1/research/notes.md`) — that file describes THIS
> item (the process.env advertisement). It is largely accurate but **STALE on one
> point** (§2 below). This file is the authoritative, code-current research for S16.

## Item contract (verbatim from `tasks.json` P1.M3.T8.S16.context_scope)

1. RESEARCH NOTE: the editor child inherits `process.env` because `spawn()` has no
   `env` option (`interactive-mode.ts:3811-3816`; `architecture/system_context.md` §1).
   The descriptor (PRD §4) is the discovery mechanism that makes the whole design work.
2. INPUT: module-level `socketPath`, `token`, and `ctx.cwd` from the session_start handler.
3. LOGIC: in `startBridge()` (or right after), write
   `process.env.PI_EDITOR_BRIDGE = JSON.stringify({ transport:"unix", path:socketPath,
   token, pid:process.pid, cwd, fdAvailable:true, serverVersion:"0.1.0" })`.
   In `stopBridge()`, delete the env var.
4. OUTPUT: `process.env.PI_EDITOR_BRIDGE` holds a valid JSON string the Neovim child
   reads via `vim.env.PI_EDITOR_BRIDGE`.
5. MOCKING: verify the env var is set after `startBridge` and deleted after `stopBridge`.
6. DOCS: [Mode A] JSDoc explaining the process.env inheritance discovery + criticality.

---

## §0 — Baseline (current code state, read from the live tree)

`extension/pi-editor-bridge.ts` (post-S15) has MORE infrastructure than the stale
notes assumed. All of these already exist and S16 REUSES them:

- module state: `let server`, `let socketPath`, `let token`, `let cwd`.
- getters: `getServer()`, `getSocketPath()`, `getToken()`, `getPid()` (`process.pid`),
  `getCwd()`, `getFdAvailable()` (with `__setFdAvailableForTest` seam + real resolver
  `resolveFdAvailable()`).
- `BRIDGE_VERSION = "0.1.0"` (exported constant).
- `startBridge(ctx)` — generates token, binds socket, `server.on("error", …)`,
  `listen`, chmod 0o600. Ends with `// NOTE: NO process.env.PI_EDITOR_BRIDGE write
  here — that is P1.M3.T8.S16.` and `void ctx;` (ctx NOT yet dereferenced).
- `stopBridge()` — `server?.close()`, `rmSync(socketPath,{force:true})`, resets state.
  Ends with `// NOTE: delete process.env.PI_EDITOR_BRIDGE is intentionally OMITTED … S16`.
- default-export factory: `session_start` (TUI guard → log → captureProvider →
  startBridge → `cwd = ctx.cwd;` → register handlers, with
  `// TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE`) + `session_shutdown`
  (stopBridge, with `// NOTE: clearing process.env.PI_EDITOR_BRIDGE belongs to S16`).

`extension/protocol.ts` (S4) defines the authoritative wire type `BridgeDescriptor`
(§B). `extension/tests/protocol.test.ts` PINS the exact literal the descriptor must
equal: `{ transport:"unix", path:"/tmp/pi-editor-bridge-x.sock", token:"deadbeef",
pid:4242, cwd:"/home/u/proj", fdAvailable:true, serverVersion:"0.1.0" }` → the field
is **`serverVersion`** (NOT `version`), value **`"0.1.0"`**.

`extension/tsconfig.json` `include = ["pi-editor-bridge.ts","protocol.ts",
"jsonl-reader.ts","connection.ts","tests/**/*.ts"]`; `strict:true`. Verified: the new
`extension/tests/bridge-env.test.ts` matches `tests/**/*.ts` → auto-included, NO
tsconfig edit needed. `tsc --noEmit -p extension/tsconfig.json` exits 0 today.

Tests run via jiti: `JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/
pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs` then
`node --import "$JITI_REG" extension/tests/<suite>.ts`. Verified the register path
exists. Node 26.4.0. Reporter prints `ℹ pass N` / `ℹ fail N` (NOT TAP). jiti prints a
benign `module.register() is deprecated` (DEP0205) on stderr — IGNORE.

---

## §1 — MAKE-OR-BREAK #1: `serverVersion` (NOT `version`), value `"0.1.0"`

The PRD is internally inconsistent (§4 prose says `"version":"0.0.1"`; §6.4 code
skeleton says `serverVersion:"0.1.0"`). Resolve: **`serverVersion: "0.1.0"`**.

Rationale: (a) it is the field the `BridgeDescriptor` TYPE declares → any other name
is a TS error / wire mismatch; (b) the Neovim client decodes into the same shape
(P2.M4.T12.S21); (c) it matches every CODE authority (§6.4 skeleton, the type, the
pinned test, `HelloResult`/`PingResult`); (d) the item's own LOGIC line uses
`serverVersion:"0.1.0"`. PRD §4's `"version":"0.0.1"` is prose-draft drift.

**Compile-time guard:** build the descriptor as `{ … } satisfies BridgeDescriptor`
(import the type from `./protocol.ts`). A `version:` typo becomes a TS error at the
build site. `satisfies` is available (target ES2022 + TS ≥4.9; repo compiles today).

---

## §2 — ⚠️ STALE-NOTE CORRECTION: `fdAvailable` MUST use `getFdAvailable()`, NOT hardcode `true`

The precursor notes (§2) argued for hardcoding `fdAvailable: true` on the grounds
that NO fd resolver existed. **That premise is now FALSE.** The current code ships a
real resolver `getFdAvailable()` (`resolveFdAvailable()` mirrors pi's
`getToolPath("fd")` lookup: pi agent bin dir then `PATH` scan; cached once per
process; `__setFdAvailableForTest` seam for determinism). It is ALREADY wired into
the `hello` (S9) and `ping` (S14) handlers' results.

**Decision: use `fdAvailable: getFdAvailable()`.** Rationale:
- **Consistency.** The Neovim client receives `fdAvailable` from THREE places: the
  `PI_EDITOR_BRIDGE` descriptor (this task), the `hello` result, and the `ping`
  result. All three MUST agree. `hello`/`ping` already use `getFdAvailable()`; if
  S16 hardcoded `true` while the descriptor's machine has no `fd`, the descriptor
  would lie and `hello` would contradict it → confusing diagnostics
  (`:checkhealth pi-editor`, P3.M10.T27.S42, reads the descriptor).
- **Testability.** `__setFdAvailableForTest(b)` makes the value deterministic in the
  exact-shape test without depending on whether the runner has `fd` installed (the
  stale notes' only real concern, now solved by the seam).
- The PRD §6.4 skeleton literally writes `fdAvailable: !!fdPathAvailable()` — i.e. a
  REAL detection, not a literal `true`. `getFdAvailable()` is the faithful
  realization of that intent.

So: hardcoding `true` would be a REGRESSION vs the rest of the extension. Use
`getFdAvailable()`. (The item LOGIC line's literal `fdAvailable: true` is the same
prose-draft drift as §1's `version`; the CODE intent — confirmed by §6.4 + S9/S14 +
PRD §11 "`fd` not installed … the bridge reports `fdAvailable` in hello" — is real
detection.)

---

## §3 — WHERE to write the env var: inside `startBridge` (end), after listen+chmod

Choose INSIDE startBridge (item allows "in startBridge() (or right after it's called)"):

- **PRD §6.4 skeleton does exactly this** — the `process.env[BRIDGE_ENV]` write is the
  LAST line of `startBridge`, after `server.listen` + chmod.
- **Cohesion:** advertisement is only meaningful while a backing server exists. Every
  bridge that starts advertises; every `stopBridge` (including the `server.on("error")`
  path) clears it.
- **State availability:** `socketPath` + `token` are module-level `let`s assigned a few
  lines above the write site → guaranteed set. `ctx.cwd` is read directly from `ctx`
  (this is WHY startBridge finally stops doing `void ctx;`).
- **Ordering:** write AFTER `server.listen(socketPath)` + chmod so the descriptor
  reflects a bound, perms-locked socket. `listen()` is async (the 'listening' event
  fires later), but the socket FILE + the path/token strings are final the instant
  `listen()` is called → writing right after is correct (the client connects after
  VimEnter, long after 'listening' fired).

**`cwd` ordering subtlety:** session_start currently sets `cwd = ctx.cwd;` AFTER
`startBridge(ctx)` returns. Inside startBridge, the module-level `cwd` is therefore
NOT yet set → use `ctx.cwd` DIRECTLY in the descriptor (NOT `getCwd()`). The
`cwd = ctx.cwd;` line in session_start STAYS (it feeds `getCwd()` for the hello/ping
handlers). Slightly redundant (ctx.cwd read twice) but correct and local. (A cleaner
alternative — move `cwd = ctx.cwd;` BEFORE `startBridge(ctx)` and use `getCwd()` — is
safe since `cwd` is only read by RPC handlers that fire long after session_start, but
is a larger diff; the straightforward `ctx.cwd`-direct approach is preferred.)

**`BRIDGE_ENV` constant:** declare `export const BRIDGE_ENV = "PI_EDITOR_BRIDGE";`
module-level near the `server`/`socketPath`/`token` state. Export so the test
references the NAME (not a hardcoded string) and a future rename is one-line.

**`delete process.env[BRIDGE_ENV]`** goes in `stopBridge()` AFTER `token = undefined;`,
replacing the current NOTE comment. `delete` on a process.env key never throws and is a
no-op if absent → safe whether or not startBridge ran (matches the idempotent idiom).
session_shutdown's NOTE comment is resolved automatically because session_shutdown
calls stopBridge (no separate code needed there).

---

## §4 — Node `process.env` semantics

- **Assignment coerces to string.** Assigning a raw object → `"[object Object]"`
  (WRONG). So `JSON.stringify(descriptor)` FIRST, then assign. Standard Node behavior
  (process.env is a Proxy; `value.toString()` on assignment).
- **`JSON.stringify` emits NO embedded newlines** for a flat object of
  string/number/boolean fields → the env var is a single clean line (the Neovim gate
  does `vim.json.decode` on the whole value; newline-free is the safe contract).
- **`delete process.env.X`** removes the own property; subsequent reads yield
  `undefined`.
- **Typing:** `@types/node` is resolvable. `process.env` is `NodeJS.ProcessEnv` =
  `{ [key: string]: string | undefined }` → assigning a string and `delete` both
  type-check with NO `declare global` augmentation. (That pattern is only for editor
  autocompletion of known keys; not required for assign/read to compile.)

---

## §5 — process.env INHERITANCE = THE discovery mechanism (the [Mode A] JSDoc)

Confirmed in `architecture/system_context.md` §1 (citing
`interactive-mode.ts:3811-3816`) and PRD §2.1:
- pi spawns the external editor with `{ stdio:"inherit", shell:
  process.platform==="win32" }` and **NO `env:` option**.
- Node `spawn` defaults to inheriting the parent's `process.env` when `env` is omitted.
- Therefore anything the extension writes to `process.env.PI_EDITOR_BRIDGE` BEFORE the
  editor launch (i.e. on `session_start`, which fires before any Ctrl+G) IS visible to
  the Neovim child as `vim.env.PI_EDITOR_BRIDGE`.
- PRD §4 step 2 + §7.1: Neovim's `VimEnter` gate does
  `vim.json.decode(vim.env.PI_EDITOR_BRIDGE)`; absent/unparseable → plugin stays
  dormant (why the plugin is safe to ship in a normal config). Present → activate.
- **This is THE discovery that makes the whole two-component design work** (PRD §2.1).
  The descriptor carries the socket path + token the client needs to connect; without
  it the client has no way to find the bridge.

The [Mode A] JSDoc on the env write MUST state: spawn-inherits-process.env →
write-before-launch → Neovim-reads-on-VimEnter. Criticality: without this write, the
plugin never activates and the bridge is unreachable.

---

## §6 — Test interaction: S5/S6 wiring `fakeCtx`/`makeCtx` lack `cwd`

- `bridge-lifecycle.test.ts` (S5) test 1 + tests 2/3 use
  `const fakeCtx = {} as ExtensionContext;`. After S16, startBridge dereferences
  `ctx.cwd`. At COMPILE time `ExtensionContext.cwd` is typed `string` → `cwd: ctx.cwd`
  type-checks (NO required edit). At RUNTIME `ctx.cwd` is `undefined` → `JSON.stringify`
  OMITS the `cwd` key. S5 tests do NOT assert the env var → they still pass.
- `bridge-lifecycle-wiring.test.ts` (S6) `makeCtx(mode)` provides
  `{ mode, ui: { addAutocompleteProvider: () => {} } }` — NO `cwd`. Same reasoning →
  test B (non-tui) is unaffected; test A (tui) sets env with cwd omitted but doesn't
  assert it → still passes.
- **Optional one-liner cleanup (recommended):** add `cwd: "/test"` to S5's `fakeCtx`
  and S6's `makeCtx` so the descriptor is well-formed during the real-integration
  tests. NOT required for green; do it for cleanliness.
- The NEW S16 test (`bridge-env.test.ts`) MUST pass a ctx WITH `cwd`
  (e.g. `cwd: "/test/proj"`) so the descriptor it asserts is the real shape.

---

## §7 — Test design (`extension/tests/bridge-env.test.ts`, node:test + jiti)

Mirror S5's two-pronged style (mocked exact-shape + real/wiring) and S6's
`captureHandlers()`/`makeCtx()` for the factory-wiring test. Tests:

1. **mocked, exact descriptor shape** — `__deps.createServer`/`chmodSync` faked (reuse
   S5's fakeServer shape: `listen(arg)` records + returns self, `close()` no-op,
   `on()` no-op); `__setFdAvailableForTest(true)` for a known value;
   `fakeCtx = { cwd: "/test/proj" } as ExtensionContext`. After startBridge:
   - `process.env.PI_EDITOR_BRIDGE` is a `string`, NOT `undefined`.
   - `JSON.parse(process.env.PI_EDITOR_BRIDGE)` → object with
     `transport==="unix"`, `path===getSocketPath()`, `token===getToken()`,
     `pid===process.pid`, `cwd==="/test/proj"`, `fdAvailable===true`,
     `serverVersion==="0.1.0"` (NOTE: `serverVersion`, NOT `version`).
   - the RAW string contains no `"\n"` (single-line — safe env value).
   - exactly 7 keys (transport/path/token/pid/cwd/fdAvailable/serverVersion) — proves
     no stray `version` key leaked in.
2. **stopBridge deletes** — after test 1's startBridge, call stopBridge →
   `process.env.PI_EDITOR_BRIDGE === undefined`. Also: stopBridge when env was never
   set is a safe no-op (delete on absent key).
3. **idempotent re-write** — startBridge twice; after the 2nd, the parsed
   descriptor's `path`/`token` equal the 2nd `getSocketPath()`/`getToken()` (NOT the
   1st). Each startBridge writes a FRESH descriptor.
4. **wiring (full lifecycle via factory)** — reuse S6's `captureHandlers()` +
   `makeCtx()` pattern (with `cwd` added):
   - `session_start(tui)` → env var set + decodes to a valid descriptor whose
     `cwd===ctx.cwd`.
   - `session_shutdown` → env var deleted (undefined).
   - `session_start(rpc/json/print)` → env var NOT set (TUI guard returns before
     startBridge); proves non-TUI sessions never advertise (S3 regression preserved).

**Cleanup discipline (LOAD-BEARING):** process.env is shared process state — tests
leak across each other in the same process. Every test MUST `stopBridge()` (which
deletes the env var) in a `finally`, AND restore `__deps` overrides in a `finally`
(S5 pattern), AND `__setFdAvailableForTest(undefined)` to reset the fd cache. Without
this, test 1's value could leak into test 2's "deleted" assertion.

---

## §8 — Scope guard (what S16 does NOT do)

- Does NOT add a NEW fd detector — `getFdAvailable()` already exists (§2 correction).
- Does NOT change the `BridgeDescriptor` type (protocol.ts is S4's, UNCHANGED) — only
  CONSUMES it via `satisfies`.
- Does NOT touch tsconfig (`tests/**/*.ts` auto-includes the new test).
- Does NOT touch jsonl-reader.ts, connection.ts, protocol.ts, or any handler.
- Does NOT write to any OTHER env var. Only `PI_EDITOR_BRIDGE`.
- Does NOT log the token/descriptor (PRD §12 — the token is the auth boundary).

---

## §9 — Validation commands (verified for this tree)

```
# Level 1 — type-check (zero output, exit 0 — VERIFIED today)
npx tsc --noEmit -p extension/tsconfig.json

# Level 2 — the new suite + regression suites (reporter: "ℹ pass N" / "ℹ fail N")
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/bridge-env.test.ts            # NEW — expect ℹ fail 0
node --import "$JITI_REG" extension/tests/bridge-lifecycle.test.ts      # S5  — expect ℹ fail 0
node --import "$JITI_REG" extension/tests/bridge-lifecycle-wiring.test.ts # S6 — expect ℹ fail 0
node --import "$JITI_REG" extension/tests/mode-guard.test.ts            # S3  — guard intact
node --import "$JITI_REG" extension/tests/provider-capture.test.ts      # S2
node --import "$JITI_REG" extension/tests/protocol.test.ts             # S4

# Level 3 — extension still loads cleanly (non-TUI path → guard returns before startBridge)
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"   # exit 0, no error lines
```

SUCCESS METRIC: confidence 9/10 — the change is ~12 lines into a file whose patterns
are fully established (getters + `__deps` seam + `satisfies`-guardable type), the type
is pinned by an existing test (protocol.test.ts), the only ambiguities
(`version`→`serverVersion`; `fdAvailable`→real resolver) are resolved above, and every
validation command is verified working.
