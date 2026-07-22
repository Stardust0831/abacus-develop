#!/usr/bin/env bash

set -euo pipefail

test_root=$(mktemp -d)
original_path=$PATH
tests_run=0

cleanup() {
    local pid
    for pid in $(jobs -pr); do
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file() {
    [[ -f $1 ]] || fail "missing file: $1"
}

assert_not_exists() {
    [[ ! -e $1 && ! -L $1 ]] || fail "unexpected path: $1"
}

assert_contains() {
    grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_not_contains() {
    if grep -Fq -- "$2" "$1"; then
        fail "$1 unexpectedly contains: $2"
    fi
}

run_test() {
    local name=$1
    shift
    "$@"
    tests_run=$((tests_run + 1))
    echo "PASS: $name"
}

wait_for_file() {
    local path=$1
    local _
    for _ in {1..100}; do
        [[ -e $path ]] && return 0
        sleep 0.02
    done
    fail "timed out waiting for $path"
}

test_configure_ssh_client() {
    local root=$test_root/ssh
    local key=$root/input-key
    local output=$root/client
    local log=$root/output.log
    mkdir -p "$root"
    ssh-keygen -q -t ed25519 -N '' -C sai-ci-secret-marker -f "$key"
    printf '[sai.example]:12022 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest\n' \
        > "$root/known_hosts"

    SAI_SSH_PRIVATE_KEY=$(<"$key") \
    SAI_SSH_HOST=sai.example \
    SAI_SSH_PORT=12022 \
    SAI_SSH_USER=abacususer01 \
        bash ci/sai/configure_ssh_client.sh "$output" "$root/known_hosts" \
        > "$log"

    assert_file "$output/config"
    assert_file "$output/id_ed25519"
    [[ $(stat -c %a "$output/config") == 600 ]]
    [[ $(stat -c %a "$output/id_ed25519") == 600 ]]
    ssh-keygen -y -f "$output/id_ed25519" >/dev/null
    assert_contains "$output/config" 'ClearAllForwardings yes'
    assert_contains "$output/config" 'StrictHostKeyChecking yes'
    assert_contains "$output/config" 'Compression yes'
    assert_contains "$output/config" 'ConnectionAttempts 4'
    assert_contains "$output/config" 'ConnectTimeout 30'
    assert_contains "$output/config" 'ControlMaster auto'
    assert_contains "$output/config" "ControlPath $output/control-%C"
    assert_contains "$output/config" 'ControlPersist 15m'
    assert_not_contains "$log" 'PRIVATE KEY'
    assert_not_contains "$log" 'sai-ci-secret-marker'
}

test_build_source_payload() {
    local root=$test_root/source-payload
    local repository=$root/repository
    local sha1 sha2 output
    mkdir -p "$repository" "$root/full" "$root/delta"
    git -C "$repository" init -q
    git -C "$repository" config user.email ci@example.invalid
    git -C "$repository" config user.name ci
    printf 'first\n' > "$repository/data.txt"
    git -C "$repository" add data.txt
    git -C "$repository" commit -q -m first
    sha1=$(git -C "$repository" rev-parse HEAD)
    printf 'second\n' > "$repository/data.txt"
    printf 'new\n' > "$repository/new.txt"
    git -C "$repository" add data.txt new.txt
    git -C "$repository" commit -q -m second
    sha2=$(git -C "$repository" rev-parse HEAD)

    output=$(bash ci/sai/build_source_payload.sh "$repository" "$sha1" none \
        "$root/full/source-payload.gz" "$root/full/source-manifest.gz")
    grep -Fxq 'SOURCE_PAYLOAD_MODE=full' <<< "$output"
    cmp <(git -C "$repository" ls-tree -r -z --full-tree "$sha1") \
        <(gzip -cd "$root/full/source-manifest.gz")
    empty_tree=$(git -C "$repository" hash-object -t tree /dev/null)
    cmp <(git -C "$repository" diff --binary --full-index --no-renames \
            "$empty_tree" "$sha1") \
        <(gzip -cd "$root/full/source-payload.gz")

    output=$(bash ci/sai/build_source_payload.sh "$repository" "$sha2" "$sha1" \
        "$root/delta/source-payload.gz" "$root/delta/source-manifest.gz")
    grep -Fxq 'SOURCE_PAYLOAD_MODE=delta' <<< "$output"
    cmp <(git -C "$repository" diff --binary --full-index --no-renames \
            "$sha1" "$sha2") \
        <(gzip -cd "$root/delta/source-payload.gz")
}

test_prepare_control_snapshot() {
    local root=$test_root/control-snapshot
    local repository=$root/repository
    local output=$root/output
    local control_sha result control_root
    mkdir -p "$repository/ci/sai"
    git -C "$repository" init -q
    git -C "$repository" config user.email ci@example.invalid
    git -C "$repository" config user.name ci
    printf '*.log\n' > "$repository/.gitignore"
    printf '#!/usr/bin/env bash\nexit 0\n' \
        > "$repository/ci/sai/run_remote_ci.sh"
    chmod +x "$repository/ci/sai/run_remote_ci.sh"
    printf 'tracked\n' > "$repository/ci/sai/tracked.txt"
    git -C "$repository" add .gitignore ci/sai
    git -C "$repository" commit -q -m control
    control_sha=$(git -C "$repository" rev-parse HEAD)
    printf 'ignored secret\n' > "$repository/ci/sai/private.log"
    printf 'untracked\n' > "$repository/ci/sai/untracked.txt"

    result=$(bash ci/sai/prepare_control_snapshot.sh \
        "$repository" "$control_sha" "$output")
    control_root=$(awk -F= '$1 == "CONTROL_ROOT" {print $2}' <<< "$result")
    [[ $control_root == "$output/ci/sai" ]]
    assert_file "$control_root/run_remote_ci.sh"
    assert_file "$control_root/tracked.txt"
    [[ -x $control_root/run_remote_ci.sh ]]
    assert_not_exists "$control_root/private.log"
    assert_not_exists "$control_root/untracked.txt"
}

test_remote_probe_identity() {
    local root=$test_root/remote-probe
    local fake_bin=$root/bin
    local command_name
    mkdir -p "$fake_bin" "$root/home"
    cat > "$fake_bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -un ]]; then
    echo localuser
else
    exec /usr/bin/id "$@"
fi
EOF
    cat > "$fake_bin/sinfo" <<'EOF'
#!/usr/bin/env bash
echo '16V100 up 1 gpu:8'
EOF
    chmod +x "$fake_bin/id" "$fake_bin/sinfo"
    for command_name in sbatch sacct squeue scancel crontab; do
        cat > "$fake_bin/$command_name" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
        chmod +x "$fake_bin/$command_name"
    done

    PATH="$fake_bin:$original_path" HOME=$root/home \
        bash ci/sai/probe_remote_sai.sh localuser > "$root/probe.log"
    assert_contains "$root/probe.log" 'SAI_SSH_PROBE_OK user=localuser'
    if PATH="$fake_bin:$original_path" HOME=$root/home \
        bash ci/sai/probe_remote_sai.sh wronguser > /dev/null 2>&1; then
        fail 'remote probe accepted the wrong expected user'
    fi
}

test_local_client_probe() {
    local root=$test_root/local-client
    local fake_bin=$root/bin
    local ssh_config=$root/ssh-config
    local local_config=$root/local-run.env
    local ssh_log=$root/ssh.log
    mkdir -p "$fake_bin"
    : > "$ssh_config"
    cat > "$local_config" <<EOF
SAI_SSH_CONFIG=$ssh_config
SAI_SSH_TARGET=test-sai
EOF
    cat > "$fake_bin/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ssh_log"
case " \$* " in
    *' -G '*) echo 'user localuser'; exit 0 ;;
    *' -MNf '*) exit 0 ;;
    *' -O exit '*) exit 0 ;;
esac
cat >/dev/null
echo 'SAI_SSH_PROBE_OK user=localuser'
EOF
    chmod +x "$fake_bin/ssh"

    PATH="$fake_bin:$original_path" \
        bash ci/sai/run_local_ci.sh "$local_config" --probe-only \
        > "$root/local-probe.log"
    assert_contains "$root/local-probe.log" \
        'SAI_LOCAL_PROBE_OK target=test-sai user=localuser'
    assert_contains "$ssh_log" 'StrictHostKeyChecking=yes'
    assert_contains "$ssh_log" 'ForwardAgent=no'
    assert_contains "$ssh_log" 'ClearAllForwardings=yes'
}

