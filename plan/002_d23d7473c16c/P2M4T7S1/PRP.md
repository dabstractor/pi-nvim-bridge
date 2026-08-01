---
name: "P2.M4.T7.S1 — README.md shell-completion blurb + config pointer + architecture diagram"
description: "Sync the project README with the now-shipped shell-completion subsystem (P2.M1–P2.M3, PRD §17). Add a feature blurb, a `shell` config pointer, an optional architecture diagram, and cross-links — without touching the extension source."
---

## Goal

**Feature Goal**: Bring `README.md` into sync with the shell-completion
subsystem that shipped across P2.M1–P2.M3 (PRD §17). A reader landing on the
README today learns only about pi-mode completion (`/commands`, `@file`, paths);
they must be able to discover that `!`/`!!` bash-mode lines also get completion,
how to configure it, and where to read more — plus understand the two-engine
architecture at a glance.

**Deliverable**: A single edit set to `README.md` (repo root) adding:
1. a concise **shell-completion feature blurb**,
2. a **`shell` config pointer** in the Configuration section,
3. an **architecture diagram** showing the two completion engines and the
   plugin-side daemon,
4. **cross-links** to `:help pi-bridge-shell` and `doc/pi-bridge-shell.txt`.

**Success Definition**: `README.md` mentions shell completion by name, shows
the `shell = { … }` config block, links to `doc/pi-bridge-shell.txt`, and
contains an ASCII architecture diagram consistent with PRD §3 + §17.3. No source
files are modified. Prose matches the existing README's voice (terse,
troubleshooting-aware, no marketing fluff).

## User Persona (if applicable)

**Target User**: A pi user who opens `$EDITOR` (Neovim) via `Ctrl+G` and reads
the project README to understand what the bridge/plugin gives them and how to
configure it.

**Use Case**: The user wants to type a `!git …` command in the external editor
and have it complete the way their shell would, and wants to know which shell
is used and how to change it.

**User Journey**: GitHub landing page → README "What it does" (sees shell
completion listed) → "Configuration" (sees the `shell` block + `prefer`
explanation) → `:help pi-bridge-shell` for the deep dive.

**Pain Points Addressed**: Today the README is silent on the entire P2 milestone;
users discover `!`/`!!` completion only by stumbling into `doc/pi-bridge-shell.txt`.

## Why

- **Documentation completeness**: P2.M1–P2.M3 shipped four driver modules, a
  daemon manager, routing, acceptance, health, and a full vimdoc — none of which
  is reflected in the README (the most-read file in the repo).
- **Discoverability**: `README.md` is the entry point for every lazy.nvim/packer
  user and every GitHub visitor. The vimdoc is excellent but only reachable once
  the plugin is installed.
- **Scope discipline**: This is a **Mode B changeset-level doc sync** (the task
  tree labels P2.M4 "Mode B"). It edits exactly one file (`README.md`) and
  introduces no code, no new config keys, and no behavioral change. Sibling
  tasks S2 (`doc/pi-bridge.txt` cross-link) and S3 (`extension/README.md`
  descriptor fields) cover the OTHER two doc surfaces; this PRP owns ONLY the
  main `README.md`.

## What

User-visible (README-reader-visible) changes to `README.md`:

### Success Criteria

- [ ] "What it does" (or a new sibling section) names shell completion of
      `!`/`!!` lines as a feature, in the same breath as the existing pi-mode
      completions.
- [ ] The `shell` config block appears in the Configuration section with the
      `prefer` knob explained and a pointer to `:help pi-bridge-shell`.
- [ ] An ASCII architecture diagram shows: pi process (bridge + provider
      capture + socket) ↔ Neovim (plugin: pi-mode completion via socket + shell
      daemon via local pipes) ↔ shell subshell. Consistent with PRD §3 and §17.3.
- [ ] Cross-links to `doc/pi-bridge-shell.txt` / `:help pi-bridge-shell` are
      present and accurate.
- [ ] No source files, `package.json`, vimdocs, or other doc files are touched.
- [ ] Markdown renders cleanly (fenced code block language tags correct; no
      broken heading anchors).

