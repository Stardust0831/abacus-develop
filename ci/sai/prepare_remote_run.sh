#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 PROJECT_ROOT RUN_KEY SOURCE_SHA CONTROL_SHA" >&2
    exit 2
fi

requested_root=$1
run_key=$2
source_sha=$3
control_sha=$4
[[ $run_key =~ ^[0-9]+-[0-9]+$ ]]
[[ $source_sha =~ ^[0-9a-fA-F]{40}$ ]]
[[ $control_sha =~ ^[0-9a-fA-F]{40}$ ]]
[[ $requested_root =~ ^(/[A-Za-z0-9._-]+)+$ ]]
case "/$requested_root/" in
    */./*|*/../*)
        echo "Project root contains a dot path component: $requested_root" >&2
        exit 1
        ;;
esac

canonical_home=$(cd "$HOME" && pwd -P)
project_root=$(realpath --canonicalize-missing "$requested_root")
case $project_root in
    "$canonical_home"/*) ;;
    *) echo "Project root escapes HOME: $project_root" >&2; exit 1 ;;
esac

config_root=$(realpath --canonicalize-missing "$HOME/.config/abacus-sai-ci")
[[ $config_root == "$canonical_home/"* ]]
mkdir -p "$project_root/runs" "$config_root"
project_root=$(cd "$project_root" && pwd -P)
config_root=$(cd "$config_root" && pwd -P)
[[ $project_root == "$canonical_home/"* ]]
[[ $config_root == "$canonical_home/"* ]]
run_root="$project_root/runs/$run_key"
[[ ! -e $run_root && ! -L $run_root ]] || {
    echo "Refusing to reuse remote run: $run_root" >&2
    exit 1
}
mkdir -p "$run_root/source" "$run_root/control" "$run_root/build" \
    "$run_root/install" "$run_root/results"
{
    printf 'created_epoch=%s\n' "$(date +%s)"
    printf 'created_iso=%s\n' "$(date --iso-8601=seconds)"
    printf 'source_sha=%s\n' "$source_sha"
    printf 'control_sha=%s\n' "$control_sha"
} > "$run_root/.ci-created"

registry="$config_root/project-roots"
exec 9<"$config_root"
flock 9
if [[ -L $registry || ( -e $registry && ! -f $registry ) ]]; then
    echo "Refusing unsafe project-root registry: $registry" >&2
    exit 1
fi
touch "$registry"
if ! grep -Fxq "$project_root" "$registry"; then
    printf '%s\n' "$project_root" >> "$registry"
fi

printf 'SAI_PROJECT_ROOT=%s\n' "$project_root"
printf 'RUN_ROOT=%s\n' "$run_root"
