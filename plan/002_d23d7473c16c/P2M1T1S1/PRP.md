# PRP — P2.M1.T1.S1: Add optional shell fields to `BridgeDescriptor` + `HelloResult` + `PingResult`

> **Plan mapping:** task `P2.M1.T1.S1` ("Add optional shell fields to
> BridgeDescriptor + HelloResult + PingResult types"). It is the **first** task of
> **P2.M1.T1** ("Bridge descriptor shell/shellSource/shellPath") within the
> **Shell Completion for !/!! Bash Mode** epic (PRD §17). This task is the
> **type-only foundation**; it does NOT populate the fields.

---

## Goal

**Feature Goal**: Widen three existing TypeScript interfaces in
`extension/protocol.ts` — `BridgeDescriptor`, `HelloResult`, `PingResult` — to
**permit** three new OPTIONAL fields (`shell?`, `shellSource?`, `shellPath?`) per
PRD §17.10.1, and update the surrounding [Mode A] doc comments to record the new
fields and their **advisory** nature (PRD §17.10.2 honesty note). This is a
**type-only** change: zero runtime behavior change, zero wire-format change (the
descriptor written today still has 7 fields until S2 populates shell).

**Deliverable** (2 files modified — both already exist):
- `extension/protocol.ts` — MODIFY:
  1. `BridgeDescriptor` (L83–91): +3 optional shell fields.
  2. `HelloResult` (L107–112): +3 optional shell fields (mirror, PRD §17.10.1).
  3. `PingResult` (L117–123): +3 optional shell fields (PingResult = HelloResult+pid).
  4. §B header comment (L74–82): amend "all fields required" → note the optional
     advisory shell fields + the `$SHELL` fallback.
  5. §C per-type comments (L106, L116): note the mirror + advisory nature.
- `extension/tests/protocol.test.ts` — MODIFY: add compile-time assertions that the
  shell fields are (a) permitted when present, (b) **absent-OK** (back-compat), and
  (c) `shellSource` is the exact `"pi" | "$SHELL" | "default"` union.

**Success Definition**:
- `npx tsc --noEmit -p extension/tsconfig.json` exits 0 (the gate for a type change).
- The existing `satisfies BridgeDescriptor` literal at `pi-nvim-bridge.ts:578`
  (7 fields, no shell) **still compiles** — proves the new fields are optional and
  nothing downstream broke.
- `makeHelloHandler`/`makePingHandler` (return `HelloResult`/`PingResult` without
  shell fields) **still compile** — same proof.
- The protocol test suite passes (existing 2 tests green + new assertions green).
- The regression suites (`hello-handler`, `ping-bye-getcommands-handler`,
  `bridge-env`) stay green.
- [Mode A] comments document that shell fields are advisory and the plugin falls
  back to `$SHELL` when absent (PRD §17.10.2).

## User Persona (if applicable)

**Target User**: Developers of the `pi-bridge.nvim` shell-completion subsystem
(§17) — specifically the **downstream tasks S2/S3/S4** that consume these types.
End users see nothing from this task (it produces no runtime effect).

**Use Case**: S2 (`resolveShell` + populate descriptor) and S3 (wire into
`makeHelloHandler`/`makePingHandler`) need the types to *accept* `shell`/
`shellSource`/`shellPath` before they can populate them; S4 (lua `M.server_info`)
needs the wire contract fixed. This task unblocks all three.

**Pain Points Addressed**: Today the types forbid shell fields, so S2/S3 cannot
even compile. Adding them as optional (vs required) keeps older descriptors and
older clients valid — the plugin degrades to `$SHELL` when the fields are absent.

## Why

- **Foundation for the §17 shell-completion epic.** PRD §17.10 names this as "the
  only Component A change": three optional descriptor fields that let the plugin's
  `prefer:"pi"` completion match the shell pi actually executes `!`/`!!` in. Without
  the types, none of S2–S4 can land.
- **Back-compatible by construction.** Optional fields (`field?: T`) mean every
  existing producer of these types — the `satisfies` literal (L578), the hello/ping
  handlers, the test literals, and **descriptors already on the wire from older
  builds** — remain valid. Older clients that ignore unknown JSON keys are
  unaffected. This is the contract's explicit "all optional (back-compat with older
  clients)" guarantee.
