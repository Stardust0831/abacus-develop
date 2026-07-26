# SAI GPU validation

SAI validation has one command-line entry point:

```bash
python3 ci/sai/sai.py --help
```

It requires Python 3.8 or newer and uses only the standard library. The same
control plane is used by GitHub Actions and by developers running directly
from a workstation. Cluster policy and the trusted test inventory live in
`gpu-matrix.ini`; Python validates that file and constructs every `sbatch`
argument. The INI file cannot provide shell commands, environment variables,
scripts, or additional scheduler arguments.

The directory is intentionally flat. `sai.py` is the only public entry point;
the adjacent Python files are focused modules and `tests/` is the only source
subdirectory. `build_gpu.sh` is the fixed build worker, while
`gpu_case.sbatch` only loads the module environment before invoking Python. The
eight-line `mpirun_with_mapping.sh` must be an executable named `mpirun` for
ABACUS Autotest. No orchestration is implemented in Shell.

## Trust model

`.github/workflows/sai-gpu-full.yml` checks out two trees:

- `control` is always the repository default branch and supplies `ci/sai`;
- `source` is the exact approved commit that ABACUS builds and executes.

The separation prevents a candidate commit from changing SSH or Slurm control
logic. It does not sandbox candidate build scripts or binaries: an approver
must understand that the selected source executes with the permissions of the
SAI account.

Scheduled runs test the current default branch through the
`sai-ssh-scheduled` Environment without approval. Manual dispatches and pull
request comment requests enter the protected `sai-ssh-manual` Environment.
Only that Environment stores `SAI_SSH_PRIVATE_KEY`; do not create a
repository-level SSH secret.

An authorized maintainer can request the exact head commit of an open pull
request with:

```text
/abacus-ci sai-gpu
```

The admission job accepts the command only from a user with triage, write,
maintain, or admin permission. It resolves the immutable PR head SHA before
entering the protected Environment. External contributors cannot trigger SAI
directly.
Manual runs are independent; scheduled runs share a serialized `daily`
concurrency group.

## GitHub configuration

Create `sai-ssh-scheduled` and `sai-ssh-manual` under **Settings >
Environments**. Restrict both to the default branch, add required reviewers
only to the manual Environment, and configure each Environment with:

```text
secret: SAI_SSH_PRIVATE_KEY=<complete private key>
variable: SAI_SSH_HOST=c0.sai.ai-4s.com
variable: SAI_SSH_PORT=12022
variable: SAI_SSH_USER=<sai-user>
variable: SAI_PROJECT_ROOT=/home/<group>/<sai-user>/abacus_sai_gpu_ci
```

GitHub Environment secrets are separate, so the key must be added to each
Environment. The workflow writes it to a temporary mode-0600 file, never puts
it on a command line, and removes it in an `always()` step.

To dispatch manually, open **Actions > SAI GPU Case Matrix > Run workflow** on
the default branch and provide a reviewed 40-character `source_sha`. An empty
`project_root` uses the Environment variable. `run_namespace` is an ordinary
label such as `pr-7658`; every attempt still receives an isolated
`runs/<namespace>/<run-id>-<attempt>` directory.

## Direct local use

Local execution uses an existing OpenSSH Host entry. The Python client never
reads or copies the identity file named by OpenSSH. Create a private INI file
from `local-run.ini.example`, outside the repository if it contains local
paths:

```ini
[local]
ssh_config = ~/.ssh/config
ssh_target = SAI-abacus
project_root = /home/your-group/your-user/abacus_sai_gpu_ci
run_namespace = local
artifact_root = ./sai-artifacts
```

Probe SSH and Slurm access without creating a run:

```bash
python3 ci/sai/sai.py local probe --config /path/to/local-run.ini
```

Test a commit or branch:

```bash
python3 ci/sai/sai.py local run \
  --config /path/to/local-run.ini --source-ref HEAD
```

Test tracked working-tree contents without committing or changing the real Git
index:

```bash
python3 ci/sai/sai.py local run \
  --config /path/to/local-run.ini --working-tree
```

Add `--include-untracked` only when untracked source is intentionally part of
the build. Ignored untracked files remain excluded. A working-tree run uses an
ephemeral source cache and never replaces a shared baseline.

The local client requires the complete `ci/sai` control directory to match
`HEAD` with no untracked files, archives that committed directory, uploads the
snapshot and a compressed Git payload, streams the remote coordinator output,
and downloads the same artifact tree produced for GitHub. Local runs do not
create GitHub Checks; use a pushed commit and the GitHub workflow when a public
record is required.

## Configuration

