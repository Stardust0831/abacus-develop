#!/bin/bash
#SBATCH --job-name=pr8169-reader-final
#SBATCH --account=proj-sai-hpc-software
#SBATCH --partition=16V100
#SBATCH --qos=flood-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --gpus-per-node=4
#SBATCH --time=01:00:00
#SBATCH --output=reader-review-%j.log
#SBATCH --export=ALL
set -euo pipefail
task_root=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-reader-20261121
ready=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-pr8169-ready-20261121
previous=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120
cd "$task_root"
source "$previous/build-env.sh"
source /opt/sai/runtime/mps_mapping.d/16V100.bash
set +u
module load libxc/7.0.0-auto
set -u
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
export LD_LIBRARY_PATH="$previous/install/ddla/lib:${LD_LIBRARY_PATH:-}"
log_root="$task_root/logs/job-$SLURM_JOB_ID"
mkdir -p "$log_root" build
exec 3> "$log_root/commands.log"
exec 4> "$log_root/returncodes.tsv"
printf 'step\treturncode\n' >&4
run_log() {
  local label=$1
  shift
  printf '%q ' "$@" >&3
  printf '> %q 2>&1\n' "$log_root/$label.log" >&3
  local rc=0
  "$@" > "$log_root/$label.log" 2>&1 || rc=$?
  printf '%s\t%s\n' "$label" "$rc" >&4
  printf '%s: returncode=%s\n' "$label" "$rc"
  return "$rc"
}
run_log allocation python3 verify-allocation.py
run_log gpus nvidia-smi
run_log compiler gcc --version
run_log cmake cmake --version
run_log cuda nvcc --version
run_log modules module list
run_log slurm scontrol show job "$SLURM_JOB_ID"
run_log ddla-sha256 sha256sum "$previous/install/ddla/lib/libddla.so"
run_log archive-sha256 sha256sum source-before.tar.gz reader-final-overlay.tar.gz validate-reader-final.sbatch
run_log source-verify python3 verify-final-source.py
common=(-DLIBCOMM_DIR="$previous/imported-deps/LibComm-master"
        -Dcereal_DIR="$previous/imported-deps/cereal/lib/cmake/cereal"
        -DBLAS_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so"
        -DLAPACK_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so")
failed=0
for variant in cpu gpu; do
  gpu=OFF
  if [[ "$variant" == gpu ]]; then gpu=ON; fi
  for phase in final; do
    build_dir="build/$phase-$variant"
    if ! run_log "$phase-$variant-configure" cmake -S "source-$phase" -B "$build_dir" \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON -DGIT_SUBMODULE=OFF \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
      -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST="$ready/deps/googletest-a46a6012a133c7c0929fdae55b321c2fe65f3c5f" \
      -DENABLE_MPI=ON -DENABLE_OPENMP=ON -DENABLE_LCAO=ON -DENABLE_LIBRI=ON \
      -DENABLE_LIBXC=ON -DENABLE_ELPA=OFF -DENABLE_MLALGO=OFF -DENABLE_JSON=OFF \
      -DUSE_CUDA="$gpu" -DENABLE_LIBRI_GPU="$gpu" -DCMAKE_CUDA_ARCHITECTURES=70 \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_CUDA_HOST_COMPILER="$CXX" \
      -DLIBRI_DIR="$ready/deps/LibRI-0.3.0.0" -DDDLA_ROOT="$previous/install/ddla" "${common[@]}" \
      -DLibxc_DIR="$LIBXC_ROOT/lib/cmake/Libxc"; then
      failed=1
      continue
    fi
    if ! run_log "$phase-$variant-build" cmake --build "$build_dir" \
      --target MODULE_IO_read_input_serial MODULE_IO_read_item_serial --parallel 32; then
      failed=1
      continue
    fi
    mkdir -p "$log_root/$phase-$variant-xml" "$log_root/$phase-$variant-tmp"
    export GTEST_OUTPUT="xml:$log_root/$phase-$variant-xml/"
    export TEST_TMPDIR="$log_root/$phase-$variant-tmp/"
    if ! run_log "$phase-$variant-test" ctest --test-dir "$build_dir" -V \
      -R '^MODULE_IO_read_(input|item)_serial$'; then failed=1; fi
    run_log "$phase-$variant-binaries" sha256sum \
      "$build_dir/source/source_io/test_serial/MODULE_IO_read_input_serial" \
      "$build_dir/source/source_io/test_serial/MODULE_IO_read_item_serial"
  done
done
if [[ "$failed" == 0 ]]; then
  mkdir -p "$log_root/final-gpu-no-visible-xml" "$log_root/final-gpu-no-visible-tmp"
  export GTEST_OUTPUT="xml:$log_root/final-gpu-no-visible-xml/"
  export TEST_TMPDIR="$log_root/final-gpu-no-visible-tmp/"
  if ! run_log final-gpu-no-visible env CUDA_VISIBLE_DEVICES= \
    "$task_root/build/final-gpu/source/source_io/test_serial/MODULE_IO_read_input_serial" \
    '--gtest_filter=InputTest.DeviceExx*'; then failed=1; fi
  if ! run_log test-counts python3 check-final-results.py "$log_root"; then failed=1; fi
fi
printf 'overall\t%s\n' "$failed" >&4
exit "$failed"
