# Research notes — P2.M1.T2.S1: Fish spike (framed round-trip validation)

**Status: SEAM PROVEN LIVE (end-to-end).** This spike's riskiest unknowns — "can a non-TTY
parent drive an *interactive* `fish` over piped stdio, and can `vim.uv.spawn` feed it framed
requests + parse sentinel-framed responses?" — were **validated by direct experiment** on this
machine (`/usr/bin/fish`, fish 4.8.1). The full round-trip works; the gate
(`checkout`/`cherry`/`cherry-pick` present) PASSES. The PRP ships a reference implementation
derived from the passing test.

---

## 1. The risk this spike retires (why it exists)

PRD §17.6.1 + architecture/research-prd-section-17.md both explicitly flag the fish driver as
**"fiddly" / "unproven until the spike"**:

> "The exact plumbing to drive an interactive fish from stdin without its line editor
> interfering is fiddly; a non-interactive `fish --noconfig` is *wrong* here — we WANT the
> user's config. The spike (§17.16 step 1) nails the precise invocation." (research-prd-section-17.md:229)

PRD §17.16 step 21 makes the spike the **✔ gate** before the rest of P2.M1.T2 (`shell.lua`).
So: prove the seam with a ~30-line standalone script; proceed to the module only if
`checkout`+`cherry` appear.

## 2. Live experiments performed (this session)

### 2a. Fish-side seam: `fish -i --init-command` + piped stdin + sentinel framing

```
$ printf '__PIREQ__\t{"line":"git ch","cursor":6,"after":""}\n' \
  | fish -i --init-command="source /tmp/drive_fish_test.fish"
]4;0;#1B1A1C\]4;1;#E82424\...   <-- user config.fish terminal-setup OSC/SGR noise
__PIRESP_START__
checkout	Checkout and switch to a branch
cherry	Find commits yet to be applied to upstream
cherry-pick	Reapply a commit on another branch
__PIRESP_END__
exit=0
```
**Findings:**
- `fish -i --init-command="source <path.fish>"` runs the user's `config.fish` **then** the
  init-command (so `__pi_handle` is defined before the interactive loop), then reads commands
  from the piped stdin. **No "no TTY" fatal error.** The user's config emits a burst of OSC/SGR
  escape sequences to stdout at startup — **this is exactly why PRD §17.5.1 mandates sentinel
  framing**: anything outside `__PIRESP_START__`/`__PIRESP_END__` is discarded. The noise is harmless.
- The fish handler is jq-free: `string replace -r '^__PIREQ__\t'` strips the prefix, then
  `string match -r '"line":"([^"]*)"' -- "$payload")[2]` extracts the `.line` field (fish returns
  the whole match at `[1]` and capture groups at `[2]`). fish has **no builtin JSON parser**; this
  string-match is sufficient for the spike's single-field payload (PRD §17.6.1 shows `jq` as an
  alternative, but `jq` is NOT guaranteed on PATH — pure-string parsing is the robust call here).

### 2b. luv-side seam: `vim.uv.spawn` + 3 pipes + sentinel parse + gate (PASS)

Wrote a full Lua spike to `/tmp/luv_spawn_test2.lua`, ran via `+"luafile" +qa` (AGENTS.md-compliant).
**Verbatim result:**
```
[wait] done=true waited=true
[items] count=3
  checkout  =>  Checkout and switch to a branch
  cherry  =>  Find commits yet to be applied to upstream
  cherry-pick  =>  Reapply a commit on another branch
[GATE] checkout present=true
[GATE] cherry present=true
[GATE] cherry-pick present=true
exit=0
```
**This is the reference implementation** the PRP ships (cleaned to match `tests/bridge_smoke.lua`
conventions: `check`/`fails`/`SMOKE-style` footer, graceful skip if `fish` missing, `pcall` every uv call).

## 3. Canonical doc URLs (verified HTTP 200, 2025-07-31)

| Doc | URL | Why for the spike |
|---|---|---|
| `complete` builtin | https://fishshell.com/docs/current/cmds/complete.html | the `-C`/`--command-line` **query** form returns `word⇥description` lines — the whole point |
| `read` builtin | https://fishshell.com/docs/current/cmds/read.html | `read -l line` reads one stdin line into a var (the request loop) |
| `string` builtin | https://fishshell.com/docs/current/cmds/string.html | `string match -r`/`replace -r` — jq-free JSON field extraction |
| `fish` invocation | https://fishshell.com/docs/current/cmds/fish.html | `-i` (interactive, loads config+completions), `--init-command=CODE` (runs AFTER config.fish) |
| fish language/startup | https://fishshell.com/docs/current/language.html | startup sequence (config.fish → `--init-command` → interactive loop) |
| luv API | https://github.com/luvit/luv/blob/master/docs.md | `uv.new_pipe` / `uv.spawn` (`stdio` array) / `pipe:read_start` / `pipe:write` / `uv.process_kill` / `pipe:close` |
| Neovim `vim.uv` | https://neovim.io/doc/user/luvref.html | `vim.uv` is the builtin luv — available in `--headless --clean -u NORC` (no plugin) |

**The two `-C` overloads (DON'T confuse):**
- `complete -C "<line>"` → the **completion query** (what the daemon runs; returns word⇥desc). ✔
- `fish -C "code"` / `--init-command` → the **init-command** flag (run at startup). We use the long
  form `--init-command=` in spawn args to avoid any ambiguity with `complete -C` in the script.

## 4. Design decisions (locked, with rationale)

1. **Invocation: `fish -i --init-command="source <tmp>.fish"`, NOT `fish -c` / `--noconfig`.**
   `-i` loads the user's `config.fish` + completion library (PRD §17.6.1: we WANT the user's config
   so their aliases/completions work). `--init-command` runs AFTER config.fish so `__pi_handle`
   exists when the loop starts. `--noconfig` is explicitly wrong (loads nothing). Verified §2a.
