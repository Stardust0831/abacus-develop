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

for name in INPUT KPT README STRU; do
    [[ -f $source_case/$name ]]
done
[[ -d $CI_SOURCE/tests/PP_ORB ]]
[[ ! -e $smoke_root && ! -L $smoke_root ]]
[[ $(grep -Ec "$cusolvermp_pattern" "$source_input") -eq 1 ]] || {
    echo "Expected exactly one ks_solver=cusolvermp line in $source_input" >&2
    exit 1
}

source_hash=$(sha256sum "$source_input" | awk '{print $1}')
mkdir -p "$smoke_suite"
cp -a "$source_case" "$smoke_suite/"
ln -s "$CI_SOURCE/tests/PP_ORB" "$smoke_root/PP_ORB"

[[ $(grep -Ec "$cusolvermp_pattern" "$smoke_input") -eq 1 ]]
[[ $(sha256sum "$source_input" | awk '{print $1}') == "$source_hash" ]]
printf 'CUSOLVERMP_SMOKE_CASE=%s\n' "$smoke_case"
