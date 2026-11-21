**ABACUS HSE06 Si64 benchmark audit — PASS — 2026-11-21**

The comparator `module` is the **baseline built from ABACUS beta13 (4e9f1636b7ca)** / **基于ABACUS beta13构建的基线**; tables abbreviate it as **beta13 baseline**. Precise executable, source and dependency provenance is recorded below.

There are 10/10 completed scientific run records, all retained in this report, including any failed checks. The complete analyzer reports 10/10 individual run checks passing and 9/9 numerical comparisons passing; the frozen-input, source and environment audit passes.

Current paired-node means reproduce the earlier approximately 10× full-build speedup: beta13 baseline 842.83 s → experimental build 85.66 s, **9.84×**. The current PR CPU/GPU backend comparison is **2.95×** (252.59 → 85.60 s). Beta13 baseline → current PR GPU is 9.85×. These are distinct comparisons: beta13 baseline → experimental includes build/dependency changes; beta13 baseline → PR additionally changes ABACUS source. Only pr_cpu → pr_gpu uses the same executable and dependencies with just device_exx changed.

**Current ideal-Si64 measurements, two repetitions per variant.** Each repetition is paired on one node; values are means with min–max ranges, in seconds. All wall times include the fresh GGA start, HSE SCF and forces.

| Variant | n | Electronic EXX mean [range] | EXX force mean [range] | Remainder mean [range] | Total wall mean [range] |
| --- | --- | --- | --- | --- | --- |
| beta13 baseline | 2 | 359.89 [359.71–360.08] | 398.01 [397.61–398.42] | 84.92 [84.05–85.79] | 842.83 [841.74–843.92] |
| experimental | 2 | 26.30 [23.86–28.73] | 29.11 [26.29–31.92] | 30.26 [28.56–31.97] | 85.66 [78.71–92.62] |
| PR CPU LibRI | 2 | 104.27 [104.09–104.44] | 115.65 [115.36–115.93] | 32.68 [32.36–33.00] | 252.59 [252.45–252.73] |
| PR GPU LibRI | 2 | 24.98 [24.55–25.41] | 28.02 [26.35–29.69] | 32.60 [31.85–33.35] | 85.60 [82.75–88.45] |

The sole additive partition is `wall = Exx_LRI::cal_exx_elec + Exx_LRI::cal_exx_force + remainder`. Electronic EXX runs during SCF; EXX forces run afterward. Remainder is subtraction from `/usr/bin/time` elapsed time and includes all other computation, setup and launcher/container overhead. ABACUS timers are printed to 0.01 s. The setup done before the timed mpirun command is excluded from this wall time and is visible in campaign start/end timestamps.

**Paired speedups and wall-time savings.**

| Comparison | 16v100n14 speedup / saved | 16v100n22 speedup / saved | Ratio of means / mean saved |
| --- | --- | --- | --- |
| beta13 baseline → experimental | 10.694× / 763.03 s | 9.112× / 751.30 s | 9.839× / 757.16 s |
| beta13 baseline → PR GPU LibRI | 10.172× / 758.99 s | 9.541× / 755.47 s | 9.846× / 757.23 s |
| PR CPU LibRI → PR GPU LibRI | 3.054× / 169.98 s | 2.854× / 164.00 s | 2.951× / 166.99 s |

| Comparison | Electronic EXX saved | EXX force saved | Remainder saved |
| --- | --- | --- | --- |
| beta13 baseline → experimental | 333.60 s (44.06%) | 368.91 s (48.72%) | 54.65 s (7.22%) |
| beta13 baseline → PR GPU LibRI | 334.91 s (44.23%) | 370.00 s (48.86%) | 52.32 s (6.91%) |
| PR CPU LibRI → PR GPU LibRI | 79.28 s (47.48%) | 87.62 s (52.47%) | 0.08 s (0.05%) |

Percentages refer to the total wall saving; a negative component indicates time increased. The ratio of means is reported separately from the two node-paired ratios.

**Nested timing diagnostics, means in seconds. These overlap the additive partition and must not be added to it.**

