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

extract_workflow_run_script() {
    local step_name=$1
    local output=$2
    python3 - .github/workflows/sai-gpu-full.yml "$step_name" "$output" <<'PY'
import sys

workflow, step_name, output = sys.argv[1:]
with open(workflow, encoding="utf-8") as handle:
    lines = handle.readlines()

step_marker = f"      - name: {step_name}\n"
try:
    step_start = lines.index(step_marker)
except ValueError as error:
    raise SystemExit(f"workflow step not found: {step_name}") from error

run_start = None
for index in range(step_start + 1, len(lines)):
    if lines[index] == "        run: |\n":
        run_start = index + 1
        break
    if lines[index].startswith("      - name:"):
        break
if run_start is None:
    raise SystemExit(f"run block not found for workflow step: {step_name}")

script = []
for line in lines[run_start:]:
    if line.strip() and not line.startswith("          "):
        break
    script.append(line[10:] if line.startswith("          ") else line)
with open(output, "w", encoding="utf-8") as handle:
    handle.writelines(script)
PY
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
    assert_contains ci/sai/probe_remote_sai.sh \
        'expected_canonical_home=/org/abacus-group/$expected_user'
    assert_contains ci/sai/probe_remote_sai.sh 'Unexpected canonical HOME'
    if PATH="$fake_bin:$original_path" HOME=$root/home \
        bash ci/sai/probe_remote_sai.sh wronguser > /dev/null 2>&1; then
        fail 'remote probe accepted the wrong expected user'
    fi
}

test_authorize_pr_comment() {
    local root=$test_root/pr-comment
    local fake_bin=$root/bin
    local event=$root/event.json
    local output=$root/output
    local summary=$root/summary
    local check_request=$root/check-request.json
    local sha=1111111111111111111111111111111111111111
    mkdir -p "$fake_bin"

    : > "$output"
    : > "$summary"
    GITHUB_EVENT_NAME=schedule GITHUB_OUTPUT=$output \
    GITHUB_REPOSITORY=Stardust0831/abacus-develop GITHUB_SHA=$sha \
    GITHUB_STEP_SUMMARY=$summary \
        bash ci/sai/authorize_pr_comment.sh
    assert_contains "$output" 'accepted=true'
    assert_contains "$output" 'run_namespace=daily'
    assert_contains "$output" "source_sha=$sha"

    : > "$output"
    : > "$summary"
    GITHUB_EVENT_NAME=workflow_dispatch GITHUB_OUTPUT=$output \
    GITHUB_REPOSITORY=Stardust0831/abacus-develop \
    GITHUB_STEP_SUMMARY=$summary MANUAL_RUN_NAMESPACE=manual-trial \
    MANUAL_SOURCE_SHA=$sha \
        bash ci/sai/authorize_pr_comment.sh
    assert_contains "$output" 'accepted=true'
    assert_contains "$output" 'run_namespace=manual-trial'
    assert_contains "$output" "source_sha=$sha"

    cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *'/collaborators/'*'/permission '*)
        printf '{"permission":"%s","role_name":"%s"}\n' \
            "$FAKE_PERMISSION" "$FAKE_ROLE"
        ;;
    *'/pulls/'*)
        printf '{"state":"open","base":{"ref":"develop","repo":{"full_name":"Stardust0831/abacus-develop"}},"head":{"sha":"%s","repo":{"full_name":"contributor/abacus-develop"}}}\n' \
            "$FAKE_HEAD_SHA"
        ;;
    *'/check-runs '*)
        cat > "$FAKE_CHECK_REQUEST"
        printf '12345\n'
        ;;
    *)
        echo "Unexpected fake gh invocation: $*" >&2
        exit 2
        ;;
esac
EOF
    chmod +x "$fake_bin/gh"

    python3 - "$event" '/abacus-ci sai-gpu' maintainer 17 <<'PY'
import json
import sys

path, command, login, number = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "comment": {"body": command, "user": {"login": login}},
        "issue": {"number": int(number), "pull_request": {}},
        "repository": {"default_branch": "develop"},
    }, handle)
PY
    : > "$output"
    : > "$summary"
    PATH="$fake_bin:$original_path" \
    FAKE_PERMISSION=write FAKE_ROLE=maintain FAKE_HEAD_SHA=$sha \
    FAKE_CHECK_REQUEST=$check_request \
    GITHUB_EVENT_NAME=issue_comment GITHUB_EVENT_PATH=$event \
    GITHUB_OUTPUT=$output GITHUB_REPOSITORY=Stardust0831/abacus-develop \
    GITHUB_RUN_ID=98765 GITHUB_SERVER_URL=https://github.com \
    GITHUB_STEP_SUMMARY=$summary \
        bash ci/sai/authorize_pr_comment.sh

    assert_contains "$output" 'accepted=true'
    assert_contains "$output" 'check_run_id=12345'
    assert_contains "$output" 'pr_number=17'
    assert_contains "$output" 'run_namespace=pr-17'
    assert_contains "$output" 'source_repository=contributor/abacus-develop'
    assert_contains "$output" "source_sha=$sha"
    python3 - "$check_request" "$sha" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    request = json.load(handle)
assert request["head_sha"] == sys.argv[2]
assert request["status"] == "queued"
assert request["details_url"] == "https://github.com/Stardust0831/abacus-develop/actions/runs/98765"
PY
    assert_contains "$summary" 'Pull request: #17'

    python3 - "$event" '/abacus-ci sai-gpu' triager 20 <<'PY'
import json
import sys

path, command, login, number = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "comment": {"body": command, "user": {"login": login}},
        "issue": {"number": int(number), "pull_request": {}},
        "repository": {"default_branch": "develop"},
    }, handle)
