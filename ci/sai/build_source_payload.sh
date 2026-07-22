#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "Usage: $0 REPOSITORY SOURCE_SHA BASE_SHA|none PAYLOAD MANIFEST" >&2
    exit 2
fi

repository=$(realpath -e "$1")
source_sha=$2
base_sha=$3
payload=$4
manifest=$5

[[ -d $repository/.git || -f $repository/.git ]]
[[ $source_sha =~ ^[0-9a-f]{40}$ ]]
[[ $base_sha == none || $base_sha =~ ^[0-9a-f]{40}$ ]]
[[ $payload != "$manifest" ]]
git -C "$repository" cat-file -e "$source_sha^{commit}"

mkdir -p "$(dirname "$payload")" "$(dirname "$manifest")"
git -C "$repository" ls-tree -r -z --full-tree "$source_sha" \
    | gzip -1 > "$manifest"

mode="full"
if [[ $base_sha != none ]]; then
    if git -C "$repository" cat-file -e "$base_sha^{commit}" 2>/dev/null || \
        git -C "$repository" fetch --no-tags --depth=1 origin "$base_sha"; then
        git -C "$repository" diff --binary --full-index --no-renames \
            "$base_sha" "$source_sha" | gzip -1 > "$payload"
        mode="delta"
    else
        echo "Cached SHA is unavailable; sending a full snapshot" >&2
    fi
fi
if [[ $mode == full ]]; then
    empty_tree=$(git -C "$repository" hash-object -t tree /dev/null)
    git -C "$repository" diff --binary --full-index --no-renames \
        "$empty_tree" "$source_sha" | gzip -1 > "$payload"
fi

[[ -s $payload && -s $manifest ]]
gzip -t -- "$payload"
gzip -t -- "$manifest"
printf 'SOURCE_PAYLOAD_MODE=%s\n' "$mode"
printf 'SOURCE_PAYLOAD_BYTES=%s\n' "$(stat -c %s "$payload")"
