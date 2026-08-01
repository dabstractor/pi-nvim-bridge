# Doc-Gap List — shell-completion changeset (1a0a071..d8d4adf)

Audit of user-facing docs vs. the 5 fixes that LANDED (Issues 1, 2, 4, 5, 6).
Issue 3 (cross-context supersession race — deleting the leading `!` mid-flight
re-opens the shell menu via the `ctx==nil` branch that doesn't bump `gen`) was
**NOT** fixed; one gap below (pi-bridge-shell.txt:366) is flagged for implying
it was.

Scope audited in full: `README.md`, `extension/README.md`, `doc/pi-bridge.txt`,
`doc/pi-bridge-shell.txt`. No files were modified (review only).

Severity legend: **MEDIUM** = factually wrong / false guarantee / missing
feature doc; **LOW** = inconsistent framing or minor over-promise.

---

## 0. What the changeset ALREADY updated (done — no action needed)

`git diff 1a0a071~1 HEAD -- README.md doc/pi-bridge.txt doc/pi-bridge-shell.txt extension/README.md`:

- **README.md** (DONE): intro `prefer="pi"` para (L40-48) — now hedges
  "agree when the bridge can read pi's execution shell"; "Shell completion"
  section (L150-170) — `PI_NVIM_SHELL` Note + §3 cross-ref; troubleshooting
  "`!`/`!!` completions are bash-quality / missing" (L318-332) — split into
  the "$SHELL fallback FAILs under bash" vs "force bash off" bullets.
- **doc/pi-bridge.txt** (DONE): header date bump; §8 SHELL COMPLETION
  (L225-233) — "when the bridge can read it; otherwise it falls back to
  `$SHELL` and a one-time notice warns you (§3 + `PI_NVIM_SHELL`)"; §13 FAQ
  "Why does `!git ch<Tab>` complete with bash…" (L378-390) — added the
  "you SEE zsh/fish completions that then fail under bash → export
  `PI_NVIM_SHELL`" inverse case.
- **doc/pi-bridge-shell.txt** (PARTIAL — gaps below): added the §3 block
  "THE DEFAULT-CASE CONSISTENCY GAP" + "THE OPT-IN FIX: `PI_NVIM_SHELL`" +
  "NOTE (forward contract)" (L89-116). §4/§5/§7/§9/§10 were **NOT** touched.
- **extension/README.md** (DONE): `PI_NVIM_SHELL` section now cross-refs the
  plugin-side §3 treatment + the one-time `:messages` warning (L148-157).

The 5 fixes are correctly described in the places the diff touched. Gaps below
are the places the diff did **not** reach.

---

## 1. `doc/pi-bridge-shell.txt`

### GAP-1 — L226-230 (§5 config table) — **MEDIUM** — false "always consistent" guarantee

**Current text:**
```
    shell.prefer             "pi"        Resolution contract (see
                                         |pi-bridge-shell-prefer|). "pi" |
                                         "shell" | "bash" | "/abs/path".
                                         Default "pi" = pi's resolved
                                         execution shell (always consistent
                                         with what will actually run).
```
**Why stale:** Issue 2's own §3 subsection (L89-101, added by this changeset)
explicitly states `prefer="pi"` is **NOT** always consistent — under non-bash
`$SHELL` with `PI_NVIM_SHELL` unset, completion uses `$SHELL` (zsh/fish) while
pi EXECUTES in bash, and a one-time `shell-consistency` notice warns about it.
This config-table cell is a standalone, unrebutted false guarantee (the closest
§3 refutation is ~140 lines away and a casual reader of the options table will
not see it).
**Suggested fix** (replace the last two lines):
```
                                         Default "pi" = pi's resolved
                                         execution shell (intended to match
                                         what `!` will run; see §3 for the
                                         one non-bash-`$SHELL` gap +
                                         `PI_NVIM_SHELL`).
```

### GAP-2 — L314-315 (§7 Health) — **MEDIUM** — "three shell notices" is now four

**Current text:**
```
  • whether any of the three shell notices (shell-mismatch / shell-degrade /
    shell-active) fired earlier this session — run `:messages` to read them.
```
**Why stale:** Issue 2 added a **fourth** notice category, `shell-consistency`
(`shell.lua` ensure(), distinct dedup key from `shell-mismatch`). The doc lists
only three. ⚠️ **Code dependency:** `lua/pi-bridge/health.lua:321` iterates
`{ "shell-degrade", "shell-mismatch", "shell-active" }` and omits
`shell-consistency`, so `:checkhealth` currently cannot report that the new
notice fired at all. Fixing the doc alone leaves the tool blind to the notice;
the implementer should add `"shell-consistency"` to the `ipairs` list in
`health.lua` **and** update this doc line together.
**Suggested fix:**
```
  • whether any of the four shell notices (shell-mismatch / shell-consistency /
    shell-degrade / shell-active) fired earlier this session — run `:messages`
    to read them.
```

### GAP-3 — L155-159 (§4 TIER 1 fish) vs. bash/zsh driver notes — **MEDIUM** — graceful-degrade guard documented for fish only

**Current text (fish Notes):**
```
  Notes:    the daemon is `fish -i`; it loads your fish config. A known edge
            case is that a command line containing a literal `"` can return an
            empty candidate set (graceful — the menu just stays closed).
```
**Why stale:** Issue 6 added a **graceful-degrade guard to ALL THREE drivers**
(bash L71-78, zsh L67-74, fish L49-54): a command line containing a literal `"`
OR an empty command returns an **empty** candidate set (preventing the
all-commands flood). The doc attributes this to fish only, and frames it as a
fish "known edge case" rather than an intentional cross-driver guard. The
**TIER 1 zsh** Notes (L174-179) and **TIER 2 bash** Notes (L184-186) say
nothing about it, so a bash/zsh user who types `"` and sees no menu has no
explanation.
**Suggested fix:**
- Fish Notes — reword to "(all drivers guard this — see below)" and keep the
  example.
- Add one shared sentence to the **bash** and **zsh** Notes blocks, e.g.:
  ```
  A literal `"` on the line, or an empty command (bare `!`), returns an empty
  candidate set on purpose (graceful degrade — prevents a full command listing
  flood; the menu just stays closed).
  ```
  (or factor this into a single note after the three driver tiers.)

### GAP-4 — MISSING (entire file) — **MEDIUM** — Issue 4 cwd tracking is undocumented (incl. the zsh no-op limitation)

**Current text:** none. `grep -niE "cwd|__PICD|re-?cd|mid-session|directory drift"
doc/pi-bridge-shell.txt` returns **zero** hits outside the `!cd /etc/<Tab>`
re-trigger example (L283) and the unrelated "DAEMON CRASH MID-SESSION"
heading (L374).
**Why stale:** Issue 4 / commit c524d87 wired `complete_current` to re-`cd` the
daemon mid-session when pi's cwd changed since spawn (`shell.lua` step 6.5,
calls `state.driver.cd` → writes a `__PICD__\t<path>\n` frame; bash L502 +
fish L482 do a real `builtin cd`; **zsh L523 writes the frame but the outer
`zsh -f` discards it — a documented v1 no-op**). None of this is in the doc:
a user whose pi cwd drifts (e.g. `cd`s in another pane) gets no explanation
that relative-path completions track pi's cwd on bash/fish, and a zsh user
gets no warning that their daemon's cwd is frozen at spawn.
**Suggested fix:** add a short subsection (e.g. in §2 after "VISUAL CUE", or a
"CWD TRACKING" note at the end of §4), roughly:
```
CWD TRACKING ~
The daemon starts in pi's session cwd (the descriptor `cwd` /
`server_info.cwd`) and re-`cd`s mid-session if pi's cwd changed since spawn,
so relative-path completions track pi's working directory. bash and fish
honor the re-`cd`; zsh is a known v1 limitation — its `zpty` capture outer
discards the `cd` frame, so a zsh daemon's cwd stays fixed at spawn
(reopen the editor after a `cd` to refresh it).
```

### GAP-5 — L366 (§9 PER-REQUEST TIMEOUT) — **LOW/MEDIUM** — supersession over-promise (Issue 3 NOT fixed)

**Current text:**
```
The daemon itself is NOT killed — the next request proceeds normally. (Only ONE
request is in flight at a time; a newer keystroke supersedes a pending one.)
```
**Why stale:** Issue 3 (the cross-context supersession race — deleting the
leading `!` while a shell request is in flight lets the stale response re-open
the shell menu) was **NOT** fixed in this changeset. The parenthetical "a newer
keystroke supersedes a pending one" is true **within** the shell path
(`shell.lua`'s `gen`-guard), but it reads as a general guarantee and a user
would reasonably expect that deleting the `!` (plainly a "newer keystroke")
cancels the pending shell completion — which it does not (the `ctx==nil` branch
in `completion.lua` `do_refresh` does not bump `gen` / cancel inflight).
**Suggested fix:** add a caveat now (or remove the over-promise until Issue 3
lands), e.g.:
```
(Only ONE shell request is in flight at a time; a newer `!`-line keystroke
supersedes a pending one. Note: deleting the leading `!` mid-flight is a known
gap — the in-flight shell result is not yet cancelled there.)
```

### GAP-6 — L139-146 (§3 "THE ONE-TIME NOTICE") — **LOW** — documents only shell-mismatch

**Current text:**
```
THE ONE-TIME NOTICE ~
The very first time the daemon is spawned and `prefer` (the default `"pi"`)
resolves to bash while `$SHELL` is zsh or fish AND that shell is on your
`$PATH`, the plugin emits ONE `vim.notify` (deduplicated to once per session)
explaining the mismatch and pointing here. It is not an error — it is a hint.
See |pi-bridge-shell-troubleshooting| for the full FAQ.
```
**Why improvable:** This subsection describes only the `shell-mismatch` notice.
The new `shell-consistency` notice (Issue 2) is mentioned **only** inside the
"DEFAULT-CASE CONSISTENCY GAP" paragraph (L100-101: "emits ONE `vim.notify`
… pointing here") and is not consolidated here, so the dedicated "notices"
treatment is incomplete. (The mismatch gate itself — Issue 1 — is described
correctly: "`prefer` (the default `"pi"`)" implies it only fires under
`prefer=="pi"`; no doc claims it fires regardless of `prefer`. ✓ clean on that
specific point.)
**Suggested fix:** rename to "THE SHELL-MISMATCH NOTICE ~" and add one line:
```
A second, distinct notice (`shell-consistency`) covers the non-bash-`$SHELL`
fallback case — see "THE DEFAULT-CASE CONSISTENCY GAP" above + §7.
```

### GAP-7 — L395-404 (§10 FAQ) — **LOW** — missing the Issue-2 inverse case

**Current text (Q "I'm a zsh/fish user but I got bash-quality completions"):**
```
A: The shell mismatch (see |pi-bridge-shell-prefer|). With the default
   `prefer = "pi"`, the plugin completes using pi's execution shell — which is
   bash unless you told pi otherwise. Two fixes:
     1. (Recommended) Set pi's `shellPath` …
     2. Or `setup({ shell = { prefer = "shell" } })` …
