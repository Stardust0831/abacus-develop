#!/bin/bash
#SBATCH --job-name=pr8169-cli-singleton
#SBATCH --account=proj-sai-hpc-software
#SBATCH --partition=16V100
#SBATCH --qos=flood-1o2gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=1
#SBATCH --time=00:05:00
#SBATCH --output=run-cli-%j.log
#SBATCH --export=ALL
set -euo pipefail
task_root=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/libri-symmetry-origin-20261121/pr8169-maintenance-20261123
previous=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120
cd "$task_root"
source "$previous/build-env.sh"
source /opt/sai/runtime/mps_mapping.d/16V100.bash
set +u
module load libxc/7.0.0-auto
set -u
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
export LD_LIBRARY_PATH="$previous/install/ddla/lib:${LD_LIBRARY_PATH:-}"
test -f logs/runtime-finished
python3 verify-sources.py > "logs/cli-source-verification-$SLURM_JOB_ID.json"
set +e
python3 check-cli-singleton.py > logs/cli-singleton.log 2>&1
result=$?
set -e
printf '%s\n' "$result" > logs/cli-singleton.exit
sha256sum build/abacus/abacus_std_gpu > logs/abacus-after-cli-singleton.sha256
exit "$result"
