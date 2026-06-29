#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
#
# verify-template-integrity.sh — local mirror of the CI template-integrity gate.
#
# Why: the authoritative integrity checks (manifest sync, setup/update parity)
# live only in .github/workflows/validate-template.yml, downstream of "done".
# Both classes of the 2026-06-29 red CI (manifest drift + rules-lazy fresh-install
# gap) passed our local close-protocol because we had no local equivalent — only
# upstream CI ran them. This script bundles those checks into one command so the
# promotion/close flow can close the loop before push, not after.
#
# Run before delivering template changes (template-sync / promote / close).
#
# Exit 0 — all integrity checks pass. Exit 1 — at least one failed.
#
# Related: peer-session 2026-06-29-03-ci-verification-gap-diagnosis

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CHECKS=(
  "verify-manifest.sh"
  "check-setup-update-parity.sh"
  "check-component-parity.sh"
)

FAIL=0
for chk in "${CHECKS[@]}"; do
  echo "──────────────────────────────────────────────"
  echo "▶ $chk"
  echo "──────────────────────────────────────────────"
  if bash "$SCRIPT_DIR/$chk"; then
    echo "  → passed"
  else
    echo "  → FAILED ($chk)"
    FAIL=1
  fi
  echo ""
done

if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ template integrity: all checks passed"
  exit 0
fi
echo "❌ template integrity: one or more checks failed (see above)"
exit 1
