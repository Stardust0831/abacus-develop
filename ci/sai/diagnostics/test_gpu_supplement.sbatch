#!/usr/bin/env bash
#SBATCH --job-name=abacus-gpu-supplement
#SBATCH --partition=16V100
#SBATCH --qos=huge-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --gpus-per-node=4
#SBATCH --time=00:15:00

set -u

: "${CI_SOURCE:?}"
: "${INSTALL_ROOT:?}"
: "${RESULT_ROOT:?}"
: "${TOOLCHAIN_FILE:?}"

source "$TOOLCHAIN_FILE"
sai_load_toolchain
source "/opt/sai_config/mps_mapping.d/${SLURM_JOB_PARTITION}.bash"

SAI_SYSTEM_MPIRUN=$(command -v mpirun)
export SAI_SYSTEM_MPIRUN MAP_OPT
launcher_dir="$RESULT_ROOT/supplement-launcher"
mkdir -p "$launcher_dir" "$RESULT_ROOT/supplement"
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
env | grep -E '^(UCX|OMPI_MCA|PRTE_MCA|NCCL)_' | sort || true
nvidia-smi --query-gpu=index,name,uuid,temperature.gpu,power.draw,power.limit,utilization.gpu,memory.used,memory.total --format=csv
ldd "$ABACUS"

run_autotest() {
    local label=$1
    local suite=$2
    local ranks=$3
    local cases_file=$4
    local regex=$5
    local log="$RESULT_ROOT/supplement/${label}.out"
    local rc

    set +e
    (cd "$CI_SOURCE/tests/$suite" &&
     timeout --signal=TERM --kill-after=30s 7m \
         bash ../integrate/Autotest.sh -a "$ABACUS" -n "$ranks" \
             -o "$OMP_NUM_THREADS" -f "$cases_file" -r "$regex") \
        2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    set -e
    echo "SUPPLEMENT_RESULT label=$label rc=$rc"
    [[ $rc -eq 0 ]] || status=1
}

set -e
run_autotest sdft-bpcg-retry-1 16_SDFT_GPU 2 CASES_GPU.txt '^005_PW_SDFT_MALL_BPCG_GPU$'
run_autotest sdft-bpcg-retry-2 16_SDFT_GPU 2 CASES_GPU.txt '^005_PW_SDFT_MALL_BPCG_GPU$'
run_autotest ofdft-wt-gpu 07_OFDFT 4 CASES_GPU.txt '^31_OF_KE_WT_GPU$'

smoke_dir="$CI_SOURCE/tests/11_PW_GPU/BUG_nspin4_u"
smoke_log="$RESULT_ROOT/supplement/bug-nspin4-u-smoke.out"
rm -rf "$smoke_dir/OUT.autotest"
rm -f "$smoke_dir/log.txt"
set +e
(cd "$smoke_dir" &&
 timeout --signal=TERM --kill-after=30s 7m \
     mpirun -np 4 "$ABACUS") 2>&1 | tee "$smoke_log"
smoke_rc=${PIPESTATUS[0]}
set -e
echo "SUPPLEMENT_RESULT label=bug-nspin4-u-smoke rc=$smoke_rc"
if [[ $smoke_rc -ne 0 || ! -d "$smoke_dir/OUT.autotest" ]]; then
    status=1
fi

exit "$status"