Validate the trusted matrix directly:

```bash
python3 ci/sai/sai.py config validate \
  --file ci/sai/gpu-matrix.ini --control-root ci/sai
```

The exact schema contains:

- `[cluster]`: partition, toolchain, MP profile, mapping root, and NCCL IB mode;
- `[coordinator]`: polling and bounded Slurm query failure limits;
- `[build]`: one build allocation;
- `[resource.*]`: per-case nodes, ranks, GPUs, time, QoS, and array concurrency;
- contiguous `[case.NNN]` sections starting at `[case.001]`: suite, case,
  resource, and runner assignments.

Sections and keys are exact. Interpolation, defaults, multiline values,
unknown resources, unsafe paths, and topology outside the validated bounds are
rejected. Resource profiles generate argv lists for `sbatch`; the fixed
`build_gpu.sh` and `gpu_case.sbatch` files contain no `#SBATCH` resource
directives. No job uses `--cpus-per-task`, memory requests, `--wrap`, or node
pinning. A fixed `--export=NIL` prevents the submission environment from being
inherited; fixed scripts reconstruct only `HOME`, `USER`, `LOGNAME`, and a
minimal `PATH` before loading the validated module stack.

The checked-in toolchain loads the site-managed ABACUS module, which supplies
the validated Open MPI 5.0.10, CUDA 12.9.1, SAI NCCL 2.29.3, cuSolverMp 0.9.0,
and cuBLASMp 0.9.1 stack. The module binary is only an environment anchor. The
workflow rebuilds the selected source into its isolated install directory and
verifies compile-time versions, runtime linkage, and library identities. It
does not modify `/opt`, modules, or system configuration.

## Execution model

The coordinator submits the build first. Only a successful terminal build
state releases one homogeneous array for each configured resource profile.
The current matrix is:

| Profile | Cases | Per task | QoS | Max concurrent |
| --- | ---: | --- | --- | ---: |
| `gpu1` | 1 | 1 node, 1 rank, 1 GPU | `flood-1o2gpu` | 2 |
| `gpu2` | 7 | 1 node, 2 ranks, 2 GPUs | `flood-1o2gpu` | 16 |
| `gpu4` | 40 | 1 node, 4 ranks, 4 GPUs | `flood-gpu` | 16 |
| `gpu8x2` | 1 | 2 nodes, 16 ranks, 16 GPUs | `flood-gpu` | 1 |

The `gpu8x2` entry is the Si48 cuSolverMp RT-TDDFT smoke case. It uses the same
manifest, worker, status protocol, accounting, and report as every other case.
The worker copies each case into an isolated task directory before execution.
Numerical references are unchanged. An ordinary case retries once only for the
known PMIx pre-initialization signature; its attempt logs and retry metadata
remain artifacts.

The coordinator waits without imposing an artificial queue-duration limit.
It does limit consecutive `squeue` failures and delayed `sacct` attempts, and
it requires terminal accounting for every array task. HUP, INT, and TERM cancel
all recorded allocations.

## Source transfer and results

GitHub creates a deterministic gzip-compressed full or delta Git payload plus
a compressed tree manifest. The source checkout includes Git history so an
available SAI cache SHA produces a delta rather than an accidental full
payload. `rsync --partial` pushes the two compressed files directly over the
approved SSH connection and resumes a failed transfer. SAI validates the
canonical Git tree before updating the verified cache.

The authoritative result is:

```text
results/case-matrix/result.json
```

It records protocol version, aggregate counts, compile status, configured
resource-group statuses, case identities, return codes, Slurm states and job
IDs, elapsed time, and artifact directories. GitHub expands the build and each
configured resource group into independent red/green jobs using the labels in
`gpu-matrix.ini`. The derived `gpu-case-summary.md` contains the complete case
matrix; reporting validates JSON against the trusted INI rather than parsing
Markdown.

The complete GitHub artifact is retained for 30 days. After a successful
upload, SAI writes the same selected results to an atomic
`archives/NAMESPACE/RUN.tar.gz` file and removes the original run directory.
Each later run removes archives older than 72 hours. Incomplete runs are left
untouched for explicit inspection instead of being deleted automatically.

## Verification

Run the test suite locally:

```bash
python3 -m unittest discover -s ci/sai/tests -p 'test_sai_*.py' -v
```

Python tests cover configuration, source selection, local transport, Slurm
argv and accounting, remote orchestration, CLI behavior, and the JSON result
protocol. The policy test fixes the small allowed shell surface, trusted
workflow boundaries, compressed delta transfer, component jobs, forbidden
Slurm options, and shell syntax.
