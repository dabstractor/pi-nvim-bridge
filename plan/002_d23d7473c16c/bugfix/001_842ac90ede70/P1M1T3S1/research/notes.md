# P1.M1.T3.S1 Research Notes — Issue 2: prefer="pi" consistency footgun detection + notice + docs

## 0. Task contract (verbatim, from item_description)

- INPUT: `source` (resolve_shell 2nd return; T1.S1 made it accurate), `cfg.prefer`
  (`pi.config.shell.prefer`), `vim.env.SHELL`, the module-local `basename()` helper
  (shell.lua:86-89), `require("pi-bridge.notify").once`.
- LOGIC: in `M.ensure()`, AFTER the existing mismatch notice block (T2.S1 wraps it in
  `if (cfg.prefer or "pi") == "pi"`) and BEFORE `pick_driver`, capture BOTH return values:
  change `local resolved = M.resolve_shell(...)` → `local resolved, source = ...`. Add a
  new pcall'd block: `if (cfg.prefer or "pi")=="pi" and source=="$SHELL" then env_base =
  basename(vim.env.SHELL or ""); if env_base=="zsh"|"fish" then pcall executable(env_base);
  if on-PATH then notify.once("shell-consistency", WARN, msg)`.
- DISTINCT category "shell-consistency" (NOT "shell-mismatch") so dedup sets don't conflate.
- OUTPUT: default zsh/fish user (no PI_NVIM_SHELL) gets ONE WARN guiding PI_NVIM_SHELL.
- DOCS [Mode A]: doc/pi-bridge-shell.txt §3 'THE MISMATCH' (lines 74-119): (a) paragraph on
  the default-case footgun, (b) document PI_NVIM_SHELL as the opt-in fix, (c) forward-contract
  note re ctx.getShellConfig() (PRD §17.17).

## 1. Prerequisite status (CONFIRMED by reading source)

- **T1.S1 (Issue 5) = COMPLETE + LANDED.** Verified in shell.lua:
  - `descriptor_shell()` returns BOTH: `return si.shell, si.shellSource` (line 149) and
    `return desc.shell, desc.shellSource` (line 154).
  - `resolve_shell("pi")` propagates: `if ds then return ds, dsrc or "pi" end` (line 188).
  - So `source` is now ACCURATE: `"$SHELL"` when the descriptor fell back to $SHELL;
    `"pi"` when PI_NVIM_SHELL was set (or older bridge w/ no shellSource → `or "pi"`).
- **T2.S1 (Issue 1) = IN-FLIGHT (parallel).** Its PRP wraps the mismatch pcall block in
  `if (cfg.prefer or "pi") == "pi" then ... end` + appends 3 cases to shell_notices_spec.lua
  after case (2b). It does NOT touch: line 393, the step-(4) comment, `pick_driver`, or
  `fake_bridge`. → DISJOINT edit regions, zero conflict, zero behavioral dependency
  (this task keys on `source`; T2.S1 keys on `cfg.prefer`).

## 2. resolve_shell call sites (CONFIRMED line-393 change is isolated)

grep -rnE 'resolve_shell' → the ONLY call inside `ensure()` is shell.lua:393:
  `local resolved = M.resolve_shell(cfg.prefer or "pi")`
Other callers ALREADY consume the 2nd return (source) or ignore it harmlessly:
  - health.lua:256 `pcall(function() resolved, source = shell_mod.resolve_shell(prefer) end)`
  - tests/shell_smoke.lua, shell_spec.lua: `local s, src = shell.resolve_shell(...)` (already 2-value)
Changing line 393 to `local resolved, source = ...` is a pure local-var addition — no other
caller is affected. `state.shell = resolved` (394) stays a single-value read.

## 3. source flow per prefer (proves the gate semantics for each test case)

| prefer | descriptor | source (resolve_shell 2nd ret) | consistency gate result |
|--------|-----------|--------------------------------|-------------------------|
| "pi"/nil | shell from $SHELL fallback | **"$SHELL"** | gate OPEN → fires (the footgun) ✓ |
| "pi"/nil | shell from PI_NVIM_SHELL | "pi" | gate CLOSED (source≠$SHELL) → no fire ✓ |
| "pi"/nil | descriptor omits shell → /bin/bash | "default" | CLOSED ✓ |
| "shell" | (bypassed — takes $SHELL branch) | "$SHELL" | CLOSED via prefer gate ✓ |
| "bash" | (bypassed) | "default" | CLOSED via prefer gate ✓ |
| "/path" | (bypassed) | "config" | CLOSED via prefer gate ✓ |

KEY: BOTH conditions are required — `(cfg.prefer or "pi")=="pi" AND source=="$SHELL"`.
Case (c) (prefer="shell", source="$SHELL") is the one that proves the `prefer=="pi"` half
is mandatory (without it, a prefer="shell" user would get a spurious notice — they already
chose $SHELL, consistency is their responsibility).

## 4. The detection block — exact placement + code

Placement: AFTER the (T2.S1-wrapped) mismatch block's closing `end` (~line 410) and BEFORE
the `-- (5) Pick the driver` comment (line 411). The block uses the module-local `basename()`
(defined line 86; already used by mismatch_target/pick_driver) and the EXACT same
pcall+executable+notify.once idiom as the mismatch block.

```lua
	-- §17 default-case consistency footgun (Issue 2): under prefer=="pi", when the descriptor
	-- fell back to $SHELL (source=="$SHELL") AND $SHELL is zsh/fish, the COMPLETION shell
	-- (zsh/fish via $SHELL) may NOT match pi's EXECUTION shell (bash — the §17.10.2 limit: the
	-- extension cannot read pi's shellPath, so the $SHELL fallback is the best signal). This is
	-- the ONE case where prefer=="pi" silently delivers INCONSISTENT completions. notify.once
	-- with a DISTINCT "shell-consistency" category (so dedup does NOT conflate with
	-- "shell-mismatch" above). pcall'd + PATH-checked (mirrors the mismatch block). First-spawn.
	if (cfg.prefer or "pi") == "pi" and source == "$SHELL" then
		local env_base = basename(vim.env.SHELL or "")
		if env_base == "zsh" or env_base == "fish" then
			pcall(function()
				local ok, ex = pcall(vim.fn.executable, env_base)
				if ok and ex == 1 then
					require("pi-bridge.notify").once("shell-consistency", vim.log.levels.WARN,
						"pi-bridge: completions use " .. env_base
						.. " (from $SHELL) but pi may execute commands in bash. "
						.. "For guaranteed consistency set PI_NVIM_SHELL=" .. (vim.env.SHELL or env_base)
						.. " (or pi's shellPath). :help pi-bridge-shell")
				end
			end)
		end
	end
