# SAI GPU self-hosted runner

The workflow in `.github/workflows/sai-gpu-full.yml` expects a runner-local
project root. Set the repository variable `SAI_PROJECT_ROOT`, or let the
workflow use this default:

```text
$HOME/agent/abacus_sai_gpu_ci
```

The project root must contain one environment file per selectable profile:

```text
toolchains/project-mp09.env
toolchains/archive-mp09.env
toolchains/system-mp072.env
```

Copy the corresponding examples from `ci/sai/toolchains/` and adjust paths on
the runner. The workflow never accepts arbitrary library paths as inputs. It
selects a profile name, sources the runner-local file, rebuilds the current
checkout, verifies the linked libraries with `ldd`, and then submits the
16-GPU RT-TDDFT cuSolverMp case through Slurm.

Do not enable automatic `pull_request` execution for this workflow. Keep it
manual and protect the `sai-gpu` GitHub environment with required reviewers.

The tested 0.9.0/0.9.1 archive binaries reference NCCL APIs that are absent
from NCCL 2.18.5. Use the matching NCCL 2.29.x runtime for this profile.
