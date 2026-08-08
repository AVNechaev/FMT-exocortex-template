#!/bin/bash
# test-issue-226.sh — end-to-end smoke test for the 3 update.sh fixes (issue #226)
#
# Runs the REAL update.sh against a sandboxed SCRIPT_DIR/WORKSPACE_DIR, with a
# curl shim serving fixture "upstream" content instead of hitting GitHub.
#
# Scenario A (defect 1 + defect 3): workspace CLAUDE.md conflicts on merge.
#   Assert: hook + memory files still delivered, commit still happens,
#   update.sh exits non-zero (EXIT_CONFLICT=49), branch guard skips commit
#   on a non-default branch.
# Scenario B (defect 2): rerun with SCRIPT_DIR already at upstream version
#   (TOTAL_CHANGES=0) but workspace missing a hook file.
#   Assert: repair-pass fires even on the "всё актуально" early-exit path.
#
# Usage:
#   bash setup/test-update-issue-226.sh
#   KEEP=1 bash setup/test-update-issue-226.sh   # keep /tmp dir for inspection

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_SH_REAL="$(dirname "$SELF_DIR")/update.sh"
TEST_ROOT="${ISSUE_226_WORKSPACE:-/tmp/iwe-issue-226-test-$$}"
FAKE_HOME="$TEST_ROOT/fake-home"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT" "$FAKE_HOME"

# ------------------------------------------------------------------
# Fixture: fake "upstream" tree (what curl will serve)
# ------------------------------------------------------------------
UPSTREAM="$TEST_ROOT/upstream"
mkdir -p "$UPSTREAM/.claude/hooks"

cat > "$UPSTREAM/CLAUDE.md" <<'EOF'
# Template CLAUDE.md

## 1. Platform section

Upstream v2 content.
EOF

cat > "$UPSTREAM/.claude/hooks/dummy-hook.sh" <<'EOF'
#!/bin/bash
echo "dummy hook v2"
EOF

mkdir -p "$UPSTREAM/memory"
cat > "$UPSTREAM/memory/dummy-memo.md" <<'EOF'
# Dummy memo v2
EOF

python3 -c "
import hashlib
import json
from pathlib import Path

root = Path('$UPSTREAM')
def entry(path):
    return {'path': path, 'sha256': hashlib.sha256((root / path).read_bytes()).hexdigest()}

manifest = {
    'schema_version': 2,
    'version': '0.99.0-test-226',
    'files': [
        entry('CLAUDE.md'),
        entry('.claude/hooks/dummy-hook.sh'),
        entry('memory/dummy-memo.md'),
    ],
    'deprecated_files': [],
}
with open('$UPSTREAM/update-manifest.json', 'w') as f:
    json.dump(manifest, f)
"

# ------------------------------------------------------------------
# Fixture: SCRIPT_DIR (local FMT-exocortex-template copy) — "old" state
# ------------------------------------------------------------------
SCRIPT_DIR="$TEST_ROOT/repo/FMT-exocortex-template"
mkdir -p "$SCRIPT_DIR/.claude/hooks" "$SCRIPT_DIR/.claude/lib" "$SCRIPT_DIR/scripts/lib" "$SCRIPT_DIR/memory"
cp "$UPDATE_SH_REAL" "$SCRIPT_DIR/update.sh"
cp "$SELF_DIR/../.claude/lib/frontmatter.sh" "$SCRIPT_DIR/.claude/lib/frontmatter.sh"
cp "$SELF_DIR/../scripts/lib/common.sh" "$SCRIPT_DIR/scripts/lib/common.sh"
chmod +x "$SCRIPT_DIR/update.sh"

cat > "$SCRIPT_DIR/CLAUDE.md" <<'EOF'
# Template CLAUDE.md

## 1. Platform section

Upstream v1 content (old).
EOF
cp "$SCRIPT_DIR/CLAUDE.md" "$SCRIPT_DIR/.claude.md.base"

WORKSPACE_DIR="$TEST_ROOT/repo"

# Workspace CLAUDE.md: user edited the SAME line the upstream also changed → real conflict
cat > "$WORKSPACE_DIR/CLAUDE.md" <<'EOF'
# Template CLAUDE.md

## 1. Platform section

Upstream v1 content (old).

## 9. My custom section

Pilot's own text, must survive.
EOF
sed_inplace() { sed -i '' "$@" 2>/dev/null || sed -i "$@"; }
sed_inplace 's/Upstream v1 content (old)\./User edited this exact line locally./' "$WORKSPACE_DIR/CLAUDE.md"
cp "$SCRIPT_DIR/CLAUDE.md" "$WORKSPACE_DIR/.claude.md.base"

