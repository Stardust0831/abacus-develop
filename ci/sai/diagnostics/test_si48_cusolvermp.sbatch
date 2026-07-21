#!/usr/bin/env bash
#SBATCH --job-name=abacus-si48-cusolvermp
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

source "$TOOLCHAIN_FILE"
declare -F sai_load_toolchain >/dev/null || {
    echo "Missing sai_load_toolchain() in $TOOLCHAIN_FILE" >&2
    exit 1
}
sai_load_toolchain
source "/opt/sai_config/mps_mapping.d/${SLURM_JOB_PARTITION}.bash"
unset NCCL_IB_DISABLE
SAI_SYSTEM_MPIRUN=$(command -v mpirun)
export SAI_SYSTEM_MPIRUN MAP_OPT

launcher_dir="$RESULT_ROOT/si48-launcher"
work_root="$RESULT_ROOT/si48-work"
case_name=19_NO_Si48_CUSOLVERMP_TDDFT_GPU
mkdir -p "$launcher_dir" "$work_root/tests/15_rtTDDFT_GPU"
ln -sfn "$CONTROL_ROOT/mpirun_with_mapping.sh" "$launcher_dir/mpirun"
ln -sfn "$CI_SOURCE/tests/PP_ORB" "$work_root/tests/PP_ORB"
cp -a "$CI_SOURCE/tests/15_rtTDDFT_GPU/$case_name" \
    "$work_root/tests/15_rtTDDFT_GPU/"
export PATH="$launcher_dir:$PATH"
export LD_LIBRARY_PATH="$SAI_MPI_ROOT/lib:$SAI_CUDA_ROOT/lib64:$SAI_CUSOLVERMP_ROOT/lib:$SAI_CUBLASMP_ROOT/lib:$SAI_NCCL_ROOT/lib:$SAI_NVHPC_ROOT/math_libs/12.9/lib64:${LD_LIBRARY_PATH:-}"

ABACUS="$INSTALL_ROOT/bin/abacus"
[[ -x $ABACUS ]]
ldd "$ABACUS" | tee "$RESULT_ROOT/si48-ldd.txt"
! grep -q 'not found' "$RESULT_ROOT/si48-ldd.txt"
grep -F "$SAI_CUSOLVERMP_ROOT" "$RESULT_ROOT/si48-ldd.txt"
grep -F "$SAI_CUBLASMP_ROOT" "$RESULT_ROOT/si48-ldd.txt"
grep -F "$SAI_NCCL_ROOT" "$RESULT_ROOT/si48-ldd.txt"
loaded_nccl=$(awk '$1 == "libnccl.so.2" {print $3; exit}' "$RESULT_ROOT/si48-ldd.txt")
[[ $(readlink -f "$loaded_nccl") == $(readlink -f "$SAI_NCCL_ROOT/lib/libnccl.so.2") ]]

echo "SI48_RESOURCE nodes=$SLURM_NNODES tasks=$SLURM_NTASKS tasks_per_node=8 gpus_per_node=8 map=$MAP_OPT"
scontrol show hostnames "$SLURM_JOB_NODELIST" | sed 's/^/SI48_NODE=/'
env | grep -E '^(UCX|OMPI_MCA|PRTE_MCA|NCCL)_' | sort || true
nvidia-smi --query-gpu=index,name,uuid,compute_mode,pstate,power.draw,power.limit,utilization.gpu,memory.used,memory.total --format=csv

cd "$work_root/tests/15_rtTDDFT_GPU/$case_name"
set +e
timeout --signal=TERM --kill-after=30s 35m \
    mpirun -np "$SLURM_NTASKS" "$ABACUS" 2>&1 | tee "$RESULT_ROOT/si48-run.log"
run_rc=${PIPESTATUS[0]}
set -e
nvidia-smi --query-gpu=index,pstate,power.draw,power.limit,utilization.gpu,memory.used,memory.total --format=csv
echo "SI48_CUSOLVERMP_RESULT rc=$run_rc"
exit "$run_rc"
