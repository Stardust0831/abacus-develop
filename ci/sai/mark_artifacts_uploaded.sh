#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 RUN_ROOT" >&2
    exit 2
fi
canonical_home=$(cd "$HOME" && pwd -P)
run_root=$(realpath -e "$1")
[[ $run_root == "$canonical_home/"*'/runs/'* ]]
uploaded_tmp=$(mktemp "$run_root/.artifacts-uploaded.XXXXXX")
trap 'rm -f "$uploaded_tmp"' EXIT
{
    printf 'uploaded_epoch=%s\n' "$(date +%s)"
    printf 'uploaded_iso=%s\n' "$(date --iso-8601=seconds)"
} > "$uploaded_tmp"
mv -T "$uploaded_tmp" "$run_root/.artifacts-uploaded"
trap - EXIT
