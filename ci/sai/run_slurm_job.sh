#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 SUBMIT_LOG OUTPUT_PATTERN JOB_SCRIPT" >&2
    exit 2
fi

submit_log=$1
output_pattern=$2
job_script=$3
job_id=
job_active=0
job_name="gha-${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-0}-$$"
sbatch_args=()
nodelist_pattern='^[[:alnum:],._-]+$'

if [[ -n ${SAI_SLURM_NODELIST:-} ]]; then
    if [[ ! $SAI_SLURM_NODELIST =~ $nodelist_pattern ]]; then
        printf 'Invalid SAI_SLURM_NODELIST: %q\n' "$SAI_SLURM_NODELIST" >&2
        exit 2
    fi
    sbatch_args+=(--nodelist="$SAI_SLURM_NODELIST")
fi

job_id_file=$(mktemp)

cancel_job() {
    if [[ -z $job_id && -s $job_id_file ]]; then
        job_id=$(<"$job_id_file")
        job_id=${job_id%%;*}
        [[ $job_id =~ ^[0-9]+$ ]] || job_id=
    fi
    if [[ $job_active -eq 1 && -n $job_id ]]; then
        echo "Cancelling Slurm job $job_id" | tee -a "$submit_log"
        scancel "$job_id" || true
    elif [[ $job_active -eq 1 ]]; then
        echo "Cancelling Slurm job name $job_name" | tee -a "$submit_log"
        scancel --user="$USER" --name="$job_name" || true
    fi
    rm -f "$job_id_file"
}
terminate() {
    cancel_job
    job_active=0
    exit 143
}
trap terminate INT TERM
trap cancel_job EXIT

job_active=1
sbatch --parsable --export=ALL --job-name="$job_name" \
    --chdir="${CI_SOURCE:?}" \
    --output="$output_pattern" "${sbatch_args[@]}" \
    "$job_script" > "$job_id_file"
job_id=$(<"$job_id_file")
rm -f "$job_id_file"
job_id=${job_id%%;*}
[[ $job_id =~ ^[0-9]+$ ]]
printf 'SLURM_JOB_ID=%s\n' "$job_id" | tee "$submit_log"

record=
while true; do
    record=$(sacct --noheader --allocations --jobs="$job_id" \
        --format=JobIDRaw,State,ExitCode \
        | awk -v id="$job_id" '$1 == id {record=$2 " " $3} END {print record}')
    state=${record%% *}
    state=${state%%+}
    exit_code=${record#* }
    case $state in
        BOOT_FAIL|CANCELLED|COMPLETED|DEADLINE|FAILED|NODE_FAIL|OUT_OF_MEMORY|PREEMPTED|REVOKED|SPECIAL_EXIT|TIMEOUT)
            break
            ;;
    esac
    sleep 10
done
job_active=0
trap - INT TERM EXIT
rm -f "$job_id_file"
printf 'SLURM_FINAL=%s\n' "$record" | tee -a "$submit_log"
[[ $state == COMPLETED && $exit_code == 0:0 ]]
