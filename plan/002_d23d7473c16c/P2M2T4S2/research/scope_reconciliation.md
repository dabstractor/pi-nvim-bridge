# P2.M2.T4.S2 — scope reconciliation & research findings

Live-verified against `fish 4.8.1` (`/usr/bin/fish`) on this machine and the
already-landed `lua/pi-bridge/shell.lua` (P2.M1.T2 + P2.M2.T3, Complete) +
`lua/pi-bridge/shell/fish.lua` (P2.M2.T4.S1, Complete).

## 0. The headline: the LIVE response path is ALREADY COMPLETE

The task title is "fish.lua response parsing + AutocompleteItem normalization +
prefix derivation". Each of those three concerns is ALREADY implemented by a
sibling task — S2 does NOT re-implement them. They are distributed as follows:

| concern (task title) | already done by | where |
|---|---|---|
| fish response parsing | **S1** daemon `__pi_handle` | `lua/pi-bridge/shell/fish.lua` `DAEMON_SCRIPT` — runs `complete -C`, tab-splits, builds single-object JSON `{"items":[{value,description?}],"prefix":""}` between `__PIRESP_START__`/`__PIRESP_END__` |
| AutocompleteItem normalization | **S5** `_feed` → `normalize_item` | `lua/pi-bridge/shell.lua:445` `normalize_item(raw)` → `{value, label=value, description?}` (label defaults to value; S1 emits no label) |
| prefix derivation | **S3** `complete_current` → `shell_word_prefix` | `lua/pi-bridge/shell.lua:917` `shell_word_prefix(line)` = trailing `[%S]+` run; `complete_current` OVERRIDES the daemon's advisory `"prefix":""` client-side (shell.lua:991) |

So the S1 scope-fence note (research/fish_driver_findings.md §10) is correct:
"No Lua-side normalization needed in fish.lua" and prefix is the consumer's job.

## 1. What S2 genuinely owns (the PRD-mandated gap)

PRD §17.15 `shell_fish_spec.lua` — "**golden parsing of `complete -C` output**:
normal `word⇥desc`, description-less `word`, empty result, multiline (N items), a
value containing a literal tab (escaped). **Uses a fixture string (no live fish
needed for the parser**; a live-fish integration test is gated on `fish` on PATH)."

The daemon's parsing is IN FISH — it CANNOT be fixture-tested without a live
`fish` subprocess. So §17.15's "no live fish needed for the parser" REQUIRES a
**pure-Lua parser of raw `complete -C` output**. That parser does not exist yet
(fish.lua exports only `start`/`cd`). **This is S2's concrete deliverable.**

→ Add `M.parse(raw)` to `fish.lua`: pure Lua, takes raw `complete -C` output
(newline-delimited `word⇥desc` lines) → `{value, description?}[]` (the daemon's
raw-item wire shape that `normalize_item` consumes). Documents + tests the EXACT
parsing contract the daemon implements in fish. NEVER throws (non-string → `{}`).

It is the canonical/testable reference implementation; the daemon is the runtime
implementation in fish. They are dual implementations of the SAME spec, tested
independently (offline golden tests + gated live round-trip). Do NOT route the
live path through `M.parse` (that would require changing the locked `_feed`
single-object-JSON protocol — out of scope).

## 2. fish `complete -C` output shape (verified)

`fish -c 'complete -C "git ch"'` emits one line per candidate:
- `checkout⇥Checkout and switch to a branch` (word⇥description, ⇥ = literal 0x09)
- `cherry` (bare word, NO tab, when a candidate has no description)

Delimiter = the FIRST literal tab byte. fish does NOT escape tabs in the output.
→ `M.parse` splits each line on the first `\t` (plain `find("\t",1,true)` — no
pattern, so literal `%`/`+`/`$` in words/descriptions never corrupt the search).
Word = before first tab; description = after first tab to EOL (may itself contain
tabs → kept verbatim). Empty words skipped. Empty lines skipped.

## 3. The literal-tab edge (§17.15 "value containing a literal tab (escaped)")

