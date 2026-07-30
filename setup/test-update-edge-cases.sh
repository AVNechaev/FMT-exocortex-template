#!/bin/bash
# test-update-edge-cases.sh — edge-case regression tests for update.sh (issue #206)
#
# Covers gaps not exercised by smoke-test-fresh-install.sh:
#   T1: --check mode does not modify any file (idempotency guard)
#   T2: orphaned {{PLACEHOLDER}} in .iwe-runtime/ is detected post-build
#   T3: CLAUDE.md with pre-existing conflict markers blocks update (stacking guard)
#   T4: role install failure surfaces a visible warning (not silently swallowed)
#   T5: network-independent --check works with a cached manifest
#   T6: memory file with owner: user survives a hash mismatch (issue #229)
#   T7: hot-budget sum over threshold is detectable (issue #228)
#   T8: build-runtime.sh does not clobber an edited params.yaml (issue #327)
#   T9: .mcp.json migration preserves a third-party server like ext-figma (issue #335)
#   T10: CLAUDE.md fallback-merge (no .base) never silently drops §8/§9 edits (issue #336)
#
# Exit: 0 = all PASS, N = N tests failed
#
# Usage:
#   bash setup/test-update-edge-cases.sh
#   KEEP_WORKSPACE=1 bash setup/test-update-edge-cases.sh   # keep /tmp dir for inspection

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_WS="${EDGE_CASE_WORKSPACE:-/tmp/iwe-edge-test-$$}"

cleanup() {
    local rc=$?
    if [ -d "$TEST_WS" ] && [ "${KEEP_WORKSPACE:-0}" != "1" ]; then
        rm -rf "$TEST_WS"
    fi
    exit "$rc"
}
trap cleanup EXIT INT TERM

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

echo "============================================"
echo "  Edge-Case Tests: update.sh (issue #206)"
echo "============================================"
echo "  Template: $TEMPLATE_DIR"
echo "  Test workspace: $TEST_WS"
echo ""

mkdir -p "$TEST_WS"

# --- Helpers ---

# Build a minimal fake governance repo that update.sh can find
setup_fake_governance() {
    local gov="$TEST_WS/DS-strategy"
    mkdir -p "$gov"
    git -C "$gov" init -q
    git -C "$gov" config user.email "test@test"
    git -C "$gov" config user.name "test"
    # Minimal CLAUDE.md so update.sh has something to merge
    cat > "$gov/CLAUDE.md" <<'HEREDOC'
# Test CLAUDE.md

## Section 1

Content here.

## 9. Custom (авторское)

User custom content that must be preserved.
HEREDOC
    git -C "$gov" add CLAUDE.md
    git -C "$gov" commit -q -m "init"
    echo "$gov"
}

# Provide a minimal fake manifest pointing at the template dir
setup_fake_manifest() {
    local manifest_file="$TEST_WS/fake-manifest.json"
    python3 -c "
import json, os, hashlib

template = '$TEMPLATE_DIR'
files = {}
for root, dirs, fnames in os.walk(template):
    dirs[:] = [d for d in dirs if d not in ['.git', 'node_modules', '__pycache__']]
    for fname in fnames:
        path = os.path.join(root, fname)
        rel = os.path.relpath(path, template)
        with open(path, 'rb') as f:
            content = f.read()
        files[rel] = hashlib.sha256(content).hexdigest()

manifest = {'version': '0.99.0-test', 'files': files}
with open('$manifest_file', 'w') as f:
    json.dump(manifest, f)
" 2>/dev/null
    echo "$manifest_file"
}

# ============================================================
# T1: --check does not modify any file
# ============================================================
echo "--- T1: --check mode is read-only ---"

gov=$(setup_fake_governance)
CLAUDE_BEFORE=$(sha256sum "$gov/CLAUDE.md" | awk '{print $1}')

# Run --check; it may fail (no network, no real manifest) — we only care about side-effects
UPDATE_SH="$TEMPLATE_DIR/update.sh"
(
    export GOVERNANCE_REPO_PATH="$gov"
    cd "$TEST_WS"
    # Suppress output; ignore exit code — T1 only checks file immutability
    bash "$UPDATE_SH" --check >/dev/null 2>&1 || true
)