## All Needed Context

### Context Completeness Check

_Pass_: An implementer who has never seen this repo needs only this PRP +
`README.md` + (read-only) `doc/pi-bridge-shell.txt` + `doc/pi-bridge.txt` to do
the edit. All exact config values, link targets, and the architecture facts are
given below verbatim. The PRD §17 reference is included inline where it matters.

### Documentation & References

```yaml
# MUST READ — the file being edited
- file: README.md
  why: The ONLY file this task modifies. Read in full before editing to match voice/section order.
  pattern: Terse prose, one-line bullets, fenced ```lua / ```bash / ```jsonc blocks,
           ">" blockquote callouts for gotchas. Sections: What it does → Prerequisites →
           Installation → Configuration → How it works → PI_NVIM_BRIDGE → Troubleshooting →
           Security → Development → Links → Releasing.
  gotcha: Do NOT touch the Demo link, Installation, $EDITOR wiring, Security, Development,
          Releasing, or Repository-layout sections. This task is additive to the
          feature/config/how-it-works surface only.

# MUST READ — the authoritative doc the README must agree with (READ-ONLY here)
- file: doc/pi-bridge-shell.txt
  why: The vimdoc S6 shipped (commit d480645). The README blurb + config block MUST be
        consistent with it (same prefer values, same driver tiers, same default config).
  section: |pi-bridge-shell-overview|, |pi-bridge-shell-prefer|, |pi-bridge-shell-config|, |pi-bridge-shell-drivers|
  critical: |
    Exact defaults the README config block MUST mirror (from §5 of the vimdoc and
    lua/pi-bridge/init.lua M.defaults.shell):
      enabled            = true
      prefer             = "pi"
      drivers            = { fish = true, zsh = true, bash = true }
      warm_on_enter      = false
      timeout_ms         = 1500
      startup_timeout_ms = 5000
      visual_cue         = "gutter"
      debounce_ms        = 0
      max_parse_failures = 5

# READ-ONLY reference — the existing main vimdoc (S2 owns cross-linking INTO it, not us)
- file: doc/pi-bridge.txt
  why: Confirm the existing pi-mode doc already cross-links to pi-bridge-shell (it does:
        line 30 + lines 214, 267-269). The README should mirror that cross-link direction
        (README → pi-bridge-shell), not duplicate the vimdoc's internal links.

# READ-ONLY reference — config ground truth
- file: lua/pi-bridge/init.lua
  why: M.defaults.shell (lines ~55-65) is the authoritative default config. The README
        config block must match it field-for-field. Do NOT invent keys.
  pattern: `M.defaults.shell = { enabled=..., prefer=..., drivers=..., ... }`
  gotcha: The README should show the SAME key set and defaults; prose can elide
          max_parse_failures/startup_timeout_ms for brevity but must not contradict them.

# READ-ONLY reference — architecture facts for the diagram
- file: PRD.md  # sections §3 (Architecture Overview) and §17.3 (shell architecture)
  why: The ASCII diagram in PRD §3 shows pi↔socket↔nvim (pi-mode). PRD §17.3 adds the
        plugin-side shell daemon (nvim → local pipes → shell subshell; DOES NOT touch the
        bridge socket). The README diagram must combine BOTH without implying the shell
        daemon talks to the bridge.
  critical: |
    The two invariants the diagram MUST convey:
      1. pi-mode completion flows pi → socket → plugin (unchanged from §3).
      2. shell-mode completion flows nvim-plugin → local stdio pipes → shell daemon;
         the daemon is a CHILD OF NVIM, never a child of pi, never touches PI_NVIM_BRIDGE
         or the socket (§17.13). Getting this wrong would misstate the security boundary.
