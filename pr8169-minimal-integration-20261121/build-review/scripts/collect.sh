#!/bin/bash
set -euo pipefail
cd /org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-build-20261121
sacct -j 2672287 --format=JobID,JobName,Partition,State,ExitCode,Elapsed,AllocCPUS,AllocTRES%65,NodeList -P > logs/sacct-2672287.txt
sha256sum provenance/abacus-head.tar.gz scripts/validate-debug.sbatch > logs/run-inputs.sha256
sha256sum abacus/source/source_lcao/module_ri/unittests/CMakeLists.txt \
  abacus/source/source_lcao/module_ri/unittests/test_exx_workspace.cpp \
  abacus/source/source_lcao/module_ri/exx_workspace.cpp \
  abacus/source/source_lcao/module_ri/lri_cv.cpp \
  abacus/tests/lcao_hse_gpu/cmake/CMakeLists.txt \
  abacus/tests/lcao_hse_gpu/cmake/test_libri_consumer.cpp \
  abacus/docs/advanced/install.md abacus/cmake/modules/FindLibRI.cmake \
  abacus/source/CMakeLists.txt abacus/cmake/Testing.cmake > logs/compiled-source.sha256
sha256sum build/abacus-gpu-debug/source/source_lcao/module_ri/unittests/MODULE_RI_exx_workspace \
  build/abacus-cpu-debug/source/source_lcao/module_ri/unittests/MODULE_RI_exx_workspace \
  build/consumer-cpu/libri_consumer build/consumer-gpu/libri_consumer > logs/binaries.sha256
for variant in cpu gpu; do
  cp "build/consumer-$variant/compile_commands.json" "logs/consumer-$variant-compile_commands.json"
  cp "build/consumer-$variant/CMakeCache.txt" "logs/consumer-$variant-CMakeCache.txt"
  cp "build/consumer-$variant/CTestTestfile.cmake" "logs/consumer-$variant-CTestTestfile.cmake"
done
if test -e abacus/tests/lcao_hse_gpu/cmake/test_libri_gpu_accumulation.cpp; then
  echo 'Unexpected deleted test still exists' >&2
  exit 1
fi
