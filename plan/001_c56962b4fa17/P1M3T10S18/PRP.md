# PRP — P1.M3.T10.S18: Create `package.json` manifest and `README.md`

## Goal

**Feature Goal**: Package the multi-file `pi-editor-bridge` extension as a
distributable **pi package** by adding a `package.json` manifest (with the
`pi.extensions` entry point) at the repo root, and document it with a `README.md`
— so the extension is installable via `pi install` (git or local) and loadable by
pi's package loader, replacing the now-impossible single-file drop-in install.

**Deliverable**:
- **CREATE** `package.json` (repo root) — the pi package manifest. Critical field:
  `"pi": { "extensions": ["./extension/pi-editor-bridge.ts"] }` (the existing,
  tested entry; NO rename). Plus best-practice fields (`name`, `version`,
  `type:"module"`, `keywords`, `license`, `peerDependencies`, optional
  `devDependencies` + `scripts`).
- **CREATE** `README.md` (repo root) — the extension's README: install (git/local),
  `$EDITOR` wiring, the `PI_EDITOR_BRIDGE` env var, troubleshooting (PRD §11),
  security (PRD §12), and development commands. Complete for the EXTENSION; notes
  the companion Neovim plugin is forthcoming (P2).
- **NO source code changes** — `pi-editor-bridge.ts`, `connection.ts`,
  `jsonl-reader.ts`, `protocol.ts`, `tests/`, `tsconfig.json` are all UNTOUCHED.

**Success Definition**:
- `package.json` is valid JSON with a `pi.extensions` array whose single entry
  `./extension/pi-editor-bridge.ts` resolves to an existing file.
- `pi -e .` (try-without-install) starts pi and **loads the extension with no load
  error** (the strongest non-interactive proxy for "pi accepts the package").
- `npx tsc --noEmit -p extension/tsconfig.json` still exits 0 (regression: a
  packaging-only change must not break the type-check).
- The existing `node --import "$JITI_REG" extension/tests/bridge-env.test.ts`
  suite still reports `ℹ fail 0` (the env-advertise logic the package depends on
  is intact).
- README covers every section listed in §"Implementation Tasks" Task 2.

## User Persona

**Target User**: A pi user who edits prompts in an external Neovim (`$EDITOR=nvim`)
and wants pi's in-prompt completion (slash commands, `skill:`, templates, `@file`,
paths) inside that Neovim instance.

**Use Case**: Installing this extension so pi advertises a `PI_EDITOR_BRIDGE`
socket descriptor to the Neovim it launches; the companion `pi-editor.nvim` plugin
(P2) then connects and renders completion.

**User Journey**: clone/copy repo → `pi install git:github.com/dabstractor/pi-nvim-bridge`
(or `pi install .`) → set `EDITOR=nvim` → start pi → press `Ctrl+G` → Neovim opens
with pi completion active.

**Pain Points Addressed**: the extension is 4 interdependent `.ts` files, so it
**cannot** be installed by copying one file (the old "simplest" PRD §9.1 path is
dead). Without a manifest, pi cannot locate the entry among the 4 files. This task
makes `pi install` "just work."

## Why

- **The extension outgrew single-file install.** PRD §9.1 offered two layouts;
  "simplest (single file)" is now impossible because `pi-editor-bridge.ts` imports
  `./connection.ts`, `./jsonl-reader.ts`, `./protocol.ts` (verified: relative
  `.ts` imports at pi-editor-bridge.ts:142-160). A single copied file has
  unresolved imports. The package-manifest path is the ONLY viable install — and
  it has been deferred until now (every prior P1 task said "packaging is S18").
- **Closes P1.M3 and all of P1.** S16 (env write) ✓, S17 (commandsChanged) ✓, S18
  (packaging) = the last item. Unblocks P2 (Neovim plugin) which assumes a
  runnable, installable bridge.