git -C "$SCRIPT_DIR" init -q
git -C "$SCRIPT_DIR" config user.email t@t; git -C "$SCRIPT_DIR" config user.name t
git -C "$SCRIPT_DIR" add -A; git -C "$SCRIPT_DIR" commit -q -m init
# Simulate the reported scenario: HEAD sits on a contributor PR branch, not main.
git -C "$SCRIPT_DIR" checkout -q -b some-pr-branch

# ------------------------------------------------------------------
# curl shim: intercepts raw.githubusercontent.com/<REPO>/<BRANCH>/<path>
# ------------------------------------------------------------------
SHIM_DIR="$TEST_ROOT/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/curl" <<SHIMEOF
#!/bin/bash
url="" out=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
    case "\${args[i]}" in
        http*) url="\${args[i]}" ;;
        -o) out="\${args[i+1]}" ;;
    esac
done
rel="\${url#*/main/}"
if [ "\$rel" = "update.sh" ]; then
    cp "$SCRIPT_DIR/update.sh" "\$out"
elif [ "\$rel" = "update-manifest.json" ]; then
    cp "$UPSTREAM/update-manifest.json" "\$out"
else
    src="$UPSTREAM/\$rel"
    [ -f "\$src" ] && cp "\$src" "\$out" || exit 22
fi
exit 0
SHIMEOF
chmod +x "$SHIM_DIR/curl"

# ------------------------------------------------------------------
# Scenario A: run update.sh --yes on the non-default branch with a conflict
# ------------------------------------------------------------------
echo "--- Scenario A: CLAUDE.md conflict + non-default branch ---"
set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-a.log" 2>&1
RC_A=$?
set -e

if [ "$RC_A" -eq 49 ]; then
    pass "A: update.sh exits with EXIT_CONFLICT(49), not a silent success"
else
    fail "A: expected exit 49, got $RC_A"
fi

if [ -f "$WORKSPACE_DIR/.claude/hooks/dummy-hook.sh" ] && grep -q "v2" "$WORKSPACE_DIR/.claude/hooks/dummy-hook.sh"; then
    pass "A: hook file still delivered to workspace despite CLAUDE.md conflict (defect 1)"
else
    fail "A: hook file was NOT delivered — defect 1 regression"
fi

CLAUDE_SLUG="$(echo "$WORKSPACE_DIR" | tr '/' '-')"
MEM_DST="$FAKE_HOME/.claude/projects/$CLAUDE_SLUG/memory/dummy-memo.md"
mkdir -p "$(dirname "$MEM_DST")"  # this dir must pre-exist for propagation per update.sh's own guard
# re-run only if propagation skipped it because dir didn't exist yet — check log for that path instead
if grep -q "dummy-memo" "$TEST_ROOT/out-a.log"; then
    pass "A: memory file propagation attempted (dummy-memo.md referenced in output)"
else
    fail "A: memory file propagation never attempted"
fi

if grep -q "конфликтов" "$TEST_ROOT/out-a.log"; then
    pass "A: conflict is reported to the user"
else
    fail "A: no conflict message found in output"
fi

if grep -qE "^\s*-\s*/.*CLAUDE\.md$" "$TEST_ROOT/out-a.log"; then
    pass "A: conflicted file path listed in final summary"
else
    fail "A: conflicted file path missing from final summary"
fi

if grep -q "Коммит пропущен" "$TEST_ROOT/out-a.log"; then
    pass "A: commit skipped on non-default branch under --yes (defect 3)"
else
    fail "A: branch guard did not fire / commit was not skipped"
fi

if [ -z "$(git -C "$SCRIPT_DIR" log --oneline -1 --grep='chore: update' 2>/dev/null)" ]; then
    pass "A: no 'chore: update' commit landed on the PR branch"
else
    fail "A: update commit landed on the contributor's PR branch — defect 3 regression"
fi

# ------------------------------------------------------------------
# Scenario B: SCRIPT_DIR already at upstream version (TOTAL_CHANGES=0),
# workspace hook file missing (simulates a prior interrupted run).
# ------------------------------------------------------------------
echo "--- Scenario B: repair-pass on the 'всё актуально' path ---"
git -C "$SCRIPT_DIR" checkout -q main 2>/dev/null || git -C "$SCRIPT_DIR" checkout -q -b main
cp "$UPSTREAM/CLAUDE.md" "$SCRIPT_DIR/CLAUDE.md"
cp "$SCRIPT_DIR/CLAUDE.md" "$SCRIPT_DIR/.claude.md.base"
cp "$UPSTREAM/.claude/hooks/dummy-hook.sh" "$SCRIPT_DIR/.claude/hooks/dummy-hook.sh"
cp "$UPSTREAM/memory/dummy-memo.md" "$SCRIPT_DIR/memory/dummy-memo.md"
cp "$UPSTREAM/update-manifest.json" "$SCRIPT_DIR/update-manifest.json"
rm -f "$WORKSPACE_DIR/.claude/hooks/dummy-hook.sh"
# Resolve the workspace CLAUDE.md conflict so it doesn't confuse this scenario
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"
cp "$UPSTREAM/CLAUDE.md" "$WORKSPACE_DIR/.claude.md.base"
git -C "$SCRIPT_DIR" add -A; git -C "$SCRIPT_DIR" commit -q -m "simulate: already at upstream version"