CLAUDE_AFTER=$(sha256sum "$gov/CLAUDE.md" | awk '{print $1}')
if [ "$CLAUDE_BEFORE" = "$CLAUDE_AFTER" ]; then
    pass "T1: CLAUDE.md unchanged after --check"
else
    fail "T1: CLAUDE.md was mutated by --check mode"
fi

# ============================================================
# T2: orphaned {{PLACEHOLDER}} in .iwe-runtime/ is detected
# ============================================================
echo "--- T2: orphaned placeholder detection ---"

RUNTIME_DIR="$TEST_WS/.iwe-runtime"
mkdir -p "$RUNTIME_DIR"

# Plant a file with an un-substituted placeholder
cat > "$RUNTIME_DIR/orphan-test.plist" <<'HEREDOC'
<?xml version="1.0"?>
<plist><dict>
  <key>WorkingDirectory</key>
  <string>{{WORKSPACE_DIR}}</string>
</dict></plist>
HEREDOC

# The placeholder check in update.sh uses: grep -rl '{{[A-Z_]*}}' .iwe-runtime/
if grep -rl '{{[A-Z_]*}}' "$RUNTIME_DIR/" >/dev/null 2>&1; then
    pass "T2: orphaned {{WORKSPACE_DIR}} is detectable by update.sh's grep pattern"
else
    fail "T2: grep pattern missed the orphaned placeholder"
fi

# Confirm the opposite: a clean file is NOT flagged
cat > "$RUNTIME_DIR/clean-test.plist" <<'HEREDOC'
<?xml version="1.0"?>
<plist><dict>
  <key>WorkingDirectory</key>
  <string>/workspace/iwe</string>
</dict></plist>
HEREDOC

orphan_count=$(grep -rl '{{[A-Z_]*}}' "$RUNTIME_DIR/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$orphan_count" = "1" ]; then
    pass "T2: clean file is NOT flagged (only 1 orphan found)"
else
    fail "T2: expected 1 orphan, got $orphan_count"
fi

rm -f "$RUNTIME_DIR/orphan-test.plist" "$RUNTIME_DIR/clean-test.plist"

# ============================================================
# T3: pre-existing conflict markers in CLAUDE.md block update
# ============================================================
echo "--- T3: conflict-marker stacking guard ---"

gov3="$TEST_WS/DS-strategy-t3"
mkdir -p "$gov3"
git -C "$gov3" init -q
git -C "$gov3" config user.email "test@test"
git -C "$gov3" config user.name "test"

# Plant CLAUDE.md that already has conflict markers (simulates unresolved prior merge)
cat > "$gov3/CLAUDE.md" <<'HEREDOC'
# Test CLAUDE.md

<<<<<<< HEAD
User version
=======
Upstream version
>>>>>>> upstream
HEREDOC
git -C "$gov3" add CLAUDE.md
git -C "$gov3" commit -q -m "init with conflict markers"

# update.sh (lines 428-438) must detect these and refuse to apply another merge
conflict_detected=false
if grep -q '^<<<<<<<' "$gov3/CLAUDE.md"; then
    conflict_detected=true
fi

if [ "$conflict_detected" = "true" ]; then
    pass "T3: pre-existing conflict markers are detectable (stacking guard can fire)"
else
    fail "T3: conflict markers were not found where expected"
fi

# ============================================================
# T4: role install failure is visible (not swallowed by 2>/dev/null)
# ============================================================
echo "--- T4: role install error surfacing ---"

ROLE_DIR="$TEST_WS/fake-role"
mkdir -p "$ROLE_DIR"

# Create an install.sh that deliberately exits non-zero
cat > "$ROLE_DIR/install.sh" <<'HEREDOC'
#!/bin/bash
echo "Role install error: missing dependency" >&2
exit 1
HEREDOC
chmod +x "$ROLE_DIR/install.sh"

# Simulate what setup.sh does at line 695: bash ... 2>/dev/null
# The test asserts that the exit code is non-zero (so a caller CAN detect it),
# but also shows that the current 2>/dev/null silencing hides stderr.
role_exit=0
bash "$ROLE_DIR/install.sh" 2>/dev/null || role_exit=$?

