#!/bin/sh
# Checks the quick tiers end to end in throwaway repositories: scripts/check_tier.sh with a stub Makefile that records what
# each check target saw, the pre-commit and pre-push hooks around it, and scripts/sync_check.sh. No npm, no network.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lilo-tier-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export LILO_TSC_LOCK="$WORK/tsc.lock"
unset CLAUDECODE GITHUB_ACTIONS LILO_CHECK_TRIGGER LILO_CHECK_TIER JSON STUB_FAIL

fail() { printf 'check_tier.test.sh: %s\n' "$*" >&2; exit 1; }
status_of() {
    want=$1; shift
    got=0; "$@" > "$WORK/out" 2>&1 || got=$?
    [ "$got" = "$want" ] || { cat "$WORK/out" >&2; fail "expected exit $want, got $got: $*"; }
}

REPO="$WORK/repo"
git -c init.defaultBranch=main init -q "$REPO"
cd "$REPO"
git config user.name t; git config user.email t@example.invalid
mkdir -p scripts .githooks Lilo lilo-ui/src docs bridge-schema
cp "$ROOT"/scripts/check_tier.sh "$ROOT"/scripts/scope_checks.sh "$ROOT"/scripts/sync_check.sh "$ROOT"/scripts/check_summary.py scripts/
cp "$ROOT"/.githooks/pre-commit "$ROOT"/.githooks/pre-push .githooks/
# Every check target records its tier, trigger, files and whether tests run; STUB_FAIL names the one that fails.
cat > Makefile << 'MK'
check check-staged:
	@scripts/check_tier.sh $(if $(filter check-staged,$@),commit,check) $(BASE)
# A stale stamp reinstalls like npm ci does: the real recipe empties a linked node_modules.
quick-deps:
	@[ "$(CHECK)" != ui-check ] || echo lilo-ui/node_modules/.package-lock.json
lilo-ui/node_modules/.package-lock.json: package-lock.json
	@find lilo-ui/node_modules/ -mindepth 1 -delete; touch $@
ui-check: lilo-ui/node_modules/.package-lock.json
ui-check swiftlint-changed docs-check release-status sync-check validate-scope:
	@echo "$@ tier=$$LILO_CHECK_TIER trigger=$$LILO_CHECK_TRIGGER tests=$$LILO_CHECK_TESTS files=$$(echo $$LILO_CHECK_FILES)" >> "$(CURDIR)/ran"
	@[ "$$STUB_FAIL" != "$@" ] || { echo "$@ broke"; exit 1; }
MK
mkdir -p lilo-ui/node_modules; echo lock > package-lock.json; touch lilo-ui/node_modules/.package-lock.json
echo base > docs/base.md; echo a > lilo-ui/src/a.ts; echo a > Lilo/A.swift
git add -A && git -c core.hooksPath=/dev/null commit -q -m "chore: base"
git branch base
ran() { cat ran 2> /dev/null || :; rm -f ran; }
names() { ran | cut -d' ' -f1 | tr '\n' ' '; }

# A Swift-only change: swiftlint on that file, nothing else.
echo b >> Lilo/A.swift
status_of 0 make --no-print-directory check BASE=base
grep -q '^ok  swiftlint-changed' "$WORK/out" || fail "no one-line summary: $(cat "$WORK/out")"
[ "$(ran)" = "swiftlint-changed tier=check trigger=manual tests=1 files=Lilo/A.swift" ] || fail "swift only"

# UI and docs together, in order; fail-first stops at the first failure and prints its log.
echo b >> lilo-ui/src/a.ts; echo b >> docs/base.md
status_of 0 env CLAUDECODE=1 make --no-print-directory check BASE=base
[ "$(names)" = "ui-check swiftlint-changed release-status " ] || fail "ui, swift and docs"
status_of 2 env STUB_FAIL=ui-check make --no-print-directory check BASE=base
[ "$(names)" = "ui-check " ] || fail "fail-first ran more than the failed check"
grep -q 'ui-check broke' "$WORK/out" || fail "the failed check's log is not printed"
status_of 2 env JSON=1 STUB_FAIL=ui-check make --no-print-directory check BASE=base
grep -q '"check":"ui-check","ok":false' "$WORK/out" || fail "JSON=1 prints no JSON"
rm -f ran
git checkout -q .

# A change with no quick check, an unknown base locally (every quick check, whole tree), and under CI (an error).
echo b >> scripts/check_tier.sh
status_of 0 make --no-print-directory check BASE=base
[ ! -e ran ] || fail "a script change ran a check"
git checkout -q .
status_of 0 make --no-print-directory check BASE=no-such-ref
[ "$(names)" = "ui-check swiftlint-changed docs-check release-status " ] || fail "unknown base is not every check"
status_of 2 env GITHUB_ACTIONS=true scripts/check_tier.sh check no-such-ref

# The tier, the trigger and the changed files reach each check through the environment.
echo c >> Lilo/A.swift
status_of 0 env LILO_CHECK_TRIGGER=agent make --no-print-directory check BASE=base
[ "$(ran)" = "swiftlint-changed tier=check trigger=agent tests=1 files=Lilo/A.swift" ] || fail "tier and trigger"
git checkout -q .

