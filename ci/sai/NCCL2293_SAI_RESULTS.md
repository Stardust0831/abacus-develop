# SAI NCCL 2.29.3 rail-by-channel ABACUS result

Date: 2026-07-21 (Asia/Shanghai)

Fork branch: `ci/sai-nccl2293-module-20260721`

Workflow run:
<https://github.com/Stardust0831/abacus-develop/actions/runs/29808710549>

## NCCL provenance

SAI module `nccl/2.29.3-sai-cuda12.9` exports:

```text
/opt/devtools/nvidia/nccl_2.29.3_cuda12.9_sai_v2.29.3-1-sai.1
```

This is not a repackaged upstream binary. It derives from NVIDIA NCCL
`v2.29.3-1` and adds AI4SAI's operator-controlled, channel-aligned dual-rail
IB endpoint selection. The installed metadata records source commit
`1e7208856a8f9affc293d721d733205c86513ace`.

The SAI and NVHPC shared libraries are distinct:

```text
SAI SHA256:   5214425a13df30baf999864f3f06f925fcd36cf0441ac21e113f348d1f360d37
NVHPC SHA256: 5df5da4643fc80b37c882ca1958ba4b08a11cfe0c9b73557599f8b32d471e84b
```

The NCCL module conflicts with `nvhpc`. The test therefore loaded the regular
NVHPC/Open MPI toolchain and prepended the exact root exported by the NCCL
module. Build- and runtime-side checks rejected unresolved dependencies,
nonempty `LD_PRELOAD`, a different canonical NCCL path, a disabled IB path,
or an inactive rail policy.

## Validated stack

```text
cuSolverMp: 0.9.0.6427, official NVIDIA CUDA 12 archive
cuBLASMp:   0.9.1.3056, official NVIDIA CUDA 12 archive
NCCL:       SAI 2.29.3-1-sai.1
CUDA:       12.9.1
Open MPI:   5.0.10, SAI NVHPC 26.3 GNU build
ABACUS:     v3.11.0-beta6 branch checkout
```

Runtime evidence:

```text
NCCL_SAI_RAIL_BY_CHANNEL=1
SAI_NCCL_RUNTIME_VERIFIED=/opt/devtools/nvidia/nccl_2.29.3_cuda12.9_sai_v2.29.3-1-sai.1/lib/libnccl.so.2.29.3 rail_by_channel=1
```

`NCCL_IB_DISABLE` was unset. The installed ABACUS `ldd` resolved
`libcusolverMp.so.0` and `libcublasmp.so.0` to the official archives and
`libnccl.so.2` to the SAI root.

## Result

| Slurm job | Purpose | Node | State | Elapsed |
|---:|---|---|---|---:|
| 688469 | ABACUS rebuild | 16v100n14 | `COMPLETED 0:0` | 1:10 |
| 688471 | 16-rank RT-TDDFT, 4x4 grid | 16v100n24 | `COMPLETED 0:0` | 3:29 |

The existing `19_NO_O3_CUSOLVERMP_16GPU` case completed all three MD/electron
evolution steps. All four harness comparisons passed:

```text
etotref          -1336.999498209972
etotperatomref    -445.6664994033
totalforceref       11.627501
totalstressref      64.927558
```

ABACUS total time was 195.76 seconds. `Diag_CusolverMP_gvd` returned 10 times,
using 51.30 seconds in total. The runtime and case log contained zero matches
for NCCL WARN/ERROR, NULL communicator, UCX WARN, MPI abort, or undefined
symbol signatures.

## Controlled comparison

| NCCL path | IB | Rail policy | Node | Outcome |
|---|---|---|---|---|
| NVHPC upstream 2.29.3 | enabled | not implemented by binary | 16v100n21 | timed out after 15:04, job 688199 |
| NVHPC upstream 2.29.3 | disabled | not applicable | 16v100n21 | passed in 2:37, job 688225 |
| SAI 2.29.3-1-sai.1 | enabled | enabled | 16v100n24 | passed in 3:29, job 688471 |

The ABACUS version/configuration, MP library versions, MPI mapping, rank count,
matrix size, and case-file contents match the corrected upstream-NCCL
experiment. Both runs rebuilt ABACUS and the recorded binaries are not
byte-identical, while `Git Commit` is unavailable in their build information.
The scheduler-selected node also differs between the upstream failure and SAI
pass because this run deliberately did not pin a node.

## Strict interpretation

1. Directly proven: SAI NCCL 2.29.3-1-sai.1 with its rail-by-channel policy can
   complete this 16-GPU ABACUS RT-TDDFT case over the IB-enabled configuration
   on `16v100n24`, with all numerical checks passing.
2. The result is consistent with the hypothesis that the SAI endpoint-selection
   change avoids the IB-dependent timeout observed with NVHPC's upstream NCCL
   2.29.3 on `16v100n21`; the logs do not directly identify a cross-NVLink-group
   communication failure.
3. Not proven: the NCCL package is the sole causal difference, because the
   scheduler selected different nodes. A same-node or repeated multi-node
   A/B would be required for that stronger claim.
4. Not proven: the failure lies at a specific source line in NCCL, cuSolverMp,
   or cuBLASMp. These remain closed-library/application-stack observations.
5. The successful run does not establish a performance advantage. Its elapsed
   time must not be compared as a benchmark against the IB-disabled run without
   repeated, topology-controlled measurements.
