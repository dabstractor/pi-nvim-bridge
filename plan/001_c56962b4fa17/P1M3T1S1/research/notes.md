# Research Notes — P1.M3.T8.S16 (Write BridgeDescriptor JSON to process.env.PI_NVIM_BRIDGE)

> Path note: the orchestrator placed artifacts under `P1M3T1S1/`; the item is task
> **P1.M3.T8.S16** in the plan tree (the process.env advertisement). Build the feature;
> ignore the folder label. The plan's `P1.M3.T8` is labelled `P1.M3.T1` in the path.

Item contract (verbatim, the parts that drive every decision):
- INPUT: module-level `socketPath`, `token`, and `ctx.cwd` from the session_start handler.
- LOGIC: `process.env.PI_NVIM_BRIDGE = JSON.stringify({ transport:"unix", path:socketPath,
  token, pid:process.pid, cwd, fdAvailable:true, serverVersion:"0.1.0" })` — written in
  startBridge (or right after it's called). stopBridge() deletes the env var.
- OUTPUT: `process.env.PI_NVIM_BRIDGE` holds a valid JSON string the Neovim child reads
  via `vim.env.PI_NVIM_BRIDGE`.
- MOCKING: verify the env var is set after startBridge and deleted after stopBridge.
- DOCS: [Mode A] JSDoc explaining the process.env inheritance discovery + criticality.

---

## §0 — Baseline (what exists TODAY, read from the live tree)

`extension/pi-editor-bridge.ts` (post-S6) already has:
- module state: `let server`, `let socketPath`, `let token` (module-level, set/cleared by
  start/stop).
- getters: `getServer()`, `getSocketPath()`, `getToken()` (the ONLY sanctioned read path —
  jiti does not live-bind `export let` reassignment, so state is exposed via getters; S2 §1.2).
- `startBridge(ctx: ExtensionContext)` — generates token, binds `${tmpdir()}/pi-editor-bridge-${uuid}.sock`,
  attaches `server.on("error", …)`, `server.listen(socketPath)`, chmod 0o600. **Currently
  does `void ctx;` and has `// NOTE: NO process.env.PI_NVIM_BRIDGE write here — that is
  P1.M3.T8.S16.` at the end.** The JSDoc says "ctx.cwd is NOT dereferenced in S5 … reserved
  for the S16 BridgeDescriptor."
- `stopBridge()` — `server?.close()`, `rmSync(socketPath,{force:true})`, resets state. Has
  `// NOTE: delete process.env.PI_NVIM_BRIDGE is intentionally OMITTED here — … S16 adds
  the WRITE to startBridge and the matching DELETE here.`
- `__deps` seam: `{ createServer, chmodSync }` (mutable plain object — the `node:net` ESM
  namespace is FROZEN so it can't be `mock.method`'d; S5 §1.1/§3).
- default-export factory: `session_start` (TUI guard → log → captureProvider → startBridge,
  with `// TODO(S16): advertise via process.env.PI_NVIM_BRIDGE`) + `session_shutdown`
  (stopBridge, with `// NOTE: clearing process.env.PI_NVIM_BRIDGE belongs to S16`).

`extension/protocol.ts` (S4) defines the authoritative wire type:
```ts
export interface BridgeDescriptor {
	transport: "unix";   // v1 literal (§5.1 names a future TCP variant)
	path: string;
	token: string;
	pid: number;
	cwd: string;
	fdAvailable: boolean;
	serverVersion: string;
}
```
`extension/tests/protocol.test.ts` (S4) pins the EXACT literal the descriptor must equal:
```ts
{ transport:"unix", path:"/tmp/pi-editor-bridge-x.sock", token:"deadbeef",
  pid:4242, cwd:"/home/u/proj", fdAvailable:true, serverVersion:"0.1.0" }
```
→ the field is **`serverVersion`** with value **`"0.1.0"`**. This is the make-or-break
field name/value (see §1).

`extension/tsconfig.json` (S1/S4/S7): `include=["pi-editor-bridge.ts","protocol.ts",
"jsonl-reader.ts","tests/**/*.ts"]`; `strict:true`; `types:[]` (NO lib field → DOM globals);
`@types/node` IS resolvable (present under pi-coding-agent/node_modules/@types/node).

Tests run via jiti:
`JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs`
then `node --import "$JITI_REG" extension/tests/<suite>.ts`. Node 26.4.0. Reporter prints
`ℹ pass N` / `ℹ fail N` (NOT TAP). jiti prints a benign `module.register() is deprecated`
(DEP0205) on stderr — IGNORE.

---

## §1 — MAKE-OR-BREAK #1: `serverVersion` (NOT `version`)

**The PRD is internally inconsistent and the item description quotes BOTH forms.** Resolve:

| Source | field | value |
|---|---|---|
| PRD §4 (illustrative JSON in prose) | `version` | `"0.0.1"` |
| PRD §6.4 (server lifecycle skeleton — the code) | `serverVersion` | `"0.1.0"` |
| protocol.ts `BridgeDescriptor` (the TYPE) | `serverVersion` | `string` |
| protocol.test.ts (the pinned literal) | `serverVersion` | `"0.1.0"` |
| HelloResult / PingResult (§C) | `serverVersion` | `"0.1.0"` |
| item LOGIC line | `serverVersion` | `"0.1.0"` |
| item's quoted §4 descriptor (in the contract's RESEARCH NOTE) | `version` | `"0.0.1"` |

