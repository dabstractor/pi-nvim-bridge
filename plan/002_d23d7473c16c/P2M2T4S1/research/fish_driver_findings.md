# P2.M2.T4.S1 — fish.lua driver: validated research findings

All findings below were **LIVE-VERIFIED** against `fish 4.8.1` (`/usr/bin/fish`) on this
machine, and against the already-landed `lua/pi-bridge/shell.lua` (P2.M1.T2 + P2.M2.T3,
Complete) and its existing test fakes. These are the non-obvious, would-bite-an-
implementer facts the PRP encodes.

## 1. The binding driver contract (from shell.lua + existing test fakes)

`shell.lua` `M.ensure` calls `state.driver.start(opts, cb)` where the `cb` it passes is
`function(err, proc, stdin, stdout)` (shell.lua:696-712). The real `fish.lua` MUST match
this EXACTLY (the existing specs/smokes inject fakes with this shape into
`package.loaded["pi-bridge.shell.fish"]`):

- `M.start(opts, on_ready)` — `opts = { shell, cwd, startup_timeout_ms }` (cwd may be nil;
  startup_timeout_ms default 5000). On success call `on_ready(nil, proc_handle, stdin_pipe,
  stdout_pipe)`. On failure call `on_ready(err_string, nil, nil, nil)`.
- `proc` MUST be the `uv_process_t` handle (shell.lua teardown does
  `uv.process_kill(proc,"sigkill")` + `proc:close()` on it).
- `stdin`/`stdout` MUST be `uv_pipe_t` (shell.lua wires `stdout:read_start` → `_feed`
  and writes `state.stdin:write(frame, cb)`).
- **The driver OWNS stderr** — shell.lua stores only proc/stdin/stdout and
  `close_handles` does NOT close stderr (`"Does NOT close stderr — shell.lua never stores
  it (the driver owns it)"`, shell.lua). The driver must close its stderr pipe on exit.
- **The driver OWNS the startup_timeout_ms cold-start timer** (`"startup_timeout_ms passed
  THROUGH — the driver owns the cold-start timer"`, shell.lua).
- `M.cd(path)` — optional; re-cd the daemon over the framed channel (architecture
  research note §17.5.2: "each driver exposes a cd(path) over the framed channel").
  Best-effort / pcall'd; cwd rarely changes mid-session (pi's cwd is fixed per session).

## 2. The response format MUST be single-object JSON (NOT NDJSON)

shell.lua `_feed` does `pcall(vim.json.decode, payload)` on the ENTIRE body between
`__PIRESP_START__\n` and `__PIRESP_END__\n` (shell.lua ~L600). LIVE-VERIFIED comment:
"P2.M2.T4 / P2.M3.T5 drivers → MUST emit the §17.5.1 single-object format
`__PIRESP_START__\n{"items":[...],"prefix":"..."}\n__PIRESP_END__\n`, NOT the §17.6.x
per-item NDJSON sketch (NDJSON fails to decode — LIVE-VERIFIED)."

So the fish DAEMON SCRIPT (not Lua) must build ONE JSON object per request.

## 3. fish 4.x has NO JSON support (PRD §17.6.1 sketch is OUTDATED)

PROBED:
- `string escape --style=json -- "x"` → `"string escape: Invalid escape style 'json'"`
  (only `script|var|url|regex` exist in fish 4.x). The PRD §17.6.1 sketch uses this —
  BROKEN on modern fish.
- `printf "%j" "x"` → `"%j\: invalid conversion specification"` (no JSON printf).

→ The fish script must build JSON MANUALLY. VALIDATED helper (produces decodable JSON):

```fish
function __pi_json_str
    set -l s "$argv"
    set -l s (string replace --all '\\' '\\\\' -- $s)   # backslash FIRST
    set -l s (string replace --all '"'  '\\"'  -- $s)
    set -l s (string replace --all \n '\\n' -- $s)
    set -l s (string replace --all \r '\\r' -- $s)
    set -l s (string replace --all \t '\\t' -- $s)
    printf '"%s"' "$s"
end
```

Full daemon script validated end-to-end: `printf '__PIREQ__\t{"line":"git ch",...}\n' |
fish -i --init-command="source /tmp/fish_daemon_probe.fish"` → body between sentinels
decoded as `{"items":[{value:"checkout",description:"..."},...]}` (json.loads OK).

## 4. The `.line` extraction regex (jq-free; spike-validated, fancy PCRE FAILS)

