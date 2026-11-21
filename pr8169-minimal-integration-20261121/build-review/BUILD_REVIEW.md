Implemented the minimal ABACUS integration follow-up and validated it on SAI on 2026-11-21. The original main-project GPU Debug target **failed to link as reviewed**; adding `LibRI::LibRI` to that target's existing `LIBS` list fixed the link, and all four subsequent CTest invocations passed.

The shared checkout started clean at `853b1644e68866caeaa5de86b45fe1c560dc555f`, branch `experiment/lcao-hse-gpu`, with PR base `5664ee7818f8da6c8dfe3c16e4bf0eb84d72967e`. The live [review comment](https://github.com/deepmodeling/abacus-develop/pull/8169#discussion_r4651154611) was read before editing; it refers to that exact HEAD and was last updated at `2026-11-21T06:42:19Z`. Its saved response is [review-4651154611.json](provenance/review-4651154611.json).

| Owned file | Change | Added / removed versus starting HEAD |
| --- | --- | ---: |
| `source/source_lcao/module_ri/unittests/CMakeLists.txt` | Link `MODULE_RI_exx_workspace` to `LibRI::LibRI` | +1 / -1 |
| `tests/lcao_hse_gpu/cmake/CMakeLists.txt` | Remove `ENABLE_LIBRI_GPU_TESTS`, its prerequisite check, executable and CTest registration | +0 / -17 |
| `tests/lcao_hse_gpu/cmake/test_libri_gpu_accumulation.cpp` | Delete the duplicate upstream numerical regression | +0 / -122 |
| `docs/advanced/install.md` | Correct the release's symmetry claim and describe the retained dependency consumer | +7 / -5 |
| **Total** | **Four files; net reduction of 137 lines** | **+8 / -145** |

For these owned paths, the final diff against the PR base is +115/-1 across four surviving files, including the unchanged 27-line `test_libri_consumer.cpp`. The deleted accumulation test is absent from the resulting PR diff. The owned patch and original files are preserved under [provenance/](provenance/), and exact counts are in [style-and-delta.txt](logs/style-and-delta.txt).

The new link is already guarded: `source/source_lcao/module_ri/CMakeLists.txt` enters the entire module only under `if(ENABLE_LIBRI)` and adds its unit tests only with `BUILD_TESTING` and MPI. The workspace target also requires LCAO. Consequently, no additional conditional or option is needed for `ENABLE_LIBRI=OFF`.

The retained standalone consumer belongs to ABACUS because it exercises ABACUS's `FindLibRI.cmake` target interface without the main project's copied include paths or compile requirements. It checks CPU/GPU feature definitions, the selected LibRI API, and transitive BLAS linkage. The retained configure-time real/complex GPU compile/link probe exercises the LibRI/DDLA adapter and official `ddla::ddla` export. These checks protect ABACUS dependency integration; maintaining the 18 numerical contraction algorithms and signed accumulation/symmetry fixtures belongs to upstream LibRI. The removed numerical test was previously passing, and its historical public raw logs remain available in the [existing release-validation archive](https://github.com/Stardust0831/abacus-develop/raw/c59297fa82e75e05e4c3c7c9e91b16fe9e4b2f35/pr8169-release-validation-20261121/abacus-pr8169-release-validation-20261121.tar.gz). Application HSE comparisons remain the application-level numerical coverage. The removal also removes this PR's standalone direct `MPI_Init`/`MPI_Finalize` calls, so no exception for those deleted calls is needed.

The installation guide retains LibRI v0.3.0.0 as the minimum GPU release, compatible CUDA DDLA, the official exported target and compatibility probe, and the current rejection of GPU RI with effective `symmetry 1`. It now explicitly says that the release's GPU symmetry validation still fails. No library implementation, algorithm, custom DDLA finder, compatibility shim, tolerance or reference was changed.

Nearby consumers were inspected without expanding the build architecture. The remaining RI tests use tensor, BLAS/LAPACK, IO or symmetry utilities; the workspace test is the concrete nearby test that invokes `RI::Exx::cal_Hs()` and `cal_force()` and thereby instantiates runtime GPU dispatch. The LR projection and RI-benchmark test sources do not instantiate those runtime GPU operations. Production RI/LR/RDMFT objects feed the final ABACUS executable, whose existing `abacus::link_libs` → `abacus::feature_libs` closure already contains conditional `LibRI::LibRI`. No second concrete missing DDLA link was found in this inspection. This is source inspection, not a claim that every neighboring test was rebuilt; its key searches are saved in [source-inspection.json](provenance/source-inspection.json).

Validation used the isolated remote directory `/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-build-20261121`. Its source is a normal `git archive` snapshot of the starting HEAD, with only this worker's owned changes overlaid. The original workspace CMake file was retained for the first build, then replaced with the fixed version in the same fresh GPU Debug build directory. Existing remote source/build trees and binaries were only read. IO-reader changes owned by the other worker were not part of this snapshot.

One Slurm job ran: **2672287**, `16V100`, node `16v100n35`, **4 V100 GPUs / 32 logical CPUs / 60G allocated memory**, one-hour limit, elapsed **00:03:09**, final state **COMPLETED**, exit **0:0**. The initial submission was rejected before allocating a job because SAI forbids explicit `--cpus-per-task`; removing that directive allowed the GPU-count policy to allocate 32 CPUs. Both the original rejected script and the executed script are retained. See [submission-rejected.txt](logs/submission-rejected.txt), [validate-debug.sbatch](scripts/validate-debug.sbatch), and [sacct-2672287.txt](remote-results/logs/sacct-2672287.txt).

The job reused GCC 13.3, CMake 3.31.6, CUDA 12.9.1, Open MPI 5.0.10 and the existing Libxc/BLAS toolchain. Runtime settings were `OMP_NUM_THREADS=1`, `OPENBLAS_NUM_THREADS=1`, and `MKL_NUM_THREADS=1`; workspace output confirms one MPI rank and one OpenMP thread. No build or runtime test ran on the login node. Main-project builds selected only `MODULE_RI_exx_workspace` and its dependencies; the complete Debug application was not built.

Dependencies were the existing released LibRI v0.3.0.0 (`a385ac9b1d04c151f26f9d14cc0c2588f96557ab`) and the existing CUDA DDLA `7c0ca08b4349a527cec2a0c0af7d1a1082bd38c7` installation. All **118** LibRI implementation headers matched the release archive byte-for-byte. The loaded DDLA binary's SHA-256 is `f359feda186e11fff4a87ad52aa2d39ee11d8e5d3ca3b619aec2eb18b11f53af`, identical to the earlier recorded 7c0ca08 build; this task did not rebuild DDLA. See [dependency-verification.json](provenance/dependency-verification.json) and [dependency-hashes.log](remote-results/logs/dependency-hashes.log).

| Check | Literal result | Evidence |
| --- | --- | --- |
| Original GPU Debug main-project target | **FAILED**, build exit 2, expected reproduction; 14 unique unresolved DDLA symbols | [gpu-before-build.log](remote-results/logs/gpu-before-build.log) |
| Fixed GPU Debug main-project target | Configure/build exit 0; CTest **1/1 passed**, both real and complex geometry/electronic-isolation cases passed | [gpu-after-test.log](remote-results/logs/gpu-after-test.log) |
| Fixed CPU LibRI Debug main-project target | Configure/build exit 0; CTest **1/1 passed**, both real and complex cases passed | [cpu-test.log](remote-results/logs/cpu-test.log) |
| Retained CPU standalone consumer, Debug | Configure/build exit 0; CTest **1/1 passed** | [consumer-cpu-test.log](remote-results/logs/consumer-cpu-test.log) |
| Retained GPU standalone consumer, Debug | GPU compatibility probe and build passed; CTest **1/1 passed** | [consumer-gpu-test.log](remote-results/logs/consumer-gpu-test.log) |
| Owned CMake formatting, whitespace and governance | **Passed**; no governance findings | [style-and-delta.txt](logs/style-and-delta.txt), [governance-owned.txt](logs/governance-owned.txt) |

The original unresolved references include `ddla::ddlaInit(ddla::DdlaStream*&, ddla::DdlaBackend)`, `ddla::ddlaGetDeviceCount(ddla::DdlaStream* const&, int*)`, `ddla::ddlaDestroy(ddla::DdlaStream*&)`, memory/stream functions, and the real/complex `ddla::gemmVbatched` and `ddla::gemmVbatched2s` instantiations. All 14 exact signatures are in [original-unresolved-symbols.txt](logs/original-unresolved-symbols.txt). The original Debug compile flags already contain `__GPU_RI`, `__DDLA_RI` and `DDLA_USE_CUDA`, while the [original link command](remote-results/logs/gpu-before-link.txt) has no DDLA library. The [fixed link command](remote-results/logs/gpu-after-link.txt) includes the installed `libddla.so`, and [ldd](remote-results/logs/gpu-after-ldd.log) resolves it. Both builds use `-g` without optimization flags, so an optimized-away dispatch cannot mask the fix. The CPU target has none of those GPU definitions and no DDLA link/runtime dependency.

Exact configure/build/test commands, timestamps and exits are in [commands.txt](remote-results/logs/commands.txt) and [status.tsv](remote-results/logs/status.tsv). The central targeted commands were:

```bash
cmake --build build/abacus-gpu-debug --target MODULE_RI_exx_workspace --parallel 24 --verbose
ctest --test-dir build/abacus-gpu-debug -V -R '^MODULE_RI_exx_workspace$'
cmake --build build/abacus-cpu-debug --target MODULE_RI_exx_workspace --parallel 24 --verbose
ctest --test-dir build/abacus-cpu-debug -V -R '^MODULE_RI_exx_workspace$'
cmake --build build/consumer-cpu --parallel 4 --verbose
ctest --test-dir build/consumer-cpu -V
cmake --build build/consumer-gpu --parallel 4 --verbose
ctest --test-dir build/consumer-gpu -V
```

All four configurations used `CMAKE_BUILD_TYPE=Debug`; main-project configurations also used `BUILD_TESTING=ON`, `ENABLE_LIBRI=ON`, MPI/OpenMP/LCAO enabled, and matching `USE_CUDA`/`ENABLE_LIBRI_GPU` ON or OFF. The script records all dependency paths and other arguments. Each standalone build registers exactly one CTest (`libri_consumer`); the removed option and numerical test have no surviving registration.

Formatting used the already-cached cmake-format package with the repository's `cmake-format.yaml`; no package installation was needed. Governance used the repository's unchanged checker through [check-owned.py](scripts/check-owned.py), which supplies the owned working-tree diff because the checker CLI otherwise requires staging or two commits. It leaves the shared index untouched. [audit-evidence.py](scripts/audit-evidence.py) verified the captured exit codes, Debug flags, DDLA link transition, source/script/archive hashes and the single remaining consumer registration; its [audit result](provenance/evidence-audit.json) passed. The collected remote logs and compile/link commands compress to approximately 84 KiB in [remote-results.tar.gz](provenance/remote-results.tar.gz).

These results validate integration and the existing workspace test at Debug. The workspace objects retain their default CPU contraction mode even in the GPU-enabled build, and the small consumer does not execute numerical GPU contractions. No new HSE benchmark, GPU numerical acceptance or upstream LibRI symmetry retest is claimed; the known release symmetry failure remains a limitation. Existing test assertions/tolerances were unchanged. The full Debug application, all other unit tests, and `ENABLE_LIBRI=OFF` configuration were not built in this task; the latter's target guard was verified from source.

No commit, push or GitHub post was made. The parent can integrate these four owned changes, this evidence and the other worker's IO-reader results into the final PR metadata.
