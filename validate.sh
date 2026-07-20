#!/usr/bin/env bash
# validate.sh — comprehensive validation for pi-nvim-bridge (extension + nvim plugin).
#
# Runs FIVE phases. Each phase is independent (a failure does not abort the rest); a
# summary is printed at the end. Designed to be re-runnable from the repo root:
#   ./validate.sh
#
# TOOL REQUIREMENTS (auto-detected; a missing tool degrades that phase gracefully):
#   - node + the jiti register that pi ships  (extension typecheck + tests + E2E server)
#   - nvim >= 0.11                            (plugin specs/smokes + E2E client)
#   - plenary.nvim on the standard lazy path  (plugin plenary specs)
#
# SAFETY: every nvim invocation is `timeout`-bounded and loads lua via real FILES
# (`:luafile <file>`), NEVER a heredoc into nvim stdin (per repo AGENTS.md HARD RULE).

set -uo pipefail
cd "$(dirname "$0")"
REPO="$(pwd)"

# ---- tool discovery ----
NODE="${NODE:-node}"
NVIM="${NVIM:-nvim}"
JITI_REG="${JITI_REG:-/home/dustin/.local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti/lib/jiti-register.mjs}"
PLENARY="${PLENARY_PATH:-/home/dustin/.local/share/nvim/lazy/plenary.nvim}"
PLUGIN_RTP="$REPO/plugin"
export PLUGIN_RTP

