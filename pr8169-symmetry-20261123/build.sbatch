#!/bin/bash
#SBATCH --job-name=pr8169-symmetry-build
#SBATCH --account=proj-sai-hpc-software
#SBATCH --partition=16V100
#SBATCH --qos=flood-1o2gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=1
#SBATCH --time=00:30:00
#SBATCH --output=build-%j.log
#SBATCH --export=ALL
set -euo pipefail
task_root=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/libri-symmetry-origin-20261121/pr8169-maintenance-20261123
previous=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120
ready=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-pr8169-ready-20261121
cd "$task_root"
source "$previous/build-env.sh"
source /opt/sai/runtime/mps_mapping.d/16V100.bash
set +u
module load libxc/7.0.0-auto
module list > logs/modules.txt 2>&1
set -u
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
export LD_LIBRARY_PATH="$previous/install/ddla/lib:${LD_LIBRARY_PATH:-}"
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
run_step compiler g++ --version
run_step ddla-sha256 sha256sum "$previous/install/ddla/lib/libddla.so"
common=(-DLIBCOMM_DIR="$previous/imported-deps/LibComm-master"
        -Dcereal_DIR="$previous/imported-deps/cereal/lib/cmake/cereal"
        -DBLAS_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so"
        -DLAPACK_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so")
run_step libri-configure cmake -S libri/unittests/physics/gpu_symmetry -B build/libri \
  -DENABLE_GPU=ON -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS_DEBUG='-O0 -g0' \
  -DCMAKE_CXX_COMPILER="$CXX" -DDDLA_ROOT="$previous/install/ddla" \
  -DLIBCOMM_ROOT="$previous/imported-deps/LibComm-master" \
  -DCEREAL_ROOT="$previous/imported-deps/cereal" \
  -DBLAS_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so" \
  -DLAPACK_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so"
run_step libri-build cmake --build build/libri --parallel 2
run_step libri-numerical mpirun -np 1 --map-by ppr:1:node:pe=1 --bind-to core \
  build/libri/test_lri_gpu_symmetry -1 all all
run_step libri-callback build/libri/test_gpu_symmetry_filters
main=(-DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON -DGIT_SUBMODULE=OFF
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
      -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST="$ready/deps/googletest-a46a6012a133c7c0929fdae55b321c2fe65f3c5f"
      -DENABLE_MPI=ON -DENABLE_OPENMP=ON -DENABLE_LCAO=ON -DENABLE_LIBRI=ON
      -DENABLE_LIBXC=ON -DENABLE_ELPA=OFF -DENABLE_MLALGO=OFF -DENABLE_JSON=OFF
      -DCMAKE_CUDA_ARCHITECTURES=70 -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
      -DCMAKE_CUDA_HOST_COMPILER="$CXX" -DLIBRI_DIR="$task_root/libri"
      -DDDLA_ROOT="$previous/install/ddla" -DLibxc_DIR="$LIBXC_ROOT/lib/cmake/Libxc")
run_step gpu-configure cmake -S abacus -B build/abacus "${main[@]}" "${common[@]}" \
  -DUSE_CUDA=ON -DENABLE_LIBRI_GPU=ON
run_step gpu-build timeout 1300 cmake --build build/abacus --parallel 4 \
  --target abacus_std_gpu MODULE_IO_read_input_serial MODULE_IO_read_item_serial MODULE_RI_exx_workspace
mkdir -p logs/gpu-xml logs/gpu-tmp
export GTEST_OUTPUT="xml:$task_root/logs/gpu-xml/" TEST_TMPDIR="$task_root/logs/gpu-tmp/"
run_step gpu-tests ctest --test-dir build/abacus -V --timeout 120 \
  -R '^(MODULE_IO_read_(input|item)_serial|MODULE_RI_exx_workspace)$'
run_step cpu-configure cmake -S abacus -B build/cpu "${main[@]}" "${common[@]}" \
  -DUSE_CUDA=OFF -DENABLE_LIBRI_GPU=OFF
run_step cpu-build timeout 300 cmake --build build/cpu --parallel 4 \
  --target MODULE_IO_read_input_serial MODULE_IO_read_item_serial MODULE_RI_exx_workspace
mkdir -p logs/cpu-xml logs/cpu-tmp
export GTEST_OUTPUT="xml:$task_root/logs/cpu-xml/" TEST_TMPDIR="$task_root/logs/cpu-tmp/"
run_step cpu-tests ctest --test-dir build/cpu -V --timeout 120 \
  -R '^(MODULE_IO_read_(input|item)_serial|MODULE_RI_exx_workspace)$'
run_step version build/abacus/abacus_std_gpu --version
run_step help-device-exx build/abacus/abacus_std_gpu -h device_exx
run_step help-realspace build/abacus/abacus_std_gpu -h exx_symmetry_realspace
run_step binary-ldd ldd build/abacus/abacus_std_gpu
sha256sum build/abacus/abacus_std_gpu > logs/abacus.sha256
touch logs/build-finished
