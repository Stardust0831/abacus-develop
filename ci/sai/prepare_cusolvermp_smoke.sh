#!/usr/bin/env bash

set -euo pipefail

: "${CI_SOURCE:?}"
: "${RESULT_ROOT:?}"

source_suite="$CI_SOURCE/tests/15_rtTDDFT_GPU"
source_input="$source_suite/11_NO_O3_TDDFT_GPU/INPUT"
smoke_root="$RESULT_ROOT/cusolvermp-smoke"
smoke_suite="$smoke_root/15_rtTDDFT_GPU"
smoke_input="$smoke_suite/11_NO_O3_TDDFT_GPU/INPUT"
cusolver_pattern='^[[:space:]]*ks_solver[[:space:]]+cusolver[[:space:]]*$'
cusolvermp_pattern='^[[:space:]]*ks_solver[[:space:]]+cusolvermp[[:space:]]*$'

[[ -d $source_suite && -f $source_input ]]
[[ -d $CI_SOURCE/tests/integrate && -d $CI_SOURCE/tests/PP_ORB ]]
[[ ! -e $smoke_root && ! -L $smoke_root ]]
[[ $(grep -Ec "$cusolver_pattern" "$source_input") -eq 1 ]] || {
    echo "Expected exactly one ks_solver=cusolver line in $source_input" >&2
    exit 1
}

source_hash=$(sha256sum "$source_input" | awk '{print $1}')
mkdir -p "$smoke_root"
cp -a "$source_suite" "$smoke_root/"
ln -s "$CI_SOURCE/tests/integrate" "$smoke_root/integrate"
ln -s "$CI_SOURCE/tests/PP_ORB" "$smoke_root/PP_ORB"
sed -i -E \
    's/^[[:space:]]*ks_solver[[:space:]]+cusolver[[:space:]]*$/ks_solver         cusolvermp/' \
    "$smoke_input"

[[ $(grep -Ec "$cusolvermp_pattern" "$smoke_input") -eq 1 ]]
[[ $(grep -Ec "$cusolver_pattern" "$smoke_input") -eq 0 ]]
[[ $(sha256sum "$source_input" | awk '{print $1}') == "$source_hash" ]]
printf 'CUSOLVERMP_SMOKE_SUITE=%s\n' "$smoke_suite"
