name: "P1.M2.T7.S1 — Sync changeset-level documentation (shell-completion bugfix 001_842ac90ede70)"
description: "Documentation sweep so user-facing docs match the shell-completion fixes that LANDED in commits 1a0a071..d8d4adf (Issues 1, 2, 4, 5, 6). NOTE: the 3 files named in the task title are ALREADY consistent; the real work is in doc/pi-bridge-shell.txt (8 gaps) + one coupled health.lua line."

---

## Goal

**Feature Goal**: Make every user-facing doc file consistent with the shell-completion
changeset that landed in commits `1a0a071..d8d4adf` (the P1.M1 + P1.M2 fixes: Issues 1,
2, 4, 5, 6). No doc should make a claim the code contradicts, and no code behavior the
changeset introduced should be undocumented.

**Deliverable**: A reconciled `doc/pi-bridge-shell.txt` (8 concrete fixes), one coupled
1-line code change in `lua/pi-bridge/health.lua` (so a doc claim about `:checkhealth` is
honest), a verified-clean pass over `README.md` / `extension/README.md` / `doc/pi-bridge.txt`
(already consistent — confirm, do not rewrite), and regenerated `doc/tags`. All existing
doc-smoke / notice / health tests still green.

**Success Definition**:
- `doc/pi-bridge-shell.txt` no longer contains the 8 stale/missing spots cataloged below.
- `:checkhealth pi-bridge` actually reports the `shell-consistency` notice (code + doc aligned).
- No doc claims `prefer:"pi"` is *unconditionally* consistent (Issue 2 caveat present).
- No doc claims the cross-context supersession race (Issue 3) is fixed — it is NOT.
- `timeout 60 nvim --headless --clean -u NORC +"luafile tests/doc_shell_smoke.lua" +qa` passes.
- `tests/health_smoke.lua`, `tests/health_spec.lua`, `tests/shell_notices_spec.lua` pass.

## Why

- The bugfix changeset touched code in `lua/pi-bridge/shell.lua` + the 3 drivers, and *partly*
  touched docs (commit `69f332b "Align overview docs with shell mismatch fixes"`). Three of
  the four doc files were fully reconciled then; `doc/pi-bridge-shell.txt` was only partly
  updated, leaving 8 spots that contradict the new behavior or omit a new feature.
- A user reading the stale config table (`prefer:"pi"` = "always consistent") or the
  "three notices" line is misled exactly in the cases the bugfix tried to clarify.
- This is the final (changeset-consolidating) task of milestone P1.M2; it closes the loop
  between code and prose so the v1 ship is coherent.

## What

Doc-only reconciliation of `doc/pi-bridge-shell.txt` against the landed code, plus a
**single coupled code line** in `health.lua` that the doc accuracy depends on. Verify (not
rewrite) the three already-consistent files named in the task title.

### Success Criteria

- [ ] All 8 gaps in `doc/pi-bridge-shell.txt` fixed with the exact replacements below.
- [ ] `health.lua:321` `ipairs` list includes `"shell-consistency"` (coupled to GAP-2).
- [ ] `README.md`, `extension/README.md`, `doc/pi-bridge.txt` confirmed consistent — NO edits.
- [ ] `doc/tags` regenerated (`:helptags doc/`) and `tests/doc_shell_smoke.lua` passes.
- [ ] Issue 3 (supersession race) is NOT documented as fixed anywhere.

## All Needed Context

### Context Completeness Check

> If someone knew nothing about this codebase, would they have everything needed to implement
> this successfully? **Yes** — every gap below is pinned to a file:line with the exact current
> text and the exact replacement text. The coupled code change is one literal string added to
> one `ipairs` list. No inference about behavior is required; the code-behavior spec is embedded.

### ⚠️ CRITICAL SCOPING NOTES — read before touching anything

