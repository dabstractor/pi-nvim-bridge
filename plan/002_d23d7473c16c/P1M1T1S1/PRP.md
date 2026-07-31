---
name: "P1.M1.T1.S1 — Verify isInteractiveSession dual-detection + session_start guard + manifest + import-type-only"
description: |
  READ-ONLY VERIFICATION task (not implementation). Confirm 5 host-compat
  claims from PRD §6.8 against the already-implemented extension source
  (`extension/pi-nvim-bridge.ts`, `extension/protocol.ts`, `package.json`),
  run the `npm run typecheck` regression gate, and emit a verification report.
  Apply a MINIMAL fix ONLY if a gap is found. Mode A: check JSDoc drift on
  `isInteractiveSession`; update only if drifted.
---

## Goal

**Feature Goal**: Produce a verification report that confirms the bridge
extension's oh-my-pi (`omp`) host-compatibility invariants (PRD §6.8) hold in
the current source, with reproducible evidence and a green typecheck — proving
the bridge activates under both `pi` (Node, `ctx.mode === "tui"`) and `omp`
(Bun, `ctx.hasUI === true`) without code changes.

**Deliverable**: A verification report (commit message or PR description)
containing a 5-claim PASS/FAIL table with `file:line` evidence, the
`npm run typecheck` exit code, and the Mode-A JSDoc-drift conclusion. **No new
code unless a verified gap is found** (none expected — see pre-check below).

**Success Definition**:
- All 5 claims re-confirmed PASS with `file:line` evidence captured via the
  exact commands in this PRP.
- `npm run typecheck` exits 0 (no regression). If a minimal fix was applied,
  typecheck still exits 0 afterward.
- Report documents the Mode-A JSDoc-drift check result (drift found → JSDoc
  updated to match PRD §6.8; no drift → explicitly stated, no change).

> **PRE-CHECK (already run during research):** As of this PRP, all 5 claims
> PASS and `npm run typecheck` exits 0. This task is the formal, reproducible
> re-confirmation + report. Expect to change nothing.

## User Persona (if applicable)

**Target User**: `pi-nvim-bridge` maintainers / the engineer hardening omp
(oh-my-pi) host compatibility before the Phase-2 shell-completion work.

**Use Case**: Lock in the omp dual-detection invariants so a future refactor
can't silently regress them (the prior incompat's root cause was a
`ctx.mode !== "tui"` guard that bailed under omp every `session_start`).

**Pain Points Addressed**: The bridge silently no-op'd under omp — no
`PI_NVIM_BRIDGE` advertisement, no socket, no completions — with no error.
This verification proves the 5 invariants that prevent that failure mode.

## Why

- **Root-cause guard for the prior omp incompat** (PRD §6.8): omp removed
  `ctx.mode` and exposes `ctx.hasUI` instead. `isInteractiveSession()` must
  accept EITHER; the `session_start` guard must run before any provider
  capture / socket bind. This task proves that ordering.
- **Type-only imports are load-critical under omp**: omp lacks the
  `@earendil-works/*` packages at runtime (it ships `@oh-my-pi/*`); every
  `@earendil-works/*` import MUST be `import type` so jiti/Bun erases it.
  This task proves zero value imports.
- **Manifest fallback**: the `"pi"` key must be the discovery key so omp's
  `(pkg.omp ?? pkg.pi).extensions` fallback finds the extension unchanged.
- **Cheap, high-value insurance**: a read-only check that prevents a
  category of silent regression before Phase-2 work lands.

## What

A verification pass that, for each of the 5 claims, runs a content-based
grep/read against the real source, captures `file:line` evidence, records
PASS/FAIL, then runs `npm run typecheck` as the regression gate. Output is a
report (no new production code unless a gap is found).

### Success Criteria

- [ ] Claim (A): `isInteractiveSession` body contains BOTH `ctx.mode === "tui"`
      AND `.hasUI === true` (via intersection cast). PASS recorded with line.
- [ ] Claim (B): the `session_start` guard `if (!isInteractiveSession(ctx)) return;`
      appears at a line number strictly LESS than `captureProvider(ctx)` and
      `startBridge(ctx)`. PASS recorded with all three line numbers.
- [ ] Claim (C): the `startBridge` descriptor (`process.env[BRIDGE_ENV] =
      JSON.stringify({...})`) references only host-agnostic values
      (`process.pid`, `ctx.cwd`, module `let`s, node builtins, local helpers) —
      no `@earendil-works` value resolution, no host-specific API. PASS recorded.
