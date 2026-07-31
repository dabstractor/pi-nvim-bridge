# Research Notes — P2.M1.T1.S3 (wire shell into makeHelloHandler/makePingHandler)

Verified against the live tree on 2025-07-31 (post-S1/S2; both landed).

## 0. What landed before me (the INPUT contract)

- **S1 (types) — DONE.** `extension/protocol.ts` already has the 3 optional fields on
  `BridgeDescriptor` (L96-98), `HelloResult` (L124-126), `PingResult` (L141-143):
  `shell?: string; shellSource?: "pi" | "$SHELL" | "default"; shellPath?: string;`.
  Confirmed by `grep -n shell extension/protocol.ts`. So the RESULT types ACCEPT shell.
- **S2 (resolver + descriptor) — DONE.** `extension/pi-nvim-bridge.ts` exports:
  - `ShellInfo` interface (L404): `{ shell; shellSource: "pi" | "$SHELL" | "default"; shellPath?: string }`.
  - `getShellInfo(): ShellInfo` (L420) — cached, lazy, **returns `ShellInfo` (never undefined in prod)**.
  - `__setShellInfoForTest(v)` (L427) — test seam.
  - `resolveShell(): ShellInfo` (L451) — the 3-branch chain.
  - The `PI_NVIM_BRIDGE` descriptor literal (L637 `const shellInfo = getShellInfo()`)
    ALREADY populates `shell`/`shellSource`/`shellPath`.
  → My INPUT `getShellInfo` exists, is in-scope at the registration sites (same file).

## 1. The handler source (CURRENT, post-S2 — line numbers shifted vs. the task's stale refs)

The task description cites L623-649 (hello) / L670-686 (ping) / L1180 / L1225. Those are
**STALE (pre-S2)**. Current reality (verified by read):

- `makeHelloHandler` signature @ **L684**, deps block **L684-688**:
  ```ts
  export function makeHelloHandler(deps: {
  	getToken: () => string | undefined;
  	getCwd: () => string | undefined;
  	getFdAvailable: () => boolean;
  	version: string;
  }): MethodHandler {
  ```
  Return @ **L702-707** (inside a block body — there is token-validation logic first):
  ```ts
  		return {
  			ok: true,
  			serverVersion: deps.version,
  			cwd: deps.getCwd() ?? "",
  			fdAvailable: deps.getFdAvailable(),
  		};
  ```

- `makePingHandler` signature @ **L733**, deps block **L733-737**:
  ```ts
  export function makePingHandler(deps: {
  	getPid: () => number;
  	getCwd: () => string | undefined;
  	getFdAvailable: () => boolean;
  	version: string;
  }): MethodHandler {
  ```
  Return @ **L739-745** (**expression body** — single returned object literal, no block):
  ```ts
  	return (_params: unknown, _state: ConnectionState): PingResult => ({
  		ok: true,
  		pid: deps.getPid(),
  		cwd: deps.getCwd() ?? "", // defensive fallback (mirrors hello's getCwd() ?? "")
  		fdAvailable: deps.getFdAvailable(),
  		serverVersion: deps.version,
  	});
  ```

## 2. The registration sites (CURRENT)

- **L1251** (inside `session_start`): `makeHelloHandler({ getToken, getCwd, getFdAvailable, version: BRIDGE_VERSION })`
- **L1296**: `makePingHandler({ getPid, getCwd, getFdAvailable, version: BRIDGE_VERSION })`
- Both use **shorthand** (`{ getToken, ... }`). `getShellInfo` is an in-scope module fn (L420,
  same file) → add as shorthand `getShellInfo,`. NO new import anywhere.
- `getToken`/`getCwd`/`getFdAvailable`/`getPid` are all module-level fns in this same file.

## 3. The deepEqual footgun (EMPIRICALLY VERIFIED)

```
deepEqual({a:1}, {a:1, b:undefined})   => FAIL   (key sets differ)
deepEqual({a:1, b:undefined}, {a:1})   => FAIL   (key sets differ)
deepEqual({a:1,b:undefined},{a:1,b:undefined}) => PASS
```
(node:assert/strict, checked 2025-07-31.) **Consequence:** if the handler return ALWAYS
emits `shell`/`shellSource`/`shellPath` keys (the task's literal direct form
`deps.getShellInfo()?.shell`, which yields `undefined` when unresolved), then EVERY existing
`assert.deepEqual` that compares a hello/ping result — full OR partial — BREAKS, because the
actual now has 3 extra keys the expected literal lacks. Examples that would break:
- `hello-handler.test.ts:74` `deepEqual(result, { ok, serverVersion, cwd, fdAvailable })`
- `hello-handler.test.ts:233` dispatch `result: { ok, serverVersion, cwd, fdAvailable }`
- `hello-handler.test.ts:313` REAL `deepEqual(rA.result, { ok, serverVersion, cwd, fdAvailable })`
- `ping-bye…:210` `deepEqual(got, { ok, pid, cwd, fdAvailable, serverVersion })`
- `ping-bye…:396` dispatch `result: { ok, pid, cwd, fdAvailable, serverVersion }`
- `connection.test.ts:53` `result: { ok: true }` (if it flows through hello — see §5)
- … and several more across 8 files. Hard to fully enumerate by hand.

## 4. DESIGN DECISION — required dep + conditional spread (NOT the literal direct form)

The task's contract #3 says: required dep `getShellInfo: () => ShellInfo | undefined`, and
return `shell: deps.getShellInfo()?.shell, …` (direct, always-3-keys). Faithful but it forces:

  (a) ~29 call-site edits (required dep → tsc enumerates ALL of them; safe), PLUS
  (b) ~6-10 `deepEqual` expected-literal edits across 8 files, EACH must EXACTLY match the
      injected stub's shell values (undefined OR real) — error-prone, many failable points.

