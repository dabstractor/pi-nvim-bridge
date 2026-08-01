---
name: "P2.M4.T7.S2 — doc/pi-bridge.txt cross-link to shell completion + !/!! behavior"
description: |
  Enhance the main `doc/pi-bridge.txt` vimdoc so the shell-completion feature
  (documented in `doc/pi-bridge-shell.txt`) is discoverable and its `!`/`!!`
  activation behavior is explained inline. This is a documentation-only change
  to ONE file. No Lua, no TS, no behavior change.
---

## Goal

**Feature Goal**: Make `doc/pi-bridge.txt` (the primary `:help pi-bridge`
entry point) fully cross-reference the shell-completion subsystem
(`doc/pi-bridge-shell.txt`) and explain, inline, how `!`/`!!` bash-mode lines
change completion routing — so a user reading `:help pi-bridge` discovers
shell completion without already knowing it exists.

**Deliverable**: Edits to `doc/pi-bridge.txt` only:
1. A short "Shell completion (`!`/`!!`)" subsection in **§8 Completion behavior**
   explaining the routing + visual cue + a pointer to the full doc.
2. One troubleshooting FAQ entry in **§13** for the `!`/`!!` context
   (and the "why bash not zsh?" redirect).
3. Confirmation/tightening of the existing TOC pointer and the env-section
   cross-link (both already present — verify, don't re-add).

**Success Definition**: `:help pi-bridge` → reading §8 a user learns that a
`!` line triggers shell completion (a separate engine) and knows where to read
more (`|pi-bridge-shell|`). `:help pi-bridge` §13 has a FAQ entry for "I typed
`!git ch<Tab>` and got bash completions / why not my zsh aliases?". No broken
help tags; `:helptags doc/` produces zero errors.

## User Persona (if applicable)

**Target User**: A pi user who has installed `pi-bridge.nvim` and runs
`:help pi-bridge` to learn how completion works. Secondary: the same user who
hits the `!`/`!!` bash mode for the first time and is surprised by the shell
used.

**Use Case**: Discover shell completion from the main help file; understand
why a `!` line behaves differently from a `/cmd` or `@file` line.

**User Journey**: `:help pi-bridge` → §8 Completion behavior → sees the
`!`/`!!` note → follows `|pi-bridge-shell|` → lands on the full subsystem doc.

**Pain Points Addressed**: Currently §8 only says "For shell completion of
`!`/`!!` bash-mode commands, see |pi-bridge-shell|." (line 214) — a single
terse sentence buried mid-section. A user skimming the bullet list of what
completion produces may miss that `!` lines are a totally different engine.
The troubleshooting section has NO `!` entry, so the common "why bash not
my shell?" confusion has no anchor in the main doc.

## Why

- **Discoverability parity.** README.md (S1) and the shell vimdoc (P2.M3.T6.S4)
  are done; the only place a user lands first — `:help pi-bridge` — should make
  shell completion visible, not require it be known ahead of time.
- **Cohesion with the shipped subsystem.** The shell daemon, routing, drivers,
  and `:checkhealth` section all ship in P2.M1–M3. The main help must reflect
  that the plugin now has TWO completion engines, not one.
- **Closes the documentation loop for the changeset (P2.M4 — Mode B sync).**
  S1 = README, S2 = main vimdoc cross-link + behavior, S3 = extension README.
  This item is the middle of the three.

## What

### Scope — EDIT `doc/pi-bridge.txt` ONLY

This is a vimdoc-only change. Do NOT touch any Lua, TypeScript, README, or
the shell help file. Do NOT introduce new help tags beyond what already exists
in `pi-bridge-shell.txt` (reuse `|pi-bridge-shell|`, `|pi-bridge-shell-prefer|`,
`|pi-bridge-shell-activation|`, `|pi-bridge-shell-config|`,
`|pi-bridge-shell-troubleshooting|`).

### Success Criteria

- [ ] §8 "Completion behavior" has a clearly delimited **"SHELL COMPLETION
      (`!`/`!!` BASH MODE)" sub-block** (a tilde-underlined heading, matching
      the file's existing sub-heading style — see §11 ENV "OPTIONAL —
      minimal-config startup optimization ~" and §4 "DEFAULTS ... ~" for the
      `Heading ~` convention) that states:
      - A first line beginning with `!` or `!!` on line 1 routes to the SHELL
        engine, NOT pi's provider.
      - The leading bangs are stripped; e.g. `!git ch<Tab>` completes `git ch`.
      - Candidates are accepted via local word-replacement with per-shell
        quoting (NOT pi's `applyCompletion`).
      - A `$` gutter visual cue marks shell items (configurable via
        `shell.visual_cue`).
      - One sentence: defaults to pi's execution shell (often bash); see
        `|pi-bridge-shell-prefer|` for why + how to change it.
      - Pointer: full docs `|pi-bridge-shell|`.
- [ ] §13 "Troubleshooting / FAQ" gains one new Q/A:
      - Q: "Why does `!git ch<Tab>` complete with bash, not my zsh aliases?"
        A: redirect to `|pi-bridge-shell-prefer|` (pi runs `!` in bash by
        default; completions must match execution; set `shell.prefer` or pi's
        `shellPath`). Plus a sub-note: if NO completion appears on a `!` line,
        the daemon may be disabled / the shell unsupported — see
        `|pi-bridge-shell-troubleshooting|` + `|pi-bridge-shell-health|`.
- [ ] The existing cross-links are left intact (do NOT duplicate):
      - Line ~30 (CONTENTS pointer): `Shell completion (!/!! bash mode) ... |pi-bridge-shell|`
      - Line ~214 (§8 one-liner): keep it, but it now sits ABOVE the new
        sub-block as the lead-in (or fold it into the sub-block — see
        Implementation Tasks for the recommended approach).
      - Lines ~267-269 (§10 env descriptor `shell`/`shellSource`/`shellPath`
        note → `|pi-bridge-shell-prefer|`): leave as-is.
- [ ] `:helptags doc/` runs cleanly (no duplicate-tag warnings; the new text
      introduces no new `*tag*` markers).

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything
needed to implement this successfully?_ — YES. The deliverable is prose edits
to one vimdoc file. The feature it documents is already shipped and already
documented in `doc/pi-bridge-shell.txt`. The implementer needs: the target
file's existing heading/tag conventions (provided below), the exact cross-link
targets (existing tags, listed below), and the routing/accept facts (provided
below, sourced from the shipped shell doc).

### Documentation & References

```yaml
- file: doc/pi-bridge.txt
  why: THE file being edited. Sections 8, 10, 13 + CONTENTS pointer.
  pattern: vimdoc. Sub-headings use a trailing line then `Heading name ~`
    (e.g. §4 "DEFAULTS ... ~", §10 "OPTIONAL — minimal-config startup
    optimization ~"). Q/A entries in §13 use `Q: "..." ~` then `A: ...`.
  gotcha: Do NOT add new `*tag*` markers — reuse the tags already defined in
    pi-bridge-shell.txt. Adding a duplicate tag makes `:helptags` warn and
    breaks `:help <tag>`.

- file: doc/pi-bridge-shell.txt
  why: The subsystem doc being cross-linked. Source of all facts for the new
    §8 sub-block and §13 FAQ. Read it fully before writing.
  pattern: tags defined here = {pi-bridge-shell, pi-bridge-shell-contents,
    pi-bridge-shell-overview, pi-bridge-shell-activation, pi-bridge-shell-prefer,
    pi-bridge-shell-drivers, pi-bridge-shell-config, pi-bridge-shell-accept,
    pi-bridge-shell-health, pi-bridge-shell-security, pi-bridge-shell-degrade,
    pi-bridge-shell-troubleshooting}. Reuse these EXACT pipe targets.

- file: lua/pi-bridge/init.lua
  why: Confirms the `shell` config block exists + default `prefer = "pi"` and
    `visual_cue = "gutter"`. Quote these defaults accurately.
  pattern: look for `M.defaults.shell` / `shell = { ... }`.

- file: lua/pi-bridge/completion.lua
  why: Confirms routing fact: `completion_context()` returns "shell" iff line 1
    starts with `!`. Quote this precisely (it is the routing invariant).

- doc: PRD §17.2 (shell mismatch) + §17.4 (`prefer`) + §17.7 (routing)
  why: The canonical design rationale. The §13 FAQ answer must align with the
    "completions must match execution" framing.
```

### Current Codebase tree (relevant slice)

```
doc/
├── pi-bridge.txt          # ← EDIT THIS (S2)
├── pi-bridge-shell.txt    # ← READ THIS (source of facts; do not edit)
└── tags                   # generated by :helptags — do not hand-edit
lua/pi-bridge/
├── init.lua               # shell config block (read for defaults)
├── completion.lua         # completion_context() routing (read for the invariant)
└── shell.lua              # the daemon manager (read for accept/quoting facts)
README.md                  # ← S1 territory; do NOT edit here
extension/                 # ← S3 territory; do NOT edit here
```

### Desired Codebase tree with files to be added/modified

```
doc/
└── pi-bridge.txt          # MODIFIED: §8 sub-block + §13 FAQ entry (no new files)
```

No files are created or deleted. `doc/tags` will be regenerated by
`:helptags doc/` during validation (it is gitignored/generated — do not commit
hand edits to it; check the repo's `.gitignore`).

### Known Gotchas of our codebase & vimdoc quirks

```text
# CRITICAL: vimdoc tag hygiene
# - Every `*foo*` is a jump target. Adding a duplicate `*pi-bridge-shell*`
#   in pi-bridge.txt (when it is ALREADY defined in pi-bridge-shell.txt) makes
#   :helptags emit "Duplicate tag" and :help pi-bridge-shell ambiguous.
# - DO reference tags with |pi-bridge-shell| (pipe, no asterisks) — that is a
#   LINK, not a definition, and is correct/safe.

# CRITICAL: heading style consistency
# - This file uses `Heading text ~` (trailing tilde, after a blank line) for
#   sub-sections within a numbered section — e.g. line "DEFAULTS ... ~".
# - Do NOT invent a new heading marker. Match the existing style.

# CRITICAL: keep it terse
# - vimdoc lines stay <= ~78 cols (the file sets tw=78 in its modeline:
#   `vim:tw=78:ts=8:noet:ft=help:norl`). Wrap prose at col 78.

# The file's existing §8 already has a one-liner cross-link at line ~214:
#   "For shell completion of `!`/`!!` bash-mode commands, see |pi-bridge-shell|."
# DO NOT leave that orphaned. Either (a) keep it as the lead sentence of the
# new sub-block, or (b) delete it in favor of the richer sub-block. Recommended:
# (a) — promote it to the sub-block's opening sentence to avoid duplication.
```

## Implementation Blueprint

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ — gather the facts
  - READ doc/pi-bridge.txt fully (it is ~460 lines; know §4, §8, §10, §13).
  - READ doc/pi-bridge-shell.txt fully (it is the source of truth for every
    claim the new text will make).
  - READ lua/pi-bridge/init.lua for the exact `shell = { ... }` default block
    (prefer, visual_cue, etc.) so the §8 text quotes real defaults.
  - READ lua/pi-bridge/completion.lua for the `completion_context()` "shell"
    routing invariant (line 1 starts with "!").
  - NOTE the exact existing cross-link lines in pi-bridge.txt:
      CONTENTS pointer (~line 30), §8 one-liner (~line 214),
      §10 env descriptor note (~lines 267-269).

Task 2: EDIT §8 "Completion behavior" — add the SHELL COMPLETION sub-block
  - TARGET: the end of §8, immediately AFTER the "ACCEPTANCE ~" block and
    BEFORE the "9. Filetype" section divider (line ~"======" preceding
    *pi-bridge-filetype*).
  - APPROACH: the existing §8 one-liner ("For shell completion of ... see
    |pi-bridge-shell|.") currently sits after the bullet list. Fold it into a
    new trailing sub-block:
      SHELL COMPLETION (`!`/`!!` BASH MODE) ~
      <2-4 short paragraphs covering routing, bang-stripping, accept/quoting,
       visual cue, default shell + prefer pointer, full-doc pointer>
  - USE the `Heading ~` convention (blank line, then "SHELL COMPLETION (`!`/`!!`
    BASH MODE) ~").
  - LINK TARGETS (pipe form, exact): |pi-bridge-shell|,
    |pi-bridge-shell-activation|, |pi-bridge-shell-prefer|,
    |pi-bridge-shell-config|, |pi-bridge-shell-accept|.
  - WRAP at col 78 (file modeline: tw=78).
  - GOTCHA: do not introduce any `*new-tag*`. Only `|existing-tag|` links.

Task 3: EDIT §13 "Troubleshooting / FAQ" — add the `!`/`!!` Q/A
  - TARGET: inside §13, among the existing Q/A entries (after the "`@file`
    finds nothing." entry and before the "lost my prompt" entry is fine; pick
    a sensible position — group with the completion-behavior FAQs).
  - ADD one Q/A:
      Q: "Why does `!git ch<Tab>` complete with bash, not my zsh aliases?" ~
      A: <2-4 sentences — pi runs `!`/`!!` in /bin/bash by default; completions
         must match execution to avoid suggesting commands that fail; to use
         your native shell set shell.prefer (|pi-bridge-shell-prefer|) or pi's
         shellPath; if NO completion appears on a `!` line see
         |pi-bridge-shell-troubleshooting| + |pi-bridge-shell-health|.>
  - LINK TARGETS: |pi-bridge-shell-prefer|, |pi-bridge-shell-troubleshooting|,
    |pi-bridge-shell-health|.
  - MATCH the existing Q/A formatting exactly (`Q: "..." ~` heading line, then
    `A:` prose; see the "`@file` finds nothing." and "lost my prompt" entries
    for the template).

Task 4: VERIFY the existing cross-links (no edit unless broken)
  - CONFIRM the CONTENTS pointer line still reads:
    `	Shell completion (!/!! bash mode) ....... |pi-bridge-shell|`
  - CONFIRM §10 env descriptor note still cross-links to
    |pi-bridge-shell-prefer|.
  - If Task 2 folded the §8 one-liner into the sub-block, ensure the original
    orphan line is REMOVED (no duplicate mention of the same link within §8).

Task 5: VALIDATE
  - Run `:helptags doc/` (see Validation Loop) and confirm NO warnings.
  - Run `:help pi-bridge`, `:help pi-bridge-shell`, `:help pi-bridge-completion`
    and confirm all three resolve and the new links jump correctly.
  - Confirm `git diff --stat` shows ONLY doc/pi-bridge.txt changed.
```

### Implementation Patterns & Key Details

```text
# Sub-block heading (match the file's convention — see §4 "DEFAULTS ... ~",
# §10 "OPTIONAL — minimal-config startup optimization ~"):
SHELL COMPLETION (`!`/`!!` BASH MODE) ~

# Q/A entry (match §13 existing entries — see "`@file` finds nothing." ~):
Q: "Why does `!git ch<Tab>` complete with bash, not my zsh aliases?" ~
A: ...

# Routing fact to state precisely (from completion.lua + PRD §17.7):
# completion_context() returns "shell" IFF line 1 starts with "!". The leading
# bangs ("!" or "!!") are stripped before querying the shell daemon.

# Accept fact to state precisely (from shell/accept.lua + PRD §17.8):
# Shell candidates are plain WORDS, not pi AutocompleteItems, so acceptance
# does NOT use pi's applyCompletion — it does a local word-replacement via
# nvim_buf_set_text with per-shell quoting.

# Default-shell fact to state precisely (from init.lua defaults + PRD §17.4):
# shell.prefer defaults to "pi" → pi's execution shell (commonly /bin/bash).
# This keeps completions consistent with execution. See |pi-bridge-shell-prefer|.
```

### Integration Points

```yaml
VIMDOC:
  - file: doc/pi-bridge.txt
  - sections touched: §8 (add sub-block), §13 (add Q/A)
  - tags: NONE added; only |...| links to existing pi-bridge-shell* tags

CONFIG: none
ROUTES: none
DATABASE: none
```

## Validation Loop

This is a documentation change. The "tests" are vimdoc validity checks.

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# 1. Regenerate the help tag index from the repo root and watch for warnings.
nvim --headless --clean -c "helptags doc/" -c "qa"
echo "exit=$?"
# Expected: exit=0 and NO "Duplicate tag" / "E..." lines on stderr.
# (A clean :helptags prints nothing; any output = a problem.)

# 2. Line-length sanity (the file's modeline is tw=78).
awk 'length > 78 {print FILENAME":"NR": "length" cols"}' doc/pi-bridge.txt
# Expected: no output (or only pre-existing long lines — do not introduce new ones).
```

### Level 2: Resolve & link checks (the real "unit test")

```bash
# Write a tiny validator to a FILE (NEVER pipe a heredoc into nvim stdin —
# see AGENTS.md HARD RULE). It opens each tag and asserts resolution.
cat > /tmp/check_help.lua <<'LUA'
local tags = {
  "pi-bridge", "pi-bridge-completion", "pi-bridge-troubleshooting",
  "pi-bridge-shell", "pi-bridge-shell-prefer", "pi-bridge-shell-activation",
  "pi-bridge-shell-config", "pi-bridge-shell-accept",
  "pi-bridge-shell-troubleshooting", "pi-bridge-shell-health",
}
local fail = 0
for _, t in ipairs(tags) do
  local ok = pcall(vim.cmd, "help " .. t)
  if not ok then print("MISSING TAG: " .. t); fail = fail + 1 end
end
if fail == 0 then print("ALL " .. #tags .. " TAGS RESOLVE OK") end
vim.cmd("qa")
LUA
timeout 30 nvim --headless --clean -u NORC \
  -c "set rtp+=." \
  +"luafile /tmp/check_help.lua"
echo "exit=$?"
# Expected: "ALL 10 TAGS RESOLVE OK", exit=0.
# CRITICAL: this uses luafile <file> + qa, NOT a heredoc into nvim stdin.
```

### Level 3: Content review (manual, scripted)

```bash
# Confirm the new sub-block and FAQ are present and cross-link correctly.
grep -nE 'SHELL COMPLETION \(`!/\?\?` BASH MODE\)|Why does `!git|pi-bridge-shell' doc/pi-bridge.txt
# Expected: shows the new §8 heading, the new §13 Q, and the existing links.

# Confirm the diff is scoped to the one file.
git diff --stat
# Expected: only  doc/pi-bridge.txt  changed.
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Smoke: render :help pi-bridge headless and grep the rendered buffer for the
# new content + that the |pi-bridge-shell| link is navigable.
cat > /tmp/render_help.lua <<'LUA'
vim.cmd("help pi-bridge")
vim.cmd("only")
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local txt = table.concat(lines, "\n")
local checks = {
  { "shell sub-block heading", "SHELL COMPLETION" },
  { "bang routing fact",       "line 1" },       -- "a first line beginning with"
  { "prefer pointer",          "pi-bridge-shell-prefer" },
  { "faq entry",               "Why does `!git" },
}
local miss = 0
for _, c in ipairs(checks) do
  if not txt:find(c[2], 1, true) then
    print("MISSING in rendered help: " .. c[1]); miss = miss + 1
  end
end
if miss == 0 then print("RENDER CHECK OK") end
vim.cmd("qa")
LUA
timeout 30 nvim --headless --clean -u NORC \
  -c "set rtp+=." \
  +"luafile /tmp/render_help.lua"
echo "exit=$?"
# Expected: "RENDER CHECK OK", exit=0.
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `nvim --headless --clean -c "helptags doc/" -c "qa"` → exit 0, no warnings.
- [ ] Level 1: no NEW lines over 78 cols (`awk length>78` check).
- [ ] Level 2: all 10 tags resolve (`/tmp/check_help.lua`).
- [ ] Level 3: `git diff --stat` shows ONLY `doc/pi-bridge.txt`.
- [ ] Level 4: render check passes (`/tmp/render_help.lua`).

### Feature Validation

- [ ] §8 has a SHELL COMPLETION sub-block covering: routing (line 1 `!`),
      bang-stripping, accept-via-word-replacement + quoting, `$` visual cue,
      default shell + `prefer`, and a `|pi-bridge-shell|` pointer.
- [ ] §13 has a `!`/`!!` FAQ that redirects mismatch questions to
      `|pi-bridge-shell-prefer|` and no-completion questions to
      `|pi-bridge-shell-troubleshooting|` / `|pi-bridge-shell-health|`.
- [ ] No duplicate/orphaned cross-links (the old §8 one-liner is folded in or
      intentionally kept, not both saying the same thing twice).

### Code Quality Validation

- [ ] Heading style matches the file's `Heading ~` convention.
- [ ] Q/A formatting matches existing §13 entries.
- [ ] No new `*tag*` definitions introduced (links only).
- [ ] Prose wrapped at col 78 per the modeline.

### Documentation & Deployment

- [ ] The change is self-documenting (it IS documentation).
- [ ] No new environment variables or config keys introduced.

---

## Anti-Patterns to Avoid

- ❌ Don't add new help tags (`*foo*`) — reuse `pi-bridge-shell*` from the
  shell doc. Duplicate tags break `:helptags`.
- ❌ Don't edit `doc/pi-bridge-shell.txt`, `README.md`, or `extension/*` —
  those belong to other items (P2.M3.T6.S4, P2.M4.T7.S1, P2.M4.T7.S3).
- ❌ Don't pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE). Write the
  validator Lua to a file (`/tmp/*.lua`) and run with `+"luafile <file>" +qa`.
- ❌ Don't duplicate the existing §8 one-liner and the new sub-block saying the
  same thing — fold or replace.
- ❌ Don't state routing/accept facts from memory — read `completion.lua`,
  `shell/accept.lua`, and `init.lua` and quote the real behavior.
- ❌ Don't exceed ~78 cols (the file's modeline is `tw=78`).