- [ ] Claim (D): `package.json` manifest block uses key `"pi"` with
      `"extensions": ["./extension/pi-nvim-bridge.ts"]`. PASS recorded.
- [ ] Claim (E): a robust multiline scan finds ZERO `@earendil-works/*` value
      imports (every one is `import type`). PASS recorded.
- [ ] `npm run typecheck` exits 0.
- [ ] Mode-A JSDoc-drift check on `isInteractiveSession` performed; result
      recorded (drift → updated to match §6.8; no drift → stated).
- [ ] Verification report written (commit msg or PR description).

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo can run each verification
command exactly as written, read the cited source lines, and decide PASS/FAIL
without any other context. Every command is content-based (robust to line
drift); current line numbers are given as anchors only.

### Documentation & References

```yaml
# MUST READ — the spec being verified against
- docfile: PRD.md
  why: §6.8 (Host compatibility — pi and omp) is the source of the 5 claims; §6.6 has the default-export + isInteractiveSession reference; §6.2 the session_start/shutdown lifecycle + host-aware gate note
  section: "h3.17 (§6.8 divergence table), h3.15 (§6.6 default export + isInteractiveSession), h3.11 (§6.2 events + host-aware gate note)"
  critical: |
    §6.8 divergence table: pi = ctx.mode==="tui" + manifest key "pi"; omp = ctx.hasUI===true + (pkg.omp ?? pkg.pi).extensions fallback + @oh-my-pi/* imports.
    §6.6: isInteractiveSession accepts ctx.mode==="tui" OR ctx.hasUI===true (hasUI read via intersection cast — not on pi's type).

# MUST READ — pre-researched exact implementation citations (the source of the contract's line numbers)
- docfile: plan/002_d23d7473c16c/architecture/research-extension-side.md
  why: §2c documents isInteractiveSession at L1119-1138 (JSDoc above, impl 1134-1138), guard at L1167, and explains the pi-vs-omp fork
  section: "§2c 'isInteractiveSession(ctx) — exact implementation (lines 1119-1138)'"

# MUST READ — the files under verification
- file: extension/pi-nvim-bridge.ts
  why: contains isInteractiveSession (L1134), session_start handler (L1142), guard (L1167), startBridge (L526), descriptor write (L570-578), and the @earendil-works imports (L135-141)
  pattern: "grep -nE 'function isInteractiveSession|isInteractiveSession\\(ctx\\)|captureProvider\\(ctx\\)|startBridge\\(ctx\\)|process\\.env\\[BRIDGE_ENV\\]' extension/pi-nvim-bridge.ts"
  gotcha: "line numbers are current as of this PRP but WILL drift over time — always verify with content greps, not by hard-coded line numbers"

- file: extension/protocol.ts
  why: second file that imports from @earendil-works (L23-26, L30-32) — both must be import type for claim (E)
  pattern: "grep -nE '@earendil-works' extension/protocol.ts"

- file: package.json
  why: the manifest discovery key (claim D) + the typecheck script (regression gate)
  pattern: '"pi": { "extensions": ["./extension/pi-nvim-bridge.ts"] } and "typecheck": "tsc --noEmit -p extension/tsconfig.json"'
```

### Current Codebase tree

```bash
$ (cd /home/dustin/projects/pi-nvim-bridge && ls -1)
AGENTS.md
doc/
extension/        # <- verification target (TS, pi side)
ftplugin/
lua/              # Neovim plugin (Component B) — NOT in scope for this task
node_modules/
package.json      # <- verification target (manifest + typecheck script)
plugin/
PRD.md
README.md
tests/
```

```bash
extension/
├── connection.ts
├── jsonl-reader.ts
├── pi-nvim-bridge.ts   # (VERIFY) isInteractiveSession, session_start guard, startBridge descriptor, imports
├── protocol.ts         # (VERIFY) @earendil-works imports are import type
├── tests/
└── tsconfig.json       # consumed by `npm run typecheck`
```

### Desired Codebase tree with files to be added

```bash
# NO new files expected. This is read-only verification.
# Only changes (ONLY if a gap is found):
#   - extension/pi-nvim-bridge.ts   (minimal fix to a failed claim, if any)
#   - extension/protocol.ts         (minimal fix to claim E, if it fails)
#   - package.json                  (minimal fix to claim D, if it fails)
#   - the isInteractiveSession JSDoc (Mode A) ONLY if drifted from §6.8
```

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL: line numbers drift. The contract cites L1134/L1167/L570/L135 etc.
//   These are CURRENT but the verification MUST use content-based greps and
//   then read ±N lines — never assert on a hard-coded line number alone.