1. **The 3 files in the task title are ALREADY consistent.** `git diff 1a0a071~1 HEAD --
   README.md doc/pi-bridge.txt doc/pi-bridge-shell.txt extension/README.md` shows the changeset
   already reconciled `README.md`, `doc/pi-bridge.txt`, and `extension/README.md`. The reviewer
   audit (see research) found **zero** stale gaps in those three. **Do not rewrite them.** Your
   job for those three is a *verification read* only (confirm the claims still match the code in
   §"Code behavior the docs must reflect" below; if — and only if — you find a real
   contradiction, make the minimal edit). All **8 real gaps are in `doc/pi-bridge-shell.txt`**,
   which the task title does NOT name but which is the shell-specific doc and is in scope.

2. **Issue 3 (P1.M2.T4.S1) is NOT in the code.** The plan status marks it "Complete" but there
   is **no commit** for it and `lua/pi-bridge/completion.lua:542-546` (the `if not ctx then`
   plain-typing close branch) still does NOT bump `state.gen` and does NOT cancel inflight.
   Confirmed by direct code read (see research/code_behavior_spec.md §7). **Do NOT document
   the supersession race as fixed.** GAP-5 below is SOFTENED, not removed, for this reason.

3. **zsh `cd()` is a script-level no-op.** Issue 4 wired the Lua-side `complete_current` →
   `state.driver.cd` re-cd (`shell.lua:1057-1070`), and `bash`/`fish` honor it (real
   `builtin cd`). But `zsh`'s `OUTER_SCRIPT` case branch for `__PICD*` is a literal `;;`
   no-op — the frame is written then discarded. So GAP-4's docs must say: bash/fish track a
   mid-session cwd change; zsh does not (frozen at spawn — reopen the editor to refresh).

4. **GAP-2 has a coupled CODE dependency.** `health.lua:321` iterates only
   `{ "shell-degrade", "shell-mismatch", "shell-active" }` — it omits the new
   `"shell-consistency"` category. So if you only edit the doc to say "four notices, run
   `:checkhealth` to see which fired", the doc would be **false** (`:checkhealth` cannot
   report `shell-consistency` today). You MUST also add `"shell-consistency"` to that
   `ipairs` list (Task 9) so doc and code agree. This is the only code change in this task.

5. **AGENTS.md HARD RULE (this repo):** never pipe a heredoc / stdin into `nvim` — it hangs
   the session. Write any lua to a FILE and run `+"luafile <path>"`. Wrap every `nvim`
   invocation in `timeout`. Do not touch `PRD.md`, `plan/`, `tasks.json`, `prd_snapshot.md`,
   `TEST_RESULTS.md`. `lua/` (implementation) + the doc files are in your edit allowlist.

### Documentation & References

```yaml
# Code the docs must match (READ these — do not edit except health.lua:321)
- file: lua/pi-bridge/shell.lua
  why: M.resolve_shell (L196-226) per-prefer table; descriptor_shell() (L147-172) returns
       (path, shellSource); M.ensure() two notices — "shell-mismatch" gated on prefer=="pi"
       (L432-448) and NEW "shell-consistency" (L449-467); complete_current cwd re-track (L1057-1070).
  pattern: the EXACT notice category keys + messages + trigger conditions live here — quote them.
  gotcha: resolve_shell("pi") propagates the REAL descriptor.shellSource (Issue 5), with an
          `or "pi"` fallback for old descriptors — health now shows the real source.

- file: lua/pi-bridge/health.lua
  why: Section 5 resolved-shell line format "resolved shell: %s (source: %s, prefer: %s)" (L172-174);
       AND the notice-report ipairs list at L321 (the GAP-2 code dependency — add "shell-consistency").
  pattern: did_notify(cat) table-read loop; adding one string to the ipairs list is the whole change.

- file: lua/pi-bridge/shell/fish.lua / zsh.lua / bash.lua
  why: Issue 6 graceful-degrade guards (empty cmd OR odd-count trailing backslash → empty result)
       are in all three DAEMON_SCRIPTs; zsh's __PICD* case is a no-op (Issue 4 nuance).

- file: doc/pi-bridge-shell.txt   # THE file with the 8 gaps — primary edit target
- file: README.md                 # ALREADY consistent — verify only
- file: extension/README.md       # ALREADY consistent — verify only
- file: doc/pi-bridge.txt         # ALREADY consistent — verify only
- file: tests/doc_shell_smoke.lua # the doc-validation harness (helptags, cross-links, modeline)
```

