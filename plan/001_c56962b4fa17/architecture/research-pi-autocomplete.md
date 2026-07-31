# Pi Autocomplete & Editor Launch — Codebase Verification

Scout report verifying PRD claims about the autocomplete engine and external-editor launch.
All four target files exist at their PRD-stated paths. Findings below use exact paths, line
ranges, and signatures.

---

## 1. `packages/tui/src/autocomplete.ts` — Autocomplete engine

**Path:** `packages/tui/src/autocomplete.ts` — CONFIRMED present.

### Type / interface definitions (all PRD claims confirmed)

`AutocompleteItem` (lines 99-102):
```ts
export interface AutocompleteItem {
	value: string;
	label: string;
	description?: string;
}
```

`AutocompleteSuggestions` (lines 116-119):
```ts
export interface AutocompleteSuggestions {
	items: AutocompleteItem[];
	prefix: string; // What we're matching against (e.g., "/" or "src/")
}
```

`AutocompleteProvider` interface (lines 121-144):
```ts
export interface AutocompleteProvider {
	/** Characters that should naturally trigger this provider at token boundaries. */
	triggerCharacters?: string[];

	getSuggestions(
		lines: string[],
		cursorLine: number,
		cursorCol: number,
		options: { signal: AbortSignal; force?: boolean },
	): Promise<AutocompleteSuggestions | null>;

	applyCompletion(
		lines: string[],
		cursorLine: number,
		cursorCol: number,
		item: AutocompleteItem,
		prefix: string,
	): {
		lines: string[];
		cursorLine: number;
		cursorCol: number;
	};

	shouldTriggerFileCompletion?(lines: string[], cursorLine: number, cursorCol: number): boolean;
}
```

All three method signatures match the PRD exactly. Note that `triggerCharacters` is an
**optional** field and `shouldTriggerFileCompletion` is also **optional** (`?`) — consumers
must null-check it before calling.

Supporting types also present:
- `SlashCommand` (lines 105-111): `name`, `description?`, `argumentHint?`, optional
  `getArgumentCompletions?(argumentPrefix): Awaitable<AutocompleteItem[] | null>`.

### `CombinedAutocompleteProvider` class (lines 147-end) — CONFIRMED

Constructor (lines 162-167):
```ts
constructor(
	commands: (SlashCommand | AutocompleteItem)[] = [],
	basePath: string,
	fdPath: string | null = null,
) { ... }
```

`getSuggestions` (lines 169-...) — fully implemented. Logic branches:
1. `@`-prefix → fuzzy file search via `getFuzzyFileSuggestions` (uses `fd`).
2. `/`-prefix at start of line (no space) → slash-command fuzzy filter; if a space follows,
   delegates to the matched command's `getArgumentCompletions`.
3. Otherwise → directory listing via `getFileSuggestions` (synchronous `readdirSync`).

`applyCompletion` (lines ~270-...) — handles four completion shapes: slash-command name,
`@`-attachment, slash-command argument, and raw file path. Adjusts cursor for directories
(no trailing space) and quoted prefixes.

`shouldTriggerFileCompletion` (lines ~375-388) — returns `false` only when typing a slash
command at start of line with no space; otherwise `true`.

### Architecture notes
- File-path completion uses **`readdirSync`** (synchronous) for directory walk.
- Fuzzy `@`-attachment completion shells out to **`fd`** via `walkDirectoryWithFd`
  (lines 86-159), respecting `.gitignore`, with an `AbortSignal`.
- `basePath` is `this.sessionManager.getCwd()`; `fdPath` comes from `ensureTool("fd")`.

---

## 2. `packages/coding-agent/src/modes/interactive/interactive-mode.ts` — Editor launch

**Path:** `packages/coding-agent/src/modes/interactive/interactive-mode.ts` — CONFIRMED present (6008 lines).

### `openExternalEditor()` (lines 3778-3826) — all PRD claims CONFIRMED

Editor command resolution:
```ts
const editorCmd = this.settingsManager.getExternalEditorCommand();
```
`SettingsManager.getExternalEditorCommand()` (settings-manager.ts:854) precedence:
`settings.externalEditor` → `$VISUAL`/`$EDITOR` env → platform default (`notepad` on
win32, else `nano`).

Temp file (line 3786) — **exact match** to PRD:
```ts
const tmpFile = path.join(os.tmpdir(), `pi-editor-${Date.now()}.pi.md`);
```

