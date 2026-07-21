#!/usr/bin/env bash
#SBATCH --job-name=cusolvermp-sygvd
#SBATCH --partition=16V100
#SBATCH --qos=huge-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=16
#SBATCH --gpus-per-node=16
#SBATCH --time=00:20:00

set -euo pipefail

: "${CUSOLVERMP_SAMPLE_BIN:?}"
: "${TOOLCHAIN_FILE:?}"

source "$TOOLCHAIN_FILE"
declare -F sai_load_toolchain >/dev/null || {
    echo "Missing sai_load_toolchain() in $TOOLCHAIN_FILE" >&2
    exit 1
}
sai_load_toolchain

source "/opt/sai_config/mps_mapping.d/${SLURM_JOB_PARTITION}.bash"
export LD_LIBRARY_PATH="$SAI_MPI_ROOT/lib:$SAI_CUDA_ROOT/lib64:$SAI_CUSOLVERMP_ROOT/lib:$SAI_CUBLASMP_ROOT/lib:$SAI_NVHPC_ROOT/math_libs/12.9/lib64:$SAI_NCCL_ROOT/lib:${LD_LIBRARY_PATH:-}"

echo "SAI runtime mapping: partition=$SLURM_JOB_PARTITION tasks=$SLURM_NTASKS map_by=$MAP_OPT omp_threads=$OMP_NUM_THREADS"
env | grep -E '^(UCX|OMPI_MCA|PRTE_MCA|NCCL)_' | sort || true
if [[ -d /sys/class/infiniband ]]; then
    find /sys/class/infiniband -mindepth 1 -maxdepth 1 -printf 'RDMA_DEVICE=%f\n' | sort
fi

ldd "$CUSOLVERMP_SAMPLE_BIN" | grep -E 'nccl|cusolverMp|cublasmp'
timeout --signal=TERM --kill-after=30s 10m \
    mpirun -np "$SLURM_NTASKS" --map-by "$MAP_OPT" \
        "$CUSOLVERMP_SAMPLE_BIN" \
        -grid_layout R -p 4 -q 4 -m 39 -mbA 10 -nbA 10

echo "CUSOLVERMP_OFFICIAL_SAMPLE_PASSED"