```

## 5. fake_bridge extension (backward-compatible, parallel-safe)

Current `fake_bridge(shell_path)` returns `{ get_shell_info = function() return { shell = shell_path } end, server_info = {} }`.
Add OPTIONAL 2nd param `shell_source`:
```lua
local function fake_bridge(shell_path, shell_source)
	return {
		get_shell_info = function()
			if shell_path == nil then return nil end
			return { shell = shell_path, shellSource = shell_source }
		end,
		server_info = {},
	}
end
```
- All EXISTING callers pass 1 arg → shellSource=nil → descriptor_shell returns (path, nil) →
  resolve_shell returns (path, `nil or "pi"`) = (path, "pi"). Same invariant as pre-T1.S1.
- New callers: `fake_bridge("/bin/zsh", "$SHELL")` / `fake_bridge("/bin/zsh", "pi")`.
- test_conventions.md ALREADY documents this exact extension for Issue-5 tests
  ("return { shell = shell_path, shellSource = shell_source or "pi" }").
- T2.S1 does NOT modify fake_bridge (its PRP: "reuse the file's existing helpers verbatim").
  → no conflict with the in-flight task.

## 6. The 3 test cases (mapping to contract a/b/c)

All reuse existing harness (fake_bridge / inject_for / stub_executable / wait_notify +
before_each/after_each which save/restore pi.config.shell, pi.bridge, vim.env.SHELL,
vim.fn.executable + purge package.loaded[.shell.*]).

- (2f) = contract (a): prefer="pi", get_shell_info={shell="/bin/zsh", shellSource="$SHELL"},
  $SHELL=/bin/zsh, executable("zsh")→1 → did_notify("shell-consistency") TRUE; mismatch FALSE
  (resolved=zsh≠bash); active TRUE (healthy zsh spawn). ALSO message-spy (Style B, mirrors
  case 2b): assert msg contains "zsh" + "bash" + "PI_NVIM_SHELL=/bin/zsh" + level WARN +
  title "pi-bridge".
- (2g) = contract (b): prefer="pi", get_shell_info={shell="/bin/zsh", shellSource="pi"}
  (user set PI_NVIM_SHELL) → did_notify("shell-consistency") FALSE (no false positive);
  active TRUE.
- (2h) = contract (c): prefer="shell", $SHELL=/bin/zsh → did_notify("shell-consistency")
  FALSE (the prefer=="pi" gate excludes prefer="shell"); active TRUE.

NOTE on (2f)/(2g)/(2h): each MUST `inject_for("/bin/zsh")` so pick_driver("/bin/zsh") finds
the fake driver → healthy spawn → shell-active fires + NO shell-degrade (else the no-driver
degrade path muddies the scope assertion). under prefer="shell", descriptor_shell is NOT
consulted (resolve takes the $SHELL branch directly), so the fake_bridge value is irrelevant
for (2h) — but pass it anyway for shape parity.

## 7. Doc edit (§3, lines 74-119) — insertion point + content

§3 structure: "THE MISMATCH ~" (line 80) → "THE FIX (pick one) ~" (line 89) → "THE ONE-TIME
NOTICE ~" (line ~110). Insert a NEW subsection "THE DEFAULT-CASE CONSISTENCY GAP" BETWEEN the
"THE MISMATCH" paragraph (ends ~line 88) and "THE FIX (pick one) ~" (line 89).

Content covers contract (a)/(b)/(c): the footgun (completions=$SHELL, exec=bash), the
PI_NVIM_SHELL opt-in fix (read FIRST by resolveShell.ts, sets shellSource="pi"), + the
forward-contract note (ctx.getShellConfig PRD §17.17 closes it upstream).

OUT OF SCOPE (mention, don't edit): doc line 200 (§5 config table "(always consistent with
what will actually run)") + line 367 (§10 FAQ) make the same default-consistency claim. The
contract scopes the doc edit to §3 (74-119). Leave 200/367 as-is to avoid undocumented
doc sprawl — the §3 subsection is the authoritative treatment.

## 8. notify API (CONFIRMED)

- `notify.once(category, level, msg)`: dedups by `category` (a string key in `seen` set);
  sets `seen[category]=true` SYNCHRONOUSLY, then `vim.schedule`s the toast.
- `notify.did_notify(category)`: returns `seen[category]==true` (synchronous — no wait needed
  after the once() call returned, but the toast flush needs vim.wait).
- `notify.reset()`: clears `seen`.
- "shell-consistency" is a FRESH category (grep-confirmed: zero refs in lua/tests/doc).

## 9. Validation commands (VERIFIED — match test_conventions.md)

Plenary:
  `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_notices_spec.lua")'`
