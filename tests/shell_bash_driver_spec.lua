-- === tests/shell_bash_driver_spec.lua — plenary/busted spec (P2.M3.T5.S2) ===
-- Covers the contract surface of the REAL bash driver: the start(opts,on_ready)/cd(path)
-- signature, the never-throws discipline, the failure paths (bad shell / spawn err) with
-- NO leaked handles, the pure-Lua M.parse, and (LIVE, UNCONDITIONAL — bash is universal
-- on Linux CI; PRD §17.15 — no pending/skip) the real spawn → on_ready(nil,proc,stdin,
-- stdout) + the "ls /tm" → /tmp + "gi" → git + "ls " → cwd entries (§3 fix) round-trips.
--
-- MOCKS nothing for the LIVE case (it spawns the real bash); the OFFLINE cases use a
-- bogus shell path + nil cb (no subprocess). Sets package.loaded["pi-bridge.shell.bash"]=nil
-- in after_each so the real module doesn't leak into shell.lua's fake-driver tests
-- (the existing-spec convention — shell_ensure_spec.lua does the same).
--
-- Run (from the repo root):
--   timeout 90 nvim --headless --clean -u tests/minimal_init.lua \
--     -c 'lua require("plenary.busted").run("tests/shell_bash_driver_spec.lua")'
local bash = require("pi-bridge.shell.bash")
local uv = vim.uv

-- count OPEN (not closing) uv handles of a given shape (the no-leak assertion; mirrors
-- shell_complete_current_spec.lua count_open_timers).
local function count_open_handles()
	local n = 0
	uv.walk(function(h)
		if type(h) == "userdata" and not h:is_closing() then
			n = n + 1
		end
	end)
	return n
end

