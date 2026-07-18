---
name: "P1.M3.T8.S16 — Write BridgeDescriptor JSON to process.env.PI_EDITOR_BRIDGE (env advertisement / discovery mechanism)"
description: |
  Make the bridge **discoverable** by the Neovim child: after `startBridge()` binds the
  Unix socket + chmod, write a one-line JSON `BridgeDescriptor` to
  `process.env.PI_EDITOR_BRIDGE`; in `stopBridge()`, `delete` it. This is THE discovery
  mechanism the entire two-component design depends on — pi spawns `$EDITOR` with
  `{ stdio:"inherit" }` and **no `env:` option**, so the child Neovim inherits pi's
  `process.env` and reads `PI_EDITOR_BRIDGE` on `VimEnter` to find the socket path + token
  (PRD §4 step 2, §2.1, §7.1). The descriptor shape is the EXISTING
  `protocol.ts` `BridgeDescriptor` type: `{ transport:"unix", path, token, pid, cwd,
  fdAvailable, serverVersion }`. NARROW and COHESIVE: ~12 lines INTO the existing
  `extension/pi-editor-bridge.ts` (no new source module, no tsconfig edit), plus a new
  `extension/tests/bridge-env.test.ts`. (Path note: orchestrator placed artifacts under
  `P1M3T1S1/`; the item is task **P1.M3.T8.S16** in the plan tree — the process.env
  advertisement. Build the feature; ignore the folder label.)
---

## Goal

**Feature Goal**: Land the env-var advertisement so that whenever a bridge server is
running, `process.env.PI_EDITOR_BRIDGE` holds a valid one-line JSON `BridgeDescriptor` the
Neovim child can `vim.json.decode`; whenever the bridge stops, the env var is gone. This
completes the pi-side half of the discovery contract (the Neovim-side `VimEnter` gate that
*reads* it is P2.M4.T12.S21 — treat that PRP as merged and this as its input).

**Deliverable** (all under `extension/`):
1. **MODIFY** `extension/pi-editor-bridge.ts`:
   - ADD module-level `export const BRIDGE_ENV = "PI_EDITOR_BRIDGE";`.
   - ADD `import type { BridgeDescriptor } from "./protocol.ts";` (type-only — protocol.ts
     has zero runtime exports).
   - In `startBridge(ctx)`: replace `void ctx;` with real use of `ctx.cwd`, and add — as
     the **last line, after `server.listen()` + chmod** — `process.env[BRIDGE_ENV] =
     JSON.stringify({ transport:"unix", path: socketPath!, token: token!, pid: process.pid,
     cwd: ctx.cwd, fdAvailable: true, serverVersion: "0.1.0" } satisfies BridgeDescriptor);`
     (remove the trailing `// NOTE: NO process.env.PI_EDITOR_BRIDGE write here …` comment).
   - In `stopBridge()`: after `token = undefined;`, add `delete process.env[BRIDGE_ENV];`
     (replace the `// NOTE: delete … is intentionally OMITTED …` comment).
   - In the factory: remove the `// TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE …`
     line from `session_start` and the `// NOTE: clearing process.env.PI_EDITOR_BRIDGE
     belongs to S16 …` line from `session_shutdown` (the work is now done inside
     start/stopBridge).
   - ADD a [Mode A] JSDoc block explaining the process.env-inheritance discovery + its
     criticality (see Implementation Patterns for the exact text).
2. **CREATE** `extension/tests/bridge-env.test.ts` — a `node:test`+jiti suite (matching the
   S2/S3/S4/S5/S6/S7 test conventions) with ~4 tests: mocked exact-descriptor-shape,
   stopBridge-deletes, idempotent re-write, and full-factory lifecycle wiring (incl. the
   non-TUI guard regression).

**Success Definition**:
- `tsc --noEmit -p extension/tsconfig.json` → exit 0, **no output** (the `satisfies
  BridgeDescriptor` literal + the type-only import type-check under the UNCHANGED
  `compilerOptions`; the `!` non-null assertions are safe because socketPath/token are
  assigned a few lines above the write site).
- `node --import "$JITI_REG" extension/tests/bridge-env.test.ts` → exit 0, `ℹ fail 0`
  (every parsed descriptor has `serverVersion:"0.1.0"` — NOT `version`; exactly 7 keys;
  env var deleted after stopBridge; non-TUI sessions never advertise).
- All pre-existing suites still green (regression): `bridge-lifecycle.test.ts` (S5),
  `bridge-lifecycle-wiring.test.ts` (S6), `mode-guard.test.ts` (S3), `provider-capture.test.ts`
  (S2), `protocol.test.ts` (S4), `jsonl-reader.test.ts` (S7), and the dispatch suite (S15)
  once merged.
- `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits 0 with no error
  lines (the modified extension still loads; print mode hits the TUI guard so startBridge
  doesn't run — proves the load path is undisturbed).
- The `onConnection(_sock)` placeholder + its `// TODO(S8)` comment in pi-editor-bridge.ts
  are byte-for-byte UNCHANGED (re-grep before finishing).

## User Persona (if applicable)

**Target User**: The downstream implementer of **P2.M4.T12.S21** (Neovim `VimEnter`
activation gate). That plugin code does `vim.json.decode(vim.env.PI_EDITOR_BRIDGE)` and
activates iff it parses into a valid descriptor. S16 is what makes `vim.env.PI_EDITOR_BRIDGE`
non-empty in the first place.

**Use Case**: User presses `Ctrl+G` in pi's TUI → pi spawns `$EDITOR` (Neovim) with
inherited `process.env` → Neovim's `VimEnter` reads `PI_EDITOR_BRIDGE`, decodes the
descriptor, connects to `path` and authenticates with `token`. Without S16, `vim.env.PI_EDITOR_BRIDGE`
is empty → the plugin stays dormant → the bridge is unreachable.

**Pain Points Addressed**: There is no other side-channel for Neovim to learn the
randomized socket path + secret token (both are per-session-random — PRD §5.1/§12). The env
var is the single, dependency-free discovery path that piggybacks on pi's existing spawn.

## Why

