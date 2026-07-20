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
export LD_LIBRARY_PATH="$SAI_MPI_ROOT/lib:$SAI_CUDA_ROOT/lib64:$SAI_CUSOLVERMP_ROOT/lib:$SAI_CUBLASMP_ROOT/lib:$SAI_NVHPC_ROOT/math_libs/12.9/lib64:$SAI_NCCL_ROOT/lib:$SAI_DEPS_PREFIX/lib:$SAI_DEPS_PREFIX/lib64:$SAI_DEEPMD_ROOT/lib:$SAI_TORCH_ROOT/lib:$SAI_REFERENCE_ROOT/NEP_CPU-main/lib:${LD_LIBRARY_PATH:-}"

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

run_cases() {
    local suite="$1"
    local ranks="$2"
    local cases_file="$3"
    local regex="$4"
    if [[ "$ranks" -lt 4 ]]; then
        (unset OMPI_MCA_rmaps_base_mapping_policy
         cd "$CI_SOURCE/tests/$suite"
         bash ../integrate/Autotest.sh -a "$ABACUS" -n "$ranks" -o 1 \
             -f "$cases_file" -r "$regex")
    else
        (cd "$CI_SOURCE/tests/$suite"
         bash ../integrate/Autotest.sh -a "$ABACUS" -n "$ranks" -o 1 \
             -f "$cases_file" -r "$regex")
    fi
}

run_checked() {
    if ! "$@"; then
        suite_status=1
        echo "[WARN] GPU suite command failed; continuing diagnostics"
    fi
}

if [[ "${RUN_FULL_SUITE:-false}" == true ]]; then
    cases_11="$CI_SOURCE/tests/11_PW_GPU/CASES_CI_GPU.txt"
    grep -v -E '^(scf_bpcg|scf_out_wf)$' \
        "$CI_SOURCE/tests/11_PW_GPU/CASES_GPU.txt" > "$cases_11"
    run_checked run_cases 11_PW_GPU 4 "$cases_11" '^[^#].*_.*$'
    run_checked run_cases 11_PW_GPU 2 \
        "$CI_SOURCE/tests/11_PW_GPU/CASES_GPU.txt" '^scf_bpcg$'
    run_checked run_cases 11_PW_GPU 1 \
        "$CI_SOURCE/tests/11_PW_GPU/CASES_GPU.txt" '^scf_out_wf$'
    for suite in 12_NAO_Gamma_GPU 13_NAO_multik_GPU 15_rtTDDFT_GPU; do
        run_checked run_cases "$suite" 4 CASES_GPU.txt '^[^#].*_.*$'
    done
    run_checked run_cases 16_SDFT_GPU 2 CASES_GPU.txt '^[^#].*_.*$'
fi

if [[ "$suite_status" -eq 0 ]]; then
    echo "SAI_GPU_VALIDATION_PASSED profile=$MP_PROFILE"
else
    echo "SAI_GPU_VALIDATION_FAILED profile=$MP_PROFILE"
fi
exit "$suite_status"
