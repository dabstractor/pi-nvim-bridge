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
	end)
end)
