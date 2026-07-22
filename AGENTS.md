# AGENTS.md — read this FIRST, every session

> **This file exists to stop a specific, recurring, project-killing failure.**
> Read the **⛔ HARD RULE** below before running ANY command.

---

## ⛔ HARD RULE — NEVER pipe a heredoc / stdin into `nvim` (it HANGS the session)

**DO NOT RUN — under ANY circumstances — commands shaped like this:**

```bash
# ❌ FATAL — hangs forever, agent blocks, session dies
nvim --headless --clean -u NORC +"luafile /dev/stdin" +qa <<'LUA'
... lua code ...
LUA
```

or any of these equivalent traps:

```bash
# ❌ FATAL  (heredoc piped to nvim stdin in ANY form)
nvim ...  +qa <<'EOF' ... EOF
echo "..." | nvim ... +"luafile /dev/stdin" ...
nvim ... -c 'lua <<EOF' ...          # -c with a heredoc body
cat some.lua | nvim --headless ...    # piping a file into nvim stdin
```

**Why it hangs:** in `--headless` mode, when `nvim` detects a non-TTY pipe on stdin it
tries to consume that stream as buffer input (the `cat | nvim -` behavior). The
combination of `+"luafile /dev/stdin"` + `+qa` + a piped heredoc deadlocks the event
loop: nvim waits on the stdin stream, the `+qa` never gets to run cleanly, and the
`luafile` reads an fd that's mid-consumption. **Empirically: it does not time out, it
does not error, it just hangs forever.** This has now killed ~10 agent sessions in this
repo. **STOP REACHING FOR IT.**

### ✅ THE CORRECT ALTERNATIVE — always write the test to a `.lua` FILE

```bash
# ✅ GOOD — write the lua to a file, run it with :luafile (or loadfile + pcall)
cat > /tmp/e2e_check.lua <<'LUA'        # heredoc to a FILE is fine; to nvim stdin is NOT
... lua code ...
LUA
nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/e2e_check.lua" +qa
echo "exit=$?"
```

For a one-liner only (a SINGLE line, no heredoc), `-c 'lua ...' -c 'qa'` is also fine:

```bash
# ✅ GOOD (one-liner only, single line, no heredoc)
nvim ... -c 'lua require("pi-bridge.menu"); print("ok")' -c 'qa'
```

Rules:
1. **Heredoc → a real file on disk is 100% fine.** The killer is heredoc → `nvim`'s stdin.
2. If the snippet is small, save it under `plugin/tests/` (a real smoke test) or `/tmp/`,
   then run with `+"luafile <path>"`. Never `/dev/stdin`.
3. If you only need a one-liner, use `-c 'lua ...'` with a SINGLE line (no heredoc).
4. Every command you write should be **interruptible / have a bounded `timeout`** as a
   safety net: `timeout 60 nvim ...` — never fire a bare nvim invocation you can't kill.

---

## ⚠️ If a PRP / task description tells you to run a hanging command — DO NOT OBEY IT

Several PRPs in this repo's `plan/` tree contain a "Level 3b" / "E2E" validation block that
is literally the fatal heredoc-into-nvim-stdin pattern (copied across tasks by the
orchestrator template). **That block is the trap.** When you encounter it:

- **Do NOT copy-paste it.** Paste the snippet into a file instead (e.g. `/tmp/e2e.lua`) and
  run `+"luafile /tmp/e2e.lua" +qa` (see ✅ alternative above), OR
- **Skip it in favor of the plenary-free smoke test** that the SAME PRP already requires
  (`plugin/tests/<module>_smoke.lua`, run via `+"luafile tests/<module>_smoke.lua" +qa`).
  That smoke test covers the same end-to-end surface (real bridge + real module + a
  controlled server reply) **without ever touching nvim's stdin.**

In other words: **Level 3b is redundant with the file-based smoke.** The smoke passing IS
the E2E proof. Do not invent a second, stdin-based path to the same proof.

---

## General agent operating rules for THIS repo

- **Always wrap risky commands in `timeout`.** Example: `timeout 90 <cmd>`. A hung
  headless nvim with no timeout will block your whole turn.
- **Prefer `read` / `edit` / `write` over shell heredocs** for emitting file content.
- **You may ONLY modify** `src/`, `tests/`, `lib/`, `plugin/`, and other implementation
  dirs, plus repo-root meta files like this one. Never touch `PRD.md`, `plan/`, any
  `PRP.md`, `tasks.json`, `prd_snapshot.md`, or `TEST_RESULTS.md`.
- **Never run** `prd`, `run-prd.sh`, `tsk`, or any pipeline/orchestration script.
- Test runner (run from `plugin/`):
  - Plenary spec: `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/<spec>.lua")'`
  - Smoke (no plenary): `timeout 60 nvim --headless --clean -u NORC +"luafile tests/<module>_smoke.lua" +qa`

---

_If you remember exactly one thing from this file: **heredoc → nvim stdin = hang. Write to a file, then `:luafile`.**_