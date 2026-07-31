# PRP — P2.M1.T1.S2: Implement `resolveShell()` + populate descriptor fields in `startBridge`

> **Plan mapping:** task `P2.M1.T1.S2` ("Implement resolveShell() + populate
> descriptor fields in startBridge"). It is the **second** task of **P2.M1.T1**
> ("Bridge descriptor shell/shellSource/shellPath") within the **Shell Completion
> for !/!! Bash Mode** epic (PRD §17). S1 (parallel) was **type-only** — it widened
> `BridgeDescriptor`/`HelloResult`/`PingResult` to ACCEPT optional shell fields.
> **This task (S2) is the RUNTIME side**: implement the resolver, populate the
> descriptor, and update the descriptor-shape test that the population breaks.

---

## Goal

**Feature Goal**: Implement `resolveShell()` + a cached `getShellInfo()` getter +
a `__setShellInfoForTest()` test seam in `extension/pi-nvim-bridge.ts` (mirroring
the existing `resolveFdAvailable` cluster at L336-380), and populate the three
advisory shell fields (`shell`/`shellSource`/`shellPath`) into the
`satisfies BridgeDescriptor` object literal inside `startBridge` (L568-578). After
this task, the `PI_NVIM_BRIDGE` env blob carries the shell pi will execute `!`/`!!`
commands in, so the plugin's `prefer:"pi"` completion can match it (PRD §17.4 /
§17.10). Resolution chain (PRD §17.10.2): `PI_NVIM_SHELL` → `$SHELL` → `/bin/bash`.

**Deliverable** (2 files modified + 1 new — all in `extension/`):
- `extension/pi-nvim-bridge.ts` — MODIFY:
  1. +`export const SHELL_MIRROR_ENV = "PI_NVIM_SHELL";` (constants cluster ~L311).
  2. +`export interface ShellInfo { shell; shellSource: "pi" | "$SHELL" | "default"; shellPath? }`.
  3. +the resolver cluster (`let shellCache`, `getShellInfo()`, `__setShellInfoForTest()`,
     `resolveShell()`) immediately after the `resolveFdAvailable` cluster (~L380).
  4. +populate `shell`/`shellSource`/`shellPath` in the `startBridge` descriptor literal.
- `extension/tests/shell-resolver.test.ts` — NEW: node:test unit tests for the
  3-branch resolution chain + caching + the test seam.
- `extension/tests/bridge-env.test.ts` — MODIFY (CO-UPDATE, mandatory): its
  `Object.keys(desc).length === 7` assertions BREAK once shell fields are populated
  (verified — the descriptor now carries 9-10 keys). Inject a deterministic
  `ShellInfo` via the new seam, bump the count, and assert the shell fields.

**Success Definition**:
- `resolveShell()` returns exactly `{ shell: explicit, shellSource: "pi", shellPath: explicit }`
  when `PI_NVIM_SHELL` is set; `{ shell: $SHELL, shellSource: "$SHELL" }` (no
  `shellPath`) when only `SHELL` is set; `{ shell: "/bin/bash", shellSource: "default" }`
  (no `shellPath`) when neither is set. `PI_NVIM_SHELL` wins over `SHELL`.
- `getShellInfo()` caches the result (one `resolveShell()` per process); the test
  seam `__setShellInfoForTest(v)` overrides the cache (`undefined` resets).
- The `PI_NVIM_BRIDGE` blob now carries `shell`/`shellSource`/`shellPath`.
- `npx tsc --noEmit -p extension/tsconfig.json` exits 0 (the `satisfies` guard now
  typechecks because S1 widened `BridgeDescriptor`).
- `shell-resolver.test.ts` (new) passes; `bridge-env.test.ts` (updated) passes.
- The regression suites (`protocol`, `hello-handler`, `ping-bye-getcommands-handler`)
  stay green (no handler/protocol/runtime-behavior regression).
- [Mode A] JSDoc on `resolveShell()` cites PRD §17.10.2's honesty note (advisory-only;
  falls back to `$SHELL`; cannot read pi's real `shellPath` setting).

## User Persona (if applicable)

**Target User**: Developers of the §17 shell-completion subsystem — specifically
**S3** (wires shell into `makeHelloHandler`/`makePingHandler` via a `getShell` dep)
and **S4** (lua `M.server_info` extracts these fields). End users see nothing
directly until S3/S4 + the plugin side land.

**Use Case**: The plugin's `prefer:"pi"` shell resolution (PRD §17.4) reads
`descriptor.shell` to pick the completion driver matching pi's execution shell.
This task populates that field. S3 mirrors it into the live `hello`/`ping`
responses; S4 extracts it on the lua side.

**Pain Points Addressed**: Without `descriptor.shell`, the plugin cannot know which
shell pi runs `!`/`!!` in, so shell completion either guesses (`$SHELL`) or
no-ops. This field makes `prefer:"pi"` resolvable (and, per §17.4.3, emits a
one-time educational notice when it resolves a *poorer* shell than `$SHELL`).

## Why

- **Closes the §17.10 "only Component A change."** PRD §17.10 names the three
  descriptor fields as the single runtime change on the extension side. S1 made
  the *types* accept them; S2 *populates* them. Without S2 the fields are never on
  the wire and the whole §17 feature is inert.
- **Mirrors a proven, tested pattern.** The `resolveFdAvailable` cluster (cache +
  getter + seam + resolver) is the established way this codebase exposes a
  process-once resolution to (a) the descriptor, (b) the hello/ping handlers, and
  (c) unit tests. Replicating it for shell means S3's wiring is mechanical and the
  test approach is already proven.
- **Honest about the public-API gap (PRD §17.10.2).** `settingsManager`/
  `getShellConfig()` are NOT on `ExtensionContext`, so the extension cannot read
  pi's real `shellPath` setting. This task replicates `getShellConfig`'s ~10-line
  resolution via env vars (`PI_NVIM_SHELL` mirror, then `$SHELL`, then `/bin/bash`).
  The fields are **advisory** — the plugin degrades to `$SHELL` if absent (PRD
  §17.4 fallback chain). The JSDoc records this honestly.
