#!/bin/sh
set -eu

VALIDATOR="$(cd "$(dirname "$0")" && pwd)/lint_commit_message.sh"
commit_base=${1:-origin/main}
commit_head=${2:-HEAD}

# A branch's first push has an all-zero before SHA.
if [ "$commit_base" = 0000000000000000000000000000000000000000 ]; then
    commits=$(git rev-list --reverse --no-merges "$commit_head")
else
    commits=$(git rev-list --reverse --no-merges "$commit_base..$commit_head")
fi

status=0
for commit in $commits; do
    if ! git show -s --format=%B "$commit" | "$VALIDATOR"; then
        printf 'Invalid commit: %s\n' "$commit" >&2
        status=1
    fi
done
exit "$status"
