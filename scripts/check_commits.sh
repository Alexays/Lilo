#!/bin/bash
# Builds every commit of BASE..HEAD with SwiftPM in a throwaway worktree.
# Usage: scripts/check_commits.sh [base] (default origin/main)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${1:-origin/main}"
# A fixed path per checkout keeps the SwiftPM cache under .build/check-commits valid across runs, and two
# checkouts checking at once never remove each other's worktree.
WT="${TMPDIR:-/tmp}/lilo-check-commits-$(printf '%s' "$ROOT" | shasum | cut -c1-8)"
cd "$ROOT"

COMMITS="$(git rev-list --reverse "$BASE..HEAD")"
if [ -z "$COMMITS" ]; then
    echo "No commits between $BASE and HEAD"
    exit 0
fi

git worktree remove --force "$WT" 2>/dev/null || true
/bin/rm -rf "$WT"
git worktree prune
trap 'git worktree remove --force "$WT" 2>/dev/null; git worktree prune' EXIT
git worktree add -q --detach "$WT" HEAD

# The worktree starts from this tree's Vendor and UI bundle; only NativeStrings is regenerated per commit.
[ -d Vendor ] && /bin/cp -Rf Vendor "$WT/"
mkdir -p "$WT/Lilo/Generated"
/bin/cp -f Lilo/Generated/ChromeUIAssets.swift "$WT/Lilo/Generated/" 2>/dev/null || make --no-print-directory -C "$WT" ui-build

for commit in $COMMITS; do
    subject="$(git log -1 --format='%h %s' "$commit")"
    echo "== $subject"
    git -C "$WT" checkout -q --detach "$commit"
    if ! (make --no-print-directory -C "$WT" vt-build \
        && cd "$WT" && python3 scripts/generate_native_strings.py \
        && swift build -q --scratch-path "$ROOT/.build/check-commits"); then
        echo "check-commits: $subject does not build" >&2
        exit 1
    fi
done
echo "All $(echo "$COMMITS" | wc -l | tr -d ' ') commits build"
