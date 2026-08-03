#!/usr/bin/env bash
# Contract test for bug #338: create-wp.sh must guarantee atomic registry coherence.
# Inject a deterministic fault on the WeekPlan write (step 4/6) and verify full
# rollback (inbox + archive stub + REGISTRY + WeekPlan all back to pre-run state),
# not a partial WP left behind.
#
# Earlier version used `chmod 444` on WeekPlan — non-deterministic (root/ACLs can
# still write) and create-wp.sh never checked the WeekPlan step's exit code at all,
# so the injected failure was silently ignored and the script reported success
# regardless (found 03.08, running this for real produced a false "Exit code: 0").
# This version shadows `python3` on PATH so only the WeekPlan-writing invocation
# fails, with a distinctive exit code — deterministic regardless of permissions.

set -euo pipefail

TEMPLATE_ROOT="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cp -R "$TEMPLATE_ROOT/seed/strategy" "$TMPDIR/strategy"

export IWE_TEMPLATE="$TEMPLATE_ROOT"
export IWE_ROOT="$TMPDIR"
export IWE_GOVERNANCE_REPO="strategy"

cd "$TMPDIR/strategy"

# $PWD (logical), not `pwd -P` (physical): on macOS $TMPDIR from mktemp is
# under /var, which is itself a symlink to /private/var — `pwd -P` resolves
# that symlink and would never match "$TMPDIR"/*, failing this guard on every
# single run regardless of whether the fixture actually escaped (found running
# this test for real, not by reading the code).
case "$PWD" in
  "$TMPDIR"/*) ;;
  *)
    echo "FAIL: fixture escaped TMPDIR: $PWD" >&2
    exit 1
    ;;
esac

WEEKPLAN=$(find current -maxdepth 1 -name "WeekPlan*.md" | head -1)
if [ -z "$WEEKPLAN" ]; then
  echo "FAIL: fresh seed/strategy has no current/WeekPlan*.md fixture" >&2
  exit 1
fi

# Fault injection: a python3 shim that fails ONLY when invoked with the
# WeekPlan path as an argument (create-wp.sh step 4), passes through to the
# real interpreter for every other call (steps 1-3 use plain heredocs, but
# the WP number lookup and slug transliteration also shell out to python3).
# `[[ == */"$WEEKPLAN" ]]`, not a `case` pattern: real WeekPlan filenames
# contain spaces (this repo's own convention — "WeekPlan W31 ....md"), and an
# unquoted case pattern splits on that space into two tokens, a syntax error
# in the generated shim (found running this test for real against the actual
# seed fixture — every python3 call failed, including unrelated ones, not
# just the one this was meant to intercept). Quoting the variable inside
# [[ == ]] forces a literal (non-glob) match for that segment.
REAL_PYTHON3=$(command -v python3)
FAKE_BIN="$TMPDIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/python3" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == */"$WEEKPLAN" ]]; then
    echo "injected WeekPlan writer failure" >&2
    exit 73
  fi
done
exec "$REAL_PYTHON3" "\$@"
EOF
chmod +x "$FAKE_BIN/python3"

INITIAL_REGISTRY=$(cat docs/WP-REGISTRY.md)
INITIAL_WEEKPLAN=$(cat "$WEEKPLAN")
INITIAL_INBOX=$(find inbox -mindepth 1 | sort)
INITIAL_ARCHIVE=$(find archive/wp-contexts -mindepth 1 | sort)

set +e
PATH="$FAKE_BIN:$PATH" bash "$IWE_TEMPLATE/scripts/create-wp.sh" \
  --title "Contract Test WP" \
  --budget "1h" \
  --priority "P4" \
  --no-consent-check \
  >"$TMPDIR/create.out" 2>&1
EXIT_CODE=$?
set -e

cat "$TMPDIR/create.out"
echo "Exit code: $EXIT_CODE"

if [ "$EXIT_CODE" -eq 0 ]; then
  echo "FAIL: injected WeekPlan failure was reported as success" >&2
  exit 1
fi

FINAL_REGISTRY=$(cat docs/WP-REGISTRY.md)
FINAL_WEEKPLAN=$(cat "$WEEKPLAN")
FINAL_INBOX=$(find inbox -mindepth 1 | sort)
FINAL_ARCHIVE=$(find archive/wp-contexts -mindepth 1 | sort)

[ "$FINAL_REGISTRY" = "$INITIAL_REGISTRY" ] ||
  { echo "FAIL: WP-REGISTRY.md was not rolled back" >&2; exit 1; }
[ "$FINAL_WEEKPLAN" = "$INITIAL_WEEKPLAN" ] ||
  { echo "FAIL: WeekPlan was not rolled back" >&2; exit 1; }
[ "$FINAL_INBOX" = "$INITIAL_INBOX" ] ||
  { echo "FAIL: inbox/ was not rolled back" >&2; exit 1; }
[ "$FINAL_ARCHIVE" = "$INITIAL_ARCHIVE" ] ||
  { echo "FAIL: archive/wp-contexts/ was not rolled back (orphaned stub left behind)" >&2; exit 1; }

echo "✓ Correctly rolled back after fault injection — no partial WP left behind"
