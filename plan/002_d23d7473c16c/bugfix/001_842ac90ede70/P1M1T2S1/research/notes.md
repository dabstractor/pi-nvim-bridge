# Research Notes — P1.M1.T2.S1 (Gate §17.4.3 mismatch notice on prefer=="pi")

> Work item: **"Wrap the mismatch notice block in ensure() with a prefer=='pi' gate"**
> (Bug-hunt **Issue 1**, severity Major). Every claim below was verified by reading
> the live source `lua/pi-bridge/shell.lua`, `tests/shell_notices_spec.lua`, and the
> bugfix-plan architecture docs. No external research needed — this is an internal
> Lua call-site gate.

---

## 0. The bug (one paragraph)

`M.ensure()` (shell.lua:379) calls `M.mismatch_target(resolved, vim.env.SHELL)`
**unconditionally** inside the §17.4.3 notice block (shell.lua:399–410).
`mismatch_target` is PURE and **prefer-free** (shell.lua:222–228): it returns the
richer shell basename ("zsh"|"fish") iff `basename(resolved)=="bash"` AND
`basename($SHELL)∈{"zsh","fish"}`. Under `prefer="bash"`, `resolve_shell` returns
`("/bin/bash","default")` (the explicit-bash branch, shell.lua:198–199) REGARDLESS
of the descriptor — so `resolved=="/bin/bash"` and the condition fires whenever
`$SHELL` is zsh/fish, even though the user **deliberately chose bash**. The notice
then tells them to "set pi's shellPath to /usr/bin/zsh" — advice that is (a) misleading
(they asked for bash) and (b) **inert** under `prefer="bash"` (that setting forces bash
regardless of `shellPath`). PRD §17.4.3 scopes the notice to *"`prefer:"pi"` resolves a
shell poorer than `$SHELL`"*; the user docs (`doc/pi-bridge-shell.txt:111-114`) agree.

---

## 1. The exact edit site (content, NOT line number)

The notice block currently reads (shell.lua:395–410, TAB-indented):

```lua
	-- §17.4.3 one-time mismatch notice: prefer:"pi" resolved bash while $SHELL is a richer
	-- zsh/fish on PATH. PURE condition (M.mismatch_target) + the PATH check
	-- (vim.fn.executable, pcall'd). notify.once dedups to once-per-session. Fires here ONLY
	-- on the first spawn (steps 4-8 run once per session — subsequent ensures hit the proc cache).
	pcall(function()
		local richer = M.mismatch_target(resolved, vim.env.SHELL)
		if richer then
			local ok, ex = pcall(vim.fn.executable, richer)
			if ok and ex == 1 then
				require("pi-bridge.notify").once("shell-mismatch", vim.log.levels.WARN,
					"pi-bridge: pi runs commands in bash; using bash completion to match. For your native "
					.. richer .. " completions, set pi's shellPath to " .. (vim.env.SHELL or richer)
					.. " (then completion and execution both use it). :help pi-bridge-shell")
			end
		end
	end)
```

**The fix:** wrap the ENTIRE `pcall(function() ... end)` in
`if (cfg.prefer or "pi") == "pi" then ... end`, and update the 4-line comment to note
the gate. The inner pcall body stays **byte-for-byte identical** (re-indented one TAB).
`cfg` is already in scope (shell.lua:390: `local cfg = (pi.config and pi.config.shell) or {}`),
captured 9 lines above — no new variable needed.

Result:

```lua
	-- §17.4.3 one-time mismatch notice: fires ONLY under prefer=="pi" (the §17.4.3 scope —
	-- explicit prefer="bash"/"/abs/path" deliberately chose bash, so advising "set shellPath
	-- to your native zsh" would be misleading AND is inert under prefer="bash"). Under
	-- prefer=="pi" (or nil): resolved bash while $SHELL is a richer zsh/fish on PATH. PURE
	-- condition (M.mismatch_target, prefer-free) + the PATH check (vim.fn.executable, pcall'd).
	-- notify.once dedups to once-per-session. The shell-active + shell-degrade notices are
	-- OUTSIDE this gate (they always run). Fires only on first spawn (proc cache thereafter).
	if (cfg.prefer or "pi") == "pi" then
		pcall(function()
			local richer = M.mismatch_target(resolved, vim.env.SHELL)
			if richer then
				local ok, ex = pcall(vim.fn.executable, richer)
				if ok and ex == 1 then
					require("pi-bridge.notify").once("shell-mismatch", vim.log.levels.WARN,
						"pi-bridge: pi runs commands in bash; using bash completion to match. For your native "
						.. richer .. " completions, set pi's shellPath to " .. (vim.env.SHELL or richer)
						.. " (then completion and execution both use it). :help pi-bridge-shell")
				end
			end
		end)
	end
```