test_workflow_security_policy() {
    local workflow=.github/workflows/sai-gpu-full.yml
    local bootstrap=.github/workflows/sai-bootstrap.yml
    local toolchain=ci/sai/toolchains/archive-mp09-sai-nccl2293.env.example
    local payload_builder=ci/sai/build_source_payload.sh
    local runtime_file
    assert_contains "$workflow" 'cron: "30 20 * * *"'
    assert_contains "$workflow" "name: \${{ github.event_name == 'schedule' && 'sai-ssh-scheduled' || 'sai-ssh-manual' }}"
    assert_contains "$workflow" "group: sai-gpu-\${{ github.event_name == 'schedule' && 'daily' || github.run_id }}"
    assert_not_contains "$workflow" 'group: sai-gpu-rebuild'
    assert_contains "$workflow" 'ref: ${{ github.event.repository.default_branch }}'
    assert_contains "$workflow" 'Approved code SHA; executes as abacususer01 on SAI'
    assert_contains "$bootstrap" 'name: sai-ssh-manual'
    assert_contains "$bootstrap" 'ref: ${{ github.event.repository.default_branch }}'
    assert_contains "$bootstrap" 'rsync -az -e "ssh -F $SAI_SSH_CONFIG"'
    assert_contains "$workflow" 'ssh -F "$SAI_SSH_CONFIG" -o ConnectionAttempts=1 -MNf sai-ci'
    assert_contains "$bootstrap" 'ssh -F "$SAI_SSH_CONFIG" -o ConnectionAttempts=1 -MNf sai-ci'
    assert_contains "$workflow" 'ssh -F "$SAI_SSH_CONFIG" -O exit sai-ci'
    assert_contains "$bootstrap" 'ssh -F "$SAI_SSH_CONFIG" -O exit sai-ci'
    assert_contains ci/sai/run_remote_ci.sh \
        'export SAI_CUSOLVERMP_ROOT=$SAI_NVIDIA_MP_ROOT/libcusolvermp-linux-x86_64-0.9.0.6427_cuda12-archive'
    assert_contains ci/sai/run_remote_ci.sh \
        'export SAI_CUBLASMP_ROOT=$SAI_NVIDIA_MP_ROOT/libcublasmp-linux-x86_64-0.9.1.3056_cuda12-archive'
    assert_contains "$toolchain" 'module load nvhpc/26.3-gnu-cuda12-tuned'
    assert_contains "$toolchain" 'export SAI_NCCL_ROOT=$NCCL_ROOT'
    assert_not_contains "$toolchain" 'module load nccl/'
    assert_not_contains "$toolchain" 'export SAI_NCCL_ROOT=/opt/'
    assert_contains "$workflow" 'source_transfer_cache.sh'
    assert_contains "$workflow" 'build_source_payload.sh'
    assert_contains "$payload_builder" 'diff --binary --full-index --no-renames'
    assert_contains "$payload_builder" 'empty_tree=$(git -C "$repository" hash-object -t tree /dev/null)'
    assert_contains "$payload_builder" 'ls-tree -r -z --full-tree "$source_sha"'
    assert_contains "$payload_builder" '| gzip -1 > "$payload"'
    assert_contains "$workflow" 'SOURCE_CACHE_BASE_SHA'
    assert_contains "$workflow" 'run_namespace=${RUN_NAMESPACE_INPUT:-manual}'
    assert_contains "$workflow" 'source_cache_role=baseline'
    assert_contains "$workflow" 'source_cache_role=candidate'
    assert_contains "$workflow" \
        'runs/$RUN_NAMESPACE/$run_key'
    assert_contains ci/sai/source_transfer_cache.sh 'flock 8'
    assert_contains "$workflow" 'SOURCE_MANIFEST=$manifest'
    assert_contains "$workflow" '"$SOURCE_PAYLOAD" "$SOURCE_MANIFEST"'
    assert_contains "$workflow" '"sai-ci:$REMOTE_SOURCE_TRANSFER_ROOT/"'
    assert_not_contains "$workflow" '"sai-ci:$REMOTE_RUN_ROOT/source/"'
    assert_contains ci/sai/probe_remote_sai.sh 'rsync curl git gzip tar xz'
    assert_contains "$workflow" 'bash -s -- "$SAI_SSH_USER"'
    assert_contains "$bootstrap" 'bash -s -- "$SAI_SSH_USER"'
    assert_not_contains ci/sai/probe_remote_sai.sh '1478400356'
    for runtime_file in ci/sai/build_gpu.sh ci/sai/test_gpu.sbatch \
        ci/sai/test_gpu_case.sh "$toolchain"; do
        assert_contains "$runtime_file" '${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}'
        assert_not_contains "$runtime_file" ':${LD_LIBRARY_PATH:-}'
    done
    assert_contains ci/sai/run_local_ci.sh 'source_transfer_cache.sh'
    assert_contains ci/sai/run_local_ci.sh '"$source_sha" candidate'
    assert_contains ci/sai/run_local_ci.sh 'status --porcelain --untracked-files=all'
    assert_contains ci/sai/run_local_ci.sh 'prepare_control_snapshot.sh'
    assert_contains ci/sai/run_local_ci.sh '"$control_root/"'
    assert_contains ci/sai/run_local_ci.sh '< "$control_root/probe_remote_sai.sh"'
    assert_not_contains ci/sai/run_local_ci.sh '< "$script_dir/probe_remote_sai.sh"'
    assert_not_contains ci/sai/local-run.env.example 'PRIVATE KEY'
    if sed -n '/^on:/,/^permissions:/p' "$workflow" | grep -Eq '^[[:space:]]+pull_request:'; then
        fail 'GPU workflow must not run automatically for pull requests'
    fi
}

test_control_executable_modes() {
    local path mode
    for path in \
        ci/sai/build_source_payload.sh \
        ci/sai/build_gpu.sbatch \
        ci/sai/mpirun_with_mapping.sh \
        ci/sai/prepare_control_snapshot.sh \
        ci/sai/run_local_ci.sh \
        ci/sai/run_slurm_job.sh \
        ci/sai/test_gpu.sbatch \
        ci/sai/test_gpu_case.sh; do
        mode=$(git ls-files -s -- "$path" | awk 'NR == 1 {print $1}')
        [[ $mode == 100755 ]] || fail "$path has Git mode ${mode:-untracked}, expected 100755"
    done
}

test_pmix_startup_retry() {
    local root=$test_root/pmix-retry
    local suite=$root/work/tests/suite
    local case_dir=$suite/case
    local integrate=$root/work/tests/integrate
    local results=$root/results
    local abacus=$root/abacus
    local fake_count=$root/count
    local task
    mkdir -p "$case_dir" "$integrate" "$results" "$root/bin"
    : > "$abacus"
    chmod +x "$abacus"
    cat > "$root/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$root/bin/sleep"
    cat > "$integrate/Autotest.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -f $FAKE_COUNT_FILE ]]; then
    count=$(<"$FAKE_COUNT_FILE")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$FAKE_COUNT_FILE"
emit_pmix_failure() {
    echo 'PMIX ERROR: PMIX_ERR_FILE_OPEN_FAILURE'
    echo '*** An error occurred in MPI_Init_thread'
    echo 'PMIx_Init failed for the following reason:'
    exit 1
}
case $FAKE_MODE in
    pmix_once)
        if [[ $count -eq 1 ]]; then
            mkdir -p "$FAKE_CASE_DIR/OUT.autotest"
            : > "$FAKE_CASE_DIR/log.txt"
            emit_pmix_failure
        fi
        [[ ! -e $FAKE_CASE_DIR/OUT.autotest ]]
        [[ ! -e $FAKE_CASE_DIR/log.txt ]]
        echo 'recovered on the second attempt'
        ;;
    pmix_always)
        emit_pmix_failure
        ;;
    pmix_timeout)
        echo 'PMIX ERROR: PMIX_ERR_FILE_OPEN_FAILURE'
        echo '*** An error occurred in MPI_Init_thread'
        echo 'PMIx_Init failed for the following reason:'
        exit 124
        ;;
    normal_failure)
        echo 'numerical comparison failed'
        exit 1
        ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "$integrate/Autotest.sh"

    task=$results/recovered
    mkdir -p "$task"
    FAKE_MODE=pmix_once FAKE_COUNT_FILE=$fake_count FAKE_CASE_DIR=$case_dir \
    RESULT_ROOT=$results PATH="$root/bin:$PATH" \
        bash ci/sai/run_gpu_case_attempts.sh \
            "$suite" "$case_dir" case "$abacus" 2 8 "$task" \
            > "$root/recovered.log"
    [[ $(<"$fake_count") == 2 ]]
    assert_contains "$task/pmix-retry.tsv" $'attempts\t2'
    assert_contains "$task/pmix-retry.tsv" $'retried\t1'
    assert_contains "$task/pmix-retry.tsv" $'final_pmix\t0'
    assert_contains "$task/case.log" 'SAI_PMIX_STARTUP_RETRY'
    assert_contains "$task/case-attempt-2.log" 'recovered on the second attempt'

    rm -f "$fake_count"
    task=$results/persistent
    mkdir -p "$task"
    if FAKE_MODE=pmix_always FAKE_COUNT_FILE=$fake_count FAKE_CASE_DIR=$case_dir \
        RESULT_ROOT=$results PATH="$root/bin:$PATH" \
            bash ci/sai/run_gpu_case_attempts.sh \
                "$suite" "$case_dir" case "$abacus" 2 8 "$task" \
                > "$root/persistent.log"; then
        fail 'persistent PMIx startup failure returned success'
    fi
    [[ $(<"$fake_count") == 2 ]]
    assert_contains "$task/pmix-retry.tsv" $'attempts\t2'
    assert_contains "$task/pmix-retry.tsv" $'final_pmix\t1'

    rm -f "$fake_count"
    task=$results/normal-failure
    mkdir -p "$task"
    if FAKE_MODE=normal_failure FAKE_COUNT_FILE=$fake_count FAKE_CASE_DIR=$case_dir \
        RESULT_ROOT=$results PATH="$root/bin:$PATH" \
            bash ci/sai/run_gpu_case_attempts.sh \
                "$suite" "$case_dir" case "$abacus" 2 8 "$task" \
                > "$root/normal-failure.log"; then
        fail 'normal case failure returned success'
    fi
    [[ $(<"$fake_count") == 1 ]]
    assert_contains "$task/pmix-retry.tsv" $'attempts\t1'
    assert_contains "$task/pmix-retry.tsv" $'retried\t0'
    assert_contains "$task/pmix-retry.tsv" $'final_pmix\t0'

    rm -f "$fake_count"
    task=$results/pmix-timeout
    mkdir -p "$task"
    if FAKE_MODE=pmix_timeout FAKE_COUNT_FILE=$fake_count FAKE_CASE_DIR=$case_dir \
        RESULT_ROOT=$results PATH="$root/bin:$PATH" \
            bash ci/sai/run_gpu_case_attempts.sh \
                "$suite" "$case_dir" case "$abacus" 2 8 "$task" \
                > "$root/pmix-timeout.log"; then
        fail 'PMIx timeout returned success'
    fi
    [[ $(<"$fake_count") == 1 ]]
    assert_contains "$task/pmix-retry.tsv" $'attempts\t1'
    assert_contains "$task/pmix-retry.tsv" $'retried\t0'
    assert_contains "$task/pmix-retry.tsv" $'final_pmix\t0'
    assert_contains "$task/pmix-retry.tsv" $'final_rc\t124'
}

