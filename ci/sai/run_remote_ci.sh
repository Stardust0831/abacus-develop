#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 6 ]]; then
    echo "Usage: $0 PROJECT_ROOT RUN_ROOT SOURCE_SHA CONTROL_SHA GITHUB_RUN_ID GITHUB_RUN_ATTEMPT" >&2
    exit 2
fi

export SAI_PROJECT_ROOT=$1
export RUN_ROOT=$2
source_sha=$3
control_sha=$4
export GITHUB_RUN_ID=$5
export GITHUB_RUN_ATTEMPT=$6
export CI_SOURCE=$RUN_ROOT/source
export CONTROL_ROOT=$RUN_ROOT/control
export BUILD_ROOT=$RUN_ROOT/build
export INSTALL_ROOT=$RUN_ROOT/install
export RESULT_ROOT=$RUN_ROOT/results
export TOOLCHAIN_FILE=$CONTROL_ROOT/toolchains/abacus-develop-git-079fd0c.env.example
export MP_PROFILE=module-abacus-develop-git-079fd0c
export SAI_DISABLE_NCCL_IB=false
unset GITHUB_ENV GITHUB_STEP_SUMMARY SAI_SLURM_NODELIST

canonical_home=$(cd "$HOME" && pwd -P)
[[ $SAI_PROJECT_ROOT == "$canonical_home/"* ]]
[[ $RUN_ROOT == "$SAI_PROJECT_ROOT/runs/"* ]]
run_parent=$(dirname "$RUN_ROOT")
[[ $(dirname "$run_parent") == "$SAI_PROJECT_ROOT/runs" ]]
run_namespace=${run_parent##*/}
[[ $run_namespace =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
[[ -d $CI_SOURCE && -d $CONTROL_ROOT && -d $BUILD_ROOT && \
   -d $INSTALL_ROOT && -d $RESULT_ROOT ]]
[[ $source_sha =~ ^[0-9a-fA-F]{40}$ ]]
[[ $control_sha =~ ^[0-9a-fA-F]{40}$ ]]
for control_file in prepare_cusolvermp_smoke.sh run_slurm_job.sh \
    run_gpu_case_attempts.sh build_gpu.sbatch \
    run_gpu_validation.sh; do
    [[ -f $CONTROL_ROOT/$control_file ]]
done

child_pid=
child_active=0
cancel_child() {
    local pid
    local -a child_pids=()
    local -A seen=()
    if [[ $child_active -eq 1 ]]; then
        for pid in "$child_pid" $(jobs -pr); do
            if [[ -n $pid && -z ${seen[$pid]+x} ]]; then
                child_pids+=("$pid")
                seen[$pid]=1
            fi
        done
        for pid in "${child_pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -TERM "$pid" 2>/dev/null || true
            fi
        done
        for pid in "${child_pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
    fi
}
terminate() {
    cancel_child
    child_active=0
    exit 143
}
trap terminate HUP INT TERM
trap cancel_child EXIT

{
    printf 'source_sha\t%s\n' "$source_sha"
    printf 'control_sha\t%s\n' "$control_sha"
    printf 'github_run_id\t%s\n' "$GITHUB_RUN_ID"
    printf 'github_run_attempt\t%s\n' "$GITHUB_RUN_ATTEMPT"
    printf 'remote_user\t%s\n' "$USER"
    printf 'remote_host\t%s\n' "$(hostname)"
    printf 'project_root\t%s\n' "$SAI_PROJECT_ROOT"
    printf 'run_namespace\t%s\n' "$run_namespace"
} > "$RESULT_ROOT/remote-run-metadata.tsv"

child_active=1
bash "$CONTROL_ROOT/run_slurm_job.sh" \
    "$RESULT_ROOT/sai-build-submit.log" \
    "$RESULT_ROOT/sai-build-%j.out" \
    "$CONTROL_ROOT/build_gpu.sbatch" &
child_pid=$!
wait "$child_pid"
child_active=0
child_pid=

child_active=1
bash "$CONTROL_ROOT/run_gpu_validation.sh" &
child_pid=$!
set +e
wait "$child_pid"
validation_rc=$?
set -e
child_active=0
child_pid=

trap - HUP INT TERM EXIT
echo "SAI_REMOTE_CI_RESULT validation_rc=$validation_rc source_sha=$source_sha"
exit "$validation_rc"