**Gate semantics** (`(cfg.prefer or "pi") == "pi"`):
| `cfg.prefer` | `cfg.prefer or "pi"` | gate | notice can fire? |
|---|---|---|---|
| `nil` (unset) | `"pi"` | OPEN | YES (default — existing behavior) |
| `"pi"` | `"pi"` | OPEN | YES (existing behavior — REGRESSION case) |
| `"bash"` | `"bash"` | CLOSED | NO (the bug fix) |
| `"/bin/bash"` | `"/bin/bash"` | CLOSED | NO (the bug fix) |
| `"shell"` | `"shell"` | CLOSED | NO (harmless — see §3) |
| `"/abs/path"` (non-bash) | the path | CLOSED | NO (and mismatch_target would return nil anyway since basename≠bash) |

The `or "pi"` default is CRITICAL: it preserves every existing test where
`pi.config.shell` is unset (the whole `shell_notices_spec.lua` suite sets no `prefer`,
relying on the nil→pi default).

---

## 2. Why the gate is at the CALL SITE, not inside `mismatch_target`

`mismatch_target`'s OWN doc-comment (shell.lua:210–214) says: *"SELF-GATING ... NO
explicit prefer check is needed (do NOT double-gate — it risks drifting from
resolve_shell)."* That guidance is about NOT adding a `prefer` PARAMETER to the helper
(keeping it pure + directly unit-testable + deterministic). The contract explicitly
agrees: **"Keep it pure" / "Do NOT modify mismatch_target itself (it stays pure and
prefer-free)."**

The self-gating the doc-comment describes is INSUFFICIENT for the `prefer="bash"` case:
it reasoned "under prefer:'pi' with a descriptor that omits shell (resolve falls through
to $SHELL) resolved==$SHELL → false" — i.e. it only considered the **prefer:"pi"**
fallback path. It did NOT consider `prefer="bash"` (resolve returns `/bin/bash` directly,
DELIBERATELY bypassing the descriptor) or `prefer="/abs/path/to/bash"`. Under those,
`resolved=="/bin/bash"` and `mismatch_target` truthfully returns "zsh"/"fish" — but that
truth is no longer **actionable** (the user chose bash). The call-site gate is the
§17.4.3 SCOPE enforcement: "this notice is only meaningful when prefer=='pi'". So:
**helper stays pure (prefer-free); the caller decides WHEN to consult it.** This is the
clean separation the architecture doc (`shell_resolution_notice.md` §"Issue 1 Fix")
prescribes.

---

## 3. Why closing the gate under `prefer="shell"` is HARMLESS

The gate `(cfg.prefer or "pi") == "pi"` is closed for `prefer="shell"` too (not just
`prefer="bash"`/path). Is that correct? YES — and harmless:
- Under `prefer="shell"`, `resolve_shell` returns `$SHELL` (or `/bin/bash` if `$SHELL`
  unset). If `$SHELL=/bin/zsh` → `resolved=="/bin/zsh"` → `mismatch_target` returns nil
  (basename≠bash). If `$SHELL` is unset → `resolved=="/bin/bash"` but `$SHELL` is nil →
  `mismatch_target` returns nil (env_shell nil). So under `prefer="shell"` the notice
  NEVER fires regardless of the gate. Closing it is a no-op AND matches the §17.4.3
  scope (the notice is ONLY about `prefer:"pi"` resolving bash).
