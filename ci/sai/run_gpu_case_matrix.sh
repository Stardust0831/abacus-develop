#!/usr/bin/env bash

set -euo pipefail

: "${CI_SOURCE:?}"
: "${INSTALL_ROOT:?}"
: "${RESULT_ROOT:?}"
: "${TOOLCHAIN_FILE:?}"
: "${MP_PROFILE:?}"

bash "$CI_SOURCE/ci/sai/prepare_gpu_case_matrix.sh"

matrix_root="$RESULT_ROOT/case-matrix"
manifest_root="$matrix_root/manifests"
log_root="$matrix_root/logs"
mkdir -p "$log_root"

classes=(gpu1 gpu2 gpu4)
declare -A limits=([gpu1]=1 [gpu2]=4 [gpu4]=4)
declare -A scripts=(
    [gpu1]="$CI_SOURCE/ci/sai/test_gpu_array_1.sbatch"
    [gpu2]="$CI_SOURCE/ci/sai/test_gpu_array_2.sbatch"
    [gpu4]="$CI_SOURCE/ci/sai/test_gpu_array_4.sbatch"
)
declare -A job_ids=()
declare -A task_counts=()
declare -A job_names=()
declare -A job_id_files=()
active=1

cancel_arrays() {
    local class job_id_file recovered_id
    if [[ $active -eq 1 ]]; then
        for class in "${classes[@]}"; do
            job_id_file=${job_id_files[$class]:-}
            if [[ -z ${job_ids[$class]:-} && -n $job_id_file && -s $job_id_file ]]; then
                recovered_id=$(<"$job_id_file")
                recovered_id=${recovered_id%%;*}
                if [[ $recovered_id =~ ^[0-9]+$ ]]; then
                    job_ids[$class]=$recovered_id
                fi
            fi
            if [[ -n ${job_ids[$class]:-} ]]; then
                scancel "${job_ids[$class]}" || true
            elif [[ -n ${job_names[$class]:-} ]]; then
                scancel --user="$USER" --name="${job_names[$class]}" || true
            fi
        done
    fi
}
cleanup_job_id_files() {
    local class
    for class in "${classes[@]}"; do
        if [[ -n ${job_id_files[$class]:-} ]]; then
            rm -f "${job_id_files[$class]}"
        fi
    done
}
terminate() {
    cancel_arrays
    active=0
    cleanup_job_id_files
    exit 143
}
trap terminate INT TERM
trap 'cancel_arrays; cleanup_job_id_files' EXIT

jobs_file="$matrix_root/array-jobs.tsv"
: > "$jobs_file"
for class in "${classes[@]}"; do
    manifest="$manifest_root/$class.tsv"
    count=$(wc -l < "$manifest")
    [[ $count -gt 0 ]]
    task_counts[$class]=$count
    last_task=$((count - 1))
    job_name="gha-${GITHUB_RUN_ID:-manual}-${class}-$$"
    job_names[$class]=$job_name
    job_id_file=$(mktemp "$matrix_root/.${class}-jobid.XXXXXX")
    job_id_files[$class]=$job_id_file
    sbatch --parsable \
        --job-name="$job_name" \
        --array="0-${last_task}%${limits[$class]}" \
        --chdir="$CI_SOURCE" \
        --output="$log_root/${class}-%A_%a.out" \
        --export="ALL,GPU_CASE_MANIFEST=$manifest,GPU_CASE_BODY=$CI_SOURCE/ci/sai/test_gpu_case.sh" \
        "${scripts[$class]}" > "$job_id_file"
    job_id=$(<"$job_id_file")
    job_id=${job_id%%;*}
    [[ $job_id =~ ^[0-9]+$ ]]
    job_ids[$class]=$job_id
    printf '%s\t%s\t%s\n' "$class" "$job_id" "$count" | tee -a "$jobs_file"
done

job_list="${job_ids[gpu1]},${job_ids[gpu2]},${job_ids[gpu4]}"
queue_failures=0
while true; do
    if ! queue_output=$(squeue --noheader --jobs="$job_list"); then
        queue_failures=$((queue_failures + 1))
        echo "squeue failed for array jobs (attempt $queue_failures/6)" >&2
        if [[ $queue_failures -ge 6 ]]; then
            echo "Unable to prove that the GPU arrays left the queue" >&2
            exit 1
        fi
        sleep 10
        continue
    fi
    queue_failures=0
    if [[ -z $queue_output ]]; then
        break
    fi
    sleep 10
done

terminal_states='BOOT_FAIL|CANCELLED|COMPLETED|DEADLINE|FAILED|NODE_FAIL|OUT_OF_MEMORY|PREEMPTED|REVOKED|SPECIAL_EXIT|TIMEOUT'
accounting_ready=0
accounting_output=
declare -A final_states=()
declare -A final_exit_codes=()
for accounting_attempt in {1..30}; do
    if accounting_output=$(sacct --noheader --allocations --jobs="$job_list" \
        --parsable2 --format=JobIDRaw,State,ExitCode); then
        final_states=()
        final_exit_codes=()
        while IFS='|' read -r got_job_id got_state got_exit_code; do
            [[ -n ${got_job_id:-} ]] || continue
            got_state=${got_state%% *}
            got_state=${got_state%%+}
            final_states[$got_job_id]=$got_state
            final_exit_codes[$got_job_id]=$got_exit_code
        done <<< "$accounting_output"

        accounting_ready=1
        for class in "${classes[@]}"; do
            for ((task_id = 0; task_id < task_counts[$class]; task_id++)); do
                task_job_id="${job_ids[$class]}_${task_id}"
                task_state=${final_states[$task_job_id]:-}
                if [[ ! $task_state =~ ^($terminal_states)$ ]]; then
                    accounting_ready=0
                    break 2
                fi
            done
        done
        if [[ $accounting_ready -eq 1 ]]; then
            break
        fi
    else
        echo "sacct failed while verifying array completion (attempt $accounting_attempt/30)" >&2
    fi
    sleep 10
done

if [[ $accounting_ready -ne 1 ]]; then
    echo "Unable to prove a terminal Slurm state for every GPU array task" >&2
    exit 1
fi

accounting_file="$matrix_root/array-task-accounting.tsv"
: > "$accounting_file"
for class in "${classes[@]}"; do
    for ((task_id = 0; task_id < task_counts[$class]; task_id++)); do
        task_job_id="${job_ids[$class]}_${task_id}"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$class" "$task_id" "${job_ids[$class]}" \
            "${final_states[$task_job_id]}" "${final_exit_codes[$task_job_id]}" \
            >> "$accounting_file"
    done
done
printf 'SLURM_ARRAYS_TERMINAL=%s\n' "$job_list" \
    > "$matrix_root/arrays-terminal.txt"

active=0
trap - INT TERM EXIT
cleanup_job_id_files

if ! sacct --noheader --allocations --jobs="$job_list" \
    --format=JobIDRaw,JobName,State,ExitCode,Elapsed,NodeList \
    > "$matrix_root/array-sacct.txt"; then
    printf '%s\n' "$accounting_output" > "$matrix_root/array-sacct.txt"
fi

bash "$CI_SOURCE/ci/sai/summarize_gpu_case_matrix.sh"