- **Three sources must agree (mirrors the existing `cwd`/`fdAvailable` pattern).**
  The plugin can read shell info from the **descriptor** (env var, pre-handshake,
  lets it pick a driver before connecting) OR the **hello/ping** result
  (post-handshake, live, what `:checkhealth` reports). Mirroring the fields across
  all three types — exactly as `cwd`/`fdAvailable`/`serverVersion` already are —
  keeps the sources consistent. (See `research/notes.md` §4.)
- **Integrates with the parallel P1.M1.T1.S2 (README omp docs) with ZERO conflict** —
  that task edits `README.md`; this task edits `extension/protocol.ts` +
  `extension/tests/protocol.test.ts`. No file overlap, no semantic overlap.

## What

**User-visible behavior**: none (type-only; no runtime change, no wire change).

**Technical requirement**: add three optional fields to three interfaces, with the
exact shapes from PRD §17.10.1:

```ts
shell?: string;                               // "/bin/zsh" — resolved execution shell binary
shellSource?: "pi" | "$SHELL" | "default";    // how `shell` was derived
shellPath?: string;                           // raw shellPath setting, if the user set one
```

Update the §B header comment's "all fields required" claim and add a one-line
note to each of the three types' doc comments stating the fields are **advisory**
(the plugin falls back to `$SHELL` when absent — PRD §17.10.2).

### Success Criteria

- [ ] `BridgeDescriptor`, `HelloResult`, `PingResult` each have the three optional
      shell fields with the EXACT names/types above (incl. the `"pi" | "$SHELL" |
      "default"` union — note `$SHELL` literal).
- [ ] The 7 existing required `BridgeDescriptor` fields and the existing
      `HelloResult`/`PingResult` fields are UNCHANGED (additive only).
- [ ] §B header comment no longer claims "all fields required"; states the shell
      fields are optional + advisory + `$SHELL` fallback.
- [ ] §C comments on `HelloResult`/`PingResult` note the mirror + advisory nature.
- [ ] `npx tsc --noEmit -p extension/tsconfig.json` exits 0.
- [ ] The `satisfies BridgeDescriptor` literal at `pi-nvim-bridge.ts:578` is
      UNCHANGED and still compiles (proves optionality / no downstream break).
- [ ] `makeHelloHandler`/`makePingHandler` are UNCHANGED and still compile.
- [ ] protocol.test.ts: new compile-time assertions present + green; existing
      assertions still green.
- [ ] [Mode A] JSDoc/block comments document the advisory nature + `$SHELL` fallback.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo needs
only this PRP + the exact current code of the three interfaces (quoted verbatim
below in the Blueprint) + the verified `tsc`/test commands. Every claim about
back-compat is proven by listing the exact consumers that omit the new fields
(§Known Gotchas). The line numbers were verified by `grep -n` against the live file.

### Documentation & References

