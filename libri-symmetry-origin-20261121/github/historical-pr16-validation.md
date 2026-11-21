# GPU symmetry fix: upstream validation

The same 20 ABACUS configurations were run before and after the symmetry fix. GPU RI with real-space symmetry aborts in all four original-version cases and passes all four fixed-version cases. The other 16 controls pass in both versions.

The baseline is [PR #15](https://github.com/abacusmodeling/LibRI/pull/15) at `bc79bb2ca52af2dbd9ab612c38e248f6c9dd96f1`; the complete fix is `27951e74f428decceca7805297838db6130cf8da`. Both builds use the exact LibRI headers from those commits. ABACUS is `b30b66a5a333a2667d618932f8430a80dd92146a` with the [test-only GPU-symmetry guard removal](../abacus-validation-only.patch). Inputs, reference files and tolerances are identical between the two runs. Hardware: NVIDIA V100-SXM2 16 GB GPUs, using two GPUs for the two-rank GPU RI cases.

## End-to-end outcomes

Each row covers real/complex RI tensors × one/two MPI ranks. PASS means SCF convergence and successful repository reference checks.

| Solver / RI backend / real-space symmetry | Before | After |
| --- | --- | --- |
| CPU ScaLAPACK / CPU RI / on | 4/4 PASS | 4/4 PASS |
| GPU cuSOLVER / CPU RI / on | 4/4 PASS | 4/4 PASS |
| GPU cuSOLVER / GPU RI / on | 4/4 abort | 4/4 PASS |
| GPU cuSOLVER / CPU RI / off | 4/4 PASS | 4/4 PASS |
| GPU cuSOLVER / GPU RI / off | 4/4 PASS | 4/4 PASS |

| Affected configuration | Before | After |
| --- | --- | --- |
| Real / 1 rank | [Exception and abort](before-fix/results/autotest/real-mpi1/gpu_sym/output.log) | [Repository checks pass](results/abacus-cases/real-mpi1/autotest.log) |
| Complex / 1 rank | [Exception and abort](before-fix/results/autotest/complex-mpi1/gpu_sym/output.log) | [Repository checks pass](results/abacus-cases/complex-mpi1/autotest.log) |
| Real / 2 ranks | [Exception and abort](before-fix/results/autotest/real-mpi2/gpu_sym/output.log) | [Repository checks pass](results/abacus-cases/real-mpi2/autotest.log) |
| Complex / 2 ranks | [Exception and abort](before-fix/results/autotest/complex-mpi2/gpu_sym/output.log) | [Repository checks pass](results/abacus-cases/complex-mpi2/autotest.log) |

The original failure, with the build path and MPI prefix abbreviated:

```text
terminate called after throwing an instance of 'std::invalid_argument'
  what():  label a0b0_a1b1 error in .../Filter_Atom_Symmetry.h line 49
Signal: Aborted (6)
```

All cases use `symmetry=1` and one OpenMP thread. `INPUT.info` confirms the selected solver, RI backend, scalar type and real-space symmetry setting. The fixture has zero forces by symmetry; nonzero-force behavior is not established by this case.

## Numerical contraction regression

| Version | 18 individual GPU contractions |
| --- | --- |
| Before the symmetry fix | 10 exceptions, 4 incorrect outputs, 4 pass |
| Two maki49 backports | 14 pass; 4 still lose intermediate contributions |
| Complete fix | All 18 pass; their combined sum also passes |

The same fixture compares against unrestricted CPU contractions masked independently on their final output keys. It covers real/complex tensors, both CPU implementations, GPU execution, one/four OpenMP threads, output-sector selection and seeded signed/zero/fractional accumulation.

- Fixed CPU: [one thread](results/fixed-cpu/omp1/output.log), [four threads](results/fixed-cpu/omp4/output.log).
- Fixed GPU: [one thread](results/fixed-gpu/omp1/output.log), [four threads](results/fixed-gpu/omp4/output.log).
- Original version: [exception](results/baseline/label-16/output.log), [incorrect output](results/baseline/label-00/output.log).
- Backports alone: [remaining numerical failure](results/backport/label-01/output.log).
- C++11 callback regression: [build](results/callbacks/build/output.log), [run](results/callbacks/test/output.log).

## Complete original build and runtime records

- Before ABACUS build: [configuration](before-fix/results/abacus/configure/output.log), [full verbose compilation/linking](before-fix/results/abacus/build/output.log), [version](before-fix/results/abacus/version/output.log).
- After ABACUS build: [configuration](results/abacus/configure/output.log), [full verbose compilation/linking](results/abacus/build/output.log), [version](results/abacus/version/output.log).
- All ABACUS inputs and outputs: [before](before-fix/results/abacus-cases), [after](results/abacus-cases).
- Individual outcomes and component comparisons: [before/after](before-fix/results/summary.json), [fixed CPU/GPU comparisons](results/abacus-cases/comparison.json).
- Commands, output and exit codes: [fixed and contraction tests](results/steps.json), [before-fix tests](before-fix/results/steps.json).
- Source revisions and archives: [manifest](manifest.json), [baseline](baseline.tar.gz), [two backports](backport.tar.gz), [complete fix](fixed.tar.gz).
- Header hashes: [before](before-fix/build-records/libri-header-sha256.json), [after](build-records/libri-header-sha256.json). All headers match their archived commits without extra LibRI patches.
- [Identical input/reference hashes](before-fix/results/input-reference-sha256.json), [final summary](upstream-summary.json), [scheduler result](results/scheduler.txt).

Both full GPU builds include BSE and pass with GCC 13.3/OpenMP and DDLA v0.0.4/CUDA. BSE numerical paths, MAGMA and multi-node execution were not tested. Complete command scripts and compilation databases are included in the `control`, `before-fix/control`, `build-records` and `before-fix/build-records` directories.
