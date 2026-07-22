#!/usr/bin/env bash

set -euo pipefail

mode=${1:-}
terminal_states='BOOT_FAIL|CANCELLED|COMPLETED|DEADLINE|FAILED|NODE_FAIL|OUT_OF_MEMORY|PREEMPTED|REVOKED|SPECIAL_EXIT|TIMEOUT'

validate_run_root() {
    local run_root=$1
    [[ $run_root == "$HOME/"* ]]
    [[ $run_root == */benchmarks/rt-tddft-efficiency/* ]]
    [[ -d $run_root && -f $run_root/metadata.tsv && -f $run_root/benchmark.tsv ]]
}

job_ids_csv() {
    local run_root=$1
    awk -F'\t' 'BEGIN {sep=""} {printf "%s%s", sep, $3; sep=","} END {print ""}' \
        "$run_root/jobs.tsv"
}

run_sbatch_matrix() {
    local submit_mode=$1
    local run_root=$2
    local index label cell nx ny nz atoms nodes ranks gpus_per_node case_root output job_id
    local -a args=() submitted_ids=()

    validate_run_root "$run_root"
    [[ -x $run_root/control/rt_tddft_efficiency_remote.sh ]]
    [[ -f $run_root/control/rt_tddft_scale.sbatch ]]
    [[ -x $run_root/control/summarize_rt_tddft_efficiency.sh ]]
    [[ $submit_mode == preflight || $submit_mode == submit ]]
    if [[ $submit_mode == submit ]]; then
        [[ ! -e $run_root/jobs.tsv ]]
        : > "$run_root/jobs.tsv"
    fi

    while IFS=$'\t' read -r index label cell nx ny nz atoms nodes ranks gpus_per_node case_root; do
        [[ $index =~ ^[0-6]$ ]]
        [[ $label =~ ^[a-z0-9-]+$ ]]
        [[ $nodes =~ ^[12]$ ]]
        [[ $ranks =~ ^(4|8|16|32)$ ]]
        [[ $gpus_per_node =~ ^(4|8|16)$ ]]
        [[ $((nodes * gpus_per_node)) -eq $ranks ]]
        [[ $case_root == "$run_root/cases/$index-$label" ]]
        [[ -f $case_root/metadata.tsv && -f $case_root/manifest.tsv ]]
        args=(
            --parsable
            --job-name="gha-eff-${run_root##*/}-$index"
            --array=0-0
            --partition=16V100
            --qos=flood-gpu
            --nodes="$nodes"
            --ntasks="$ranks"
            --gpus-per-node="$gpus_per_node"
            --time=01:00:00
            --chdir="$case_root"
            --output="$case_root/results/slurm-%A_%a.out"
            --export=ALL
        )
        if [[ $submit_mode == preflight ]]; then
            args+=(--test-only)
            (
                cd "$case_root"
                sbatch "${args[@]}" "$run_root/control/rt_tddft_scale.sbatch"
            )
        else
            output=$(
                cd "$case_root"
                sbatch "${args[@]}" "$run_root/control/rt_tddft_scale.sbatch"
            )
            job_id=${output%%;*}
            [[ $job_id =~ ^[0-9]+$ ]]
            submitted_ids+=("$job_id")
            printf '%s\t%s\t%s\t%s\n' "$index" "$label" "$job_id" "$case_root" \
                >> "$run_root/jobs.tsv"
            printf 'SUBMITTED\t%s\t%s\t%s\n' "$index" "$label" "$job_id"
        fi
    done < "$run_root/benchmark.tsv"

    if [[ $submit_mode == submit ]]; then
        local IFS=,
        printf 'SLURM_JOB_IDS=%s\n' "${submitted_ids[*]}"
    fi
}

