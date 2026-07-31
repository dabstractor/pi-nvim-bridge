# PRP — P2.M1.T2.S1: Fish spike — standalone validation of framed round-trip

> **Plan mapping:** task `P2.M1.T2.S1` ("Fish spike — standalone validation of framed round-trip"). First subtask of
> **P2.M1.T2** ("shell.lua daemon manager + fish spike") within the **Shell Completion for !/!! Bash Mode** epic
> (PRD §17). This is the **✔ gate (PRD §17.16 step 21)** that retires PRD §17.6.1's "fiddly / unproven" fish risk
> BEFORE the rest of `shell.lua` (S2–S6) + the fish driver (P2.M2.T4) are built.
>
> **THE SEAM IS ALREADY PROVEN LIVE** in this PRP's research session: a direct experiment spawned `fish -i` over
> piped stdio via `vim.uv.spawn`, sent one `__PIREQ__` frame, parsed `word⇥desc` between sentinels, and got
> `checkout`/`cherry`/`cherry-pick` (exit 0). The PRP ships the cleaned-up, convention-matching version of that
> passing script as the reference implementation. See `research/notes.md` §2 for the verbatim transcripts.

---

## Goal

**Feature Goal**: Prove, with a standalone (plenary-FREE) Lua script, that the framed fish completion round-trip
works end-to-end: spawn an **interactive** `fish` over piped stdio via `vim.uv.spawn`, send one framed
`__PIREQ__` request, buffer the response, slice it out between `__PIRESP_START__`/`__PIRESP_END__` sentinels,
parse `word<TAB>description` lines, and echo them via `nvim_echo`. **Gate**: `checkout` + `cherry` (bonus:
`cherry-pick`) must appear in the parsed results. P2.M1.T2 proceeds only if the gate passes.

**Deliverable** (ONE new file — nothing else is touched):
- **`tests/shell_fish_spike.lua`** — a self-contained smoke-style script (mirrors `tests/bridge_smoke.lua`'s
  `check`/`fails`/`SMOKE`-style footer + `+"luafile" +qa` run shape). It writes the fish startup script to a
  temp file, spawns `fish -i --init-command="source <tmp>"` with 3 piped streams, drives one request, parses the
  sentinel-framed response, echoes items via `vim.api.nvim_echo`, and prints a parseable `SPIKE_PASS`/
  `SPIKE_SKIP` verdict to stdout.

**Success Definition**:
- Running `timeout 30 nvim --headless --clean -u NORC +"luafile tests/shell_fish_spike.lua" +qa` prints
  `SPIKE_PASS: fish framed round-trip proven (checkout+cherry present)` and exits **0** on a machine with
  `fish` on `$PATH` (this dev box: `/usr/bin/fish`, fish 4.8.1 — verified present).
- On a fish-less box it prints `SPIKE_SKIP: fish not on PATH` and exits **0** (PRD §17.15: never fail CI for a
  missing optional shell — the gate is deferred, not failed).
- The parsed items include `checkout`, `cherry`, and (bonus) `cherry-pick`, each with its `complete -C`
  description (e.g. `checkout => Checkout and switch to a branch`).
- Every `vim.uv` call is wrapped in `pcall`; the script has a bounded `vim.wait` timeout; all spawned handles
  (proc + 3 pipes) are killed/closed before exit (no leak).
- **No** file under `lua/`, `extension/`, `doc/`, `ftplugin/`, `plugin/`, or `README.md` is modified. **No**
  `shell.lua` is created (that is S2). This is a one-file spike.

## User Persona (if applicable)

**Target User**: the **implementer of P2.M1.T2.S2–S6** (`shell.lua` daemon manager) and **P2.M2.T4.S1–S2**
(`shell/fish.lua` driver). They need empirical proof that the transport primitives work before committing to the
full module — PRD §17.6.1 says the interactive-fish plumbing is "fiddly" and "unproven until the spike."

**Use Case**: run the spike once (gate ✔) before writing `shell.lua`; keep it as a re-runnable regression smoke
that exercises the real `fish` binary so a future regression in the framed protocol is caught independently of the
plugin's higher layers.

**Pain Points Addressed**: retires the single highest-risk unknown of the entire Phase-6 (shell completion) epic in
~30 lines, instead of discovering the plumbing is broken deep inside `shell.lua`.

## Why

- **It is the explicit §17.16 step-21 gate.** PRD §17.16 orders Phase 6: *(21) Spike → ✔ Gate → proceed*; only
  then *(22) `shell.lua`*, *(23) fish driver*. Building the daemon before proving the seam would be building on
  sand — the spike de-risks the exact thing PRD §17.6.1 flagged "unproven."
- **Mirrors a proven repo convention at throwaway cost.** `tests/bridge_smoke.lua` already proves the
  "standalone Lua spawns a real subprocess over luv pipes, asserts on the round-trip, prints `SMOKE_PASS`, exits 0"
  shape. This spike is the same shape pointed at `fish` instead of a JSONL socket server. One new file, zero new
  patterns, zero integration surface.
- **Decouples from the parallel descriptor work.** The spike uses the literal `/usr/bin/fish` path the contract
  pins (the item description: "fish is at /usr/bin/fish (verified)"). It does **NOT** depend on the in-flight
  `bridge.get_shell_info()` accessor (P2.M1.T1.S4) — that's `shell.lua`'s job (S2), not the spike's.
