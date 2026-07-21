#!/usr/bin/env bash
#SBATCH --job-name=abacus-gpu-single
#SBATCH --partition=16V100
#SBATCH --qos=flood-1o2gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=1
#SBATCH --time=00:10:00

set -euo pipefail

: "${CI_SOURCE:?}"
: "${INSTALL_ROOT:?}"
: "${RESULT_ROOT:?}"
: "${TOOLCHAIN_FILE:?}"

source "$TOOLCHAIN_FILE"
sai_load_toolchain
source "/opt/sai_config/mps_mapping.d/${SLURM_JOB_PARTITION}.bash"

SAI_SYSTEM_MPIRUN=$(command -v mpirun)
export SAI_SYSTEM_MPIRUN MAP_OPT
launcher_dir="$RESULT_ROOT/single-launcher"
mkdir -p "$launcher_dir" "$RESULT_ROOT/single"
ln -sfn "$CI_SOURCE/ci/sai/mpirun_with_mapping.sh" "$launcher_dir/mpirun"
export PATH="$launcher_dir:$PATH"
export LD_LIBRARY_PATH="$SAI_MPI_ROOT/lib:$SAI_CUDA_ROOT/lib64:$SAI_CUSOLVERMP_ROOT/lib:$SAI_CUBLASMP_ROOT/lib:$SAI_NVHPC_ROOT/math_libs/12.9/lib64:$SAI_NCCL_ROOT/lib:${LD_LIBRARY_PATH:-}"

ABACUS="$INSTALL_ROOT/bin/abacus"
status=0

echo "SLURM_JOB_ID=$SLURM_JOB_ID"
echo "SLURM_JOB_NODELIST=$SLURM_JOB_NODELIST"
echo "MAP_OPT=$MAP_OPT"
echo "OMP_NUM_THREADS=$OMP_NUM_THREADS"
echo "NCCL_SAI_RAIL_BY_CHANNEL=${NCCL_SAI_RAIL_BY_CHANNEL:-}"
nvidia-smi --query-gpu=index,name,uuid,temperature.gpu,power.draw,power.limit,utilization.gpu,memory.used,memory.total --format=csv

set +e
(cd "$CI_SOURCE/tests/07_OFDFT" &&
 timeout --signal=TERM --kill-after=30s 7m \
     bash ../integrate/Autotest.sh -a "$ABACUS" -n 1 \
         -o "$OMP_NUM_THREADS" -f CASES_GPU.txt -r '^31_OF_KE_WT_GPU$') \
    2>&1 | tee "$RESULT_ROOT/single/ofdft-wt-gpu-1rank.out"
ofdft_rc=${PIPESTATUS[0]}
set -e
echo "SINGLE_RESULT label=ofdft-wt-gpu-1rank rc=$ofdft_rc"
[[ $ofdft_rc -eq 0 ]] || status=1

set +e
(cd "$CI_SOURCE/tests/07_OFDFT" &&
 timeout --signal=TERM --kill-after=30s 7m \
     bash ../integrate/Autotest.sh -a "$ABACUS" -n 1 \
         -o "$OMP_NUM_THREADS" -f CASES_CPU.txt -r '^09_OF_KE_WT$') \
    2>&1 | tee "$RESULT_ROOT/single/ofdft-wt-cpu-1rank.out"
ofdft_cpu_rc=${PIPESTATUS[0]}
set -e
echo "SINGLE_RESULT label=ofdft-wt-cpu-1rank rc=$ofdft_cpu_rc"
[[ $ofdft_cpu_rc -eq 0 ]] || status=1

smoke_dir="$CI_SOURCE/tests/11_PW_GPU/BUG_nspin4_u"
rm -rf "$smoke_dir/OUT.autotest"
rm -f "$smoke_dir/log.txt" "$smoke_dir/result.out"
set +e
(cd "$smoke_dir" &&
 timeout --signal=TERM --kill-after=30s 7m \
     mpirun -np 1 "$ABACUS") \
    2>&1 | tee "$RESULT_ROOT/single/bug-nspin4-u-1rank.out"
smoke_rc=${PIPESTATUS[0]}
set -e
if [[ $smoke_rc -eq 0 && -d "$smoke_dir/OUT.autotest" ]]; then
    (cd "$smoke_dir" &&
     bash ../../integrate/tools/catch_properties.sh \
         "$RESULT_ROOT/single/bug-nspin4-u-1rank.result.out")
else
    status=1
fi
echo "SINGLE_RESULT label=bug-nspin4-u-1rank rc=$smoke_rc"

exit "$status"