- The bug-hunt Issue 1 names only `prefer="bash"` and `prefer="/path/to/bash"`, but the
  contract's gate expression `(cfg.prefer or "pi") == "pi"` is the precise encoding of
  "the §17.4.3 scope" and is what the architecture doc specifies verbatim.

---

## 4. Parallel-safety with P1.M1.T1.S1 (Issue 5, running NOW)

Issue 5 (the parallel task) edits **disjoint code regions** in the SAME file
(`lua/pi-bridge/shell.lua`):
- Issue 5 touches: `descriptor_shell()` (shell.lua:143–156) + `resolve_shell`'s `"pi"`
  branch (shell.lua:186–188) + the `resolve_shell` doc-comment.
- Issue 1 (THIS task) touches: the notice block (shell.lua:395–410) + its comment.

`grep -nE` confirms the four functions are far apart (143, 179, 222, 395). **Zero
overlap.** The architecture doc (`shell_resolution_notice.md`) confirms: *"T1 and T2
touch DIFFERENT code regions (resolve_shell:168–189 vs notice block:384–396) so they
can be developed in parallel."*

**No behavioral dependency either:** Issue 5 changes `resolve_shell` to return the real
`descriptor.shellSource` as its 2nd return. `ensure()` captures ONLY the 1st return
(`local resolved = M.resolve_shell(...)`). Issue 1's gate keys on `cfg.prefer`, NOT on
`source`. So Issue 1 is fully independent of Issue 5 — order doesn't matter, and a merge
of the two is conflict-free (different lines).

---

## 5. The `cfg` variable is already in scope (no new read)

`ensure()` step (3) (shell.lua:390) already does:
```lua
local pi = require("pi-bridge")
local cfg = (pi.config and pi.config.shell) or {}
```
and step (4) (shell.lua:393) uses `cfg.prefer`:
```lua
local resolved = M.resolve_shell(cfg.prefer or "pi")
```
So the notice block (9 lines below) reuses the SAME `cfg`. No new `require`, no new
local — the gate is a pure boolean check on an existing local. Minimal diff.

---

## 6. Test harness (copy from `tests/shell_notices_spec.lua`)

The spec already defines every helper this task needs (verified by reading the full file):