- **Cheap insurance.** ~30 lines, one `timeout 30 nvim …` invocation, no CI cost (skips when fish is absent).
  The alternative (skip the spike, find the plumbing broken inside a 200-line `shell.lua`) costs far more.

## What

**User-visible behavior**: none at runtime in the plugin (no `shell.lua` exists yet; the spike is run manually as
a gate + kept as a regression smoke). The observable artifact is the script's stdout when run:

```
$ timeout 30 nvim --headless --clean -u NORC +"luafile tests/shell_fish_spike.lua" +qa
SPIKE_PASS: fish framed round-trip proven (checkout+cherry present)
$ echo "exit=$?"
exit=0
```
(The items are also echoed to `:messages` via `vim.api.nvim_echo`, satisfying the contract; in headless mode that
records to the message history rather than displaying.)

**Technical requirements** (all in `tests/shell_fish_spike.lua`):
- Spawn `fish` with args `{ "-i", "--init-command=" .. "source " .. <tmp_path> }` and `stdio = {stdin, stdout,
  stderr}` (three `uv.new_pipe(false)`). `-i` loads the user's config + completions; `--init-command` runs AFTER
  config.fish so the `__pi_handle` function is defined before the loop reads stdin. (Verified — research §2a.)
- The fish startup script (written to `os.tmpname()`) defines `__pi_handle`: it `read -l line`, strips the
  `__PIREQ__\t` prefix, extracts the JSON `line` field via `string match -r '"line":"([^"]*)"'` (jq-free — fish has
  no builtin JSON parser and jq is not guaranteed on PATH), echoes `__PIRESP_START__`, runs `complete -C "$cmd"`
  piped through a `while read word desc` loop that prints `word\tdesc` (or bare `word` when no desc), then echoes
  `__PIRESP_END__`. It also defines `function fish_prompt; end` to reduce prompt noise (sentinels isolate the
  remainder). Then it calls `__pi_handle` once (one round-trip = the spike scope).
- Lua side: `stdout:read_start` appends each chunk to `rx_buf` and, on each chunk, scans for a
  `__PIRESP_START__\n` … `__PIRESP_END__` pair; when found, slices the body and parses each non-empty line as
  `word` + optional `\tdesc` into an `items` table, sets `done = true`. `data == nil` (EOF) also finalizes.
- Sends the framed request: `stdin:write('__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n')` (PRD §17.5.1
  exact wire shape).
- Drives the event loop with `vim.wait(<ms>, function() return done end, <interval>)` (bounded — safety net).
- Gate checks (`check(fails)`): at least one item parsed; `checkout` present; `cherry` present.
- Echoes parsed items via `vim.api.nvim_echo` (the `:messages` requirement).
- Teardown: `pcall` `uv.process_kill(handle, "sigkill")` + `:close()` on each of the 3 pipes; `os.remove(tmp)`.
- Footer: on any `check` failure → stderr + `vim.cmd("cquit 1")`; else stdout `SPIKE_PASS: …`.
- Skip path: `vim.fn.executable("fish") == 0` → print `SPIKE_SKIP: fish not on PATH — gate deferred`, `return`
  (the `+qa` exits 0).

### Success Criteria

- [ ] `tests/shell_fish_spike.lua` exists and is the ONLY new/modified file.
- [ ] `timeout 30 nvim --headless --clean -u NORC +"luafile tests/shell_fish_spike.lua" +qa` prints
      `SPIKE_PASS: …` and `exit=0` on this machine (fish present).
- [ ] Parsed results include `checkout`, `cherry`, and `cherry-pick` (the known `complete -C "git ch"` output).
- [ ] Every `vim.uv` call is `pcall`'d; a bounded `vim.wait` is present; all handles are killed/closed before exit.
- [ ] `vim.fn.executable("fish")==0` path prints `SPIKE_SKIP` and exits 0 (does not fail on a fish-less box).
- [ ] NO file under `lua/`, `extension/`, `doc/`, `ftplugin/`, `plugin/`, or `README.md` is touched. NO `shell.lua`
      is created.

## All Needed Context

### Context Completeness Check

_Passes "No Prior Knowledge":_ an implementer who has never seen this repo gets (a) the verbatim, live-verified
reference implementation (it passed the gate in this research session — see §Reference Implementation below),
(b) the exact run command + expected stdout, (c) the fish doc URLs (HTTP 200-verified) for every builtin the
script uses, (d) the luv API signatures + gotchas, and (e) the convention file (`tests/bridge_smoke.lua`) to
mirror for the footer/skip style. The only judgment call (placement: `tests/` vs `/tmp/`) is decided in favor of
`tests/shell_fish_spike.lua` with rationale in research §4.5.

### Documentation & References

