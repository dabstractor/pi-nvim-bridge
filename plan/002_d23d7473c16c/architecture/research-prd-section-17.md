# PRD §17 — Shell Completion for `!`/`!!` Bash Mode (Research / Scouting Notes)

Source: `plan/002_d23d7473c16c/prd_snapshot.md` §17 (lines 1119–1849) and §6.8 (lines 498–578).
This is an **additive subsystem of Component B** (`pi-bridge.nvim`). It adds one new Lua module tree (`lua/pi-bridge/shell*`) + one enriched descriptor field. **Component A (extension) changes by exactly three optional descriptor fields.**

## Current repo state (verified, not assumed) — what does NOT exist yet

| Concern | Status now | Where it must change |
|---|---|---|
| `completion_context()` return value | returns `"slash" \| "path" \| nil` (NO `"shell"`) | `lua/pi-bridge/completion.lua:377-401` |
| `BridgeDescriptor` interface | has transport/path/token/pid/cwd/fdAvailable/serverVersion — **no shell fields** | `extension/protocol.ts:83-91` |
| `lua/pi-bridge/shell.lua` + `lua/pi-bridge/shell/` drivers | **does not exist** (grep `lua/pi-bridge` for `shell\|prefer` → 0 matches) | new files |
| `notify.lua` dedup mechanism | **already exists** — `M.once(category, …)` over `seen={}` set, `M.reset()` | `lua/pi-bridge/notify.lua:1-37` (reusable for §17.4.3/§17.6.4/§17.12 one-time notices) |
| `doc/pi-bridge-shell.txt` | does not exist (`doc/` has only `pi-bridge.txt` + `tags`) | new file |

---

## §6.8 Host compatibility divergence table (`prd_snapshot.md:498-578`)

The bridge runs under both **pi** (`@earendil-works/pi-coding-agent`, `pi` binary) and **oh-my-pi** (`omp` binary). Divergences the bridge must tolerate:

| concern | pi | omp |
|---|---|---|
| interactive-mode signal | `ctx.mode === "tui"` | `ctx.hasUI === true` (no `ctx.mode`) |
| manifest discovery key | `"pi": { "extensions": [...] }` | reads `(pkg.omp ?? pkg.pi).extensions` — `pi` works as fallback |
| config / plugin dir | `~/.pi/agent/extensions/` | `~/.omp/plugins/` |
| runtime | Node | Bun |
| install / list CLI | `pi install` / `pi list` | `omp plugin install` / `omp plugin list` |
| extension type imports | `@earendil-works/*` | `@oh-my-pi/*` |

The bridge sidesteps each divergence by construction (manifest ships `pi` key; all `@earendil-works/*` are `import type`-only so Bun/jiti erases them; only Node builtins used, all implemented by Bun; mode gate `isInteractiveSession(ctx)` accepts `ctx.mode === "tui"` OR `ctx.hasUI === true`). The plugin side needs no host change (keys only on `PI_NVIM_BRIDGE` env var).

> Scope note: other pi plugins often break under omp (e.g. omp removed `getShellConfig`-adjacent `getGlobalSettings`). The bridge avoids this by using only the stable API subset.

---

## §17.1 Motivation & scope (`prd_snapshot.md:1131-1154`)

pi's `!` (run bash) / `!!` (run bash, no context) prefixes enter **bash mode** — on submit pi runs `AgentSession.executeBash()` → `createLocalBashOperations()` → `getShellConfig()` (`interactive-mode.ts:2757`, `agent-session.ts:2712`). pi's `CombinedAutocompleteProvider` and the plugin's `completion_context()` both return nothing for `!` lines → **no completion of any kind** for shell commands today.

- **In scope (v1):** single-line `!`/`!!`, completed against fish/zsh/bash (user's choice, default = pi's execution shell), rendered in the existing menu, accepted via **local word-replacement** (shell candidates are plain words, NOT pi `AutocompleteItem`s).
- **Out of scope (v1):** multi-line/continued commands, Windows, shells beyond fish/zsh/bash, completion of surrounding pi prompt semantics (there are none — the whole `!` line is a shell command).

## §17.2 The shell mismatch — the central design constraint (`prd_snapshot.md:1155-1192`)

> Read before anything else in §17 — determines the default and the single user-facing knob.

pi does **not** execute `!`/`!!` in the user's `$SHELL`. `getShellConfig()` (`utils/shell.ts`) resolves to **`/bin/bash -c` by default** (then bash-on-`PATH`, then `sh`), **regardless of `$SHELL`**, unless the user sets pi's `shellPath` setting. So completion shell and execution shell can disagree.

- **Sharp footgun:** a zsh user with a `g=git` alias in `.zshrc` would, if completed against zsh, get `!g <tab>` → git subcommands that **fail at execution** (bash has no `g` alias). Common-command word completion is largely interchangeable; alias/function divergence is real and sharp.

**Resolution (the `prefer` contract):** completion **defaults to pi's resolved execution shell** (`prefer: "pi"`), so completions and execution **always agree**. An unconfigured zsh user therefore gets *bash* completion (tier-2) until they set pi's `shellPath` to zsh — then completion is both rich AND consistent. The default *nudges users toward the config that fixes both quality and correctness*, and emits a one-time educational notice when a richer `$SHELL` is available (§17.4.3).

