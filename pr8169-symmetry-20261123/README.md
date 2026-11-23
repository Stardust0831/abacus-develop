# ABACUS #8169: GPU EXX symmetry validation

The PR accepts `device_exx gpu` with `symmetry 1`, including `exx_symmetry_realspace 1`. With the official LibRI v0.3.0.0 release, all 20 HSE calculations and all 18 energy/force/stress comparisons pass. The runtime rejection, restrictive INPUT help, rejection tests and installation warning have been removed or updated.

## Revisions and build

| Component | Revision / configuration |
| --- | --- |
| ABACUS tested commit | `fa1c75dcce0df12fe37267aed5ed2deef3fcaef0` |
| Integrated develop | `c46ae1ede78f266441255a81b20cb176b8c5f6e2` |
| LibRI, official v0.3.0.0 | `589f6f8c6df3916575a1ba41e840de919d40d345` |
| DDLA | `7c0ca08b4349a527cec2a0c0af7d1a1082bd38c7` |
| Toolchain | GCC 13.3.0, CUDA 12.9.1, Open MPI 5.0.10, CPU LibXC 7.0.0 |
| Runtime | SAI 16V100, one V100, one MPI rank, OMP=1, BLAS=1 |

ABACUS was built in Release mode with CUDA and GPU RI enabled, and the two INPUT targets plus RI workspace target were also built with CUDA/GPU RI disabled. Both standalone CMake consumers and the LibRI regression were built in Debug mode. No LibRI headers, dependency implementations or numerical tolerances were patched. The original DDLA v0.0.6 interface is incompatible; the DDLA revision above is the tested dependency.

The source manifest verifies 7,948 ABACUS/LibRI files before build and execution. Dependency files confirm that all actual RI consumers use the isolated official LibRI headers. The source archive has no Git metadata, so the executable prints commit `unknown`; its source manifest, candidate tree and binary digest identify the build:

```text
ABACUS binary SHA256
6245f1ad87366354fff89547dfb6c0af29f17f6563bfe8f0e53cd8f6ac722726
DDLA libddla.so SHA256
f359feda186e11fff4a87ad52aa2d39ee11d8e5d3ca3b619aec2eb18b11f53af
```

The ABACUS binary digest is unchanged before/after all calculations and the CLI recheck.

## Results

| Verification | Observed result |
| --- | --- |
| LibRI numerical symmetry regression | 456 CHECK, 38 PASS; exit 0 |
| LibRI symmetry callbacks | 31,104 label/sector/atom/cell combinations; exit 0 |
| INPUT and RI workspace tests, CPU build | 50/50 GoogleTests, 3/3 CTest targets; no skips |
| INPUT and RI workspace tests, GPU build | 52/52 GoogleTests, 3/3 CTest targets; no skips |
| Debug CMake consumers | CPU 1/1, GPU 1/1 |
| Direct `--check-input` | 8/8, unchanged inputs from the initial launcher attempt |
| `--version`, parameter help | Pass; help no longer reports a GPU symmetry restriction |
| Original Autotest cases | 12/12 calculations; 36 reference assertions per backend |
| Displaced Si2 supplement | 8/8 calculations; nonzero forces in all eight |
| Numerical comparisons | 10/10 CPU/GPU pairs, 8/8 real-space symmetry off/on pairs |
| Governance, changed-line formatting, whitespace | Pass |

The Si2 matrix covers real/complex EXX tensors, real-space reduction off/on and CPU/GPU RI on both original and displaced geometries (16 runs). Four additional water Gamma runs cover `nspin=1/2` with CPU/GPU RI. Every pair uses the same ABACUS executable and GPU Kohn–Sham solver; only `device_exx` selects the contraction backend.

All Si2 runs retain `symmetry 1`. The original geometry has 48 space-group operations, 3 irreducible k-points and 12 irreducible pair/cell entries. Moving the first Si fractional x coordinate from 0.125 to 0.135 gives 4 operations, 6 irreducible k-points and 22 entries. The displaced cases have maximum force component **2.9498564343 eV/Å**. Their comparisons use the displaced CPU results; the undisplaced Autotest reference is not applied to the displaced structure.

