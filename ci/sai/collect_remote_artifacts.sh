#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 RUN_ROOT" >&2
    exit 2
fi

run_root=$(realpath -e "$1")
[[ $run_root == "$HOME/"*'/runs/'* ]]
cd "$run_root"

list_file=$(mktemp "$run_root/.artifact-list.XXXXXX")
trap 'rm -f "$list_file"' EXIT
add_file() {
    local canonical
    [[ -e $1 || -L $1 ]] || return 0
    canonical=$(realpath -e "$1")
    [[ $canonical == "$run_root/"* ]]
    printf '%s\0' "$1" >> "$list_file"
}

add_file .ci-created
add_file .artifacts-uploaded
for path in \
    build/toolchain-summary.txt build/CMakeCache.txt \
    install/abacus-info.txt install/ldd.txt install/abacus.sha256; do
    add_file "$path"
done

if [[ -d results ]]; then
    find results -type f \( \
        -name '*.log' -o -name '*.out' -o -name '*.txt' -o \
        -name '*.tsv' -o -name '*.md' -o -name '*.sha256' \
    \) -print0 >> "$list_file"
fi
if [[ -d source/tests ]]; then
    find source/tests -type f \( \
        -name log.txt -o -name result.out -o -name 'running*.log' -o \
        -name warning.log \
    \) -print0 >> "$list_file"
fi

tar --no-recursion --null --files-from="$list_file" -czf -
