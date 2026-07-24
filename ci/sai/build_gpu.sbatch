#!/bin/bash
#SBATCH --job-name=abacus-sai-build
#SBATCH --partition=16V100
#SBATCH --nodes=1
#SBATCH --ntasks=4          # Nodes * GPUs-per-node * Ranks-per-GPU
#SBATCH --gpus-per-node=4   # Specify the GPUs-per-node
#SBATCH --qos=huge-gpu      # Depending on your needs [Priority: rush-* > improper-* = huge-* > flood-* = ultimate-*]
#SBATCH --time=01:00:00

set -euo pipefail

: "${CI_SOURCE:?}"
: "${CONTROL_ROOT:?}"
bash "$CONTROL_ROOT/build_gpu.sh"
