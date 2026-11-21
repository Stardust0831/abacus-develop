#!/bin/bash
#SBATCH --job-name=libri-pr24
#SBATCH --account=proj-sai-hpc-software
#SBATCH --partition=16V100
#SBATCH --qos=flood-1o2gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=1
#SBATCH --time=00:30:00
#SBATCH --output=pr24-%j.log
#SBATCH --export=ALL
set -euo pipefail
task_root=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/libri-pr24-validation-20261121
previous=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120
cd "$task_root"
source "$previous/build-env.sh"
source /opt/sai/runtime/mps_mapping.d/16V100.bash
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
export LD_LIBRARY_PATH="$previous/install/ddla/lib:${LD_LIBRARY_PATH:-}"
mkdir -p logs build
nvidia-smi > logs/gpus.txt
module list > logs/modules.txt 2>&1
g++ --version > logs/compiler.txt
sha256sum "$previous/install/ddla/lib/libddla.so" > logs/ddla-sha256.txt
printf 'case\targuments\texit_code\n' > logs/status.tsv
build_variant() {
    local name=$1
    local source=$2
    local libri=$3
    cmake -S "$source" -B "build/$name" -DENABLE_GPU=ON \
      -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS_DEBUG='-O0 -g0' \
      -DCMAKE_CXX_COMPILER="$CXX" -DLIBRI_ROOT="$libri" \
      -DDDLA_ROOT="$previous/install/ddla" \
      -DLIBCOMM_ROOT="$previous/imported-deps/LibComm-master" \
      -DCEREAL_ROOT="$previous/imported-deps/cereal" \
      -DBLAS_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so" \
      -DLAPACK_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so" \
      > "logs/$name-configure.log" 2>&1
    cmake --build "build/$name" --parallel 2 > "logs/$name-build.log" 2>&1
    sha256sum "build/$name/test_lri_gpu_symmetry" >> logs/binary-sha256.txt
    ldd "build/$name/test_lri_gpu_symmetry" > "logs/$name-ldd.txt"
}
run_case() {
    local name=$1
    local suffix=$2
    shift 2
    set +e
    timeout 120 mpirun -np 1 --map-by ppr:1:node:pe=1 --bind-to core \
      "build/$name/test_lri_gpu_symmetry" "$@" > "logs/$name-$suffix.log" 2>&1
    local status=$?
    set -e
    printf '%s\t%s\t%s\n' "$name-$suffix" "$*" "$status" >> logs/status.tsv
}
build_variant pr24-original "$task_root/source-pr24/unittests/gpu_symmetry" "$task_root/source-pr24"
run_case pr24-original all -1 all all
build_variant pr24-wrapper "$task_root/fixture-wrapper" "$task_root/source-pr24"
run_case pr24-wrapper cpu -1 cpu all
for scalar in real complex; do
    for label in $(seq 0 18); do
        run_case pr24-wrapper "$scalar-label-$label" "$label" gpu "$scalar"
    done
done
build_variant pr24-diagnostic "$task_root/fixture-wrapper" "$task_root/source-diagnostic"
run_case pr24-diagnostic all -1 all all
sha256sum source-*/include/RI/ri/LRI-cal_loop3_GPU.hpp > logs/gpu-loop-sha256.txt
sha256sum -c manifest.sha256 > logs/source-hash-check.txt
date -u +%FT%TZ > logs/finished.txt
