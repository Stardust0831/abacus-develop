#!/bin/bash
#SBATCH --job-name=pr8169-release-check
#SBATCH --account=proj-sai-hpc-software
#SBATCH --partition=16V100
#SBATCH --qos=flood-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --gpus-per-node=8
#SBATCH --time=02:00:00
#SBATCH --output=validate-%j.log
#SBATCH --export=ALL
set -euo pipefail
task_root=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-pr8169-ready-20261121
previous=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120
cd "$task_root"
source "$previous/build-env.sh"
source /opt/sai/runtime/mps_mapping.d/16V100.bash
set +u
module load libxc/7.0.0-auto
set -u
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
export LD_LIBRARY_PATH="$previous/install/ddla/lib:${LD_LIBRARY_PATH:-}"
libri="$task_root/deps/LibRI-0.3.0.0"
libcomm="$previous/imported-deps/LibComm-master"
cereal="$previous/imported-deps/cereal"
ddla="$previous/install/ddla"
nvidia-smi > logs/gpus.txt
gcc --version > logs/compiler.txt
sha256sum "$ddla/lib/libddla.so" > logs/ddla-sha256.txt
common=(-DLIBCOMM_DIR="$libcomm" -Dcereal_DIR="$cereal/lib/cmake/cereal"
        -DBLAS_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so"
        -DLAPACK_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so")
if [[ ${1:-all} == all ]]; then
for variant in cpu gpu old-cpu; do
  ri_path="$libri"
  gpu=OFF
  if [[ "$variant" == gpu ]]; then gpu=ON; fi
  if [[ "$variant" == old-cpu ]]; then ri_path="$previous/src/LibRI"; fi
  cmake -S abacus/tests/lcao_hse_gpu/cmake -B "build/consumer-$variant" \
    -DCMAKE_BUILD_TYPE=Release -DLIBRI_DIR="$ri_path" "${common[@]}" \
    -DENABLE_LIBRI_GPU="$gpu" -DENABLE_LIBRI_GPU_TESTS="$gpu" -DDDLA_ROOT="$ddla" \
    > "logs/consumer-$variant-configure.log" 2>&1
  cmake --build "build/consumer-$variant" --parallel 4 > "logs/consumer-$variant-build.log" 2>&1
  ctest --test-dir "build/consumer-$variant" --output-on-failure > "logs/consumer-$variant-test.log" 2>&1
done
if cmake -S abacus/tests/lcao_hse_gpu/cmake -B build/old-gpu-reject \
    -DLIBRI_DIR="$previous/src/LibRI" "${common[@]}" \
    -DENABLE_LIBRI_GPU=ON -DDDLA_ROOT="$ddla" > logs/old-gpu-reject.log 2>&1; then
  printf 'ERROR: old LibRI unexpectedly accepted for GPU\n'
  exit 1
fi
grep -q 'LibRI v0.3.0.0' logs/old-gpu-reject.log
cmake -S "$libri/unittests/gpu_symmetry" -B build/libri-symmetry \
  -DENABLE_GPU=ON -DCMAKE_BUILD_TYPE=Debug -DDDLA_ROOT="$ddla" \
  -DLIBCOMM_ROOT="$libcomm" -DCEREAL_ROOT="$cereal" \
  -DBLAS_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so" \
  -DLAPACK_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so" > logs/symmetry-configure.log 2>&1
cmake --build build/libri-symmetry --parallel 4 > logs/symmetry-build.log 2>&1
mpirun -np 1 --map-by ppr:1:node:pe=1 --bind-to core \
  build/libri-symmetry/test_lri_gpu_symmetry > logs/symmetry-test.log 2>&1
touch logs/dependencies-passed
fi
for variant in gpu cpu; do
  gpu=OFF
  if [[ "$variant" == gpu ]]; then gpu=ON; fi
  cmake -S abacus -B "build/abacus-$variant" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON -DGIT_SUBMODULE=OFF \
    -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST="$task_root/deps/googletest-a46a6012a133c7c0929fdae55b321c2fe65f3c5f" \
    -DENABLE_MPI=ON -DENABLE_OPENMP=ON -DENABLE_LCAO=ON -DENABLE_LIBRI=ON \
    -DENABLE_LIBXC=ON -DENABLE_ELPA=OFF -DENABLE_MLALGO=OFF -DENABLE_JSON=OFF \
    -DUSE_CUDA="$gpu" -DENABLE_LIBRI_GPU="$gpu" -DCMAKE_CUDA_ARCHITECTURES=70 \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_CUDA_HOST_COMPILER="$CXX" \
    -DLIBRI_DIR="$libri" -DDDLA_ROOT="$ddla" "${common[@]}" \
    -DLibxc_DIR="$LIBXC_ROOT/lib/cmake/Libxc" \
    > "logs/abacus-$variant-configure.log" 2>&1
  cmake --build "build/abacus-$variant" --target MODULE_IO_read_item_serial --parallel 24 \
    > "logs/abacus-$variant-input-build.log" 2>&1
  ctest --test-dir "build/abacus-$variant" -V -R '^MODULE_IO_read_item_serial$' \
    > "logs/abacus-$variant-input-test.log" 2>&1
done
touch logs/input-passed
cmake --build build/abacus-gpu --target abacus_std_gpu --parallel 28 > logs/abacus-gpu-build.log 2>&1
build/abacus-gpu/abacus_std_gpu --version > logs/abacus-version.txt
build/abacus-gpu/abacus_std_gpu -h device_exx > logs/device-exx-help.txt
ldd build/abacus-gpu/abacus_std_gpu > logs/abacus-ldd.txt
touch logs/build-passed
