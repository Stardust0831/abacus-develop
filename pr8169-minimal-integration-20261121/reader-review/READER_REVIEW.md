# PR 8169 reader regression review

Completed: **47/47 CPU unit tests and 49/49 GPU unit tests passed**, with zero skipped tests in the normal V100 runs. With `CUDA_VISIBLE_DEVICES` empty, the focused final GPU executable selected three new tests: the CPU test passed and exactly the two GPU-specific tests skipped. No production behavior, LibRI implementation, reference or tolerance changed.

The repository regression addresses [discussion_r4651154624](https://github.com/deepmodeling/abacus-develop/pull/8169#discussion_r4651154624): it invokes actual `ReadInput::read_parameters` and observes the effective values after reset/validation, rather than invoking `check_value` directly.

## Exact patch scope

Starting revision: `853b1644e68866caeaa5de86b45fe1c560dc555f`; upstream base supplied for review: `5664ee7818f8da6c8dfe3c16e4bf0eb84d72967e`.

- `source/source_io/test_serial/read_input_test.cpp`: **74 added lines**; one required device API include and three Google Test cases using the existing `InputTest` fixture. Every new scratch INPUT is under `testing::TempDir()` and uses the existing helper's cleanup. No new globals, private-access macros or MPI calls.
- `source/source_io/unittests/CMakeLists.txt`: **10 added lines**; when `ENABLE_LIBRI_GPU=ON`, compile only the existing serial reader target's `device.cpp` with `__CUDA` and link that target to `CUDA::cudart`. MPI remains disabled. No new target or executable.
- `source/source_io/unittests/test_read_inp_exx_dftu.cpp`: unchanged; its existing `DeviceExxInput.SelectionAndValidation` remains in both item-suite runs, including its CPU-build unsupported-GPU check.

The final diff is [reader-final.patch](reader-final.patch), **84 insertions in two files, no deletions**. The unchanged production guard still rejects effective `symmetry=1` for GPU EXX. No fallback shim, INPUT parameter, library-algorithm test, commit, push or GitHub post was introduced by this worker.

The extra test wiring is necessary: `device` resets through `get_device_flag`, whose CPU-only implementation rejects `device gpu` before the EXX guard. Using the real CUDA probe avoids a mock of reader behavior. Per-source CUDA compilation also avoids enabling CUDA in `output_device.cpp` or other serial-reader sources. In the GPU configuration, the saved compile commands verify that the serial reader, EXX input registry and test TU retain `__GPU_RI` but have neither `__CUDA` nor `__MPI`; only this target's `device.cpp` gains `__CUDA`, without `__MPI`.

Only `DeviceExxGpuScfSymmetry` and `DeviceExxGpuMdEffectiveSymmetry` consult `probe_gpu_availability()` and call `GTEST_SKIP()` when it returns false. All CPU cases remain active. When a GPU is available, all rejection diagnostics and effective-value assertions execute unchanged.

## Reader coverage

All new fixtures use `basis_type lcao`, `dft_functional hse` and `ks_solver lapack`. The explicit LAPACK solver keeps the serial reader from selecting the MPI-dependent default `cusolver`; this is parser validation, not a solver run. GPU fixtures add `device gpu` and `device_exx gpu`; CPU fixtures select `device_exx cpu`. Normal SCF fixtures omit `calculation` and `gamma_only` so the ordinary SCF defaults are exercised.

| INPUT case | Effective symmetry | Expected and observed result |
| --- | --- | --- |
| CPU EXX, omitted symmetry | `1` | Accepted; real-space EXX symmetry remains enabled |
| CPU EXX, explicit `symmetry 1` | `1` | Accepted; real-space EXX symmetry remains enabled |
| GPU EXX, omitted symmetry | `1` | Rejected with the complete symmetry guard diagnostic |
| GPU EXX, `symmetry 1`, `exx_symmetry_realspace 0` | `1` | Rejected with the same complete diagnostic |
| GPU EXX, `symmetry 0` | `0` | Accepted; GPU EXX retained and real-space EXX symmetry disabled |
| GPU EXX, `symmetry -1` | `-1` | Accepted; GPU EXX retained and real-space EXX symmetry disabled |
| GPU EXX, `calculation md`, explicit `symmetry 1` | `0` | Accepted after reset; `calculation=md`, `device=gpu`, `device_exx=gpu` and disabled real-space EXX symmetry asserted |

The MD fixture also sets `md_type nve` and `md_tfirst 300`. Both rejected inputs must throw the fixture's `std::runtime_error` and contain this exact complete output line, bounded by newlines:

```text
 device_exx=gpu does not support symmetry=1 until LibRI GPU symmetry is fixed; use symmetry=0 or symmetry=-1, or device_exx=cpu
```

Moving validation before the MD reset would reject the MD fixture; failing to resolve the omitted SCF symmetry before the guard would miss the expected rejection. These tests observe the public reader pipeline and do not reproduce its reset logic.

## SAI jobs and observed results

Remote isolation root: `/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-reader-20261121`. All actual jobs used `16V100`, four V100s, 32 allocated logical CPUs and a one-hour maximum; only one job ran at a time. Successful jobs used four Slurm tasks for SAI mapping, but each serial unit executable ran as one process, with `OMP_NUM_THREADS=1`, `OPENBLAS_NUM_THREADS=1` and `MKL_NUM_THREADS=1`. The build used `--parallel 32`. Allocation and affinity checks ran before configuration/build and passed.

| Job | State / Slurm exit | Elapsed | Node | Purpose |
| --- | --- | --- | --- | --- |
| 2672381 | FAILED / `1:0` | 00:00:04 | 16v100n45 | Setup failure, before configure/build/test |
| 2672555 | COMPLETED / `0:0` | 00:05:53 | 16v100n12 | Unmodified baseline and initial reader patch, CPU/GPU |
| 2672722 | COMPLETED / `0:0` | 00:02:58 | 16v100n15 | Final patch with availability skips, CPU/GPU and hidden GPU run |

The final source was prepared as a separate `source-final` snapshot and built in fresh `build/final-cpu` and `build/final-gpu` directories after the coordinator requested no-visible-GPU handling. Earlier sources, builds and logs remain intact. [Slurm accounting](evidence/logs/sacct-final.txt) records actual resource allocations and exit statuses.

| Job | Source/configuration | Reader tests passed | Item tests passed | Configure / build / CTest return codes |
| --- | --- | --- | --- | --- |
| 2672555 | before-cpu | 13/13 | 33/33 | 0 / 0 / 0 |
| 2672555 | before-gpu | 13/13 | 33/33 | 0 / 0 / 0 |
| 2672555 | after-cpu | 14/14 | 33/33 | 0 / 0 / 0 |
| 2672555 | after-gpu | 16/16 | 33/33 | 0 / 0 / 0 |
| 2672722 | final-cpu | 14/14 | 33/33 | 0 / 0 / 0 |
| 2672722 | final-gpu | 16/16 | 33/33 | 0 / 0 / 0 |

Each row ran exactly two selected CTest executables. All listed normal runs have zero failed and zero skipped unit tests. The final GPU run executed both new GPU tests; it did not pass by skipping them. The hidden-GPU focused run returned **0**, with **1 passed / 2 skipped / 0 failed**: [raw output](evidence/logs/job-2672722/final-gpu-no-visible.log). The automated count checks assert both GPU tests ran normally and that only those two names skip under masking: [counts](evidence/logs/job-2672722/test-counts.json).

Build environment: GCC **13.3.0**, CUDA **12.9.86**, CMake **3.31.6**, Release builds, `ENABLE_MPI=ON` project configuration with the existing serial-reader MPI exclusions, `ENABLE_LIBRI=ON`, LibRI `0.3.0.0` from the provided dependency directory, Google Test source `a46a6012a133c7c0929fdae55b321c2fe65f3c5f`, and standard CPU LibXC **7.0.0**. CPU configuration used `USE_CUDA=OFF` and `ENABLE_LIBRI_GPU=OFF`; GPU used both `ON` and architecture `70`. Existing source/dependency/build trees outside the isolated root were read only.

The selected DDLA shared library SHA-256 is `f359feda186e11fff4a87ad52aa2d39ee11d8e5d3ca3b619aec2eb18b11f53af`; its path and all selected dependency/compiler paths are preserved in the CMake caches and command logs. No DDLA/LibRI numerical behavior was exercised or changed by the new tests.

## Exact execution commands and provenance

The submitted scripts are [validate-reader.sbatch](validate-reader.sbatch) for job 2672555 and [validate-reader-final.sbatch](validate-reader-final.sbatch) for job 2672722. Both reuse the provided `hse06-gpu-libs-20261120/build-env.sh`, SAI mapping, and dependencies; neither changes them. Successful submissions were `sbatch validate-reader.sbatch` and `sbatch validate-reader-final.sbatch` from the isolated remote root. Full expanded commands, including baseline and initial patch runs, are in [job 2672555 commands](evidence/logs/job-2672555/commands.log) and [job 2672722 commands](evidence/logs/job-2672722/commands.log). The final configure/build/test commands were exactly:

```bash
cmake --version > /org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-reader-20261121/logs/job-2672722/cmake.log 2>&1
cmake -S source-final -B build/final-cpu -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON -DGIT_SUBMODULE=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-pr8169-ready-20261121/deps/googletest-a46a6012a133c7c0929fdae55b321c2fe65f3c5f -DENABLE_MPI=ON -DENABLE_OPENMP=ON -DENABLE_LCAO=ON -DENABLE_LIBRI=ON -DENABLE_LIBXC=ON -DENABLE_ELPA=OFF -DENABLE_MLALGO=OFF -DENABLE_JSON=OFF -DUSE_CUDA=OFF -DENABLE_LIBRI_GPU=OFF -DCMAKE_CUDA_ARCHITECTURES=70 -DCMAKE_C_COMPILER=/usr/bin/gcc -DCMAKE_CXX_COMPILER=/usr/bin/g++ -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++ -DLIBRI_DIR=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-pr8169-ready-20261121/deps/LibRI-0.3.0.0 -DDDLA_ROOT=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120/install/ddla -DLIBCOMM_DIR=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120/imported-deps/LibComm-master -Dcereal_DIR=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120/imported-deps/cereal/lib/cmake/cereal -DBLAS_LIBRARIES=/opt/devtools/saiblas/2603-gnu-avx2/lib/libopenblas.so -DLAPACK_LIBRARIES=/opt/devtools/saiblas/2603-gnu-avx2/lib/libopenblas.so -DLibxc_DIR=/opt/devtools/libxc/libxc-7.0.0-avx2/lib/cmake/Libxc > /org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-reader-20261121/logs/job-2672722/final-cpu-configure.log 2>&1
cmake --build build/final-cpu --target MODULE_IO_read_input_serial MODULE_IO_read_item_serial --parallel 32 > /org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-reader-20261121/logs/job-2672722/final-cpu-build.log 2>&1
ctest --test-dir build/final-cpu -V -R \^MODULE_IO_read_\(input\|item\)_serial\$ > /org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-reader-20261121/logs/job-2672722/final-cpu-test.log 2>&1
cmake -S source-final -B build/final-gpu -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON -DGIT_SUBMODULE=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DFETCHCONTENT_SOURCE_DIR_GOOGLETEST=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-pr8169-ready-20261121/deps/googletest-a46a6012a133c7c0929fdae55b321c2fe65f3c5f -DENABLE_MPI=ON -DENABLE_OPENMP=ON -DENABLE_LCAO=ON -DENABLE_LIBRI=ON -DENABLE_LIBXC=ON -DENABLE_ELPA=OFF -DENABLE_MLALGO=OFF -DENABLE_JSON=OFF -DUSE_CUDA=ON -DENABLE_LIBRI_GPU=ON -DCMAKE_CUDA_ARCHITECTURES=70 -DCMAKE_C_COMPILER=/usr/bin/gcc -DCMAKE_CXX_COMPILER=/usr/bin/g++ -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++ -DLIBRI_DIR=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-pr8169-ready-20261121/deps/LibRI-0.3.0.0 -DDDLA_ROOT=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120/install/ddla -DLIBCOMM_DIR=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120/imported-deps/LibComm-master -Dcereal_DIR=/org/org-open-sai/proj-sai-hpc-software/runtime-tests/hse06-gpu-libs-20261120/imported-deps/cereal/lib/cmake/cereal -DBLAS_LIBRARIES=/opt/devtools/saiblas/2603-gnu-avx2/lib/libopenblas.so -DLAPACK_LIBRARIES=/opt/devtools/saiblas/2603-gnu-avx2/lib/libopenblas.so -DLibxc_DIR=/opt/devtools/libxc/libxc-7.0.0-avx2/lib/cmake/Libxc > /org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-reader-20261121/logs/job-2672722/final-gpu-configure.log 2>&1
cmake --build build/final-gpu --target MODULE_IO_read_input_serial MODULE_IO_read_item_serial --parallel 32 > /org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-reader-20261121/logs/job-2672722/final-gpu-build.log 2>&1
ctest --test-dir build/final-gpu -V -R \^MODULE_IO_read_\(input\|item\)_serial\$ > /org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-reader-20261121/logs/job-2672722/final-gpu-test.log 2>&1
env CUDA_VISIBLE_DEVICES= /org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-reader-20261121/build/final-gpu/source/source_io/test_serial/MODULE_IO_read_input_serial --gtest_filter=InputTest.DeviceExx\* > /org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-reader-20261121/logs/job-2672722/final-gpu-no-visible.log 2>&1
```

Every final configure/build/test and the count validator returned **0**: [final return codes](evidence/logs/job-2672722/returncodes.tsv). The same is true for all baseline/initial-patch configure/build/test commands: [earlier return codes](evidence/logs/job-2672555/returncodes.tsv). XML, raw logs, binary hashes, CMake caches, selected compile commands and link lines are retained under each job's evidence directory.

All source snapshots are based on `853b1644e68866caeaa5de86b45fe1c560dc555f`. SHA-256 manifests cover **7650 tracked regular files** in each snapshot; verification found zero mismatches before builds and again for the final snapshot after execution. The final manifest differs from baseline in exactly the two owned files. The coordinator's disjoint build-cleanup commit `af5c02db8` was not folded into these source snapshots and is not claimed tested by this worker.

- Baseline source archive: `source-before.tar.gz`, SHA-256 `895def68357e623a92a46dfa199d56928262f157bc76c3a647cb9c765bf6e824`.
- Initial-patch overlay: `reader-overlay.tar.gz`, SHA-256 `2db316f3f72312ae6c28b29bdea9dbcb537059ead1853a1512479a1c6f99b994`; retained for job 2672555 reproduction.
- Final overlay: `reader-final-overlay.tar.gz`, SHA-256 `d6a6bc51a5e7f09f506a330c44e32a1d21e62699c21b59dc4c8ce9014db4dbf4`.
- Full manifests: [baseline](source-before-sha256.json), [initial patch](source-after-sha256.json), [final](source-final-sha256.json).
- Focused before/final/local comparisons: [focused-source-hashes.json](focused-source-hashes.json).

Final source hashes (the last five files below are identical to baseline):

```text
57b0051830fe80b13e8afd42e9c95e863a5779b12bc05a1cdb949e947e3f9077  source/source_io/test_serial/read_input_test.cpp
44b513a2113cb9c7bc367553aa01eeb3a44aea509105c81c65864c69afbba53b  source/source_io/unittests/CMakeLists.txt
ce137026eb4bf6d644fc056eaa4a9f264feb4db540dac4cfbfedb2bc2b3e0bdb  source/source_io/unittests/test_read_inp_exx_dftu.cpp
df9867d25063463e87f2e4868a4b3a0ce25620fddbc5125d9428cbb700d72ec7  source/source_io/module_parameter/read_input.cpp
4c89c7f25935c0f85f06215c14b7cfd55cf305bbb32d8f9d9b59d3c8fc9bd8d8  source/source_io/module_parameter/read_inp_sys.cpp
1ea9cd2adc073860c4bf9899977509ecfb6977d1b2355dbbd906312f4ba9fed8  source/source_io/module_parameter/read_inp_exx_dftu.cpp
caaf95510fb7f19459759b83baa9edd7aafe5da56c6cb4b88662f7dd1b122190  source/source_base/module_device/device.cpp
```

## Formatting, governance and retained failures

The added C++ test block passes **clang-format 23.1.3** with the repository configuration; unrelated historical C++ formatting was not rewritten. The owned patch passes `git diff --check`. `source/source_io/unittests/CMakeLists.txt` passes **cmake-format 0.6.13**. Reverting its three earlier unrelated layout hunks while retaining `target_sources` fails the configured formatter, which produces exactly those three hunks: [required formatter diff](cmake-base-format-required.patch), [failed base-layout check](base-plus-target-sources-cmake-format-corrected.log), [passing current-layout check](current-cmake-format-corrected.log). Therefore those existing formatter-required hunks were retained.

The official governance checker ran through an isolated temporary Git index/object directory, without staging shared files, and returned **0**: [governance-final.log](governance-final.log). Its sole non-blocking warning requested documentation or a no-docs-needed explanation. **No documentation change is needed because this patch adds regression coverage and test build wiring while leaving every production INPUT registration, default, reset and validation behavior unchanged.** No governance exception is required.

Failure evidence is retained, not counted as passing validation:

1. Initial Slurm submission with `--cpus-per-task=32` was rejected by SAI policy before a job existed; CPUs are assigned from GPU count. See [submission output](remote-submit.log) and [original script](validate-reader-submission-rejected.sbatch).
2. Job **2672381** failed before any configure/build/test because `SLURM_NTASKS=1` was not divisible by four GPUs. The corrected jobs used four tasks, and their allocation/mapping assertions passed. See [setup failure record](job2672381-failed-setup.txt) and [original job script](validate-reader-failed-job2672381.sbatch).
3. A guarded attempt to update the unused initial-patch snapshot after the skip request refused to proceed because its CPU build had already started; no source was changed by that attempt. The final code instead used a new source directory and fresh builds. See [refused update](final-source-update.log) and [successful final snapshot preparation](final-source-prepare.log).
4. An exploratory formatter invocation omitted the `--` separator after the variadic `-c` option and did not process an input file; its no-op output is retained under `invalid-invocation-*` and is excluded from verification. Corrected formatter invocations above supply `-c CONFIG -- INPUT`.

## Limits and remaining work

This validates real INPUT reading, reset ordering, guard diagnostics, and hardware-conditional test behavior. The existing fixture disables STRU atom-count discovery and mocks global output-directory operations; it does not execute SCF, MD trajectories, EXX contractions or numerical comparisons. No full application/CLI rebuild, MPI runtime matrix, additional benchmark, LibRI algorithm test, production guard mutation or reference/tolerance relaxation was needed or performed. No claim is made about a physical host lacking CUDA driver libraries; the unavailable-GPU path was verified by masking visible GPUs in a fresh process.

The patch and report are ready for the coordinator to combine with the independent build cleanup, commit, push and update the PR. This worker has not committed, pushed or posted to GitHub.
