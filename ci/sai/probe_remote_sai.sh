#!/usr/bin/env bash

set -euo pipefail

[[ $USER == abacususer01 ]]
[[ $HOME == /home/abacus-group/abacususer01 ]]
[[ $(id -u) -eq 1478400356 ]]
for command_name in sbatch sacct squeue scancel rsync curl git gzip tar xz \
    realpath flock crontab; do
    command -v "$command_name" >/dev/null
done
sinfo -h -p 16V100 -o '%P %a %D %G' | grep -q '^16V100 '
echo "SAI_SSH_PROBE_OK user=$USER home=$HOME host=$(hostname)"
sinfo -h -p 16V100 -o 'SAI_PARTITION=%P state=%a nodes=%D gres=%G'
