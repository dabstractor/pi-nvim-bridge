name: "P2.M7.T20.S33 — Tab handler (shouldTriggerFileCompletion + force getSuggestions)"
description: |

# Goal

**Feature Goal**: Implement `completion.on_tab(buf)` — the THIRD and final insert-mode keymap
handler of P2.M7 (after S30 `refresh` + S32 `accept`/`on_enter`) — so that pressing `<Tab>` in a
pi-prompt buffer behaves **byte-for-byte identically to pi's TUI Tab**. Concretely: Tab with the
menu open accepts the selected item; Tab with the menu closed replicates pi's `handleTabCompletion`
(slash-command `force:false` fetch when on a bare `/cmd` at line 0; otherwise consult
`shouldTriggerFileCompletion` over the bridge and, if true, issue an immediate `force:true`
`getSuggestions`, with pi's single-item auto-apply on the file-force path).

**Deliverable**: One additive function `M.on_tab(buf)` (+ two small private helpers
`force_fetch` / `_route_or_accept`) and one backward-compatible change to `M.accept` (an optional
`prefix_override` arg) in `plugin/lua/pi-editor/completion.lua`; an additive `describe("on_tab", …)`
block in `plugin/tests/completion_spec.lua`; a new plenary-free
`plugin/tests/completion_tab_smoke.lua`. The ftplugin (S22) ALREADY dispatches `<Tab>` →
`completion.on_tab(buf)` — S33 makes the function exist + return the right truthy/falsy so Tab is
consumed (or falls through to indent) exactly as pi intends.

**Success Definition**: `on_tab(buf)` (a) accepts the selected item when the menu is open (reuses
the S32 `accept` core — the menu-open branch issues `applyCompletion` + replaces the buffer +
closes the menu); (b) when the menu is closed, replicates pi's `handleTabCompletion` exactly:
the slash-command branch (`cursorLine==0` + bare `/cmd` no-space) issues an immediate
`force:false` `getSuggestions` (no `shouldTriggerFileCompletion` call); the file-force branch
calls `shouldTriggerFileCompletion` (RPC) and, iff `true`, issues an immediate `force:true`
`getSuggestions`; the file-force path with EXACTLY one result applies it immediately via
`accept(item, suggestions.prefix)` (pi's single-item auto-apply) instead of showing the menu;
(c) routes multi-item results through the SAME `completion.on_results` → `menu.on_results` seam
S30/S31 use (empty→close, non-empty→open); (d) returns `true` (Tab consumed) when it acts and
`false` (Tab → indent fall-through) on bad args / disconnected bridge; (e) never throws; (f) all
prior specs stay green; (g) the new smoke prints `SMOKE_PASS`.

## User Persona (if applicable)

**Target User**: A pi user editing their prompt in the Neovim instance pi launches as `$EDITOR`
(Ctrl+G / `app.editor.external`). They expect `<Tab>` to behave like pi's TUI: complete a slash
command, force file/path completion, or accept a highlighted item.

**Use Case**: The user is mid-prompt. They type `/mo` and the menu offers `/model`; Tab accepts
it. Or they type `./src/com` and press Tab to force pi's fuzzy `@file`/path completion (the same
`fd`-scored, gitignore-aware logic pi uses), because no menu auto-appeared at that position. Or
the forced file search yields a single match and Tab inserts it outright (pi's auto-apply).

**User Journey**: (1) pi opens nvim on the temp prompt file (env `PI_NVIM_BRIDGE` set). (2) The
plugin activates + attaches the menu (S21/S31). (3) User types; per-keystroke `refresh` (S30)
populates the menu. (4) User presses `<Tab>`: if the menu is showing → the selected item is
accepted; if not → pi's file-completion force (or slash re-fetch) runs. (5) User saves + quits;
pi reads the prompt back.

**Pain Points Addressed**: Without S33, `<Tab>` in a pi-prompt buffer just indents (the forward-
contract fall-through) — no slash completion, no file-completion force, no Tab-to-accept. This
breaks the "identical to the TUI" expectation (PRD §1) and forces the user to type full paths /
commands by hand.

## Why

- **PRD §1 #1 goal — byte-for-byte TUI parity**: completion behavior in Neovim must be identical
  to pi's TUI because the SAME live `AutocompleteProvider` produces + applies the suggestions.
  Tab is the one key pi users reach for most (force file completion, accept a suggestion); S33 is
  the last piece that makes the external editor's Tab indistinguishable from the TUI's.
- **Closes P2.M7 (Completion Flow)**: S30 (triggers/debounce) + S32 (accept/CR) + **S33 (Tab)**
  are the three handlers the ftplugin dispatches; with S33 the completion flow is functionally
  complete (the floating window S34/S35 + navigation S36 + dismiss S37 are UX polish on top of
  the now-complete data/accept/force pipeline).
- **Unblocks P2.M8 (the menu)**: S34's floating window renders whatever `menu.on_results` stores;
  S33's file-force Tab is a primary driver that populates that state, so the window has something
  to show as soon as it lands.
- **No new dependencies / no new RPC methods**: everything S33 needs — `shouldTriggerFileCompletion`
  (bridge method, S13 COMPLETE), `getSuggestions` with `force` (S11), `applyCompletion` (S12),
  `coords.utf16_to_byte` (S28), the menu seam (S31), the S32 `accept` core — is COMPLETE + in-tree.

## What

User-visible + technical behavior of `completion.on_tab(buf)` (insert-mode, buffer-local, dispatched
by the ftplugin's `map_dispatch("i","<Tab>",…)`):

1. **Menu OPEN + a selected item** → delegate to the S32 `accept` core (`M.accept(item)`). Issues
   `applyCompletion`, replaces the whole buffer with pi's result, positions the cursor, closes the
   menu. Tab is CONSUMED (`on_tab` returns `true`). *(pi `editor.ts:664` — Tab confirm in the list.)*
2. **Menu CLOSED** → replicate pi's `handleTabCompletion` (`editor.ts:2126`):
   - **Slash-command branch** — `cursorLine==0` AND `beforeCursor` (trimStart) starts with `/` AND
     no space in the trimmed prefix → issue an IMMEDIATE (0-debounce) `getSuggestions` with
     `force=false` (pi's `handleSlashCommandCompletion`). NO `shouldTriggerFileCompletion` call.
     *(pi `editor.ts:2132-2134` + `isSlashMenuAllowed`=`cursorLine===0`.)*
   - **File-force branch** — otherwise → call `shouldTriggerFileCompletion(lines, cursorLine,
     cursorCol)` over the bridge; **iff it returns `true`**, issue an IMMEDIATE `getSuggestions`
     with `force=true` (pi's `forceFileAutocomplete`). If `false`, do nothing (no fetch — pi's
     `requestAutocomplete` `force` guard aborts). *(pi `editor.ts:2143-2144` + `2150-2160`.)*
   - **Single-item auto-apply** (file-force path only) — when the `force=true` `getSuggestions`
     returns EXACTLY one item, apply it immediately via `M.accept(items[1], suggestions.prefix)`
     WITHOUT showing the menu. *(pi `editor.ts:2253-2271`.)*
   - **Multi-item / empty** — route through the SAME `completion.on_results` → `menu.on_results`
     seam S30/S31 use (empty items → `menu.close()`; non-empty → `menu.open(items)`).
3. In all acting cases `on_tab` returns `true` (Tab consumed). On bad args / disconnected bridge /
   `pi.bridge==nil` it returns `false` (the ftplugin's `feedkey("<Tab>")` runs the DEFAULT —
   indent). `on_tab` NEVER throws (pcall every nvim/bridge call; type-guard; read bridge/menu/
   coords FRESH at call time — the handshake resolves async + tests swap fakes after `require`).

### Success Criteria

- [ ] `on_tab(buf)` with the menu open + a selected item issues `applyCompletion` (via the S32
      `accept` core) + returns `true` (Tab consumed).
- [ ] `on_tab(buf)` with the menu closed on a NON-slash position calls `shouldTriggerFileCompletion`
      (RPC) FIRST; iff `true` it issues `getSuggestions` with `params.force==true`; iff `false` it
      issues NO `getSuggestions` (pi's `force`-guard abort).
- [ ] `on_tab(buf)` with the menu closed on a bare slash command at `cursorLine==0`
      (`/mod`, no space) issues `getSuggestions` with `params.force==false` WITHOUT calling
      `shouldTriggerFileCompletion` first (pi's slash branch).
- [ ] The slash branch does NOT fire at `cursorLine!=0` (a `/mod` on line 2 routes to the file-force
      branch) — proves the `isSlashMenuAllowed`=`cursorLine===0` gate.
- [ ] Single-item auto-apply: a `force=true` `getSuggestions` returning EXACTLY one item issues
      `applyCompletion` with `params.prefix == <the getSuggestions result's prefix>` (NOT
      `menu.get_prefix()`, which is stale/empty for a closed menu) + leaves the menu CLOSED.
- [ ] Multi-item force/slash results route through `completion.on_results` → `menu.on_results`
      (menu opens); empty results → `menu.close()`.
- [ ] Both Tab fetch paths are IMMEDIATE (0-debounce — not the 25ms `refresh` debounce) AND
      supersede a pending `refresh` debounce + any in-flight request (cancel + gen-guard) — and a
      later `refresh` supersedes an in-flight Tab fetch (shared `state.gen`).
- [ ] `on_tab` returns `true` when it acts; `false` on bad args / disconnected bridge / wiped buf /
      non-current buf (Tab → indent fall-through); never throws.
- [ ] The `accept` signature change is backward-compatible: S32's `on_enter` → `accept(item)` (no
      override) still reads `menu.get_prefix()`; S33's auto-apply → `accept(item, prefix)` uses the
      override. S32's spec stays GREEN.
- [ ] Non-regression: every prior spec (init/shim/activate/ftplugin/jsonlreader/bridge/handshake/
      request/notify/coords/completion/menu) exits 0 unchanged.
- [ ] The new `completion_tab_smoke.lua` prints `SMOKE_PASS` + exit 0.

## All Needed Context

### Context Completeness Check

_If someone knew nothing about this codebase, would they have everything needed to implement this
successfully?_ **YES** — every upstream dependency is COMPLETE and in-tree with exhaustive
`[Mode A]` headers + PRPs: the S31 `menu` accessors (`is_open`/`has_items`/`get_selected`/
`get_prefix`/`get_buf`/`close`/`on_results`), the S29/S28 `coords.nvim_to_pi_coords`/
`utf16_to_byte`/`pi_to_nvim_coords`, the S26 `bridge.request`/`cancel`/`is_connected` (TWO-LAYER
pending map; `shouldTriggerFileCompletion` + `getSuggestions` + `applyCompletion` each resolve to
their OWN cb), the `shouldTriggerFileCompletion` + `GetSuggestionsParams.force` wire shapes
(`extension/protocol.ts`), the server-side SYNC-delegation behavior (`makeShouldTrigger…`/
`makeGetSuggestionsHandler`), the S32 `accept`/`on_enter` core (+ the `prefix_override` extension),
the fake_bridge test helper + the fake-server smoke bootstrap, the COMPLETE pi Tab logic
(`handleTabCompletion`/`isSlashMenuAllowed`/`shouldTriggerFileCompletion`/single-item auto-apply —
all cited to `editor.ts`/`autocomplete.ts` line ranges), and the `:help`-verified nvim insert-mode
semantics (keymap callback = main loop; no `TextChangedI` loop from API mutations; stay-Insert).
The implementer reads these, adds `on_tab` + 2 helpers + the `accept` arg to `completion.lua`,
extends the spec, writes the smoke, and runs the verified test commands. No guessing; no further
external research required (all references in-tree + the research file + the `:help` tags).

### Documentation & References

```yaml
# MUST READ - Include these in your context window
- url: https://neovim.io/doc/user/api.html#nvim_buf_get_lines()
  why: "on_tab reads the current lines (BRANCH 2 needs them for the slash/force decision + the
        getSuggestions/shouldTrigger params). Confirms the API is callable from a keymap callback
        (main loop) — NO vim.schedule wrapper needed."
  critical: "on_tab is a vim.keymap.set('i',…) callback → it runs on the nvim MAIN LOOP → call
             nvim_buf_get_lines / nvim_win_get_cursor / bridge.request DIRECTLY (same api-safe
             contract as do_refresh S30 + accept S32). bridge.request's cb is schedule_wrap'd →
             also api-safe."

- url: https://neovim.io/doc/user/autocmd.html#TextChangedI
  why: "Proves the single-item auto-apply's buffer-replace (nvim_buf_set_lines inside accept) does
        NOT fire TextChangedI — only TYPED input does. => the auto-apply CANNOT re-trigger the
        refresh autocmd; NO re-entrancy guard is REQUIRED. (b:changedtick DOES increment — do not
        key refresh off it.)"
  critical: "Do NOT route the auto-apply edit through feedkeys 'to trigger refresh' — that WOULD
             fire TextChangedI + risk a loop. The S32 accept core already uses nvim_buf_set_lines
             (API) — loop-free by design. on_tab's menu-populating path does NOT mutate the buffer
             at all."

# THE pi Tab source of truth (editor.ts) — S33 replicates handleTabCompletion verbatim.
- file: ~/projects/pi/packages/tui/src/components/editor.ts
  why: "THE pi Tab dispatch S33 mirrors. (A) editor.ts:664 — Tab when the menu is OPEN applies the
        selected item (applyCompletion + cancelAutocomplete). (B) editor.ts:714 — Tab when the menu
        is CLOSED → handleTabCompletion(). editor.ts:2126 handleTabCompletion branches: isInSlash-
        CommandContext(beforeCursor) && !beforeCursor.trimStart().includes(' ') → handleSlashCommand-
        Completion (force:false); else forceFileAutocomplete(true) (force:true). editor.ts:2068
        isSlashMenuAllowed() = (cursorLine === 0) — the slash branch is GATED on line 0. editor.ts:
        2080 isInSlashCommandContext = isSlashMenuAllowed && trimStart.startsWith('/'). editor.ts:
        2147 requestAutocomplete — the force:true path CONSULTS shouldTriggerFileCompletion FIRST
        (editor.ts:2150-2160) + aborts if false; explicitTab/force ⇒ 0ms debounce (getAutocomplete-
        DebounceMs editor.ts:2214). editor.ts:2253 — the single-item auto-apply: force && explicitTab
        && items.length===1 ⇒ apply immediately with suggestions.prefix (NOT autocompletePrefix),
        do NOT show the list."
  pattern: "Map editor.ts:664 → on_tab BRANCH 1 (menu.open → M.accept). Map editor.ts:2126 → on_tab
            BRANCH 2 (the slash vs file-force decision). Map editor.ts:2147-2160 → force_fetch's
            shouldTrigger guard + immediate fetch. Map editor.ts:2253 → _route_or_accept's auto-apply."
  gotcha: "beforeCursor = currentLine.slice(0, cursorCol) where cursorCol is a UTF-16 (JS string)
           index. In Lua, pi.lines[cursorLine] is UTF-8; slice it at the UTF-16 boundary via
           coords.utf16_to_byte(line, pi.cursorCol) then :sub(1, byte_end). The slash/space checks
           are ASCII so a UTF-8 prefix is char-faithful. (research/notes.md §3.)"

- file: ~/projects/pi/packages/tui/src/autocomplete.ts
  why: "shouldTriggerFileCompletion's BODY (autocomplete.ts:775): returns FALSE only when
        textBeforeCursor.trim().startsWith('/') && !trim().includes(' ') (a bare slash command);
        true otherwise. Also documents the force flag's effect on getSuggestions: autocomplete.ts:
        308 (!force && startsWith('/')) skips file suggestions; autocomplete.ts:361/490 force changes
        path-prefix extraction (forced extraction always returns something). So force:true is
        MEANINGFUL to the provider — on_tab MUST forward it."
  pattern: "The plugin does NOT reimplement shouldTriggerFileCompletion — it RPCs it (the bridge
            method, S13). Reimplementing risks divergence + misses isSlashMenuAllowed-style changes."
  gotcha: "Because on_tab's slash branch ALREADY excluded the 'bare /cmd' case, the file-force
           branch's shouldTriggerFileCompletion would in practice always return true — but call it
           ANYWAY (RPC) to honor PRD §7.4 verbatim + stay robust to pi changes (belt-and-suspenders,
           exactly like pi's own double-check)."

- file: plugin/lua/pi-editor/completion.lua
  why: "THE file S33 modifies. Read its [Mode A] header (esp. the FORWARD CONTRACTS block — on_tab
        is still a forward contract; S33 ships it + force_fetch/_route_or_accept) + do_refresh's cb
        (the api-safe main-loop contract + the bridge-read-fresh rule + the TWO-LAYER supersession
        cancel+gen-guard that force_fetch MUST mirror) + M.accept() (S32 — the core on_tab's BRANCH 1
        + the auto-apply reuse; S33 adds the optional prefix_override arg) + M.on_enter() (the
        pattern for a ftplugin-dispatched handler returning truthy/falsy) + the singleton `state`
        (gen/inflight_id/debounce_timer/last_result — force_fetch SHARES these for supersession)."
  pattern: "force_fetch is the IMMEDIATE (0-debounce) sibling of do_refresh. It reuses cancel_timer()
            (the S30 stop+close leak fix) + the SAME state.gen/state.inflight_id so refresh↔Tab
            supersession is correct. on_tab reads bridge/menu/coords FRESH inside the fn (NOT
            module-load locals — handshake resolves async + tests swap fakes after require)."
  gotcha: "Do NOT refactor do_refresh into force_fetch (do_refresh DEBOUNCES 25ms; Tab is 0ms per
           pi getAutocompleteDebounceMs — reusing do_refresh would add a 25ms Tab lag). force_fetch
           DUPLICATES the few-line supersession block INTENTIONALLY (additive over refactor — the
           codebase pattern; document the pair in the header). The debounce_timer leak fix (stop
           THEN close, never stop-only) applies to force_fetch via the SHARED cancel_timer()."

- file: plugin/lua/pi-editor/menu.lua
  why: "THE module on_tab READS for the BRANCH 1 gate + routes through for BRANCH 2. Public surface:
        is_open()/has_items()/get_selected() (the BRANCH 1 gate: is_open AND has_items AND type(
        get_selected)=='table'); on_results(buf, items, prefix) (the SEAM force_fetch routes multi-
        item results through — same as S30's do_refresh cb). M.accept (S32) internally reads
        get_prefix()/get_buf(). S33 does NOT touch menu.lua."
  pattern: "BRANCH 1: `if menu.is_open() and menu.has_items() and type(menu.get_selected())=='table'
            then return M.accept(menu.get_selected()) end`. BRANCH 2 routing (in _route_or_accept):
            `if type(M.on_results)=='function' then pcall(M.on_results, buf, items, prefix) end`
            (on_results is registered by menu.attach onto completion.on_results — calling it drives
            empty→menu.close / non-empty→menu.open, IDENTICAL to the S30 refresh path)."
  gotcha: "menu.is_open() implies has_items + selected>=1 (open() sets selected=1; close() resets to
           0). So the BRANCH 1 gate is equivalent to pi's `autocompleteState && autocompleteList`.
           Do NOT call nvim_win_close in on_tab (the window is S34's job inside menu's render)."

- file: plugin/lua/pi-editor/coords.lua
  why: "THE centralized coordinate seam on_tab routes BOTH conversions through (PRD §8 'MUST be
        centralized'). nvim_to_pi_coords(lines, row, byte_col) → {lines, cursorLine=row-1, cursorCol
        =<UTF-16>} (for the getSuggestions/shouldTrigger params + the slash-branch cursorLine check).
        utf16_to_byte(line, utf16_idx) (S28 primitive) → the byte offset of a UTF-16 boundary (for
        slicing beforeCursor at pi.cursorCol). pi_to_nvim_coords is used INSIDE accept (S32) — on_tab
        does not call it directly."
  pattern: "BRANCH 2: `local pi = coords.nvim_to_pi_coords(lines, cur[1], cur[2])` then
            `local line_str = pi.lines[pi.cursorLine] or ''; local byte_end = coords.utf16_to_byte(
            line_str, pi.cursorCol); local before = line_str:sub(1, byte_end)`. The slash check:
            `local trimmed = before:gsub('^%s+','') or ''; local is_slash = pi.cursorLine==0 and
            trimmed:sub(1,1)=='/'; local no_space = not trimmed:find(' ')`."
  gotcha: "pi.cursorCol is UTF-16 (JS string index). Do NOT :sub(1, pi.cursorCol) on the UTF-8 line
           (wrong for multibyte). ALWAYS go UTF-16→byte via coords.utf16_to_byte first. For BMP text
           (the vast majority of prompts) byte==UTF-16-bytes but the helper is correct for astral
           too — use it unconditionally."

- file: plugin/lua/pi-editor/bridge.lua
  why: "THE RPC layer. Read the [Mode A] S26 block: M.request(method, params, cb) -> string|nil (cb
        is function(err, result) resolved EXACTLY ONCE by response/timeout/cancel/close, schedule_
        wrap'd → api-safe; returns the id or nil). M.cancel(id) (records + fires cb 'cancelled' —
        mirrors the real bridge so the gen-guard path is exercisable). M.is_connected(). The TWO-
        LAYER design: the pending map holds EVERY concurrent outstanding request —
        shouldTriggerFileCompletion + getSuggestions + applyCompletion each resolve to their OWN cb
        (they never mis-drop each other)."
  pattern: "BRANCH 2b: `bridge.request('shouldTriggerFileCompletion', {lines=pi.lines, cursorLine=
            pi.cursorLine, cursorCol=pi.cursorCol}, function(err, ok) if err or ok ~= true then
            return end; M.force_fetch(buf, {force=true}, M._route_or_accept(buf, true)) end)`.
            force_fetch: `bridge.request('getSuggestions', vim.tbl_extend('keep', pi, {force=…}), cb)`."
  gotcha: "shouldTriggerFileCompletion is SYNC on the SERVER (makeShouldTriggerFileCompletionHandler —
           a pure boolean fn) but the RPC is ASYNC on ours (a socket round-trip). So the file-force
           path is 2 sequential RPCs (shouldTrigger THEN getSuggestions) — that is correct + pi-
           faithful (pi consults the guard THEN fetches in-process). cb latency < rpc_timeout_ms (2000).
           on_tab returns true (Tab consumed) as soon as shouldTrigger is ISSUED; the fetch is async."

- file: extension/protocol.ts
  why: "THE wire shapes (authoritative). ShouldTriggerFileCompletionParams {lines, cursorLine,
        cursorCol}; ShouldTriggerFileCompletionResult = boolean. GetSuggestionsParams {lines,
        cursorLine, cursorCol, force?} (force 'mirrors pi's Tab / shouldTriggerFileCompletion path'
        — protocol.ts:128); GetSuggestionsResult = AutocompleteSuggestions | null. ApplyCompletionParams
        {lines, cursorLine, cursorCol, item, prefix} (S32)."
  pattern: "Build params as Lua tables with EXACTLY those keys. force is a BOOLEAN (opts.force == true).
            The getSuggestions null result resolves cb(nil, nil) — force_fetch normalizes to
            {items={}, prefix=''} (SUCCESS with empty, NOT an error) before routing."
  gotcha: "The single-item auto-apply needs suggestions.prefix (the getSuggestions RESULT's prefix),
           NOT menu.get_prefix() (the menu is not shown). That is why accept gains the prefix_override
           arg. Forward item VERBATIM (the whole AutocompleteItem table) in the auto-apply applyCompletion."

- file: plugin/lua/pi-editor/init.lua
  why: "READ ONLY (S33 does NOT modify it). Confirms `require('pi-editor').bridge` is the published
        bridge (set by handshake on success; nil otherwise) + `require('pi-editor').config` holds the
        resolved config (rpc_timeout_ms). on_tab reads the bridge fresh from here."
  pattern: "`local bridge = require('pi-editor').bridge` inside on_tab (read fresh). `if not bridge
            or type(bridge.is_connected) ~= 'function' or not bridge.is_connected() then return false
            end` (Tab → indent degrade)."

- file: plugin/ftplugin/pi-prompt.lua
  why: "READ ONLY (S33 does NOT modify it — it ALREADY dispatches on_tab). Confirms the <Tab> wiring:
        map_dispatch('i','<Tab>','pi-editor.completion','on_tab') → if on_tab returns truthy, Tab is
        CONSUMED; else feedkey('<Tab>') runs the DEFAULT (indent). buf is the pi-prompt buffer handle.
        The dispatch is pcall-wrapped — on_tab never breaks the keymap chain (but be defensive)."
  pattern: "on_tab(buf) must return `true` ONLY when it acts (so the Tab is consumed); return `false`
            (or nil) to fall through to indent. There is NO <Tab> expr-mode string contract — the
            ftplugin uses a function keymap + feedkey fall-through (NOT expr)."

- file: plugin/tests/completion_spec.lua
  why: "THE test style S33's on_tab cases EXTEND. Read its fake_bridge(opts) helper (controllable
        request/cancel/is_connected + resolve(i,err,result)/resolve_last — the fake stores EVERY cb;
        shouldTrigger's cb is the last request, then getSuggestions's) + the S32 populated_menu(line,
        byte_col, items, prefix) helper (drives the menu open via the REAL seam: fake_bridge +
        menu.attach() + refresh() + resolve a getSuggestions) + the win/nvim_win_set_buf/virtualedit=
        onemore/nvim_win_set_cursor buffer-cursor setup + the vim.wait(ms,predicate,5) async idiom +
        reset() before_each/after_each. S33 ADDS a describe('on_tab', …) block to THIS file."
  pattern: "BRANCH 1: populated_menu('/mod',3,{{value='/model',label='model'}},'/mo'); local n0=#
            fake.requests; local ok=completion.on_tab(buf); assert ok + last req is applyCompletion.
            BRANCH 2b: a closed_menu('./src/com',8) helper (buf+cursor, NO refresh / empty result so
            menu.is_open()==false); on_tab; assert first req is shouldTriggerFileCompletion; resolve
            true; assert next req is getSuggestions force==true. AUTO-APPLY: resolve the force
            getSuggestions with 1 item; assert next req is applyCompletion with params.prefix==the
            getSuggestions prefix."
  gotcha: "Do NOT name a spec-local table `pending` (shadows plenary's skip fn — use `got`/`reqs`).
           Drive menu state via REAL menu.attach()+completion.refresh()+a getSuggestions reply so
           BRANCH 1 sees a populated menu (don't hand-set menu state). For BRANCH 2 use a closed menu
           (no refresh, or an empty-items reply). Set virtualedit=onemore so the cursor can sit at EOL."

- file: plugin/tests/completion_accept_smoke.lua
  why: "THE plenary-free smoke bootstrap S33's completion_tab_smoke.lua MIRRORS. Read its fake luv
        unix-socket server (unique path, jreader, hello reply, controlled getSuggestions/applyCompletion
        replies) + REAL bridge.handshake + completion + menu.attach() + the check/fails/cquit/
        SMOKE_PASS footer + the teardown (menu.reset/completion.reset/bridge.close/srv close/os.remove).
        S33's smoke ADDS: a shouldTriggerFileCompletion reply branch + the 3 on_tab flows (menu-open
        accept, file-force show, single-item auto-apply)."
  pattern: "Server's jsonlreader cb: branch on req.method — 'hello'→reply ok; 'shouldTriggerFile-
            Completion'→reply <controlled bool>; 'getSuggestions'→reply {items,prefix}; 'applyCompletion'
            → stash the observed req + reply {lines,cursorLine,cursorCol}. vim.wait between each step."

- file: plan/001_c56962b4fa17/architecture/research-pi-autocomplete.md
  why: "THE in-tree pi research. §shouldTriggerFileCompletion call site (requestAutocomplete lines
        2150-2160 — consulted ONLY on force:true); §applyCompletion call sites (3: Tab-confirm
        editor.ts:669, Enter-confirm :690, single-item auto-apply :2255); §debounce (0ms for
        explicitTab/force). Confirms the pi Tab semantics S33 replicates."
  section: "the shouldTriggerFileCompletion + applyCompletion + debounce sections (line ~272-320)."

- file: plan/001_c56962b4fa17/P2M7T20S33/research/notes.md
  why: "THE consolidated research (this task). §1 (the S33 contract + the PRD §7.4 vs pi full-truth
        note); §2 (THE COMPLETE pi Tab logic — editor.ts:664/714/2126/2068/2080/2147/2150/2214/2253
        + autocomplete.ts:775, all quoted); §3 (the on_tab branch map + force_fetch/_route_or_accept
        pseudocode); §4 (the accept prefix_override); §5 (nvim semantics); §6 (the seams READ/WRITTEN);
        §7 (test strategy); §8 (scope/non-regression)."
  section: "all; esp. §2 (pi source), §3 (the branch map), §4 (prefix_override)."

- docfile: PRD.md
  why: "§7.4 (the Tab bullets — the AUTHORITATIVE requirement: Tab+menu-closed→shouldTrigger→
        force getSuggestions; Tab+menu-open→accept); §1 (#1 goal byte-for-byte TUI parity — why S33
        follows pi's full handleTabCompletion, not just the PRD summary); §5.4 (the shouldTrigger/
        getSuggestions/applyCompletion method rows); §8 (the coordinate contract); §11 (one pi-prompt
        buffer per session)."
  section: "§7.4 (heading:h3.20); §1 (heading:h2.1); §5.4 (heading:h3.8); §8 (heading:h2.8)"
  gotcha: "PRD §7.4 OMITS the slash force:false branch + the single-item auto-apply (it is the
           common-case simplification). S33 implements the FULLER pi truth (research-pi-autocomplete.md
           + editor.ts) because PRD §1 #1 is byte-for-byte parity. If the implementer prefers the
           strict PRD-minimum, the slash branch + auto-apply are the descopable pieces — but full
           parity is the recommended default (document the choice in the [Mode A] header)."
```

### Current Codebase tree (run `tree` in the root of the project) to get an overview of the codebase

```bash
$ cd /home/dustin/projects/pi-nvim-bridge && tree -L 3 plugin plan/001_c56962b4fa17/architecture plan/001_c56962b4fa17/P2M7T20S33
plugin
├── ftplugin/pi-prompt.lua                 # buffer-local setup (S22, COMPLETE) — ALREADY dispatches on_tab (<Tab>) + refresh autocmds + on_enter (<CR>) + autosave. S33 DOES NOT touch it.
├── lua/pi-editor/
│   ├── bridge.lua                         # socket client + handshake + RPC (S24-S27, COMPLETE) — request(method,params,cb)/cancel/is_connected (TWO-LAYER pending map; shouldTrigger + getSuggestions + applyCompletion each their own cb)
│   ├── completion.lua                     # per-keystroke TRIGGER (S30) + accept/on_enter (S32), COMPLETE — refresh/debounce/do_refresh/supersede + on_results + current + accept(item)+on_enter. S33 ADDS on_tab(buf)+force_fetch+_route_or_accept HERE + the accept prefix_override arg.
│   ├── coords.lua                         # nvim_to_pi_coords / pi_to_nvim_coords (S29) + byte_to_utf16/utf16_to_byte (S28), COMPLETE — on_tab uses nvim_to_pi_coords + utf16_to_byte (the beforeCursor slice)
│   ├── init.lua                           # setup() + VimEnter gate + activate() (S19-S21, COMPLETE) — publishes require("pi-editor").bridge
│   ├── menu.lua                           # windowless menu-STATE (S31, COMPLETE) — is_open/has_items/get_selected/get_prefix/get_buf/on_results/close. S33 READS it (BRANCH 1 gate + BRANCH 2 routing).
│   └── jsonlreader.lua                    # JSONL framing (S23, COMPLETE)
├── plugin/pi-editor.lua                   # VimEnter auto-activation shim (S20, COMPLETE)
└── tests/
    ├── minimal_init.lua                   # plenary harness (S19; reused UNCHANGED)
    ├── completion_spec.lua                # fake_bridge helper + populated_menu helper (S32) + full-flow async style — S33 EXTENDS this with a describe("on_tab", …) block
    ├── completion_smoke.lua               # plenary-free smoke style (S30)
    ├── completion_accept_smoke.lua        # the S32 accept smoke (fake luv server + REAL bridge + menu) — S33's completion_tab_smoke.lua MIRRORS it + adds shouldTrigger + the 3 Tab flows
    ├── menu_spec.lua + menu_smoke.lua     # the menu MODULE tests (S31)
    ├── bridge_request_spec.lua            # with_request_server fake-server pattern (S26)
    └── … (init/shim/activate/ftplugin/jsonlreader/bridge/handshake/notify/coords specs + smokes — all COMPLETE)
plan/001_c56962b4fa17/architecture/
├── external_deps.md                       # §1.2 (cursor API) + §1.6 (autocmds)
└── research-pi-autocomplete.md            # THE pi Tab/accept research (shouldTrigger call site; 3 applyCompletion sites; debounce 0ms for explicitTab/force)
plan/001_c56962b4fa17/P2M7T20S33/research/
└── notes.md                               # THE consolidated research for this task (§1-§8; esp. §2 pi source, §3 branch map, §4 prefix_override)
```

### Desired Codebase tree with files to be added and responsibility of file

```bash
plugin/lua/pi-editor/completion.lua              # MODIFY — ADD M.on_tab(buf) + private force_fetch/_route_or_accept + the accept(item, prefix_override?) arg + update [Mode A] header (on_tab→shipped; new on_tab/force_fetch block)
plugin/tests/completion_spec.lua                 # EXTEND — add describe("on_tab", …) block (fake_bridge + populated_menu + a closed_menu helper; BRANCH 1 accept, BRANCH 2b shouldTrigger→force, auto-apply, slash force:false, cursorLine!=0 gate, never-throws, supersession)
plugin/tests/completion_tab_smoke.lua            # NEW — plenary-free; fake luv server (hello/shouldTrigger/getSuggestions/applyCompletion branches) + REAL bridge + REAL completion + menu.attach; the 3 Tab flows (menu-open accept, file-force show, single-item auto-apply)
```

### Known Gotchas of our codebase & Library Quirks

```lua
-- CRITICAL: on_tab runs on the nvim MAIN LOOP (it is a vim.keymap.set('i',…) callback). Call
-- nvim_buf_get_lines / nvim_win_get_cursor / bridge.request DIRECTLY — NO vim.schedule wrapper
-- (same api-safe contract as do_refresh S30 + accept S32). bridge.request's cb is schedule_wrap'd
-- → also api-safe. (research/notes.md §5.)

-- CRITICAL: Tab is IMMEDIATE (0-debounce), NOT the 25ms refresh debounce. pi's getAutocompleteDebounceMs
-- (editor.ts:2214) returns 0 for explicitTab OR force. Do NOT reuse do_refresh (it debounces 25ms —
-- would add a Tab lag). force_fetch is the 0-debounce sibling. (research/notes.md §3.)

-- CRITICAL: beforeCursor must be sliced at the UTF-16 boundary. pi.cursorCol is a UTF-16 (JS string)
-- index; pi.lines[cursorLine] is a UTF-8 Lua string. NEVER :sub(1, pi.cursorCol) on the UTF-8 line
-- (wrong for multibyte). ALWAYS: byte_end = coords.utf16_to_byte(line_str, pi.cursorCol); before =
-- line_str:sub(1, byte_end). The slash/space checks are ASCII so the UTF-8 prefix is char-faithful.
-- (research/notes.md §3; coords.lua S28.)

-- CRITICAL: the slash branch is GATED on cursorLine==0. pi isSlashMenuAllowed (editor.ts:2068) =
-- (cursorLine === 0). A `/mod` on line 2 is NOT a slash context → routes to the file-force branch.
-- (research/notes.md §2.)

-- CRITICAL: shouldTriggerFileCompletion is consulted ONLY on the force:true (file-force) path. The
-- slash branch (force:false) does NOT call it (pi requestAutocomplete:2150 guards only when force).
-- (research/notes.md §2.)

-- CRITICAL: the single-item auto-apply uses suggestions.prefix (the getSuggestions RESULT's prefix),
-- NOT menu.get_prefix() (the menu is not shown → get_prefix is stale/""). That is why accept gains
-- the optional prefix_override arg. Forward item VERBATIM. (pi editor.ts:2253; research/notes.md §4.)

-- CRITICAL: the single-item auto-apply fires ONLY on the file-force path (force:true && explicitTab
-- && items.length===1). The slash path (force:false) NEVER auto-applies (shows the menu even with 1
-- item). (pi editor.ts:2253; research/notes.md §2.)

-- CRITICAL: no TextChangedI re-entrancy from the auto-apply. The auto-apply reuses M.accept, which
-- mutates the buffer via nvim_buf_set_lines (API mutation — does NOT fire TextChangedI, :help). So
-- no refresh loop. The menu-populating Tab path does NOT mutate the buffer at all. (research §5.)

-- READ bridge/menu/coords FRESH inside on_tab (NOT module-load locals): `local bridge =
-- require("pi-editor").bridge` / `require("pi-editor.menu")` / `require("pi-editor.coords")`.
-- (Same rule as completion.lua do_refresh/accept — handshake resolves async + tests swap fakes
-- after require + a /reload re-runs activate().)

-- on_tab RETURN CONTRACT: return true ONLY when it acts (menu-open accept issued OR a BRANCH 2 fetch/
-- shouldTrigger issued) so the ftplugin CONSUMES the Tab; return false/nil on bad args / disconnected
-- bridge / wiped buf / non-current buf (the ftplugin feedkey("<Tab>") runs the DEFAULT — indent).
-- (PRD §7.4; ftplugin S22 map_dispatch feedkey fall-through.)

-- SUPERSESSION is SHARED with refresh: force_fetch bumps state.gen + cancels state.inflight_id +
-- cancel_timer() (the SAME state do_refresh uses). So a refresh issued after Tab supersedes the Tab
-- fetch (gen-guard) + Tab cancels a pending refresh debounce. The TWO-LAYER pattern (cancel + gen-
-- guard) is MANDATORY (cancel can race; the gen-guard cannot). (completion.lua [Mode A] S30 block.)

-- force_fetch DUPLICATES do_refresh's few-line supersession block INTENTIONALLY (additive over
-- refactor — the codebase pattern). Do NOT refactor do_refresh (it is exhaustively S30-tested).
-- Document the force_fetch↔do_refresh pair in the [Mode A] header. Reuse the EXISTING cancel_timer()
-- local (the S30 stop+close leak fix — NEVER stop-only; leaks the uv_timer_t on nvim 0.12.x).

-- ONE-BUFFER-PER-SESSION (PRD §11): on_tab reads nvim_win_get_cursor(0) (the CURRENT window). Guard
-- `buf == nvim_get_current_buf()` (mirror accept/on_enter) so a non-current buf is a silent bail.

-- DO NOT couple to the floating window. on_tab routes via menu.on_results (STATE) + accept calls
-- menu.close() (STATE). Do NOT call nvim_win_close (the window is S34's job inside menu's render()).

-- DO NOT reimplement shouldTriggerFileCompletion locally — RPC it (the bridge method S13). Local
-- reimplementation risks divergence + misses isSlashMenuAllowed-style pi changes. (research §2.)

-- DO NOT implement on_next/on_prev/on_dismiss — those are S36/S37. S33 ships on_tab ONLY (+ the
-- accept prefix_override). The ftplugin's on_next/on_prev/on_dismiss dispatches still return false
-- (fall-through) until S36/S37 land.

-- DO NOT modify menu.lua/bridge.lua/coords.lua/init.lua/the ftplugin/the shim/jsonlreader.lua. S33's
-- ONLY existing-source-file change is completion.lua (on_tab + force_fetch + _route_or_accept + the
-- accept arg + header-doc update). The ftplugin ALREADY dispatches on_tab — S33 makes it return truthy.
```

## Implementation Blueprint

### Data models and structure

No new data models — S33 reuses the COMPLETE in-tree types. The `force_fetch` cb consumes the
`GetSuggestionsResult` wire shape (`extension/protocol.ts`); the shouldTrigger cb consumes
`ShouldTriggerFileCompletionResult = boolean`. The ONE signature change is `accept`:

```lua
--- The 5-step PRD §7.4 accept flow (S32) — UNCHANGED except the OPTIONAL prefix_override (S33).
--- S32's on_enter calls accept(item) (no override → reads menu.get_prefix()). S33's single-item
--- auto-apply calls accept(item, suggestions.prefix) (the result's prefix — the menu is not shown).
---@param item            pi-editor.AutocompleteItem The selected item — forwarded VERBATIM.
---@param prefix_override string?                     OPTIONAL: the getSuggestions result's prefix
---                                               (single-item auto-apply). Defaults to menu.get_prefix().
---@return boolean issued true iff the applyCompletion RPC was accepted by the bridge.
function M.accept(item, prefix_override) … end
```

The singleton `completion.lua` `state` table gains NO new REQUIRED fields (force_fetch SHARES
`state.gen`/`state.inflight_id`/`state.debounce_timer`/`state.last_result` with do_refresh for
correct supersession). The REQUIRED additions are `on_tab` + the two private helpers:

```lua
--- The immediate (0-debounce), superseded getSuggestions issuer — the Tab sibling of do_refresh.
--- Cancels the debounce timer + any in-flight request (supersede layer 1), bumps state.gen (layer 2),
--- issues bridge.request("getSuggestions", {lines,cursorLine,cursorCol,force}, cb). cb: gen-guard,
--- normalize null→{items={},prefix=""}, store last_result, call on_items(buf, items, prefix).
--- pcall-wrapped; never throws. (research/notes.md §3.)
---@param buf     integer                The pi-prompt buffer handle (captured in the cb closure).
---@param pi      table                  The pi coords {lines, cursorLine, cursorCol} (S29).
---@param opts    {force:boolean}        force=true ⇒ the file-force path; force=false ⇒ the slash path.
---@param on_items fun(buf:integer, items:pi-editor.AutocompleteItem[], prefix:string) The result router.
local force_fetch -- (forward declaration; assigned below)

--- Builds the result-router closure: single-item auto-apply (force+1 item → M.accept(item, prefix))
--- else route to the menu via completion.on_results (empty→close, non-empty→open). (research §3.)
---@param buf        integer  The pi-prompt buffer handle.
---@param allow_auto boolean  true on the file-force path (auto-apply eligible); false on the slash path.
local function _route_or_accept(buf, allow_auto) … end

--- The <Tab> handler (the ftplugin ALREADY dispatches on_tab). BRANCH 1 (menu open+selected) →
--- M.accept. BRANCH 2 (menu closed) → pi handleTabCompletion: slash ctx (cursorLine==0 + bare /cmd
--- no-space) → force_fetch force=false; else → shouldTriggerFileCompletion RPC → iff true →
--- force_fetch force=true. Returns true when it acts; false on bad args / disconnected bridge.
--- Never throws. (research/notes.md §2/§3.)
---@param buf integer The pi-prompt buffer handle (from the buffer-local <Tab> keymap dispatch).
---@return boolean handled true iff Tab was consumed (accept/fetch/shouldTrigger issued); false → indent.
function M.on_tab(buf) … end
```

### Implementation Tasks (ordered by dependencies)

```yaml
Task 1: READ (do NOT edit yet) — anchor on the COMPLETE seam + the pi Tab logic + the wire shapes
  - READ: plugin/lua/pi-editor/completion.lua  (the [Mode A] header esp. the FORWARD CONTRACTS block —
      on_tab is still a forward contract; do_refresh's cb — the api-safe main-loop contract + the
      bridge-read-fresh rule + the TWO-LAYER supersession cancel+gen-guard force_fetch MUST mirror;
      M.accept() — the S32 core on_tab BRANCH 1 + the auto-apply reuse; M.on_enter() — the truthy/falsy
      handler pattern; the singleton `state` — gen/inflight_id/debounce_timer/last_result)
  - READ: plugin/lua/pi-editor/menu.lua  (the public surface on_tab READS: is_open/has_items/get_selected
      for the BRANCH 1 gate; on_results for the BRANCH 2 routing. CONFIRM S33 does NOT touch it.)
  - READ: plugin/lua/pi-editor/coords.lua  (nvim_to_pi_coords + utf16_to_byte signatures; the [Mode A]
      header's UTF-16/byte notes — on_tab uses BOTH for the beforeCursor slice)
  - READ: plugin/lua/pi-editor/bridge.lua  (the [Mode A] S26 block: request(method,params,cb)->id|nil;
      cb(err,result) EXACTLY ONCE; schedule_wrap'd → api-safe; TWO-LAYER pending map; cancel(id))
  - READ: plugin/ftplugin/pi-prompt.lua  (the <Tab> map_dispatch → on_tab; the feedkey fall-through;
      the consume-vs-indent return contract. CONFIRM S33 does NOT touch it.)
  - READ: extension/protocol.ts  (ShouldTriggerFileCompletionParams/Result; GetSuggestionsParams.force;
      ApplyCompletionParams — the wire shapes)
  - READ: ~/projects/pi/packages/tui/src/components/editor.ts  (lines 664, 714, 2068, 2080, 2126, 2147,
      2150, 2214, 2253 — THE pi Tab logic S33 replicates: menu-open Tab-confirm; handleTabCompletion;
      isSlashMenuAllowed=cursorLine===0; isInSlashCommandContext; requestAutocomplete force guard;
      getAutocompleteDebounceMs 0ms; single-item auto-apply)
  - READ: ~/projects/pi/packages/tui/src/autocomplete.ts  (line 775 — shouldTriggerFileCompletion body;
      lines 308/361/490 — the force flag's effect on getSuggestions)
  - READ: plugin/tests/completion_spec.lua  (fake_bridge + the S32 populated_menu helper + the win/buf/
      cursor setup + vim.wait idiom + reset() — S33's cases EXTEND this file)
  - READ: plugin/tests/completion_accept_smoke.lua  (the fake luv server + REAL bridge + completion +
      menu.attach bootstrap — S33's smoke MIRRORS it + adds shouldTrigger + the 3 Tab flows)
  - READ: plan/001_c56962b4fa17/P2M7T20S33/research/notes.md  (★ §2 pi source; §3 branch map + force_fetch
      pseudocode; §4 prefix_override; §7 test strategy; §8 scope/non-regression)
  - WHY: locks the contract (pi Tab logic; menu accessors; coords UTF-16 slice; bridge async cb +
      TWO-LAYER; wire shapes; the 0-debounce + supersession + auto-apply discipline) before writing.

Task 2: MODIFY completion.lua — the accept(item, prefix_override?) arg (the ONE S32 change)
  - EDIT M.accept's signature + the prefix line:
      * `function M.accept(item, prefix_override)`  (add the 2nd param)
      * `prefix = (type(prefix_override) == "string") and prefix_override or (menu.get_prefix() or ""),`
      * ADD the LuaCATS `---@param prefix_override string?` line.
  - NO other change to accept's body (the guards/cb/nvim calls are UNCHANGED). S32's on_enter calls
      accept(item) (no override) → reads menu.get_prefix() — IDENTICAL behavior (S32 spec stays green).
  - NAMING: `prefix_override` (clear; does not collide with the `prefix` local).

Task 3: MODIFY completion.lua — the private force_fetch(buf, pi, opts, on_items) helper
  - IMPLEMENT (place after do_refresh / before the Public API section, OR just above M.on_tab):
      * cancel_timer()                                   -- drop any pending refresh debounce (can't race)
      * local bridge = require("pi-editor").bridge        -- read FRESH
      * if state.inflight_id and type(bridge.cancel)=="function" then pcall(bridge.cancel, state.inflight_id) end
      * state.inflight_id = nil
      * state.gen = state.gen + 1; local gen = state.gen   -- supersession layer 2 (gen-guard)
      * local params = vim.tbl_extend("keep", pi, { force = (opts.force == true) })
      * local id
      * pcall(bridge.request, "getSuggestions", params, function(err, result)
          if gen ~= state.gen then return end              -- STALE — drop, touch nothing
          state.inflight_id = nil
          if err then return end                           -- cancelled/timeout/error → touch nothing
          local items  = (result and type(result.items)=="table")  and result.items  or {}
          local prefix = (result and type(result.prefix)=="string") and result.prefix or ""
          state.last_result = { items = items, prefix = prefix }
          pcall(on_items, buf, items, prefix)              -- route to menu OR auto-apply
        end)
      * if type(id)=="string" then state.inflight_id = id end   -- (id set by the pcall; capture below)
      * (NOTE: capture `id` from the pcall return — `local ok, rid = pcall(bridge.request, …)`; if ok
        and type(rid)=="string" then state.inflight_id = rid end. Fix the sketch above accordingly.)
  - NEVER THROWS: pcall-wrapped; reads bridge fresh; type-guards.
  - 0-DEBOUNCE: NO vim.defer_fn — direct bridge.request (Tab is immediate per pi getAutocompleteDebounceMs).

Task 4: MODIFY completion.lua — the private _route_or_accept(buf, allow_auto) helper
  - IMPLEMENT (place just below force_fetch):
      * return function(_, items, prefix)
          if allow_auto and #items == 1 then
            M.accept(items[1], prefix)                    -- single-item auto-apply (pi:2253); prefix OVERRIDE
            return
          end
          if type(M.on_results) == "function" then pcall(M.on_results, buf, items, prefix) end
        end
  - allow_auto=true ONLY on the file-force path (force:true && explicitTab && 1 item). The slash path
      passes allow_auto=false (shows the menu even with 1 item — pi applyAutocompleteSuggestions always
      sets the list).
  - on_results is registered by menu.attach onto completion.on_results — calling it drives empty→
      menu.close / non-empty→menu.open (IDENTICAL to the S30 refresh path). api-safe (main loop).

Task 5: MODIFY completion.lua — M.on_tab(buf) (the public handler)
  - IMPLEMENT (place after M.on_enter, before `return M`):
      * if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
      * if buf ~= vim.api.nvim_get_current_buf() then return false end    -- one buf/session
      * local menu = require("pi-editor.menu")
      * ── BRANCH 1 (menu OPEN + selected): pi editor.ts:664 ──
      * if menu.is_open() and menu.has_items() then
          local item = menu.get_selected()
          if type(item) == "table" then return M.accept(item) == true end   -- S32 core (no override)
        end
      * ── BRANCH 2 (menu CLOSED): pi handleTabCompletion ──
      * local bridge = require("pi-editor").bridge                       -- read FRESH
      * if not bridge or type(bridge.is_connected) ~= "function" or not bridge.is_connected() then
          return false                                                    -- silent degrade (Tab → indent)
        end
      * local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false); if not ok then return false end
      * local cur; ok, cur = pcall(vim.api.nvim_win_get_cursor, 0); if not ok or type(cur) ~= "table" then return false end
      * local coords = require("pi-editor.coords")
      * local pi = coords.nvim_to_pi_coords(lines, cur[1], cur[2])        -- {lines, cursorLine, cursorCol(UTF-16)}
      * local line_str = pi.lines[pi.cursorLine] or ""
      * local bok, byte_end = pcall(coords.utf16_to_byte, line_str, pi.cursorCol)
      * if not bok or type(byte_end) ~= "number" then byte_end = #line_str end   -- defensive (utf16_to_byte is pure; shouldn't fail)
      * local before = line_str:sub(1, byte_end)
      * local trimmed = (before:gsub("^%s+", "")) or ""
      * local is_slash_ctx = (pi.cursorLine == 0) and trimmed:sub(1, 1) == "/"   -- isSlashMenuAllowed + trimStart starts "/"
      * local no_space = not trimmed:find(" ")                                    -- !trimStart().includes(" ")
      * ── BRANCH 2a (slash command, force:false): pi handleSlashCommandCompletion ──
      * if is_slash_ctx and no_space then
          force_fetch(buf, pi, { force = false }, _route_or_accept(buf, false))
          return true                                                     -- Tab CONSUMED
        end
      * ── BRANCH 2b (file force, force:true): pi forceFileAutocomplete ──
      * pcall(bridge.request, "shouldTriggerFileCompletion",
            { lines = pi.lines, cursorLine = pi.cursorLine, cursorCol = pi.cursorCol },
            function(err, trig)
              if err or trig ~= true then return end                      -- false/no-op (Tab already consumed)
              force_fetch(buf, pi, { force = true }, _route_or_accept(buf, true))
            end)
      * return true                                                       -- Tab CONSUMED
  - RETURN CONTRACT: true ONLY when it acts (BRANCH 1 accept issued OR BRANCH 2 fetch/shouldTrigger
      issued); false on bad args / disconnected bridge / wiped buf / non-current buf (Tab → indent).
  - NEVER THROWS: every nvim/bridge/coords call pcall'd; bridge/menu/coords read fresh + type-guarded.
  - NO shouldTrigger call on the slash branch (pi requestAutocomplete:2150 guards only when force).

Task 6: MODIFY completion.lua — update the [Mode A] header
  - EDIT the FORWARD CONTRACTS block: move on_tab from "stay absent" to "shipped (S33)". Keep
    on_next/on_prev/on_dismiss as forward contracts (S36/S37).
  - ADD an `on_tab / force_fetch` [Mode A] block (mirror the density of the S30/S32 blocks): the pi
      handleTabCompletion replication (BRANCH 1 accept editor.ts:664; BRANCH 2a slash force:false
      editor.ts:2132 + isSlashMenuAllowed=cursorLine===0 editor.ts:2068; BRANCH 2b file-force
      shouldTrigger→force:true editor.ts:2143/2150; single-item auto-apply editor.ts:2253); the 0-
      debounce (getAutocompleteDebounceMs editor.ts:2214); the beforeCursor UTF-16 slice (coords.
      utf16_to_byte); the shared state.gen/inflight_id supersession; the accept prefix_override;
      the api-safe main-loop contract; the consume-vs-indent return contract; read bridge/menu/coords
      fresh; no TextChangedI re-entrancy (accept's nvim_buf_set_lines is loop-free); no window coupling.
  - DOCUMENT the force_fetch↔do_refresh pair (force_fetch is the 0-debounce sibling; the duplicated
      supersession block is intentional — additive over refactor).

Task 7: EXTEND plugin/tests/completion_spec.lua — describe("on_tab", …) (reuse fake_bridge + populated_menu)
  - ADD a describe block AFTER the S32 accept/on_enter block (before the final `end)`). before_each/
      after_each already `reset()` (clears pi.bridge + on_results + completion state) + menu.reset().
  - ADD a `closed_menu(line, byte_col)` helper: a buf + cursor with NO refresh (or an empty-items
      reply) so menu.is_open()==false. (Mirror populated_menu minus the resolve, OR resolve empty.)
  - CASE (1) BRANCH 1 — menu open + Tab → accept: populated_menu('/mod',3,{{value='/model',label='model'}},'/mo');
      local n0=#fake.requests; local ok=completion.on_tab(buf); assert ok==true; local req=fake.requests[#];
      assert req.method=='applyCompletion' + req.params.item.value=='/model' + req.params.prefix=='/mo'.
  - CASE (2) BRANCH 2b — file-force: shouldTrigger=true → force getSuggestions: closed_menu('./src/com',8);
      local n0=#fake.requests; on_tab(buf); wait_for(200,()=>#fake.requests>n0); assert first new req is
      shouldTriggerFileCompletion + params {lines,cursorLine=0,cursorCol=8}; fake.resolve_last(nil,true);
      wait_for next req; assert it is getSuggestions + params.force==true; resolve with >1 items →
      wait_for(menu.is_open()); assert menu.is_open()==true (shown, not auto-applied).
  - CASE (3) BRANCH 2b — shouldTrigger=false → NO getSuggestions: closed_menu; on_tab; resolve shouldTrigger
      →false; assert NO getSuggestions req ever issued + on_tab returned true (consumed, no fetch).
  - CASE (4) SINGLE-ITEM AUTO-APPLY: closed_menu (non-slash); on_tab; resolve shouldTrigger→true; resolve
      the force getSuggestions with EXACTLY 1 item {items={{value='x',label='x'}}, prefix='./'}; wait_for;
      assert next req is applyCompletion + params.item==items[1] + params.prefix=='./' (NOT menu.get_prefix
      which is "") + menu.is_open()==false.
  - CASE (5) BRANCH 2a — slash ctx (cursorLine 0, bare /cmd) → force:FALSE (no shouldTrigger first):
      closed_menu('/mod',3); local n0=#fake.requests; on_tab; wait_for(#fake.requests>n0); assert first
      new req is getSuggestions + params.force==false (NOT shouldTriggerFileCompletion first); resolve
      with items → menu.is_open()==true (slash path never auto-applies even with 1 item).
  - CASE (6) slash gate on cursorLine!=0: a multi-line buf {row1:'', row2:'/mod'}; cursor on row 2;
      closed_menu; on_tab; assert the FIRST req is shouldTriggerFileCompletion (file-force, NOT slash)
      + resolve→true → getSuggestions force==true. (Proves the cursorLine==0 gate.)
  - CASE (7) never-throws/degrade: on_tab(nil); on_tab on a wiped buf; pi.bridge=nil → on_tab(buf)==false
      (no throw); bridge disconnected → false.
  - CASE (8) supersession: on_tab issues a force getSuggestions; before its cb, completion.refresh(buf)
      fires → assert the Tab req's cb is dropped (gen-guard) OR cancelled + the refresh req is live.
  - DISCIPLINE: do NOT name a spec-local table `pending` (shadows plenary's skip fn). Drive menu state
      via the REAL seam. Reset menu + completion + pi.bridge in before/after_each.

Task 8: CREATE plugin/tests/completion_tab_smoke.lua (plenary-free; mirror completion_accept_smoke.lua)
  - BOOTSTRAP: the completion_accept_smoke.lua header (add plugin_root to rtp; require bridge/completion/
      menu/pi/coords; self-sufficient setup({debounce_ms=5}); the fails/check/cquit/SMOKE_PASS footer).
  - SERVER: fake luv unix-socket server (unique path) + jreader. The server cb branches on req.method:
      'hello'→reply {ok=true,serverVersion='0.1.0',cwd=DESC_CWD,fdAvailable=true};
      'shouldTriggerFileCompletion'→ reply <a controlled bool> (stash nothing);
      'getSuggestions'→ reply <controlled {items,prefix}> (stash nothing);
      'applyCompletion'→ stash the observed req (for the assertion) + reply {lines=…,cursorLine=…,cursorCol=…}.
  - FLOW 1 (menu-open accept): handshake REAL bridge; buf {lines={'/mod'}}; cursor {1,3}; menu.attach();
      completion.refresh(buf); wait_for menu open; completion.on_tab(buf); wait_for server sees applyCompletion;
      reply; assert buffer + cursor + menu closed.
  - FLOW 2 (file-force show): menu.close() (menu closed); buf {lines={'./src/com'}}; cursor {1,8};
      completion.on_tab(buf); wait_for server sees shouldTriggerFileCompletion; reply true; wait_for server
      sees getSuggestions force==true; reply >1 items; wait_for menu.is_open().
  - FLOW 3 (single-item auto-apply): menu.close(); buf {lines={'./x'}}; cursor {1,3}; on_tab; shouldTrigger
      →true; getSuggestions reply 1 item; wait_for server sees applyCompletion; reply {lines,cursor}; assert
      buffer applied + menu closed.
  - ASSERTIONS (check): each flow's req.method + params (force, prefix, item) + buffer/cursor/menu state.
  - TEARDOWN: menu.reset(); completion.reset(); bridge.close(); server stop (srv:close(); os.remove(path)).
  - FOOTER: if fails>0 then vim.cmd('cquit 1') end; io.stdout:write('SMOKE_PASS\n').
  - ⚠️ AGENTS.md: this is a FILE run via `nvim … +"luafile tests/completion_tab_smoke.lua" +qa` — NEVER
    pipe a heredoc into nvim stdin (hangs). Wrap in `timeout 60`.
```

### Implementation Patterns & Key Details

```lua
-- The accept prefix_override (Task 2 — the ONE S32 change):
function M.accept(item, prefix_override)
  if type(item) ~= "table" then return false end
  local bridge = require("pi-editor").bridge
  if not bridge or type(bridge.is_connected) ~= "function" or not bridge.is_connected() then
    return false
  end
  local menu = require("pi-editor.menu")
  local buf  = menu.get_buf()
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok or type(lines) ~= "table" then return false end
  local cur
  ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok or type(cur) ~= "table" then return false end
  local coords = require("pi-editor.coords")
  local pi = coords.nvim_to_pi_coords(lines, cur[1], cur[2])
  local params = {
    lines = pi.lines, cursorLine = pi.cursorLine, cursorCol = pi.cursorCol,
    item  = item,
    prefix = (type(prefix_override) == "string") and prefix_override or (menu.get_prefix() or ""),
  }
  pcall(bridge.request, "applyCompletion", params, function(err, result)
    if err then pcall(menu.close); return end
    if type(result) ~= "table" then pcall(menu.close); return end
    local nv = coords.pi_to_nvim_coords(result.lines, result.cursorLine, result.cursorCol)
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, nv.lines)
    pcall(vim.api.nvim_win_set_cursor, 0, { nv.row, nv.col })
    pcall(menu.close)
  end)
  return true
end

-- The immediate force_fetch (Task 3 — the 0-debounce sibling of do_refresh):
force_fetch = function(buf, pi, opts, on_items)
  cancel_timer()                                   -- drop any pending refresh debounce
  local bridge = require("pi-editor").bridge
  if state.inflight_id and type(bridge.cancel) == "function" then
    pcall(bridge.cancel, state.inflight_id)
  end
  state.inflight_id = nil
  state.gen = state.gen + 1
  local gen = state.gen                            -- supersession layer 2 (gen-guard)
  local params = vim.tbl_extend("keep", pi, { force = (opts.force == true) })
  local ok, rid = pcall(bridge.request, "getSuggestions", params, function(err, result)
    if gen ~= state.gen then return end            -- STALE — drop, touch nothing
    state.inflight_id = nil
    if err then return end                         -- cancelled/timeout/error → touch nothing
    local items  = (result and type(result.items)  == "table")  and result.items  or {}
    local prefix = (result and type(result.prefix) == "string") and result.prefix or ""
    state.last_result = { items = items, prefix = prefix }
    pcall(on_items, buf, items, prefix)
  end)
  if ok and type(rid) == "string" then state.inflight_id = rid end
end

-- The result router (Task 4):
local function _route_or_accept(buf, allow_auto)
  return function(_, items, prefix)
    if allow_auto and #items == 1 then
      M.accept(items[1], prefix)                   -- single-item auto-apply (pi:2253); prefix OVERRIDE
      return
    end
    if type(M.on_results) == "function" then pcall(M.on_results, buf, items, prefix) end
  end
end

-- The on_tab handler (Task 5 — pi handleTabCompletion):
function M.on_tab(buf)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then return false end
  if buf ~= vim.api.nvim_get_current_buf() then return false end
  local menu = require("pi-editor.menu")
  -- BRANCH 1 (menu OPEN + selected): pi editor.ts:664
  if menu.is_open() and menu.has_items() then
    local item = menu.get_selected()
    if type(item) == "table" then return M.accept(item) == true end
  end
  -- BRANCH 2 (menu CLOSED): pi handleTabCompletion
  local bridge = require("pi-editor").bridge
  if not bridge or type(bridge.is_connected) ~= "function" or not bridge.is_connected() then
    return false                                   -- silent degrade (Tab → indent)
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok or type(lines) ~= "table" then return false end
  local cur
  ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok or type(cur) ~= "table" then return false end
  local coords = require("pi-editor.coords")
  local pi = coords.nvim_to_pi_coords(lines, cur[1], cur[2])
  local line_str = pi.lines[pi.cursorLine] or ""
  local bok, byte_end = pcall(coords.utf16_to_byte, line_str, pi.cursorCol)
  if not bok or type(byte_end) ~= "number" then byte_end = #line_str end
  local before  = line_str:sub(1, byte_end)
  local trimmed = (before:gsub("^%s+", "")) or ""
  local is_slash_ctx = (pi.cursorLine == 0) and trimmed:sub(1, 1) == "/"
  local no_space     = not trimmed:find(" ")
  -- BRANCH 2a (slash command, force:false): pi handleSlashCommandCompletion
  if is_slash_ctx and no_space then
    force_fetch(buf, pi, { force = false }, _route_or_accept(buf, false))
    return true                                    -- Tab CONSUMED
  end
  -- BRANCH 2b (file force, force:true): pi forceFileAutocomplete → shouldTriggerFileCompletion guard
  pcall(bridge.request, "shouldTriggerFileCompletion",
    { lines = pi.lines, cursorLine = pi.cursorLine, cursorCol = pi.cursorCol },
    function(err, trig)
      if err or trig ~= true then return end       -- false/no-op (Tab already consumed)
      force_fetch(buf, pi, { force = true }, _route_or_accept(buf, true))
    end)
  return true                                      -- Tab CONSUMED
end
```

### Integration Points

```yaml
KEYMAPS:
  - file: plugin/ftplugin/pi-prompt.lua
  - status: "ALREADY WIRED (S22). map_dispatch('i','<Tab>','pi-editor.completion','on_tab') →
    if on_tab returns truthy the Tab is CONSUMED; else feedkey('<Tab>') runs the DEFAULT (indent).
    S33 does NOT touch the ftplugin — it makes completion.on_tab exist + return the right truthy/falsy."

RPC:
  - method: "shouldTriggerFileCompletion"
  - params: "{lines:string[], cursorLine:int(0-idx), cursorCol:int(0-idx UTF-16)}"
  - result: "boolean (false ⇒ abort the file-force fetch — pi:2150)"
  - server: "extension/pi-editor-bridge.ts makeShouldTriggerFileCompletionHandler (P1.M2.T6.S13, COMPLETE)
    — SYNC pure-fn delegation; forwards (lines,cursorLine,cursorCol) VERBATIM, returns pi's boolean UNCHANGED."
  - method: "getSuggestions"
  - params: "{lines, cursorLine, cursorCol, force?:boolean} (force=true ⇒ the file-force path; false ⇒ slash)"
  - result: "AutocompleteSuggestions | null (null ⇒ cb(nil,nil) ⇒ force_fetch normalizes to {items={},prefix=''})"

COORDINATES:
  - "nvim→pi: coords.nvim_to_pi_coords(lines, row(1-idx), byte_col(0-idx)) → {lines, cursorLine, cursorCol(UTF-16)}"
  - "UTF-16 slice: coords.utf16_to_byte(line, pi.cursorCol) → byte_end; before = line:sub(1, byte_end) (S28)"

MENU:
  - "READ: menu.is_open()/has_items()/get_selected() (BRANCH 1 gate)"
  - "ROUTE: completion.on_results(buf, items, prefix) (registered by menu.attach → drives empty→close /
    non-empty→open; IDENTICAL to the S30 refresh path)"
  - "WRITE (via accept): menu.close() (the only menu mutation in BRANCH 1/auto-apply — clears state)"

STATE (completion.lua — SHARED with do_refresh for supersession):
  - "state.gen (bumped by BOTH do_refresh + force_fetch — mutual supersession)"
  - "state.inflight_id (cancelled by BOTH — frees the round-trip)"
  - "state.debounce_timer (cancel_timer() — the SHARED S30 stop+close leak fix)"
  - "state.last_result (updated by force_fetch — M.current() reflects the latest Tab result too)"
```

## Validation Loop

### Level 1: Syntax & Style (Immediate Feedback)

```bash
# No ruff/mypy (this is Lua). Use selene (lint) + stylua (format) if configured.
cd /home/dustin/projects/pi-nvim-bridge
# (optional, if selene/stylua are installed — the repo ships stylua.toml/selene.yml per the S31 PRP).
# selene --config plugin/selene.yml plugin/lua/pi-editor/completion.lua
# stylua --check plugin/lua/pi-editor/completion.lua

# A fast parse check (NO plenary) — write nothing to nvim stdin (AGENTS.md hard rule):
timeout 30 nvim --headless --clean -u NORC -c 'set rtp+=.' \
  -c 'lua require("pi-editor.completion"); print("parse-ok")' -c 'qa'
echo "exit=$?   # 0 = the module parses + require resolves (incl. the new on_tab)"
# Expected: prints `parse-ok`, exit 0. (Run from plugin/ so 'pi-editor' resolves via rtp+=.)
```

### Level 2: Unit Tests (Component Validation — the plenary spec)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# The S33 on_tab cases (the additive describe block in completion_spec.lua):
timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/completion_spec.lua")'
echo "exit=$?   # 0 = all completion cases pass (S30 refresh + S32 accept/on_enter + S33 on_tab)"

# Full suite (non-regression — every prior spec must stay green):
for spec in init_spec shim_spec activate_spec ftplugin_spec jsonlreader_spec bridge_spec \
            bridge_handshake_spec bridge_request_spec bridge_notify_spec coords_spec \
            completion_spec menu_spec; do
  echo "--- $spec ---"
  timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
    -c "lua require('plenary.busted').run('tests/${spec}.lua')" || echo "FAIL: $spec"
done
# Expected: every spec exits 0 (non-regression; the accept prefix_override is backward-compatible).
```

### Level 3: Integration Testing (the plenary-free smoke — real bridge + real completion + menu)

```bash
cd /home/dustin/projects/pi-nvim-bridge/plugin
# S33's NEW smoke: a fake luv server + REAL bridge.handshake + REAL completion + menu.attach;
# the 3 Tab flows (menu-open accept, file-force show, single-item auto-apply) over real RPCs.
timeout 60 nvim --headless --clean -u NORC +"luafile tests/completion_tab_smoke.lua" +qa
echo "exit=$?   # 0 = pass (prints 'SMOKE_PASS'), 1 = a check failed"
# Expected: prints `SMOKE_PASS`, exit 0.
# ⚠️ AGENTS.md: this is a FILE + :luafile — NEVER pipe a heredoc into nvim stdin (it HANGS).
```

### Level 4: End-to-End Manual Check (optional — the real pi ↔ nvim round-trip)

```bash
# (Optional / manual — only if the bridge extension is installed + a real pi session is running.)
# In pi: press Ctrl+G to open $EDITOR; type `/mo`; confirm the menu (state — window is S34) selects
# /model; press <Tab>; the buffer should become `/model ` (BRANCH 1 accept).
# Then: clear the line, type `./<Tab>` (menu closed, non-slash); confirm a force file completion fires
# (the menu populates with path results, or a single result auto-applies).
# (Until S34 lands there is no visible popup, but the Tab accept + the buffer update work.)
# Automated equivalent: the Level-3 smoke IS the E2E proof (real bridge + real completion + the
# shouldTrigger/getSuggestions/applyCompletion round-trips). Do NOT invent a stdin-based nvim check
# (AGENTS.md hard rule).
```

## Final Validation Checklist

### Technical Validation

- [ ] Level 1 parse check passes (the module require resolves, incl. the new on_tab; exit 0).
- [ ] Level 2: `completion_spec.lua` exits 0 (the additive `on_tab` cases pass).
- [ ] Level 2 non-regression: every prior spec (init/shim/activate/ftplugin/jsonlreader/bridge/
      handshake/request/notify/coords/completion/menu) exits 0 unchanged.
- [ ] Level 3: `completion_tab_smoke.lua` prints `SMOKE_PASS` + exit 0.
- [ ] (If selene/stylua configured) zero lint/format errors on `completion.lua`.

### Feature Validation

- [ ] `on_tab(buf)` BRANCH 1: menu open + selected → `accept` issued (applyCompletion) + returns true.
- [ ] `on_tab(buf)` BRANCH 2b: menu closed + non-slash → `shouldTriggerFileCompletion` FIRST; iff true
      → `getSuggestions` `force==true`; iff false → NO `getSuggestions` (pi:2150 abort).
- [ ] `on_tab(buf)` BRANCH 2a: menu closed + bare `/cmd` at `cursorLine==0` → `getSuggestions` `force==false`
      (NO shouldTrigger call first).
- [ ] The slash branch does NOT fire at `cursorLine!=0` (line-2 `/cmd` → file-force) — proves the gate.
- [ ] Single-item auto-apply: `force==true` + 1 item → `applyCompletion` with `params.prefix == <getSuggestions
      result prefix>` (NOT menu.get_prefix) + menu CLOSED.
- [ ] Multi-item force/slash results route through `completion.on_results` → menu opens; empty → menu.close.
- [ ] Both Tab fetch paths are IMMEDIATE (0-debounce) + supersede a pending refresh + are superseded by a
      later refresh (shared `state.gen`).
- [ ] `on_tab` returns `true` when it acts; `false` on bad args / disconnected bridge / wiped/non-current buf;
      never throws.
- [ ] The `accept(item, prefix_override?)` change is backward-compatible (S32's on_enter → accept(item) still
      reads menu.get_prefix; S32 spec GREEN).
- [ ] User STAYS in Insert mode after the auto-apply (no feedkeys mode-dance; accept's set_lines/set_cursor).
- [ ] No `TextChangedI` re-entrancy loop (the auto-apply's nvim_buf_set_lines is loop-free).
- [ ] The [Mode A] header is updated (on_tab→shipped; new on_tab/force_fetch block with the pi cite + the
      0-debounce + UTF-16 slice + supersession + prefix_override notes).

### Code Quality Validation

- [ ] Follows the existing codebase patterns: singleton `state` (shared with do_refresh); read bridge/menu/
      coords FRESH inside on_tab/force_fetch/accept; pcall every nvim/bridge call (never-throws contract);
      LuaCATS annotations on on_tab/force_fetch/_route_or_accept/accept's new arg (match bridge.lua/
      completion.lua's density).
- [ ] Additive to `completion.lua` (S30 `refresh`/`do_refresh`/`reset`/`current`/`on_results` + S32 `accept`/
      `on_enter` unchanged except the optional accept arg); the spec extension is additive (S30/S32 cases stay
      green; `reset()` before/after_each).
- [ ] Anti-patterns avoided (see below): no local shouldTrigger reimplementation; no 25ms debounce on Tab; no
      UTF-8 :sub at a UTF-16 index; no auto-apply on the slash path; no window coupling; no on_next/on_prev.
- [ ] Dependencies properly managed: only the in-tree bridge/coords/menu/pi modules; no new requires beyond
      what's in-tree; no new runtime files beyond the smoke.

### Documentation & Deployment

- [ ] The [Mode A] header docstring explains the pi `handleTabCompletion` replication (BRANCH 1 editor.ts:664;
      BRANCH 2a slash editor.ts:2132 + isSlashMenuAllowed=cursorLine===0; BRANCH 2b file-force editor.ts:
      2143/2150; single-item auto-apply editor.ts:2253) + the 0-debounce + the UTF-16 slice + the supersession
      + the prefix_override + the consume-vs-indent return contract.
- [ ] No new env vars / config keys (on_tab reads the EXISTING `rpc_timeout_ms` via the bridge; no new
      setup() option).
- [ ] The smoke's SMOKE_PASS footer + the AGENTS.md `:luafile`-from-a-file discipline are followed.

---

## Anti-Patterns to Avoid

- ❌ Don't reimplement `shouldTriggerFileCompletion` locally — RPC it (the bridge method S13). Local
  reimplementation risks divergence + misses `isSlashMenuAllowed`-style pi changes. The slash/space
  branch decision (which determines force:false vs force:true) IS a local string check (it mirrors pi's
  `handleTabCompletion`), but the `shouldTriggerFileCompletion` GUARD itself is the bridge's job.
- ❌ Don't debounce the Tab fetch — pi's `getAutocompleteDebounceMs` returns **0** for explicitTab/force.
  Reusing `do_refresh` (25ms) would add a Tab lag + diverge from the TUI. `force_fetch` is immediate.
- ❌ Don't `:sub(1, pi.cursorCol)` on the UTF-8 line — `pi.cursorCol` is UTF-16; slice at the UTF-16
  boundary via `coords.utf16_to_byte(line, pi.cursorCol)` first (wrong for multibyte otherwise).
- ❌ Don't apply the single-item auto-apply on the slash path (`force:false`) — pi auto-applies ONLY on
  `force && explicitTab && items.length===1` (the file-force path). The slash path always shows the menu.
- ❌ Don't gate the slash branch without `cursorLine==0` — pi's `isSlashMenuAllowed` is `cursorLine===0`.
  A `/cmd` on line 2 is NOT a slash context → routes to the file-force branch.
- ❌ Don't read `menu.get_prefix()` for the single-item auto-apply — the menu is not shown (closed), so
  `get_prefix()` is stale/empty. Use the getSuggestions RESULT's `prefix` (the `accept` `prefix_override`).
- ❌ Don't route the auto-apply edit through `feedkeys` "to trigger refresh" — that fires `TextChangedI` +
  risks a loop. The S32 `accept` core uses `nvim_buf_set_lines` (API) — loop-free by design.
- ❌ Don't add a generation-id supersession guard to `accept` itself — it's a ONE-SHOT user action (S32).
  The supersession guard lives in `force_fetch` (the getSuggestions that FEEDS the auto-apply), not accept.
- ❌ Don't couple to the floating window (`nvim_win_close`) — route via `menu.on_results` (state) +
  `menu.close()` (state). The window is S34's job inside `menu`'s `render()`.
- ❌ Don't implement `on_next`/`on_prev`/`on_dismiss` — those are S36/S37. S33 ships `on_tab` ONLY (+ the
  `accept` prefix_override). The ftplugin's other dispatches still return false (fall-through) until then.
- ❌ Don't modify `menu.lua`/`bridge.lua`/`coords.lua`/the ftplugin/init/shim/jsonlreader — S33's only
  existing-source-file change is `completion.lua` (additive). The ftplugin ALREADY dispatches `on_tab`.
- ❌ Don't refactor `do_refresh` into `force_fetch` — `do_refresh` is exhaustively S30-tested + DEBOUNCES;
  `force_fetch` is the 0-debounce sibling. The duplicated few-line supersession block is INTENTIONAL
  (additive over refactor — the codebase pattern); reuse the EXISTING `cancel_timer()` local.