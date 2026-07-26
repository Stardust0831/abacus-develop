#!/usr/bin/env bash

set -euo pipefail

mode=normal
case ${1:-} in
    '') ;;
    --dry-run) mode=dry-run ;;
    --cron) mode=cron ;;
    *) echo "Usage: $0 [--dry-run|--cron]" >&2; exit 2 ;;
esac

canonical_home=$(cd "$HOME" && pwd -P)
state_root=$(realpath --canonicalize-missing "$HOME/.local/state/abacus-sai-ci")
cache_root=$(realpath --canonicalize-missing "$HOME/.cache/abacus-sai-ci")
[[ $state_root == "$canonical_home/"* ]]
[[ $cache_root == "$canonical_home/"* ]]
mkdir -p "$state_root" "$cache_root"
state_root=$(cd "$state_root" && pwd -P)
cache_root=$(cd "$cache_root" && pwd -P)
[[ $state_root == "$canonical_home/"* ]]
[[ $cache_root == "$canonical_home/"* ]]
if [[ $mode == cron ]]; then
    log="$state_root/cleanup.log"
    if [[ -L $log || ( -e $log && ! -f $log ) || \
          -L $log.1 || ( -e $log.1 && ! -f $log.1 ) ]]; then
        echo "Refusing unsafe cleanup log path under $state_root" >&2
        exit 1
    fi
    if [[ -f $log && $(stat -c %s "$log") -gt 10485760 ]]; then
        mv -T "$log" "$log.1"
    fi
    exec "$0" >> "$log" 2>&1
fi

exec 9<"$cache_root"
flock -n 9 || exit 0
registry="$HOME/.config/abacus-sai-ci/project-roots"
[[ ! -L $registry ]]
[[ -f $registry ]] || exit 0
now=$(date +%s)
squeue_checked=0
squeue_ok=0
active_job_ids=

load_active_jobs() {
    local output
    [[ $squeue_checked -eq 0 ]] || return 0
    squeue_checked=1
    if ! output=$(squeue --noheader --user="$USER" --format='%F' 2>&1); then
        echo "SQUEUE_QUERY_FAILED output=$output"
        return 0
    fi
    active_job_ids=$(awk '$1 ~ /^[0-9]+$/ {print $1}' <<< "$output" | sort -u)
    squeue_ok=1
}

has_active_jobs() {
    local run_root=$1 ledger=$1/results/jobs.json jobs job_id
    [[ -e $ledger || -L $ledger ]] || return 1
    if [[ ! -f $ledger || -L $ledger ]]; then
        echo "SKIP invalid_job_ledger run=$run_root"
        return 0
    fi
    if ! jobs=$(python3 - "$ledger" 2>/dev/null <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    ledger = json.load(handle)
if not isinstance(ledger, dict) or set(ledger) != {"protocol", "jobs"} or ledger["protocol"] != 1:
    raise SystemExit(1)
if not isinstance(ledger["jobs"], list) or not ledger["jobs"]:
    raise SystemExit(1)
ids = []
for job in ledger["jobs"]:
    if not isinstance(job, dict) or set(job) != {"job_id", "name", "label", "array_count", "argv"}:
        raise SystemExit(1)
    if not isinstance(job["job_id"], str) or not re.fullmatch(r"[0-9]+", job["job_id"]):
        raise SystemExit(1)
    ids.append(job["job_id"])
if len(set(ids)) != len(ids):
    raise SystemExit(1)
print(",".join(ids))
PY
    ); then
        echo "SKIP invalid_job_ledger run=$run_root"
        return 0
    fi
    load_active_jobs
    if [[ $squeue_ok -ne 1 ]]; then
        echo "SKIP squeue_failed run=$run_root jobs=$jobs"
        return 0
    fi
    while IFS= read -r job_id; do
        if grep -Fxq "$job_id" <<< "$active_job_ids"; then
            return 0
        fi
    done < <(tr ',' '\n' <<< "$jobs")
    return 1
}

remove_candidate() {
    local path=$1 reason=$2
    if has_active_jobs "$path"; then
        echo "SKIP active_or_unknown path=$path reason=$reason"
    elif [[ $mode == dry-run ]]; then
        echo "DRY_RUN delete path=$path reason=$reason"
    else
        rm -rf --one-file-system -- "$path"
        echo "DELETED path=$path reason=$reason"
    fi
}

while IFS= read -r configured_root; do
    [[ -n $configured_root ]] || continue
    project_root=$(realpath --canonicalize-missing "$configured_root")
    [[ $project_root == "$canonical_home/"* ]] || {
        echo "SKIP root_outside_home path=$project_root"
        continue
    }
    if [[ -d $project_root/runs ]]; then
        while IFS= read -r -d '' run_root; do
            run_name=${run_root##*/}
            [[ $run_name =~ ^[0-9]+-[0-9]+$ ]] || continue
            if [[ -f $run_root/.artifacts-uploaded ]]; then
                stamp=$(stat -c %Y "$run_root/.artifacts-uploaded")
                age_limit=259200
                reason=uploaded_over_72h
            elif [[ -f $run_root/.ci-created ]]; then
                stamp=$(stat -c %Y "$run_root/.ci-created")
                age_limit=604800
                reason=incomplete_over_168h
            else
                continue
            fi
            (( now - stamp >= age_limit )) || continue
            remove_candidate "$run_root" "$reason"
        done < <(find "$project_root/runs" -mindepth 1 -maxdepth 2 -type d -print0)
    fi

    if [[ -d $project_root/diagnostics ]]; then
        while IFS= read -r -d '' diagnostic; do
            [[ -f $diagnostic/.ci-diagnostic ]] || continue
            stamp=$(stat -c %Y "$diagnostic/.ci-diagnostic")
            (( now - stamp >= 604800 )) || continue
            remove_candidate "$diagnostic" diagnostic_over_168h
        done < <(find "$project_root/diagnostics" -mindepth 1 -maxdepth 1 -type d -print0)
    fi

    transfer_root="$project_root/cache/source-transfers"
    if [[ -d $transfer_root && ! -L $transfer_root ]]; then
        transfer_root=$(realpath -e "$transfer_root")
        [[ $transfer_root == "$project_root/cache/source-transfers" ]]
        while IFS= read -r -d '' transfer; do
            transfer_name=${transfer##*/}
            [[ $transfer_name =~ ^[0-9]+-[0-9]+$ ]] || continue
            marker="$transfer/.ci-source-transfer"
            [[ -f $marker && ! -L $marker ]] || continue
            stamp=$(stat -c %Y "$marker")
            (( now - stamp >= 604800 )) || continue
            remove_candidate "$transfer" source_transfer_over_168h
        done < <(find "$transfer_root" -mindepth 1 -maxdepth 1 -type d -print0)
    fi
done < "$registry"

echo "CLEANUP_FINISHED mode=$mode at=$(date --iso-8601=seconds)"
