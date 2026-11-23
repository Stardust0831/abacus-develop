#!/bin/bash
#SBATCH --job-name=pr8169-ddla007-app
#SBATCH --account=proj-sai-hpc-software
#SBATCH --partition=16V100
#SBATCH --qos=flood-1o2gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=1
#SBATCH --time=00:30:00
#SBATCH --output=application-%j.log
#SBATCH --export=ALL
set -euo pipefail
task_root=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/libri-symmetry-origin-20261121/pr8169-ddla007-20261123
previous=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120
ready=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-pr8169-ready-20261121
cd "$task_root"
test -f logs/dependency-finished
source "$previous/build-env.sh"
source /opt/sai/runtime/mps_mapping.d/16V100.bash
set +u
module load libxc/7.0.0-auto
module list > logs/application-modules.txt 2>&1
set -u
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
export LD_LIBRARY_PATH="$task_root/install/ddla/lib:${LD_LIBRARY_PATH:-}"
export ABACUS_MPIEXEC_PREFLAGS='--map-by ppr:1:node:pe=1 --bind-to core'
run_step() {
  local label=$1
  shift
  local result=0
  "$@" > "logs/$label.log" 2>&1 || result=$?
  printf '%s\n' "$result" > "logs/$label.exit"
  printf '%s: %s\n' "$label" "$result"
  return "$result"
}
run_step application-source-verification python3 verify-sources.py
common=(-DBUILD_TESTING=ON -DGIT_SUBMODULE=OFF -DCMAKE_CXX_STANDARD=14
        -DCMAKE_CXX_STANDARD_REQUIRED=ON -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
        -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST="$ready/deps/googletest-a46a6012a133c7c0929fdae55b321c2fe65f3c5f"
        -DENABLE_MPI=ON -DENABLE_OPENMP=ON -DENABLE_LCAO=ON -DENABLE_LIBRI=ON
        -DENABLE_LIBXC=ON -DENABLE_ELPA=OFF -DENABLE_MLALGO=OFF -DENABLE_JSON=OFF
        -DUSE_CUDA=ON -DENABLE_LIBRI_GPU=ON
        -DCMAKE_CUDA_ARCHITECTURES=70 -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
        -DCMAKE_CUDA_HOST_COMPILER="$CXX" -DLIBRI_DIR="$task_root/libri"
        -DDDLA_ROOT="$task_root/install/ddla" -DLibxc_DIR="$LIBXC_ROOT/lib/cmake/Libxc"
        -DLIBCOMM_DIR="$previous/imported-deps/LibComm-master"
        -Dcereal_DIR="$previous/imported-deps/cereal/lib/cmake/cereal"
        -DBLAS_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so"
        -DLAPACK_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so")
run_step gpu-configure cmake -S abacus -B build/abacus "${common[@]}" -DCMAKE_BUILD_TYPE=Release
run_step gpu-build timeout 1100 cmake --build build/abacus --parallel 4 \
  --target abacus_std_gpu MODULE_IO_read_input_serial MODULE_IO_read_item_serial MODULE_RI_exx_workspace
mkdir -p logs/gpu-xml logs/gpu-tmp
export GTEST_OUTPUT="xml:$task_root/logs/gpu-xml/" TEST_TMPDIR="$task_root/logs/gpu-tmp/"
run_step gpu-tests ctest --test-dir build/abacus -V --timeout 120 \
  -R '^(MODULE_IO_read_(input|item)_serial|MODULE_RI_exx_workspace)$'
run_step debug-configure cmake -S abacus -B build/debug "${common[@]}" -DCMAKE_BUILD_TYPE=Debug
run_step debug-build timeout 300 cmake --build build/debug --parallel 4 --target MODULE_RI_exx_workspace
mkdir -p logs/debug-xml logs/debug-tmp
export GTEST_OUTPUT="xml:$task_root/logs/debug-xml/" TEST_TMPDIR="$task_root/logs/debug-tmp/"
run_step debug-tests ctest --test-dir build/debug -V --timeout 120 -R '^MODULE_RI_exx_workspace$'
run_step build-audit python3 verify-build.py
run_step version build/abacus/abacus_std_gpu --version
run_step binary-ldd ldd build/abacus/abacus_std_gpu
run_step e2e python3 run-e2e.py
run_step cli python3 check-cli.py
sha256sum build/abacus/abacus_std_gpu install/ddla/lib/libddla.so > logs/final-binaries.sha256
touch logs/application-finished
