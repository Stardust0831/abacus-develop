#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "Usage: $0 REPOSITORY {--source-ref REF|--working-tree [--include-untracked]}" >&2
    exit 2
}

[[ $# -ge 2 ]] || usage
repository=$(realpath -e "$1")
shift
[[ $(git -C "$repository" rev-parse --is-inside-work-tree) == true ]]
repository=$(git -C "$repository" rev-parse --show-toplevel)
repository=$(cd "$repository" && pwd -P)

mode=
source_ref=
include_untracked=false
case ${1:-} in
    --source-ref)
        [[ $# -eq 2 ]] || usage
        mode=commit
        source_ref=$2
        ;;
    --working-tree)
        mode=working-tree
        shift
        if [[ $# -eq 1 && $1 == --include-untracked ]]; then
            include_untracked=true
        elif [[ $# -ne 0 ]]; then
            usage
        fi
        ;;
    *) usage ;;
esac

base_commit=$(git -C "$repository" rev-parse --verify "HEAD^{commit}")
base_tree=$(git -C "$repository" rev-parse --verify "$base_commit^{tree}")
[[ $base_commit =~ ^[0-9a-f]{40}$ && $base_tree =~ ^[0-9a-f]{40}$ ]]

if [[ $mode == commit ]]; then
    source_id=$(git -C "$repository" rev-parse --verify "$source_ref^{commit}")
    source_tree=$(git -C "$repository" rev-parse --verify "$source_id^{tree}")
    [[ $source_id =~ ^[0-9a-f]{40}$ && $source_tree =~ ^[0-9a-f]{40}$ ]]
    dirty=false
else
    real_index=$(git -C "$repository" rev-parse --git-path index)
    if [[ $real_index != /* ]]; then
        real_index=$repository/$real_index
    fi
    real_index=$(realpath -e "$real_index")
    temporary_index=$(mktemp "$(dirname "$real_index")/.abacus-ci-index.XXXXXX")
    cleanup() {
        rm -f "$temporary_index"
    }
    trap cleanup EXIT

    cp -- "$real_index" "$temporary_index"
    while IFS= read -r -d '' record; do
        tag=${record%% *}
        path=${record#* }
        if [[ $tag =~ ^[a-z]$ ]]; then
            GIT_INDEX_FILE=$temporary_index git -C "$repository" \
                update-index --no-assume-unchanged -- "$path"
        fi
    done < <(GIT_INDEX_FILE=$temporary_index \
        git -C "$repository" ls-files -v -z)
    if [[ $include_untracked == true ]]; then
        GIT_INDEX_FILE=$temporary_index git -C "$repository" add -A -- .
    else
        while IFS= read -r -d '' path; do
            printf 'LOCAL_SOURCE_UNTRACKED_EXCLUDED=%q\n' "$path" >&2
        done < <(git -C "$repository" ls-files --others --exclude-standard -z)
        GIT_INDEX_FILE=$temporary_index git -C "$repository" add -u -- .
    fi
    while IFS= read -r -d '' path; do
        printf 'LOCAL_SOURCE_IGNORED_ADDITION_EXCLUDED=%q\n' "$path" >&2
        GIT_INDEX_FILE=$temporary_index git -C "$repository" \
            update-index --force-remove -- "$path"
    done < <(
        GIT_INDEX_FILE=$temporary_index git -C "$repository" diff \
            --cached --diff-filter=A --no-renames --name-only -z \
            "$base_commit" -- \
            | git -C "$repository" check-ignore --no-index -z --stdin
    )
    source_tree=$(GIT_INDEX_FILE=$temporary_index \
        git -C "$repository" write-tree)
    [[ $source_tree =~ ^[0-9a-f]{40}$ ]]
    source_id=$source_tree
    if [[ $source_tree == "$base_tree" ]]; then
        dirty=false
    else
        dirty=true
    fi
    trap - EXIT
    cleanup
fi

printf 'SOURCE_MODE=%s\n' "$mode"
printf 'SOURCE_ID=%s\n' "$source_id"
printf 'SOURCE_BASE_COMMIT=%s\n' "$base_commit"
printf 'SOURCE_TREE_SHA=%s\n' "$source_tree"
printf 'SOURCE_DIRTY=%s\n' "$dirty"
printf 'SOURCE_INCLUDE_UNTRACKED=%s\n' "$include_untracked"
