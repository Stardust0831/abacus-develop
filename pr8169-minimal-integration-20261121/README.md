ABACUS PR #8169 integration follow-up at `6dd58cf762fd730d62eb61ed36e3383e660066bb`.

The GPU Debug RI workspace target now links through `LibRI::LibRI`. The duplicate LibRI numerical accumulation test has been removed from ABACUS; the small consumer/interface test and application comparisons remain. INPUT reader regressions exercise effective symmetry after the normal reset sequence. LR/RDMFT contractions remain on CPU, including LR reuse of Kohn-Sham geometry. No new INPUT parameter or library implementation patch is added by this follow-up.

| Targeted validation | Result |
| --- | --- |
| GPU Debug workspace before the link fix | Reproduced build failure: 14 unresolved DDLA symbols |
| CPU/GPU Debug workspace after fix | Both CTest 1/1, real and complex cases pass |
| CPU/GPU standalone consumer | Both CTest 1/1 pass |
| Final serial reader + EXX item suites | CPU 47/47; GPU 49/49, zero skips with a visible V100 |
| GPU tests with visible devices masked | One CPU case passes; exactly two GPU cases skip |
| Combined PR governance and whitespace | Pass |

SAI `16V100` jobs: build/link **2672287**, reader **2672722** (baseline/initial reader **2672555**). Runtime OMP/BLAS=1. Exact commands, raw outputs, source hashes and setup failures are retained in [build report](build-review/BUILD_REVIEW.md) and [reader report](reader-review/READER_REVIEW.md).

Source traceability: [final-source-audit.json](final-source-audit.json) verifies the targeted sources against the independent build evidence and the final combined reader snapshot. A new upstream CI directory-layout rule required moving the existing test file byte-for-byte into `unittests/`; [migration and retest](reader-layout-review/README.md), job **2673188**, again pass **47/47 CPU and 49/49 GPU**, with zero normal-run skips and exactly two skips under GPU masking. The current upstream governance checker now reports no findings for the full PR. The final reader build includes the complete combined source; the separate Debug workspace builds retain identical target sources. The installation guide differs only by the LR documentation correction. No new full-application/HSE benchmark is claimed: those timings remain tied to `f2667c6eed30e661a36bfb0ae1844802c99f171e`.

This archive includes reports, scripts, patches, all small validation logs, CMake caches and source manifests. Large complete baseline-source archives and redundant archive copies are omitted; obtain the base at `853b1644e68866caeaa5de86b45fe1c560dc555f` and apply the included patches to reproduce each isolated snapshot. Git administrative objects/indexes and Python caches are omitted. The published standalone LibRI PR #24 investigation is a separate test; it does not alter these builds or remove the ABACUS symmetry guard.
