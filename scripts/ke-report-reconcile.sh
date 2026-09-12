#!/bin/bash
# WP-170/WP-569: Explicit scoped writer; no implicit whole-queue mutation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/ke-report-state.py" reconcile "$@"
