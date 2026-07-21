#!/usr/bin/env bash

set -euo pipefail

: "${CI_SOURCE:?}"
: "${INSTALL_ROOT:?}"
: "${RESULT_ROOT:?}"
: "${TOOLCHAIN_FILE:?}"
: "${MP_PROFILE:?}"

unset SAI_SLURM_NODELIST

matrix_log="$RESULT_ROOT/gpu-case-matrix-coordinator.log"
multinode_log="$RESULT_ROOT/cusolvermp-multinode-coordinator.log"
multinode_submit_log="$RESULT_ROOT/sai-cusolvermp-multinode-submit.log"
components_file="$RESULT_ROOT/gpu-validation-components.tsv"
matrix_pid=
multinode_pid=
children_active=1

cancel_children() {
    local pid
    local -a child_pids=()
    local -A seen=()
    if [[ $children_active -eq 1 ]]; then
        for pid in "$matrix_pid" "$multinode_pid" $(jobs -pr); do
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
    cancel_children
    children_active=0
    exit 143
}
trap terminate INT TERM
trap cancel_children EXIT

echo "Submitting GPU case arrays and 2-node cuSolverMp validation concurrently"
bash "$CI_SOURCE/ci/sai/run_gpu_case_matrix.sh" > "$matrix_log" 2>&1 &
matrix_pid=$!
"$CI_SOURCE/ci/sai/run_slurm_job.sh" "$multinode_submit_log" \
    "$RESULT_ROOT/sai-cusolvermp-multinode-%j.out" \
    "$CI_SOURCE/ci/sai/test_gpu.sbatch" > "$multinode_log" 2>&1 &
multinode_pid=$!
printf 'GPU_MATRIX_COORDINATOR_PID=%s\n' "$matrix_pid"
printf 'CUSOLVERMP_MULTINODE_COORDINATOR_PID=%s\n' "$multinode_pid"

set +e
wait "$matrix_pid"
matrix_rc=$?
wait "$multinode_pid"
multinode_rc=$?
set -e
children_active=0
trap - INT TERM EXIT

printf 'component\texit_code\ncase-matrix\t%s\ncusolvermp-multinode\t%s\n' \
    "$matrix_rc" "$multinode_rc" > "$components_file"

echo "::group::SAI GPU case matrix coordinator"
cat "$matrix_log"
echo "::endgroup::"
echo "::group::SAI 2-node cuSolverMp coordinator"
cat "$multinode_log"
echo "::endgroup::"

if [[ $matrix_rc -ne 0 ]]; then
    echo "::error title=SAI GPU case matrix failed::Coordinator exit code $matrix_rc"
fi
if [[ $multinode_rc -ne 0 ]]; then
    echo "::error title=SAI cuSolverMp multinode validation failed::Coordinator exit code $multinode_rc"
fi

echo "SAI_GPU_VALIDATION_RESULT matrix_rc=$matrix_rc multinode_rc=$multinode_rc"
[[ $matrix_rc -eq 0 && $multinode_rc -eq 0 ]]
