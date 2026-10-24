#!/bin/sh
set -eu
export LC_ALL=C

subject=$(sed -n '1p' "${1:-/dev/stdin}")
pattern='^(feat|fix|perf|refactor|docs|test|build|ci|chore|style)(\([a-z0-9][a-z0-9._/-]*\))?!?: [^[:space:]]'

if printf '%s\n' "$subject" | grep -Eq "$pattern"; then
    case "$subject" in
        *[[:space:].]) ;;
        *) exit 0 ;;
    esac
fi

printf '%s\n' \
    "Invalid Conventional Commit header: $subject" \
    'Expected type(scope): description, with an optional scope and optional ! before the colon.' \
    'Types: feat, fix, perf, refactor, docs, test, build, ci, chore, style.' \
    'Use a lowercase scope and a description without trailing whitespace or a final period.' \
    'Example: fix(sidebar): keep pinned tabs visible' >&2
exit 1
