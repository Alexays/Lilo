#!/bin/sh
# Print the make targets a diff needs: `full` (run make validate) or a list of check targets.
#   scripts/scope_checks.sh [BASE]     the diff of the work tree against merge-base(HEAD, BASE), BASE defaulting to origin/main
#   scripts/scope_checks.sh --files    the changed paths, one per line, on stdin
#   scripts/scope_checks.sh --staged   the staged paths
#   scripts/scope_checks.sh --tier check|commit [...]   the quick checks of `make check` and the pre-commit hook instead
#   scripts/scope_checks.sh --list [...]   the changed paths of any of the above, one per line (none when there is no base)
# The split between code and not code is CI's `changes` job (.github/workflows/build.yml), kept in step by
# scripts/scope_checks.test.sh: a change outside docs, release notes and the websites, or to COMPATIBILITY.md (a test
# input), is code and needs the Swift build, so `full`. Only a diff of lilo-ui/ alone is scoped further, as AGENTS.md says.
# Anything unexpected, an empty diff or a range git cannot read included, is `full`, as in CI. Under GITHUB_ACTIONS a
# range git cannot read is an error instead: CI never widens or skips on a missing base.
# The quick tiers never build: a Swift-only diff is `swiftlint-changed`, with no UI, site or docs work, and a diff the
# tiers have no quick check for (the Makefile, scripts, the websites) is `none`, left to validate-scope. Their `full`
# (no merge base, locally) runs every quick check on the whole tree; an empty diff is `none`.
set -eu

list=
if [ "${1:-}" = --list ]; then list=1; shift; fi
tier=validate
if [ "${1:-}" = --tier ]; then
    tier=${2:?scope_checks.sh: --tier needs check or commit}
    shift 2
fi

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
if [ -z "$files" ]; then
    [ "$tier" = validate ] && echo full || echo none
    exit 0
fi

if [ "$tier" != validate ]; then
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
    exit 0
fi

ui=; site=; docs=
while IFS= read -r file; do
    case $file in
        # The docs site's reference generator reads these (docs-site/README.md, build watch paths).
        lilo-ui/src/components/settings/settingsPanelModel.ts | lilo-ui/src/lib/i18n/locales/en.json | lilo-ui/src/lib/i18n/locales/fr.json) ui=1; docs=1 ;;
        lilo-ui/*) ui=1 ;;
        site/*) site=1 ;;
        docs-site/*) docs=1 ;;
        COMPATIBILITY.md) echo full; exit 0 ;;
        .changes/* | docs/* | *.md) ;;
        *) echo full; exit 0 ;;
    esac
done << EOL
$files
EOL

checks=${ui:+ui-lint ui-test }${site:+site-check site-test }${docs:+docs-check docs-test }
echo "${checks}release-status"
