#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 7 || $# -gt 8 ]]; then
    echo "Usage: $0 SUITE_DIR CASE_DIR CASE_NAME ABACUS RANKS OMP_THREADS TASK_ROOT [MAX_ATTEMPTS]" >&2
    exit 2
fi

suite_dir=$(realpath -e "$1")
case_dir=$(realpath -e "$2")
case_name=$3
abacus=$(realpath -e "$4")
ranks=$5
omp_threads=$6
task_root=$(realpath -e "$7")
max_attempts=${8:-2}
retry_delay=10

[[ $case_name =~ ^[A-Za-z0-9_.-]+$ ]]
[[ $case_dir == "$suite_dir/$case_name" ]]
[[ -x $abacus ]]
[[ $ranks =~ ^[1-9][0-9]*$ ]]
[[ $omp_threads =~ ^[1-9][0-9]*$ ]]
[[ $max_attempts =~ ^[1-9][0-9]*$ && $max_attempts -le 2 ]]
: "${RESULT_ROOT:?}"
result_root=$(realpath -e "$RESULT_ROOT")
[[ $task_root == "$result_root/"* ]]
autotest=$(realpath -e "$suite_dir/../integrate/Autotest.sh")
[[ -f $autotest ]]

combined_log="$task_root/case.log"
metadata="$task_root/pmix-retry.tsv"
: > "$combined_log"

cleanup_case_outputs() {
    rm -rf "$case_dir/OUT.autotest"
    rm -f "$case_dir/log.txt" "$case_dir/result.out"
}

is_pmix_startup_failure() {
    local log=$1
    grep -aEq 'PMIX_ERR_(FILE_OPEN_FAILURE|OUT_OF_RESOURCE)' "$log" &&
        grep -aFq 'MPI_Init_thread' "$log" &&
        grep -aFq 'PMIx_Init failed' "$log"
}

attempt=1
retried=0
retry_reason=none
final_pmix=0
test_rc=2
while [[ $attempt -le $max_attempts ]]; do
    cleanup_case_outputs
    attempt_log="$task_root/case-attempt-${attempt}.log"
    printf 'SAI_GPU_CASE_ATTEMPT attempt=%s max=%s\n' "$attempt" "$max_attempts" \
        | tee -a "$combined_log"

    set +e
    (cd "$suite_dir" &&
        timeout --signal=TERM --kill-after=30s 10m \
            bash "$autotest" -a "$abacus" -n "$ranks" \
                -o "$omp_threads" -f CASES.task.txt -r "^${case_name}$") \
        2>&1 | tee "$attempt_log" | tee -a "$combined_log"
    pipeline_status=("${PIPESTATUS[@]}")
    set -e
    [[ ${pipeline_status[1]} -eq 0 && ${pipeline_status[2]} -eq 0 ]]
    test_rc=${pipeline_status[0]}

    final_pmix=0
    case $test_rc in
        0|124|137|143) ;;
        *)
            if is_pmix_startup_failure "$attempt_log"; then
                final_pmix=1
            fi
            ;;
    esac
    if [[ $attempt -lt $max_attempts && $final_pmix -eq 1 ]]; then
        retried=1
        retry_reason=pmix_startup
        echo "SAI_PMIX_STARTUP_RETRY delay_seconds=$retry_delay" \
            | tee -a "$combined_log"
        sleep "$retry_delay"
        attempt=2
        continue
    fi
    break
done

metadata_tmp=$(mktemp "$task_root/.pmix-retry.XXXXXX")
{
    printf 'attempts\t%s\n' "$attempt"
    printf 'max_attempts\t%s\n' "$max_attempts"
    printf 'retried\t%s\n' "$retried"
    printf 'retry_reason\t%s\n' "$retry_reason"
    printf 'final_pmix\t%s\n' "$final_pmix"
    printf 'final_rc\t%s\n' "$test_rc"
} > "$metadata_tmp"
mv -T "$metadata_tmp" "$metadata"
echo "SAI_GPU_CASE_ATTEMPTS attempts=$attempt retried=$retried final_pmix=$final_pmix rc=$test_rc"
exit "$test_rc"
