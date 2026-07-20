#!/usr/bin/env bash
#SBATCH --job-name=abacus-gpu-full-ci
#SBATCH --partition=16V100
#SBATCH --qos=huge-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --gpus-per-node=4
#SBATCH --time=01:00:00

set -euo pipefail

: "${CI_SOURCE:?}"
: "${INSTALL_ROOT:?}"
: "${RESULT_ROOT:?}"
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
ldd "$ABACUS" | tee "$RESULT_ROOT/gpu-full-ldd.txt"

suite_status=0
run_cases() {
    local suite=$1
    local ranks=$2
    local cases_file=$3
    local regex=$4
    local log="$RESULT_ROOT/${suite}-${ranks}rank.out"
    if [[ $ranks -lt 4 ]]; then
        (unset OMPI_MCA_rmaps_base_mapping_policy
         cd "$CI_SOURCE/tests/$suite"
         timeout --signal=TERM --kill-after=30s 7m \
             bash ../integrate/Autotest.sh -a "$ABACUS" -n "$ranks" -o 1 \
                 -f "$cases_file" -r "$regex") 2>&1 | tee "$log"
    else
        (cd "$CI_SOURCE/tests/$suite"
         timeout --signal=TERM --kill-after=30s 7m \
             bash ../integrate/Autotest.sh -a "$ABACUS" -n "$ranks" -o 1 \
                 -f "$cases_file" -r "$regex") 2>&1 | tee "$log"
    fi
}

run_checked() {
    if ! run_cases "$@"; then
        suite_status=1
        echo "[WARN] GPU suite failed: $1 ($2 ranks)"
    fi
}

cases_11="$RESULT_ROOT/CASES_CI_GPU.txt"
grep -v -E '^(scf_bpcg|scf_out_wf)$' \
    "$CI_SOURCE/tests/11_PW_GPU/CASES_GPU.txt" > "$cases_11"
run_checked 11_PW_GPU 4 "$cases_11" '^[^#].*_.*$'
run_checked 11_PW_GPU 2 "$CI_SOURCE/tests/11_PW_GPU/CASES_GPU.txt" '^scf_bpcg$'
run_checked 11_PW_GPU 1 "$CI_SOURCE/tests/11_PW_GPU/CASES_GPU.txt" '^scf_out_wf$'
for suite in 12_NAO_Gamma_GPU 13_NAO_multik_GPU 15_rtTDDFT_GPU; do
    run_checked "$suite" 4 CASES_GPU.txt '^[^#].*_.*$'
done
run_checked 16_SDFT_GPU 2 CASES_GPU.txt '^[^#].*_.*$'

if [[ $suite_status -eq 0 ]]; then
    echo "SAI_GPU_FULL_VALIDATION_PASSED profile=$MP_PROFILE"
else
    echo "SAI_GPU_FULL_VALIDATION_FAILED profile=$MP_PROFILE"
fi
exit "$suite_status"