Spawn (lines 3811-3816):
```ts
const child = spawn(editor, [...editorArgs, tmpFile], {
	stdio: "inherit",
	shell: process.platform === "win32",
});
```
- **Process.env inheritance: CONFIRMED.** No `env` option is passed, so Node's `spawn`
  defaults to inheriting `process.env` for the child. No `cwd` is passed either, so the
  editor runs in the host process's cwd.
- `stdio: "inherit"` — the editor takes over the terminal directly (critical for vim/nvim).
- A code comment (lines 3808-3810) explicitly warns NOT to use `spawnSync`: on Windows
  synchronous child_process calls keep libuv's console-input read active after `ui.stop()`
  pauses stdin, racing the editor for the input buffer.

Read-back after editor exit (lines 3819-3822) — CONFIRMED, conditional on status 0:
```ts
if (status === 0) {
	const newContent = fs.readFileSync(tmpFile, "utf-8").replace(/\n$/, "");
	this.editor.setText(newContent);
}
// On non-zero exit, keep original text (no action needed)
```
Always cleans up the temp file in the `finally` block (lines 3824-3828) and restarts the TUI
with a forced full re-render.

### `createBaseAutocompleteProvider()` (lines 538-621) — CONFIRMED

Builds a `CombinedAutocompleteProvider` seeded with:
- `BUILTIN_SLASH_COMMANDS` mapped to `SlashCommand[]`.
- Dynamic `getArgumentCompletions` wired onto `/model` (fuzzy over runtime models) and
  `/login` (provider list).
- Prompt-template commands, extension commands (from `extensionRunner.getRegisteredCommands()`),
  and skill commands (`skill:<name>`, gated on `getEnableSkillCommands()`).

Constructor args (lines 617-621):
```ts
return new CombinedAutocompleteProvider(
	[...slashCommands, ...templateCommands, ...extensionCommands, ...skillCommandList],
	this.sessionManager.getCwd(),
	this.fdPath,
);
```

### `setupAutocompleteProvider()` (lines 624-639) — CONFIRMED

Implements a **wrapper/chain** pattern (not additive registration):
```ts
let provider = this.createBaseAutocompleteProvider();
const triggerCharacters: string[] = [];
for (const wrapProvider of this.autocompleteProviderWrappers) {
	provider = wrapProvider(provider);                 // wraps the previous provider
	triggerCharacters.push(...(provider.triggerCharacters ?? []));
}
if (triggerCharacters.length > 0) {
	provider.triggerCharacters = [...new Set(triggerCharacters)];
}
this.autocompleteProvider = provider;
this.defaultEditor.setAutocompleteProvider(provider);
if (this.editor !== this.defaultEditor) {
	this.editor.setAutocompleteProvider?.(provider);
}
```
Each `AutocompleteProviderFactory` receives the *current* (possibly already-wrapped) provider
and returns a new one. Trigger characters from every layer are merged (deduped). The provider
is then pushed onto both the default editor and any active custom editor.

### `addAutocompleteProvider` on the UI context (lines 2143-2146) — CONFIRMED

```ts
addAutocompleteProvider: (factory) => {
	this.autocompleteProviderWrappers.push(factory);
	this.setupAutocompleteProvider();
},
```
Part of the extension UI context object (the `ExtensionUIContext` returned around line 2130).
The factory type is `AutocompleteProviderFactory = (current: AutocompleteProvider) => AutocompleteProvider`
(core/extensions/types.ts:121). Pushing is **append-only**; wrappers accumulate across calls
and rebuild the whole chain immediately. They are cleared to `[]` on session reset (line 1952).

### Other relevant state (lines 326-328)
```ts
private autocompleteProvider: AutocompleteProvider | undefined;
private autocompleteProviderWrappers: AutocompleteProviderFactory[] = [];
private fdPath: string | undefined;
```
`fdPath` is resolved via `ensureTool("fd")` during startup (lines 681-683).

---

## 3. `packages/coding-agent/src/modes/interactive/components/extension-editor.ts` — Modal variant

**Path:** `packages/coding-agent/src/modes/interactive/components/extension-editor.ts` — CONFIRMED present.

`ExtensionEditorComponent` is a modal multi-line editor shown by extensions (via the
`editor(title, prefill)` UI-context method → `showExtensionEditor`).