PY
    : > "$output"
    : > "$summary"
    PATH="$fake_bin:$original_path" \
    FAKE_PERMISSION=triage FAKE_ROLE=triage FAKE_HEAD_SHA=$sha \
    FAKE_CHECK_REQUEST=$root/triage-check.json \
    GITHUB_EVENT_NAME=issue_comment GITHUB_EVENT_PATH=$event \
    GITHUB_OUTPUT=$output GITHUB_REPOSITORY=Stardust0831/abacus-develop \
    GITHUB_RUN_ID=98768 GITHUB_SERVER_URL=https://github.com \
    GITHUB_STEP_SUMMARY=$summary \
        bash ci/sai/authorize_pr_comment.sh
    assert_contains "$output" 'accepted=true'
    assert_contains "$output" 'pr_number=20'
    assert_file "$root/triage-check.json"

    python3 - "$event" '/abacus-ci sai-gpu' reader 18 <<'PY'
import json
import sys

path, command, login, number = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "comment": {"body": command, "user": {"login": login}},
        "issue": {"number": int(number), "pull_request": {}},
        "repository": {"default_branch": "develop"},
    }, handle)
PY
    : > "$output"
    : > "$summary"
    PATH="$fake_bin:$original_path" \
    FAKE_PERMISSION=read FAKE_ROLE=read FAKE_HEAD_SHA=$sha \
    FAKE_CHECK_REQUEST=$root/unauthorized-check.json \
    GITHUB_EVENT_NAME=issue_comment GITHUB_EVENT_PATH=$event \
    GITHUB_OUTPUT=$output GITHUB_REPOSITORY=Stardust0831/abacus-develop \
    GITHUB_RUN_ID=98766 GITHUB_SERVER_URL=https://github.com \
    GITHUB_STEP_SUMMARY=$summary \
        bash ci/sai/authorize_pr_comment.sh 2> "$root/unauthorized.err"
    assert_contains "$output" 'accepted=false'
    assert_contains "$output" 'run_namespace=unauthorized'
    assert_not_exists "$root/unauthorized-check.json"
    assert_contains "$root/unauthorized.err" 'repository role is read (read)'

    python3 - "$event" '/abacus-ci sai-gpu full' maintainer 19 <<'PY'
import json
import sys

path, command, login, number = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({
        "comment": {"body": command, "user": {"login": login}},
        "issue": {"number": int(number), "pull_request": {}},
        "repository": {"default_branch": "develop"},
    }, handle)
PY
    if PATH="$fake_bin:$original_path" \
        FAKE_PERMISSION=write FAKE_ROLE=maintain FAKE_HEAD_SHA=$sha \
        FAKE_CHECK_REQUEST=$root/wrong-command-check.json \
        GITHUB_EVENT_NAME=issue_comment GITHUB_EVENT_PATH=$event \
        GITHUB_OUTPUT=$output GITHUB_REPOSITORY=Stardust0831/abacus-develop \
        GITHUB_RUN_ID=98767 GITHUB_SERVER_URL=https://github.com \
        GITHUB_STEP_SUMMARY=$summary \
            bash ci/sai/authorize_pr_comment.sh >/dev/null 2>&1; then
        fail 'comment authorization accepted a command with extra arguments'
    fi
    assert_not_exists "$root/wrong-command-check.json"
}

test_pr_result_comment() {
    local root=$test_root/pr-result-comment
    local artifact_root=$root/artifacts
    local fake_bin=$root/bin
    local summary_script=$root/publish-summary.sh
    local report_script=$root/report-result.sh
    local summary_output=$root/summary-output
    local check_request=$root/check-request.json
    local comment_request=$root/comment-request.json
    local sha=1111111111111111111111111111111111111111
    mkdir -p "$artifact_root/results/case-matrix" "$fake_bin"
    python3 - "$artifact_root/results/case-matrix/result.json" <<'PY'
import json
import sys

resources = ["gpu1"] + ["gpu2"] * 7 + ["gpu4"] * 40 + ["gpu8x2"]
cases = []
for index, resource in enumerate(resources):
    suite, name, runner = "suite", f"case-{index:02d}", "autotest"
    if resource == "gpu8x2":
        suite = "15_rtTDDFT_GPU"
        name = "19_NO_Si48_CUSOLVERMP_TDDFT_GPU"
        runner = "cusolvermp"
    cases.append({
        "case_id": f"{suite}/{name}", "suite": suite, "name": name,
        "resource": resource, "runner": runner,
        "state": "FAIL" if index == 0 else "PASS",
        "exit_code": 1 if index == 0 else 0,
        "slurm_state": "FAILED" if index == 0 else "COMPLETED",
        "job_id": f"100_{index}", "elapsed_seconds": 3,
        "artifact_dir": f"/tmp/case-{index:02d}",
    })
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({
        "protocol": 1, "total": 49, "passed": 48, "failed": 1,
        "infrastructure": 0, "cases": cases,
    }, handle)
PY
    printf '# SAI GPU result\n\nPassed: **48**; Failed: **1**; Infrastructure: **0**\n' \
        > "$artifact_root/results/case-matrix/gpu-case-summary.md"

    extract_workflow_run_script 'Publish GPU case summary' "$summary_script"
    sed -i 's#control/ci/sai/sai.py#ci/sai/sai.py#g' "$summary_script"
    ARTIFACT_ROOT=$artifact_root GITHUB_OUTPUT=$summary_output \
        GITHUB_STEP_SUMMARY=$root/step-summary.md bash "$summary_script"
    assert_contains "$summary_output" 'available=true'
    assert_contains "$summary_output" 'passed=48'
    assert_contains "$summary_output" 'failed=1'
    assert_contains "$summary_output" 'total=49'

    cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *'check-runs/12345'*) cat > "$FAKE_CHECK_REQUEST" ;;
    *'issues/17/comments'*) cat > "$FAKE_COMMENT_REQUEST" ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "$fake_bin/gh"
    extract_workflow_run_script 'Complete requested PR check' "$report_script"
    PATH="$fake_bin:$original_path" \
        FAKE_CHECK_REQUEST=$check_request FAKE_COMMENT_REQUEST=$comment_request \
        ARTIFACT_URL=https://github.com/Stardust0831/abacus-develop/actions/runs/98765/artifacts/24680 \
        CASE_SUMMARY_AVAILABLE=true CHECK_RUN_ID=12345 \
        GPU_FAILED=1 GPU_INFRASTRUCTURE=0 GPU_PASSED=48 \
        PR_NUMBER=17 SAI_RESULT=failure SOURCE_SHA=$sha GH_TOKEN=test-token \
        GITHUB_RUN_ID=98765 GITHUB_REPOSITORY=Stardust0831/abacus-develop \
        GITHUB_SERVER_URL=https://github.com bash "$report_script"

    python3 - "$check_request" "$comment_request" "$sha" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    check = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    comment = json.load(handle)["body"]
