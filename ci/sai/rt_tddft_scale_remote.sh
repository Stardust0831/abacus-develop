#!/usr/bin/env bash

set -euo pipefail

mode=${1:-}
canonical_home=$(cd "$HOME" && pwd -P)

validate_run_root() {
    local run_root=$1
    [[ $run_root == "$canonical_home/"* ]]
    [[ $run_root == */benchmarks/rt-tddft-4gpu/* ]]
    [[ -d $run_root && -f $run_root/metadata.tsv && -f $run_root/manifest.tsv ]]
}

run_scale_sbatch() {
    local submit_mode=$1
    local run_root=$2
    local count run_key
    local -a args

    validate_run_root "$run_root"
    [[ -x $run_root/control/rt_tddft_scale_remote.sh ]]
    [[ -f $run_root/control/rt_tddft_scale.sbatch ]]
    [[ -x $run_root/control/select_rt_tddft_scale_batch.sh ]]
    count=$(wc -l < "$run_root/manifest.tsv")
    (( count >= 1 && count <= 5 ))
    run_key=${run_root##*/}
    [[ $run_key =~ ^[0-9]+-[0-9]+$ ]]

    args=(
        --parsable
        --job-name="gha-scale-$run_key"
        --array="0-$((count - 1))%$count"
        --partition=16V100
        --qos=flood-gpu
        --nodes=1
        --ntasks=4
        --gpus-per-node=4
        --time=01:00:00
        --chdir="$run_root"
        --output="$run_root/results/slurm-%A_%a.out"
        --export=ALL
    )
    if [[ $submit_mode == preflight ]]; then
        args+=(--test-only)
    else
        [[ $submit_mode == submit ]]
    fi
    (
        cd "$run_root"
        sbatch "${args[@]}" "$run_root/control/rt_tddft_scale.sbatch"
    )
}

case $mode in
    prepare)
        [[ $# -eq 6 ]]
        project_root=$(realpath -e "$2")
        install_run=$3
        run_key=$4
        supercells=$5
        expected_abacus_sha256=$6
        [[ $project_root == "$canonical_home/"* ]]
        [[ $run_key =~ ^[0-9]+-[0-9]+$ ]]
        install_run_root=$(realpath -e "$project_root/$install_run")
        [[ $install_run_root == "$project_root/runs/"* ]]
        [[ -x $install_run_root/install/bin/abacus ]]
        [[ -d $install_run_root/source/tests/PP_ORB ]]
        [[ -f $install_run_root/control/mpirun_with_mapping.sh ]]
        base_case=$install_run_root/source/tests/15_rtTDDFT_GPU/19_NO_Si48_CUSOLVERMP_TDDFT_GPU
        [[ -f $base_case/INPUT && -f $base_case/KPT ]]
        toolchain=$install_run_root/control/toolchains/abacus-develop-git-079fd0c.env.example
        [[ -f $toolchain ]]
        [[ $expected_abacus_sha256 =~ ^[0-9a-f]{64}$ ]]
        actual_abacus_sha256=$(sha256sum "$install_run_root/install/bin/abacus" | awk '{print $1}')
        [[ $actual_abacus_sha256 == "$expected_abacus_sha256" ]]

        run_root=$project_root/benchmarks/rt-tddft-4gpu/$run_key
        [[ ! -e $run_root ]]
        mkdir -p "$run_root/control" "$run_root/results/tasks" "$run_root/template"
        cp "$base_case/INPUT" "$base_case/KPT" "$run_root/template/"
        cp "$toolchain" "$run_root/control/toolchain.env"
        cp "$install_run_root/control/mpirun_with_mapping.sh" "$run_root/control/"

        IFS=',' read -r -a cells <<< "$supercells"
        : > "$run_root/manifest.tsv"
        for index in "${!cells[@]}"; do
            cell=${cells[$index]}
            [[ $cell =~ ^([1-9][0-9]?)x([1-9][0-9]?)x([1-9][0-9]?)$ ]]
            nx=${BASH_REMATCH[1]}
            ny=${BASH_REMATCH[2]}
            nz=${BASH_REMATCH[3]}
            atoms=$((8 * nx * ny * nz))
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$index" "$cell" "$nx" "$ny" "$nz" "$atoms" \
                >> "$run_root/manifest.tsv"
        done
        printf '%s  %s\n' "$actual_abacus_sha256" "$install_run_root/install/bin/abacus" \
            > "$run_root/abacus.sha256"
        {
            printf 'project_root\t%s\n' "$project_root"
            printf 'install_run_root\t%s\n' "$install_run_root"
            printf 'abacus\t%s\n' "$install_run_root/install/bin/abacus"
            printf 'expected_abacus_sha256\t%s\n' "$expected_abacus_sha256"
            printf 'supercells\t%s\n' "$supercells"
            printf 'created_utc\t%s\n' "$(date -u +%FT%TZ)"
        } > "$run_root/metadata.tsv"
        printf 'RUN_ROOT=%s\n' "$run_root"
        ;;

    preflight|submit)
        [[ $# -eq 2 ]]
        run_root=$2
        if [[ $mode == preflight ]]; then
            run_scale_sbatch preflight "$run_root"
            echo 'SLURM_PREFLIGHT_OK'
            exit 0
        fi
        job_id=$(run_scale_sbatch submit "$run_root")
        job_id=${job_id%%;*}
        [[ $job_id =~ ^[0-9]+$ ]]
        printf '%s\n' "$job_id" > "$run_root/slurm-job-id"
        printf 'SLURM_JOB_ID=%s\n' "$job_id"
        ;;

    status)
        [[ $# -eq 3 ]]
        run_root=$2
        job_id=$3
        validate_run_root "$run_root"
        [[ $job_id =~ ^[0-9]+$ ]]
        [[ $(<"$run_root/slurm-job-id") == "$job_id" ]]
        active=$(squeue --noheader --jobs="$job_id" | wc -l)
        printf 'SLURM_JOB_ID=%s\nACTIVE_TASKS=%s\n' "$job_id" "$active"
        ;;

    summarize)
        [[ $# -eq 3 ]]
        run_root=$2
        job_id=$3
        validate_run_root "$run_root"
        [[ $job_id =~ ^[0-9]+$ ]]
        [[ $(<"$run_root/slurm-job-id") == "$job_id" ]]
        results=$run_root/results
        terminal_states='BOOT_FAIL|CANCELLED|COMPLETED|DEADLINE|FAILED|NODE_FAIL|OUT_OF_MEMORY|PREEMPTED|REVOKED|SPECIAL_EXIT|TIMEOUT'
        accounting_ready=0
        accounting_output=
        declare -A final_states=()
        for accounting_attempt in {1..30}; do
            if accounting_output=$(sacct --jobs="$job_id" --noheader --allocations \
                --parsable2 --format=JobID,State,ExitCode,Elapsed,MaxRSS,MaxVMSize,AllocTRES); then
                final_states=()
                while IFS='|' read -r got_job_id got_state rest; do
                    [[ -n ${got_job_id:-} ]] || continue
                    got_state=${got_state%% *}
                    got_state=${got_state%%+}
                    final_states[$got_job_id]=$got_state
                done <<< "$accounting_output"
                accounting_ready=1
                while IFS=$'\t' read -r index cell nx ny nz atoms; do
                    state=${final_states[${job_id}_${index}]:-}
                    if [[ ! $state =~ ^($terminal_states)$ ]]; then
                        accounting_ready=0
                        break
                    fi
                done < "$run_root/manifest.tsv"
                [[ $accounting_ready -eq 0 ]] || break
            else
                echo "sacct failed while checking scale tasks (attempt $accounting_attempt/30)" >&2
            fi
            sleep 10
        done
        [[ $accounting_ready -eq 1 ]] || {
            echo "Unable to prove a terminal Slurm state for every scale task" >&2
            exit 1
        }
        printf '%s\n' "$accounting_output" > "$results/slurm-sacct.tsv"
        infra_count=0
        selection_input=$results/selection-input.tsv
        : > "$selection_input"
        {
            echo "# SAI 4-GPU Si RT-TDDFT scale probe"
            echo
            echo "Slurm array: \`$job_id\` on \`flood-gpu\`; each task used one node, four MPI ranks and four GPUs."
            echo
            echo "| Task | Supercell | Atoms | Basis | Entered script | Result | Exit | Elapsed (s) | Peak/GPU (MiB) | Peak sum (MiB) | Capacity/GPU (MiB) | Peak SM (%) | Peak power (W) |"
            echo "|---:|:---:|---:|---:|:---:|:---:|---:|---:|---:|---:|---:|---:|---:|"
            while IFS=$'\t' read -r index cell nx ny nz atoms; do
                result_file=$results/tasks/$index/result.tsv
                entered=no
                [[ ! -f $results/tasks/$index/task-entered.tsv ]] || entered=yes
                if [[ -f $result_file ]]; then
                    IFS=$'\t' read -r result rc elapsed basis peak_gpu peak_sum capacity peak_util peak_power < "$result_file"
                else
                    state=${final_states[${job_id}_${index}]}
                    case $state in
                        OUT_OF_MEMORY) result=HOST_OOM ;;
                        TIMEOUT) result=TIMEOUT ;;
                        *)
                            result=INFRA_$state
                            infra_count=$((infra_count + 1))
                            ;;
                    esac
                    rc=-
                    elapsed=-
                    basis=$((atoms * 13))
                    peak_gpu=-
                    peak_sum=-
                    capacity=-
                    peak_util=-
                    peak_power=-
                fi
                printf '%s\t%s\t%s\n' "$cell" "$atoms" "$result" >> "$selection_input"
                printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
                    "$index" "$cell" "$atoms" "$basis" "$entered" "$result" "$rc" \
                    "$elapsed" "$peak_gpu" "$peak_sum" "$capacity" "$peak_util" "$peak_power"
            done < "$run_root/manifest.tsv"
            echo
            echo "A passing point proves completion of this two-step smoke input. GPU_OOM and HOST_OOM are separate capacity bounds; MEMORY_ERROR remains ambiguous and is not a bound without log inspection."
        } > "$results/summary.md"
        bash "$run_root/control/select_rt_tddft_scale_batch.sh" "$selection_input" \
            > "$results/next-batch.env"
        {
            echo
            echo '## Recommended second batch'
            echo
            sed 's/^/- `/' "$results/next-batch.env" | sed 's/$/`/'
        } >> "$results/summary.md"
        cat "$results/summary.md"
        if [[ $infra_count -gt 0 ]]; then
            echo "Scale probe had $infra_count task(s) without result evidence" >&2
            exit 1
        fi
        ;;

    collect)
        [[ $# -eq 2 ]]
        run_root=$2
        validate_run_root "$run_root"
        tar -czf - --exclude='results/tasks/*/case/OUT.*' \
            -C "$run_root" metadata.tsv manifest.tsv abacus.sha256 slurm-job-id results
        ;;

    diagnose)
        [[ $# -eq 3 ]]
        job_id=$2
        project_root=$(realpath -e "$3")
        [[ $job_id =~ ^[0-9]+$ ]]
        [[ $project_root == "$canonical_home/"* ]]
        printf 'DIAGNOSE_JOB_ID=%s\nDIAGNOSE_HOST=%s\nDIAGNOSE_TIME=%s\n' \
            "$job_id" "$(hostname)" "$(date -u +%FT%TZ)"

        set +e
        echo "===== scontrol show job ====="
        scontrol show job --details "$job_id" 2>&1
        echo "===== sacct allocations ====="
        sacct --duplicates --jobs="$job_id" --noheader --allocations --parsable2 \
            --format=JobID,JobIDRaw,JobName,Partition,QOS,State,ExitCode,DerivedExitCode,Elapsed,Timelimit,Submit,Eligible,Start,End,NodeList,ReqTRES,AllocTRES 2>&1
        echo "===== sacct comments ====="
        sacct --duplicates --jobs="$job_id" --noheader --allocations --parsable2 \
            --format=JobID,State,Comment,AdminComment,SystemComment 2>&1
        echo "===== partition ====="
        scontrol show partition 16V100 2>&1
        echo "===== qos ====="
        sacctmgr --noheader --parsable2 show qos where name=flood-gpu 2>&1
        echo "===== prolog configuration ====="
        scontrol show config 2>&1 \
            | grep -E '^(Prolog|Epilog|TaskPlugin|JobAcctGather|SchedulerParameters)' || true
        set -e

        job_file=
        while IFS= read -r candidate; do
            if [[ $(<"$candidate") == "$job_id" ]]; then
                job_file=$candidate
                break
            fi
        done < <(find "$project_root/benchmarks/rt-tddft-4gpu" \
            -mindepth 2 -maxdepth 2 -type f -name slurm-job-id -print 2>/dev/null)
        if [[ -n $job_file ]]; then
            run_root=$(dirname "$job_file")
            echo "===== remote run files ====="
            printf 'RUN_ROOT=%s\n' "$run_root"
            stat -c '%A %a %U:%G %s %n' \
                "$run_root" "$run_root/control" \
                "$run_root/control/rt_tddft_scale_remote.sh" \
                "$run_root/control/rt_tddft_scale.sbatch"
            find "$run_root/results" -mindepth 1 -maxdepth 3 \
                -printf '%M %u:%g %s %TY-%Tm-%TdT%TH:%TM:%TS %p\n' | sort
            sha256sum "$run_root/control/rt_tddft_scale.sbatch"
            sed -n '1,16p' "$run_root/control/rt_tddft_scale.sbatch"
        else
            echo "RUN_ROOT=not-found"
        fi
        ;;

    *)
        echo "Usage: $0 {prepare|preflight|submit|status|summarize|collect|diagnose} ..." >&2
        exit 2
        ;;
esac