// CRITICAL: claim (E) "all imports are import type" must be checked with a
//   MULTILINE-aware scan. A naive `grep '^import {'` misses multi-line imports
//   like:  import {\n  Foo,\n  Bar,\n} from "@earendil-works/...". Use the
//   perl -0777 scan in the Validation Loop, which flags any @earendil-works
//   import not preceded by `import type`.

// GOTCHA: `import { createServer, type Server } from "node:net";` (L142) is a
//   MIXED import but it is from "node:net", NOT @earendil-works — that is
//   CORRECT and must NOT be flagged. Claim (E) is scoped to @earendil-works/* only.

// GOTCHA: the descriptor uses `satisfies BridgeDescriptor` (L578) — a
//   compile-time guard. It is NOT a host-specific runtime call; it is erased by
//   tsc. Do not mistake it for a value dependency.

// GOTCHA: omp fallback is `(pkg.omp ?? pkg.pi).extensions`. There is intentionally
//   NO "omp" key in package.json — the "pi" key IS the fallback omp reads. A
//   "missing omp key" is the DESIGNED state, NOT a gap.

// CRITICAL (AGENTS.md HARD RULE): NEVER pipe a heredoc into `nvim` stdin (it
//   hangs). This task should not need nvim at all — it is grep/read/tsc only.
//   If any nvim check is added, write the snippet to a real file first.
```

## Implementation Blueprint

### Data models and structure

Not applicable — read-only verification. No data models are created or modified.

### Verification Tasks (ordered by dependencies)

```yaml
Task 1: VERIFY claim (A) — isInteractiveSession dual-detection
  - RUN: grep -nE 'function isInteractiveSession' extension/pi-nvim-bridge.ts
  - READ ±10 lines around the hit (should be ~L1134)
  - ASSERT: body contains BOTH `ctx.mode === "tui"` AND `(ctx as ExtensionContext & { hasUI?: boolean }).hasUI === true`
  - RECORD: file:line + PASS/FAIL

Task 2: VERIFY claim (B) — session_start guard precedes capture+bridge
  - RUN: grep -nE 'isInteractiveSession\(ctx\)|captureProvider\(ctx\)|startBridge\(ctx\)' extension/pi-nvim-bridge.ts
  - ASSERT: the guard line (the bare `if (!isInteractiveSession(ctx)) return;`, NOT the function def) has a number strictly LESS than captureProvider AND startBridge lines
  - ASSERT: all three are INSIDE the `pi.on("session_start", ...)` handler (read the surrounding handler; starts ~L1142)
  - RECORD: the three line numbers + PASS/FAIL

Task 3: VERIFY claim (C) — startBridge descriptor is host-agnostic
  - RUN: grep -nE 'process\.env\[BRIDGE_ENV\] = JSON\.stringify' extension/pi-nvim-bridge.ts
  - READ the object literal (≈L570-578): transport/path/token/pid/cwd/fdAvailable/serverVersion
  - ASSERT: every referenced value is host-agnostic — process.pid, ctx.cwd, module-level `let`s, node builtins (net/crypto/fs/os/path), and local helpers (getFdAvailable, BRIDGE_VERSION). NO `@earendil-works` value resolution; NO host-specific API (e.g. no omp-only call).
  - RECORD: file:line + PASS/FAIL + the field list

