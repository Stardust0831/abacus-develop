# SAI GPU self-hosted runner

The manual workflow in `.github/workflows/sai-gpu-full.yml` uses a per-user
project root. Set `SAI_PROJECT_ROOT` in the runner environment when needed, or
let the workflow use this portable default:

```text
$HOME/agent/abacus_sai_gpu_ci
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
features. It then runs the existing 11/12/13/15/16 GPU suites in a 4-GPU Slurm
job and the cuSolverMp RT-TDDFT smoke case in a separate 16-GPU job.

The system CUDA/NVHPC/NCCL roots are pinned by default. A runner administrator
may set `SAI_ALLOW_TOOLCHAIN_OVERRIDE=1` together with all three explicit roots
to qualify an equivalent installation. The same exact versions and required
NCCL symbol are checked before each build. Set `SAI_PROJECT_ROOT` in the runner
service environment to relocate the user-owned cache and per-attempt run trees.

Each Slurm submission records its job ID and final accounting state. Cancelling
the Actions step also cancels the associated pending or running Slurm job.

Do not enable automatic `pull_request` execution for this workflow. Keep it
manual and protect the `sai-gpu` GitHub environment with required reviewers.

The tested 0.9.0/0.9.1 archive binaries reference NCCL APIs that are absent
from NCCL 2.18.5. This workflow requires NVIDIA NCCL 2.29.3.
