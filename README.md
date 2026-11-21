# ABACUS GPU LibRI / LibXC: HSE06 input and output archive

Measurements: 2026-11-20/21, SAI 16V100. This data branch records the experimental CUDA LibRI/DDLA and LibXC integration and its energy/force benchmarks. Source identities are in [versions.json](versions.json); build instructions and integration patches are in [BUILD.md](BUILD.md) and [patches/](patches/).

The [complete results and configuration](RESULTS.md), [PR/backend timer analysis](TIMER_ANALYSIS.md) and [historical CP2K / old-new ABACUS analysis](HISTORICAL_TIMERS.md) show where time decreased. All accepted ABACUS cases disable crystal symmetry (`symmetry=-1`) and EXX real-space symmetry (`exx_symmetry_realspace=0`), with `gamma_only=1`, `cal_force=1`, and `cal_stress=0`. Main timings use ideal Si crystals; nonzero-force checks use the first Si atom shifted by (+0.01, +0.02, -0.015) angstrom. Symmetry-enabled application performance is not established.

## Downloads

| File | MiB | Contents |
| --- | ---: | --- |
| [libri-pr17-hse06-testcases.zip](archives/libri-pr17-hse06-testcases.zip) | 3.56 | Curated 56-run comparison, runnable cases and timer analysis |
| [raw-hse06-si-20261120.zip](archives/raw-hse06-si-20261120.zip) | 4.25 | Original inputs, outputs, build logs and campaign metadata |
| [raw-hse06-gpu-libs-20261120.zip](archives/raw-hse06-gpu-libs-20261120.zip) | 2.49 | Original inputs, outputs, build logs and campaign metadata |
| [raw-hse06-libri-pr17-20261121.zip](archives/raw-hse06-libri-pr17-20261121.zip) | 4.72 | Original inputs, outputs, build logs and campaign metadata |
| [cp2k-small-restarts-part01.zip](archives/cp2k-small-restarts-part01.zip) | 19.02 | CP2K wavefunction/restart outputs, each original file at most 10 MiB |
| [cp2k-small-restarts-part02.zip](archives/cp2k-small-restarts-part02.zip) | 13.34 | CP2K wavefunction/restart outputs, each original file at most 10 MiB |
| [cp2k-small-restarts-part03.zip](archives/cp2k-small-restarts-part03.zip) | 17.59 | CP2K wavefunction/restart outputs, each original file at most 10 MiB |
| [cp2k-small-restarts-part04.zip](archives/cp2k-small-restarts-part04.zip) | 20.87 | CP2K wavefunction/restart outputs, each original file at most 10 MiB |
| [cp2k-small-restarts-part05.zip](archives/cp2k-small-restarts-part05.zip) | 19.37 | CP2K wavefunction/restart outputs, each original file at most 10 MiB |
| [cp2k-small-restarts-part06.zip](archives/cp2k-small-restarts-part06.zip) | 22.36 | CP2K wavefunction/restart outputs, each original file at most 10 MiB |
| [cp2k-small-restarts-part07.zip](archives/cp2k-small-restarts-part07.zip) | 2.35 | CP2K wavefunction/restart outputs, each original file at most 10 MiB |

All ZIP files are independent archives, not byte-split volumes. Extract any raw archive into the same fresh directory to reconstruct `campaigns/<original-campaign-name>/...`. The small-restart ZIPs add the original CP2K wavefunctions to that layout; they are optional for rerunning from atomic/PBE initialization. Each raw ZIP has a FILE_SHA256SUMS covering its original payload. The curated ZIP extracts to `libri-pr17-hse06-testcases/` and contains its own README, runnable cases and verification scripts.

## Coverage

The expanded raw archive includes **2418 files**, covering **all 2345 files at most 10 MiB** in the inventoried remote `results/`, `logs/`, `inputs/`, `data/` directories and root log/metadata files. SHA256 was computed on the cluster and matched against each packaged remote file. Additional local reports, build/launch/analysis scripts, plots and provenance notes are included. Original output files are not edited.

The campaign parsers list 49 original-module/CP2K attempts, 13 GPU-library calculations, and 27 PR calculations. Those raw records include exploratory settings and unsuccessful/unconverged attempts. **Only 56 accepted comparison/validation calculations enter the curated package and reported performance comparisons.** A batch-driver failure is not silently converted to success: the three post-calculation failures remain in raw output and validation records.

The 41 small CP2K restart files are included in the separate ZIPs. The 55 larger ABACUS charge-density restarts (3.22 GiB in total) exceed the 10 MiB per-file cutoff and are listed individually in [the omission manifest](manifests/omitted-large-files.csv). Full executables, build objects and dependency source trees are outside the scientific-output archive; their pinned source revisions and build settings are recorded.

- [Archive SHA256 checksums](SHA256SUMS)
- [Per-file paths, sizes, hashes and archive membership](manifests/files.csv)
- [Cluster inventory with remote SHA256 checks](manifests/remote-small-files-sha256.json)
- [Machine-readable coverage](manifests/coverage.json)

## Inspect without launching calculations

After extracting the curated ZIP:

```bash
cd libri-pr17-hse06-testcases
sha256sum --check --quiet SHA256SUMS
python3 scripts/verify.py
python3 scripts/analyze-timers.py
python3 scripts/analyze-history.py
```

The original launch/build scripts and numerical logs are in the campaign ZIPs. Their paths and environment settings describe the measured SAI installation and need adaptation elsewhere. Archived reports retain some references to older campaign archives; the download table above and new manifests define this publication. Paths inside TIMER_ANALYSIS.md/HISTORICAL_TIMERS.md refer to the extracted curated package, with the principal tables/figures also available directly on this branch.

Cross-code CP2K/ABACUS equal accuracy is not established. The old/new ABACUS comparison contains dependency and build differences. Only the same-executable backend comparisons isolate CPU/GPU selection; only the fresh paired baseline is used to calculate PR #17 speedups.