| Variant | SCF parent | All-force parent | LCAO solver | LibXC potential | Effective potential | EXX ion setup |
| --- | --- | --- | --- | --- | --- | --- |
| beta13 baseline | 423.26 | 403.55 | 31.09 | 20.25 | 30.35 | unavailable |
| experimental | 46.25 | 30.62 | 7.99 | 4.03 | 10.16 | 2.42 |
| PR CPU LibRI | 126.24 | 117.64 | 6.55 | 8.16 | 13.70 | 2.60 |
| PR GPU LibRI | 46.98 | 29.89 | 6.59 | 8.18 | 13.70 | 2.65 |

Timer names are respectively `ESolver_KS::scf_loop`, `ESolver_KS_LCAO::cal_force`, `HSolverLCAO::solve`, `XC_Functional_Libxc::v_xc_libxc`, `Potential::cal_veff`, and `Exx_LRI::cal_exx_ions`. `Potential::update_from_charge` is a function/title, not the effective-potential timer. ABACUS suppresses timers smaller than 1% of total runtime; an absent diagnostic is unavailable, never zero. Solver and LibXC differences between builds cannot be assigned wholly to EXX acceleration.

**All requested run statuses: eight ideal runs and two displaced force checks.** Detailed force vectors, settings, hashes and every check are in `summary.json`, `analysis.json` and `asset-environment-audit.json`; `summary.csv` contains all timing columns.

| Job / block | Structure / variant | Wall s | Electronic / force EXX s | GGA + HSE iterations | Final density residual | Total energy eV | Energy eV/atom | Run checks |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2670088 / 0 (16v100n14) | ideal / beta13 baseline | 841.74 | 360.08 / 397.61 | 12 + 8 | 6.56734e-09 | -7244.018052984140 | -113.187782077877 | PASS |
| 2670088 / 0 (16v100n14) | ideal / experimental | 78.71 | 23.86 / 26.29 | 12 + 8 | 6.56521e-09 | -7244.018053122975 | -113.187782080046 | PASS |
| 2670088 / 0 (16v100n14) | ideal / PR CPU LibRI | 252.73 | 104.44 / 115.93 | 12 + 8 | 6.567e-09 | -7244.018052984155 | -113.187782077877 | PASS |
| 2670088 / 0 (16v100n14) | ideal / PR GPU LibRI | 82.75 | 24.55 / 26.35 | 12 + 8 | 6.56628e-09 | -7244.018052984093 | -113.187782077876 | PASS |
| 2670089 / 1 (16v100n22) | ideal / PR GPU LibRI | 88.45 | 25.41 / 29.69 | 12 + 8 | 6.56664e-09 | -7244.018052984140 | -113.187782077877 | PASS |
| 2670089 / 1 (16v100n22) | ideal / PR CPU LibRI | 252.45 | 104.09 / 115.36 | 12 + 8 | 6.56706e-09 | -7244.018052984151 | -113.187782077877 | PASS |
| 2670089 / 1 (16v100n22) | ideal / experimental | 92.62 | 28.73 / 31.92 | 12 + 8 | 6.56368e-09 | -7244.018053122973 | -113.187782080046 | PASS |
| 2670089 / 1 (16v100n22) | ideal / beta13 baseline | 843.92 | 359.71 / 398.42 | 12 + 8 | 6.56688e-09 | -7244.018052984137 | -113.187782077877 | PASS |
| 2670638 / 1 (16v100n13) | displaced / PR CPU LibRI | 325.13 | 163.15 / 120.49 | 12 + 12 | 9.742e-09 | -7244.012644084922 | -113.187697563827 | PASS |
| 2670638 / 1 (16v100n13) | displaced / PR GPU LibRI | 112.61 | 40.61 / 30.93 | 12 + 12 | 9.742e-09 | -7244.012644084925 | -113.187697563827 | PASS |

Each run is required to have exit code 0 in both the shell and time record, a converged SCF with final density residual ≤1e-8, a normal end marker, finite total energy, nonzero finite EXX energy, 64 finite force vectors and EXX electronic/force timers. Iterations are counted separately before and after the HSE transition; both the launcher and detailed SCF logs are checked.

**Numerical comparisons with the original thresholds, without reference changes.** Cross-build comparisons use the beta13 baseline on the same node: |ΔE|/64 ≤1e-6 eV/atom and max per-atom force-vector norm |ΔF| ≤1e-5 eV/Å. Same-PR CPU/GPU comparisons require ≤1e-8 eV/atom and ≤1e-6 eV/Å. Force-vector deltas are Euclidean norms, not maximum components.

