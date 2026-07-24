#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 EXPECTED_USER" >&2
    exit 2
fi
expected_user=$1
[[ $expected_user =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'Invalid expected user: %q\n' "$expected_user" >&2
    exit 1
}
remote_user=$(id -un)
[[ $remote_user == "$expected_user" ]] || {
    printf 'Unexpected remote user: expected=%q actual=%q\n' \
        "$expected_user" "$remote_user" >&2
    exit 1
}
canonical_home=$(cd "$HOME" && pwd -P)
expected_canonical_home=/org/abacus-group/$expected_user
if [[ $canonical_home != "$HOME" \
    && $canonical_home != "$expected_canonical_home" ]]; then
    printf 'Unexpected canonical HOME: logical=%q canonical=%q allowed=%q\n' \
        "$HOME" "$canonical_home" "$expected_canonical_home" >&2
    exit 1
fi
for command_name in sbatch sacct squeue scancel rsync git gzip tar \
    realpath flock crontab; do
    command -v "$command_name" >/dev/null
done
sinfo -h -p 16V100 -o '%P %a %D %G' | grep -q '^16V100 '
echo "SAI_SSH_PROBE_OK user=$remote_user home=$canonical_home host=$(hostname)"
sinfo -h -p 16V100 -o 'SAI_PARTITION=%P state=%a nodes=%D gres=%G'
