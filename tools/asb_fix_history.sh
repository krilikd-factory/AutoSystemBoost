#!/bin/sh
# Run in a full AutoSystemBoost checkout. Inputs are full Git commit IDs.
set -eu
[ "$#" -eq 2 ] || { echo 'usage: asb_fix_history.sh FIX_SHA CAPTURE_SOURCE_SHA' >&2; exit 2; }
for sha in "$@"; do
    case "$sha" in *[!0-9a-f]*|'') echo 'unknown_source'; exit 0;; esac
    if [ "${#sha}" -ne 40 ] || ! git cat-file -e "$sha^{commit}" 2>/dev/null; then
        echo 'unknown_source'
        exit 0
    fi
done
if git merge-base --is-ancestor "$1" "$2"; then
    echo 'fix_in_history'
elif [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo 'incomplete_history'
elif [ "$(git rev-list --parents -n 1 "$1" | awk '{print NF}')" -ne 2 ]; then
    echo 'patch_comparison_unavailable'
else
    cherry=$(git cherry "$2" "$1" "$1^")
    case "$cherry" in
        "- $1") echo 'equivalent_patch_in_history';;
        "+ $1") echo 'patch_not_found';;
        *) echo 'patch_comparison_unavailable';;
    esac
fi