- SIMPLE `"line":"([^"]*)"` → group 2 = `git ch` → `complete -C "git ch"` returns
  checkout/cherry/cherry-pick. ✅ VALIDATED.
- FANCY `"line":"((?:[^"\\]|\\.)*)"` → `string match: Regular expression compile error:
  missing terminating ] for character class`. ❌ BROKEN in fish.

→ Use the SIMPLE regex. **Known limitation (document):** a command line containing a
literal `"` (e.g. `!echo "hel`) breaks extraction → cmd resolves empty → `complete -C ""`
returns all commands (degraded, not a crash; gen-guard + menu handle it gracefully). A
true JSON-string regex is infeasible in fish without a JSON parser; v1 accepts this edge.

## 5. `complete -C` output shape + robust item split

- `complete -C "git ch"` → `word⇥description` lines (bare `word` when no description).
- fish `read -l word desc` (spike) splits on IFS; WRONG if a completion WORD contains a
  space (filenames can). ROBUST split: `string replace -r '\t.*$' '' -- $raw` (word) +
  `string replace -r '^[^\t]*\t' '' -- $raw` (desc) — splits on the FIRST tab only.

## 6. Persistent daemon loop (the spike did ONE request; production loops)

The spike called `__pi_handle` once. Production is a PERSISTENT daemon (shell.lua keeps
the proc for the session). The script needs a read loop after config sourcing:

```fish
function __pi_handle  # takes $argv[1] = the __PIREQ__ line (loop does the read)
    ...
end
function fish_prompt; end
while read -l line
    __pi_handle $line
end
```

## 7. Cold-start readiness signal (honors startup_timeout_ms cleanly)

Config sourcing (100ms-1s+) is the cold-start cost. To detect "ready" WITHOUT contending
with shell.lua's `stdout:read_start` (two readers on one pipe is illegal in luv), emit the
ready marker on **STDERR** (fd 2): `printf '__PIREADY__\n' >&2` after config sourcing.

The driver reads the **stderr** pipe for `__PIREADY__`, then read_stop stderr + on_ready.
stdout stays pristine for shell.lua → no read_start handoff. fish supports `>&2`. Validated
fish redirection is standard.

## 8. Terminal noise from `fish -i` is filtered by `_feed` sentinel slicing

`fish -i` emits color escape sequences (`\]4;0;#...`) at startup. PROBED: these appear
OUTSIDE the `__PIRESP_START__..__PIRESP_END__` window → `_feed`'s plain `find(START)` +
`find(END)` slicing discards them. The JSON payload between sentinels was clean + decoded.
So `fish -i --init-command="source <file>"` (spike invocation) is correct; do NOT add
noise-suppression flags.

## 9. Test conventions (from existing shell_*_spec/_smoke.lua)

- Plenary spec (Level 2): `tests/<name>_spec.lua` via
  `nvim --headless -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/<spec>")'`.
- Plenary-free smoke (Level 1): `tests/<name>_smoke.lua` via
  `nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/<smoke>" +qa`.
- Drivers injected as fakes into `package.loaded["pi-bridge.shell.fish"]`; the REAL
  fish.lua MUST satisfy the same `start(opts,cb)` / `cd(path)` interface.
- LIVE fish tests GATED on `vim.fn.executable("fish")==1`; **skip (exit 0, never fail)**
  when absent (PRD §17.15). fish 4.8.1 is present in THIS env → live tests run here.
- `M._test_*` helpers exist in shell.lua for state inspection (gen/inflight/pending_cb) —
  the fish driver is tested via shell.lua's existing seams, NOT new ones in fish.lua.

## 10. Scope fence (this task = S1 ONLY)

- **IN (S1):** the fish DAEMON SCRIPT (startup + `__pi_handle` + `__pi_json_str` +
  ready marker + read loop), the Lua `start(opts, on_ready)` (write script→temp file,
  spawn, stderr ready-detect, startup timer, on_ready), `cd(path)` (framed `__PICD__`).
- **OUT (S2, next):** prefix derivation refinement (complete_current may override prefix
  from the buffer). S1's script emits `"prefix":""` (shell.lua `_feed` reads
  `decoded.prefix`; the consumer complete_current already exists).
- **OUT (S3/S4):** `accept.lua` (shell-word computation + quoting + nvim_buf_set_text).
- **OUT (P2.M3.T5):** zsh.lua / bash.lua / unknown degrade.
- shell.lua's `_feed` already does AutocompleteItem normalization (normalize_item) — S1's
  script emits `{value,description?}` raw items and `_feed` normalizes. No Lua-side
  normalization needed in fish.lua.