test_gpu_matrix_submission_policy() {
    local script=ci/sai/run_gpu_case_matrix.sh
    local multinode=ci/sai/test_gpu.sbatch
    local launcher=ci/sai/test_gpu_case.sh
    local summary=ci/sai/summarize_gpu_case_matrix.sh
    assert_contains "$script" \
        'declare -A limits=([gpu1]=2 [gpu2]=8 [gpu4]=8)'
    assert_contains "$script" 'export GPU_CASE_CLASS=$class'
    assert_contains "$script" 'export GPU_CASE_RANKS=${ranks[$class]}'
    assert_contains "$script" 'export GPU_CASE_MANIFEST=$manifest'
    assert_contains "$script" '--export=ALL'
    assert_not_contains "$script" '--export="ALL,'
    assert_contains "$script" 'declare -A ranks=([gpu1]=1 [gpu2]=2 [gpu4]=4)'
    assert_contains "$script" 'declare -A qos=([gpu1]=flood-1o2gpu [gpu2]=flood-1o2gpu [gpu4]=flood-gpu)'
    assert_contains "$script" '--ntasks="${ranks[$class]}"'
    assert_contains "$script" '--gpus-per-node="${ranks[$class]}"'
    assert_contains "$script" '"$CONTROL_ROOT/test_gpu_case.sh"'
    assert_not_contains "$script" '--cpus-per-task'
    assert_contains "$multinode" 'prepare_cusolvermp_smoke.sh'
    assert_not_contains "$multinode" 'CASES_CUSOLVERMP_16GPU.txt'
    assert_contains "$multinode" '#SBATCH --nodes=2'
    assert_contains "$multinode" '#SBATCH --ntasks=16'
    assert_contains "$multinode" '#SBATCH --ntasks-per-node=8'
    assert_contains "$multinode" '#SBATCH --gpus-per-node=8'
    assert_contains "$multinode" '19_NO_Si48_CUSOLVERMP_TDDFT_GPU'
    assert_not_contains "$multinode" 'Autotest.sh'
    assert_contains "$launcher" 'run_gpu_case_attempts.sh'
    assert_contains "$launcher" 'state=INFRA'
    assert_contains "$summary" '^(PASS|FAIL|TIMEOUT|INFRA)$'
}

test_gpu_case_symlink_rejection() {
    local root=$test_root/gpu-case-symlink
    local source=$root/source
    local case_dir=$source/tests/suite/case
    local manifest=$root/manifest.tsv
    local outside=$root/outside
    mkdir -p "$case_dir" "$source/tests/integrate" "$source/tests/PP_ORB" \
        "$root/results" "$root/install" "$root/control"
    printf 'outside\n' > "$outside"
    ln -s "$outside" "$case_dir/INPUT"
    printf 'suite\tcase\n' > "$manifest"

    if CI_SOURCE=$source CONTROL_ROOT=$root/control \
        INSTALL_ROOT=$root/install RESULT_ROOT=$root/results \
        TOOLCHAIN_FILE=$root/missing-toolchain MP_PROFILE=test \
        GPU_CASE_CLASS=gpu1 GPU_CASE_RANKS=1 \
        GPU_CASE_MANIFEST=$manifest SLURM_ARRAY_JOB_ID=1 \
        SLURM_ARRAY_TASK_ID=0 SLURM_NTASKS=1 SLURM_GPUS_ON_NODE=1 \
        bash ci/sai/test_gpu_case.sh > "$root/case.log" 2>&1; then
        fail 'GPU case launcher accepted a symbolic link'
    fi
    assert_contains "$root/case.log" 'GPU case contains a symbolic link'
    [[ $(<"$outside") == outside ]]
}

test_prepare_cusolvermp_smoke() {
    local root=$test_root/cusolvermp-smoke
    local source=$root/source
    local results=$root/results
    local case_name=19_NO_Si48_CUSOLVERMP_TDDFT_GPU
    local repository_case=tests/15_rtTDDFT_GPU/$case_name
    local source_case=$source/tests/15_rtTDDFT_GPU/$case_name
    local input=$source_case/INPUT
    local staged=$results/cusolvermp-smoke/15_rtTDDFT_GPU/$case_name/INPUT
    local name
    mkdir -p "$(dirname "$source_case")" "$source/tests/PP_ORB"
    cp -a "$repository_case" "$source_case"
    printf 'must not be staged\n' > "$source_case/UNTRUSTED_EXTRA"
    CI_SOURCE=$source RESULT_ROOT=$results \
        bash ci/sai/prepare_cusolvermp_smoke.sh > "$root/prepare.log"
    assert_contains "$input" 'ks_solver         cusolvermp'
    assert_contains "$staged" 'ks_solver         cusolvermp'
    for name in INPUT KPT README STRU; do
        cmp "$source_case/$name" \
            "$results/cusolvermp-smoke/15_rtTDDFT_GPU/$case_name/$name"
    done
    if [[ -e $results/cusolvermp-smoke/15_rtTDDFT_GPU/$case_name/UNTRUSTED_EXTRA ]]; then
        fail 'cuSolverMp smoke staging copied an unvalidated extra file'
    fi

    printf '%s\n' INPUT_PARAMETERS 'ks_solver         elpa' > "$input"
    if CI_SOURCE=$source RESULT_ROOT=$root/missing-results \
        bash ci/sai/prepare_cusolvermp_smoke.sh > /dev/null 2>&1; then
        fail 'cuSolverMp smoke staging accepted a missing cusolvermp line'
    fi

    printf '%s\n' INPUT_PARAMETERS 'ks_solver cusolvermp' 'ks_solver cusolvermp' > "$input"
    if CI_SOURCE=$source RESULT_ROOT=$root/duplicate-results \
        bash ci/sai/prepare_cusolvermp_smoke.sh > /dev/null 2>&1; then
        fail 'cuSolverMp smoke staging accepted duplicate cusolvermp lines'
    fi

    cp "$repository_case/INPUT" "$input"
    rm -f "$source_case/KPT"
    ln -s "$PWD/$repository_case/KPT" "$source_case/KPT"
    if CI_SOURCE=$source RESULT_ROOT=$root/symlink-results \
        bash ci/sai/prepare_cusolvermp_smoke.sh > /dev/null 2>&1; then
        fail 'cuSolverMp smoke staging accepted a symlinked case file'
    fi
}