- **Distribution + discoverability.** A root `package.json` with `pi.extensions`
  is what makes `pi install git:...` resolve (pi reads the clone-ROOT manifest —
  see Context §"Known Gotchas" #1). The `pi-package` keyword enables gallery
  discoverability.
- **Zero risk to working code.** This is a manifest + docs task. It touches no
  `.ts`/`tsconfig`, so all 18 passing test files + the clean `tsc` are unaffected
  (only re-verified, not changed).

## What

User-visible behavior: none at runtime (the extension's behavior is unchanged — it
was already fully implemented in P1.M1–P1.M3.S17). What changes is **installability
and documentation**: users can now `pi install` the extension from the repo, and
the README explains how.

Technical requirement: a JSON manifest at the repo root declaring the extension
entry via the `pi` key, plus a Markdown README. pi's loader
(`dist/core/extensions/loader.js` → `resolveExtensionEntries`) reads `pkg.pi.extensions`
and `path.resolve(root, entry)` for each — so `["./extension/pi-editor-bridge.ts"]`
loads the existing entry with jiti resolving the sibling imports.

### Success Criteria

- [ ] `package.json` exists at repo root; `node -e "JSON.parse(require('fs').readFileSync('package.json','utf8'))"` exits 0.
- [ ] `package.json` has `"pi": { "extensions": ["./extension/pi-editor-bridge.ts"] }` and that file exists.
- [ ] `package.json` `name` is `"pi-editor-bridge"`; `version` is `"0.1.0"` (matches `BRIDGE_VERSION`); `type` is `"module"`; `keywords` includes `"pi-package"`.
- [ ] `package.json` lists `@earendil-works/pi-coding-agent` and `@earendil-works/pi-tui` in `peerDependencies` with `"*"` (packages.md convention).
- [ ] `README.md` exists at repo root and covers: what it does, prerequisites, install (git + local + "no single-file drop-in"), `$EDITOR` wiring, `PI_EDITOR_BRIDGE` env var, troubleshooting (≥ the PRD §11 items), security, development commands.
- [ ] `pi -e .` loads the extension with no error (or, if `-e` rejects a local dir in your pi build, `pi install . && pi list` shows `pi-editor-bridge`).
- [ ] `npx tsc --noEmit -p extension/tsconfig.json` exits 0 (regression).
- [ ] `node --import "$JITI_REG" extension/tests/bridge-env.test.ts` ⇒ `ℹ fail 0` (regression).
- [ ] NO files under `extension/` are modified (`git diff --stat extension/` is empty).

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ the implementer needs only this PRP + the repo
itself. Every decision (root vs subdir placement, entry path, field set, README
outline, validation commands) is justified below with citations to pi's dist
source, docs, the canonical `with-deps` example, and the actual extension tree.
No guesswork remains.

### Documentation & References

```yaml
# MUST READ — the manifest contract + resolution rules
- url: docs/packages.md  (installed: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/docs/packages.md)
  why: "THE pi-package spec. §'Creating a Pi Package' shows the {pi:{extensions:[...]}} manifest + 'pi-package' keyword. §'Dependencies' mandates peerDependencies '*' for @earendil-works/pi-coding-agent, pi-tui, typebox (do NOT bundle). §'Install and Manage' lists pi install git:/local/npm sources + 'pi -e' try-without-install + 'pi list'."
  critical: "§'Dependencies' is the authority for peerDependencies. §'Package Sources' documents git:github.com/user/repo@ref and local /abs or ./relative paths."

- url: docs/extensions.md  (same install prefix)
  why: "§'Package with dependencies' (L245-271) shows the canonical subdir package.json: {name, dependencies, pi:{extensions:['./src/index.ts']}} + 'npm install in the extension directory'. L117-120 lists auto-discovery locations including '~/.pi/agent/extensions/*/index.ts' (subdir entry fallback). L148-150: 'Add a package.json next to your extension (or in a parent directory)'; 'distributed pi packages ... runtime deps must be in dependencies; install uses npm install --omit=dev'."
  critical: "Confirms the manifest entry need NOT be index.ts (the pi.extensions array names exact files) AND that devDependencies are NOT available at runtime (--omit=dev)."

# MUST READ — the canonical package.json to mirror
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/examples/extensions/with-deps/package.json
  why: "The closest real example: {name, private, version, type:'module', scripts, pi:{extensions:['./index.ts']}, dependencies, devDependencies}. Mirror its SHAPE; adapt fields per this PRP's Decision (root placement, pi-editor-bridge.ts entry, peerDeps not runtime deps)."
  pattern: "name + version + type:module + pi.extensions + (peer/dev)Dependencies + scripts."
  gotcha: "with-deps sets private:true because it is a NON-distributable example. pi-editor-bridge IS distributable → OMIT private (defaults false). 'private' has zero effect on pi loading anyway."

# MUST READ — pi's loader/installer resolution (scout-verified against dist)
- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/extensions/loader.js
  why: "readPiManifest(pkgPath) returns pkg.pi; resolveExtensionEntries(dir) reads manifest.extensions → path.resolve(dir, extPath) for each → loads those EXACT files via jiti.import. index.ts/index.js is ONLY the no-manifest fallback. PROVES entry need not be index.ts and that './extension/pi-editor-bridge.ts' resolves from the package root."
  pattern: "manifest.extensions entries are resolved relative to the package.json dir (the package root)."

- file: /home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/dist/core/package-manager.js
  why: "installGit (L1498-1522): clones to targetDir, reads join(targetDir,'package.json') — CLONE ROOT ONLY (no subdir manifest walk). resolveLocalExtensionSource (L1038-1061): the given dir IS baseDir → reads <dir>/package.json. readPiManifest (L1841-1853): returns pkg.pi ?? null. collectPackageResources (L1740-1782): manifest entries resolve relative to root; else convention <root>/extensions/."
  critical: "PROVES git install reads ONLY the repo-root package.json — this is WHY the manifest must live at the repo ROOT, not in extension/. (A root manifest's entry path MAY point into a subdir.)"

# MUST READ — the extension being packaged (read-only; do NOT modify)
- file: extension/pi-editor-bridge.ts
  why: "The ENTRY file the manifest must point at. Confirms `export default function (pi: ExtensionAPI): void` at L983 (valid pi factory) + module exports (BRIDGE_VERSION='0.1.0' L272, BRIDGE_ENV='PI_EDITOR_BRIDGE' L281). Lines 142-160 import ./connection.ts, ./jsonl-reader.ts, ./protocol.ts (the multi-file reason a manifest is required)."
  pattern: "default-export factory; type-only imports from @earendil-works/pi-tui (L130) + pi-coding-agent (L131-136) — ALL `import type` (erased by jiti)."

- file: extension/tsconfig.json
  why: "module:ESNext + moduleResolution:Bundler + allowImportingTsExtensions → justifies package.json `type:'module'`. Paths map @earendil-works/* to the installed pi dist (type-resolution only). UNCHANGED by this task."

- file: extension/protocol.ts
  why: "Defines BridgeDescriptor (transport:'unix', path, token, pid, cwd, fdAvailable, serverVersion) + JSON-RPC types. Referenced by README's 'how it works'. type-only module (protocol.test.ts pins it as runtime-empty). UNCHANGED."

# Reference — README source material (PRD already provided verbatim in <selected_prd_content>)
- url: PRD §9.1 (package layout) + §10 (Installation & Configuration) + §11 (Edge Cases) + §12 (Security) + §16 (pi source locations)
  why: "§10.2/10.4 = install + $EDITOR wiring copy. §11 = troubleshooting bullet list (forgotten save→autosave, stale socket, fd missing, reload, post-bridge wrapper limit). §12 = security copy (0600 socket, 32-byte token via process.env, never log token). §16 = 'how it works' architecture summary."

- docfile: plan/001_c56962b4fa17/P1M3T10S18/research/notes.md
  why: "Full research: scout dist findings (8 Q&A on resolution/private/types/keyword/version/npm-install), the root-vs-subdir DECISION, exact package.json field set, README outline, scope guard."
  section: "§3 (resolution verdicts), §4 (root placement decision), §5 (fields), §6 (validation cmds), §8 (README outline)."
```

### Current Codebase tree

```bash
pi-nvim-bridge/                      # repo root; git remote: dabstractor/pi-nvim-bridge
├── PRD.md
├── plan/001_c56962b4fa17/...        # PRPs + research (this file lives here)
├── .gitignore
└── extension/                       # Component A — the pi extension package CONTENTS
    ├── pi-editor-bridge.ts          # ENTRY (export default factory; L983)
    ├── connection.ts                # JSONL server + RPC dispatch + connection registry
    ├── jsonl-reader.ts              # newline-delimited JSON framing
    ├── protocol.ts                  # type-only: BridgeDescriptor + JSON-RPC envelopes
    ├── tsconfig.json
    └── tests/                       # 18 node:test + jiti suites (all green)
# NOTE: NO package.json anywhere. NO README.md anywhere. (Both created by this task.)
```

### Desired Codebase tree with files to be added

```bash
pi-nvim-bridge/
├── package.json                     # NEW (S18) — pi package manifest (repo root)
├── README.md                        # NEW (S18) — extension README (repo root)
├── PRD.md
├── plan/...
└── extension/                       # UNCHANGED (all 4 .ts + tests + tsconfig untouched)
    └── ...
```

**Responsibility of new files:**
- `package.json` — declares the extension as a pi package: the `pi.extensions`
  entry point (so pi's loader finds `pi-editor-bridge.ts` among the 4 files),
  the package identity/version/keywords (npm + gallery), the peerDependency
  contract (`@earendil-works/*`), and dev `scripts` (typecheck/test).
- `README.md` — human-facing docs: what it does, how to install/configure, how to
  troubleshoot, how to develop. The single source users read before `pi install`.

### Known Gotchas of our codebase & Library Quirks

```python
# CRITICAL #1: git install reads ONLY the repo-root package.json.
# pi's package-manager.js installGit() reads join(cloneRoot,'package.json') and does
# NOT walk subdirs for a manifest. A package.json placed in extension/ would be
# INVISIBLE to `pi install git:.../pi-nvim-bridge`. => manifest MUST be at repo ROOT.
# (The manifest's *entry path* MAY point into a subdir: ./extension/pi-editor-bridge.ts.)

# CRITICAL #2: the manifest entry need NOT be index.ts.
# loader.js resolveExtensionEntries reads pi.extensions[] and path.resolve(root, entry)
# for EACH named file. index.ts is only the no-manifest fallback. => keep the tested
# filename pi-editor-bridge.ts; do NOT rename (zero churn).

# CRITICAL #3: ALL @earendil-works/* imports are `import type` (erased by jiti).
# Verified: pi-editor-bridge.ts L130/131/136/152 + protocol.ts L26/32 — zero value
# imports. jiti's @babel/preset-typescript strips them, so the package LOADS even if
# those packages are absent from node_modules. peerDependencies are therefore
# load-OPTIONAL but included per packages.md convention (documents the contract).

# GOTCHA #4: devDependencies are NOT installed at runtime.
# git install uses `npm install --omit=dev`; local-dir install runs NO npm install at
# all. So devDeps (typescript/jiti) are dev-only — safe to add, never bloat runtime.

# GOTCHA #5: `private`, `version`, `pi-package` keyword are NOT enforced by pi.
# Scout grep over dist: zero matches for consumer reads of these. They are npm/gallery
# conventions. Include version+keywords as best-practice; omit private (defaults false;
# this package IS distributable, unlike the with-deps example).

# GOTCHA #6: PI_EDITOR_BRIDGE is PROCESS-LOCAL (written to process.env inside pi),
# NOT exported to the shell. README MUST say `echo $PI_EDITOR_BRIDGE` shows nothing —
# this is the #1 user confusion. It is only visible to the child $EDITOR pi spawns.

# GOTCHA #7: the test runner is node:test + jiti, NOT vitest.
# The validated invocation uses an ABSOLUTE JITI_REG path
# (/home/dustin/.local/lib/.../jiti/lib/jiti-register.mjs) — machine-specific. A
# `test` npm script cannot hardcode it portably; document the command in README and
# keep the `typecheck` script (tsc) as the portable, reproducible `npm run` entry.
```

## Implementation Blueprint

### Data models and structure

Not applicable — this task creates a JSON manifest and a Markdown document. No
runtime data models, no TypeScript types, no schemas. The one "structure" is the
`package.json` JSON object (specified field-by-field in Task 1).

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE package.json  (repo root: /home/dustin/projects/pi-nvim-bridge/package.json)
  - IMPLEMENT: a JSON object with EXACTLY these fields (verbatim shape; values per notes):
      {
        "name": "pi-editor-bridge",
        "version": "0.1.0",
        "description": "Bridge pi's autocomplete engine to an external $EDITOR (Neovim) over a local Unix socket.",
        "type": "module",
        "keywords": ["pi-package", "pi", "neovim", "completion"],
        "license": "MIT",
        "pi": { "extensions": ["./extension/pi-editor-bridge.ts"] },
        "peerDependencies": {
          "@earendil-works/pi-coding-agent": "*",
          "@earendil-works/pi-tui": "*"
        },
        "devDependencies": { "typescript": "^5.6.0", "jiti": "^2.7.0" },
        "scripts": {
          "typecheck": "tsc --noEmit -p extension/tsconfig.json",
          "test": "echo 'See README: tests run via node --import jiti-register extension/tests/*.ts' && exit 0"
        }
      }
  - FOLLOW pattern: examples/extensions/with-deps/package.json (name+version+type:module+pi.extensions+deps+scripts SHAPE).
  - FIELD JUSTIFICATIONS:
      name:        "pi-editor-bridge" — the package identity (matches BRIDGE_VERSION domain).
      version:     "0.1.0" — ALIGNED with BRIDGE_VERSION (pi-editor-bridge.ts:272); single conceptual source.
      type:        "module" — matches tsconfig module:"ESNext" + the .ts ESM syntax.
      keywords:    includes "pi-package" — gallery discoverability (docs/packages.md §Gallery Metadata).
      license:     "MIT" — manifest convention. GOTCHA: a LICENSE FILE does not exist in the repo;
                   adding one is OUT OF SCOPE (separate human decision) — flag it in the PRP notes,
                   but the field is the standard manifest entry.
      pi.extensions: ["./extension/pi-editor-bridge.ts"] — THE critical field. Resolves from repo root
                   (loader.js path.resolve(root, entry)). Points at the EXISTING tested entry; NO rename.
      peerDependencies: @earendil-works/pi-coding-agent + pi-tui at "*" — docs/packages.md §Dependencies
                   mandates this for imported pi core packages (load-OPTIONAL per Gotcha #3, but correct).
      devDependencies: typescript + jiti — OPTIONAL but recommended for reproducible dev. Pin to the
                   working versions (jiti 2.7.0 is in pi's node_modules; typescript ^5.6 recent stable).
                   NEVER affect runtime (Gotcha #4: --omit=dev / no local install).
      scripts.typecheck: "tsc --noEmit -p extension/tsconfig.json" — the EXACT validated gate from every
                   prior P1 PRP; portable and reproducible.
      scripts.test: a honest pointer — the real test command uses an absolute machine-specific JITI_REG
                   path (Gotcha #7), so the script documents rather than hardcodes. (Alternative: if you
                   make jiti a local devDep, `node --import jiti/register extension/tests/$FILE` may work —
                   verify in your environment; keep the typecheck script as the reliable `npm run`.)
  - DO NOT include: "private" (omit → defaults false; this IS distributable),
                   "main"/"module"/"exports" (pi uses pi.extensions, not these; adding them is noise),
                   "dependencies" (there are NO runtime deps — all imports are type-only or node: builtins).
  - NAMING/PLACEMENT: file is `package.json` at the REPO ROOT (Gotcha #1: git install reads root only).
  - VERIFY after writing: `node -e "const p=require('./package.json'); console.assert(p.pi.extensions[0]==='./extension/pi-editor-bridge.ts'); console.log('ok')"` ⇒ prints `ok`.

Task 2: CREATE README.md  (repo root: /home/dustin/projects/pi-nvim-bridge/README.md)
  - IMPLEMENT: a Markdown document with these sections (use the PRD §10/§11/§12 copy as the
    authoritative source — paraphrase, do not copy verbatim wall-of-text; keep it skimmable):
      1. Title + one-line tagline ("Bridge pi's completion into the Neovim pi launches as $EDITOR").
      2. **What it does** (2-4 sentences): captures pi's live AutocompleteProvider via a pass-through
         factory, serves it over a Unix-domain-socket JSON-RPC server for the session lifetime, and
         advertises the socket+token to the spawned $EDITOR via the PI_EDITOR_BRIDGE env var. The
         companion Neovim plugin (pi-editor.nvim, forthcoming) connects and renders /commands,
         skill:, templates, @file, and path completion.
      3. **Prerequisites**: pi with extension support; Neovim 0.10+ (0.12 verified) for the companion
         plugin; the `fd` binary (optional — enables fuzzy @file search; without it @file silently
         returns nothing but path completion still works).
      4. **Installation** — THREE points, in this order:
           a. `pi install git:github.com/dabstractor/pi-nvim-bridge` (preferred) OR `pi install .`
              from a local clone. Then `pi list` should show `pi-editor-bridge`.
           b. NOTE (prominent): this extension is MULTI-FILE; you CANNOT install it by copying a
              single .ts into ~/.pi/agent/extensions/. It must be installed as a package (Gotcha #2).
           c. Companion plugin: install `pi-editor.nvim` via your Neovim plugin manager (lazy.nvim)
              — see that plugin's README (P2, forthcoming).
      5. **Configuration** ($EDITOR wiring — PRD §10.4): any of `export EDITOR=nvim` / `export VISUAL=nvim`
         / pi settings.json `{ "externalEditor": "nvim" }` (externalEditor takes precedence). Optional
         NVIM_APPNAME minimal-config optimization (PRD §10.4 last paragraph) — link forward, mark optional.
      6. **How it works** (brief — PRD §4 TL;DR + §16): list the live-provider capture, the
         process.env.PI_EDITOR_BRIDGE discovery (the KEY insight — pi spawns $EDITOR with stdio:inherit
         and no env:, so the child inherits process.env), and the JSON-RPC methods (getSuggestions /
         applyCompletion / shouldTriggerFileCompletion) with acceptance delegated to pi's applyCompletion
         (byte-for-byte identical insertion).
      7. **The PI_EDITOR_BRIDGE environment variable** (Gotcha #6 — PRD §6.4): it is a single-line JSON
         descriptor {transport,path,token,pid,cwd,fdAvailable,serverVersion} written to process.env INSIDE
         pi. CRITICAL NOTE: `echo $PI_EDITOR_BRIDGE` in a shell shows NOTHING — it is process-local, visible
         only to the Neovim pi launches. This is expected, not a bug.
      8. **Troubleshooting** (bullet list — PRD §11, the user-facing subset):
           - "I typed and quit (:q) and lost my prompt" → the companion plugin autosaves on VimLeavePre;
             until P2 lands, remember to :w before :q (pi reads the file only after the editor exits 0).
           - "Completion doesn't appear" → confirm the extension loaded (`pi list`), confirm EDITOR=nvim,
             confirm the companion plugin is installed & PI_EDITOR_BRIDGE gated it on.
           - "@file finds nothing" → install `fd`; the bridge reports fdAvailable; without fd, @file is
             empty but path completion (readdir) still works.
           - "Reload (/reload) while the editor is open" → the bridge re-captures the provider and
             re-advertises; the open editor's connection stays valid; a commandsChanged notification fires.
           - "Another extension's custom trigger (e.g. #issues) doesn't complete" → KNOWN LIMITATION
             (PRD §11): the bridge captures the provider at registration time; wrappers registered AFTER
             it won't appear. The base provider (slash/skill/template/path) is always captured.
      9. **Security** (PRD §12): socket lives in os.tmpdir() with 0600 perms; a 32-byte random token
         (delivered via process.env, never on disk) is validated in the hello handshake; the server
         rejects any method before a valid hello. Never log/echo the token.
     10. **Development**: typecheck (`npm run typecheck` or `npx tsc --noEmit -p extension/tsconfig.json`);
         run a test (the jiti invocation — document the JITI_REG command from Gotcha #7; note node:test +
         jiti, NOT vitest); repo layout (extension/ holds the 4 .ts + tests/ + tsconfig.json).
     11. **Links**: PRD reference, pi docs (packages.md, extensions.md), companion pi-editor.nvim (P2).
  - FOLLOW pattern: a standard OSS extension README (see any examples/extensions/*/README.md for tone;
    doom-overlay/README.md exists as a reference). Keep it skimmable with clear headings + code fences.
  - NAMING/PLACEMENT: `README.md` at REPO ROOT (companion to root package.json; npm convention).
  - BOUNDARY: this is the EXTENSION README. Do NOT document the Neovim plugin's Lua API/options (P2/P3
    territory — S44 "README for both" expands later). A one-line forward-link to the forthcoming plugin suffices.
  - VERIFY after writing: the file has H2 headings for at least: Installation, Configuration,
    Troubleshooting, Security, Development.

Task 3: VALIDATE (no file changes — verification only)
  - RUN: `node -e "const p=require('./package.json'); if(p.pi.extensions[0]!=='./extension/pi-editor-bridge.ts')process.exit(1); JSON.parse(require('fs').readFileSync('package.json','utf8'))"` ⇒ exit 0 (valid JSON + correct manifest entry).
  - RUN: `ls extension/pi-editor-bridge.ts` ⇒ the entry file exists (manifest resolves).
  - RUN: `npx tsc --noEmit -p extension/tsconfig.json` ⇒ exit 0 (regression: no source changed).
  - RUN: the bridge-env regression suite:
        JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
        node --import "$JITI_REG" extension/tests/bridge-env.test.ts
        ⇒ `ℹ fail 0` (jiti may print a benign DeprecationWarning on Node 26 — judge by exit code + summary).
  - RUN (the real packaging test): `pi -e .` ⇒ pi starts and loads the extension with NO load error.
        (If your pi build rejects a local dir for `-e`, fall back to `pi install .` then `pi list`
        — it should list `pi-editor-bridge` — then start `pi` and confirm no load error. NOTE:
        `pi install .` writes to settings.json; remove it after testing if undesired.)
  - RUN: `git diff --stat extension/` ⇒ EMPTY (no source touched).
```

### Implementation Patterns & Key Details

```jsonc
// package.json — the manifest. The pi.extensions entry is the load-bearing field.
{
  "name": "pi-editor-bridge",
  "version": "0.1.0",            // == BRIDGE_VERSION (pi-editor-bridge.ts:272)
  "description": "Bridge pi's autocomplete engine to an external $EDITOR (Neovim) over a local Unix socket.",
  "type": "module",              // == tsconfig module:"ESNext"
  "keywords": ["pi-package", "pi", "neovim", "completion"],
  "license": "MIT",
  "pi": {
    "extensions": ["./extension/pi-editor-bridge.ts"]   // resolved from repo ROOT by loader.js
  },
  "peerDependencies": {
    "@earendil-works/pi-coding-agent": "*",
    "@earendil-works/pi-tui": "*"
  },
  "devDependencies": {
    "typescript": "^5.6.0",
    "jiti": "^2.7.0"
  },
  "scripts": {
    "typecheck": "tsc --noEmit -p extension/tsconfig.json",
    "test": "echo 'See README — node --import jiti-register extension/tests/*.ts (node:test, not vitest)' && exit 0"
  }
}
// WHY NO "dependencies": every @earendil-works/* import is `import type` (erased by
// jiti); the rest are node: builtins. Zero runtime deps => npm install is a no-op.
// WHY NO "private": this package IS distributable (unlike the with-deps example).
// WHY NO "main"/"exports": pi keys off pi.extensions, not the npm entry-point fields.
```

```markdown
# README.md — skeleton (fill from PRD §10/§11/§12; keep skimmable)

# pi-editor-bridge
> Bridge pi's in-prompt completion into the Neovim instance pi launches as `$EDITOR`.

## What it does
…(2-4 sentences; live-provider capture + Unix-socket JSON-RPC + PI_EDITOR_BRIDGE env)…

## Prerequisites
- pi (with extension support)
- Neovim ≥ 0.10 (0.12 verified) + the companion **pi-editor.nvim** plugin (forthcoming)
- `fd` (optional — fuzzy `@file` search)

## Installation
```bash
pi install git:github.com/dabstractor/pi-nvim-bridge   # or: pi install .
pi list   # should show pi-editor-bridge
```
> ⚠️ This extension is **multi-file** — you cannot copy a single `.ts` into
> `~/.pi/agent/extensions/`. Install it as a package (above).

## Configuration (`$EDITOR`)
`export EDITOR=nvim` · `export VISUAL=nvim` · or pi `settings.json`:
`{ "externalEditor": "nvim" }` (takes precedence).

## How it works
…(PI_EDITOR_BRIDGE discovery insight; JSON-RPC methods; applyCompletion delegation)…

## The `PI_EDITOR_BRIDGE` environment variable
…(single-line JSON descriptor; PROCESS-LOCAL — `echo $PI_EDITOR_BRIDGE` is empty
in a shell by design; visible only to the spawned Neovim)…

## Troubleshooting
…(lost-prompt↦autosave; no completion↦check pi list + EDITOR + plugin; @file empty↦fd;
/reload; post-bridge wrapper limitation)…

## Security
…(0600 socket; 32-byte token via process.env; hello handshake; never log token)…

## Development
```bash
npm run typecheck                                       # tsc --noEmit
JITI_REG=…/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/bridge-env.test.ts   # node:test + jiti
```

## Links
- PRD · pi packages.md · pi extensions.md · companion **pi-editor.nvim** (P2)
```

### Integration Points

```yaml
PACKAGING (the whole point of S18):
  - add to: <repo-root>/package.json   (NEW)
  - pattern: "pi": { "extensions": ["./extension/pi-editor-bridge.ts"] }
  - resolution: loader.js path.resolve(root, entry) loads the existing tested entry.

DOCUMENTATION:
  - add to: <repo-root>/README.md      (NEW)
  - audience: pi users installing the extension; references PRD §10/§11/§12.

NO OTHER INTEGRATION POINTS:
  - DATABASE: none.
  - CONFIG: none (README documents user config; no settings.json change by this task).
  - ROUTES/SOURCE: none — zero .ts/.json-under-extension changes.
  - The extension's RUNTIME behavior is unchanged (already implemented P1.M1–S17).
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# package.json is valid JSON with the correct manifest entry
node -e "const p=require('./package.json'); \
  if(p.pi.extensions[0]!=='./extension/pi-editor-bridge.ts') process.exit(1); \
  if(p.name!=='pi-editor-bridge'||p.version!=='0.1.0'||p.type!=='module') process.exit(1); \
  if(!(p.keywords||[]).includes('pi-package')) process.exit(1); \
  if(!p.peerDependencies['@earendil-works/pi-coding-agent']) process.exit(1); \
  console.log('package.json OK')"
# Expected: package.json OK  (exit 0). If it exits 1, fix the named field.

# README has the required top-level sections
grep -E '^## (Installation|Configuration|Troubleshooting|Security|Development)' README.md
# Expected: 5 matching headings. If any missing, add the section.

# Type-check regression (NO source changed — must stay clean)
npx tsc --noEmit -p extension/tsconfig.json
# Expected: exit 0, no output.
```

### Level 2: Unit Tests (Component Validation — regression only)

```bash
# The extension's env-advertise logic must still work (the package depends on it)
JITI_REG=/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs
node --import "$JITI_REG" extension/tests/bridge-env.test.ts
# Expected: ℹ fail 0  (node:test reporter; a benign jiti DeprecationWarning on Node 26 is OK — judge by exit code).

# Optional: run the full extension suite to prove zero regressions
for f in extension/tests/*.test.ts; do
  node --import "$JITI_REG" "$f" >/dev/null 2>&1 || echo "FAIL: $f"
done
# Expected: no FAIL lines.
```

### Level 3: Integration Testing (System Validation — the real packaging test)

```bash
# PRIMARY: pi accepts and loads the package (try-without-install)
pi -e .
# Expected: pi STARTS and loads the extension with NO load error. (It will attempt to
# start the bridge on session_start; in a non-TUI/-print context the mode-guard no-ops.)
# If `-e .` rejects a local dir in your build, use the fallback below.

# FALLBACK (if `-e .` is unsupported for local dirs): install + list + run
pi install .           # writes to ~/.pi/agent/settings.json
pi list                # Expected: lists "pi-editor-bridge"
pi                     # start; confirm no extension load error in startup
pi remove npm:pi-editor-bridge 2>/dev/null || pi remove ./package.json  # CLEAN UP after testing

# Confirm NO source was touched by this task
git diff --stat extension/
# Expected: empty (no output). package.json + README.md are the ONLY new/changed files.
git status --short
# Expected: ?? package.json  and  ?? README.md  (and this PRP's plan/ files).
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Manifest-entry resolution proof (mimics loader.js path.resolve(root, entry)):
test -f "$(node -e "console.log(require('path').resolve('.', require('./package.json').pi.extensions[0]))")" \
  && echo "entry resolves to an existing file" || echo "ENTRY MISSING"
# Expected: entry resolves to an existing file.

# Manual functional smoke (OPTIONAL, interactive — strongest proof the package end-to-end works):
# 1. Ensure EDITOR=nvim and the companion plugin is installed (or skip if P2 not ready).
# 2. pi -e .   (or pi after `pi install .`)
# 3. In the prompt, press Ctrl+G to open the external editor.
# 4. In Neovim, :lua print(vim.env.PI_EDITOR_BRIDGE) should print the JSON descriptor.
# (Until P2 lands, step 4 is the meaningful proof the package wired the bridge correctly.)
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1 passed: `package.json OK`, README has 5 required H2 sections, `tsc` exit 0.
- [ ] Level 2 passed: `bridge-env.test.ts` ⇒ `ℹ fail 0`; full suite has no FAIL.
- [ ] Level 3 passed: `pi -e .` loads with no error (or `pi install .` + `pi list` shows the package).
- [ ] `git diff --stat extension/` is empty — no source touched.

### Feature Validation
- [ ] `package.json` has `pi.extensions: ["./extension/pi-editor-bridge.ts"]` and that file exists.
- [ ] `name=pi-editor-bridge`, `version=0.1.0`, `type=module`, `keywords` includes `pi-package`.
- [ ] `peerDependencies` lists both `@earendil-works/pi-coding-agent` and `pi-tui` at `"*"`.
- [ ] README covers install (git + local + "no single-file drop-in"), `$EDITOR` wiring,
      `PI_EDITOR_BRIDGE` env var (process-local caveat), troubleshooting (PRD §11), security (PRD §12), dev.
- [ ] The extension's runtime behavior is unchanged (regression suites green).

### Code Quality Validation
- [ ] package.json is minimal — no noise fields (`main`/`module`/`exports`/`dependencies`/`private`).
- [ ] README is skimmable (clear headings, code fences, a prominent multi-file install warning).
- [ ] Decisions documented in research notes (root placement, entry path, peerDeps rationale).
- [ ] Follows the `with-deps` example's package.json SHAPE.

### Documentation & Deployment
- [ ] README's install commands are copy-pasteable and correct for this repo's remote.
- [ ] README flags the LICENSE-file gap (license field is MIT but no LICENSE file exists yet).
- [ ] README forward-links the companion pi-editor.nvim plugin (P2) without documenting its API.

---

## Anti-Patterns to Avoid

- ❌ Don't place `package.json` in `extension/` (subdir) — git install reads the repo ROOT only;
  a subdir manifest is invisible to `pi install git:...`. ROOT is mandatory.
- ❌ Don't rename `pi-editor-bridge.ts` → `index.ts` to "follow convention" — the manifest names
  the entry explicitly; renaming is needless churn on tested code.
- ❌ Don't add `dependencies` — there are NO runtime deps (type-only imports are erased by jiti;
  the rest are `node:` builtins). Adding fake deps bloats the install for nothing.
- ❌ Don't set `"private": true` — this package IS distributable (unlike the `with-deps` example,
  which is private because it's a non-shipped demo).
- ❌ Don't add `main`/`module`/`exports` — pi keys off `pi.extensions`, not npm entry-point fields.
- ❌ Don't modify ANY file under `extension/` — this is manifest + docs only. If you find yourself
  editing `.ts`/`tsconfig.json`/tests, STOP: you've drifted out of scope.
- ❌ Don't document the Neovim plugin's Lua API/options in this README — that's P2/S44 territory.
- ❌ Don't hardcode the absolute `JITI_REG` path into a portable `test` script — it's machine-specific;
  document it in README and keep `typecheck` as the reliable `npm run`.
- ❌ Don't copy the PRD wall-of-text into the README verbatim — paraphrase for skimmability.

---

## Confidence Score

**9/10** for one-pass implementation success.

Rationale: this is a low-risk, well-bounded manifest + docs task with ZERO source
code changes. Every decision (root placement, entry path, field set, README outline,
validation commands) is pinned to scout-verified pi dist behavior
(`loader.js`/`package-manager.js`) + the canonical `with-deps` example + the actual
extension tree. The only residual uncertainty is whether `pi -e .` accepts a local
directory in the user's pi build (a documented fallback covers it) and the optional
`devDependencies` version pins (jiti 2.7.0 verified; typescript version to confirm in-env).
Neither blocks a correct, passing result.
