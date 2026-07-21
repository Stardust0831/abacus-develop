#!/usr/bin/env bash

set -euo pipefail

: "${RESULT_ROOT:?}"

matrix_root="$RESULT_ROOT/case-matrix"
manifest_root="$matrix_root/manifests"
jobs_file="$matrix_root/array-jobs.tsv"
accounting_file="$matrix_root/array-task-accounting.tsv"
[[ -f "$jobs_file" ]]
[[ -f "$accounting_file" ]]

classes=(gpu1 gpu2 gpu4)
declare -A job_ids=()
declare -A task_counts=()
while IFS=$'\t' read -r class job_id count; do
    [[ $class =~ ^gpu(1|2|4)$ ]]
    [[ $job_id =~ ^[0-9]+$ ]]
    [[ $count =~ ^[0-9]+$ ]]
    job_ids[$class]=$job_id
    task_counts[$class]=$count
done < "$jobs_file"

declare -A slurm_states=()
declare -A slurm_exit_codes=()
accounting_rows=0
while IFS=$'\t' read -r class task_id job_id slurm_state slurm_exit_code extra; do
    [[ -z ${extra:-} ]]
    [[ $class =~ ^gpu(1|2|4)$ ]]
    [[ $task_id =~ ^[0-9]+$ ]]
    [[ $job_id =~ ^[0-9]+$ ]]
    [[ $job_id == "${job_ids[$class]:-}" ]]
    [[ $slurm_state =~ ^(BOOT_FAIL|CANCELLED|COMPLETED|DEADLINE|FAILED|NODE_FAIL|OUT_OF_MEMORY|PREEMPTED|REVOKED|SPECIAL_EXIT|TIMEOUT)$ ]]
    [[ $slurm_exit_code =~ ^[0-9]+:[0-9]+$ ]]
    accounting_key="$class-$task_id"
    [[ -z ${slurm_states[$accounting_key]+x} ]]
    slurm_states[$accounting_key]=$slurm_state
    slurm_exit_codes[$accounting_key]=$slurm_exit_code
    accounting_rows=$((accounting_rows + 1))
done < "$accounting_file"
[[ $accounting_rows -eq 48 ]]

summary="$matrix_root/gpu-case-summary.md"
{
    echo "## SAI GPU case matrix"
    echo
    echo '| Resource | Test case | Status | Slurm task | Ranks | Elapsed |'
    echo '| --- | --- | --- | ---: | ---: | ---: |'
} > "$summary"

