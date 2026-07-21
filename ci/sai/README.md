# SAI GPU self-hosted runner

The workflow in `.github/workflows/sai-gpu-full.yml` uses a per-user project
root on storage shared by the login and compute nodes. Configure the
`SAI_PROJECT_ROOT` environment variable in the runner service, or set the
same-named GitHub repository variable for each runner installation:

```text
/user-selected/shared/path/abacus_sai_gpu_ci
```

The workflow caches official NVIDIA archives in the project root, verifies
their pinned SHA256 values, and extracts a private copy for each run attempt:

```text
cuSolverMp 0.9.0.6427 (CUDA 12)
cuBLASMp 0.9.1.3056 (CUDA 12)
```

The archive profile uses NVIDIA NCCL 2.29.3 from the NVHPC 26.3 module stack.
All user-owned paths are derived from `HOME`, `GITHUB_WORKSPACE`, the project
root, and the GitHub run ID. A second user on the same cluster can run the
workflow without editing scripts or copying another user's toolchain file.

The build intentionally disables DeePMD, Torch/DeepKS, PEXSI, DFT-D4, LibRI,
NEP, and cnpy because the selected GPU suites do not exercise those optional
features. It assigns every listed 11/12/13/15/16 GPU case to exactly one
Slurm-array task. Resource-homogeneous arrays cover one 1-GPU case, seven
2-GPU cases, and forty 4-GPU cases. The arrays run concurrently with throttles
that cap their peak allocation at 25 GPUs. After the build succeeds, all three
arrays and a separate 2-node, 8-rank cuSolverMp RT-TDDFT smoke job are submitted
concurrently. The 1/2-GPU arrays use `flood-1o2gpu`; the 4-GPU array and the
multinode job use `flood-gpu`.

Each array task uses an isolated work directory and writes an atomic status
record. The coordinator turns those records into a 48-row GitHub step summary
and emits an Actions error annotation for every failed or missing case. This
keeps Slurm parallelism while making the exact failing test visible without
opening a combined suite log. A status is accepted only when its result agrees
with the corresponding terminal Slurm state and exit code.

SAI accepts `--export=ALL` for these arrays but cancels jobs submitted with
assignment-bearing `--export=...,NAME=value` forms. The coordinator exports the
per-array manifest and body paths in its own environment before each submission.
It keys accounting by Slurm's logical array `JobID` (`parent_task`), since SAI
assigns a separate numeric `JobIDRaw` to each array element.

Runtime placement follows SAI's `/opt/sbatch_examples/gpu_abacus.sbatch`
baseline: each job sources the partition-specific `mps_mapping.d` script and
uses its `MAP_OPT` and `OMP_NUM_THREADS` values. Test-harness launches use a
thin `mpirun` wrapper that adds the example's exact `--map-by "$MAP_OPT"`
argument before forwarding the harness arguments. The validation scripts do not
override NCCL's IB selection. The intended experimental differences from the
SAI example are the freshly built ABACUS executable and the pinned newer
cuSolverMp/cuBLASMp/NCCL toolchain. Each test job records the effective UCX/Open
MPI/NCCL environment and the RDMA devices visible on its compute node.

The system CUDA/NVHPC/NCCL roots are pinned by default. A runner administrator
may set `SAI_ALLOW_TOOLCHAIN_OVERRIDE=1` together with all three explicit roots
to qualify an equivalent installation. The same exact versions and required
NCCL symbol are checked before each build. `SAI_PROJECT_ROOT` relocates the
user-owned cache and per-attempt run trees without changing repository files.

Each Slurm submission records its job ID and final accounting state. Cancelling
the Actions step signals both coordinators, which cancel their associated
pending or running Slurm jobs. Normal CI does not pin particular node names or
expose an IB-disable input.

Do not enable automatic `pull_request` execution for this workflow. It supports
protected manual dispatches and a weekly default-branch schedule. Protect the
runner through repository permissions. If the `sai-gpu` environment requires
reviewers, scheduled runs will wait for that approval as well.

The tested 0.9.0/0.9.1 archive binaries reference NCCL APIs that are absent
from NCCL 2.18.5. This workflow requires NVIDIA NCCL 2.29.3.

The `archive-mp09-sai-nccl2293` profile is a controlled alternative that uses
the exact library root exported by SAI's `nccl/2.29.3-sai-cuda12.9` module.
That module conflicts with `nvhpc`, so the profile loads the NVHPC/Open MPI
toolchain and prepends the module's NCCL root directly. The SAI build derives
from NVIDIA NCCL 2.29.3 but adds an operator-controlled dual-rail endpoint
policy; it is not an unmodified NVIDIA binary. Validation must confirm both
the resolved `libnccl.so.2` path and `NCCL_SAI_RAIL_BY_CHANNEL=1` at runtime.
The profile explicitly enables that policy, rejects inherited `LD_PRELOAD`,
requires IB to remain enabled, and ignores node-selection/IB-disable workflow
inputs so the A/B control cannot be dispatched with those confounders.
