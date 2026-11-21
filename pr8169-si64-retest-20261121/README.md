HSE06 Si64 retest on SAI 16V100, 2026-11-21: ten scientific runs and nine numerical comparisons pass. The baseline is built from ABACUS beta13 `4e9f1636b7ca` with CPU LibRI `b0eff7a` (header version 2.1.1).

| Component / s | beta13 baseline | beta13 + GPU libraries | PR, CPU LibRI | PR, GPU LibRI |
| --- | ---: | ---: | ---: | ---: |
| Electronic EXX | 359.895 | 26.295 | 104.265 | 24.980 |
| EXX forces | 398.015 | 29.105 | 115.645 | 28.020 |
| Remaining wall time | 84.920 | 30.265 | 32.680 | 32.600 |
| **Complete calculation** | 842.830 | 85.665 | 252.590 | 85.600 |

The beta13 baseline → experimental comparison is 9.84×; the same-PR CPU → GPU LibRI comparison is 2.95×. All timings include atomic forces. See [full report](BENCHMARK_REPORT.md), [per-run data](summary.csv), [comparisons](comparisons.csv), and [dependency provenance](baseline-libri-provenance.json).

Download [abacus-si64-symmetry-guard-retest-20261121.tar.gz](abacus-si64-symmetry-guard-retest-20261121.tar.gz) and extract it. It contains 490 files, including the original inputs, Si pseudopotential/orbitals, small outputs, scripts, build/CLI logs and preserved failed-attempt records. SHA256: `4ca994d552094f9e3180751b6572653798d1463ccec9c893c3308f5143fe5587`. [Manifest](raw-file-manifest.json) lists every included file and larger omissions; [verification](archive-verification.json) records payload checks and offline reanalysis.

From the extracted directory run `python3 analyze.py`, `python3 audit-assets.py`, `python3 verify-analysis.py`, and `python3 make-report.py`. Numerical tolerances and original data are unchanged. The companion report adds publication links and the baseline dependency identity to the original report inside the checked archive.

The executable is built at `f2667c6ee`; `853b1644e` changes documentation only. [Guard patch](guard.patch), [documentation follow-up](docs-followup.patch), [full original module build information](original-module-build-info.txt).
