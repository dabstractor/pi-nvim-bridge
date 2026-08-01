name: "P2.M3.T6.S4 — doc/pi-bridge-shell.txt vimdoc (shell-completion subsystem help)"
description: |

  PRD §17 ("Shell Completion for `!`/`!!` Bash Mode") is fully IMPLEMENTED across
  P2.M1–P2.M3 (descriptor shell fields, `shell.lua` daemon manager, fish/zsh/bash
  drivers + unknown-shell degrade, `completion.lua` routing, `accept.lua` local
  quoting, `init.lua` `config.shell`, `health.lua` 5th section, `ftplugin`
  VimLeavePre teardown). The ONE missing deliverable is the **user-facing help
  file**: `doc/pi-bridge-shell.txt`, the vimdoc that `:help pi-bridge-shell` opens.

  This is a pure-documentation task. It writes exactly **one new file**
  (`doc/pi-bridge-shell.txt`) and edits exactly **one existing file**
  (`doc/pi-bridge.txt`) to add cross-links (CONTENTS pointer + a §17 pointer in
  the completion/environment sections). No Lua, no extension, no config, no
  behavior change. The file is the documented target the already-shipped
  `health.lua` points users at: health.lua:299 emits
  `"See :help pi-bridge-shell (P2.M3.T6.S4) for resolution / config."` — that
  link is currently a dead reference until this file + its tags exist.

---

## Goal

**Feature Goal**: A complete, convention-correct vimdoc help file
`doc/pi-bridge-shell.txt` that documents the entire §17 shell-completion
subsystem for end users — what it does, when it activates, the `prefer` shell
resolution contract (the central design decision), the per-shell driver tiers,
the full `config.shell` options table, the `:checkhealth` shell section, the
trust/security model, the failure-mode degrade behavior, and a troubleshooting
FAQ — written so a user who typed `!git ch<Tab>` and saw nothing can
self-diagnose in under a minute. It must match the established style of the
sibling `doc/pi-bridge.txt` byte-for-byte (header line, modeline, `===` rules,
`*tag*`/`|tag|` conventions, `>` ... `<` example blocks, `DEFAULTS ~` option
tables, `NOTE:`/`WARNING:` callouts).

**Deliverable**:
1. **NEW file** `doc/pi-bridge-shell.txt` — a vimdoc (ft=help) with the
   structure in "Implementation Tasks" Task 1, ~250–400 lines, every section
   carrying at least one `*pi-bridge-shell-*` tag, ending in the
   ` vim:tw=78:ts=8:noet:ft=help:norl:` modeline.
2. **EDIT** `doc/pi-bridge.txt` — add the cross-links in Task 2 (CONTENTS
   pointer + inline `|pi-bridge-shell|` references in §8 completion-behavior and
   §10 environment). Pure additive; no existing line removed or re-wrapped
   beyond the minimal insertion points.
3. **REGENERATE** `doc/tags` via `:helptags` so the new `*pi-bridge-shell*` tags
   resolve (Task 3 — a one-command runtime step, not a hand-edit).

**Success Definition**:
- `:help pi-bridge-shell` opens `doc/pi-bridge-shell.txt` at the top.
- Every `*pi-bridge-shell-<topic>*` tag defined in the new file resolves
  (`:help pi-bridge-shell-config`, `:help pi-bridge-shell-prefer`,
  `:help pi-bridge-shell-drivers`, `:help pi-bridge-shell-health`,
  `:help pi-bridge-shell-troubleshooting`, etc.).
- The dead link in `health.lua:299` (`"See :help pi-bridge-shell ..."`) now
  resolves to real content.
- `:help pi-bridge` (the existing file) contains at least one
  `|pi-bridge-shell|` cross-link in its CONTENTS block and in §8/§10.
- The file passes `nvim --headless` syntax/load validation (opens with no
  `E670`/tag errors; `:helptags` runs clean; no stray-non-help highlighting).
- No source code, config, or behavior changes anywhere.

## User Persona

**Target User**: A pi user editing a prompt in the Neovim external editor
(`Ctrl+G`) who typed `!git ch<Tab>` (or `!!docker <Tab>`) expecting shell
completion and either saw nothing (daemon failed / shell unsupported /
mismatched) or saw bash-quality completions while being a zsh/fish user (the
§17.2/§17.4.3 mismatch). Secondary: a user who wants to configure shell
completion (`prefer`, `drivers`, `warm_on_enter`, `visual_cue`) or understand
the trust model (the daemon sources their rc files).