```
**Why improvable:** This Q handles only the resolved==bash case. README
troubleshooting (L318-332) and `pi-bridge.txt` §13 FAQ (L378-390) were BOTH
updated to cover the inverse — "I SEE zsh/fish completions that then FAIL under
bash" (the Issue 2 `$SHELL`-fallback footgun). This file's FAQ was not, so the
three docs are inconsistent. 
**Suggested fix:** add a paired Q, e.g.:
```
Q: "I SEE zsh/fish completions on `!` lines, but the command then FAILS under
   bash (e.g. a zsh-only alias)."
A: The resolver fell back to `$SHELL` (the bridge could not read pi's execution
   shell — §3 "DEFAULT-CASE CONSISTENCY GAP"). Export `PI_NVIM_SHELL=<that
   shell>` (or set pi's `shellPath`) so completion matches execution.
```

### GAP-8 — L86 (§3 "THE MISMATCH") — **LOW** — unconditional "always consistent" assertion

**Current text:**
```
… by default this plugin completes using pi's execution shell — bash — which is
always consistent with execution, but offers fewer completions than a native
zsh/fish setup.
```
**Why improvable:** The very next subsection (L89-101) walks this back ("That
holds ONLY when the bridge can read pi's execution shell"), so the net message
is correct — but THE MISMATCH paragraph itself still asserts "always
consistent" unconditionally. Low risk (hedged ~5 lines later) but the
assertion reads as authoritative before the reader reaches the refutation.
**Suggested fix:** soften in place — "which is *intended to be* consistent with
execution (see the gap below) …".

---

## 2. `doc/pi-bridge.txt`

**No stale gaps found.** The changeset correctly updated:
- §8 SHELL COMPLETION (L225-233) — accurate `$SHELL`-fallback + notice + §3
  + `PI_NVIM_SHELL` cross-ref. ✓
- §13 FAQ "Why does `!git ch<Tab>` complete with bash…" (L378-390) — now
  covers both the resolved==bash answer AND the inverse "`$SHELL` fallback →
  export `PI_NVIM_SHELL`" case. ✓
- §7 Health (pi-bridge-shell-health) cross-ref is unchanged and still accurate.
- No claim anywhere that the mismatch notice fires regardless of `prefer`, and
  no standalone "always consistent" claim. ✓

No action required in this file.

---

## 3. `README.md`

**No stale gaps found.** The changeset correctly updated:
- Intro `prefer="pi"` para (L40-48) — hedges "agree when the bridge can read
  pi's execution shell" + the `PI_NVIM_SHELL` close-the-gap sentence. ✓
- "Shell completion" section (L150-170) — `PI_NVIM_SHELL` Note + §3 cross-ref +
  "(a one-time `:messages` notice warns you)". ✓
- Troubleshooting "`!`/`!!` completions are bash-quality / missing"
  (L318-332) — split into the `$SHELL`-fallback-fails-under-bash bullet and the
  force-bash-off bullet. ✓

No claim that `prefer="pi"` is always consistent, and no claim the mismatch
notice fires regardless of `prefer`. ✓ No action required.

---

## 4. `extension/README.md`

**No stale gaps found.** Verified against `extension/pi-nvim-bridge.ts`:
- `shellSource` values `"pi" | "$SHELL" | "default"` (doc table) == code
  `ShellInfo.shellSource` union (L406) and `resolveShell()` branches (L453-456:
  `PI_NVIM_SHELL`→`"pi"`, `$SHELL`→`"$SHELL"`, else→`"default"`). ✓
- "`shellPath` present **only** when `shellSource === "pi"`" (doc) == code
  (only branch (a) sets `shellPath`). ✓
- Typical-machine example (`shellSource: "$SHELL"`, no `shellPath`) matches
  code. ✓
- `PI_NVIM_SHELL` is read BEFORE `$SHELL` by `resolveShell()` (doc) == code
  order. ✓
- The §3 plugin-side consistency-notice cross-ref was added (L148-157). ✓

No action required.

---

## Summary table

| # | File | Lines | Severity | Category |
|---|------|-------|----------|----------|
| GAP-1 | pi-bridge-shell.txt | 226-230 | MEDIUM | false "always consistent" guarantee (contradicts new §3) |
| GAP-2 | pi-bridge-shell.txt | 314-315 (+health.lua:321) | MEDIUM | "three notices" → four; `:checkhealth` blind to `shell-consistency` |
| GAP-3 | pi-bridge-shell.txt | 155-159 (+bash/zsh §4) | MEDIUM | graceful-degrade guard documented fish-only |
| GAP-4 | pi-bridge-shell.txt | (missing) | MEDIUM | Issue 4 cwd tracking + zsh no-op undocumented |
| GAP-5 | pi-bridge-shell.txt | 366 | LOW/MEDIUM | supersession over-promise (Issue 3 NOT fixed) |
| GAP-6 | pi-bridge-shell.txt | 139-146 | LOW | ONE-TIME NOTICE covers only shell-mismatch |
| GAP-7 | pi-bridge-shell.txt | 395-404 | LOW | §10 FAQ missing Issue-2 inverse case |
| GAP-8 | pi-bridge-shell.txt | 86 | LOW | unconditional "always consistent" (hedged later) |

All 8 gaps are in **`doc/pi-bridge-shell.txt`**. `README.md`, `doc/pi-bridge.txt`,
and `extension/README.md` are consistent with the changeset.

**Highest-leverage fixes** (do these first): GAP-1, GAP-2 (+ code), GAP-3,
GAP-4.