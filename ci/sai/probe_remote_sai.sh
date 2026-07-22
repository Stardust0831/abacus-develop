#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 EXPECTED_USER" >&2
    exit 2
fi
expected_user=$1
[[ $expected_user =~ ^[A-Za-z0-9._-]+$ ]]
remote_user=$(id -un)
[[ $remote_user == "$expected_user" ]]
canonical_home=$(cd "$HOME" && pwd -P)
[[ $canonical_home == "$HOME" ]]
for command_name in sbatch sacct squeue scancel rsync curl git gzip tar xz \
    realpath flock crontab; do
    command -v "$command_name" >/dev/null
done
sinfo -h -p 16V100 -o '%P %a %D %G' | grep -q '^16V100 '
echo "SAI_SSH_PROBE_OK user=$remote_user home=$canonical_home host=$(hostname)"
sinfo -h -p 16V100 -o 'SAI_PARTITION=%P state=%a nodes=%D gres=%G'
