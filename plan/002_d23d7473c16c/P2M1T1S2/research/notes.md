# Research: resolveShell() + populate descriptor fields (P2.M1.T1.S2)

> Scope: task **P2.M1.T1.S2** — the RUNTIME side of the §17.10 shell-descriptor
> fields (S1 was type-only). Implements `resolveShell()` + cached `getShellInfo()` +
> `__setShellInfoForTest()` seam, and populates `shell`/`shellSource`/`shellPath`
> into the `startBridge` descriptor literal. TypeScript extension side.
>
> **Provenance.** All facts verified against the working tree at
> `/home/dustin/projects/pi-nvim-bridge` (read + grep + live baseline runs of
> `tsc --noEmit` and the protocol/bridge-env tests on 2025-07-31). Line numbers
> are current.

---

## Summary

- The **pattern to mirror** is the `fd`-availability resolver cluster at
  `pi-nvim-bridge.ts:336-380`: module-level cache → exported cached getter →
  exported `__set*ForTest` seam → private resolver. Replicate it for shell.
- The **single population site** is the `satisfies BridgeDescriptor` literal inside
  `startBridge` at `pi-nvim-bridge.ts:568-578`. Add the 3 fields there.
- **CRITICAL integration breakage:** `extension/tests/bridge-env.test.ts` asserts
  `Object.keys(desc).length === 7` in 3 of its 4 tests. After S2 the descriptor
  carries shell fields, so those assertions **will break** and MUST be co-updated
  (inject a deterministic `ShellInfo` via the seam, bump the count, assert fields).
- **`JSON.stringify` OMITS `undefined`** (verified) → when `shellPath` is absent
  (resolution cases b/c) it is dropped from the serialized blob, so the key count
  is 10 in case (a) and 9 in cases (b)/(c). Tests must stub deterministically.
- **`process.env.SHELL` is set in the test env** (`/usr/bin/zsh` here) and varies
  across machines → tests MUST stub `PI_NVIM_SHELL`/`SHELL` or (better for
  `bridge-env.test.ts`) inject via `__setShellInfoForTest`.

---

## 1. The resolver pattern to mirror — `resolveFdAvailable` (pi-nvim-bridge.ts:336-380)

Exact current code (verified):

```ts
// L336-339 — module-level cache + JSDoc
/** Cached `fd`/`fdfind` availability (resolved ONCE per process via
 *  {@link resolveFdAvailable}). Read via {@link getFdAvailable}; used by
 *  {@link makeHelloHandler} for `HelloResult.fdAvailable` and (later) by S16. */
let fdAvailableCache: boolean | undefined;

// L344-348 — JSDoc + exported cached getter
export function getFdAvailable(): boolean {
	if (fdAvailableCache === undefined) fdAvailableCache = resolveFdAvailable();
	return fdAvailableCache;
}

// L351-353 — exported test seam (pass undefined to reset)
export function __setFdAvailableForTest(v: boolean | undefined): void {
	fdAvailableCache = v;
}

// L361-380 — PRIVATE resolver (the actual lookup; NOT exported)
function resolveFdAvailable(): boolean {
	// ... pi agent bin dir, then PATH scan ...
	return false;
}
```

**Pattern shape (4 pieces):** (1) `let <cache>: T | undefined` + JSDoc, (2) exported
cached getter that lazily resolves on first call, (3) exported `__set<Name>ForTest`
seam, (4) the resolver itself.

**One DEVIATION the task mandates:** `resolveFdAvailable` is **private**, but the
task's OUTPUT explicitly lists `resolveShell()` as **exported** (so the 3-branch
resolution chain can be unit-tested directly without cache/env coupling). Export it.
This is the ONLY structural deviation from the fd pattern; everything else mirrors.

## 2. The ShellInfo type