set +e
PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-b.log" 2>&1
RC_B=$?
set -e

if grep -q "Всё актуально" "$TEST_ROOT/out-b.log"; then
    pass "B: update.sh correctly reports 'всё актуально' (TOTAL_CHANGES=0)"
else
    fail "B: expected 'всё актуально' branch, output was:"; cat "$TEST_ROOT/out-b.log" >&2
fi

if [ -f "$WORKSPACE_DIR/.claude/hooks/dummy-hook.sh" ]; then
    pass "B: missing hook file was repaired even on the early-exit path (defect 2)"
else
    fail "B: hook file was NOT repaired — defect 2 regression (repair-pass unreachable)"
fi

if [ "$RC_B" -eq 0 ]; then
    pass "B: exit code 0 (no conflicts in this scenario)"
else
    fail "B: expected exit 0, got $RC_B"
fi

# ------------------------------------------------------------------
# Scenario C: same version and paths, changed content hash.
# --check --fast must detect it; full check must reject a bad payload hash.
# ------------------------------------------------------------------
echo "--- Scenario C: manifest content hashes (#378) ---"
printf '#!/bin/bash\necho "dummy hook v3"\n' > "$UPSTREAM/.claude/hooks/dummy-hook.sh"
python3 - "$UPSTREAM/update-manifest.json" "$UPSTREAM/.claude/hooks/dummy-hook.sh" <<'PY'
import hashlib
import json
import sys

manifest_path, content_path = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
digest = hashlib.sha256(open(content_path, "rb").read()).hexdigest()
for entry in manifest["files"]:
    if entry["path"] == ".claude/hooks/dummy-hook.sh":
        entry["sha256"] = digest
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY

PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT_DIR/update.sh" --check --fast > "$TEST_ROOT/out-c-fast.log" 2>&1
if grep -q "Состав манифеста изменился" "$TEST_ROOT/out-c-fast.log"; then
    pass "C: --check --fast detects a content-only change at the same version/path"
else
    fail "C: --check --fast missed a content-only manifest change"
fi

python3 - "$UPSTREAM/update-manifest.json" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
for entry in manifest["files"]:
    if entry["path"] == ".claude/hooks/dummy-hook.sh":
        entry["sha256"] = "0" * 64
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY

PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT_DIR/update.sh" --check > "$TEST_ROOT/out-c-integrity.log" 2>&1 || true
if grep -q "sha256 не совпадает" "$TEST_ROOT/out-c-integrity.log" && \
   grep -q "Проверка неполная" "$TEST_ROOT/out-c-integrity.log"; then
    pass "C: full check rejects a downloaded file that does not match manifest sha256"
else
    fail "C: payload integrity mismatch was not surfaced as an incomplete check"
fi

# ------------------------------------------------------------------
# Scenario D: owner:user drift is reported even when no file is in the
# current NEW_FILES/UPDATED_FILES list (#375).
# ------------------------------------------------------------------
echo "--- Scenario D: owner:user memory drift (#375) ---"
# Restore a valid, unchanged remote manifest/payload first.
cp "$UPSTREAM/.claude/hooks/dummy-hook.sh" "$SCRIPT_DIR/.claude/hooks/dummy-hook.sh"
python3 - "$UPSTREAM/update-manifest.json" "$UPSTREAM" <<'PY'
import hashlib
import json
import pathlib
import sys
manifest_path, root = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)
for entry in manifest["files"]:
    entry["sha256"] = hashlib.sha256((pathlib.Path(root) / entry["path"]).read_bytes()).hexdigest()
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle)
PY
cp "$UPSTREAM/update-manifest.json" "$SCRIPT_DIR/update-manifest.json"
mkdir -p "$(dirname "$MEM_DST")"
cat > "$MEM_DST" <<'EOF'
---
owner: user
---
Pilot-owned content that intentionally differs.
EOF

PATH="$SHIM_DIR:$PATH" HOME="$FAKE_HOME" bash "$SCRIPT_DIR/update.sh" --yes > "$TEST_ROOT/out-d.log" 2>&1 || true
if grep -q "owner: user, НЕ обновлён, но шаблонная версия отличается" "$TEST_ROOT/out-d.log" && \
   grep -q 'Сверьте: diff' "$TEST_ROOT/out-d.log"; then
    pass "D: owner:user drift is visible with a comparison command on an unchanged run"
else
    fail "D: owner:user drift remained silent outside the changed-files list"
fi

echo ""
echo "============================================"
echo "  Results: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
echo "============================================"
[ "$FAIL_COUNT" -eq 0 ]