# pre-commit: the staged files only, tests off, trigger hook; a failure blocks the commit and names the way out.
git config core.hooksPath .githooks
# Opt-in: with only the commit-msg hook installed, a commit and a push run no check.
echo b >> Lilo/A.swift; git add Lilo/A.swift
status_of 0 git commit -q -m "chore: hooks off"
git init -q --bare "$WORK/off.git"
status_of 0 git push -q "$WORK/off.git" HEAD:refs/heads/off
[ ! -e ran ] || fail "a hook ran without its opt-in: $(cat ran)"
git config lilo.hooks.pre-commit true
echo c >> lilo-ui/src/a.ts; echo b2 >> Lilo/A.swift; git add Lilo/A.swift
status_of 0 git commit -q -m "chore: stage swift only"
[ "$(names)" = "swiftlint-changed sync-check " ] || fail "pre-commit ran the wrong checks: $(cat "$WORK/out")"
echo d >> Lilo/A.swift; git add Lilo/A.swift
status_of 1 env STUB_FAIL=swiftlint-changed git commit -q -m "chore: blocked"
grep -q 'git commit --no-verify' "$WORK/out" || fail "the failure does not name --no-verify"
rm -f ran
status_of 0 env STUB_FAIL=swiftlint-changed git commit -q --no-verify -m "chore: skipped on purpose"
[ ! -e ran ] || fail "--no-verify ran the hook"
git checkout -q .

# pre-push: validate-scope with the tier and trigger; a failure blocks; --no-verify and a branch deletion do not run it.
git init -q --bare "$WORK/remote.git"
git remote add origin "$WORK/remote.git"
rm -f ran
git config lilo.hooks.pre-push true
git config --unset lilo.hooks.pre-commit
status_of 0 git commit -q --allow-empty -m "chore: pre-commit stays off"
[ ! -e ran ] || fail "pre-push opt-in enabled pre-commit"
status_of 0 git push -q origin HEAD:refs/heads/one
[ "$(ran)" = "validate-scope tier=pre-push trigger=hook tests= files=" ] || fail "pre-push"
status_of 1 env STUB_FAIL=validate-scope git push -q origin HEAD:refs/heads/two
grep -q 'git push --no-verify' "$WORK/out" || fail "the failure does not name --no-verify"
rm -f ran
status_of 0 env STUB_FAIL=validate-scope git push -q --no-verify origin HEAD:refs/heads/two
status_of 0 env STUB_FAIL=validate-scope git push -q origin :refs/heads/two
[ ! -e ran ] || fail "--no-verify or a deletion ran validate-scope"

# Never install: a symlinked shared node_modules with a lockfile newer than the stamp is left intact and ui-check is skipped.
git config lilo.hooks.pre-commit true
mkdir -p "$WORK/shared"; echo dep > "$WORK/shared/a"; echo dep > "$WORK/shared/b"
rm -rf lilo-ui/node_modules; ln -s "$WORK/shared" lilo-ui/node_modules; touch -t 200001010000 "$WORK/shared/.package-lock.json"
touch package-lock.json
echo z >> lilo-ui/src/a.ts; echo z >> Lilo/A.swift; git add lilo-ui/src/a.ts Lilo/A.swift
status_of 0 git commit -q -m "chore: stale install"
[ "$(ls -A "$WORK/shared" | wc -l | tr -d ' ')" = 3 ] || fail "a hook emptied the shared node_modules: $(ls "$WORK/shared")"
grep -q 'skipped ui-check' "$WORK/out" || fail "the skipped check is not reported: $(cat "$WORK/out")"
[ "$(names)" = "swiftlint-changed sync-check " ] || fail "a stale install still ran ui-check"
status_of 0 scripts/check_tier.sh check base
[ "$(ls -A "$WORK/shared" | wc -l | tr -d ' ')" = 3 ] || fail "make check emptied the shared node_modules"
git reset -q --hard

# sync-check: a Swift file added or deleted needs Lilo.xcodeproj, so does project.yml; the bridge outputs must be fresh.
git config core.hooksPath /dev/null
echo x > Lilo/B.swift; git add Lilo/B.swift
status_of 1 scripts/sync_check.sh
grep -q 'make project-sync' "$WORK/out" || fail "an added Swift file without the project"
mkdir -p Lilo.xcodeproj; echo p > Lilo.xcodeproj/project.pbxproj; git add Lilo.xcodeproj
status_of 0 scripts/sync_check.sh
git commit -q -m "chore: add a swift file"
echo e >> Lilo/B.swift; git add Lilo/B.swift
status_of 0 scripts/sync_check.sh
git rm -qf Lilo/B.swift
status_of 1 scripts/sync_check.sh
git reset -q --hard
echo y > project.yml; git add project.yml
status_of 1 scripts/sync_check.sh
git reset -q --hard
rm -f project.yml
echo '{}' > bridge-schema/tab.json; git add bridge-schema/tab.json
echo 'console.log("wrote some.gen.ts")' > scripts/generate_bridge_protocol.mjs
status_of 1 scripts/sync_check.sh
grep -q 'wrote some.gen.ts' "$WORK/out" || fail "stale bridge outputs are not reported"
echo '// nothing to write' > scripts/generate_bridge_protocol.mjs
status_of 0 scripts/sync_check.sh

echo "check_tier.test.sh: ok"