- `fake_bridge(shell_path)` → `{ get_shell_info = function() return { shell = shell_path } end }`.
  (Under `prefer="bash"`/path, `resolve_shell` ignores the descriptor, so `pi.bridge`
  affects only `pick_driver`'s driver lookup via the resolved basename — still set it for
  realism / to match the existing cases' shape.)
- `make_fake_driver()` → fake driver whose `start` calls cb SYNCHRONOUSLY with fake pipes.
- `inject_for(resolved_shell_path)` → injects the fake driver under
  `package.loaded["pi-bridge.shell."..basename]`. For resolved `/bin/bash` → basename
  `"bash"` → injects `pi-bridge.shell.bash`. **This is REQUIRED** under `prefer="bash"`:
  without it, `pick_driver("/bin/bash")` finds no driver → `state.failed=true` + a
  `shell-degrade` notice (which would muddy the "only mismatch is suppressed" assertion).
- `stub_executable(names_true)` → stubs `vim.fn.executable` (the mismatch PATH check).
  Returns a restore fn.
- `wait_notify(category)` → `vim.wait(200, predicate, 5)` wrapper.
- `before_each`/`after_each` already save/restore `pi.bridge`, `pi.descriptor`,
  `vim.env.SHELL`, `pi.config.shell` (line 99: `orig_shell_cfg = (pi.config and
  pi.config.shell) or nil`; line 117: `if pi.config then pi.config.shell = orig_shell_cfg
  end`), `vim.fn.executable`, and purge `package.loaded["pi-bridge.shell.*"]` for
  fish/bash/zsh/noshell/unknownshell. So setting `pi.config.shell = { prefer = "bash" }`
  per-case is automatically cleaned up — **no new harness code needed**.

**The new test cases** (append to the existing `describe(...)` block, after case (2)/(2b)):

```lua
-- (2c) ISSUE-1: prefer="bash" + resolved=/bin/bash + $SHELL=/bin/zsh → NO mismatch
it("ISSUE-1: prefer='bash' does NOT fire the mismatch notice (user chose bash)", function()
	pi.config.shell = { prefer = "bash" }
	inject_for("/bin/bash")
	pi.bridge = fake_bridge("/bin/bash")
	vim.env.SHELL = "/bin/zsh"
	local restore_exec = stub_executable({ "zsh" })
	shell.ensure(function() end)
	assert.is_false(wait_notify("shell-mismatch"), "mismatch MUST NOT fire under prefer='bash'")
	assert.is_false(notify.did_notify("shell-mismatch"))
	-- SCOPE guard: the gate suppresses ONLY the mismatch notice — active still fires
	assert.is_true(notify.did_notify("shell-active"), "shell-active still fires (gate is scoped)")
	assert.is_false(notify.did_notify("shell-degrade"), "no degrade (healthy bash spawn)")
	restore_exec()
end)

-- (2d) ISSUE-1: prefer="/bin/bash" (explicit path) + $SHELL=/bin/zsh → NO mismatch
it("ISSUE-1: prefer='/bin/bash' (explicit path) does NOT fire the mismatch notice", function()
	pi.config.shell = { prefer = "/bin/bash" }
	inject_for("/bin/bash")
	pi.bridge = fake_bridge("/bin/bash")
	vim.env.SHELL = "/bin/zsh"
	local restore_exec = stub_executable({ "zsh" })
	shell.ensure(function() end)
	assert.is_false(wait_notify("shell-mismatch"), "mismatch MUST NOT fire under explicit prefer='/bin/bash'")
	assert.is_false(notify.did_notify("shell-mismatch"))
	assert.is_true(notify.did_notify("shell-active"), "scope guard: active still fires")
	restore_exec()
end)

-- (2e) ISSUE-1 REGRESSION: prefer="pi" (explicit) + descriptor bash + $SHELL=/bin/zsh → mismatch STILL fires
it("ISSUE-1 regression: prefer='pi' (explicit) STILL fires the mismatch notice", function()
	pi.config.shell = { prefer = "pi" }
	inject_for("/bin/bash")
	pi.bridge = fake_bridge("/bin/bash")
	vim.env.SHELL = "/bin/zsh"
	local restore_exec = stub_executable({ "zsh" })
	shell.ensure(function() end)
	assert.is_true(wait_notify("shell-mismatch"), "mismatch MUST fire under prefer='pi' (regression)")
	assert.is_true(notify.did_notify("shell-mismatch"))
	restore_exec()
end)
```

**Key assertion discipline:**
- For the SUPPRESS cases (2c/2d), assert BOTH `wait_notify("shell-mismatch")` is FALSE
  (it never registered in the dedup set within 200ms) AND `notify.did_notify(...)`
  is FALSE. AND assert `shell-active` is TRUE — this proves the gate is **scoped**
  (only the mismatch notice is gated; the rest of `ensure` runs unchanged). This is the
  contract's "shell-active and shell-degrade notices are UNAFFECTED" guarantee, tested.
- For the REGRESSION case (2e), the assertion is the POSITIVE: mismatch STILL fires.
  Case (2) (the existing implicit-default case) also still passes (prefer unset →
  nil→pi default → gate open) — no edit needed to (2).

**Why `pi.config.shell = { prefer = "bash" }` is safe in this harness:** `before_each`
captures `orig_shell_cfg` BEFORE any case mutates it, and `after_each` restores
`pi.config.shell = orig_shell_cfg`. `pi.config` is guaranteed non-nil (the spec's top
does `if pi.config == nil then pi.setup({}) end`). So the mutation is local to the case.

---

## 7. Validation commands (verified against this repo)

```bash
# Level 1 — parse check (luac if available; else the plenary load covers it). NEVER heredoc→nvim stdin.
luac -p lua/pi-bridge/shell.lua 2>/dev/null && echo "parse OK" || echo "luac unavailable (skip — L2 covers parse)"

# Confirm the edit landed (content grep, NOT line number):
grep -nE 'if \(cfg\.prefer or .pi.\) == .pi. then' lua/pi-bridge/shell.lua   # → 1 hit inside ensure()
grep -nE 'function M\.mismatch_target' lua/pi-bridge/shell.lua                # → unchanged (1 hit, still pure)

# Level 2 — the spec (home of the 3 new cases + all existing notice cases):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_notices_spec.lua")'
# Expected: all `it` PASS, incl. the 3 new (2c/2d/2e) + existing (1)(2)(2b)(3-14).

# Level 3 — regression sweep (ensure + resolve_shell + health; unaffected by this gate):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_ensure_spec.lua")'
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/shell_spec.lua")'
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_notices_smoke.lua" +qa; echo "exit=$?"

# Level 4 — adversarial one-shot repro of the exact bug scenario (prefer="bash"):
cat > /tmp/issue1_check.lua <<'LUA'   -- heredoc→FILE is fine; heredoc→nvim stdin is NOT (AGENTS.md HARD RULE)
local pi = require("pi-bridge"); if pi.config == nil then pi.setup({}) end
pi.config.shell = { prefer = "bash" }
local shell = require("pi-bridge.shell"); local notify = require("pi-bridge.notify")
package.loaded["pi-bridge.shell.bash"] = {
  start = function(opts, cb) cb(nil, {is_closing=function() return false end},
    {read_start=function() end, close=function() end, is_closing=function() return false end},
    {write=function() end, close=function() end, is_closing=function() return false end}) end }
pi.bridge = { get_shell_info = function() return { shell = "/bin/bash" } end, server_info = {} }
vim.env.SHELL = "/bin/zsh"
notify.reset(); shell.reset()
shell.ensure(function() end)
vim.wait(150, function() return false end, 5)  -- flush scheduled notify
print("mismatch_fired=" .. tostring(notify.did_notify("shell-mismatch")))
assert(notify.did_notify("shell-mismatch") == false, "BUG: mismatch fired under prefer='bash'")
print("ISSUE1_OK")
LUA
timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile /tmp/issue1_check.lua" +qa; echo "exit=$?"
# Expected: prints `mismatch_fired=false` then `ISSUE1_OK`, exit=0.
```

Note: `wait_notify` returns the `vim.wait` BOOLEAN (true if predicate became true within
the timeout). For a SUPPRESS case, `wait_notify(...)` is expected FALSE — but
`vim.wait` returns FALSE both on timeout AND if the loop ran the full 200ms without the
predicate. Since the notice never registers, the predicate stays false → returns false
after 200ms. That is the correct "did not fire" signal. (Do NOT shorten the wait for
suppress cases — a too-short wait could falsely report false before a real fire
registers. 200ms matches the harness's existing `wait_notify`.)

---

## 8. Conventions / gotchas recap

- **TABS** for indentation (the whole file is TAB-indented). The re-indented pcall body
  gains ONE leading TAB inside the new `if ... then`.
- **Match edits by CONTENT, not line number** — shell.lua line numbers drift (contract
  says "384-396"; actual is 395-410 today). The `oldText` below is the verbatim current
  block.
- **AGENTS.md HARD RULE**: NEVER pipe a heredoc into `nvim` stdin. Write check Lua to a
  real `.lua` file (`/tmp/*.lua` or `tests/*.lua`), then `:luafile` it, wrapped in
  `timeout`.
- **Do NOT touch `mismatch_target`** (shell.lua:222–228) or its doc-comment — it stays
  pure + prefer-free. The gate is at the CALL SITE only.
- **Do NOT touch the shell-active / shell-degrade notice blocks** — they are OUTSIDE
  this gate (shell-active at step 8b ~shell.lua:464-475; shell-degrade at steps 5/8a/8c
  ~418-422/444-454/476-486). The contract: "The existing shell-active and shell-degrade
  notices are UNAFFECTED."
- **Do NOT widen scope** into Issue 2 (the `prefer:"pi"` consistency-footgun notice),
  Issue 3/4/6 — those are separate tasks (P1.M1.T3, P1.M2.T4/T5/T6). Issue 2 in
  particular is a NEW notice block (`shell-consistency`), not a modification of this one.
- **No user-facing/config/doc-surface change** (Mode A — internal comment only). The
  contract: "No user-facing/config surface change."