> Why not default to `$SHELL`? Wrong completions (suggesting a command that errors) are worse than plain completions. `prefer:"pi"` trades richness for correctness by default; the notice makes richness recoverable in one setting change. **This is the single design decision baked into the default.**

## §17.3 Architecture & integration points (`prd_snapshot.md:1193-1229`)

Data flow:
```
ftplugin/pi-prompt.lua (InsertEnter/TextChangedI/CursorMovedI/<Tab>)
  → completion.lua: completion_context() now returns "shell" for a `!` line
       ctx=="shell"  → route to shell.lua (NOT bridge.getSuggestions)
       ctx=="slash"/"path" → existing bridge path (unchanged)
  → shell.lua: resolve shell (§17.4) → spawn/ensure daemon → framed request
       (vim.uv async pipes; debounce + supersession mirror completion.lua)
  → shell/{fish,zsh,bash}.lua: per-shell driver (one persistent subshell)
       fish: complete -C   zsh: capture widget   bash: compgen/COMPREPLY
  → shell/accept.lua: replace current shell word + per-shell quoting
  → menu.lua (UNCHANGED) renders AutocompleteItem[]
```

Four integration seams — all pre-existing; §17 only *extends* `completion_context`:
1. **Routing** — `completion_context()` gains a third return value `"shell"`; `do_refresh`/`force_fetch` branch on it (§17.7). No change to slash/path.
2. **Rendering** — menu module reused unchanged; shell items normalized to the same `AutocompleteItem { value, label, description? }` shape.
3. **Lifecycle** — shell daemon is a child of the **nvim** process (`vim.uv.spawn`), torn down on `VimLeavePre` alongside the existing bridge-client teardown. NOT a child of pi.
4. **Activation gate** — unchanged: dormant unless `PI_NVIM_BRIDGE` is present (only ever runs inside a pi-launched editor).

## §17.4 Shell resolution — the `prefer` contract (default `"pi"`) (`prd_snapshot.md:1230-1285`)

`shell.lua` resolves **one** shell for the session, at first `!` activation, then caches it. Resolution order is governed by `setup({ shell = { prefer = … } })`:

