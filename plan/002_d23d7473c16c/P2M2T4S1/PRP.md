---
name: "P2.M2.T4.S1 — fish.lua shell-completion driver: daemon script + start(opts,on_ready) + cd(path)"
why_this_prp: "First concrete per-shell driver for §17 shell completion. It is the template every later driver (zsh/bash) copies, AND it must satisfy the exact `start(opts,on_ready)` contract the already-landed shell.lua (P2.M1.T2) and its test fakes (P2.M2.T3) assume. Every non-obvious detail below was LIVE-VERIFIED against fish 4.8.1 on this machine."
---

## Goal

**Feature Goal**: Implement `lua/pi-bridge/shell/fish.lua` — the Tier-1 fish
shell-completion driver (PRD §17.6.1) — exposing `start(opts, on_ready)` (spawn a
persistent `fish -i` daemon, source the user's config, install a framed request handler
that turns `complete -C` output into ONE valid JSON object between sentinels) and
`cd(path)` (re-`cd` the daemon over a framed channel). It is loaded by
`shell.lua`'s `M.pick_driver` (`require("pi-bridge.shell.fish")`) and driven by the
existing `M.ensure`/`M.request`/`M._feed` pipeline (already Complete).

**Deliverable**: One new Lua module `lua/pi-bridge/shell/fish.lua` (~150-220 lines)
exporting `M.start(opts, on_ready)` and `M.cd(path)`, plus two test files:
`tests/shell_fish_driver_smoke.lua` (plenary-free, LIVE-gated on `fish`) and
`tests/shell_fish_driver_spec.lua` (plenary, live + offline contract cases). No changes
to `shell.lua`, `completion.lua`, or any extension file — the seams are already in place.

