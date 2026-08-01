-- === tests/shell_fish_smoke.lua — plenary-FREE, OFFLINE parser smoke (P2.M2.T4.S2) ===
-- The secondary Level-2 gate for `M.parse` (the pure-Lua `complete -C` parser). Drives 5
-- representative inputs through `fish.parse` and asserts the output shape/values WITHOUT
-- plenary (the `-u NORC` harness). NOT gated on `fish` — the parser is pure Lua, runs
-- anywhere (PRD §17.15 "no live fish needed for the parser"). Prints SMOKE_PASS + exits 0
-- (or SMOKE_FAIL + stderr + cquit 1).
--
-- The S1 LIVE driver smoke lives in `tests/shell_fish_driver_smoke.lua` (gated on `fish`);
-- S2's parser smoke is the OFFLINE complement (different file, different concern).
--
-- Run from the REPO ROOT:
--   timeout 60 nvim --headless --clean -u NORC -c 'set rtp+=.' +"luafile tests/shell_fish_smoke.lua" +qa
--   echo "exit=$?"   # 0 + SMOKE_PASS = good; 1 + SMOKE_FAIL = bad
--
-- AGENTS.md HARD RULE: this IS a file on disk — run via :luafile. NEVER heredoc-to-nvim-stdin.
local fish = require("pi-bridge.shell.fish")

local fails = 0
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		fails = fails + 1
	end
end

-- (1) M.parse is a function (surface guard).
check(type(fish.parse) == "function", "fish.parse is not a function (got " .. type(fish.parse) .. ")")

-- (2) §17.15 golden fixture: normal word<TAB>desc.
do
	local got = fish.parse("checkout\tCheckout and switch to a branch\n")
	check(#got == 1, "golden normal: expected 1 item, got " .. #got)
	if got[1] then
		check(got[1].value == "checkout", "golden normal value: got " .. tostring(got[1].value))
		check(
			got[1].description == "Checkout and switch to a branch",
			"golden normal desc: got " .. tostring(got[1].description)
		)
	end
end

-- (3) §17.15 golden fixture: descriptionless bare word (description ABSENT, not "").
do
	local got = fish.parse("cherry\n")
	check(#got == 1, "golden bare: expected 1 item, got " .. #got)
	if got[1] then
		check(got[1].value == "cherry", "golden bare value: got " .. tostring(got[1].value))
		check(got[1].description == nil, "golden bare desc must be ABSENT (got " .. tostring(got[1].description) .. ")")
	end
end

-- (4) realistic `complete -C "git ch"` blob (checkout⇥desc, bare cherry, cherry-pick⇥desc).
do
	local raw = "checkout\tCheckout and switch to a branch\n"
		.. "cherry\n"
		.. "cherry-pick\tApply a commit on another branch\n"
	local got = fish.parse(raw)
	check(#got == 3, "git-ch blob: expected 3 items, got " .. #got)
	local by_val = {}
	for _, it in ipairs(got) do
		by_val[it.value] = it
	end
	check(by_val["checkout"] ~= nil, "git-ch blob: missing checkout")
	check(by_val["cherry"] ~= nil, "git-ch blob: missing cherry")
	check(by_val["cherry-pick"] ~= nil, "git-ch blob: missing cherry-pick")
	check(by_val["cherry"] and by_val["cherry"].description == nil, "git-ch blob: cherry must have NO description")
end

-- (5) literal-tab-in-value: first tab = delimiter (KNOWN LIMITATION, no escape scheme).
do
	local got = fish.parse("a\tb\tc\n")
	check(#got == 1, "literal-tab: expected 1 item, got " .. #got)
	if got[1] then
		check(got[1].value == "a", "literal-tab value: got " .. tostring(got[1].value))
		check(
			got[1].description == "b\tc",
			"literal-tab desc must keep 2nd tab verbatim (got " .. tostring(got[1].description) .. ")"
		)
	end
end

-- (6) never-throws + shape contract: bad inputs → {}; every item has non-empty value,
-- description absent-or-non-empty (the normalize_item input shape).
check(pcall(fish.parse, nil) ~= nil, "fish.parse(nil) threw") -- pcall returns true (truthy) if no throw
check(#fish.parse(nil) == 0, "fish.parse(nil) != {}")
check(#fish.parse(123) == 0, "fish.parse(123) != {}")
check(#fish.parse({}) == 0, "fish.parse({}) != {}")
check(#fish.parse("") == 0, "fish.parse('') != {}")
check(#fish.parse("\t\n") == 0, "lone-tab line must be DROPPED (no {value=''})")

do
	-- shape: every item satisfies the normalize_item input contract.
	local raw = "checkout\tCheckout and switch to a branch\ncherry\ncherry-pick\tApply\n"
	for _, it in ipairs(fish.parse(raw)) do
		check(type(it.value) == "string" and it.value ~= "", "shape: bad value (got " .. tostring(it.value) .. ")")
		if it.description ~= nil then
			check(
				type(it.description) == "string" and it.description ~= "",
				"shape: bad desc (got " .. tostring(it.description) .. ")"
			)
		end
	end
end

if fails > 0 then
	io.stderr:write(fails .. " check(s) failed — fish parser smoke GATE FAILED\n")
	vim.cmd("cquit 1")
end
io.stdout:write("SMOKE_PASS: fish.parse maps complete -C output → {value,description?}[] offline\n")