```

### Current Codebase tree (the doc surface this task touches)

```bash
pi-nvim-bridge/
├── README.md                 # ← THE ONLY FILE THIS PRP EDITS
├── doc/
│   ├── pi-bridge.txt         # (S2's scope) main vimdoc — already cross-links to shell
│   ├── pi-bridge-shell.txt   # shell vimdoc — READ-ONLY reference for the blurb
│   └── tags                  # helptags — do NOT regenerate here
├── extension/                # pi extension (TS) — untouched by this task
├── lua/pi-bridge/
│   ├── init.lua              # M.defaults.shell — config ground truth (READ-ONLY ref)
│   ├── shell.lua             # daemon manager (READ-ONLY ref for "how it works")
│   └── shell/{fish,zsh,bash}.lua  # drivers (READ-ONLY ref for the driver tier table)
└── ... (rest unchanged)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
# NO new files. README.md is MODIFIED in place. No tree change.
pi-nvim-bridge/
└── README.md   # MODIFIED: +shell blurb, +shell config block, +architecture diagram, +cross-links
```

### Known Gotchas of our codebase & doc conventions

```python
# CRITICAL: README voice is terse and troubleshooting-forward, not marketing.
#   Match existing sentence rhythm (see "What it does" / "Troubleshooting").
#   Do NOT add emoji headers, badges, or "✨ Features" sections — the README has none.

# CRITICAL: The architecture diagram must NOT imply the shell daemon uses the bridge socket.
#   PRD §17.13 / §17.3 are explicit: the daemon is a child of nvim over LOCAL pipes only;
#   it never sees PI_NVIM_BRIDGE or the token. A wrong diagram would misstate security.

# CRITICAL: prefer default is "pi" (NOT "shell"). This is THE central design decision
#   (PRD §17.2). The README blurb must state it correctly: completion defaults to pi's
#   execution shell (bash unless the user set shellPath), NOT to $SHELL. Getting this
#   backwards is the #1 documentation failure mode for this subsystem.

# CRITICAL: Do NOT regenerate doc/tags. The helptags already include pi-bridge-shell*
#   (commit d480645 added them). Editing README does not touch tags.

# GOTCHA: fenced code block languages. Existing README uses ```lua, ```bash, ```jsonc,
#   ```text. For the architecture diagram use ```text (not ``` or ```ascii) so renderers
#   preserve the box-drawing characters.

