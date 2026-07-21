#!/usr/bin/env bash

set -euo pipefail

: "${CI_SOURCE:?}"
: "${RESULT_ROOT:?}"

case_name=19_NO_Si48_CUSOLVERMP_TDDFT_GPU
source_case="$CI_SOURCE/tests/15_rtTDDFT_GPU/$case_name"
source_input="$source_case/INPUT"
smoke_root="$RESULT_ROOT/cusolvermp-smoke"
smoke_suite="$smoke_root/15_rtTDDFT_GPU"
smoke_case="$smoke_suite/$case_name"
smoke_input="$smoke_case/INPUT"
cusolvermp_pattern='^[[:space:]]*ks_solver[[:space:]]+cusolvermp[[:space:]]*$'
declare -A expected_sha=(
    [INPUT]=1285180c32058368699e0ec8c0b50d73f6a8af3e89aabe2791c91a210ed57c54
    [KPT]=91042b39ee493cb5c1bee648adc865a2e5935a29278eb405dc009f994db55ece
    [README]=19a018be686ce24a5e43684cac588e10cf72ade391fd08a6f600e316cfe48ce7
    [STRU]=8da05442b1f70f79b3decd603c94bd7d650b5f31df166db2916e981b61294760
)

[[ -d $source_case && ! -L $source_case ]]
for name in INPUT KPT README STRU; do
    source_file=$source_case/$name
    [[ -f $source_file && ! -L $source_file ]]
    actual_sha=$(sha256sum "$source_file" | awk '{print $1}')
    [[ $actual_sha == "${expected_sha[$name]}" ]] || {
        echo "Unexpected $name hash in $source_case: $actual_sha" >&2
        exit 1
    }
done
[[ -d $CI_SOURCE/tests/PP_ORB ]]
[[ ! -e $smoke_root && ! -L $smoke_root ]]
[[ $(grep -Ec "$cusolvermp_pattern" "$source_input") -eq 1 ]] || {
    echo "Expected exactly one ks_solver=cusolvermp line in $source_input" >&2
    exit 1
}

mkdir -p "$smoke_suite"
mkdir "$smoke_case"
for name in INPUT KPT README STRU; do
    install -m 0644 -- "$source_case/$name" "$smoke_case/$name"
done
ln -s "$CI_SOURCE/tests/PP_ORB" "$smoke_root/PP_ORB"

[[ $(grep -Ec "$cusolvermp_pattern" "$smoke_input") -eq 1 ]]
printf 'CUSOLVERMP_SMOKE_CASE=%s\n' "$smoke_case"
