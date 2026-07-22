# PRP — P4.M12.T31.S47: Optional `NVIM_APPNAME` minimal-config optimization

## Goal

**Feature Goal**: Add a **documented, opt-in** optimization to the
`pi-editor-bridge` extension: when the user enables it, the extension sets
`process.env.NVIM_APPNAME` to a configurable appname (default `"pi-editor"`)
inside pi's process **before** pi spawns `$EDITOR`, so the pi-launched Neovim
boots with a tiny dedicated config (`~/.config/pi-editor/`) that loads only
`pi-bridge.nvim` — dramatically faster editor startup than the user's full
config. Off by default (zero behavior change); polite save/restore of any
pre-existing user `NVIM_APPNAME`.

**Deliverable**:
- Modify `extension/pi-editor-bridge.ts`:
  - Add constants `NVIM_APPNAME_ENV = "NVIM_APPNAME"`,
    `NVIM_APPNAME_OPTIN_ENV = "PI_EDITOR_NVIM_APPNAME"`,
    `DEFAULT_NVIM_APPNAME = "pi-editor"`.
  - Add + export a pure resolver `resolveNvimAppname(): string | undefined`
    that reads `PI_EDITOR_NVIM_APPNAME` and returns `undefined` (opt-in OFF),
    `DEFAULT_NVIM_APPNAME` (empty / `1`/`true`/`yes`/`on`), or the literal
    string (custom appname).
  - Add module state `nvimAppnameApplied`/`nvimAppnameBaseline` + an
    `applyNvimAppname()` (capture baseline, set env) /
    `restoreNvimAppname()` (restore baseline) pair, and a
    `__resetNvimAppnameStateForTest()` seam.
  - Wire `applyNvimAppname()` into `startBridge` (AFTER the existing
    `PI_NVIM_BRIDGE` write) and `restoreNvimAppname()` into `stopBridge`
    (near the existing `delete process.env[BRIDGE_ENV]`).
  - Add [Mode A] JSDoc on the apply call explaining the
    process.env-inheritance discovery, the save/restore rationale, and
    opt-in semantics.
- Create `extension/tests/nvim-appname.test.ts` — value-table resolver tests,
  apply/restore lifecycle, opt-in-OFF is a no-op, baseline-save/restore with a
  pre-existing user value, idempotent re-apply across two startBridge calls,
  TUI-guard (non-tui never applies), and the default-appname branch.
- Update `README.md` — rewrite the existing "Optional startup optimization"
  paragraph to document `PI_EDITOR_NVIM_APPNAME` (the var the bridge reads),
  list the value table, give the `~/.config/pi-editor/` minimal-config example,
  and keep the manual `NVIM_APPNAME=pi-editor` alternative for users who prefer
  not to use the extension opt-in.

**Success Definition**:
- With `PI_EDITOR_NVIM_APPNAME` unset, the extension is **byte-for-byte
  identical** to today: `process.env.NVIM_APPNAME` is never read or written by
  the bridge, and every existing suite (`bridge-env`, `bridge-lifecycle`,
  `bridge-lifecycle-wiring`, `mode-guard`, …) passes unchanged.
- With `PI_EDITOR_NVIM_APPNAME=1`, after `startBridge(tui-ctx)`,
  `process.env.NVIM_APPNAME === "pi-editor"`; after `stopBridge()`, it is
  restored to whatever it was before (undefined if the user had none).
- With `PI_EDITOR_NVIM_APPNAME=pi-fast`, `process.env.NVIM_APPNAME ===
  "pi-fast"` after `startBridge`.
- A pre-existing user `NVIM_APPNAME=work` is **restored intact** after
  `stopBridge` (NOT clobbered/deleted) — the key correctness property that
  distinguishes this from a naive `delete`.
- `tsc --noEmit -p extension/tsconfig.json` exits 0; the `BridgeDescriptor`
  written to `PI_NVIM_BRIDGE` still has EXACTLY 7 keys (NVIM_APPNAME is a
  separate `process.env` entry, NOT a new descriptor field).
- No source file other than `extension/pi-editor-bridge.ts` is touched; no
  `tsconfig` edit (the `tests/**/*.ts` glob auto-includes the new test).

## Why

- **PRD §10.4** explicitly lists this as the Phase-4 "minimal-config
  optimization": *"the bridge extension may additionally set
  `process.env.NVIM_APPNAME = "pi-editor"` (documented opt-in), and the user
  maintains a tiny `~/.config/pi-editor/` that loads only `pi-bridge.nvim`.
  This is an optional optimization, not required."* This task ships that line.
