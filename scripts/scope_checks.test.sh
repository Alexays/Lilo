#!/bin/sh
# Checks scripts/scope_checks.sh: its table of diffs, its agreement with CI's code/not-code split, and a real git diff.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCOPE="$ROOT/scripts/scope_checks.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lilo-scope-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
# The missing-base assertions below exercise the non-CI path; CI behavior is set inline where tested.
unset GITHUB_ACTIONS

fail() { printf 'scope_checks.test.sh: %s\n' "$*" >&2; exit 1; }
scope() { printf '%s\n' "$@" | "$SCOPE" --files; }
expect() {
    want=$1; shift
    got=$(scope "$@")
    [ "$got" = "$want" ] || fail "for '$*' expected '$want', got '$got'"
}

tier() {
    tier=$1 want=$2; shift 2
    got=$(printf '%s\n' "$@" | "$SCOPE" --tier "$tier" --files)
    [ "$got" = "$want" ] || fail "tier $tier for '$*' expected '$want', got '$got'"
}

expect "ui-lint ui-test release-status" lilo-ui/src/lib/foo.ts lilo-ui/src/app.css
expect "site-check site-test release-status" site/src/pages/index.astro
expect "docs-check docs-test release-status" docs-site/content/index.md
expect "release-status" docs/ARCHITECTURE.md AGENTS.md .changes/unreleased/Fixed-1.yaml
expect "ui-lint ui-test docs-check docs-test release-status" lilo-ui/src/lib/i18n/locales/fr.json
expect "ui-lint ui-test site-check site-test release-status" lilo-ui/src/lib/foo.ts site/README.md
expect full Lilo/App/Foo.swift
expect full lilo-ui/src/lib/foo.ts Makefile
expect full COMPATIBILITY.md docs/ARCHITECTURE.md
expect full lilo-ui/src/lib/foo.ts Lilo/Extensions/bridge-src/src/a.ts
expect full scripts/scope_checks.sh
# The quick tiers: a Swift-only change is swiftlint alone, nothing builds, and what has no quick check is none.
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
[ "$(printf '' | "$SCOPE" --tier check --files)" = none ] || fail "an empty diff is not none for the quick tiers"
[ "$(printf '' | "$SCOPE" --files)" = full ]  || fail "an empty diff is not full"

# The code split must say what CI's changes job says. The regex and the test are read from build.yml itself.
workflow="$ROOT/.github/workflows/build.yml"
regex=$(sed -n "s/.*grep -qvE '\\(.*\\)' .*/\\1/p" "$workflow")
[ -n "$regex" ] || fail "no code/not-code regex found in $workflow"
grep -q "grep -qx COMPATIBILITY.md" "$workflow" || fail "build.yml's changes job no longer special-cases COMPATIBILITY.md"
ci_code() {
    code=true
    printf '%s\n' "$@" | grep -qvE "$regex" || printf '%s\n' "$@" | grep -qx COMPATIBILITY.md || code=false
    echo $code
}
for path in Lilo/App/Foo.swift lilo-ui/src/a.ts Makefile project.yml scripts/x.sh .github/workflows/build.yml README.md AGENTS.md \
    docs/ARCHITECTURE.md docs-site/content/a.md docs-site/src/a.ts site/src/a.astro site/package.json .changes/unreleased/a.yaml \
    COMPATIBILITY.md docs/COMPATIBILITY.md Xcode/Configs/Base.xcconfig LiloTests/A.swift notes.md; do
    got=$(scope "$path")
    case $got in full | *ui-lint*) mine=true ;; *) mine=false ;; esac
    [ "$mine" = "$(ci_code "$path")" ] || fail "$path: CI says code=$(ci_code "$path"), scope_checks says '$got'"
done

# A real diff: the merge base, edits to tracked files and new files all count.
cd "$WORK"
git init -q repo && cd repo
mkdir -p lilo-ui/src docs
echo a > lilo-ui/src/a.ts; echo a > docs/a.md
git add -A && git -c user.name=t -c user.email=t@example.com commit -q -m base && git branch base
[ "$("$SCOPE" base)" = full ] || fail "no diff should be full"
echo b >> lilo-ui/src/a.ts
[ "$("$SCOPE" base)" = "ui-lint ui-test release-status" ] || fail "edited UI file: $("$SCOPE" base)"
echo c > docs/new.md
[ "$("$SCOPE" base)" = "ui-lint ui-test release-status" ] || fail "new docs file: $("$SCOPE" base)"
echo d > Foo.swift
[ "$("$SCOPE" base)" = full ] || fail "new Swift file"
[ "$("$SCOPE" no-such-ref 2> /dev/null)" = full ] || fail "unknown base is not full"
[ "$("$SCOPE" --tier check no-such-ref 2> /dev/null)" = full ] || fail "unknown base is not full for the quick tiers"
[ -z "$("$SCOPE" --list no-such-ref 2> /dev/null)" ] || fail "unknown base lists files"
# Under CI a missing base is an error, never a silent full or skip.
for args in "no-such-ref" "--tier check no-such-ref" "--list no-such-ref"; do
    status=0; out=$(GITHUB_ACTIONS=true "$SCOPE" $args 2> /dev/null) || status=$?
    [ "$status" -ne 0 ] && [ -z "$out" ] || fail "GITHUB_ACTIONS with a missing base ($args): status $status, output '$out'"
done
[ "$("$SCOPE" --list base)" = "$(printf 'Foo.swift\ndocs/new.md\nlilo-ui/src/a.ts')" ] || fail "--list: $("$SCOPE" --list base)"
git add -A
[ "$("$SCOPE" --tier commit --staged)" = "ui-check release-status sync-check" ] || fail "--staged: $("$SCOPE" --tier commit --staged)"

echo "scope_checks.test.sh: ok"