```yaml
# MUST READ — the spec being implemented
- docfile: PRD.md   # (PRD §17.10.1 + §17.10.2 are reproduced verbatim in this PRP's <selected_prd_content>)
  why: "§17.10.1 gives the EXACT field shapes (shell?: string; shellSource?: \"pi\" | \"$SHELL\" | \"default\"; shellPath?: string) and mandates 'the hello result mirrors these'. §17.10.2 is the honesty note (advisory; falls back to $SHELL)."
  section: "h3.39 (§17.10), h4.9 (§17.10.1 BridgeDescriptor), h4.10 (§17.10.2 Resolution)"
  critical: "The fields are OPTIONAL ('absent on older clients is fine — the plugin falls back to $SHELL'). Do NOT make them required. shellSource's '$SHELL' literal includes the '$' — it is a valid TS string-literal union member."

# MUST READ — the file being edited (current content quoted verbatim in Blueprint below)
- file: extension/protocol.ts
  why: "the ONLY source file to modify: BridgeDescriptor (L83-91), HelloResult (L107-112), PingResult (L117-123), §B header comment (L74-82), §C comments (L106, L116)."
  pattern: "interfaces use TAB indentation; block comments are /* … */ with '*'-prefixed lines + boxed === headers; inline field comments use '// …'."
  gotcha: "Match TABS (not spaces) in the new field lines. The contract's 'satisfies guard at L570' is slightly stale — it is actually at pi-nvim-bridge.ts:578."

# MUST READ — the test file to extend
- file: extension/tests/protocol.test.ts
  why: "the existing compile-time type-shape test ('wire type shapes compile and round-trip key literals'). ADD the shell-field assertions here (a descriptor WITH shell fields type-checks; the existing 7-field literal STILL type-checks = back-compat proof)."
  pattern: "node:test 'test(\"…\", () => { const x: Type = {…}; assert.equal(…) });' — declarations INSIDE the test body (not module-level) so they are not unused locals; tsc --noEmit is the validator."

# MUST READ — local research notes (verified facts + forward contracts)
- docfile: plan/002_d23d7473c16c/P2M1T1S1/research/notes.md
  why: "exact line numbers, back-compat proof (lists every consumer that omits the fields), field semantics, forward contracts to S2/S3/S4, verified validation commands."
  section: "§1 (exact state), §2 (back-compat proof), §3 (field semantics), §5 (forward contracts), §6 (validation), §7 (style)"

# SUPPORTING — architecture research for §17 (confirms semantics + the honesty gap)
- docfile: plan/002_d23d7473c16c/architecture/research-prd-section-17.md
  why: "confirms shellSource values ('pi'=$SHELL-mirror-via-PI_NVIM_SHELL; '$SHELL'=fallback; 'default'=/bin/bash) and the §17.10.2 honesty gap (settingsManager not on ExtensionContext → fields are advisory)."
  section: "§17.10.1 / §17.10.2 excerpts + '§17.10.2 honesty gap' risk note"

# SUPPORTING — the consumers that must NOT break (read-only confirmation)
- file: extension/pi-nvim-bridge.ts
  why: "L578 'satisfies BridgeDescriptor' literal (7 fields), L623/L629 makeHelloHandler→HelloResult, L670/L676 makePingHandler→PingResult. None are edited by this task; all must still compile after the optional fields are added."
  gotcha: "Do NOT edit pi-nvim-bridge.ts in this task. S2 populates the descriptor; S3 wires the handlers. This task is protocol.ts + its test ONLY."
```

### Current Codebase tree (relevant slice)

```bash
extension/
├── protocol.ts                 # MODIFY — 3 interfaces (L83-91, L107-112, L117-123) + §B/§C comments
├── pi-nvim-bridge.ts           # READ-ONLY consumer — L578 satisfies literal, L629/L676 handlers (must still compile)
├── connection.ts               # READ-ONLY (descriptor builder is a LATER task per §17.16 step 26 — NOT this one)
├── jsonl-reader.ts             # READ-ONLY
├── tsconfig.json               # READ-ONLY (strict:true; include auto-covers tests/**/*.ts → NO edit)
└── tests/
    ├── protocol.test.ts        # MODIFY — add shell-field compile-time assertions
    ├── hello-handler.test.ts   # READ-ONLY regression (HelloResult consumer)
    ├── ping-bye-getcommands-handler.test.ts  # READ-ONLY regression (PingResult consumer)
    └── bridge-env.test.ts      # READ-ONLY regression (BridgeDescriptor satisfies literal)
```

### Desired Codebase tree with files to be modified

```bash
extension/protocol.ts                 # MODIFIED — +3 optional shell fields × 3 interfaces + comment updates
extension/tests/protocol.test.ts      # MODIFIED — +shell-field compile-time assertions
# (NO new files. NO pi-nvim-bridge.ts edit. NO connection.ts edit. NO tsconfig edit. NO lua edit.)
```

### Known Gotchas of our codebase & Library Quirks

```typescript
// CRITICAL: the new fields MUST be OPTIONAL (shell?: …). Making them required would
// break (a) the satisfies literal at pi-nvim-bridge.ts:578 (7 fields, no shell),
// (b) makeHelloHandler/makePingHandler return values, (c) every descriptor already
// on the wire from older builds, and (d) older Neovim clients. Optional is the
// entire back-compat story (PRD §17.10.1: "absent on older clients is fine").

// CRITICAL: shellSource's union is "pi" | "$SHELL" | "default" — the "$SHELL"
// member LITERALLY contains a '$'. It is a valid TS string-literal type. Do NOT
// strip the '$' or rename it to "shell" / "env".

// GOTCHA: protocol.ts uses TAB indentation (verified). Match tabs on the new field
// lines — mixing spaces triggers inconsistent-indent friction and diverges from
// every other interface body in the file.

// GOTCHA: the contract's "satisfies guard at L570" is stale — the real site is
// pi-nvim-bridge.ts:578. The proof it still compiles is the SAME either way.

// GOTCHA: exactOptionalPropertyTypes is NOT enabled (only strict:true). So
// `shell?: string` is the standard optional — no need for `string | undefined`.

// SCOPE: this task is TYPE-ONLY. Do NOT:
//   - implement resolveShell() (that is S2),
//   - populate the descriptor literal at L578 with shell fields (S2),
//   - wire shell into makeHelloHandler/makePingHandler deps (S3),
//   - edit connection.ts descriptor builder (a later §17.16 task),
//   - extract shell on the lua side into M.server_info (S4).
// This task ONLY widens the types + documents them + adds compile-time tests.

// BACK-COMAT PROOF (the consumers that omit shell and must still compile):
//   pi-nvim-bridge.ts:578  JSON.stringify({...7 fields...} satisfies BridgeDescriptor)
//   pi-nvim-bridge.ts:629  makeHelloHandler returns { ok, serverVersion, cwd, fdAvailable }
//   pi-nvim-bridge.ts:676  makePingHandler  returns { ok, pid, cwd, fdAvailable, serverVersion }
//   tests/protocol.test.ts const desc/helloRes/pingRes literals (7/4/5 fields)
// All are valid against the widened types because the new fields are optional.
```