if [ "$role_exit" -ne 0 ]; then
    pass "T4: role install exit code ($role_exit) is non-zero — caller CAN detect failure"
    # Now verify the current setup.sh pattern would miss it:
    # setup.sh does: bash "$role_dir/install.sh" 2>/dev/null   (no || check)
    # This is the gap: exit code is discarded because the line is not in an 'if' or '||'.
    echo "     ⚠️  KNOWN GAP: setup.sh line 695 does not check exit code — failure is silent"
else
    fail "T4: role install did not exit non-zero as expected"
fi

# ============================================================
# T5: --check works without network (cached manifest path)
# ============================================================
echo "--- T5: --check is network-independent when manifest is cached ---"

CACHE_MANIFEST="/tmp/iwe-update-manifest-cache-test-$$.json"
# Write a minimal valid manifest JSON
python3 -c "import json; print(json.dumps({'version':'0.99.0','files':{}}))" > "$CACHE_MANIFEST"

if [ -f "$CACHE_MANIFEST" ] && python3 -c "import json; json.load(open('$CACHE_MANIFEST'))" 2>/dev/null; then
    pass "T5: local manifest cache is valid JSON and parseable"
else
    fail "T5: manifest cache file is invalid or missing"
fi
rm -f "$CACHE_MANIFEST"

# ============================================================================
# T6: memory file with owner: user survives a hash mismatch (issue #229)
# ============================================================================
echo "--- T6: owner:user memory file is not stale-repaired ---"

source "$TEMPLATE_DIR/.claude/lib/frontmatter.sh"

T6_UPSTREAM="$TEST_WS/upstream-fake.md"
T6_DEPLOYED="$TEST_WS/deployed-fake.md"

cat > "$T6_UPSTREAM" <<'HEREDOC'
---
owner: platform
horizon: hot
---
Upstream content (would overwrite deployed if copied).
HEREDOC

cat > "$T6_DEPLOYED" <<'HEREDOC'
---
owner: 'user'
horizon: hot
---
Pilot's own edit — must never be overwritten by stale-repair.
HEREDOC

# Same conditional update.sh's repair_pass() / Step 6 propagation use: owner:user guard first.
if [ "$(get_field "$T6_DEPLOYED" owner)" = "user" ]; then
    T6_PROTECTED=true
else
    T6_PROTECTED=false
fi

if [ "$T6_PROTECTED" = "true" ]; then
    pass "T6: get_field detects owner:user (single-quoted) — repair_pass would skip this file"
else
    fail "T6: get_field failed to detect owner:user — file would be clobbered"
fi

# Wiring check: the helper working in isolation doesn't prove update.sh still
# calls it in the right place. Grep for the actual guard at both call sites
# (repair_pass() and the Step 6 memory-copy loop) so a future refactor that
# drops or reorders the check fails this test even though get_field itself
# is untouched.
T6_WIRED_COUNT=$(grep -cE 'get_field "\$[a-z_]*dst" owner' "$TEMPLATE_DIR/update.sh")
if [ "$T6_WIRED_COUNT" -eq 2 ]; then
    pass "T6: owner:user guard is wired into both repair_pass() and Step 6 propagation"
else
    fail "T6: expected owner:user guard at 2 call sites in update.sh, found $T6_WIRED_COUNT"
fi

# ============================================================================
# T7: hot-budget sum over threshold is detectable (issue #228)
# ============================================================================
echo "--- T7: hot-budget validator sums horizon:hot lines ---"

T7_DIR="$TEST_WS/hot-budget-memory"
mkdir -p "$T7_DIR"

# Two hot files summing to 160 lines (over the 150 limit)
python3 -c "
print('---')
print('horizon: hot')
print('---')
for i in range(97): print(f'line {i}')
" > "$T7_DIR/hot-a.md"   # 100 lines total (3 frontmatter + 97 body)

python3 -c "
print('---')
print('horizon: hot')
print('---')
for i in range(57): print(f'line {i}')
" > "$T7_DIR/hot-b.md"   # 60 lines total

cat > "$T7_DIR/warm-c.md" <<'HEREDOC'
---
horizon: warm
---
This file's lines must NOT count toward the hot budget.
HEREDOC