| Block / structure | Comparison | \|ΔE\| total eV | \|ΔE\| eV/atom | max \|ΔF\| eV/Å | Energy / force result |
| --- | --- | --- | --- | --- | --- |
| 0 / ideal | beta13 baseline → experimental | 1.38835e-07 | 2.1693e-09 | 1.27279e-09 | PASS / PASS |
| 0 / ideal | beta13 baseline → PR CPU LibRI | 1.45519e-11 | 2.27374e-13 | 2.23607e-10 | PASS / PASS |
| 0 / ideal | beta13 baseline → PR GPU LibRI | 4.72937e-11 | 7.38964e-13 | 4.58258e-10 | PASS / PASS |
| 0 / ideal | PR CPU LibRI → PR GPU LibRI | 6.18456e-11 | 9.66338e-13 | 3.16228e-10 | PASS / PASS |
| 1 / displaced | PR CPU LibRI → PR GPU LibRI | 3.63798e-12 | 5.68434e-14 | 1.41421e-10 | PASS / PASS |
| 1 / ideal | beta13 baseline → experimental | 1.38835e-07 | 2.1693e-09 | 1.27279e-09 | PASS / PASS |
| 1 / ideal | beta13 baseline → PR CPU LibRI | 1.36424e-11 | 2.13163e-13 | 2.23607e-10 | PASS / PASS |
| 1 / ideal | beta13 baseline → PR GPU LibRI | 2.72848e-12 | 4.26326e-14 | 3.16228e-10 | PASS / PASS |
| 1 / ideal | PR CPU LibRI → PR GPU LibRI | 1.09139e-11 | 1.7053e-13 | 1.41421e-10 | PASS / PASS |

| Structure | Variant | Block | Maximum force norm eV/Å |
| --- | --- | --- | --- |
| ideal | beta13 baseline | 0 | 1.10709e-05 |
| ideal | experimental | 0 | 1.10716e-05 |
| ideal | PR CPU LibRI | 0 | 1.10708e-05 |
| ideal | PR GPU LibRI | 0 | 1.10707e-05 |
| ideal | PR GPU LibRI | 1 | 1.10707e-05 |
| ideal | PR CPU LibRI | 1 | 1.10707e-05 |
| ideal | experimental | 1 | 1.10716e-05 |
| ideal | beta13 baseline | 1 | 1.10707e-05 |
| displaced | PR CPU LibRI | 1 | 0.398013 |
| displaced | PR GPU LibRI | 1 | 0.398013 |

All completed calculations use `symmetry -1`; the generated inputs confirm `exx_symmetry_realspace 0`. This respects the current GPU LibRI path supported by the PR and avoids relying on symmetry to make a force check look trivial. Ideal Si64 has small numerical residual forces. The separate displaced structure moves only the first Si by (+0.01, +0.02, −0.015) Å, verified from the original fractional coordinates. The maximum force must exceed 1e-3 eV/Å in both PR runs; both measured values are 0.398013 eV/Å. This tests nontrivial forces with one CPU/GPU repetition; the displaced pair has no beta13-baseline comparator in this campaign. No claim is made here about symmetry=1 support.

**Failed checks in the final scientific validation:** none. Earlier driver failures remain in the preserved audit and attempt records.

**Original campaign failure and recovery:** job 2670089 exited 1 after the eight ideal runs had finished. The driver asserted that the displaced original INPUT must contain `ks_solver cusolvermp`, but that frozen INPUT contains `ks_solver elpa`; neither displaced executable was launched in that allocation. `audit/campaign-failure.json`, the original log and `audit/pre-recovery-analysis.json` retain this failed full-benchmark check. The coordinator authorized only the two missing displaced calculations after correcting the harness. Mistaken recovery allocation 2670593 initially dropped the recovery flag in the batch wrapper and began an unintended ideal repetition; it was cancelled after identity verification, and all of its inputs and outputs are retained under `attempts/`, excluded by explicit design from the ten-run sample. The wrapper was then corrected to forward all arguments, and the two-request recovery plan was verified before replacement submission.

Replacement recovery allocation(s): 2670638. Both requested displaced records are now included in the final ten-run analysis; their numerical outcome is reported above.

**Jobs, hardware and dataset.**