## Implementation Blueprint

### Data models and structure

The "data models" ARE the three interfaces. Below is the **exact current → exact
target** for each. The implementer may apply these verbatim.

**BridgeDescriptor — current (L83–91):**
```ts
export interface BridgeDescriptor {
	transport: "unix";
	path: string;
	token: string;
	pid: number;
	cwd: string;
	fdAvailable: boolean;
	serverVersion: string;
}
```
**BridgeDescriptor — target:** (append the three optional fields, tab-indented)
```ts
export interface BridgeDescriptor {
	transport: "unix";
	path: string;
	token: string;
	pid: number;
	cwd: string;
	fdAvailable: boolean;
	serverVersion: string;
	// §17.10 (NEW) — OPTIONAL, advisory shell info so the plugin's !/!! completion
	// can match the shell pi executes commands in (prefer:"pi"). Absent on older
	// builds/clients is fine — the plugin falls back to $SHELL (PRD §17.10.2).
	shell?: string; // "/bin/zsh" — resolved execution shell binary
	shellSource?: "pi" | "$SHELL" | "default"; // how `shell` was derived
	shellPath?: string; // raw shellPath setting, if the user set one
}
```

**HelloResult — current (L107–112):**
```ts
export interface HelloResult {
	ok: true;
	serverVersion: string;
	cwd: string;
	fdAvailable: boolean;
}
```
**HelloResult — target:**
```ts
export interface HelloResult {
	ok: true;
	serverVersion: string;
	cwd: string;
	fdAvailable: boolean;
	// §17.10 (NEW) — OPTIONAL advisory mirror of BridgeDescriptor.shell* (PRD §17.10.1:
	// "the hello result mirrors these"). Lets the plugin read the resolved shell
	// post-handshake; falls back to $SHELL if absent.
	shell?: string;
	shellSource?: "pi" | "$SHELL" | "default";
	shellPath?: string;
}
```