Smoke:
  `timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_notices_smoke.lua" +qa; echo "exit=$?"`
Regression sweep: shell_ensure_spec.lua, shell_spec.lua, health_spec.lua, shell_smoke.lua
(all consume resolve_shell; must stay green — this task adds a 2nd-return capture at 1 site +
a NEW block, it does NOT change resolve_shell/mismatch_target/pick_driver).

## 10. Parallel-safety matrix

| task | edits shell.lua? | edits shell_notices_spec.lua? | region | conflict w/ T3.S1? |
|------|------------------|------------------------------|--------|---------------------|
| T1.S1 (DONE) | descriptor_shell + resolve_shell "pi" branch | shell_spec/health | lines 143-188 | NONE (landed; T3 consumes its output) |
| T2.S1 (in-flight) | wraps mismatch pcall (395-410) in if/end | appends 3 cases after (2b) | lines 395-410 | NONE (T3 inserts AFTER 410's `end`; T3 changes line 393 + the step-4 comment — disjoint) |
| T3.S1 (this) | line 393 + new block (410-411) + step-4 comment | fake_bridge + 3 cases (2f/2g/2h) | lines 393, 410-411 | — |

T2.S1 does NOT touch fake_bridge → T3.S1's fake_bridge extension is conflict-free.
T2.S1's 3 cases insert after (2b); T3.S1's 3 cases insert after (2e) [T2.S1's last] or grouped
near the mismatch cases. To AVOID any textual overlap, T3.S1 should insert its 3 cases AFTER
T2.S1's (2e) case (which itself is after (2b)) — i.e. after the last mismatch case, before (3).
Even if both land in any order, the cases are independent `it(...)` blocks; plenary runs them
all. The only true merge risk is the fake_bridge signature line — T2.S1's PRP explicitly leaves
it untouched.