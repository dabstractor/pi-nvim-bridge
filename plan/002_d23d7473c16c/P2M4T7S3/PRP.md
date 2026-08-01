---
name: "P2.M4.T7.S3 — extension/README.md: optional descriptor fields + PI_NVIM_SHELL"
description: |
  Create a focused `extension/README.md` that documents (for a reader browsing
  the npm package or the `extension/` source) the bridge extension's own
  surface: what it is, how it activates, the `PI_NVIM_BRIDGE` descriptor (with
  the new optional §17.10 `shell`/`shellSource`/`shellPath` fields), and the
  `PI_NVIM_SHELL` opt-in env var that mirrors pi's `shellPath` setting. This is
  a documentation-only NEW file — no code, no config, no behavioral change. It
  is the extension-side companion to the root `README.md` (which serves the
  whole repo / nvim plugin).
---

## Goal

**Feature Goal**: Fill the last documentation surface in the P2.M4 "Mode B
changeset-level doc sync" milestone. The root `README.md` (S1) documents the
*whole repo* (extension + nvim plugin) for GitHub/lazy.nvim visitors;
`doc/pi-bridge.txt` (S2) documents the nvim plugin via `:help`. But a reader
who lands on the **npm package page** for `pi-nvim-bridge` (or browses the
`extension/` directory) sees only `package.json`'s terse `description` field
and has no extension-scoped README explaining: what the extension is, how it
activates (the `PI_NVIM_BRIDGE` process.env discovery), what the descriptor
contains (including the new optional `shell*` fields from §17.10), and how to
align completion with pi's execution shell via `PI_NVIM_SHELL`. This task
creates that file.

**Deliverable**: A single NEW file `extension/README.md` (~120–180 lines)
containing:
1. A one-paragraph "What it is" — the extension is the pi-side half of the
   two-component bridge (captures pi's live `AutocompleteProvider`, serves it
   over a Unix socket advertised via `PI_NVIM_BRIDGE`).
2. An **Installation** section (mirrors the root README's install commands but
   extension-scoped: `pi install npm:pi-nvim-bridge` / `pi install git:…`,
   `pi list`), with a pointer to the root `README.md` for the nvim-plugin half
   and full setup.
3. A **How it works** section — 3 numbered steps (live-provider capture via a
   pass-through `addAutocompleteProvider` factory; `process.env.PI_NVIM_BRIDGE`
   discovery via the `stdio:"inherit"` + no-`env:` spawn seam; JSON-RPC methods).
4. A **`PI_NVIM_BRIDGE` descriptor reference** section — the JSON shape with a
   field table, **including** the new optional `shell` / `shellSource` /
   `shellPath` fields (§17.10), with their advisory-only semantics and the
   fallback chain the plugin applies when they are absent.
