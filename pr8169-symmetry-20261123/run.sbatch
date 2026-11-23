#!/bin/bash
#SBATCH --job-name=libri24-e2e-run
#SBATCH --account=proj-sai-hpc-software
#SBATCH --partition=16V100
#SBATCH --qos=flood-1o2gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=1
#SBATCH --time=00:30:00
#SBATCH --output=run-%j.log
#SBATCH --export=ALL
set -euo pipefail
task_root=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/libri-symmetry-origin-20261121/pr8169-maintenance-20261123
previous=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120
cd "$task_root"
source "$previous/build-env.sh"
source /opt/sai/runtime/mps_mapping.d/16V100.bash
set +u
module load libxc/7.0.0-auto
module list > "logs/runtime-modules-$SLURM_JOB_ID.txt" 2>&1
set -u
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
export LD_LIBRARY_PATH="$previous/install/ddla/lib:${LD_LIBRARY_PATH:-}"
export ABACUS_MPIEXEC_PREFLAGS='--map-by ppr:1:node:pe=1 --bind-to core'
test -f logs/build-finished
python3 verify-build.py > logs/build-dependency-audit.log
python3 verify-sources.py > "logs/runtime-source-verification-$SLURM_JOB_ID.json"
nvidia-smi > "logs/runtime-gpu-$SLURM_JOB_ID.txt"
for variant in cpu gpu; do
  gpu=OFF
  if [[ "$variant" == gpu ]]; then gpu=ON; fi
  cmake -S abacus/tests/lcao_hse_gpu/cmake -B "build/consumer-$variant" \
    -DCMAKE_BUILD_TYPE=Debug -DENABLE_LIBRI_GPU="$gpu" \
    -DLIBRI_DIR="$task_root/libri" -DDDLA_ROOT="$previous/install/ddla" \
    -DLIBCOMM_DIR="$previous/imported-deps/LibComm-master" \
    -Dcereal_DIR="$previous/imported-deps/cereal/lib/cmake/cereal" \
    -DBLAS_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so" \
    -DLAPACK_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so" \
    > "logs/consumer-$variant-configure.log" 2>&1
  cmake --build "build/consumer-$variant" --parallel 2 > "logs/consumer-$variant-build.log" 2>&1
  ctest --test-dir "build/consumer-$variant" -V > "logs/consumer-$variant-test.log" 2>&1
done
set +e
python3 check-cli.py > logs/cli-driver.log 2>&1
cli_result=$?
printf '%s\n' "$cli_result" > logs/cli-driver.exit
python3 run-e2e.py > logs/e2e-driver.log 2>&1
result=$?
set -e
printf '%s\n' "$result" > logs/e2e-driver.exit
sha256sum build/abacus/abacus_std_gpu > logs/abacus-after-runs.sha256
touch logs/runtime-finished
if [[ "$result" == 0 && "$cli_result" == 0 ]]; then exit 0; else exit 1; fi
