#!/usr/bin/env bash
# Run regression tests for bug fixes (#338, #339, #340).
# Used in CI and pre-commit validation.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/tests" && pwd)"
FAILED=0

echo "Running regression tests..."
echo ""

for test_script in "$TEST_DIR"/test_*.sh; do
  # Skip non-regression tests
  [[ $(basename "$test_script") == test_create_wp_registry_coherence.sh ]] || \
  [[ $(basename "$test_script") == test_capture_bus_detector_timeout.sh ]] || \
  [[ $(basename "$test_script") == test_critical_alert_disabled_tracker.sh ]] || continue

  test_name=$(basename "$test_script" .sh)
  echo "Running: $test_name"

  if bash "$test_script"; then
    echo "✓ $test_name PASSED"
  else
    echo "✗ $test_name FAILED"
    FAILED=$((FAILED + 1))
  fi
  echo ""
done

if [ $FAILED -eq 0 ]; then
  echo "✓ All regression tests passed"
  exit 0
else
  echo "✗ $FAILED test(s) failed"
  exit 1
fi
