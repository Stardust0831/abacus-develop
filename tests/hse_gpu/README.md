# Fork-only HSE GPU experiments

This experiment starts from upstream develop `f264b4022fd477734de0f3ace723f6da9e306943`.
It is confined to `Stardust0831/abacus-develop`; no upstream PR is requested.

Run the existing Slurm client with an isolated experimental matrix:

```sh
python3 .ci/slurm/run_hse_experiment.py --target SAI-abacus \
  --run-id UNIQUE-RUN-ID --artifacts /absolute/path/to/results
```

The wrapper copies the normal control files, substitutes `hse-config.ini`, and
enables LibRI in the copied build template, and passes the committed checkout
to `runner.py`. Header-only dependencies are staged locally using the versions
and SHA256 hashes in `toolchain/scripts/package_versions.sh`, because the
compute nodes cannot reach GitHub. Cereal uses the existing toolchain install
settings. No global cluster environment is changed. Uncommitted C++ changes are not
compiled. Use a fresh run ID and artifacts directory for each revision.

The matrix includes existing PW PBE0 and LCAO HSE reference comparisons plus
Si8 HSE calculations at Gamma, 20 bands, 30 Ry wavefunction cutoff, 120 Ry
density cutoff, and a fixed random seed. The benchmark runs CPU and GPU,
ACE and ordinary exchange, divisible and nondivisible band chunks, and a
60 Ry exchange grid. Each configuration runs twice, reversing the order on
the second pass. All calculations start fresh and use one MPI rank and one
OpenMP thread. The strict round sets `scf_thr=1e-12` and the initial
`pw_diag_thr=1e-12`, and additionally covers CPU chunk 6 and GPU chunk 19
(a one-band tail). This CPU baseline is not an optimized full-node CPU benchmark.

Full-grid results must agree within 1e-6 eV/atom; small-grid results are an
accuracy/performance study and are not silently treated as equivalent.
The benchmark retains INPUT, STRU, KPT, stdout, running logs, convergence
markers, final energies, process wall times, GPU identity, and executable
version. Slurm CI additionally records module versions and GPU telemetry.
Si8 is a focused reproducibility/performance probe, not a production-quality
basis/k-point convergence study or evidence of large-system scaling.

## Candidate change

The original `ensure_exx_batch` resizes buffers and recreates both FFT plans
whenever the requested batch width changes. With 20 bands and chunk width 6,
the 6/2 alternation repeats for every occupied source orbital.

The candidate keeps peak buffer capacity and at most two batch plans, plus
the separate single-source-orbital plan. The two-entry cache bounds cuFFT
workspace retention for solvers requesting varying band counts. Grid changes
invalidate all plans; the destructor releases each owning handle once.
Additional cuFFT plan workspace is a memory tradeoff to measure.

No INPUT fields, physical approximations, arithmetic kernels, or accumulation
orders change. The existing CPU/CUDA FFT interfaces are reused, so no new
source or build linkage is required. Numerical verification is performed by
the committed Slurm matrix rather than an implementation-mirroring unit test.
Results and limitations are recorded in RESULTS.md.