**PingResult — current (L117–123):**
```ts
export interface PingResult {
	ok: true;
	pid: number;
	cwd: string;
	fdAvailable: boolean;
	serverVersion: string;
}
```
**PingResult — target:**
```ts
export interface PingResult {
	ok: true;
	pid: number;
	cwd: string;
	fdAvailable: boolean;
	serverVersion: string;
	// §17.10 (NEW) — OPTIONAL advisory mirror of BridgeDescriptor.shell* (PingResult
	// is HelloResult + pid). Same semantics/fallback as HelloResult.
	shell?: string;
	shellSource?: "pi" | "$SHELL" | "default";
	shellPath?: string;
}
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: MODIFY extension/protocol.ts — BridgeDescriptor (L83-91)
  - APPEND the three optional fields (shell?, shellSource?, shellPath?) AFTER
        serverVersion, with the §17.10 block comment + inline // comments shown above.
  - TYPES EXACT: shell?: string; shellSource?: "pi" | "$SHELL" | "default"; shellPath?: string;
  - INDENTATION: TABS (match the file).
  - DO NOT: reorder or rename any existing field; do NOT make any existing field optional.

Task 2: MODIFY extension/protocol.ts — HelloResult (L107-112) + PingResult (L117-123)
  - APPEND the SAME three optional fields to each (with the mirror comment).
  - PingResult gets them AFTER serverVersion (its last field).
  - SAME types/indentation as Task 1.

Task 3: MODIFY extension/protocol.ts — the §B header comment (L74-82) + §C comments (L106, L116)  [Mode A]
  - §B: amend the sentence "MUST be a plain JSON object (all fields required,
        JSON-serializable)" to reflect that the 7 base fields are required but the
        §17.10 shell.* fields are OPTIONAL and ADVISORY (plugin falls back to $SHELL
        if absent — PRD §17.10.2). Keep the rest of the §B block (transport literal,
        field-value-sources map) intact.
  - §C HelloResult comment (L106): append "(+ optional §17.10 advisory shell.*
        mirror; plugin falls back to $SHELL if absent)".
  - §C PingResult comment (L116): append the same mirror note.
  - STYLE: match the existing '*'-prefixed block-comment lines.

Task 4: MODIFY extension/tests/protocol.test.ts — add shell-field compile-time assertions
  - INSIDE the existing "wire type shapes compile and round-trip key literals" test
        (after the current `const desc: BridgeDescriptor = {…7…}` block), ADD:
      (a) a BridgeDescriptor WITH all three shell fields (incl. shellSource:"pi",
          "$SHELL", "default" exercised) — proves the type ACCEPTS them;
      (b) a HelloResult WITH the three shell fields;
      (c) a PingResult WITH the three shell fields;
      (d) a shellSource assigned each of the three union members (compile-time union check).
  - LEAVE the existing 7-field/4-field/5-field literals IN PLACE — they are the
        back-compat proof (a descriptor WITHOUT shell fields still type-checks).
  - ADD a couple of runtime assert.equal for signal (e.g. assert.equal(descWithShell.shell, "/bin/zsh")).
  - NAMING: descriptive locals (descWithShell, helloWithShell, pingWithShell, src).
  - PLACEMENT: inside the existing test body (so they are not unused-local errors).
  - DEPENDENCIES: Tasks 1-3 (the widened types).

Task 5: VALIDATE — tsc + protocol test + regression suites
  - RUN: npx tsc --noEmit -p extension/tsconfig.json   (exit 0)
  - RUN: node --import "$JITI_REG" extension/tests/protocol.test.ts   (all pass)
  - RUN (regression): hello-handler, ping-bye-getcommands-handler, bridge-env tests
        (all pass — proves optional fields didn't break the consumers).
```

### Implementation Patterns & Key Details

```typescript
// === protocol.test.ts — the shell-field assertions to ADD (inside the existing test) ===
// Place AFTER the existing `const desc: BridgeDescriptor = { …7 fields… };` block.

// (a) BridgeDescriptor ACCEPTS the three optional shell fields:
const descWithShell: BridgeDescriptor = {
	transport: "unix",
	path: "/tmp/x.sock",
	token: "deadbeef",
	pid: 1,
	cwd: "/p",
	fdAvailable: true,
	serverVersion: "0.1.0",
	shell: "/bin/zsh",
	shellSource: "pi",
	shellPath: "/bin/zsh",
};
assert.equal(descWithShell.shell, "/bin/zsh");

// (b) HelloResult ACCEPTS the mirror:
const helloWithShell: HelloResult = {
	ok: true,
	serverVersion: "0.1.0",
	cwd: "/p",
	fdAvailable: true,
	shell: "/bin/bash",
	shellSource: "default",
};
assert.equal(helloWithShell.shellSource, "default");

// (c) PingResult ACCEPTS the mirror:
const pingWithShell: PingResult = {
	ok: true,
	pid: 1,
	cwd: "/p",
	fdAvailable: true,
	serverVersion: "0.1.0",
	shell: "/bin/sh",
	shellSource: "$SHELL",
};
assert.equal(pingWithShell.shellSource, "$SHELL");

// (d) shellSource accepts EACH union member (compile-time union exhaustiveness):
const src: "pi" | "$SHELL" | "default" = "$SHELL";
const dPi: BridgeDescriptor = { transport: "unix", path: "/", token: "t", pid: 0, cwd: "/", fdAvailable: false, serverVersion: "0", shellSource: "pi" };
const dEnv: BridgeDescriptor = { transport: "unix", path: "/", token: "t", pid: 0, cwd: "/", fdAvailable: false, serverVersion: "0", shellSource: "$SHELL" };
const dDef: BridgeDescriptor = { transport: "unix", path: "/", token: "t", pid: 0, cwd: "/", fdAvailable: false, serverVersion: "0", shellSource: "default" };
assert.equal(src, "$SHELL");

// NOTE: the existing `desc`/`helloRes`/`pingRes` literals (WITHOUT shell fields)
// STAY in the test unchanged — they are the proof that the new fields are OPTIONAL
// and that every existing producer still type-checks (the back-compat guarantee).
```