2. **Startup script → temp file, sourced via `--init-command` (NOT inlined as one `-c` arg).**
   Multi-line fish syntax is awkward as a single `--init-command` string; writing it to
   `os.tmpname()` and `source`-ing it is the daemon pattern PRD §17.6.1 specifies ("the daemon's
   startup script (written to a temp file, sourced via -i)"). The real fish.lua driver (P2.M2.T4.S1)
   does the same; the spike mirrors it.
3. **jq-free JSON parse in fish (`string match -r`).** jq is not guaranteed on PATH. The spike's
   payload is a single `"line"` field; a regex capture suffices. (The real driver can keep this or
   upgrade to jq if detected — out of scope for the spike.)
4. **Sentinel framing is the transport-isolation layer.** Stdout carries config-time escape noise
   (OSC/SGR color sequences). The plugin buffers, slices `[__PIRESP_START__\n .. __PIRESP_END__]`,
   discards everything else. Verified harmless in §2a/§2b.
5. **Placement: `tests/shell_fish_spike.lua` (NOT `/tmp/shell_spike.lua`).** Matches the repo's
   `tests/*_smoke.lua` convention (same `check`/`fails`/footer, same `+"luafile" +qa` run shape as
   `tests/bridge_smoke.lua`). Re-runnable as a Phase-6 regression smoke once the real fish driver
   lands. `/tmp/` is acceptable per the contract but forfeits the convention + re-run value.
6. **`vim.api.nvim_echo` for the `:messages` requirement + stdout verdict for the gate.** In headless
   mode there's no `:messages` *display*, but `nvim_echo` records to the message history (satisfies
   the literal contract). The `SPIKE_PASS`/`SPIKE_SKIP` stdout line is the parseable gate signal for
   the harness/CI (mirrors `SMOKE_PASS`).
7. **Graceful skip if `fish` not on PATH (exit 0).** PRD §17.15: "never fail CI for a missing optional
   shell." `vim.fn.executable("fish")==0` → print `SPIKE_SKIP`, return (exit 0 via `+qa`). On this
   dev machine fish IS present, so the gate runs.
8. **`pcall` EVERY uv call + `vim.wait` timeout safety net.** PRD §17.5.2: "never blocks, never
   throws." `vim.wait(10000, done, 20)` bounds the wait; the teardown kills+closes all handles
   regardless of outcome. AGENTS.md: every risky nvim/uv command under `timeout` at the shell level too.

## 5. Gotchas (verified or high-confidence)

- **G1 — EOF signal.** `stdout:read_start`'s cb receives `data == nil` on EOF (NOT an error). Treat
  `err==nil and data==nil` as "stream closed" → finalize. (Do NOT error on it.)
- **G2 — pcall everything.** `uv.spawn`, `pipe:read_start`, `pipe:write`, `uv.process_kill`,
  `pipe:close` can each throw on a bad handle (e.g. double-close). Wrap each in `pcall`.
- **G3 — fish exits on its own after one read, BUT kill anyway.** After `__pi_handle` reads one line
  and returns, fish's interactive loop re-reads stdin, hits EOF, and exits. The `vim.wait` will see
  `done` (sentinel parsed) before that. Kill+close at the end is deterministic cleanup (handles leak
  otherwise — the real `shell.lua` teardown does the same).
- **G4 — the OSC/SGR startup noise.** A `fish_prompt; end` no-op reduces (not eliminates) prompt
  noise; sentinels handle the rest. Do NOT try to suppress the config's color setup — it's harmless.
- **G5 — `string match -r` capture indexing.** `(string match -r '"line":"([^"]*)"' -- $p)[2]` —
  index `[1]` is the whole match, `[2]` is group 1. (fish lists are 1-based.) Verified §2b.
- **G6 — no lua linter in this repo.** The spike's "type" surface is nil; validation = run it and
  read `SPIKE_PASS`/exit 0. (Consistent with every other smoke in `tests/`.)
- **G7 — AGENTS.md HARD RULE.** Run via `+"luafile tests/shell_fish_spike.lua" +qa`. NEVER pipe a
  heredoc into nvim's stdin (it hangs the session). The spike IS a file on disk; this is the safe path.

## 6. Scope fence (what the spike is NOT)

- It does NOT build `shell.lua` (P2.M1.T2.S2–S6), the fish **driver** module (P2.M2.T4.S1–S2),
  `accept.lua`, routing, or the descriptor wiring. It is a **throwaway/keep proof**.
- It does ONE round-trip (the gate is a single `complete -C "git ch"`). The real driver needs a
  request loop (`while read` / re-bind) — out of scope; the spike proves the loop's primitives work.
- It does NOT touch `lua/pi-bridge/*` (no `shell.lua` is created here), `extension/*`, `completion.lua`,
  or any docs. New file is `tests/shell_fish_spike.lua` ONLY.
- It does NOT depend on the (parallel, in-flight) P2.M1.T1.S4 `bridge.get_shell_info()` accessor —
  the spike resolves the shell via the literal `/usr/bin/fish` path the contract pins. The real
  `shell.lua` (S2) will use `get_shell_info()`; the spike doesn't need it.

## 7. Verification command (the exact gate)

```bash
# from repo root — AGENTS.md-compliant (file-based :luafile, timeout-bounded):
timeout 30 nvim --headless --clean -u NORC +"luafile tests/shell_fish_spike.lua" +qa
echo "exit=$?"   # 0 = SPIKE_PASS (gate met); on a fish-less box: SPIKE_SKIP, exit 0
```
Expected stdout tail (this machine): `SPIKE_PASS: fish framed round-trip proven (checkout+cherry present)`.