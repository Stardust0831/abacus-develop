#!/usr/bin/env bash
#SBATCH --job-name=abacus-cusolvermp-ci
#SBATCH --partition=16V100
#SBATCH --qos=huge-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=16
#SBATCH --gpus-per-node=16
#SBATCH --time=01:00:00

set -euo pipefail

: "${CI_SOURCE:?}"
: "${INSTALL_ROOT:?}"
: "${TOOLCHAIN_FILE:?}"
: "${MP_PROFILE:?}"

source "$TOOLCHAIN_FILE"
declare -F sai_load_toolchain >/dev/null || {
    echo "Missing sai_load_toolchain() in $TOOLCHAIN_FILE" >&2
    exit 1
}
sai_load_toolchain

source /opt/sai_config/mps_mapping.d/16V100.bash
export NCCL_IB_DISABLE=1
export OMP_NUM_THREADS=1
export OMPI_MCA_rmaps_base_mapping_policy="$MAP_OPT"
export LD_LIBRARY_PATH="$SAI_MPI_ROOT/lib:$SAI_CUDA_ROOT/lib64:$SAI_CUSOLVERMP_ROOT/lib:$SAI_CUBLASMP_ROOT/lib:$SAI_NVHPC_ROOT/math_libs/12.9/lib64:$SAI_NCCL_ROOT/lib:${LD_LIBRARY_PATH:-}"

ABACUS="$INSTALL_ROOT/bin/abacus"
[[ -x "$ABACUS" ]]
"$ABACUS" --info
ldd "$ABACUS"

suite_status=0
cd "$CI_SOURCE/tests/15_rtTDDFT_GPU"
if ! timeout --signal=TERM --kill-after=30s 15m \
    bash ../integrate/Autotest.sh -a "$ABACUS" -n 16 -o 1 \
        -f CASES_CUSOLVERMP_16GPU.txt -r '^19_NO_O3_CUSOLVERMP_16GPU$'; then
    suite_status=1
    echo "[ERROR] 16-GPU cuSolverMp RT-TDDFT case failed"
fi

if [[ "$suite_status" -eq 0 ]]; then
    echo "SAI_GPU_VALIDATION_PASSED profile=$MP_PROFILE"
else
    echo "SAI_GPU_VALIDATION_FAILED profile=$MP_PROFILE"
fi
exit "$suite_status"
