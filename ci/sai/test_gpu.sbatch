#!/usr/bin/env bash
#SBATCH --job-name=abacus-cusolvermp-multinode-ci
#SBATCH --partition=16V100
#SBATCH --qos=flood-gpu
#SBATCH --nodes=2
#SBATCH --ntasks=16
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8
#SBATCH --time=00:40:00

set -euo pipefail

: "${CI_SOURCE:?}"
: "${CONTROL_ROOT:?}"
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
case ${SAI_DISABLE_NCCL_IB-false} in
    true)
        export NCCL_IB_DISABLE=1
        ;;
    false)
        unset NCCL_IB_DISABLE
        ;;
    *)
        echo "Invalid SAI_DISABLE_NCCL_IB=${SAI_DISABLE_NCCL_IB}" >&2
        exit 2
        ;;
esac
SAI_SYSTEM_MPIRUN=$(command -v mpirun)
export SAI_SYSTEM_MPIRUN MAP_OPT
launcher_dir="$RESULT_ROOT/launcher"
mkdir -p "$launcher_dir"
ln -sfn "$CONTROL_ROOT/mpirun_with_mapping.sh" "$launcher_dir/mpirun"
export PATH="$launcher_dir:$PATH"
export LD_LIBRARY_PATH="$SAI_MPI_ROOT/lib:$SAI_CUDA_ROOT/lib64:$SAI_CUSOLVERMP_ROOT/lib:$SAI_CUBLASMP_ROOT/lib:$SAI_NCCL_ROOT/lib:$SAI_NVHPC_ROOT/math_libs/12.9/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "SAI runtime mapping: partition=$SLURM_JOB_PARTITION tasks=$SLURM_NTASKS map_by=$MAP_OPT omp_threads=$OMP_NUM_THREADS"
scontrol show hostnames "$SLURM_JOB_NODELIST" | sed 's/^/SLURM_NODE=/'
env | grep -E '^(UCX|OMPI_MCA|PRTE_MCA|NCCL)_' | sort || true
if [[ -d /sys/class/infiniband ]]; then
    find /sys/class/infiniband -mindepth 1 -maxdepth 1 -printf 'RDMA_DEVICE=%f\n' | sort
fi

ABACUS="$INSTALL_ROOT/bin/abacus"
[[ -x "$ABACUS" ]]
ABACUS_LDD=$(ldd "$ABACUS")
printf '%s\n' "$ABACUS_LDD"
if grep -q 'not found' <<< "$ABACUS_LDD"; then
    echo "ABACUS has unresolved runtime dependencies" >&2
    exit 1
fi

if [[ ${SAI_REQUIRE_NCCL_SAI_RAIL_BY_CHANNEL:-0} == 1 ]]; then
    [[ ${NCCL_SAI_RAIL_BY_CHANNEL:-} == 1 ]] || {
        echo "NCCL_SAI_RAIL_BY_CHANNEL=1 is required for this profile" >&2
        exit 1
    }
    [[ -z ${LD_PRELOAD:-} ]] || {
        printf 'LD_PRELOAD must be empty at runtime: %q\n' "$LD_PRELOAD" >&2
        exit 1
    }
    NCCL_LOADED_PATH=$(awk '$1 == "libnccl.so.2" {print $3; exit}' <<< "$ABACUS_LDD")
    [[ -n $NCCL_LOADED_PATH ]]
    NCCL_EXPECTED_PATH=$(readlink -f "$SAI_NCCL_ROOT/lib/libnccl.so.2")
    NCCL_LOADED_PATH=$(readlink -f "$NCCL_LOADED_PATH")
    [[ $NCCL_LOADED_PATH == "$NCCL_EXPECTED_PATH" ]] || {
        echo "Unexpected NCCL runtime: $NCCL_LOADED_PATH (expected $NCCL_EXPECTED_PATH)" >&2
        exit 1
    }
    echo "SAI_NCCL_RUNTIME_VERIFIED=$NCCL_LOADED_PATH rail_by_channel=$NCCL_SAI_RAIL_BY_CHANNEL"
fi

"$ABACUS" --info

bash "$CONTROL_ROOT/prepare_cusolvermp_smoke.sh"
case_name=19_NO_Si48_CUSOLVERMP_TDDFT_GPU
case_dir="$RESULT_ROOT/cusolvermp-smoke/15_rtTDDFT_GPU/$case_name"
run_log="$RESULT_ROOT/cusolvermp-si48-run.log"
cd "$case_dir"
set +e
timeout --signal=TERM --kill-after=30s 35m \
    mpirun -np "$SLURM_NTASKS" "$ABACUS" 2>&1 | tee "$run_log"
suite_status=${PIPESTATUS[0]}
set -e
if [[ $suite_status -ne 0 ]]; then
    echo "[ERROR] 2-node 16-GPU Si48 cuSolverMp RT-TDDFT case failed (rc=$suite_status)"
fi

if [[ "$suite_status" -eq 0 ]]; then
    echo "SAI_GPU_VALIDATION_PASSED profile=$MP_PROFILE"
else
    echo "SAI_GPU_VALIDATION_FAILED profile=$MP_PROFILE"
fi
exit "$suite_status"