PASS=0; FAIL=0; PHASE_FAILS=""
note_pass() { PASS=$((PASS+1)); }
note_fail() { FAIL=$((FAIL+1)); PHASE_FAILS="$PHASE_FAILS\n  - $1"; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "============================================================"
echo " pi-nvim-bridge validation"
echo "============================================================"

# ============================================================================
# PHASE 1 — Linting  (no linter configured in-repo: stylua/selene absent)
# ============================================================================
echo
echo "## Phase 1: Linting"
if [ -f stylua.toml ] || [ -f plugin/stylua.toml ] || [ -f selene.yml ] || [ -f plugin/selene.yml ]; then
  echo "  (linter config present — would run here)"
else
  echo "  SKIP: no stylua.toml / selene.yml in repo (no Lua lint/format gate). Not a blocker."
fi

# ============================================================================
# PHASE 2 — Type checking (extension TS)
# ============================================================================
echo
echo "## Phase 2: Type checking (tsc --noEmit, extension/)"
if have "$NODE" && [ -f "$JITI_REG" ]; then
  if timeout 120 npx --no-install tsc --noEmit -p extension/tsconfig.json 2>&1 | tail -20; then
    echo "  RESULT: PASS"; note_pass "typecheck"
  else
    echo "  RESULT: FAIL"; note_fail "typecheck"
  fi
else
  echo "  SKIP: node or jiti register unavailable"
fi

# ============================================================================
# PHASE 3 — Style checking  (no formatter configured)
# ============================================================================
echo
echo "## Phase 3: Style checking"
echo "  SKIP: no .stylua.toml / prettier config (no format gate). See Phase 1."

# ============================================================================
# PHASE 4 — Unit tests
# ============================================================================
echo
echo "## Phase 4: Unit tests"

# 4a — extension node:test suites (via jiti)
echo "  [4a] extension tests (node:test + jiti):"
if have "$NODE" && [ -f "$JITI_REG" ]; then
  epass=0; efail=0
  for f in extension/tests/*.test.ts; do
    if timeout 60 "$NODE" --import "$JITI_REG" "$f" >/dev/null 2>&1; then
      epass=$((epass+1))
    else
      efail=$((efail+1)); echo "    FAIL: $f"
    fi
  done
  echo "    -> $epass passed, $efail failed"
  [ "$efail" -eq 0 ] && note_pass "extension tests" || note_fail "extension tests ($efail failed)"
else
  echo "    SKIP: node/jiti unavailable"
fi

# 4b — plugin plenary specs
echo "  [4b] plugin plenary specs (19):"
if have "$NVIM" && [ -d "$PLENARY" ]; then
  ( cd "$PLUGIN_RTP" || exit 0 )
  spass=0; sfail=0
  for f in "$PLUGIN_RTP"/tests/*_spec.lua; do
    name="$(basename "$f")"
    if timeout 90 "$NVIM" --headless --clean -u "$PLUGIN_RTP/tests/minimal_init.lua" \
        -c "lua require('plenary.busted').run('tests/$name')" >/dev/null 2>&1; then
      spass=$((spass+1))
    else
      sfail=$((sfail+1)); echo "    FAIL: $name"
    fi
  done
  echo "    -> $spass passed, $sfail failed"
  [ "$sfail" -eq 0 ] && note_pass "plenary specs" || note_fail "plenary specs ($sfail failed)"
else
  echo "    SKIP: nvim or plenary unavailable"
fi

# 4c — plugin standalone (plenary-free) smoke tests
echo "  [4c] plugin standalone smoke tests (plenary-free, :luafile):"
if have "$NVIM"; then
  mpass=0; mfail=0; mfailed=""
  for f in "$PLUGIN_RTP"/tests/*_smoke.lua "$PLUGIN_RTP"/tests/smoke.lua; do
    [ -f "$f" ] || continue
    if timeout 60 "$NVIM" --headless --clean -u NORC +"luafile $f" +qa >/dev/null 2>&1; then
      mpass=$((mpass+1))
    else
      mfail=$((mfail+1)); mfailed="$mfailed $(basename "$f")"
    fi
  done
  echo "    -> $mpass passed, $mfail failed${mfailed:+ (FAILED:$mfailed)}"
  [ "$mfail" -eq 0 ] && note_pass "smoke tests" || note_fail "smoke tests ($mfailed)"
else
  echo "    SKIP: nvim unavailable"
fi

# ============================================================================
# PHASE 5 — End-to-end (complete user journeys)
# ============================================================================
echo
echo "## Phase 5: End-to-end"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ----- 5a: real TS bridge <-> real nvim client over an OS Unix socket -----
echo "  [5a] E2E: real bridge extension <-> real nvim bridge.lua (OS socket):"
cat > "$TMP/server.ts" <<'TSERVER'
import { spawn } from "node:child_process";
import { readFileSync, unlinkSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os"; import { join } from "node:path";
import {
  startBridge, stopBridge, BRIDGE_VERSION,
  makeHelloHandler, makeGetSuggestionsHandler, makeApplyCompletionHandler,
  makeShouldTriggerFileCompletionHandler, makePingHandler, makeByeHandler,
  makeGetCommandsHandler, getProvider, captureProvider,
  getToken, getFdAvailable, __setCwdForTest,
} from "__REPO__/extension/pi-editor-bridge.ts";
import { registerBridgeHandler, __resetHandlersForTest, __resetConnectionsForTest } from "__REPO__/extension/connection.ts";
const mock = {
  async getSuggestions(lines: string[], cl: number, cc: number) {
    const before = (lines[cl] ?? "").slice(0, cc);
    if (before.startsWith("/m")) return { items: [{ value: "/model", label: "/model", description: "Select model" }], prefix: before };
    return null;
  },
  applyCompletion(lines: string[], cl: number, _cc: number, item: { value: string }) {
    const nl = [...lines]; nl[cl] = item.value + " ";
    return { lines: nl, cursorLine: cl, cursorCol: item.value.length + 1 };
  },
  shouldTriggerFileCompletion() { return true; },
};
const cwd = mkdtempSync(join(tmpdir(), "pi-e2e-"));
captureProvider({ cwd, mode: "tui", ui: { addAutocompleteProvider: (f: any) => f(mock) } } as any);
__resetHandlersForTest(); __resetConnectionsForTest(); __setCwdForTest(cwd);
startBridge({ cwd, mode: "tui" } as any);
const token = getToken()!;
registerBridgeHandler("hello", makeHelloHandler({ getToken: () => token, getCwd: () => cwd, getFdAvailable, version: BRIDGE_VERSION }));
registerBridgeHandler("getSuggestions", makeGetSuggestionsHandler({ getProvider }));
registerBridgeHandler("applyCompletion", makeApplyCompletionHandler({ getProvider }));
registerBridgeHandler("shouldTriggerFileCompletion", makeShouldTriggerFileCompletionHandler({ getProvider }));
registerBridgeHandler("ping", makePingHandler({ getPid: () => process.pid, getCwd: () => cwd, getFdAvailable, version: BRIDGE_VERSION }));
registerBridgeHandler("bye", makeByeHandler());
registerBridgeHandler("getCommands", makeGetCommandsHandler({ getProvider }));
const RESULT = "__TMP__/result.json"; try { unlinkSync(RESULT); } catch {}
const nvim = spawn("nvim", ["--headless","--clean","-u","NORC","-c","luafile __TMP__/client.lua","-c","qa"],
  { env: { ...process.env, PLUGIN_RTP: "__REPO__/plugin" }, stdio: ["ignore","pipe","pipe"] });
let e=""; nvim.stderr.on("data", d => e+=d);
nvim.on("exit", () => {
  let fails=0; const fail=(m:string)=>{console.error("    "+m);fails++;};
  let res:any; try { res = JSON.parse(readFileSync(RESULT,"utf8")); } catch { console.error("    RESULT MISSING"); if(e)console.error(e.split("\n").slice(0,10).join("\n")); stopBridge(); process.exit(3); }
  if (res.handshake?.err) fail("handshake: "+res.handshake.err);
  else if (typeof res.handshake?.info?.serverVersion !== "string") fail("handshake: no serverVersion");
  if (res.getSuggestions?.err) fail("getSuggestions: "+res.getSuggestions.err);
  else if (!res.getSuggestions?.result?.items?.some((i:any)=>i.value==="/model")) fail("getSuggestions items");
  if (res.ping?.err) fail("ping: "+res.ping.err);
  else if (res.ping?.result?.pid !== process.pid) fail("ping pid mismatch");
  if (res.applyCompletion?.err) fail("applyCompletion: "+res.applyCompletion.err);
  else if (res.applyCompletion?.result?.lines?.[0] !== "/model ") fail("applyCompletion lines");
  stopBridge();
  process.exit(fails?1:0);
});
TSERVER
sed -i "s#__REPO__#$REPO#g; s#__TMP__#$TMP#g" "$TMP/server.ts"

cat > "$TMP/client.lua" <<'LCLIENT'
local rtp = os.getenv("PLUGIN_RTP"); vim.opt.runtimepath:prepend(rtp)
local pi = require("pi-editor"); pi.setup({})
local desc = pi.descriptor or vim.json.decode(vim.env.PI_EDITOR_BRIDGE)
local bridge = require("pi-editor.bridge")
local R = {}
local function wait(name, fn) R[name]={} local d=false
  fn(function(err,res) R[name].err=err; R[name].result=res; d=true end)
  assert(vim.wait(3000, function() return d end, 20), name.." timed out") end
wait("handshake", function(cb) bridge.handshake(desc, cb) end)
local b = require("pi-editor").bridge
assert(b and b.is_connected(), "not connected post-handshake")
wait("getSuggestions", function(cb) b.request("getSuggestions", {lines={"/m"},cursorLine=0,cursorCol=2}, cb) end)
wait("ping", function(cb) b.request("ping", {}, cb) end)
wait("applyCompletion", function(cb) b.request("applyCompletion", {lines={"/m\"},cursorLine=0,cursorCol=2,item={value="/model",label="/model"},prefix="/m"}, cb) end)
local f = io.open(os.getenv("TMP_RESULT"), "w"); f:write(vim.json.encode(R)); f:close()
b.request("bye", {}, function() end); vim.wait(100, function() return false end)
LCLIENT
# fix the escaped quote in the lua heredoc above (luafile string content)
sed -i 's#{lines={"/m\"}#{lines={"/m"}#' "$TMP/client.lua"

if have "$NODE" && [ -f "$JITI_REG" ] && have "$NVIM"; then
  if TMP="$TMP" TMP_RESULT="$TMP/result.json" timeout 60 "$NODE" --import "$JITI_REG" "$TMP/server.ts" >/tmp/validate_5a.log 2>&1; then
    echo "    RESULT: PASS"; note_pass "E2E real-socket"
  else
    echo "    RESULT: FAIL (see /tmp/validate_5a.log)"; tail -12 /tmp/validate_5a.log | sed 's/^/      /'
    note_fail "E2E real-socket"
  fi
else
  echo "    SKIP: node/jiti/nvim unavailable"
fi

# ----- 5b: bad-token security rejection (real bridge, raw socket) -----
echo "  [5b] Security: bad-token -> -32600 + close; correct token -> ok:"
cat > "$TMP/badtoken.ts" <<'TBT'
import { mkdtempSync } from "node:fs"; import { tmpdir } from "node:os"; import { join } from "node:path";
import { createConnection } from "node:net";
import { startBridge, stopBridge, BRIDGE_VERSION, getToken, getFdAvailable,
  makeHelloHandler, captureProvider, __setCwdForTest } from "__REPO__/extension/pi-editor-bridge.ts";
import { registerBridgeHandler, __resetHandlersForTest, __resetConnectionsForTest } from "__REPO__/extension/connection.ts";
const cwd = mkdtempSync(join(tmpdir(), "pi-bt-"));
__resetHandlersForTest(); __resetConnectionsForTest(); __setCwdForTest(cwd);
captureProvider({ cwd, mode: "tui", ui: { addAutocompleteProvider: (f:any)=>f({getSuggestions:async()=>null,applyCompletion:()=>"x" as any}) } } as any);
startBridge({ cwd, mode: "tui" } as any);
const token = getToken()!;
registerBridgeHandler("hello", makeHelloHandler({ getToken: ()=>token, getCwd: ()=>cwd, getFdAvailable, version: BRIDGE_VERSION }));
const path = JSON.parse(process.env.PI_EDITOR_BRIDGE!).path;
let badErr=false, badClose=false;
const s1 = createConnection(path, () => s1.write(JSON.stringify({jsonrpc:"2.0",id:"h1",method:"hello",params:{token:"0".repeat(32)}})+"\n"));
let b1=""; s1.on("data", c => { b1+=c; for (const l of b1.split("\n")) { if(!l.trim())continue; try{const m=JSON.parse(l); if(m.id==="h1"&&m.error?.code===-32600) badErr=true;}catch{} } });
s1.on("close", ()=>{ badClose=true; runGood(); });
s1.on("error", ()=>{});
setTimeout(()=>{ if(!s1.destroyed) s1.destroy(); runGood(); }, 1500);
let ranGood=false;
function runGood(){ if(ranGood) return; ranGood=true;
  let ok=false; const s2=createConnection(path, ()=>s2.write(JSON.stringify({jsonrpc:"2.0",id:"h1",method:"hello",params:{token}})+"\n"));
  let b2=""; s2.on("data",c=>b2+=c);
  s2.on("close",()=>{ for(const l of b2.split("\n")){if(!l.trim())continue;try{const m=JSON.parse(l);if(m.id==="h1"&&m.result?.ok===true)ok=true;}catch{}}
    let f=0; if(!badErr){console.error("    FAIL: no -32600 for bad token");f++;} if(!badClose){console.error("    FAIL: not closed after bad token");f++;}
    if(!ok){console.error("    FAIL: correct token rejected");f++;} stopBridge(); process.exit(f?1:0); });
  setTimeout(()=>{ if(!s2.destroyed) s2.destroy(); }, 1500);
}
TBT
sed -i "s#__REPO__#$REPO#g" "$TMP/badtoken.ts"
if have "$NODE" && [ -f "$JITI_REG" ]; then
  if timeout 30 "$NODE" --import "$JITI_REG" "$TMP/badtoken.ts" >/tmp/validate_5b.log 2>&1; then
    echo "    RESULT: PASS"; note_pass "bad-token security"
  else
    echo "    RESULT: FAIL (see /tmp/validate_5b.log)"; tail -8 /tmp/validate_5b.log | sed 's/^/      /'
    note_fail "bad-token security"
  fi
else
  echo "    SKIP: node/jiti unavailable"
fi

# ----- 5c: targeted module validations (coords multibyte, autosave, dormant, health, help) -----
echo "  [5c] Targeted: multibyte coords + autosave + dormant + checkhealth + :help:"
cat > "$TMP/targeted.lua" <<'LTGT'
local rtp = os.getenv("PLUGIN_RTP"); vim.opt.runtimepath:prepend(rtp)
local fails=0; local function check(c,m) if not c then io.stderr:write("    FAIL: "..m.."\n"); fails=fails+1 end end
local pi = require("pi-editor"); pi.setup({})
local coords = require("pi-editor.coords")
check(coords.byte_to_utf16("a😀b",5)==3, "astral byte5->utf16 3 (😀 = 2 units, NOT the v1 codepoint approx)")
check(coords.byte_to_utf16("a😀b",6)==4, "astral EOL -> utf16 4")
check(coords.utf16_to_byte("a😀b",3)==5, "astral utf16 3 -> byte 5 (inverse)")
check(pcall(coords.byte_to_utf16,"hi",999), "out-of-range clamps, does not throw")
-- autosave (PRD §11 critical lost-prompt fix)
local tmp = os.tmpname(); local f=io.open(tmp,"w"); f:write("orig\n"); f:close()
vim.cmd("edit "..tmp); local b=vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(b,0,-1,false,{"edited"})
check(vim.bo[b].modified, "buffer modified pre-exit")
require("pi-editor.bridge").on_exit(b)
check(not vim.bo[b].modified, "autosave fired on on_exit")
local g=io.open(tmp,"r"); check(g:read("*a")=="edited\n", "autosave wrote edited content"); g:close(); os.remove(tmp)
-- dormant gate
pi.descriptor=nil; local sv=vim.env.PI_EDITOR_BRIDGE; vim.env.PI_EDITOR_BRIDGE=nil
check(pi.activate()==nil, "dormant: activate() nil w/o env var"); vim.env.PI_EDITOR_BRIDGE=sv
-- checkhealth + help run without throwing
check(pcall(vim.cmd, "checkhealth pi-editor"), "checkhealth runs")
check(pcall(vim.cmd, "help pi-editor"), ":help pi-editor resolves")
if fails>0 then os.exit(1) end
LTGT
if have "$NVIM"; then
  if timeout 60 "$NVIM" --headless --clean -u NORC -c "luafile $TMP/targeted.lua" -c "qa" >/tmp/validate_5c.log 2>&1; then
    echo "    RESULT: PASS"; note_pass "targeted modules"
  else
    echo "    RESULT: FAIL (see /tmp/validate_5c.log)"; cat /tmp/validate_5c.log | sed 's/^/      /' | head -15
    note_fail "targeted modules"
  fi
else
  echo "    SKIP: nvim unavailable"
fi

# ============================================================================
# SUMMARY
# ============================================================================
echo
echo "============================================================"
echo " SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && echo -e " FAILURES:$PHASE_FAILS"
echo "============================================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1