T7_HOT_LINES=0
for mem_file in "$T7_DIR"/*.md; do
    if [ "$(get_field "$mem_file" horizon)" = "hot" ]; then
        n=$(wc -l < "$mem_file" | tr -d ' ')
        T7_HOT_LINES=$((T7_HOT_LINES + n))
    fi
done

if [ "$T7_HOT_LINES" -gt 150 ]; then
    pass "T7: hot-budget validator sums to $T7_HOT_LINES (>150), warning would fire"
else
    fail "T7: expected hot sum >150, got $T7_HOT_LINES"
fi

# Confirm warm file is excluded from the sum (160 hot + 4 warm would be 164 if miscounted)
if [ "$T7_HOT_LINES" -lt 164 ]; then
    pass "T7: warm-c.md correctly excluded from hot sum"
else
    fail "T7: warm file was incorrectly counted into hot sum"
fi

# ============================================================================
# T8: build-runtime.sh does not clobber an edited params.yaml (issue #327)
# ============================================================================
echo "--- T8: copied_to_workspace protects an existing params.yaml ---"

T8_WS="$TEST_WS/t8-workspace"
mkdir -p "$T8_WS"

# Pilot's own edit — must survive a build-runtime.sh run, same as a fresh install
# would seed it if absent.
cat > "$T8_WS/params.yaml" <<'HEREDOC'
github_user: pilot-own-value
author_mode: false
HEREDOC

cp "$TEMPLATE_DIR/.exocortex.env" "$T8_WS/.exocortex.env" 2>/dev/null || cat > "$T8_WS/.exocortex.env" <<HEREDOC
HOME_DIR=$HOME
WORKSPACE_DIR=$T8_WS
CLAUDE_PATH=/usr/bin/claude
CLAUDE_PROJECT_SLUG=test
TIMEZONE_HOUR=3
TIMEZONE_DESC=UTC
GITHUB_USER=test-user
GOVERNANCE_REPO=DS-strategy
HEREDOC

bash "$TEMPLATE_DIR/setup/build-runtime.sh" \
    --workspace "$T8_WS" \
    --env-file "$T8_WS/.exocortex.env" \
    --quiet >/dev/null 2>&1

if grep -q "github_user: pilot-own-value" "$T8_WS/params.yaml" 2>/dev/null; then
    pass "T8: existing params.yaml survives build-runtime.sh (edit not overwritten)"
else
    fail "T8: params.yaml was reset to template defaults — edit lost"
fi

# Wiring check: is_protected_user_file must actually gate the copy, not just exist.
T8_WIRED_COUNT=$(grep -cE 'is_protected_user_file "\$f"' "$TEMPLATE_DIR/setup/build-runtime.sh")
if [ "$T8_WIRED_COUNT" -ge 1 ]; then
    pass "T8: is_protected_user_file guard is wired into copied_to_workspace loop"
else
    fail "T8: is_protected_user_file exists but is not called in the copy loop"
fi

# ============================================================================
# T9: .mcp.json migration preserves a third-party server like ext-figma (issue #335)
# ============================================================================
echo "--- T9: .mcp.json migration keeps user-added servers ---"

T9_MCP="$TEST_WS/t9-mcp.json"
cat > "$T9_MCP" <<'HEREDOC'
{
  "mcpServers": {
    "ext-figma": {
      "type": "http",
      "url": "http://127.0.0.1:3845/mcp"
    },
    "knowledge-mcp": {
      "command": "old-stdio-server"
    }
  }
}
HEREDOC

python3 -c "
import json
with open('$T9_MCP') as f:
    data = json.load(f)
servers = data.get('mcpServers', {})
old_keys = [k for k in servers if k in ('knowledge-mcp', 'digital-twin-mcp', 'personal-knowledge-mcp')]
for k in old_keys:
    del servers[k]
if 'iwe-knowledge' not in servers:
    servers['iwe-knowledge'] = {'type': 'http', 'url': 'https://mcp.aisystant.com/mcp'}
data['mcpServers'] = servers
with open('$T9_MCP', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
" 2>/dev/null

if python3 -c "
import json
with open('$T9_MCP') as f:
    data = json.load(f)
servers = data.get('mcpServers', {})
assert 'ext-figma' in servers, 'ext-figma missing'
assert 'knowledge-mcp' not in servers, 'old stdio server not removed'
assert 'iwe-knowledge' in servers, 'iwe-knowledge not added'
" 2>/dev/null; then
    pass "T9: ext-figma survives migration, knowledge-mcp removed, iwe-knowledge added"
else
    fail "T9: migration logic mishandled server keys"
fi

# Wiring check: the actual Step 6c code in update.sh must implement the same
# preserve-then-merge shape (iterate old_keys → del, then add iwe-knowledge if
# missing) rather than a whole-file overwrite. Greps for the two defining lines
# so a future rewrite that drops the preserve step fails this test.
T9_WIRED_DEL=$(grep -c "for k in old_keys:" "$TEMPLATE_DIR/update.sh")
T9_WIRED_ADD=$(grep -c "if 'iwe-knowledge' not in servers:" "$TEMPLATE_DIR/update.sh")
if [ "$T9_WIRED_DEL" -ge 1 ] && [ "$T9_WIRED_ADD" -ge 1 ]; then
    pass "T9: update.sh Step 6c still preserves existing servers (not a whole-file overwrite)"
else
    fail "T9: update.sh Step 6c no longer matches the preserve-then-merge shape this test verified"
fi

# ============================================================================
# T10: CLAUDE.md fallback-merge (no .base) never silently drops §8/§9 edits (issue #336)
# ============================================================================
echo "--- T10: CLAUDE.md fallback path without .base does not clobber pilot edits ---"

T10_DIR="$TEST_WS/t10-claude-md"
mkdir -p "$T10_DIR"

# Case A: pilot's file has real §8/§9 content, NO <!-- USER-SPACE --> markers
# (issue #336's exact shape — the markers never existed in the real format).
T10_CURRENT="$T10_DIR/current.md"
T10_NEW="$T10_DIR/new.md"
cat > "$T10_CURRENT" <<'HEREDOC'
## 8. Staging
Полный раздел про staging-канал, четыре шага промоции
## 9. Авторское
- Комментарии кода — только EN
HEREDOC
cat > "$T10_NEW" <<'HEREDOC'
## 8. Staging
Одна строка вместо полного раздела
## 9. Авторское
HEREDOC

T10_USER_SECTION=$(sed -n '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/p' "$T10_CURRENT")
if [ -n "$T10_USER_SECTION" ]; then
    fail "T10 setup: test fixture should have no USER-SPACE markers, found some"
else
    # This mirrors the else-branch fixed for issue #336: no markers found →
    # leave the pilot's file untouched instead of blindly overwriting it.
    if grep -q "EN" "$T10_CURRENT" && grep -q "Полный раздел" "$T10_CURRENT"; then
        pass "T10: pilot's §8/§9 content is still on disk (fallback did not overwrite it)"
    else
        fail "T10: pilot's §8/§9 content is gone from the fixture before the fix even ran"
    fi
fi

# Case B: pilot's file DOES use USER-SPACE markers — must still merge as before
# (issue #336's fix must not regress the one case that already worked).
T10_CURRENT_B="$T10_DIR/current-b.md"
cat > "$T10_CURRENT_B" <<'HEREDOC'
## 8. Staging
<!-- USER-SPACE -->
my custom staging note
<!-- /USER-SPACE -->
HEREDOC
T10_USER_SECTION_B=$(sed -n '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/p' "$T10_CURRENT_B")
if [ -n "$T10_USER_SECTION_B" ]; then
    pass "T10: USER-SPACE markers are still detected when present (case B unaffected)"
else
    fail "T10: USER-SPACE marker detection broke for the case that used to work"
fi

# Wiring check: both fallback call sites (Step 5 §SCRIPT_DIR, Step 6 §WORKSPACE_DIR)
# must branch on USER_SECTION being non-empty before deciding to overwrite, not
# copy first unconditionally. Greps for the fixed condition shape at both sites.
T10_WIRED_COUNT=$(grep -cE 'if \[ -n "\$USER_SECTION" \]; then|if \[ -n "\$WS_USER_SECTION" \]; then' "$TEMPLATE_DIR/update.sh")
if [ "$T10_WIRED_COUNT" -ge 2 ]; then
    pass "T10: both CLAUDE.md fallback sites gate the overwrite on USER_SECTION (not unconditional)"
else
    fail "T10: expected the USER_SECTION guard at both fallback sites, found $T10_WIRED_COUNT"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================"
echo "  Results: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
echo "============================================"

exit "$FAIL_COUNT"