- **Integrates with the parallel S1 (type widening) with ZERO conflict** — S1 edits
  `protocol.ts` + `protocol.test.ts`; S2 edits `pi-nvim-bridge.ts` +
  `shell-resolver.test.ts` (new) + `bridge-env.test.ts` (co-update). No file overlap.

## What

**User-visible behavior**: none directly (the env blob gains 2-3 JSON keys; the
plugin does not consume them until S3/S4 + the lua side). The *contract* change:
`process.env.PI_NVIM_BRIDGE` now JSON-serializes to an object that, alongside the
existing 7 fields, carries:

```jsonc
{
  "transport": "unix", "path": "…", "token": "…", "pid": 1234,
  "cwd": "…", "fdAvailable": true, "serverVersion": "0.1.0",
  "shell": "/bin/zsh",                       // NEW — resolved execution shell
  "shellSource": "pi" | "$SHELL" | "default" // NEW — how `shell` was derived
  // "shellPath": "…"                         // NEW — present only in the "pi" case (§Known Gotchas)
}
```

**Technical requirements** (all in `extension/pi-nvim-bridge.ts` unless noted):
- `export const SHELL_MIRROR_ENV = "PI_NVIM_SHELL";` (constants cluster).
- `export interface ShellInfo { shell: string; shellSource: "pi" | "$SHELL" | "default"; shellPath?: string; }`.
- `let shellCache: ShellInfo | undefined;` + `export function getShellInfo(): ShellInfo`
  (cached, lazily resolves) + `export function __setShellInfoForTest(v: ShellInfo | undefined): void`
  + `export function resolveShell(): ShellInfo` (the 3-branch chain).
- In `startBridge`'s descriptor literal: `const shellInfo = getShellInfo();` then
  `shell: shellInfo.shell, shellSource: shellInfo.shellSource, shellPath: shellInfo.shellPath`.
- NO edit to `protocol.ts` (S1 owns it), NO edit to the handlers (S3), NO edit to
  `connection.ts`, `tsconfig.json`, or any lua.

### Success Criteria

- [ ] `resolveShell()` returns the exact 3-branch matrix (PI_NVIM_SHELL → SHELL →
      /bin/bash), with `shellPath` present ONLY in the `PI_NVIM_SHELL` branch.
- [ ] `PI_NVIM_SHELL` precedence: when BOTH `PI_NVIM_SHELL` and `SHELL` are set,
      the `PI_NVIM_SHELL` branch wins.
- [ ] `getShellInfo()` caches: a second call returns the SAME object reference (no
      re-resolution); `resolveShell` is invoked at most once per process.
- [ ] `__setShellInfoForTest(v)` makes `getShellInfo()` return `v` without resolving;
      `__setShellInfoForTest(undefined)` resets so the next call re-resolves.
- [ ] The `PI_NVIM_BRIDGE` blob carries `shell` + `shellSource` always, and
      `shellPath` only in the `PI_NVIM_SHELL` case (JSON.stringify omits undefined).
- [ ] `npx tsc --noEmit -p extension/tsconfig.json` exits 0.
- [ ] `shell-resolver.test.ts` (new) passes; `bridge-env.test.ts` (updated) passes;
      `protocol`/`hello-handler`/`ping-bye-getcommands-handler` stay green.
