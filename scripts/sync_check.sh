#!/bin/sh
# The pre-commit hook's generated-file checks, on the staged paths only (the other generators need the network or a build):
# the tab bridge outputs must be what `make bridge-gen` writes, and a Swift file added, deleted or renamed, or a change to
# project.yml, must come with Lilo.xcodeproj in the same commit. CI's xcodegen diff stays the full check.
set -eu

status=0
staged=$(git diff --cached --name-status --no-renames)

if printf '%s\n' "$staged" | grep -qE '	(bridge-schema/|scripts/generate_bridge_protocol\.mjs|.*tabProtocol\.gen\.ts|.*TabBridgeSchema\.gen\.swift)'; then
    wrote=$(node scripts/generate_bridge_protocol.mjs)
    if [ -n "$wrote" ]; then
        printf '%s\n' "$wrote" >&2
        echo "sync-check: the bridge outputs were stale and are rewritten above: stage them (see make bridge-gen)" >&2
        status=1
    fi
fi

if printf '%s\n' "$staged" | grep -qE '^[AD]	.*\.swift$|	project\.yml$' && ! printf '%s\n' "$staged" | grep -q '	Lilo\.xcodeproj/'; then
    echo "sync-check: a Swift file was added or deleted, or project.yml changed, without Lilo.xcodeproj: run make project-sync and stage it" >&2
    status=1
fi
exit $status
