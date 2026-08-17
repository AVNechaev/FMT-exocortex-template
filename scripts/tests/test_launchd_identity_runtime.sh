#!/usr/bin/env bash
# WP-5 Ф43: launchd provides a minimal environment, so USER and LOGNAME must
# be rendered from explicit runtime configuration in every shipped job.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

WORKSPACE="$TMP/workspace"
ENV_FILE="$WORKSPACE/.exocortex.env"
mkdir -p "$WORKSPACE"
cat > "$ENV_FILE" <<EOF
GITHUB_USER="runtime-test"
WORKSPACE_DIR="$WORKSPACE"
CLAUDE_PATH="/usr/bin/claude"
CLAUDE_PROJECT_SLUG="runtime-test"
TIMEZONE_HOUR="4"
TIMEZONE_DESC="4:00 UTC"
HOME_DIR="$TMP/home"
USER_NAME="runtime-test-user"
GOVERNANCE_REPO="DS-strategy"
IWE_TEMPLATE="$ROOT"
IWE_RUNTIME="$WORKSPACE/.iwe-runtime"
EOF

bash "$ROOT/setup/build-runtime.sh" --quiet --workspace "$WORKSPACE" --env-file "$ENV_FILE"

assert_plist_identity() {
    local plist="$1"
    local key="$2"
    awk -v key="$key" -v value="runtime-test-user" '
        $0 == "        <key>" key "</key>" {
            getline
            matched = $0 == "        <string>" value "</string>"
            exit
        }
        END { exit matched ? 0 : 1 }
    ' "$plist" || {
        echo "FAIL: $plist does not render $key=runtime-test-user" >&2
        exit 1
    }
}

PLISTS=(
    roles/strategist/scripts/launchd/com.strategist.morning.plist
    roles/strategist/scripts/launchd/com.strategist.weekreview.plist
    roles/synchronizer/scripts/launchd/com.exocortex.scheduler.plist
    roles/extractor/scripts/launchd/com.extractor.inbox-check.plist
)
for rel in "${PLISTS[@]}"; do
    plist="$WORKSPACE/.iwe-runtime/$rel"
    [ -f "$plist" ] || { echo "FAIL: missing rendered plist $rel" >&2; exit 1; }
    assert_plist_identity "$plist" USER
    assert_plist_identity "$plist" LOGNAME
    if command -v plutil >/dev/null 2>&1 && ! plutil -lint "$plist" >/dev/null; then
        echo "FAIL: rendered plist is invalid: $rel" >&2
        exit 1
    fi
    if grep -q '{{USER_NAME}}' "$plist"; then
        echo "FAIL: $rel retains USER_NAME placeholder" >&2
        exit 1
    fi
done

MISSING_ENV="$TMP/missing-user.env"
grep -v '^USER_NAME=' "$ENV_FILE" > "$MISSING_ENV"
if bash "$ROOT/setup/build-runtime.sh" --quiet --workspace "$TMP/missing" --env-file "$MISSING_ENV" >"$TMP/missing.out" 2>&1; then
    echo "FAIL: build-runtime accepted an absent USER_NAME" >&2
    exit 1
fi
grep -q 'USER_NAME is required' "$TMP/missing.out" || {
    echo "FAIL: missing USER_NAME was not reported clearly" >&2
    cat "$TMP/missing.out" >&2
    exit 1
}

echo "PASS: all launchd jobs render explicit USER and LOGNAME; missing USER_NAME fails"
