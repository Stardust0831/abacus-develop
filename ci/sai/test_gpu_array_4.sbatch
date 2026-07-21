#!/usr/bin/env bash
#SBATCH --job-name=abacus-gpu4-cases
#SBATCH --partition=16V100
#SBATCH --qos=flood-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --gpus-per-node=4
#SBATCH --time=00:15:00

export GPU_CASE_CLASS=gpu4
export GPU_CASE_RANKS=4
exec bash "${GPU_CASE_BODY:?}"