assert check["status"] == "completed" and check["conclusion"] == "failure"
assert "48 passed, 1 failed, 0 infrastructure" in comment
assert "actions/runs/98765/artifacts/24680" in comment
assert "Multinode" not in comment
assert sys.argv[3] in comment
PY
}

test_workflow_security_policy() {
    local workflow=.github/workflows/sai-gpu-full.yml
    local bootstrap=.github/workflows/sai-bootstrap.yml
    local toolchain=ci/sai/toolchains/abacus-develop-git-079fd0c.env.example
    local report_job
    assert_contains "$workflow" 'cron: "30 20 * * *"'
    assert_contains "$workflow" "github.event.comment.body == '/abacus-ci sai-gpu'"
    assert_contains "$workflow" "if: needs.admit.outputs.accepted == 'true'"
    assert_contains "$workflow" 'ref: ${{ github.event.repository.default_branch }}'
    assert_contains "$workflow" "name: \${{ github.event_name == 'schedule' && 'sai-ssh-scheduled' || 'sai-ssh-manual' }}"
    assert_contains "$workflow" 'python3 control/ci/sai/sai.py source payload'
    assert_contains "$workflow" 'python3 "$REMOTE_RUN_ROOT/control/sai.py" remote run'
    assert_contains "$workflow" 'python3 control/ci/sai/sai.py report github'
    assert_contains "$workflow" '[[ "$RESULT_AVAILABLE" == true ]]'
    assert_contains "$workflow" '[[ "$RESULT_PASSED" == 49 ]]'
    assert_not_contains "$workflow" 'run_remote_ci.sh'
    assert_not_contains "$workflow" 'build_source_payload.sh'
    assert_not_contains "$workflow" 'multinode_result'
    assert_contains "$workflow" 'retention-days: 1'
    assert_contains "$workflow" 'retention-days: 30'
    assert_contains "$workflow" 'unset GH_TOKEN'
    assert_not_contains "$workflow" '--header "Authorization: Bearer $GH_TOKEN"'
    report_job=$(sed -n '/^  report-pr-check:/,$p' "$workflow")
    assert_contains <(printf '%s\n' "$report_job") 'pull-requests: write'
    assert_contains "$bootstrap" 'name: sai-ssh-manual'
    assert_contains "$toolchain" 'module load "$SAI_ABACUS_MODULE"'
    assert_not_contains "$toolchain" 'module load nvhpc/'
    assert_not_contains "$toolchain" 'module load nccl/'
    assert_contains "$toolchain" 'export SAI_NCCL_ROOT=$NCCL_ROOT'
    if sed -n '/^on:/,/^permissions:/p' "$workflow" | grep -Eq '^[[:space:]]+pull_request:'; then
        fail 'GPU workflow must not run automatically for pull requests'
    fi
}

