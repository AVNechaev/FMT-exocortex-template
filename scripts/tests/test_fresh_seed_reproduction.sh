#!/usr/bin/env bash
# Fresh seed-template smoke test / reproduction-gate (Ф-script-contract-gate,
# Этап 2). Copies seed/strategy into an isolated tmpdir — nothing carried over
# from the real installation — and verifies a brand-new checkout is actually
# usable: the files a fresh WP Gate depends on exist, and create-wp.sh can
# create a first WP against it end-to-end.
#
# Scope, stated honestly (code review 03.08 caught the draft overclaiming
# this): covers seed/strategy + create-wp.sh end-to-end, not the top-level
# setup.sh install flow. setup.sh resolves its own location via `dirname "$0"`
# and expects the real ~/IWE/FMT-exocortex-template layout — unlike
# create-wp.sh, it can't be pointed at an isolated tmpdir through env vars
# alone, so driving it here would mean staging a full fake workspace, not a
# quick fixture. Left as a separate, larger follow-up rather than a shallow
# `[ -f setup.sh ]` check standing in for "install-flow covered".

set -euo pipefail

TEMPLATE_ROOT="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

[ -d "$TEMPLATE_ROOT/seed/strategy" ] ||
  { echo "FAIL: seed/strategy missing from template" >&2; exit 1; }

cp -R "$TEMPLATE_ROOT/seed/strategy" "$TMPDIR/strategy"

required=(
  CLAUDE.md
  REPO-TYPE.md
  docs/WP-REGISTRY.md
  docs/Strategy.md
  inbox
  archive/wp-contexts
  current
)
for path in "${required[@]}"; do
  [ -e "$TMPDIR/strategy/$path" ] ||
    { echo "FAIL: fresh seed missing required path: $path" >&2; exit 1; }
done
echo "✓ Fresh seed/strategy checkout has all paths WP Gate depends on"

export IWE_TEMPLATE="$TEMPLATE_ROOT"
export IWE_ROOT="$TMPDIR"
export IWE_GOVERNANCE_REPO="strategy"

(
  cd "$TMPDIR"
  bash "$TEMPLATE_ROOT/scripts/create-wp.sh" \
    --title "Fresh Seed Smoke" \
    --budget 1h \
    --priority P4 \
    --no-consent-check
) >"$TMPDIR/create.out" 2>&1 || {
  echo "FAIL: create-wp.sh failed against a freshly copied seed" >&2
  cat "$TMPDIR/create.out" >&2
  exit 1
}

WP_FILE=$(find "$TMPDIR/strategy/inbox" -type f -path '*/WP-*/WP-*.md' | head -1)
[ -n "$WP_FILE" ] ||
  { echo "FAIL: fresh seed produced no first WP" >&2; exit 1; }

WP_ID=$(basename "$WP_FILE" .md)
grep -q "$WP_ID" "$TMPDIR/strategy/docs/WP-REGISTRY.md" ||
  { echo "FAIL: fresh-seed WP missing from WP-REGISTRY.md" >&2; exit 1; }

echo "✓ create-wp.sh works end-to-end against a fresh seed checkout ($WP_ID)"
echo "✓ seed/strategy reproduction covered — setup.sh install flow NOT exercised by this test (see file header)"