Task 4: VERIFY claim (D) — package.json manifest key is "pi"
  - RUN: grep -nA3 '"pi"' package.json
  - ASSERT: a top-level `"pi": { "extensions": ["./extension/pi-nvim-bridge.ts"] }` block (NOT nested; NOT "omp")
  - NOTE: absence of an "omp" key is CORRECT (omp's `(pkg.omp ?? pkg.pi)` fallback reads "pi")
  - RECORD: file:line + PASS/FAIL

Task 5: VERIFY claim (E) — every @earendil-works/* import is `import type`
  - RUN (multiline-safe): see Validation Loop Level-1 perl scan
  - ASSERT: ZERO value imports flagged; every @earendil-works import line is `import type` (single-line) or the block starts with `import type {`
  - EXPECTED sites: pi-nvim-bridge.ts:135, 136-141; protocol.ts:23-26, 30-32 (4 total)
  - RECORD: the 4 sites + PASS/FAIL

Task 6: MODE A — JSDoc drift check on isInteractiveSession
  - READ the JSDoc block ABOVE the isInteractiveSession def (≈L1107-1133)
  - ASSERT it covers: pi `ctx.mode === "tui"`; omp removed ctx.mode / exposes ctx.hasUI; the silent-no-op root cause; the intersection-type workaround
  - IF DRIFTED from PRD §6.8: update the JSDoc to match (minimal edit, Mode A). IF NO DRIFT: record "no drift, no change".
  - RECORD: conclusion

Task 7: REGRESSION GATE — npm run typecheck
  - RUN: npm run typecheck
  - ASSERT: exit 0
  - IF a minimal fix was applied in Tasks 1-6: re-run; must still exit 0
  - RECORD: exit code

Task 8: EMIT verification report
  - WRITE the report (commit message or PR description) per the template in Validation Loop Level-4
  - NO code change committed unless a Task 1-6 gap was found and fixed
```

### Verification Patterns & Key Details

```typescript
// === Expected isInteractiveSession body (claim A) ===
function isInteractiveSession(ctx: ExtensionContext): boolean {
	return (
		ctx.mode === "tui" ||
		(ctx as ExtensionContext & { hasUI?: boolean }).hasUI === true
	);
}
// Both branches MUST be present. The intersection cast `(ctx as ExtensionContext & { hasUI?: boolean })`
// is REQUIRED — `hasUI` is not on pi's `ExtensionContext` type, so a bare `ctx.hasUI`
// would be a typecheck error. If you see a bare `ctx.hasUI`, that is BOTH a type
// hole AND a claim-(A) regression.

// === Expected session_start ordering (claim B) — guard FIRST ===
pi.on("session_start", (event: SessionStartEvent, ctx: ExtensionContext) => {
	/* ...JSDoc... */
	if (!isInteractiveSession(ctx)) return;   // <-- must be before the next two
	captureProvider(ctx);
	startBridge(ctx);
	// ...
});

// === Expected descriptor (claim C) — host-agnostic fields only ===
process.env[BRIDGE_ENV] = JSON.stringify({
	transport: "unix",
	path: socketPath,          // module-level let (join(tmpdir(), ...sock))
	token,                     // module-level let (randomUUID-derived)
	pid: process.pid,          // node global — works under Node AND Bun
	cwd: ctx.cwd,              // from the event ctx
	fdAvailable: getFdAvailable(),   // local helper
	serverVersion: BRIDGE_VERSION,   // local const "0.1.0"
} satisfies BridgeDescriptor);
// If ANY field resolved a @earendil-works value at runtime or called an
// omp-only API, claim (C) FAILS — flag and minimally fix.
```

### Integration Points

```yaml
NO integration changes. Read-only verification.
  - The only "integration" is re-running `npm run typecheck` (the project's
    existing `tsc --noEmit -p extension/tsconfig.json` gate).
  - If (and only if) a minimal fix is applied, it must not change the public
    extension surface (default export, exported handler fns, BridgeDescriptor
    shape) — this task must not ripple into Component B (the Neovim plugin).
