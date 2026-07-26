#!/usr/bin/env bash

# Resource flags are supplied by the Python coordinator.  This bridge only
# establishes the module environment before handing the array task to Python.
set -euo pipefail

if [[ $# -ne 10 ]]; then
    echo "Usage: $0 HOME SOURCE CONTROL INSTALL RESULTS TOOLCHAIN MAPPING_ROOT DISABLE_IB PROFILE MANIFEST" >&2
    exit 2
fi
export HOME=$1
export USER=${SLURM_JOB_USER:?}
export LOGNAME=$USER
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export CI_SOURCE=$2
export CONTROL_ROOT=$3
export INSTALL_ROOT=$4
export RESULT_ROOT=$5
export TOOLCHAIN_FILE=$6
export MPS_MAPPING_ROOT=$7
export SAI_DISABLE_NCCL_IB=$8
export SAI_EXPECTED_PROFILE=$9
export GPU_CASE_MANIFEST=${10}

: "${SLURM_ARRAY_TASK_ID:?}"
: "${SLURM_ARRAY_JOB_ID:?}"
: "${SLURM_JOB_ID:?}"
[[ $SLURM_ARRAY_TASK_ID =~ ^[0-9]+$ ]]

# Lmod and the partition-specific mapping are intentionally loaded in a shell;
# worker.py receives the resulting environment and owns all case semantics.
# shellcheck source=/dev/null
source "$TOOLCHAIN_FILE"
declare -F sai_load_toolchain >/dev/null || {
    echo "Missing sai_load_toolchain() in $TOOLCHAIN_FILE" >&2
    exit 2
}
sai_load_toolchain
[[ ${SAI_PROFILE_NAME:-} == "$SAI_EXPECTED_PROFILE" ]]
# shellcheck source=/dev/null
source "$MPS_MAPPING_ROOT/${SLURM_JOB_PARTITION}.bash"
case "$SAI_DISABLE_NCCL_IB" in
    true) export NCCL_IB_DISABLE=1 ;;
    false) unset NCCL_IB_DISABLE ;;
    *) echo "Invalid SAI_DISABLE_NCCL_IB=$SAI_DISABLE_NCCL_IB" >&2; exit 2 ;;
esac

exec python3 "$CONTROL_ROOT/sai.py" worker case \
    "$CI_SOURCE" "$CONTROL_ROOT" "$INSTALL_ROOT" "$RESULT_ROOT" \
    "$TOOLCHAIN_FILE" "$MPS_MAPPING_ROOT" "$SAI_DISABLE_NCCL_IB" \
    "$SAI_EXPECTED_PROFILE" "$GPU_CASE_MANIFEST"