- **The discovery that makes the whole design work.** Per PRD §2.1 ("This is the discovery
  that makes the whole design work") and architecture/system_context.md §1: pi spawns the
  editor with `{ stdio:"inherit", shell: process.platform==="win32" }` and **no `env:`
  option** → Node `spawn` inherits the parent's `process.env` → anything the extension
  writes to `process.env.PI_EDITOR_BRIDGE` before the launch is visible to the Neovim child.
  Writing the descriptor on `session_start` (which fires before any Ctrl+G) is therefore the
  only side-channel that needs zero Neovim-side wiring to find the bridge.
- **Cohesion with the server lifecycle.** Writing the advertisement INSIDE startBridge (after
  listen+chmod) and clearing it INSIDE stopBridge means the env var is always consistent with
  whether a server exists — including the `server.on("error")` path that calls stopBridge
  (S6), which now also clears the advertisement. No stale descriptors pointing at unlinked
  sockets.
- **Zero new dependencies / zero config churn.** `process.env` assignment + `JSON.stringify`
  are builtins; the descriptor type already exists (S4 protocol.ts). No tsconfig edit, no new
  source module — the smallest possible change that unlocks the entire client side.

## What

A few-line edit to `startBridge`/`stopBridge` + a constant + a type-only import + a new
test. No new module, no tsconfig change, no new env vars beyond `PI_EDITOR_BRIDGE`, no fd
detection (deferred — see Gotchas).

### Success Criteria

- [ ] `extension/pi-editor-bridge.ts` exports `BRIDGE_ENV = "PI_EDITOR_BRIDGE"` and imports
      `BridgeDescriptor` (type-only) from `./protocol.ts`.
- [ ] `startBridge(ctx)` writes `process.env[BRIDGE_ENV] = JSON.stringify(<BridgeDescriptor>)`
      as its **last line** (after listen+chmod), where the descriptor literal is exactly
      `{ transport:"unix", path: socketPath!, token: token!, pid: process.pid,
      cwd: ctx.cwd, fdAvailable: true, serverVersion: "0.1.0" }` and is checked with
      `satisfies BridgeDescriptor`. `void ctx;` is REMOVED (ctx.cwd is now used).
- [ ] The descriptor uses **`serverVersion: "0.1.0"`** — NOT `version` (see Gotchas #1). The
      `satisfies` guard makes a `version` typo a compile error.
- [ ] `stopBridge()` calls `delete process.env[BRIDGE_ENV];` after resetting state.
- [ ] `session_start`'s `// TODO(S16)…` line and `session_shutdown`'s `// NOTE: clearing …`
      line are removed (the work moved into start/stopBridge).
- [ ] A [Mode A] JSDoc explains the spawn-inherits-process.env discovery + criticality.
- [ ] `extension/tests/bridge-env.test.ts` EXISTS, uses `node:test` + `node:assert/strict`
      (NOT vitest), and asserts: (a) mocked exact-descriptor shape incl. serverVersion + 7
      keys + no `\n`; (b) stopBridge deletes (+ no-op when never set); (c) idempotent
      re-write; (d) full-factory lifecycle incl. non-TUI guard.
- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] `node --import "$JITI_REG" extension/tests/bridge-env.test.ts` → exit 0, `ℹ fail 0`.
- [ ] All pre-existing suites still report `ℹ fail 0` (regression).
- [ ] `onConnection(_sock)` placeholder + its `// TODO(S8)` comment byte-for-byte unchanged.
- [ ] `extension/tsconfig.json` is UNCHANGED (no `include`/`compilerOptions` edit).
- [ ] `extension/protocol.ts` is UNCHANGED.
- [ ] `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits 0, no errors.

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo, given the current
`extension/pi-editor-bridge.ts` (post-S6), `extension/protocol.ts` (S4), and this PRP, can
(1) make the exact edits from the pinned before/after in Implementation Patterns (every line
reproduced — no guessing), (2) write the test from the supplied skeleton, and (3) run the
exact validation commands to green — with every load-bearing claim (serverVersion-not-version,
fdAvailable-hardcoded-true, JSON.stringify-then-assign, where-to-write, the `satisfies`
guard, the S5 fakeCtx interaction, no tsconfig edit) cited and reasoned in `research/notes.md`.

### Documentation & References

```yaml
# MUST READ — the authoritative task analysis FOR THIS EXACT TASK
- docfile: plan/001_c56962b4fa17/P1M3T1S1/research/notes.md
  why: the make-or-break decisions: §1 serverVersion-NOT-version (the PRD §4 "version":"0.0.1" is prose drift; protocol.ts type + protocol.test.ts literal + §6.4 skeleton + item LOGIC all use serverVersion:"0.1.0" — use `satisfies BridgeDescriptor` as the compile-time guard); §2 fdAvailable hardcoded true (no fdPathAvailable() helper exists; item INPUT omits fd; deferred); §3 WHERE to write (inside startBridge end, after listen+chmod — §6.4 skeleton does this; ctx.cwd now dereferenced, remove `void ctx`); §4 Node process.env coercion (assign→toString, so JSON.stringify FIRST; delete is safe/idempotent; @types/node present → no ProcessEnv augmentation needed); §5 the discovery criticality for the Mode-A JSDoc; §6 S5 fakeCtx has no cwd (compiles because ctx.cwd is typed string; optional one-liner to add cwd); §7 no tsconfig edit.
  section: "all sections (§1 + §3 + §4 are the three make-or-break claims)"
  critical: |
    §1 is THE bug-prevention claim: the item description QUOTES both `version:"0.0.1"`
    (from PRD §4 prose) and `serverVersion:"0.1.0"` (from the LOGIC line). The TYPE
    (protocol.ts BridgeDescriptor), the pinned test literal (protocol.test.ts), the §6.4
    code skeleton, and HelloResult/PingResult ALL use `serverVersion:"0.1.0"`. Build the
    descriptor literal `{ … } satisfies BridgeDescriptor` so a `version` typo is a TS error.

# MUST READ — the type the descriptor must satisfy (type-only import source)
- file: extension/protocol.ts
  why: §B defines `interface BridgeDescriptor { transport:"unix"; path:string; token:string; pid:number; cwd:string; fdAvailable:boolean; serverVersion:string; }` — the EXACT shape. protocol.ts is TYPE-ONLY (zero runtime exports; protocol.test.ts confirms it loads as an empty namespace). Import it as `import type { BridgeDescriptor } from "./protocol.ts"` (fully erased at runtime). DO NOT edit protocol.ts; DO NOT add a value import.
  section: "§B (BridgeDescriptor)"
  critical: |
    The field is `serverVersion` (string), NOT `version`. The descriptor literal you build
    MUST `satisfies BridgeDescriptor` so the name is checked at compile time. transport is
    the literal "unix".

# MUST READ — the pinned literal the descriptor must equal (shape authority)
- file: extension/tests/protocol.test.ts
  why: lines ~78-86 construct a `BridgeDescriptor` literal with EXACTLY { transport:"unix", path:"/tmp/pi-editor-bridge-x.sock", token:"deadbeef", pid:4242, cwd:"/home/u/proj", fdAvailable:true, serverVersion:"0.1.0" }. This is the canonical shape — your runtime descriptor must match it field-for-field (modulo the live path/token/pid/cwd values). Confirms serverVersion:"0.1.0" and the 7-key set.
  section: "the `const desc: BridgeDescriptor = { … }` literal (~line 78)"

# MUST READ — the file you are editing (the live post-S6 source)
- file: extension/pi-editor-bridge.ts
  why: contains startBridge(ctx) (with `void ctx;` + the trailing `// NOTE: NO … write here … S16` comment), stopBridge() (with the `// NOTE: delete … is intentionally OMITTED …` comment), the module-level `let server/socketPath/token`, the getters getSocketPath()/getToken(), the `__deps` seam, and the factory's `// TODO(S16)`/`// NOTE: clearing …` lines. Re-grep before finishing to confirm onConnection(_sock) + its // TODO(S8) comment are unchanged.
  section: "startBridge, stopBridge, the state block, the factory"
  critical: |
    Three load-bearing existing facts: (1) socketPath/token are module-level `let`s assigned
    a few lines above the write site (so `!` is safe); (2) the `__deps` seam (createServer/
    chmodSync) is the sanctioned override point for tests (the node:net namespace is FROZEN);
    (3) startBridge is ALREADY wired into session_start (S6) behind the TUI guard, so the env
    write is automatically TUI-gated — do NOT add a second guard.

# MUST READ — the test patterns to mirror (mocked + real + wiring)
- file: extension/tests/bridge-lifecycle.test.ts
  why: S5's suite. Test 1 is the MOCKED exact-shape template: snapshot `__deps.createServer`/`chmodSync`, install a `fakeServer` ({listen→records arg+returns this, close→noop, on→returns this}), call startBridge(fakeCtx), assert via getters, restore in finally, stopBridge() cleanup. Tests 2/3 are the REAL-integration template (await once(srv,"listening"), statSync mode 0o600). Mirror this two-pronged style for bridge-env.test.ts.
  section: "TEST 1 (mocked) + the `const realCreateServer = __deps.createServer` snapshot/restore idiom"

- file: extension/tests/bridge-lifecycle-wiring.test.ts
  why: S6's suite. The `captureHandlers()` helper (fake pi `.on` records session_start + session_shutdown handlers) + `makeCtx(mode)` helper ({mode, ui:{addAutocompleteProvider:noop}}) are the template for the full-factory lifecycle test. Test A does a REAL startBridge via session_start(tui); Test B proves non-TUI modes create NO server. Reuse both helpers verbatim for the wiring test, adding cwd to makeCtx.
  section: "captureHandlers() + makeCtx() + TEST A/B"

# SUPPORTING — the consumer of this descriptor (treat as merged; design input shape to match)
- docfile: plan/001_c56962b4fa17/P1M3T1S1/research/notes.md
  why: §5 summarizes the consumer: Neovim's VimEnter gate (P2.M4.T12.S21) does `vim.json.decode(vim.env.PI_EDITOR_BRIDGE)`; absent/unparseable → dormant; present → connect to `path`, auth with `token`. This is WHY the descriptor must be a single clean JSON line and WHY serverVersion (not version) matters — the Lua side decodes into the same contract.
  section: "§5 (the discovery mechanism + the consumer)"

# SUPPORTING — PRD requirements + the authoritative skeleton
- docfile: PRD.md
  why: §2.1 (editor launch — spawn has NO env option → child inherits process.env → "This is the discovery that makes the whole design work"); §4 step 2 (the descriptor write + the illustrative JSON — NOTE the prose says `version` but §6.4's CODE says serverVersion; the code wins); §6.4 (the `startBridge`/`stopBridge` reference skeleton that writes `process.env[BRIDGE_ENV] = JSON.stringify({transport:"unix",path:socketPath,token,pid:process.pid,cwd,fdAvailable:!!fdPathAvailable(),serverVersion:"0.1.0"})` as startBridge's last line and `delete process.env[BRIDGE_ENV]` in stopBridge — the code authority); §7.1 (Neovim VimEnter gate reads+decodes the env var); §12 (token is the auth boundary — do NOT log the descriptor).
  section: "§2.1, §4 step 2, §6.4 (the skeleton), §7.1, §12"
  critical: |
    §6.4 is the CODE authority for WHERE (last line of startBridge) and the field names
    (serverVersion, NOT version). §4's prose JSON is the ONLY place `version` appears — it
    is draft drift; do not copy it. §6.4 uses `fdPathAvailable()` which does NOT exist yet —
    hardcode `true` per the item contract (research §2).

# SUPPORTING — system_context confirmation of the spawn inheritance
- docfile: plan/001_c56962b4fa17/architecture/system_context.md
  why: §1 "Editor Launch — process.env Inheritance (CRITICAL)" cites interactive-mode.ts:3811-3816 (`{ stdio:"inherit", shell: process.platform==="win32" }` — no env option) and states Node spawn inherits process.env when env is omitted. This is the factual backbone of the [Mode A] JSDoc.
  section: "§1 (process.env inheritance)"

# SUPPORTING — Node process.env semantics (coercion + delete)
- url: https://nodejs.org/api/process.html#processenv
  why: confirms `process.env` assignment coerces the value to a string (so JSON.stringify FIRST, never assign a raw object → "[object Object]"); that values are `string | undefined`; and that `delete process.env.X` removes the key (subsequent reads → undefined). Also confirms the proxy nature of process.env (why direct assignment works without a declaration).
  section: "`process.env` (coercion to string; delete behavior)"
  critical: |
    The descriptor MUST be `JSON.stringify(...)`'d BEFORE assignment — `process.env.X =
    {object}` stores "[object Object]". `delete process.env[BRIDGE_ENV]` is always safe
    (idempotent), matching stopBridge's existing no-op-safe teardown style.

# SUPPORTING — @types/node ProcessEnv typing (no augmentation needed)
- url: https://github.com/DefinitelyTyped/DefinitelyTyped/blob/master/types/node/process.d.ts
  why: confirms `interface ProcessEnv { [key: string]: string | undefined }` has an index signature → assigning `process.env.PI_EDITOR_BRIDGE = "<string>"` and `delete process.env.PI_EDITOR_BRIDGE` both type-check with NO `declare global { namespace NodeJS { interface ProcessEnv … } }` augmentation. (Augmentation is only for editor autocomplete of known keys, not for compile-correctness here.) @types/node IS resolvable in this repo (verified present under pi-coding-agent/node_modules/@types/node).
  section: "ProcessEnv interface (index signature)"
```

### Current Codebase tree (post-S6 baseline — S16 edits 1 existing file, adds 1 test)

```bash
extension/
├── pi-editor-bridge.ts            # (S1+S2+S3+S5+S6) default-export factory + captureProvider/getProvider/liveProvider + startBridge/stopBridge/getServer/getSocketPath/getToken/__deps/onConnection-PLACEHOLDER. S16 EDITS startBridge + stopBridge + adds BRIDGE_ENV const + BridgeDescriptor type import + Mode-A JSDoc; removes the TODO(S16)/NOTE comments. onConnection placeholder UNCHANGED.
├── protocol.ts                    # (S4) type-only JSON-RPC contract. S16 imports the BridgeDescriptor TYPE from it (no edit).
├── jsonl-reader.ts                # (S7) S16 does NOT touch it.
├── tsconfig.json                  # (S1/S4/S7) include=["pi-editor-bridge.ts","protocol.ts","jsonl-reader.ts","tests/**/*.ts"]. S16 makes NO edit (code goes into an already-included file; new test matches tests/**/*.ts).
└── tests/
    ├── provider-capture.test.ts   # (S2) regression — S16 does NOT touch.
    ├── mode-guard.test.ts         # (S3) regression — S16 does NOT touch.
    ├── protocol.test.ts           # (S4) regression — S16 does NOT touch.
    ├── bridge-lifecycle.test.ts   # (S5) regression — OPTIONAL one-liner: add cwd to fakeCtx (§6). NOT required.
    ├── bridge-lifecycle-wiring.test.ts # (S6) regression — S16 does NOT touch.
    ├── jsonl-reader.test.ts       # (S7) regression — S16 does NOT touch.
    └── (dispatch.test.ts)         # (S15, if merged) regression — S16 does NOT touch.
# plan/ holds planning artifacts only — no other source code
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
├── pi-editor-bridge.ts            # (MODIFY) +BRIDGE_ENV const, +import type BridgeDescriptor, startBridge writes process.env[BRIDGE_ENV] as last line (+removes void ctx), stopBridge deletes it, factory TODO/NOTE comments removed, +Mode-A JSDoc.
├── protocol.ts                    # (UNCHANGED — S4)
├── jsonl-reader.ts                # (UNCHANGED — S7)
├── tsconfig.json                  # (UNCHANGED — no include/compilerOptions edit)
└── tests/
    ├── bridge-env.test.ts         # (CREATE) node:test+jiti: mocked exact-descriptor-shape + stopBridge-deletes + idempotent re-write + full-factory lifecycle (incl non-TUI guard). process.env cleanup in finally.
    └── … (all pre-existing suites UNCHANGED except the optional S5 fakeCtx one-liner)
```

**File responsibilities**
- `extension/pi-editor-bridge.ts` — gains the env advertisement: a `BRIDGE_ENV` constant, a
  type-only `BridgeDescriptor` import, the write at the end of `startBridge`, the delete in
  `stopBridge`, and the Mode-A discovery JSDoc. Still the single bridge lifecycle module.
- `extension/tests/bridge-env.test.ts` — the contract gate for S16: proves the descriptor is
  the exact `BridgeDescriptor` shape (serverVersion, 7 keys, single-line), that stopBridge
  clears it, that re-start rewrites it, and that the full factory lifecycle
  (session_start→set / session_shutdown→clear / non-TUI→never-set) works.

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL #1 (research §1; the PRD is self-contradictory): the descriptor field is
//   `serverVersion: "0.1.0"`, NOT `version: "0.0.1"`. PRD §4's prose JSON uses `version`,
//   but EVERY code authority — protocol.ts `BridgeDescriptor`, protocol.test.ts's pinned
//   literal, PRD §6.4's skeleton, and HelloResult/PingResult — uses `serverVersion`.
//   The item description quotes BOTH; its LOGIC line (authoritative for behavior) uses
//   serverVersion. BUILD THE LITERAL AS `{ … } satisfies BridgeDescriptor` so a `version`
//   typo is a TS compile error. This is the single highest-risk bug in this task.

// CRITICAL #2 (research §4; Node process.env): assignment COERCES to string. You MUST
//   `JSON.stringify(descriptor)` BEFORE assigning — `process.env.X = {object}` stores
//   "[object Object]". JSON.stringify of a flat string/number/boolean object emits NO
//   embedded `\n`, so the env var is a single clean line (safe for vim.json.decode).

// CRITICAL #3 (research §2; fdAvailable): hardcode `true` per the item contract. There is
//   NO `fdPathAvailable()` helper in the extension (grep: zero matches), the item INPUT
//   lists only socketPath/token/cwd, and real fd detection (pi's `ensureTool("fd")`) is a
//   separate concern. Add a JSDoc NOTE that detection is deferred (cite §6.4). Hardcoding
//   `true` is also DETERMINISTIC for tests (no dependence on whether `fd` is installed).

// GOTCHA (research §3): write the descriptor as the LAST line of startBridge, AFTER
//   server.listen() + chmod — matches PRD §6.4 and guarantees the descriptor reflects a
//   bound, perms-locked socket. socketPath/token are module-level `let`s assigned a few
//   lines above, so the `!` non-null assertions are safe. Remove the existing `void ctx;`
//   (ctx.cwd is now used). Do NOT add a second TUI guard — startBridge is already called
//   behind the guard in session_start (S6).

// GOTCHA (research §7): NO tsconfig edit. The code change is inside pi-editor-bridge.ts
//   (already in include); the new test matches tests/**/*.ts; the BridgeDescriptor import
//   is type-only (protocol.ts already in include). This is simpler than S4/S7/S15.

// GOTCHA (research §4): `delete process.env[BRIDGE_ENV]` is safe + idempotent (no-op if the
//   key is absent) — it never throws, matching stopBridge's existing no-op-safe style.
//   @types/node IS present; ProcessEnv has an index signature → assignment + delete both
//   compile with NO `declare global` augmentation.

// GOTCHA (research §6): extension/tests/bridge-lifecycle.test.ts (S5) uses
//   `const fakeCtx = {} as ExtensionContext;` (no cwd). After S16, startBridge dereferences
//   ctx.cwd. This still COMPILES (ctx.cwd is typed `string`) and S5 doesn't assert the env
//   var, so S5 stays green. OPTIONAL one-liner cleanup: add `cwd: "/test"` to that fakeCtx
//   so the descriptor is well-formed during S5's real-integration tests. NOT required.

// GOTCHA (process.env is shared process state): every test in bridge-env.test.ts MUST clean
//   up — stopBridge() (which deletes the env var) AND/OR `delete process.env[BRIDGE_ENV]`
//   in a `finally` — otherwise test 1's value can leak into test 2's "deleted" assertion.
//   Also restore `__deps.createServer`/`chmodSync` in finally (S5 pattern).

// GOTCHA (jiti): `import type { BridgeDescriptor } from "./protocol.ts"` is fully erased at
//   runtime (protocol.ts is type-only — protocol.test.ts confirms it loads as an empty
//   namespace). No runtime import is added.

// GOTCHA: node:test's default reporter prints `ℹ pass N` / `ℹ fail N` (NOT TAP). Judge by
//   exit code 0 + `ℹ fail 0`. jiti prints a benign `module.register() is deprecated`
//   (DEP0205) on Node 26 stderr — IGNORE.

// GOTCHA (PRD §12 — security): the token is the auth boundary. Do NOT console.log the
//   descriptor or the token. The existing `server.on("error")` handler already logs only
//   the Error (not the token) — leave it.

// STYLE: TABS for indentation (match pi-editor-bridge.ts / protocol.ts / every test).
//   `import type` for the BridgeDescriptor import. Mode-A JSDoc on startBridge (or a
//   dedicated block above the env write) with a STATUS (P1.M3.T8.S16) marker.
```

## Implementation Blueprint

### Data models and structure

S16 introduces **NO new wire types** — it CONSUMES the existing `BridgeDescriptor` from
`protocol.ts` (S4). Its "data model" is the descriptor literal it serializes:

```typescript
// The literal written to process.env.PI_EDITOR_BRIDGE (research §1 — serverVersion, NOT version):
{
  transport: "unix",        // v1 literal (PRD §5.1 names a future TCP variant)
  path: socketPath!,        // module-level, set by startBridge before this line
  token: token!,            // module-level, set by startBridge before this line
  pid: process.pid,         // Node global
  cwd: ctx.cwd,             // ExtensionContext.cwd (string — confirmed in pi's types.d.ts)
  fdAvailable: true,        // v1 hardcoded (research §2; real detection deferred)
  serverVersion: "0.1.0",   // PRD §6.4 + protocol.ts + protocol.test.ts
} satisfies BridgeDescriptor // compile-time shape guard (catches the `version` typo)
```

No module-level mutable state is added beyond the existing `server`/`socketPath`/`token`.
The only new module-level binding is the `const BRIDGE_ENV` (immutable).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-editor-bridge.ts — add the advertisement + teardown
  - ADD (module-level, next to the `let token`/getters block):
        /** Environment variable name the Neovim child reads to discover the bridge (PRD §4 step 2, §6.4, §7.1). */
        export const BRIDGE_ENV = "PI_EDITOR_BRIDGE";
  - ADD (top of file, with the other `import type` lines):
        import type { BridgeDescriptor } from "./protocol.ts";
  - EDIT startBridge(ctx): replace the `void ctx;` line with a comment that ctx.cwd is now
      used by the descriptor; ADD as the LAST line of startBridge (after the chmod if-block,
      replacing the `// NOTE: NO process.env.PI_EDITOR_BRIDGE write here …` comment):
        // Advertise the bridge so the Neovim child (spawned by pi with stdio:"inherit" and
        // NO env option → inherits process.env) can discover it on VimEnter. THE discovery
        // mechanism (PRD §2.1/§4 step 2/§7.1). Written AFTER listen()+chmod so the descriptor
        // reflects a bound, perms-locked socket. `satisfies BridgeDescriptor` guards the
        // field names at compile time (serverVersion, NOT version — research §1).
        process.env[BRIDGE_ENV] = JSON.stringify({
        	transport: "unix",
        	path: socketPath!,
        	token: token!,
        	pid: process.pid,
        	cwd: ctx.cwd,
        	fdAvailable: true, // v1 hardcoded; real fd detection (PRD §6.4 fdPathAvailable) deferred
        	serverVersion: "0.1.0",
        } satisfies BridgeDescriptor);
  - EDIT stopBridge(): after the `token = undefined;` line, ADD (replacing the
      `// NOTE: delete process.env.PI_EDITOR_BRIDGE is intentionally OMITTED …` comment):
        delete process.env[BRIDGE_ENV]; // clear the advertisement (idempotent — no-op if absent)
  - EDIT the factory: REMOVE the `// TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE …`
      line from session_start and the `// NOTE: clearing process.env.PI_EDITOR_BRIDGE belongs
      to S16 …` line from session_shutdown (the work is now inside start/stopBridge).
  - ADD/UPDATE the [Mode A] JSDoc on startBridge: explain spawn-inherits-process.env →
      write-before-launch → Neovim reads on VimEnter; state criticality ("without this write
      the plugin never activates and the bridge is unreachable"); add a STATUS (P1.M3.T8.S16)
      marker. (See Implementation Patterns for exact text.)
  - UPDATE the now-stale STATUS JSDoc lines that say "env advertisement … P1.M3.T8.S16 (will
      call …)" / "S16 adds the WRITE …" → change to past tense / remove, since S16 IS this task.
  - DO NOT: touch onConnection (the _sock placeholder + // TODO(S8) comment stay intact);
      touch protocol.ts/jsonl-reader.ts; touch tsconfig.json; log the token/descriptor.

Task 2: CREATE extension/tests/bridge-env.test.ts (node:test + jiti)
  - IMPORT: `import { test } from "node:test"; import assert from "node:assert/strict";`
      `import type { ExtensionAPI, ExtensionContext, SessionStartEvent, SessionShutdownEvent } from "@earendil-works/pi-coding-agent";`
      `import { startBridge, stopBridge, getSocketPath, getToken, __deps, BRIDGE_ENV } from "../pi-editor-bridge.ts";`
      `import bridgeFactory from "../pi-editor-bridge.ts";` (for the wiring test).
  - SHARED HELPERS:
      - snapshot/restore `__deps.createServer`/`__deps.chmodSync` (S5 pattern) — top-level consts.
      - `cleanup()`: `stopBridge(); delete process.env[BRIDGE_ENV];` — call in every finally.
      - `fakeServer()` returning the S5 fake ({ listening:false, listen(arg){return this},
        close(){}, on(){return this} }).
      - reuse S6's `captureHandlers()` + `makeCtx(mode, cwd)` for the wiring test.
  - TEST 1 (mocked, exact descriptor shape):
      - install fakeServer + fake chmodSync via __deps; `const fakeCtx = { cwd: "/test/proj" } as ExtensionContext;`
      - startBridge(fakeCtx).
      - assert `typeof process.env[BRIDGE_ENV] === "string"` (set, not undefined).
      - `const d = JSON.parse(process.env[BRIDGE_ENV]!);`
      - assert d.transport === "unix"; d.path === getSocketPath(); d.token === getToken();
        d.pid === process.pid; d.cwd === "/test/proj"; d.fdAvailable === true;
        d.serverVersion === "0.1.0" (NOTE: serverVersion, NOT version).
      - assert `Object.keys(d).length === 7` AND `Object.keys(d).sort()` equals
        ["cwd","fdAvailable","path","pid","serverVersion","token","transport"] (proves NO stray
        `version` key).
      - assert the RAW string `(process.env[BRIDGE_ENV]!).includes("\n") === false` (single line).
      - finally: restore __deps + cleanup().
  - TEST 2 (stopBridge deletes + no-op when never set):
      - `delete process.env[BRIDGE_ENV];` (ensure clean slate) → call stopBridge() →
        assert `process.env[BRIDGE_ENV] === undefined` (safe no-op delete on absent key).
      - startBridge(fakeCtx) → env set → stopBridge() → assert undefined (deleted).
      - finally: cleanup().
  - TEST 3 (idempotent re-write): startBridge(fakeCtx) → capture d1.path/d1.token →
      startBridge(fakeCtx) again (stopBridge runs first inside) → capture d2 →
      assert d2.path === getSocketPath() && d2.token === getToken() && d2.path !== d1.path
      (fresh descriptor each start). finally: cleanup().
  - TEST 4 (full-factory lifecycle incl non-TUI guard): reuse captureHandlers/makeCtx.
      - makeCtx("tui", "/home/u/proj") → session_start → assert env set + decoded
        d.cwd === "/home/u/proj" + d.serverVersion === "0.1.0". (REAL startBridge here, like
        S6 test A — await once(getServer(),"listening") before asserting, then stopBridge.)
      - session_shutdown → assert env undefined.
      - for mode of ["rpc","json","print"]: session_start(makeCtx(mode)) → assert env is
        undefined (TUI guard returns before startBridge → no advertisement). (S3 regression.)
      - finally: cleanup().
  - FOLLOW: TAB indentation; node:test top-level test() (no describe); assert/strict.
  - NAMING: descriptive test("…") titles.
  - PLACEMENT: extension/tests/bridge-env.test.ts (matches tests/**/*.ts → NO tsconfig edit).

Task 3: VALIDATE — run the validation commands; fix until all green
  - RUN (Level 1): `tsc --noEmit -p extension/tsconfig.json` (expect exit 0, no output).
  - RUN (Level 2): `node --import "$JITI_REG" extension/tests/bridge-env.test.ts` (exit 0,
      ℹ fail 0 — ignore the benign jiti DEP0205 deprecation on stderr).
  - RUN (Level 2 regression): re-run bridge-lifecycle (S5), bridge-lifecycle-wiring (S6),
      mode-guard (S3), provider-capture (S2), protocol (S4), jsonl-reader (S7) — each ℹ fail 0.
  - RUN (Level 3): `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` exits
      0, no error lines (modified extension still loads; print mode → TUI guard → no startBridge).
  - RUN (sanity): grep-confirm onConnection(_sock) + its // TODO(S8) comment UNCHANGED;
      grep-confirm tsconfig.json UNCHANGED; grep-confirm protocol.ts UNCHANGED.
```

### Implementation Patterns & Key Details

```typescript
// === EXACT EDITS to extension/pi-editor-bridge.ts (Task 1) ============================

// (1) Type-only import — add with the other `import type` lines near the top:
import type { BridgeDescriptor } from "./protocol.ts";

// (2) Module constant — add next to the `let token` / getters block:
/**
 * Environment variable name under which the BridgeDescriptor JSON is advertised to the
 * Neovim child (PRD §4 step 2, §6.4, §7.1). Exported so tests reference the name (not a
 * hardcoded string).
 */
export const BRIDGE_ENV = "PI_EDITOR_BRIDGE";

// (3) startBridge — replace `void ctx; …` and ADD the write as the LAST line (after chmod):
//     BEFORE:
//       void ctx; // ctx.cwd is reserved for the S16 BridgeDescriptor; S5 derives path from tmpdir().
//     AFTER: (remove the void ctx line; ctx.cwd is now used by the descriptor below)
//     …and at the very end, replacing `// NOTE: NO process.env.PI_EDITOR_BRIDGE write here — that is P1.M3.T8.S16.`:
	process.env[BRIDGE_ENV] = JSON.stringify({
		transport: "unix",
		path: socketPath!,
		token: token!,
		pid: process.pid,
		cwd: ctx.cwd,
		fdAvailable: true, // v1 hardcoded; real fd detection (PRD §6.4 fdPathAvailable) deferred
		serverVersion: "0.1.0",
	} satisfies BridgeDescriptor);
//   Update startBridge's JSDoc: change the "ctx.cwd is NOT dereferenced in S5" line to note
//   ctx.cwd IS now used (by the descriptor); add the Mode-A discovery block (see (5)).

// (4) stopBridge — replace the NOTE comment with the delete:
//     BEFORE:
//       token = undefined;
//       // NOTE: `delete process.env.PI_EDITOR_BRIDGE` is intentionally OMITTED here — S5 writes
//       // no env var. S16 adds the WRITE to startBridge and the matching DELETE here.
//     AFTER:
	token = undefined;
	delete process.env[BRIDGE_ENV]; // clear the advertisement (idempotent — no-op if absent)

// (5) [Mode A] JSDoc (add to startBridge, or a dedicated block above the env write):
/**
 * [Discovery — THE mechanism that makes the two-component design work]
 * pi spawns the external `$EDITOR` (Neovim) via InteractiveMode.openExternalEditor() with
 * `{ stdio: "inherit", shell: process.platform === "win32" }` and **NO `env:` option**
 * (interactive-mode.ts:3811-3816). Node `spawn` therefore INHERITS pi's `process.env`, so
 * anything this extension writes to `process.env.PI_EDITOR_BRIDGE` BEFORE the editor launch
 * is visible to the Neovim child as `vim.env.PI_EDITOR_BRIDGE`. The plugin's `VimEnter`
 * gate (P2.M4.T12.S21) does `vim.json.decode(vim.env.PI_EDITOR_BRIDGE)`; absent/unparseable
 * → dormant; present → connect to `path`, authenticate with `token`. Writing the descriptor
 * here (on session_start, which fires before any Ctrl+G) is the ONLY side-channel Neovim has
 * to learn the randomized socket path + secret token (PRD §2.1, §4 step 2, §7.1). Without
 * this write the plugin never activates and the bridge is unreachable.
 *
 * STATUS (P1.M3.T8.S16): the env advertisement. The descriptor is the existing
 * `BridgeDescriptor` (protocol.ts §B); built with `satisfies BridgeDescriptor` so the field
 * names (serverVersion, NOT version) are compile-checked. Cleared by stopBridge() (and thus
 * also by the server.on("error") path that calls stopBridge).
 */

// (6) Factory — remove the now-done TODO/NOTE comments:
//     In session_start, REMOVE: `// TODO(S16): advertise via process.env.PI_EDITOR_BRIDGE (env write is S16's job).`
//     In session_shutdown, REMOVE: `// NOTE: clearing process.env.PI_EDITOR_BRIDGE belongs to S16 (which writes it).`
//     (The advertisement write/delete now live inside startBridge/stopBridge.)

// === WHY each non-obvious choice =====================================================
// - `satisfies BridgeDescriptor` (NOT `: BridgeDescriptor` on a const): checks the literal
//   against the type without widening, and the expression's type stays the inferred literal
//   so JSON.stringify is unaffected. A `version:` typo → TS error. (research §1)
// - `socketPath!` / `token!`: non-null assertions are SAFE — both are module-level `let`s
//   assigned a few lines above (token = randomUUID()…; socketPath = join(tmpdir()…)). At the
//   write site they are guaranteed defined. (research §3)
// - JSON.stringify BEFORE assign: process.env coerces to string; a raw object → "[object Object]".
//   JSON.stringify of this flat literal emits a single line (no `\n`). (research §4)
// - `delete process.env[BRIDGE_ENV]`: always safe (idempotent); ProcessEnv index signature →
//   compiles with no augmentation. (research §4)
// - fdAvailable: true (hardcoded): no fdPathAvailable() helper exists; item INPUT omits fd;
//   deferred. Deterministic for tests. (research §2)
```

```typescript
// === extension/tests/bridge-env.test.ts (Task 2) — skeleton (fill in the bodies) ======
import { test } from "node:test";
import assert from "node:assert/strict";
import type {
	ExtensionAPI,
	ExtensionContext,
	SessionStartEvent,
	SessionShutdownEvent,
} from "@earendil-works/pi-coding-agent";
import bridgeFactory, {
	startBridge,
	stopBridge,
	getServer,
	getSocketPath,
	getToken,
	__deps,
	BRIDGE_ENV,
} from "../pi-editor-bridge.ts";

const realCreateServer = __deps.createServer;
const realChmodSync = __deps.chmodSync;

function cleanup() {
	stopBridge();
	delete process.env[BRIDGE_ENV];
}

function fakeServer() {
	const srv = {
		listening: false,
		listen(_arg: string) {
			return srv;
		},
		close() {
			/* noop */
		},
		on(_e: string, _h: (err: Error) => void) {
			return srv;
		},
	};
	return srv;
}

function installFakes() {
	__deps.createServer = (() => fakeServer()) as unknown as typeof realCreateServer;
	__deps.chmodSync = (() => {}) as unknown as typeof realChmodSync;
}
function restoreFakes() {
	__deps.createServer = realCreateServer;
	__deps.chmodSync = realChmodSync;
}

// S6 wiring helpers
type StartHandler = (e: SessionStartEvent, ctx: ExtensionContext) => void;
type ShutdownHandler = (e: SessionShutdownEvent) => void;
function captureHandlers() {
	let startHandler: StartHandler | undefined;
	let shutdownHandler: ShutdownHandler | undefined;
	const fakePi = {
		on(event: string, h: StartHandler | ShutdownHandler) {
			if (event === "session_start") startHandler = h as StartHandler;
			if (event === "session_shutdown") shutdownHandler = h as ShutdownHandler;
		},
	} as unknown as ExtensionAPI;
	bridgeFactory(fakePi);
	assert.ok(typeof startHandler === "function");
	assert.ok(typeof shutdownHandler === "function");
	return { startHandler: startHandler!, shutdownHandler: shutdownHandler! };
}
function makeCtx(mode: ExtensionContext["mode"], cwd = "/home/u/proj"): ExtensionContext {
	return { mode, cwd, ui: { addAutocompleteProvider: () => {} } } as unknown as ExtensionContext;
}
const STARTUP = { reason: "startup" } as SessionStartEvent;

test("startBridge (mocked): writes a valid 7-key BridgeDescriptor (serverVersion, not version) to process.env.PI_EDITOR_BRIDGE", () => {
	installFakes();
	try {
		const fakeCtx = { cwd: "/test/proj" } as ExtensionContext;
		startBridge(fakeCtx);
		const raw = process.env[BRIDGE_ENV];
		assert.equal(typeof raw, "string", "env var must be set");
		assert.equal(raw!.includes("\n"), false, "descriptor must be a single JSON line");
		const d = JSON.parse(raw!);
		assert.equal(d.transport, "unix");
		assert.equal(d.path, getSocketPath());
		assert.equal(d.token, getToken());
		assert.equal(d.pid, process.pid);
		assert.equal(d.cwd, "/test/proj");
		assert.equal(d.fdAvailable, true);
		assert.equal(d.serverVersion, "0.1.0"); // NOT "version"
		assert.deepEqual(
			Object.keys(d).sort(),
			["cwd", "fdAvailable", "path", "pid", "serverVersion", "token", "transport"],
			"exactly 7 keys — no stray `version`",
		);
	} finally {
		restoreFakes();
		cleanup();
	}
});

test("stopBridge deletes process.env.PI_EDITOR_BRIDGE (and is a safe no-op when never set)", () => {
	delete process.env[BRIDGE_ENV];
	stopBridge(); // no-op when env absent + idle
	assert.equal(process.env[BRIDGE_ENV], undefined);

	installFakes();
	try {
		startBridge({ cwd: "/x" } as ExtensionContext);
		assert.equal(typeof process.env[BRIDGE_ENV], "string", "precondition: set after startBridge");
		stopBridge();
		assert.equal(process.env[BRIDGE_ENV], undefined, "must be deleted after stopBridge");
	} finally {
		restoreFakes();
		cleanup();
	}
});

test("startBridge is idempotent: each call rewrites a FRESH descriptor (new path/token)", () => {
	installFakes();
	try {
		startBridge({ cwd: "/x" } as ExtensionContext);
		const d1 = JSON.parse(process.env[BRIDGE_ENV]!);
		startBridge({ cwd: "/x" } as ExtensionContext); // stopBridge runs first inside
		const d2 = JSON.parse(process.env[BRIDGE_ENV]!);
		assert.equal(d2.path, getSocketPath());
		assert.equal(d2.token, getToken());
		assert.notEqual(d2.path, d1.path, "second start must advertise a NEW path");
		assert.notEqual(d2.token, d1.token, "second start must advertise a NEW token");
	} finally {
		restoreFakes();
		cleanup();
	}
});

test("factory lifecycle: session_start(tui) advertises; session_shutdown clears; non-tui never advertises", async () => {
	const { startHandler, shutdownHandler } = captureHandlers();
	// tui: advertises
	startHandler(STARTUP, makeCtx("tui", "/home/u/proj"));
	const srv = getServer();
	assert.ok(srv, "precondition: server started");
	await new Promise((r) => setTimeout(r, 10)); // let listen() bind (real server)
	const d = JSON.parse(process.env[BRIDGE_ENV]!);
	assert.equal(d.cwd, "/home/u/proj");
	assert.equal(d.serverVersion, "0.1.0");
	// shutdown clears
	shutdownHandler({} as SessionShutdownEvent);
	assert.equal(process.env[BRIDGE_ENV], undefined, "cleared after session_shutdown");
	// non-tui: never advertises (S3 regression — guard returns before startBridge)
	for (const mode of ["rpc", "json", "print"] as const) {
		assert.doesNotThrow(() => startHandler(STARTUP, makeCtx(mode)));
		assert.equal(process.env[BRIDGE_ENV], undefined, `no advertisement after session_start(${mode})`);
	}
	cleanup();
});
```

### Integration Points

```yaml
ENV (process.env):
  - write: "process.env.PI_EDITOR_BRIDGE = JSON.stringify(<BridgeDescriptor>)"  # inside startBridge, last line
  - clear: "delete process.env.PI_EDITOR_BRIDGE"                                # inside stopBridge
  - field-shape: "MUST equal protocol.ts BridgeDescriptor: {transport:'unix',path,token,pid,cwd,fdAvailable,serverVersion:'0.1.0'}"
  - coercion: "JSON.stringify BEFORE assign (process.env coerces to string); single-line output (no \\n)"

TYPES (protocol.ts — type-only import):
  - consume: "import type { BridgeDescriptor } from './protocol.ts'  # no runtime import; protocol.ts unchanged"

CONFIG (tsconfig.json):
  - change: "NONE — code edits an already-included file; new test matches tests/**/*.ts"

NO-TOUCH (regression surface):
  - onConnection: "the _sock placeholder + // TODO(S8) comment stay byte-for-byte intact"
  - protocol.ts: "UNCHANGED"
  - jsonl-reader.ts: "UNCHANGED"
  - other tests: "UNCHANGED (optional: add cwd to bridge-lifecycle.test.ts fakeCtx — NOT required)"
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Type-check the extension (zero output, exit 0). The `satisfies BridgeDescriptor` literal +
# the type-only import + the `!` assertions must all type-check under the UNCHANGED compilerOptions.
tsc --noEmit -p extension/tsconfig.json

# Expected: exit 0, no output. If errors: READ them — a `version` typo would surface here as a
# `satisfies` failure (Object literal may only specify known properties). Fix before proceeding.
```

### Level 2: Unit Tests (Component Validation)

```bash
# The new suite + full regression (jiti transpiles TS on the fly).
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# NEW — the S16 contract gate:
node --import "$JITI_REG" extension/tests/bridge-env.test.ts          # expect exit 0, ℹ fail 0

# Regression — every prior suite must still be green (S16 is additive to start/stopBridge):
node --import "$JITI_REG" extension/tests/bridge-lifecycle.test.ts         # S5
node --import "$JITI_REG" extension/tests/bridge-lifecycle-wiring.test.ts  # S6
node --import "$JITI_REG" extension/tests/mode-guard.test.ts               # S3
node --import "$JITI_REG" extension/tests/provider-capture.test.ts         # S2
node --import "$JITI_REG" extension/tests/protocol.test.ts                # S4
node --import "$JITI_REG" extension/tests/jsonl-reader.test.ts            # S7
# (node --import "$JITI_REG" extension/tests/dispatch.test.ts)            # S15, if merged

# Expected: each exits 0 with ℹ fail 0. Ignore the benign jiti `module.register() is
# deprecated` (DEP0205) line on stderr. If bridge-env fails: the most likely cause is a
# `version` vs `serverVersion` mismatch, a missing cleanup() (process.env leak across tests),
# or a forgotten __deps restore — debug root cause, do not paper over.
```

### Level 3: Integration Testing (System Validation)

```bash
# The modified extension must still load cleanly under pi. Print mode hits the TUI guard,
# so startBridge does NOT run (no socket bind, no env write) — this proves the load path is
# undisturbed by the edits.
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"
# Expected: exit 0, prints "ok", no error lines.

# (The real end-to-end discovery — pi TUI → Ctrl+G → Neovim reads PI_EDITOR_BRIDGE → connects
# — requires the Neovim plugin side (P2) which is out of scope here. The bridge-env wiring
# test (Test 4) proves the pi-side half: session_start(tui) sets the env var with the correct
# shape; session_shutdown clears it; non-tui never sets it.)

# Sanity greps (must all pass before declaring done):
grep -n "onConnection(_sock" extension/pi-editor-bridge.ts       # placeholder intact
grep -n "TODO(S8)" extension/pi-editor-bridge.ts                 # S8 comment intact
grep -c "PI_EDITOR_BRIDGE" extension/tsconfig.json               # 0 (no tsconfig change)
diff <(git show HEAD:extension/protocol.ts) extension/protocol.ts # empty (protocol.ts unchanged)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# (N/A for this task — no web UI, no DB, no perf budget. The descriptor is a tiny static JSON
# string written once per session_start. Security note: PRD §12 — the token is the auth
# boundary; verify the descriptor is NEVER logged: grep -n "console" extension/pi-editor-bridge.ts
# should show ONLY the existing session_start log + the server.on("error") Error log — neither
# prints the token/descriptor.)
grep -n "console\." extension/pi-editor-bridge.ts   # audit: no token/descriptor leakage
```

## Final Validation Checklist

### Technical Validation

- [ ] `tsc --noEmit -p extension/tsconfig.json` → exit 0, no output.
- [ ] `node --import "$JITI_REG" extension/tests/bridge-env.test.ts` → exit 0, `ℹ fail 0`.
- [ ] All 6 (7 with S15) regression suites → `ℹ fail 0`.
- [ ] `pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"` → exit 0, no errors.

### Feature Validation

- [ ] After `startBridge(ctx)`, `process.env.PI_EDITOR_BRIDGE` is a string that `JSON.parse`es
      to a `BridgeDescriptor` with transport:"unix", path===getSocketPath(), token===getToken(),
      pid===process.pid, cwd===ctx.cwd, fdAvailable===true, **serverVersion:"0.1.0"**.
- [ ] The descriptor has EXACTLY 7 keys (no stray `version`).
- [ ] The raw env string contains no `\n` (single-line JSON).
- [ ] After `stopBridge()`, `process.env.PI_EDITOR_BRIDGE === undefined`.
- [ ] Repeated `startBridge` rewrites a fresh descriptor each time.
- [ ] Non-TUI `session_start` (rpc/json/print) NEVER sets the env var (TUI guard).
- [ ] No console output leaks the token or the descriptor (PRD §12).

### Code Quality Validation

- [ ] Follows existing patterns: `__deps` seam, getter-only state exposure, TAB indentation,
      `import type`, Mode-A JSDoc with STATUS marker.
- [ ] File placement matches the desired tree (edit in pi-editor-bridge.ts; new test in tests/).
- [ ] Anti-patterns avoided (see Anti-Patterns).
- [ ] `BRIDGE_ENV` exported and referenced by name in tests (no hardcoded "PI_EDITOR_BRIDGE").
- [ ] No tsconfig change (the simplification vs S4/S7/S15).

### Documentation & Deployment

- [ ] [Mode A] JSDoc on startBridge explains the spawn-inherits-process.env discovery + criticality.
- [ ] Stale STATUS comments ("S16 will call…", "S16 adds the WRITE…") updated to past tense / removed.
- [ ] No new environment variables beyond `PI_EDITOR_BRIDGE`.

---

## Anti-Patterns to Avoid

- ❌ Don't use `version` — the field is `serverVersion` (use `satisfies BridgeDescriptor` to enforce).
- ❌ Don't assign a raw object to `process.env.X` — JSON.stringify FIRST (else "[object Object]").
- ❌ Don't write the descriptor before `server.listen()` — write it LAST (after chmod), matching §6.4.
- ❌ Don't add a second TUI guard inside startBridge — it's already gated by the session_start guard (S6).
- ❌ Don't add a tsconfig `include` entry — no new source module; the test matches `tests/**/*.ts`.
- ❌ Don't add real `fd` detection — hardcode `true` per the item contract (detection is deferred).
- ❌ Don't `console.log` the descriptor or token (PRD §12 — token is the auth boundary).
- ❌ Don't forget `cleanup()` (stopBridge + delete env) in every test's `finally` — process.env is
  shared process state and leaks across tests in the same run.
- ❌ Don't touch `onConnection`, `protocol.ts`, `jsonl-reader.ts`, or any other test (except the
  optional S5 fakeCtx one-liner).
- ❌ Don't `import` (value) from protocol.ts — it's type-only; use `import type`.
