#!/usr/bin/env bash
#SBATCH --job-name=abacus-nvhpc245-build
#SBATCH --partition=16V100
#SBATCH --qos=huge-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --gpus-per-node=4
#SBATCH --time=01:00:00

set -euo pipefail

: "${CI_SOURCE:?}"
bash "$CI_SOURCE/ci/sai/build_gpu_nvhpc245.sh"