It has its **own** `openExternalEditor()` (lines ~75-115). Key differences from the
interactive-mode version:

| Aspect | interactive-mode.ts | extension-editor.ts |
|---|---|---|
| Temp file name | `pi-editor-${Date.now()}.pi.md` | `pi-extension-editor-${Date.now()}.md` |
| Editor cmd source | `settingsManager.getExternalEditorCommand()` | `externalEditorCommand` arg → `$VISUAL`/`$EDITOR` → platform default |
| TUI stop/start | `this.ui.stop()` / `this.ui.start()` | `this.tui.stop()` / `this.tui.start()` |
| Spawn | `spawn(editor, [...editorArgs, tmpFile], { stdio:"inherit", shell: win32 })` | identical spawn options |
| Read-back | `readFileSync(...).replace(/\n$/,"")` only on status 0 | identical (only on status 0) |

**Inconsistency to flag:** the two editor-launch paths use **different temp-file naming
patterns**. The PRD's `pi-editor-<ts>.pi.md` matches `interactive-mode.ts` exactly but NOT
`extension-editor.ts` (which drops the `.pi` segment and uses an `extension-editor` prefix).
Both inherit `process.env` (no `env` option on spawn) and read back on status 0.

The extension editor is invoked via the `app.editor.external` keybinding (handled in
`handleInput`, lines ~70-72), distinct from the main editor's binding of the same action.

---

## 4. `packages/tui/src/components/editor.ts` — Editor → provider wiring

**Path:** `packages/tui/src/components/editor.ts` — CONFIRMED present (2333 lines).

### Provider storage & setup (lines 275-375)
```ts
private autocompleteProvider?: AutocompleteProvider;
private autocompleteTriggerCharacters = [...DEFAULT_AUTOCOMPLETE_TRIGGER_CHARACTERS];
private autocompleteTriggerPattern = buildTriggerPattern(this.autocompleteTriggerCharacters);
...
setAutocompleteProvider(provider: AutocompleteProvider): void {
	this.cancelAutocomplete();
	this.autocompleteProvider = provider;
	this.setAutocompleteTriggerCharacters(provider.triggerCharacters ?? []);
}
```
Default triggers: `DEFAULT_AUTOCOMPLETE_TRIGGER_CHARACTERS = ["@", "#"]` (line 237).
Debounce for attachment triggers: `ATTACHMENT_AUTOCOMPLETE_DEBOUNCE_MS = 20` (line 236).
`setAutocompleteTriggerCharacters` (lines 2201-2213) **filters out `/`** and whitespace from
custom triggers and dedupes against the defaults.

### `getSuggestions` call site — `runAutocompleteRequest` (lines 2228-2246)
```ts
const suggestions = await this.autocompleteProvider.getSuggestions(
	this.state.lines,
	this.state.cursorLine,
	this.state.cursorCol,
	{ signal: controller.signal, force: options.force },
);
```
Guarded by staleness checks (`isAutocompleteRequestCurrent`) using snapshot text/cursor +
request id + abort signal. Abort/cancel handled via a token queue in `requestAutocomplete`
(lines 2147-2181) and `startAutocompleteRequest`.

### `shouldTriggerFileCompletion` call site — `requestAutocomplete` (lines 2150-2160)
```ts
if (options.force) {
	const shouldTrigger =
		!this.autocompleteProvider.shouldTriggerFileCompletion ||
		this.autocompleteProvider.shouldTriggerFileCompletion(
			this.state.lines,
			this.state.cursorLine,
			this.state.cursorCol,
		);
	if (!shouldTrigger) return;
}
```
Only consulted on **forced** (Tab/explicit) requests; the optional guard is null-checked
first (consistent with the optional interface field).

### `applyCompletion` call sites (three)
1. **Tab confirm in autocomplete list** (lines 669-679) — applies selected item.
2. **Enter confirm in autocomplete list** (lines 690-712) — applies, then for `/`-prefix
   falls through to submit; otherwise consumes.
3. **Single-item auto-apply on forced+explicit Tab** (lines 2255-2271 in `runAutocompleteRequest`)
   — when `force && explicitTab && items.length === 1`, applies immediately without showing
   the list.

