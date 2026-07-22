#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 REPOSITORY CONTROL_SHA OUTPUT_DIRECTORY" >&2
    exit 2
fi

repository=$(realpath -e "$1")
control_sha=$2
output_dir=$(realpath --canonicalize-missing "$3")
[[ -d $repository/.git || -f $repository/.git ]]
[[ $control_sha =~ ^[0-9a-f]{40}$ ]]
[[ ! -e $output_dir && ! -L $output_dir ]]
git -C "$repository" cat-file -e "$control_sha^{commit}"

mkdir -p "$output_dir"
git -C "$repository" archive --format=tar "$control_sha" -- ci/sai \
    | tar -xf - -C "$output_dir"
control_root=$(realpath -e "$output_dir/ci/sai")
[[ $control_root == "$output_dir/ci/sai" ]]
[[ -f $control_root/run_remote_ci.sh && ! -L $control_root/run_remote_ci.sh ]]
printf 'CONTROL_ROOT=%s\n' "$control_root"
