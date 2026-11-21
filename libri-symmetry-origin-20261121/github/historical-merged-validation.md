# LibRI #15/#16: merge verification and combined regression

Both PR branches now include upstream `master` at `6534722`, preserving PeizeLin's original commits. Ordinary merge commits retain the existing PR history:

- #15: `e72194dc104f47294c733ef314255ccec4995c11`. The entire file tree is identical to the previously tested `2cf8290`. Relative to current master, this leaves the const-input accumulator fix, two atom-list indexing fixes and their regressions.
- #16: `7025df62cc4d3c7a609d1acec1733ab4a95dc7fb`. Includes updated #15 and retains the original symmetry corrections. The CPU contraction files are identical to #15.

The merged #16 version was built and tested with its exact committed LibRI sources, without additional LibRI patches. Hardware: NVIDIA V100-SXM2 16 GB GPUs with GCC 13.3/OpenMP and DDLA v0.0.4/CUDA.

| Validation | Result |
| --- | --- |
| CPU-only and GPU-enabled symmetry builds, 1 and 4 OpenMP threads | All four runs pass |
| All 18 contraction labels and their combined sum, real/complex tensors, selected/empty output and seeded accumulation | Pass with both CPU implementations and GPU execution |
| Scalar accumulation: float/double, real/complex, CPU-only/GPU-enabled, 1 and 4 threads | 16/16 runs pass |
| Hartree reference, distinct/unequal atom lists, exchange matrix/force/stress comparisons | 6/6 runs pass |
| C++11 symmetry callback build and assertions | Pass |
| Complete ABACUS GPU compilation and linking, including BSE | Pass |
| ABACUS HSE symmetry calculations | 20/20 pass unchanged repository checks; all 16 backend comparisons pass |

The 20 ABACUS calculations cover five configurations, each with real/complex RI tensors and one/two MPI ranks:

| Solver / RI backend / real-space EXX symmetry | Result |
| --- | --- |
| CPU ScaLAPACK / CPU RI / on | 4/4 pass |
| GPU cuSOLVER / CPU RI / on | 4/4 pass |
| GPU cuSOLVER / GPU RI / on | 4/4 pass |
| GPU cuSOLVER / CPU RI / off | 4/4 pass |
| GPU cuSOLVER / GPU RI / off | 4/4 pass |

ABACUS is `b30b66a5a333a2667d618932f8430a80dd92146a` with only the [test patch](abacus-validation-only.patch) removing its GPU-symmetry rejection. Inputs and reference files use the existing `scf_hse_symm_multik` fixture. `INPUT.info` checks confirm the selected backend and symmetry settings. The fixture's forces vanish by symmetry, so these ABACUS runs do not establish nonzero-force behavior. MAGMA, BSE numerical results and multi-node execution were not tested. The existing LR rounded-reference limitation documented in [the #15 results](../scaled-accumulation/gitee-integration-20261024/README.md) was not re-tested here.

Complete original records:

- [Full ABACUS verbose build](results/abacus/build/output.log), [configuration](results/abacus/configure/output.log), [version](results/abacus/version/output.log).
- HSE run logs: [real/one rank](results/abacus-cases/real-mpi1/autotest.log), [complex/one rank](results/abacus-cases/complex-mpi1/autotest.log), [real/two ranks](results/abacus-cases/real-mpi2/autotest.log), [complex/two ranks](results/abacus-cases/complex-mpi2/autotest.log).
- Symmetry numerical tests: [CPU/one thread](results/symmetry/cpu/omp1/output.log), [CPU/four threads](results/symmetry/cpu/omp4/output.log), [GPU/one thread](results/symmetry/gpu/omp1/output.log), [GPU/four threads](results/symmetry/gpu/omp4/output.log).
- [Accumulation build and results](results/accumulation), [Hartree/atom-list/physics results](results/physics), [backend comparisons](results/abacus-cases/comparison.json).
- [All commands and exit codes](results/steps.json), [scheduler outcome](results/scheduler.txt), [final summary](results/summary.json), [drivers and scripts](control), [compilation databases](build-records).
- [Pinned revisions and archive hashes](manifest.json), [merge verification](merge-verification.json), [runtime header hashes](results/libri-header-sha256.json), [file checksums](SHA256SUMS).
- [Exact #15 source](pr15.tar.gz), [exact #16 source](source.tar.gz), [#15 delta from master](pr15-fixes.patch), [#16 symmetry delta](symmetry-delta.patch).

The original [symmetry before/after failure logs](../gpu-symmetry/upstream/README.md) and [#15 defect reproductions](../scaled-accumulation/gitee-integration-20261024/README.md) remain available.
