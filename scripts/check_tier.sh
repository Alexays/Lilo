#!/bin/sh
# Run the quick checks of a tier, quietly, stopping at the first failure:
#   scripts/check_tier.sh check [BASE]   `make check`: the diff against BASE (origin/main), the work tree included
#   scripts/check_tier.sh commit         the pre-commit hook: the staged files
# scripts/scope_checks.sh picks the targets; each runs through check_summary.py, so JSON=1 works as for
# validate, and the environment carries LILO_CHECK_TIER (check or pre-commit), LILO_CHECK_TRIGGER (hook, agent
# or manual) and the scope for whatever wraps the checks.
set -eu

tier=${1:?usage: check_tier.sh check [BASE] | commit}
shift
case $tier in
    check) set -- "${1:-origin/main}"; tier_name=check; tests=1 ;;
    commit) set -- --staged; tier_name=pre-commit; tests=0 ;;
    *) echo "check_tier.sh: unknown tier $tier" >&2; exit 2 ;;
esac

checks=$(scripts/scope_checks.sh --tier "$tier" "$@")
if [ "$checks" = none ]; then
    echo "$tier_name: no quick check for these changes; git push runs validate-scope"
    exit 0
fi
# No base, so no list: every quick check runs on the whole tree.
files=$(scripts/scope_checks.sh --list "$@" | while IFS= read -r file; do [ -f "$file" ] && printf '%s\n' "$file"; done || :)
[ "$checks" != full ] || checks="ui-check swiftlint-changed docs-check release-status"

trigger=${LILO_CHECK_TRIGGER:-}
[ -n "$trigger" ] || if [ -n "${CLAUDECODE:-}" ]; then trigger=agent; else trigger=manual; fi
export LILO_CHECK_TIER=$tier_name LILO_CHECK_TRIGGER=$trigger LILO_CHECK_SCOPE="$checks" LILO_CHECK_FILES="$files" LILO_CHECK_TESTS=$tests

logs=$(mktemp -d)
trap 'rm -rf "$logs"' EXIT
ran=; status=0
for check in $checks; do
    ran="$ran $check"
    python3 scripts/check_summary.py run "$check" "$logs" -- make --no-print-directory "$check" || { status=1; break; }
done
python3 scripts/check_summary.py report ${JSON:+--json} "$logs" $ran || status=1
exit $status