| Job | State | Exit | Node | Start | End | Elapsed |
| --- | --- | --- | --- | --- | --- | --- |
| 2670088 | COMPLETED | 0:0 | 16v100n14 | 2026-11-21T13:16:47 | 2026-11-21T13:38:18 | 00:21:31 |
| 2670089 | FAILED | 1:0 | 16v100n22 | 2026-11-21T13:16:47 | 2026-11-21T13:38:30 | 00:21:43 |
| 2670593 | CANCELLED by 1478400690 | 0:0 | 16v100n15 | 2026-11-21T13:42:50 | 2026-11-21T13:44:38 | 00:01:48 |
| 2670638 | COMPLETED | 0:0 | 16v100n13 | 2026-11-21T13:45:50 | 2026-11-21T13:53:26 | 00:07:36 |

Benchmark jobs 2670088 (block 0) and 2670089 (block 1) were allocated on partition `16V100`, each with a one-hour limit, one Tesla V100-SXM2-16GB, one MPI rank, four OpenMP threads and BLAS thread count one. Both hosts have an AMD Ryzen Threadripper PRO 5995WX (64 physical cores, two SMT threads/core). Slurm allocates eight logical CPUs per GPU; `mpirun --map-by ppr:1:node:pe=4 --bind-to core` exposes four core pairs. The archived rank-placement probes and runtime thread summaries agree with this configuration; individual OpenMP thread scheduling was not sampled. The nodes were not requested exclusively. Raw `lscpu`, `nvidia-smi -q`, Slurm allocation, module, affinity and shared-library records are included.

Slurm times and campaign timestamps are Asia/Shanghai. The container’s internal text timestamps can be UTC, so elapsed `/usr/bin/time` values are used for timing. The scheduler start precedes the Python campaign START record by about one second. Block 0 runs beta13 baseline → experimental → pr_cpu → pr_gpu; block 1 reverses that ideal order. The displaced CPU → GPU pair retains logical block 1 but runs together in separate recovery allocation 2670638 on 16v100n13; it is not pooled with ideal timings. The ideal comparison therefore uses two independent nodes and both execution orders, but only two repetitions and no statistical confidence interval.

The frozen dataset is Si64 in a 10.862 Å cubic cell, 832 LCAO basis functions, the APNS efficiency `Si_gga_7au_100Ry_2s2p1d.orb` orbital and `Si.upf`, Γ-only, double precision, 128 bands, 100 Ry, HSE06 (25% exact exchange, erfc ω=0.11), `scf_thr 1e-8`, `exx_separate_loop 0`, RI screening thresholds 1e-4, fresh atomic charge starts, forces on and stress off. Original input files come from `hse06-gpu-libs-20261120/inputs/{abacus-si64-cusolvermp-loop0,abacus-si64-displaced-normal}`. Ideal inputs transform `ks_solver cusolvermp` → `cusolver`; displaced inputs transform their original `ks_solver elpa` → `cusolver`, plus the PR `device_exx` selector. All original assets and these exact input transformations were checked byte-for-byte with hashes. The unchanged frozen INPUT files are separately archived.

| Asset | SHA256 |
| --- | --- |
| Si.upf | f7e77a752acc9d9a66409715ed5454752aa1ce6dad7d924cab3246fd30a3daec |
| Si_gga_7au_100Ry_2s2p1d.orb | 20ecb1f5b75f80065a5f47157d0024974cf6df1f035336ed192de2cb42521249 |

**Executable and source provenance.**

| Variant | ABACUS source / dependency scope | Executable or image SHA256 |
| --- | --- | --- |
| beta13 baseline | beta13 4e9f1636b7ca27d1dc634711915c18087654b911; original SAI container, CPU LibRI b0eff7ad70ab (header version 2.1.1), CPU LibXC 7.0.0 | a085b32d873f6815e28e39342ad4fbcdf245c0488c2eec24ad9ff161a82ba531 (SIF image) |
| experimental | beta13 base source with recorded integration patch; GPU LibRI 0e8afc3931ee4cdf564699811ca220215570dd6b and GPU LibXC 3c7794c5047d5f19c088b856b24879ac7174ddfe | c4d2155489301a4d7a5bdd25e8da41d967a8b285b024bcfe9990c3825279a023 |
| pr_cpu / pr_gpu | f2667c6eed30e661a36bfb0ae1844802c99f171e; released LibRI v0.3.0.0 and CPU LibXC 7.0.0; only device_exx changes | 7a008e1274516d1c7d592c73bddd8afd24886bde147197dec7e96f9df2de0e64 |

