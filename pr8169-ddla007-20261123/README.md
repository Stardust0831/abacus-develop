# ABACUS #8169: DDLA v0.0.7 and C++14 validation

DDLA v0.0.7 works with the released LibRI and an ABACUS production executable compiled as C++14. The integration uses DDLA's public `DDLA_HAS_GPU` capability and installed `ddla::ddla` target. All 20 HSE calculations, 18 CPU/GPU and real-space symmetry comparisons, and 20 comparisons against the previous DDLA/C++17 configuration passed with unchanged tolerances.

## Revisions and build

| Component | Revision |
| --- | --- |
| ABACUS validated source | `e47e26947e6620fee11a44de3fdb520b49fae76e` |
| Build input | `fa1c75dcce0df12fe37267aed5ed2deef3fcaef0` + [four-file patch](ddla007-integration.patch) |
| LibRI, official v0.3.0.0 | `589f6f8c6df3916575a1ba41e840de919d40d345` |
| DDLA, official v0.0.7 | `0a65e570d3d3bc70e4d53a7e992b2de60abc884c` |
| Toolchain | GCC 13.3.0, CUDA 12.9.1, Open MPI 5.0.10, CPU LibXC 7.0.0 |
| Runtime | One V100, one MPI rank, OMP=1, BLAS=1 |

The source commit was created after validation; its tree contains exactly the tested patch. The build source copy has no Git metadata, so the executable's commit field is `unknown`. The [source manifest](source-manifest.json) verified 8,594 ABACUS/LibRI/DDLA files before building. ABACUS binary SHA256: `3a0a2f6a6f9aeccd85371a12c7777b32ddde773509b378daa0626c2f3117f258`.

DDLA was built and installed to a dedicated prefix. The executable, LibRI numerical regression and Debug RI workspace test all resolve this installation's `libddla.so.0.0.7`. LibRI and DDLA source files, numerical masks, references and tolerances are unmodified.

The old ABACUS configure probe rejects v0.0.7 because it requires the now-private `DDLA_USE_CUDA` definition. That expected failure is preserved. The patch requires DDLA 0.0.7, uses public `DDLA_HAS_GPU`, retains real/complex GPU API compile/link checking and removes the C++17 requirement from ABACUS.

## Results

| Check | Result |
| --- | --- |
| DDLA implementation | C++17 build/install passed |
| Official DDLA installed consumer | Strict C++11 with `-pedantic-errors`; passed |
| Standalone ABACUS CPU/GPU consumers | Both compiled as C++14 and passed |
| LibRI numerical regression | 456 CHECK / 38 PASS, compiled as C++14 |
| Release GPU ABACUS | Full build passed; all 1,003 directly linked production objects compiled as C++14 |
| GPU INPUT/workspace tests | 52/52 GoogleTests, no skips |
| Debug workspace target | 2/2 GoogleTests, no skips |
| HSE calculations | 20/20 converged and completed normally |
| CPU/GPU and real-space reduction comparisons | 18/18 passed |
| Comparison with previous DDLA/C++17 configuration | 20/20 passed |
| Direct `--check-input` | 8/8 passed, requiring both exit 0 and success text |

The released LibRI numerical test's own CMake file requests C++17; the supplied [external CMake wrapper](cxx14-regression/CMakeLists.txt) compiles its unchanged test source as C++14. GoogleTest publicly requires C++17, so GoogleTest-based unit tests use that standard. The independent consumers, LibRI regression and production ABACUS objects demonstrate C++14 compatibility. The Debug build covers the workspace target, not a full Debug executable.

The HSE matrix includes original/displaced Si2, real/complex multi-k EXX tensors, real-space reduction off/on under `symmetry 1`, CPU/GPU RI, and water Gamma with `nspin=1/2`. Displaced Si2 has nonzero forces. The raw-output audit checks effective symmetry counts, unchanged reference/threshold/KPT files, SCF convergence, normal completion and every force/stress component.

| Comparison | Max ΔE / eV | Max component ΔF / eV/Å | Max component Δstress / kbar |
| --- | ---: | ---: | ---: |
| CPU/GPU RI, 10 pairs | 1.7053e-12 | 2e-10 | 1e-10 |
| Real-space reduction off/on, 8 pairs | 3.979e-13 | 0 | 0 |
| Previous/new configuration, 20 pairs | 2.6148e-12 | 1.3e-9 | 4e-10 |
| Unchanged acceptance limit | 1e-7 | 1e-6 | 1e-5 |

Differences were independently recomputed with Decimal from raw logs. Zero force/stress differences mean agreement at the output precision of ten decimal places. The previous configuration used DDLA `7c0ca08b4349a527cec2a0c0af7d1a1082bd38c7` and ABACUS C++17; the comparison includes both the dependency and compiler-standard change. Its [raw baseline and report](https://github.com/Stardust0831/abacus-develop/tree/aaf9c9b3f6652d3e60ab728304d578e0ab62ba3f/pr8169-symmetry-20261123) remain available.

## Audit correction and job records

The initial application job built ABACUS and passed the unit tests, then failed because its audit incorrectly required every configured GoogleTest target to use C++14. The original audit and failure logs are preserved in the archive. The corrected audit verifies that every C++17 command uses GoogleTest, no such object is linked into the production executable, all direct production link objects use C++14, and no private DDLA backend definitions reach consumers.

| Job | Result | Elapsed |
| --- | --- | --- |
| 2745169, dependencies | COMPLETED, 0:0 | 3m17s |
| 2745261, application build and initial audit | FAILED, 1:0, audit classification error described above | 18m48s |
| 2745922, corrected audit and runtime tests | COMPLETED, 0:0 | 2m01s |

The runtime job's time limit was shortened from 30 to 5 minutes before it started. A read-only diagnostic step in the build job also returned 127 because `rg` was unavailable on that node; a `grep` retry succeeded. No numerical failures were hidden by these corrections.

Governance and `git diff --check` passed. Local formatting tools were unavailable; formatting is checked by PR CI. This validation covers the listed small fixtures on one GPU/rank; it does not retest performance, HIP, multi-rank or multi-GPU behavior.

## Evidence and reproduction

- [Raw inputs, outputs and build logs](ddla007-evidence.tar.gz), 2,335,848 bytes / 519 files; [SHA256](ddla007-evidence.tar.gz.sha256).
- [Validation summary](validation-summary.json), [independent numerical audit](independent-audit.json), [cross-version comparisons](cross-version-comparison.json), [source provenance](provenance.json).
- [Dependency build/test commands](validate-dependency.sbatch), [application build/test commands](validate-abacus.sbatch), [runtime commands](validate-runtime.sbatch).
- [HSE matrix driver](run-e2e.py), [CLI driver](check-cli.py), [final build audit](verify-build-final.py), [numerical audit](audit-results.py).

Archive SHA256: `5a55ac7896678bb8ea891dab8cff5ed8fc49742be9cb217f6ead1ea203c8c2b6`. All 518 payload manifest entries were verified after downloading. Source trees, build objects and binaries are excluded. The archive retains configure/build/test logs, compile commands, link response files, failed and successful audits, runtime inputs/outputs and job accounting.

Scripts preserve the tested dependency paths; adjust these to equivalent local installations. To repeat postprocessing, extract the archive into `evidence/` beside the scripts and an ABACUS source copy matching the commit above, then run `python3 audit-results.py`. `summarize-validation.py` additionally expects the earlier public evidence extracted as `../pr8169-maintenance-20261123/evidence` to recompute cross-version comparisons.
