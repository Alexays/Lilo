#!/bin/sh
# Checks scripts/scope_checks.sh: its table of diffs per quick tier and a real git diff.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCOPE="$ROOT/scripts/scope_checks.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lilo-scope-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
# The missing-base assertions below exercise the non-CI path; CI behavior is set inline where tested.
unset GITHUB_ACTIONS

fail() { printf 'scope_checks.test.sh: %s\n' "$*" >&2; exit 1; }

tier() {
    tier=$1 want=$2; shift 2
    got=$(printf '%s\n' "$@" | "$SCOPE" --tier "$tier" --files)
    [ "$got" = "$want" ] || fail "tier $tier for '$*' expected '$want', got '$got'"
}

# A Swift-only change is swiftlint alone, nothing builds, and what has no quick check is none.
tier check swiftlint-changed Lilo/App/Foo.swift Lilo/Agent/Bar.swift
tier check "ui-check release-status" lilo-ui/src/lib/foo.ts docs/ARCHITECTURE.md
tier check "ui-check swiftlint-changed" lilo-ui/src/lib/foo.ts Lilo/App/Foo.swift
tier check "ui-check docs-check" lilo-ui/src/lib/i18n/locales/fr.json
tier check docs-check docs-site/content/index.md
tier check release-status .changes/unreleased/Fixed-1.yaml
tier check none site/src/pages/index.astro
tier check none Makefile scripts/x.sh LiloTests/FooTests.swift
tier commit "swiftlint-changed sync-check" Lilo/App/Foo.swift
tier commit "ui-check sync-check" lilo-ui/src/lib/tabProtocol.gen.ts
tier commit sync-check project.yml
tier commit none Makefile
[ "$(printf '' | "$SCOPE" --tier check --files)" = none ] || fail "an empty diff is not none"
status=0; "$SCOPE" --files < /dev/null 2> /dev/null || status=$?
[ "$status" -ne 0 ] || fail "--tier is required"

# A real diff: the merge base, edits to tracked files and new files all count.
cd "$WORK"
git init -q repo && cd repo
mkdir -p lilo-ui/src docs
echo a > lilo-ui/src/a.ts; echo a > docs/a.md
git add -A && git -c user.name=t -c user.email=t@example.com commit -q -m base && git branch base
[ "$("$SCOPE" --tier check base)" = none ] || fail "no diff should be none"
echo b >> lilo-ui/src/a.ts
[ "$("$SCOPE" --tier check base)" = "ui-check" ] || fail "edited UI file: $("$SCOPE" --tier check base)"
echo c > docs/new.md
[ "$("$SCOPE" --tier check base)" = "ui-check release-status" ] || fail "new docs file: $("$SCOPE" --tier check base)"
echo d > Foo.swift
[ "$("$SCOPE" --tier check base)" = "ui-check release-status" ] || fail "a top-level Swift file stays none (no quick check)"
[ "$("$SCOPE" --tier check no-such-ref 2> /dev/null)" = full ] || fail "unknown base is not full"
[ -z "$("$SCOPE" --list no-such-ref 2> /dev/null)" ] || fail "unknown base lists files"
# Under CI a missing base is an error, never a silent full or skip.
for args in "--tier check no-such-ref" "--list no-such-ref"; do
    status=0; out=$(GITHUB_ACTIONS=true "$SCOPE" $args 2> /dev/null) || status=$?
    [ "$status" -ne 0 ] && [ -z "$out" ] || fail "GITHUB_ACTIONS with a missing base ($args): status $status, output '$out'"
done
[ "$("$SCOPE" --list base)" = "$(printf 'Foo.swift\ndocs/new.md\nlilo-ui/src/a.ts')" ] || fail "--list: $("$SCOPE" --list base)"
git add -A
[ "$("$SCOPE" --tier commit --staged)" = "ui-check release-status sync-check" ] || fail "--staged: $("$SCOPE" --tier commit --staged)"

echo "scope_checks.test.sh: ok"
