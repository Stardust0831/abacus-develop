#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 PROJECT_ROOT RUN_KEY" >&2
    exit 2
fi

requested_root=$1
run_key=$2
[[ $run_key =~ ^[0-9]+-[0-9]+$ ]]
[[ $requested_root =~ ^(/[A-Za-z0-9._-]+)+$ ]]
case "/$requested_root/" in
    */./*|*/../*)
        echo "Project root contains a dot path component: $requested_root" >&2
        exit 1
        ;;
esac

canonical_home=$(cd "$HOME" && pwd -P)
project_root=$(realpath --canonicalize-missing "$requested_root")
[[ $project_root == "$canonical_home/"* ]]
mkdir -p "$project_root"
project_root=$(cd "$project_root" && pwd -P)
[[ $project_root == "$canonical_home/"* ]]

config_root=$(realpath --canonicalize-missing "$HOME/.config/abacus-sai-ci")
[[ $config_root == "$canonical_home/"* ]]
mkdir -p "$config_root"
config_root=$(cd "$config_root" && pwd -P)
[[ $config_root == "$canonical_home/"* ]]
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

diagnostics_root=$(realpath --canonicalize-missing "$project_root/diagnostics")
[[ $diagnostics_root == "$project_root/diagnostics" ]]
mkdir -p "$diagnostics_root"
diagnostics_root=$(cd "$diagnostics_root" && pwd -P)
[[ $diagnostics_root == "$project_root/diagnostics" ]]

staging_root="$diagnostics_root/cleanup-$run_key"
[[ ! -e $staging_root && ! -L $staging_root ]]
umask 077
mkdir -p "$staging_root"
: > "$staging_root/.ci-diagnostic"
staging_file="$staging_root/cleanup_sai_runs.sh"
: > "$staging_file"

printf 'SAI_PROJECT_ROOT=%s\n' "$project_root"
printf 'CLEANUP_STAGING_FILE=%s\n' "$staging_file"