**Use Case**: The user runs `:help pi-bridge-shell`, reads the overview, jumps
to `:help pi-bridge-shell-prefer` to understand why they got bash completions,
follows the link to `:help pi-bridge-shell-config`, sets
`setup({ shell = { prefer = "zsh" } })` (or sets pi's `shellPath`), reopens the
editor, and `!git ch<Tab>` now yields rich, execution-consistent completions.

**User Journey**:
1. `!git ch<Tab>` shows nothing / wrong-quality completions in a pi editor.
2. `:checkhealth pi-bridge` → the "pi-bridge shell completion" section (S2,
   COMPLETE) reports the resolved shell + source + driver tier + daemon health
   and ends with `"See :help pi-bridge-shell (P2.M3.T6.S4) ..."`.
3. User follows that link → reads §prefer (the mismatch explainer) → §config
   (the options table) → §troubleshooting (the FAQ).
4. User applies the one-line config fix; completion works on next editor open.

**Pain Points Addressed**:
- **Silent degrade is undocumented.** §17.12 mandates shell failures degrade
  *silently* (one dedup'd notice; never block). Without a help file, a user
  whose daemon crashed has only `:messages` (which scrolls). The help file is
  the durable reference the health section + notices point at.
- **The mismatch is non-obvious.** "pi runs `!` in bash, not `$SHELL`" is the
  single sharpest correctness footgun (§17.2). Users blame the plugin; the help
  file explains *why* `prefer:"pi"` is the default and the one-setting fix.
- **Config is undiscoverable.** `config.shell` has 8 knobs (S1, COMPLETE). With
  no vimdoc, the only way to learn them is reading `init.lua` source.

## Why

- **Business value**: A shipped feature without docs is half-shipped.
  `:checkhealth` (S2) and the runtime notices (S4-notices, COMPLETE) both
  already emit `:help pi-bridge-shell` as the resolution path — that link is a
  404 until this file exists. This task closes the doc loop on the entire §17
  subsystem (P2.M1–P2.M3) and is the gate before P2.M4 (README/changeset sync).
- **Integration with existing features**:
  - **`health.lua` §5 (S2, COMPLETE)** — emits `"See :help pi-bridge-shell
    (P2.M3.T6.S4) for resolution / config."` at health.lua:299 (and similar
    advice lines). This file is the target of that pointer.
  - **`notify.lua` (COMPLETE)** — the three shell notice categories
    (`shell-mismatch` §17.4.3, `shell-degrade` §17.12, `shell-active` §17.9)
    each advise `:help pi-bridge-shell`. This file is their target.
  - **`doc/pi-bridge.txt` (COMPLETE, the sibling)** — establishes every style
    convention the new file must mirror (header/modeline/`===`/tags/`>` blocks/
    `DEFAULTS ~`/`NOTE:`). The new file is a structural clone with shell-specific
    content. Cross-links from pi-bridge.txt → pi-bridge-shell.txt are standard
    cross-file help links (`:helptags` builds one shared `doc/tags`).
  - **`init.lua` `M.defaults.shell` (S1, COMPLETE)** — the documented options
    table is a direct mirror of the shipped defaults (every field verified).
- **Problems this solves, for whom**: Gives end-users a single durable
  reference (`:help pi-bridge-shell`) for the whole subsystem; gives maintainers
  a stable target for the health/notice cross-links; closes the P2.M3 milestone.

## What

A new vimdoc help file `doc/pi-bridge-shell.txt` documenting the §17
shell-completion subsystem, plus minimal cross-links from `doc/pi-bridge.txt`.
The file covers: overview + activation gate; the shell-mismatch design
constraint and the `prefer` contract; per-shell driver tiers (fish/zsh/bash +
unknown degrade); the full `config.shell` options table (mirroring
`init.lua` `M.defaults.shell`); the `:checkhealth pi-bridge` shell section
pointer; the trust/security model (daemon sources rc files — same trust as pi's
own `!` execution); failure-mode degrade behavior; and a troubleshooting FAQ.
Plus `:helptags` regeneration so the new tags resolve.

### Success Criteria

- [ ] `doc/pi-bridge-shell.txt` exists, is `ft=help`, opens cleanly under
      `nvim --headless`, and ends with the exact modeline
      ` vim:tw=78:ts=8:noet:ft=help:norl:`.
- [ ] First line is `*pi-bridge-shell.txt*\tFor Nvim 0.11+.\tLast change: <date>`
      (tag matches filename; `:helptags` requires this).
- [ ] A `CONTENTS` block (mirroring pi-bridge.txt's) lists every section with a
      `|pi-bridge-shell-<topic>|` link.
- [ ] Every section header is a column-1 `===`-ruled title with a right-aligned
      `*pi-bridge-shell-<topic>*` tag.
- [ ] The `config.shell` options table mirrors `init.lua` `M.defaults.shell`
      exactly (all 8 fields: `enabled`, `prefer`, `drivers`, `warm_on_enter`,
      `timeout_ms`, `startup_timeout_ms`, `visual_cue`, `debounce_ms`, plus the
      documented `max_parse_failures`) — values + one-line meanings match source.
- [ ] The `prefer` contract (§17.4) is documented with all four values
      (`"pi"`/`"shell"`/`"bash"`/`"/abs/path"`), the default `"pi"`, and the
      §17.4.3 mismatch notice behavior.
- [ ] Driver tiers are documented: fish (tier-1, `complete -C`, with
      descriptions), zsh (tier-1, capture widget, with descriptions), bash
      (tier-2, `compgen`/compspec, no descriptions, opt-out via
      `drivers.bash=false`), unknown → degrade.
- [ ] The trust model (§17.13) is documented: the daemon sources rc files
      (`~/.zshrc`, `~/.config/fish/config.fish`, `~/.bashrc` + bash-completion)
      → executes user-authored code, SAME trust model as pi's own `!` execution;
      daemon is a child of nvim on local pipes, never touches the bridge socket.
- [ ] The troubleshooting FAQ covers: nothing happens on `!<Tab>`; bash-quality
      as a zsh/fish user (the mismatch); daemon crashed mid-session; quoting
      edge cases; unsupported shell; Windows unsupported.
- [ ] `doc/pi-bridge.txt` gained ≥1 `|pi-bridge-shell|` cross-link in its
      CONTENTS block and in §8 (`pi-bridge-completion`) and §10
      (`pi-bridge-env`).
- [ ] `:helptags` regenerated; `doc/tags` contains the new `pi-bridge-shell*`
      entries; `:help pi-bridge-shell` resolves.
- [ ] `:help pi-bridge` still opens correctly (no regressions from the
      cross-link edits).
- [ ] No source/config/behavior changes (diff is `doc/`-only).

## All Needed Context

### Context Completeness Check

> If someone knew nothing about this codebase, would they have everything needed
> to implement this successfully? **Yes.** This is a documentation task whose
> "API" is (a) the vimdoc conventions (verified against the locally-installed
> Neovim `helphelp.txt` + the repo's own `pi-bridge.txt` gold-standard template)
> and (b) the shipped §17 subsystem surface, every field/function of which is
> pinned below with exact source citations. No inference about behavior is
> required — the implementer transcribes verified source into help prose.

### Documentation & References

```yaml
# MUST READ — the canonical vimdoc authoring guide (verified locally)
- url: :help help-writing   (Neovim helphelp.txt, tag *help-writing*)
  why: the MUST-FOLLOW rules for help files: first-line format, modeline,
       *tag*/|ref| syntax, column-78 wrap, > ... < example blocks, ~ continuation.
  critical: the first line MUST be `*<filename>*\t...` with the tag matching the
       filename EXACTLY or :helptags fails (E670 on mismatch/duplicate). Hyphens
       in tags are explicitly valid (syntax regex includes `-`).

# The GOLD-STANDARD template to clone structurally — the repo's own sibling help
- file: doc/pi-bridge.txt
  why: every style convention the new file must match lives here. Clone its
       structure (header line, CONTENTS block, === rules, section headers, tag
       placement, DEFAULTS ~ blocks, NOTE:/WARNING: callouts, > example blocks,
       trailing modeline).
  pattern: mirror EXACTLY — same column-1 `===` rule width, same right-aligned
       *tag* placement (~col 78), same `>` ... `<` example indent, same
       `DEFAULTS ~` sub-heading style, same FAQ Q:/A: ~ style as §13.
  gotcha: do NOT re-wrap existing lines in pi-bridge.txt when adding cross-links;
       insert at the marked points only (Task 2 pins the exact anchors).

# The §17 subsystem being documented — GROUND TRUTH sources (all COMPLETE)
- file: lua/pi-bridge/init.lua  (M.defaults.shell L55-65; ShellConfig class L21-30)
  why: the config options table in the help file must mirror these EXACT values.
  pattern: each field has a one-line `-- §...` comment that is the docstring;
       transcribe that meaning into the DEFAULTS ~ block.

- file: lua/pi-bridge/shell.lua
  why: the documented behavior (resolve_shell fallback chain, pick_driver tiers,
       the sentinel protocol, teardown) must match this source.
  sections: resolve_shell (L168), mismatch_target (L211), pick_driver (L234),
       session_cwd (L259), status (L299), ensure (L368), request (L796),
       teardown (L926), complete_current (L984).

- file: lua/pi-bridge/shell/fish.lua  (M.start L238, M.parse L189, M.cd L428)
  why: fish driver — tier-1, `complete -C`, yields descriptions. Document the
       tier + mechanism.
- file: lua/pi-bridge/shell/zsh.lua   (M.start L293, M.parse L243, M.cd L497)
  why: zsh driver — tier-1, capture-completion widget (compinit + redefined
       compadd), yields descriptions. Most fragile driver — document.
- file: lua/pi-bridge/shell/bash.lua  (M.start L285, M.parse L241, M.cd L477)
  why: bash driver — tier-2, compgen/compspec + bash-completion sourcing, NO
       descriptions. Opt-out via drivers.bash=false.
- file: lua/pi-bridge/shell/accept.lua (M.current_shell_word L133, M.quote L195, M.apply L261)
  why: local word-replacement + per-shell quoting (NOT pi's applyCompletion).
       Documents §17.8.

- file: lua/pi-bridge/completion.lua  (completion_context L456-461; shell branch L525)
  why: documents §17.7 routing — line 1 beginning with `!` → ctx=="shell".
- file: lua/pi-bridge/menu.lua  (GUTTER="$ " L185; visual cue L179-412)
  why: documents §17.9 visual_cue ("gutter" default → `$ ` prefix on each item).
- file: lua/pi-bridge/health.lua  (§5 "pi-bridge shell completion" L217-355)
  why: the :checkhealth section the help file points AT and describes. Note
       L299 emits the very `:help pi-bridge-shell` link this file fulfills.
- file: lua/pi-bridge/notify.lua  (M.once / did_notify; categories shell-mismatch/shell-degrade/shell-active)
  why: documents the one-time dedup'd notices (§17.4.3 / §17.12 / §17.9).

# The PRD section being documented (read for content accuracy, do NOT paste verbatim)
- file: PRD.md  §17.1–§17.18 (L1131–L1830)
  why: the behavioral spec the help prose summarizes. Paraphrase into user-facing
       help tone; do not copy spec internals (reference numbers, skeletons).
  critical: §17.2 (the mismatch — the central design constraint), §17.4 (prefer
       contract + default "pi"), §17.6 (driver tiers), §17.11 (config), §17.12
       (degrade), §17.13 (security/trust). These six are the user-facing core.

# External exemplars (plugin help files that document a subsystem well)
- url: https://github.com/folke/which-key.nvim/blob/main/doc/which-key.txt
  why: exemplar of a focused feature help file with options tables + FAQ.
- url: https://github.com/nvim-lualine/lualine.nvim/blob/master/doc/lualine.txt
  why: exemplar of DEFAULTS ~ option tables + section/tag discipline.
```

### Current Codebase tree (relevant slice)

```bash
doc/
├── pi-bridge.txt          # COMPLETE sibling help (the template) — 19 tags today
├── pi-bridge-shell.txt    # ❌ MISSING — this task creates it
└── tags                   # auto-generated by :helptags; gains pi-bridge-shell* entries
lua/pi-bridge/
├── init.lua               # M.defaults.shell (L55-65) — the options-table source of truth
├── shell.lua              # daemon manager (resolve/ensure/request/teardown/status)
├── completion.lua         # completion_context() → "shell" routing (L456-525)
├── menu.lua               # visual_cue gutter "$ " (L185)
├── health.lua             # §5 shell section (L217) — emits the :help link this file fulfills
├── notify.lua             # shell-mismatch/shell-degrade/shell-active notices
└── shell/
    ├── fish.lua           # tier-1 driver
    ├── zsh.lua            # tier-1 driver
    ├── bash.lua           # tier-2 driver
    └── accept.lua         # local quoting + word replacement
```

### Desired Codebase tree with files to be added/edited

```bash
doc/
├── pi-bridge.txt          # EDITED — add cross-links (CONTENTS + §8 + §10) [Task 2]
├── pi-bridge-shell.txt    # NEW — the vimdoc [Task 1]
└── tags                   # REGENERATED via :helptags [Task 3]
```

### Known Gotchas of our codebase & Library Quirks

```text
# CRITICAL: the first line of a help file MUST be `*<exact-filename>*\t...`.
# `*pi-bridge-shell.txt*` (matching the filename) — or :helptags fails / E670.
# Mirror doc/pi-bridge.txt line 1 verbatim in structure.

# CRITICAL: the trailing modeline is load-bearing for ft=help detection +
# column-78 wrapping in the editor. EXACT bytes:
#  ' vim:tw=78:ts=8:noet:ft=help:norl:'   (leading space; copy from pi-bridge.txt)

# CRITICAL: tags are GLOBAL across all .txt in doc/. Adding pi-bridge-shell.txt
# + running :helptags auto-registers its *pi-bridge-shell* tags into the shared
# doc/tags. Cross-file |pi-bridge-shell| links from pi-bridge.txt just work.

# CRITICAL: NEVER paste the live PI_NVIM_BRIDGE descriptor (esp. `token`) into
# the help file (§12 security). Use the redacted shape from pi-bridge.txt §10.

# CRITICAL: the daemon sources user rc files (§17.13) — this is the SAME trust
# model as pi's own `!` execution. Document it as such; do NOT frame it as a new
# risk. The daemon is a child of nvim on local pipes; it NEVER touches the
# bridge socket (the §12 token boundary is unchanged).

# GOTCHA (content accuracy): `prefer` default is `"pi"` (pi's resolved execution
# shell), NOT `$SHELL`. This is THE central design decision (§17.2). An
# unconfigured zsh user gets BASH completion (tier-2) by default, because pi
# runs `!` in bash. Document why (wrong completions > plain completions) + the
# one-setting fix (pi's `shellPath` → $SHELL, or `prefer="shell"`).

# GOTCHA (do not over-document internals): the help file is USER-FACING. Do NOT
# paste the __PIREQ__/__PIRESP_START__/__PIRESP_END__ sentinel protocol, the
# gen-guard supersession, or the driver startup scripts. Those are in PRD §17 +
# source comments. The help file says WHAT the user sees + HOW to configure it,
# not HOW it is implemented. One sentence ("a persistent completion subshell")
# is enough for the daemon.

# GOTCHA (cross-link editing): when editing doc/pi-bridge.txt, insert cross-links
# at the pinned anchors (Task 2). Do NOT re-flow surrounding paragraphs (column
# wrap is hand-maintained; re-flowing creates noisy diffs + can break tag
# right-alignment).

# GOTCHA (validation): the AGENTS.md HARD RULE forbids piping a heredoc into
# nvim stdin (it hangs). To validate the help file, write the validation script
# to a FILE and run `:luafile`, or use the plenary-free smoke pattern. Never
# `nvim ... +"luafile /dev/stdin"`.
```

## Implementation Blueprint

### Data models and structure

N/A — this is a documentation task. No data models, schemas, or code structures
are created. The only "model" is the help-file structure (section list), defined
in Task 1.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE doc/pi-bridge-shell.txt  (the vimdoc — the primary deliverable)
  - WRITE a new ft=help file matching doc/pi-bridge.txt's conventions EXACTLY.
  - FIRST LINE (literal, tab-separated): 
      *pi-bridge-shell.txt*\tFor Nvim 0.11+.\tLast change: 2025 Aug 01
    (date = today's date; the tag MUST equal the filename or :helptags fails.)
  - LAST LINE (literal, leading space): 
       vim:tw=78:ts=8:noet:ft=help:norl:
  - STRUCTURE (mirror pi-bridge.txt's CONTENTS + === rules + right-aligned tags):
      1. Overview ............................ |pi-bridge-shell|
         - what it is: shell completion for `!`/`!!` bash-mode lines in the pi
           external editor, using the user's REAL shell completion engine.
         - the big picture: a persistent completion subshell (child of nvim)
           drives fish/zsh/bash; results render in the same floating menu as
           pi's own completions; accepted via local word-replacement (NOT pi's
           applyCompletion).
         - one-line activation: fires only on line 1 beginning with `!` (or
           `!!`), only inside a pi-launched editor (dormant otherwise).
      2. When it activates ................... |pi-bridge-shell-activation|
         - line 1 (cursorLine 0) begins with `!` or `!!` (pi bash mode).
         - the bangs are stripped before querying the shell.
         - dormant unless PI_NVIM_BRIDGE is set (cross-link |pi-bridge-env|).
      3. The shell mismatch + `prefer` ....... |pi-bridge-shell-prefer|
         - THE central design constraint (§17.2): pi runs `!`/`!!` in /bin/bash
           by default (NOT $SHELL) unless the user sets pi's `shellPath`.
         - the `prefer` contract (§17.4) with the 4-value table:
             "pi"       pi's resolved execution shell (DEFAULT; always consistent)
             "shell"    $SHELL (consistent iff shellPath==$SHELL)
             "bash"     /bin/bash
             "/abs/path" that path
         - WHY default "pi": wrong completions (a command that errors) are worse
           than plain completions; "pi" trades richness for correctness.
         - the §17.4.3 one-time mismatch notice: when resolved=bash + $SHELL is
           zsh/fish + that shell is on PATH → one dedup'd vim.notify pointing
           here. Cross-link |pi-bridge-shell-troubleshooting|.
      4. Per-shell drivers ................... |pi-bridge-shell-drivers|
         - fish — Tier 1: `complete -C`; yields word+description; clean win.
         - zsh  — Tier 1: capture-completion widget (compinit); yields
           word+description; most fragile across zsh versions.
         - bash — Tier 2: compgen/compspec + bash-completion; NO descriptions;
           opt-out via `setup({ shell = { drivers = { bash = false } } })`.
         - unknown shell → silent degrade to a plain buffer + one notice
           (cross-link |pi-bridge-shell-troubleshooting|).
         - driver quality is surfaced in :checkhealth (cross-link
           |pi-bridge-shell-health|).
      5. Configuration ........................ |pi-bridge-shell-config|
         - the `setup({ shell = { ... } })` invocation example in a `>` ... `<` block.
         - a DEFAULTS ~ block mirroring init.lua M.defaults.shell EXACTLY:
             shell.enabled            true        master switch (false → no `!` completion)
             shell.prefer             "pi"        §17.4 (pi|$SHELL|bash|/abs/path)
             shell.drivers            {fish,zsh,bash all true}  per-shell enable
             shell.warm_on_enter      false       spawn daemon at VimEnter
             shell.timeout_ms         1500        per-request budget
             shell.startup_timeout_ms 5000        daemon cold-start (rc load)
             shell.visual_cue         "gutter"    "gutter"|"border"|"off" (§17.9)
             shell.debounce_ms        0           shell-context debounce (immediate)
             shell.max_parse_failures 5           consecutive-failure threshold (§17.12)
         - each value MUST match lua/pi-bridge/init.lua L55-65 verbatim.
      6. Acceptance & quoting ................ |pi-bridge-shell-accept|
         - shell candidates are plain words, accepted via LOCAL word-replacement
           (shell/accept.lua), NOT pi's applyCompletion.
         - per-shell quoting: bash/zsh single-quote (with '"'"' idiom for
           embedded quotes); fish lighter rules. (§17.8)
         - uses nvim_buf_set_text (range edit, not whole-buffer rewrite).
         - re-triggers completion only if the candidate is a directory.
      7. Health .............................. |pi-bridge-shell-health|
         - `:checkhealth pi-bridge` → §5 "pi-bridge shell completion" reports:
           resolved shell + source, driver + tier, daemon health (alive / not
           spawned (lazy) / failed), effective config, last shell notice.
         - cross-link |pi-bridge-checkhealth| for the parent report.
      8. Security & trust model .............. |pi-bridge-shell-security|
         - the daemon SOURCES the user's rc files (~/.zshrc,
           ~/.config/fish/config.fish, ~/.bashrc + bash-completion) → executes
           user-authored code. This is the SAME trust model pi already operates
           under (pi executes arbitrary `!` commands, incl. aliases/functions
           from those same rc files). (§17.13)
         - the daemon is a child of the NVIM editor process, on LOCAL pipes
           only; it NEVER touches the bridge socket — the §12 token boundary
           is unchanged. Cross-link |pi-bridge-env|.
         - completion payloads are not logged beyond the opt-in local debug log.
      9. Failure modes / degrade ............. |pi-bridge-shell-degrade|
         - daemon spawn failure / startup timeout → silent degrade + ONE notice.
         - per-request timeout → abort + drop (gen-guard); menu as-is or closes.
         - N consecutive parse failures (default 5) → daemon killed + marked
           unhealthy; shell completion disabled for the session.
         - EOF on daemon pipe (crash) → unhealthy; one notice; no auto-respawn
           in v1.
         - NEVER blocks editor startup; the menu simply never opens for `!` lines.
      10. Troubleshooting / FAQ .............. |pi-bridge-shell-troubleshooting|
          - Q: "`!git ch<Tab>` shows nothing." → daemon failed / unsupported
            shell / not in a pi editor. Run `:checkhealth pi-bridge` (§5); read
            `:messages` for the one-time degrade notice.
          - Q: "I'm a zsh/fish user but got bash-quality completions." → the
            §17.2 mismatch: `prefer:"pi"` (default) resolved to bash because pi
            runs `!` in bash. Fix: set pi's `shellPath` to your shell (rich AND
            consistent), OR `setup({ shell = { prefer = "shell" } })`.
          - Q: "Completion stopped mid-session." → daemon crashed (EOF) or hit
            the parse-failure threshold; disabled for the session; see
            `:checkhealth` + `:messages`. Reopen the editor to restart it.
          - Q: "A filename with spaces quoted wrong." → see
            |pi-bridge-shell-accept|; if still wrong, file an issue with the
            candidate + resolved shell.
          - Q: "My shell is fish/nu/elvish and it's unsupported." → only
            fish/zsh/bash are supported (§17.6); others degrade silently. nu/
            elvish are future (§17.17).
          - Q: "Does this work on Windows?" → No. Git Bash completion is
            impoverished; unsupported, degrades silently (PRD §1 Non-Goals).
          - Q: "Does it complete multi-line / backslash-continued commands?" →
            No, only the current logical line (v1; §17.17 future).
  - FOLLOW pattern: doc/pi-bridge.txt (header/CONTENTS/===/tags/>/DEFAULTS ~/FAQ).
  - NAMING: tags are `pi-bridge-shell` + `pi-bridge-shell-<topic>` (hyphens OK).
  - PLACEMENT: doc/pi-bridge-shell.txt (repo root doc/).
  - CONTENT RULE: user-facing prose; paraphrase PRD §17, do NOT paste spec
    internals (sentinel strings, gen-guard, driver scripts, line numbers).

Task 2: EDIT doc/pi-bridge.txt  (add cross-links — pure additive, minimal)
  - ADD to the CONTENTS block a pointer line (keep column alignment with the
    existing dot-leader):
       Shell completion (!/!! bash mode) .... |pi-bridge-shell|
    Place it after the §13 Troubleshooting line / before the Autosave line (or
    at the end of the list — match the existing alignment exactly).
  - ADD an inline cross-link in §8 (pi-bridge-completion): after the bullet
    listing what pi's provider completes, add one sentence:
       For shell completion of `!`/`!!` bash-mode commands, see
       |pi-bridge-shell|.
  - ADD an inline cross-link in §10 (pi-bridge-env): after the descriptor JSON
    block, add a sentence noting the OPTIONAL `shell`/`shellSource`/`shellPath`
    fields and pointing to |pi-bridge-shell-prefer|:
       The descriptor MAY also carry optional `shell`/`shellSource`/`shellPath`
       fields (advisory; absent on older bridges) — see |pi-bridge-shell-prefer|.
  - PRESERVE: every existing line, tag, and column-wrap. Insert at the pinned
    anchors only; do NOT re-flow surrounding text.
  - GOTCHA: keep the `*pi-bridge-contents*` etc. tags intact; do not shift them.

Task 3: REGENERATE doc/tags  (so the new tags resolve)
  - RUN `:helptags` over the doc/ dir. Use the plenary-free smoke pattern (write
    a tiny .lua to /tmp or tests/, luafile it) — NEVER a heredoc into nvim stdin
    (AGENTS.md HARD RULE). Example safe invocation:
       nvim --headless --clean -u NORC -c "set rtp+=." \
         -c "lua vim.cmd('helptags doc')" -c "qa"
    or write tests/doc_helptags_smoke.lua and run it via :luafile.
  - VERIFY doc/tags now contains entries like:
       pi-bridge-shell\tpi-bridge-shell.txt\t/*pi-bridge-shell*
       pi-bridge-shell-config\tpi-bridge-shell.txt\t/*pi-bridge-shell-config*
       ... (one per tag defined in the new file)
  - VERIFY (smoke) that `:help pi-bridge-shell` opens the new file (Level-3 gate).

Task 4: VALIDATE  (smoke gates — no plenary needed for a doc-only change)
  - RUN the doc-load smoke (Level 1 below): opens both help files headless,
    asserts no E670/tag errors, asserts `:help pi-bridge-shell` resolves, asserts
    the modeline + first-line tag are correct.
  - RUN `:helptags` clean (no duplicate-tag errors).
  - VISUAL spot-check: open `:help pi-bridge-shell` in a real nvim, confirm
    highlighting (headers, tags, >blocks) renders like pi-bridge.txt.
```

### Implementation Patterns & Key Details

```text
# PATTERN: help-file skeleton (clone from doc/pi-bridge.txt)
*pi-bridge-shell.txt*\tFor Nvim 0.11+.\tLast change: 2025 Aug 01

          SHELL COMPLETION — pi-bridge.nvim
          Shell completion for `!`/`!!` bash-mode commands in the pi
          external editor, driven by your real shell's completion engine.

          License:  MIT

==============================================================================
CONTENTS                                  *pi-bridge-shell* *pi-bridge-shell-contents*

	1. Overview ............................ |pi-bridge-shell|
	2. When it activates ................... |pi-bridge-shell-activation|
	... (etc) ...
	10. Troubleshooting / FAQ .............. |pi-bridge-shell-troubleshooting|

==============================================================================
1. Overview                                  *pi-bridge-shell*

(prose...)

==============================================================================
2. When it activates                    *pi-bridge-shell-activation*

(prose + `>` example `<`)

... (sections 3-10) ...

 vim:tw=78:ts=8:noet:ft=help:norl:

# PATTERN: options table (mirror pi-bridge.txt §4 DEFAULTS ~)
DEFAULTS (mirror `lua/pi-bridge/init.lua` `M.defaults.shell`) ~

    shell.enabled            true        Master switch. false → `!`/`!!` lines
                                         get no completion.
    shell.prefer             "pi"        §17.4. "pi" | "shell" | "bash" |
                                         "/abs/path". Default "pi" = pi's
                                         resolved execution shell (always
                                         consistent with execution).
    ... (all 9 fields, values EXACTLY matching init.lua L55-65) ...

# PATTERN: cross-link from pi-bridge.txt (inline, minimal)
For shell completion of `!`/`!!` bash-mode commands, see |pi-bridge-shell|.

# PATTERN: > example block
Install + configure: >
    require("pi-bridge").setup({
      shell = { prefer = "shell", drivers = { bash = false } },
    })
<
```

### Integration Points

```yaml
HELP SYSTEM (Neovim):
  - new file: doc/pi-bridge-shell.txt  → auto-discovered by :helptags (scans
    all doc/*.txt); tags merge into the shared doc/tags index.
  - cross-links: |pi-bridge-shell| and |pi-bridge-shell-<topic>| resolve
    globally once :helptags runs.

EXISTING CROSS-LINK SOURCES (these already emit :help pi-bridge-shell; this
task makes their target exist):
  - lua/pi-bridge/health.lua:299  ("See :help pi-bridge-shell (P2.M3.T6.S4) ...")
  - lua/pi-bridge/notify.lua shell notice categories (shell-mismatch /
    shell-degrade / shell-active) — each advises :help pi-bridge-shell.

NO SOURCE / CONFIG / BEHAVIOR CHANGES:
  - this task touches ONLY doc/. No lua, no extension, no package.json, no
    config defaults. The subsystem is fully implemented (P2.M1–P2.M3); this is
    the documentation that closes it out.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# 1a. The help file loads under nvim with NO errors (E670 = duplicate/bad tag).
#     Write the checker to a FILE (AGENTS.md HARD RULE: never heredoc→nvim stdin).
cat > tests/doc_shell_smoke.lua <<'LUA'
local errs = {}
vim.diagnostic.config({}) -- ensure no surprise handlers
vim.api.nvim_create_autocmd("ShellCmdPost", { callback=function() end })
-- capture vim.v.errmsg / messages
local ok, parsed = pcall(vim.cmd, "help pi-bridge-shell")
-- assert the help buffer opened + is ft=help
local bufs = vim.api.nvim_list_bufs()
local found = false
for _, b in ipairs(bufs) do
  if vim.bo[b].filetype == "help" then found = true break end
end
assert(found, ":help pi-bridge-shell did not open a help buffer")
-- assert first-line tag + modeline by reading the file directly
local lines = vim.fn.readfile("doc/pi-bridge-shell.txt")
assert(lines[1]:find("^%*pi%-bridge%-shell%.txt%*"), "bad first-line tag: "..lines[1])
assert(lines[#lines]:find("vim:tw=78:ts=8:noet:ft=help:norl:"), "bad/missing modeline")
print("doc_shell_smoke: OK")
LUA
timeout 60 nvim --headless --clean -u NORC -c "set rtp+=." \
  +"luafile tests/doc_shell_smoke.lua" +qa
echo "exit=$?"

# 1b. :helptags regenerates cleanly (no duplicate-tag errors → exit 0).
timeout 60 nvim --headless --clean -u NORC -c "set rtp+=." \
  -c "helptags doc" -c "qa"
echo "exit=$?"

# 1c. grep the regenerated tags index for the new entries.
grep -c '^pi-bridge-shell\b' doc/tags          # expect >= 1
grep '^pi-bridge-shell-config\b' doc/tags      # expect a hit

# Expected: all exit 0; smoke prints "doc_shell_smoke: OK"; tags index populated.
```

### Level 2: Unit Tests (Component Validation)

```bash
# A documentation-only change has NO unit tests to run. The Lua test suite is
# unaffected (no .lua touched). Run the existing suite as a REGRESSION guard to
# confirm nothing was broken by the doc/ edits (it should be a pure no-op for
# the test layer):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/health_spec.lua")' \
  && echo "health_spec OK"
# (health_spec.lua asserts health.lua:299 emits the :help link; it does NOT
#  resolve the link, so it is unaffected by this task — green is the baseline.)

# Expected: existing suite green; no new tests required for a doc-only change.
```

### Level 3: Integration Testing (System Validation)

```bash
# 3a. End-to-end help resolution: `:help pi-bridge-shell` opens the new file at
#     the *pi-bridge-shell* tag; a sub-tag (`:help pi-bridge-shell-config`) jumps
#     to the config section. Write the checker to a FILE (AGENTS.md HARD RULE).
cat > /tmp/doc_shell_e2e.lua <<'LUA'
local function tag_opens(tag)
  vim.cmd("help " .. tag)
  local bt = vim.bo[vim.api.nvim_get_current_buf()].filetype
  return bt == "help"
end
assert(tag_opens("pi-bridge-shell"),       ":help pi-bridge-shell failed")
assert(tag_opens("pi-bridge-shell-config"),":help pi-bridge-shell-config failed")
assert(tag_opens("pi-bridge-shell-prefer"),":help pi-bridge-shell-prefer failed")
assert(tag_opens("pi-bridge-shell-drivers"),":help pi-bridge-shell-drivers failed")
assert(tag_opens("pi-bridge-shell-health"),":help pi-bridge-shell-health failed")
assert(tag_opens("pi-bridge-shell-troubleshooting"),
                                           ":help pi-bridge-shell-troubleshooting failed")
-- the dead link from health.lua:299 now resolves:
assert(tag_opens("pi-bridge-shell"), "health.lua:299 link still dead")
print("doc_shell_e2e: ALL TAGS RESOLVE")
LUA
timeout 60 nvim --headless --clean -u NORC -c "set rtp+=." \
  +"luafile /tmp/doc_shell_e2e.lua" +qa
echo "exit=$?"

# 3b. Cross-link from pi-bridge.txt resolves (the sibling file points here):
timeout 60 nvim --headless --clean -u NORC -c "set rtp+=." \
  -c "help pi-bridge-completion" -c "qa" && echo "pi-bridge.txt OK"

# Expected: all tags resolve; exit 0; "ALL TAGS RESOLVE" printed.
```

### Level 4: Creative & Domain-Specific Validation

```text
# Manual visual review (the real "did we ship good docs" gate):
#   1. Open a real nvim (not headless) on the repo: `nvim -c "set rtp+=."`
#   2. `:helptags doc`
#   3. `:help pi-bridge-shell` — confirm:
#        - section headers render as helpHeader (the === rule + title)
#        - *tags* are concealed/highlighted correctly
#        - |pi-bridge-shell-<topic>| links are navigable (Ctrl-])
#        - > example blocks render as helpExample
#        - DEFAULTS ~ block renders with the ~ as a header
#        - the modeline is the last line
#   4. `:help pi-bridge` → confirm the CONTENTS cross-link + inline §8/§10
#      links to |pi-bridge-shell| exist and navigate.
#   5. Read the prose end-to-end as a NEW USER: can you answer "why did I get
#      bash completions as a zsh user?" + "how do I fix it?" from the file alone?
#        - if yes → ship. if no → revise §prefer / §troubleshooting.

# Content-accuracy cross-check (no tool — a human/agent review pass):
#   - every value in the DEFAULTS ~ block matches lua/pi-bridge/init.lua L55-65.
#   - the prefer table matches PRD §17.4 + shell.lua resolve_shell (L168).
#   - driver tiers match PRD §17.6 + shell/fish.lua/zsh.lua/bash.lua.
#   - the trust model matches PRD §17.13.
#   - no live descriptor / token is pasted into the file (§12).

# Expected: visual review passes; content accuracy cross-check passes.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 smoke (`tests/doc_shell_smoke.lua`) prints "doc_shell_smoke: OK".
- [ ] `:helptags doc` exits 0 (no E670 / duplicate-tag errors).
- [ ] `doc/tags` contains `pi-bridge-shell` + `pi-bridge-shell-config` + the
      other defined tags.
- [ ] Level 3 e2e (`/tmp/doc_shell_e2e.lua`) prints "ALL TAGS RESOLVE".
- [ ] The dead link at `health.lua:299` (`:help pi-bridge-shell`) now resolves.
- [ ] Existing Lua test suite still green (regression guard; doc-only change).

### Feature Validation

- [ ] `:help pi-bridge-shell` opens the new file at the top tag.
- [ ] Every section's `*pi-bridge-shell-<topic>*` tag resolves via `:help`.
- [ ] First line is `*pi-bridge-shell.txt*` (matches filename); last line is the
      exact modeline ` vim:tw=78:ts=8:noet:ft=help:norl:`.
- [ ] `config.shell` options table mirrors `init.lua` `M.defaults.shell` (all 9
      fields, values verbatim).
- [ ] `prefer` contract + default `"pi"` + mismatch rationale documented.
- [ ] Driver tiers (fish/zsh/bash tier-1/1/2 + unknown degrade) documented.
- [ ] Trust model (rc sourcing = same trust as pi `!`; daemon is nvim child on
      local pipes; never touches bridge socket) documented.
- [ ] Troubleshooting FAQ covers the 7 listed scenarios.
- [ ] `doc/pi-bridge.txt` has ≥1 CONTENTS + ≥2 inline `|pi-bridge-shell|` links.
- [ ] Manual visual review (Level 4) passes.

### Code Quality Validation

- [ ] Doc prose matches the sibling's tone/voice (user-facing, not spec-internal).
- [ ] No PRD internals pasted (no sentinel strings, gen-guard, driver scripts,
      source line numbers, reference markers like §17.4.3 in the user prose —
      keep those as internal comments only if helpful, not in user-visible text).
- [ ] No live descriptor / token pasted (§12 security).
- [ ] Column-78 wrapping honored (the `tw=78` modeline); tags right-aligned.
- [ ] Diff is `doc/`-only (no lua/extension/config/package.json changes).

### Documentation & Deployment

- [ ] The file is self-contained (a user can learn the whole subsystem from it).
- [ ] Cross-links are bidirectional where useful (pi-bridge.txt → shell; shell
      → pi-bridge-env / pi-bridge-checkhealth).
- [ ] `:checkhealth pi-bridge` §5 + the runtime notices now point at real content.

---

## Anti-Patterns to Avoid

- ❌ Don't paste PRD §17 spec internals (sentinel protocol, gen-guard, driver
  startup scripts, lua line numbers) into a USER-FACING help file. Paraphrase.
- ❌ Don't re-flow existing paragraphs in `doc/pi-bridge.txt` when adding
  cross-links — insert at the pinned anchors only (hand-maintained column wrap).
- ❌ Don't hand-edit `doc/tags` — always regenerate via `:helptags`.
- ❌ Don't pipe a heredoc into `nvim` stdin to validate (AGENTS.md HARD RULE —
  it hangs). Write the checker to a FILE and run `:luafile`.
- ❌ Don't invent config values — mirror `init.lua` `M.defaults.shell` verbatim.
- ❌ Don't frame the rc-sourcing daemon as a NEW security risk — it's the SAME
  trust model as pi's own `!` execution (§17.13). Document it as such.
- ❌ Don't document `prefer` default as `$SHELL` — it is `"pi"` (the central
  design decision; §17.2). Getting this wrong misleads every zsh/fish user.
- ❌ Don't touch any `.lua`, the extension, `package.json`, or config defaults —
  this is a doc-only task. If you find yourself editing source, STOP.
- ❌ Don't skip the modeline or mis-format the first-line tag — `:helptags`
  silently breaks (E670) and `:help pi-bridge-shell` won't resolve.