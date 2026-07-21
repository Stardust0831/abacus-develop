# SAI NVHPC 24.5 cuSolverMp/CAL control results

Date: 2026-07-21 (Asia/Shanghai)

Fork branch: `ci/sai-nvhpc245-cal-20260721`

ABACUS workflow run:
<https://github.com/Stardust0831/abacus-develop/actions/runs/29805516274>

## Validated stack

```text
CUDA:       12.4.1 (nvcc 12.4.131)
Open MPI:   5.0.8, SAI nvhpc24.5 GNU build
cuSolverMp: 0.5.0
CAL:        NVHPC 24.5 CUDA 12.4 target library
cuBLASMp:   0.2.0 (installed stack component; direct ABACUS support disabled)
NCCL:       2.18.5-1-sai.1 path exported by nccl/2.18.5-sai-cuda12.4
```

The cuSolverMp 0.5 ELF dependency list contains `libcal.so.0` and contains no
NCCL or cuBLASMp dependency. The rebuilt ABACUS binary likewise resolves
cuSolverMp and CAL, but not NCCL or cuBLASMp. NCCL 2.18.5 was present at its
exact module path and its symlinks were verified, but it is absent from the
recorded ELF/startup dependency closure. No evidence from these runs
shows NCCL participation, although `ldd` alone cannot exclude a later plugin
`dlopen`. This is a CAL/UCC/MPI control, not a direct test of cuSolverMp over
NCCL 2.18.5.

Current ABACUS directly supports cuBLASMp 0.8 or newer. The matched NVHPC 24.5
cuBLASMp 0.2 library was therefore recorded but `ENABLE_CUBLASMP=OFF` and
`ENABLE_NCCL_PARALLEL_DEVICE=OFF` were used for this build.

## Results

| Slurm job | Program | Ranks / grid | Node | Result | Elapsed |
|---:|---|---|---|---|---:|
| 688292 | ABACUS rebuild | 4 build tasks | 16v100n02 | `COMPLETED 0:0` | 1:07 |
| 688296 | ABACUS `19_NO_O3_CUSOLVERMP_16GPU` | 16 / 4x4 | 16v100n21 | `FAILED 1:0` | 0:23 |
| 688333 | NVIDIA sample build | 1 attached task / 1 GPU | 16v100n21 | `COMPLETED 0:0` | 0:10 |
| 688352 | NVIDIA `mp_sygvd` | 16 / 4x4 | 16v100n21 | `FAILED 124:0` (8-minute timeout) | 8:08 |
| 688374 | NVIDIA Release `mp_sygvd` | 4 / 2x2 | 16v100n21 | `COMPLETED 0:0` | 0:09 |
| 688391 | NVIDIA Debug sample build | 1 attached task / 1 GPU | 16v100n24 | `COMPLETED 0:0` | 0:15 |
| 688395 | NVIDIA Debug `mp_sygvd` | 4 / 2x2 | 16v100n24 | `COMPLETED 0:0` | 0:08 |

All three sample runs used `CUDA_R_64F`, `m=39`, row-major mapping, and square
block size 1. The sample source was the pre-NCCL NVIDIA implementation from
`NVIDIA/CUDALibrarySamples@4253515` (2024-11-04), which creates the official
CAL communicator callbacks.

### ABACUS 16-GPU result

ABACUS reached the first electronic evolution step. Its first
`cusolverMpSygvd()` call returned:

```text
CUSOLVER_STATUS_INTERNAL_ERROR (7)
```

No numerical comparison was reached.

### Official sample controls

The initial 4-rank Release sample returned normally with exit 0, but Release
uses `-DNDEBUG` and therefore compiles out NVIDIA's assertions. A second Debug
build used `CMAKE_C_FLAGS_DEBUG=-g` and no `NDEBUG`; job 688395 also returned
0. In that Debug control the NVIDIA assertions covering the
`cusolverMpSygvd()` status, CAL stream sync, CUDA stream sync, and device
`info == 0` were active and passed. The sample does not independently compute
a residual, so this is an API/status pass rather than a standalone numerical
accuracy result. Its complete transcript is archived at:

```text
~/agent/abacus_sai_gpu_ci/controls/cusolvermp050-official-20260721T1405/debug-4rank-transcript.log
```

During the attached 16-rank/4x4 run, the operator observed the following
UCC/CUDA cleanup errors after the sample entered the solve:

```text
TL_CUDA WARN cudaEventDestroy failed: 700 (cudaErrorIllegalAddress)
TL_CUDA WARN cudaStreamDestroy failed: 700 (cudaErrorIllegalAddress)
UCC ERROR cudaIpcCloseMemHandle(mapped_addr) failed: 700
```

The process then hung until the 8-minute command timeout. `sacct` independently
preserves job 688352 as `FAILED 124:0` after 8:08, and `run.sbatch` records the
timeout command. The quoted diagnostics and a GPU sample showing all 16 GPUs
at P0, 0% SM utilization, about 1.0-1.16 GiB allocated per GPU, and roughly
64-73 W draw are contemporaneous operator observations; the attached `srun`
transcript and telemetry were not written to a remote evidence file.

## Strict interpretation

1. A fully matched CUDA 12.4-era cuSolverMp 0.5/CAL stack can build current
   ABACUS, but the 16-GPU RT-TDDFT case does not pass.
2. The same Release sample binary exits 0 at 4 ranks and times out at 16 ranks;
   the separate assertion-enabled Debug 4-rank control also passes its API and
   status checks. The scale-dependent failure in completion behavior is
   therefore directly reproducible outside ABACUS.
3. NCCL is absent from the recorded startup dependency closures and there is
   no evidence it participates in these calls. This makes an ABACUS-only root
   cause unlikely for the cuSolverMp 0.5 result, but does not prove that CAL or
   UCC could not load an NCCL-related plugin later.
4. The evidence is consistent with a problem in the cuSolverMp 0.5/CAL/UCC
   CUDA-IPC stack or its interaction at 16 ranks. It does not identify which
   closed-source component or source line is responsible.
5. This does not prove that the separate cuSolverMp 0.7.2 NCCL-backend failure
   has the same root cause. The backend and observed failure signatures differ.
6. Block size 1 is a power of two. These controls do not match the known
   non-power-of-two STEDC block-size trigger.

The first workflow attempt, run 29805330627 / Slurm 688274, stopped before
configuration because Lmod read an unset `LD_LIBRARY_PATH` under `set -u`.
The profile now initializes loader/toolchain variables before sourcing Lmod;
the remote preflight and the subsequent full build both passed.