Native builds use DDLA `7c0ca08b4349a527cec2a0c0af7d1a1082bd38c7`. The PR binary was built in existing job 2670062; CPU/GPU input unit-test logs (33/33 each), eight CLI guard cases (8/8), compile/link logs, CMake caches, source guard.patch and the beta13 baseline build information are archived. All 7,693 tracked remote PR source files were checked against pinned commit f2667c6: 7,690 are byte-exact Git blobs and three Windows .bat files match after the CRLF checkout conversion explicitly required by .gitattributes. The actual SIF image was hashed and matches its catalog; both native executables were rehashed. Earlier source-verification records retained in provenance describe an older commit and are explicitly superseded by this campaign’s full-tree audit. A later coordinator docs-only commit does not change the executable identity reported here.

**Historical approximately 10× result, context only.** These are the earlier measurements, not repetitions from the current jobs, and are not pooled with the current sample.

| Historical variant | n | Wall mean [range] s | Electronic EXX s | EXX force s | Remainder s | LibXC s | Solver s |
| --- | --- | --- | --- | --- | --- | --- | --- |
| beta13 baseline | 2 | 852.13 [850.56–853.70] | 364.28 | 402.31 | 85.54 | 20.94 | 29.55 |
| historical experimental | 2 | 84.50 [80.07–88.92] | 25.89 | 28.30 | 30.31 | 4.19 | 6.30 |

Historical wall speedup is 10.08×. Beta13-baseline repetitions came from job 2652177; experimental repetitions came from jobs 2655071 and 2655265. The experimental binary is identical to the one used now. Source records and historical timer rows are included under `historical/`; the current paired-node measurements are the evidence for this retest. Both historical and current beta13 baseline → experimental comparisons include compiler/build/dependency changes, so neither establishes an isolated 10× LibRI backend effect.

**Analysis changes and collection.** `audit/analyze-before.py` and `audit/collect-before.py` retain the supplied scripts. The revised analyzer corrects the effective-potential label, records all comparisons before returning a failure status, checks finite energies/forces and exact residuals, checks original hashes and runtime settings, reports sample ranges and retains all timings independently of numerical acceptance. Optional suppressed diagnostics remain null. The original numerical tolerances and reference inputs are unchanged. `audit-assets.py` independently checks frozen inputs, dependency links, geometry, source and recorded environment. The campaign recovery changes normalize only the solver line, select only the two displaced requests and forward all batch arguments; original harness versions and the plan check are archived. The eight original ideal measurements, executables, builds and application source were not changed.

The archive `abacus-si64-symmetry-guard-retest-20261121.tar.gz` contains all raw run inputs/assets and every task output ≤10 MiB, plus scripts, frozen originals, build/test/CLI logs and provenance. `raw-file-manifest.json` records paths, sizes and SHA256 hashes; larger omitted files have size/hash/reason entries. Wavefunctions, executables, build intermediates, coordinator PR drafts and worker task specifications are excluded. CLI PP_ORB symlink dependencies are materialized under `cli-assets/PP_ORB`; the original symlink is recorded without archiving it. The manifest intentionally does not hash itself. `archive-receipt.json` and `archive.sha256` are external companion receipts, avoiding a circular archive checksum. The collector verifies every archived member and payload hash before reporting success; local transfer verification is recorded separately.

Local task: `/home/stardust/orca/workspaces/sai-hpc-software/cp2k/.work/abacus-libri-symmetry-benchmark-20261121`. Remote task: `/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-symmetry-benchmark-20261121`. To reproduce analysis on an extracted archive: `python3 analyze.py`, then `python3 audit-assets.py` and `python3 make-report.py`. The remote-only `capture-provenance.py` reads existing sources/build metadata; it does not launch computations.

Publication links: [abacus-si64-symmetry-guard-retest-20261121.tar.gz](abacus-si64-symmetry-guard-retest-20261121.tar.gz), [issue #52](https://github.com/Stardust0831/abacus-develop/issues/52), [ABACUS #8169](https://github.com/deepmodeling/abacus-develop/pull/8169).

Supplemental baseline identity: [baseline-libri-provenance.json](baseline-libri-provenance.json). The archived report remains the original worker output; these companion additions do not change raw measurements or the archive checksum.
