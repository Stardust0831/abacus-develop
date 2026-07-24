# SAI GPU validation through SSH

`.github/workflows/sai-gpu-full.yml` runs on a GitHub-hosted
`ubuntu-24.04` runner. It checks out the trusted control plane from the
repository default branch, checks out the requested ABACUS source commit
separately, and connects to SAI over pinned-host-key SSH as `abacususer01`.
No self-hosted GitHub runner or inbound service on SAI is required.

The control checkout's exact commit is recorded as `CONTROL_SHA`. Its
`ci/sai` directory is uploaded to the run's `control` directory, and all
Slurm submission, toolchain, matrix, and launcher scripts execute from that
copy. `SOURCE_SHA` identifies the ABACUS source and test data being built.
Building an approved source commit still executes that commit's build system
and code as `abacususer01`; the control-plane separation does not sandbox an
untrusted source commit.

## Triggers and trust boundary

The daily schedule is `30 20 * * *` (04:30 the following day in Beijing).
Scheduled runs test the default-branch commit supplied by GitHub and use the
`sai-ssh-scheduled` Environment. That Environment has no required reviewer and
allows deployments only from the default branch.

Manual dispatch requires an exact 40-character source commit SHA and uses the
protected `sai-ssh-manual` Environment. Configure `Stardust0831` as its required
reviewer and leave self-approval enabled. The reviewer must inspect the commit
before approval because its code will execute on SAI with all permissions of
`abacususer01`. External contributors only submit pull requests; a maintainer
reviews the pull request and then dispatches its exact commit when GPU testing
is warranted. Do not add an automatic `pull_request` trigger.

Different manually approved commits may run concurrently. Scheduled runs share
one `daily` concurrency group and therefore serialize with other scheduled
runs, while every manual dispatch uses its GitHub run ID as an independent
group. The protected Environment approval remains per run.

### One-time GitHub configuration

Configure these settings in the upstream repository after this workflow is
merged. Do not upload the SSH key to a fork or create a repository-level
secret.

1. Open **Settings > Environments** and create `sai-ssh-scheduled`.
2. Restrict its deployment branches to the default branch and do not add a
   required reviewer.
3. Add an Environment secret named `SAI_SSH_PRIVATE_KEY`. Its value is the
   complete contents of `~/.ssh/abacususer01`, including the `BEGIN` and `END`
   lines. GitHub accepts the key as pasted text, not as a file upload.
4. Add the Environment variables shown below.
5. Create `sai-ssh-manual`, restrict it to the default branch, and add the
   designated maintainer as a required reviewer. Allow self-review if that
   maintainer must be able to dispatch and approve the same run.
6. Add the same Environment secret and variables to `sai-ssh-manual`. GitHub
   does not share secrets or variables between Environments.

Both Environments use these variables:

```text
SAI_SSH_HOST=c0.sai.ai-4s.com
SAI_SSH_PORT=12022
SAI_SSH_USER=abacususer01
SAI_PROJECT_ROOT=/home/abacus-group/abacususer01/agent/abacus_sai_gpu_ci
```

`SAI_PROJECT_ROOT` is a default, not a compiled-in path. A manual run may use
another absolute project root whose components contain only letters, digits,
dot, underscore, or hyphen. The remote setup resolves existing symlinks and
rejects any path that escapes the account's canonical HOME. Only
`abacususer01` is supported by this deployment.

### Manual run

1. Review the source commit that will execute as `abacususer01` and obtain its
   full 40-character SHA. For a pull request, use its head commit, not a merge
   ref.
2. Open **Actions > SAI GPU Case Matrix > Run workflow** and select the
   repository default branch. The workflow control scripts always come from
   that trusted branch.
3. Enter the reviewed SHA as `source_sha`.
4. Leave `project_root` empty to use the manual Environment's
   `SAI_PROJECT_ROOT`, or enter another absolute directory below
   `/home/abacus-group/abacususer01` or its canonical
   `/org/abacus-group/abacususer01` path, for example
   `/home/abacus-group/abacususer01/agent/abacus_sai_gpu_ci_trial`.
5. Set `run_namespace` to a short label such as `pr-7658`. Runs using the same
   project root share the daily source baseline, but keep source, build,
   install, and result files in separate namespace directories.
6. Submit the workflow. A required reviewer then opens the pending deployment,
   checks the requested SHA and directory, and approves `sai-ssh-manual`.

### Direct local run