```

## Validation Loop

### Level 1: Syntax & Type (the regression gate)

```bash
# Claim (E) — multiline-safe scan for @earendil-works VALUE imports.
# Flags any @earendil-works import whose `import` is NOT `import type`.
perl -0777 -ne 'while(/^(import\s+(?:type\s+)?[\{a-zA-Z][^;]*?)\s+from\s+"\@earendil-works[^"]*"\s*;/gms){ print "VALUE IMPORT (missing type): $1\n" if $1 !~ /^\s*import\s+type\b/ }' extension/*.ts
# Expected: NO output. Any line printed => claim (E) FAIL => minimally convert to `import type`.

# List every @earendil-works import site (manual confirm each is type-only)
grep -rnE '@earendil-works' extension/*.ts
# Expected: 4 sites — pi-nvim-bridge.ts:135 & 136-141; protocol.ts:23-26 & 30-32 — all `import type`.

# The regression gate itself
npm run typecheck
# Expected: exit 0, no output. This is THE gate for "no regression".
```

### Level 2: Claim (A) + (B) — control-flow verification

```bash
# Claim (A): isInteractiveSession has both branches
grep -nE 'function isInteractiveSession' extension/pi-nvim-bridge.ts
# then read ±10 lines: must contain `ctx.mode === "tui"` AND `.hasUI === true`

# Claim (B): ordering — guard < capture < bridge, all inside session_start
grep -nE 'pi\.on\("session_start"|isInteractiveSession\(ctx\)|captureProvider\(ctx\)|startBridge\(ctx\)' extension/pi-nvim-bridge.ts
# Expected line ordering: on("session_start") < guard < captureProvider < startBridge
# (read the handler block to confirm all three are inside it, not elsewhere)
```

### Level 3: Claim (C) + (D) — descriptor + manifest

```bash
# Claim (C): descriptor fields are host-agnostic
grep -nE 'process\.env\[BRIDGE_ENV\] = JSON\.stringify' extension/pi-nvim-bridge.ts
# read the object literal (~L570-578): transport/path/token/pid/cwd/fdAvailable/serverVersion
# confirm: only process.pid, ctx.cwd, module `let`s, node builtins, local helpers.

# Claim (D): manifest key
grep -nA3 '"pi"' package.json
# Expected:  "pi": {  /  "extensions": ["./extension/pi-nvim-bridge.ts"]  /  }
```

### Level 4: Report Generation (the deliverable)

```bash
# Emit the verification report into the commit message or PR description.
# Fill this template with the evidence captured in Levels 1-3:

cat <<'REPORT'
## P1.M1.T1.S1 — omp host-compat verification (PRD §6.8)

| # | Claim | Evidence (file:line) | Result |
|---|-------|----------------------|--------|
| A | isInteractiveSession accepts ctx.mode==="tui" AND ctx.hasUI===true | extension/pi-nvim-bridge.ts:<LN> | PASS/FAIL |
| B | session_start guard precedes captureProvider+startBridge | guard <LN>, capture <LN>, bridge <LN> | PASS/FAIL |
| C | startBridge descriptor is host-agnostic (no @earendil-works value / host API) | extension/pi-nvim-bridge.ts:<LN> | PASS/FAIL |
| D | package.json manifest key is "pi" (omp `(omp ?? pi)` fallback) | package.json:<LN> | PASS/FAIL |
| E | all @earendil-works/* imports are `import type`-only | 4 sites: <list> | PASS/FAIL |

- `npm run typecheck`: exit <0/nonzero>
- Mode A (isInteractiveSession JSDoc drift vs §6.8): <NO DRIFT — no change | DRIFT — updated>
- Code changes: <NONE — read-only verification | minimal fix to claim X>
REPORT
```

## Final Validation Checklist

### Technical Validation

- [ ] Claim (A) verified with content grep + read; result recorded.
- [ ] Claim (B) verified with line-ordering check inside `session_start`; result recorded.
- [ ] Claim (C) verified — descriptor fields all host-agnostic; result recorded.
- [ ] Claim (D) verified — `"pi"` manifest key present; result recorded.
- [ ] Claim (E) verified via multiline perl scan — zero value imports; result recorded.
- [ ] `npm run typecheck` exits 0 (baseline AND after any minimal fix).

### Feature Validation

- [ ] All 5 claims PASS (or any FAIL is fixed minimally and re-verified PASS).
- [ ] Verification report (Level-4 template) written to commit message / PR description.
- [ ] Mode-A JSDoc-drift check performed; result recorded.
- [ ] If a fix was applied, it does NOT change the public extension surface
      (default export, exported handlers, `BridgeDescriptor` shape) — no ripple
      into Component B.

### Code Quality Validation (only if a minimal fix was applied)

- [ ] Fix follows existing patterns (intersection cast for `hasUI`; `import type`).
- [ ] Fix is the SMALLEST possible change to close the gap — no refactors.
- [ ] No new runtime dependencies introduced (claim (C)/(E) invariants preserved).
- [ ] Indentation matches the file (TABs).

### Documentation & Deployment

- [ ] Verification report is self-contained (reproducible from the cited commands).
- [ ] If JSDoc was updated (Mode A), it now matches the PRD §6.8 divergence table.
- [ ] No env-var or install-path changes (this task changes none).

---

## Anti-Patterns to Avoid

- ❌ Don't hard-assert on line numbers (they drift) — verify by content grep, then read ±N lines.
- ❌ Don't use a single-line `grep '^import {'` for claim (E) — it misses multi-line
  imports; use the `perl -0777` multiline scan.
- ❌ Don't flag `import { createServer, type Server } from "node:net";` (L142) —
  it is from `node:net`, not `@earendil-works`. Claim (E) is scoped to `@earendil-works/*`.
- ❌ Don't "fix" the missing `"omp"` key in package.json — the `"pi"` key IS the
  omp fallback by design. Adding `"omp"` is out of scope and unnecessary.
- ❌ Don't implement the bridge, the socket server, or any new feature — this is
  read-only verification; a minimal fix is allowed ONLY for a verified gap.
- ❌ Don't skip `npm run typecheck` "because nothing changed" — it is the formal
  regression gate and must be recorded in the report.
- ❌ Don't pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — it hangs). This
  task needs only grep/read/tsc; no nvim is required.
- ❌ Don't widen a minimal fix into a refactor — close the gap with the smallest
  edit and re-run typecheck.