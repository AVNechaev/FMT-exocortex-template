#!/usr/bin/env bash
# pull-on-touch-ff-only-smoke.sh — regression coverage for .claude/hooks/pull-on-touch.sh
# (issue #1245, recurrence of bug-2026-07-17-kimi-queue-autostash-conflict-and-orphaned-semaphores.md).
# Real bare-origin sandboxes, real hook invocation via stdin JSON — no mocking of
# git-sync-status.sh or the hook itself.
set -uo pipefail

HOOK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$HOOK_ROOT/.claude/hooks/pull-on-touch.sh"
[ -f "$HOOK" ] || { echo "FAIL: $HOOK not found"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$HOME/.claude/state/repo-pulled-pull-ff-only-smoke-"*.txt 2>/dev/null' EXIT

FAILURES=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 -- ожидалось '$2', получено '$3'"
    FAILURES=$((FAILURES + 1))
  fi
}

setup_sandbox() {  # setup_sandbox <workspace-dir> <repo-name> -- real bare "origin" под IWE/<repo-name>
  local ws="$1" name="$2"
  local bare="$ws/${name}.origin.git"
  mkdir -p "$ws"
  git init -q --bare "$bare"
  git clone -q "$bare" "$ws/$name"
  git -C "$ws/$name" checkout -q -b main
  git -C "$ws/$name" config user.email test@test.local
  git -C "$ws/$name" config user.name test
  echo init > "$ws/$name/seed.md"
  git -C "$ws/$name" add seed.md
  git -C "$ws/$name" commit -q -m init
  git -C "$ws/$name" push -q origin main
  git -C "$bare" symbolic-ref HEAD refs/heads/main
}

advance_remote() {  # advance_remote <workspace-dir> <repo-name> -- push one commit from a second clone
  local ws="$1" name="$2"
  local pusher="$ws/${name}-pusher"
  git clone -q "$ws/${name}.origin.git" "$pusher" 2>/dev/null
  git -C "$pusher" checkout -q main
  git -C "$pusher" config user.email test@test.local
  git -C "$pusher" config user.name test
  echo remote-change >> "$pusher/seed.md"
  git -C "$pusher" add seed.md
  git -C "$pusher" commit -q -m remote-change
  git -C "$pusher" push -q origin main
}

run_hook() {  # run_hook <workspace-dir> <repo-name> <session-id> -- real stdin JSON, real env.
  # Decodes the hook's JSON reply to its plain-text additionalContext: the hook
  # emits Cyrillic through `json.dumps` (ensure_ascii, \uXXXX escapes), so a
  # literal grep for Cyrillic text on the raw reply would never match.
  local ws="$1" name="$2" session="$3"
  IWE_WORKSPACE="$ws" python3 -c '
import json, sys
print(json.dumps({
    "tool_name": "Read",
    "tool_input": {"file_path": sys.argv[1] + "/" + sys.argv[2] + "/seed.md"},
    "session_id": sys.argv[3],
}))
' "$ws" "$name" "$session" | IWE_WORKSPACE="$ws" bash "$HOOK" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
print(json.loads(raw).get("hookSpecificOutput", {}).get("additionalContext", ""))
'
}

echo "=== FF: clean tree, remote ahead -> fast-forwards, no stash ==="
WS="$TMP/ok-ff/IWE"; setup_sandbox "$WS" repo-ff
advance_remote "$WS" repo-ff
before_head=$(git -C "$WS/repo-ff" rev-parse HEAD)
out=$(run_hook "$WS" repo-ff pull-ff-only-smoke-ff)
after_head=$(git -C "$WS/repo-ff" rev-parse HEAD)
remote_head=$(git -C "$WS/repo-ff.origin.git" rev-parse main)
check "HEAD advanced to match origin" "$remote_head" "$after_head"
check "HEAD actually moved" "1" "$([ "$before_head" != "$after_head" ] && echo 1 || echo 0)"
check "no stash left behind" "" "$(git -C "$WS/repo-ff" stash list)"
check "hook reports a pull, not a stale warning" "1" "$(printf '%s' "$out" | grep -qF 'Подтянул свежее' && echo 1 || echo 0)"

echo "=== STALE-SAFE: dirty tracked tree, remote ahead -> no merge, no stash, no data loss ==="
WS="$TMP/dirty-tracked/IWE"; setup_sandbox "$WS" repo-dirty
advance_remote "$WS" repo-dirty
echo "uncommitted local work" >> "$WS/repo-dirty/seed.md"
before_head=$(git -C "$WS/repo-dirty" rev-parse HEAD)
out=$(run_hook "$WS" repo-dirty pull-ff-only-smoke-dirty)
after_head=$(git -C "$WS/repo-dirty" rev-parse HEAD)
check "HEAD did not move (merge was skipped)" "$before_head" "$after_head"
check "no autostash was created" "" "$(git -C "$WS/repo-dirty" stash list)"
check "local edit survived on disk" "1" "$(grep -qF 'uncommitted local work' "$WS/repo-dirty/seed.md" && echo 1 || echo 0)"
check "hook names it a stale-not-fetched case" "1" "$(printf '%s' "$out" | grep -qF 'не подтягиваю' && echo 1 || echo 0)"

