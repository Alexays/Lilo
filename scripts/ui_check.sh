#!/bin/sh
# The UI's quick check: eslint on the changed files and the tests beside them (make check, the pre-commit hook).
# LILO_CHECK_FILES lists the changed paths, empty for the whole tree; LILO_CHECK_TESTS=0 skips the tests. svelte-check
# type-checks the whole project in about 7 s, past this tier's budget, so it stays in `make ui-lint`, which pre-push runs.
set -eu
cd lilo-ui
cache="--cache --cache-location node_modules/.cache/eslint/"

if [ -z "${LILO_CHECK_FILES:-}" ]; then
    npm exec -- eslint $cache .
    [ "${LILO_CHECK_TESTS:-1}" = 0 ] || npm run test
    exit 0
fi

files=$(printf '%s\n' "$LILO_CHECK_FILES" | sed -n 's|^lilo-ui/||p')
lintable=$(printf '%s\n' "$files" | grep -E '\.(ts|js|mjs|svelte)$' || :)
[ -z "$lintable" ] || npm exec -- eslint $cache $lintable
[ "${LILO_CHECK_TESTS:-1}" != 0 ] || exit 0

# The test of each changed file: itself, its sibling, or the catalog tests for a locale.
related() {
    while IFS= read -r file; do
        case $file in
            *.test.ts) echo "$file" ;;
            src/lib/i18n/locales/*) ls src/lib/i18n/*.test.ts ;;
            *.ts | *.svelte) [ ! -f "${file%.*}.test.ts" ] || echo "${file%.*}.test.ts" ;;
        esac
    done
}
tests=$(printf '%s\n' "$files" | related | sort -u)
[ -z "$tests" ] || npm exec -- tsx --test --experimental-test-isolation=none $tests