test_prepare_remote_run_paths() {
    local root=$test_root/remote-paths
    local home=$root/home
    local outside=$root/outside
    local project=$home/projects/abacus-ci
    local output=$root/create.out
    local config_home=$root/config-escape-home
    local registry_home=$root/registry-leaf-home
    mkdir -p "$home/projects" "$outside"

    HOME=$home bash ci/sai/prepare_remote_run.sh \
        "$project" pr-123 123-1 \
        0123456789abcdef0123456789abcdef01234567 \
        89abcdef0123456789abcdef0123456789abcdef \
        > "$output"
    assert_file "$project/runs/pr-123/123-1/.ci-created"
    assert_contains "$output" "SAI_PROJECT_ROOT=$project"
    assert_contains "$output" "RUN_ROOT=$project/runs/pr-123/123-1"
    if HOME=$home bash ci/sai/prepare_remote_run.sh \
        "$project" pr-123 123-1 \
        0123456789abcdef0123456789abcdef01234567 \
        89abcdef0123456789abcdef0123456789abcdef \
        > /dev/null 2>&1; then
        fail 'remote run collision was accepted'
    fi
    if HOME=$home bash ci/sai/prepare_remote_run.sh \
        "$project" ../escape 128-1 \
        0123456789abcdef0123456789abcdef01234567 \
        89abcdef0123456789abcdef0123456789abcdef \
        > /dev/null 2>&1; then
        fail 'unsafe run namespace was accepted'
    fi
    ln -s "$outside" "$project/runs/linked"
    if HOME=$home bash ci/sai/prepare_remote_run.sh \
        "$project" linked 129-1 \
        0123456789abcdef0123456789abcdef01234567 \
        89abcdef0123456789abcdef0123456789abcdef \
        > /dev/null 2>&1; then
        fail 'symlinked run namespace was accepted'
    fi
    assert_not_exists "$outside/129-1"

    ln -s "$outside" "$home/projects/escape"
    if HOME=$home bash ci/sai/prepare_remote_run.sh \
        "$home/projects/escape/project" manual 124-1 \
        0123456789abcdef0123456789abcdef01234567 \
        89abcdef0123456789abcdef0123456789abcdef \
        > /dev/null 2>&1; then
        fail 'symlink escape was accepted'
    fi
    if HOME=$home bash ci/sai/prepare_remote_run.sh \
        "$home/projects/../outside" manual 125-1 \
        0123456789abcdef0123456789abcdef01234567 \
        89abcdef0123456789abcdef0123456789abcdef \
        > /dev/null 2>&1; then
        fail 'dot-dot path was accepted'
    fi

    mkdir -p "$config_home" "$root/outside-config"
    ln -s "$root/outside-config" "$config_home/.config"
    if HOME=$config_home bash ci/sai/prepare_remote_run.sh \
        "$config_home/project" manual 126-1 \
        0123456789abcdef0123456789abcdef01234567 \
        89abcdef0123456789abcdef0123456789abcdef \
        > /dev/null 2>&1; then
        fail 'remote setup accepted a .config symlink escape'
    fi
    assert_not_exists "$root/outside-config/abacus-sai-ci"

    mkdir -p "$registry_home/.config/abacus-sai-ci"
    printf 'registry-sentinel\n' > "$root/registry-target"
    ln -s "$root/registry-target" \
        "$registry_home/.config/abacus-sai-ci/project-roots"
    if HOME=$registry_home bash ci/sai/prepare_remote_run.sh \
        "$registry_home/project" manual 127-1 \
        0123456789abcdef0123456789abcdef01234567 \
        89abcdef0123456789abcdef0123456789abcdef \
        > /dev/null 2>&1; then
        fail 'remote setup accepted a registry leaf symlink'
    fi
    [[ $(<"$root/registry-target") == registry-sentinel ]]
}