echo "=== STALE-SAFE: untracked file present, remote ahead -> no merge, no stash (the exact #1245 class) ==="
WS="$TMP/dirty-untracked/IWE"; setup_sandbox "$WS" repo-untracked
advance_remote "$WS" repo-untracked
echo "new work product draft" > "$WS/repo-untracked/new-wp-draft.md"
before_head=$(git -C "$WS/repo-untracked" rev-parse HEAD)
run_hook "$WS" repo-untracked pull-ff-only-smoke-untracked >/dev/null
after_head=$(git -C "$WS/repo-untracked" rev-parse HEAD)
check "HEAD did not move with an untracked file present" "$before_head" "$after_head"
check "no autostash was created" "" "$(git -C "$WS/repo-untracked" stash list)"
check "untracked file survived on disk" "1" "$([ -f "$WS/repo-untracked/new-wp-draft.md" ] && echo 1 || echo 0)"

echo "=== DIVERGED: both sides advanced -> no merge attempted, no stash ==="
WS="$TMP/diverged/IWE"; setup_sandbox "$WS" repo-diverged
advance_remote "$WS" repo-diverged
echo local-side-commit >> "$WS/repo-diverged/seed.md"
git -C "$WS/repo-diverged" add seed.md
git -C "$WS/repo-diverged" commit -q -m local-side-commit
before_head=$(git -C "$WS/repo-diverged" rev-parse HEAD)
run_hook "$WS" repo-diverged pull-ff-only-smoke-diverged >/dev/null
after_head=$(git -C "$WS/repo-diverged" rev-parse HEAD)
check "HEAD did not move on diverged history" "$before_head" "$after_head"
check "no autostash was created" "" "$(git -C "$WS/repo-diverged" stash list)"

echo "=== OK: already up to date -> no pull message ==="
WS="$TMP/already-ok/IWE"; setup_sandbox "$WS" repo-ok
out=$(run_hook "$WS" repo-ok pull-ff-only-smoke-ok)
check "no stash" "" "$(git -C "$WS/repo-ok" stash list)"
check "hook stays silent when already fresh" "" "$out"

echo "=== PRE-EXISTING STASH: unrelated stash from before this hook ran is left untouched ==="
# `stash push` itself cleans the working tree, so the hook sees a clean tree
# and (remote being ahead) does fast-forward -- the point of this case is that
# an unrelated, already-stashed entry must survive that untouched, not that
# the hook should skip the repo.
WS="$TMP/pre-existing-stash/IWE"; setup_sandbox "$WS" repo-prestash
advance_remote "$WS" repo-prestash
# A different file than seed.md (which advance_remote also changes) -- the
# point is an unrelated stash, not a stash that would collide on pop with
# the file the fast-forward itself touches.
echo "unrelated earlier work" > "$WS/repo-prestash/unrelated.md"
git -C "$WS/repo-prestash" stash push -q --include-untracked -m pre-existing
before_stash=$(git -C "$WS/repo-prestash" stash list)
run_hook "$WS" repo-prestash pull-ff-only-smoke-prestash >/dev/null
after_head=$(git -C "$WS/repo-prestash" rev-parse HEAD)
remote_head=$(git -C "$WS/repo-prestash.origin.git" rev-parse main)
check "HEAD still fast-forwards normally despite the unrelated stash" "$remote_head" "$after_head"
check "pre-existing stash entry is untouched (same ref, not popped/dropped/added to)" "$before_stash" "$(git -C "$WS/repo-prestash" stash list)"
check "pre-existing stash content still pops cleanly afterwards" "1" "$(git -C "$WS/repo-prestash" stash pop -q >/dev/null 2>&1 && grep -qF 'unrelated earlier work' "$WS/repo-prestash/unrelated.md" && echo 1 || echo 0)"

echo "=== DETACHED HEAD: no upstream branch to compare against -> no merge, no stash ==="
WS="$TMP/detached/IWE"; setup_sandbox "$WS" repo-detached
advance_remote "$WS" repo-detached
git -C "$WS/repo-detached" checkout -q --detach HEAD
before_head=$(git -C "$WS/repo-detached" rev-parse HEAD)
run_hook "$WS" repo-detached pull-ff-only-smoke-detached >/dev/null
after_head=$(git -C "$WS/repo-detached" rev-parse HEAD)
check "HEAD did not move on detached HEAD" "$before_head" "$after_head"
check "no autostash was created" "" "$(git -C "$WS/repo-detached" stash list)"

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: все проверки pull-on-touch.sh (ff-only, без autostash) прошли"
  exit 0
else
  echo "FAIL: $FAILURES проверок не прошли"
  exit 1
fi
