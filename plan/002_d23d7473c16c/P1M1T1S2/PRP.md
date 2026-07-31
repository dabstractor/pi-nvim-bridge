---
name: "P1.M1.T1.S2 — Sync README.md install section for omp host path"
description: |
  DOCUMENTATION-ONLY task (Mode B). Update `README.md` so the **Installation**
  section documents the **oh-my-pi (`omp`) host install path** alongside the
  existing `pi` path, plus a one-line "runs under either host with zero code
  change" note and a Prerequisites bullet tweak. Add the three verified omp
  commands (`omp plugin install npm:pi-nvim-bridge`, `omp plugin list`,
  `omp plugin doctor`) as an alternative subsection. Do NOT change the Neovim
  plugin install instructions (host-agnostic — keys only on `PI_NVIM_BRIDGE`).
  No code, no tests, no mocking. INPUT = the verified 5-claim omp-compat report
  from P1.M1.T1.S1 (the code half is already complete; residual work is docs).
---

## Goal

**Feature Goal**: `README.md`'s **Installation** section documents **both** the
`pi` host install path (already present) **and** the `oh-my-pi` (`omp`) host
install path (new), with a clear one-line statement that the extension runs
under either host with zero code change — so an omp user can install, verify, and
health-check the bridge by following the README alone.

**Deliverable**: Edits to exactly one file — `README.md`:
1. **`## Installation`**: insert a new **omp (`oh-my-pi`)** alternative
   subsection containing the three verified commands
   (`omp plugin install npm:pi-nvim-bridge`, `omp plugin list`,
   `omp plugin doctor`), placed **alongside** the existing `pi install` block;
   add the "either host / zero code change" one-line note.
2. **`## Prerequisites`**: amend the first bullet to name `omp` as an alternative
   host (per PRD §10.1), so Prerequisites and Installation are coherent.
3. **Preserve verbatim**: the existing `pi install` block, the
   `⚠️ Multi-file package` warning, and the entire **Companion plugin**
   (Neovim) install block.

**Success Definition**: A reader who uses `omp` (not `pi`) can follow the
README's Installation section to install `pi-nvim-bridge`, confirm it via
`omp plugin list`, and health-check it via `omp plugin doctor` — without
consulting any other doc. The three omp commands are **byte-accurate** (verified
empirically: `omp/17.1.3`). The pi path and the host-agnostic Neovim plugin
instructions are unchanged.

## User Persona (if applicable)

**Target User**: A pi-nvim-bridge user who runs the **oh-my-pi (`omp`) fork**
instead of upstream `pi` (Bun runtime, `omp` binary, `~/.omp/plugins/` dir).

**Use Case**: Install the bridge extension under omp and get pi-faithful
completion in the external `$EDITOR` (Neovim) — the same workflow pi users have.

**User Journey**: omp user opens README → Prerequisites confirms omp is a
supported host → Installation shows the omp commands → runs
`omp plugin install npm:pi-nvim-bridge` → `omp plugin list` shows
`pi-nvim-bridge` → `omp plugin doctor` reports it healthy → installs the
companion `pi-bridge.nvim` plugin (unchanged, host-agnostic) → launches `$EDITOR`
from omp → completion works.

**Pain Points Addressed**: Today the README documents only `pi install` /
`pi list`, so an omp user has no documented path and may assume the bridge is
pi-only. omp is fully supported (code-complete per `system_context.md`); this
task closes the docs gap.

## Why

- **The code is already done; docs are the residual work.** `system_context.md`
  states: *"Change A (omp host compat): Code-complete. The dual-detection mode
  gate `isInteractiveSession(ctx)` … already accepts `ctx.mode === "tui"` OR
  `ctx.hasUI === true`. Residual work is documentation only."* The preceding
  task **S1** verifies those 5 invariants; **S2 (this task) is the documentation.**
- **omp discoverability is empirically proven, not theorized.** On this machine
  `omp/17.1.3` is installed, `omp plugin list` already shows
  `● pi-nvim-bridge@0.1.0`, and `omp plugin doctor` reports it healthy
  (`Summary: 6 ok, 0 warnings, 0 errors`). The `"pi"` manifest key is omp's
  `(pkg.omp ?? pkg.pi).extensions` fallback. Documenting this costs nothing and
  unblocks omp users.
- **Coherence with PRD §10.** PRD §10.1 (Prerequisites) and §10.2 (Install the
  bridge extension) both already specify the omp path; the README has drifted
  behind the spec. This task re-syncs README to the PRD's install surface.