### Integration Points

```yaml
TYPES (extension/protocol.ts — type-only, zero runtime cost):
  - BridgeDescriptor:  +shell?: string, +shellSource?: "pi" | "$SHELL" | "default", +shellPath?: string
  - HelloResult:       +same three optional fields (mirror)
  - PingResult:        +same three optional fields (mirror)

NO RUNTIME / WIRE CHANGE:
  - The descriptor written by startBridge (pi-nvim-bridge.ts:578) STILL has 7 fields
    after this task (S2 populates shell). The wire format is byte-identical today.
  - makeHelloHandler/makePingHandler return values are UNCHANGED (S3 adds shell).

FORWARD CONTRACTS (do NOT implement here — just don't break them):
  - S2: resolveShell() + populate the L578 literal with shell fields (needs these types).
  - S3: add a getShell dep to makeHelloHandler/makePingHandler; return shell fields
        (needs HelloResult/PingResult to accept them).
  - S4: lua/pi-bridge/bridge.lua M.server_info extracts shell/shellSource from the
        descriptor + hello result (needs the TS types as the wire contract).

NO DATABASE / NO CONFIG / NO ROUTES / NO env vars / NO tsconfig edit / NO lua edit.
```

## Validation Loop

> Run all commands from the repo root (`/home/dustin/projects/pi-nvim-bridge`).
> For a **type-only** change, `tsc --noEmit` is the primary gate; the test suite
> adds compile-time assertions + a runtime signal. All commands are VERIFIED to run
> in this env (baseline: tsc exit 0, protocol test 2/2 pass — confirmed pre-change).

### Level 1: Type-check (THE gate)

```bash
# The authoritative gate for a type-only change. Must exit 0 with zero output.
npx tsc --noEmit -p extension/tsconfig.json
echo "exit=$?   # 0 = pass"
# Expected: exit 0. If it fails, READ the errors. Likely causes:
#   - a typo in a field name / type (e.g. shellSource: "shell" instead of the union),
#   - spaces instead of tabs (won't fail tsc, but diverges from file style),
#   - accidentally making a field REQUIRED (would break the L578 satisfies literal
#     and the handlers — the error would point at pi-nvim-bridge.ts:578 / :629 / :676).
```

### Level 2: Unit Tests (protocol + the new shell-field assertions)

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
# The deliverable test (existing 2 tests + the new shell-field assertions):
node --import "$JITI_REG" extension/tests/protocol.test.ts
echo "exit=$?   # 0 = pass; reporter prints 'ℹ pass N' / 'ℹ fail 0'"
# Expected: ℹ fail 0. (jiti prints a benign "module.register() is deprecated"
# DEP0205 on stderr — IGNORE it.)
```

### Level 3: Regression — prove optional fields didn't break consumers

```bash
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
# Each of these builds a HelloResult/PingResult/BridgeDescriptor WITHOUT shell fields.
# They MUST still pass (proves the new fields are optional and the handlers/satisfies
# literal are untouched).
node --import "$JITI_REG" extension/tests/hello-handler.test.ts                 # HelloResult consumer
node --import "$JITI_REG" extension/tests/ping-bye-getcommands-handler.test.ts  # PingResult consumer
node --import "$JITI_REG" extension/tests/bridge-env.test.ts                    # satisfies BridgeDescriptor literal
# Expected: each prints ℹ fail 0. If any fails, you likely made a field required
# or renamed an existing field — re-read the error and fix protocol.ts.
```

### Level 4: Back-compat & forward-contract verification

```bash
# 4a. PROVE the descriptor on the wire is UNCHANGED by this task (S1 is type-only):
#     grep the L578 literal — it must STILL be 7 fields (no shell keys present).
grep -n "satisfies BridgeDescriptor" extension/pi-nvim-bridge.ts
sed -n '565,580p' extension/pi-nvim-bridge.ts   # confirm NO shell: keys in the literal
# Expected: the literal shows transport/path/token/pid/cwd/fdAvailable/serverVersion ONLY.
#           (S2 will ADD shell here later — NOT this task.)

