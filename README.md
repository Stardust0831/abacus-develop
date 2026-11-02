# Independent LCAO RI performance experiments

Three standalone changes based on upstream develop `d20090cc137fdc3b3baddd9217f792bb7af922d7`. This branch contains review evidence only.

| Change | Commit |
| --- | --- |
| Libxc OpenMP scheduling | `90f5c2536795cff162d42b7620265e6a248cdc5f` |
| Integral evaluation reuse | `06ab2be77f993b045a623948661663c86225c99b` |
| Radial table construction | `dfc71eb145aef88d0e2f22c2e7739939bc8f351e` |

All six merge orders succeed and produce tree `474865f66716ea285fe84b90f26bd091b45f8375`. Each independent branch and the combined source was built and tested. No DDLA library or LibRI GPU macro is used; LibRI is the unmodified default `b0eff7a`.

## Method

HSE calculations start from atomic density and include converged SCF, nonzero forces and stress. The primary cases are displaced Si32 (416 basis functions) and CsPbI3 (5 atoms). Each comparison fixes the pseudopotentials, basis, grids, screening and convergence thresholds. Asset hashes and portable INPUT/STRU/KPT files are under `cases/`; point `PP_ORB` at the matching upstream `tests/PP_ORB` directory.

The primary resource configuration is one V100, one MPI rank, four physical CPU cores/OpenMP threads and serial BLAS. CPU placement was checked with an OpenMP probe before every run. Two matched sequences use opposite execution orders on separate allocations. Each baseline/candidate pair shares its allocation. Nodes are shared with other jobs; this is not an exclusive-node scaling study. cuSOLVER diagonalization and CPU LibRI contractions are common to all primary versions. Compiler: GCC 13.3; CUDA 12.9.1; Libxc 7.0.0.

All six executables enable the existing `ModuleBase::timer::write_to_json("time.json")` call at the end of timer printing. This identical benchmark-only instrumentation exposes timers below the default 1% display threshold and is absent from the PR branches. Timers are rank-zero elapsed time; nested timers are never summed. Complete time is measured around MPI process launch and includes startup.

Build verification checks source hashes, linked-object timestamps/hashes, symbols for each new API, and identical Libxc objects in baseline/reuse/radial builds. `builds.json` records the executable identities. Earlier runs affected by stale incremental objects are excluded. An initial complex-k control used an unsupported direct k-point list and failed in the unchanged baseline's LibRI distribution; the valid comparison uses a regular 2x1x1 Gamma mesh.

## Libxc scheduling

| System | Stage | Baseline (s) | This PR (s) | Paired speedup |
| --- | --- | ---: | ---: | ---: |
| Si32 | Libxc evaluation | 77.87–88.66 | 19.51–22.70 | 3.91–3.99x |
| Si32 | Effective potential | 98.46–110.97 | 40.89–46.17 | 2.40–2.41x |
| Si32 | Complete SCF + forces + stress | 182.22–203.71 | 122.53–138.02 | 1.48–1.49x |
| CsPbI3 | Libxc evaluation | 42.56–42.75 | 10.29–10.86 | 3.94–4.13x |
| CsPbI3 | Effective potential | 47.81–48.09 | 15.34–16.11 | 2.98–3.12x |
| CsPbI3 | Complete SCF + forces + stress | 424.48–426.14 | 391.86–396.49 | 1.07–1.08x |

Ranges cover two paired runs in separate allocations; speedups are computed within each pair.

## Integral evaluation reuse

| System | Stage | Baseline (s) | This PR (s) | Paired speedup |
| --- | --- | ---: | ---: | ---: |
| Si32 | RI integrals and derivatives | 6.64–7.59 | 1.97–2.19 | 3.36–3.47x |
| Si32 | Complete SCF + forces + stress | 182.22–203.71 | 174.42–186.09 | 1.04–1.09x |
| CsPbI3 | RI integrals and derivatives | 16.21–16.28 | 2.48–2.54 | 6.38–6.57x |
| CsPbI3 | Complete SCF + forces + stress | 424.48–426.14 | 407.10–414.09 | 1.03–1.04x |

Ranges cover two paired runs in separate allocations; speedups are computed within each pair.

## Radial table construction

| System | Stage | Baseline (s) | This PR (s) | Paired speedup |
| --- | --- | ---: | ---: | ---: |
| Si32 | RI initialization | 6.52–7.15 | 1.34–1.41 | 4.86–5.09x |
| Si32 | Complete SCF + forces + stress | 182.22–203.71 | 181.38–187.34 | 1.00–1.09x |
| CsPbI3 | RI initialization | 343.48–344.15 | 14.73–15.38 | 22.33–23.37x |
| CsPbI3 | Complete SCF + forces + stress | 424.48–426.14 | 95.52–96.23 | 4.43–4.44x |

Ranges cover two paired runs in separate allocations; speedups are computed within each pair.

The radial result combines GPU batching and product preparation reuse. It does not isolate a GEMM kernel speedup. CPU full-table construction retains individual quadrature. Explicit device scratch is bounded at 160 MiB per rank, with the same maximum host staging, and released before SCF. CUDA context/library allocations and existing host tables are outside that bound.

Sampled total process GPU peaks (baseline / candidate): Si32: 442–450 / 460–462 MiB; CsPbI3: 438 / 530 MiB. Sampling interval: 0.5 s.

## Validation

Maximum differences across the 29 completed calculations are 2.2e-11 eV/atom, 2.3e-09 eV/Angstrom and 9.6e-09 kbar. These checks establish agreement with the baseline, not absolute force accuracy. All matched SCF iteration counts agree. Validation includes one-thread controls, CPU execution, a build with CUDA disabled, and complex tensors on a 2x1x1 k mesh with two MPI ranks/GPUs.

Focused CTest output is in `tests/`. CUDA checks run at one and four OpenMP threads, including actual execution of the GPU radial-table test. CPU-only combined checks also pass. For each standalone variant, the executable and its relevant target(s) were built with `cmake --build build --target ... --parallel 24`, then selected using `ctest --test-dir build -V -R ...`:

| Variant | CTest targets |
| --- | --- |
| Baseline / Libxc | `MODULE_HAMILT_XCTest_VXC` |
| Reuse | `MODULE_LCAO_integral_reuse` |
| Radial | `MODULE_LCAO_radial_tables`, `MODULE_LCAO_radial_tables_gpu` |
| Combined CUDA | All of the above |
| Combined CPU | All CPU targets above; executable `abacus_std_para` |

The branch adds no approximation or relaxed tolerance. Integral tests cover magnetic components, origin/cutoff behavior, high angular momenta, radial tiling and finite-difference gradients. The numerical audit requires energy differences <=1e-8 eV/atom, forces <=1e-6 eV/Angstrom and stress <=1e-5 kbar. All compared inputs/assets are identical within each matched pair. Portable INPUT paths differ from the original absolute paths, so their content hashes differ from the recorded execution hashes.