**Decision: use `serverVersion: "0.1.0"`.** Rationale: (a) it is the field the
`BridgeDescriptor` TYPE declares, so any other name is a TS error / wire mismatch; (b) it is
what the Neovim client decodes (P2.M4.T12.S21 `vim.json.decode`s into the same shape); (c) it
matches every CODE authority (§6.4 skeleton, the type, the test, HelloResult/PingResult) and
the item's own LOGIC line. PRD §4's `"version":"0.0.1"` is prose-draft drift. The item's
"RESEARCH NOTE" sentence that quotes §4 verbatim is the SOURCE of the confusion — the LOGIC
line (authoritative for behavior) wins.

**Compile-time guard:** build the descriptor as `{ … } satisfies BridgeDescriptor` (import
the type from `./protocol.ts`). `satisfies` checks the literal against the type WITHOUT
widening it, so a `version:` typo becomes a TS error at the build site. This is the single
best defense against the §4 drift bug. (Confirmed `satisfies` is available: target ES2022 +
TS ≥4.9; the repo compiles under the existing strict config.)

---

## §2 — MAKE-OR-BREAK #2: `fdAvailable` is HARDCODED `true` (v1)

The item LOGIC line says `fdAvailable: true`. The PRD §6.4 skeleton says `fdAvailable: !!fdPathAvailable()`.
Resolve:

- There is **NO** `fdPathAvailable()` helper anywhere in the extension today (grep: zero
  matches). Building a real detector (pi resolves fd via `ensureTool("fd")` at startup —
  architecture/research-pi-autocomplete.md:97,206) is its OWN concern: it would spawn/PATH-
  scan for the `fd` binary, which is exactly the kind of side-effect the item contract does
  NOT list as an INPUT (INPUT lists only `socketPath`, `token`, `ctx.cwd`).
- The item's MOCKING requirement is purely "env var set after startBridge / deleted after
  stopBridge" — it does NOT require controlling or asserting fd detection.
