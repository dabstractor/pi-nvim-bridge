The research brief has been written successfully to the authoritative output path. Here is the completed deliverable.

---

# Research: Vimdoc Authoring Conventions for a Sibling Help File

## Summary

The canonical vimdoc authoring guide lives under the `*help-writing*` tag in Neovim's `helphelp.txt`. All five research questions are answered with primary-source evidence — read directly from the locally installed Neovim 0.11 runtime (`helphelp.txt`, `syntax/help.vim`) and the repo's own `doc/pi-bridge.txt` / `doc/tags`. Tags are **global across all `.txt` files** in a `doc/` directory: `:helptags` builds one shared `doc/tags` index, so `|pi-bridge-shell-config|` in `pi-bridge.txt` resolves to `*pi-bridge-shell-config*` in `pi-bridge-shell.txt` with zero extra configuration.

## Key Findings (condensed)

1. **First-line format (blocker if wrong):** `*pi-bridge-shell.txt*\tFor Nvim 0.11+.\tLast change: <date>` — the tag must match the filename exactly or `:helptags` fails. Match the existing `pi-bridge.txt` convention (version+date on line 1, not line 2).

2. **Trailing modeline (blocker if missing):** ` vim:tw=78:ts=8:noet:ft=help:norl:` — leading space required; sets textwidth, tabstop, filetype.

3. **Tags/refs:** `*tag-name*` (definition, right-aligned) / `|tag-name|` (cross-reference). Options in `'quotes'`, technical terms in backticks. The syntax regex `[#-)!+-~]` **explicitly includes hyphens** — `*pi-bridge-shell-config*` is fully valid.

4. **Cross-file links:** Confirmed via `:helptags` docs — it scans *all* `.txt` files in the directory, writes one `doc/tags`. Adding `pi-bridge-shell.txt` + `:helptags doc/` auto-registers every tag. Cross-file `|links|` in CONTENTS and inline are standard practice (Neovim's own docs do this constantly).

5. **Gotchas:** `~` = column heading (text before `~` gets `helpHeader`); `NOTE:`/`Note:`/`Notes:` → `helpNote`, `WARNING:` → `helpWarning`, `DEPRECATED:` → `helpDeprecated` (confirmed from `help.vim` lines 82–84); section titles must start uppercase; `>` blocks close at `<` or any column-1 line; `E670` on duplicate tags.

6. **Exemplary plugin help files:** which-key.nvim, mason.nvim, telescope.nvim, nvim-lspconfig (all with URLs in the brief). The repo's own `pi-bridge.txt` is itself a gold-standard template — mirror it.

Full details, code snippets, syntax regexes, severity annotations, and a copy-paste checklist are in the written brief.