Define + export an interface (local to `pi-nvim-bridge.ts`, NOT in `protocol.ts`
— that file is S1's; `ShellInfo` is an internal runtime type). The `shellSource`
union duplicates protocol.ts's union; the `satisfies BridgeDescriptor` guard
catches any drift.

```ts
export interface ShellInfo {
	shell: string;
	shellSource: "pi" | "$SHELL" | "default";
	shellPath?: string;
}
```

Used for: `resolveShell`'s return type, the cache type, `getShellInfo`'s return
type, AND S3's future `getShell: () => ShellInfo` handler dep. Exporting it now
unblocks S3 with no extra edit.

## 3. The SHELL_MIRROR_ENV constant

The codebase exports env-var-name constants (`BRIDGE_ENV` L286, `NVIM_APPNAME_ENV`
L298, `NVIM_APPNAME_OPTIN_ENV` L308) so tests reference names, not magic strings.
`PI_NVIM_SHELL` is a documented user-facing mirror var (PRD §17.10.2) → follow the
precedent:

```ts
export const SHELL_MIRROR_ENV = "PI_NVIM_SHELL";
```

Place it in the constants cluster (after `NVIM_APPNAME_OPTIN_ENV` / `DEFAULT_NVIM_APPNAME`,
~L311-316). (`resolveFdAvailable` reads `process.env.PI_CODING_AGENT_DIR`/`PATH`
literally with no constant — but those are NOT user-facing; `PI_NVIM_SHELL` IS, so
the constant is warranted and consistent with `NVIM_APPNAME_OPTIN_ENV`.)

## 4. The population site — startBridge descriptor literal (pi-nvim-bridge.ts:568-578)

Exact current code (verified):

```ts
process.env[BRIDGE_ENV] = JSON.stringify({
	transport: "unix",
	path: socketPath, // module-level let — guaranteed set above
	token, // module-level let — guaranteed set above
	pid: process.pid,
	cwd: ctx.cwd, // read DIRECTLY (module `cwd` is set in session_start AFTER startBridge)
	fdAvailable: getFdAvailable(), // REAL resolver — consistent with hello/ping (GOTCHA #2)
	serverVersion: BRIDGE_VERSION, // "0.1.0" — NOT "0.0.1" (GOTCHA #1)
} satisfies BridgeDescriptor); // compile-time guard against the `version` typo
```

**Target (minimal diff):** call `getShellInfo()` once just before the literal, then
add the 3 fields after `serverVersion`:

```ts
const shellInfo = getShellInfo();
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
	shellPath: shellInfo.shellPath, // undefined in cases (b)/(c) → JSON.stringify OMITS it (§5)
} satisfies BridgeDescriptor);
```

**Why compute `shellInfo` once (not 3 inline `getShellInfo().x` calls):** `getShellInfo()`
returns a 3-field object; calling it 3× is wasteful/ugly even though cached. `getFdAvailable()`
is called inline only because it returns a single boolean. One `const` read is cleaner.
(Caching still means `resolveShell` runs at most once per process.)

## 5. CRITICAL — JSON.stringify omits `undefined` → key count varies (verified)

```js
JSON.stringify({ a: 1, b: undefined })  //  '{"a":1}'  — b OMITTED
Object.keys(JSON.parse('{"a":1}')).length  //  1
```

Applied to the descriptor after S2:

| Resolution case | `shell` | `shellSource` | `shellPath` | serialized key count |
| --- | --- | --- | --- | --- |
| (a) `PI_NVIM_SHELL` set | that | `"pi"` | that | **10** (7 + 3) |
| (b) `SHELL` set | `$SHELL` | `"$SHELL"` | `undefined` → omitted | **9** (7 + 2) |
| (c) neither | `"/bin/bash"` | `"default"` | `undefined` → omitted | **9** (7 + 2) |

**This is why `bridge-env.test.ts`'s `Object.keys(desc).length === 7` assertions
break** (3 of its 4 tests). They MUST be co-updated in S2 (§6).

## 6. bridge-env.test.ts — the necessary co-update (4 tests, verified current shape)

Current assertions that break (after `const desc = JSON.parse(raw!)`):
- TEST 1: `assert.equal(Object.keys(desc).length, 7, "exactly 7 keys — no stray version")`
- TEST 3: `assert.equal(Object.keys(desc).length, 7)`
- (TEST 2 / TEST 4 parse the descriptor but don't assert the count — still need the
  shell seam reset so the injected value is deterministic.)

Current imports already include `__setFdAvailableForTest`; add `__setShellInfoForTest`
(+ the `ShellInfo` type for injection literals).

**Fix approach (mirrors exactly how `__setFdAvailableForTest(true)` is used):**
- In each test's setup: `__setShellInfoForTest({ shell: "/bin/zsh", shellSource: "pi", shellPath: "/bin/zsh" })`
  (full 3 fields → deterministic 10 keys, independent of the real `$SHELL`).
- In each test's `finally`: `__setShellInfoForTest(undefined)` (reset cache — GOTCHA #6).
- Bump the count assertions `7 → 10` and add `desc.shell` / `desc.shellSource` /
  `desc.shellPath` value assertions.

Injecting via the seam (not env vars) is correct here because bridge-env.test.ts
validates the **descriptor shape** (that startBridge populates it), NOT the
resolution chain — that's `shell-resolver.test.ts`'s job.

## 7. New test file — shell-resolver.test.ts

Tests `resolveShell` (the 3 branches, exported), `getShellInfo` (caching), and the
`__setShellInfoForTest` seam. **process.env is SHARED across tests in one process**
(bridge-env.test.ts GOTCHA #6) → save/restore `PI_NVIM_SHELL` + `SHELL` per test
in a `finally`, and `__setShellInfoForTest(undefined)` to reset the cache.

Branch matrix (matches PRD §17.10.2 exactly):
- `PI_NVIM_SHELL=/bin/zsh` set, `SHELL` anything → `{ shell:"/bin/zsh", shellSource:"pi", shellPath:"/bin/zsh" }`
- `PI_NVIM_SHELL` unset, `SHELL=/bin/fish` → `{ shell:"/bin/fish", shellSource:"$SHELL" }` (no shellPath)
- both unset → `{ shell:"/bin/bash", shellSource:"default" }` (no shellPath)
- `PI_NVIM_SHELL` WINS over `SHELL` when both set (precedence).
- caching: `resolveShell` is NOT directly observable as call-count, but `getShellInfo()`
  twice returns the SAME object reference (proves cache hit / single resolution).
- seam: `__setShellInfoForTest(X)` makes `getShellInfo()` return X without resolving;
  `__setShellInfoForTest(undefined)` resets so the next call re-resolves.

## 8. Placement of the new resolver block

Insert the `ShellInfo`/`shellCache`/`getShellInfo`/`__setShellInfoForTest`/`resolveShell`
cluster **immediately after the `resolveFdAvailable` cluster** (which ends ~L380,
right before `isExecutableFile` at L382). This keeps the two resolver clusters
side-by-side (they share the cache+getter+seam shape), which is the natural reading
order. `SHELL_MIRROR_ENV` goes in the constants cluster (~L311-316) with the other
env-name constants.

## 9. Forward contracts (do NOT implement — just don't break)

- **S3** (`P2.M1.T1.S3`): adds a `getShell: () => ShellInfo` dep to
  `makeHelloHandler`/`makePingHandler`; returns `shell`/`shellSource`/`shellPath`
  in `HelloResult`/`PingResult`. My exported `ShellInfo` + `getShellInfo()` are
  exactly what S3 wires in. Do NOT touch the handlers here.
- **S4** (lua side): extracts `shell`/`shellSource` from the descriptor + hello
  result. The wire fields I populate here ARE that contract.
- Do NOT edit `connection.ts`, `protocol.ts` (S1 owns it), `tsconfig.json`,
  `makeHelloHandler`/`makePingHandler`, or any lua.

## 10. Baseline (verified 2025-07-31, before S1/S2 land)

```
npx tsc --noEmit -p extension/tsconfig.json          → exit 0
node --import $JITI_REG extension/tests/protocol.test.ts   → 2/2 pass
node --import $JITI_REG extension/tests/bridge-env.test.ts → 4/4 pass
process.env.SHELL = /usr/bin/zsh   (machine-specific — tests must stub)
process.env.PI_NVIM_SHELL = <unset>
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
```

## Sources (all verified against the working tree)
- `extension/pi-nvim-bridge.ts:336-380` — the `resolveFdAvailable` cluster (pattern to mirror).
- `extension/pi-nvim-bridge.ts:568-578` — the `startBridge` `satisfies BridgeDescriptor` literal (population site).
- `extension/pi-nvim-bridge.ts:286-316` — env-name constant cluster (`BRIDGE_ENV`, `NVIM_APPNAME_OPTIN_ENV`).
- `extension/pi-nvim-bridge.ts:150-169` — `import type { … BridgeDescriptor } from "./protocol.ts"` (already present).
- `extension/pi-nvim-bridge.ts:623-686` — `makeHelloHandler`/`makePingHandler` (S3's sites; read-only here).
- `extension/tests/bridge-env.test.ts` — descriptor-shape test (the co-update target; 4 tests).
- `extension/tests/hello-handler.test.ts` — canonical node:test + deps-injection pattern.
- `plan/002_d23d7473c16c/architecture/research-extension-side.md` — §2e (resolver pattern), §2b (population site), §5 (test patterns).
- PRD §17.10.2 (`resolveShell` reference + honesty note), §17.4.1 (`descriptor.shell` contents).