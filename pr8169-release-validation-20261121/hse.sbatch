#!/bin/bash
#SBATCH --job-name=pr8169-release-hse
#SBATCH --account=proj-sai-hpc-software
#SBATCH --partition=16V100
#SBATCH --qos=flood-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --gpus-per-node=4
#SBATCH --time=00:30:00
#SBATCH --output=hse-%j.log
#SBATCH --export=ALL
set -euo pipefail
task_root=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-pr8169-ready-20261121
previous=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120
source "$previous/build-env.sh"
source /opt/sai/runtime/mps_mapping.d/16V100.bash
set +u
module load libxc/7.0.0-auto
set -u
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
export LD_LIBRARY_PATH="$previous/install/ddla/lib:${LD_LIBRARY_PATH:-}"
export ABACUS_MPIEXEC_PREFLAGS='--map-by slot:PE=1 --bind-to core'
cd "$task_root"
test -x build/abacus-gpu/abacus_std_gpu
build/abacus-gpu/abacus_std_gpu --version > logs/abacus-version.txt
build/abacus-gpu/abacus_std_gpu -h device_exx > logs/device-exx-help.txt
touch logs/build-passed
python3 check-input.py
python3 run-hse.py