- **Low-risk, high-value.** A pure-doc additive edit with no code/test/build
  surface — it cannot regress the extension or the Neovim plugin.

## What

Three additive, precisely-scoped edits to `README.md`:

1. **`## Prerequisites`** — amend the first bullet from
   `- **pi** with extension support.` to name omp as an alternative host
   (matches PRD §10.1).
2. **`## Installation`** — keep the existing `pi install` block; insert a new
   **omp (`oh-my-pi`)** alternative subsection with the three verified commands;
   add the one-line "either host / zero code change" note.
3. Leave the `⚠️ Multi-file package` warning (applies to both hosts) and the
   entire **Companion plugin** block (host-agnostic) untouched.

No other file is modified. No code, no `package.json` change (do NOT add an
`"omp"` key — the `"pi"` key is the omp fallback by design), no tests.

### Success Criteria

- [ ] `README.md` `## Installation` contains an **omp** subsection with the three
      EXACT commands: `omp plugin install npm:pi-nvim-bridge`, `omp plugin list`,
      `omp plugin doctor`.
- [ ] The one-line note "runs under either host (pi or omp) with zero code
      change" (or semantically identical wording) is present in/near the
      Installation section.
- [ ] `## Prerequisites` first bullet names `omp` as an alternative host.
- [ ] The existing `pi install npm:pi-nvim-bridge` / `pi install .` / `pi list`
      block is preserved (grep still matches `pi install` and `pi list`).
- [ ] The `⚠️ Multi-file package — no single-file drop-in.` warning is preserved.
- [ ] The **Companion plugin** (Neovim) install block (lazy.nvim + the
      runtimepath note + `:help pi-bridge`) is byte-for-byte unchanged.
- [ ] No shell-completion feature content added (that is P2.M4.T7.S1, later).
- [ ] The three omp commands are accurate (verified empirically — see Context).

## All Needed Context

### Context Completeness Check

_Pass test_: An agent who has never seen this repo can open `README.md`, locate
the `## Prerequisites` and `## Installation` sections from the exact current
content quoted below, apply the three edits using the reference markdown provided,
and confirm correctness with the grep gate + the cited empirical omp output —
without reading any other file. Every command string, the exact current README
text at the edit sites, and the verified omp CLI output are all in this PRP.

### Documentation & References

```yaml
# MUST READ — the file being edited (current, full content already captured in this PRP's Blueprint)
- file: README.md
  why: the sole edit target; its ## Prerequisites and ## Installation sections are the edit sites
  section: "## Prerequisites (first bullet) and ## Installation (pi block + Multi-file warning + Companion plugin block)"
  critical: |
    The current ## Installation documents ONLY `pi install npm:pi-nvim-bridge`,
    `pi install .`, and `pi list`. There is NO omp content anywhere in README.md
    today. The Companion plugin block that follows is HOST-AGNOSTIC and must be
    left verbatim (it keys only on PI_NVIM_BRIDGE).

# MUST READ — the spec being synced to (PRD install surface)
- docfile: PRD.md
  why: §10.1 (Prerequisites) and §10.2 (Install the bridge extension) + §6.8 (Host compat) define the exact omp commands and the "either host" claim
  section: "h3.25 (§10.1 Prerequisites), h3.26 (§10.2 Install — shows the omp install/list/doctor commands), h3.17 (§6.8 Host compatibility divergence table)"
  critical: |
    §10.2 already specifies the omp install block (install/list/doctor). §6.8
    gives the divergence table (omp CLI = `omp plugin install`/`omp plugin list`,
    dir ~/.omp/plugins/, manifest fallback `(pkg.omp ?? pkg.pi).extensions`).
    §10.1 mandates Prerequisites name omp. README must match.

# MUST READ — the preceding task's PRP (the INPUT: the verified omp-compat report basis)
- docfile: plan/002_d23d7473c16c/P1M1T1S1/PRP.md
  why: S1 produces the 5-claim PASS/FAIL report that this task's "zero code change" claim rests on (claims A–E: dual-detection gate, guard ordering, host-agnostic descriptor, "pi" manifest key, all-imports-type-only)
  section: "Goal + Verification Tasks (claims A–E) + the PRE-CHECK note 'all 5 claims PASS'"
  critical: |
    S1 is READ-ONLY verification (no code change). Its output is EVIDENCE this
    task cites. Assume S1's 5 claims PASS (the PRE-CHECK confirms they do). This
    task does NOT re-verify the code — it documents the omp install path that the
    verified code enables.

# MUST READ — architecture (pre-researched, code-complete confirmation)
- docfile: plan/002_d23d7473c16c/architecture/system_context.md
  why: confirms "Change A (omp host compat): Code-complete … Residual work is documentation only" + the manifest fallback + plugin dir
  section: "'Overview — Change A (omp host compat)' + 'Extension side' table row 'package.json manifest'"
- docfile: plan/002_d23d7473c16c/architecture/research-extension-side.md
  why: §2c documents the isInteractiveSession host fork (ctx.mode==="tui" OR ctx.hasUI===true) — the rationale for "zero code change"
  section: "§2c 'isInteractiveSession(ctx) — exact implementation (lines 1119-1138)'"

# SUPPORTING — the manifest (confirms the "pi" fallback key + npm package name)
- file: package.json
  why: confirms the manifest discovery key is "pi" (omp's fallback) and the published name is "pi-nvim-bridge" (the omp target)
  section: '"name": "pi-nvim-bridge" and "pi": { "extensions": ["./extension/pi-nvim-bridge.ts"] }'
  gotcha: "There is intentionally NO \"omp\" key. Do NOT add one — the \"pi\" key IS the omp fallback. (Out of scope anyway: this task edits only README.md.)"

# SUPPORTING — local research notes for S2 (empirical omp evidence + exact edit sites)
- docfile: plan/002_d23d7473c16c/P1M1T1S2/research/notes.md
  why: every omp command verified empirically (omp/17.1.3 outputs captured); exact current README text at the edit sites; scope boundaries
```

