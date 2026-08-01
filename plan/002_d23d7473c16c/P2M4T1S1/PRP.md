---
name: "P2.M4.T7.S1 — README.md shell-completion feature blurb + config pointer + architecture diagram update"
why_this_prp: |
  Mode B changeset-level documentation task. The shell-completion feature
  (PRD §17) landed across P2.M1–P2.M3 (descriptor shell fields, shell.lua
  daemon manager, fish driver, routing/accept, and the in-flight zsh/bash
  drivers), but the repo-root README.md still describes ONLY the pi-faithful
  completion surface (slash commands, skill: templates, @file, paths, args) and
  makes no mention of !/!! shell completion, the shell.lua daemon, or the
  `shell = {}` config. This task syncs the README to the shipped (and
  in-flight) feature so an external user discovers shell completion from the
  README alone. Pure documentation: one file (README.md), no code, no tests, no
  mocking, no schema change. It PRESERVES the omp install path landed by
  P1.M1.T1.S2 (already present) and does NOT touch doc/pi-bridge.txt
  (P2.M4.T7.S2) or extension/README.md (P2.M4.T7.S3).
---

## Goal

**Feature Goal**: `README.md` advertises the **shell completion for `!/!!`
bash-mode** feature end-to-end: a features-list bullet, a short standalone
section with the `shell = {}` config pointer, an architecture representation
that names `shell.lua`, a Prerequisites note that fish/zsh/bash are optional
(graceful degrade), and the already-present omp install path left intact.

**Deliverable**: Edits to **exactly one file** — repo-root `README.md`. No
other file is created or modified. Specifically:
1. **Features list** (two locations) — add a `!/!!` shell-completion bullet.
2. **New short section** — a "Shell completion (`!`/`!!`)" subsection carrying
   the `shell = {}` config pointer + the `:help pi-bridge-shell` detail link.
3. **Architecture representation** — add the box-drawing architecture diagram
   (from PRD §3, whose nvim box already names `shell.lua`) to the "How it
   works" section, AND update the "Repository layout" tree's `lua/pi-bridge/`
   annotation to name `shell` + `shell/`.
4. **Prerequisites** — a bullet noting fish/zsh/bash are OPTIONAL and the
   feature degrades gracefully when absent.
5. **omp install path** — preserved verbatim (verification gate only).

**Success Definition**: A reader who has never seen §17 can learn from the
README that (a) typing `!git ch<Tab>` completes against their real shell, (b)
how to enable/tune it (`shell = { prefer = "pi", ... }`), (c) that it is driven
by a `shell.lua` daemon (not the bridge socket), (d) that it works without any
shell installed (degrades to no completion), and (e) the omp install path is
unchanged. Every contract point is provable by a deterministic grep gate.

## User Persona (if applicable)

**Target User**: a pi user who types `!`/`!!` shell commands into the
pi-prompt Neovim buffer (bash mode) and expects the same Tab-completion they
get at their real shell prompt.

**Use Case**: reading the README to learn what the bridge/plugin does → sees
shell completion listed → opens `:help pi-bridge-shell` for tuning details.

**User Journey**: README features list → "Shell completion" section (config
pointer) → architecture diagram shows `shell.lua` in the nvim box →
Prerequisites confirms no shell is mandatory → tries `!git ch<Tab>` → works.

**Pain Points Addressed**: today the README is silent on shell completion, so
the feature is invisible; an omp/fish/zsh/bash user has no reason to believe
`!/!!` completion exists.

## Why

- **The feature shipped; the README drifted.** P2.M1–P2.M3 landed the bridge
  descriptor `shell` fields (P2.M1.T1), the `shell.lua` daemon manager
  (P2.M1.T2), fish driver + routing + accept (P2.M2.T3/T4), and the
  in-flight zsh/bash drivers (P2.M3.T5). The README still describes only the
  pi-faithful surface. This is the residual docs debt for §17.
- **This IS the Mode B changeset-level doc sweep** (P2.M4.T7) for the shell
  feature — no separate docs subtask is needed (contract point 6).
- **Low-risk, high-discoverability.** A pure additive markdown edit to one
  file — it cannot regress the extension, the plugin, or any test. The only
  invariant to protect is the already-present omp install path (point e).

## What

Five precisely-scoped, mostly-additive edits to `README.md`:

