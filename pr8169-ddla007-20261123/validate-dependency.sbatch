#!/bin/bash
#SBATCH --job-name=pr8169-ddla007
#SBATCH --account=proj-sai-hpc-software
#SBATCH --partition=16V100
#SBATCH --qos=flood-1o2gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=1
#SBATCH --time=00:30:00
#SBATCH --output=dependency-%j.log
#SBATCH --export=ALL
set -euo pipefail
task_root=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/libri-symmetry-origin-20261121/pr8169-ddla007-20261123
previous=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120
baseline=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/libri-symmetry-origin-20261121/pr8169-maintenance-20261123
cd "$task_root"
source "$previous/build-env.sh"
source /opt/sai/runtime/mps_mapping.d/16V100.bash
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
export LD_LIBRARY_PATH="$task_root/install/ddla/lib:${LD_LIBRARY_PATH:-}"
mkdir -p logs build
run_step() {
  local label=$1
  shift
  local result=0
  "$@" > "logs/$label.log" 2>&1 || result=$?
  printf '%s\n' "$result" > "logs/$label.exit"
  printf '%s: %s\n' "$label" "$result"
  return "$result"
}
run_step source-verification python3 verify-sources.py
run_step gpu-info nvidia-smi
run_step compiler "$CXX" --version
run_step ddla-configure cmake -S ddla -B build/ddla -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$task_root/install/ddla" -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_CUDA_HOST_COMPILER="$CXX" \
  -DCMAKE_CUDA_ARCHITECTURES=70 -DDDLA_USE_CUDA=ON -DBUILD_TESTS=OFF \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DDDLA_CPU_BLAS_LIBRARY="$OPENBLAS_ROOT/lib/libopenblas.so" \
  -DDDLA_LAPACK_LIBRARY="$OPENBLAS_ROOT/lib/libopenblas.so"
run_step ddla-build timeout 1400 cmake --build build/ddla --parallel 4
run_step ddla-install cmake --install build/ddla
run_step ddla-ldd ldd install/ddla/lib/libddla.so
sha256sum install/ddla/lib/libddla.so > logs/ddla-library.sha256
run_step ddla-consumer-configure cmake -S ddla/tests/install_consumer -B build/ddla-consumer \
  -DCMAKE_BUILD_TYPE=Debug -DLibDDLA_DIR="$task_root/install/ddla/lib/cmake/LibDDLA" \
  -DMPIEXEC_PREFLAGS='--map-by;ppr:1:node:pe=1;--bind-to;core'
run_step ddla-consumer-build cmake --build build/ddla-consumer --parallel 2
run_step ddla-consumer-test ctest --test-dir build/ddla-consumer -V --timeout 120
common=(-DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_STANDARD=14 -DCMAKE_CXX_STANDARD_REQUIRED=ON
        -DCMAKE_CXX_EXTENSIONS=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
        -DLIBRI_DIR="$task_root/libri" -DDDLA_ROOT="$task_root/install/ddla"
        -DLIBCOMM_DIR="$previous/imported-deps/LibComm-master"
        -Dcereal_DIR="$previous/imported-deps/cereal/lib/cmake/cereal"
        -DBLAS_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so"
        -DLAPACK_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so")
if run_step baseline-consumer-configure cmake -S "$baseline/abacus/tests/lcao_hse_gpu/cmake" \
  -B build/baseline-consumer "${common[@]}" -DENABLE_LIBRI_GPU=ON; then
  printf '%s\n' 'Unexpected baseline success; inspect private macro check.'
  exit 1
fi
python3 - <<'PY'
from pathlib import Path
text=Path('build/baseline-consumer/CMakeFiles/CMakeConfigureLog.yaml').read_text()
assert 'LibRI GPU requires a CUDA build of DDLA' in text
PY
for variant in cpu gpu; do
  gpu=OFF
  if [[ "$variant" == gpu ]]; then gpu=ON; fi
  run_step "consumer-$variant-configure" cmake -S abacus/tests/lcao_hse_gpu/cmake \
    -B "build/consumer-$variant" "${common[@]}" -DENABLE_LIBRI_GPU="$gpu"
  run_step "consumer-$variant-build" cmake --build "build/consumer-$variant" --parallel 2
  run_step "consumer-$variant-test" ctest --test-dir "build/consumer-$variant" -V --timeout 120
done
run_step libri14-configure cmake -S cxx14-regression -B build/libri14 \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS_DEBUG='-O0 -g0' \
  -DLIBRI_ROOT="$task_root/libri" -DLIBCOMM_ROOT="$previous/imported-deps/LibComm-master" \
  -DCEREAL_ROOT="$previous/imported-deps/cereal" \
  -DLibDDLA_DIR="$task_root/install/ddla/lib/cmake/LibDDLA" \
  -DBLAS_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so" \
  -DLAPACK_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so"
run_step libri14-build cmake --build build/libri14 --parallel 2
run_step libri14-numerical mpirun -np 1 --map-by ppr:1:node:pe=1 --bind-to core \
  build/libri14/test_lri_gpu_symmetry -1 all all
touch logs/dependency-finished
