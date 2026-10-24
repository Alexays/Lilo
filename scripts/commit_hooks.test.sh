#!/bin/sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VALIDATOR="$ROOT/scripts/lint_commit_message.sh"
RANGE_VALIDATOR="$ROOT/scripts/lint_commits.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lilo-hooks.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

expect_status() {
    expected=$1
    shift
    actual=0
    "$@" > "$TEST_DIR/output" 2>&1 || actual=$?
    if [ "$actual" -ne "$expected" ]; then
        cat "$TEST_DIR/output" >&2
        printf 'Expected exit %s, got %s: %s\n' "$expected" "$actual" "$*" >&2
        exit 1
    fi
}

while IFS= read -r subject; do
    printf '%s\n' "$subject" > "$TEST_DIR/message"
    expect_status 0 "$VALIDATOR" "$TEST_DIR/message"
done <<'VALID'
feat: add tab groups
fix(sidebar): hide empty spaces
perf: reduce idle work
refactor(tabs): simplify selection
docs: explain setup
test: cover pinned tabs
build: update the project
ci: check commit messages
chore(deps): update packages
style: align the toolbar
feat!: remove the old bridge
feat(bridge)!: change the tab protocol
fix(extension-bridge): preserve URL casing
chore(release): 0.1.5
Revert "feat: add tab groups"
Reapply "feat: add tab groups"
VALID

while IFS= read -r subject; do
    printf '%s\n' "$subject" > "$TEST_DIR/message"
    expect_status 1 "$VALIDATOR" "$TEST_DIR/message"
done <<'INVALID'

update tabs
feature: add tab groups
Fix: hide empty spaces
fix(): hide empty spaces
fix(Sidebar): hide empty spaces
fix(side bar): hide empty spaces
fix:hide empty spaces
fix:
fix:  hide empty spaces
fix: hide empty spaces.
fix: Hide empty spaces
Revert ""
Revert feat: add tab groups
 fix: hide empty spaces
fixup! fix: hide empty spaces
Merge branch 'main'
INVALID

for subject in 'fix:   ' 'fix: hide empty spaces '; do
    printf '%s\n' "$subject" > "$TEST_DIR/message"
    expect_status 1 "$VALIDATOR" "$TEST_DIR/message"
done

printf '%s' 'fix: accept input without a final newline' > "$TEST_DIR/message with spaces"
expect_status 0 "$VALIDATOR" "$TEST_DIR/message with spaces"
expect_status 0 "$VALIDATOR" < "$TEST_DIR/message with spaces"
printf '%s\n' 'docs: explain setup' '' 'Body text and BREAKING CHANGE footers remain free-form.' > "$TEST_DIR/message"
expect_status 0 "$VALIDATOR" "$TEST_DIR/message"
cd "$TEST_DIR"
printf '%s\n' 'fix: keep $(touch sentinel) and `commands` literal' > "$TEST_DIR/message"
expect_status 0 "$VALIDATOR" < "$TEST_DIR/message"
expect_status 0 test ! -e sentinel

REPO="$TEST_DIR/repo"
git -c init.defaultBranch=main init -q "$REPO"
git -C "$REPO" config user.name 'Hook tests'
git -C "$REPO" config user.email 'hooks@example.invalid'
git -C "$REPO" -c core.hooksPath=/dev/null commit -q --allow-empty -m 'legacy history'
BASE=$(git -C "$REPO" rev-parse HEAD)
mkdir -p "$REPO/.githooks" "$REPO/scripts"
cp "$ROOT/.githooks/commit-msg" "$REPO/.githooks/"
cp "$VALIDATOR" "$REPO/scripts/"
expect_status 0 env GIT_DIR="$REPO/.git" GIT_WORK_TREE="$REPO" make --no-print-directory -C "$ROOT" hooks-install
cd "$REPO"
expect_status 0 git commit -q --allow-empty -m 'fix: accept a valid commit'
expect_status 1 git commit -q --allow-empty -m 'work in progress'
printf '%s\n' '# a comment Git strips' '' 'fix: skip comment lines' > "$TEST_DIR/message"
expect_status 0 git commit -q --allow-empty --cleanup=strip -F "$TEST_DIR/message"
expect_status 0 git -c core.commentChar=';' commit -q --allow-empty --cleanup=strip -m '; a comment' -m 'fix: honor the comment character'
expect_status 0 "$RANGE_VALIDATOR" "$BASE"
expect_status 0 "$RANGE_VALIDATOR" HEAD

git checkout -qb feature
git commit -q --allow-empty -m 'feat: add a feature'
git checkout -q main
git commit -q --allow-empty -m 'docs: explain the feature'
expect_status 0 git merge -q --no-ff feature -m "Merge branch 'feature'"
expect_status 0 "$RANGE_VALIDATOR" "$BASE"
MERGED=$(git rev-parse HEAD)

for prefix in 'fixup!' 'squash!' 'amend!'; do
    expect_status 0 git commit -q --allow-empty -m "$prefix fix: accept a valid commit"
done
git commit -q --allow-empty -m 'test: cover autosquash commits'
expect_status 1 "$RANGE_VALIDATOR" "$MERGED"

git -c core.hooksPath=/dev/null commit -q --allow-empty -m 'invalid commit bypassing the hook'
INVALID=$(git rev-parse HEAD)
git commit -q --allow-empty -m 'fix: keep checking earlier commits'
expect_status 1 "$RANGE_VALIDATOR" "$INVALID^"
if ! grep -q "$INVALID" "$TEST_DIR/output"; then
    printf 'The range check did not identify the invalid commit.\n' >&2
    exit 1
fi
expect_status 0 "$RANGE_VALIDATOR" "$MERGED" "$MERGED"
expect_status 128 "$RANGE_VALIDATOR" refs/heads/missing

printf 'change\n' > change
git add change
git commit -q -m 'feat: add a revertible change'
expect_status 0 git revert --no-edit HEAD
expect_status 0 "$RANGE_VALIDATOR" HEAD~2

HOOKED_REPO="$TEST_DIR/hooked"
git -c init.defaultBranch=main init -q "$HOOKED_REPO"
printf '#!/bin/sh\n' > "$HOOKED_REPO/.git/hooks/pre-push"
expect_status 2 env GIT_DIR="$HOOKED_REPO/.git" make --no-print-directory -C "$ROOT" hooks-install
/bin/rm -f "$HOOKED_REPO/.git/hooks/pre-push"
git -C "$HOOKED_REPO" config core.hooksPath hooks
expect_status 2 env GIT_DIR="$HOOKED_REPO/.git" make --no-print-directory -C "$ROOT" hooks-install
git -C "$HOOKED_REPO" config core.hooksPath .githooks
expect_status 0 env GIT_DIR="$HOOKED_REPO/.git" make --no-print-directory -C "$ROOT" hooks-install

INITIAL_REPO="$TEST_DIR/initial"
git -c init.defaultBranch=main init -q "$INITIAL_REPO"
git -C "$INITIAL_REPO" config user.name 'Hook tests'
git -C "$INITIAL_REPO" config user.email 'hooks@example.invalid'
git -C "$INITIAL_REPO" -c core.hooksPath=/dev/null commit -q --allow-empty -m 'feat: initialize the project'
cd "$INITIAL_REPO"
expect_status 0 "$RANGE_VALIDATOR" 0000000000000000000000000000000000000000

printf 'Commit hook and message validation tests passed.\n'