- **Startup latency matters for the editor loop.** pi re-reads the temp file
  only after the editor exits (PRD §2.1), and a heavy daily-driver Neovim
  config (LSP servers, lazy-loaded plugins, plugin-manager boot) can add
  hundreds of milliseconds-to-seconds to every Ctrl+G launch. A minimal
  `pi-editor` config that loads ONLY the dependency-free `pi-bridge.nvim`
  (PRD §7.5 — "the primary UX … must work with a stock Neovim and no plugin
  manager") makes the external-editor round-trip feel instant.
- **It must be opt-in.** Blindly setting `NVIM_APPNAME` globally would hijack
  the user's own Neovim profile system; doing it only inside pi's process, only
  when asked, scoped to the launched child, and **restored** on shutdown is the
  well-behaved design.
- **It reuses the proven discovery.** pi spawns `$EDITOR` with
  `stdio:"inherit"` and NO `env:` override (interactive-mode.ts:3811-3816,
  established in S16) — the same `process.env`-inheritance seam that delivers
  `PI_NVIM_BRIDGE` to the child delivers `NVIM_APPNAME` too. Zero new IPC.
- **Closes P4.M12.T31** (the last "Researching" item in the plan). The two
  sibling sources (blink.cmp S45, nvim-cmp S46) are already Complete; this is
  the remaining optimization + its docs.

## What

User-visible behavior: when the user opts in (sets `PI_EDITOR_NVIM_APPNAME` in
their shell/pi-launch environment) AND maintains a `~/.config/pi-editor/`
config, the Neovim pi opens via Ctrl+G uses THAT config (fast, minimal) instead
of their default `~/.config/nvim/`. When opted out (default), nothing changes
at all — the bridge never touches `NVIM_APPNAME`.

Technical requirement: a tiny, self-contained `process.env` save/restore in
`startBridge`/`stopBridge`, gated on a dedicated opt-in env var whose value
selects either the default appname (`"pi-editor"`) or a custom one.

### Success Criteria

- [ ] Opt-in OFF (var unset) ⇒ `applyNvimAppname()` is a no-op; `NVIM_APPNAME`
      is never read or written; all existing suites pass unchanged.
- [ ] Opt-in ON (`=1` / `=true` / `=yes` / `=on` / `=""`) ⇒
      `process.env.NVIM_APPNAME === "pi-editor"` after `startBridge`.
- [ ] Opt-in ON with a custom value (`=pi-fast`) ⇒
      `process.env.NVIM_APPNAME === "pi-fast"` after `startBridge`.
- [ ] A pre-existing user `NVIM_APPNAME=<X>` is restored to `<X>` (or deleted
      if `<X>` was undefined) after `stopBridge` — never clobbered.
- [ ] Idempotent across two `startBridge` calls (S16 TEST-3 analogue): the
      baseline captured on the 2nd apply is the genuine environment baseline
      (NOT the bridge's own prior override), because `startBridge` calls
      `stopBridge` first.
- [ ] Non-TUI `session_start` never applies (the existing `ctx.mode !== "tui"`
      guard at the top of `session_start` short-circuits before `startBridge`).
- [ ] `BridgeDescriptor` still has EXACTLY 7 keys (NVIM_APPNAME is NOT a new
      descriptor field — it is its own `process.env` entry).
- [ ] `tsc --noEmit` exits 0; no `tsconfig` edit.
- [ ] README documents `PI_EDITOR_NVIM_APPNAME` (value table + minimal-config
      example) and keeps the manual `NVIM_APPNAME=pi-editor` alternative.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ the implementer needs only this PRP + the one
source file (`extension/pi-editor-bridge.ts`) + the verified build/test
commands. Every pattern (`__deps` seam, module-level state + test seams,
`startBridge`/`stopBridge` symmetry, `process.env` manipulation, the S16
`PI_NVIM_BRIDGE` write site, the `node:test` + jiti test idiom) is reproduced
or cited with exact anchors. The one external fact (NVIM_APPNAME semantics) is
summarized with a `:help` URL.

### Documentation & References

```yaml
# MUST READ before editing
- url: https://neovim.io/doc/user/starting.html#$NVIM_APPNAME
  why: "Authoritative NVIM_APPNAME semantics. Setting $NVIM_APPNAME=foo makes
        Nvim read $XDG_CONFIG_HOME/foo instead of $XDG_CONFIG_HOME/nvim; it
        replaces the 'nvim' segment in EVERY stdpath() path (config/data/state/
        log/shada) on all platforms. nvim starts cleanly (no error) if the dir
        is absent."
  critical: "nvim rejects an appname containing a path separator. We do NOT
             validate this in the bridge (out of scope; nvim surfaces the
             error) — document it as a gotcha. The appname must be a simple
             directory name."

- file: extension/pi-editor-bridge.ts
  why: "The ONLY source file to modify. Read: the constants cluster
        (BRIDGE_VERSION, BRIDGE_ENV, GET_SUGGESTIONS_TIMEOUT_MS) where the new
        NVIM_APPNAME_* constants go; `startBridge(ctx)` (the env write is its
        LAST block — the new applyNvimAppname() call goes right after the
        `process.env[BRIDGE_ENV] = JSON.stringify(...)` write); `stopBridge()`
        (the restoreNvimAppname() call goes near the existing
        `delete process.env[BRIDGE_ENV]` line); the `__setFdAvailableForTest`
        / `__setCwdForTest` seam idiom (mirror it for
        __resetNvimAppnameStateForTest); and the default-export factory's
        session_start (which is where the TUI guard lives — the apply inherits
        it because startBridge is only called in the tui branch)."
  pattern: "module-level `let` state + getters/seams; export const constants
            UPPER_SNAKE; [Mode A] JSDoc inline with the code; idempotent
            startBridge (calls stopBridge first)."
  gotcha: "NVIM_APPNAME is a SEPARATE process.env entry from PI_NVIM_BRIDGE.
           Do NOT add it to the BridgeDescriptor (that object must stay 7 keys
           — bridge-env.test.ts TEST 1 pins Object.keys(desc).length===7)."

- file: extension/tests/bridge-env.test.ts
  why: "The S16 suite — the EXACT pattern to mirror for nvim-appname.test.ts:
        node:test + assert/strict; a mockDeps() helper (snapshot+restore
        __deps.createServer/chmodSync via the fakeServer); the
        captureHandlers()/fakePi pattern for the factory-wiring (TUI vs non-tui)
        test; EVERY test tears down in `finally` (restore __deps, reset fd
        cache, stopBridge) because process.env is shared across tests in one
        process (GOTCHA #6 in the S16 PRP). Reuse makeFakeServer/mockDeps
        verbatim."
  pattern: "assert.equal(typeof process.env[X], 'string'|'undefined');
            JSON.parse round-trip; `try { … } finally { restore; stopBridge(); }`."

- file: README.md
  why: "Contains the EXISTING 'Optional startup optimization' paragraph (in the
        'Configuration (`$EDITOR`)' section) that currently tells users to set
        NVIM_APPNAME manually. This task REWRITES that paragraph to document
        the bridge's new PI_EDITOR_NVIM_APPNAME opt-in (the idiomatic path)
        while keeping the manual alternative. Scoped docs change — the full
        README rewrite is a separate task (P3.M11.T28.S44)."
  pattern: " fenced code blocks for env exports; > blockquote callouts for
            gotchas; matches the existing troubleshooting/Security section tone."

- docfile: plan/001_c56962b4fa17/P4M12T31S47/research/notes.md
  why: "Full research for this task: the opt-in-mechanism decision (§1, with
        pi's own PI_CLEAR_ON_SHRINK/PI_HARDWARE_CURSOR env-var-toggle
        precedent), NVIM_APPNAME semantics (§2), the SAVE/RESTORE rationale
        (§3), TUI-guard inheritance (§4), testability (§5), verified validation
        commands (§6), scope guards (§7)."
  section: "§1.3 (resolver value table — copy into resolveNvimAppname tests);
            §3 (the save/restore state machine — copy into apply/restore);
            §6 (exact test commands)."

- docfile: plan/001_c56962b4fa17/P1M3T8S16/PRP.md
  why: "The sibling 'env advertisement' PRP (S16) — the structural template
        this PRP mirrors. Its GOTCHAs (#1–#7) about process.env being shared
        across tests, jiti not live-binding `export let`, JSON.stringify-then-
        assign, and idempotent teardown ALL apply here unchanged."
```

### Current Codebase tree (relevant slice)

```bash
extension/
  pi-editor-bridge.ts          # MODIFY: add NVIM_APPNAME_* constants, resolver, apply/restore, wire into start/stopBridge, [Mode A] JSDoc
  protocol.ts                  # READ-ONLY (BridgeDescriptor UNCHANGED — stays 7 keys)
  connection.ts                # READ-ONLY
  jsonl-reader.ts              # READ-ONLY
  tsconfig.json                # READ-ONLY (tests/**/*.ts glob auto-includes the new test)
  tests/
    nvim-appname.test.ts       # CREATE (new suite)
    bridge-env.test.ts         # READ-ONLY (pattern source; must stay green)
    bridge-lifecycle.test.ts   # READ-ONLY (regression)
    bridge-lifecycle-wiring.test.ts  # READ-ONLY (regression)
    mode-guard.test.ts         # READ-ONLY (regression)
    ... (S7–S17 suites)        # READ-ONLY (regression)
README.md                      # MODIFY: rewrite the "Optional startup optimization" paragraph
```

### Desired Codebase tree with files to be added/modified

```bash
extension/
  pi-editor-bridge.ts          # MODIFIED (constants + resolver + apply/restore + wiring + JSDoc)
  tests/
    nvim-appname.test.ts       # NEW — ~7 tests (resolver table + apply/restore lifecycle)
README.md                      # MODIFIED (one paragraph + example block)
```

### Known Gotchas of our codebase & Library Quirks

```typescript
// GOTCHA #1 — NVIM_APPNAME is NOT owned by pi; do SAVE/RESTORE, never plain delete.
// PI_NVIM_BRIDGE (S16) is a name pi invents, so `delete process.env[BRIDGE_ENV]`
// on stop is correct & harmless. NVIM_APPNAME is a STANDARD Neovim var the USER may
// already export globally (e.g. NVIM_APPNAME=work). If stopBridge did
// `delete process.env.NVIM_APPNAME`, it would PERMANENTLY CLOBBER the user's global
// for the rest of the pi process (a real bug across /reload). MUST capture the
// baseline at apply time and RESTORE it (write-back or delete-if-was-undefined) at
// restore time. See Implementation Patterns for the exact state machine.

// GOTCHA #2 — opt-in must be OFF by default (regression safety).
// With PI_EDITOR_NVIM_APPNAME unset, applyNvimAppname() returns IMMEDIATELY and
// touches NOTHING. This guarantees bridge-env.test.ts (S16) and every other
// startBridge/stopBridge caller is byte-identical to today. NVIM_APPNAME must NOT
// appear in the BridgeDescriptor (it stays its own process.env entry) — so the S16
// TEST-1 assertion Object.keys(desc).length===7 still holds.

// GOTCHA #3 — capture the baseline AFTER stopBridge's restore, not before.
// startBridge's first line is stopBridge(). stopBridge calls restoreNvimAppname()
// (which writes the baseline back / deletes the override). So by the time the
// applyNvimAppname() call later in startBridge reads process.env.NVIM_APPNAME, any
// prior bridge override is already gone and the value is the genuine environment
// baseline. Two startBridge calls therefore capture the SAME baseline both times
// (verified — see research §3). Do NOT move the capture above stopBridge or you'll
// re-capture the bridge's own prior override.

// GOTCHA #4 — process.env assignment coerces; strings only.
// `process.env[X] = obj` becomes "[object Object]". Here we only ever assign
// strings (the resolved appname) or the captured baseline (already a string|undefined),
// so this is fine — but never assign a non-string. `delete process.env[X]` is a safe
// no-op when absent (idempotent).

// GOTCHA #5 — jiti does NOT live-bind `export let` reassignment.
// (Established in S2/S16.) This is why state is exposed via getters/seams, not
// re-exported `let`. The new nvimAppnameApplied/nvimAppnameBaseline are MODULE-LOCAL
// `let`s mutated in place by apply/restore; tests inspect them via process.env (the
// real observable) + the __resetNvimAppnameStateForTest() seam — NOT by importing the
// `let`s (which would snapshot stale).

// GOTCHA #6 — process.env is SHARED across tests in one node:test process.
// (S16 GOTCHA #6.) Every test MUST, in a `finally`: restore __deps, reset the fd
// cache, __resetNvimAppnameStateForTest(), delete BOTH process.env.NVIM_APPNAME and
// process.env.PI_EDITOR_NVIM_APPNAME, and stopBridge(). Without this, test 1's opt-in
// value leaks into test 2's "OFF" assertion.

// GOTCHA #7 — NO tsconfig edit. The `include: ["tests/**/*.ts"]` glob (S16 GOTCHA #7)
// auto-includes nvim-appname.test.ts. `tsc --noEmit -p extension/tsconfig.json` exits
// 0 today — keep it that way.

// GOTCHA #8 — TUI guard inheritance. Place applyNvimAppname() INSIDE startBridge
// (NOT in a separate session_start hook). session_start's top line is
// `if (ctx.mode !== "tui") return;` (S3) — so startBridge (and thus the apply) is
// reached ONLY in tui mode. The editor is launched only in tui anyway. stopBridge's
// restore is unconditional (safe no-op when not applied). bridge-env.test.ts TEST 4
// (non-tui never sets the env) continues to pass.

// GOTCHA #9 — invalid appnames are nvim's problem, not ours. nvim rejects an appname
// with a path separator (e.g. PI_EDITOR_NVIM_APPNAME=../evil). We do NOT validate
// (scope creep for a 0.5-pt task; nvim surfaces a clear error to the editor). Document
// the constraint in README; do not silently swallow it.
```

## Implementation Blueprint

### Data models and structure

No wire/protocol types change. `BridgeDescriptor` (`protocol.ts` §B) is
**untouched** — it stays the 7-key object S16 ships. The new state is purely
module-local:

```typescript
// === New module-level state (extension/pi-editor-bridge.ts) ===

/** The standard Neovim env var the spawned $EDITOR reads to pick its config dir. */
export const NVIM_APPNAME_ENV = "NVIM_APPNAME";
/**
 * The opt-in env var THIS extension reads. Absent ⇒ feature OFF (zero behavior
 * change). Set to "" / "1" / "true" / "yes" / "on" (case-insensitive) ⇒ use
 * {@link DEFAULT_NVIM_APPNAME}. Any other non-empty string ⇒ that literal appname.
 */
export const NVIM_APPNAME_OPTIN_ENV = "PI_EDITOR_NVIM_APPNAME";
/** Default appname when the opt-in is a truthy sentinel (PRD §10.4: "pi-editor"). */
export const DEFAULT_NVIM_APPNAME = "pi-editor";

/**
 * SAVE/RESTORE state for NVIM_APPNAME (GOTCHA #1). `nvimAppnameApplied` is true
 * iff the bridge currently has an override active; `nvimAppnameBaseline` is the
 * user's pre-bridge value (string) or `undefined` (the user had none). Both are
 * mutated ONLY by {@link applyNvimAppname} / {@link restoreNvimAppname}.
 */
let nvimAppnameApplied = false;
let nvimAppnameBaseline: string | undefined;

/**
 * Pure resolver for the opt-in. Reads PI_EDITOR_NVIM_APPNAME and returns:
 *  - undefined  → opt-in OFF (applyNvimAppname does nothing)
 *  - "pi-editor" (DEFAULT_NVIM_APPNAME) → empty / 1 / true / yes / on
 *  - <literal>  → any other non-empty string (custom appname)
 * Exported so the value table is unit-testable without startBridge.
 */
export function resolveNvimAppname(): string | undefined {
	const raw = process.env[NVIM_APPNAME_OPTIN_ENV];
	if (raw === undefined) return undefined; // opt-in OFF (default)
	const trimmed = raw.trim();
	if (trimmed === "" || /^(1|true|yes|on)$/i.test(trimmed)) {
		return DEFAULT_NVIM_APPNAME;
	}
	return trimmed; // custom appname literal
}

/**
 * Apply the NVIM_APPNAME opt-in (if enabled) by capturing the current
 * NVIM_APPNAME baseline and overriding it with the resolved appname. NO-OP when
 * the opt-in is off (GOTCHA #2). Called at the END of startBridge, AFTER the
 * PI_NVIM_BRIDGE descriptor write.
 */
function applyNvimAppname(): void {
	const appname = resolveNvimAppname();
	if (appname === undefined) return; // opt-in OFF → touch nothing
	nvimAppnameBaseline = process.env[NVIM_APPNAME_ENV]; // capture the genuine baseline (stopBridge already restored)
	process.env[NVIM_APPNAME_ENV] = appname;
	nvimAppnameApplied = true;
}

/**
 * Restore the NVIM_APPNAME baseline captured by {@link applyNvimAppname}. NO-OP
 * when no override is active (safe to call unconditionally). Writes the baseline
 * back, or deletes the var if the baseline was undefined (GOTCHA #1 — NEVER
 * clobber a pre-existing user value). Called from stopBridge.
 */
function restoreNvimAppname(): void {
	if (!nvimAppnameApplied) return;
	if (nvimAppnameBaseline === undefined) {
		delete process.env[NVIM_APPNAME_ENV];
	} else {
		process.env[NVIM_APPNAME_ENV] = nvimAppnameBaseline;
	}
	nvimAppnameApplied = false;
	nvimAppnameBaseline = undefined;
}

/** Test seam: zero the apply/restore state (parallels __setFdAvailableForTest). */
export function __resetNvimAppnameStateForTest(): void {
	nvimAppnameApplied = false;
	nvimAppnameBaseline = undefined;
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/pi-editor-bridge.ts — add the 3 constants
  - ADD (in the constants cluster, next to BRIDGE_ENV/BRIDGE_VERSION):
        export const NVIM_APPNAME_ENV = "NVIM_APPNAME";
        export const NVIM_APPNAME_OPTIN_ENV = "PI_EDITOR_NVIM_APPNAME";
        export const DEFAULT_NVIM_APPNAME = "pi-editor";
  - NAMING: UPPER_SNAKE matching BRIDGE_ENV/BRIDGE_VERSION/GET_SUGGESTIONS_TIMEOUT_MS.
  - PLACEMENT: constants cluster, before `let server`. Export all three (tests + the
          manual alternative reference them by name; a future rename is one-line).

Task 2: MODIFY extension/pi-editor-bridge.ts — add the resolver + apply/restore + seam
  - ADD (near the other module-level state + __set*CwdForTest/__setFdAvailableForTest
          seam cluster): the resolveNvimAppname() function, the
          nvimAppnameApplied/nvimAppnameBaseline `let` state, applyNvimAppname() /
          restoreNvimAppname() (module-private, NOT exported — they are wired into
          start/stopBridge only), and __resetNvimAppnameStateForTest() (exported).
  - FOLLOW pattern: the resolveFdAvailable()/getFdAvailable()/__setFdAvailableForTest
          idiom (module `let` cache + pure-ish resolver + test seam). resolveNvimAppname
          is PURE (no caching — re-reads process.env each call; the opt-in can be
          changed between sessions, and it's called once per startBridge).
  - NAMING: camelCase functions; the apply/restore pair reads as a matched
          save/restore. DO NOT export apply/restore (start/stopBridge are their only
          callers; exporting invites misuse).
  - DEPENDENCIES: Task 1 (constants).

Task 3: MODIFY startBridge(ctx) — call applyNvimAppname() AFTER the PI_NVIM_BRIDGE write
  - ADD, as the FINAL statement of startBridge (immediately AFTER the existing
          `process.env[BRIDGE_ENV] = JSON.stringify({…} satisfies BridgeDescriptor);`
          line), a [Mode A] JSDoc block + the call:
        /**
         * [Mode A] Optional NVIM_APPNAME opt-in — minimal-config optimization (PRD §10.4).
         *
         * When the user sets PI_EDITOR_NVIM_APPNAME ("" / "1" / "true" / "yes" / "on"
         * ⇒ default "pi-editor"; any other non-empty string ⇒ that appname), override
         * process.env.NVIM_APPNAME so the pi-spawned $EDITOR (Neovim) boots with a tiny
         * dedicated config (~/.config/<appname>/) instead of the user's full ~/.config/nvim/.
         * DISCOVERY: same process.env-inheritance seam as PI_NVIM_BRIDGE above — pi
         * spawns the editor with stdio:"inherit" and no env override, so the child sees
         * this value. SAVE/RESTORE: unlike PI_NVIM_BRIDGE (which pi owns), NVIM_APPNAME
         * is a standard var the user may already export globally; we capture the baseline
         * here and restoreNvimAppname() (called from stopBridge) writes it back — we NEVER
         * clobber a pre-existing user value. OFF by default (resolveNvimAppname() returns
         * undefined when the opt-in var is unset → this is a pure no-op).
         */
        applyNvimAppname();
  - WHY HERE: (a) AFTER the descriptor write keeps the two env concerns visually grouped
          at the end of startBridge; (b) startBridge's first line is stopBridge() which
          calls restoreNvimAppname(), so by this point any prior override is already
          restored and the baseline capture reads the genuine environment (GOTCHA #3);
          (c) placing it inside startBridge (not a separate session_start hook) inherits
          the TUI guard (GOTCHA #8).
  - DEPENDENCIES: Task 2.
  - PRESERVE: everything above (stopBridge() first-line teardown, token/socketPath gen,
          createServer, server.on("error"), listen, chmod, the PI_NVIM_BRIDGE write).

Task 4: MODIFY stopBridge() — call restoreNvimAppname()
  - ADD, near the existing `delete process.env[BRIDGE_ENV];` line (either immediately
          before or after — order is irrelevant; both are independent teardown steps):
        restoreNvimAppname(); // restore the user's pre-bridge NVIM_APPNAME (no-op if not applied)
  - WHY HERE: symmetric with the apply in startBridge; startBridge calls stopBridge first,
          so the restore runs before every re-apply (GOTCHA #3). Safe no-op when nothing
          was applied (the common opt-in-OFF case).
  - DEPENDENCIES: Task 2.
  - NOTE: do NOT add a `delete process.env.NVIM_APPNAME` (GOTCHA #1 — that would clobber
          the user's global). The restore writes the baseline back / deletes only if the
          baseline was undefined.

Task 5: CREATE extension/tests/nvim-appname.test.ts — ~7 tests (node:test + jiti)
  - IMPORTS: `startBridge, stopBridge, resolveNvimAppname,
          __resetNvimAppnameStateForTest, NVIM_APPNAME_ENV, NVIM_APPNAME_OPTIN_ENV,
          DEFAULT_NVIM_APPNAME, __deps, __setFdAvailableForTest` from
          `../pi-editor-bridge.ts`; default-import the factory for the wiring test;
          `ExtensionAPI/ExtensionContext/SessionStartEvent` types from
          @earendil-works/pi-coding-agent.
  - FOLLOW pattern: S16's bridge-env.test.ts verbatim — its makeFakeServer()/mockDeps()
          helper (snapshot+restore __deps.createServer/chmodSync) and the
          captureHandlers()/fakePi pattern for the factory-wiring (TUI vs non-tui) test.
          EVERY test tears down in `finally`: restore __deps, __setFdAvailableForTest(
          undefined), __resetNvimAppnameStateForTest(), delete BOTH
          process.env[NVIM_APPNAME_ENV] AND process.env[NVIM_APPNAME_OPTIN_ENV], and
          stopBridge() (GOTCHA #6).
  - TESTS:
    1. resolveNvimAppname() value table (PURE — no startBridge): unset→undefined;
       ""→"pi-editor"; "1"/"TRUE"/"yes"/"On"→"pi-editor"; "pi-fast"→"pi-fast";
       "  pi-editor  " (whitespace)→"pi-editor" (trim). Set/restore the opt-in env in
       a finally.
    2. apply lifecycle (opt-in ON, default): set PI_EDITOR_NVIM_APPNAME=1; mockDeps;
       startBridge({cwd:"/test/proj"}) → assert process.env.NVIM_APPNAME ===
       "pi-editor". finally restores.
    3. apply lifecycle (custom appname): PI_EDITOR_NVIM_APPNAME=pi-fast; startBridge
       → process.env.NVIM_APPNAME === "pi-fast".
    4. opt-in OFF is a no-op: leave PI_EDITOR_NVIM_APPNAME unset; startBridge →
       process.env.NVIM_APPNAME === undefined (or whatever it was) AND the existing
       bridge-env descriptor contract still holds (parse PI_NVIM_BRIDGE, 7 keys,
       serverVersion "0.1.0"). Proves no regression to S16.
    5. restore after stopBridge (no pre-existing baseline): PI_EDITOR_NVIM_APPNAME=1;
       startBridge → NVIM_APPNAME === "pi-editor"; stopBridge → NVIM_APPNAME ===
       undefined (was undefined before).
    6. SAVE/RESTORE a pre-existing user baseline (THE key correctness test): pre-set
       process.env.NVIM_APPNAME = "work"; PI_EDITOR_NVIM_APPNAME=1; startBridge →
       NVIM_APPNAME === "pi-editor"; stopBridge → NVIM_APPNAME === "work" (RESTORED,
       not deleted/clobbered).
    7. idempotent across two startBridge calls: PI_EDITOR_NVIM_APPNAME=1; pre-set
       NVIM_APPNAME="work"; startBridge → "pi-editor"; startBridge again (internal
       stopBridge restores to "work", then re-applies) → "pi-editor"; stopBridge →
       "work". Proves the baseline capture on the 2nd apply reads the genuine
       environment, not the bridge's prior override (GOTCHA #3).
    8. (factory wiring / TUI guard) reuse bridge-env TEST 4's captureHandlers():
       PI_EDITOR_NVIM_APPNAME=1; session_start(tui) → NVIM_APPNAME === "pi-editor";
       session_shutdown → NVIM_APPNAME === undefined; for each non-tui mode
       ("rpc","json","print") session_start → NVIM_APPNAME stays undefined (TUI guard
       intact — GOTCHA #8).
  - COVERAGE: positive (apply default/custom), negative (opt-in OFF no-op), the
          correctness invariant (baseline save/restore), idempotency, and the TUI
          guard. That is the full surface.
  - PLACEMENT: extension/tests/nvim-appname.test.ts (matches tests/**/*.ts glob →
          auto-included by tsconfig, NO tsconfig edit — GOTCHA #7).
  - DEPENDENCIES: Tasks 1–4.

Task 6: MODIFY README.md — rewrite the "Optional startup optimization" paragraph
  - LOCATE: the "Configuration (`$EDITOR`)" section's blockquote paragraph that
          currently reads (approx): *"Optional startup optimization: for a faster
          editor launch you may keep a minimal Neovim config at
          `~/.config/pi-editor/` and set `NVIM_APPNAME=pi-editor` in pi's
          environment so the editor instance loads only `pi-bridge.nvim`. This is
          optional, not required."*
  - REPLACE with a subsection that documents BOTH paths, lead with the bridge opt-in:
        - The bridge opt-in (recommended): set `PI_EDITOR_NVIM_APPNAME` (value
          table: unset=off; `1`/`true`/`yes`/`on`/`""` → "pi-editor"; any other
          non-empty string → that appname). The extension sets NVIM_APPNAME inside
          pi for the session and restores your prior value on exit (so your global
          NVIM_APPNAME, if any, is untouched).
        - The minimal config: create `~/.config/pi-editor/init.lua` that loads ONLY
          `pi-bridge.nvim` (stock Neovim, no plugin manager required — PRD §7.5).
          nvim starts cleanly even before you create it (just with no user config).
        - The manual alternative: users who prefer not to use the extension opt-in
          can `export NVIM_APPNAME=pi-editor` in the shell that launches pi (the
          child editor inherits it the same way).
        - Gotcha callout (> blockquote): the appname must be a simple directory
          name (no `/`); nvim rejects path separators.
  - DOCS MODE: user-facing README prose (NOT [Mode A] inline — that's Task 3's JSDoc).
  - SCOPE: edit ONLY this paragraph + add the example block. Do NOT rewrite other
          README sections (the full README pass is P3.M11.T28.S44).
  - DEPENDENCIES: Tasks 1–5 (so the documented behavior matches the shipped code).
```

### Implementation Patterns & Key Details

```typescript
// === The save/restore state machine (GOTCHA #1/#3) ===
// applyNvimAppname() — called at END of startBridge (after the PI_NVIM_BRIDGE write):
function applyNvimAppname(): void {
	const appname = resolveNvimAppname();
	if (appname === undefined) return; // opt-in OFF → NO-OP (GOTCHA #2)
	// startBridge's first line is stopBridge() → restoreNvimAppname(), so any prior
	// override is already gone and THIS reads the genuine environment baseline (GOTCHA #3).
	nvimAppnameBaseline = process.env[NVIM_APPNAME_ENV];
	process.env[NVIM_APPNAME_ENV] = appname; // string only (GOTCHA #4)
	nvimAppnameApplied = true;
}

// restoreNvimAppname() — called from stopBridge (near `delete process.env[BRIDGE_ENV]`):
function restoreNvimAppname(): void {
	if (!nvimAppnameApplied) return; // safe no-op when opt-in was off / nothing applied
	if (nvimAppnameBaseline === undefined) {
		delete process.env[NVIM_APPNAME_ENV]; // user had none → leave it absent
	} else {
		process.env[NVIM_APPNAME_ENV] = nvimAppnameBaseline; // RESTORE the user's value
	}
	nvimAppnameApplied = false;
	nvimAppnameBaseline = undefined;
}

// === startBridge tail (Task 3) — apply is the LAST line, after the descriptor write ===
export function startBridge(ctx: ExtensionContext): void {
	stopBridge(); // ← its restoreNvimAppname() runs FIRST → baseline is clean
	// …token, socketPath, createServer, server.on("error"), listen, chmod…
	/** [Mode A] PI_NVIM_BRIDGE advertisement (S16 — UNCHANGED) */
	process.env[BRIDGE_ENV] = JSON.stringify({ /* … 7 keys … */ } satisfies BridgeDescriptor);
	/** [Mode A] Optional NVIM_APPNAME opt-in — see Task 3 JSDoc */
	applyNvimAppname();
}

// === stopBridge (Task 4) — restore alongside the BRIDGE_ENV delete ===
export function stopBridge(): void {
	try { server?.close(); } catch { /* idempotent */ }
	closeAllConnections();
	if (socketPath) { try { rmSync(socketPath, { force: true }); } catch {} }
	server = undefined; socketPath = undefined; token = undefined;
	delete process.env[BRIDGE_ENV];      // S16 — pi owns this name
	restoreNvimAppname();                 // S47 — restore user's NVIM_APPNAME baseline
}
```

```typescript
// === Test pattern (TEST 6 — the key correctness invariant) ===
test("a pre-existing user NVIM_APPNAME is RESTORED after stopBridge (never clobbered)", () => {
	const mock = mockDeps();
	__setFdAvailableForTest(true);
	process.env[NVIM_APPNAME_ENV] = "work";           // user's global profile
	process.env[NVIM_APPNAME_OPTIN_ENV] = "1";        // opt in to the bridge override
	try {
		startBridge({ cwd: "/test/proj" } as ExtensionContext);
		assert.equal(process.env[NVIM_APPNAME_ENV], "pi-editor", "override active during session");

		stopBridge();
		assert.equal(
			process.env[NVIM_APPNAME_ENV],
			"work",
			"user baseline RESTORED — NOT deleted/clobbered (GOTCHA #1)",
		);
	} finally {
		__setFdAvailableForTest(undefined);
		__resetNvimAppnameStateForTest();
		delete process.env[NVIM_APPNAME_ENV];
		delete process.env[NVIM_APPNAME_OPTIN_ENV];
		mock.restore();
		stopBridge();
	}
});
```

### Integration Points

```yaml
ENVIRONMENT (process.env):
  - read:  "process.env.PI_EDITOR_NVIM_APPNAME (the opt-in; absent ⇒ OFF)"
  - write: "process.env.NVIM_APPNAME (the standard Neovim var the spawned $EDITOR
            reads) — set to the resolved appname in applyNvimAppname(); restored to
            the captured baseline in restoreNvimAppname()"
  - pattern: "SAVE-then-SET on apply; RESTORE-on-stop (NOT delete — GOTCHA #1).
            Matches pi's own PI_CLEAR_ON_SHRINK / PI_HARDWARE_CURSOR env-var-toggle
            idiom (settings-manager.ts) for the opt-in READ."

NO OTHER INTEGRATION POINTS:
  - DATABASE: none
  - CONFIG (settings.json): none — pi exposes no extension-config channel; the
            opt-in is the PI_EDITOR_NVIM_APPNAME env var (research §1)
  - ROUTES / RPC: none — NVIM_APPNAME is process.env only, NOT a BridgeDescriptor
            field and NOT an RPC method
  - TSCONFIG: none (tests/**/*.ts glob auto-includes the new test — GOTCHA #7)
  - PROTOCOL.TS: none (BridgeDescriptor stays 7 keys — NVIM_APPNAME is separate)
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Type-check the extension (VERIFIED: exits 0 today; must stay 0)
npx tsc --noEmit -p extension/tsconfig.json
# Expected: zero output, exit 0. If errors: READ them. Likely causes: a typo in a
# constant name, or accidentally importing apply/restore (they are NOT exported).
# The BridgeDescriptor write is UNCHANGED, so no satisfies-guard regression.

# (No ruff/mypy — TypeScript extension. tsc IS the linter+type-checker.)
```

### Level 2: Unit Tests (Component Validation)

```bash
# The jiti register path (VERIFIED to exist):
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs

# NEW suite — the deliverable
node --import "$JITI_REG" extension/tests/nvim-appname.test.ts
# Expected: "ℹ fail 0" (~7-8 tests pass — reporter is node:test).

# Regression suites — MUST stay green (they call startBridge/stopBridge)
node --import "$JITI_REG" extension/tests/bridge-env.test.ts          # S16 (descriptor still 7 keys)
node --import "$JITI_REG" extension/tests/bridge-lifecycle.test.ts    # S5
node --import "$JITI_REG" extension/tests/bridge-lifecycle-wiring.test.ts  # S6
node --import "$JITI_REG" extension/tests/mode-guard.test.ts          # S3 (TUI guard intact)
# Expected: each prints "ℹ fail 0". If bridge-env regresses, the cause is almost
# certainly that applyNvimAppname mutated NVIM_APPNAME with the opt-in OFF — recheck
# resolveNvimAppname()'s unset→undefined branch (GOTCHA #2) and the finally cleanup
# in nvim-appname.test.ts leaking into bridge-env.test.ts (GOTCHA #6).

# NOTE: jiti prints a benign "module.register() is deprecated" (DEP0205) on stderr — IGNORE.
```

### Level 3: Integration Testing (System Validation)

```bash
# Extension loads cleanly under pi (non-TUI → TUI guard returns BEFORE startBridge,
# so NO env var is written in --print mode; proves the apply is TUI-only too).
pi --no-extensions -e ./extension/pi-editor-bridge.ts --print "ok"
# Expected: exit 0, no error lines, "ok" echoed.

# Manual end-to-end (optional, requires a real TUI + nvim):
# 1. export PI_EDITOR_NVIM_APPNAME=1
# 2. mkdir -p ~/.config/pi-editor && echo 'require("pi-editor").setup({})' > ~/.config/pi-editor/init.lua
# 3. export EDITOR=nvim
# 4. pi            # then Ctrl+G
# 5. Inside the launched nvim: :lua print(vim.env.NVIM_APPNAME)  → "pi-editor"
#    and :echo stdpath("config")  → ~/.config/pi-editor
# (This is exercised fully by the Neovim-side activation work in P2.M4; S47's job
#  is the WRITE + restore, covered by the unit suite above.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Prove the opt-in value table round-trips the way resolveNvimAppname implements it:
node -e '
  const cases = [["","pi-editor"],["1","pi-editor"],["TRUE","pi-editor"],
                 ["yes","pi-editor"],["on","pi-editor"],["pi-fast","pi-fast"]];
  for (const [v,exp] of cases) {
    process.env.PI_EDITOR_NVIM_APPNAME = v;
    const raw = process.env.PI_EDITOR_NVIM_APPNAME;
    const trimmed = raw.trim();
    const out = (trimmed==="" || /^(1|true|yes|on)$/i.test(trimmed)) ? "pi-editor" : trimmed;
    console.log(JSON.stringify(v), "→", out, out===exp ? "OK" : "MISMATCH");
  }
  delete process.env.PI_EDITOR_NVIM_APPNAME;
  console.log("unset →", process.env.PI_EDITOR_NVIM_APPNAME === undefined ? "undefined (OFF)" : "BUG");
'
# Expected: every line "OK"; unset → "undefined (OFF)".
```

## Final Validation Checklist

### Technical Validation

- [ ] `npx tsc --noEmit -p extension/tsconfig.json` exits 0 (zero output).
- [ ] `node --import "$JITI_REG" extension/tests/nvim-appname.test.ts` → `ℹ fail 0`
      (all ~7-8 tests pass, incl. the baseline save/restore invariant TEST 6).
- [ ] All regression suites green: `bridge-env` (S16), `bridge-lifecycle` (S5),
      `bridge-lifecycle-wiring` (S6), `mode-guard` (S3).
- [ ] No tsconfig edit made (the `tests/**/*.ts` glob auto-includes the new test).
- [ ] No file other than `extension/pi-editor-bridge.ts` (source) +
      `extension/tests/nvim-appname.test.ts` (new) + `README.md` (one paragraph)
      is modified.

### Feature Validation

- [ ] Opt-in OFF (unset) ⇒ `NVIM_APPNAME` never read/written; existing suites pass
      unchanged (TEST 4).
- [ ] Opt-in ON (`1`/`true`/`yes`/`on`/`""`) ⇒ `process.env.NVIM_APPNAME ===
      "pi-editor"` after `startBridge` (TEST 2).
- [ ] Opt-in ON custom (`pi-fast`) ⇒ `process.env.NVIM_APPNAME === "pi-fast"`
      (TEST 3).
- [ ] Pre-existing user `NVIM_APPNAME=<X>` RESTORED after `stopBridge` — never
      clobbered/deleted (TEST 6 — GOTCHA #1).
- [ ] Idempotent across two `startBridge` calls; baseline re-captured cleanly
      (TEST 7 — GOTCHA #3).
- [ ] Non-TUI `session_start` never applies (TEST 8 — GOTCHA #8).
- [ ] `BridgeDescriptor` still EXACTLY 7 keys; `serverVersion === "0.1.0"` (TEST 4
      re-asserts the S16 contract — NVIM_APPNAME is NOT a descriptor field).

### Code Quality Validation

- [ ] Constants `NVIM_APPNAME_ENV` / `NVIM_APPNAME_OPTIN_ENV` /
      `DEFAULT_NVIM_APPNAME` exported + referenced by name in tests (no hardcoded
      strings).
- [ ] `applyNvimAppname()`/`restoreNvimAppname()` are module-private (NOT exported);
      `resolveNvimAppname()` + `__resetNvimAppnameStateForTest()` ARE exported.
- [ ] Follows existing patterns: module-level `let` state + test seam (mirrors
      `fdAvailableCache`/`__setFdAvailableForTest`), `[Mode A]` JSDoc inline.
- [ ] save/restore (NOT delete) for `NVIM_APPNAME`; plain delete only for the
      pi-owned `PI_NVIM_BRIDGE`.

### Documentation & Deployment

- [ ] [Mode A] JSDoc on the `applyNvimAppname()` call in startBridge (Task 3).
- [ ] README "Optional startup optimization" paragraph rewritten to document
      `PI_EDITOR_NVIM_APPNAME` (value table + minimal-config example), keeps the
      manual `NVIM_APPNAME=pi-editor` alternative, notes the no-path-separator
      gotcha (Task 6).
- [ ] No new env vars beyond `NVIM_APPNAME` (written) + `PI_EDITOR_NVIM_APPNAME`
      (read); no token/descriptor value logged anywhere (PRD §12).

---

## Anti-Patterns to Avoid

- ❌ Don't `delete process.env.NVIM_APPNAME` on stop — that clobbers a pre-existing
  user value. SAVE the baseline at apply, RESTORE it at stop (GOTCHA #1). Only the
  pi-owned `PI_NVIM_BRIDGE` gets a plain delete.
- ❌ Don't make the opt-in default-ON. It MUST be off when
  `PI_EDITOR_NVIM_APPNAME` is unset, or S16 + every startBridge/stopBridge caller
  regresses (GOTCHA #2). `resolveNvimAppname()` returns `undefined` for the unset
  case and `applyNvimAppname()` early-returns on `undefined`.
- ❌ Don't add `NVIM_APPNAME` to the `BridgeDescriptor`. It is its own `process.env`
  entry; the descriptor stays 7 keys (pinned by bridge-env.test.ts TEST 1).
- ❌ Don't read pi's `Settings` for the opt-in — `ExtensionContext` exposes no
  settings, and `Settings` has no extension-config bag (research §1). The
  `PI_EDITOR_NVIM_APPNAME` env var is the idiomatic channel (pi's own
  `PI_CLEAR_ON_SHRINK`/`PI_HARDWARE_CURSOR` precedent).
- ❌ Don't validate the appname for path separators in the bridge (scope creep);
  nvim rejects invalid appnames with a clear error — just document it.
- ❌ Don't place the apply in a separate `session_start` hook outside `startBridge`;
  it would bypass the TUI guard. Keep it inside `startBridge` (GOTCHA #8).
- ❌ Don't capture the baseline before `stopBridge` runs in `startBridge` — you'd
  re-capture the bridge's own prior override. Capture after (GOTCHA #3).
- ❌ Don't skip test cleanup (`finally`: restore __deps; reset fd cache;
  `__resetNvimAppnameStateForTest()`; delete BOTH `NVIM_APPNAME` and
  `PI_EDITOR_NVIM_APPNAME`; `stopBridge()`) — process.env leaks across tests in
  one process (GOTCHA #6).
- ❌ Don't edit `tsconfig.json` — the `tests/**/*.ts` glob already covers the new
  test (GOTCHA #7).

---

## Confidence Score

**9/10** for one-pass implementation success.

Rationale: the change is small and self-contained (3 constants, a pure resolver,
a save/restore pair, two 1-line wirings, one test file, one README paragraph).
It builds directly on the S16 pattern (env-var advertisement), which is already
shipped and tested — the test scaffolding (mockDeps, captureHandlers, finally
cleanup) is copy-adapted verbatim. The one non-obvious correctness property
(save/restore vs delete) is spelled out as GOTCHA #1 and pinned by TEST 6. The
only residual risk is a process.env-leak between the new test and bridge-env if
the `finally` cleanup is incomplete — mitigated by GOTCHA #6 + the explicit
delete of both vars in every test's teardown.