Developers with their own SAI account may launch the same remote build and
Slurm validation directly, without GitHub Actions. The local client uses an
existing OpenSSH configuration and never reads or copies the private key
itself. For example:

```sshconfig
Host SAI-abacus
    HostName c0.sai.ai-4s.com
    Port 12022
    User your-sai-user
    IdentityFile ~/.ssh/your-sai-key
    IdentitiesOnly yes
    StrictHostKeyChecking yes
```

Copy `ci/sai/local-run.env.example` outside the ABACUS checkout and set
`SAI_SSH_CONFIG` to the OpenSSH configuration file, `SAI_SSH_TARGET` to its
Host alias, and `SAI_PROJECT_ROOT` to an absolute directory below that remote
account's HOME. Do not put the local configuration or private key in the
repository. Validate access without creating a run:

```bash
bash ci/sai/run_local_ci.sh /path/to/local-run.env --probe-only
```

Run the full validation with:

```bash
bash ci/sai/run_local_ci.sh /path/to/local-run.env
```

The control checkout must have no tracked changes or non-ignored untracked
files. The client materializes `ci/sai` from the recorded `CONTROL_SHA` with
`git archive`, so ignored files and a check-to-upload working-tree race cannot
alter or add remote control files. `SAI_SOURCE_SHA` defaults to `HEAD` and may
name any commit already available in the local Git object database. The client
uploads a gzip-compressed Git delta and manifest through SSH, executes the same
remote build and validation scripts, and downloads the artifact bundle below
`SAI_ARTIFACT_ROOT/<run-id>/`. This legacy local transport may consume an
existing daily baseline but never advances it. GitHub-hosted runs instead use
the reverse artifact download described below.

The OpenSSH Host entry determines the remote username and identity file. The
client additionally forces batch mode, strict host-key checking, disabled
agent/port forwarding, and a temporary multiplexed control socket. The local
developer is responsible for reviewing `SAI_SOURCE_SHA`, because that commit's
build system, integration scripts, and binaries execute with the permissions
of the configured SAI account.

The selected directory is a reusable project root, not a checkout directory.
Each attempt uses a new
`runs/<namespace>/<GitHub run ID>-<attempt>` subdirectory, and the user-level
cleanup service discovers every selected project root through its registry. A
scheduled run has no input form, always uses namespace `daily`, and uses the
scheduled Environment's `SAI_PROJECT_ROOT` with the current default-branch
SHA. Choosing a different project root intentionally creates an independent
source baseline; use a namespace below the default project root when sharing
that baseline is desired.

The SSH client disables agent and port forwarding, uses `BatchMode`, requires
the repository-pinned SAI host key, and enables transport compression for all
control commands and rsync traffic. Source payloads and manifests are already
gzip-compressed before rsync starts, while returned artifacts are created as a
gzip-compressed tar stream on SAI. The read-only probe establishes one SSH
master connection with bounded connection retries; later SSH and rsync steps
reuse it instead of repeatedly negotiating with the login gateway. The
workflow explicitly closes the master before removing the private key and
socket directory in an `always()` step. The key is written only to the GitHub
runner's temporary directory with mode 0600. Never print the key or pass it on
a command line. This connection retry does not resume a Slurm coordinator
after a mid-session disconnect; the current signal handlers cancel recorded
jobs to avoid leaving orphan allocations.

## Build and GPU jobs

Each attempt creates a collision-resistant directory at
`$SAI_PROJECT_ROOT/runs/$RUN_NAMESPACE/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT`.

The active `module-abacus-develop-git-079fd0c` profile loads the site-managed
`abacus/develop-git-079fd0c-260724-sm70-auto` module. That module provides the
validated NVHPC 26.3, Open MPI 5.0.10, CUDA 12.9.1, ELPA, SAIBLAS, SAI NCCL
2.29.3, cuSolverMp 0.9.0, and cuBLASMp 0.9.1 environment. It loads
`nvmplibs/26.7-tmp` after the other runtime dependencies so
`/opt/devtools/nvidia/mp_libs` takes precedence over the older MP libraries
bundled with NVHPC 26.3.

The installed ABACUS named by the site module is a toolchain anchor only. The
workflow still rebuilds the approved `SOURCE_SHA` into the current run's
isolated build and install directories and executes that newly built binary.
The loader verifies the module's full `ABACUS_COMMIT`. Subsequent build and
runtime checks verify the required MPI, CUDA, cuSolverMp, cuBLASMp, and NCCL
versions, the resolved MP and SAI `libnccl.so.2` targets, and
`NCCL_SAI_RAIL_BY_CHANNEL=1`. The workflow does not modify `/opt`, modules, or
system configuration.

