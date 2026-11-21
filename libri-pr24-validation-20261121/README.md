LibRI [PR #24](https://github.com/abacusmodeling/LibRI/pull/24), tested at `d8fc6eca97f6ccf0b4448644f2f891ad7f2eb2e9`, **partially fixes GPU symmetry filtering but does not fully resolve the regression**. It was open and unmerged at verification; no GitHub check runs or review results were attached to this head.

SAI job **2673063**, partition **16V100**, node `16v100n09`: one V100, one MPI rank, OMP/BLAS=1. Elapsed **2m22s**. GCC 13.3, unchanged CUDA DDLA installation, library SHA256 `f359feda186e11fff4a87ad52aa2d39ee11d8e5d3ca3b619aec2eb18b11f53af`. Slurm completion means the collection script completed; test failures below remain failures.

| Variant | Result |
| --- | --- |
| PR #24, original upstream test fixture | Fails in GPU mode: `a1b1_a2b2`, sector 1, output block count differs. The fixture still directly constructs the CPU filter. |
| PR #24, fixture migrated to Wrapper, both CPU modes | Pass: 304 CHECK / 38 PASS, all 18 labels + their sum, real and complex. |
| PR #24, Wrapper fixture, GPU | **14/18 individual labels pass; 4/18 fail.** The combined sum fails too. Same failing labels for real and complex. |
| PR #24 + diagnostic removal of four intermediate filters, Wrapper fixture | Pass: **456 CHECK / 38 PASS**, two CPU modes + GPU, all labels + sum, real and complex. |

Compared with the earlier released `a385ac9` reproduction (8/18 GPU labels failing), PR #24 fixes the four `a01b01_a01b2` cases. It fixes callback argument order in both the header and generator, but leaves the four early `filter_for2(label,Aa01,Aa2)` calls in `a01b2_a2b01`. Here `Aa2` is an intermediate summation index, not the output partner. The GPU filter interprets this pair as output-sector membership and incorrectly discards required intermediate terms. Later correction of `filter_for32` argument order cannot restore terms already discarded.

| Remaining failing label | First real element error | First complex element error |
| --- | ---: | ---: |
| `a1b2_a2b1` | 4.89589 | 5.16888 |
| `a1b2_a2b0` | 5.06813 | 5.35631 |
| `a0b2_a2b1` | 4.88398 | 5.16407 |
| `a0b2_a2b0` | 5.05577 | 5.35130 |
| All labels combined | 19.9038 | 21.0402 |

These are synthetic tensor element errors, not physical energy/force units. Each failure is at sector 1, GPU mode 2, output atoms `(1,0)`, cell 1, element 0. Every real and complex label was launched separately so a real failure could not hide complex coverage.

The four retained calls are at [header line 2107](https://github.com/abacusmodeling/LibRI/blob/d8fc6eca97f6ccf0b4448644f2f891ad7f2eb2e9/include/RI/ri/LRI-cal_loop3_GPU.hpp#L2107), 2271, 2435 and 2599; their common [generator call is line 838](https://github.com/abacusmodeling/LibRI/blob/d8fc6eca97f6ccf0b4448644f2f891ad7f2eb2e9/tools/cal_loop3/cal_loop3_GPU.py#L838). [GPU filter semantics](https://github.com/abacusmodeling/LibRI/blob/d8fc6eca97f6ccf0b4448644f2f891ad7f2eb2e9/include/RI/physics/symmetry/Filter_Atom_Symmetry_GPU.h#L47) still require filtering output atoms only. The additional `filter_for31` order corrections in PR #24 do not change this symptom because that GPU symmetry callback deliberately does no pair filtering.

The [diagnostic patch](diagnostic-remove-intermediate-filter.patch) deletes only those four header calls and the one generator call. It was applied to a separate source copy, never silently to the PR snapshot or ABACUS dependencies. Both PR and diagnostic generators reproduce their tested headers exactly: [verification](generator-verification.json). No reference or tolerance was weakened: reference is the full unfiltered CPU contraction followed by an independently selected output mask, using the existing `1e-10 * (1 + abs(reference))` tolerance. Tests include four sectors, real/complex, empty and seeded outputs, and signed/zero accumulation. The fixture migration plus command-line selection is recorded in [fixture-wrapper.patch](fixture-wrapper.patch).

All **335** uploaded source/script hashes match the compute-node copies. Source provenance is pinned in [PR metadata](pr-metadata.json), [manifest](manifest.sha256), and [test summary](test-summary.json). [Raw run status](remote-results/logs/status.tsv), [real failing case](remote-results/logs/pr24-wrapper-real-label-1.log), [complex failing case](remote-results/logs/pr24-wrapper-complex-label-1.log), [passing diagnostic run](remote-results/logs/pr24-diagnostic-all.log), build logs and scheduler output are preserved.

Reproduction: unpack [test-bundle.tar.gz](test-bundle.tar.gz), adjust dependency paths and `task_root` in [pr24.sbatch](pr24.sbatch), then submit with `sbatch pr24.sbatch`. Build and run commands use the official DDLA CMake export. The minimal failing command after building is:

```bash
OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 \
  mpirun -np 1 --map-by ppr:1:node:pe=1 --bind-to core \
  build/pr24-wrapper/test_lri_gpu_symmetry 1 gpu real
```

[remote-results.tar.gz](remote-results.tar.gz) contains every small build/run output. [SHA256SUMS](SHA256SUMS) covers the archives and reports. The source bundle contains the unmodified PR source, separately named diagnostic source and Wrapper fixture. Existing benchmark builds were untouched.

**Application limit:** this is standalone LibRI validation. No new symmetry-enabled ABACUS energy/force/stress acceptance is claimed. The diagnostic patch is not an ABACUS-maintained library patch. The ABACUS GPU + effective symmetry=1 guard remains until an upstream fix passes application-level validation.