test_source_snapshot_cache() {
    local root=$test_root/source-cache
    local home=$root/home
    local project=$home/projects/abacus-ci
    local repository=$root/repository
    local sha1 sha2
    local run1=$project/runs/100-1
    local run2=$project/runs/101-1
    local run3=$project/runs/102-1
    local run4=$project/runs/103-1
    local run5=$project/runs/104-1
    local run6=$project/runs/105-1
    local run7=$project/runs/106-1
    local run8=$project/runs/107-1
    local run9=$project/runs/108-1
    local candidate=$project/runs/pr-7658/109-1
    local invalid_candidate=$project/runs/pr-invalid/110-1
    local output transfer snapshot snapshot_name inode_run inode_cache orphan
    mkdir -p "$repository"
    git -C "$repository" init -q
    git -C "$repository" config user.email ci@example.invalid
    git -C "$repository" config user.name ci
    printf '*.bat text eol=crlf\n' > "$repository/.gitattributes"
    printf 'canonical line\r\n' > "$repository/windows.bat"
    printf 'unchanged\n' > "$repository/keep.txt"
    printf 'remove later\n' > "$repository/delete.txt"
    printf '\x00\x01base\xff' > "$repository/data.bin"
    printf '#!/bin/sh\necho base\n' > "$repository/tool.sh"
    chmod 0644 "$repository/tool.sh"
    ln -s keep.txt "$repository/link"
    git -C "$repository" add .
    git -C "$repository" commit -qm base
    sha1=$(git -C "$repository" rev-parse HEAD)
    rm "$repository/windows.bat"
    git -C "$repository" checkout -q -- windows.bat

    mkdir -p "$run1/source" "$run1/control" "$run1/build" \
        "$run1/install" "$run1/results"
    touch "$run1/.ci-created"

    output=$(HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$run1" "$sha1" baseline)
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    assert_contains <(printf '%s\n' "$output") 'SOURCE_CACHE_BASE_SHA=none'
    [[ $transfer == "$project/cache/source-transfers/100-1" ]]
    git -C "$repository" diff --binary --full-index --no-renames \
        "$(git -C "$repository" hash-object -t tree /dev/null)" "$sha1" \
        | gzip -1 > "$transfer/source-payload.gz"
    git -C "$repository" ls-tree -r -z --full-tree "$sha1" \
        | gzip -1 > "$transfer/source-manifest.gz"
    HOME=$home bash ci/sai/source_transfer_cache.sh receive \
        "$project" "$run1" "$transfer" full "$sha1" > "$root/receive1.log"
    HOME=$home bash ci/sai/source_transfer_cache.sh finalize \
        "$project" "$run1" "$transfer" "$sha1" > "$root/finalize1.log"
    assert_contains "$run1/source/keep.txt" 'unchanged'
    assert_file "$project/cache/source-latest"
    assert_contains "$project/cache/source-latest" "$sha1.100-1"
    snapshot=$project/cache/source-snapshots/$sha1.100-1
    assert_file "$snapshot/keep.txt"
    assert_file "$snapshot.manifest.gz"
    git -C "$repository" show "$sha1:windows.bat" > "$root/windows.blob"
    cmp "$root/windows.blob" "$snapshot/windows.bat"
    if cmp -s "$repository/windows.bat" "$snapshot/windows.bat"; then
        fail 'full source payload came from the CRLF checkout instead of Git blobs'
    fi
    inode_run=$(stat -c %i "$run1/source/keep.txt")
    inode_cache=$(stat -c %i "$snapshot/keep.txt")
    [[ $inode_run != "$inode_cache" ]] || fail 'run source shares cache inode'

    printf 'changed\n' > "$repository/keep.txt"
    printf '\x00\x01target\xfe' > "$repository/data.bin"
    rm "$repository/delete.txt" "$repository/link"
    printf '#!/bin/sh\necho target\n' > "$repository/tool.sh"
    chmod 0755 "$repository/tool.sh"
    ln -s data.bin "$repository/link"
    printf 'added\n' > "$repository/add.txt"
    git -C "$repository" add -A
    git -C "$repository" commit -qm target
    sha2=$(git -C "$repository" rev-parse HEAD)

    mkdir -p "$candidate/source" "$candidate/control" "$candidate/build" \
        "$candidate/install" "$candidate/results"
    touch "$candidate/.ci-created"
    output=$(HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$candidate" "$sha2" candidate)
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    assert_contains <(printf '%s\n' "$output") "SOURCE_CACHE_BASE_SHA=$sha1"
    assert_contains <(printf '%s\n' "$output") 'SOURCE_CACHE_ROLE=candidate'
    git -C "$repository" diff --binary --full-index --no-renames \
        "$sha1" "$sha2" | gzip -1 > "$transfer/source-payload.gz"
    git -C "$repository" ls-tree -r -z --full-tree "$sha2" \
        | gzip -1 > "$transfer/source-manifest.gz"
    HOME=$home bash ci/sai/source_transfer_cache.sh receive \
        "$project" "$candidate" "$transfer" delta "$sha2" > /dev/null
    HOME=$home bash ci/sai/source_transfer_cache.sh finalize \
        "$project" "$candidate" "$transfer" "$sha2" \
        > "$root/finalize-candidate.log"
    assert_contains "$candidate/source/keep.txt" 'changed'
    assert_contains "$root/finalize-candidate.log" \
        "SOURCE_CACHE_PROMOTION=skipped role=candidate source_sha=$sha2"
    assert_contains "$project/cache/source-latest" "$sha1.100-1"
    assert_file "$snapshot/keep.txt"
    assert_not_exists "$transfer"

    mkdir -p "$run2/source" "$run2/control" "$run2/build" \
        "$run2/install" "$run2/results"
    touch "$run2/.ci-created"
    output=$(HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$run2" "$sha2" baseline)
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    assert_contains <(printf '%s\n' "$output") "SOURCE_CACHE_BASE_SHA=$sha1"
    assert_contains "$transfer/source/keep.txt" 'unchanged'
    assert_file "$transfer/source/delete.txt"
    git -C "$repository" diff --binary --full-index --no-renames \
        "$sha1" "$sha2" | gzip -1 > "$transfer/source-payload.gz"
    git -C "$repository" ls-tree -r -z --full-tree "$sha2" \
        | gzip -1 > "$transfer/source-manifest.gz"
    HOME=$home bash ci/sai/source_transfer_cache.sh receive \
        "$project" "$run2" "$transfer" delta "$sha2" > "$root/receive2.log"
    HOME=$home bash ci/sai/source_transfer_cache.sh finalize \
        "$project" "$run2" "$transfer" "$sha2" > "$root/finalize2.log"
    assert_contains "$run2/source/keep.txt" 'changed'
    assert_contains "$run2/source/add.txt" 'added'
    assert_not_exists "$run2/source/delete.txt"
    [[ -x $run2/source/tool.sh ]]
    [[ $(readlink "$run2/source/link") == data.bin ]]
    cmp "$repository/data.bin" "$run2/source/data.bin"
    assert_contains "$project/cache/source-latest" "$sha2.101-1"
    assert_not_exists "$snapshot"
    assert_not_exists "$snapshot.manifest.gz"

    orphan="$project/cache/source-snapshots/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.999-1"
    mkdir -p "$orphan"
    printf 'orphan\n' > "$orphan/file"
    printf 'orphan manifest\n' | gzip -1 > "$orphan.manifest.gz"
    mkdir -p "$run3/source" "$run3/control" "$run3/build" \
        "$run3/install" "$run3/results"
    touch "$run3/.ci-created"
    output=$(HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$run3" "$sha2" baseline)
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    assert_contains <(printf '%s\n' "$output") "SOURCE_CACHE_BASE_SHA=$sha2"
    assert_not_exists "$orphan"
    assert_not_exists "$orphan.manifest.gz"
    git -C "$repository" diff --binary --full-index --no-renames \
        "$sha2" "$sha2" | gzip -1 > "$transfer/source-payload.gz"
    git -C "$repository" ls-tree -r -z --full-tree "$sha2" \
        | gzip -1 > "$transfer/source-manifest.gz"
    HOME=$home bash ci/sai/source_transfer_cache.sh receive \
        "$project" "$run3" "$transfer" delta "$sha2" > /dev/null
    HOME=$home bash ci/sai/source_transfer_cache.sh finalize \
        "$project" "$run3" "$transfer" "$sha2" > /dev/null

    snapshot_name=$(<"$project/cache/source-latest")
    snapshot="$project/cache/source-snapshots/$snapshot_name"
    printf 'cache drift\n' > "$snapshot/keep.txt"

    mkdir -p "$invalid_candidate/source" "$invalid_candidate/control" \
        "$invalid_candidate/build" "$invalid_candidate/install" \
        "$invalid_candidate/results"
    touch "$invalid_candidate/.ci-created"
    output=$(HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$invalid_candidate" "$sha2" candidate \
        2> "$root/candidate-drift.err")
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    assert_contains <(printf '%s\n' "$output") 'SOURCE_CACHE_BASE_SHA=none'
    assert_contains "$root/candidate-drift.err" \
        'content_or_manifest_mismatch role=candidate'
    assert_contains "$project/cache/source-latest" "$snapshot_name"
    assert_not_exists "$project/cache/.source-latest.invalid.110-1"
    assert_contains "$snapshot/keep.txt" 'cache drift'
    git -C "$repository" diff --binary --full-index --no-renames \
        "$(git -C "$repository" hash-object -t tree /dev/null)" "$sha2" \
        | gzip -1 > "$transfer/source-payload.gz"
    git -C "$repository" ls-tree -r -z --full-tree "$sha2" \
        | gzip -1 > "$transfer/source-manifest.gz"
    HOME=$home bash ci/sai/source_transfer_cache.sh receive \
        "$project" "$invalid_candidate" "$transfer" full "$sha2" > /dev/null
    HOME=$home bash ci/sai/source_transfer_cache.sh finalize \
        "$project" "$invalid_candidate" "$transfer" "$sha2" > /dev/null
    assert_contains "$invalid_candidate/source/keep.txt" 'changed'
    assert_contains "$project/cache/source-latest" "$snapshot_name"
    assert_contains "$snapshot/keep.txt" 'cache drift'

    mkdir -p "$run4/source" "$run4/control" "$run4/build" \
        "$run4/install" "$run4/results"
    touch "$run4/.ci-created"
    output=$(HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$run4" "$sha2" baseline 2> "$root/drift.err")
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    assert_contains <(printf '%s\n' "$output") 'SOURCE_CACHE_BASE_SHA=none'
    assert_contains "$root/drift.err" 'content_or_manifest_mismatch'
    assert_file "$project/cache/.source-latest.invalid.103-1"
    [[ -z $(find "$transfer/source" -mindepth 1 -print -quit) ]]
    git -C "$repository" diff --binary --full-index --no-renames \
        "$(git -C "$repository" hash-object -t tree /dev/null)" "$sha2" \
        | gzip -1 > "$transfer/source-payload.gz"
    git -C "$repository" ls-tree -r -z --full-tree "$sha2" \
        | gzip -1 > "$transfer/source-manifest.gz"
    HOME=$home bash ci/sai/source_transfer_cache.sh receive \
        "$project" "$run4" "$transfer" full "$sha2" > /dev/null
    HOME=$home bash ci/sai/source_transfer_cache.sh finalize \
        "$project" "$run4" "$transfer" "$sha2" > /dev/null

    snapshot_name=$(<"$project/cache/source-latest")
    snapshot="$project/cache/source-snapshots/$snapshot_name"
    printf 'extra\n' > "$snapshot/untracked.txt"
    mkdir -p "$run5/source" "$run5/control" "$run5/build" \
        "$run5/install" "$run5/results"
    touch "$run5/.ci-created"
    output=$(HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$run5" "$sha2" baseline 2> "$root/extra.err")
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    assert_contains <(printf '%s\n' "$output") 'SOURCE_CACHE_BASE_SHA=none'
    assert_contains "$root/extra.err" 'content_or_manifest_mismatch'
    git -C "$repository" diff --binary --full-index --no-renames \
        "$(git -C "$repository" hash-object -t tree /dev/null)" "$sha2" \
        | gzip -1 > "$transfer/source-payload.gz"
    git -C "$repository" ls-tree -r -z --full-tree "$sha2" \
        | gzip -1 > "$transfer/source-manifest.gz"
    HOME=$home bash ci/sai/source_transfer_cache.sh receive \
        "$project" "$run5" "$transfer" full "$sha2" > /dev/null
    HOME=$home bash ci/sai/source_transfer_cache.sh finalize \
        "$project" "$run5" "$transfer" "$sha2" > /dev/null

    printf 'not-a-cache-pointer\n' > "$project/cache/source-latest"
    mkdir -p "$run6/source" "$run6/control" "$run6/build" \
        "$run6/install" "$run6/results"
    touch "$run6/.ci-created"
    output=$(HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$run6" "$sha2" baseline \
        2> "$root/malformed-pointer.err")
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    assert_contains <(printf '%s\n' "$output") 'SOURCE_CACHE_BASE_SHA=none'
    assert_contains "$root/malformed-pointer.err" 'malformed_pointer'
    git -C "$repository" diff --binary --full-index --no-renames \
        "$(git -C "$repository" hash-object -t tree /dev/null)" "$sha2" \
        | gzip -1 > "$transfer/source-payload.gz"
    git -C "$repository" ls-tree -r -z --full-tree "$sha2" \
        | gzip -1 > "$transfer/source-manifest.gz"
    HOME=$home bash ci/sai/source_transfer_cache.sh receive \
        "$project" "$run6" "$transfer" full "$sha2" > /dev/null
    HOME=$home bash ci/sai/source_transfer_cache.sh finalize \
        "$project" "$run6" "$transfer" "$sha2" > /dev/null

    printf '%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.777-1 \
        > "$project/cache/source-latest"
    mkdir -p "$run7/source" "$run7/control" "$run7/build" \
        "$run7/install" "$run7/results"
    touch "$run7/.ci-created"
    output=$(HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$run7" "$sha2" baseline \
        2> "$root/dangling-pointer.err")
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    assert_contains <(printf '%s\n' "$output") 'SOURCE_CACHE_BASE_SHA=none'
    assert_contains "$root/dangling-pointer.err" 'content_or_manifest_mismatch'
    git -C "$repository" diff --binary --full-index --no-renames \
        "$(git -C "$repository" hash-object -t tree /dev/null)" "$sha2" \
        | gzip -1 > "$transfer/source-payload.gz"
    git -C "$repository" ls-tree -r -z --full-tree "$sha2" \
        | gzip -1 > "$transfer/source-manifest.gz"
    HOME=$home bash ci/sai/source_transfer_cache.sh receive \
        "$project" "$run7" "$transfer" full "$sha2" > /dev/null
    HOME=$home bash ci/sai/source_transfer_cache.sh finalize \
        "$project" "$run7" "$transfer" "$sha2" > /dev/null

    mkdir -p "$run8/source" "$run8/control" "$run8/build" \
        "$run8/install" "$run8/results"
    touch "$run8/.ci-created"
    output=$(HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$run8" "$sha2" baseline)
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    git -C "$repository" ls-tree -r -z --full-tree "$sha2" \
        | gzip -1 > "$transfer/source-manifest.gz"
    printf 'not gzip\n' > "$transfer/source-payload.gz"
    if HOME=$home bash ci/sai/source_transfer_cache.sh receive \
        "$project" "$run8" "$transfer" delta "$sha2" > /dev/null 2>&1; then
        fail 'source transfer accepted a malformed gzip payload'
    fi
    printf 'not a Git patch\n' | gzip -1 > "$transfer/source-payload.gz"
    if HOME=$home bash ci/sai/source_transfer_cache.sh receive \
        "$project" "$run8" "$transfer" delta "$sha2" > /dev/null 2>&1; then
        fail 'source transfer accepted an invalid Git patch'
    fi

    mkdir -p "$run9/source" "$run9/control" "$run9/build" \
        "$run9/install" "$run9/results"
    touch "$run9/.ci-created"
    output=$(HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$run9" "$sha2" baseline)
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    rm "$transfer/source/windows.bat"
    git -C "$repository" diff --binary --full-index --no-renames \
        "$sha2" "$sha2" | gzip -1 > "$transfer/source-payload.gz"
    git -C "$repository" ls-tree -r -z --full-tree "$sha2" \
        | head -c -1 | gzip -1 > "$transfer/source-manifest.gz"
    HOME=$home bash ci/sai/source_transfer_cache.sh receive \
        "$project" "$run9" "$transfer" delta "$sha2" > /dev/null
    if HOME=$home bash ci/sai/source_transfer_cache.sh finalize \
        "$project" "$run9" "$transfer" "$sha2" > /dev/null 2>&1; then
        fail 'source transfer accepted a manifest with an unterminated record'
    fi

    if HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$run2" "$sha2" > /dev/null 2>&1; then
        fail 'source transfer accepted an omitted cache role'
    fi
    if HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$run2" "$sha2" baseline > /dev/null 2>&1; then
        fail 'source transfer accepted a reused run key'
    fi
}

test_prepare_cleanup_install() {
    local root=$test_root/cleanup-staging
    local home=$root/home
    local outside=$root/outside
    local project=$home/project
    local output=$root/prepare.out
    local registry_home=$root/registry-home
    mkdir -p "$home" "$outside"

    HOME=$home bash ci/sai/prepare_cleanup_install.sh "$project" 300-1 \
        > "$output"
    assert_file "$project/diagnostics/cleanup-300-1/cleanup_sai_runs.sh"
    assert_file "$project/diagnostics/cleanup-300-1/.ci-diagnostic"
    assert_contains "$output" "SAI_PROJECT_ROOT=$project"
    assert_contains "$output" \
        "CLEANUP_STAGING_FILE=$project/diagnostics/cleanup-300-1/cleanup_sai_runs.sh"
    assert_contains "$home/.config/abacus-sai-ci/project-roots" "$project"
    if HOME=$home bash ci/sai/prepare_cleanup_install.sh \
        "$project" 300-1 > /dev/null 2>&1; then
        fail 'cleanup staging collision was accepted'
    fi

    ln -s "$outside" "$home/escape"
    if HOME=$home bash ci/sai/prepare_cleanup_install.sh \
        "$home/escape/project" 301-1 > /dev/null 2>&1; then
        fail 'cleanup staging symlink escape was accepted'
    fi

    mkdir -p "$registry_home/.config/abacus-sai-ci"
    printf 'registry-sentinel\n' > "$root/registry-target"
    ln -s "$root/registry-target" \
        "$registry_home/.config/abacus-sai-ci/project-roots"
    if HOME=$registry_home bash ci/sai/prepare_cleanup_install.sh \
        "$registry_home/project" 302-1 > /dev/null 2>&1; then
        fail 'cleanup staging accepted a registry leaf symlink'
    fi
    [[ $(<"$root/registry-target") == registry-sentinel ]]
}

make_cached_archive() {
    local destination=$1
    local sha=$2
    local header=$3
    local library=$4
    mkdir -p "$destination/include" "$destination/lib"
    : > "$destination/include/$header"
    : > "$destination/lib/$library"
    printf '%s\n' "$sha" > "$destination/.archive-sha256"
}

test_nvidia_archive_cache() {
    local root=$test_root/archive-cache
    local project=$root/project
    local vendor=$project/vendor/nvidia-mp-0.9-archive
    local cusolver=$vendor/libcusolvermp-linux-x86_64-0.9.0.6427_cuda12-archive
    local cublas=$vendor/libcublasmp-linux-x86_64-0.9.1.3056_cuda12-archive
    local fake_bin=$root/bin
    local curl_called=$root/curl-called
    local tarlink_project=$root/tarlink-project
    local tarlink_downloads=$tarlink_project/vendor/downloads
    local tarlink_outside=$root/tarlink-outside
    mkdir -p "$fake_bin" "$project/vendor/downloads"
    printf 'lock-sentinel\n' > "$root/lock-target"
    ln -s "$root/lock-target" \
        "$project/vendor/downloads/.nvidia-mp-download.lock"
    make_cached_archive "$cusolver" \
        3b071ce69c6a6a6bb7add8784e6a3fc54e9a64a8f2c1c7da40b03bcde39eb57c \
        cusolverMp.h libcusolverMp.so.0
    make_cached_archive "$cublas" \
        35fea4df2bb08a496981f34c0d486f0753d3766a31d60dbe6daa6f16673cd1cc \
        cublasmp.h libcublasmp.so.0
    cat > "$fake_bin/curl" <<EOF
#!/usr/bin/env bash
touch "$curl_called"
exit 99
EOF
    chmod +x "$fake_bin/curl"

    PATH="$fake_bin:$original_path" HOME=$root TMPDIR=$root/missing-tmp \
    SAI_PROJECT_ROOT=$project \
        bash ci/sai/prepare_nvidia_mp.sh > "$root/reuse.log"
    assert_not_exists "$curl_called"
    assert_contains "$root/reuse.log" 'NVIDIA_MP_ARCHIVES_READY'
    [[ $(<"$root/lock-target") == lock-sentinel ]]

    printf '%s\n' bad-sha > "$cublas/.archive-sha256"
    if PATH="$fake_bin:$original_path" HOME=$root TMPDIR=$root/missing-tmp \
        SAI_PROJECT_ROOT=$project \
        bash ci/sai/prepare_nvidia_mp.sh > /dev/null 2> "$root/mismatch.err"; then
        fail 'mismatched extracted archive cache was accepted'
    fi
    assert_contains "$root/mismatch.err" 'cache'
    assert_not_exists "$curl_called"

    mkdir -p "$tarlink_downloads" "$tarlink_outside"
    ln -s "$tarlink_outside" \
        "$tarlink_downloads/libcusolvermp-linux-x86_64-0.9.0.6427_cuda12-archive.tar.xz"
    if PATH="$fake_bin:$original_path" HOME=$root TMPDIR=$root/missing-tmp \
        SAI_PROJECT_ROOT=$tarlink_project \
        bash ci/sai/prepare_nvidia_mp.sh > /dev/null 2> "$root/tarlink.err"; then
        fail 'tarball cache symlink to an outside directory was accepted'
    fi
    assert_contains "$root/tarlink.err" 'tarball cache'
    assert_not_exists "$curl_called"
    [[ -z $(find "$tarlink_outside" -mindepth 1 -print -quit) ]]

    mkdir -p "$root/escaped-project" "$root/outside-vendor"
    ln -s "$root/outside-vendor" "$root/escaped-project/vendor"
    if PATH="$fake_bin:$original_path" HOME=$root TMPDIR=$root/missing-tmp \
        SAI_PROJECT_ROOT=$root/escaped-project \
        bash ci/sai/prepare_nvidia_mp.sh > /dev/null 2> "$root/escape.err"; then
        fail 'vendor symlink escape was accepted'
    fi
    assert_not_exists "$curl_called"
}

test_artifact_collection() {
    local root=$test_root/artifacts
    local home=$root/home
    local run=$home/project/runs/200-1
    local empty_extract=$root/empty
    local full_extract=$root/full
    mkdir -p "$run/results" "$empty_extract" "$full_extract"
    : > "$run/.ci-created"

    HOME=$home TMPDIR=$root/missing-tmp \
        bash ci/sai/collect_remote_artifacts.sh "$run" \
        | tar -xzf - -C "$empty_extract"
    assert_file "$empty_extract/.ci-created"

    mkdir -p "$run/results/case-matrix" \
        "$run/source/tests/11_GPU/case/OUT.test"
    printf 'summary\n' > "$run/results/case-matrix/summary.md"
    printf 'ignore\n' > "$run/results/case-matrix/raw.bin"
    printf 'result\n' > "$run/source/tests/11_GPU/case/result.out"
    printf 'running\n' > "$run/source/tests/11_GPU/case/OUT.test/running.log"
    HOME=$home TMPDIR=$root/missing-tmp \
        bash ci/sai/collect_remote_artifacts.sh "$run" \
        | tar -xzf - -C "$full_extract"
    assert_file "$full_extract/results/case-matrix/summary.md"
    assert_file "$full_extract/source/tests/11_GPU/case/result.out"
    assert_file "$full_extract/source/tests/11_GPU/case/OUT.test/running.log"
    assert_not_exists "$full_extract/results/case-matrix/raw.bin"

    mkdir -p "$run/build" "$root/outside"
    printf 'outside\n' > "$root/outside/toolchain-summary.txt"
    ln -s "$root/outside/toolchain-summary.txt" \
        "$run/build/toolchain-summary.txt"
    if HOME=$home TMPDIR=$root/missing-tmp \
        bash ci/sai/collect_remote_artifacts.sh "$run" \
        > "$root/escaped.tar.gz" 2> "$root/escape.err"; then
        fail 'artifact collector accepted a symlink escape'
    fi
}

make_cleanup_fixture() {
    local home=$1
    local project=$home/project
    mkdir -p "$project/runs" "$project/diagnostics" \
        "$project/cache/source-transfers/206-1" \
        "$project/cache/source-transfers/207-1" \
        "$home/.config/abacus-sai-ci"
    printf '%s\n' "$project" > "$home/.config/abacus-sai-ci/project-roots"

    mkdir -p "$project/runs/201-1/results"
    : > "$project/runs/201-1/.artifacts-uploaded"
    touch -d '73 hours ago' "$project/runs/201-1/.artifacts-uploaded"

    mkdir -p "$project/runs/202-1/results"
    : > "$project/runs/202-1/.artifacts-uploaded"
    touch -d '71 hours ago' "$project/runs/202-1/.artifacts-uploaded"

    mkdir -p "$project/runs/203-1/results"
    : > "$project/runs/203-1/.ci-created"
    touch -d '169 hours ago' "$project/runs/203-1/.ci-created"

    mkdir -p "$project/runs/204-1/results"
    : > "$project/runs/204-1/.artifacts-uploaded"
    touch -d '73 hours ago' "$project/runs/204-1/.artifacts-uploaded"
    printf 'SLURM_JOB_ID=701\n' > "$project/runs/204-1/results/build-submit.log"

    mkdir -p "$project/runs/205-1/results"
    : > "$project/runs/205-1/.artifacts-uploaded"
    touch -d '73 hours ago' "$project/runs/205-1/.artifacts-uploaded"
    printf 'SLURM_JOB_ID=702\n' > "$project/runs/205-1/results/build-submit.log"

    mkdir -p "$project/runs/pr-7658/208-1/results"
    : > "$project/runs/pr-7658/208-1/.artifacts-uploaded"
    touch -d '73 hours ago' \
        "$project/runs/pr-7658/208-1/.artifacts-uploaded"

    mkdir -p "$project/diagnostics/diagnostic-old"
    : > "$project/diagnostics/diagnostic-old/.ci-diagnostic"
    touch -d '169 hours ago' "$project/diagnostics/diagnostic-old/.ci-diagnostic"

    : > "$project/cache/source-transfers/206-1/.ci-source-transfer"
    touch -d '169 hours ago' \
        "$project/cache/source-transfers/206-1/.ci-source-transfer"
    : > "$project/cache/source-transfers/207-1/.ci-source-transfer"
    touch -d '167 hours ago' \
        "$project/cache/source-transfers/207-1/.ci-source-transfer"

    diagnostic_only=$home/diagnostic-only
    mkdir -p "$diagnostic_only/diagnostics/diagnostic-old"
    : > "$diagnostic_only/diagnostics/diagnostic-old/.ci-diagnostic"
    touch -d '169 hours ago' \
        "$diagnostic_only/diagnostics/diagnostic-old/.ci-diagnostic"
    printf '%s\n' "$diagnostic_only" >> \
        "$home/.config/abacus-sai-ci/project-roots"
}

test_cleanup_retention() {
    local root=$test_root/cleanup
    local home=$root/home
    local project=$home/project
    local fake_bin=$root/bin
    local squeue_mode=$root/squeue-mode
    local squeue_log=$root/squeue.log
    local escape_home=$root/escape-home
    local leaf_home=$root/leaf-home
    mkdir -p "$fake_bin"
    make_cleanup_fixture "$home"
    cat > "$fake_bin/squeue" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$squeue_log"
[[ " \$* " == *' --noheader '* ]]
[[ " \$* " == *' --user='* ]]
[[ " \$* " == *' --format=%F '* ]]
if [[ -f "$squeue_mode" ]]; then
    exit 1
fi
echo 701
EOF
    chmod +x "$fake_bin/squeue"

    PATH="$fake_bin:$original_path" HOME=$home \
        bash ci/sai/cleanup_sai_runs.sh --dry-run > "$root/dry-run.log"
    assert_contains "$root/dry-run.log" "DRY_RUN delete path=$project/runs/201-1"
    assert_contains "$root/dry-run.log" "DRY_RUN delete path=$project/runs/203-1"
    assert_contains "$root/dry-run.log" "DRY_RUN delete path=$project/runs/205-1"
    assert_contains "$root/dry-run.log" \
        "DRY_RUN delete path=$project/runs/pr-7658/208-1"
    assert_contains "$root/dry-run.log" "DRY_RUN delete path=$project/diagnostics/diagnostic-old"
    assert_contains "$root/dry-run.log" "DRY_RUN delete path=$project/cache/source-transfers/206-1"
    assert_contains "$root/dry-run.log" "DRY_RUN delete path=$home/diagnostic-only/diagnostics/diagnostic-old"
    assert_contains "$root/dry-run.log" "SKIP active_or_unknown path=$project/runs/204-1"
    assert_file "$project/runs/201-1/.artifacts-uploaded"
    [[ -d $project/runs/pr-7658 ]]

    : > "$squeue_mode"
    PATH="$fake_bin:$original_path" HOME=$home \
        bash ci/sai/cleanup_sai_runs.sh > "$root/cleanup.log"
    assert_not_exists "$project/runs/201-1"
    assert_not_exists "$project/runs/203-1"
    assert_not_exists "$project/runs/pr-7658/208-1"
    [[ -d $project/runs/pr-7658 ]]
    assert_not_exists "$project/diagnostics/diagnostic-old"
    assert_not_exists "$project/cache/source-transfers/206-1"
    assert_not_exists "$home/diagnostic-only/diagnostics/diagnostic-old"
    assert_file "$project/runs/202-1/.artifacts-uploaded"
    assert_file "$project/runs/204-1/.artifacts-uploaded"
    assert_file "$project/runs/205-1/.artifacts-uploaded"
    assert_file "$project/cache/source-transfers/207-1/.ci-source-transfer"

    mkdir -p "$escape_home" "$root/outside-cache"
    ln -s "$root/outside-cache" "$escape_home/.cache"
    if PATH="$fake_bin:$original_path" HOME=$escape_home \
        bash ci/sai/cleanup_sai_runs.sh --dry-run > /dev/null 2>&1; then
        fail 'cleanup accepted a .cache symlink escape'
    fi
    assert_not_exists "$root/outside-cache/abacus-sai-ci"

    mkdir -p "$leaf_home/.cache/abacus-sai-ci" \
        "$leaf_home/.local/state/abacus-sai-ci"
    printf 'leaf-sentinel\n' > "$root/leaf-target"
    ln -s "$root/leaf-target" "$leaf_home/.cache/abacus-sai-ci/cleanup.lock"
    PATH="$fake_bin:$original_path" HOME=$leaf_home \
        bash ci/sai/cleanup_sai_runs.sh --dry-run > /dev/null
    [[ $(<"$root/leaf-target") == leaf-sentinel ]]
    ln -s "$root/leaf-target" "$leaf_home/.local/state/abacus-sai-ci/cleanup.log"
    if PATH="$fake_bin:$original_path" HOME=$leaf_home \
        bash ci/sai/cleanup_sai_runs.sh --cron > /dev/null 2>&1; then
        fail 'cleanup accepted a log leaf symlink'
    fi
    [[ $(<"$root/leaf-target") == leaf-sentinel ]]
}

test_cleanup_cron_installation() {
    local root=$test_root/cleanup-cron
    local home=$root/home
    local project=$home/project
    local fake_bin=$root/bin
    local crontab_file=$root/crontab
    local original=$root/original-crontab
    local crontab_failure=$root/crontab-failure
    local staging_root=$project/diagnostics/cleanup-999-1
    local staged_cleanup=$staging_root/cleanup_sai_runs.sh
    local escape_home=$root/escape-home
    local escape_project=$escape_home/project
    local escape_staging_root=$escape_project/diagnostics/cleanup-998-1
    local escape_staged=$escape_staging_root/cleanup_sai_runs.sh
    local missing_tmp=$root/missing-tmp
    local leaf_home=$root/leaf-home
    local leaf_project=$leaf_home/project
    local leaf_staging_root=$leaf_project/diagnostics/cleanup-997-1
    local leaf_staged=$leaf_staging_root/cleanup_sai_runs.sh
    mkdir -p "$fake_bin" "$project"
    stage_cleanup() {
        mkdir -p "$staging_root"
        : > "$staging_root/.ci-diagnostic"
        cp ci/sai/cleanup_sai_runs.sh "$staged_cleanup"
    }
    cat > "$fake_bin/crontab" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == -l ]]; then
    if [[ -f "$crontab_failure" ]]; then
        echo 'simulated crontab backend failure' >&2
        exit 2
    elif [[ -f "$crontab_file" ]]; then
        cat "$crontab_file"
    else
        echo "no crontab for \${USER:-unknown}" >&2
        exit 1
    fi
else
    cp "\$1" "$crontab_file"
fi
EOF
    chmod +x "$fake_bin/crontab"

    stage_cleanup
    PATH="$fake_bin:$original_path" HOME=$home TMPDIR=$missing_tmp \
        bash ci/sai/install_cleanup_cron.sh "$project" "$staged_cleanup" \
        > "$root/first-install.log"
    assert_contains "$crontab_file" '15 7 * * * $HOME/.local/libexec/abacus-sai-ci/cleanup_sai_runs.sh --cron'

    printf '%s\n' '5 1 * * * existing-job' > "$crontab_file"
    cp "$crontab_file" "$original"
    : > "$crontab_failure"
    stage_cleanup
    if PATH="$fake_bin:$original_path" HOME=$home TMPDIR=$missing_tmp \
        bash ci/sai/install_cleanup_cron.sh "$project" "$staged_cleanup" \
        > /dev/null 2> "$root/read-failure.err"; then
        fail 'cleanup installer replaced crontab after a read failure'
    fi
    cmp "$original" "$crontab_file"
    rm -f "$crontab_failure"

    printf '%s\n' '# BEGIN ABACUS_SAI_CI_CLEANUP' '5 1 * * * existing-job' \
        > "$crontab_file"
    cp "$crontab_file" "$original"
    stage_cleanup
    if PATH="$fake_bin:$original_path" HOME=$home TMPDIR=$missing_tmp \
        bash ci/sai/install_cleanup_cron.sh "$project" "$staged_cleanup" \
        > /dev/null 2> "$root/invalid.err"; then
        fail 'cleanup installer accepted an unmatched cron marker'
    fi
    cmp "$original" "$crontab_file"

    printf '%s\n' \
        'MAILTO=owner@example.invalid' \
        '# BEGIN ABACUS_SAI_CI_CLEANUP' \
        '0 0 * * * obsolete-cleanup' \
        '# END ABACUS_SAI_CI_CLEANUP' \
        '5 1 * * * existing-job' > "$crontab_file"
    PATH="$fake_bin:$original_path" HOME=$home TMPDIR=$missing_tmp \
        bash ci/sai/install_cleanup_cron.sh "$project" "$staged_cleanup" \
        > "$root/install.log"
    assert_contains "$crontab_file" 'MAILTO=owner@example.invalid'
    assert_contains "$crontab_file" '5 1 * * * existing-job'
    assert_contains "$crontab_file" '15 7 * * * $HOME/.local/libexec/abacus-sai-ci/cleanup_sai_runs.sh --cron'
    [[ $(grep -Fc '# BEGIN ABACUS_SAI_CI_CLEANUP' "$crontab_file") -eq 1 ]]
    [[ $(grep -Fc '# END ABACUS_SAI_CI_CLEANUP' "$crontab_file") -eq 1 ]]
    assert_contains "$home/.config/abacus-sai-ci/project-roots" "$project"
    assert_not_contains "$root/install.log" 'MAILTO=owner@example.invalid'
    assert_not_contains "$root/install.log" '5 1 * * * existing-job'

    mkdir -p "$escape_home" "$escape_project" "$root/outside-local"
    ln -s "$root/outside-local" "$escape_home/.local"
    mkdir -p "$escape_staging_root"
    : > "$escape_staging_root/.ci-diagnostic"
    cp ci/sai/cleanup_sai_runs.sh "$escape_staged"
    if PATH="$fake_bin:$original_path" HOME=$escape_home TMPDIR=$missing_tmp \
        bash ci/sai/install_cleanup_cron.sh \
        "$escape_project" "$escape_staged" > /dev/null 2>&1; then
        fail 'cleanup installer accepted a .local symlink escape'
    fi
    assert_not_exists "$root/outside-local/state"

    mkdir -p "$leaf_staging_root" \
        "$leaf_home/.local/libexec/abacus-sai-ci"
    : > "$leaf_staging_root/.ci-diagnostic"
    cp ci/sai/cleanup_sai_runs.sh "$leaf_staged"
    printf 'install-sentinel\n' > "$root/install-target"
    ln -s "$root/install-target" \
        "$leaf_home/.local/libexec/abacus-sai-ci/cleanup_sai_runs.sh"
    if PATH="$fake_bin:$original_path" HOME=$leaf_home TMPDIR=$missing_tmp \
        bash ci/sai/install_cleanup_cron.sh \
        "$leaf_project" "$leaf_staged" > /dev/null 2>&1; then
        fail 'cleanup installer accepted a target leaf symlink'
    fi
    [[ $(<"$root/install-target") == install-sentinel ]]
}

test_mark_artifacts_uploaded() {
    local root=$test_root/mark-uploaded
    local home=$root/home
    local run=$home/project/runs/400-1
    mkdir -p "$run"
    printf 'upload-sentinel\n' > "$root/upload-target"
    ln -s "$root/upload-target" "$run/.artifacts-uploaded"

    HOME=$home TMPDIR=$root/missing-tmp \
        bash ci/sai/mark_artifacts_uploaded.sh "$run"
    [[ ! -L $run/.artifacts-uploaded ]]
    assert_contains "$run/.artifacts-uploaded" 'uploaded_epoch='
    [[ $(<"$root/upload-target") == upload-sentinel ]]
}

test_slurm_signal_cancellation() {
    local root=$test_root/slurm-signal
    local fake_bin=$root/bin
    local submit_log=$root/submit.log
    local output_pattern=$root/job-%j.out
    local cancel_log=$root/scancel.log
    local pid rc
    mkdir -p "$fake_bin" "$root/source"
    : > "$root/job.sbatch"
    cat > "$fake_bin/sbatch" <<'EOF'
#!/usr/bin/env bash
echo 801
EOF
    cat > "$fake_bin/sacct" <<'EOF'
#!/usr/bin/env bash
echo '801 RUNNING 0:0'
EOF
    cat > "$fake_bin/scancel" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$cancel_log"
EOF
    chmod +x "$fake_bin/sbatch" "$fake_bin/sacct" "$fake_bin/scancel"

    PATH="$fake_bin:$original_path" HOME=$test_root TMPDIR=$root/missing-tmp \
    CI_SOURCE=$root/source \
    GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 \
        bash ci/sai/run_slurm_job.sh "$submit_log" "$output_pattern" \
        "$root/job.sbatch" > "$root/driver.log" 2>&1 &
    pid=$!
    wait_for_file "$submit_log"
    kill -TERM "$pid"
    set +e
    wait "$pid"
    rc=$?
    set -e
    [[ $rc -eq 143 ]] || fail "TERM returned $rc instead of 143"
    assert_contains "$cancel_log" '801'
}

test_slurm_launch_window_cancellation() {
    local root=$test_root/slurm-launch-signal
    local fake_bin=$root/bin
    local submit_log=$root/submit.log
    local output_pattern=$root/job-%j.out
    local cancel_log=$root/scancel.log
    local ready=$root/sbatch-ready
    local pid rc
    mkdir -p "$fake_bin" "$root/source"
    : > "$root/job.sbatch"
    cat > "$fake_bin/sbatch" <<EOF
#!/usr/bin/env bash
echo 802
touch "$ready"
trap 'exit 143' TERM HUP INT
while true; do sleep 1; done
EOF
    cat > "$fake_bin/scancel" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$cancel_log"
EOF
    chmod +x "$fake_bin/sbatch" "$fake_bin/scancel"

    PATH="$fake_bin:$original_path" HOME=$test_root TMPDIR=$root/missing-tmp \
    CI_SOURCE=$root/source \
    GITHUB_RUN_ID=2 GITHUB_RUN_ATTEMPT=1 \
        bash ci/sai/run_slurm_job.sh "$submit_log" "$output_pattern" \
        "$root/job.sbatch" > "$root/driver.log" 2>&1 &
    pid=$!
    wait_for_file "$ready"
    kill -HUP "$pid"
    set +e
    wait "$pid"
    rc=$?
    set -e
    [[ $rc -eq 143 ]] || fail "launch-window HUP returned $rc instead of 143"
    assert_contains "$cancel_log" '802'
}

run_test 'SSH client configuration' test_configure_ssh_client
run_test 'source payload builder' test_build_source_payload
run_test 'committed control snapshot' test_prepare_control_snapshot
run_test 'remote probe identity' test_remote_probe_identity
run_test 'local client SSH probe' test_local_client_probe
run_test 'workflow security policy' test_workflow_security_policy
run_test 'control executable modes' test_control_executable_modes
run_test 'PMIx startup retry policy' test_pmix_startup_retry
run_test 'GPU matrix submission policy' test_gpu_matrix_submission_policy
run_test 'GPU case symlink rejection' test_gpu_case_symlink_rejection
run_test 'cuSolverMp smoke staging' test_prepare_cusolvermp_smoke
run_test 'remote path containment and collision' test_prepare_remote_run_paths
run_test 'compressed source snapshot cache' test_source_snapshot_cache
run_test 'cleanup staging containment and collision' test_prepare_cleanup_install
run_test 'NVIDIA archive cache reuse and rejection' test_nvidia_archive_cache
run_test 'artifact collection whitelist' test_artifact_collection
run_test 'uploaded marker atomic replacement' test_mark_artifacts_uploaded
run_test 'cleanup retention and active-job safety' test_cleanup_retention
run_test 'cleanup cron installation safety' test_cleanup_cron_installation
run_test 'Slurm TERM cancellation' test_slurm_signal_cancellation
run_test 'Slurm launch-window HUP cancellation' test_slurm_launch_window_cancellation

echo "ALL TESTS PASSED ($tests_run)"
