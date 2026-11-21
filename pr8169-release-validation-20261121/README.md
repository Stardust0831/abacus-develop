# LibRI release validation for ABACUS #8169

Validated ABACUS `64b7ef6133bf1f36de2b87276889e67b5245177c` with LibRI `v0.3.0.0` (`a385ac9b1d04c151f26f9d14cc0c2588f96557ab`), CUDA DDLA `7c0ca08b4349a527cec2a0c0af7d1a1082bd38c7`, and the standard CPU LibXC 7.0.0 module on SAI `16V100`, 2026-11-21. GCC 13.3, CUDA 12.9 and Open MPI 5.0.10; runtime `OMP_NUM_THREADS=1` and BLAS threads = 1.

The GPU RI path rejects `symmetry 1` with `exx_symmetry_realspace 1`. Use `exx_symmetry_realspace 0` for GPU RI while retaining k-point symmetry. CPU RI can use real-space EXX symmetry. This guard addresses an observed error in the released dependency; it does not modify LibRI's numerical implementation.

| Verification | Result |
| --- | --- |
| Full GPU executable | Build and CLI help/version passed |
| Serial INPUT suite in CPU/GPU configurations | 33/33 passed in each |
| CLI acceptance and rejection | 6/6 passed, including implicit symmetry defaults |
| Dependency consumers and signed real/complex GPU accumulation | 4/4 CTest checks passed; old LibRI rejected for GPU |
| Supported HSE cases | 10/10 runs passed repository references; 5/5 CPU/GPU backend comparisons passed |
| Changed-file formatting and full PR Governance check | Passed |

The HSE matrix covers Gamma, spin polarization, real/complex RI, one/two MPI ranks, nonzero forces, and k-point symmetry with real-space EXX symmetry disabled. Both backends use the same GPU executable with `device gpu` and `ks_solver cusolver`; only `device_exx` selects CPU/GPU RI. All runs compute forces and stress. Maximum differences: energy `2.10321e-12 eV`, force component `4e-10 eV/Angstrom`, stress component `9.99876e-11 kbar`. Limits are `1e-7 eV`, `1e-6 eV/Angstrom`, and `1e-5 kbar`; no repository references or tolerances were relaxed. Separate full CPU application, multi-node, SOC, and long MD validation are not part of this release check.

## Reproduced symmetry regression

At the preceding ABACUS commit `c1d3b81e97f7fcd4d4fafd0d65416fa227151a81`, 12 HSE runs completed. The four pairs without real-space EXX symmetry agreed. Both Si2 pairs with that symmetry enabled failed: real and complex GPU contractions differed from CPU RI by `0.032459305870816 eV` in total energy and `0.3058679098 kbar` in a stress component. Forces vanish in this symmetric fixture. See `symmetry-regression.json` and the raw `hse/` directories. These failures are retained as negative evidence, and are not included in the final 10-run acceptance count.

The LibRI release's independent GPU symmetry fixture also fails. Its original test directly constructs the CPU filter and reports a GPU block-count mismatch. `libri-symmetry-fixture.patch` changes only its include/constructor to the public `Filter_Atom_Symmetry_Wrapper`, matching `RI::Exx::set_symmetry`. The adapted test still fails real `a1b2_a2b1`, sector 1, GPU mode 2, element error `4.89589`. The independent test is **not passed**. All 118 released LibRI implementation headers were verified byte-for-byte against the release archive; only the standalone test fixture was adapted.

## Evidence and reproduction

`abacus-pr8169-release-validation-20261121.tar.gz` contains 537 files (1.99 MiB): the executed inputs, required pseudopotentials/orbitals, original small outputs, build/configuration logs, scripts, source verification, and numerical audits. `SHA256SUMS` verifies the archive; its internal manifest hashes the payload files. Executables, build intermediates and public dependency source trees are excluded. No calculation output exceeded the 10 MiB per-file limit.

- `hse-supported/`: the accepted final 10-run matrix.
- `cli/`: six final CLI cases, including expected rejections.
- `hse/`: the 12 completed runs exposing the dependency symmetry regression before the guard.
- `logs/symmetry-unadapted-fixture-failed.log` and `logs/symmetry-test.log`: both failed independent LibRI checks.
- `hse-incompatible-gpu-libxc/`: an initial harness attempt using the separate experimental GPU LibXC 7.1.2 installation. Those six runs aborted on host-pointer handling and are excluded from acceptance. The final build uses standard CPU LibXC 7.0.0.

Build the final ABACUS commit with `ENABLE_LIBRI=ON`, `USE_CUDA=ON`, `ENABLE_LIBRI_GPU=ON`, the pinned released LibRI headers, and compatible CUDA DDLA. The original DDLA v0.0.6 release has an incompatible API. `validate.sbatch` records the exact cluster build settings; its `application` argument runs the application checks independently of the known failing LibRI symmetry fixture. `hse.sbatch`, `check-input.py` and `run-hse.py` reproduce the final acceptance matrix. Paths in the batch scripts refer to the recorded SAI installation and can be replaced with equivalent dependency installations.

To reproduce the numerical regression, use the pre-guard ABACUS commit and `run-hse-before-symmetry-guard.py` with standard CPU LibXC; the driver intentionally stops when the repository reference check fails. `analyze-regression.py` independently audits its completed runs. These data are correctness checks, not new performance measurements.