```yaml
# MUST READ — the spec (reproduced in this PRP's <selected_prd_content>)
- docfile: PRD.md
  why: "§17.6.1 (fish Tier-1) gives the daemon startup script + the 'fiddly, unproven until spike' caveat. §17.5.1 gives the EXACT framing wire shape (__PIREQ__\\t{json} / __PIRESP_START__ / __PIRESP_END__). §17.16 step 21 makes this spike the explicit gate."
  section: "h4.5 (§17.6.1 fish), h4.3 (§17.5.1 framing), h3.45 (§17.16 step 21), h3.34 (§17.5.2 shell.lua skeleton — the future consumer)"
  critical: "The wire payload is EXACTLY `__PIREQ__\\t{\"line\":\"git ch\",\"cursor\":6,\"after\":\"\"}\\n` (tab between sentinel and JSON; cursor is a BYTE offset). Response lines are `word\\tdesc` (literal tab). The daemon MUST emit __PIRESP_END__ even on empty/error (robustness) — the spike's fish script always emits both sentinels."

# MUST READ — fish `complete` builtin (the completion-query API the whole feature rests on)
- url: https://fishshell.com/docs/current/cmds/complete.html
  why: "documents `complete -C \"<line>\"` (a.k.a. --command-line): the query form that returns `word⇥description` lines using ALL loaded completions. This is the fish feature that makes Tier-1 a 'clean win' (PRD §17.6.1)."
  critical: "Do NOT confuse `complete -C` (the completion QUERY, run inside the daemon script) with `fish -C`/`--init-command` (the STARTUP flag). They share a letter; contexts differ. In spawn args use the long form `--init-command=` to avoid ambiguity."

# MUST READ — fish invocation flags (-i + --init-command)
- url: https://fishshell.com/docs/current/cmds/fish.html
  why: "`-i` (interactive) loads the user's config.fish + completion library; `--init-command=CODE` is evaluated AFTER config.fish (so the daemon's `__pi_handle` is defined before the interactive loop reads stdin). The spike uses BOTH."
  critical: "`--noconfig` is WRONG (PRD §17.6.1) — we WANT the user's config so their aliases/completions load. `-c`/single-command exits after one command (wrong — no loop). `-i` with a non-TTY (piped) stdin works and does NOT fatally error (verified research §2a); it emits startup OSC/SGR noise to stdout, which the sentinel framing discards."

# MUST READ — fish `read` + `string` builtins (the jq-free request parser)
- url: https://fishshell.com/docs/current/cmds/read.html
  why: "`read -l line` reads one line from stdin into a local variable — the request intake in `__pi_handle`."
- url: https://fishshell.com/docs/current/cmds/string.html
  why: "`string replace -r '^__PIREQ__\\t' '' -- \"$line\"` strips the sentinel prefix; `string match -r '\"line\":\"([^\"]*)\"' -- \"$payload\"` extracts the `.line` field (index [2] = capture group 1; fish lists are 1-based). jq-free because jq is not guaranteed on PATH."

# MUST READ — luv / vim.uv spawn + piped stdio API (the transport the spike proves)
- url: https://github.com/luvit/luv/blob/master/docs.md
  why: "the `uv.new_pipe(ipc)`, `uv.spawn(path, options, on_exit)` with the `stdio` array, `pipe:read_start(cb)`, `pipe:write(data, cb)`, `uv.process_kill(handle, signum)`, `pipe:close()` signatures. `stdio` is a 3-element array {stdin, stdout, stderr}; each element is a pipe handle (or integer fd)."
  critical: "`read_start`'s callback is `(err, data)` where `data == nil` means EOF (NOT an error) — treat `err==nil and data==nil` as 'stream closed, finalize'. EVERY uv call can throw on a bad/double-closed handle → wrap each in `pcall` (PRD §17.5.2 'never blocks, never throws'). `process_kill`'s signum accepts the string `\"sigkill\"`."

# SUPPORTING — Neovim vim.uv is builtin (available in --headless --clean -u NORC)
- url: https://neovim.io/doc/user/luvref.html
  why: "confirms `vim.uv` is the builtin luv binding — no plugin/runtimepath needed. The spike runs under `nvim --headless --clean -u NORC` and `vim.uv.spawn` is available with zero setup (verified research §2b)."

# MUST READ — the convention file to mirror (the spike's footer/skip/run shape)
- file: tests/bridge_smoke.lua
  why: "the established 'standalone Lua spawns a real subprocess over luv pipes, asserts, prints SMOKE_PASS, exits 0' pattern. Copy its `check`/`fails` footer, its `os.tmpname()`-style temp handling, and its `+\"luafile tests/<x>.lua\" +qa` run doc-comment header. The spike is the same shape pointed at `fish` instead of a luv unix-socket server."
  pattern: "header doc-comment with the exact run command; `local fails = 0; local function check(cond,msg) … end`; spawn a subprocess, drive it, assert; footer `if fails>0 then stderr; vim.cmd('cquit 1') end; io.stdout:write('SPIKE_PASS\\n')`."
  gotcha: "bridge_smoke uses `os.remove(path)` for its socket; the spike must `os.remove(<tmp fish script>)` too. Do NOT copy its jsonlreader dependency — the spike does its OWN line/sentinel parsing (it is proving the shell transport, not the bridge transport)."

# MUST READ — local research notes (verbatim transcripts of the passing experiments + locked decisions)
- docfile: plan/002_d23d7473c16c/P2M1T2S1/research/notes.md
  why: "§2 = the live-verified fish-side AND luv-side experiments (verbatim stdout showing checkout/cherry/cherry-pick, exit 0). §4 = the 8 locked design decisions with rationale. §5 = the gotchas. §6 = the scope fence. §7 = the exact gate command."
```

### Current Codebase tree (relevant slice)

```bash
tests/
├── bridge_smoke.lua        # READ-ONLY — the convention file to MIRROR (check/fails/footer/run shape)
├── *_smoke.lua             # (15 smoke files; all plenary-FREE, all `+\"luafile\" +qa`, all print SMOKE_PASS)
└── (shell_fish_spike.lua does NOT exist yet)   # ← this spike CREATES it
lua/pi-bridge/
└── (shell.lua does NOT exist yet)              # ← P2.M1.T2.S2 creates it; the spike does NOT
```

### Desired Codebase tree with files to be added

```bash
tests/shell_fish_spike.lua   # NEW — the standalone spike (the ONLY deliverable). ~30-60 lines.
# (NO other file is created or modified.)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (AGENTS.md HARD RULE): run the spike via `+"luafile tests/shell_fish_spike.lua" +qa`.
-- NEVER pipe a heredoc into nvim's stdin (`nvim ... +"luafile /dev/stdin" +qa <<EOF` HANGS the session —
-- ~10 killed sessions in this repo). The spike IS a file on disk; that is the safe path. (research §5 G7.)

