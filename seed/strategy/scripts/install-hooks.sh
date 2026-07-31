#!/bin/bash
# install-hooks.sh — устанавливает .githooks/ как core.hooksPath для governance-репо.
#
# Usage:
#   bash scripts/install-hooks.sh [REPO_PATH]
#
# If REPO_PATH is omitted, uses the current working directory.
# This script is intentionally minimal and template-safe: it does not hardcode
# governance-repo paths or agent-specific checks. It only wires the repository
# to the tracked .githooks/ directory (pre-commit + pre-push guards).
#
# see WP-436 (force-push guard) + seed/strategy/.githooks/

set -euo pipefail

REPO="${1:-${PWD}}"
HOOK_DIR="$REPO/.githooks"
BACKUP_DIR="$REPO/.git/hook-backups"

if [ ! -d "$REPO/.git" ]; then
  echo "❌ Not a git repo: $REPO"
  exit 1
fi

mkdir -p "$HOOK_DIR" "$BACKUP_DIR"

for hook in pre-commit pre-push; do
  target="$HOOK_DIR/$hook"
  if [ -f "$target" ]; then
    backup="$BACKUP_DIR/$hook.backup.$(date +%s)"
    cp "$target" "$backup"
    echo "📝 Existing $hook backed up to: $backup"
  fi
  # Ensure executable in case it was checked out without +x
  if [ -f "$target" ]; then
    chmod +x "$target"
  fi
done

git -C "$REPO" config core.hooksPath .githooks

echo "✅ Hooks wired: $HOOK_DIR"
echo "   core.hooksPath = $(git -C "$REPO" config core.hooksPath)"