describe("pi-bridge.shell.bash driver (P2.M3.T5.S2)", function()
	after_each(function()
		-- cleanup so the real module doesn't leak into shell.lua's fake-driver tests.
		package.loaded["pi-bridge.shell.bash"] = nil
		-- re-require so the next `it` (same describe) still sees the module if the nil
		-- happened mid-suite; bash is a stateless module so re-require is free.
		bash = require("pi-bridge.shell.bash")
	end)

	describe("offline contract (no subprocess)", function()
		it("exports M.start, M.cd, M.parse as functions + require loads without error", function()
			assert.is_truthy(bash, "require('pi-bridge.shell.bash') returned nil")
			assert.are.equals("function", type(bash.start))
			assert.are.equals("function", type(bash.cd))
			assert.are.equals("function", type(bash.parse))
		end)

		it("M.start({}, nil) does NOT throw on a non-function on_ready (never-throws)", function()
			assert.has_no.errors(function()
				bash.start({}, nil)
				bash.start({}, 123)
				bash.start({}, "not a function")
			end)
		end)

		it("M.start with a bogus shell path → on_ready(err, nil,nil,nil); no leaked handles", function()
			local before = count_open_handles()
			local got_err = "UNSET"
			local got_proc, got_stdin, got_stdout = "UNSET", "UNSET", "UNSET"
			bash.start({
				shell = "/nonexistent/path/bash-definitely-missing-xyz",
				cwd = vim.fn.getcwd(),
				startup_timeout_ms = 500,
			}, function(err, proc, stdin, stdout)
				got_err = err
				got_proc, got_stdin, got_stdout = proc, stdin, stdout
			end)
			-- the spawn fails immediately OR the startup timer fires; either way on_ready
			-- MUST fire within a small budget. Drive the loop.
			vim.wait(2000, function()
				return got_err ~= "UNSET"
			end, 20)
			-- give luv a tick to finalize any pending closes.
			vim.wait(100, function()
				return false
			end, 50)

			assert.is_truthy(got_err and got_err ~= "UNSET", "on_ready never fired for the bogus shell")
			assert.is_nil(got_proc, "on_ready proc must be nil on failure (got " .. tostring(got_proc) .. ")")
			assert.is_nil(got_stdin, "on_ready stdin must be nil on failure")
			assert.is_nil(got_stdout, "on_ready stdout must be nil on failure")
			-- no leaked handles: the count after must not exceed the count before (every
			-- handle the driver created on the failure path must be closed).
			local after = count_open_handles()
			assert.is_true(
				after <= before,
				"handle leak: before="
					.. tostring(before)
					.. " after="
					.. tostring(after)
					.. " (err="
					.. tostring(got_err)
					.. ")"
			)
		end)

		it("M.start never throws on a missing cwd / missing startup_timeout_ms (defaults)", function()
			-- use a bogus shell so no subprocess lingers; we only assert never-throws here.
			assert.has_no.errors(function()
				bash.start({ shell = "/nonexistent/bash-xyz" }, function() end)
			end)
			-- drain any pending timer so it doesn't leak across the suite.
			vim.wait(800, function()
				return false
			end, 50)
		end)

		it("M.cd never throws on bad args (nil/empty/number) or when no daemon is running", function()
			assert.has_no.errors(function()
				bash.cd(nil)
				bash.cd("")
				bash.cd(123)
				bash.cd("/tmp") -- no daemon started in this case → silent noop
			end)
		end)

		it("M.parse parses bare-word lines into {value} (no description — Tier-2 §8)", function()
			-- bash compgen/COMPREPLY emit bare words, one per line — NO tab-split (unlike fish/zsh).
			local items = bash.parse("/tmp\n/var\n/etc\n")
			assert.are.equals(3, #items)
			assert.are.equals("/tmp", items[1].value)
			assert.is_nil(items[1].description, "bash items have NO description key (Tier-2, §8)")
			assert.are.equals("/var", items[2].value)
			assert.is_nil(items[2].description, "items[2] has no description key")
			assert.are.equals("/etc", items[3].value)
			assert.is_nil(items[3].description, "items[3] has no description key")
		end)

		it("M.parse never throws + returns {} on bad input", function()
			assert.has_no.errors(function()
				bash.parse(nil)
				bash.parse(123)
				bash.parse("")
				bash.parse("\n\n\r\n")
			end)
			assert.are.same({}, bash.parse(nil))
			assert.are.same({}, bash.parse(123))
			assert.are.same({}, bash.parse(""))
			-- empty lines are dropped (gmatch skips them).
			assert.are.same({}, bash.parse("\n\n\r\n"))
		end)

		it("M.parse treats each line as a value (no tab-split, unlike fish/zsh)", function()
			-- a line containing a tab is STILL a single value (bash has no description channel;
			-- the tab is part of the word, not a delimiter — Tier-2 §8 documented limitation).
			local items = bash.parse("a\tb\nc\n")
			assert.are.equals(2, #items)
			assert.are.equals("a\tb", items[1].value, "bash parse must NOT tab-split (Tier-2)")
			assert.are.equals("c", items[2].value)
		end)
	end)

	describe("LIVE driver (bash universal on Linux — runs UNCONDITIONALLY; PRD §17.15)", function()
		-- bash is present on essentially every Linux CI runner (unlike fish/zsh). The LIVE
		-- case runs unconditionally — stronger coverage than the fish/zsh specs (which skip
		-- when the shell is absent). The executable check is a defensive guard only.
		local have_bash = vim.fn.executable("bash") == 1

		-- Build a request frame byte-for-byte like shell.lua M.request (avoids hand-escaping
		-- the embedded quote in a `git "feature` line). SAME encoding M.request step (6) uses.
		local function make_frame(line, cursor, after)
			local l_str = vim.json.encode(line)
			local a_str = vim.json.encode(after or "")
			local payload = string.format('{"line":%s,"cursor":%d,"after":%s}', l_str, cursor, a_str)
			return string.format('__PIREQ__\t%s\n', payload)
		end

		-- shared spawn/teardown helper (each `it` spawns its OWN daemon + tears it down —
		-- no state shared across `it`s). Mirrors the fish S1 spec's idiom.
		local function spawn_daemon(on_ready_cb)
			local ready = false
			local start_err = "UNSET"
			local proc, stdin, stdout
			bash.start({
				shell = "bash",
				cwd = vim.fn.getcwd(),
				startup_timeout_ms = 5000,
			}, function(err, p, si, so)
				start_err = err
				if not err then
					proc, stdin, stdout = p, si, so
				end
				ready = true
				if not err and on_ready_cb then
					on_ready_cb(proc, stdin, stdout)
				end
			end)
			vim.wait(8000, function()
				return ready
			end, 20)
			return start_err, proc, stdin, stdout
		end

		local function teardown_daemon(proc, stdin, stdout)
			pcall(function()
				if proc and not proc:is_closing() then
					uv.process_kill(proc, "sigkill")
				end
			end)
			pcall(function()
				if proc and not proc:is_closing() then
					proc:close()
				end
			end)
			pcall(function()
				if stdin and not stdin:is_closing() then
					stdin:close()
				end
			end)
			pcall(function()
				if stdout and not stdout:is_closing() then
					stdout:read_stop()
					stdout:close()
				end
			end)
		end

		it("start → on_ready(nil, proc, stdin, stdout) + 'ls /tm' → /tmp in items", function()
			if not have_bash then
				pending(
					"bash not on PATH — LIVE case skipped (defensive; essentially never on Linux)",
					function() end
				)
				return
			end
			local ready = false
			local start_err = "UNSET"
			local proc, stdin, stdout
			bash.start({
				shell = "bash",
				cwd = vim.fn.getcwd(),
				startup_timeout_ms = 5000,
			}, function(err, p, si, so)
				start_err = err
				if err then
					ready = true
					return
				end
				proc, stdin, stdout = p, si, so
				ready = true
			end)
			-- drive the loop until on_ready fires (async — the __PIREADY__ marker arrives on
			-- stderr after best-effort bash-completion sourcing; bash cold-start is FAST).
			vim.wait(8000, function()
				return ready
			end, 20)
			assert.is_nil(start_err, "LIVE start on_ready err=" .. tostring(start_err))
			assert.is_truthy(proc, "LIVE proc handle missing")
			assert.is_truthy(stdin, "LIVE stdin pipe missing")
			assert.is_truthy(stdout, "LIVE stdout pipe missing")

			-- wire stdout (the spec stands in for shell.lua's _feed route) + send "ls /tm".
			local rx_buf = ""
			local decoded = nil
			pcall(function()
				stdout:read_start(function(rerr, data)
					if rerr or not data then
						return
					end
					rx_buf = rx_buf .. data
					local s = rx_buf:find("__PIRESP_START__\n", 1, true)
					local e = s and rx_buf:find("__PIRESP_END__\n", s + 1, true)
					if s and e then
						local payload = rx_buf:sub(s + #"__PIRESP_START__\n", e - 1)
						local ok, d = pcall(vim.json.decode, payload)
						if ok and type(d) == "table" then
							decoded = d
						end
					end
				end)
			end)
			pcall(function()
				stdin:write('__PIREQ__\t{"line":"ls /tm","cursor":6,"after":""}\n')
			end)
			vim.wait(5000, function()
				return decoded ~= nil
			end, 20)

			assert.is_truthy(decoded, "LIVE 'ls /tm' response never decoded")
			if decoded then
				local items = (type(decoded.items) == "table") and decoded.items or {}
				local found_tmp = false
				for _, it in ipairs(items) do
					if it.value == "/tmp" then
						found_tmp = true
					end
				end
				assert.is_true(#items > 0, "LIVE 'ls /tm' decoded but empty (compgen -f -d returned nothing?)")
				assert.is_true(found_tmp == true, "LIVE 'ls /tm' missing /tmp (the §5 files/dirs floor)")
			end

			-- teardown the live daemon (shell.lua owns this in prod).
			pcall(function()
				if proc and not proc:is_closing() then
					uv.process_kill(proc, "sigkill")
				end
			end)
			pcall(function()
				if proc and not proc:is_closing() then
					proc:close()
				end
			end)
			pcall(function()
				if stdin and not stdin:is_closing() then
					stdin:close()
				end
			end)
			pcall(function()
				if stdout and not stdout:is_closing() then
					stdout:read_stop()
					stdout:close()
				end
			end)
		end)

		it("'gi' → git (cword==0 command-name completion — §4)", function()
			if not have_bash then
				pending("bash not on PATH — LIVE case skipped (defensive)", function() end)
				return
			end
			local ready = false
			local proc, stdin, stdout
			bash.start({ shell = "bash", cwd = vim.fn.getcwd(), startup_timeout_ms = 5000 }, function(err, p, si, so)
				if err then
					ready = true
					return
				end
				proc, stdin, stdout = p, si, so
				ready = true
			end)
			vim.wait(8000, function()
				return ready
			end, 20)
			assert.is_truthy(proc, "LIVE proc handle missing")

			local rx_buf = ""
			local decoded = nil
			pcall(function()
				stdout:read_start(function(rerr, data)
					if rerr or not data then
						return
					end
					rx_buf = rx_buf .. data
					local s = rx_buf:find("__PIRESP_START__\n", 1, true)
					local e = s and rx_buf:find("__PIRESP_END__\n", s + 1, true)
					if s and e then
						local payload = rx_buf:sub(s + #"__PIRESP_START__\n", e - 1)
						local ok, d = pcall(vim.json.decode, payload)
						if ok and type(d) == "table" then
							decoded = d
						end
					end
				end)
			end)
			pcall(function()
				stdin:write('__PIREQ__\t{"line":"gi","cursor":2,"after":""}\n')
			end)
			vim.wait(5000, function()
				return decoded ~= nil
			end, 20)

			assert.is_truthy(decoded, "LIVE 'gi' response never decoded")
			if decoded then
				local items = (type(decoded.items) == "table") and decoded.items or {}
				local found_git = false
				for _, it in ipairs(items) do
					if it.value == "git" then
						found_git = true
					end
				end
				assert.is_true(#items > 0, "LIVE 'gi' decoded but empty (compgen -abck returned nothing?)")
				assert.is_true(found_git == true, "LIVE 'gi' missing git (the §4 cword==0 command-name branch)")
			end

			pcall(function()
				if proc and not proc:is_closing() then
					uv.process_kill(proc, "sigkill")
				end
			end)
			pcall(function()
				if proc and not proc:is_closing() then
					proc:close()
				end
			end)
			pcall(function()
				if stdin and not stdin:is_closing() then
					stdin:close()
				end
			end)
			pcall(function()
				if stdout and not stdout:is_closing() then
					stdout:read_stop()
					stdout:close()
				end
			end)
		end)

		it("'ls ' (trailing space) → cwd entries (the §3 COMP_CWORD fix)", function()
			if not have_bash then
				pending("bash not on PATH — LIVE case skipped (defensive)", function() end)
				return
			end
			local ready = false
			local proc, stdin, stdout
			bash.start({ shell = "bash", cwd = vim.fn.getcwd(), startup_timeout_ms = 5000 }, function(err, p, si, so)
				if err then
					ready = true
					return
				end
				proc, stdin, stdout = p, si, so
				ready = true
			end)
			vim.wait(8000, function()
				return ready
			end, 20)
			assert.is_truthy(proc, "LIVE proc handle missing")

			local rx_buf = ""
			local decoded = nil
			pcall(function()
				stdout:read_start(function(rerr, data)
					if rerr or not data then
						return
					end
					rx_buf = rx_buf .. data
					local s = rx_buf:find("__PIRESP_START__\n", 1, true)
					local e = s and rx_buf:find("__PIRESP_END__\n", s + 1, true)
					if s and e then
						local payload = rx_buf:sub(s + #"__PIRESP_START__\n", e - 1)
						local ok, d = pcall(vim.json.decode, payload)
						if ok and type(d) == "table" then
							decoded = d
						end
					end
				end)
			end)
			-- "ls " (trailing space, point=3) — the §3 fix makes cur="" → cwd file/dir completion.
			pcall(function()
				stdin:write('__PIREQ__\t{"line":"ls ","cursor":3,"after":""}\n')
			end)
			vim.wait(5000, function()
				return decoded ~= nil
			end, 20)

			assert.is_truthy(decoded, "LIVE 'ls ' response never decoded")
			if decoded then
				local items = (type(decoded.items) == "table") and decoded.items or {}
				-- §3 fix: assert cwd entries (NOT command-name completion of "ls").
				local found_ls = false
				for _, it in ipairs(items) do
					if it.value == "ls" or it.value == "lsof" then
						found_ls = true
					end
				end
				assert.is_true(#items > 0, "LIVE 'ls ' decoded but empty (cwd has no entries?)")
				assert.is_false(
					found_ls,
					"LIVE 'ls ' returned ls/lsof — the §3 COMP_CWORD fix FAILED (got command-name completion instead of cwd entries)"
				)
			end

			pcall(function()
				if proc and not proc:is_closing() then
					uv.process_kill(proc, "sigkill")
				end
			end)
			pcall(function()
				if proc and not proc:is_closing() then
					proc:close()
				end
			end)
			pcall(function()
				if stdin and not stdin:is_closing() then
					stdin:close()
				end
			end)
			pcall(function()
				if stdout and not stdout:is_closing() then
					stdout:read_stop()
					stdout:close()
				end
			end)
		end)

		it("NEW-1: 'git ch' (cword>0) — lazy-load code path is non-regressing (responds + stays responsive)", function()
			if not have_bash then
				pending("bash not on PATH — LIVE case skipped (defensive)", function() end)
				return
			end
			local start_err, proc, stdin, stdout = spawn_daemon()
			assert.is_nil(start_err, "LIVE start on_ready err=" .. tostring(start_err))
			assert.is_truthy(proc, "LIVE proc handle missing")

			-- rx_buf persists across the two frames; resolvers fire in send order.
			local rx_buf = ""
			local r_git, r_followup = nil, nil
			pcall(function()
				stdout:read_start(function(rerr, data)
					if rerr or not data then
						return
					end
					rx_buf = rx_buf .. data
					-- decode EVERY complete frame in rx_buf (handles both responses landing in one read)
					local pos = 1
					while pos do
						local s = rx_buf:find("__PIRESP_START__\n", pos, true)
						local e = s and rx_buf:find("__PIRESP_END__\n", s + 1, true)
						if s and e then
							local payload = rx_buf:sub(s + #"__PIRESP_START__\n", e - 1)
							local ok, d = pcall(vim.json.decode, payload)
							if ok and type(d) == "table" then
								if not r_git then
									r_git = d
								else
									r_followup = d
								end
							end
							pos = e + 1
						else
							pos = nil
						end
					end
				end)
			end)
			-- 'git ch' (cword>0, cur='ch') — exercises the NEW-1 lazy-load code path (the
			-- `complete -p -D` lookup + loader invocation + `complete -p "$cmd"` re-check).
			-- On a box WITH bash-completion (lazy): returns git subcommands (checkout, etc.).
			-- On a box WITHOUT (e.g. CI): falls through to file/dir fallback (may be empty).
			-- Either way the daemon MUST respond valid JSON + stay responsive (the lazy-load
			-- block runs in the daemon shell, NOT a subshell that could crash it).
			pcall(function()
				stdin:write(make_frame("git ch", 6, ""))
			end)
			vim.wait(5000, function()
				return r_git ~= nil
			end, 20)
			assert.is_truthy(r_git, "LIVE 'git ch' response never decoded (lazy-load path crashed the daemon?)")
			-- the daemon MUST still respond to a follow-up request (lazy-load did not wedge it)
			pcall(function()
				stdin:write(make_frame("gi", 2, ""))
			end)
			vim.wait(5000, function()
				return r_followup ~= nil
			end, 20)
			assert.is_truthy(r_followup, "LIVE daemon wedged after the lazy-load path (follow-up 'gi' never decoded)")

			teardown_daemon(proc, stdin, stdout)
		end)

		it("empty line → empty items (no all-commands flood)", function()
			if not have_bash then
				pending("bash not on PATH — LIVE case skipped (defensive)", function() end)
				return
			end
			local start_err, proc, stdin, stdout = spawn_daemon()
			assert.is_nil(start_err, "LIVE start on_ready err=" .. tostring(start_err))
			assert.is_truthy(proc, "LIVE proc handle missing")

			local rx_buf = ""
			local decoded = nil
			pcall(function()
				stdout:read_start(function(rerr, data)
					if rerr or not data then
						return
					end
					rx_buf = rx_buf .. data
					local s = rx_buf:find("__PIRESP_START__\n", 1, true)
					local e = s and rx_buf:find("__PIRESP_END__\n", s + 1, true)
					if s and e then
						local payload = rx_buf:sub(s + #"__PIRESP_START__\n", e - 1)
						local ok, d = pcall(vim.json.decode, payload)
						if ok and type(d) == "table" then
							decoded = d
						end
					end
				end)
			end)
			pcall(function()
				stdin:write(make_frame("", 0, ""))
			end)
			vim.wait(5000, function()
				return decoded ~= nil
			end, 20)

			assert.is_truthy(decoded, "LIVE empty-line response never decoded")
			if decoded then
				local items = (type(decoded.items) == "table") and decoded.items or {}
				assert.are.equals(0, #items,
					"empty line should yield 0 items, got " .. tostring(#items) .. " (FLOOD not suppressed)")
			end

			teardown_daemon(proc, stdin, stdout)
		end)

		it("quote-line → empty items AND daemon stays responsive on the NEXT request (no flood)", function()
			if not have_bash then
				pending("bash not on PATH — LIVE case skipped (defensive)", function() end)
				return
			end
			local start_err, proc, stdin, stdout = spawn_daemon()
			assert.is_nil(start_err, "LIVE start on_ready err=" .. tostring(start_err))
			assert.is_truthy(proc, "LIVE proc handle missing")

			-- rx_buf persists across the two frames (the responsiveness check decodes BOTH on
			-- the SAME stdout read). resolvers fire in send order.
			local rx_buf = ""
			local r_quote, r_followup = nil, nil
			pcall(function()
				stdout:read_start(function(rerr, data)
					if rerr or not data then
						return
					end
					rx_buf = rx_buf .. data
					-- drain every complete START..END pair in the buffer (a chunk may carry both).
					while true do
						local s = rx_buf:find("__PIRESP_START__\n", 1, true)
						if not s then
							break
						end
						local ps = s + #"__PIRESP_START__\n"
						local e = rx_buf:find("__PIRESP_END__\n", ps, true)
						if not e then
							break
						end
						local payload = rx_buf:sub(ps, e - 1)
						rx_buf = rx_buf:sub(e + #"__PIRESP_END__\n")
						local ok, d = pcall(vim.json.decode, payload)
						if ok and type(d) == "table" then
							local items = (type(d.items) == "table") and d.items or {}
							if r_quote == nil then
								r_quote = items
							else
								r_followup = items
							end
						end
					end
				end)
			end)

			-- (1) the quote-frame: `git "feature` extracts to a TRAILING-BACKSLASH line → guard
			--     must emit empty BEFORE compgen/complete -F (no flood).
			pcall(function()
				stdin:write(make_frame('git "feature', 11, ""))
			end)
			vim.wait(5000, function()
				return r_quote ~= nil
			end, 20)

			-- (2) the FOLLOW-UP on the SAME daemon: `ls /tm` → /tmp. If the quote had wedged the
			--     daemon, this follow-up would hang → timeout → r_followup stays nil.
			pcall(function()
				stdin:write(make_frame("ls /tm", 6, ""))
			end)
			vim.wait(5000, function()
				return r_followup ~= nil
			end, 20)

			assert.is_truthy(r_quote, "quote-frame never resolved — daemon died (guard did not fire)")
			if r_quote then
				assert.are.equals(0, #r_quote,
					"quote-line should yield 0 items, got " .. tostring(#r_quote) .. " (flood not suppressed)")
			end
			assert.is_truthy(r_followup,
				"follow-up `ls /tm` never resolved — daemon did NOT stay responsive after the quote-frame")
			if r_followup then
				local found_tmp = false
				for _, it in ipairs(r_followup) do
					if it.value == "/tmp" then
						found_tmp = true
					end
				end
				assert.is_true(found_tmp,
					"follow-up `ls /tm` missing /tmp (daemon degraded after the quote-frame)")
			end

			teardown_daemon(proc, stdin, stdout)
		end)
	end)
end)
