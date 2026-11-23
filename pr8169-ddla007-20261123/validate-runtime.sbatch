#!/bin/bash
#SBATCH --job-name=pr8169-ddla007-run
#SBATCH --account=proj-sai-hpc-software
#SBATCH --partition=16V100
#SBATCH --qos=flood-1o2gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=1
#SBATCH --time=00:30:00
#SBATCH --output=runtime-%j.log
#SBATCH --export=ALL
set -euo pipefail
task_root=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/libri-symmetry-origin-20261121/pr8169-ddla007-20261123
previous=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120
cd "$task_root"
test "$(cat logs/gpu-build.exit)" = 0
test "$(cat logs/gpu-tests.exit)" = 0
test "$(cat logs/debug-tests.exit)" = 0
test ! -e runs
test ! -e cli-checks
source "$previous/build-env.sh"
source /opt/sai/runtime/mps_mapping.d/16V100.bash
set +u
module load libxc/7.0.0-auto
module list > logs/runtime-modules.txt 2>&1
set -u
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
export LD_LIBRARY_PATH="$task_root/install/ddla/lib:${LD_LIBRARY_PATH:-}"
export ABACUS_MPIEXEC_PREFLAGS='--map-by ppr:1:node:pe=1 --bind-to core'
run_step() {
  local label=$1
  shift
  local result=0
  "$@" > "logs/$label.log" 2>&1 || result=$?
  printf '%s\n' "$result" > "logs/$label.exit"
  printf '%s: %s\n' "$label" "$result"
  return "$result"
}
run_step build-audit-final python3 verify-build-final.py
run_step version build/abacus/abacus_std_gpu --version
run_step binary-ldd ldd build/abacus/abacus_std_gpu
run_step e2e python3 run-e2e.py
run_step cli python3 check-cli.py
sha256sum build/abacus/abacus_std_gpu install/ddla/lib/libddla.so > logs/final-binaries.sha256
touch logs/runtime-finished
