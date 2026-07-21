# SAI NCCL 2.29.3 full GPU integration results

Date: 2026-07-21

This report records a fresh ABACUS rebuild and every explicit `device gpu`
integration input currently present on branch
`ci/sai-nccl2293-module-20260721`. It does not claim CUDA source-line
coverage, and it excludes optional DeePMD/ML dependencies that are disabled in
the selected build profile.

## Toolchain

The build used:

- cuSolverMp 0.9.0.6427 from the NVIDIA CUDA 12 archive;
- cuBLASMp 0.9.1.3056 from the NVIDIA CUDA 12 archive;
- CUDA 12.9.1;
- Open MPI 5.0.10;
- SAI NCCL 2.29.3 at
  `/opt/devtools/nvidia/nccl_2.29.3_cuda12.9_sai_v2.29.3-1-sai.1`.

`NCCL_SAI_RAIL_BY_CHANNEL=1` was active. `NCCL_IB_DISABLE` was not set.
The build and test scripts verified that the runtime loaded
`libnccl.so.2.29.3` from the SAI root above. No node was pinned. All jobs were
single-node, so this run does not directly demonstrate which NCCL transport
carried intra-node traffic and does not exercise multi-node IB communication.

GitHub Actions run:
<https://github.com/Stardust0831/abacus-develop/actions/runs/29810162734>

The Actions conclusion is `failure`, as expected from the SDFT BPCG numerical
failure in its 48-case validation. Logs and artifacts were still uploaded.

## Evidence

The Actions artifact contains the build summary, `ldd`, main-suite output, and
16-rank output. Supplemental commands are preserved in:

- `ci/sai/diagnostics/test_gpu_supplement.sbatch`;
- `ci/sai/diagnostics/test_gpu_single.sbatch`;
- `ci/sai/diagnostics/test_sdft4_control.sbatch`.

The supplemental logs remain under
`$HOME/agent/abacus_sai_gpu_ci/runs/29810162734-1/results` on SAI. Operator
copies were checked against these SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `sai-gpu-full-688562.out` | `bcd214f85b8e451f7eefbae6a6eaa07d58d374c4fb4817c0b147679e6ac0e1be` |
| `sai-cusolvermp-688584.out` | `60bffbfbb8254d759635fe4131786cb75ca68a348df71d2557ca9511b8f10b1c` |
| `sai-gpu-supplement-688600.out` | `0c5ba17ba3bbbd9a7b7a4a64b451ae51bc041ff3cb9061a966299990967d9340` |
| `sai-gpu-single-688602.out` | `91ab152f74d51b9d883656fdc70cee84956000d5e8d411720d58f22a29df3767` |
| `sai-sdft4-688606.out` | `59664dbd184cb415cdcacb74c03d466b3336cf41081110cb2a02e9f65b2be54c` |
| `sai-ofdft-control-688608.out` | `f1242cfe73945faf491f2a6939b1f1d6b2ae9719028f776fffea14cbf5e344f9` |
| `toolchain-summary.txt` | `b13492ecd9343bbbf7e9c056a14ad7f8297fb0639b424019be79018c50d7051c` |
| `ldd.txt` | `7637d83526a5d71ebc3a0d8911c409bd736aa783d84fc680e96b9c73ae11365a` |

## Slurm jobs

| Job | Node | Elapsed | State | Purpose |
| ---: | --- | ---: | --- | --- |
| 688560 | 16v100n14 | 00:01:12 | COMPLETED 0:0 | Fresh ABACUS rebuild |
| 688562 | 16v100n14 | 00:09:58 | FAILED 1:0 | 48-case upstream-style GPU suite |
| 688584 | 16v100n26 | 00:03:29 | COMPLETED 0:0 | 16-rank cuSolverMp RT-TDDFT |
| 688600 | 16v100n04 | 00:00:18 | FAILED 1:0 | SDFT repeats and extra-case diagnostics |
| 688602 | 16v100n01 | 00:00:09 | FAILED 1:0 | One-rank OFDFT and nspin4 controls |
| 688606 | 16v100n04 | 00:00:04 | FAILED 1:0 | Four-rank SDFT topology control |
| 688608 | 16v100n01 | 00:00:22 | FAILED 1:0 | Matched CPU/GPU OFDFT control |

Failed diagnostic jobs intentionally return nonzero when any checked case
fails. Their individual outcomes are separated below.

## Coverage and results

The branch contains 51 inputs with an explicit `device gpu` setting. Fifty
have numerical references; `11_PW_GPU/BUG_nspin4_u` has no `result.ref` and can
only be treated as a runtime smoke test.