### (a) Features list — add the shell-completion bullet
Add a bullet stating shell completion: **"`!/!!` bash-mode commands complete
against your real shell (fish/zsh/bash)"** (contract wording). Place it in
BOTH the opening two-component blurb's render list AND the "What it does"
prose, so the two features inventories stay coherent.

### (b) New "Shell completion" section with the `shell = {}` config pointer
Add a short subsection (under "Configuration (`$EDITOR`)" or directly after
"How it works") that:
- States the daemon drives the user's **real shell** (fish/zsh/bash) — not pi's
  completion engine — and that it does **not** use the bridge socket.
- Shows the `shell = { prefer = "pi", ... }` config pointer (master switch +
  `prefer` contract; default `prefer = "pi"` matches pi's own execution shell).
- Points to `:help pi-bridge-shell` for the full option set (produced by
  sibling task P2.M3.T6.S4).

### (c) Architecture representation — name `shell.lua`
- **Add the box-drawing architecture diagram** (copy PRD §3 verbatim — its nvim
  box ALREADY contains the `shell.lua` line) into the "How it works" section.
- **Update the "Repository layout" tree**: the `lua/pi-bridge/` annotation must
  name `shell` (daemon manager) + `shell/` (per-shell drivers + accept).

### (d) Prerequisites — shells are optional, graceful degrade
Add a bullet: **fish / zsh / bash are OPTIONAL** — the `shell = {}` feature
degrades gracefully (no completion for `!`/`!!` lines, the rest is unaffected)
when none is on PATH.

### (e) Preserve the omp install path (verification gate)
The omp install path from P1.M1.T1.S2 (the `### oh-my-pi (\`omp\`)` subsection
+ the Prerequisites "either host" bullet) is **already present and correct**.
This task must NOT alter it; the PRP's validation gates assert it survives.

### Success Criteria

- [ ] `README.md` features list (both spots) contains a `!/!!` shell-completion
      bullet mentioning fish/zsh/bash.
- [ ] A "Shell completion" section exists with the `shell = {}` config pointer
      (incl. `prefer = "pi"`) and a `:help pi-bridge-shell` link.
- [ ] The README contains a box-drawing architecture diagram whose nvim box
      names `shell.lua` (the persistent completion subshell that routes
      `!`/`!!` lines), AND the "Repository layout" tree names `shell`/`shell/`.
- [ ] Prerequisites lists fish/zsh/bash as optional with a graceful-degrade note.
- [ ] The omp install path is byte-for-byte intact (the three `omp plugin …`
      commands + the "either host / zero code change" note survive).
- [ ] No other file is modified (`git status` shows ONLY `README.md`).

## All Needed Context

### Context Completeness Check

_Pass_: an implementer who knows nothing about this repo gets (a) the full
current README.md (the entire file is small, ~14KB, and every edit site is
quoted below with exact line numbers + verbatim old text), (b) the canonical
PRD §3 box-drawing diagram (already containing the correct `shell.lua` nvim-box
line — copied verbatim below), (c) the exact `shell = {}` config block from
PRD §17.11 (verbatim below), (d) the precise two features-list locations, and
(e) the exact omp strings to preserve. No external reading is required; the
PRD sections are quoted inline.

### Documentation & References

```yaml
# MUST READ #1 — the file being edited (the SOLE edit target)
- file: README.md
  why: the only file touched; its sections are the edit sites
  section: "## What it does (L28), ## Prerequisites (L44), ## Configuration (L117),
            ## How it works (L182), Repository layout tree (L283), ### oh-my-pi (L74)"
  critical: |
    The README has NO box-drawing architecture diagram today — only the
    "Repository layout" file tree (L283) + "How it works" prose (L182). The
    features list appears in TWO places (opening blurb L18-27 AND "What it does"
    L28-42) — edit BOTH for coherence. The omp path (L46-47 + L74-90) is already
    present from P1.M1.T1.S2 — PRESERVE it verbatim.

# MUST READ #2 — the canonical architecture diagram (copy its nvim box verbatim)
- docfile: plan/002_d23d7473c16c/prd_snapshot.md
  why: PRD §3 (Architecture Overview, L190-215) is the box-drawing diagram whose
        nvim box ALREADY names shell.lua. Copy it into the README's "How it works".
  section: "## 3. Architecture Overview (L190-215)"
  critical: |
    The PRD diagram is ALREADY correct (the §17 author added the shell.lua line).
    Do NOT re-derive the art — copy it verbatim. The nvim box must keep its
    `shell.lua: persistent completion subshell (fish/zsh/bash)` line.

# MUST READ #3 — the config block source of truth
- docfile: PRD.md
  why: §17.11 (Configuration) defines the exact `shell = {}` option set the README
        config pointer must reflect.
  section: "### 17.11 Configuration"
  critical: |
    prefer:"pi" (default) matches pi's own execution shell. Shell completion does
    NOT use the bridge socket (rpc_timeout_ms is unaffected — §17.11 last line).
    Trim the block to the master switch + prefer + a comment in the README; full
    detail lives at :help pi-bridge-shell.

# MUST READ #4 — the motivation/wording for the features bullet + degrade note
- docfile: PRD.md
  why: §17.1 (Motivation & scope), §17.4 (prefer contract), §17.12 (degrade)
  section: "h3.30 (§17.1), h3.33+17.4 (prefer), h3.41 (§17.12 degrade)"
  critical: |
    §17.1 states fish/zsh/bash are the v1 driver set; prefer:"pi" default resolves
    to pi's execution shell. §17.12 is the graceful-degrade contract (missing shell
    → notice, no crash, rest of completion unaffected) — the Prerequisites bullet.

# RELATED — sibling tasks in the same changeset sweep (boundaries; do NOT cross)
- docfile: plan/002_d23d7473c16c/P1M1T1S2/PRP.md
  why: the PRECEDING omp README task; defines the exact omp strings this task PRESERVES.
        Read it to confirm the omp install block's wording before editing nearby.
- file: doc/pi-bridge.txt
  why: OWNED by P2.M4.T7.S2 (cross-link). Do NOT edit it. The README's
        `:help pi-bridge-shell` pointer is a forward ref to P2.M3.T6.S4's output.
- file: extension/README.md
  why: OWNED by P2.M4.T7.S3. Do NOT edit it.
```

### Current README.md structure map (verified 2025-07-31)

```bash
# Section headers + key line numbers (run: grep -nE '^## |^### ' README.md)
L8   ## Demo:
L28  ## What it does                  ← FEATURES prose (edit site a-ii)
L44  ## Prerequisites                 ← edit site (d); omp bullet L46 (preserve)
L56  ## Installation
L74    ### oh-my-pi (`omp`)           ← ALREADY PRESENT (P1.M1.T1.S2) — PRESERVE (e)
L117 ## Configuration (`$EDITOR`)     ← candidate host for the new Shell section (b)
L137   ### Optional startup optimization
L182 ## How it works                  ← edit site (c): add diagram + shell point
L197 ## The `PI_NVIM_BRIDGE` environment variable
L219 ## Troubleshooting
L246 ## Security
L256 ## Development
L283   **Repository layout:**         ← file tree; update lua/pi-bridge/ line (c)
L315 ## Links
L322 ## Releasing
```

### The two FEATURES-list spots (exact current text at edit site a)

**Spot (i) — opening blurb render list (L18–27):**
```
- **`pi-bridge.nvim`** *(the companion **Neovim plugin**, shipped in this same
  repo at the root — see `:help pi-bridge`)* connects to that socket and
  renders pi's completion inside Neovim: `/commands`,
  `skill:` templates, argument completions, `@file` references, and filesystem
  paths.
```
**Spot (ii) — "What it does" prose (L30–34):**
```
It brings pi's autocomplete into Neovim. When you launch your external editor
from pi, it behaves just like pi's prompt box — same `/` slash commands, same
`skill:` templates, same `@file` references and path suggestions, same argument
completions. Whatever pi would suggest inline, you get here, inside Neovim.
```

### The canonical architecture diagram (copy verbatim into "How it works" — site c)

From PRD §3 (`prd_snapshot.md` L193–214). The nvim box ALREADY contains the
shell.lua line — do not alter the art:

```
 ┌──────────────────────── pi process (Node) ─────────────────────────┐
 │                                                                     │
 │  InteractiveMode  ──► openExternalEditor()  ──► spawn($EDITOR …)    │
 │         ▲                                       (inherits process.env)│
 │         │                                                           │
 │   CombinedAutocompleteProvider  ◄── captured by ──┐                 │
 │                                                    │                 │
 │   pi-nvim-bridge (extension)  ──────────────────┘                 │
 │     • session_start  ──► net.createServer on Unix socket            │
 │     • sets process.env.PI_NVIM_BRIDGE = {path, token, pid, …}     │
 │     • JSONL RPC: getSuggestions / applyCompletion / shouldTrigger…  │
 │     • session_shutdown ──► server.close() + unlink socket           │
 │                                                                     │
 └───────────────────────────│─────────────────────────────────────────┘
                              │ Unix domain socket (or TCP loopback)
                              │ newline-delimited JSON (JSONL) with id correlation
 ┌───────────────────────────▼─────────────────────────────────────────┐
 │  nvim (the $EDITOR child)  ◄── loads pi-bridge.nvim                  │
 │     • VimEnter: vim.env.PI_NVIM_BRIDGE present? → activate         │
 │     • bridge.lua: luv pipe client, handshake (token), RPC dispatch   │
 │     • completion.lua: triggers, debounce, accept flow                │
 │     • menu.lua: dependency-free floating completion popup            │
 │     • shell.lua: persistent completion subshell (fish/zsh/bash)      │
 │       spawns pi's resolved shell (default); routes `!`/`!!` lines    │
 │       descriptor gains shell/shellSource (§17.4 consistency)         │
 │     • ExitPre/VimLeavePre: autosave (so pi reads the latest prompt)  │
 └──────────────────────────────────────────────────────────────────────┘
```

### The `shell = {}` config block (PRD §17.11 — trim for the README pointer)

```lua
require("pi-bridge").setup({
  shell = {
    enabled           = true,                 -- master switch (false → no !/!! completion)
    prefer            = "pi",                 -- "pi" | "shell" | "bash" | "/abs/path"
    drivers           = { fish = true, zsh = true, bash = true },
    warm_on_enter     = false,                -- spawn daemon at VimEnter (latency vs memory)
    timeout_ms        = 1500,                 -- per-request budget
    startup_timeout_ms= 5000,                 -- daemon cold-start (rc load) budget
    visual_cue        = "gutter",             -- "gutter" | "border" | "off"
    debounce_ms       = 0,                    -- 0 = immediate (daemon warm)
  },
})
```
README copy can show just `enabled` + `prefer` + a one-line comment; point to
`:help pi-bridge-shell` for the rest. **Critical:** state that shell completion
does NOT use the bridge socket (§17.11: "`rpc_timeout_ms` … is unaffected").

### Desired README.md delta (no new files; edits to one file)

```bash
README.md                    # MODIFIED — features bullet (×2), Shell section,
                             #   architecture diagram + How-it-works point,
                             #   Prerequisites optional-shells bullet, layout-tree line.
# No file is created. No file other than README.md is touched.
```

### Known Gotchas of our codebase & Library Quirks

```markdown
# CRITICAL (contract ambiguity): the contract says "update the nvim box", but the
#   README has NO box-drawing diagram today — only a file tree + prose. The canonical
#   box diagram is in the PRD (§3), and its nvim box ALREADY names shell.lua. The
#   faithful action is to ADD that diagram to the README's "How it works" (verbatim
#   from PRD §3 — no art edit needed) PLUS update the "Repository layout" tree line.
#   Do NOT search for a non-existent "nvim box" in the current README.

# CRITICAL (two features inventories): the features list appears in BOTH the opening
#   blurb (L18-27) AND "What it does" (L28-42). Edit BOTH or they drift apart
#   (the P1.M1.T1.S2 omp PRP set the precedent of editing paired sections together).

# GOTCHA (forward doc reference): `:help pi-bridge-shell` is produced by P2.M3.T6.S4
#   (Planned). Referencing it from the README NOW is correct — both ship in the same
#   Mode B changeset sweep. Do NOT invent the help-tag's content; just point at it.

# GOTCHA (scope): do NOT edit doc/pi-bridge.txt (P2.M4.T7.S2) or extension/README.md
#   (P2.M4.T7.S3). Those are sibling tasks. This PRP owns ONLY repo-root README.md.

# GOTCHA (omp preservation): the omp install path (L46-47 bullet + L74-90 subsection)
#   is ALREADY correct from P1.M1.T1.S2. Editing NEAR it (e.g. the Prerequisites
#   optional-shells bullet) must not alter it. The validation gate greps the three
#   `omp plugin …` commands + the "zero code change" note post-edit.

# GOTCHA (markdown box art): the architecture diagram uses box-drawing chars inside a
#   ``` fence. Keep it inside a fenced code block (``` … ```) so GitHub renders it
#   monospaced and aligned. Do NOT let a prose edit shift its indentation.
```

## Implementation Blueprint

### Implementation Tasks (ordered: edits are independent, but do (c) diagram first so prose can reference it)

```yaml
Task 1: ADD the architecture diagram to "How it works" + update the layout tree  [point c]
  - INSERT into the "## How it works" section (L182), after the 3 numbered points,
    a fenced (```) copy of the PRD §3 box-drawing diagram (quoted verbatim in this
    PRP's "canonical architecture diagram" block). The nvim box's shell.lua line is
    already correct — copy it AS-IS.
  - ADD a 4th numbered "How it works" point: "Shell completion (optional). For `!`/`!!`
    bash-mode lines, `shell.lua` spawns a persistent fish/zsh/bash daemon (pi's
    resolved shell by default) and completes against it — this path does NOT use the
    bridge socket. See `:help pi-bridge-shell`."
  - EDIT the "Repository layout" tree (L291-292): change the lua/pi-bridge/ annotation
    from `# init/bridge/completion/menu/coords/health/` + `# blink_source/cmp_source/
    notify/jsonlreader` to include `shell` + `shell/` (e.g.
    `# init/bridge/completion/menu/coords/health/shell(+shell/)/…`).
  - NAMING: keep the existing tree's `│ nvim plugin` / `│ runtime files` gutter alignment.
  - GOTCHA: keep the diagram inside a fenced code block so GitHub renders it aligned.

Task 2: ADD the shell-completion bullet to BOTH features spots  [point a]
  - SPOT (i) opening blurb render list (L18-27): append a phrase/bullet —
    "`!/!!` bash-mode commands complete against your real shell (fish/zsh/bash)".
  - SPOT (ii) "What it does" prose (L30-34): append a sentence with the same wording.
  - FOLLOW pattern: the existing list uses inline backticked tokens (`/commands`,
    `skill:`, `@file`); mirror that style (backtick `!/!!`).
  - GOTCHA: edit BOTH spots so the two inventories stay coherent.

Task 3: ADD the "Shell completion" section with the config pointer  [point b]
  - PLACE: a new `### Shell completion (\`!\`/\`!!\`)` subsection under "## Configuration
    (`$EDITOR`)" (after L117's block) OR directly after the new diagram in "How it
    works" (L182). Pick "Configuration" for discoverability (users scan config first).
  - CONTENT (keep it short — detail lives at :help pi-bridge-shell):
      * one paragraph: the daemon drives the user's REAL shell (fish/zsh/bash), NOT
        pi's completion engine; it does NOT use the bridge socket; prefer:"pi" (default)
        matches pi's own execution shell.
      * a trimmed config block: `setup({ shell = { enabled = true, prefer = "pi" } })`
        with a comment that the full option set (drivers, timeouts, visual_cue) is at
        `:help pi-bridge-shell`.
  - FOLLOW pattern: the existing "Configuration (`$EDITOR`)" + "Optional startup
    optimization" subsections (L117/L137) — fenced lua blocks, one-paragraph lead-ins.
  - GOTCHA: do NOT duplicate the full §17.11 block (8 options) — the README points to
    the help file; pasting all options invites drift.

Task 4: ADD the optional-shells Prerequisites bullet  [point d]
  - INSERT into "## Prerequisites" (L44), after the `fd` bullet (L51), a new bullet:
    "**fish / zsh / bash** *(optional)* — enable shell completion for `!`/`!!` lines.
    The feature degrades gracefully (no `!`/`!!` completion; the rest is unaffected)
    if none is on PATH."
  - FOLLOW pattern: the `fd` optional-bullet phrasing (`*(optional)* — … Without it …`).
  - GOTCHA: do NOT alter the first Prerequisites bullet (the pi/omp "either host" line,
    L46-47) — that is the omp path this task must PRESERVE.

Task 5: VERIFY the omp install path survives (point e) — NO edit, run the gate
  - RUN the grep gate (see Validation Level 2). If any of the three `omp plugin …`
    commands or the "zero code change" note is missing/changed, RESTORE it from the
    current README (quoted in this PRP: L74-90 block). Do not "improve" the omp wording.
```

### Implementation Patterns & Key Details

```markdown
# PATTERN: mirror the README's existing voice. The README is conversational ("When you
#   launch your external editor from pi, it behaves just like pi's prompt box …"),
#   uses backticked tokens for feature names, and fences code/config in ``` blocks.
#   Match that — do not write in spec/PRD voice.

# PATTERN: optional-feature bullets. The `fd` bullet is the template:
#     "- **`fd`** *(optional)* — enables …. Without it … still works."
#   The shells bullet (Task 4) mirrors it exactly.

# PATTERN: forward doc pointers. The README already says "see `:help pi-bridge`"
#   (L19). The new section's `:help pi-bridge-shell` pointer mirrors that idiom.

# CRITICAL: the architecture diagram's nvim box ALREADY contains the shell.lua line
#   (PRD §3 was updated when §17 was authored). Copy it verbatim — do NOT retype or
#   "fix" the art; a misaligned box char breaks the GitHub render.

# CRITICAL: keep the diagram inside a ``` fence and do not indent it (GitHub renders
#   fenced blocks monospaced; leading spaces in prose would misalign the box).
```

### Integration Points

```yaml
DOCUMENTATION GRAPH (no code/config/schema integration):
  - README.md → :help pi-bridge-shell : forward pointer to P2.M3.T6.S4's vimdoc
      (same changeset sweep). The help-tag does not exist yet; referencing it now is
      correct and expected.
  - README.md → PRD §17: the features bullet + config pointer summarize §17.1/§17.4/
      §17.11; the diagram mirrors PRD §3. No PRD edit (PRD is read-only).
  - README.md omp path: PRESERVED from P1.M1.T1.S2 (no integration; a regression guard).

NO CODE CHANGE: shell.lua / completion.lua / init.lua are NOT touched. The `shell = {}`
  config shown in the README is the USER-facing pointer to init.lua's defaults (landed
  by P2.M3.T6.S1, Planned); showing it in the README does not require init.lua to exist
  yet — both ship in the same sweep, and `setup()` merges over defaults either way.
```

## Validation Loop

> This is a documentation task. There is no compiler/test gate. Validation =
> deterministic grep gates (one per contract point) + a markdown-render sanity
> check + a cross-doc consistency check. Wrap any markdown-preview command in
> `timeout` (AGENTS.md), though none are required to PASS.

### Level 1: Markdown sanity (immediate)

```bash
# Confirm the file still parses cleanly + the box diagram is fenced + tables intact.
# (GitHub renders GitHub-Flavored Markdown; a local previewer is optional.)
command -v mdcat >/dev/null && timeout 20 mdcat README.md >/dev/null && echo "mdcat OK" || echo "mdcat absent (skip)"
command -v glow >/dev/null && timeout 20 glow README.md >/dev/null && echo "glow OK" || echo "glow absent (skip)"
# Confirm no stray un-fenced box-drawing chars leaked into prose:
grep -nP '[┌└├│─▼]' README.md | grep -v '```' | head   # expect: only lines INSIDE a fence
# Expected: every box-drawing char is within a ``` fence (the diagram).
```

### Level 2: Content gates — one grep per contract point (a–e)

```bash
# (a) Features bullet in BOTH spots — fish/zsh/bash + !/!!
grep -ciE 'bash.mode|!/!!|! / !!' README.md | xargs -I{} echo "features mentions: {}"
grep -nE 'fish.*zsh.*bash|fish/zsh/bash' README.md          # expect ≥1 in features area

# (b) Shell-completion section + config pointer + help link
grep -nE 'shell = \{|prefer.*=.*"pi"|prefer.*pi' README.md  # config pointer present
grep -n 'pi-bridge-shell' README.md                          # :help pointer present
grep -niE 'does not use the bridge socket|not.*bridge socket|shell completion does not' README.md

# (c) Architecture diagram names shell.lua + layout tree names shell/
grep -n 'shell.lua: persistent completion subshell' README.md   # the diagram's nvim box
grep -nE 'lua/pi-bridge/.*shell' README.md                      # the layout-tree line

# (d) Prerequisites optional-shells + graceful degrade
grep -niE 'fish.*zsh.*bash.*optional|optional.*fish.*zsh.*bash|degrade' README.md | grep -i prereq -A2 -B2 || \
  grep -niE 'degrades gracefully|graceful' README.md

# (e) omp install path PRESERVED (the three commands + the zero-code-change note)
grep -c 'omp plugin install npm:pi-nvim-bridge' README.md   # expect 1
grep -c 'omp plugin list' README.md                          # expect 1
grep -c 'omp plugin doctor' README.md                        # expect 1
grep -ciE 'zero code change|either host' README.md           # expect ≥1
# Expected: all counts ≥1 (the omp path survived the edits).
```

### Level 3: Cross-doc consistency

```bash
# The README's :help pi-bridge-shell pointer will resolve to P2.M3.T6.S4's vimdoc.
# Confirm the tag NAME is consistent (grep the doc target if it exists yet):
grep -R 'pi-bridge-shell' doc/ 2>/dev/null | head || echo "doc/pi-bridge-shell.txt not yet present (P2.M3.T6.S4) — forward ref OK"
# Confirm the omp path matches P1.M1.T1.S2's PRP (the three commands verbatim):
grep -F 'omp plugin install npm:pi-nvim-bridge' README.md && \
grep -F 'omp plugin list' README.md && \
grep -F 'omp plugin doctor' README.md && echo "omp path consistent with P1.M1.T1.S2"
# Expected: all three omp commands present verbatim.
```

### Level 4: Scope guard (no collateral edits)

```bash
# ONLY README.md changed; no sibling-task files touched.
git status --porcelain | grep -E '\.md$|\.txt$|\.lua$'
# Expected: exactly one line — " M README.md". doc/pi-bridge.txt and extension/README.md
# MUST NOT appear. If they do, STOP — you crossed into P2.M4.T7.S2/S3 territory.
git diff --name-only
# Expected: README.md only.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 markdown sanity passes (box diagram fenced; no leaked box chars in prose).
- [ ] Every Level 2 content gate (a–e) returns ≥1 match with the expected values.
- [ ] Level 3 cross-doc consistency: omp commands verbatim; `pi-bridge-shell` tag consistent.
- [ ] Level 4 scope guard: `git diff --name-only` shows ONLY `README.md`.

### Feature Validation

- [ ] (a) `!/!!` shell-completion bullet present in BOTH features spots (opening blurb + "What it does").
- [ ] (b) "Shell completion" section with `shell = {}` + `prefer = "pi"` + `:help pi-bridge-shell` + "does not use the bridge socket".
- [ ] (c) Box-drawing architecture diagram in "How it works" whose nvim box names `shell.lua`; "Repository layout" tree names `shell`/`shell/`.
- [ ] (d) Prerequisites: fish/zsh/bash optional + graceful-degrade note.
- [ ] (e) omp install path (`omp plugin install/list/doctor` + "zero code change"/"either host") byte-for-byte intact.

### Documentation Quality

- [ ] README voice matches existing conversational style + backticked-token convention.
- [ ] Optional-feature bullet mirrors the `fd` bullet phrasing.
- [ ] Config block trimmed (not the full 8-option §17.11 dump) to avoid drift.
- [ ] No PRD/PRP/tasks.json/extension/doc edits (read-only outside README.md).

---

## Anti-Patterns to Avoid

- ❌ Don't search the current README for a "nvim box" to edit — there is none; the
  diagram is added (copied from PRD §3, whose nvim box already names shell.lua).
- ❌ Don't edit only ONE of the two features inventories — they must stay coherent.
- ❌ Don't paste the full 8-option §17.11 config block — the README points to
  `:help pi-bridge-shell`; a full dump invites drift on every option change.
- ❌ Don't touch doc/pi-bridge.txt (P2.M4.T7.S2) or extension/README.md (P2.M4.T7.S3).
- ❌ Don't "improve" the omp wording while editing nearby Prerequisites — preserve it.
- ❌ Don't retype the box-drawing art (a misaligned char breaks the GitHub render) — copy it.
- ❌ Don't add the shell feature to the README's Troubleshooting section (out of scope;
  troubleshooting lives in the help file). Stay within the five contract points (a–e).

---

**Confidence Score: 9/10** — one-pass success is highly likely: the task is a
single-file additive markdown edit, the entire current README is quoted at the
edit sites, the canonical diagram + config block are quoted verbatim, and the
validation is deterministic grep gates. The one residual risk is the "nvim box"
contract ambiguity (resolved here by adding the PRD §3 diagram, which already
names shell.lua) — the PRP flags it explicitly so the implementer doesn't stall.