#!/bin/bash
#SBATCH --job-name=pr8169-minimal-debug
#SBATCH --account=proj-sai-hpc-software
#SBATCH --partition=16V100
#SBATCH --qos=flood-gpu
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --cpus-per-task=8
#SBATCH --gpus-per-node=4
#SBATCH --time=01:00:00
#SBATCH --output=validate-%j.log
#SBATCH --export=ALL
set -euo pipefail
task_root=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-build-20261121
released=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-pr8169-ready-20261121
previous=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120
cd "$task_root"
source "$previous/build-env.sh"
source /opt/sai/runtime/mps_mapping.d/16V100.bash
set +u
module load libxc/7.0.0-auto
set -u
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
export LD_LIBRARY_PATH="$previous/install/ddla/lib:${LD_LIBRARY_PATH:-}"
libri="$released/deps/LibRI-0.3.0.0"
libcomm="$previous/imported-deps/LibComm-master"
cereal="$previous/imported-deps/cereal"
ddla="$previous/install/ddla"
mkdir -p logs build
exec 3> logs/commands.txt
printf 'step\texit_code\tutc_start\tutc_end\n' > logs/status.tsv
run_step() {
  local step=$1
  shift
  local started
  started=$(date -u +%FT%TZ)
  printf '%q ' "$@" >&3
  printf '\n' >&3
  local status=0
  "$@" > "logs/$step.log" 2>&1 || status=$?
  printf '%s\t%s\t%s\t%s\n' "$step" "$status" "$started" "$(date -u +%FT%TZ)" >> logs/status.tsv
  return "$status"
}
capture_target() {
  local builddir=$1
  local prefix=$2
  local targetdir="$builddir/source/source_lcao/module_ri/unittests/CMakeFiles/MODULE_RI_exx_workspace.dir"
  cp "$targetdir/link.txt" "logs/$prefix-link.txt"
  cp "$targetdir/flags.make" "logs/$prefix-flags.make"
  cp "$builddir/CMakeCache.txt" "logs/$prefix-CMakeCache.txt"
  python3 - "$builddir/compile_commands.json" > "logs/$prefix-compile_commands.json" <<'PY'
import json,sys
commands=json.load(open(sys.argv[1]))
print(json.dumps([x for x in commands if 'MODULE_RI_exx_workspace.dir/' in x['command']],indent=2))
PY
}
run_step allocation bash -c 'date -u; hostname; scontrol show job "$SLURM_JOB_ID"; nvidia-smi; gcc --version; cmake --version; module list; env | sort | grep -E "^(OMP_|OPENBLAS_|MKL_|CUDA_VISIBLE_DEVICES|SLURM_JOB_ID|SLURM_CPUS_ON_NODE|SLURM_NTASKS|SLURM_CPUS_PER_TASK)="'
run_step dependency-hashes bash -c 'sha256sum "$1/lib/libddla.so" "$2/include/RI/version.h" "$2/include/RI/ri/LRI.h"; find "$1/lib/cmake/LibDDLA" -type f -exec sha256sum {} +; find "$2/include" -type f -print0 | sort -z | xargs -0 sha256sum' bash "$ddla" "$libri"
common=(-DLIBCOMM_DIR="$libcomm" -Dcereal_DIR="$cereal/lib/cmake/cereal"
        -DBLAS_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so"
        -DLAPACK_LIBRARIES="$OPENBLAS_ROOT/lib/libopenblas.so")
main=(-DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTING=ON -DGIT_SUBMODULE=OFF
      -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST="$released/deps/googletest-a46a6012a133c7c0929fdae55b321c2fe65f3c5f"
      -DENABLE_MPI=ON -DENABLE_OPENMP=ON -DENABLE_LCAO=ON -DENABLE_LIBRI=ON
      -DENABLE_LIBXC=ON -DENABLE_ELPA=OFF -DENABLE_MLALGO=OFF -DENABLE_JSON=OFF
      -DCMAKE_CUDA_ARCHITECTURES=70 -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_CUDA_HOST_COMPILER="$CXX"
      -DLIBRI_DIR="$libri" -DDDLA_ROOT="$ddla" -DLibxc_DIR="$LIBXC_ROOT/lib/cmake/Libxc")
run_step gpu-before-configure cmake -S abacus -B build/abacus-gpu-debug "${main[@]}" "${common[@]}" -DUSE_CUDA=ON -DENABLE_LIBRI_GPU=ON
capture_target build/abacus-gpu-debug gpu-before
# The original target is expected to fail here; preserve its unmodified error.
run_step gpu-before-build cmake --build build/abacus-gpu-debug --target MODULE_RI_exx_workspace --parallel 24 --verbose || true
cp overlay/source/source_lcao/module_ri/unittests/CMakeLists.txt abacus/source/source_lcao/module_ri/unittests/CMakeLists.txt
sha256sum abacus/source/source_lcao/module_ri/unittests/CMakeLists.txt > logs/fixed-target-source.sha256
run_step gpu-after-configure cmake -S abacus -B build/abacus-gpu-debug "${main[@]}" "${common[@]}" -DUSE_CUDA=ON -DENABLE_LIBRI_GPU=ON
capture_target build/abacus-gpu-debug gpu-after
validation_failed=0
if run_step gpu-after-build cmake --build build/abacus-gpu-debug --target MODULE_RI_exx_workspace --parallel 24 --verbose; then
  run_step gpu-after-test ctest --test-dir build/abacus-gpu-debug -V -R '^MODULE_RI_exx_workspace$' || validation_failed=1
  run_step gpu-after-ldd ldd build/abacus-gpu-debug/source/source_lcao/module_ri/unittests/MODULE_RI_exx_workspace || validation_failed=1
else
  validation_failed=1
fi
if run_step cpu-configure cmake -S abacus -B build/abacus-cpu-debug "${main[@]}" "${common[@]}" -DUSE_CUDA=OFF -DENABLE_LIBRI_GPU=OFF; then
  capture_target build/abacus-cpu-debug cpu
  if run_step cpu-build cmake --build build/abacus-cpu-debug --target MODULE_RI_exx_workspace --parallel 24 --verbose; then
    run_step cpu-test ctest --test-dir build/abacus-cpu-debug -V -R '^MODULE_RI_exx_workspace$' || validation_failed=1
    run_step cpu-ldd ldd build/abacus-cpu-debug/source/source_lcao/module_ri/unittests/MODULE_RI_exx_workspace || validation_failed=1
  else
    validation_failed=1
  fi
else
  validation_failed=1
fi
for variant in cpu gpu; do
  gpu=OFF
  if [[ "$variant" == gpu ]]; then gpu=ON; fi
  if run_step "consumer-$variant-configure" cmake -S abacus/tests/lcao_hse_gpu/cmake -B "build/consumer-$variant" \
      -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DLIBRI_DIR="$libri" "${common[@]}" \
      -DENABLE_LIBRI_GPU="$gpu" -DDDLA_ROOT="$ddla"; then
    cp "build/consumer-$variant/CMakeFiles/libri_consumer.dir/link.txt" "logs/consumer-$variant-link.txt"
    cp "build/consumer-$variant/CMakeFiles/libri_consumer.dir/flags.make" "logs/consumer-$variant-flags.make"
    if run_step "consumer-$variant-build" cmake --build "build/consumer-$variant" --parallel 4 --verbose; then
      run_step "consumer-$variant-test" ctest --test-dir "build/consumer-$variant" -V || validation_failed=1
    else
      validation_failed=1
    fi
  else
    validation_failed=1
  fi
done
printf '%s\n' "$validation_failed" > logs/validation-exit.txt
exit "$validation_failed"