# GOTCHA: link targets. README links to doc files as relative paths:
#   [pi-bridge-shell](./doc/pi-bridge-shell.txt). For :help, write `:help pi-bridge-shell`
#   in backticks (the README already references `:help pi-bridge` this way at line ~120).
```

## Implementation Blueprint

### Data models and structure

_N/A — this is a documentation-only task. There are no data models, types, or
schemas to create. The "data" is the exact config-key/value table above, quoted
verbatim from `lua/pi-bridge/init.lua` `M.defaults.shell` and `doc/pi-bridge-shell.txt` §5._

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ the full current README.md + doc/pi-bridge-shell.txt
  - ACTION: read README.md (353 lines) end-to-end; read doc/pi-bridge-shell.txt §1,§3,§4,§5
  - WHY: match the existing voice, section order, and link style; avoid duplicating the
         vimdoc; confirm the exact config defaults
  - OUTPUT: a mental map of where each edit lands (see Task placement notes below)
  - DEPENDENCIES: none

Task 2: ADD the shell-completion blurb to "What it does"
  - EDIT: README.md "What it does" section (lines ~28-42)
  - ADD: 2-4 sentences naming shell completion of `!`/`!!` bash-mode lines as a second
         completion engine, driven by the user's real shell, defaulting to pi's
         execution shell (prefer:"pi"), rendered in the same floating menu
  - FOLLOW pattern: the existing paragraph rhythm in "What it does" (one idea per sentence)
  - NAMING/TERMS: use "shell completion", "bash mode", "`!`/`!!`" exactly as the vimdoc does
  - CROSS-LINK: end the blurb with a pointer: "See `:help pi-bridge-shell`
         ([`doc/pi-bridge-shell.txt`](./doc/pi-bridge-shell.txt)) for the full guide."
  - GOTCHA: do NOT promise $SHELL completion by default — prefer is "pi" (bash unless
            shellPath is set). State the mismatch/fix in ONE clause, link out for detail.

Task 3: ADD the `shell` config block to the Configuration section
  - EDIT: README.md "## Configuration (`$EDITOR`)" area (after the existing editor-wiring
          prose, before "### Optional startup optimization", OR as a new "### Shell
          completion" subsection — prefer the subsection for scannability)
  - ADD: a fenced ```lua block showing the shell config with the EXACT defaults from
         M.defaults.shell (see Known Gotchas table above); a one-line explanation of
         `prefer` with the four values; a pointer to `:help pi-bridge-shell`
  - FOLLOW pattern: the existing ```lua setup({}) blocks (lazy.nvim config, the
         PI_NVIM_APPNAME table). Keep it copy-pasteable.
  - NAMING: `setup({ shell = { ... } })` — matches init.lua's option path exactly
  - GOTCHA: show `prefer = "pi"` as the default in the block (commented or explicit);
            do not show `prefer = "shell"` as if it were default.

Task 4: ADD (or expand) an architecture diagram
  - EDIT: README.md "## How it works" section (line ~182)
  - ADD: a fenced ```text ASCII diagram combining PRD §3 (pi↔socket↔nvim) and §17.3
         (nvim↔local pipes↔shell daemon). Label: pi process (bridge, live provider,
         PI_NVIM_BRIDGE env, Unix socket); nvim (plugin: pi-mode completion client +
         shell daemon manager); shell subshell (fish/zsh/bash driver, local stdio).
  - FOLLOW pattern: PRD §3's box-drawing style (┌─┐│└─┘ + ▲▼ arrows). Keep ≤ ~22 lines
         so it renders without horizontal scroll on GitHub.
  - CRITICAL invariant (PRD §17.13): draw the shell daemon as a CHILD OF NVIM connected
         by LOCAL PIPES only; it must NOT connect to the bridge socket or PI_NVIM_BRIDGE.
         Add a one-line caption under the diagram stating this.
  - GOTCHA: if a diagram already existed and was removed, re-add; currently the README
            has NO architecture diagram, so this is a net-new addition.

Task 5: ADD a Troubleshooting bullet for shell completion (optional but recommended)
  - EDIT: README.md "## Troubleshooting" (lines ~219-244)
  - ADD: one bullet, e.g. "`!`/`!!` completions are bash-quality / missing." → pointer to
         the `prefer` mismatch + `:checkhealth pi-bridge` + `:help pi-bridge-shell`.
  - FOLLOW pattern: existing Troubleshooting bullets (bold question, short answer, link).
  - WHY: the vimdoc FAQ (§10) has rich answers; the README needs only the signpost.

Task 6: VERIFY — no source/vimdoc/package changes; markdown sanity
  - ACTION: `git diff --stat` shows ONLY README.md; `git diff README.md` reads clean;
            optional `npx --yes markdownlint-cli README.md` or a visual GitHub-render check
  - CHECK: every fenced block has a language tag; every relative link resolves;
           heading anchors not broken by renames (we add NO new top-level headings that
           others link to, so this is safe)
  - DEPENDENCIES: Tasks 2-5
```

### Implementation Patterns & Key Details

```python
# PATTERN: README config block — mirror this exact shape (lazy.nvim block at ~line 110
# and the PI_NVIM_APPNAME table are the style references):
#
#   ### Shell completion
#
#   `!`/`!!` bash-mode lines are completed by your real shell's completion engine
#   (fish/zsh/bash), rendered in the same floating menu. It defaults to the shell pi
#   *executes* commands in (`prefer = "pi"` — bash unless you set pi's `shellPath`),
#   so completions and execution always agree. See `:help pi-bridge-shell`.
#
#   ```lua
#   require("pi-bridge").setup({
#     shell = {
#       enabled            = true,                 -- master switch
#       prefer             = "pi",                 -- "pi" | "shell" | "bash" | "/abs/path"
#       drivers            = { fish = true, zsh = true, bash = true },
#       warm_on_enter      = false,                -- spawn the daemon at VimEnter
#       visual_cue         = "gutter",             -- "$ " prefix on shell items
#       -- timeout_ms, startup_timeout_ms, debounce_ms, max_parse_failures also exist;
#       -- see :help pi-bridge-shell-config for the full table.
#     },
#   })
#   ```

