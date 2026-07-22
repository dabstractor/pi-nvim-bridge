# External Dependencies & API Reference

## 1. Neovim Core APIs (verified on 0.12.4)

### 1.1 String Index Conversion — `coords.lua`

**EXACT UTF-16 conversion (refinement over PRD §8):**

```lua
-- Byte index → UTF-16 code unit index (for sending to pi)
-- byte_idx is 0-indexed byte offset into the Lua/UTF-8 string
local utf16_idx = vim.str_utfindex(line, "utf-16", byte_idx)

-- UTF-16 code unit index → byte index (for applying pi results)
-- utf16_idx is pi's cursorCol (0-indexed UTF-16 offset)
local byte_idx = vim.str_byteindex(line, "utf-16", utf16_idx)
```

**Verified behavior:**
| String | byte_idx | `str_utfindex(s, 'utf-16', byte_idx)` | `str_byteindex(s, 'utf-16', utf16)` |
|--------|----------|--------------------------------------|--------------------------------------|
| `héllo` | 3 | 2 | 3 |
| `日本語` | 3 | 1 | 3 |

**Also available (2-arg, returns codepoint index — NOT UTF-16):**
```lua
local cp_idx = vim.str_utfindex(line, byte_idx)  -- codepoint index
local byte_idx = vim.str_byteindex(line, cp_idx) -- codepoint → byte
```

### 1.2 Buffer/Window/Cursor API

```lua
-- Get all lines (0-indexed start/end, returns array of Lua strings)
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

-- Set all lines
vim.api.nvim_buf_set_lines(0, 0, -1, false, result_lines)

-- Get cursor [row, col] — row is 1-indexed, col is 0-indexed BYTE offset
local cursor = vim.api.nvim_win_get_cursor(0)  -- {row, col}

-- Set cursor — row 1-indexed, col 0-indexed BYTE offset
vim.api.nvim_win_set_cursor(0, { row, byte_col })
-- Note: nvim_win_set_cursor col is 0-indexed (unlike vim.fn.col which is 1-indexed)
```

**Indexing summary:**
| Source | Row/Index base | Column type |
|--------|---------------|-------------|
| `nvim_win_get_cursor` | row 1-indexed | col 0-indexed byte |
| `nvim_buf_get_lines` | 0-indexed line range | N/A (returns strings) |
| pi `cursorLine` | 0-indexed | N/A |
| pi `cursorCol` | 0-indexed UTF-16 | N/A |

### 1.3 Floating Window — `menu.lua`

```lua
local buf = vim.api.nvim_create_buf(false, true)  -- unlisted, scratch
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.api.nvim_buf_add_highlight(buf, ns, hl_group, line, col_start, col_end)

local win = vim.api.nvim_open_win(buf, false, {
  relative = "cursor",   -- or "win" with win=0
  row = 1,               -- below cursor
  col = 0,
  width = 40,
  height = 10,
  style = "minimal",     -- no line numbers, no fold column
  border = "rounded",    -- or "none", "single", "double", or chars table
  focusable = false,     -- don't steal focus from insert buffer
})
vim.api.nvim_win_set_option(win, "wrap", false)

-- Close
vim.api.nvim_win_close(win, true)
```

### 1.4 luv (vim.uv) Unix Socket — `bridge.lua`

```lua
local uv = vim.uv
local pipe = uv.new_pipe(false)  -- false = not IPC pipe

-- Connect to Unix domain socket
pipe:connect(socket_path, function(err)
  if err then ... end
  -- connected
end)

-- Start reading
pipe:read_start(function(err, chunk)
  if err then ... end
  if not chunk then return end  -- EOF
  -- process chunk
end)

-- Write data (JSONL: encode + "\n")
pipe:write(vim.json.encode(msg) .. "\n", function(err)
  if err then ... end
end)

-- Close
pipe:close()
```

### 1.5 JSON — built-in
```lua
local obj = vim.json.decode(json_string)  -- throws on invalid JSON
local str = vim.json.encode(obj)          -- produces compact JSON
```

### 1.6 Autocmds
```lua
-- Buffer-local autocmd
vim.api.nvim_create_autocmd("TextChangedI", {
  buffer = bufnr,
  callback = function() ... end,
})
```

### 1.7 Debounce / Timers
```lua
-- Using vim.defer_fn (schedules on event loop)
local timer
local function debounced(fn, ms)
  if timer then timer:stop() end
  timer = vim.defer_fn(fn, ms)
end

-- Using uv timer (more control)
local uv_timer = vim.uv.new_timer()
uv_timer:start(ms, 0, function() vim.schedule(fn) end)
```

### 1.8 Checkhealth
```lua
-- lua/pi-editor/health.lua
local M = {}
function M.check()
  vim.health.start("pi-editor")
  vim.health.ok("...")
  vim.health.warn("...")
  vim.health.error("...")
end
return M
-- Run with: :checkhealth pi-editor
```

## 2. blink.cmp Source API

**Registration (user config):**
```lua
{
  "saghen/blink.cmp",
  opts = {
    sources = {
      providers = {
        ["pi-editor"] = {
          name = "pi-editor",
          module = "pi-editor.blink_source",
        },
      },
    },
  },
}
```

**Source contract:**
```lua
local source = {}

function source.new(opts)
  local self = setmetatable({}, { __index = source })
  return self
end

function source:enabled()
  return vim.env.PI_NVIM_BRIDGE ~= nil
end

function source:get_trigger_characters()
  return { "/", "@" }
end

function source:get_completions(ctx, callback)
  -- ctx contains: keyword, cursor position, bufnr
  -- callback MUST be called at least once
  -- Items are LSP CompletionItem-shaped
  callback({
    items = { { label = "...", kind = CompletionItemKind.Text } },
    is_incomplete_backward = false,
    is_incomplete_forward = false,
  })
  -- Return cancel function for long-running requests
  return function() end
end

return source
```

## 3. nvim-cmp Source API

```lua
local source = {}

source.new = function()
  return setmetatable({}, { __index = source })
end

function source:is_available()
  return vim.env.PI_NVIM_BRIDGE ~= nil
end

function source:get_trigger_characters()
  return { "/", "@" }
end

function source:complete(params, callback)
  -- params.context, params.offset, params.completion_context
  callback({ { label = "..." } })  -- LSP CompletionItem[]
end

return source

-- Registration: require('cmp').register_source('pi-editor', source.new())
```

## 4. pi Extension API

**Factory pattern:**
```typescript
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { AutocompleteProvider } from "@earendil-works/pi-tui";

export default function (pi: ExtensionAPI): void {
  pi.on("session_start", (event, ctx) => { ... });
  pi.on("session_shutdown", (event, ctx) => { ... });
}
```

**Event handler signature:** `(event, ctx: ExtensionContext) => void | Promise<void>`

**Key ExtensionContext fields:** `ctx.ui.addAutocompleteProvider(factory)`, `ctx.cwd`, `ctx.mode` (`"tui"|"rpc"|"json"|"print"`)

**AutocompleteProviderFactory:** `(current: AutocompleteProvider) => AutocompleteProvider`

## 5. Node.js Builtins Used

- `node:net` — `createServer`, `Socket`, `listen(path)`
- `node:crypto` — `randomUUID()`
- `node:fs` — `chmodSync`, `rmSync`, `existsSync`
- `node:os` — `tmpdir()`
- `node:path` — `join()`

## 6. Test Frameworks

- **Lua:** plenary.nvim (`describe`/`it`/`assert.are.same`), run via `PlenaryBustedFile`
- **TypeScript:** Node built-in test runner or vitest for extension unit tests
- **Linting:** selene (Lua), stylua (formatting)