test_control_executable_modes() {
    local path
    for path in ci/sai/authorize_pr_comment.sh ci/sai/build_gpu.sbatch \
        ci/sai/gpu_case.sbatch ci/sai/sai.py ci/sai/download_source_artifact.sh; do
        [[ -x $path ]] || fail "$path must be executable"
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

test_download_source_artifact() {
    local root=$test_root/source-artifact
    local physical_home=$root/org/abacus-group/abacususer01
    local logical_home=$root/home/abacus-group/abacususer01
    local project=$physical_home/agent/abacus_sai_gpu_ci
    local logical_project=$logical_home/agent/abacus_sai_gpu_ci
    local repository=$root/repository
    local fake_bin=$root/bin
    local artifact=$root/source-artifact.zip
    local bad_artifact=$root/bad-source-artifact.zip
    local sha output run logical_run transfer logical_transfer

    mkdir -p "$physical_home" "$(dirname "$logical_home")" \
        "$repository" "$fake_bin" "$root/payload"
    ln -s "$physical_home" "$logical_home"
    git -C "$repository" init -q
    git -C "$repository" config user.email ci@example.invalid
    git -C "$repository" config user.name ci
    printf 'artifact source\n' > "$repository/source.txt"
    git -C "$repository" add source.txt
    git -C "$repository" commit -qm source
    sha=$(git -C "$repository" rev-parse HEAD)

    output=$(HOME=$logical_home bash ci/sai/prepare_remote_run.sh \
        "$logical_project" manual 200-1 "$sha" \
        89abcdef0123456789abcdef0123456789abcdef)
    run=$(awk -F= '$1 == "RUN_ROOT" {print $2}' <<< "$output")
    logical_run=${run/#$physical_home/$logical_home}
    output=$(HOME=$logical_home bash ci/sai/source_transfer_cache.sh prepare \
        "$logical_project" "$logical_run" "$sha" candidate)
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    logical_transfer=${transfer/#$physical_home/$logical_home}

    git -C "$repository" diff --binary --full-index --no-renames \
        "$(git -C "$repository" hash-object -t tree /dev/null)" "$sha" \
        | gzip -1 > "$root/payload/source-payload.gz"
    git -C "$repository" ls-tree -r -z --full-tree "$sha" \
        | gzip -1 > "$root/payload/source-manifest.gz"
    zip -q -j "$artifact" "$root/payload/source-payload.gz" \
        "$root/payload/source-manifest.gz"
    mkdir -p "$root/bad-payload"
    cp "$root/payload/source-manifest.gz" "$root/bad-payload/source-manifest.gz"
    printf 'not gzip\n' > "$root/bad-payload/source-payload.gz"
    zip -q -j "$bad_artifact" "$root/bad-payload/source-payload.gz" \
        "$root/bad-payload/source-manifest.gz"

    cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
config=
range=
args=("$@")
for ((index=0; index<${#args[@]}; index++)); do
    case ${args[$index]} in
        --output) output=${args[$((index + 1))]} ;;
        --config) config=${args[$((index + 1))]} ;;
        --range) range=${args[$((index + 1))]} ;;
        *sig=secret*) exit 91 ;;
    esac
done
: "${output:?}" "${config:?}" "${range:?}"
[[ $config == - ]]
cat > "$FAKE_CURL_CONFIG_LOG"
printf '%s\n' "$*" > "$FAKE_CURL_ARGS_LOG"
first=${range%-*}
last=${range#*-}
dd if="$FAKE_ARTIFACT" of="$output" bs=1 skip="$first" \
    count=$((last - first + 1)) status=none
EOF
    chmod +x "$fake_bin/curl"

    if printf '%s\n' \
        'https://productionresultssa0.blob.core.windows.net/actions-results/source.zip?sig=secret' \
        | PATH="$fake_bin:$original_path" HOME=$logical_home \
            FAKE_ARTIFACT=$bad_artifact \
            FAKE_CURL_CONFIG_LOG=$root/curl.config \
            FAKE_CURL_ARGS_LOG=$root/curl.args \
            bash ci/sai/download_source_artifact.sh \
            "$logical_project" "$logical_run" "$logical_transfer" \
            "$(stat -c %s "$bad_artifact")" \
            > /dev/null 2>&1; then
        fail 'source artifact downloader accepted an invalid gzip payload'
    fi
    assert_not_exists "$transfer/source-payload.gz"
    assert_not_exists "$transfer/source-manifest.gz"

    output=$(printf '%s\n' \
        'https://productionresultssa0.blob.core.windows.net/actions-results/source.zip?sig=secret' \
        | PATH="$fake_bin:$original_path" HOME=$logical_home \
            FAKE_ARTIFACT=$artifact \
            FAKE_CURL_CONFIG_LOG=$root/curl.config \
            FAKE_CURL_ARGS_LOG=$root/curl.args \
            bash ci/sai/download_source_artifact.sh \
            "$logical_project" "$logical_run" "$logical_transfer" \
            "$(stat -c %s "$artifact")")
    assert_contains <(printf '%s\n' "$output") 'SOURCE_ARTIFACT_DOWNLOADED=1'
    assert_contains <(printf '%s\n' "$output") 'SOURCE_ARTIFACT_BYTES='
    assert_contains <(printf '%s\n' "$output") \
        'SOURCE_ARTIFACT_DOWNLOAD_SECONDS='
    assert_file "$transfer/source-payload.gz"
    assert_file "$transfer/source-manifest.gz"
    assert_contains "$root/curl.config" 'sig=secret'
    assert_not_contains "$root/curl.args" 'sig=secret'

    if printf '%s\n' 'https://github.com/not-blob' \
        | HOME=$logical_home bash ci/sai/download_source_artifact.sh \
            "$logical_project" "$logical_run" "$logical_transfer" 1 \
            > /dev/null 2>&1; then
        fail 'source artifact downloader accepted a non-Blob URL'
    fi

    HOME=$logical_home bash ci/sai/source_transfer_cache.sh receive \
        "$logical_project" "$logical_run" "$logical_transfer" full "$sha" \
        > "$root/receive.log"
    HOME=$logical_home bash ci/sai/source_transfer_cache.sh finalize \
        "$logical_project" "$logical_run" "$logical_transfer" "$sha" \
        > "$root/finalize.log"
    assert_contains "$run/source/source.txt" 'artifact source'
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
    local legacy_candidate=$project/runs/pr-legacy/111-1
    local ephemeral=$project/runs/local-dirty/112-1
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
        "$project" "$run1" "$sha1" candidate)
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
    assert_contains "$root/finalize1.log" \
        "SOURCE_CACHE_PROMOTION=bootstrap role=candidate source_sha=$sha1"
    assert_file "$project/cache/source-latest"
    assert_contains "$project/cache/source-latest" "$sha1.100-1"
    assert_contains "$project/cache/source-latest" 'role=candidate'
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

    mkdir -p "$ephemeral/source" "$ephemeral/control" "$ephemeral/build" \
        "$ephemeral/install" "$ephemeral/results"
    touch "$ephemeral/.ci-created"
    output=$(HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$ephemeral" "$sha2" ephemeral)
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    assert_contains <(printf '%s\n' "$output") "SOURCE_CACHE_BASE_SHA=$sha1"
    assert_contains <(printf '%s\n' "$output") 'SOURCE_CACHE_ROLE=ephemeral'
    git -C "$repository" diff --binary --full-index --no-renames \
        "$sha1" "$sha2" | gzip -1 > "$transfer/source-payload.gz"
    git -C "$repository" ls-tree -r -z --full-tree "$sha2" \
        | gzip -1 > "$transfer/source-manifest.gz"
    HOME=$home bash ci/sai/source_transfer_cache.sh receive \
        "$project" "$ephemeral" "$transfer" delta "$sha2" > /dev/null
    HOME=$home bash ci/sai/source_transfer_cache.sh finalize \
        "$project" "$ephemeral" "$transfer" "$sha2" \
        > "$root/finalize-ephemeral.log"
    assert_contains "$ephemeral/source/keep.txt" 'changed'
    assert_contains "$root/finalize-ephemeral.log" \
        "SOURCE_CACHE_PROMOTION=skipped role=ephemeral source_sha=$sha2"
    assert_contains "$project/cache/source-latest" "$sha1.100-1"
    assert_contains "$project/cache/source-latest" 'role=candidate'
    assert_not_exists "$transfer"

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
        "SOURCE_CACHE_PROMOTION=refresh role=candidate source_sha=$sha2"
    assert_contains "$project/cache/source-latest" "$sha2.109-1"
    assert_contains "$project/cache/source-latest" 'role=candidate'
    assert_not_exists "$snapshot"
    snapshot=$project/cache/source-snapshots/$sha2.109-1
    assert_file "$snapshot/keep.txt"
    assert_not_exists "$transfer"

    printf '%s\n' "$sha2.109-1" > "$project/cache/source-latest"
    mkdir -p "$legacy_candidate/source" "$legacy_candidate/control" \
        "$legacy_candidate/build" "$legacy_candidate/install" \
        "$legacy_candidate/results"
    touch "$legacy_candidate/.ci-created"
    output=$(HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$legacy_candidate" "$sha2" candidate)
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    assert_contains <(printf '%s\n' "$output") "SOURCE_CACHE_BASE_SHA=$sha2"
    git -C "$repository" diff --binary --full-index --no-renames \
        "$sha2" "$sha2" | gzip -1 > "$transfer/source-payload.gz"
    git -C "$repository" ls-tree -r -z --full-tree "$sha2" \
        | gzip -1 > "$transfer/source-manifest.gz"
    HOME=$home bash ci/sai/source_transfer_cache.sh receive \
        "$project" "$legacy_candidate" "$transfer" delta "$sha2" > /dev/null
    HOME=$home bash ci/sai/source_transfer_cache.sh finalize \
        "$project" "$legacy_candidate" "$transfer" "$sha2" \
        > "$root/finalize-legacy-candidate.log"
    assert_contains "$root/finalize-legacy-candidate.log" \
        "SOURCE_CACHE_PROMOTION=skipped role=candidate source_sha=$sha2"
    printf '%s\n' "$sha2.109-1" \
        | cmp -s - "$project/cache/source-latest"

    mkdir -p "$run2/source" "$run2/control" "$run2/build" \
        "$run2/install" "$run2/results"
    touch "$run2/.ci-created"
    output=$(HOME=$home bash ci/sai/source_transfer_cache.sh prepare \
        "$project" "$run2" "$sha2" baseline)
    transfer=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
    assert_contains <(printf '%s\n' "$output") "SOURCE_CACHE_BASE_SHA=$sha2"
    assert_contains "$transfer/source/keep.txt" 'changed'
    assert_not_exists "$transfer/source/delete.txt"
    git -C "$repository" diff --binary --full-index --no-renames \
        "$sha2" "$sha2" | gzip -1 > "$transfer/source-payload.gz"
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
    assert_contains "$project/cache/source-latest" 'role=baseline'
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

    IFS= read -r snapshot_name < "$project/cache/source-latest"
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

    IFS= read -r snapshot_name < "$project/cache/source-latest"
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
    printf '{"protocol":1,"jobs":[{"job_id":"701","name":"build","label":"build","array_count":null,"argv":[]}]}\n' \
        > "$project/runs/204-1/results/jobs.json"

    mkdir -p "$project/runs/205-1/results"
    : > "$project/runs/205-1/.artifacts-uploaded"
    touch -d '73 hours ago' "$project/runs/205-1/.artifacts-uploaded"
    printf '{"protocol":1,"jobs":[{"job_id":"702","name":"build","label":"build","array_count":null,"argv":[]}]}\n' \
        > "$project/runs/205-1/results/jobs.json"

    mkdir -p "$project/runs/209-1/results"
    : > "$project/runs/209-1/.artifacts-uploaded"
    touch -d '73 hours ago' "$project/runs/209-1/.artifacts-uploaded"
    printf '{not-json}\n' > "$project/runs/209-1/results/jobs.json"

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
    assert_contains "$root/dry-run.log" "SKIP invalid_job_ledger run=$project/runs/209-1"
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
    assert_file "$project/runs/209-1/.artifacts-uploaded"
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

test_rt_tddft_scale_submission_policy() {
    local workflow=.github/workflows/sai-rt-tddft-scale.yml
    local remote=ci/sai/rt_tddft_scale_remote.sh
    local task=ci/sai/rt_tddft_scale.sbatch

    assert_contains "$workflow" \
        'default: "3x3x3,4x4x4,5x5x4,5x5x5,6x6x5"'
    assert_contains "$workflow" \
        'expected_org_prefix="/org/abacus-group/$SAI_SSH_USER/"'
    assert_contains "$workflow" 'Validate Slurm submission'
    assert_contains "$workflow" 'select_rt_tddft_scale_batch.sh'
    assert_contains "$workflow" 'actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803'
    assert_contains "$workflow" 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'

    assert_contains "$remote" 'preflight|submit)'
    assert_contains "$remote" '--array="0-$((count - 1))%$count"'
    assert_contains "$remote" '--partition=16V100'
    assert_contains "$remote" '--qos=flood-gpu'
    assert_contains "$remote" '--nodes=1'
    assert_contains "$remote" '--ntasks=4'
    assert_contains "$remote" '--gpus-per-node=4'
    assert_contains "$remote" '--time=01:00:00'
    assert_contains "$remote" '--export=ALL'
    assert_contains "$remote" \
        'toolchains/abacus-develop-git-079fd0c.env.example'
    assert_not_contains "$remote" \
        'archive-mp09-sai-nccl2293.env.example'
    assert_not_contains "$remote" 'ALL,RUN_ROOT='
    assert_not_contains "$remote" '--cpus-per-task'
    assert_not_contains "$remote" '--ntasks-per-node'
    assert_not_contains "$remote" '--mem='
    assert_not_contains "$remote" '--nodelist'

    assert_not_contains "$task" '#SBATCH'
    assert_contains "$task" 'task-entered.tsv'
    assert_contains "$task" 'expected_ranks=${expected_ranks:-4}'
    assert_contains "$task" 'expected_gpus_per_node=${expected_gpus_per_node:-4}'
    assert_contains "$task" '[[ $SLURM_NTASKS -eq $expected_ranks ]]'
    assert_contains "$task" '[[ ${SLURM_GPUS_ON_NODE:-} == "$expected_gpus_per_node" ]]'
    assert_contains "$task" 'RUN_ROOT=$(realpath -e "$SLURM_SUBMIT_DIR")'
    assert_contains "$task" \
        '[[ $SAI_PROFILE_NAME == module-abacus-develop-git-079fd0c ]]'
    assert_contains "$task" \
        '[[ $SAI_CUSOLVERMP_ROOT == /opt/devtools/nvidia/mp_libs ]]'
    assert_contains "$task" '${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}'
    assert_contains "$task" 'nvidia_smi=(nvidia-smi)'
    assert_not_contains "$task" 'nvidia-smi -i'
    assert_contains "$task" '[[ $rc -eq 137 && $elapsed -ge 3300 ]]'

    python3 - "$workflow" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
remove = text.index("- name: Remove local SSH credentials")
upload = text.index("- name: Upload probe artifacts")
if remove >= upload:
    raise SystemExit("SSH credentials must be removed before artifact upload")
PY
}

test_rt_tddft_scale_batch_selector() {
    local root=$test_root/scale-selector
    local selector=ci/sai/select_rt_tddft_scale_batch.sh
    mkdir -p "$root"

    cat > "$root/all-pass.tsv" <<'EOF'
3x3x3	216	PASS
4x4x4	512	PASS
5x5x4	800	PASS
5x5x5	1000	PASS
6x6x5	1440	PASS
EOF
    bash "$selector" "$root/all-pass.tsv" > "$root/all-pass.out"
    assert_contains "$root/all-pass.out" \
        'NEXT_SUPERCELLS=6x6x6,6x6x7,6x7x7,7x7x7,7x7x8'
    assert_contains "$root/all-pass.out" 'NEXT_REASON=search-above'

    cat > "$root/bracket.tsv" <<'EOF'
3x3x3	216	PASS
4x4x4	512	PASS
5x5x4	800	GPU_OOM
5x5x5	1000	GPU_OOM
6x6x5	1440	GPU_OOM
EOF
    bash "$selector" "$root/bracket.tsv" > "$root/bracket.out"
    assert_contains "$root/bracket.out" 'NEXT_SUPERCELLS=4x4x5,4x4x6'
    assert_contains "$root/bracket.out" 'NEXT_REASON=refine-capacity-boundary'

    cat > "$root/no-pass.tsv" <<'EOF'
3x3x3	216	GPU_OOM
4x4x4	512	GPU_OOM
EOF
    bash "$selector" "$root/no-pass.tsv" > "$root/no-pass.out"
    assert_contains "$root/no-pass.out" 'NEXT_SUPERCELLS=1x1x1,1x2x2,2x2x2,2x3x3'
    assert_contains "$root/no-pass.out" 'NEXT_REASON=search-below'

    cat > "$root/infra.tsv" <<'EOF'
3x3x3	216	INFRA_CANCELLED
4x4x4	512	PASS
EOF
    bash "$selector" "$root/infra.tsv" > "$root/infra.out"
    assert_contains "$root/infra.out" 'NEXT_SUPERCELLS=3x3x3'
    assert_contains "$root/infra.out" 'NEXT_REASON=repeat-ambiguous'
}

test_rt_tddft_scale_sbatch_invocation() {
    local root=$test_root/scale-sbatch
    local home=$root/home
    local run=$home/project/benchmarks/rt-tddft-4gpu/123-1
    local fake_bin=$root/bin
    local args_log=$root/sbatch-args.log
    local pwd_log=$root/sbatch-pwd.log
    mkdir -p "$run/control" "$run/results" "$fake_bin"
    : > "$run/metadata.tsv"
    : > "$run/abacus.sha256"
    printf '0\t3x3x3\t3\t3\t3\t216\n1\t4x4x4\t4\t4\t4\t512\n' \
        > "$run/manifest.tsv"
    cp ci/sai/rt_tddft_scale_remote.sh \
        ci/sai/rt_tddft_scale.sbatch \
        ci/sai/select_rt_tddft_scale_batch.sh "$run/control/"
    chmod +x "$run/control/rt_tddft_scale_remote.sh" \
        "$run/control/select_rt_tddft_scale_batch.sh"
    cat > "$fake_bin/sbatch" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$args_log"
pwd > "$pwd_log"
if [[ " \$* " == *' --test-only '* ]]; then
    echo 'test-only accepted'
else
    echo 900001
fi
EOF
    chmod +x "$fake_bin/sbatch"
    PATH="$fake_bin:$original_path" HOME=$home \
        bash "$run/control/rt_tddft_scale_remote.sh" preflight "$run" \
        > "$root/preflight.out"
    assert_contains "$root/preflight.out" 'SLURM_PREFLIGHT_OK'
    assert_contains "$args_log" '--test-only'
    assert_contains "$args_log" '--array=0-1%2'
    assert_contains "$args_log" '--partition=16V100'
    assert_contains "$args_log" '--qos=flood-gpu'
    assert_contains "$args_log" '--nodes=1'
    assert_contains "$args_log" '--ntasks=4'
    assert_contains "$args_log" '--gpus-per-node=4'
    assert_contains "$args_log" '--time=01:00:00'
    assert_contains "$args_log" '--export=ALL'
    assert_not_contains "$args_log" 'ALL,RUN_ROOT='
    [[ $(<"$pwd_log") == "$run" ]]
    assert_not_exists "$run/slurm-job-id"

    PATH="$fake_bin:$original_path" HOME=$home \
        bash "$run/control/rt_tddft_scale_remote.sh" submit "$run" \
        > "$root/submit.out"
    assert_contains "$root/submit.out" 'SLURM_JOB_ID=900001'
    [[ $(<"$run/slurm-job-id") == 900001 ]]
    assert_not_contains "$args_log" '--test-only'

    mkdir -p "$run/results/tasks/0/case/OUT.si216_4gpu"
    printf 'large generated output\n' > "$run/results/tasks/0/case/OUT.si216_4gpu/bulk.dat"
    printf 'useful task log\n' > "$run/results/tasks/0/abacus.log"
    HOME=$home bash "$run/control/rt_tddft_scale_remote.sh" collect "$run" \
        > "$root/artifacts.tar.gz"
    tar -tzf "$root/artifacts.tar.gz" > "$root/artifacts.list"
    assert_contains "$root/artifacts.list" 'results/tasks/0/abacus.log'
    assert_not_contains "$root/artifacts.list" '/case/OUT.'
}

test_rt_tddft_efficiency_policy() {
    local workflow=.github/workflows/sai-rt-tddft-efficiency.yml
    local remote=ci/sai/rt_tddft_efficiency_remote.sh

    assert_contains "$workflow" 'name: SAI RT-TDDFT Scaling Benchmark'
    assert_contains "$workflow" \
        'expected_org_prefix="/org/abacus-group/$SAI_SSH_USER/"'
    assert_contains "$workflow" 'run_kind:'
    assert_contains "$workflow" 'ci/sai/summarize_rt_tddft_efficiency.sh'
    assert_contains "$workflow" "if: always() && env.SUBMISSION_STARTED == '1'"
    assert_contains "$workflow" 'actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803'
    assert_contains "$workflow" 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
    assert_contains "$remote" '0 base-4-si1000 5x5x5 1 4 4'
    assert_contains "$remote" '1 strong-8-si1000 5x5x5 1 8 8'
    assert_contains "$remote" '2 strong-16-si1000 5x5x5 1 16 16'
    assert_contains "$remote" '3 strong-32-si1000 5x5x5 2 32 16'
    assert_contains "$remote" '4 weak-8-si2000 5x5x10 1 8 8'
    assert_contains "$remote" '5 weak-16-si4000 5x10x10 1 16 16'
    assert_contains "$remote" '6 weak-32-si8000 10x10x10 2 32 16'
    assert_contains "$remote" '--qos=flood-gpu'
    assert_contains "$remote" '--time=01:00:00'
    assert_contains "$remote" '--export=ALL'
    assert_contains "$remote" \
        'toolchains/abacus-develop-git-079fd0c.env.example'
    assert_not_contains "$remote" \
        'archive-mp09-sai-nccl2293.env.example'
    assert_not_contains "$remote" '--cpus-per-task'
    assert_not_contains "$remote" '--ntasks-per-node'
    assert_not_contains "$remote" '--mem='
    assert_not_contains "$remote" '--nodelist'
}

test_rt_tddft_efficiency_summary() {
    local root=$test_root/efficiency-summary
    local input=$root/cases.tsv
    local output=$root/summary.md
    mkdir -p "$root"
    cat > "$input" <<'EOF'
base-4-si1000	1000	4	1	PASS	0	100	6000	16384	100	200
strong-8-si1000	1000	8	1	PASS	0	60	4000	16384	100	200
strong-16-si1000	1000	16	1	PASS	0	35	3000	16384	100	200
strong-32-si1000	1000	32	2	PASS	0	25	2000	16384	100	200
weak-8-si2000	2000	8	1	PASS	0	120	8000	16384	100	200
weak-16-si4000	4000	16	1	PASS	0	150	12000	16384	100	200
weak-32-si8000	8000	32	2	HOST_OOM	-	-	-	-	-	-
EOF
    bash ci/sai/summarize_rt_tddft_efficiency.sh "$input" > "$output"
    assert_contains "$output" '| 8 | 60 | 1.667 | 83.3% |'
    assert_contains "$output" '| 16 | 35 | 2.857 | 71.4% |'
    assert_contains "$output" '| 32 | 25 | 4.000 | 50.0% |'
    assert_contains "$output" '| 8 | 2000 | 120 | 83.3% |'
    assert_contains "$output" '| 16 | 4000 | 150 | 66.7% |'
    assert_not_contains "$output" '| 32 | 8000 |'
}

test_rt_tddft_efficiency_sbatch_invocation() {
    local root=$test_root/efficiency-sbatch
    local home=$root/home
    local run=$home/project/benchmarks/rt-tddft-efficiency/456-1
    local fake_bin=$root/bin
    local args_log=$root/sbatch.log
    local counter=$root/counter
    local partial=$home/project/benchmarks/rt-tddft-efficiency/457-1
    local index label cell nodes ranks gpus case_root partial_rc
    mkdir -p "$run/control" "$run/results" "$run/cases" "$fake_bin"
    : > "$run/metadata.tsv"
    : > "$run/benchmark.tsv"
    for spec in \
        '0 trial-8-si1000 5x5x5 1 8 8' \
        '1 trial-8-si2000 5x5x10 1 8 8' \
        '2 trial-32-si1000 5x5x5 2 32 16'; do
        read -r index label cell nodes ranks gpus <<< "$spec"
        case_root=$run/cases/$index-$label
        mkdir -p "$case_root/results/tasks/0/case/OUT.si1000_${ranks}gpu"
        : > "$case_root/metadata.tsv"
        : > "$case_root/manifest.tsv"
        printf '%s\t%s\t%s\t1\t1\t1\t1000\t%s\t%s\t%s\t%s\n' \
            "$index" "$label" "$cell" "$nodes" "$ranks" "$gpus" "$case_root" \
            >> "$run/benchmark.tsv"
        printf 'generated\n' > "$case_root/results/tasks/0/case/OUT.si1000_${ranks}gpu/data"
        printf 'useful\n' > "$case_root/results/tasks/0/abacus.log"
    done
    cp ci/sai/rt_tddft_efficiency_remote.sh ci/sai/rt_tddft_scale.sbatch \
        ci/sai/summarize_rt_tddft_efficiency.sh "$run/control/"
    chmod +x "$run/control/rt_tddft_efficiency_remote.sh" \
        "$run/control/summarize_rt_tddft_efficiency.sh"
    cat > "$fake_bin/sbatch" <<EOF
#!/usr/bin/env bash
printf 'PWD=%s ARGS=%s\n' "\$PWD" "\$*" >> "$args_log"
if [[ " \$* " == *' --test-only '* ]]; then
    echo accepted
else
    value=0
    [[ ! -f "$counter" ]] || value=\$(<"$counter")
    value=\$((value + 1))
    [[ \${FAIL_AT:-0} -ne \$value ]] || exit 1
    printf '%s\n' "\$value" > "$counter"
    printf '92%04d\n' "\$value"
fi
EOF
    chmod +x "$fake_bin/sbatch"
    cat > "$fake_bin/squeue" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fake_bin/squeue"

    PATH="$fake_bin:$original_path" HOME=$home \
        bash "$run/control/rt_tddft_efficiency_remote.sh" preflight "$run" \
        > "$root/preflight.out"
    assert_contains "$root/preflight.out" 'SLURM_PREFLIGHT_OK'
    [[ $(grep -c -- '--test-only' "$args_log") -eq 3 ]]
    assert_contains "$args_log" '--nodes=1 --ntasks=8 --gpus-per-node=8'
    assert_contains "$args_log" '--nodes=2 --ntasks=32 --gpus-per-node=16'
    assert_contains "$args_log" "PWD=$run/cases/2-trial-32-si1000"

    cp -a "$run" "$partial"
    sed -i "s#$run#$partial#g" "$partial/benchmark.tsv"
    : > "$args_log"
    set +e
    FAIL_AT=2 PATH="$fake_bin:$original_path" HOME=$home \
        bash "$partial/control/rt_tddft_efficiency_remote.sh" submit "$partial" \
        > "$root/partial-submit.out" 2>&1
    partial_rc=$?
    set -e
    [[ $partial_rc -ne 0 ]]
    [[ $(wc -l < "$partial/jobs.tsv") -eq 1 ]]
    PATH="$fake_bin:$original_path" HOME=$home \
        bash "$partial/control/rt_tddft_efficiency_remote.sh" status "$partial" \
        > "$root/partial-status.out"
    assert_contains "$root/partial-status.out" 'SLURM_JOB_IDS=920001'
    assert_contains "$root/partial-status.out" 'ACTIVE_TASKS=0'
    HOME=$home bash "$partial/control/rt_tddft_efficiency_remote.sh" collect "$partial" \
        > "$root/partial-artifacts.tar.gz"
    tar -tzf "$root/partial-artifacts.tar.gz" > "$root/partial-artifacts.list"
    assert_contains "$root/partial-artifacts.list" 'jobs.tsv'
    assert_not_contains "$root/partial-artifacts.list" '/case/OUT.'

    : > "$counter"
    : > "$args_log"
    PATH="$fake_bin:$original_path" HOME=$home \
        bash "$run/control/rt_tddft_efficiency_remote.sh" submit "$run" \
        > "$root/submit.out"
    [[ $(wc -l < "$run/jobs.tsv") -eq 3 ]]
    assert_contains "$root/submit.out" 'SLURM_JOB_IDS=920001,920002,920003'
    assert_not_contains "$args_log" '--test-only'

    HOME=$home bash "$run/control/rt_tddft_efficiency_remote.sh" collect "$run" \
        > "$root/artifacts.tar.gz"
    tar -tzf "$root/artifacts.tar.gz" > "$root/artifacts.list"
    assert_contains "$root/artifacts.list" 'cases/0-trial-8-si1000/results/tasks/0/abacus.log'
    assert_not_contains "$root/artifacts.list" '/case/OUT.'
}

run_test 'SSH client configuration' test_configure_ssh_client
run_test 'remote probe identity' test_remote_probe_identity
run_test 'pull request comment authorization' test_authorize_pr_comment
run_test 'pull request result comment' test_pr_result_comment
run_test 'workflow security policy' test_workflow_security_policy
run_test 'control executable modes' test_control_executable_modes
run_test 'PMIx startup retry policy' test_pmix_startup_retry
run_test 'remote path containment and collision' test_prepare_remote_run_paths
run_test 'source artifact reverse download' test_download_source_artifact
run_test 'compressed source snapshot cache' test_source_snapshot_cache
run_test 'cleanup staging containment and collision' test_prepare_cleanup_install
run_test 'artifact collection whitelist' test_artifact_collection
run_test 'uploaded marker atomic replacement' test_mark_artifacts_uploaded
run_test 'cleanup retention and active-job safety' test_cleanup_retention
run_test 'cleanup cron installation safety' test_cleanup_cron_installation
run_test 'RT-TDDFT scale submission policy' test_rt_tddft_scale_submission_policy
run_test 'RT-TDDFT scale batch selector' test_rt_tddft_scale_batch_selector
run_test 'RT-TDDFT scale sbatch invocation' test_rt_tddft_scale_sbatch_invocation
run_test 'RT-TDDFT efficiency policy' test_rt_tddft_efficiency_policy
run_test 'RT-TDDFT efficiency formulas' test_rt_tddft_efficiency_summary
run_test 'RT-TDDFT efficiency sbatch invocation' test_rt_tddft_efficiency_sbatch_invocation

echo "ALL TESTS PASSED ($tests_run)"