# PATTERN: architecture diagram caption invariant — include this line verbatim-ish:
#   "The shell daemon is a child of the Neovim process over local pipes only; it never
#    touches the pi-nvim-bridge socket or the PI_NVIM_BRIDGE token (see §Security)."

# PATTERN: cross-link style (already used in README for pi-bridge):
#   `:help pi-bridge-shell` ([`doc/pi-bridge-shell.txt`](./doc/pi-bridge-shell.txt))

# GOTCHA: the README's "Security" section (lines ~246-254) currently covers only the
#   socket/token. If you add a sentence to "How it works" claiming the shell daemon
#   "never touches the socket", that is TRUE and consistent with Security — but do NOT
#   edit the Security section itself unless you also document the rc-sourcing trust model.
#   The vimdoc (pi-bridge-shell.txt §8) already owns that; the README should LINK to it
#   rather than duplicate. Keep Security edits out of scope for S1 (S2/S3 may extend).
```

### Integration Points

```yaml
FILES MODIFIED:
  - exactly one: README.md (repo root)

FILES READ-ONLY (do NOT edit — owned by other tasks or by humans):
  - doc/pi-bridge.txt          # S2's scope (already cross-links to shell)
  - doc/pi-bridge-shell.txt    # reference for the blurb/config
  - extension/*                # S3 owns extension/README.md; extension source untouched
  - lua/pi-bridge/*            # config ground truth only
  - package.json               # no version/manifest change
  - doc/tags                   # already includes pi-bridge-shell* tags

CONFIG:
  - none (no new config keys; the README only documents the existing shell.* keys)

ROUTES/DB/MIGRATIONS:
  - none (documentation only)
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# README is Markdown — validate rendering and links.
# 1. No other file changed:
git diff --stat
# Expected: exactly one line — " README.md | <n> +-". If more appears, STOP and revert.

# 2. Diff is clean and reviewable:
git diff README.md | less

# 3. (Optional, if available) markdown lint — README currently has no lint config,
#    so this is advisory only; skip if markdownlint is not installed:
npx --yes markdownlint-cli README.md 2>/dev/null || true

# 4. (Optional) render check — open README.md on GitHub's preview or run a local
#    renderer; confirm the ASCII diagram has no horizontal scroll and fenced blocks
#    have syntax highlighting (correct language tags).
```

### Level 2: Unit Tests (Component Validation)

_N/A — documentation-only task. There are no unit tests for README content. The
plenary/node:test suites under `tests/` and `extension/tests/` are unaffected
and need not be run (no source changed)._

### Level 3: Integration Testing (System Validation)

```bash
# Verify internal consistency: the README config block matches the code's defaults.
# 1. Extract the keys the README shows and diff against init.lua's M.defaults.shell:
grep -A12 'M.defaults.shell' lua/pi-bridge/init.lua
# Then manually confirm every key/value in the README block appears here with the
# same default. Mismatch = bug in the README.

# 2. Verify cross-link targets exist:
test -f doc/pi-bridge-shell.txt && echo "pi-bridge-shell.txt OK"
grep -q 'pi-bridge-shell-overview' doc/pi-bridge-shell.txt && echo "help-tag OK"

# 3. Verify the architecture invariants are stated (grep the new prose):
git diff README.md | grep -E 'never touches|local pipes|child of (the )?Neovim'
# Expected: at least one match affirming the daemon does not use the bridge socket.

# 4. Confirm prefer default is stated as "pi", not "shell":
git diff README.md | grep -E 'prefer\s*=\s*"pi"'
# Expected: a match in the config block.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Render the README the way a user will: GitHub markdown.
# If `gh` is available and authenticated, preview locally:
gh api -X POST /markdown -f text="$(cat README.md)" >/tmp/readme.html 2>/dev/null \
  && echo "rendered OK (open /tmp/readme.html)" || echo "gh unavailable — visual check on push"

# Confirm the ASCII diagram survives rendering (no ```text fence swallowed it):
grep -c '^```text' README.md   # Expected: >= 1 (the architecture block)

# Confirm no accidental edit to the Demo link / Installation / Releasing sections:
git diff README.md | grep -E '^[-+].*(Demo|pi install|git tag|NPM_TOKEN|lazy = false)' 
# Expected: NO output (those lines are untouched). If output appears, you edited a
# section outside scope — revert it.
```

## Final Validation Checklist

### Technical Validation

- [ ] `git diff --stat` shows ONLY `README.md` changed.
- [ ] Level 1 checks pass (diff is clean; fenced blocks have language tags).
- [ ] Level 3 consistency checks pass (config block matches `M.defaults.shell`;
      help-tag exists; `prefer = "pi"`; daemon-socket invariant stated).
- [ ] Level 4 render check: ASCII diagram present under a ` ```text ` fence; no
      accidental edits to Demo/Installation/Releasing.

### Feature Validation

- [ ] "What it does" names shell completion of `!`/`!!` lines.
- [ ] Configuration section shows the `shell = { … }` block with correct defaults.
- [ ] Architecture diagram shows both the pi↔socket↔nvim path AND the
      nvim↔pipes↔shell-daemon path, with the security invariant captioned.
- [ ] Cross-links to `:help pi-bridge-shell` / `doc/pi-bridge-shell.txt` present.
- [ ] (Optional) Troubleshooting has one shell-completion signpost bullet.

### Code Quality Validation

- [ ] Prose matches the existing README voice (terse, troubleshooting-aware).
- [ ] No emoji/badge/marketing-flair introduced.
- [ ] No duplicated content from `doc/pi-bridge-shell.txt` (README links out, vimdoc owns depth).
- [ ] No new top-level heading that breaks existing inbound anchors.
- [ ] Diagram ≤ ~22 lines, box-drawing renders on GitHub without horizontal scroll.

### Documentation & Deployment

- [ ] `doc/tags` not regenerated (already current).
- [ ] No `package.json` version bump (README is not a release artifact).
- [ ] Sibling tasks (S2 `doc/pi-bridge.txt`, S3 `extension/README.md`) are NOT
      touched — this PRP owns only the main `README.md`.

---

## Anti-Patterns to Avoid

- ❌ Don't document `prefer = "shell"` as the default — it is `"pi"`. This is the
  single most dangerous doc error for this subsystem (it would make zsh users
  expect zsh completions and then hit the alias footgun PRD §17.2 exists to prevent).
- ❌ Don't draw the shell daemon connected to the bridge socket — it isn't. The
  daemon is a child of nvim over local pipes and never sees `PI_NVIM_BRIDGE`/token.
- ❌ Don't copy the vimdoc's full FAQ/quoting/health tables into the README —
  link to `:help pi-bridge-shell` instead. The README is the signpost, not the manual.
- ❌ Don't edit `doc/pi-bridge.txt`, `doc/pi-bridge-shell.txt`, `extension/*`,
  `package.json`, or `doc/tags` — those belong to S2/S3 or are owned by humans.
- ❌ Don't add a "Features ✨" section or restructure existing headings — be additive
  and match the current section rhythm.
- ❌ Don't invent config keys not present in `lua/pi-bridge/init.lua` `M.defaults.shell`.
- ❌ Don't skip the diagram caption stating the security invariant — the diagram
  without it is actively misleading about the trust boundary.

---

## Confidence Score

**8/10** — one-pass success is highly likely. The task is a single-file
documentation edit with all exact content (config defaults, link targets,
architecture facts, prose patterns) specified verbatim above and verified against
the shipped code (`lua/pi-bridge/init.lua`) and vimdoc (`doc/pi-bridge-shell.txt`).
The only residual uncertainty is aesthetic (diagram width on GitHub, exact blurb
phrasing), which the Level 4 render check catches. No code, no types, no tests —
the blast radius of a mistake is limited to prose accuracy, which the Level 3
grep checks guard against.