- Hardcoding `true` is **deterministic** for tests (no dependence on whether the test runner
  has `fd` installed — the same machine-independence principle S5's mocked test followed).

**Decision: hardcode `fdAvailable: true`.** Add a JSDoc NOTE that real fd detection
(mirroring pi's `ensureTool("fd")`) is deferred, citing PRD §6.4 `fdPathAvailable()` + §6.7
line "completion (readdir) still works. The bridge reports fdAvailable in hello." This keeps
S16 focused on the env advertisement (its actual job) and leaves fd detection to a future
refinement. (A plain `fdAvailable: true` also trivially `satisfies BridgeDescriptor`'s
`fdAvailable: boolean`.)

---

## §3 — WHERE to write the env var: inside `startBridge` (end), after listen+chmod

The item says "In startBridge() (or right after it's called)". Choose INSIDE startBridge:

- **PRD §6.4 skeleton does exactly this** — `process.env[BRIDGE_ENV] = JSON.stringify({…})`
  is the LAST line of `startBridge(ctx, cwd)`, after `server.listen` + chmod.
- **Cohesion:** the advertisement is only meaningful while a backing server exists. Writing
  it inside startBridge guarantees: every bridge that starts advertises; every stopBridge
  (including the error-handler path that calls stopBridge on `server.on("error")`) clears it.
- **State availability:** `socketPath` + `token` are module-level `let`s assigned a few lines
  above the write site, so they are guaranteed set. `ctx.cwd` becomes the reason startBridge
  finally dereferences `ctx` (removing the current `void ctx;`).
- **Ordering:** write AFTER `server.listen(socketPath)` + chmod so the descriptor reflects a
  bound, perms-locked socket (the descriptor is the client's connection target — it must not
  advertise a path that isn't listening yet). listen() is async (the 'listening' event fires
  later), but the socket FILE exists synchronously inside listen() (S5 verified chmod does
  not ENOENT), and the path/token strings are final the instant listen() is called — so
  writing the descriptor right after listen() is correct (the client connects after
  VimEnter, long after 'listening' fired).

`BRIDGE_ENV` constant: the §6.4 skeleton declares `const BRIDGE_ENV = "PI_NVIM_BRIDGE";`
module-level. Export it so the test references the name (not a hardcoded string) and so a
future rename is one-line. Place it next to the `server`/`socketPath`/`token` state.

**`delete process.env[BRIDGE_ENV]`** goes in `stopBridge()` (the matching half). Place it
AFTER the `token = undefined;` line, replacing the current NOTE comment. `delete` on a
process.env key is always safe (no-op if absent); reading afterwards yields `undefined`.

---

## §4 — Node `process.env` semantics (why JSON.stringify + delete are correct)

- **Assignment coerces to string.** `process.env.X = value` runs `value.toString()` (via the
  Proxy on process.env). Assigning a raw object → `"[object Object]"` (WRONG). So we
  `JSON.stringify(descriptor)` FIRST, then assign the string. Confirmed standard Node
  behavior; the §6.4 skeleton relies on it. (Ref: Node docs, process.env — "values are
  coerced to strings".)
- **JSON.stringify emits NO embedded newlines** for a flat object of string/number/boolean
  fields → the env var is a single clean line. Important because some consumers split on
  newlines; here Neovim does `vim.json.decode` on the whole value, but a newline-free string
  is still the safe contract. (If the descriptor ever grew nested structures, JSON.stringify
  still never emits literal `\n` unless one is in a string value — none of our fields are.)
- **`delete process.env.X`** removes the own property; `process.env.X` then reads
  `undefined`. Safe in stopBridge whether or not startBridge ran (idempotent, matches the
  existing try/catch idiom — though delete itself never throws).
- **Typing:** `@types/node` IS resolvable (verified present). `process.env` is typed
  `NodeJS.ProcessEnv` = `{ [key: string]: string | undefined }` → assigning a string and
  `delete` both compile with NO declaration augmentation. No `declare global { namespace
  NodeJS { interface ProcessEnv … } }` needed (that pattern is only for ergonomic
  autocompletion of known keys; it is NOT required for assignment/read to type-check here).

---

## §5 — process.env INHERITANCE = THE discovery mechanism (the [Mode A] JSDoc)

Confirmed in architecture/system_context.md §1 (citing interactive-mode.ts:3811-3816) and
PRD §2.1:
- pi spawns the external editor with `{ stdio:"inherit", shell: process.platform==="win32" }`
  and **NO `env:` option**.
- Node `spawn` defaults to inheriting the parent's `process.env` when `env` is omitted.
- Therefore anything the extension writes to `process.env.PI_NVIM_BRIDGE` BEFORE the editor
  launch (i.e. on `session_start`, which fires before any Ctrl+G) IS visible to the Neovim
  child as `vim.env.PI_NVIM_BRIDGE`.
- PRD §4 step 2 + §7.1: Neovim's `VimEnter` gate does `vim.json.decode(vim.env.PI_NVIM_BRIDGE)`;
  absent/unparseable → plugin stays dormant (this is why the plugin is safe to ship in a
  normal config). Present → activate.
- **This is THE discovery that makes the whole two-component design work** (PRD §2.1:
  "This is the discovery that makes the whole design work."). The descriptor carries the
  socket path + token the client needs to connect; without it the client has no way to find
  the bridge.

The [Mode A] JSDoc on startBridge (or a dedicated block above the env write) MUST state this:
spawn-inherits-process.env → write-before-launch → Neovim-reads-on-VimEnter. Criticality:
without this write, the plugin never activates and the bridge is unreachable.

---

## §6 — S5 test interaction (`bridge-lifecycle.test.ts` fakeCtx lacks `cwd`)

`extension/tests/bridge-lifecycle.test.ts` (S5) test 1 + tests 2/3 use
`const fakeCtx = {} as ExtensionContext;`. After S16, startBridge dereferences `ctx.cwd`.
- At COMPILE time: `ExtensionContext.cwd` is typed `string` (confirmed in pi's
  extensions/types.d.ts), so `cwd: ctx.cwd` in the `satisfies BridgeDescriptor` literal
  type-checks — NO compile error, NO required edit to S5's test.
- At RUNTIME: `ctx.cwd` is `undefined` → `JSON.stringify` OMITS the `cwd` key (JSON.stringify
  drops `undefined` values). S5 tests do NOT assert the env var (that's S16's job), so they
  still pass.
- **Optional cleanup (recommended, one-liner):** add `cwd: "/test"` to S5's `fakeCtx` so the
  descriptor is well-formed during S5's real-integration tests (tests 2/3 bind a real
  socket). NOT required for green; do it for cleanliness. Documented in the PRP as optional.

The new S16 test (`bridge-env.test.ts`) MUST pass a ctx WITH `cwd` (e.g. `cwd: "/test/proj"`)
so the descriptor it asserts is the real shape.

---

## §7 — No tsconfig change needed (simpler than S4/S7/S15)

- The code change is INSIDE `extension/pi-editor-bridge.ts` (already in `include`) — no new
  source module.
- The new test `extension/tests/bridge-env.test.ts` matches the `tests/**/*.ts` glob →
  auto-included.
- The type-only import `import type { BridgeDescriptor } from "./protocol.ts"` is fully
  erased at runtime; `protocol.ts` is already in `include`. (protocol.test.ts confirms
  protocol.ts loads as an empty namespace — zero runtime exports.)
- ⇒ **ZERO tsconfig edits.** This is the key simplification vs S4/S7/S15 (which each appended
  one file to `include`). Verify after: `compilerOptions` byte-identical.

---

## §8 — Test design (`extension/tests/bridge-env.test.ts`, node:test + jiti)

Mirror S5's two-pronged style (mocked for the exact-shape assertion + real/wiring for the
lifecycle), and S6's `captureHandlers()`/`makeCtx()` for the factory-wiring test.

Tests:
1. **mocked, exact descriptor shape** — `__deps.createServer`/`chmodSync` faked (reuse S5's
   fakeServer); `fakeCtx = { cwd: "/test/proj" } as ExtensionContext`. After startBridge:
   - `process.env.PI_NVIM_BRIDGE` is a `string`, is NOT `undefined`.
   - `JSON.parse(process.env.PI_NVIM_BRIDGE)` → object with transport==="unix",
     path===getSocketPath(), token===getToken(), pid===process.pid, cwd==="/test/proj",
     fdAvailable===true, serverVersion==="0.1.0" (NOTE: serverVersion, NOT version).
   - the RAW string contains no `"\n"` (single-line — safe env value).
   - exactly 7 keys (transport/path/token/pid/cwd/fdAvailable/serverVersion) — proves no
     stray `version` key leaked in.
2. **stopBridge deletes** — after test 1's startBridge, call stopBridge →
   `process.env.PI_NVIM_BRIDGE` === `undefined` (deleted). Also: stopBridge when env was
   never set is a safe no-op (delete on absent key).
3. **idempotent re-write** — startBridge twice; after the 2nd, the parsed descriptor's
   path/token equal the 2nd getSocketPath()/getToken() (NOT the 1st). Each startBridge writes
   a FRESH descriptor.
4. **wiring (full lifecycle via factory)** — reuse S6's `captureHandlers()`/`makeCtx()`.
   - `session_start(tui)` → env var set + decodes to a valid descriptor whose
     cwd===ctx.cwd. (Real startBridge here, like S6 test A.)
   - `session_shutdown` → env var deleted (undefined).
   - `session_start(rpc/json/print)` → env var NOT set (TUI guard returns before
     startBridge); proves non-TUI sessions never advertise (S3 regression preserved).

Cleanup discipline (process.env is shared process state): every test `stopBridge()`s (which
deletes the env var) AND/OR explicitly `delete process.env[BRIDGE_ENV]` in a `finally`. The
`__deps` overrides also restore in `finally` (S5 pattern). Because process.env leaks across
tests in the same process, this cleanup is load-bearing — without it test 1's value could
leak into test 2's "deleted" assertion.

---

## §9 — Scope guard (what S16 does NOT do)

- Does NOT add fd detection (`fdPathAvailable`) — §2.
- Does NOT change the BridgeDescriptor type (protocol.ts is S4's, UNCHANGED) — only CONSUMES
  it via `satisfies`.
- Does NOT touch tsconfig (§7).
- Does NOT implement onConnection / handlers / handshake / reader (S8/S9–S14) — the
  `onConnection(_sock)` placeholder + its `// TODO(S8)` comment stay byte-for-byte intact
  (re-grep before finishing).
- Does NOT touch jsonl-reader.ts, protocol.ts, or any other test file (except the OPTIONAL
  one-liner to S5's fakeCtx in §6).
- Does NOT write to any OTHER env var. Only `PI_NVIM_BRIDGE`.
- Does NOT log the token/descriptor (PRD §12 — the token is the auth boundary; console.error
  in the error handler already avoids printing it).

## §10 — Validation commands (verified for this tree)

```
# Level 1 — type-check (zero output, exit 0)
tsc --noEmit -p extension/tsconfig.json

# Level 2 — the new suite + regression suites
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/bridge-env.test.ts          # NEW — expect ℹ fail 0
node --import "$JITI_REG" extension/tests/bridge-lifecycle.test.ts     # S5  — expect ℹ fail 0
node --import "$JITI_REG" extension/tests/bridge-lifecycle-wiring.test.ts # S6
node --import "$JITI_REG" extension/tests/mode-guard.test.ts           # S3  — guard intact
node --import "$JITI_REG" extension/tests/provider-capture.test.ts     # S2
node --import "$JITI_REG" extension/tests/protocol.test.ts            # S4
node --import "$JITI_REG" extension/tests/jsonl-reader.test.ts        # S7

# Level 3 — extension still loads cleanly (non-TUI path → guard returns before startBridge)
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"   # exit 0, no error lines
```
```

SUCCESS METRIC: confidence 9/10 — the change is ~12 lines into a file whose patterns are
fully established (S5/S6 getters + __deps seam + factory wiring), the type is pinned by an
existing test (protocol.test.ts), and the only ambiguity (version vs serverVersion) is
resolved by the type + guarded by `satisfies`.
