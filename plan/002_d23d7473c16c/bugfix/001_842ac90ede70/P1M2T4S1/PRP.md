---
name: "P1.M2.T7.S1 — Changeset doc sweep (README.md, extension/README.md, doc/pi-bridge.txt)"
description: >
  Mode-B final documentation sweep (SOW §5) over the THREE cross-cutting
  OVERVIEW docs so they accurately reflect post-fix `!`/`!!` shell-completion
  behavior. DOCUMENTATION ONLY — no code, no tests, no per-feature driver
  doc-comments (those are owned by T1–T6).

  NOTE on path: the orchestrator stored this work item at `P1M2T4S1/`, but its
  TITLE/DESCRIPTION are the documentation sweep (`P1.M2.T7.S1` in the plan
  tree). Implement the doc-sweep content below.
---

## Goal

**Feature Goal**: After the 6 bugfixes (Issues 1–6), the three cross-cutting
overview docs — `README.md` (root), `extension/README.md`, and
`doc/pi-bridge.txt` — contain **no stale claims** about the `prefer="pi"`
default-case consistency guarantee, **document `PI_NVIM_SHELL`** wherever the
shell-completion consistency topic is discussed, and keep their cross-references
to `doc/pi-bridge-shell.txt` (`pi-bridge-shell-prefer` / `pi-bridge-shell-config`)
consistent with that file's post-T3.S1 §3 content.

**Deliverable**: Edited versions of exactly three files — `README.md`,
`extension/README.md`, `doc/pi-bridge.txt` — plus regenerated `doc/tags`. No
other files change. No code.

**Success Definition**:
- `grep` for the stale phrases (`always agree`, `completions and execution`,
  `completion uses pi's execution shell — bash`, `completions match what`)
  returns ZERO unqualified matches in the three files (every surviving match is
  qualified + cross-referenced).
- `PI_NVIM_SHELL` is mentioned in `README.md` (currently 0 hits) and remains
  documented in `extension/README.md`; the new `doc/pi-bridge-shell.txt §3`
  gap/notice content is cross-linked from both.
- `doc/pi-bridge.txt` cross-refs `|pi-bridge-shell-prefer|` and
  `|pi-bridge-shell-config|` remain resolvable (tags present in `doc/tags`).
- The existing Lua spec suite (incl. `tests/shell_notices_spec.lua`) still
  passes green — confirms docs weren't accidentally loaded as code.

## User Persona (if applicable)

**Target User**: End users reading the README / `:help` to install and
configure `!`/`!!` shell completion, and integrators reading
`extension/README.md` to understand the `PI_NVIM_BRIDGE` descriptor.

**Use Case**: A zsh/fish user on the DEFAULT config (`prefer="pi"`, no
`PI_NVIM_SHELL`) reads the docs to understand why a zsh alias was suggested then
failed under bash, and how to fix it.

**User Journey**: README "Shell completion" section → `:help pi-bridge-shell`
§3 → discovers `PI_NVIM_SHELL` opt-in → exports it → reopens editor →
completions and execution agree.

