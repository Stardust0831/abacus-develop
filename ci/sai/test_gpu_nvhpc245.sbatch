#!/usr/bin/env bash
#SBATCH --job-name=abacus-nvhpc245-rt
#SBATCH --partition=16V100
#SBATCH --qos=huge-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=16
#SBATCH --gpus-per-node=16
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
source "/opt/sai_config/mps_mapping.d/${SLURM_JOB_PARTITION}.bash"

SAI_SYSTEM_MPIRUN=$(command -v mpirun)
export SAI_SYSTEM_MPIRUN MAP_OPT
launcher_dir="$RESULT_ROOT/launcher"
mkdir -p "$launcher_dir"
ln -sfn "$CI_SOURCE/ci/sai/mpirun_with_mapping.sh" "$launcher_dir/mpirun"
export PATH="$launcher_dir:$PATH"
export LD_LIBRARY_PATH="$SAI_RUNTIME_LIBRARY_PATH:${LD_LIBRARY_PATH:-}"

echo "SAI runtime mapping: partition=$SLURM_JOB_PARTITION tasks=$SLURM_NTASKS map_by=$MAP_OPT omp_threads=$OMP_NUM_THREADS"
echo "SAI legacy backend: cuSolverMp=0.5.0 communicator=CAL cuBLASMp-direct=OFF"
echo "SAI NCCL module root: $SAI_NCCL_ROOT"
env | grep -E '^(UCX|OMPI_MCA|PRTE_MCA|NCCL)_' | sort || true
if [[ -d /sys/class/infiniband ]]; then
    find /sys/class/infiniband -mindepth 1 -maxdepth 1 -printf 'RDMA_DEVICE=%f\n' | sort
fi

ABACUS="$INSTALL_ROOT/bin/abacus"
[[ -x "$ABACUS" ]]
"$ABACUS" --info
ldd "$ABACUS" | tee "$RESULT_ROOT/legacy-rt-ldd.txt"
readelf -d "$SAI_CUSOLVERMP_ROOT/lib/libcusolverMp.so.0" \
    | grep NEEDED | tee "$RESULT_ROOT/cusolvermp-needed.txt"

suite_status=0
cd "$CI_SOURCE/tests/15_rtTDDFT_GPU"
if ! timeout --signal=TERM --kill-after=30s 15m \
    bash ../integrate/Autotest.sh -a "$ABACUS" -n 16 \
        -o "$OMP_NUM_THREADS" \
        -f CASES_CUSOLVERMP_16GPU.txt -r '^19_NO_O3_CUSOLVERMP_16GPU$'; then
    suite_status=1
    echo "[ERROR] NVHPC 24.5 16-GPU cuSolverMp RT-TDDFT case failed"
fi

if [[ "$suite_status" -eq 0 ]]; then
    echo "SAI_GPU_VALIDATION_PASSED profile=$MP_PROFILE"
else
    echo "SAI_GPU_VALIDATION_FAILED profile=$MP_PROFILE"
fi
exit "$suite_status"