- [ ] [Mode A] JSDoc on `resolveShell()` cites PRD §17.10.2 honesty note (advisory;
      falls back to `$SHELL`; cannot read pi's real `shellPath`).

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo needs
only this PRP + the exact current code quoted verbatim below (the `resolveFdAvailable`
cluster, the descriptor literal, the `bridge-env.test.ts` shape) + the verified
commands. Every line number was confirmed by `grep -n` + `read` against the live
file on 2025-07-31; the baseline (`tsc` 0, protocol 2/2, bridge-env 4/4) was
confirmed by live runs. The single non-obvious trap — that populating the descriptor
breaks `bridge-env.test.ts`'s `=== 7` key-count assertions — is spelled out in
§Known Gotchas and is a mandatory task (not optional).

### Documentation & References

```yaml
# MUST READ — the spec being implemented (reproduced in <selected_prd_content>)
- docfile: PRD.md
  why: "§17.10.2 gives the EXACT resolveShell() body (the 3-branch chain) + the honesty note (advisory; falls back to $SHELL; settingsManager not on ctx). §17.4.1 documents what descriptor.shell contains + the shellSource value semantics."
  section: "h3.39 (§17.10), h4.10 (§17.10.2 Resolution), h3.33 (§17.4), h4.0 (§17.4.1)"
  critical: "shellSource union is literally \"pi\" | \"$SHELL\" | \"default\" (the $SHELL member has a '$'). Resolution order is PI_NVIM_SHELL → $SHELL → /bin/bash. shellPath is set ONLY in the PI_NVIM_SHELL branch (= the explicit value)."

# MUST READ — the pattern to mirror (current code quoted verbatim in Blueprint)
- file: extension/pi-nvim-bridge.ts
  why: "(1) the resolveFdAvailable cluster at L336-380 is the EXACT shape to replicate (cache+getter+seam+resolver). (2) the startBridge descriptor literal at L568-578 is the single population site. (3) the constants cluster L286-316 is where SHELL_MIRROR_ENV goes. (4) BridgeDescriptor is ALREADY imported (L168) — no new import needed."
  pattern: "module-level `let xCache: T | undefined` + JSDoc; `export function getX()` lazily resolves on first call; `export function __setXForTest(v: T | undefined)`; `function resolveX(): T` (fd's resolver is PRIVATE, but per the task OUTPUT resolveShell is EXPORTED — the one sanctioned deviation)."
  gotcha: "resolveFdAvailable ends ~L380, immediately followed by isExecutableFile (its helper) at L382. Place the shell cluster AFTER the fd cluster so the two resolvers sit side-by-side."

# MUST READ — the test file to CO-UPDATE (mandatory; its === 7 assertions break)
- file: extension/tests/bridge-env.test.ts
  why: "3 of its 4 tests assert Object.keys(desc).length === 7. After S2 the descriptor carries shell fields (9-10 keys) → these assertions FAIL. Inject a deterministic ShellInfo via __setShellInfoForTest, bump 7→10, assert the shell fields, reset the cache in finally."
  pattern: "node:test + node:assert/strict; mockDeps() installs __deps (createServer/chmodSync); __setFdAvailableForTest(true/false) for fd determinism; EVERY test tears down in finally (restore __deps, reset caches, stopBridge). Mirror this EXACTLY for the shell seam."
  gotcha: "process.env is SHARED across tests in one process (the file's own GOTCHA #6). __setShellInfoForTest(undefined) in finally is MANDATORY or a prior test's injected value leaks into the next."

# MUST READ — the new test file's pattern source
- file: extension/tests/hello-handler.test.ts
  why: "the canonical node:test + deps-injection pattern: save/restore env + module state in finally, assert.are.equal for values. shell-resolver.test.ts follows this (but for process.env.PI_NVIM_SHELL/SHELL save-restore instead of deps)."
  pattern: "import { test } from 'node:test'; import assert from 'node:assert/strict'; direct relative import '../pi-nvim-bridge.ts'; finally { restore env; __setShellInfoForTest(undefined) }."

# MUST READ — the S1 CONTRACT (parallel; defines the types S2 populates against)
- file: plan/002_d23d7473c16c/P2M1T1S1/PRP.md
  why: "S1 widens BridgeDescriptor/HelloResult/PingResult with the 3 optional shell fields. S2's `satisfies BridgeDescriptor` literal typechecks ONLY because S1 landed. S2 does NOT edit protocol.ts."
  pattern: "Contract: after S1, BridgeDescriptor has `shell?: string; shellSource?: \"pi\" | \"$SHELL\" | \"default\"; shellPath?: string;`. The satisfies guard accepts the populated literal."

# MUST READ — local research notes (verified facts + the bridge-env breakage analysis)
- docfile: plan/002_d23d7473c16c/P2M1T1S2/research/notes.md
  why: "the resolveFdAvailable cluster quoted verbatim, the descriptor literal quoted verbatim, the JSON.stringify-omits-undefined key-count table (10 vs 9), the bridge-env.test.ts co-update plan, the ShellInfo/SHELL_MIRROR_ENV/resolveShell-export decisions, forward contracts to S3/S4."

# SUPPORTING — architecture research (confirms the pattern + population site)
- docfile: plan/002_d23d7473c16c/architecture/research-extension-side.md
  why: "§2e (resolver pattern), §2b (the single descriptor write site + the ctx.cwd GOTCHA), §2f (makeHelloHandler/makePingHandler = S3's sites, read-only here), §5 (test patterns incl. bridge-env.test.ts relevance)."
  section: "§2b, §2e, §2f, §5"

# SUPPORTING — the consumers that must NOT break (read-only confirmation)
- file: extension/pi-nvim-bridge.ts
  why: "makeHelloHandler (L623-649) returns HelloResult WITHOUT shell (S3 adds it); makePingHandler (L670-686) returns PingResult WITHOUT shell. Both must STILL compile after S2 (S1 made the fields optional, so omitting them is valid). Do NOT edit these handlers."
```

### Current Codebase tree (relevant slice)

```bash
extension/
├── protocol.ts                 # (S1, parallel) widens the 3 interfaces — READ-ONLY for S2
├── pi-nvim-bridge.ts           # MODIFY — +SHELL_MIRROR_ENV, +ShellInfo, +resolver cluster, +populate literal
├── connection.ts               # READ-ONLY (transport; no descriptor/result building)
├── tsconfig.json               # READ-ONLY (strict:true; noEmit; include covers tests — NO edit)
└── tests/
    ├── bridge-env.test.ts      # MODIFY (CO-UPDATE) — === 7 assertions break; inject shell seam, bump count
    ├── shell-resolver.test.ts  # NEW — resolveShell 3-branch + cache + seam unit tests
    ├── protocol.test.ts        # READ-ONLY regression (S1 owns; the type assertions)
    ├── hello-handler.test.ts   # READ-ONLY regression (HelloResult consumer — still omits shell)
    └── ping-bye-getcommands-handler.test.ts  # READ-ONLY regression (PingResult consumer)
```

### Desired Codebase tree with files to be added/modified

```bash
extension/pi-nvim-bridge.ts            # MODIFIED — +const, +interface, +4 resolver fns, +3 descriptor fields
extension/tests/shell-resolver.test.ts # NEW — resolver unit tests (node:test)
extension/tests/bridge-env.test.ts     # MODIFIED — co-update (shell seam + key count + field asserts)
# (NO protocol.ts edit — S1 owns it. NO handler edits — S3 owns them. NO connection.ts/tsconfig/lua.)
```

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL GOTCHA #1 — bridge-env.test.ts BREAKS; the co-update is MANDATORY, not optional.
// 3 of its 4 tests assert `Object.keys(desc).length === 7`. After S2 the descriptor
// carries shell/shellSource (+shellPath in the PI_NVIM_SHELL branch) → 9 or 10 keys.
// JSON.stringify OMITS undefined, so in the $SHELL/default branches shellPath is absent.
// FIX: in bridge-env.test.ts inject a FULL ShellInfo via __setShellInfoForTest
//   ({ shell: "/bin/zsh", shellSource: "pi", shellPath: "/bin/zsh" }) → deterministic
//   10 keys; bump `7 → 10`; assert desc.shell/shellSource/shellPath; reset cache in finally.

// CRITICAL GOTCHA #2 — JSON.stringify OMITS undefined (verified).
//   JSON.stringify({ a: 1, b: undefined }) === '{"a":1}'. So `shellPath: shellInfo.shellPath`
//   in the literal, when shellInfo.shellPath is undefined (the $SHELL/default branches),
//   is DROPPED from the serialized blob. Key counts: PI_NVIM_SHELL branch = 10;
//   $SHELL/default branches = 9. This is CORRECT/desired (absent-OK back-compat) — just
//   make tests stub deterministically and assert against the stubbed branch.

// GOTCHA #3 — process.env is SHARED across tests in one process (bridge-env.test.ts GOTCHA #6).
//   process.env.SHELL is set in the test env (/usr/bin/zsh here) and VARIES across machines.
//   So: shell-resolver.test.ts MUST save/restore PI_NVIM_SHELL + SHELL per test in a finally,
//   and __setShellInfoForTest(undefined) to reset the cache. Otherwise a prior test's env
//   or injected value leaks into the next → flaky/non-deterministic tests.

// GOTCHA #4 — the `satisfies BridgeDescriptor` guard typechecks ONLY because S1 widened the type.
//   If S1 has NOT landed yet (parallel), `tsc` will error on the new literal fields. That is
//   expected: S2 depends on S1. The PRP assumes S1 is the contract (treat it as landed).

// GOTCHA #5 — resolveShell is EXPORTED (deviation from resolveFdAvailable which is PRIVATE).
//   The task OUTPUT explicitly lists resolveShell() as exported, so the 3-branch chain can be
//   unit-tested directly (without cache/env coupling). This is the ONLY structural deviation
//   from the fd pattern; the cache+getter+seam shape is otherwise identical.

// GOTCHA #6 — ctx.cwd is read DIRECTLY in the descriptor (not the module `cwd` getter), because
//   the module `cwd` is set in session_start AFTER startBridge returns (the existing L575 comment).
//   Shell resolution does NOT read ctx at all (it reads process.env), so this GOTCHA does not
//   apply to S2 — but do NOT be tempted to thread `ctx` into resolveShell.

// GOTCHA #7 — TAB indentation (the file uses tabs everywhere; verified). Match tabs on every
//   new line. Mixing spaces diverges from the file and every sibling resolver.

// SCOPE — this task is the resolver + descriptor population + the descriptor-shape test fix.
//   Do NOT: edit protocol.ts (S1), edit makeHelloHandler/makePingHandler (S3), edit connection.ts,
//   add a new RPC method, edit tsconfig.json, edit any lua (S4). Do NOT add shell fields to the
//   hello/ping handler return values (S3). The descriptor literal is the ONLY startBridge edit.
```

## Implementation Blueprint

### Data models and structure

The "data model" is the `ShellInfo` interface (local to `pi-nvim-bridge.ts`).
Define it ONCE; reuse for the cache, the getter return, the resolver return, and
S3's future handler dep.

```ts
/**
 * Resolved shell info for the §17.10 advisory descriptor fields. `shellSource`
 * mirrors the `BridgeDescriptor.shellSource` union (PRD §17.10.1). `shellPath` is
 * present ONLY when the user set the {@link SHELL_MIRROR_ENV} mirror (the "pi"
 * branch); absent (undefined → omitted by JSON.stringify) in the "$SHELL"/"default"
 * branches. Exported so S3 can type its injected `getShell` dep.
 */
export interface ShellInfo {
	shell: string;
	shellSource: "pi" | "$SHELL" | "default";
	shellPath?: string;
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-nvim-bridge.ts — add SHELL_MIRROR_ENV constant (~L311)
  - ADD after DEFAULT_NVIM_APPNAME (in the env-name constants cluster):
      /** The opt-in env var THIS extension reads to mirror pi's `shellPath` setting
       *  (PRD §17.10.2). The extension CANNOT read settingsManager/getShellConfig
       *  (not on ExtensionContext), so the user sets this once to advertise the
       *  shell pi runs `!`/`!!` in. Absent ⇒ fall back to $SHELL (/bin/bash). */
      export const SHELL_MIRROR_ENV = "PI_NVIM_SHELL";
  - NAMING: SHELL_MIRROR_ENV (parallels NVIM_APPNAME_OPTIN_ENV).
  - PLACEMENT: constants cluster, after DEFAULT_NVIM_APPNAME.

Task 2: MODIFY extension/pi-nvim-bridge.ts — add the ShellInfo interface + resolver cluster
  - INSERT immediately AFTER the resolveFdAvailable cluster (which ends ~L380, right
        before `function isExecutableFile` at L382). This keeps the two resolver
        clusters side-by-side.
  - CONTENT (verbatim-OK reference, see "Reference implementation" below):
      export interface ShellInfo { shell; shellSource: "pi"|"$SHELL"|"default"; shellPath? }
      let shellCache: ShellInfo | undefined;
      export function getShellInfo(): ShellInfo { ... cached lazy resolve ... }
      export function __setShellInfoForTest(v: ShellInfo | undefined): void { shellCache = v; }
      export function resolveShell(): ShellInfo { ... 3-branch chain ... }
  - PATTERN: mirror resolveFdAvailable/getFdAvailable/__setFdAvailableForTest EXACTLY
        (cache+getter+seam). DEVIATION (GOTCHA #5): resolveShell is EXPORTED (fd's is private).
  - DOCS MODE A: JSDoc on resolveShell citing PRD §17.10.2 honesty note (advisory; falls
        back to $SHELL; settingsManager/getShellConfig NOT on ExtensionContext).
  - NAMING: shellCache, getShellInfo, __setShellInfoForTest, resolveShell, ShellInfo.
  - DO NOT: read ctx, read pi internals, throw, or add a new RPC method.

Task 3: MODIFY extension/pi-nvim-bridge.ts — populate the startBridge descriptor literal (L568-578)
  - FIND: `process.env[BRIDGE_ENV] = JSON.stringify({ ... } satisfies BridgeDescriptor);`
  - ADD `const shellInfo = getShellInfo();` on the line IMMEDIATELY BEFORE the
        `process.env[BRIDGE_ENV] = JSON.stringify({` line (compute once — GOTCHA: calling
        getShellInfo() 3× inline is wasteful even though cached).
  - ADD inside the literal, AFTER `serverVersion: BRIDGE_VERSION,`:
        shell: shellInfo.shell,        // §17.10 — advisory; plugin falls back to $SHELL if absent
        shellSource: shellInfo.shellSource,
        shellPath: shellInfo.shellPath, // undefined in $SHELL/default branches → JSON.stringify omits
  - The `satisfies BridgeDescriptor` guard now typechecks (S1 widened the type — GOTCHA #4).
  - DO NOT: reorder existing fields, change any existing value, or remove the satisfies guard.

Task 4: CREATE extension/tests/shell-resolver.test.ts — resolver unit tests (node:test)
  - CONTENT (see "Reference implementation"): node:test + node:assert/strict; import
        resolveShell, getShellInfo, __setShellInfoForTest, SHELL_MIRROR_ENV from
        "../pi-nvim-bridge.ts". Cover the full Success Criteria:
        (1) PI_NVIM_SHELL branch → { shell, shellSource:"pi", shellPath } (all 3);
        (2) SHELL-only branch → { shell, shellSource:"$SHELL" } (NO shellPath key);
        (3) neither → { shell:"/bin/bash", shellSource:"default" } (NO shellPath);
        (4) precedence: PI_NVIM_SHELL wins when BOTH set;
        (5) getShellInfo() caches (same object ref on 2nd call; resolveShell not re-run);
        (6) __setShellInfoForTest(v) overrides; __setShellInfoForTest(undefined) resets.
  - PATTERN: save/restore process.env.PI_NVIM_SHELL + process.env.SHELL per test in a
        finally; __setShellInfoForTest(undefined) in finally (GOTCHA #3). resolveShell is
        pure (no cache) so test it directly; getShellInfo needs the cache reset.
  - PLACEMENT: extension/tests/shell-resolver.test.ts.

Task 5: MODIFY extension/tests/bridge-env.test.ts — CO-UPDATE (mandatory; GOTCHA #1)
  - IMPORTS: add `__setShellInfoForTest` (and `type ShellInfo` for the injection literal)
        to the existing `import { … } from "../pi-nvim-bridge.ts";`.
  - IN EACH TEST'S SETUP (after `__setFdAvailableForTest(...)`): add
        `__setShellInfoForTest({ shell: "/bin/zsh", shellSource: "pi", shellPath: "/bin/zsh" });`
        (full 3-field injection → deterministic 10 keys; decouples from the real $SHELL).
  - IN EACH TEST'S FINALLY (before/after `__setFdAvailableForTest(undefined)`): add
        `__setShellInfoForTest(undefined);` (reset cache — GOTCHA #3).
  - TEST 1 (exact-shape): bump `assert.equal(Object.keys(desc).length, 7, …)` → `10`; ADD
        `assert.equal(desc.shell, "/bin/zsh"); assert.equal(desc.shellSource, "pi");
        assert.equal(desc.shellPath, "/bin/zsh");`.
  - TEST 3 (idempotent re-write): bump the trailing `assert.equal(Object.keys(desc).length, 7)`
        → `10`.
  - TESTS 2 & 4: they parse the descriptor but do NOT assert the count — still add the seam
        inject + reset (so the injected value is deterministic and doesn't leak).
  - DO NOT: change mockDeps(), makeFakeServer, the factory-wiring test's structure, or any
        fd-related assertion. ONLY add the shell seam + bump counts + add shell assertions.
```

### Reference implementation

```typescript
// === extension/pi-nvim-bridge.ts — the resolver cluster (insert AFTER resolveFdAvailable, ~L380) ===

/**
 * Resolved shell info for the §17.10 advisory descriptor fields. `shell` is the
 * binary pi will execute `!`/`!!` commands in; `shellSource` says how it was
 * derived; `shellPath` is present only in the "pi" branch. Exported so S3 can type
 * its injected `getShell` dep on {@link makeHelloHandler}/{@link makePingHandler}.
 */
export interface ShellInfo {
	shell: string;
	shellSource: "pi" | "$SHELL" | "default";
	shellPath?: string;
}

/** Cached {@link ShellInfo} (resolved ONCE per process via {@link resolveShell}).
 *  Read via {@link getShellInfo}; used by {@link startBridge} for the §17.10
 *  `PI_NVIM_BRIDGE` descriptor fields (and, later, by S3's hello/ping handlers). */
let shellCache: ShellInfo | undefined;

/**
 * @returns the resolved {@link ShellInfo} (cached on first call; one-time per
 *  process). Mirrors {@link getFdAvailable}'s lazy-cache shape. Test seam:
 *  {@link __setShellInfoForTest}.
 */
export function getShellInfo(): ShellInfo {
	if (shellCache === undefined) shellCache = resolveShell();
	return shellCache;
}

/** Test seam: override the cached shell info (pass `undefined` to reset so the
 *  next {@link getShellInfo} call re-resolves). Parallels {@link __setFdAvailableForTest}. */
export function __setShellInfoForTest(v: ShellInfo | undefined): void {
	shellCache = v;
}

/**
 * Resolve the shell pi will execute `!`/`!!` commands in (PRD §17.10.2). ADVISORY:
 * the result populates the `shell`/`shellSource`/`shellPath` descriptor fields so
 * the plugin's `prefer:"pi"` completion can match pi's execution shell; the plugin
 * falls back to `$SHELL` if these fields are absent (PRD §17.4 fallback chain).
 *
 * HONESTY NOTE (PRD §17.10.2): `settingsManager`/`getShellConfig()` are NOT on
 * `ExtensionContext`, so this extension CANNOT read pi's real `shellPath` setting
 * through the public API. It replicates `getShellConfig`'s ~10-line resolution via
 * the same inputs pi uses:
 *  (a) {@link SHELL_MIRROR_ENV} (`PI_NVIM_SHELL`) — a bridge-local mirror of the
 *      `shellPath` setting the user sets once. If set ⇒ `"pi"` (shellPath = that value).
 *  (b) Else `process.env.SHELL` ⇒ `"$SHELL"` (no shellPath).
 *  (c) Else `/bin/bash` (pi's getShellConfig default on Unix) ⇒ `"default"` (no shellPath).
 * If this mismatch bites real users, PRD §17.17 proposes a tiny upstream
 * `ctx.getShellConfig()` (matching §15's "propose upstream only if it bites" posture).
 *
 * Exported (unlike {@link resolveFdAvailable}) so the 3-branch chain is directly
 * unit-testable. Pure: reads only process.env, no module state, no side effects.
 */
export function resolveShell(): ShellInfo {
	const explicit = process.env[SHELL_MIRROR_ENV];
	if (explicit) return { shell: explicit, shellSource: "pi", shellPath: explicit };
	const sh = process.env.SHELL;
	if (sh) return { shell: sh, shellSource: "$SHELL" };
	return { shell: "/bin/bash", shellSource: "default" };
}
```

```typescript
// === extension/pi-nvim-bridge.ts — the startBridge descriptor literal (L568-578) ===
// BEFORE (current):
	process.env[BRIDGE_ENV] = JSON.stringify({
		transport: "unix",
		path: socketPath,
		token,
		pid: process.pid,
		cwd: ctx.cwd,
		fdAvailable: getFdAvailable(),
		serverVersion: BRIDGE_VERSION,
	} satisfies BridgeDescriptor);

// AFTER (S2):
	const shellInfo = getShellInfo(); // §17.10 — advisory shell fields (cached; resolveShell runs ≤1×/process)
	process.env[BRIDGE_ENV] = JSON.stringify({
		transport: "unix",
		path: socketPath,
		token,
		pid: process.pid,
		cwd: ctx.cwd,
		fdAvailable: getFdAvailable(),
		serverVersion: BRIDGE_VERSION,
		shell: shellInfo.shell, // §17.10 — advisory; plugin falls back to $SHELL if absent
		shellSource: shellInfo.shellSource,
		shellPath: shellInfo.shellPath, // undefined in $SHELL/default branches → JSON.stringify omits
	} satisfies BridgeDescriptor);
```

```typescript
// === extension/tests/shell-resolver.test.ts — NEW (node:test) ===
import { test } from "node:test";
import assert from "node:assert/strict";
import {
	resolveShell,
	getShellInfo,
	__setShellInfoForTest,
	SHELL_MIRROR_ENV,
} from "../pi-nvim-bridge.ts";

// Save/restore PI_NVIM_SHELL + SHELL + the cache around every test (process.env is
// SHARED across tests in one process; SHELL varies across machines — bridge-env.test.ts GOTCHA #6).
function withEnv(
	env: Partial<{ piNvimShell: string | undefined; shell: string | undefined }>,
	fn: () => void,
) {
	const savedPi = process.env[SHELL_MIRROR_ENV];
	const savedShell = process.env.SHELL;
	__setShellInfoForTest(undefined); // force re-resolution
	if (env.piNvimShell === undefined) delete process.env[SHELL_MIRROR_ENV];
	else process.env[SHELL_MIRROR_ENV] = env.piNvimShell;
	if (env.shell === undefined) delete process.env.SHELL;
	else process.env.SHELL = env.shell;
	try {
		fn();
	} finally {
		if (savedPi === undefined) delete process.env[SHELL_MIRROR_ENV];
		else process.env[SHELL_MIRROR_ENV] = savedPi;
		if (savedShell === undefined) delete process.env.SHELL;
		else process.env.SHELL = savedShell;
		__setShellInfoForTest(undefined);
	}
}

test("resolveShell: PI_NVIM_SHELL set → { shell, shellSource:'pi', shellPath }", () => {
	withEnv({ piNvimShell: "/bin/zsh", shell: "/bin/bash" }, () => {
		const r = resolveShell();
		assert.equal(r.shell, "/bin/zsh");
		assert.equal(r.shellSource, "pi");
		assert.equal(r.shellPath, "/bin/zsh");
	});
});

test("resolveShell: PI_NVIM_SHELL wins over SHELL when both set (precedence)", () => {
	withEnv({ piNvimShell: "/bin/fish", shell: "/bin/zsh" }, () => {
		assert.equal(resolveShell().shellSource, "pi");
		assert.equal(resolveShell().shell, "/bin/fish");
	});
});

test("resolveShell: only SHELL set → { shell, shellSource:'$SHELL' }, NO shellPath", () => {
	withEnv({ piNvimShell: undefined, shell: "/bin/zsh" }, () => {
		const r = resolveShell();
		assert.equal(r.shell, "/bin/zsh");
		assert.equal(r.shellSource, "$SHELL");
		assert.equal(r.shellPath, undefined, "shellPath absent in the $SHELL branch");
	});
});

test("resolveShell: neither set → { '/bin/bash', 'default' }, NO shellPath", () => {
	withEnv({ piNvimShell: undefined, shell: undefined }, () => {
		const r = resolveShell();
		assert.equal(r.shell, "/bin/bash");
		assert.equal(r.shellSource, "default");
		assert.equal(r.shellPath, undefined, "shellPath absent in the default branch");
	});
});

test("getShellInfo caches: 2nd call returns the SAME object (resolveShell runs once)", () => {
	withEnv({ piNvimShell: "/bin/zsh" }, () => {
		const a = getShellInfo();
		const b = getShellInfo();
		assert.equal(a, b, "same reference — cached, no re-resolution");
		assert.equal(a.shellSource, "pi");
	});
});

test("__setShellInfoForTest overrides the cache; undefined resets", () => {
	withEnv({ piNvimShell: "/bin/zsh" }, () => {
		const injected: ShellInfo = { shell: "/custom/sh", shellSource: "pi", shellPath: "/custom/sh" };
		__setShellInfoForTest(injected);
		assert.equal(getShellInfo(), injected, "seam overrides resolution");
		__setShellInfoForTest(undefined); // reset → next call re-resolves from env
		assert.equal(getShellInfo().shell, "/bin/zsh", "reset re-resolves from PI_NVIM_SHELL");
	});
});
```
> **Note** the last test needs `type ShellInfo` imported too: add it to the import list
> (`import { resolveShell, getShellInfo, __setShellInfoForTest, SHELL_MIRROR_ENV, type ShellInfo } from "../pi-nvim-bridge.ts";`).

```typescript
// === extension/tests/bridge-env.test.ts — the CO-UPDATE (diffs only) ===
// (a) imports: add __setShellInfoForTest + the ShellInfo type
import {
	startBridge, stopBridge, getSocketPath, getToken, BRIDGE_ENV, __deps,
	__setFdAvailableForTest,
	__setShellInfoForTest,          // NEW (S2)
	type ShellInfo,                 // NEW (S2) — for the injection literal
} from "../pi-nvim-bridge.ts";

// (b) the deterministic injected value (full 3 fields → 10 keys). Add near the top.
const SHELL_INFO_STUB: ShellInfo = { shell: "/bin/zsh", shellSource: "pi", shellPath: "/bin/zsh" };

// (c) in EVERY test: setup adds the inject; finally adds the reset. Example (TEST 1):
test("startBridge writes a valid single-line BridgeDescriptor to process.env.PI_NVIM_BRIDGE", () => {
	const mock = mockDeps();
	__setFdAvailableForTest(true);
	__setShellInfoForTest(SHELL_INFO_STUB);   // NEW (S2) — deterministic shell
	try {
		// ... existing startBridge + parse ...
		assert.equal(desc.shell, "/bin/zsh");          // NEW (S2)
		assert.equal(desc.shellSource, "pi");          // NEW (S2)
		assert.equal(desc.shellPath, "/bin/zsh");      // NEW (S2)
		assert.equal(Object.keys(desc).length, 10, "7 base + 3 shell");  // CHANGED 7 → 10
	} finally {
		__setFdAvailableForTest(undefined);
		__setShellInfoForTest(undefined);   // NEW (S2) — reset cache
		mock.restore();
		stopBridge();
	}
});
// (d) TEST 3: bump the trailing `Object.keys(desc).length` 7 → 10.
// (e) TESTS 2 & 4: add the same __setShellInfoForTest(SHELL_INFO_STUB) setup + undefined reset
//     in finally (they parse the descriptor; the stub makes the shell value deterministic and
//     prevents leakage). They don't assert the count, so no count change needed there.
```

### Integration Points

```yaml
MODULE STATE (extension/pi-nvim-bridge.ts — additive):
  - +export const SHELL_MIRROR_ENV = "PI_NVIM_SHELL"   (constants cluster)
  - +export interface ShellInfo { shell; shellSource; shellPath? }
  - +let shellCache: ShellInfo | undefined
  - +export function getShellInfo(): ShellInfo          (cached lazy resolve)
  - +export function __setShellInfoForTest(v): void     (test seam)
  - +export function resolveShell(): ShellInfo          (3-branch; pure; exported)

DESCRIPTOR (the ONE runtime/wire change):
  - the PI_NVIM_BRIDGE blob now carries shell + shellSource always; shellPath only in
    the PI_NVIM_SHELL branch (JSON.stringify omits undefined). 7 → 9/10 keys.

FORWARD CONTRACTS (do NOT implement here — just don't break them):
  - S3 (P2.M1.T1.S3): adds `getShell: () => ShellInfo` to makeHelloHandler/makePingHandler
    deps; returns shell/shellSource/shellPath in HelloResult/PingResult. My exported
    ShellInfo + getShellInfo() are exactly what S3 wires. Do NOT touch the handlers.
  - S4 (lua): extracts shell/shellSource from descriptor + hello. The fields I populate
    here ARE that wire contract.

NO DATABASE / NO CONFIG / NO ROUTES / NO new RPC method / NO protocol.ts edit / NO lua.
```

## Validation Loop

> Run all commands from the repo root (`/home/dustin/projects/pi-nvim-bridge`).
> `tsc --noEmit` is the type gate; the test suites are the behavior gate. Baseline
> (verified 2025-07-31, BEFORE S1/S2): tsc exit 0, protocol 2/2, bridge-env 4/4.

### Level 1: Type-check (THE gate — proves the `satisfies` guard accepts shell fields)

```bash
# Requires S1 to have widened BridgeDescriptor (GOTCHA #4). Must exit 0.
npx tsc --noEmit -p extension/tsconfig.json
echo "exit=$?   # 0 = pass"
# Expected: exit 0. If it errors on the descriptor literal, S1 hasn't landed — S2
# depends on S1. If it errors elsewhere, READ it: likely a typo in the ShellInfo
# union (e.g. shellSource: "shell") or a missing export.
```

### Level 2: Unit Tests (the new resolver suite + the co-updated descriptor suite)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# 2a. The NEW resolver suite (THE deliverable test):
node --import "$JITI_REG" extension/tests/shell-resolver.test.ts
echo "exit=$?   # 0 = pass (7 tests; ℹ fail 0)"
# Expected: ℹ fail 0. (jiti prints a benign "module.register() is deprecated" DEP0205 on stderr — IGNORE.)

# 2b. The CO-UPDATED descriptor suite (proves startBridge now populates shell fields):
node --import "$JITI_REG" extension/tests/bridge-env.test.ts
echo "exit=$?   # 0 = pass (4 tests; ℹ fail 0)"
# Expected: ℹ fail 0. If TEST 1/3 fail on Object.keys length, you forgot the 7→10 bump (GOTCHA #1).
```

### Level 3: Regression — prove no handler/protocol/runtime-behavior break

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
# Each builds HelloResult/PingResult/BridgeDescriptor WITHOUT touching shell resolution
# (the handlers still OMIT shell — S3 adds it). They MUST stay green.
node --import "$JITI_REG" extension/tests/protocol.test.ts                      # S1's type assertions
node --import "$JITI_REG" extension/tests/hello-handler.test.ts                 # HelloResult consumer
node --import "$JITI_REG" extension/tests/ping-bye-getcommands-handler.test.ts  # PingResult consumer
# Expected: each ℹ fail 0. If any fails, you likely edited a handler or protocol.ts — re-read scope.
```

### Level 4: End-to-end descriptor verification (the actual wire blob)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
# 4a. Drive startBridge directly and inspect the REAL env blob's shell fields (no seam —
#     exercises the genuine resolution against the live $SHELL). Prints the resolved shell.
cat > /tmp/shell_e2e.mjs <<'EOF'
import { startBridge, stopBridge, BRIDGE_ENV, __deps, __setFdAvailableForTest, __setShellInfoForTest } from "/home/dustin/projects/pi-nvim-bridge/extension/pi-nvim-bridge.ts";
__deps.createServer = (() => ({ listen(){return this;}, close(){}, on(){} })) ;
__deps.chmodSync = () => {};
__setFdAvailableForTest(true);
__setShellInfoForTest(undefined); // use REAL resolution (reads live $SHELL)
startBridge({ cwd: "/tmp" });
const desc = JSON.parse(process.env[BRIDGE_ENV]);
console.log("shell=", JSON.stringify(desc.shell), "shellSource=", JSON.stringify(desc.shellSource), "shellPath=", JSON.stringify(desc.shellPath), "keyCount=", Object.keys(desc).length);
stopBridge();
EOF
node --import "$JITI_REG" /tmp/shell_e2e.mjs
rm -f /tmp/shell_e2e.mjs
# Expected: shell="<live $SHELL or /bin/bash>" shellSource="$SHELL" (or "default") shellPath=undefined
#           keyCount=9 (because PI_NVIM_SHELL is unset here → $SHELL/default branch; shellPath omitted).
# (This proves JSON.stringify omits the undefined shellPath on the REAL wire — GOTCHA #2.)

# 4b. Confirm the 3 fields are present in the descriptor literal source (grep the edit site):
grep -n "shell: shellInfo\|shellSource: shellInfo\|shellPath: shellInfo\|const shellInfo = getShellInfo" extension/pi-nvim-bridge.ts
# Expected: 4 matches (the const + the 3 fields).

# 4c. Confirm the resolver + seam are exported:
grep -n "export function resolveShell\|export function getShellInfo\|export function __setShellInfoForTest\|export interface ShellInfo\|export const SHELL_MIRROR_ENV" extension/pi-nvim-bridge.ts
# Expected: 5 matches.
```

## Final Validation Checklist

### Technical Validation

- [ ] `npx tsc --noEmit -p extension/tsconfig.json` exits 0 (zero output).
- [ ] `shell-resolver.test.ts` passes (7 tests; ℹ fail 0).
- [ ] `bridge-env.test.ts` passes (4 tests; ℹ fail 0; key counts bumped 7→10).
- [ ] Regression green: `protocol`, `hello-handler`, `ping-bye-getcommands-handler` ℹ fail 0.
- [ ] Level 4a: the real env blob carries `shell` + `shellSource` (and `shellPath` only in the
      `PI_NVIM_SHELL` branch).
- [ ] No file other than `extension/pi-nvim-bridge.ts` + `extension/tests/shell-resolver.test.ts`
      (new) + `extension/tests/bridge-env.test.ts` is modified.

### Feature Validation

- [ ] `resolveShell()` returns the exact 3-branch matrix; `shellPath` present ONLY in the
      `PI_NVIM_SHELL` branch.
- [ ] `PI_NVIM_SHELL` precedence over `SHELL` (both-set test).
- [ ] `getShellInfo()` caches (same ref on 2nd call); `__setShellInfoForTest` overrides + resets.
- [ ] The `PI_NVIM_BRIDGE` blob carries `shell`/`shellSource` always; `shellPath` only when
      `PI_NVIM_SHELL` is set (JSON.stringify omits undefined).
- [ ] `SHELL_MIRROR_ENV`, `ShellInfo`, `resolveShell`, `getShellInfo`, `__setShellInfoForTest`
      are all exported.

### Code Quality Validation

- [ ] New code mirrors the `resolveFdAvailable` cluster shape (cache+getter+seam); the ONLY
      deviation is `resolveShell` is exported (task-mandated — GOTCHA #5).
- [ ] TAB indentation throughout (match the file).
- [ ] JSDoc style matches the existing resolver (block `/** … */` + `{@link}` refs).
- [ ] `bridge-env.test.ts` changes are ADDITIVE to the existing structure (mockDeps/fakeServer
      untouched); only the shell seam + counts + field asserts are added.
- [ ] No edit to `protocol.ts`, the handlers, `connection.ts`, `tsconfig.json`, or lua.

### Documentation & Deployment

- [ ] [Mode A] JSDoc on `resolveShell()` cites PRD §17.10.2 honesty note (advisory; falls back
      to `$SHELL`; cannot read pi's real `shellPath` setting).
- [ ] `SHELL_MIRROR_ENV` JSDoc explains the mirror var + the public-API gap.
- [ ] No README / `doc/pi-bridge.txt` / `extension/README.md` change (those are later Mode-B
      tasks: P2.M4.T7.S1/S3 — `PI_NVIM_SHELL` documentation lands there).

---

## Anti-Patterns to Avoid

- ❌ Don't skip the `bridge-env.test.ts` co-update — its `Object.keys(desc).length === 7`
  assertions WILL fail once shell fields are populated (verified; GOTCHA #1). The co-update is
  mandatory, not optional.
- ❌ Don't call `getShellInfo()` 3× inline in the descriptor literal — compute `const shellInfo`
  once (it's a 3-field object, not a single boolean like `getFdAvailable()`).
- ❌ Don't make `shellPath` always-present by forcing `shellPath: shellInfo.shellPath ?? ""` —
  the PRD contract is "shellPath present only in the pi branch"; `undefined` → JSON.stringify
  omits it is the CORRECT behavior (absent-OK back-compat). Don't fight it.
- ❌ Don't read `ctx` in `resolveShell()` — the resolver reads ONLY `process.env` (PRD §17.10.2).
  The `settingsManager`/`getShellConfig` public-API gap is the whole reason this is env-based.
- ❌ Don't edit `protocol.ts` (S1 owns it), the handlers (S3), `connection.ts`, `tsconfig.json`,
  or lua (S4). The descriptor literal is the ONLY `startBridge` edit.
- ❌ Don't keep `resolveShell` private "to match fd exactly" — the task OUTPUT mandates it
  exported (GOTCHA #5); exporting enables direct 3-branch unit testing.
- ❌ Don't forget the `finally { __setShellInfoForTest(undefined) }` in tests — `process.env` +
  the module cache are SHARED across tests in one process; a leak makes tests order-dependent
  and machine-specific (GOTCHA #3).
- ❌ Don't use spaces where the file uses tabs (pi-nvim-bridge.ts is tab-indented throughout).
- ❌ Don't add shell fields to `makeHelloHandler`/`makePingHandler` return values — that is S3.
  This task only populates the descriptor + ships the resolver the handlers will later call.
- ❌ Don't skip the Level 3 regression suites — they prove the optional fields (S1) + the new
  resolver didn't break a consumer that builds these types without shell.