**Chosen design:** REQUIRED dep `getShellInfo: () => ShellInfo | undefined` (honors the
explicit, checkable contract point) + **conditional spread** in the return:
```ts
const sh = deps.getShellInfo();
return { ok: true, …, ...(sh ? { shell: sh.shell, shellSource: sh.shellSource, shellPath: sh.shellPath } : {}) };
```
Why:
- **Wire-equivalent.** JSON.stringify omits `undefined` anyway (S2 established this for the
  descriptor). On the wire, `{…, shell: undefined}` and `{…}` (omitted) serialize IDENTICALLY.
  So the hello/ping JSON responses are byte-identical to the direct form.
- **Faithful to OUTPUT #4** ("carry shell fields WHEN the bridge has resolved them"):
  conditional spread carries them exactly when resolved, omits when not — a more precise
  match than always-present-as-undefined.
- **Type-consistent:** `cwd`/`fdAvailable` are REQUIRED on the result types → always present;
  `shell*` are OPTIONAL (S1) → conditionally present. Treating optional fields as conditional
  is architecturally consistent, not ad-hoc.
- **One-pass success:** the ONLY co-update is adding `getShellInfo: () => undefined,` to the
  ~27 existing test call sites (tsc-enumerated; mechanical; NO value-matching) + extending the
  `makeRecordingDeps` helper + 2-3 NEW focused tests with real stubs. ZERO `deepEqual`
  expected-literal edits (conditional spread omits the keys when the stub returns undefined →
  existing 4/5-field `deepEqual` pass UNCHANGED).
- `exactOptionalPropertyTypes` is OFF (only `strict:true`) → `shellPath: string | undefined`
  spread into `shellPath?: string` compiles. ✓ (tsconfig.json verified.)

> Sidebar — the literal-contract alternative (required dep + direct `deps.getShellInfo()?.shell`)
> is wire-equivalent and also correct, but forces ~6-10 `deepEqual` expected-literal edits
> across 8 files (each must match the stub's shell values exactly). It is NOT recommended for a
> one-pass implementation. If a reviewer insists on literal syntax, see PRP "Anti-Patterns".

## 5. The co-update surface (required dep → tsc is the source of truth)

`grep -rn "makeHelloHandler\|makePingHandler" extension/tests` found these call sites. With a
REQUIRED dep, `tsc --noEmit` will ERROR on each that lacks `getShellInfo` — that IS the
enumeration (the agent cannot miss one). Fix per site: add `getShellInfo: () => undefined,`
(tests that don't care about shell) — their `deepEqual` then stays 4/5-field (conditional
spread omits the keys). NEW focused tests inject real stubs.

makeHelloHandler call sites (tests):
- connection.test.ts:255
- hello-handler.test.ts: 67, 85, 102, 123, 137, 152, 166, 182, 194, 218, 255, 293
- handshake-gate.test.ts: 121, 179
- get-suggestions-handler.test.ts:514
- apply-completion-handler.test.ts:483
- should-trigger-file-completion-handler.test.ts:503
- ping-bye-getcommands-handler.test.ts:652
- commands-changed-notification.test.ts: 358, 411

makePingHandler call sites (tests):
- ping-bye-getcommands-handler.test.ts: 203, 220, 231, 248 (uses `makeRecordingDeps` helper),
  382, 418, 448, 661, 753

Helpers that build a deps object (also tsc-flagged):
- `ping-bye-getcommands-handler.test.ts` `makeRecordingDeps` (~L180) — returns a `{getPid,
  getCwd, getFdAvailable, version}` record used at L248. Must add `getShellInfo` (recording
  wrapper or `() => undefined`).

## 6. Test patterns (verified)

- `node:test` + `node:assert/strict` + jiti (NOT vitest). Run:
  `node --import "$JITI_REG" extension/tests/<file>.test.ts`
  where `JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs`.
  Reporter prints `ℹ tests N / ℹ pass N / ℹ fail N`.
- Deps are injected as plain object literals of stub fns. `assert.equal` on individual fields
  OR `assert.deepEqual` on the whole result.
- `hello-handler.test.ts` has a LOCAL structural type `HelloResultShape` (very end of file):
  ```ts
  type HelloResultShape = {
  	jsonrpc?: string; id?: string;
  	result?: { ok: true; serverVersion: string; cwd: string; fdAvailable: boolean };
  	ok?: true; serverVersion?: string; cwd?: string; fdAvailable?: boolean;
  };
  ```
  New shell-field assertions need `shell?/shellSource?/shellPath?` added to it (or an inline cast).

## 7. Baseline (verified green post-S2, BEFORE S3)

```
npx tsc --noEmit -p extension/tsconfig.json   → exit 0
hello-handler.test.ts            → 12/12 pass
ping-bye-getcommands-handler     → 25/25 pass
shell-resolver.test.ts (S2)      → 6/6 pass
protocol.test.ts (S1)            → 2/2 pass
bridge-env.test.ts               → 4/4 pass
```

## 8. Scope / non-goals

- DO: add `getShellInfo` dep to BOTH handler factories + the 2 registration sites; return shell
  fields (conditional spread); co-update test call sites (tsc-enumerated); add focused tests.
- DO NOT: touch `protocol.ts` (S1), the resolver/descriptor (S2), `connection.ts`,
  `tsconfig.json`, or any lua (S4). DO NOT change `getCwd`/`getFdAvailable` behavior. DO NOT
  make shell fields required on the types. DO NOT edit README/docs (Mode-B task P2.M4.T7).