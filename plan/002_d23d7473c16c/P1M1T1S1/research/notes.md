# Research Notes — P1.M1.T1.S1 (Verify omp host-compat claims)

This is a **READ-ONLY VERIFICATION** task (not implementation). The extension
already exists and is fully implemented. The deliverable is a verification
report confirming 5 PRD §6.8 claims, plus `npm run typecheck` regression gate.
Minimal code change ONLY if a gap is found.

## Pre-verification result: ALL 5 CLAIMS PASS in current source (2025-07-31)

I verified each claim against the real source. Evidence captured below so the
implementer can re-confirm reproducibly. No fixes needed (as of this snapshot).

## Files in scope (all exist, at repo root)
- `extension/pi-nvim-bridge.ts` (1252 lines)
- `extension/protocol.ts`
- `extension/tsconfig.json` (dev type-check config)
- `package.json` (has `typecheck` script + `"pi"` manifest key)
- `plan/002_d23d7473c16c/architecture/research-extension-side.md` (cited; §2c
  documents isInteractiveSession at L1119-1138, guard at L1167)

## Claim-by-claim evidence (current line numbers — may drift; use content greps)

### (A) isInteractiveSession dual-detection — PASS
`extension/pi-nvim-bridge.ts:1134-1138`:
```ts
function isInteractiveSession(ctx: ExtensionContext): boolean {
	return (
		ctx.mode === "tui" ||
		(ctx as ExtensionContext & { hasUI?: boolean }).hasUI === true
	);
}
```
Accepts BOTH `ctx.mode === "tui"` (pi) AND `ctx.hasUI === true` (omp). The
`hasUI` read uses a localized intersection type (pi's `ExtensionContext` lacks
`hasUI`) so typecheck stays clean against pi's types.

### (B) session_start guard BEFORE captureProvider/startBridge — PASS
`extension/pi-nvim-bridge.ts:1142` handler, `:1167` guard, `:1172-1173` work:
```ts
pi.on("session_start", (event: SessionStartEvent, ctx: ExtensionContext) => {
	... // JSDoc explaining TUI-only gate
	if (!isInteractiveSession(ctx)) return;   // L1167 — GUARD
	...
	captureProvider(ctx);   // L1172 — AFTER guard
	startBridge(ctx);       // L1173 — AFTER guard
```
Order: guard (1167) → capture (1172) → bridge (1173). Correct.

### (C) startBridge descriptor is host-agnostic — PASS
`extension/pi-nvim-bridge.ts:526` `export function startBridge(ctx)`, descriptor
write at `:570-578`:
```ts
process.env[BRIDGE_ENV] = JSON.stringify({
	transport: "unix",
	path: socketPath,
	token,
	pid: process.pid,
	cwd: ctx.cwd,
	fdAvailable: getFdAvailable(),
	serverVersion: BRIDGE_VERSION,
} satisfies BridgeDescriptor);
```
Uses ONLY: `process.pid`, `ctx.cwd`, module-level `let`s (socketPath/token),
node builtins (via `__deps`/`join`/`tmpdir`/`randomUUID`), and
`getFdAvailable()`/`BRIDGE_VERSION` (local helpers). NO `@earendil-works`
value resolution, NO host-specific API call. `process.env` writes + `net` +
`crypto` + `fs` + `os` + `path` all work under both Node (pi) and Bun (omp).
=> Host-agnostic by construction. CONFIRMED.

### (D) package.json manifest key is "pi" (omp fallback) — PASS
`package.json` (root), the manifest block:
```json
"pi": {
	"extensions": ["./extension/pi-nvim-bridge.ts"]
}
```
Key is literally `"pi"`. omp reads `(pkg.omp ?? pkg.pi).extensions` — `pkg.omp`
is absent so it falls back to `pkg.pi` and discovers the extension unchanged.

### (E) every @earendil-works/* import is `import type`-only — PASS
Robust multiline perl check (`/^(import\s+(?:type\s+)?...from "@earendil-works/`
with "VALUE IMPORT" flag when not `import type`): **0 value imports**.
All 4 import sites:
- `pi-nvim-bridge.ts:135`  `import type { AutocompleteProvider, AutocompleteItem } from "@earendil-works/pi-tui";`
- `pi-nvim-bridge.ts:136-141`  `import type { ExtensionAPI, ExtensionContext, SessionStartEvent, SessionShutdownEvent } from "@earendil-works/pi-coding-agent";`
- `protocol.ts:23-26`  `import type { ... } from "@earendil-works/pi-tui";`
- `protocol.ts:30-32`  `import type { ... } from "@earendil-works/pi-tui";`
=> All type-only → erased at load (jiti Node / Bun) → no runtime resolution of
a package omp lacks.

## Mode A — JSDoc drift check (isInteractiveSession JSDoc) — NO DRIFT
The JSDoc above isInteractiveSession (`pi-nvim-bridge.ts:1107-1133`) covers:
- pi sets `ctx.mode === "tui"` ✓
- omp REMOVED `ctx.mode`, exposes `ctx.hasUI: boolean` ✓
- root cause (silent no-op, `PI_NVIM_BRIDGE` never advertised) ✓
- localized intersection type workaround ✓
This matches PRD §6.8 divergence table and §6.6. **No drift → no doc change.**

## Baseline typecheck — PASSES
`npm run typecheck` → `tsc --noEmit -p extension/tsconfig.json` → **exit 0**.
This is the regression gate; the implementer re-runs it after any (unexpected)
minimal fix to confirm no regression.

## Verification commands (reproducible, content-based — robust to line drift)
A: `grep -nE 'function isInteractiveSession' extension/pi-nvim-bridge.ts` then read ±8 lines → expect both `ctx.mode === "tui"` and `hasUI === true`.
B: `grep -nE 'isInteractiveSession\(ctx\)|captureProvider\(ctx\)|startBridge\(ctx\)' extension/pi-nvim-bridge.ts` → expect guard line number < capture line number < bridge line number.
C: read `startBridge` descriptor block (grep `process.env\[BRIDGE_ENV\] = JSON.stringify`) → only host-agnostic fields.
D: `grep -nA2 '"pi"' package.json` → `{"extensions":["./extension/pi-nvim-bridge.ts"]}`.
E: `grep -rnE '@earendil-works' extension/*.ts` → every hit is inside an `import type` (robust: perl multiline scan).
Gate: `npm run typecheck` → exit 0.

## Report format
Implementer fills a 5-row table (claim | evidence file:line | PASS/FAIL) +
typecheck exit + Mode A drift conclusion, emitted in commit message / PR desc.