# 4b. PROVE the three interfaces now DECLARE the optional shell fields (robust grep).
#     (Do NOT use a standalone `tsc file.ts` here — it cannot resolve the
#     @earendil-works/pi-tui import without the project tsconfig path mapping and
#     fails with TS2307. That a CONSUMER can assign the fields is already proven by
#     Level 2: protocol.test.ts's descWithShell/helloWithShell/pingWithShell
#     literals, compiled by the PROJECT tsconfig in Level 1.)
grep -nE 'shell\?:|shellSource\?:|shellPath\?:' extension/protocol.ts | wc -l
# Expected: 9  (3 fields × 3 interfaces: BridgeDescriptor, HelloResult, PingResult).
#           (Today, before the change, this grep yields 0 — that is correct.)
grep -nE 'shellSource\?:' extension/protocol.ts | head -1
# Expected: a line showing shellSource?: "pi" | "$SHELL" | "default"  (the '$' is literal).

# 4c. Confirm the §B/§C comments were updated (Mode A docs gate):
grep -n "advisory\|falls back to .SHELL\|§17.10" extension/protocol.ts
# Expected: matches in the §B header comment + the three interface comments.
```

## Final Validation Checklist

### Technical Validation

- [ ] `npx tsc --noEmit -p extension/tsconfig.json` exits 0 (zero output).
- [ ] `protocol.test.ts` passes (existing + new shell-field assertions; ℹ fail 0).
- [ ] Regression green: `hello-handler`, `ping-bye-getcommands-handler`,
      `bridge-env` each ℹ fail 0.
- [ ] Level 4a: the L578 `satisfies` literal is UNCHANGED (still 7 fields).
- [ ] Level 4b: an external consumer can assign shell fields (type-check passes).
- [ ] No file other than `extension/protocol.ts` + `extension/tests/protocol.test.ts`
      is modified (no pi-nvim-bridge.ts, no connection.ts, no tsconfig, no lua).

### Feature Validation

- [ ] `BridgeDescriptor`/`HelloResult`/`PingResult` each carry the three optional
      shell fields with EXACT names/types (`shell?: string`;
      `shellSource?: "pi" | "$SHELL" | "default"`; `shellPath?: string`).
- [ ] All existing required fields are unchanged (additive only).
- [ ] §B header comment no longer says "all fields required"; notes optional +
      advisory + `$SHELL` fallback.
- [ ] §C comments note the mirror + advisory nature.
- [ ] The existing 7/4/5-field test literals STILL type-check (back-compat proof).

### Code Quality Validation

- [ ] New field lines use TAB indentation (match the file).
- [ ] Block-comment style matches the existing `*`-prefixed boxed comments.
- [ ] No field made required; no existing field renamed/reordered.
- [ ] Test additions are INSIDE the existing test body (no unused-local errors).

### Documentation & Deployment

- [ ] [Mode A] comments document the advisory nature + `$SHELL` fallback (PRD §17.10.2).
- [ ] No README / doc/pi-bridge.txt / extension/README.md change (those are later
      Mode-B tasks: P2.M4.T7.S1/S3).
- [ ] No new env vars documented/introduced (PI_NVIM_SHELL is S2's concern).

---

## Anti-Patterns to Avoid

- ❌ Don't make the shell fields **required** — that breaks the L578 `satisfies`
  literal, the hello/ping handlers, and every older descriptor/client. Optional is
  the entire back-compat contract (PRD §17.10.1).
- ❌ Don't strip the `$` from `"$SHELL"` in the `shellSource` union — it is a literal
  string-literal type member, not a variable reference.
- ❌ Don't edit `pi-nvim-bridge.ts` (the L578 literal or the handlers) — populating
  shell is S2/S3. This task is `protocol.ts` + its test ONLY.
- ❌ Don't edit `connection.ts` (the descriptor builder) — that is a later §17.16 task.
- ❌ Don't edit `tsconfig.json` — `include` already covers `protocol.ts` +
  `tests/**/*.ts` (no new file, no glob change needed).
- ❌ Don't reorder/rename existing fields or touch other interfaces — this is a
  purely ADDITIVE change to three named interfaces + their comments.
- ❌ Don't add runtime code — `protocol.ts` is TYPE-ONLY (its own header says so);
  this task must keep it that way.
- ❌ Don't skip the regression suites — they are the proof that adding optional
  fields didn't silently break a consumer that builds these types.
- ❌ Don't use spaces where the file uses tabs (protocol.ts interface bodies are
  tab-indented — verified).