| `prefer` | Resolved shell | Consistency with execution | Default? |
|---|---|---|---|
| `"pi"` | `descriptor.shell` (pi's resolved shell) if advertised; else fall through `"shell"` | **Always consistent** (same shell executes) | **✅ yes** |
| `"shell"` | `$SHELL` | Consistent iff user set `shellPath == $SHELL`; else mismatch (notice) | |
| `"bash"` | `/bin/bash` (or getShellConfig equivalent) | Consistent iff pi's default bash is in use | |
| `"/abs/path"` | that path | Consistent iff `shellPath` matches | |

**Fallback chain when `prefer:"pi"` and the descriptor omits `shell`** (older bridge version, or resolution failed): `descriptor.shell` → `$SHELL` → `/bin/bash`.

### §17.4.1 What `descriptor.shell` contains (`prd_snapshot.md:1246-1264`)

Bridge extension populates a new `BridgeDescriptor` field (§17.10):
```jsonc
{
  "shell": "/bin/zsh",                 // the binary pi will actually invoke for `!`/`!!`
  "shellSource": "pi" | "$SHELL" | "default",  // how it was derived
  "shellPath": "/home/u/.pi/..."       // the raw shellPath setting, if the user set one
}
```
`shellSource`: `"pi"` = from `shellPath` setting; `"default"` = `getShellConfig`'s `/bin/bash`; `"$SHELL"` = extension fell back to `$SHELL`. Because `settingsManager`/`getShellConfig` are NOT on `ExtensionContext`, the extension derives this by replicating `getShellConfig`'s ~10-line resolution (or by reading `process.env.SHELL`) — see §17.10.2.

### §17.4.2 Driver selection (`prd_snapshot.md:1265-1271`)

Resolved shell's **basename** (`zsh`/`fish`/`bash`) selects the driver (`shell/zsh.lua`, `shell/fish.lua`, `shell/bash.lua`). Unknown basename → `shell/unknown.lua` → **silent no-op** (no completion, plain buffer). User may disable a driver explicitly: `setup({ shell = { drivers = { bash = false } } })`.

### §17.4.3 The one-time educational notice (`prd_snapshot.md:1272-1285`)

When `prefer:"pi"` resolves a shell **poorer than the user's `$SHELL`** — specifically: resolved shell is `bash` (tier-2) **AND** `$SHELL` is `zsh`/`fish` (tier-1) **AND** that richer shell exists on `PATH` — emit **one** dedup'd `vim.notify` (reuse `notify.lua`'s existing dedup):

> pi runs commands in **bash**; using bash completion to match. For your native `<SHELL>` completions, set pi's `shellPath` to `<SHELL>` (then completion and execution both use it). `:help pi-bridge-shell`.

Fires at most once per session (dedup'd on a stable key). **Note:** `notify.lua` already provides `M.once(category, …)` over a `seen={}` set — this is the exact mechanism to reuse.

## §17.5 The completion daemon (`prd_snapshot.md:1286-1391`)

Each shell's real completion needs the user's rc + completion library loaded (sourcing `.zshrc`+`compinit`, `.config/fish/config.fish`, or `bash-completion`), costing **100 ms–1 s+**. Per-keystroke spawning is a non-starter. So `shell.lua` owns a **persistent, long-lived completion subshell** for the session lifetime (the fzf-tab / `zsh-capture-completion` pattern).

### §17.5.1 Framing protocol — transport-agnostic sentinels (`prd_snapshot.md:1295-1322`)

Uniform request/response over the daemon's stdin/stdout, with sentinels that isolate responses from shell prompt noise (PS1/prompt segments also write to stdout):

```text
# plugin → daemon stdin  (one line; \t-separated; JSON is the payload)
__PIREQ__\t{"line":"git ch","cursor":6,"after":""}

# daemon → plugin stdout
__PIRESP_START__
{"items":[{"value":"checkout","description":"Checkout and switch to a branch"},…],"prefix":"ch"}
__PIRESP_END__
```

- **`line`** = command text after stripping leading `!`/`!!`, **up to the cursor** (UTF-8; Lua strings are UTF-8 — **no UTF-16 conversion**, unlike §8's pi path). **`cursor` = byte offset into `line` (0-based)**.
- **`after`** (optional) = text after the cursor; drivers that need the full line (zsh's `BUFFER`/`CURSOR`, bash's `COMP_LINE`/`COMP_POINT`) reconstruct it.
- Plugin buffers stdout, slices between `__PIRESP_START__\n` and next `__PIRESP_END__\n`, `vim.json.decode`s the payload. Anything outside sentinels (prompts, async segments, stray output) is **discarded**.
- **Robustness:** the daemon MUST emit `__PIRESP_END__` even on error/empty results (empty `items` array), so the plugin's request-timeout + supersession never hang waiting for a missing sentinel.

### §17.5.2 `shell.lua` reference skeleton (`prd_snapshot.md:1323-1391`)

```lua
-- shell.lua — persistent completion subshell manager.
-- Owns: shell resolution (§17.4), daemon spawn/teardown, framed req/resp,
-- debounce + supersession (MIRRORS completion.lua's two-layer design), item
-- normalization to AutocompleteItem. Does NOT render (menu.lua) or accept
-- (shell/accept.lua). Reads the descriptor + config FRESH at call time.
local M = {}
local uv = vim.uv

local state = { proc=nil, stdin=nil, stdout=nil, rx_buf="",
                gen=0, inflight=false, shell=nil, driver=nil, cwd=nil }

local function pick_driver(resolved_shell)        -- basename → driver module
  local base = resolved_shell:gsub(".*/","")
  local ok, drv = pcall(require, "pi-bridge.shell."..base)
  if ok and drv and type(drv.start)=="function" then return drv end
  return nil                                      -- unknown → degrade (§17.6.4)
end

function M.ensure(on_ready)
  if state.proc then return on_ready(nil) end
  local cfg = require("pi-bridge").config.shell or {}
  local resolved, source = M.resolve_shell(cfg.prefer or "pi")   -- §17.4
  state.shell, state.driver = resolved, pick_driver(resolved)
  if not state.driver then return on_ready("no driver for "..tostring(resolved)) end
  state.driver.start({ shell=resolved, cwd=M.session_cwd(),
    startup_timeout_ms=cfg.startup_timeout_ms or 5000 },
    function(err, proc, stdin, stdout)
      if err then state.driver=nil; return on_ready(err) end
      state.proc, state.stdin, state.stdout = proc, stdin, stdout
      stdout:read_start(function(_, chunk)       -- append + scan for sentinel
        if chunk then M._feed(chunk) else M._reset() end end)   -- EOF → teardown
      on_ready(nil)
    end)
end

-- request(line, cursor, after, cb) — framed request; supersession via gen-guard.
function M.request(line, cursor, after, cb)
  M.ensure(function(err)
    if err then return cb(err) end
    state.gen = state.gen + 1; local gen = state.gen; state.inflight = true
    local payload = vim.json.encode({ line=line, cursor=cursor, after=after or "" })
    state.pending_cb = function(items, prefix)
      if gen ~= state.gen then return end        -- STALE — drop
      state.inflight = false; cb(nil, items, prefix)
    end
    state.stdin:write(string.format("__PIREQ__\t%s\n", payload))
  end)
end
-- _feed(chunk): append to rx_buf; while a __PIRESP_START__/__PIRESP_END__ pair is
--   present, slice it out, vim.json.decode, normalize to AutocompleteItem[], call
--   pending_cb (gen-guarded). Leftover stays in rx_buf. pcall every decode.
-- teardown()/on_exit(): kill proc (uv.process_kill SIGKILL), close pipes, reset state.
return M
```

Key invariants:
- **Supersession mirrors `completion.lua`:** monotonic `state.gen` captured in the response callback; a newer `request()` bumps `gen`, so a late response for a stale keystroke is dropped at the guard. One in-flight request at a time is natural here (shell completion is fast; sentinel protocol is sequential).
- **cwd tracking:** `M.session_cwd()` reads `descriptor.cwd`; if it changed since spawn, the driver re-`cd`s the daemon (each driver exposes a `cd(path)` over the framed channel) so path/relative completions match pi's working directory.
- **Never blocks, never throws:** every `uv` call and decode is `pcall`'d; a daemon error degrades to "no completion this keystroke" and the health check (§17.15) records it.

## §17.6 Per-shell drivers (`prd_snapshot.md:1392-1520`)

Each driver is a Lua module exporting `start(opts, on_ready)` (spawn the shell, source rc/completion, install request handler + sentinel writer) and (optionally) `cd(path)`. Quality tiers are explicit and surfaced in `:checkhealth pi-bridge` (§17.15).

### §17.6.1 fish — Tier 1 (clean win) (`prd_snapshot.md:1399-1434`)

fish exposes `complete -C "<line>"` returning `word⇥description` lines using ALL loaded completions. Verified: `fish -c 'complete -C "git ch"'` → `checkout⇥Checkout and switch to a branch`, etc.

```fish
# fish driver — the daemon's startup script (written to a temp file, sourced via -i)
function __pi_handle
    read -l line                          # we send: __PIREQ__\t{"line":..,"cursor":..}
    set -l js (string replace -r '^__PIREQ__\t' '' -- $line)
    set -l cmd (echo $js | jq -r .line)          # or fish's string ops
    echo __PIRESP_START__
    complete -C "$cmd" | while read -l word desc
        test -n "$desc" \
            and printf '{"value":%s,"description":%s}\n' \
                (string escape --style=json -- $word) (string escape --style=json -- $desc) \
            or printf '{"value":%s}\n' (string escape --style=json -- $word)
    end
    echo __PIRESP_END__
end
function fish_prompt; end        # silence the prompt to reduce noise (sentinel-isolated anyway)
bind \r '__pi_handle; commandline -f repaint'   # each Enter-terminated request triggers it
```
**Parsing (Lua):** split each response line on the first `\t`; left = `value` (+ `label`), right = `description`. Map to `AutocompleteItem`. Current word (for `prefix`) is derivable client-side (last whitespace-delimited token of `line[1..cursor]`), so no extra round-trip.

> Implementation note: the exact plumbing to drive an interactive fish from stdin without its line editor interfering is fiddly; `fish --noconfig` is **wrong** here (we WANT the user's config). The spike (§17.16 step 1) nails the precise invocation; sentinel framing makes the prompt-noise question moot.

### §17.6.2 zsh — Tier 1 (capture-completion) (`prd_snapshot.md:1435-1473`)

zsh has no `compgen`. Canonical technique (fzf's zsh completion + `Valodim/zsh-capture-completion`): a **persistent interactive zsh** with a bound zle widget that programmatically drives the completion system and dumps the candidates.

```zsh
# zsh driver — daemon startup script (sourced by `zsh -f -i`; -f avoids double-sourcing,
# we explicitly autoload compinit + the user's comp dump)
autoload -Uz compinit && compinit -u          # load completions (use -C cached dump if fast)

__pi_capture() {                               # the widget; bound below
  local out
  # _main_complete is zsh's completion entrypoint; it populates global arrays.
  # We redirect its compadd calls by redefining compadd to collect into stdout.
  compadd() {
    local desc=""
    [[ "$1" == "-d" ]] && { desc="$2"; shift 2 }
    local w; for w in "$@"; do printf '%s\t%s\n' "$w" "$desc"; done
  }
  # caller sets BUFFER/CURSOR via the framed request before invoking the widget
  zle complete-word                            # drive the system; our compadd captures
  print __PIRESP_END__                         # sentinel (start emitted before the call)
}
zle -N __pi_capture
# request loop: read __PIREQ__ lines from stdin, set BUFFER/CURSOR, trigger the widget
```
Driver writes each request by feeding a line that sets `BUFFER`/`CURSOR` and triggers `__pi_capture`; the widget's redefined `compadd` collects `word⇥desc` pairs emitted between sentinels. **This is the most fragile driver** — the exact zle incantation varies subtly across zsh versions; the spike (§17.16 step 4) must validate against the user's installed zsh, and `:checkhealth` reports the detected zsh version. Descriptions come through `_describe`/`compadd -d`. Parsing identical to fish.

### §17.6.3 bash — Tier 2 (best-effort) (`prd_snapshot.md:1474-1512`)

`compgen` returns **bare words, no descriptions**, and a bare `bash -c` does NOT source the user's completion library. The driver sources bash-completion best-effort and invokes the registered completion function for the command word:

```bash
# bash driver — daemon startup (bash --rcfile <this> -i)
[ -f /usr/local/etc/bash_completion ] && . /usr/local/etc/bash_completion
[ -f /etc/bash_completion ] && . /etc/bash_completion
__pi_complete() {
  local line="$1" point="$2"                    # line=up-to-cursor, point=byte offset
  COMP_LINE="$line"; COMP_POINT="$point"
  read -ra COMP_WORDS <<< "${line}"
  local i cword=0 cum=0
  for ((i=0;i<${#COMP_WORDS[@]};i++)); do
    cum=$((cum+${#COMP_WORDS[i]}+1)); (( cum>=point )) && { cword=$i; break; }
  done
  COMP_CWORD=$cword; local cur="${COMP_WORDS[cword]}" cmd="${COMP_WORDS[0]}"
  COMPREPLY=()
  local spec; spec=$(complete -p "$cmd" 2>/dev/null) || spec=""
  if [[ "$spec" == *-F* ]]; then
    local fn; fn=$(sed -n 's/.*-F \([^ ]*\).*/\1/p' <<< "$spec")
    "$fn" "$cmd" "$cur" "${COMP_WORDS[cword-1]}"
  else
    COMPREPLY=( $(compgen -f -d -- "$cur") )    # default: files+dirs
  fi
  local w; for w in "${COMPREPLY[@]}"; do printf '{"value":%s}\n' \
    "$(printf '%s' "$w" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')"; done
}
# request loop reads __PIREQ__\t{...} lines, calls __pi_complete, wraps in sentinels
```
**Limitations (documented, surfaced in `:checkhealth`):** no descriptions; quality depends entirely on whether bash-completion is installed and the per-command completion file is sourced; fragile across bash versions. Files/dirs always work (`compgen -f -d`). **Opt-out via `drivers.bash = false`.**

### §17.6.4 unknown shells — degrade (`prd_snapshot.md:1513-1520`)

Basename not in `{fish,zsh,bash}` → `shell/unknown.lua` (or nil driver) → `shell.request` short-circuits to `cb("no driver")`, `completion.lua` treats it as a null result (empty items → menu closes), and a single `vim.notify` fires once: "Shell completion not supported for `<shell>`; degraded to no completion." **Never blocks, never throws.**

## §17.7 Routing in the plugin (`completion.lua` extension) (`prd_snapshot.md:1521-1561`)

`completion_context()` gains a `"shell"` return value. The check is precise and unambiguous (mirrors pi's own `text.trimStart().startsWith("!")`):

```lua
-- in completion_context(lines, cursorLine, cursorCol):
-- NEW (before the existing slash/path checks): bash mode is line 1 starting with `!`.
local line1 = (lines or {})[1] or ""
if cursorLine == 0 and line1:sub(1,1) == "!" then return "shell" end
```

- **Line 1 only:** pi's bash mode triggers on the submitted prompt's first character; completion is scoped to the first line (multi-line continued commands are future, §17.17).
- **`!` vs `!!`:** irrelevant to routing — both go to `"shell"`; the bangs are stripped by `shell.lua` before querying (strip 2 if `line1` starts with `!!`, else 1).

`do_refresh` and `force_fetch` gain one branch each:

```lua
if ctx == "shell" then
  require("pi-bridge.shell").complete_current(buf, function(err, items, prefix)
    if gen ~= state.gen then return end          -- supersession (same gen-guard as getSuggestions)
    if err then return end                       -- silent degrade (notify dedup'd elsewhere)
    state.last_result = { items = items or {}, prefix = prefix or "" }
    if type(M.on_results)=="function" then pcall(M.on_results, buf, items or {}, prefix or "") end
  end)
  return
end
-- …existing slash/path bridge path unchanged…
```

`shell.complete_current(buf, cb)` reads buffer + cursor, strips bangs, computes `line`/`cursor`/`after`, calls `shell.request(...)`. The debounce window for `"shell"` context is **0 ms** (shell completion is interactive-grade; daemon warm after first use; per-shell engine is fast). The `<Tab>`-closed path (`force_fetch`) forces an immediate fetch in `"shell"` context, mirroring the existing file-force behavior.

> Note: the existing `completion_context` (verified at `lua/pi-bridge/completion.lua:377-401`) returns `"slash" | "path" | nil` and uses `token`/`token_start` logic. The new `"shell"` early-return must be inserted **before** those checks, gated on `cursorLine == 0 and line1:sub(1,1) == "!"`.

## §17.8 Local acceptance & quoting (NOT pi's `applyCompletion`) (`prd_snapshot.md:1562-1597`)

Shell candidates are **plain words**, not pi `AutocompleteItem`s — pi's `applyCompletion` (trailing space for files, no space for dirs, `@`-mention quoting, `/cmd ` spacing) does NOT apply. The shell path uses its **own** accept in `shell/accept.lua`:

1. **Compute the current shell word:** maximal substring of `line[1..cursor]` ending at the cursor, delimited by unquoted whitespace. (Shell tokenization is subtle — the daemon could optionally return the word's start byte offset; v1 approximates client-side with a quote-aware splitter. `\`-continuations are v1-out.)
2. **Quote the candidate** if it contains chars special to the resolved shell (spaces, and shell metacharacters `$ \ ` " ' < > | & ; ( ) ~` for bash/zsh; fish has lighter rules). Use the resolved shell's quoting convention:
   - **fish:** auto-quotes on `complete -C` expansion; still wrap paths with spaces in double quotes.
   - **bash/zsh:** single-quote unless the candidate contains a single quote (then use the `'…'"'"'…'` idiom) — the robust general choice.
3. **Replace** bytes `[word_start+1 .. cursor]` (Lua 1-indexed) with the quoted candidate, via **`nvim_buf_set_text`** (range edit, not whole-buffer rewrite — shell mode edits only the current word, unlike pi-mode's wholesale `nvim_buf_set_lines`).
4. **Position** the cursor immediately after the inserted text. Stay in Insert mode.
5. **Re-trigger** a completion fetch only if the candidate is a directory (ends in `/`) — mirrors shells' behavior of expanding a dir and continuing; otherwise close the menu.

> **Why `nvim_buf_set_text`, not `nvim_buf_set_lines`:** pi-mode accepts rewrite the *whole* buffer (pi returns the complete new lines[]). Shell-mode accepts rewrite a *word range*. `nvim_buf_set_text(buf, row, start_col, row, end_col, {text})` is the precise API for a range edit; like `set_lines`, it does **NOT** fire `TextChangedI` for typed-input semantics (`:help`), so no re-entrancy loop.

## §17.9 Trigger & UX parity with the TUI (`prd_snapshot.md:1598-1613`)

- **Menu keys unchanged.** `<C-N>/<C-P>/<Up>/<Down>` navigate, `<C-E>` dismisses, `<Tab>`/`<C-Y>`/`<CR>` accept — identical to pi-mode. `<CR>` accepts (if menu open) else inserts a newline (no Enter-to-submit; quitting submits — same as §7.4).
- **Bash-mode visual cue (optional, on by default):** when `ctx=="shell"`, the menu shows a `$` gutter prefix on each item (or a distinct border color from `theme.bashMode`). Mirrors pi's TUI border recoloring on `isBashMode`. Configurable: `setup({ shell = { visual_cue = "gutter" | "border" | "off" } })`.
- **First-run hint:** the first time a `!` line is detected in a session, emit a one-time hint (dedup'd): "Shell completion active (`<resolved shell>`); `:help pi-bridge-shell`." Suppressed if the daemon failed (the degrade notice fires instead).

## §17.10 Bridge descriptor extension — the ONLY Component A change (`prd_snapshot.md:1614-1671`)

### §17.10.1 `BridgeDescriptor` (extension/protocol.ts) (`prd_snapshot.md:1616-1639`)

Add three optional fields (all JSON-serializable; absent on older clients is fine — plugin falls back to `$SHELL`):

```ts
export interface BridgeDescriptor {
  transport: "unix";
  path: string;
  token: string;
  pid: number;
  cwd: string;
  fdAvailable: boolean;
  serverVersion: string;
  // NEW (§17.10) — the shell pi will execute `!`/`!!` commands in, so the
  // plugin's completion can match it (prefer:"pi"). All optional for back-compat.
  shell?: string;        // "/bin/zsh" — the resolved execution shell binary
  shellSource?: "pi" | "$SHELL" | "default";  // how it was derived
  shellPath?: string;    // the raw `shellPath` setting, if the user set one
}
```
The `hello` result mirrors these (it already carries `cwd`/`fdAvailable`).

> Current state (verified at `extension/protocol.ts:83-91`): the interface has NO shell fields yet. Also note `HelloResult` (protocol.ts ~98-103) and `PingResult` carry `cwd`/`fdAvailable`/`serverVersion` — they may need the shell fields mirrored too if §17.10.1 says "the `hello` result mirrors these."

### §17.10.2 Resolution in the extension — why it can't call `getShellConfig` (`prd_snapshot.md:1640-1671`)

`settingsManager`/`getShellConfig()` are **NOT on `ExtensionContext`**, so the extension cannot read pi's resolved shell through the public API. It derives `shell`/`shellSource` by replicating `getShellConfig`'s tiny resolution (`utils/shell.ts`), reading the same inputs pi uses:

```ts
function resolveShell(): { shell: string; shellSource: "pi" | "$SHELL" | "default"; shellPath?: string } {
  // pi's settings.shellPath is not on ctx; the extension CANNOT read it directly.
  // Two viable strategies (pick in the spike; §17.16 step 5):
  //  (a) Honor a bridge-local mirror of the setting via a documented env var the
  //      user sets once: process.env.PI_NVIM_SHELL (absolute path). If set → "pi".
  //  (b) Else fall back to process.env.SHELL ("$SHELL") if present.
  //  (c) Else "/bin/bash" (pi's getShellConfig default on Unix) → "default".
  const explicit = process.env.PI_NVIM_SHELL;
  if (explicit) return { shell: explicit, shellSource: "pi", shellPath: explicit };
  const sh = process.env.SHELL;
  if (sh) return { shell: sh, shellSource: "$SHELL" };
  return { shell: "/bin/bash", shellSource: "default" };
}
```

> **Honesty note:** this is the ONE place §17 reaches past pi's public extension API. The replication is small and stable (mirrors a ~10-line function), and the descriptor fields are **advisory** — the plugin works correctly even if they are absent (falls back to `$SHELL`). If the mismatch footgun or this replication bites real users, §17.17 proposes a tiny upstream `ctx.getShellConfig()`. Setting pi's `shellPath` to `$SHELL` today already makes `prefer:"pi"` resolve correctly *without* any of this, because the user has aligned the two.

## §17.11 Configuration (`prd_snapshot.md:1672-1691`)

```lua
require("pi-bridge").setup({
  shell = {
    enabled           = true,                 -- master switch (false → `!` lines get no completion)
    prefer            = "pi",                 -- "pi" | "shell" | "bash" | "/abs/path"  (§17.4)
    drivers           = { fish = true, zsh = true, bash = true },
    warm_on_enter     = false,                -- spawn daemon at VimEnter (trades memory for first-`!` latency)
    timeout_ms        = 1500,                 -- per-request budget (shell completion)
    startup_timeout_ms= 5000,                 -- daemon cold-start (rc load) budget
    visual_cue        = "gutter",             -- "gutter" | "border" | "off"  (§17.9)
    debounce_ms       = 0,                    -- 0 = immediate (daemon warm); raise if a shell is slow
  },
})
```
`rpc_timeout_ms` (the bridge's, §10.5) is **unaffected** — shell completion does NOT use the bridge socket.

## §17.12 Failure modes & degradation (`prd_snapshot.md:1692-1711`)

- **Daemon spawn failure** (shell missing, rc error, startup timeout) → silent degrade to a plain buffer + **one** `vim.notify` (`notify.lua` dedup). Never blocks editor startup; menu simply never opens for `!` lines.
- **Per-request timeout** (slow completion, runaway `compinit`) → abort + drop (gen-guard), leave menu as-is or close. Never blocks the cursor.
- **Capture fragility (zsh/bash)** — a shell-version quirk breaks the widget → daemon's response fails the sentinel/parse check → treated as empty; **after N consecutive parse failures the daemon is killed and marked unhealthy** (`:checkhealth` reports it), and shell completion is disabled for the session.
- **Unsupported/unknown shell** → §17.6.4 degrade.
- **EOF on the daemon pipe** (shell crashed mid-session) → `M._reset()`, mark unhealthy, one notify; subsequent `!` lines get no completion (**no auto-respawn in v1** — document; a future enhancement may respawn).
- **Quoting edge cases** (candidate with embedded single quote + space) → `shell/accept.lua`'s quote helper is table-tested (§17.15); on any parse failure it inserts the raw value unquoted and notifies once (never leaves the buffer inconsistent).

## §17.13 Security (`prd_snapshot.md:1712-1726`)

- The completion daemon **sources the user's rc files** (`~/.zshrc`, `~/.config/fish/config.fish`, `~/.bashrc` + bash-completion) → it **executes user-authored code**. This is the **same trust model** pi already operates under (pi executes arbitrary user `!` commands, including aliases/functions from those same rc files). Document it prominently in `:help pi-bridge-shell`.
- The daemon is a **child of the nvim editor process**, not of pi, and is **NOT network-exposed** (local pipes only). The existing socket/token security boundary (§12) is untouched — shell completion never touches the bridge socket.
- **No secrets in completions:** the daemon runs the user's own completion functions, which may read env vars; that is the user's own code. The plugin does NOT log completion payloads (which could contain expanded secrets) beyond the existing `/tmp/pi-bridge-…` debug log, which is opt-in and local.

## §17.14 Coordinate & encoding notes (shell path) (`prd_snapshot.md:1727-1741`)

Unlike pi-mode (§8), the shell path does **NOT** use pi's UTF-16 cursor contract:
- The daemon works in **plain bytes / characters** (Lua strings are UTF-8; shells are UTF-8-aware). `cursor` sent in the request is a **byte offset** into the UTF-8 `line` — directly from `vim.fn.col(".")` semantics (**no `coords.lua` conversion needed** for the shell path).
- **Accept** uses `nvim_buf_set_text` with **byte** column offsets (Lua 0-based via the API), again no UTF-16 conversion.
- Astral-plane characters (emoji) in a shell command are rare; if present, byte offsets are still correct for the shell and for `nvim_buf_set_text` (which is byte-indexed). No approximation needed here (contrast §8's pi-path caveat).

## §17.15 Testing strategy (shell-specific) (`prd_snapshot.md:1742-1775`)

Plenary tests under `tests/shell/`:
- **`shell_fish_spec.lua`** — golden parsing of `complete -C` output: normal `word⇥desc`, description-less `word`, empty result, multiline (N items), a value containing a literal tab (escaped). Uses a fixture string (no live fish needed for the parser; a live-fish integration test is gated on `fish` being on `PATH`).
- **`shell_zsh_spec.lua`** — spin up a headless `zsh -f -i` with the capture widget sourced, send `git ch`, assert `checkout`/`cherry`/`cherry-pick` appear. Gated on `zsh` on `PATH`.
- **`shell_bash_spec.lua`** — assert `compgen`-based file completion for `!ls /tm` → `/tmp/`; assert a command with a registered compspec (e.g. `git`) yields subcommands *iff* bash-completion is present (skip otherwise).
- **`shell_accept_spec.lua`** — table tests for quoting: spaces (`my file.txt`), `$`, backtick, single quote, double quote, combined; per shell; assert the inserted byte range and cursor position.
- **`shell_daemon_spec.lua`** — lifecycle: spawn → 3 sequential requests → teardown (no leaked `uv` handles via `vim.uv.loop():gc_collect()` / handle-count assert); cold-start-timeout path; EOF-on-pipe → unhealthy; N consecutive-parse-failures → disabled.
- **`shell_routing_spec.lua`** — `completion_context` returns `"shell"` iff line 1 starts with `!`/`!!`; returns the existing values otherwise (regression guard).
- **`:checkhealth pi-bridge` shell section** — reports resolved shell, source, driver detected, daemon health, last error; live-spawns each available shell's driver for a 1-shot smoke.

**CI:** fish/zsh live tests run only on runners with those shells (most Linux runners have both); bash tests run everywhere. Mark shell-dependent tests `pending`/`skip` when the binary is absent (**never fail CI for a missing optional shell**).

## §17.16 Implementation phasing — Phase 6 (appends to §13) (`prd_snapshot.md:1776-1798`)

> **Phase 6 — Shell completion (bash mode).**
> 21. **Spike (prove the seam):** a 30-line `shell.lua` that spawns `fish -i`, sends `complete -C "git ch"` framed, parses `word⇥desc`, prints to `:messages` inside a pi-prompt buffer. ✔ Gate → proceed.
> 22. `shell.lua` daemon manager: resolution (`prefer:"pi"`), spawn/teardown, framed protocol, gen-guard supersession, item normalization.
> 23. `shell/fish.lua` driver + `notify` of the `prefer:"pi"` mismatch (§17.4.3).
> 24. `completion.lua` routing extension (`completion_context` → `"shell"`) + `do_refresh`/`force_fetch` shell branch.
> 25. `shell/accept.lua` local word-replacement + per-shell quoting; `nvim_buf_set_text`.
> 26. Bridge descriptor `shell`/`shellSource`/`shellPath` (`protocol.ts` + `connection.ts` descriptor builder); `bridge.lua` exposes them on the client.
> 27. `shell/zsh.lua` capture-completion driver (port + validate against the installed zsh).
> 28. `:checkhealth pi-bridge` shell section; `doc/pi-bridge-shell.txt`; README.
> 29. `shell/bash.lua` best-effort driver (last; lowest priority).

## §17.17 Future enhancements (appends to §15) (`prd_snapshot.md:1799-1817`)

- **Upstream `ctx.getShellConfig()`** — tiny public-API addition letting the extension read pi's *actual* resolved shell deterministically (eliminating the §17.10.2 replication and the advisory-only descriptor). Propose only if the mismatch/replication bites real users.
- **nu / elvish drivers** — each has its own completion protocol; add as demand appears.
- **Multi-line / continued commands** — complete across `\`-continued lines (drive the shell with the full logical line).
- **Piped commands** — `!foo | bar<tab>` completing `bar`'s context (the shell already does this if given the full line; wire the `after`-cursor text through).
- **Reuse the daemon for `@file` mentions** — route pi's `@file` path completion through the shell too, for `~`/glob expansion parity with the user's shell.
- **Daemon respawn** on EOF (v1 disables shell completion for the session after a crash; a respawn-with-backoff would recover).

## §17.18 Key pi source locations (shell/completion) (`prd_snapshot.md:1818-1847`)

All under `~/projects/pi`:

| Concern | Path |
|---|---|
| `!`/`!!` detection → bash mode | `packages/coding-agent/src/modes/interactive/interactive-mode.ts:2583` (`isBashMode`), `:2757` (`text.startsWith("!")`) |
| Bash command handler | `interactive-mode.ts:5893` (`handleBashCommand`) |
| Execution → shell config | `packages/coding-agent/src/core/agent-session.ts:2712` (`executeBash` → `createLocalBashOperations({ shellPath })`) |
| Shell resolution | `packages/coding-agent/src/utils/shell.ts` — `getShellConfig()` (defaults `/bin/bash`; honors `customShellPath`) |
| `shellPath` / `shellCommandPrefix` settings | `packages/coding-agent/src/core/settings-manager.ts:878` / `:910` |
| Keybinding hints (`!`/`!!`) | `interactive-mode.ts:745-746` |
| (No shell completion exists) | `packages/tui/src/autocomplete.ts` — `CombinedAutocompleteProvider` handles slash + path only |

---

## Start Here (for the implementing agent)

1. **`lua/pi-bridge/completion.lua:377-401`** — the `completion_context()` function. This is the single routing seam: insert the early-return `if cursorLine == 0 and line1:sub(1,1) == "!" then return "shell" end` before the slash/path checks, then add the `ctx == "shell"` branch in `do_refresh`/`force_fetch` (§17.7).
2. **`extension/protocol.ts:83-91`** — `BridgeDescriptor`. Add the three optional `shell?`/`shellSource?`/`shellPath?` fields (§17.10.1); also check whether `HelloResult`/`PingResult` (~protocol.ts:98-122) need mirroring.
3. **`extension/connection.ts`** — the descriptor builder (§17.16 step 26); wire `resolveShell()` (§17.10.2) into it.
4. **`lua/pi-bridge/notify.lua:1-37`** — already provides `M.once(category, …)` dedup; reuse for ALL one-time notices (§17.4.3 mismatch, §17.6.4 unknown-shell, §17.9 first-run hint, §17.12 failure modes). Add new categories.
5. **New files:** `lua/pi-bridge/shell.lua` (daemon manager, §17.5.2), `lua/pi-bridge/shell/{fish,zsh,bash,unknown,accept}.lua`, `doc/pi-bridge-shell.txt`, and `tests/shell/*_spec.lua`.
6. **Phase-6 ordering is in §17.16 steps 21–29** — the fish spike (step 21) is the ✔ gate before the rest.

## Residual risks / open questions

- **§17.10.2 honesty gap:** the extension cannot read pi's real `shellPath` setting (`settingsManager` not on `ExtensionContext`). The descriptor `shell` field is **advisory**; `prefer:"pi"` only resolves perfectly if the user aligns `shellPath == $SHELL` OR sets `PI_NVIM_SHELL`. Mitigation: the §17.4.3 notice. Risk: a user with `shellPath=/bin/zsh` but no `PI_NVIM_SHELL` env var gets `$SHELL`-derived completion, which may mismatch. Low severity (the notice + user-set `shellPath=$SHELL` recovers), but worth surfacing to the user.
- **zsh capture-completion fragility (§17.6.2):** explicitly flagged "the most fragile driver" — the zle widget incantation varies across zsh versions. The spike (step 27) MUST validate against the user's installed zsh; `:checkhealth` reports the detected version.
- **`PI_NVIM_SHELL` is an UNDOCUMENTED new env var** (§17.10.2 strategy a) — needs `:help pi-bridge-shell` documentation and a decision on whether to ship it at all vs. rely on `$SHELL` fallback only. This is a product decision (open question for the supervisor if it bites).
- **fish interactive-from-stdin plumbing (§17.6.1):** flagged "fiddly" — the precise invocation to drive an interactive fish without its line editor interfering is unproven until the spike (step 1/23). `fish --noconfig` is explicitly wrong (we want the user's config).
- **No auto-respawn in v1 (§17.12):** a mid-session daemon crash disables shell completion for the rest of the session. Acceptable for v1; respawn-with-backoff is §17.17 future.