`complete -C`'s format is UNESCAPED tab-delimited → a candidate WORD containing a
literal 0x09 cannot be represented unambiguously (the first tab is the
word/desc delimiter). S1's daemon handles this the same way (first-tab split).
`M.parse`'s contract: split on first tab; document the limitation. The §17.15
fixture "(escaped)" is interpreted as: the TEST uses a Lua `\t` to inject a
second tab mid-value and asserts the parser treats the FIRST tab as the
delimiter (word = bytes before first tab). Implementer: LIVE-VERIFY a real
`complete -C` of a path containing a tab during validation + align tests to
reality; do not invent an escape scheme.

## 4. fish has NO JSON builtin (4.x) — but S2's `M.parse` is Lua, unaffected

S1 research §3: `string escape --style=json` and `printf %j` are GONE in fish 4.x
→ the daemon builds JSON MANUALLY (`__pi_json_str`). This is a DAEMON concern.
`M.parse` is pure Lua over the ALREADY-emitted raw `complete -C` text — no JSON
escaping in Lua. (shell.lua `_feed` does the JSON decode of the daemon's body.)

## 5. Normalization verification (S2 = verify, not implement)

Confirm the daemon's emitted items are shaped `{value:string, description?:string}`
with NO `label` → `normalize_item` (shell.lua:445) defaults `label = value` →
yields `AutocompleteItem {value, label, description?}`. This is already true by
S1 construction (`__pi_handle` emits `{"value":..,"description":..}`). S2 verifies
via the live round-trip (S1's `shell_fish_driver_spec.lua` already asserts
`checkout`/`cherry` decode). No fish.lua normalization code.

## 6. Prefix derivation verification (S2 = verify, not implement)

`shell.shell_word_prefix(line)` = `line:match("[%S]+$")` (trailing non-whitespace
run). For fish's word-completion model (complete the trailing token) this is
correct + sufficient. `complete_current` (S3) calls it and OVERRIDES the daemon's
`"prefix":""`. S2 documents this + may add a few prefix assertions for confidence.
NO new prefix code in fish.lua (avoid duplicating shell.lua's already-complete,
unit-tested helper).

## 7. Test placement

All existing shell tests are FLAT in `tests/` (S1 set the precedent:
`tests/shell_fish_driver_spec.lua`, `tests/shell_fish_driver_smoke.lua`).
S2 follows the SAME flat convention (lowest friction; the implementer sees the
sibling immediately). Names:
- `tests/shell_fish_spec.lua` — plenary/busted, OFFLINE golden parser tests of
  `M.parse` (NO live fish). Mirrors `tests/coords_spec.lua` structure.
- `tests/shell_fish_smoke.lua` — plenary-FREE parser smoke (N→O) of `M.parse`.

(PRD §17.15 mentions `tests/shell/` as the eventual home; consolidating there is
a P2.M3.T5 organizational concern when zsh/bash arrive, NOT S2's. The
`minimal_init.lua` rtp includes the repo root so subdirectory paths also resolve,
but flat is chosen to match the live convention.)

`shell_fish_spec.lua` (PARSER, offline) is DISTINCT from S1's
`shell_fish_driver_spec.lua` (LIFECYCLE/live round-trip, gated on fish).

## 8. Validation commands (verified-working in this repo)

- Plenary spec: `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_fish_spec.lua")'`
- Smoke: `timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_fish_smoke.lua" +qa && echo "exit=$?"`
- S1 live round-trip (re-run to confirm daemon parsing still healthy):
  `timeout 90 nvim --headless --clean -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/shell_fish_driver_spec.lua")'`
- Lua syntax: `luac -p lua/pi-bridge/shell/fish.lua` (or a `:luafile` eval)
- Direct `complete -C` probe: `fish -c 'complete -C "git ch"'` (human-verify the format)

fish 4.8.1 is PRESENT in this env → live tests run here. CI elsewhere must skip
them gracefully (the existing `vim.fn.executable("fish")` gate).