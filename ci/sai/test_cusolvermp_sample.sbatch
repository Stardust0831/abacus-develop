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

source /opt/sai_config/mps_mapping.d/16V100.bash
export NCCL_IB_DISABLE=1
export OMP_NUM_THREADS=1
export OMPI_MCA_rmaps_base_mapping_policy="$MAP_OPT"
export LD_LIBRARY_PATH="$SAI_MPI_ROOT/lib:$SAI_CUDA_ROOT/lib64:$SAI_CUSOLVERMP_ROOT/lib:$SAI_CUBLASMP_ROOT/lib:$SAI_NVHPC_ROOT/math_libs/12.9/lib64:$SAI_NCCL_ROOT/lib:${LD_LIBRARY_PATH:-}"

ldd "$CUSOLVERMP_SAMPLE_BIN" | grep -E 'nccl|cusolverMp|cublasmp'
timeout --signal=TERM --kill-after=30s 10m \
    mpirun -np 16 "$CUSOLVERMP_SAMPLE_BIN" \
        -grid_layout R -p 4 -q 4 -m 39 -mbA 10 -nbA 10

echo "CUSOLVERMP_OFFICIAL_SAMPLE_PASSED"