-- GOTCHA #1 — `read_start`'s EOF is `data == nil`, NOT an error.
-- The cb is (err, data). err==nil + data==nil ⇒ stream closed ⇒ finalize (set done). Do NOT treat EOF as failure.

-- GOTCHA #2 — pcall EVERY uv call (PRD §17.5.2 "never blocks, never throws").
-- uv.spawn / pipe:read_start / pipe:write / uv.process_kill / pipe:close can each throw on a bad/double-closed
-- handle. Wrap each in pcall so a teardown race never crashes the spike.

-- GOTCHA #3 — fish exits on its own after one read, BUT kill+close anyway.
-- After __pi_handle reads one line + returns, fish's interactive loop re-reads stdin, hits EOF, exits. vim.wait
-- sees `done` (sentinel parsed) before that. Kill+close at the end is deterministic cleanup (handle leak guard);
-- the real shell.lua teardown() does the same (research §5 G3).

-- GOTCHA #4 — the OSC/SGR startup noise is HARMLESS (sentinels isolate it).
-- The user's config.fish emits a burst of `]4;…`/SGR color-setup sequences to stdout at startup. `function
-- fish_prompt; end` reduces (not eliminates) prompt noise; the sentinel framing discards the rest. Do NOT try to
-- suppress the config's color setup. (research §2a shows the noise in the raw output; §2b shows it's discarded.)

-- GOTCHA #5 — `string match -r` capture indexing is 1-based: [1]=whole match, [2]=group 1.
-- `(string match -r '"line":"([^"]*)"' -- "$payload")[2]` extracts the captured `line` value. Verified §2b.

-- GOTCHA #6 — the two `-C` overloads share a letter; do NOT confuse them.
-- `complete -C "<line>"` = the completion QUERY (run inside the daemon script). `fish -C "<code>"` / the long
-- form `--init-command="<code>"` = the STARTUP flag. In spawn args use the long form `--init-command=`.

-- GOTCHA #7 — jq is NOT guaranteed on PATH. fish has NO builtin JSON parser.
-- The spike parses the single `"line"` field with `string match -r` (jq-free). Do NOT add a jq dependency.

-- GOTCHA #8 — no lua linter/formatter in this repo (no luacheck/selene/stylua/.luarc).
-- The spike's "type" surface is nil; validation = run it and read SPIKE_PASS / exit 0. (Consistent w/ all smokes.)

-- GOTCHA #9 — `vim.api.nvim_echo` in headless records to message history (no display) but does NOT error.
-- It satisfies the contract's "prints to :messages" requirement. The SPIKE_PASS stdout line is the parseable
-- gate signal (mirrors SMOKE_PASS). Use BOTH.

-- GOTCHA #10 — skip-if-missing MUST exit 0 (PRD §17.15: never fail CI for a missing optional shell).
-- `vim.fn.executable("fish") == 0` ⇒ print SPIKE_SKIP, `return` (the +qa exits 0). Do NOT `cquit` on a missing fish.

-- GOTCHA #11 — wrap the spawn under `timeout 30` at the SHELL level too (AGENTS.md).
-- `timeout 30 nvim …` is the outer safety net; `vim.wait` is the inner one. A hung headless nvim with no
-- timeout blocks the whole turn.
```

## Implementation Blueprint

### Design Decision (READ FIRST — placement: `tests/`, not `/tmp/`)

The contract allows "`/tmp/shell_spike.lua` or `tests/shell_fish_spike.lua`." **Choose `tests/shell_fish_spike.lua`.**
Rationale (research §4.5): (1) it matches the repo's `tests/*_smoke.lua` convention (same `check`/`fails` footer,
same `+"luafile" +qa` run shape as `tests/bridge_smoke.lua`); (2) it's re-runnable as a Phase-6 regression smoke
once the real fish driver lands; (3) AGENTS.md's hard rule is about heredoc→nvim-stdin, and a file under `tests/`
satisfies "write to a real file" identically to `/tmp/`. The only cost is committing one tracked file (intended —
the spike doubles as a smoke). `/tmp/` is acceptable if a reviewer prefers a throwaway, but forfeits the convention
and re-run value.

