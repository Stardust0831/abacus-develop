#!/usr/bin/env bash
#SBATCH --job-name=abacus-gpu1-cases
#SBATCH --partition=16V100
#SBATCH --qos=flood-1o2gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=1
#SBATCH --time=00:15:00

export GPU_CASE_CLASS=gpu1
export GPU_CASE_RANKS=1
exec bash "${GPU_CASE_BODY:?}"