GitHub-hosted runners do not upload the source payload over the slow SAI SSH
path. The runner builds the same compressed Git delta and canonical tree
manifest, stores the two files in a one-day Actions artifact without another
compression pass, and exchanges its GitHub token for a short-lived Azure Blob
download URL. Only that signed URL is sent to SAI; the GitHub token never
leaves the runner and the URL is kept out of command arguments and logs. SAI
downloads the artifact directly from Blob storage, validates its exact two
entries, and feeds them into the existing manifest verification and isolated
source-cache flow. To work around the low single-connection throughput, SAI
downloads eight bounded byte ranges in parallel, verifies every range and the
REST-reported total archive size, then reconstructs the ZIP before extraction.

The project root is canonicalized first, so transfer caches and run directories
use the physical `/org` path even when the login environment exposes a `/home`
symlink. Scheduled runs still promote verified source baselines and manual
runs only consume them. Source, build, install, and result directories remain
isolated, and tested code never executes from or writes into the source cache.

The build disables DeePMD, Torch/DeepKS, PEXSI, DFT-D4, LibRI, NEP, and cnpy
because the selected GPU suites do not exercise them. After a successful
build, three resource-homogeneous Slurm arrays submit all 48 cases in suites
11/12/13/15/16 while a 2-node, 16-rank Si48 cuSolverMp RT-TDDFT smoke job runs in
parallel. The arrays use one 1-GPU task, seven 2-GPU tasks, and forty 4-GPU
tasks. The 1/2-GPU arrays use `flood-1o2gpu`; the 4-GPU array and multinode job
use `flood-gpu`. Their per-class concurrent task caps are 2, 8, and 8,
respectively. No job pins a node name or explicitly requests CPU resources.

SAI's partition mapping scripts determine MPI placement and OpenMP threads.
The validation keeps InfiniBand enabled and records effective MPI, UCX, NCCL,
RDMA, dynamic-library, Slurm accounting, and per-case numerical results.
Existing numerical references and thresholds are not relaxed. The currently
known `16_SDFT_GPU/005_PW_SDFT_MALL_BPCG_GPU` numerical failure therefore
makes the full workflow red until ABACUS fixes it. A case is retried exactly
once only when its first attempt fails before MPI initialization with the
observed PMIx shared-memory startup signature. Both attempt logs and retry
metadata are retained. A second PMIx startup failure is reported as
infrastructure rather than as an ABACUS numerical failure.

## Artifacts and cleanup

The GitHub artifact is retained for 30 days. It includes source/control commit
IDs, build identity and linkage, complete coordinator and Slurm logs, terminal
accounting, the 48-row case summary, per-case status, and ABACUS numerical
outputs. Collection uses an explicit extension/name allowlist. A failed setup
still uploads local workflow context instead of hiding the first error behind
an undefined path.

After GitHub confirms artifact upload, the remote run gets an atomic
`.artifacts-uploaded` marker. `.github/workflows/sai-bootstrap.yml` has a
read-only `probe` mode and an `install-cleanup` mode. Both are manual and use
the protected manual Environment. Installation copies the cleanup program to
`$HOME/.local/libexec/abacus-sai-ci` and installs this user crontab entry:

```text
15 7 * * * $HOME/.local/libexec/abacus-sai-ci/cleanup_sai_runs.sh --cron
```

Cleanup deletes uploaded runs 72 hours after their upload marker. Incomplete
runs and directories explicitly marked `.ci-diagnostic` are deleted after 168
hours. Bootstrap stages the cleanup program in one of these marked diagnostic
directories and removes it after successful installation, so an interrupted
install follows the same retention rule. It discovers relocatable project
roots through a locked per-user registry, refuses roots outside HOME, and skips
runs whose recorded Slurm jobs are active. Failure to query a recorded job is
treated as unknown and also skipped. `--dry-run` prints the decisions without
deleting anything. Cleanup logs are stored under
`$HOME/.local/state/abacus-sai-ci` and rotate at 10 MiB.

## Local verification

The shell regression suite uses only temporary directories and mocked Slurm
commands:

```bash
bash ci/sai/tests/test_sai_ci.sh
```

It covers SSH configuration, project-root containment and collision rejection,
site-module and Slurm submission policy, empty/populated artifact collection,
cleanup retention and job-query safety, and TERM/HUP cancellation including
the Slurm submission launch window.
