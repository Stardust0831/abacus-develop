#!/usr/bin/env bash

set -euo pipefail

: "${CI_SOURCE:?}"
: "${RESULT_ROOT:?}"

matrix_root="$RESULT_ROOT/case-matrix"
manifest_root="$matrix_root/manifests"
[[ ! -e "$manifest_root" ]] || {
    echo "Refusing to replace existing manifests: $manifest_root" >&2
    exit 1
}
mkdir -p "$manifest_root"

declare -A seen=()
declare -A counts=([gpu1]=0 [gpu2]=0 [gpu4]=0)

add_case() {
    local class=$1
    local suite=$2
    local case_name=$3
    local key="$suite/$case_name"
    local case_dir="$CI_SOURCE/tests/$key"

    [[ $class =~ ^gpu(1|2|4)$ ]]
    [[ $suite =~ ^[A-Za-z0-9_.-]+$ ]]
    [[ $case_name =~ ^[A-Za-z0-9_.-]+$ ]]
    [[ -d "$case_dir" ]] || {
        echo "GPU case directory is missing: $case_dir" >&2
        exit 1
    }
    [[ -f "$case_dir/result.ref" ]] || {
        echo "GPU case has no numerical reference: $key" >&2
        exit 1
    }
    [[ -z ${seen[$key]+x} ]] || {
        echo "GPU case is assigned more than once: $key" >&2
        exit 1
    }

    seen[$key]=$class
    counts[$class]=$((counts[$class] + 1))
    printf '%s\t%s\n' "$suite" "$case_name" >> "$manifest_root/$class.tsv"
}

read_cases() {
    local class=$1
    local suite=$2
    local cases_file="$CI_SOURCE/tests/$suite/CASES_GPU.txt"
    local line case_name

    [[ -f "$cases_file" ]]
    while IFS= read -r line || [[ -n $line ]]; do
        case_name=${line%%#*}
        read -r case_name <<< "$case_name"
        [[ -n $case_name ]] || continue
        add_case "$class" "$suite" "$case_name"
    done < "$cases_file"
}

while IFS= read -r case_name || [[ -n $case_name ]]; do
    case_name=${case_name%%#*}
    read -r case_name <<< "$case_name"
    [[ -n $case_name ]] || continue
    case "$case_name" in
        scf_out_wf) add_case gpu1 11_PW_GPU "$case_name" ;;
        scf_bpcg) add_case gpu2 11_PW_GPU "$case_name" ;;
        *) add_case gpu4 11_PW_GPU "$case_name" ;;
    esac
done < "$CI_SOURCE/tests/11_PW_GPU/CASES_GPU.txt"

read_cases gpu4 12_NAO_Gamma_GPU
read_cases gpu4 13_NAO_multik_GPU
read_cases gpu4 15_rtTDDFT_GPU
read_cases gpu2 16_SDFT_GPU

[[ ${counts[gpu1]} -eq 1 ]]
[[ ${counts[gpu2]} -eq 7 ]]
[[ ${counts[gpu4]} -eq 40 ]]
[[ ${#seen[@]} -eq 48 ]]

summary="$matrix_root/inventory.txt"
{
    echo "GPU_CASE_MATRIX_TOTAL=${#seen[@]}"
    for class in gpu1 gpu2 gpu4; do
        echo "GPU_CASE_MATRIX_${class^^}=${counts[$class]}"
    done
} | tee "$summary"

echo "SAI_GPU_CASE_MANIFESTS_READY root=$manifest_root"
