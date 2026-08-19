#!/usr/bin/env bash
# test_setup_reuses_resolved_python3.sh — WP-529 F6 (Evgenii Red Team review
# 2026-08-19, defect #2).
#
# setup.sh used to run scripts/lib/find-python3.sh only for its exit code
# (stdout discarded to /dev/null) and then call bare `python3` again to
# generate executor-catalog.yaml. On a real Apple Silicon machine those can
# be two DIFFERENT interpreters: the resolver walks a fixed candidate list
# (python3, /opt/homebrew/bin/python3, /usr/local/bin/python3, /usr/bin/…)
# and returns the first one with yaml importable, while bare `python3` just
# follows PATH — if PATH's `python3` has no yaml but a later resolver
# candidate does, setup.sh finds a working interpreter and then throws it
# away before actually using it.
#
# This test does not need two real Apple-Silicon python installs: it makes
# find-python3.sh's FIRST candidate (`python3` on PATH) resolve to a stub
# with no yaml, forcing the resolver to walk to its second candidate — a
# second stub that delegates to this machine's real yaml-capable python3.
# A setup.sh that discards the resolved path and calls bare `python3` again
# will hit the no-yaml stub and fail; a setup.sh that reuses the resolved
# path succeeds. Requires the host running this test to have a working
# python3+PyYAML somewhere findable via `command -v` (true for CI and any
# dev machine that can run the rest of this repo's test suite).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
TEST_ROOT="/tmp/iwe-wp529-setup-python-test-$$"

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass() { echo "  ✅ PASS: $*"; }
cleanup() { local rc=$?; [ "${KEEP:-0}" = "1" ] || rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

mkdir -p "$TEST_ROOT"

# --- Stub PATH: a python3 with no yaml, shadowing the real one ---
BIN_NO_YAML="$TEST_ROOT/bin-no-yaml"
mkdir -p "$BIN_NO_YAML"

# generate-executor-catalog.py does `import yaml` at module load time — ANY
# invocation of it on a yaml-less interpreter fails with the same traceback,
# regardless of the script's own args. The resolver's own `-c "import yaml"`
# probe hits the identical failure, which is what makes it walk to the next
# candidate.
cat > "$BIN_NO_YAML/python3" <<'EOF'
#!/bin/bash
echo "no-yaml-stub-invoked" >> "$IWE_TEST_PROBE"
echo "Traceback (most recent call last):" >&2
echo "ModuleNotFoundError: No module named 'yaml'" >&2
exit 1
EOF
chmod +x "$BIN_NO_YAML/python3"

# find-python3.sh's second candidate is a hardcoded absolute path
# (/opt/homebrew/bin/python3) — it is used here AS-IS, not shadowed, so the
# resolver genuinely walks past the no-yaml stub to a real interpreter (same
# as the "resolver alone" check above). What this section actually verifies
# is the DIFFERENCE between two callers sharing the SAME `python3` PATH
# entry: the resolver (which also checks /opt/homebrew directly) succeeds
# either way, while a caller that discards its result and calls bare
# `python3` only ever sees whatever PATH's `python3` is — the no-yaml stub.
# A probe log on real /opt/homebrew/bin/python3 would need modifying a real
# system binary, which this test does not do; the assertions below instead
# distinguish success (yaml-capable output) from the specific ModuleNotFoundError
# defect #2 produces, which is what actually needs distinguishing.

# --- Sandbox TEMPLATE_DIR: only the two files under test, called directly
# with the same env find-python3.sh's candidate walk relies on (PATH order
# makes candidate #1 `python3` resolve to the no-yaml stub deterministically;
# the with-yaml stub is not on this PATH at all — reachability of a SECOND
# working interpreter is exactly what a discarding setup.sh would miss).
TEMPLATE_DIR="$ROOT"
export IWE_TEST_PROBE="$TEST_ROOT/probe.log"
: > "$IWE_TEST_PROBE"

echo "--- find-python3.sh alone: falls through the no-yaml stub to a real interpreter ---"
RESOLVED=$(PATH="$BIN_NO_YAML:$PATH" "$TEMPLATE_DIR/scripts/lib/find-python3.sh" 2>/dev/null)
RESOLVE_STATUS=$?
if [ "$RESOLVE_STATUS" -eq 0 ] && [ -n "$RESOLVED" ]; then
    pass "resolver succeeds despite the no-yaml stub being PATH's first python3"
else
    fail "resolver could not find any yaml-capable interpreter (status=$RESOLVE_STATUS)"
fi
if grep -q "no-yaml-stub-invoked" "$IWE_TEST_PROBE" 2>/dev/null; then
    pass "resolver actually tried the no-yaml stub first (candidate order respected)"
else
    fail "no-yaml stub was never invoked — PATH override did not take effect"
fi

echo "--- setup.sh's executor-catalog step: must reuse the resolved path, not re-call bare python3 ---"
# Extract the full "4e" block (preflight resolve + catalog generation) by line
# range and run it in isolation — running the whole setup.sh would need a
# full governance-repo fixture unrelated to this defect. The range is pinned
# to the section's own start/end markers so it survives edits elsewhere in
# setup.sh; if the markers move, START/END below need updating together with
# the sed range (both read from the same two greps, not duplicated numbers).
SECTION_START=$(grep -n '^# === 4e\. Generate executor-catalog' "$ROOT/setup.sh" | head -1 | cut -d: -f1)
SECTION_END=$(grep -n '^# === 4f\.' "$ROOT/setup.sh" | head -1 | cut -d: -f1)
if [ -z "$SECTION_START" ] || [ -z "$SECTION_END" ]; then
    fail "could not locate the 4e/4f section markers in setup.sh — extraction range invalid"
fi
SNIPPET="$TEST_ROOT/snippet.sh"
{
    echo "#!/bin/bash"
    echo "set -u"
    echo "TEMPLATE_DIR='$TEMPLATE_DIR'"
    echo "GOVERNANCE_REPO='irrelevant-for-this-snippet'"
    echo "CORE_ONLY=false"
    echo "DRY_RUN=false"
    sed -n "${SECTION_START},$((SECTION_END - 1))p" "$ROOT/setup.sh"
} > "$SNIPPET"
chmod +x "$SNIPPET"

# PATH puts the no-yaml stub first for BOTH the resolver call inside the
# snippet and any bare `python3` the snippet might call — this is the actual
# defect #2 scenario: PATH's own python3 has no yaml, but find-python3.sh's
# second candidate (a hardcoded /opt/homebrew/bin/python3) does. A fixed
# setup.sh reuses what the resolver found; a discarding one calls bare
# `python3` again, which resolves to the SAME no-yaml stub the resolver
# already rejected.
: > "$IWE_TEST_PROBE"
OUT=$(PATH="$BIN_NO_YAML:$PATH" bash "$SNIPPET" 2>&1)
STATUS=$?

if echo "$OUT" | grep -qi "No module named 'yaml'\|ModuleNotFoundError"; then
    fail "catalog generation hit the no-yaml stub despite the resolver finding a working interpreter (defect #2 reproduced)"
    echo "  --- snippet output ---" >&2
    echo "$OUT" | sed 's/^/  /' >&2
else
    pass "catalog generation did not hit ModuleNotFoundError — the resolved interpreter was reused, not re-derived from bare python3"
fi
if [ "$STATUS" -eq 0 ]; then
    pass "snippet completed successfully (exit 0)"
else
    fail "snippet exited $STATUS (expected 0 — see output above)"
fi

echo "---"
if [ "$FAIL" -gt 0 ]; then
    echo "setup.sh python3-reuse contract: $FAIL check(s) failed"
    exit 1
fi
echo "setup.sh python3-reuse contract: all checks passed"