**Pain Points Addressed**: The current README actively MISLEADS ("completions
and execution always agree") in exactly the configuration the user is most
likely to be in (non-bash `$SHELL`, `PI_NVIM_SHELL` unset). The fix makes the
docs honest and points to the one-line workaround.

## Why

- **Issue 2** changed the headline `prefer="pi"` guarantee: in the most common
  config (non-bash `$SHELL`, `PI_NVIM_SHELL` unset) completion uses `$SHELL`
  while pi EXECUTES in bash — they do NOT agree. The README still asserts the
  old "always agree" guarantee in two prominent places and omits `PI_NVIM_SHELL`
  entirely.
- `PI_NVIM_SHELL` (the documented opt-in fix) is fully documented in
  `extension/README.md` and `doc/pi-bridge-shell.txt §3` but **absent from the
  root `README.md`**, which is the file users actually read.
- `doc/pi-bridge.txt` FAQ answers a question whose premise ("complete with
  bash") is conditional on `shellSource`; it now needs the inverse case.
- Keeps the docs a single coherent story across the three overview files +
  the already-updated per-feature `doc/pi-bridge-shell.txt`.

## What

Documentation edits to three files. Concrete edits are itemized in
**Implementation Tasks** below. Summary:

- **README.md**: qualify the two "always agree" claims (L40-44, L146-148);
  add `PI_NVIM_SHELL` to the shell-completion section; fix the backwards
  troubleshooting entry (L303-308).
- **extension/README.md**: already documents `PI_NVIM_SHELL` comprehensively —
  add an explicit cross-link to `doc/pi-bridge-shell.txt §3`
  (`pi-bridge-shell-prefer`) in the honesty-note section; verify the
  `shellSource` table values match the code.
- **doc/pi-bridge.txt**: qualify the "completions match" claim (§8, L227-230);
  extend the `!`/bash FAQ (§13, L374-380) with the inverse shellSource case +
  `PI_NVIM_SHELL`; bump the `Last change:` header.

### Success Criteria

- [ ] Zero unqualified "always agree"/"completions match"/"completion uses pi's
      execution shell — bash" claims remain in the three overview docs.
- [ ] `PI_NVIM_SHELL` appears in `README.md` (was 0).
- [ ] `extension/README.md` links `doc/pi-bridge-shell.txt §3` explicitly.
- [ ] `doc/pi-bridge.txt` FAQ covers BOTH shellSource outcomes (bash-completion
      AND zsh/fish-completion-that-fails).
- [ ] `doc/tags` regenerated; `pi-bridge-shell-prefer` + `pi-bridge-shell-config`
      still resolve.
- [ ] Existing test suite green.

## All Needed Context

### Context Completeness Check

Yes — a reader with no prior knowledge of this repo can implement this PRP:
exact files, exact stale phrases with line numbers, exact replacement intent,
and the code facts the prose must match are all inlined below.

### Documentation & References

```yaml
# MUST READ — the authoritative post-fix behavior the prose must match
- file: lua/pi-bridge/shell.lua
  why: source of truth for resolve_shell() (path,source) + the two notice gates
  sections: L160-225 (resolve_shell + mismatch_target), L388-437 (ensure() notice blocks)
  pattern: |
    - resolve_shell returns source ∈ {"pi","$SHELL","default"} (T1.S1 / Issue 5)
    - §17.4.3 mismatch notice gated on (cfg.prefer or "pi")=="pi" (T2.S1 / Issue 1)
    - §17 consistency-footgun notice: prefer=="pi" AND source=="$SHELL" AND
      basename($SHELL)∈{zsh,fish}; DISTINCT "shell-consistency" notify category,
      dedup once/session; message names PI_NVIM_SHELL (T3.S1 / Issue 2)
  gotcha: the two notices are SEPARATE — one fires when resolved==bash (mismatch),
          the other when resolved==zsh/fish via $SHELL (consistency). Docs must not conflate.

- file: doc/pi-bridge-shell.txt
  why: the per-feature doc ALREADY updated (T3.S1) — this sweep's prose must be
        consistent with it, not contradict it
  sections: §3 "THE DEFAULT-CASE CONSISTENCY GAP", "THE OPT-IN FIX: PI_NVIM_SHELL",
            "THE ONE-TIME NOTICE" (L131-160 region); §5 config (pi-bridge-shell-config, L188+)
  pattern: it already states the gap + PI_NVIM_SHELL workaround + the once/session notice.
           The overview docs just need to agree and point here.

- file: extension/pi-nvim-bridge.ts
  why: SHELL_MIRROR_ENV constant + 3-branch resolveShell() chain
  sections: L323 (SHELL_MIRROR_ENV="PI_NVIM_SHELL"), L441-452 (resolveShell 3 branches)
  pattern: PI_NVIM_SHELL set → source="pi"; else $SHELL → source="$SHELL"; else /bin/bash → "default"

- file: extension/README.md
  why: ALREADY documents PI_NVIM_SHELL comprehensively (L129-165) — use as the prose
        template for what README.md should say, and add the §3 cross-link here too.

- file: doc/tags
  why: help-tag index; cross-refs |pi-bridge-shell-prefer| / |pi-bridge-shell-config|
        must resolve here. Regenerate with :helptags after editing pi-bridge.txt.
  gotcha: only add NEW tag lines if you introduce a NEW |tag| — none are planned here.
```

### Current Codebase tree (overview docs focus)

```bash
pi-nvim-bridge/
├── README.md                 # root overview (EDIT) — L40-44, L146-148, L303-308 + add PI_NVIM_SHELL
├── extension/README.md       # extension overview (EDIT) — add §3 cross-link; verify shellSource table
├── doc/
│   ├── pi-bridge.txt         # plugin vimdoc (EDIT) — §8 L227-230, §13 FAQ L374-380; bump date
│   ├── pi-bridge-shell.txt   # per-feature shell doc (READ-ONLY — T3.S1 owns it)
│   └── tags                  # help-tag index (REGEN via :helptags)
└── lua/pi-bridge/shell.lua   # behavior source of truth (READ-ONLY)
```

### Desired Codebase tree with files to be added

No new files. Only the three existing overview docs are edited; `doc/tags` is
regenerated in place.

### Known Gotchas of our codebase & Library Quirks

```bash
# CRITICAL (AGENTS.md HARD RULE): NEVER pipe a heredoc / stdin into nvim — it
#   HANGS the session. For the :helptags regen + help-resolution check, write
#   the lua to a FILE (e.g. /tmp/helptags_check.lua) then run:
#     timeout 60 nvim --headless --clean -u NORC +"luafile /tmp/helptags_check.lua" +qa
#   or use a SINGLE-LINE -c 'lua ...' -c 'qa'. See AGENTS.md.
#
# GOTCHA: doc/pi-bridge.txt is a vim help file — keep columns ≤78, preserve the
#   `*tag*` markers and the trailing ` vim:tw=78:ts=8:noet:ft=help:norl:` modeline.
#
# GOTCHA: README.md is the file the npm tarball ships (package.json `files`
#   includes root README). extension/README.md is git-only (NOT in the tarball).
#   Keep user-facing PI_NVIM_SHELL guidance in README.md (the visible one).
#
# GOTCHA: the two notices ("shell-mismatch" vs "shell-consistency") are DISTINCT
#   notify categories. Prose must NOT say "the mismatch notice fires when..."
#   for the consistency case — they are different conditions (resolved==bash vs
#   resolved==zsh/fish-via-$SHELL). doc/pi-bridge-shell.txt §3 already gets this
#   right; mirror its wording.
```

## Implementation Blueprint

### Data models and structure

N/A — documentation only. No models, schemas, or code structures.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: README.md — qualify the "always agree" claim in "What it does" (L40-44)
  - FIND: the sentence containing "completions and execution always agree rather
          than a zsh-only alias being suggested then failing under bash"
  - EDIT: soften to acknowledge the default-case gap, e.g. "so completions and
          execution agree by default (and when the bridge can't read pi's
          execution shell, a one-time notice + the PI_NVIM_SHELL env var close
          the gap — see `:help pi-bridge-shell` §3)" — keep it to ONE sentence
          in the same paragraph; do NOT remove the zsh-alias example, just stop
          claiming "always".
  - NAMING: keep `PI_NVIM_SHELL` in UPPER_CASE + backticked; spell
            `:help pi-bridge-shell` exactly.
  - PLACEMENT: same paragraph, root README.md "What it does" section.

Task 2: README.md — qualify the "### Shell completion" intro (L146-148)
  - FIND: "so a completion and the command that runs always agree"
  - EDIT: change "always agree" → "agree whenever the bridge can read pi's
          execution shell" and append one sentence: "If your `$SHELL` is zsh
          or fish and you have NOT set pi's `shellPath`, export
          `PI_NVIM_SHELL=<that shell>` so completion and execution both use it
          (a one-time `:messages` notice warns you; see `:help pi-bridge-shell`
          §3)."
  - DEPENDENCIES: references the behavior documented in doc/pi-bridge-shell.txt §3.
  - GOTCHA: do NOT change the setup() lua snippet that follows — `prefer` still
            defaults to "pi"; the fix is about the ENV-VAR, not the option.

Task 3: README.md — add a PI_NVIM_SHELL env-var note
  - DECIDE placement: as a short "> **Note**" callout immediately under the
          "### Shell completion" heading (after the intro paragraph, before the
          lua snippet), OR as a new bullet in the existing env-var coverage.
          Prefer the callout (it sits next to the shell section users read).
  - CONTENT (≤4 lines): "Sets the shell pi executes `!`/`!!` in when the bridge
          can't read pi's `shellPath` (it can't today — no public API). With a
          non-bash `$SHELL` and `PI_NVIM_SHELL` unset, `prefer="pi"` completes
          with `$SHELL` while pi still runs bash — they may disagree. Export
          `PI_NVIM_SHELL` (or set pi's `shellPath`) to fix. See
          `:help pi-bridge-shell` (§3)."
  - NAMING: `PI_NVIM_SHELL` backticked; mirror extension/README.md's honesty note.
  - GOTCHA: it is an ENV VAR the USER sets in the shell that launches pi — NOT a
            setup() option. Do not put it in the lua config table.

Task 4: README.md — fix the backwards troubleshooting entry (L303-308)
  - FIND: the "``!`/`!!` completions are bash-quality / missing.``" bullet whose
          body says "completion uses pi's execution shell — bash".
  - EDIT: the current text is BACKWARDS for the default fallback (completion
          actually uses `$SHELL`=zsh/fish there, NOT bash). Rewrite to cover
          BOTH outcomes:
          (a) If you see zsh/fish completions that FAIL under bash → export
              `PI_NVIM_SHELL` (or set pi's `shellPath`).
          (b) If you want bash-quality forced off → `setup({shell={prefer="shell"}})`
              or disable the bash driver.
          Keep the `:checkhealth pi-bridge` + `:help pi-bridge-shell` pointers.
  - GOTCHA: preserve the existing markdown bullet structure + backtick style.

Task 5: extension/README.md — add explicit §3 cross-link in the honesty note
  - FIND: the "PI_NVIM_SHELL — matching pi's execution shell" section (L129-165).
  - EDIT: in the "Why it exists (the honesty note)" paragraph, add a sentence
          pointing to the PLUGIN-side doc of the same gap + the in-editor
          notice: "From the plugin side, the same gap + the one-time `:messages`
          warning are documented in `:help pi-bridge-shell` §3
          ([`doc/pi-bridge-shell.txt`](../doc/pi-bridge-shell.txt),
          `pi-bridge-shell-prefer`)."
  - VERIFY: the descriptor table `shellSource` row (L96) values
          `"pi" | "$SHELL" | "default"` match resolve_shell's post-T1.S1
          sources — they DO; no change. Verify the worked example (L99-118,
          `$SHELL=/bin/zsh` → `shellSource:"$SHELL"`, no `shellPath`) is still
          accurate — it is; no change.
  - NAMING: use relative path `../doc/pi-bridge-shell.txt` (extension/ is the cwd).

Task 6: doc/pi-bridge.txt — qualify §8 "completions match" (L227-230)
  - FIND: "By default the daemon completes using pi's execution shell (commonly
          /bin/bash) so completions match what `!` will actually run — see
          |pi-bridge-shell-prefer| for why + how to change it."
  - EDIT: insert a qualifier clause: "...so completions match what `!` will
          actually run (when the bridge can read pi's execution shell —
          otherwise it falls back to `$SHELL` and a one-time notice warns you;
          see |pi-bridge-shell-prefer| §3 + `PI_NVIM_SHELL`)..."
  - GOTCHA: keep ≤78 cols; preserve the trailing `|pi-bridge-shell-prefer|`
            and `|pi-bridge-shell|` tag cross-refs.

Task 7: doc/pi-bridge.txt — extend the §13 `!`/bash FAQ (L374-380)
  - FIND: the FAQ "Why does `!git ch<Tab>` complete with bash, not my zsh
          aliases?" and its answer beginning "pi runs `!`/`!!` commands in
          /bin/bash by default..."
  - EDIT: the answer's premise holds only when the resolved shell is bash. Add
          the inverse: "If instead you SEE zsh/fish completions that then fail
          under bash, the resolver fell back to `$SHELL` — export
          `PI_NVIM_SHELL` (see |pi-bridge-shell-prefer|) so completion matches
          execution."
  - GOTCHA: keep the existing |pi-bridge-shell-prefer|, |pi-bridge-shell-troubleshooting|,
            |pi-bridge-shell-health| cross-refs intact.

Task 8: doc/pi-bridge.txt — bump the "Last change:" header (L1)
  - FIND: "*pi-bridge.txt*\tFor Nvim 0.11+.\tLast change: 2025 Jul 20"
  - EDIT: update the date to today's date (format "YYYY Mon DD", e.g. "2026 Aug 01").
  - NAMING: keep the tab separators + the leading `*pi-bridge.txt*` tag.

Task 9: VERIFY only — confirm Issues 3/4/6 don't surface stale claims in the
        three overview docs
  - RUN: grep -nE 'supersess|re-open|cwd|M\.cd|re-track|quoted|literal "|flood|all commands' \
          README.md extension/README.md doc/pi-bridge.txt
  - EXPECT: either no hits, or hits that are already correct (e.g. shell.txt §4
            already documents the fish literal-`"` graceful-degrade; that file
            is OUT OF SCOPE here — do not edit it).
  - ACTION: these three driver/internal behaviors are NOT user-facing in the
            overview docs. If a hit is stale, fix it; otherwise make NO edit.
            Do NOT invent user-facing claims about supersession/cwd/quoting that
            the overview docs don't currently make.

Task 10: REGENERATE doc/tags (after Task 8 edits to pi-bridge.txt)
  - WHY: the help-tag index must match the edited help file so |pi-bridge-shell-prefer|
        etc. still resolve for users.
  - HOW (FILE-BASED — AGENTS.md HARD RULE): write the lua to /tmp/helptags_check.lua:
        local dir = vim.fs.abspath("doc")
        vim.cmd("helptags " .. dir)
        -- assert the two tags resolve
        assert(vim.fn.tagfiles() ~= nil)
        local t = vim.fn.taglist("pi-bridge-shell-prefer")
        assert(t and t[1] and t[1].filename:match("pi%-bridge%-shell"), "tag missing")
        local t2 = vim.fn.taglist("pi-bridge-shell-config")
        assert(t2 and t2[1], "config tag missing")
        print("helptags OK")
    then:  timeout 60 nvim --headless --clean -u NORC +"set rtp+=." +"luafile /tmp/helptags_check.lua" +qa; echo "exit=$?"
  - GOTCHA: do NOT hand-edit doc/tags; let :helptags regenerate it. If you added
            NO new |tag| markers, only the byte offsets change — that's expected.
```

### Implementation Patterns & Key Details

```markdown
# Pattern for the "always agree" qualifications (Tasks 1, 2, 6):
#   OLD: "...always agree..."  (absolute claim — now FALSE in the default case)
#   NEW: "...agree when the bridge can read pi's execution shell; otherwise a
#        one-time :messages notice + PI_NVIM_SHELL close the gap
#        (see :help pi-bridge-shell §3)."  (qualified + actionable)

# Pattern for the troubleshooting rewrite (Task 4): cover BOTH shellSource outcomes
#   outcome A (shellSource=="default"/"pi" → bash): native-shell guidance
#   outcome B (shellSource=="$SHELL" → zsh/fish that fails under bash): PI_NVIM_SHELL

# DO NOT:
#   - change the setup() defaults (prefer still = "pi")
#   - touch doc/pi-bridge-shell.txt (T3.S1 owns it — READ-ONLY here)
#   - edit driver .lua files or their doc-comments (T5/T6 own those)
#   - add new help |tags| (none needed)
```

### Integration Points

```yaml
NO CODE INTEGRATION POINTS — documentation only.

DOC INDEX (doc/tags):
  - regenerate: :helptags doc   (Task 10)
  - no new tags added; pi-bridge-shell-prefer / pi-bridge-shell-config must remain present

README ENV-VAR COVERAGE (README.md):
  - PI_NVIM_BRIDGE  (existing)  — keep
  - PI_NVIM_APPNAME (existing)  — keep
  - PI_NVIM_SHELL   (NEW here)  — add per Task 3
```

## Validation Loop

> This is a docs-only task. The template's ruff/mypy/pytest gates are N/A
> (no Python). Substitute the docs-appropriate gates below.

### Level 1: Prose & Residual-Stale-Claim Check (run after every edit)

```bash
# Must return ZERO hits (every surviving match must be a QUALIFIED version):
grep -nE 'always agree|completions and execution|completion and the command that runs always|completions match what|completion uses pi.s execution shell . bash' \
  README.md extension/README.md doc/pi-bridge.txt
echo "exit=$? (1 = no hits = PASS)"

# PI_NVIM_SHELL now present in README.md (was 0):
grep -c "PI_NVIM_SHELL" README.md   # expect >= 1
```

### Level 2: Cross-reference & Tag Consistency

```bash
# The two shell tags must exist in doc/tags:
grep -E 'pi-bridge-shell-prefer|pi-bridge-shell-config' doc/tags   # expect 2 lines

# extension/README.md now links shell.txt §3 explicitly:
grep -n 'pi-bridge-shell' extension/README.md   # must include a §3 / pi-bridge-shell-prefer link

# doc/pi-bridge.txt still cross-refs the shell tags:
grep -nE 'pi-bridge-shell-prefer|pi-bridge-shell-config|pi-bridge-shell-troubleshooting' doc/pi-bridge.txt

# Vimdoc hygiene: no line in pi-bridge.txt exceeds 78 cols (excluding URLs/code):
awk 'length($0) > 78 && $0 !~ /^<|https?:|^    / {print FILENAME":"NR": "$0}' doc/pi-bridge.txt
```

### Level 3: Help-tag Regeneration + Resolution (FILE-BASED — see AGENTS.md)

```bash
# CRITICAL: write the lua to a FILE, never pipe a heredoc into nvim stdin.
cat > /tmp/helptags_check.lua <<'LUA'
local dir = vim.fs.abspath("doc")
vim.cmd("helptags " .. dir)
local t  = vim.fn.taglist("pi-bridge-shell-prefer")
local t2 = vim.fn.taglist("pi-bridge-shell-config")
assert(t  and t[1]  and t[1].filename:match("pi%-bridge%-shell"), "prefer tag missing")
assert(t2 and t2[1] and t2[1].filename:match("pi%-bridge%-shell"), "config tag missing")
print("helptags OK")
LUA
timeout 60 nvim --headless --clean -u NORC +"set rtp+=." +"luafile /tmp/helptags_check.lua" +qa
echo "exit=$? (0 = PASS)"
```

### Level 4: No-Regression (existing test suite — docs must not break code loading)

```bash
# Run the existing Lua spec suite (confirm docs weren't loaded as code).
# T3.S1 updated tests/shell_notices_spec.lua — it must still pass.
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_notices_spec.lua")'
echo "exit=$? (0 = PASS)"

# Optional full suite sweep (smoke files are plenary-free):
for f in tests/*_smoke.lua; do
  timeout 60 nvim --headless --clean -u NORC +"luafile $f" +qa \
    && echo "ok: $f" || echo "FAIL: $f"
done
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `grep` for stale claims returns 0 unqualified hits in all 3 files.
- [ ] Level 1: `grep -c PI_NVIM_SHELL README.md` ≥ 1.
- [ ] Level 2: `pi-bridge-shell-prefer` + `pi-bridge-shell-config` present in `doc/tags`.
- [ ] Level 2: `extension/README.md` links `doc/pi-bridge-shell.txt §3`.
- [ ] Level 2: no pi-bridge.txt line >78 cols (excluding code/URLs).
- [ ] Level 3: `:helptags doc` regenerates + both shell tags resolve (FILE-BASED).
- [ ] Level 4: `tests/shell_notices_spec.lua` passes; smoke files green.

### Feature Validation

- [ ] README.md no longer claims "completions and execution always agree" absolutely.
- [ ] README.md documents `PI_NVIM_SHELL` (env var, not setup() option).
- [ ] README.md troubleshooting covers BOTH shellSource outcomes.
- [ ] extension/README.md cross-links shell.txt §3; shellSource table matches code.
- [ ] doc/pi-bridge.txt §8 + §13 FAQ qualified for the default-case gap.
- [ ] doc/pi-bridge.txt `Last change:` date bumped.

### Scope Discipline

- [ ] Only README.md, extension/README.md, doc/pi-bridge.txt (+ regenerated
      doc/tags) were modified.
- [ ] doc/pi-bridge-shell.txt NOT touched (T3.S1 owns it).
- [ ] No driver .lua files or code comments touched.
- [ ] No PRD.md / tasks.json / prd_snapshot.md touched.

### Documentation & Deployment

- [ ] Cross-references are consistent across all three overview docs + shell.txt.
- [ ] No new help |tags| introduced (none needed).
- [ ] Env-var naming (`PI_NVIM_SHELL`) is identical everywhere (UPPER_CASE, backticked).

---

## Anti-Patterns to Avoid

- ❌ Don't rewrite the shell.txt §3 gap/notice prose here — it's owned by T3.S1
      and already correct; just point to it.
- ❌ Don't "fix" the backwards troubleshooting entry by deleting it — rewrite it
      to cover both shellSource outcomes.
- ❌ Don't put `PI_NVIM_SHELL` in the `setup()` lua table — it's an env var the
      user exports in the shell that launches pi.
- ❌ Don't hand-edit `doc/tags` — regenerate with `:helptags`.
- ❌ Don't pipe a heredoc into nvim stdin (AGENTS.md HARD RULE) — write the
      helptags check to `/tmp/*.lua` and run `:luafile`.
- ❌ Don't conflate the two notices ("shell-mismatch" fires at resolved==bash;
      "shell-consistency" fires at resolved==zsh/fish-via-$SHELL). Different
      conditions, different categories — keep the prose precise.

---

## Confidence Score

**8/10** — one-pass success likelihood.

Rationale: the task is pure prose editing against a precisely-identified set of
stale phrases with exact line numbers and verified code facts. The only
residual risk is the implementing agent over-editing (touching shell.txt or
driver files, which are explicitly out of scope) or hand-editing doc/tags — both
called out above. The dependency on T4–T6 being complete is LOW: those fixes are
driver/internal and the overview docs do not currently make user-facing claims
about supersession/cwd/quoting-flood, so Task 9's verify step handles it (likely
no edits needed even if T4–T6 land after this sweep).