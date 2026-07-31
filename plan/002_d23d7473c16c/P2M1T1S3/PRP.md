# PRP — P2.M1.T1.S3: Wire shell fields into `makeHelloHandler` + `makePingHandler` deps injection

> **Plan mapping:** task `P2.M1.T1.S3` ("Wire shell fields into makeHelloHandler +
> makePingHandler deps injection"). Third task of **P2.M1.T1** ("Bridge descriptor
> shell/shellSource/shellPath") within the **Shell Completion for !/!! Bash Mode** epic
> (PRD §17). S1 (types) and S2 (resolver + descriptor) are **DONE**; this task (S3) is the
> **live-RPC mirror**: surface the §17.10 advisory shell fields in the `hello`/`ping`
> *responses* (not just the `PI_NVIM_BRIDGE` descriptor) so a post-handshake client
> (`:checkhealth`, S4's lua `M.server_info`) can read them.

---

## Goal

**Feature Goal**: Add a `getShellInfo: () => ShellInfo | undefined` injected dep to the two
deps-injected RPC handler factories `makeHelloHandler` and `makePingHandler` in
`extension/pi-nvim-bridge.ts`, and surface the three §17.10 advisory fields
(`shell`/`shellSource`/`shellPath`) in their `HelloResult`/`PingResult` returns — **only when
the bridge has resolved a shell** (PRD §17.10.1: "the hello result mirrors these"). Wire the
real `getShellInfo` (exported by S2 at L420) into both registration sites (L1251 hello, L1296
ping). After this task, `hello`/`ping` JSON-RPC responses carry the resolved execution shell,
mirroring the descriptor fields S2 already populates.

**Deliverable** (files modified — all exist):
- `extension/pi-nvim-bridge.ts` — MODIFY: add `getShellInfo` to both handler deps types + the
  two registration-site literals + the two return values (conditional spread).
- `extension/tests/hello-handler.test.ts` — MODIFY: co-update the existing `makeHelloHandler`
  call sites (add `getShellInfo: () => undefined`) + extend `HelloResultShape` + ADD focused
  shell-field assertions.
- `extension/tests/ping-bye-getcommands-handler.test.ts` — MODIFY: co-update the existing
  `makePingHandler` call sites + the `makeRecordingDeps` helper + ADD focused shell-field
  assertions.
- **6 further test files** (`connection`, `handshake-gate`, `get-suggestions-handler`,
  `apply-completion-handler`, `should-trigger-file-completion-handler`,
  `commands-changed-notification`) — MODIFY: add `getShellInfo: () => undefined` to their
  `makeHelloHandler` call sites (tsc enumerates every one — see Validation Level 1).

**Success Definition**:
- `hello`/`ping` responses carry `shell`/`shellSource`/`shellPath` when `getShellInfo()`
  resolves a shell, and OMIT them entirely when it returns `undefined` (advisory/absent-OK
  back-compat — PRD §17.4 fallback to `$SHELL`).
- `npx tsc --noEmit -p extension/tsconfig.json` exits 0 (the required-dep gate proves every
  call site was updated).
- `hello-handler` (12→~14 pass), `ping-bye-getcommands-handler` (25→~27 pass) green; the 6
  co-updated suites + `protocol`/`bridge-env`/`shell-resolver` stay green (ℹ fail 0).

## User Persona (if applicable)

**Target User**: Developers of the §17 shell-completion subsystem — **S4** (lua
`bridge.lua` `M.server_info` extracts shell from descriptor AND hello), and the
`:checkhealth pi-bridge` consumer (P3.M10.T27.S42, which opens a connection, handshakes, then
sends `ping` to read server identity). End users see nothing until the plugin side (S4+) lands.

**Use Case**: A post-handshake client reads `hello`/`ping` result to learn the shell pi
executes `!`/`!!` in (the descriptor is pre-handshake; the RPC result is live + is what
`:checkhealth` reports). This task populates that result.

**Pain Points Addressed**: Without the RPC mirror, a client that connects post-discovery (or
one that distrusts the env blob) has no live source for the shell; `:checkhealth` cannot
report it. Mirroring the descriptor fields into `hello`/`ping` (exactly as `cwd`/
`fdAvailable`/`serverVersion` already are) closes that gap.

## Why

- **Closes the live-RPC half of §17.10.** S2 put the shell fields on the `PI_NVIM_BRIDGE`
  *descriptor* (pre-handshake). §17.10.1 mandates "the hello result mirrors these" — S3 is
  that mirror. Without it the fields are discoverable only via the env blob, never via RPC.
- **Mirrors a proven convention.** `makeHelloHandler`/`makePingHandler` already mirror
  `cwd`/`fdAvailable`/`serverVersion` from deps into both the descriptor and the RPC results.
  Shell fields are the fourth such mirror — mechanical, following the exact same shape.
- **Consumes S2's contract cleanly.** S2 exported `getShellInfo(): ShellInfo` + `ShellInfo`
  (L404/L420) specifically so S3 can inject it as a dep (S2's JSDoc at L402 says: "Exported so
  S3 can type its injected getShell dep"). This task wires exactly that.
- **Integrates with S1/S2 with ZERO file conflict.** S1 owns `protocol.ts`; S2 owns the
  resolver + descriptor literal. S3 owns the handlers + registration + their tests. No overlap.

## What

**User-visible behavior**: none directly (2-3 extra JSON keys in `hello`/`ping` success
responses; no plugin consumes them until S4+). The *contract* change — a successful `hello`
response now looks like:

```jsonc
{ "jsonrpc":"2.0", "id":"h1", "result": {
    "ok": true, "serverVersion": "0.1.0", "cwd": "…", "fdAvailable": true,
    "shell": "/bin/zsh",                       // NEW (§17.10) — present only when resolved
    "shellSource": "pi",                       // NEW — "pi" | "$SHELL" | "default"
    "shellPath": "/bin/zsh"                     // NEW — present only in the "pi" branch
}}
```
When the bridge has NOT resolved a shell (`getShellInfo()` → undefined), the three keys are
**omitted entirely** (advisory/absent-OK — the plugin falls back to `$SHELL`). `ping` is
identical plus `pid`.

**Technical requirements** (all in `extension/pi-nvim-bridge.ts` unless noted):
- Add `getShellInfo: () => ShellInfo | undefined;` to BOTH `makeHelloHandler` and
  `makePingHandler` deps object types (REQUIRED field — honors the task contract).
- In each handler's return, surface shell fields via **conditional spread**: compute
  `const sh = deps.getShellInfo();` once, then `...(sh ? { shell: sh.shell, shellSource:
  sh.shellSource, shellPath: sh.shellPath } : {})`. (See "Design Decision" below for why this
  is wire-equivalent to the contract's direct `deps.getShellInfo()?.shell` form yet far safer.)
- At the two registration sites (L1251 hello, L1296 ping), pass the real `getShellInfo`
  (module fn, L420, in-scope) via shorthand alongside `getFdAvailable`.

### Success Criteria

- [ ] Both handler deps types declare `getShellInfo: () => ShellInfo | undefined` (required).
- [ ] Both handler returns carry `shell`/`shellSource`/`shellPath` when `getShellInfo()`
      returns a `ShellInfo`, and OMIT all three when it returns `undefined`.
- [ ] Both registration sites pass the real `getShellInfo` (shorthand).
- [ ] `npx tsc --noEmit -p extension/tsconfig.json` exits 0 (proves every call site updated).
- [ ] `hello-handler`/`ping-bye-getcommands-handler` green with new shell assertions; the 6
      co-updated suites + `protocol`/`bridge-env`/`shell-resolver` stay green.
- [ ] NO edit to `protocol.ts`, the resolver/descriptor, `connection.ts`, `tsconfig.json`,
      or any lua.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo needs only this
PRP + the verbatim BEFORE/AFTER blocks below + the verified commands. Every line number was
confirmed by `grep -n`/`read` against the live file on 2025-07-31 (post-S1/S2); the baseline
(tsc 0; hello 12/12; ping 25/25; shell-resolver 6/6; protocol 2/2; bridge-env 4/4) was
confirmed by live runs. The single hard trap — that the literal direct-form return breaks
`deepEqual` across 8 test files (verified empirically) — is spelled out in §Design Decision +
§Known Gotchas, and the conditional-spread design sidesteps it entirely.

### Documentation & References

```yaml
# MUST READ — the spec (reproduced in this PRP's <selected_prd_content>)
- docfile: PRD.md
  why: "§17.10.1 mandates 'the hello result mirrors these' (the 3 descriptor shell fields) and gives the EXACT field shapes. §17.4.1 documents what descriptor.shell contains + shellSource semantics. §5.4 lists hello/ping result shapes."
  section: "h3.39 (§17.10), h4.9 (§17.10.1), h4.10 (§17.10.2), h3.8 (§5.4 Methods)"
  critical: "shellSource union is literally \"pi\" | \"$SHELL\" | \"default\" (the '$SHELL' member contains a '$'). Fields are ADVISORY + OPTIONAL — 'absent on older clients is fine; the plugin falls back to $SHELL' (§17.10.1)."

# MUST READ — the file being edited (verbatim BEFORE/AFTER in the Blueprint)
- file: extension/pi-nvim-bridge.ts
  why: "(1) makeHelloHandler deps+return (L684-707) + makePingHandler deps+return (L733-745) are the edit sites. (2) registration sites L1251 (hello) + L1296 (ping) pass the real deps via shorthand. (3) ShellInfo (L404) + getShellInfo (L420) are S2's exports — ALREADY in-scope (same file), no import."
  pattern: "deps-injected factory: `export function makeX(deps: { …getters… }): MethodHandler { return (params,state): TResult => ({ …deps… }) }`. Existing mirrors: cwd uses `deps.getCwd() ?? \"\"` (always-present required field); fdAvailable uses `deps.getFdAvailable()` (always-present)."
  gotcha: "makePingHandler's return is an EXPRESSION body `(…) => ({…})` — adding `const sh` requires converting to a BLOCK body `(…) => { const sh=…; return {…} }`. makeHelloHandler already has a block body (token logic) so `const sh` slots in before `return`."

# MUST READ — S2's CONTRACT (defines the INPUT this task consumes)
- file: plan/002_d23d7473c16c/P2M1T1S2/PRP.md
  why: "S2 exports getShellInfo(): ShellInfo + the ShellInfo interface + __setShellInfoForTest. S3 injects getShellInfo as a dep. S2's JSDoc (pi-nvim-bridge.ts:402) explicitly says ShellInfo/getShellInfo are exported 'so S3 can type its injected getShell dep'. S2 also populated the descriptor — S3 mirrors into the RPC results."
  pattern: "Contract: `getShellInfo(): ShellInfo` returns ShellInfo (cached, never undefined in prod). S3's dep type widens the return to `ShellInfo | undefined` so test stubs can inject `() => undefined` (the absent-shell path). `() => ShellInfo` is assignable to `() => ShellInfo | undefined` (return-type covariance) — the registration site passes the real fn unchanged."

# MUST READ — the test files to MODIFY (deps-injection + assertion patterns)
- file: extension/tests/hello-handler.test.ts
  why: "the canonical deps-injection test: stub fns in an object literal; `assert.equal` on fields + `assert.deepEqual` on full result. Co-update: every `makeHelloHandler({...})` needs `getShellInfo: () => undefined` added; extend the local `HelloResultShape` (end of file) with shell fields; ADD focused shell assertions."
- file: extension/tests/ping-bye-getcommands-handler.test.ts
  why: "mirrors hello's pattern for ping. ALSO has a `makeRecordingDeps` helper (~L180) that builds a ping-deps record — it must add getShellInfo too (tsc flags it)."

# MUST READ — local research notes (verified facts + the deepEqual-breakage analysis + design decision)
- docfile: plan/002_d23d7473c16c/P2M1T1S3/research/notes.md
  why: "exact current line numbers, the verbatim handler/registration source, the EMPIRICALLY-VERIFIED deepEqual footgun, the full co-update call-site enumeration, the conditional-spread design decision + rationale, baseline test counts."

# SUPPORTING — architecture research (confirms the deps-injection + mirror pattern)
- docfile: plan/002_d23d7473c16c/architecture/research-extension-side.md
  why: "§2f documents makeHelloHandler/makePingHandler as the deps-injected factories + their mirror of cwd/fdAvailable. Confirms shell is the 4th such mirror."
  section: "§2f"
  note: "if this file is absent under plan/002_…, the equivalent analysis is in research/notes.md §1-§2 (self-contained)."
```

### Current Codebase tree (relevant slice)

```bash
extension/
├── protocol.ts                 # (S1, DONE) BridgeDescriptor/HelloResult/PingResult already accept optional shell* — READ-ONLY for S3
├── pi-nvim-bridge.ts           # MODIFY — +getShellInfo dep ×2 handlers, +conditional-spread return ×2, +getShellInfo ×2 registration sites
├── connection.ts               # READ-ONLY (transport; MethodHandler/ConnectionState types live here)
├── tsconfig.json               # READ-ONLY (strict:true; exactOptionalPropertyTypes NOT enabled → shell?: string accepts undefined)
└── tests/
    ├── hello-handler.test.ts                      # MODIFY — co-update call sites + HelloResultShape + ADD shell assertions
    ├── ping-bye-getcommands-handler.test.ts       # MODIFY — co-update call sites + makeRecordingDeps + ADD shell assertions
    ├── connection.test.ts                         # MODIFY — add getShellInfo:()=>undefined to the 1 makeHelloHandler call site
    ├── handshake-gate.test.ts                     # MODIFY — add getShellInfo:()=>undefined to 2 makeHelloHandler call sites
    ├── get-suggestions-handler.test.ts            # MODIFY — add getShellInfo:()=>undefined to 1 makeHelloHandler call site
    ├── apply-completion-handler.test.ts           # MODIFY — add getShellInfo:()=>undefined to 1 makeHelloHandler call site
    ├── should-trigger-file-completion-handler.test.ts # MODIFY — add getShellInfo:()=>undefined to 1 makeHelloHandler call site
    ├── commands-changed-notification.test.ts      # MODIFY — add getShellInfo:()=>undefined to 2 makeHelloHandler call sites
    ├── protocol.test.ts        # READ-ONLY regression (S1)
    ├── bridge-env.test.ts      # READ-ONLY regression (S2 — descriptor already carries shell; untouched by S3)
    └── shell-resolver.test.ts  # READ-ONLY regression (S2)
```

### Desired Codebase tree with files to be modified

```bash
extension/pi-nvim-bridge.ts                                    # MODIFIED — handlers + registration (4 edits)
extension/tests/hello-handler.test.ts                          # MODIFIED — co-update + new assertions
extension/tests/ping-bye-getcommands-handler.test.ts           # MODIFIED — co-update + helper + new assertions
extension/tests/connection.test.ts                             # MODIFIED — 1 call-site co-update
extension/tests/handshake-gate.test.ts                         # MODIFIED — 2 call-site co-updates
extension/tests/get-suggestions-handler.test.ts                # MODIFIED — 1 call-site co-update
extension/tests/apply-completion-handler.test.ts              # MODIFIED — 1 call-site co-update
extension/tests/should-trigger-file-completion-handler.test.ts# MODIFIED — 1 call-site co-update
extension/tests/commands-changed-notification.test.ts          # MODIFIED — 2 call-site co-updates
# (NO protocol.ts / connection.ts / tsconfig.json / lua edits. NO new non-test files.)
```

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL GOTCHA #1 — deepEqual breaks on extra undefined-valued keys (EMPIRICALLY VERIFIED).
// `assert.deepEqual({a:1}, {a:1, b:undefined})` => FAIL (key sets differ). So if the handler
// return ALWAYS emits shell/shellSource/shellPath (the contract's literal direct form
// `deps.getShellInfo()?.shell`, which yields undefined when unresolved), EVERY existing
// deepEqual that compares a hello/ping result — full OR partial — BREAKS across 8 test files
// (hello-handler 74/233/313; ping-bye 210/396/551; connection 53; …). FIX: use CONDITIONAL
// SPREAD (omit the keys when shell unresolved) so existing deepEqual stay 4/5-field & PASS.

// CRITICAL GOTCHA #2 — makePingHandler's return is an EXPRESSION body, not a block.
//   Current: `return (_params, _state): PingResult => ({ … });`
// Adding `const sh = deps.getShellInfo();` REQUIRES converting to a block body:
//   `return (_params, _state): PingResult => { const sh = deps.getShellInfo(); return { … }; };`
// (makeHelloHandler already has a block body — slot `const sh` before its `return`.)

// GOTCHA #3 — the task's line numbers are STALE (pre-S2). The contract cites L623-649 (hello),
// L670-686 (ping), L1180/L1225 (registration). CURRENT (post-S2): makeHelloHandler @ L684,
// makePingHandler @ L733, registration @ L1251 (hello) / L1296 (ping). Do NOT trust the stale
// numbers — grep for the exact strings (see Blueprint) or use the L-numbers above as hints.

// GOTCHA #4 — a REQUIRED dep makes tsc the enumeration oracle. `npx tsc --noEmit` will ERROR
// on EVERY makeHelloHandler/makePingHandler call site missing getShellInfo (exact file:line).
// That IS the co-update list — you cannot miss one. Fix each by adding `getShellInfo: () => undefined,`
// (tests that don't assert shell) — conditional spread then keeps their deepEqual 4/5-field.

// GOTCHA #5 — exactOptionalPropertyTypes is OFF (only strict:true). So spreading
// `{ shellPath: sh.shellPath }` (where sh.shellPath is `string | undefined`) into a result
// typed `: HelloResult` (where `shellPath?: string`) type-checks. No `?? ""` needed (and
// `?? ""` would be WRONG — shellPath must be absent, not "", when unset).

// GOTCHA #6 — getShellInfo is ALREADY in-scope at the registration sites (same file, L420).
// Do NOT import it. Add it as shorthand in the deps literal: `{ getToken, getCwd, getFdAvailable, getShellInfo, version }`.
// The module getShellInfo is `() => ShellInfo`; the dep type is `() => ShellInfo | undefined` —
// assignable via return-type covariance. ✓

// GOTCHA #7 — TAB indentation (the file uses tabs everywhere; verified). Match tabs on every
// new line. The spread `...(sh ? { … } : {})` is ONE logical line — keep it on one line.

// SCOPE — this task is the handler wiring + registration + test co-update.
//   Do NOT: edit protocol.ts (S1), the resolver/descriptor (S2), connection.ts, tsconfig.json,
//   or lua (S4). Do NOT make shell fields required on the types. Do NOT add a new RPC method.
//   Do NOT edit README/docs (Mode-B task P2.M4.T7).
```

## Implementation Blueprint

### Design Decision (READ FIRST — why conditional spread, not the literal direct form)

The task contract #3 literally specifies a **required dep** `getShellInfo: () => ShellInfo |
undefined` and a **direct** return `shell: deps.getShellInfo()?.shell, …` (always-3-keys).
This PRP **honors the required dep** (it is the explicit, checkable contract point) but uses a
**conditional spread** in the return:

```ts
const sh = deps.getShellInfo();
return { ok: true, …base fields…,
    ...(sh ? { shell: sh.shell, shellSource: sh.shellSource, shellPath: sh.shellPath } : {}),
};
```

**Why** (each reason verified):
1. **Wire-equivalent.** `JSON.stringify` omits `undefined` (S2 established this for the
   descriptor). On the wire `{…, shell: undefined}` ≡ `{…}` (omitted). The hello/ping JSON
   responses are byte-identical to the direct form. PRD §17.10 cares about the *wire* shape.
2. **More faithful to OUTPUT #4** ("carry shell fields **when the bridge has resolved them**"):
   conditional spread carries them exactly when resolved, omits when not.
3. **Type-consistent:** `cwd`/`fdAvailable` are REQUIRED result fields → always present;
   `shell*` are OPTIONAL (S1) → conditionally present. Not ad-hoc.
4. **One-pass success:** the direct form breaks ~6-10 `deepEqual` assertions across 8 files
   (GOTCHA #1, verified) — each fix must EXACTLY match the injected stub's shell values.
   Conditional spread breaks ZERO (existing 4/5-field `deepEqual` pass unchanged when the stub
   returns `undefined`). The only co-update is adding `getShellInfo: () => undefined,` to
   ~27 call sites, which `tsc` enumerates with exact file:line (GOTCHA #4) — mechanical, no
   value-matching.

> The literal-contract alternative (direct form + fixing every `deepEqual`) is wire-equivalent
> and also correct, but is NOT recommended for a one-pass implementation. See Anti-Patterns.

### Data models and structure

No new types. Reuse S2's exported `ShellInfo` (pi-nvim-bridge.ts:404) — it is ALREADY in scope
inside both handlers (same file). The dep signature references it directly:

```ts
getShellInfo: () => ShellInfo | undefined;   // widens S2's () => ShellInfo to allow the absent-shell test path
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-nvim-bridge.ts — makeHelloHandler: add dep + conditional-spread return
  - DEPS TYPE (L684-688): add `getShellInfo: () => ShellInfo | undefined;` AFTER getFdAvailable
        and BEFORE `version:`. (Required field — honors contract #3.)
  - RETURN (L702-707, inside the existing BLOCK body): insert `const sh = deps.getShellInfo();`
        on the line immediately BEFORE `return {`, then append the conditional spread as the
        LAST property of the returned object literal.
  - BEFORE/AFTER: see "Reference implementation" block 1.
  - DO NOT: touch the token-validation logic, getCwd/getFdAvailable handling, or the JSDoc's
        registration example line (it's illustrative). DO NOT change the return type annotation
        (`: HelloResult`) — it already accepts optional shell* (S1).

Task 2: MODIFY extension/pi-nvim-bridge.ts — makePingHandler: add dep + conditional-spread return
  - DEPS TYPE (L733-737): add `getShellInfo: () => ShellInfo | undefined;` AFTER getFdAvailable,
        BEFORE `version:`.
  - RETURN (L739-745): CONVERT the expression body to a block body and add the same
        `const sh = deps.getShellInfo();` + conditional spread. See "Reference implementation"
        block 2 (GOTCHA #2 — this is the one structural change).
  - DO NOT: change the `_params`/`_state` param names or the `: PingResult` annotation.

Task 3: MODIFY extension/pi-nvim-bridge.ts — the 2 registration sites (L1251, L1296)
  - L1251 (hello): `makeHelloHandler({ getToken, getCwd, getFdAvailable, version: BRIDGE_VERSION })`
        → add `getShellInfo,` (shorthand — module fn is in scope, GOTCHA #6) alongside getFdAvailable.
  - L1296 (ping): `makePingHandler({ getPid, getCwd, getFdAvailable, version: BRIDGE_VERSION })`
        → add `getShellInfo,`.
  - DO NOT: add a new import, reorder other fields, or touch neighboring registerBridgeHandler calls.

Task 4: CO-UPDATE test call sites — add `getShellInfo: () => undefined,` (tsc enumerates them)
  - RUN `npx tsc --noEmit -p extension/tsconfig.json` AFTER Tasks 1-3. It will ERROR on every
        `makeHelloHandler`/`makePingHandler` call site missing `getShellInfo` (GOTCHA #4).
        For EACH error: add `getShellInfo: () => undefined,` to that call's deps literal.
  - AFFECTED FILES (full list in research/notes.md §5): connection.test.ts (1),
        handshake-gate.test.ts (2), get-suggestions-handler.test.ts (1),
        apply-completion-handler.test.ts (1), should-trigger-file-completion-handler.test.ts (1),
        commands-changed-notification.test.ts (2), hello-handler.test.ts (12),
        ping-bye-getcommands-handler.test.ts (8) — ~28 sites total.
  - SPECIAL: ping-bye-getcommands-handler.test.ts `makeRecordingDeps` helper (~L180, used at
        L248) builds a ping-deps record — add `getShellInfo: () => undefined` (or a recording
        wrapper) to the record it returns. tsc flags it.
  - WHY `() => undefined`: these tests assert non-shell behavior (token/handshake/cwd/fdAvailable).
        Conditional spread then OMITS the shell keys → their existing deepEqual stay 4/5-field
        and PASS unchanged (GOTCHA #1). No deepEqual expected-literal edits needed.

Task 5: ADD focused shell-field assertions (the new behavior proof)
  - IN hello-handler.test.ts: extend the local `HelloResultShape` (end of file) with
        `shell?: string; shellSource?: string; shellPath?: string;`. Then ADD 2 tests in the
        UNIT layer (mirror the existing `makeHelloHandler: …` tests):
        (a) stub `getShellInfo: () => ({ shell: "/bin/zsh", shellSource: "pi", shellPath: "/bin/zsh" })`
            → assert result.shell==="/bin/zsh", result.shellSource==="pi", result.shellPath==="/bin/zsh".
        (b) stub `getShellInfo: () => undefined` → assert `!("shell" in result)` (key ABSENT —
            proves conditional spread omits when unresolved).
  - IN ping-bye-getcommands-handler.test.ts: ADD the same 2 tests for makePingHandler (in the
        "1. UNIT — ping" section, after the existing `UNIT ping: happy path` test).
  - PATTERN: node:test + assert/strict; assert.equal on individual shell fields (NOT deepEqual
        on the whole — robust to other fields). See "Reference implementation" block 3.
  - NAMING: "makeHelloHandler: getShellInfo stub → result carries shell/shellSource/shellPath"
            "makeHelloHandler: getShellInfo()=>undefined → shell fields ABSENT (advisory)"
```

### Reference implementation

```typescript
// === Block 1: makeHelloHandler (pi-nvim-bridge.ts ~L684) — BEFORE → AFTER ===
// BEFORE (current):
export function makeHelloHandler(deps: {
	getToken: () => string | undefined;
	getCwd: () => string | undefined;
	getFdAvailable: () => boolean;
	version: string;
}): MethodHandler {
	return (params: unknown, state: ConnectionState): HelloResult => {
		// …token-validation logic unchanged…
		state.handshakeComplete = true; // S10 gates every other method on this.
		return {
			ok: true,
			serverVersion: deps.version,
			cwd: deps.getCwd() ?? "",
			fdAvailable: deps.getFdAvailable(),
		};
	};
}

// AFTER (S3):
export function makeHelloHandler(deps: {
	getToken: () => string | undefined;
	getCwd: () => string | undefined;
	getFdAvailable: () => boolean;
	getShellInfo: () => ShellInfo | undefined; // §17.10 (S3) — advisory shell mirror
	version: string;
}): MethodHandler {
	return (params: unknown, state: ConnectionState): HelloResult => {
		// …token-validation logic unchanged…
		state.handshakeComplete = true; // S10 gates every other method on this.
		const sh = deps.getShellInfo(); // §17.10 (S3) — advisory; omitted when unresolved
		return {
			ok: true,
			serverVersion: deps.version,
			cwd: deps.getCwd() ?? "",
			fdAvailable: deps.getFdAvailable(),
			...(sh ? { shell: sh.shell, shellSource: sh.shellSource, shellPath: sh.shellPath } : {}),
		};
	};
}
```

```typescript
// === Block 2: makePingHandler (pi-nvim-bridge.ts ~L733) — BEFORE → AFTER ===
// BEFORE (current — EXPRESSION body):
export function makePingHandler(deps: {
	getPid: () => number;
	getCwd: () => string | undefined;
	getFdAvailable: () => boolean;
	version: string;
}): MethodHandler {
	return (_params: unknown, _state: ConnectionState): PingResult => ({
		ok: true,
		pid: deps.getPid(),
		cwd: deps.getCwd() ?? "", // defensive fallback (mirrors hello's getCwd() ?? "")
		fdAvailable: deps.getFdAvailable(),
		serverVersion: deps.version,
	});
}

// AFTER (S3 — converted to BLOCK body so `const sh` can precede the return):
export function makePingHandler(deps: {
	getPid: () => number;
	getCwd: () => string | undefined;
	getFdAvailable: () => boolean;
	getShellInfo: () => ShellInfo | undefined; // §17.10 (S3) — advisory shell mirror
	version: string;
}): MethodHandler {
	return (_params: unknown, _state: ConnectionState): PingResult => {
		const sh = deps.getShellInfo(); // §17.10 (S3) — advisory; omitted when unresolved
		return {
			ok: true,
			pid: deps.getPid(),
			cwd: deps.getCwd() ?? "", // defensive fallback (mirrors hello's getCwd() ?? "")
			fdAvailable: deps.getFdAvailable(),
			serverVersion: deps.version,
			...(sh ? { shell: sh.shell, shellSource: sh.shellSource, shellPath: sh.shellPath } : {}),
		};
	};
}
```

```typescript
// === Block 3: registration sites (pi-nvim-bridge.ts L1251 + L1296) — BEFORE → AFTER ===
// BEFORE (hello, L1251):
		makeHelloHandler({ getToken, getCwd, getFdAvailable, version: BRIDGE_VERSION }),
// AFTER:
		makeHelloHandler({ getToken, getCwd, getFdAvailable, getShellInfo, version: BRIDGE_VERSION }),

// BEFORE (ping, L1296):
		makePingHandler({ getPid, getCwd, getFdAvailable, version: BRIDGE_VERSION }),
// AFTER:
		makePingHandler({ getPid, getCwd, getFdAvailable, getShellInfo, version: BRIDGE_VERSION }),
```

```typescript
// === Block 4: NEW focused tests (add to hello-handler.test.ts UNIT layer; mirror in ping-bye) ===
// (a) hello-handler.test.ts — FIRST extend the local type at the END of the file:
type HelloResultShape = {
	jsonrpc?: string;
	id?: string;
	result?: { ok: true; serverVersion: string; cwd: string; fdAvailable: boolean };
	ok?: true;
	serverVersion?: string;
	cwd?: string;
	fdAvailable?: boolean;
	shell?: string;        // NEW (S3)
	shellSource?: string;  // NEW (S3)
	shellPath?: string;    // NEW (S3)
};

// (b) ADD these two tests (after the existing "getCwd()===undefined" hello unit test):
test("makeHelloHandler: getShellInfo stub → result carries shell/shellSource/shellPath", () => {
	const state: ConnectionState = { handshakeComplete: false };
	const handler = makeHelloHandler({
		getToken: () => TOKEN,
		getCwd: () => "/tmp",
		getFdAvailable: () => true,
		getShellInfo: () => ({ shell: "/bin/zsh", shellSource: "pi", shellPath: "/bin/zsh" }),
		version: BRIDGE_VERSION,
	});
	const result = handler({ token: TOKEN }, state) as HelloResultShape;
	assert.equal(result.shell, "/bin/zsh");
	assert.equal(result.shellSource, "pi");
	assert.equal(result.shellPath, "/bin/zsh");
	assert.equal(state.handshakeComplete, true);
});

test("makeHelloHandler: getShellInfo()=>undefined → shell fields ABSENT (advisory, §17.10)", () => {
	const state: ConnectionState = { handshakeComplete: false };
	const handler = makeHelloHandler({
		getToken: () => TOKEN,
		getCwd: () => "/tmp",
		getFdAvailable: () => true,
		getShellInfo: () => undefined,
		version: BRIDGE_VERSION,
	});
	const result = handler({ token: TOKEN }, state) as Record<string, unknown>;
	assert.equal("shell" in result, false, "shell key must be ABSENT when getShellInfo returns undefined");
	assert.equal("shellSource" in result, false);
	assert.equal("shellPath" in result, false);
	assert.equal(result.ok, true);
});

// (c) MIRROR the same 2 tests in ping-bye-getcommands-handler.test.ts ("1. UNIT — ping"),
//     calling makePingHandler with { getPid, getCwd, getFdAvailable, getShellInfo, version } and
//     asserting on the PingResult. Use the same stub values + the `in` checks for the absent path.
```

### Integration Points

```yaml
MODULE STATE (extension/pi-nvim-bridge.ts — additive, no new exports):
  - makeHelloHandler deps: +getShellInfo: () => ShellInfo | undefined   (required)
  - makePingHandler  deps: +getShellInfo: () => ShellInfo | undefined   (required)
  - both returns: +conditional spread of shell/shellSource/shellPath (present only when resolved)

REGISTRATION (the ONLY production wiring change):
  - L1251 hello deps literal: +getShellInfo (shorthand; module fn in scope)
  - L1296 ping  deps literal: +getShellInfo (shorthand)

WIRE CONTRACT (forward to S4 — do NOT implement here):
  - S4 (lua bridge.lua M.server_info) extracts shell/shellSource from BOTH the descriptor AND
    the hello result. The fields S3 surfaces here ARE that RPC contract. S3 does not touch lua.

NO DATABASE / NO CONFIG / NO ROUTES / NO new RPC method / NO protocol.ts edit / NO env var /
NO tsconfig edit / NO docs (Mode-B task P2.M4.T7 owns README/extension/README.md).
```

## Validation Loop

> Run all commands from the repo root (`/home/dustin/projects/pi-nvim-bridge`).
> Baseline (verified 2025-07-31, post-S2, BEFORE S3): tsc exit 0; hello 12/12; ping 25/25;
> shell-resolver 6/6; protocol 2/2; bridge-env 4/4. Set the jiti register once:
> `JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs`

### Level 1: Type-check (THE co-update oracle — proves every call site was updated)

```bash
timeout 90 npx tsc --noEmit -p extension/tsconfig.json && echo "tsc exit=0"
# Expected: exit 0. REQUIRED-dep errors list EVERY makeHelloHandler/makePingHandler call site
# missing getShellInfo (GOTCHA #4) — fix each per Task 4 until exit 0. If tsc errors on the
# handler bodies, READ it: likely a typo in the dep type, a missing brace (ping block-body
# conversion — GOTCHA #2), or a spread type mismatch (shouldn't happen; exactOptionalPropertyTypes off).
```

### Level 2: Unit Tests (the new behavior + the co-updated suites)

```bash
# 2a. hello — new shell assertions + co-updated call sites (expect ~14 pass, ℹ fail 0):
timeout 60 node --import "$JITI_REG" extension/tests/hello-handler.test.ts 2>/dev/null | grep -E "ℹ (tests|pass|fail)"
# 2b. ping — new shell assertions + co-updated call sites + makeRecordingDeps (expect ~27, ℹ fail 0):
timeout 60 node --import "$JITI_REG" extension/tests/ping-bye-getcommands-handler.test.ts 2>/dev/null | grep -E "ℹ (tests|pass|fail)"
# Expected: ℹ fail 0 for both. If a deepEqual FAILS, you likely used the direct form instead of
# conditional spread (GOTCHA #1) OR a stub returns a real ShellInfo but the test's deepEqual
# wasn't updated — re-read Design Decision.
```

### Level 3: Regression — prove the 6 co-updated suites + S1/S2 suites stay green

```bash
# Each co-updated suite must still pass (getShellInfo:()=>undefined added; behavior unchanged):
for f in connection handshake-gate get-suggestions-handler apply-completion-handler should-trigger-file-completion-handler commands-changed-notification; do
  echo -n "$f: "; timeout 60 node --import "$JITI_REG" extension/tests/$f.test.ts 2>/dev/null | grep -E "ℹ fail" | tr '\n' ' '; echo
done
# S1/S2 suites untouched by S3 — must stay green:
timeout 60 node --import "$JITI_REG" extension/tests/protocol.test.ts        2>/dev/null | grep -E "ℹ fail"
timeout 60 node --import "$JITI_REG" extension/tests/bridge-env.test.ts      2>/dev/null | grep -E "ℹ fail"
timeout 60 node --import "$JITI_REG" extension/tests/shell-resolver.test.ts  2>/dev/null | grep -E "ℹ fail"
# Expected: every line shows ℹ fail 0.
```

### Level 4: End-to-end RPC verification (the actual hello/ping wire shape)

```bash
# 4a. Drive a REAL hello + ping over a Unix socket and inspect the JSON results' shell fields.
#     (startBridge resolves the real $SHELL; handshake then ping reads the live RPC mirror.)
cat > /tmp/s3_e2e.mjs <<'EOF'
import { createServer, connect } from "node:net";
import { once } from "node:events";
import { onConnection, registerBridgeHandler, __resetHandlersForTest } from "/home/dustin/projects/pi-nvim-bridge/extension/connection.ts";
import { makeHelloHandler, makePingHandler, getShellInfo, getToken, getCwd, getPid, getFdAvailable, BRIDGE_VERSION, startBridge, stopBridge, __deps, __setFdAvailableForTest, __setShellInfoForTest } from "/home/dustin/projects/pi-nvim-bridge/extension/pi-nvim-bridge.ts";
__deps.createServer = (() => ({ listen(){return this;}, close(){}, on(){} }));
__deps.chmodSync = () => {};
__setFdAvailableForTest(true);
__setShellInfoForTest(undefined); // use REAL resolution (reads live $SHELL)
startBridge({ cwd: "/tmp" });
registerBridgeHandler("hello", makeHelloHandler({ getToken, getCwd, getFdAvailable, getShellInfo, version: BRIDGE_VERSION }));
registerBridgeHandler("ping",  makePingHandler({ getPid, getCwd, getFdAvailable, getShellInfo, version: BRIDGE_VERSION }));
const sp = `/tmp/s3-${process.pid}.sock`;
const srv = createServer((c) => onConnection(c));
srv.listen(sp); await once(srv, "listening");
async function rpc(method, params) {
  const c = connect(sp); await once(c, "connect");
  let res;
  c.on("data", (d) => { if (!res) res = JSON.parse(d.toString().trim()); });
  c.write(JSON.stringify({ jsonrpc: "2.0", id: method, method, params }) + "\n");
  await new Promise((r) => setTimeout(r, 200)); c.destroy(); return res;
}
// handshake with the real token, then ping:
const h = await rpc("hello", { token: getToken() });
console.log("hello.shell=", JSON.stringify(h.result.shell), "shellSource=", JSON.stringify(h.result.shellSource), "keys=", Object.keys(h.result).length);
const p = await rpc("ping", {});
console.log("ping.shell=", JSON.stringify(p.result.shell), "shellSource=", JSON.stringify(p.result.shellSource), "keys=", Object.keys(p.result).length);
__resetHandlersForTest(); srv.close(); stopBridge();
EOF
node --import "$JITI_REG" /tmp/s3_e2e.mjs; rm -f /tmp/s3_e2e.mjs /tmp/s3-*.sock
# Expected: hello.shell and ping.shell are the SAME resolved value (your live $SHELL, e.g.
#   "/bin/zsh", or "/bin/bash" if SHELL unset); shellSource "$SHELL" (or "default"); both
#   results carry shell/shellSource keys. (shellPath omitted unless PI_NVIM_SHELL is set.)

# 4b. Confirm the conditional spread + registration edits are present in source:
grep -n "getShellInfo: () => ShellInfo | undefined" extension/pi-nvim-bridge.ts   # expect 2 (both handler deps)
grep -n "sh ? { shell:" extension/pi-nvim-bridge.ts                              # expect 2 (both returns)
grep -n "getShellInfo, version: BRIDGE_VERSION" extension/pi-nvim-bridge.ts      # expect 2 (both registration sites)
```

## Final Validation Checklist

### Technical Validation

- [ ] `npx tsc --noEmit -p extension/tsconfig.json` exits 0 (zero output) — proves every call site updated.
- [ ] `hello-handler` green with the 2 new shell assertions (~14 pass, ℹ fail 0).
- [ ] `ping-bye-getcommands-handler` green with the 2 new shell assertions (~27 pass, ℹ fail 0).
- [ ] The 6 co-updated suites green (ℹ fail 0): connection, handshake-gate, get-suggestions,
      apply-completion, should-trigger-file-completion, commands-changed-notification.
- [ ] S1/S2 suites untouched & green: protocol, bridge-env, shell-resolver (ℹ fail 0).
- [ ] Level 4a: real hello & ping results carry the SAME resolved `shell`/`shellSource`.
- [ ] No file other than `extension/pi-nvim-bridge.ts` + the 8 listed test files is modified.

### Feature Validation

- [ ] Both handler deps declare `getShellInfo: () => ShellInfo | undefined` (required).
- [ ] Both returns carry shell/shellSource/shellPath when `getShellInfo()` resolves, and OMIT
      all three (keys absent, not just undefined) when it returns `undefined`.
- [ ] Both registration sites pass the real `getShellInfo` (shorthand).
- [ ] New tests prove BOTH the present-path (real stub) and the absent-path (`()=>undefined`).

### Code Quality Validation

- [ ] Conditional spread mirrors S2's descriptor approach; the ONLY deviation from the contract
      literal (direct `deps.getShellInfo()?.shell`) is documented in Design Decision.
- [ ] TAB indentation throughout (match the file); the spread is one logical line.
- [ ] `makePingHandler` block-body conversion is the only structural change; param names + return
      type annotation unchanged.
- [ ] Co-updates are ADDITIVE to existing test structure (only `getShellInfo: () => undefined,`
      added); no existing assertion's MEANING changed.
- [ ] No edit to protocol.ts, the resolver/descriptor, connection.ts, tsconfig.json, or lua.

### Documentation & Deployment

- [ ] [Mode A] a one-line `// §17.10 (S3)` comment on the new dep + the `const sh` line (matches
      the existing `// §…` inline-comment convention in this file).
- [ ] No README / `doc/pi-bridge.txt` / `extension/README.md` change (Mode-B task P2.M4.T7).

---

## Anti-Patterns to Avoid

- ❌ Don't use the literal direct form `shell: deps.getShellInfo()?.shell` (always-3-keys) — it
  breaks `deepEqual` across 8 test files (GOTCHA #1, verified) because the result then carries
  `shell: undefined` keys the expected literals lack. Use **conditional spread** (omit when
  unresolved) — wire-equivalent, zero breakage. (If a reviewer mandates the literal syntax, the
  co-update cost is ~6-10 `deepEqual` expected-literal edits, each matching the stub's shell
  values — see research/notes.md §4 sidebar.)
- ❌ Don't make the dep OPTIONAL to "avoid" the call-site co-update — the contract specifies a
  REQUIRED dep, and a required dep makes `tsc` the reliable enumeration oracle (GOTCHA #4).
  The call-site fix is mechanical (`getShellInfo: () => undefined,`); conditional spread keeps
  every existing `deepEqual` green without touching expected literals.
- ❌ Don't call `deps.getShellInfo()` 3× inline — compute `const sh` ONCE (it's a 3-field object,
  and the single read makes the conditional spread read cleanly).
- ❌ Don't force `shellPath ?? ""` — `shellPath` must be ABSENT (not `""`) when unset (the
  absent-OK back-compat contract). Conditional spread already omits it; `?? ""` would be wrong.
- ❌ Don't convert `getShellInfo`'s return type to non-undefined at the dep — the `|
  undefined` lets test stubs inject `() => undefined` to exercise the absent-shell path.
- ❌ Don't trust the task's line numbers (L623-686/L1180/L1225 are STALE pre-S2 — GOTCHA #3).
  Current: hello @ L684, ping @ L733, registration @ L1251/L1296. Grep the exact strings instead.
- ❌ Don't edit protocol.ts (S1), the resolver/descriptor (S2), connection.ts, tsconfig.json, or
  lua (S4). Don't add shell to the handlers' JSDoc registration example line (it's illustrative).
- ❌ Don't forget the `makeRecordingDeps` helper in ping-bye test (tsc flags it, but fix it
  deliberately — it feeds the `makePingHandler(deps)` call at L248).
- ❌ Don't use spaces where the file uses tabs; don't leave the conditional spread split across
  multiple lines.