passed=0
failed=0
infra=0
for class in "${classes[@]}"; do
    [[ -n ${job_ids[$class]:-} ]]
    manifest="$manifest_root/$class.tsv"
    task_id=0
    while IFS=$'\t' read -r suite case_name; do
        status_file="$matrix_root/status/${class}-${task_id}.tsv"
        expected_ranks=${class#gpu}
        expected_job_id=${job_ids[$class]}
        accounting_key="$class-$task_id"
        slurm_state=${slurm_states[$accounting_key]:-}
        slurm_exit_code=${slurm_exit_codes[$accounting_key]:-}
        status_error=
        status_lines=()
        got_class=
        got_task=
        got_suite=
        got_case=
        ranks=
        state=
        rc=
        elapsed=
        job_id=

        if [[ ! -f $status_file ]]; then
            status_error=missing_status
        elif [[ ! -s $status_file ]]; then
            status_error=empty_status
        else
            mapfile -t status_lines < "$status_file"
            if [[ ${#status_lines[@]} -ne 1 ]]; then
                status_error=expected_one_status_row
            elif [[ -n $(tail -c 1 "$status_file") ]]; then
                status_error=missing_final_newline
            elif [[ $(awk -F '\t' 'NR == 1 { print NF }' "$status_file") -ne 9 ]]; then
                status_error=expected_nine_fields
            else
                IFS=$'\t' read -r got_class got_task got_suite got_case ranks state rc elapsed job_id \
                    <<< "${status_lines[0]}"
                errors=()
                [[ $got_class == "$class" ]] || errors+=(class_mismatch)
                [[ $got_task =~ ^[0-9]+$ ]] || errors+=(task_not_numeric)
                [[ $got_task == "$task_id" ]] || errors+=(task_mismatch)
                [[ $got_suite == "$suite" ]] || errors+=(suite_mismatch)
                [[ $got_case == "$case_name" ]] || errors+=(case_mismatch)
                [[ $ranks =~ ^[0-9]+$ ]] || errors+=(ranks_not_numeric)
                [[ $ranks == "$expected_ranks" ]] || errors+=(ranks_mismatch)
                [[ $state =~ ^(PASS|FAIL|TIMEOUT)$ ]] || errors+=(invalid_state)
                [[ $rc =~ ^[0-9]+$ ]] || errors+=(rc_not_numeric)
                if [[ $state == PASS && $rc != 0 ]]; then
                    errors+=(pass_with_nonzero_rc)
                elif [[ $state =~ ^(FAIL|TIMEOUT)$ && $rc == 0 ]]; then
                    errors+=(failure_with_zero_rc)
                fi
                slurm_rc=${slurm_exit_code%%:*}
                slurm_signal=${slurm_exit_code#*:}
                if [[ $state == PASS ]]; then
                    [[ $slurm_state == COMPLETED ]] || errors+=(pass_without_completed_slurm_state)
                    [[ $slurm_exit_code == 0:0 ]] || errors+=(pass_with_nonzero_slurm_exit)
                elif [[ $state =~ ^(FAIL|TIMEOUT)$ ]]; then
                    [[ $slurm_state == FAILED ]] || errors+=(failure_without_failed_slurm_state)
                    [[ $slurm_rc == "$rc" && $slurm_signal == 0 ]] || errors+=(status_slurm_exit_mismatch)
                fi
                [[ $elapsed =~ ^[0-9]+$ ]] || errors+=(elapsed_not_numeric)
                [[ $job_id =~ ^[0-9]+$ ]] || errors+=(job_id_not_numeric)
                [[ $job_id == "$expected_job_id" ]] || errors+=(job_id_mismatch)
                if [[ ${#errors[@]} -gt 0 ]]; then
                    status_error=$(IFS=,; echo "${errors[*]}")
                fi
            fi
        fi

        if [[ -n $status_error ]]; then
            state=INFRA
            rc=$status_error
            elapsed='-'
            job_id=$expected_job_id
            ranks=$expected_ranks
        fi

        case $state in
            PASS) passed=$((passed + 1)) ;;
            FAIL|TIMEOUT)
                failed=$((failed + 1))
                echo "::error title=SAI GPU case failed::${suite}/${case_name} state=${state} rc=${rc} Slurm=${job_id}_${task_id}"
                ;;
            *)
                infra=$((infra + 1))
                echo "::error title=SAI GPU case infrastructure failure::${suite}/${case_name} state=${state} rc=${rc} Slurm=${job_id}_${task_id}"
                ;;
        esac
        printf '| %s | `%s/%s` | %s | `%s_%s` | %s | %s s |\n' \
            "$class" "$suite" "$case_name" "$state" "$job_id" "$task_id" \
            "$ranks" "$elapsed" >> "$summary"
        task_id=$((task_id + 1))
    done < "$manifest"
    [[ $task_id -eq ${task_counts[$class]} ]]
done

{
    echo
    echo "Passed: **$passed**; Failed: **$failed**; Infrastructure: **$infra**"
} >> "$summary"

cat "$summary"
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    cat "$summary" >> "$GITHUB_STEP_SUMMARY"
fi

echo "SAI_GPU_CASE_MATRIX_RESULT passed=$passed failed=$failed infra=$infra"
[[ $passed -eq 48 && $failed -eq 0 && $infra -eq 0 ]]