**Success Definition**:
1. `require("pi-bridge.shell.fish").start` is a function and `.cd` is a function (the
   contract `shell.lua`'s `pick_driver` validates: `type(drv.start)=="function"`).
2. `start({shell="/usr/bin/fish",cwd=<tmp>,startup_timeout_ms=5000}, cb)` spawns a
   persistent `fish` process and calls `cb(nil, proc, stdin, stdout)` with live luv
   handles; the daemon stays alive across ≥3 sequential framed requests (persistence —
   the spike only did ONE).
3. A framed request `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n` yields a
   response `__PIRESP_START__\n{"items":[...],"prefix":""}\n__PIRESP_END__\n` whose
   decoded `items` include `checkout`/`cherry`/`cherry-pick` (with descriptions).
4. `state.failed` semantics: on spawn error / binary missing / startup-timeout, `start`
   calls `cb(err, nil, nil, nil)` (never throws, never leaves handles open).
5. The two test files pass (smoke exit 0; spec green). Smoke `SPIKE_SKIP`s (exit 0) when
   `fish` is not on PATH (PRD §17.15: never fail CI for a missing optional shell).

## User Persona (if applicable)

**Target User**: a pi user whose `$SHELL` (or pi's resolved execution shell) is fish, and
who types `!`/`!!` shell commands into the pi-prompt Neovim buffer (PRD §17). Indirect
user: the `pi-bridge.nvim` plugin itself, which calls this driver through `shell.lua`.

**Use Case**: typing `!git ch<Tab>` in the pi-prompt buffer → the menu shows fish's
`checkout`/`cherry`/`cherry-pick` with descriptions, identical to typing `git ch` at a
real fish prompt.

**Pain Points Addressed**: today (pre-S1) a `!` line gets NO completion of any kind
(completion_context returns `"shell"` but no driver exists → `pick_driver` returns nil →
`ensure` sets `state.failed` and emits the degrade notice). S1 makes the most common case
(fish) actually work.

## Why

- **Closes the shell-completion gap for the Tier-1 shell** (PRD §17.6.1 "clean win" — fish
  has a designed-for-this `complete -C` API, unlike zsh/bash which need fragile widgets).
- **Sets the driver template**: `zsh.lua`/`bash.lua` (P2.M3.T5) copy this module's
  `start(opts,on_ready)`/`cd(path)` shape + the stderr-ready-signal + framed-response
  pattern. Getting fish right first makes the others mechanical.
- **Consumes already-landed infrastructure**: `shell.lua` (`ensure`/`request`/`_feed`/
  `teardown`/`pick_driver`), `completion.lua` (`do_shell_fetch`→`complete_current`), and
  the bridge descriptor `shell` field (P2.M1.T1) are all Complete. S1 is the leaf that
  turns the plumbing into working completions.

## What

A Lua module `lua/pi-bridge/shell/fish.lua` that:

1. On `start(opts, on_ready)`: writes a fish startup script to a temp file, creates three
   `uv.new_pipe(false)` handles (stdin/stdout/stderr), spawns
   `fish -i --init-command="source <tmpfile>"` with `stdio={stdin,stdout,stderr}` and
   `cwd=opts.cwd` (when non-nil), arms a `startup_timeout_ms` cold-start timer, reads
   **stderr** for an `__PIREADY__\n` marker, and on readiness calls
   `on_ready(nil, proc, stdin, stdout)`. On any failure it kills the proc + closes all
   three pipes + calls `on_ready(err, nil, nil, nil)`.
2. On `cd(path)`: writes `__PICD__\t<path>\n` to the daemon's stdin (best-effort, pcall'd,
   silent — the daemon's read loop recognizes `__PICD__` and `builtin cd`s).
3. The fish DAEMON SCRIPT (embedded as a Lua long-string, written to the temp file):
   defines `__pi_json_str` (jq-free manual JSON escaping), `__pi_handle` (extract `.line`
   via the SIMPLE regex, run `complete -C`, build the items array, emit the single-object
   JSON between sentinels), silences `fish_prompt`, emits `__PIREADY__` to stderr, then
   enters a `while read` loop.

### Success Criteria

- [ ] `lua/pi-bridge/shell/fish.lua` exists, `require("pi-bridge.shell.fish")` loads
      without error, and `M.start`/`M.cd` are functions.
- [ ] `M.start` calls `on_ready(nil, proc, stdin, stdout)` with live handles within
      `startup_timeout_ms` (5s); the daemon survives ≥3 sequential framed requests.
- [ ] End-to-end: feeding `__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n` to the
      spawned daemon's stdin produces `checkout`/`cherry`/`cherry-pick` in the decoded
      `items` (LIVE fish, gated on `vim.fn.executable("fish")`).
- [ ] `cd("/tmp")` then a path-relative request reflects the new cwd (best-effort).
- [ ] Spawn error / binary-missing / startup-timeout → `on_ready(err, nil,nil,nil)`, no
      leaked handles, never throws.
- [ ] `tests/shell_fish_driver_smoke.lua` exits 0 (PASS, or SKIP if no fish);
      `tests/shell_fish_driver_spec.lua` green.

## All Needed Context

### Context Completeness Check

_Pass_: an implementer who knows nothing about this codebase gets (a) the exact
`start(opts,on_ready)`/`cd(path)` contract with arg arity + return shape, (b) the COMPLETE
validated fish daemon script (with the manual-JSON helper that the PRD's outdated
`--style=json` sketch got wrong), (c) the stderr-ready-signal trick that avoids an illegal
double-`read_start`, (d) the exact test invocation + gating pattern, and (e) every
LIVE-VERIFIED gotcha (simple-not-fancy regex, single-object-not-NDJSON response, first-tab
split). No fish or luv knowledge beyond what's quoted here is required.

### Documentation & References

```yaml
# MUST READ — the contract this driver must satisfy (already-landed, read-only)
- file: lua/pi-bridge/shell.lua
  why: "M.ensure (L329) calls state.driver.start(opts, cb) where cb=function(err,proc,stdin,stdout) (L696-712);
        M.pick_driver (L220) validates type(drv.start)=='function'; M._feed (L525) decodes the single-object
        JSON between sentinels; M.teardown/close_handles (L621/L680) kill+close proc/stdin/stdout and EXPLICITLY
        do NOT close stderr ('the driver owns it'). Read L525-L620 (_feed) to see the EXACT response shape your
        daemon script must emit."
  pattern: "the driver seam: start(opts,on_ready)→on_ready(err,proc,stdin,stdout); driver owns stderr + startup timer"
  gotcha: "on_ready takes 4 args (err, proc, stdin, stdout) — the test fakes pass exactly this arity. proc MUST be
           the uv_process_t (teardown process_kills it). stdout MUST NOT be read_start'd by the driver (shell.lua
           owns it post-on_ready) — use STDERR for the ready signal (see §Integration)."

# The validated spike (single-request proof) — your daemon script's lineage
- file: tests/shell_fish_spike.lua
  why: "P2.M1.T2.S1 (Complete) — proved fish -i --init-command='source <file>' + framed round-trip works.
        The production daemon script EXTENDS this: adds __pi_json_str (single-object JSON), the while-read loop
        (persistence), and the __PIREADY__ stderr marker. Copy the spawn/teardown idiom verbatim (is_closing-guard
        + pcall + 'sigkill')."
  pattern: "uv.new_pipe(false) ×3; uv.spawn('fish',{args,stdio,cwd}); stdout:read_start; teardown = read_stop→close, process_kill→close, stdin:close"
  gotcha: "the spike read stdout ITSELF for the single response (one-shot). Production must NOT — shell.lua owns
           stdout post-on_ready. Emit __PIREADY__ to STDERR, read stderr in start(), hand stdout off untouched."

# The caller (completion routing — already Complete; do NOT modify, just understand the consumer)
- file: lua/pi-bridge/completion.lua
  why: "do_shell_fetch (L411) → shell.complete_current (L945) → shell.request → ensure → driver.start. The response
        cb runs in LIBUV FAST context (L429-440) — your driver must do NO vim.api.* in its callbacks (only luv +
        state writes); the menu hop is vim.schedule'd by the consumer. This is already handled; just don't ADD
        vim.api calls in your on_exit/timer/read callbacks."
  pattern: "fast-context-safe driver callbacks (luv only); consumer schedules the UI"
  gotcha: "complete_current reads the buffer + strips bangs + computes byte offsets BEFORE calling shell.request —
           your driver never touches the buffer."

# Test fake pattern — the real fish.lua MUST match this exact interface
- file: tests/shell_complete_current_spec.lua
  why: "inject_fake_driver (L67) defines the contract the real fish.lua must satisfy: drv.start=function(opts,cb)
        cb(nil, {is_closing=...}, stdin, stdout). Your real start() must hand REAL luv handles of the same shape."
  pattern: "package.loaded['pi-bridge.shell.fish'] = {start=..., cd=...}; cb(err,proc,stdin,stdout)"
  gotcha: "the fakes set package.loaded['pi-bridge.shell.fish']=nil in after_each (cleanup). Your live-driver spec
           must do the SAME so a stale real module doesn't leak into shell.lua's unit tests."

# PRD source-of-truth (§17.6.1 sketch is PARTLY OUTDATED — see gotcha)
- url: in-repo PRD.md §17.6.1 (fish — Tier 1) and §17.5.1 (Framing protocol)
  why: "the design intent + the complete -C 'git ch' → checkout semantic. §17.5.1 defines the wire frame
        (__PIREQ__\\t{json}\\n / __PIRESP_START__\\n{single-object}\\n__PIRESP_END__\\n)."
  critical: "§17.6.1's sketch uses 'string escape --style=json' — REMOVED in fish 4.x (LIVE-VERIFIED:
            'Invalid escape style json'). It also emits per-line NDJSON — but shell.lua _feed LIVE-VERIFIED
            that NDJSON FAILS to decode. Your daemon script MUST build ONE single-object JSON via the manual
            __pi_json_str helper (validated in research/fish_driver_findings.md §3). The sketch's fancy
            (?:...) regex also FAILS in fish — use the SIMPLE [^\"]* regex (research §4)."

# fish docs (only the two APIs the script depends on)
- url: https://fishshell.com/docs/current/cmds/complete.html
  why: "'complete -C \"<line>\"' returns word⇥description completions using all loaded completions (the Tier-1 API)."
  critical: "the cursor is implicitly at the END of <line>; fish completes the trailing word. Confirmed live."
- url: https://fishshell.com/docs/current/cmds/string.html
  why: "string replace --all + string match -r (the script's only string tools). NO --style=json in fish 4.x."
  critical: "string match -r uses PCRE but NON-CAPTURING groups (?:...) throw 'missing terminating ]' under fish's
            shell-quoting — use SIMPLE character classes only (research §4)."
```

### Current Codebase tree (relevant slice)

```bash
lua/pi-bridge/
├── shell.lua              # COMPLETE (P2.M1.T2 + P2.M2.T3). The daemon manager + driver caller.
├── completion.lua         # COMPLETE. do_shell_fetch→complete_current→shell.request.
├── bridge.lua             # COMPLETE. server_info.shell (P2.M1.T1) feeds resolve_shell.
├── notify.lua             # COMPLETE. notify.once (used by shell.lua, NOT by this driver).
└── (no shell/ subdir yet) # ← fish.lua is the FIRST file under lua/pi-bridge/shell/
tests/
├── shell_fish_spike.lua        # COMPLETE (P2.M1.T2.S1) — the single-request proof.
├── shell_ensure_spec.lua       # COMPLETE — uses FAKE drivers (the contract source).
├── shell_complete_current_spec.lua  # COMPLETE — fake driver contract (L67).
└── minimal_init.lua            # plenary bootstrap for spec files.
```

### Desired Codebase tree with files to be added

```bash
lua/pi-bridge/shell/
└── fish.lua              # NEW (S1). Exports M.start(opts,on_ready), M.cd(path).
                           # Embeds the daemon script as a Lua long-string; writes it to a
                           # temp file at start(); spawns fish -i; reads STDERR for ready.
tests/
├── shell_fish_driver_smoke.lua  # NEW (S1). Plenary-FREE, LIVE (gated on `fish`).
│                                  # Spawns the real driver, sends 3 sequential requests,
│                                  # asserts checkout/cherry/cherry-pick + persistence + cd.
└── shell_fish_driver_spec.lua    # NEW (S1). Plenary. Offline contract cases (start/cd
                                   # signature, never-throws on bad opts, on_ready arity) +
                                   # a LIVE case (skipped if no fish).
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL (LIVE-VERIFIED): fish 4.x has NO JSON support.
--   string escape --style=json  → "Invalid escape style 'json'" (PRD §17.6.1 sketch is BROKEN)
--   printf "%j"                 → "invalid conversion specification"
-- → The DAEMON SCRIPT must build JSON manually via __pi_json_str (string replace --all for \ " \n \r \t).
--   Validated: produces decodable {"items":[...]} (research/fish_driver_findings.md §3).

-- CRITICAL (LIVE-VERIFIED): the .line extraction MUST use the SIMPLE regex.
--   "line":"([^"]*)"            → works (cmd = "git ch")
--   "line":"((?:[^"\\]|\\.)*)"  → FAILS: "Regular expression compile error: missing terminating ]"
-- → Use the simple regex. KNOWN LIMITATION (document in fish.lua header): a command line
--   containing a literal " breaks extraction → cmd="" → complete -C "" returns all commands
--   (graceful degradation, not a crash).

-- CRITICAL (LIVE-VERIFIED): the response MUST be ONE single-object JSON, NOT per-line NDJSON.
--   shell.lua _feed does pcall(vim.json.decode, payload) on the WHOLE body between sentinels.
--   NDJSON (multiple objects) → decode throws → parse_failure (§17.12). Emit:
--     __PIRESP_START__\n{"items":[{...},{...}],"prefix":""}\n__PIRESP_END__\n

-- CRITICAL (luv): you CANNOT read_start the SAME pipe twice. shell.lua wires stdout:read_start
--   AFTER on_ready (shell.lua L707). So your driver must NOT read_start stdout. Emit the
--   __PIREADY__\n marker to STDERR (printf '__PIREADY__\n' >&2) and read_start the STDERR pipe
--   in start() — stdout stays pristine for shell.lua. (research §7)

-- GOTCHA (luv): uv.spawn is SYNCHRONOUS — returns (handle, err) immediately. There is no
--   "spawn hang"; the cold-start latency is fish's config SOURCING (100ms-1s+), which happens
--   BEFORE the script's read loop starts. The __PIREADY__ stderr marker is what gates on_ready
--   against that latency; startup_timeout_ms (default 5000) is the safety net for a hung config.fish.

-- GOTCHA (luv): process_kill("sigkill") does NOT close the uv_process_t (is_closing stays false
--   even after on_exit). proc:close() is REQUIRED or the handle LEAKS (shell.lua F3 comment).
--   Your driver's failure paths MUST proc:close() after process_kill. (shell.lua teardown owns
--   the success path's close; you own the PRE-on_ready failure path's close.)

-- GOTCHA (luv): a callback-less stdin:write SILENTLY swallows EPIPE (bridge.lua GOTCHA 3).
--   Not your concern (shell.lua owns request writes), but your cd(path) write SHOULD pass a
--   cb to avoid silently losing the cd on a dead pipe — OR accept silent loss (cd is best-effort).

-- GOTCHA (fish): interactive `fish -i` emits terminal color escapes (\]4;0;#...) at startup.
--   These appear OUTSIDE the __PIRESP_START__..__PIRESP_END__ window → shell.lua _feed's plain
--   find(START)/find(END) slicing DISCARDS them. Do NOT add noise-suppression flags; the spike
--   validated -i works as-is. (research §8)

-- GOTCHA (test isolation): existing shell_*_spec/smoke files set package.loaded["pi-bridge.shell.fish"]=nil
--   in cleanup. Your new spec MUST do the same so the REAL module doesn't leak into those tests.
```

## Implementation Blueprint

### Data models and structure

No persistent data models. The driver is a stateless-ish module with a small per-spawn
closure (the temp-file path, the stderr-ready buffer, the startup timer, the proc/pipes).
The DAEMON SCRIPT's wire types (fixed by shell.lua `_feed` / PRD §17.5.1):

```jsonc
// REQUEST (shell.lua request() sends this; the daemon script parses it):
"__PIREQ__\t{\"line\":\"git ch\",\"cursor\":6,\"after\":\"\"}\n"

// RESPONSE (the daemon script EMITS this; shell.lua _feed decodes it):
"__PIRESP_START__\n{\"items\":[{\"value\":\"checkout\",\"description\":\"Checkout and switch to a branch\"}],\"prefix\":\"\"}\n__PIRESP_END__\n"

// READY (stderr, consumed ONCE by start() before on_ready):
"__PIREADY__\n"

// CD (cd(path) writes this; the daemon recognizes + builtin cd's, NO response):
"__PICD__\t/tmp\n"
```

The item shape `{value, description?}` is normalized to `AutocompleteItem {value,label,description?}`
by shell.lua `_feed`'s `normalize_item` (already implemented). The daemon script does NOT
emit `label` (it defaults to `value`).

### The fish daemon script (the embedded long-string — VALIDATED)

This is the heart of S1. Write it as a Lua `[[ ... ]]` long-string constant in `fish.lua`
and `io.open(tmpfile,"w"):write(script)` at `start()` time. Every line below was
LIVE-VERIFIED (research §3/§4/§5/§6):

```fish
# === pi-bridge fish completion daemon (PRD §17.6.1 / §17.5.1) ===
# Sourced by: fish -i --init-command="source <this file>"
# Reads framed __PIREQ__ lines from stdin; emits ONE single-object JSON between
# __PIRESP_START__/__PIRESP_END__ sentinels. Emits __PIREADY__ to stderr once at startup.

# jq-free JSON string escape (fish 4.x has NO --style=json / printf %j — LIVE-VERIFIED).
# Escapes \, ", \n, \r, \t. Outputs the double-quoted JSON string.
function __pi_json_str
    set -l s "$argv"
    set -l s (string replace --all '\\' '\\\\' -- $s)   # backslash FIRST (before re-escaping)
    set -l s (string replace --all '"'  '\\"'  -- $s)
    set -l s (string replace --all \n '\\n' -- $s)
    set -l s (string replace --all \r '\\r' -- $s)
    set -l s (string replace --all \t '\\t' -- $s)
    printf '"%s"' "$s"
end

# Handle ONE __PIREQ__ line (argv[1]). Extracts .line via the SIMPLE regex (the fancy
# (?:...) PCRE variant FAILS in fish — LIVE-VERIFIED), runs `complete -C`, builds the
# items array, emits START / single-object-JSON / END.
function __pi_handle
    set -l line "$argv[1]"
    if test -z "$line"; or not string match -q '__PIREQ__*' -- $line; return; end

    # CD frame: __PICD__\t<path> → builtin cd, no response (best-effort, silent).
    if string match -q '__PICD__*' -- $line
        set -l p (string replace -r '^__PICD__\t' '' -- $line)
        builtin cd "$p" 2>/dev/null
        return
    end

    # Strip the __PIREQ__\t prefix, then extract .line with the SIMPLE regex.
    set -l payload (string replace -r '^__PIREQ__\t' '' -- $line)
    set -l cmd ""
    set -l m (string match -r '"line":"([^"]*)"' -- $payload)
    if test (count $m) -ge 2
        set cmd $m[2]
    end

    # Run fish's completion engine (the Tier-1 API). Build the items JSON array.
    set -l items_json ""
    set -l first 1
    complete -C "$cmd" | while read -l raw
        test -z "$raw"; and continue
        # Robust split on the FIRST tab (handles spaces in words/descriptions — fish's
        # `read word desc` IFS-split would mis-split a filename with a space).
        set -l word (string replace -r '\t.*$' '' -- $raw)
        set -l desc ""
        if string match -q '*\t*' -- $raw
            set desc (string replace -r '^[^\t]*\t' '' -- $raw)
        end
        set -l item "{\"value\":$(__pi_json_str $word)"
        if test -n "$desc"
            set item "$item,\"description\":$(__pi_json_str $desc)"
        end
        set item "$item}"
        if test $first -eq 1
            set items_json "$item"; set first 0
        else
            set items_json "$items_json,$item"
        end
    end

    # Emit the single-object JSON (NOT NDJSON — shell.lua _feed decodes the WHOLE body).
    echo __PIRESP_START__
    printf '{"items":[%s],"prefix":""}\n' "$items_json"
    echo __PIRESP_END__
end

# Silence the prompt (sentinel framing isolates any residual noise anyway).
function fish_prompt; end

# Announce readiness on STDERR (fd 2) — the Lua start() reads stderr for this marker
# (stdout is owned by shell.lua post-on_ready; two read_start's on one pipe is illegal).
printf '__PIREADY__\n' >&2

# Persistent request loop (the spike did one request; production loops for the session).
while read -l line
    __pi_handle $line
end
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: CREATE lua/pi-bridge/shell/fish.lua — module skeleton + daemon script constant
  - IMPLEMENT: local M = {}; the DAEMON_SCRIPT long-string above (validated, verbatim);
    return M at the bottom.
  - FOLLOW pattern: tests/shell_fish_spike.lua's fish_script (the lineage) — but ADD the
    __pi_json_str helper, the while-read loop, the __PICD__ branch, and the stderr ready marker.
  - NAMING: module-local `M`; the script's helpers are __pi_-prefixed (fish convention; avoids
    colliding with the user's config functions since fish functions are global — the __pi_ prefix
    is the namespace).
  - PLACEMENT: lua/pi-bridge/shell/fish.lua (the basename MUST be `fish` — shell.lua's
    pick_driver does require("pi-bridge.shell."..basename); basename("/usr/bin/fish")=="fish").
  - GOTCHA: do NOT require("pi-bridge") at module top (handshake is async; lazy-require inside
    functions only if needed — fish.lua likely needs NO pi-bridge require at all; it only uses vim.uv).

Task 2: IMPLEMENT M.start(opts, on_ready) in fish.lua
  - SIGNATURE: M.start(opts, on_ready) where opts={shell,cwd,startup_timeout_ms}; on_ready is
    function(err, proc, stdin, stdout). Mirror the spike's spawn idiom.
  - STEPS (each pcall'd / never-throws):
    1. guard on_ready type (if not function, noop) — mirrors shell.lua's never-throws discipline.
    2. write DAEMON_SCRIPT to os.tmpname() (io.open("w"), :write, :close). pcall it; on fail →
       on_ready("script write failed", nil,nil,nil).
    3. create 3 pipes: stdin/stdout/stderr = uv.new_pipe(false) (false = not readable→ wait, new_pipe(false)
       means "not a TTY"; pass false for all three piped streams — matches the spike L57-59).
    4. uv.spawn(opts.shell or "fish", {args={"-i","--init-command=source "..tmp}, stdio={stdin,stdout,stderr},
       cwd=(opts.cwd or nil)}, on_exit). pcall; on spawn_err → close 3 pipes + os.remove(tmp) +
       on_ready(tostring(spawn_err), nil,nil,nil).
    5. arm startup timer: uv.new_timer(); :start(opts.startup_timeout_ms or 5000, 0, timeout_cb).
       timeout_cb → kill proc + close 3 pipes + os.remove(tmp) + on_ready("startup timeout", nil,nil,nil).
    6. read_start STDERR for __PIREADY__: stderr:read_start(function(err,data) ... accumulate into a
       ready_buf; if ready_buf:find("__PIREADY__\n",1,true) then stderr:read_stop() + timer:stop()+:close()
       + os.remove(tmp) + on_ready(nil, proc, stdin, stdout) end). EOF on stderr before ready → startup
       timeout path (proc died during config sourcing).
  - FOLLOW pattern: tests/shell_fish_spike.lua L46-91 (spawn + read + teardown) — the EXACT luv shape.
  - CRITICAL: hand stdout to on_ready UNTOUCHED (no read_start on stdout — shell.lua owns it post-callback).
  - CRITICAL: the on_exit cb (proc died) — if on_ready was already called (success), do nothing (shell.lua's
    stdout EOF → _reset handles it); if NOT yet called, treat as startup failure (close pipes + on_ready err).
    Track readiness with a local `resolved=false` flag closed over by on_exit + the ready cb + the timer cb.
  - GOTCHA: proc:close() is REQUIRED after process_kill (F3 — is_closing stays false). Every failure path
    that kills must also close the proc handle. Close in this order: stderr read_stop→close, proc
    process_kill→close, stdin close, stdout close (mirror shell.lua close_handles L680-700).
  - NEVER throws: pcall EVERY uv call; a throwing luv call degrades to on_ready(err).

Task 3: IMPLEMENT M.cd(path) in fish.lua
  - SIGNATURE: M.cd(path) — best-effort re-cd over the framed channel.
  - STEPS: pcall stdin:write(string.format("__PICD__\t%s\n", path), write_cb) — write_cb swallows
    err silently (cd is advisory; a dead pipe just means the next request's completions use the
    old cwd). If stdin is nil/closing → silent noop.
  - GOTCHA: cd needs a reference to the daemon's stdin. Since the driver module is loaded ONCE and
    start() may be called by shell.lua's ensure (which caches proc/stdin/stdout in shell.lua's OWN
    state), the cleanest is: cd writes via the stdin handle shell.lua already cached → BUT cd is a
    DRIVER method, called on the driver module, with no access to shell.lua's state.
    RESOLUTION: fish.lua keeps a module-local `last_stdin` set by start() (the stdin it handed to
    on_ready). cd(path) writes to last_stdin. This is safe because there's ONE daemon per session
    (shell.lua singleton state) — last_stdin is always the live one. pcall + is_closing-guard every use.
  - FOLLOW pattern: shell.lua request()'s stdin:write(frame, cb) (L830-845) — the write-cb discipline.
  - NAMING: M.cd (shell.lua pick_driver/ensure reference driver.cd implicitly via the architecture note).

Task 4: CREATE tests/shell_fish_driver_smoke.lua (plenary-FREE, LIVE-gated)
  - IMPLEMENT: standalone smoke (mirror tests/shell_fish_spike.lua's structure + the
    tests/shell_ensure_smoke.lua L1-L25 header/run convention).
  - STEPS:
    1. GATE: if vim.fn.executable("fish")==0 → print "SMOKE_SKIP: fish not on PATH" + return (exit 0).
    2. require("pi-bridge.shell.fish").start({shell="fish",cwd=vim.fn.getcwd(),startup_timeout_ms=5000}, cb).
    3. cb(nil,proc,stdin,stdout): wire stdout:read_start into a sentinel parser (reuse the spike's
       try_parse: find __PIRESP_START__\n..__PIRESP_END__\n, vim.json.decode the body).
    4. send 3 SEQUENTIAL __PIREQ__ frames (git ch, ls /tm, git che) — each after the prior resolves
       (persistence proof). Assert each decodes + that "git ch" yields checkout+cherry.
    5. test cd: write __PICD__\t<vimpld> then a request expecting cwd-relative results (best-effort:
       assert no crash; a path-relative completion check is bonus).
    6. teardown: process_kill + close all handles (spike L86-98 idiom). Set package.loaded[...fish]=nil.
  - NAMING: tests/shell_fish_driver_smoke.lua.
  - RUN: `timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_fish_driver_smoke.lua" +qa`
    (AGENTS.md HARD RULE: this is a FILE run via :luafile — NEVER heredoc-to-nvim-stdin).
  - GOTCHA: the driver reads STDERR for __PIREADY__ itself (Task 2 step 6); the smoke test must NOT
    also read stderr (let the driver own it). The test reads only STDOUT (post-on_ready).

Task 5: CREATE tests/shell_fish_driver_spec.lua (plenary, live + offline)
  - IMPLEMENT: plenary/busted spec (mirror tests/shell_ensure_spec.lua structure + before_each/
    after_each cleanup that sets package.loaded["pi-bridge.shell.fish"]=nil).
  - CASES:
    1. offline: M.start and M.cd are functions; require loads without error.
    2. offline: M.start({}, cb) with a non-function cb does NOT throw (never-throws contract).
    3. offline: M.start({shell="/nonexistent/fish"}, cb) → cb(err, nil,nil,nil); no leaked handles
       (assert via uv.walk handle count before/after, like shell_ensure_spec.lua count_open_timers).
    4. LIVE (skip if no fish): M.start real spawn → cb(nil,proc,stdin,stdout) within timeout;
       send "git ch" → decoded items contain checkout. Set package.loaded[...]=nil in after_each.
  - FOLLOW pattern: tests/shell_ensure_spec.lua (the fake-driver spec) for structure + handle-count assert.
  - RUN: `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_fish_driver_spec.lua")'`
  - GOTCHA: the LIVE case must vim.wait for on_ready (it's async — the ready marker arrives on stderr
    after config sourcing). Use a generous timeout (startup_timeout_ms + slack).

Task 6: (NO shell.lua / completion.lua / extension changes)
  - VERIFY: shell.lua's pick_driver already does require("pi-bridge.shell.fish") + validates .start.
    completion.lua's do_shell_fetch already calls shell.complete_current → shell.request → ensure →
    driver.start. The bridge descriptor's `shell` field (P2.M1.T1) already feeds resolve_shell. So S1
    is PURELY additive: one new module + two tests. Do NOT edit any existing file.
```

### Implementation Patterns & Key Details

```lua
-- The start() never-throws skeleton (the discipline every luv driver in this repo follows):
function M.start(opts, on_ready)
  if type(on_ready) ~= "function" then return end          -- never-throws on a bad arg
  opts = opts or {}
  local resolved = false                                    -- guards exactly-one on_ready call
  local function done(err, proc, stdin, stdout)            -- the single exit point
    if resolved then return end; resolved = true
    on_ready(err, proc, stdin, stdout)
  end
  -- ... write script, create pipes, spawn, arm timer, read stderr for __PIREADY__ ...
  -- every failure path: kill+close handles (pcall'd) THEN done(err, nil,nil,nil)
  -- success path (ready marker seen): stderr:read_stop() + timer:stop()+:close() + done(nil,proc,stdin,stdout)
end

-- cd() pattern (advisory, silent — a dead pipe is not an error here, unlike request's write):
function M.cd(path)
  if not last_stdin or last_stdin:is_closing() then return end
  pcall(function()
    last_stdin:write(string.format("__PICD__\t%s\n", tostring(path)), function() end)  -- cb swallows err
  end)
end
```

### Integration Points

```yaml
MODULE LOAD (no config change):
  - shell.lua pick_driver does: pcall(require, "pi-bridge.shell.fish") → validates .start → returns drv.
    No registration needed; just dropping fish.lua at lua/pi-bridge/shell/fish.lua makes it discoverable
    (Neovim's package.path resolves lua/pi-bridge/shell/fish.lua from &runtimepath).
CONFIG:
  - fish.lua reads NO config directly. shell.lua's ensure reads config.shell.startup_timeout_ms
    (default 5000) + config.shell.drivers.fish (default true) and passes startup_timeout_ms THROUGH
    to start(); a `drivers.fish=false` makes pick_driver return nil (§17.4.2). fish.lua honors whatever
    startup_timeout_ms it receives.
ROUTES:
  - none new. completion.lua do_shell_fetch (L411) → shell.complete_current → shell.request → ensure →
    driver.start. The response flows stdout → shell.lua _feed → normalize_item → completion M.on_results → menu.
NO DATABASE / NO EXTENSION CHANGES:
  - the bridge descriptor's `shell` field already exists (P2.M1.T1); resolve_shell already reads it;
    fish.lua never touches the bridge.
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# After creating fish.lua — selene + stylua (the repo's Lua lint/format; follow the existing
# lua/pi-bridge/*.lua style: tabs, double-quoted strings, the [Mode A] header comment convention).
# Run from the repo root:
timeout 30 selene lua/pi-bridge/shell/fish.lua 2>/dev/null || true   # informational (selene may be absent)
timeout 30 stylua --check lua/pi-bridge/shell/fish.lua 2>/dev/null || true
# Quick load check (AGENTS.md: one-liner via -c 'lua ...' is fine; NO heredoc-to-stdin):
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' -c 'lua local d=require("pi-bridge.shell.fish"); assert(type(d.start)=="function"); assert(type(d.cd)=="function"); print("LOAD_OK")' -c 'qa'
echo "exit=$?"   # 0 + LOAD_OK = pass
# Expected: LOAD_OK printed, exit 0.
```

### Level 2: Unit / Component Tests (plenary + smoke)

```bash
# The plenary-FREE smoke (instant feedback, LIVE fish, the primary gate):
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_fish_driver_smoke.lua" +qa
echo "exit=$?"   # 0 = SMOKE_PASS (or SMOKE_SKIP if no fish); 1 = FAIL
# The plenary spec (contract + live cases):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_fish_driver_spec.lua")'
echo "exit=$?"   # 0 = pass
# Regression: ensure the new module doesn't break shell.lua's OWN (fake-driver) tests:
timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")'
echo "exit=$?"   # must stay 0 (the fakes set package.loaded[...]=nil; verify no leak)
# Expected: all green. fish 4.8.1 IS present in this env → the LIVE cases run (not skipped).
```

### Level 3: Integration (the daemon manager + completion routing end-to-end)

```bash
# The REAL end-to-end: shell.lua ensure/request/_feed driving the REAL fish.lua driver.
# This reuses the existing shell.lua pipeline — no new harness. Write a tiny driver-level
# integration smoke that calls shell.lua directly (NOT the driver in isolation):
cat > /tmp/fish_e2e.lua <<'LUA'   # heredoc→FILE is fine (AGENTS.md); heredoc→nvim stdin is NOT
local shell = require("pi-bridge.shell")
local pi = require("pi-bridge"); if pi.config==nil then pi.setup({}) end
pi.bridge = { get_shell_info=function() return {shell="/usr/bin/fish"} end, server_info={cwd=vim.fn.getcwd()} }
shell.reset()
shell.request("git ch", 6, "", function(err, items, prefix)
  assert(err==nil, "err="..tostring(err))
  local found = {}
  for _, it in ipairs(items or {}) do found[it.value]=true end
  assert(found.checkout, "missing checkout"); assert(found.cherry, "missing cherry")
  print("E2E_PASS: "..#items.." items, checkout+cherry present")
  shell.teardown()
  vim.cmd("qa")
end)
-- drive the loop until teardown resolves
vim.wait(8000, function() return shell._test_pending_is_nil() end, 20)
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/fish_e2e.lua" +qa
echo "exit=$?"   # 0 + E2E_PASS = the full pipeline works with the real fish driver
# Expected: E2E_PASS, exit 0. (This proves fish.lua integrates with the ALREADY-LANDED shell.lua.)
```

### Level 4: Creative & Domain-Specific Validation

```bash
# Persistence + cd (the two things the spike did NOT prove):
# the smoke (Task 4) sends 3 sequential requests through ONE spawned daemon — if the daemon
# died after request 1, requests 2-3 would hang/timeout. Persistence = sequential decode success.
# cd: write __PICD__\t<path> then request a path-relative completion (e.g. ls <rel>) — assert
# no crash + (bonus) cwd-relative results. Best-effort: the assert is "no throw", not "exact items".
#
# Quoting/escape correctness (the __pi_json_str helper): craft a completion whose word contains a
# space or quote (hard to force via complete -C; instead unit-test __pi_json_str in isolation by
# sourcing the script in a fish subprocess — OR trust the LIVE-VALIDATED helper from research §3,
# which decoded 5466 items cleanly including special chars). v1 accepts the live proof.
```

## Final Validation Checklist

### Technical Validation
- [ ] Level 1: `LOAD_OK`, stylua clean (or informational), selene clean (or informational).
- [ ] Level 2: `shell_fish_driver_smoke.lua` exits 0 (PASS or SKIP); `shell_fish_driver_spec.lua` green.
- [ ] Level 2 regression: `shell_ensure_spec.lua` still green (no module-leak into fakes).
- [ ] Level 3: `/tmp/fish_e2e.lua` prints `E2E_PASS`, exit 0 (real fish.lua through real shell.lua).
- [ ] No new lint/type errors introduced (fish.lua is additive; no existing file touched).

### Feature Validation
- [ ] `start(opts,on_ready)` calls `on_ready(nil,proc,stdin,stdout)` with live handles.
- [ ] Persistence: ≥3 sequential framed requests through ONE daemon all decode.
- [ ] `git ch` → checkout/cherry/cherry-pick (with descriptions) in decoded items.
- [ ] `cd(path)` does not throw; best-effort cwd update observable.
- [ ] Failure paths (bad shell path / startup timeout / proc-dies-pre-ready) → `on_ready(err,nil,nil,nil)`, no leaked handles, never throws.
- [ ] Success Criteria from "What" all met.

### Code Quality Validation
- [ ] Follows existing `lua/pi-bridge/*.lua` conventions (tabs, [Mode A]-style header comment, lazy require, never-throws pcall discipline).
- [ ] File placement matches desired tree (`lua/pi-bridge/shell/fish.lua`).
- [ ] Anti-patterns avoided: no read_start on stdout (shell.lua owns it); no vim.api.* in luv callbacks (fast-context); no module-top require("pi-bridge"); no proc handle leak (proc:close after kill).
- [ ] DAEMON_SCRIPT is the VALIDATED verbatim text (research §3/§4/§5/§6) — NOT the PRD §17.6.1 sketch (which uses broken `--style=json` + NDJSON).

### Documentation & Deployment
- [ ] fish.lua header comment documents: the §17.6.1 sketch divergences (manual JSON, single-object response, simple regex), the stderr-ready-signal rationale, the embedded-quote limitation, and that shell.lua owns teardown/stdout.
- [ ] The fish daemon script is self-commenting (the `#` lines above).
- [ ] No new env vars (PI_NVIM_SHELL etc. are the extension's concern, P2.M1.T1 — already done).

---

## Anti-Patterns to Avoid

- ❌ Don't read_start the stdout pipe in `start()` (two readers on one pipe is illegal in luv; shell.lua owns stdout post-on_ready). Use STDERR for the ready signal.
- ❌ Don't emit per-line NDJSON between sentinels (shell.lua `_feed` LIVE-VERIFIED that NDJSON fails `vim.json.decode` → parse_failure). Emit ONE single-object JSON.
- ❌ Don't use `string escape --style=json` or `printf "%j"` (removed/absent in fish 4.x — LIVE-VERIFIED). Build JSON manually.
- ❌ Don't use the fancy `(?:[^"\\]|\\.)*` regex in the fish script (compile error in fish). Use the simple `[^"]*` regex.
- ❌ Don't `proc:close()`-less after `process_kill` (the uv_process_t LEAKS — F3). Every kill path must close.
- ❌ Don't call `vim.api.*` from the on_exit / timer / stderr-read callbacks (they run in libuv FAST context — E5560). Only luv + state writes there.
- ❌ Don't require("pi-bridge") at module top (async handshake; lazy-require inside functions if ever needed — fish.lua likely needs none).
- ❌ Don't edit shell.lua / completion.lua / any extension file (the seams are already Complete; S1 is purely additive).
- ❌ Don't fail CI when `fish` is absent (gated skip, exit 0 — PRD §17.15).
- ❌ Don't pipe a heredoc into nvim's stdin to run tests (AGENTS.md HARD RULE — it hangs the session). Write the test to a FILE, run via `+"luafile <file>" +qa`.

---

## Confidence Score

**9/10** for one-pass implementation success. Rationale: every non-obvious detail was
LIVE-VERIFIED against fish 4.8.1 and the already-landed shell.lua (the exact `start`/`cd`
contract, the manual-JSON helper, the simple-not-fancy regex, the single-object-not-NDJSON
response, the stderr-ready-signal, the persistence loop, the test/gating conventions). The
one residual risk is the `while read` loop's behavior under `-i`+piped-stdin over MANY
iterations (the spike proved ONE; the smoke Task 4 proves ≥3) — but that is exactly what
the smoke gate validates, and a hang there surfaces as a timeout (bounded by the test's
`timeout 60`), not a silent failure. The embedded-quote extraction limitation is documented
and degrades gracefully (no crash).