### Current Codebase tree (only README.md is touched)

```bash
pi-nvim-bridge/
├── README.md                 # <-- THE SOLE EDIT TARGET (## Prerequisites + ## Installation)
├── package.json              # "pi" manifest key (omp fallback) — NOT edited
├── extension/                # TS extension — NOT edited (S1 verifies it)
├── lua/pi-bridge/            # Neovim plugin — NOT edited
├── doc/pi-bridge.txt         # vimdoc — NOT edited (P2.M4.T7.S2 cross-links later)
└── ...
```

### Desired Codebase tree with files to be added/modified

```bash
README.md   # (MODIFY) +omp subsection in ## Installation + omp line in ## Prerequisites
# (NO new files. NO code. NO tests. NO package.json.)
```

### Known Gotchas of our codebase & Library Quirks

```markdown
<!-- CRITICAL: omp's CLI shape is `omp plugin install <target>` (space-separated
     action+target), NOT `omp install <target>` (pi's shape). Getting this wrong
     = broken docs. Verified exact: `omp plugin install npm:pi-nvim-bridge`. -->

<!-- CRITICAL: the install TARGET prefix is `npm:` (matches the existing
     `pi install npm:pi-nvim-bridge` line). Do NOT invent `git:`/`omp:` prefixes
     for omp. The dry-run `[dry-run] Would install npm:pi-nvim-bridge` confirms it. -->

<!-- CRITICAL: the "⚠️ Multi-file package — no single-file drop-in." warning
     applies to omp TOO (omp also cannot drop in a single file — it discovers the
     same package). Do NOT move it under only the pi subsection. Keep it shared. -->

<!-- CRITICAL: the Companion plugin (Neovim) install block is HOST-AGNOSTIC —
     activation gates on the PI_NVIM_BRIDGE env var, not on pi-vs-omp. The
     contract FORBIDS changing it. Leave it byte-for-byte verbatim. -->

<!-- GOTCHA: there is intentionally NO "omp" key in package.json. omp reads
     `(pkg.omp ?? pkg.pi).extensions`, so the "pi" key IS its fallback. Do NOT
     add an "omp" key (that would be a code/manifest change, out of scope, and
     unnecessary). This task touches ONLY README.md. -->

<!-- SCOPE: do NOT add shell-completion feature content (PRD §17). That README
     augmentation is a LATER task — P2.M4.T7.S1. This task is ONLY the omp
     install-path documentation. -->

<!-- STYLE: match the existing README's markdown voice (terse, second-person,
     fenced ```bash blocks with `# comment` lines, `>` callouts for warnings).
     Use a heading level one deeper than `## Installation` (i.e. `###`) for the
     omp subsection so it nests cleanly. -->
