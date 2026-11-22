#!/bin/sh
# Print the quick checks a set of changed files needs, or the changed paths themselves:
#   scripts/scope_checks.sh --tier check [BASE]     `make check`: the diff of the work tree against merge-base(HEAD, BASE)
#   scripts/scope_checks.sh --tier commit           the pre-commit hook: the staged files
#   scripts/scope_checks.sh --tier T --files        the changed paths, one per line, on stdin
#   scripts/scope_checks.sh --tier T --staged       the staged paths
#   scripts/scope_checks.sh --list [BASE|--staged|--files]   the changed paths of any of the above (none when there is no base)
# The quick tiers never build: a Swift-only diff is `swiftlint-changed`, with no UI, site or docs work, and a diff the
# tiers have no quick check for (the Makefile, scripts, the websites) is `none`, left to the push's full validate. Their
# `full` (no merge base, locally) runs every quick check on the whole tree; an empty diff is `none`. Under GITHUB_ACTIONS
# a range git cannot read is an error instead: CI never widens or skips on a missing base.
set -eu

list=
if [ "${1:-}" = --list ]; then list=1; shift; fi
tier=
if [ "${1:-}" = --tier ]; then
    tier=${2:?scope_checks.sh: --tier needs check or commit}
    shift 2
fi
[ -n "$list$tier" ] || { echo "scope_checks.sh: --list or --tier check|commit is required" >&2; exit 2; }

case ${1:-} in
    --files) files=$(cat) ;;
    --staged) files=$(git diff --cached --name-only) ;;
    *)
        base=${1:-origin/main}
        mergebase=$(git merge-base HEAD "$base" 2> /dev/null) || {
            [ -z "${GITHUB_ACTIONS:-}" ] || { echo "scope_checks.sh: no merge base with $base under GITHUB_ACTIONS: fetch it (fetch-depth: 0)" >&2; exit 2; }
            echo "scope_checks.sh: no merge base with $base, so full" >&2; [ -n "$list" ] || echo full; exit 0
        }
        files=$({ git diff --name-only "$mergebase"; git ls-files --others --exclude-standard; } | sort -u)
        ;;
esac
if [ -n "$list" ]; then [ -z "$files" ] || printf '%s\n' "$files"; exit 0; fi
[ -n "$files" ] || { echo none; exit 0; }

ui=; swift=; docs=; notes=; sync=
while IFS= read -r file; do
    case $file in
        lilo-ui/src/components/settings/settingsPanelModel.ts | lilo-ui/src/lib/i18n/locales/en.json | lilo-ui/src/lib/i18n/locales/fr.json) ui=1; docs=1 ;;
        lilo-ui/*) ui=1 ;;
        docs-site/*) docs=1 ;;
        Lilo/*.swift) swift=1 ;;
        .changes/* | docs/* | *.md) notes=1 ;;
    esac
    case $file in
        *.gen.* | bridge-schema/* | scripts/generate_bridge_protocol.mjs | project.yml | *.swift) sync=1 ;;
    esac
done << EOL
$files
EOL
checks=${ui:+ui-check }${swift:+swiftlint-changed }${docs:+docs-check }${notes:+release-status }
[ "$tier" != commit ] || checks=$checks${sync:+sync-check }
checks=${checks% }
echo "${checks:-none}"