All three call signatures:
```ts
const result = this.autocompleteProvider.applyCompletion(
	this.state.lines,
	this.state.cursorLine,
	this.state.cursorCol,
	selected,            // AutocompleteItem
	this.autocompletePrefix, // string  (or suggestions.prefix for the auto-apply path)
);
this.state.lines = result.lines;
this.state.cursorLine = result.cursorLine;
this.setCursorCol(result.cursorCol);
```

### Debounce behavior (`getAutocompleteDebounceMs`, lines 2214-2222)
Returns `0` for explicit/forced Tab requests; otherwise `20ms` only when the pre-cursor text
matches the attachment debounce pattern (i.e., right after a trigger character). Non-attachment
natural typing is not debounced.

---

## Cross-cutting verification summary

| PRD claim | Status | Evidence |
|---|---|---|
| `AutocompleteProvider` interface + signatures | ✅ CONFIRMED | autocomplete.ts:121-144 |
| `AutocompleteItem` / `AutocompleteSuggestions` | ✅ CONFIRMED | autocomplete.ts:99-119 |
| `CombinedAutocompleteProvider` class | ✅ CONFIRMED | autocomplete.ts:147-388 |
| `getSuggestions` / `applyCompletion` / `shouldTriggerFileCompletion` signatures | ✅ CONFIRMED | autocomplete.ts:124-143 |
| `openExternalEditor()` in interactive-mode | ✅ CONFIRMED | interactive-mode.ts:3778-3826 |
| Editor spawn inherits process.env | ✅ CONFIRMED | no `env` option on spawn (line 3811) → Node inherits process.env |
| Temp file `pi-editor-<ts>.pi.md` | ✅ CONFIRMED (interactive-mode only) | interactive-mode.ts:3786 |
| Reads file back after editor exit | ✅ CONFIRMED | interactive-mode.ts:3819-3822 (only on status 0) |
| `createBaseAutocompleteProvider()` | ✅ CONFIRMED | interactive-mode.ts:538-621 |
| `setupAutocompleteProvider()` | ✅ CONFIRMED | interactive-mode.ts:624-639 |
| `addAutocompleteProvider` on UI context | ✅ CONFIRMED | interactive-mode.ts:2143-2146 |
| Modal editor variant (extension-editor.ts) | ✅ CONFIRMED | extension-editor.ts (own openExternalEditor) |
| editor.ts calls `getSuggestions`/`applyCompletion` | ✅ CONFIRMED | editor.ts:2234-2257, 669-690 |

### Findings / discrepancies (severity low–medium)
- **low:** Two divergent temp-file naming patterns between the main editor
  (`pi-editor-<ts>.pi.md`) and the extension modal editor (`pi-extension-editor-<ts>.md`).
  A pi-nvim-bridge that intercepts/recognizes temp files by pattern must account for BOTH,
  or only the main-editor pattern will match.
- **low:** `getExternalEditorCommand()` precedence differs slightly: main editor goes through
  `SettingsManager` (settings → env → platform default), while the extension editor checks an
  injected `externalEditorCommand` arg → env → platform default. Both ultimately honor
  `$VISUAL`/`$EDITOR`.
- **low:** The provider chain is **rebuild-from-scratch on every `addAutocompleteProvider`
  / `setupAutocompleteProvider` call** (factories are append-only and re-applied in order).
  Wrappers are cleared to `[]` on session reset (line 1952). A bridge that registers a
  provider must re-register after reset, and its wrapper must faithfully forward
  `getSuggestions`/`applyCompletion`/`triggerCharacters` to the inner provider.
- **info:** `triggerCharacters` `/` is explicitly excluded by the editor's
  `setAutocompleteTriggerCharacters` filter (editor.ts:2204) — slash is handled internally,
  not as a provider trigger.
- **info:** `applyCompletion` cursor math differs for directories (no trailing space) and
  quoted prefixes; bridge providers must replicate or delegate to inner provider for correct
  cursor placement.

### Residual risks
- A bridge that wraps the provider must preserve abort-signal handling and the
  `{ signal, force }` options object exactly, or the editor's staleness/abort logic breaks.
- A bridge editor must keep the `stdio: "inherit"` + no-`spawnSync` contract; violating it
  reintroduces the Windows stdin race documented in the code comment.
- The read-back only fires on exit status 0; non-zero exit silently keeps old text. A
  bridge that exits non-zero on success (e.g., nvim errorformat) would appear to "fail."