### Code behavior the docs must reflect (landed changeset — quoted from code)

**A. `prefer` resolution** (`shell.lua:196-226`). `source` values: `"pi"` (descriptor
advertised, or `or "pi"` back-compat) | `"$SHELL"` | `"default"` (`/bin/bash`) | `"config"`
(explicit `/abs/path`). `prefer:"pi"` (default) is NOT unconditionally consistent: when the
bridge cannot read pi's execution shell (PRD §17.10.2), the descriptor carries no shell, so
`resolve_shell` falls through to `$SHELL` → completion uses zsh/fish while pi EXECUTES in bash.

**B. Notice 1 — `shell-mismatch`** (`shell.lua:432-448`, WARN, `notify.once`). Category key
`"shell-mismatch"`. **Gated on `(cfg.prefer or "pi") == "pi"`** (Issue 1). Fires only when
resolved==bash AND `$SHELL` basename ∈ {zsh,fish} AND on PATH. Message (example, richer="zsh"):
`pi-bridge: pi runs commands in bash; using bash completion to match. For your native zsh completions, set pi's shellPath to /bin/zsh (then completion and execution both use it). :help pi-bridge-shell`
Does NOT fire under `prefer="bash"` or explicit `/abs/path`.

**C. Notice 2 — `shell-consistency`** (`shell.lua:449-467`, WARN, `notify.once`). Category key
`"shell-consistency"` — **DISTINCT dedup set** from `shell-mismatch`. Fires iff:
`(cfg.prefer or "pi")=="pi"` AND `source=="$SHELL"` AND `basename($SHELL)` ∈ {zsh,fish} AND
`executable==1`. Message (example, env_base="zsh"):
`pi-bridge: completions use zsh (from $SHELL) but pi may execute commands in bash. For guaranteed consistency set PI_NVIM_SHELL=/bin/zsh (or pi's shellPath). :help pi-bridge-shell`
(The two notices are mutually exclusive in practice: #1 needs resolved==bash, #2 needs resolved==$SHELL.)

**D. Health** (`health.lua:172-174`): prints `resolved shell: <path> (source: <source>, prefer: <prefer>)`
where `source` is the REAL `shellSource` (Issue 5). **But** the notice-report loop at `health.lua:321`
omits `shell-consistency` — fix in Task 9.

**E. CWD re-tracking** (`shell.lua:1057-1070`, Issue 4): on each `complete_current`, if
`state.proc` exists AND `state.driver.cd` is a function AND `cur_cwd ~= state.cwd`, it
`pcall(state.driver.cd, cur_cwd)` + updates `state.cwd`. bash/fish honor it (real `builtin cd`);
**zsh discards the `__PICD*` frame (no-op) — v1 limitation**.

**F. Graceful degrade** (Issue 6, all 3 driver DAEMON_SCRIPTs): empty cmd OR odd-count trailing
backslash → emit `{"items":[],"prefix":""}` (clean empty, NOT an all-commands flood). Always
wrapped in `__PIRESP_START__`/`__PIRESP_END__`.

## Implementation Blueprint

### Implementation Tasks (ordered by dependency)

> All line numbers are against the CURRENT files (HEAD = `d8d4adf`). Re-locate with the
> quoted "CURRENT TEXT" before editing (lines drift). Every fix below is exact text.

```yaml
Task 0: VERIFY (do NOT edit) the three already-consistent files
  - READ: README.md, extension/README.md, doc/pi-bridge.txt
  - CONFIRM each matches code behavior A–F above. Expected: no contradictions.
  - The changeset (commit 69f332b + others) already reconciled them.
  - EDIT RULE: only if you find a genuine NEW contradiction not covered by GAP-1..8; otherwise
    leave them byte-for-byte unchanged. If you do edit, keep it minimal and re-run doc_shell_smoke.

Task 1: FIX GAP-1 — doc/pi-bridge-shell.txt §5 config table "always consistent" (MEDIUM)
  - LOCATE: the `shell.prefer` config-table cell (~L226-230). CURRENT TEXT ends:
        Default "pi" = pi's resolved
        execution shell (always consistent
        with what will actually run).
  - REPLACE those last two lines with:
        Default "pi" = pi's resolved
        execution shell (intended to match
        what `!` will run; see §3 for the
        one non-bash-`$SHELL` gap +
        `PI_NVIM_SHELL`).
  - WHY: contradicts the §3 "DEFAULT-CASE CONSISTENCY GAP" subsection the SAME changeset added.

Task 2: FIX GAP-2 — doc/pi-bridge-shell.txt §7 "three notices" → four (MEDIUM)  [COUPLED W/ Task 9]
  - LOCATE: §7 Health bullet (~L314-315). CURRENT TEXT:
        whether any of the three shell notices (shell-mismatch / shell-degrade /
        shell-active) fired earlier this session — run `:messages` to read them.
  - REPLACE WITH:
        whether any of the four shell notices (shell-mismatch / shell-consistency /
        shell-degrade / shell-active) fired earlier this session — run `:messages`
        to read them.
  - WHY: Issue 2 added the `shell-consistency` category. THIS FIX IS ONLY HONEST IF Task 9
         (add "shell-consistency" to health.lua:321) also lands — do both together.

Task 3: FIX GAP-3 — doc/pi-bridge-shell.txt §4 graceful-degrade documented fish-only (MEDIUM)
  - LOCATE: §4 TIER 1 fish "Notes" (~L155-159). CURRENT TEXT attributes the literal-`"` empty
        result to fish only ("A known edge case is that a command line containing a literal
        `"` can return an empty candidate set").
  - REWORD the fish note to indicate it is cross-driver, AND add one shared sentence to the
        zsh (TIER 1) and bash (TIER 2) Notes blocks (~L174-179, ~L184-186), e.g.:
        A literal `"` on the line, or an empty command (bare `!`), returns an empty
        candidate set on purpose (graceful degrade — prevents a full command listing
        flood; the menu just stays closed).
  - WHY: Issue 6 guards exist in ALL three drivers (bash/zsh/fish); doc covered fish only.

Task 4: ADD GAP-4 — doc/pi-bridge-shell.txt CWD TRACKING subsection (MISSING, MEDIUM)
  - LOCATE: a sensible anchor — e.g. end of §2 (after "VISUAL CUE") or end of §4 (after the
        driver tiers). There is currently NO cwd-tracking prose anywhere in the file.
  - ADD a short subsection, e.g.:
        CWD TRACKING ~
        The daemon starts in pi's session cwd (the descriptor `cwd` / `server_info.cwd`)
        and re-`cd`s mid-session if pi's cwd changed since spawn, so relative-path
        completions track pi's working directory. bash and fish honor the re-`cd`; zsh is
        a known v1 limitation — its `zpty` capture outer discards the `cd` frame, so a zsh
        daemon's cwd stays fixed at spawn (reopen the editor after a `cd` to refresh it).
  - WHY: Issue 4 wired mid-session re-cd (bash/fish real; zsh no-op). Entirely undocumented.

Task 5: FIX GAP-5 — doc/pi-bridge-shell.txt §9 supersession over-promise (LOW/MEDIUM)
  - LOCATE: §9 PER-REQUEST TIMEOUT (~L366). CURRENT TEXT:
        The daemon itself is NOT killed — the next request proceeds normally. (Only ONE
        request is in flight at a time; a newer keystroke supersedes a pending one.)
  - REPLACE the parenthetical with:
        (Only ONE shell request is in flight at a time; a newer `!`-line keystroke
        supersedes a pending one. Note: deleting the leading `!` mid-flight is a known
        gap — the in-flight shell result is not yet cancelled there.)
  - WHY: Issue 3 (the cross-context supersession race) is NOT fixed (see SCOPING NOTE 2).
         Do NOT claim a general "newer keystroke supersedes" guarantee.

Task 6: FIX GAP-6 — doc/pi-bridge-shell.txt §3 "ONE-TIME NOTICE" covers only mismatch (LOW)
  - LOCATE: §3 "THE ONE-TIME NOTICE" heading (~L139-146).
  - RENAME heading to "THE SHELL-MISMATCH NOTICE ~" and append one line after the block:
        A second, distinct notice (`shell-consistency`) covers the non-bash-`$SHELL`
        fallback case — see "THE DEFAULT-CASE CONSISTENCY GAP" above + §7.
  - WHY: consolidates the two notices; the §3 gap paragraph mentions #2 only in passing.

Task 7: FIX GAP-7 — doc/pi-bridge-shell.txt §10 FAQ missing Issue-2 inverse case (LOW)
  - LOCATE: §10 FAQ Q "I'm a zsh/fish user but I got bash-quality completions" (~L395-404).
  - ADD a paired Q after it:
        Q: "I SEE zsh/fish completions on `!` lines, but the command then FAILS under
           bash (e.g. a zsh-only alias)."
        A: The resolver fell back to `$SHELL` (the bridge could not read pi's execution
           shell — §3 "DEFAULT-CASE CONSISTENCY GAP"). Export `PI_NVIM_SHELL=<that shell>`
           (or set pi's `shellPath`) so completion matches execution.
  - WHY: README troubleshooting + pi-bridge.txt §13 FAQ already cover this inverse case;
         this file's FAQ does not → three-way inconsistency.

Task 8: FIX GAP-8 — doc/pi-bridge-shell.txt §3 "THE MISMATCH" unconditional claim (LOW)
  - LOCATE: §3 "THE MISMATCH" (~L86). CURRENT TEXT:
        … by default this plugin completes using pi's execution shell — bash — which is
        always consistent with execution, but offers fewer completions than a native zsh/fish setup.
  - SOFTEN "always consistent" → "intended to be consistent with execution (see the gap
        below)". (The next subsection already walks it back; this makes the assertion itself hedged.)
  - WHY: low risk (hedged ~5 lines later) but the authoritative sentence currently overstates.

Task 9: CODE — lua/pi-bridge/health.lua:321 add "shell-consistency" to notice ipairs  [COUPLED W/ Task 2]
  - LOCATE: health.lua:321. CURRENT:
        for _, cat in ipairs({ "shell-degrade", "shell-mismatch", "shell-active" }) do
  - REPLACE WITH:
        for _, cat in ipairs({ "shell-degrade", "shell-mismatch", "shell-consistency", "shell-active" }) do
  - WHY: without this, :checkhealth cannot report that the shell-consistency notice fired,
         making Task 2's "four notices" doc line FALSE. Single-string addition; no logic change.
  - VERIFY: tests/health_smoke.lua + tests/health_spec.lua still pass after this change.

Task 10: REGENERATE doc/tags + run the doc smoke
  - After all doc edits: regenerate the help tag index (doc_shell_smoke asserts entries exist):
        nvim --headless --clean -u NORC -c 'helptags doc' -c 'qa'
    (one-liner, no heredoc — AGENTS.md compliant). Then run Level 1 below.
```

### Implementation Patterns & Key Details

```lua
-- The ONLY code change is one string added to one ipairs list (Task 9). Pattern to follow:
-- health.lua:321 already iterates did_notify(cat) per category — adding "shell-consistency"
-- means :checkhealth will report it the same way it reports the other three. Do NOT add any
-- branching, messages, or new helpers — just the list entry. The notice itself is ALREADY
-- emitted by shell.lua:449-467; this only makes :checkhealth AWARE of it.
```

```vim
# Vimdoc edit discipline (doc/pi-bridge-shell.txt):
# - Preserve column alignment in the §5 config table (it is a formatted table; keep the
#   right-edge ragged-but-aligned like the neighbouring rows).
# - Keep the trailing modeline EXACT: `vim:tw=78:ts=8:noet:ft=help:norl:` (doc_shell_smoke asserts it).
# - First line must stay `*pi-bridge-shell.txt*` (helptags requires it).
# - Reuse existing helptag targets (|pi-bridge-shell-prefer|, |pi-bridge-shell-troubleshooting|,
#   |pi-bridge-shell-degrade|) — do NOT invent new tags unless you also add them as targets.
# - New subsection headings use the `HEADING ~` two-space-tilde form used elsewhere in the file.
```

### Integration Points

```yaml
DOCS:
  - primary edit target: doc/pi-bridge-shell.txt (8 fixes: GAP-1..8)
  - verify-only (no edits expected): README.md, extension/README.md, doc/pi-bridge.txt
CODE:
  - one coupled line: lua/pi-bridge/health.lua:321 (add "shell-consistency" to ipairs)
TAGS:
  - regenerate: doc/tags via `:helptags doc` (doc_shell_smoke asserts pi-bridge-shell* entries)
NO DB / NO CONFIG / NO ROUTES — pure docs + one health-report line.
```

## Validation Loop

### Level 1: Doc integrity (run after every doc edit batch)

```bash
# Regenerate the help tag index (one-liner, AGENTS.md-compliant — NO heredoc into nvim stdin)
timeout 30 nvim --headless --clean -u NORC -c 'helptags doc' -c 'qa'
echo "helptags exit=$?"

# Doc smoke: tags resolve, first-line tag, modeline, cross-links, doc/tags entries
timeout 60 nvim --headless --clean -u NORC +"luafile tests/doc_shell_smoke.lua" +qa
echo "doc_shell_smoke exit=$?"
# Expected: no assertion errors, exit 0.

# Sanity: the four notice categories now appear in the doc + code
grep -n "shell-consistency" doc/pi-bridge-shell.txt   # GAP-2/GAP-6 prose
grep -n "shell-consistency" lua/pi-bridge/health.lua  # Task 9 code line
grep -c "always consistent" doc/pi-bridge-shell.txt   # GAP-1/GAP-8 → expect 0 after fixes
```

### Level 2: Health + notices tests (after Task 9 code change)

```bash
# Plenary specs (run from repo root):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/health_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_notices_spec.lua")'

# Smokes (no plenary):
timeout 60 nvim --headless --clean -u NORC +"luafile tests/health_smoke.lua" +qa
timeout 60 nvim --headless --clean -u NORC +"luafile tests/shell_notices_smoke.lua" +qa
# Expected: all pass. Task 9 only ADDS a category to an ipairs list — no behavior change.
```

### Level 3: Whole-doc consistency read (manual eyeball)

```bash
# Re-read the edited file end-to-end; confirm no internal contradiction remains:
#  - §3 "DEFAULT-CASE CONSISTENCY GAP", "THE MISMATCH", "THE SHELL-MISMATCH NOTICE" are coherent
#  - §5 config table cell no longer says "always consistent"
#  - §7 lists FOUR notices and :checkhealth can actually report all four (Task 9)
#  - §4/CWD TRACKING documents the zsh no-op
#  - §9 does not promise cross-context supersession (Issue 3 caveat present)
#  - §10 FAQ covers BOTH directions (got-bash / saw-zsh-then-failed)
grep -niE "always consistent|three shell notices|four shell notices|cwd|__PICD|supersedes" \
  doc/pi-bridge-shell.txt
```

### Level 4: Verify the three "already-consistent" files are untouched & still correct

```bash
# Confirm you did NOT accidentally edit README.md / extension/README.md / doc/pi-bridge.txt
git diff --stat README.md extension/README.md doc/pi-bridge.txt
# Expected: empty (no changes) — UNLESS you found a genuine new contradiction in Task 0.
# If non-empty, the diff must be a minimal, justified fix — re-run doc_shell_smoke after it.

# Confirm Issue 3 is NOT documented as fixed anywhere (it isn't fixed in code):
grep -rniE "supersession race|deleting the.*!|cancelled there|cross-context supersession" \
  doc/ README.md extension/README.md
# Expected: only the GAP-5 caveat you added (softened, not "fixed").
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: `tests/doc_shell_smoke.lua` passes; `doc/tags` regenerated.
- [ ] Level 2: `tests/health_spec.lua`, `tests/shell_notices_spec.lua`, `health_smoke.lua`,
      `shell_notices_smoke.lua` all pass.
- [ ] `grep -c "always consistent" doc/pi-bridge-shell.txt` → 0 (GAP-1, GAP-8).
- [ ] `grep -n "shell-consistency"` appears in BOTH `doc/pi-bridge-shell.txt` AND `health.lua`.
- [ ] `git diff --stat README.md extension/README.md doc/pi-bridge.txt` → empty (verify-only).

### Feature Validation
- [ ] All 8 gaps (GAP-1..8) fixed in `doc/pi-bridge-shell.txt` with the exact replacements.
- [ ] Task 9: `health.lua:321` ipairs list includes `"shell-consistency"` (coupled to GAP-2).
- [ ] `:checkhealth pi-bridge` can report all four notice categories.
- [ ] No doc claims `prefer:"pi"` is unconditionally consistent.
- [ ] No doc claims the Issue 3 supersession race is fixed.
- [ ] CWD tracking (incl. zsh no-op) is documented.

### Code Quality Validation
- [ ] The single `health.lua` change is a one-string addition — no new logic/helpers/branches.
- [ ] Vimdoc table alignment, modeline, first-line tag, and helptag targets preserved.
- [ ] No edits to `PRD.md`, `plan/`, `tasks.json`, `prd_snapshot.md`, `TEST_RESULTS.md`.
- [ ] No heredoc piped into `nvim` stdin (AGENTS.md HARD RULE); all `nvim` calls `timeout`-wrapped.

### Documentation & Deployment
- [ ] `doc/pi-bridge-shell.txt` reads coherently end-to-end (no internal contradictions).
- [ ] The three already-consistent files verified clean (or minimally + justifiably patched).

---

## Anti-Patterns to Avoid

- ❌ Don't rewrite `README.md` / `extension/README.md` / `doc/pi-bridge.txt` — they are ALREADY
  consistent (Task 0 is verify-only). Rewriting them introduces risk for zero benefit.
- ❌ Don't document Issue 3 (supersession race) as fixed — the code fix is ABSENT (plan status is
  stale). Soften the over-promise (GAP-5); do not remove the caveat.
- ❌ Don't edit GAP-2's doc line ("four notices") WITHOUT also doing Task 9 (the `health.lua`
  ipairs addition) — the doc would then be false (`:checkhealth` can't see `shell-consistency`).
- ❌ Don't claim zsh honors mid-session cwd re-cd — it does NOT (script-level no-op). Document
  the v1 limitation honestly (bash/fish yes, zsh no).
- ❌ Don't invent new helptags without adding the targets, or break the §5 config-table
  alignment / trailing modeline / first-line tag (doc_shell_smoke asserts all three).
- ❌ Don't pipe a heredoc into `nvim` stdin (AGENTS.md HARD RULE — hangs the session). Write to a
  file and `+"luafile <path>"`, or use a one-line `-c`.
- ❌ Don't touch `PRD.md`, `plan/`, `tasks.json`, `prd_snapshot.md`, `TEST_RESULTS.md`.
- ❌ Don't expand scope into the unfixed Issue 3 code — that belongs to P1.M2.T4.S1, not this doc task.