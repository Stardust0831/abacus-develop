#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 SCALE_RESULTS_TSV" >&2
    exit 2
fi

input=$1
[[ -f $input ]]

ladder_cells=(
    1x1x1 1x2x2 2x2x2 2x3x3 3x3x3 3x3x4 3x4x4 4x4x4 4x4x5
    4x4x6 4x5x5 4x5x6 5x5x5 5x5x6 5x6x6 6x6x6 6x6x7
    6x7x7 7x7x7 7x7x8 7x8x8 8x8x8
)
ladder_atoms=(
    8 32 64 144 216 288 384 512 640 768 800 960 1000 1200 1440
    1728 2016 2352 2744 3136 3584 4096
)

declare -a cells=() atoms=() results=() ambiguous=()
declare -A seen_cells=()
count=0
pass_count=0
max_pass=0
min_tested=

while IFS=$'\t' read -r cell atom result extra; do
    [[ -n $cell && -n $atom && -n $result && -z ${extra:-} ]]
    [[ $cell =~ ^([1-9][0-9]?)x([1-9][0-9]?)x([1-9][0-9]?)$ ]]
    expected_atoms=$((8 * BASH_REMATCH[1] * BASH_REMATCH[2] * BASH_REMATCH[3]))
    [[ $atom =~ ^[1-9][0-9]*$ && $atom -eq $expected_atoms ]]
    [[ $result =~ ^(PASS|GPU_OOM|HOST_OOM|TIMEOUT|FAIL|MEMORY_ERROR|INFRA_[A-Z_]+)$ ]]
    [[ -z ${seen_cells[$cell]+x} ]]
    seen_cells[$cell]=1

    cells+=("$cell")
    atoms+=("$atom")
    results+=("$result")
    count=$((count + 1))
    if [[ -z $min_tested || $atom -lt $min_tested ]]; then
        min_tested=$atom
    fi
    if [[ $result == PASS ]]; then
        pass_count=$((pass_count + 1))
        if (( atom > max_pass )); then
            max_pass=$atom
        fi
    elif [[ $result == FAIL || $result == MEMORY_ERROR || $result == INFRA_* ]]; then
        ambiguous+=("$cell")
    fi
done < "$input"

(( count >= 1 && count <= 5 ))

join_cells() {
    local IFS=,
    printf '%s' "$*"
}

emit() {
    local reason=$1
    shift
    if [[ $# -eq 0 ]]; then
        echo 'NEXT_SUPERCELLS=none'
    else
        printf 'NEXT_SUPERCELLS=%s\n' "$(join_cells "$@")"
    fi
    printf 'NEXT_REASON=%s\n' "$reason"
}

if (( ${#ambiguous[@]} > 0 )); then
    emit repeat-ambiguous "${ambiguous[@]:0:5}"
    exit 0
fi

declare -a candidates=()
if (( pass_count == count )); then
    for i in "${!ladder_atoms[@]}"; do
        if (( ladder_atoms[i] > max_pass )); then
            candidates+=("${ladder_cells[i]}")
            (( ${#candidates[@]} == 5 )) && break
        fi
    done
    emit search-above "${candidates[@]}"
    exit 0
fi

if (( pass_count == 0 )); then
    for i in "${!ladder_atoms[@]}"; do
        if (( ladder_atoms[i] < min_tested )); then
            candidates+=("${ladder_cells[i]}")
        fi
    done
    if (( ${#candidates[@]} > 5 )); then
        candidates=("${candidates[@]:${#candidates[@]}-5}")
    fi
    emit search-below "${candidates[@]}"
    exit 0
fi

declare -a nonmonotonic=()
min_failure=
min_failure_result=
for i in "${!cells[@]}"; do
    if [[ ${results[i]} != PASS && ${atoms[i]} -lt $max_pass ]]; then
        nonmonotonic+=("${cells[i]}")
    elif [[ ${results[i]} != PASS && ${atoms[i]} -gt $max_pass ]] && \
        [[ -z $min_failure || ${atoms[i]} -lt $min_failure ]]; then
        min_failure=${atoms[i]}
        min_failure_result=${results[i]}
    fi
done

if (( ${#nonmonotonic[@]} > 0 )); then
    emit repeat-nonmonotonic "${nonmonotonic[@]:0:5}"
    exit 0
fi

if [[ -z $min_failure ]]; then
    for i in "${!ladder_atoms[@]}"; do
        if (( ladder_atoms[i] > max_pass )); then
            candidates+=("${ladder_cells[i]}")
            (( ${#candidates[@]} == 5 )) && break
        fi
    done
    emit search-above "${candidates[@]}"
    exit 0
fi

for i in "${!ladder_atoms[@]}"; do
    if (( ladder_atoms[i] > max_pass && ladder_atoms[i] < min_failure )); then
        candidates+=("${ladder_cells[i]}")
        (( ${#candidates[@]} == 5 )) && break
    fi
done

case $min_failure_result in
    GPU_OOM|HOST_OOM) reason=refine-capacity-boundary ;;
    TIMEOUT) reason=refine-runtime-boundary ;;
    *) reason=repeat-ambiguous ;;
esac
emit "$reason" "${candidates[@]}"