```

## Implementation Blueprint

### Data models and structure

Not applicable — documentation edit. No data structures.

### Implementation Tasks (ordered; all edits to `README.md`)

```yaml
Task 1: AMEND the ## Prerequisites first bullet (coherence with PRD §10.1)
  - FIND: the line ` - **pi** with extension support.` under `## Prerequisites`.
  - REPLACE with (or augment to): a bullet naming omp as an alternative host, e.g.
      `- **pi** with extension support — or the **oh-my-pi** fork (\`omp\`); the
       extension runs under either host (see Installation below).`
  - DO NOT: touch the Neovim / fd / companion-plugin bullets.
  - WHY: PRD §10.1 mandates this; a reader seeing omp in Installation but only pi
      in Prerequisites would be confused. Minimal, consistency-preserving edit.

Task 2: INSERT the omp alternative subsection inside ## Installation
  - FIND: the existing pi install block (the ```bash fence with `pi install
      npm:pi-nvim-bridge` and `pi install .`) followed by the `Verify:` block
      (`pi list`).
  - INSERT immediately AFTER the `Verify:` ```bash block (and BEFORE the
      `⚠️ Multi-file package` warning) a new subsection. Reference markdown:

      ### oh-my-pi (`omp`)

      The extension also runs under the **oh-my-pi** fork (`omp`, Bun runtime)
      with **zero code change** — every `@earendil-works/*` import is `import
      type`-only, so omp's loader erases it at load, and omp reads the same
      `"pi"` manifest key as a fallback (`(pkg.omp ?? pkg.pi).extensions`).

      ```bash
      omp plugin install npm:pi-nvim-bridge
      omp plugin list        # should show "pi-nvim-bridge"
      omp plugin doctor      # should report it healthy (✔ plugin:pi-nvim-bridge)
      ```

  - NAMING/HEADING: use a `###` subsection (one level under `## Installation`)
      titled "oh-my-pi (`omp`)" so it nests alongside the pi path.
  - COMMANDS: EXACTLY the three verified commands (see Context / research notes).
      Keep the `# comment` hints aligned with the verified output.
  - DO NOT: duplicate the local-clone (`pi install .`) variant under omp (it is
      pi-specific; omit). Do NOT mention plugin dir paths (~/.omp/plugins) — the
      CLI commands are what users run.

Task 3: PRESERVE the shared warnings + the host-agnostic Companion plugin block
  - KEEP VERBATIM: the `> ⚠️ **Multi-file package — no single-file drop-in.**`
      warning (it applies to BOTH hosts — do not move it under only the pi path).
  - KEEP VERBATIM: the entire **Companion plugin** (`pi-bridge.nvim`) install
      block — the lazy.nvim snippet, the `lazy = false` note, the runtimepath
      explanation, and the `:help pi-bridge` reference. Activation is gated on
      `PI_NVIM_BRIDGE` (host-agnostic); the contract forbids changing it.
  - DO NOT: touch `## Configuration ($EDITOR)`, `## How it works`,
      `## PI_NVIM_BRIDGE`, `## Development`, or any other section.

Task 4: VALIDATE — run the grep presence gate + (optional) empirical re-confirm
  - RUN: the grep gate in Validation Loop Level 1 (omp commands present; pi path
      + companion block intact; no stray "omp" manifest key claim).
  - OPTIONAL: re-run `omp plugin list` / `omp plugin doctor` to re-confirm the
      documented output (already verified in this PRP's research; see Context).
```

### Implementation Patterns & Key Details

```markdown
<!-- === README.md — reference shape for the INSERT (Task 2) === -->
<!-- Insert this block INSIDE ## Installation, AFTER the `pi list` Verify fence, -->
<!-- BEFORE the `⚠️ Multi-file package` warning. Indentation/voice matches the   -->
<!-- existing README (terse, ```bash fences with `#` comments, `>` callouts).   -->

### oh-my-pi (`omp`)

The extension also runs under the **oh-my-pi** fork (`omp`, Bun runtime) with
**zero code change**: every `@earendil-works/*` import is `import type`-only
(so omp's loader erases it at load), and omp reads the same `"pi"` manifest key
as a fallback (`(pkg.omp ?? pkg.pi).extensions`).

```bash
omp plugin install npm:pi-nvim-bridge
omp plugin list        # should show "pi-nvim-bridge"
omp plugin doctor      # ✔ plugin:pi-nvim-bridge … Summary: 0 errors
```

> Prefer `omp` over `pi` only if you already run the oh-my-pi fork. The
> companion `pi-bridge.nvim` plugin install is identical under either host —
> it keys only on the `PI_NVIM_BRIDGE` env var the bridge advertises.

<!-- === README.md — Prerequisites bullet amendment (Task 1) === -->
<!-- BEFORE: - **pi** with extension support.                                   -->
<!-- AFTER:  - **pi** with extension support — or the **oh-my-pi** fork (`omp`); -->
<!--           the extension runs under either host (see Installation).         -->
```

### Integration Points

```yaml
NO code/config/build integration. Pure documentation.
  - The ONLY consumer is a human reader following the install steps.
  - No package.json change (do NOT add an "omp" key — the "pi" key is the omp
    fallback by design; adding "omp" is out of scope and unnecessary).
  - No doc/pi-bridge.txt change (cross-links to shell-completion vimdoc land in
    P2.M4.T7.S2 — later).
DOWNSTREAM (NOT this task):
  - P2.M4.T7.S1 will AUGMENT README.md with the shell-completion feature blurb.
    Leave room: do not lock the Installation section's structure in a way that
    blocks that future addition (a simple ### subsection is fine).
```

## Validation Loop

> This is a documentation change. There is **no markdown-lint or doc-compile
> gate** in the repo (`package.json` has only `typecheck` for TS; Lua tests run
> under nvim). Validation is therefore (1) a **grep presence/integrity gate**,
> (2) **empirical command accuracy** (already verified in this PRP's research),
> and (3) an optional render sanity check.

### Level 1: Presence & Integrity Gate (THE gate)

```bash
# (a) The three omp commands are present and EXACT:
grep -nE 'omp plugin install npm:pi-nvim-bridge' README.md && \
grep -nE 'omp plugin list' README.md && \
grep -nE 'omp plugin doctor' README.md \
  && echo "PASS: omp install commands present" || echo "FAIL: an omp command is missing/mis-spelled"

# (b) The "either host / zero code change" note is present:
grep -niE 'either host|zero code change|runs under (both|either)' README.md \
  && echo "PASS: either-host note present" || echo "FAIL: either-host note missing"

# (c) Prerequisites names omp:
grep -nE 'omp|oh-my-pi' README.md | grep -iE 'prerequis|^\s*- \*\*pi\*\*' \
  && echo "PASS: Prerequisites mentions omp" || echo "FAIL: Prerequisites still pi-only"

# (d) The existing pi path is INTACT (must still match):
grep -nE 'pi install npm:pi-nvim-bridge' README.md && \
grep -nE 'pi list' README.md \
  && echo "PASS: pi path preserved" || echo "FAIL: pi path was removed"

# (e) The shared Multi-file warning is INTACT:
grep -nE 'Multi-file package|no single-file drop-in' README.md \
  && echo "PASS: Multi-file warning preserved" || echo "FAIL: Multi-file warning lost"

# (f) The host-agnostic Companion plugin block is INTACT (lazy.nvim + runtimepath):
grep -nE 'lazy = false' README.md && grep -nE 'runtimepath|rtp' README.md \
  && echo "PASS: Companion plugin block preserved" || echo "FAIL: Companion block changed"

# (g) NO stray claim that package.json has an "omp" key (it must NOT):
grep -nE '"omp"\s*:' README.md \
  && echo "FAIL: README implies an omp manifest key (wrong)" || echo "PASS: no omp-key claim"
# Expected: all PASS. Any FAIL → fix the edit before committing.
```

### Level 2: Empirical Command Accuracy (re-confirm the docs are correct)

```bash
# The three documented commands are REAL and produce the cited output.
# (Already verified during this PRP's research; re-running is optional confirmation.)
omp --version                       # expect: omp/<version>  (e.g. omp/17.1.3)
omp plugin list | grep -i pi-nvim-bridge   # expect: ● pi-nvim-bridge@0.1.0
omp plugin doctor 2>&1 | grep -iE 'pi-nvim-bridge|errors'   # expect: ✔ plugin:pi-nvim-bridge … 0 errors
# Optional: confirm the install target syntax without side effects:
omp plugin install npm:pi-nvim-bridge --dry-run   # expect: [dry-run] Would install npm:pi-nvim-bridge
# NOTE: if `omp` is not installed on the validation machine, SKIP this level —
# the Level-1 grep gate + this PRP's captured evidence are sufficient. The
# commands are accurate (verified against omp/17.1.3).
```

### Level 3: Render & Anchor Sanity (optional but recommended)

```bash
# No formal markdown linter is configured. Do a light render/anchor check:
# (a) confirm no heading collision and the new ### nests under ## Installation:
grep -nE '^#+ ' README.md | grep -iE 'installation|oh-my-pi|omp|companion'
# Expected: a `## Installation` line, then a `### oh-my-pi` line nested below it,
# and the existing Companion-plugin heading unchanged.

# (b) confirm the only internal anchor still resolves (Prerequisites links to Installation):
grep -nE '\]\(#installation\)' README.md   # the Prerequisites→Installation cross-link
# Expected: the existing [Installation](#installation) link still present and valid.

# (c) OPTIONAL markdown render (if a renderer is available; not required):
# command -v mdformat >/dev/null && mdformat --check README.md || echo "mdformat not installed — skip (no gate)"
```

### Level 4: Holistic Read-Through

```bash
# Read the edited Installation section end-to-end as an omp user would:
sed -n '/^## Installation/,/^## Configuration/p' README.md
# Check: (1) pi path reads as before; (2) omp subsection follows naturally;
# (3) the Multi-file warning still applies to both; (4) the Companion plugin
# block is unchanged and reads host-agnostic. Nothing should imply omp needs a
# different Neovim plugin install or a different $EDITOR wiring.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 grep gate: all of (a)–(g) PASS.
- [ ] Level 2 (if `omp` available): `omp plugin list` shows `pi-nvim-bridge`;
      `omp plugin doctor` reports 0 errors. (If `omp` absent, rely on Level 1 +
      this PRP's captured evidence.)
- [ ] Level 3: new `### oh-my-pi` heading nests under `## Installation`; no
      heading collision; the `[Installation](#installation)` anchor still resolves.
- [ ] Level 4: holistic read-through — the section reads coherently for both a pi
      user and an omp user.

### Feature Validation

- [ ] `## Installation` documents BOTH pi and omp host paths.
- [ ] The three omp commands are byte-accurate (`omp plugin install
      npm:pi-nvim-bridge`, `omp plugin list`, `omp plugin doctor`).
- [ ] The "either host / zero code change" note is present.
- [ ] `## Prerequisites` names `omp` as an alternative host.
- [ ] The pi install block, the Multi-file warning, and the Companion plugin
      block are preserved verbatim.

### Code Quality Validation (doc-specific)

- [ ] Markdown voice/voice matches the existing README (terse, ```bash fences,
      `#` comments, `>` callouts).
- [ ] The omp subsection is a `###` nested under `## Installation`.
- [ ] No invented command prefixes (`git:`/`omp:`) — only the verified `npm:`.
- [ ] No claim that `package.json` has an `"omp"` key.
- [ ] No shell-completion content (deferred to P2.M4.T7.S1).

### Documentation & Deployment

- [ ] An omp user can install + verify + health-check the bridge from the README alone.
- [ ] The documented behavior matches PRD §10.1/§10.2/§6.8 and the verified omp output.
- [ ] No other doc (`doc/pi-bridge.txt`, `extension/README.md`) is touched here.

---

## Anti-Patterns to Avoid

- ❌ Don't write `omp install npm:pi-nvim-bridge` — omp's CLI is
  `omp plugin install <target>` (space-separated action+target). Verified exact.
- ❌ Don't invent a `git:` or `omp:` install target for omp — use `npm:` (matches
  the existing pi line and the verified dry-run).
- ❌ Don't move the `⚠️ Multi-file package` warning under only the pi path — it
  applies to omp too (omp also discovers the multi-file package, not a single file).
- ❌ Don't touch the Companion plugin (Neovim) install block — it's host-agnostic
  (keys on `PI_NVIM_BRIDGE`); the contract forbids changing it.
- ❌ Don't add an `"omp"` key to `package.json` or claim one exists — the `"pi"`
  key is omp's fallback by design; this task edits ONLY README.md.
- ❌ Don't add shell-completion feature content (PRD §17) — that's P2.M4.T7.S1.
- ❌ Don't restructure the whole Installation section or rewrite the pi path —
  this is an ADDITIVE insert (one new `###` subsection + the Prerequisites bullet).
- ❌ Don't skip the grep gate "because it's just docs" — it is the formal
  integrity check that the omp commands landed and the pi/plugin blocks survived.
- ❌ Don't pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — it hangs). This
  task needs no nvim at all; use `edit`/`write` for the README change.