case $mode in
    prepare)
        [[ $# -eq 6 ]]
        project_root=$2
        install_run=$3
        run_key=$4
        run_kind=$5
        expected_abacus_sha256=$6
        [[ $project_root == "$HOME/"* ]]
        [[ $run_key =~ ^[0-9]+-[0-9]+$ ]]
        [[ $run_kind == trial || $run_kind == formal ]]
        project_root=$(realpath -e "$project_root")
        [[ $project_root == "$HOME/"* ]]
        install_run_root=$(realpath -e "$project_root/$install_run")
        [[ $install_run_root == "$project_root/runs/"* ]]
        [[ -x $install_run_root/install/bin/abacus ]]
        [[ -d $install_run_root/source/tests/PP_ORB ]]
        [[ -f $install_run_root/control/mpirun_with_mapping.sh ]]
        base_case=$install_run_root/source/tests/15_rtTDDFT_GPU/19_NO_Si48_CUSOLVERMP_TDDFT_GPU
        [[ -f $base_case/INPUT && -f $base_case/KPT ]]
        toolchain=$install_run_root/control/toolchains/archive-mp09-sai-nccl2293.env.example
        [[ -f $toolchain ]]
        [[ $expected_abacus_sha256 =~ ^[0-9a-f]{64}$ ]]
        actual_abacus_sha256=$(sha256sum "$install_run_root/install/bin/abacus" | awk '{print $1}')
        [[ $actual_abacus_sha256 == "$expected_abacus_sha256" ]]

        run_root=$project_root/benchmarks/rt-tddft-efficiency/$run_key
        [[ ! -e $run_root ]]
        mkdir -p "$run_root/control" "$run_root/results" "$run_root/cases"
        {
            printf 'project_root\t%s\n' "$project_root"
            printf 'install_run_root\t%s\n' "$install_run_root"
            printf 'abacus\t%s\n' "$install_run_root/install/bin/abacus"
            printf 'expected_abacus_sha256\t%s\n' "$expected_abacus_sha256"
            printf 'run_kind\t%s\n' "$run_kind"
            printf 'created_utc\t%s\n' "$(date -u +%FT%TZ)"
        } > "$run_root/metadata.tsv"
        : > "$run_root/benchmark.tsv"

        if [[ $run_kind == trial ]]; then
            case_specs=(
                '0 trial-8-si1000 5x5x5 1 8 8'
                '1 trial-8-si2000 5x5x10 1 8 8'
                '2 trial-32-si1000 5x5x5 2 32 16'
            )
        else
            case_specs=(
                '0 base-4-si1000 5x5x5 1 4 4'
                '1 strong-8-si1000 5x5x5 1 8 8'
                '2 strong-16-si1000 5x5x5 1 16 16'
                '3 strong-32-si1000 5x5x5 2 32 16'
                '4 weak-8-si2000 5x5x10 1 8 8'
                '5 weak-16-si4000 5x10x10 1 16 16'
                '6 weak-32-si8000 10x10x10 2 32 16'
            )
        fi

        for spec in "${case_specs[@]}"; do
            read -r index label cell nodes ranks gpus_per_node <<< "$spec"
            IFS=x read -r nx ny nz <<< "$cell"
            atoms=$((8 * nx * ny * nz))
            case_root=$run_root/cases/$index-$label
            mkdir -p "$case_root/control" "$case_root/results/tasks" "$case_root/template"
            cp "$base_case/INPUT" "$base_case/KPT" "$case_root/template/"
            cp "$toolchain" "$case_root/control/toolchain.env"
            cp "$install_run_root/control/mpirun_with_mapping.sh" "$case_root/control/"
            printf '0\t%s\t%s\t%s\t%s\t%s\n' "$cell" "$nx" "$ny" "$nz" "$atoms" \
                > "$case_root/manifest.tsv"
            printf '%s  %s\n' "$actual_abacus_sha256" "$install_run_root/install/bin/abacus" \
                > "$case_root/abacus.sha256"
            {
                printf 'project_root\t%s\n' "$project_root"
                printf 'install_run_root\t%s\n' "$install_run_root"
                printf 'abacus\t%s\n' "$install_run_root/install/bin/abacus"
                printf 'expected_abacus_sha256\t%s\n' "$expected_abacus_sha256"
                printf 'benchmark_label\t%s\n' "$label"
                printf 'expected_nodes\t%s\n' "$nodes"
                printf 'expected_ranks\t%s\n' "$ranks"
                printf 'expected_gpus_per_node\t%s\n' "$gpus_per_node"
            } > "$case_root/metadata.tsv"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$index" "$label" "$cell" "$nx" "$ny" "$nz" "$atoms" \
                "$nodes" "$ranks" "$gpus_per_node" "$case_root" \
                >> "$run_root/benchmark.tsv"
        done
        printf 'RUN_ROOT=%s\n' "$run_root"
        ;;

    preflight|submit)
        [[ $# -eq 2 ]]
        run_root=$2
        run_sbatch_matrix "$mode" "$run_root"
        [[ $mode != preflight ]] || echo 'SLURM_PREFLIGHT_OK'
        ;;

    status)
        [[ $# -eq 2 ]]
        run_root=$2
        validate_run_root "$run_root"
        [[ -f $run_root/jobs.tsv ]]
        if [[ ! -s $run_root/jobs.tsv ]]; then
            echo 'SLURM_JOB_IDS=none'
            echo 'ACTIVE_TASKS=0'
            exit 0
        fi
        job_list=$(job_ids_csv "$run_root")
        [[ $job_list =~ ^[0-9]+(,[0-9]+)*$ ]]
        active=$(squeue --noheader --jobs="$job_list" | wc -l)
        printf 'SLURM_JOB_IDS=%s\nACTIVE_TASKS=%s\n' "$job_list" "$active"
        ;;

    summarize)
        [[ $# -eq 2 ]]
        run_root=$2
        validate_run_root "$run_root"
        [[ -f $run_root/jobs.tsv ]]
        job_list=$(job_ids_csv "$run_root")
        results=$run_root/results
        accounting_ready=1
        accounting_output=
        declare -A final_states=() job_ids=()
        while IFS=$'\t' read -r index label job_id case_root; do
            job_ids[$index]=$job_id
        done < "$run_root/jobs.tsv"
        if [[ -n $job_list ]]; then
            accounting_ready=0
            for accounting_attempt in {1..30}; do
                if accounting_output=$(sacct --jobs="$job_list" --noheader --allocations \
                    --parsable2 --format=JobID,State,ExitCode,Elapsed,MaxRSS,MaxVMSize,AllocTRES); then
                    final_states=()
                    while IFS='|' read -r got_job_id got_state rest; do
                        [[ -n ${got_job_id:-} ]] || continue
                        got_state=${got_state%% *}
                        got_state=${got_state%%+}
                        final_states[$got_job_id]=$got_state
                    done <<< "$accounting_output"
                    accounting_ready=1
                    for index in "${!job_ids[@]}"; do
                        state=${final_states[${job_ids[$index]}_0]:-}
                        if [[ ! $state =~ ^($terminal_states)$ ]]; then
                            accounting_ready=0
                            break
                        fi
                    done
                    [[ $accounting_ready -eq 0 ]] || break
                else
                    echo "sacct failed for benchmark jobs (attempt $accounting_attempt/30)" >&2
                fi
                sleep 10
            done
        fi
        [[ $accounting_ready -eq 1 ]]
        printf '%s\n' "$accounting_output" > "$results/slurm-sacct.tsv"
        case_results=$results/case-results.tsv
        : > "$case_results"
        infra_count=0
        nonpass_count=0
        {
            echo '# SAI RT-TDDFT scaling benchmark'
            echo
            echo '| Case | Atoms | GPUs | Nodes | Result | Exit | Elapsed (s) | Peak/GPU on batch node (MiB) | Capacity/GPU (MiB) | Peak SM (%) | Peak power/GPU (W) |'
            echo '|:---|---:|---:|---:|:---:|---:|---:|---:|---:|---:|---:|'
            while IFS=$'\t' read -r index label cell nx ny nz atoms nodes ranks gpus_per_node case_root; do
                result_file=$case_root/results/tasks/0/result.tsv
                missing_result=0
                if [[ -z ${job_ids[$index]+x} ]]; then
                    state=NOT_SUBMITTED
                    missing_result=1
                    result=INFRA_NOT_SUBMITTED
                    rc=- elapsed=- peak_gpu=- capacity=- peak_util=- peak_power=-
                elif [[ -f $result_file ]]; then
                    job_id=${job_ids[$index]}
                    state=${final_states[${job_id}_0]}
                    IFS=$'\t' read -r result rc elapsed _basis peak_gpu _peak_sum capacity peak_util peak_power < "$result_file"
                else
                    job_id=${job_ids[$index]}
                    state=${final_states[${job_id}_0]}
                    missing_result=1
                    result=INFRA_$state
                    rc=- elapsed=- peak_gpu=- capacity=- peak_util=- peak_power=-
                fi
                case $state in
                    OUT_OF_MEMORY) result=HOST_OOM ;;
                    TIMEOUT) result=TIMEOUT ;;
                    *) [[ $missing_result -eq 0 ]] || infra_count=$((infra_count + 1)) ;;
                esac
                [[ $result == PASS ]] || nonpass_count=$((nonpass_count + 1))
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$label" "$atoms" "$ranks" "$nodes" "$result" "$rc" "$elapsed" \
                    "$peak_gpu" "$capacity" "$peak_util" "$peak_power" >> "$case_results"
                printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
                    "$label" "$atoms" "$ranks" "$nodes" "$result" "$rc" "$elapsed" \
                    "$peak_gpu" "$capacity" "$peak_util" "$peak_power"
            done < "$run_root/benchmark.tsv"
            echo
            echo 'GPU memory, SM and power cover the batch node only; elapsed time and result cover the full MPI job.'
        } > "$results/summary.md"

        printf '\n' >> "$results/summary.md"
        bash "$run_root/control/summarize_rt_tddft_efficiency.sh" "$case_results" \
            >> "$results/summary.md"
        if [[ $nonpass_count -gt 0 ]]; then
            printf '\nBenchmark incomplete: **%s** required case(s) did not pass.\n' \
                "$nonpass_count" >> "$results/summary.md"
        fi
        cat "$results/summary.md"
        [[ $infra_count -eq 0 && $nonpass_count -eq 0 ]]
        ;;

    collect)
        [[ $# -eq 2 ]]
        run_root=$2
        validate_run_root "$run_root"
        tar -czf - --exclude='cases/*/results/tasks/*/case/OUT.ABACUS' \
            -C "$run_root" metadata.tsv benchmark.tsv jobs.tsv results cases
        ;;

    *)
        echo "Usage: $0 {prepare|preflight|submit|status|summarize|collect} ..." >&2
        exit 2
        ;;
esac