| Suite | Inputs | Numerical result |
| --- | ---: | --- |
| 11_PW_GPU listed cases | 7 | 7 passed |
| 12_NAO_Gamma_GPU | 16 | 16 passed |
| 13_NAO_multik_GPU | 3 | 3 passed |
| 15_rtTDDFT_GPU | 16 | 16 passed |
| 16_SDFT_GPU | 6 | 5 passed; BPCG case failed tolerance |
| 16-rank cuSolverMp RT-TDDFT | 1 | 1 passed |
| 07_OFDFT GPU extension | 1 | completed, but failed reference comparison |
| BUG_nspin4_u | 1 | one-rank smoke passed; no numerical reference |

The numerical total is 48 of 50 referenced GPU inputs passing. The unreferenced
nspin4 case completed its SCF run in the valid one-rank topology.

The 48-case main suite and the 16-rank cuSolverMp log contain zero matches for
`NCCL WARN`, `NCCL ERROR`, or a NULL `CommUserRank` communicator. The dedicated
16-rank case passed all four reference properties and printed:

```text
SAI_NCCL_RUNTIME_VERIFIED=/opt/devtools/nvidia/nccl_2.29.3_cuda12.9_sai_v2.29.3-1-sai.1/lib/libnccl.so.2.29.3 rail_by_channel=1
SAI_GPU_VALIDATION_PASSED profile=archive-mp09-sai-nccl2293
```

## SDFT BPCG numerical failure

`16_SDFT_GPU/005_PW_SDFT_MALL_BPCG_GPU` completed normally at two ranks, but
failed the default `1e-7` eV energy tolerance and the raw scalar
`totalstressref` tolerance of `0.001`. `Autotest.sh` defines these defaults; the
reference and extraction scripts do not state a physical unit or tensor norm
for `totalstressref`. The table therefore preserves the harness scalar rather
than assigning an unsupported unit. Deviations are `reference - calculated`.
Three fresh runs produced:

| Run | Node | Total-energy deviation (eV) | `totalstressref` scalar deviation |
| --- | --- | ---: | ---: |
| main suite | 16v100n14 | -0.00000066 | -0.033540 |
| repeat 1 | 16v100n04 | +0.00000673 | -0.021550 |
| repeat 2 | 16v100n04 | +0.00000145 | -0.028352 |

Force passed in all three runs. The changing printed values show that the
result is not repeatable at the reported precision. Three observations are not
a statistical characterization. A four-rank control is invalid for this input:
it exits before numerical work because some ranks receive zero k-points. This
result does not exhibit an NCCL communicator failure and does not by itself
identify whether the reference, tolerance, stochastic algorithm, or another
ABACUS component should change.

## OFDFT control

The one-rank GPU case `31_OF_KE_WT_GPU` completed, but returned
`-85.77846227` eV and a unit-unspecified `totalstressref` harness scalar of
`5623.746570`, versus references `-57.93385514` eV and `29.613417`. The matched
CPU case `09_OF_KE_WT`, whose input differs only by the absence of `device gpu`,
returned exactly the same energy and harness scalar as the GPU case and failed
the same reference comparison.

Therefore the mismatch is not specific to selecting `device gpu` in this
control and is not evidence of an SAI NCCL regression. The experiment does not
distinguish among a common build, dependency, runtime, environment, input,
implementation, or reference issue. The reference was not changed.

## Rank controls and submission behavior

The OFDFT input has one k-point and the nspin4 input has two k-points. Both exit
with `nks == 0` when launched at four ranks. At one rank, OFDFT reaches and
finishes its numerical calculation, and the nspin4 SCF smoke test completes.

No test script specified `--cpus-per-task`. The cluster assigned eight CPUs per
GPU automatically. Direct `sbatch` submissions whose SSH submitting process
exited were cancelled by UID 0 after two seconds (jobs 688590, 688593, 688594,
688595, and 688598). Keeping the SSH session alive through the existing
`run_slurm_job.sh` waiter allowed the same script and resources to execute as
job 688600. This is consistent with orphan-job cleanup tied to the submitting
session; it is not evidence of an ABACUS or explicit-CPU-request failure.

## Strict conclusion

1. The SAI NCCL 2.29.3 rail-by-channel stack builds ABACUS and passes all seven
   `11_PW_GPU`, all NAO Gamma, all NAO multik, and all existing RT-TDDFT GPU
   references exercised here, including the 16-rank cuSolverMp case without
   setting `NCCL_IB_DISABLE`. Actual IB transport use was not demonstrated.
2. The full GPU result is not completely green: one SDFT BPCG reference check
   fails reproducibly, and the added OFDFT check shares a larger failure with
   its matched CPU control.
3. These observations do not prove a source-line cause inside NCCL,
   cuSolverMp, cuBLASMp, or ABACUS. Optional DeePMD/ML GPU functionality and
   CUDA source-line coverage remain outside this run.