5. A **`PI_NVIM_SHELL` opt-in env var** section — what it is (a bridge-local
   mirror of pi's `shellPath` setting), the 3-branch resolution order
   (`PI_NVIM_SHELL` → `$SHELL` → `/bin/bash`), why it exists (the extension
   cannot read `settingsManager`/`getShellConfig` — not on `ExtensionContext`),
   and a worked example (zsh user wanting `!` completions in zsh).
6. A **Host compatibility** note — pi vs oh-my-pi (`omp`); the extension runs
   under both via the `(pkg.omp ?? pkg.pi).extensions` manifest fallback and the
   dual `isInteractiveSession` guard (`ctx.mode === "tui"` OR `ctx.hasUI === true`).
7. A **Development** section — `npm run typecheck`, the `node:test` + jiti test
   invocation, pointer to `extension/tests/`.
8. A **Scope / pointers** footer — links to the root `README.md`, `doc/pi-bridge.txt`,
   `doc/pi-bridge-shell.txt`, and the `PRD.md` design doc.

**Success Definition**: `extension/README.md` exists, is accurate against the
shipped code (verified by reading `protocol.ts` `BridgeDescriptor`, the
`resolveShell()` 3-branch chain, and `SHELL_MIRROR_ENV = "PI_NVIM_SHELL"`),
documents both the descriptor's `shell*` optional fields AND the `PI_NVIM_SHELL`
env var, and is reachable from the npm package tarball (the `files` field in
`package.json` already includes `README.md` at the repo root — **GOTCHA**: see
Implementation Notes; the extension README must be referenced correctly relative
to the npm `files` scope). No source/config/code files are modified.

## User Persona (if applicable)

**Target User**: A pi user (or `omp` user) who installs the `pi-nvim-bridge`
npm package / pi extension and wants to understand its own surface — either
(a) browsing the npm page before installing, (b) reading `extension/` source
while developing/debugging, or (c) hitting the shell-mismatch footgun and
searching for how to make `!` completion use their shell.

**Use Case**: "I installed `pi-nvim-bridge` as a pi extension; what env vars
does it touch, what's in the `PI_NVIM_BRIDGE` descriptor, and how do I get my
native zsh/fish completions on `!` lines instead of bash?" — answered entirely
from `extension/README.md` without needing to read the nvim-plugin docs.

**User Journey**: `pi install npm:pi-nvim-bridge` → `pi list` (shows healthy) →
opens `Ctrl+G` editor → reads `:lua print(vim.env.PI_NVIM_BRIDGE)` → wants to
understand the JSON → finds `extension/README.md` (via the npm page or the repo)
→ sees the descriptor field table + the `shell*` fields + `PI_NVIM_SHELL` →
sets `PI_NVIM_SHELL=/bin/zsh` in the env that launches pi → native completions.

**Pain Points Addressed**:
- The descriptor's `shell`/`shellSource`/`shellPath` fields ship with no
  extension-side documentation (they were added in P2.M1.T1; only `doc/pi-bridge-shell.txt`
  explains them from the plugin's consumer side).
- `PI_NVIM_SHELL` is a real, documented opt-in (`SHELL_MIRROR_ENV` constant in
  `pi-nvim-bridge.ts`) but appears NOWHERE in any README — a user who wants
  `prefer:"pi"` to resolve to a richer shell than bash has no way to discover
  the env var that makes that work without reading the extension source.

## Why

- **Documentation completeness**: P2.M1.T1 added three optional descriptor fields
  + the `PI_NVIM_SHELL` resolution chain; P2.M1–P2.M3 built the entire shell-
  completion subsystem. The root `README.md` (S1) and `doc/pi-bridge-shell.txt`
  cover the *plugin/consumer* side, but the *extension producer* side has no
  README at all. This is the missing third surface of the P2.M4 milestone.
- **Discoverability of `PI_NVIM_SHELL`**: this env var is the only way (short of
  a future upstream `ctx.getShellConfig()`, PRD §17.17) for the extension to
  advertise pi's resolved execution shell to the plugin's `prefer:"pi"` resolver.
  Without it, a zsh/fish user gets bash-quality `!` completions by default and
  has no documented path to fix it. The descriptor `shell*` fields are advisory
  and silently absent on older bridges; `PI_NVIM_SHELL` is the user-facing knob.
- **Scope discipline (Mode B)**: this is a pure new-doc task. It creates exactly
  one file (`extension/README.md`), introduces no code/config/keys/behavior, and
  is the sibling of S1 (`README.md`) and S2 (`doc/pi-bridge.txt`). It owns ONLY
  the extension-scoped surface.

## What

A new `extension/README.md` that is accurate, terse, and consistent with the
root README's voice (no marketing fluff; troubleshooting-aware). It MUST:

- State the extension is one of two cooperating components and link the root
  `README.md` for the full picture (do not duplicate the nvim-plugin install /
  config — point to it).
- Document the `PI_NVIM_BRIDGE` descriptor as a field table, with the `shell*`
  fields clearly marked **optional / advisory** and the plugin's fallback
  (`$SHELL` then `/bin/bash`) stated.
- Document `PI_NVIM_SHELL` as the env var the extension reads to populate the
  `shell*` fields when the user wants `prefer:"pi"` to resolve to a specific
  shell. Give the exact 3-branch resolution order.
- Explain the *why* honestly: the extension cannot read pi's `settingsManager`/
  `getShellConfig()` (not on `ExtensionContext`), so `PI_NVIM_SHELL` is a manual
  mirror of pi's `shellPath` setting.
- Note pi-vs-omp host compatibility (both supported; manifest fallback + dual
  mode guard).
- Include a Development section pointing at `npm run typecheck` and the
  `node:test` + jiti test invocation.

### Success Criteria

- [ ] `extension/README.md` exists and renders as valid Markdown.
- [ ] It documents all 10 `BridgeDescriptor` fields (7 required + 3 optional
      `shell*`), matching `extension/protocol.ts` exactly.
- [ ] It documents `PI_NVIM_SHELL` with the 3-branch resolution order matching
      `resolveShell()` in `extension/pi-nvim-bridge.ts` (`PI_NVIM_SHELL` →
      `$SHELL` → `/bin/bash`, with `shellSource` = `"pi"` / `"$SHELL"` /
      `"default"` respectively).
- [ ] It links the root `README.md`, `doc/pi-bridge.txt`, `doc/pi-bridge-shell.txt`,
      and `PRD.md`.
- [ ] No source, config, `package.json`, `tasks.json`, or PRD files are modified.
- [ ] The descriptor JSON example is byte-consistent with what `startBridge()`
      actually emits (`serverVersion: "0.1.0"`; `shellPath` omitted when
      `shellSource` is `"$SHELL"`/`"default"` because it is `undefined` and
      `JSON.stringify` drops it).

## All Needed Context

### Context Completeness Check

_Before writing this PRP, validated: "If someone knew nothing about this
codebase, would they have everything needed to implement this successfully?"_
**Yes** — the implementer needs: (a) the exact descriptor shape (in
`extension/protocol.ts` `BridgeDescriptor`, quoted below), (b) the exact
`resolveShell()` 3-branch chain (in `extension/pi-nvim-bridge.ts`, quoted below),
(c) the root README's voice/structure to match (read it), and (d) the npm
`files` scope gotcha. All four are provided here verbatim.

### Documentation & References

```yaml
# MUST READ — the authoritative sources for every claim the new README makes.

- file: extension/protocol.ts
  why: |
    The BridgeDescriptor interface (§B of the file) is the EXACT shape the README's
    descriptor field table must match — field names, types, optionality, and the
    shellSource union ("pi" | "$SHELL" | "default"). HelloResult + PingResult
    (§C) carry the optional shell.* mirror the README should also mention
    (post-handshake / ping reads). Do not invent fields.
  pattern: |
    export interface BridgeDescriptor {
      transport: "unix";
      path: string; token: string; pid: number; cwd: string;
      fdAvailable: boolean; serverVersion: string;
      // OPTIONAL §17.10 advisory:
      shell?: string;
      shellSource?: "pi" | "$SHELL" | "default";
      shellPath?: string;
    }
  critical: |
    The 3 shell.* fields are OPTIONAL. The README MUST mark them optional/advisory
    and state the plugin's fallback ($SHELL then /bin/bash) when absent — this is
    the back-compat contract (older bridges omit them entirely).

- file: extension/pi-nvim-bridge.ts
  why: |
    Contains (1) `SHELL_MIRROR_ENV = "PI_NVIM_SHELL"` (the constant — the README
    MUST use this exact env-var name), (2) `resolveShell()` — the EXACT 3-branch
    resolution chain the README must reproduce verbatim in prose, and
    (3) `startBridge()`'s descriptor write site (lines ~635-650) — the canonical
    JSON shape + the fact that `shellPath` is `undefined` in the $SHELL/default
    branches so JSON.stringify OMITS it (the README's example must reflect this).
  pattern: |
    export const SHELL_MIRROR_ENV = "PI_NVIM_SHELL";
    export function resolveShell(): ShellInfo {
      const explicit = process.env[SHELL_MIRROR_ENV];
      if (explicit) return { shell: explicit, shellSource: "pi", shellPath: explicit };
      const sh = process.env.SHELL;
      if (sh) return { shell: sh, shellSource: "$SHELL" };
      return { shell: "/bin/bash", shellSource: "default" };
    }
  gotcha: |
    `shellPath` is ONLY present in the "pi" branch. In the "$SHELL" and "default"
    branches it is `undefined`, and `JSON.stringify` drops undefined object
    values — so the descriptor emitted on a typical machine (no PI_NVIM_SHELL set,
    $SHELL=/bin/zsh) contains `shell:"/bin/zsh", shellSource:"$SHELL"` and NO
    `shellPath` key at all. The README's example JSON must show this accurately
    (do not show a `shellPath: undefined` field).

- file: README.md
  why: |
    The root README is the voice/structure template: terse, troubleshooting-aware,
    uses ```jsonc fenced blocks for the descriptor, has explicit "How it works",
    "The PI_NVIM_BRIDGE environment variable", "Troubleshooting", "Development",
    and "Repository layout" sections. The new extension/README.md should MATCH
    this voice and CROSS-LINK it (not duplicate it). Lines ~257-275 (the
    descriptor JSON + the "`echo $PI_NVIM_BRIDGE` shows nothing" callout) are the
    canonical phrasing to reuse/adapt.
  pattern: |
    The descriptor is a single-line JSON object: { ... }
    > `echo $PI_NVIM_BRIDGE` shows nothing in your shell — this is expected.
  critical: |
    DO NOT duplicate the nvim-plugin install/config in extension/README.md —
    the extension README is extension-scoped. Point readers to the root README
    + doc/pi-bridge.txt for the plugin half.

- file: doc/pi-bridge-shell.txt
  why: |
    The consumer-side (plugin) doc for the shell* descriptor fields and the
    prefer:"pi" contract (§17.4). The extension README should LINK to
    |pi-bridge-shell-prefer| / the `:help pi-bridge-shell` doc rather than
    re-explain the prefer contract in depth — but it should give the one-line
    summary ("the plugin uses these fields to match pi's execution shell for
    `!`/`!!` completion; see :help pi-bridge-shell").
  section: pi-bridge-shell-prefer (the prefer contract + fallback chain)

- file: PRD.md
  why: |
    §17.10 (BridgeDescriptor extension) and §17.10.2 (Resolution in the extension)
    are the design rationale for the shell.* fields + PI_NVIM_SHELL. §6.8 is the
    pi-vs-omp host-compat reference. §2.1 is the process.env inheritance
    discovery. The extension README should cite these sections by number for the
    reader who wants the full design.
  section: §17.10, §17.10.2, §6.8, §2.1

- file: extension/tests/shell-resolver.test.ts
  why: |
    The authoritative, executable spec for the 3-branch resolution chain — every
    test here is a claim the README's `PI_NVIM_SHELL` section must be consistent
    with (e.g. "PI_NVIM_SHELL wins over SHELL when both set"). Reading it confirms
    the precedence + the shellSource mapping before writing prose.
```

### Current Codebase tree (relevant slice)

```bash
pi-nvim-bridge/
├── README.md                 # repo README (S1) — extension + nvim plugin, GitHub/npm landing
├── package.json              # `files`: extension/*.ts + README.md + LICENSE  (npm tarball scope)
├── extension/
│   ├── pi-nvim-bridge.ts     # entry; resolveShell(), SHELL_MIRROR_ENV, startBridge() descriptor write
│   ├── connection.ts         # JSON-RPC server + dispatch + connection registry
│   ├── jsonl-reader.ts       # newline-delimited JSON framing (server side)
│   ├── protocol.ts           # type-only: BridgeDescriptor (+shell.*) + RPC envelopes
│   ├── tsconfig.json
│   └── tests/                # node:test + jiti suites (incl. shell-resolver.test.ts)
│   └── README.md             # ← THIS TASK CREATES THIS FILE (extension-scoped docs)
├── doc/
│   ├── pi-bridge.txt         # :help pi-bridge (S2 touched this)
│   ├── pi-bridge-shell.txt   # :help pi-bridge-shell (P2.M3.T6.S4)
│   └── tags
├── lua/pi-bridge/  plugin/pi-bridge.lua  ftplugin/pi-prompt.lua  tests/
└── PRD.md
```

### Desired Codebase tree with files to be added

```bash
extension/
└── README.md   # NEW (this task). Extension-scoped docs: descriptor fields + PI_NVIM_SHELL + host compat + dev.
```

### Known Gotchas of our codebase & Library Quirks

```python
# CRITICAL (npm `files` scope): package.json's `files` array is
#   ["extension/*.ts", "README.md", "LICENSE"]
# — note it scopes the published tarball to extension/*.ts (NOT extension/**) plus
# the REPO-ROOT README.md. Therefore extension/README.md is NOT shipped in the npm
# tarball by default. This is FINE and intended (the npm page shows the root
# README.md; extension/README.md is for source-browsers / git readers). DO NOT
# "fix" this by widening `files` to "extension/**" — that would leak test files
# + tsconfig into the tarball. If you want extension/README.md in the tarball,
# the correct minimal change is adding "extension/README.md" to `files` — but
# that is OUT OF SCOPE for this doc task; leave package.json untouched and just
# note in extension/README.md that it lives in the git repo (not the npm tarball).

# GOTCHA (shellPath omission): in the $SHELL and "default" branches,
# resolveShell() returns { shell, shellSource } with NO shellPath (undefined).
# JSON.stringify drops undefined object values, so the descriptor line a typical
# machine emits has shell + shellSource but NO shellPath key. The README's
# example JSON must reflect this — do NOT show `"shellPath": undefined` or
# `"shellPath": null`; either omit it or show it only in the PI_NVIM_SHELL
# example where it IS present.

# GOTCHA (serverVersion): the descriptor's serverVersion is the literal "0.1.0"
# (BRIDGE_VERSION constant in pi-nvim-bridge.ts), NOT the package.json version
# (which is tag-driven and may differ at release time). Document "0.1.0" as the
# current bridge protocol/handshake version, and note it is independent of the
# npm package version.

# GOTCHA (env-var name): the constant is `SHELL_MIRROR_ENV = "PI_NVIM_SHELL"`.
# It is NOT `PI_BRIDGE_SHELL` or `PI_SHELL`. Use the exact name `PI_NVIM_SHELL`
# everywhere in the README. (The discovery/env var is `PI_NVIM_BRIDGE` —
# different var, different purpose: BRIDGE advertises the socket; SHELL mirrors
# the shellPath setting.)

# GOTCHA (host gate): under omp, `ctx.mode` is undefined; the extension's
# `isInteractiveSession(ctx)` accepts `ctx.mode === "tui"` OR
# `(ctx as ...).hasUI === true`. Document BOTH signals. Under omp the manifest
# key `(pkg.omp ?? pkg.pi).extensions` discovers the same `"pi": {extensions}`
# field as a fallback — no manifest change is needed.

# CRITICAL (read-only boundary): this is a Mode B doc task. You MAY create
# extension/README.md. You MUST NOT modify PRD.md, tasks.json, prd_snapshot.md,
# any source .ts/.lua, package.json, or the root README.md. If you believe the
# root README needs a change, that is S1's scope, not S3's.
```

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ the authoritative sources (no edits yet)
  - READ extension/protocol.ts → copy the BridgeDescriptor field list (10 fields:
    7 required + 3 optional shell.*) into your notes; note the shellSource union.
  - READ extension/pi-nvim-bridge.ts lines ~319-323 (SHELL_MIRROR_ENV) and ~451-457
    (resolveShell) → copy the exact 3-branch chain. Note shellPath is undefined
    in branches 2 and 3.
  - READ extension/pi-nvim-bridge.ts lines ~635-650 (startBridge descriptor write)
    → confirm the JSON shape emitted + that serverVersion is BRIDGE_VERSION ("0.1.0").
  - READ README.md (root) sections "How it works", "The PI_NVIM_BRIDGE environment
    variable", "Troubleshooting", "Development", "Repository layout" → absorb voice.
  - READ doc/pi-bridge-shell.txt §pi-bridge-shell-prefer → one-line summary only.
  - READ extension/tests/shell-resolver.test.ts → confirm precedence claims.
  - NO file is modified in this task; it is pure research to ground every claim.

Task 2: CREATE extension/README.md — structure + body
  - CREATE extension/README.md with this section order:
      1. Title + one-paragraph "What it is" (extension = pi-side half; link root README).
      2. "Installation" (pi install npm:… / git:…; pi list; omp equivalent; link root README for nvim plugin).
      3. "How it works" (3 numbered steps: capture, env discovery, JSON-RPC).
      4. "The PI_NVIM_BRIDGE descriptor" (field table: 10 rows; mark shell.* optional/advisory; plugin fallback).
      5. "PI_NVIM_SHELL — matching pi's execution shell" (the 3-branch chain; why it exists; worked zsh example).
      6. "Host compatibility — pi and oh-my-pi (omp)" (dual mode guard; manifest fallback).
      7. "Development" (npm run typecheck; node:test + jiti pointer to extension/tests/).
      8. "See also" footer (root README.md, doc/pi-bridge.txt, doc/pi-bridge-shell.txt, PRD.md § refs).
  - FOLLOW pattern: root README.md voice — terse, ```jsonc fenced blocks, `> ` callouts
    for gotchas, no marketing prose.
  - NAMING: file is extension/README.md (lowercase, repo-root convention).
  - PLACEMENT: extension/ directory (sibling of pi-nvim-bridge.ts). NOT the repo root.

Task 3: VERIFY accuracy (no edits unless a claim is wrong)
  - GREP the new README for `PI_NVIM_SHELL` — confirm it matches SHELL_MIRROR_ENV.
  - GREP for `0.1.0` — confirm serverVersion matches BRIDGE_VERSION.
  - Re-read the descriptor field table against protocol.ts BridgeDescriptor —
    every field name + type + optionality must match.
  - Confirm the 3-branch resolution prose matches resolveShell() exactly.
  - Confirm `shellPath` is shown ONLY in the PI_NVIM_SHELL (branch 1) example,
    omitted from the default/$SHELL examples.
  - Confirm NO other file was modified (git status shows only extension/README.md new).

Task 4: (no tests) Documentation has no automated test. The "validation" is the
  accuracy cross-check in Task 3 + a human read-through. Do NOT invent a test.
```

### Implementation Patterns & Key Details

```python
# Pattern: the descriptor field table (Markdown). Use this exact shape, filling
# from protocol.ts BridgeDescriptor. Mark optionality explicitly.

# | Field | Type | Required? | Source / meaning |
# |---|---|---|---|
# | transport | `"unix"` | yes | literal v1 |
# | path | string | yes | socket path (/tmp/pi-nvim-bridge-<uuid>.sock, 0600) |
# | token | string | yes | 32-byte hex; the REAL auth boundary (validated in `hello`) |
# | pid | number | yes | process.pid |
# | cwd | string | yes | ctx.cwd (session working dir) |
# | fdAvailable | boolean | yes | whether `fd`/`fdfind` is resolvable (for @file) |
# | serverVersion | string | yes | bridge protocol version ("0.1.0"); independent of npm version |
# | shell | string | **no** | §17.10 advisory: resolved shell pi runs `!`/`!!` in |
# | shellSource | `"pi"\|"$SHELL"\|"$default"` | **no** | how `shell` was derived |
# | shellPath | string | **no** | raw shellPath mirror; present ONLY when shellSource=="pi" |

# Pattern: the PI_NVIM_SHELL 3-branch chain as prose + a worked example.
# Prose (mirror resolveShell() exactly):
#   1. If PI_NVIM_SHELL is set  → shell = that value, shellSource = "pi",
#      shellPath = that value.  (This is the "I want prefer:'pi' to resolve to
#      a specific shell" branch.)
#   2. Else if $SHELL is set    → shell = $SHELL, shellSource = "$SHELL", no shellPath.
#      (Typical machine default — advisory only; plugin's prefer:'pi' then matches $SHELL.)
#   3. Else                     → shell = "/bin/bash", shellSource = "default", no shellPath.
#      (pi's getShellConfig Unix default.)
# Worked example (zsh user wanting native zsh ! completions + execution consistency):
#   export PI_NVIM_SHELL=/bin/zsh   # in the shell that launches pi
#   # → descriptor gains shell:"/bin/zsh", shellSource:"pi", shellPath:"/bin/zsh"
#   # → plugin's prefer:"pi" resolves to zsh → zsh completions AND pi runs ! in zsh.
# Honesty note (quote PRD §17.10.2): the extension CANNOT read settingsManager/
# getShellConfig() (not on ExtensionContext); PI_NVIM_SHELL is a manual mirror of
# pi's shellPath setting. Cite PRD §17.17 (future upstream ctx.getShellConfig()).

# Pattern: the "shows nothing in your shell" callout (reuse root README phrasing,
# adapted to be extension-scoped):
# > `echo $PI_NVIM_BRIDGE` (and `echo $PI_NVIM_SHELL`) show nothing in your shell
# > unless YOU export them. `PI_NVIM_BRIDGE` is written to process.env INSIDE pi
# > and is only visible to the child $EDITOR pi spawns. `PI_NVIM_SHELL` is the
# > reverse: YOU set it in the shell that launches pi so the extension can read it.
```

### Integration Points

```yaml
DOCUMENTATION (no code/config integration):
  - new file: extension/README.md
  - cross-links OUT (the new README points to):
      - ../README.md            (root — full repo + nvim plugin install/config)
      - ../doc/pi-bridge.txt    (:help pi-bridge)
      - ../doc/pi-bridge-shell.txt (:help pi-bridge-shell — prefer contract, drivers)
      - ../PRD.md §17.10, §17.10.2, §6.8, §2.1 (design rationale)
  - cross-links IN (nothing needs to link TO extension/README.md for this task;
      the root README's "Repository layout" already lists extension/ — optionally
      S1 could add a pointer, but that is S1's scope, not S3's; leave the root
      README untouched).

NO CHANGES TO:
  - package.json (the `files` scope is correct as-is; extension/README.md is a
      git-repo doc, not an npm-tarball doc — see Known Gotchas)
  - any .ts / .lua / .json (other than the new README) / PRD.md / tasks.json
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# Markdown lint (if available; optional — do not fail the task if mdl isn't installed)
# Project has no markdown linter configured; a manual render-check is the gate.
# Render-check: paste extension/README.md into GitHub's preview OR run:
npx --yes markdownlint-cli2 extension/README.md 2>/dev/null || echo "markdownlint not required"

# Confirm every fenced code block is closed (count ``` fences — must be even):
grep -c '^```' extension/README.md   # expect an EVEN number

# Confirm the only new file is extension/README.md:
git status --porcelain
# Expected: exactly one line: "?? extension/README.md"  (no M lines, no other ??)
```

### Level 2: Accuracy Cross-Check (the REAL gate — no test suite exists for docs)

```bash
# 1. PI_NVIM_SHELL env-var name matches the code constant exactly:
grep -c '"PI_NVIM_SHELL"' extension/pi-nvim-bridge.ts   # ≥1 (the SHELL_MIRROR_ENV value)
grep -c 'PI_NVIM_SHELL' extension/README.md             # ≥1 (documented)

# 2. serverVersion "0.1.0" matches BRIDGE_VERSION:
grep -n 'BRIDGE_VERSION' extension/pi-nvim-bridge.ts | grep '0\.1\.0'   # the constant
grep -c '0\.1\.0' extension/README.md                                   # documented

# 3. Every BridgeDescriptor field is mentioned in the README's field table:
for f in transport path token pid cwd fdAvailable serverVersion shell shellSource shellPath; do
  grep -q "$f" extension/README.md || echo "MISSING field in README: $f"
done
# Expected: no MISSING lines.

# 4. The 3-branch resolution chain is documented (PI_NVIM_SHELL → $SHELL → /bin/bash):
grep -q 'PI_NVIM_SHELL' extension/README.md
grep -q 'SHELL' extension/README.md
grep -q '/bin/bash' extension/README.md

# 5. shellPath omission gotcha: the default/$SHELL example must NOT show shellPath:
#    (manual eyeball — confirm the worked example that sets PI_NVIM_SHELL is the
#     ONLY place shellPath appears with a value.)

# Expected: all greps succeed; no MISSING lines.
```

### Level 3: Integration / Render Validation

```bash
# Render the Markdown to confirm it is valid + readable (uses any available renderer):
# Option A — GitHub-style via npx (no install):
npx --yes markdown-it extension/README.md > /tmp/ext-readme.html 2>/dev/null && \
  echo "renders OK ($(wc -l < /tmp/ext-readme.html) html lines)" || \
  echo "markdown-it unavailable — manual review required"

# Confirm cross-link targets exist (no broken relative links):
for tgt in ../README.md ../doc/pi-bridge.txt ../doc/pi-bridge-shell.txt ../PRD.md; do
  test -f "extension/$tgt" && echo "OK: $tgt" || echo "BROKEN LINK: $tgt"
done
# Expected: all OK.

# Confirm the descriptor JSON example parses (copy it out and jq it):
#   (extract the ```jsonc block by hand into /tmp/desc.json, then:)
#   jq . /tmp/desc.json && echo "valid JSON"
```

### Level 4: Domain-Specific Validation

```bash
# Confirm no protected files were touched (Mode B read-only boundary):
git status --porcelain | grep -E 'PRD\.md|tasks\.json|prd_snapshot\.md|package\.json|\.ts$|\.lua$' && \
  echo "VIOLATION: protected file modified" || echo "OK: only extension/README.md touched"

# Line-count sanity (the file should be ~120-180 lines — terse, not a wall):
wc -l extension/README.md

# Confirm voice consistency with root README (spot-check a callout phrase shape):
grep -c '^>' extension/README.md   # should have a few `> ` callouts (matches root README style)
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: fenced code block count is even; `git status` shows only `?? extension/README.md`.
- [ ] Level 2: all 10 descriptor fields present; `PI_NVIM_SHELL` / `0.1.0` / 3-branch chain accurate.
- [ ] Level 3: all relative cross-links (`../README.md`, `../doc/*.txt`, `../PRD.md`) resolve.
- [ ] Level 4: no protected file modified; line count ~120-180.

### Feature Validation

- [ ] `extension/README.md` documents the `PI_NVIM_BRIDGE` descriptor with a 10-field table.
- [ ] The 3 optional `shell*` fields are marked optional/advisory with the plugin fallback stated.
- [ ] `PI_NVIM_SHELL` is documented with the exact 3-branch resolution order + a worked example.
- [ ] The honesty note (extension cannot read `getShellConfig`) is present + cites PRD §17.10.2.
- [ ] pi-vs-omp host compatibility is documented (dual mode guard + manifest fallback).
- [ ] Cross-links to root README, doc/pi-bridge*.txt, and PRD.md are present.

### Code Quality Validation

- [ ] Voice matches the root README (terse, troubleshooting-aware, no marketing fluff).
- [ ] Descriptor JSON examples are byte-consistent with `startBridge()` output
      (serverVersion `"0.1.0"`; `shellPath` omitted in non-`pi` branches).
- [ ] No invented fields / no invented env vars (everything traces to `protocol.ts` or
      `pi-nvim-bridge.ts`).

### Documentation & Deployment

- [ ] The file is self-contained for the extension's own surface (a reader need not
      open the source to understand what the extension does + what env vars it touches).
- [ ] It explicitly defers to the root README + vimdoc for the nvim-plugin half
      (no duplication).

---

## Anti-Patterns to Avoid

- ❌ Don't duplicate the root README's nvim-plugin install/config/lazy.nvim blocks —
  this is extension-scoped; cross-link instead.
- ❌ Don't re-explain the `prefer:"pi"` contract or shell drivers in depth — that's
  `doc/pi-bridge-shell.txt`'s job; give a one-line summary + a `:help` link.
- ❌ Don't invent descriptor fields or env-var names — every name MUST trace to
  `protocol.ts` (`BridgeDescriptor`) or `pi-nvim-bridge.ts` (`SHELL_MIRROR_ENV`,
  `BRIDGE_VERSION`).
- ❌ Don't widen `package.json`'s `files` array to ship `extension/README.md` in
  the npm tarball — that's a packaging decision out of scope for a doc task;
  the file lives in the git repo (source browsers, GitHub), which is correct.
- ❌ Don't modify any `.ts`, `.lua`, `package.json`, `PRD.md`, `tasks.json`, or the
  root `README.md` — this is Mode B (one new doc file only).
- ❌ Don't write a test — documentation has no automated test; the gate is the
  Level 2 accuracy cross-check + human review.
- ❌ Don't pad the README to hit a line count — terse is correct; ~120-180 lines is
  a sanity bound, not a target.