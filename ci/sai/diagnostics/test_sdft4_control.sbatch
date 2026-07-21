#!/usr/bin/env bash
#SBATCH --job-name=abacus-sdft4-control
#SBATCH --partition=16V100
#SBATCH --qos=huge-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --gpus-per-node=4
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
launcher_dir="$RESULT_ROOT/sdft4-launcher"
mkdir -p "$launcher_dir" "$RESULT_ROOT/sdft4"
ln -sfn "$CI_SOURCE/ci/sai/mpirun_with_mapping.sh" "$launcher_dir/mpirun"
export PATH="$launcher_dir:$PATH"
export LD_LIBRARY_PATH="$SAI_MPI_ROOT/lib:$SAI_CUDA_ROOT/lib64:$SAI_CUSOLVERMP_ROOT/lib:$SAI_CUBLASMP_ROOT/lib:$SAI_NVHPC_ROOT/math_libs/12.9/lib64:$SAI_NCCL_ROOT/lib:${LD_LIBRARY_PATH:-}"

echo "SLURM_JOB_ID=$SLURM_JOB_ID"
echo "SLURM_JOB_NODELIST=$SLURM_JOB_NODELIST"
echo "MAP_OPT=$MAP_OPT"
echo "OMP_NUM_THREADS=$OMP_NUM_THREADS"
echo "NCCL_SAI_RAIL_BY_CHANNEL=${NCCL_SAI_RAIL_BY_CHANNEL:-}"

cd "$CI_SOURCE/tests/16_SDFT_GPU"
timeout --signal=TERM --kill-after=30s 7m \
    bash ../integrate/Autotest.sh -a "$INSTALL_ROOT/bin/abacus" -n 4 \
        -o "$OMP_NUM_THREADS" -f CASES_GPU.txt \
        -r '^005_PW_SDFT_MALL_BPCG_GPU$'