### Data models and structure

No persistent data models. Runtime locals in the spike script:
- `items` = array of `{ word: string, desc: string }` parsed from the sentinel-framed response.
- `rx_buf` = the accumulating stdout buffer (string); sliced on sentinel pairs.
- `done` / `fails` / `skipped` = booleans/counters driving the wait + footer.

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE tests/shell_fish_spike.lua — header + skip-if-missing + footer skeleton
  - WRITE the file header doc-comment with the EXACT run command:
      `timeout 30 nvim --headless --clean -u NORC +"luafile tests/shell_fish_spike.lua" +qa`
    and the exit-code legend (0 = SPIKE_PASS or SPIKE_SKIP; 1 = gate failed). Note the AGENTS.md HARD RULE.
  - DEFINE `local uv = vim.uv`, `local fails = 0`, `local function check(cond, msg) … end` (mirror bridge_smoke).
  - GUARD: `if vim.fn.executable("fish") == 0 then io.stdout:write("SPIKE_SKIP: fish not on PATH — gate deferred\n"); return end`
    (return at chunk top-level exits the script; the +qa then exits 0).
  - DO NOT: import jsonlreader (the spike parses its OWN sentinel framing); require any pi-bridge module
    (it is standalone); create any lua/pi-bridge/* file.

Task 2: APPEND the fish startup script + temp-file write
  - DEFINE the fish startup script as a Lua `[[ … ]]` string (see Reference Implementation §A). It defines:
      `__pi_handle` (read prefix, strip __PIREQ__, extract .line via string match -r, echo __PIRESP_START__,
      complete -C "$cmd" | while read word desc; printf '%s\t%s' / bare word; echo __PIRESP_END__),
      `function fish_prompt; end` (reduce noise), and a trailing `__pi_handle` call (one round-trip).
  - WRITE it to `local script_path = os.tmpname()` via `io.open(script_path,"w")`. Defer `os.remove` to teardown.
  - DO NOT: inline the script as one `--init-command` literal (multi-line is awkward; the temp-file approach is
    the daemon pattern PRD §17.6.1 specifies and what the real fish.lua driver will use). Do NOT use `--noconfig`.

Task 3: APPEND the spawn + 3 pipes + read_start + write + wait
  - CREATE `stdin, stdout, stderr_pipe = uv.new_pipe(false)` (×3).
  - SPAWN: `pcall(function() handle, spawn_err = uv.spawn("fish", { args={"-i","--init-command=".."source "..script_path}, stdio={stdin,stdout,stderr_pipe} }, function() end) end)`.
    `check(handle ~= nil, "uv.spawn(fish) returned no handle; err="..tostring(spawn_err))`.
  - READ: `pcall(function() stdout:read_start(function(rerr,data) … end) end)`. In the cb: on rerr → record + done;
    on data → append to rx_buf + try_parse(); on nil (EOF) → done = done or #items>0.
  - try_parse(): find "__PIRESP_START__\n" then "__PIRESP_END__"; if both, slice body, `gmatch("([^\n\r]+)")`,
    parse `^([^\t]+)\t(.+)$` → {word,desc} (desc optional), insert, set done=true.
  - WRITE the request: `pcall(function() stdin:write('__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n') end)`.
  - WAIT: `vim.wait(10000, function() return done end, 20)` (bounded safety net). Capture `waited`; if not done → timed_out.
  - DO NOT: omit the pcall on any uv call (GOTCHA #2). Do NOT forget the `stdio` array ORDER {stdin,stdout,stderr}.

Task 4: APPEND the gate checks + nvim_echo + teardown + footer
  - BUILD `words = {}` set from items; `vim.api.nvim_echo` the count + each item (the :messages requirement).
  - CHECK: `check(#items > 0, "no items parsed (done=.., waited=.., timed_out=..)")`; `check(words["checkout"]~=nil,…)`;
    `check(words["cherry"]~=nil,…)`. (cherry-pick is bonus — assert softly or just note it.)
  - TEARDOWN (pcall each): `uv.process_kill(handle,"sigkill")` if handle & not closing; `:close()` on each pipe;
    `os.remove(script_path)`.
  - FOOTER: `if fails > 0 then io.stderr:write(fails.." check(s) failed — fish spike GATE FAILED\n"); vim.cmd("cquit 1") end`;
    `io.stdout:write("SPIKE_PASS: fish framed round-trip proven (checkout+cherry present)\n")`.
  - DO NOT: `cquit` on a missing fish (handled by Task 1's return). Do NOT skip teardown even on failure.
```

### Reference Implementation (LIVE-VERIFIED — derived from the passing experiment in research §2b)

> This is the cleaned-up, convention-matching version of the script that passed the gate in this research session.
> It is the intended content of `tests/shell_fish_spike.lua`. The implementer may paste it verbatim and run Task 5.

```lua
-- === tests/shell_fish_spike.lua — Phase 6, step 21 SPIKE (PRD §17.16 step 21 / §17.6.1 / §17.5.1) ===
-- Standalone (plenary-FREE) proof that the framed fish completion round-trip works: spawns an INTERACTIVE
-- `fish` over piped stdio via vim.uv.spawn, sends one __PIREQ__ frame, parses word<TAB>desc lines between
-- __PIRESP_START__/__PIRESP_END__ sentinels, echoes them via nvim_echo, and prints a parseable verdict.
-- GATE for the rest of P2.M1.T2 (shell.lua): proceed iff `checkout` + `cherry` appear.
--
-- Run from the REPO ROOT:
--   timeout 30 nvim --headless --clean -u NORC +"luafile tests/shell_fish_spike.lua" +qa
--   echo "exit=$?"   # 0 = SPIKE_PASS (or SPIKE_SKIP if fish absent); 1 = gate FAILED
--
-- AGENTS.md HARD RULE: this IS a file on disk — run via :luafile. NEVER heredoc-to-nvim-stdin (it hangs).
-- Gated on `fish` being on $PATH; prints SPIKE_SKIP + exits 0 if absent (PRD §17.15: never fail CI for a missing shell).
local uv = vim.uv

local fails = 0
local function check(cond, msg)
	if not cond then io.stderr:write("FAIL: " .. msg .. "\n"); fails = fails + 1 end
end

if vim.fn.executable("fish") == 0 then
	io.stdout:write("SPIKE_SKIP: fish not on PATH — gate deferred (exit 0)\n")
	return -- chunk-level return; the +qa exits 0
end

-- (1) The daemon's startup script (PRD §17.6.1): written to a temp file, sourced via `fish -i --init-command`.
--     jq-free JSON: fish has no builtin JSON parser (jq not guaranteed on PATH), so `string match -r` extracts .line.
local fish_script = [[
function __pi_handle
    set -l line ""
    read -l line
    if test -z "$line"; return; end
    set -l payload (string replace -r '^__PIREQ__\t' '' -- "$line")
    set -l cmd (string match -r '"line":"([^"]*)"' -- "$payload")[2]
    echo __PIRESP_START__
    complete -C "$cmd" | while read -l word desc
        test -n "$desc"; and printf '%s\t%s\n' "$word" "$desc"; or printf '%s\n' "$word"
    end
    echo __PIRESP_END__
end
function fish_prompt; end
__pi_handle
]]
local script_path = os.tmpname()
local f = io.open(script_path, "w")
f:write(fish_script)
f:close()

-- (2) Spawn `fish -i` with 3 piped streams. pcall EVERY uv call (PRD §17.5.2: never blocks, never throws).
local stdin = uv.new_pipe(false)
local stdout = uv.new_pipe(false)
local stderr_pipe = uv.new_pipe(false)
local handle, spawn_err
pcall(function()
	handle, spawn_err = uv.spawn("fish", {
		args = { "-i", "--init-command=" .. "source " .. script_path },
		stdio = { stdin, stdout, stderr_pipe },
	}, function() end) -- on_exit no-op for the spike (we teardown on sentinel/timeout)
end)
check(handle ~= nil, "uv.spawn(fish) returned no handle; err=" .. tostring(spawn_err))

local rx_buf, done = "", false
local items = {}

-- try_parse: scan rx_buf for a __PIRESP_START__\n .. __PIRESP_END__ pair; slice + parse word(\tdesc)? lines.
local function try_parse()
	local s = rx_buf:find("__PIRESP_START__\n", 1, true)
	local e = rx_buf:find("__PIRESP_END__", (s or 1) + 1, true)
	if not (s and e) then return end
	local body = rx_buf:sub(s + #"__PIRESP_START__\n", e - 1)
	for line in body:gmatch("([^\n\r]+)") do
		local word, desc = line:match("^([^\t]+)\t(.+)$")
		table.insert(items, { word = word or line, desc = desc or "" })
	end
	done = true
end

-- (3) Read stdout; buffer + scan each chunk. data == nil ⇒ EOF (finalize), NOT an error.
local read_ok = pcall(function()
	stdout:read_start(function(rerr, data)
		if rerr then
			io.stderr:write("FAIL: stdout read_start err=" .. tostring(rerr) .. "\n")
			done = true
			return
		end
		if data then
			rx_buf = rx_buf .. data
			try_parse()
		else
			done = done or (#items > 0) -- EOF: finalize if we already parsed
		end
	end)
end)
check(read_ok, "stdout:read_start threw")

-- (4) Send the framed request (PRD §17.5.1 EXACT wire shape).
pcall(function()
	stdin:write('__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n')
end)

-- (5) Drive the event loop until done OR a hard timeout (safety net; AGENTS.md).
local waited = vim.wait(10000, function() return done end, 20)
local timed_out = not done

-- (6) Gate verdict + :messages echo (PRD §17.16 step 21). nvim_echo records to message history (headless-safe).
local words = {}
for _, it in ipairs(items) do words[it.word] = true end
vim.api.nvim_echo({ { "[shell-fish-spike] parsed " .. #items .. " item(s):", "Title" } }, false, {})
for _, it in ipairs(items) do
	vim.api.nvim_echo({ { "  " .. it.word .. "  =>  " .. it.desc } }, false, {})
end

check(#items > 0,
	"no items parsed (done=" .. tostring(done) .. ", waited=" .. tostring(waited) .. ", timed_out=" .. tostring(timed_out) .. ")")
check(words["checkout"] ~= nil, "expected `checkout` in results (complete -C \"git ch\")")
check(words["cherry"] ~= nil, "expected `cherry` in results (complete -C \"git ch\")")
-- bonus (do NOT hard-fail on this — it's informational; some fish installs order differently):
if words["cherry-pick"] ~= nil then
	vim.api.nvim_echo({ { "[shell-fish-spike] bonus: cherry-pick present" } }, false, {})
end

-- (7) Teardown — kill + close every handle (mirrors shell.lua teardown(); §17.5.2). pcall each.
pcall(function()
	if handle and not handle:is_closing() then uv.process_kill(handle, "sigkill") end
end)
pcall(function()
	if stdin and not stdin:is_closing() then stdin:close() end
end)
pcall(function()
	if stdout and not stdout:is_closing() then stdout:close() end
end)
pcall(function()
	if stderr_pipe and not stderr_pipe:is_closing() then stderr_pipe:close() end
end)
os.remove(script_path)

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed — fish spike GATE FAILED\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SPIKE_PASS: fish framed round-trip proven (checkout+cherry present)\n")
```

### Integration Points

```yaml
NO INTEGRATION. This is a standalone spike:
  - NO new module under lua/pi-bridge/ (shell.lua is P2.M1.T2.S2; the fish driver is P2.M2.T4.S1).
  - NO edit to lua/pi-bridge/* , extension/* , doc/* , ftplugin/* , plugin/* , README.md.
  - NO dependency on the parallel P2.M1.T1.S4 bridge.get_shell_info() accessor (the spike uses the literal
    "/usr/bin/fish" the contract pins; the real shell.lua will use get_shell_info()).
  - NO new config key, env var, RPC method, or helpdoc.

GATE OUTPUT (the signal downstream tasks key on):
  - SPIKE_PASS  ⇒ proceed to P2.M1.T2.S2 (shell.lua resolve_shell/pick_driver/session_cwd).
  - SPIKE_SKIP  ⇒ fish absent on this box — defer the gate; do NOT block the build (CI-equivalent: skip).
  - GATE FAILED ⇒ the framed fish seam is broken; STOP and re-plan the fish driver before building shell.lua.
```

## Validation Loop

> Run from the repo root (`/home/dustin/projects/pi-nvim-bridge`). ALWAYS wrap nvim in `timeout`
> (AGENTS.md HARD RULE). No lua linter exists (GOTCHA #8) — the spike run IS the gate.

### Level 1: Syntax (the file parses)

```bash
# 1a. Byte-compile the spike (catches a syntax error / unbalanced block fast, no subprocess):
timeout 30 nvim --headless --clean -u NORC \
  -c 'lua assert(loadfile("tests/shell_fish_spike.lua"))' -c 'qa' && echo "PARSE_OK exit=$?"
# Expected: PARSE_OK exit=0. If loadfile returns nil + err, READ it: likely a tab/space mix, an unbalanced
#   `end`/`function`, or a typo in the fish_script heredoc delimiters ([[ ]]).
```

### Level 2: The gate (the actual spike run)

```bash
# 2a. THE gate — run the spike against the REAL fish binary:
timeout 30 nvim --headless --clean -u NORC +"luafile tests/shell_fish_spike.lua" +qa
echo "exit=$?"
# Expected (this machine, fish present):
#   SPIKE_PASS: fish framed round-trip proven (checkout+cherry present)
#   exit=0
# If SPIKE_PASS: ✔ GATE MET — proceed to P2.M1.T2.S2.
# If "FAIL: ..." lines + "... GATE FAILED" + exit=1: a check failed. Re-read the FAIL line:
#   - "no items parsed" → the sentinels never landed in rx_buf. Likely: spawn failed (check the "uv.spawn(fish)
#     returned no handle" FAIL), or fish errored at startup (raise the noise: drop the grep filter, run without
#     |grep, inspect raw stdout for fish errors), or the fish_script has a syntax error (run
#     `fish -n <(echo '<script>')` or `fish -c 'source <tmp>'` standalone to isolate).
#   - "expected `checkout`/`cherry`" → fish ran but complete -C returned different items. Run
#     `fish -c 'complete -C "git ch"'` directly to see what THIS fish actually returns; adjust the asserts only
#     if the local fish genuinely lacks those (it won't on a normal install).
```

### Level 3: Skip-path + isolation (robustness)

```bash
# 3a. Skip path — simulate a fish-less box (PATH without fish) → must SPIKE_SKIP + exit 0 (NOT fail):
PATH=/usr/bin:/bin timeout 30 nvim --headless --clean -u NORC \
  +"lua vim.uv=nil" +"luafile tests/shell_fish_spike.lua" +qa 2>&1 | tail -2
# NOTE: cleaner skip test — temporarily make fish unresolvable via a fake executable() check is hard in --clean;
#   instead, verify the guard logic by reading it: `if vim.fn.executable("fish") == 0 then ... return end`.
#   On CI runners WITHOUT fish, this path fires and the job stays green (exit 0). On THIS box fish is present,
#   so the gate runs and prints SPIKE_PASS.

# 3b. Isolation — confirm NO source files were touched (only tests/shell_fish_spike.lua is new):
git status --porcelain
# Expected: exactly one untracked/new file: `?? tests/shell_fish_spike.lua`. Nothing under lua/extension/doc/.
```

### Level 4: (none — no MCP/Docker/Playwright/web surface; this is a one-file standalone spike)

## Final Validation Checklist

### Technical Validation

- [ ] Level 1: `tests/shell_fish_spike.lua` byte-compiles (`PARSE_OK exit=0`).
- [ ] Level 2a: `timeout 30 nvim --headless --clean -u NORC +"luafile tests/shell_fish_spike.lua" +qa` prints
      `SPIKE_PASS: …` and `exit=0` on this machine (fish present).
- [ ] Level 3b: `git status --porcelain` shows ONLY `?? tests/shell_fish_spike.lua` (no other file touched).

### Feature Validation (the gate)

- [ ] Parsed results include `checkout` and `cherry` (and bonus `cherry-pick`), each with its description.
- [ ] Items are echoed via `vim.api.nvim_echo` (the `:messages` requirement).
- [ ] The framed wire shape is exactly `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n` and the response is
      sliced between `__PIRESP_START__`/`__PIRESP_END__` (anything outside discarded — incl. config noise).
- [ ] On a fish-less box the script prints `SPIKE_SKIP` and exits 0 (does not fail CI).

### Code Quality Validation

- [ ] Every `vim.uv` call (`spawn`, `read_start`, `write`, `process_kill`, `close` ×3) is wrapped in `pcall`.
- [ ] A bounded `vim.wait` is present (no unbounded block); the outer command is under `timeout 30`.
- [ ] Teardown kills the proc + closes all 3 pipes + removes the temp script even on the failure path.
- [ ] Matches `tests/bridge_smoke.lua` conventions (`check`/`fails` footer, header run-command doc-comment).
- [ ] The fish startup script is written to `os.tmpname()` and `source`d (NOT `--noconfig`; NOT a one-line `-c`).

### Documentation & Deployment

- [ ] Header doc-comment documents the exact run command + exit-code legend + the AGENTS.md HARD RULE.
- [ ] NO README / `doc/pi-bridge.txt` / `doc/pi-bridge-shell.txt` / `extension/README.md` change (Mode-B task
      P2.M4.T7 + vimdoc task P2.M3.T6.S4 own those; the spike is pre-doc).
- [ ] Inline comments cite PRD §17.16 step 21 / §17.6.1 / §17.5.1 so a future reader knows WHY each piece exists.

---

## Anti-Patterns to Avoid

- ❌ **Don't pipe a heredoc into nvim's stdin** (AGENTS.md HARD RULE — it hangs the session). The spike MUST be a
  file on disk run via `+"luafile tests/shell_fish_spike.lua" +qa`. (The fish startup script is written to
  `os.tmpname()` and `source`d — also a file, also safe.)
- ❌ **Don't use `fish --noconfig` or `fish -c "<one-cmd>"`.** `--noconfig` loads nothing (we WANT the user's
  config so their completions load — PRD §17.6.1); `-c` exits after one command (no loop/handler). Use
  `fish -i --init-command="source <tmp>"` (verified research §2a).
- ❌ **Don't add a `jq` dependency.** jq is not guaranteed on PATH and fish has no builtin JSON parser. Parse the
  single `"line"` field with `string match -r '"line":"([^"]*)"'` (research §4.3).
- ❌ **Don't confuse `complete -C` (query) with `fish -C`/`--init-command` (startup flag).** They share a letter.
  In spawn args use the long form `--init-command=`. The `complete -C "$cmd"` runs INSIDE the daemon script.
- ❌ **Don't skip the `pcall` on any uv call** "because it should work." A teardown race (double-close, killed
  handle) throws and crashes the spike. PRD §17.5.2 mandates "never blocks, never throws."
- ❌ **Don't treat `data == nil` from `read_start` as an error.** It's EOF — finalize (`done = done or #items>0`),
  don't error. The error case is `rerr ~= nil`.
- ❌ **Don't omit the bounded `vim.wait` / the outer `timeout 30`.** A hung headless nvim with no timeout blocks
  the whole turn (the same class of failure AGENTS.md warns about). Both safety nets are mandatory.
- ❌ **Don't `cquit` on a missing fish.** PRD §17.15: never fail CI for a missing optional shell. Print
  `SPIKE_SKIP` and `return` (exit 0). `cquit 1` is ONLY for a real gate failure (fish present + checkout/cherry absent).
- ❌ **Don't create `shell.lua`, `shell/fish.lua`, `accept.lua`, or any `lua/pi-bridge/*` file.** This spike is
  ONE file (`tests/shell_fish_spike.lua`) and creates nothing else. The module is P2.M1.T2.S2; the driver is
  P2.M2.T4.S1.
- ❌ **Don't depend on `bridge.get_shell_info()` (the parallel P2.M1.T1.S4 accessor).** The spike uses the literal
  `/usr/bin/fish` the contract pins. Coupling to the in-flight descriptor work would create a false dependency
  and a cross-task deadlock. `shell.lua` (S2) will use the accessor; the spike doesn't.