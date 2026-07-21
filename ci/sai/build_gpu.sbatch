#!/usr/bin/env bash
#SBATCH --job-name=abacus-sai-build
#SBATCH --partition=16V100
#SBATCH --qos=huge-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --gpus-per-node=4
#SBATCH --time=01:00:00

set -euo pipefail

: "${CI_SOURCE:?}"
: "${CONTROL_ROOT:?}"
bash "$CONTROL_ROOT/build_gpu.sh"