The raw outputs were parsed independently with decimal arithmetic. Maximum absolute differences:

| Comparison | ΔE (eV) | max component ΔF (eV/Å) | max component Δstress (kbar) |
| --- | ---: | ---: | ---: |
| CPU/GPU RI, 10 pairs | 7.958e-13 | 1.1e-9 | 3e-10 |
| Real-space symmetry off/on, 8 pairs | 6.821e-13 | 0 | 0 |
| Acceptance limit | 1e-7 | 1e-6 | 1e-5 |

Force and stress zeros mean agreement at the output precision of 10 decimal places. Original `result.ref`, thresholds and k-point files are unchanged. Effective INPUT settings, SCF convergence, normal completion and complete force/stress arrays were checked for every calculation. These results cover the listed small fixtures and one GPU/rank; they do not establish all materials or multi-GPU correctness and do not replace performance measurements.

## CLI launcher incident

The first eight `mpirun -np 1 ... --check-input` calls printed successful INPUT validation but returned launcher status 1. The existing `ReadInput::read_parameters` check-mode path calls `exit(0)` without MPI finalization (`source/source_io/module_parameter/read_input.cpp:276`), so Open MPI reports an improper exit. The initial runtime job therefore has Slurm state `FAILED`, even though its separate HSE driver passed. This path is unchanged by the PR.

Direct single-process invocation of the same binary and byte-identical INPUT/STRU/KPT files subsequently passed 8/8 checks, each requiring both exit 0 and the success message. Original failure logs and accounting are retained. No source change or launcher-error suppression was used for the recheck.

| Job | Purpose | State / elapsed |
| --- | --- | --- |
| 2737480 | Build, LibRI and CPU/GPU unit tests | COMPLETED / 11m11s |
| 2737883 | CMake consumers, initial CLI, HSE comparisons | FAILED (CLI launcher); HSE driver exit 0 / 2m49s |
| 2738086 | Direct CLI recheck | COMPLETED / 24s |

## Evidence and reproduction

- [Raw evidence archive](e2e-evidence.tar.gz), 638 files, 2,446,652 bytes; [checksum](e2e-evidence.tar.gz.sha256).
- [Machine-readable validation summary](validation-summary.json), [independent numerical audit](independent-audit.json), [E2E results](e2e-results.json) and [source revisions](provenance.json).
- [Full PR patch](abacus-pr.patch), [symmetry cleanup patch](symmetry-cleanup.patch) and [source manifest](source-manifest.json).
- [Build and test commands](build.sbatch), [runtime commands](run.sbatch), [HSE matrix driver](run-e2e.py), [direct CLI recheck](cli-singleton.sbatch), [raw-output audit](audit-results.py).

Archive SHA256: `41b27a5a760d2bb9d1d69d4adc0fa9474742d4b46123f62aa9f548624b5940fb`.

The archive contains the original calculation inputs and logs, unit-test XML, failed and successful CLI attempts, compiler/build/dependency records, and a SHA256 manifest of 637 payload files. ABACUS source and pseudopotential/orbital assets are identified by the exact commit and source manifest; build objects and the executable are excluded. Scripts retain the recorded dependency paths; set these to equivalent local installations when reproducing. Relevant commands include:

```sh
mpirun -np 1 --map-by ppr:1:node:pe=1 --bind-to core \
  build/libri/test_lri_gpu_symmetry -1 all all
build/libri/test_gpu_symmetry_filters
ctest --test-dir build/abacus -V --timeout 120 \
  -R '^(MODULE_IO_read_(input|item)_serial|MODULE_RI_exx_workspace)$'
ctest --test-dir build/cpu -V --timeout 120 \
  -R '^(MODULE_IO_read_(input|item)_serial|MODULE_RI_exx_workspace)$'
ctest --test-dir build/consumer-cpu -V
ctest --test-dir build/consumer-gpu -V
python3 run-e2e.py
python3 check-cli-singleton.py
```

Extract the archive into `evidence/` beside the supplied scripts and an ABACUS source copy at the tested commit, then run `python3 summarize-validation.py` and `python3 audit-results.py` for independent postprocessing.
