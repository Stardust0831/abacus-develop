#!/usr/bin/env bash
#SBATCH --job-name=abacus-gpu2-cases
#SBATCH --partition=16V100
#SBATCH --qos=flood-1o2gpu
#SBATCH --nodes=1
#SBATCH --ntasks=2
#SBATCH --gpus-per-node=2
#SBATCH --time=00:15:00

export GPU_CASE_CLASS=gpu2
export GPU_CASE_RANKS=2
exec bash "${GPU_CASE_BODY:?}"
