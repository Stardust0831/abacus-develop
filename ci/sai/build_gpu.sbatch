#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 7 ]]; then
    echo "Usage: $0 HOME SOURCE CONTROL BUILD INSTALL TOOLCHAIN PROFILE" >&2
    exit 2
fi
export HOME=$1
export USER=${SLURM_JOB_USER:?}
export LOGNAME=$USER
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export CI_SOURCE=$2
export CONTROL_ROOT=$3
export BUILD_ROOT=$4
export INSTALL_ROOT=$5
export TOOLCHAIN_FILE=$6
export MP_PROFILE=$7
bash "$CONTROL_ROOT/build_gpu.sh"
