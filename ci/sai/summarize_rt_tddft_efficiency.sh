#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 CASE_RESULTS_TSV" >&2
    exit 2
fi

input=$1
[[ -f $input ]]
baseline=$(awk -F'\t' '$1 == "base-4-si1000" && $5 == "PASS" {print $7}' "$input")
[[ $baseline =~ ^[1-9][0-9]*$ ]] || exit 0

echo '## Strong scaling: Si1000'
echo
echo '| GPUs | Elapsed (s) | Speedup vs 4 GPU | Parallel efficiency |'
echo '|---:|---:|---:|---:|'
awk -F'\t' -v base="$baseline" '
    $2 == 1000 && $5 == "PASS" {
        speedup=base/$7; efficiency=100*speedup/($3/4)
        printf "| %d | %d | %.3f | %.1f%% |\n", $3, $7, speedup, efficiency
    }
' "$input"
echo
echo '## Weak scaling: about 250 atoms/GPU'
echo
echo '| GPUs | Atoms | Elapsed (s) | Weak-scaling efficiency |'
echo '|---:|---:|---:|---:|'
awk -F'\t' -v base="$baseline" '
    ($1 == "base-4-si1000" || $1 ~ /^weak-/) && $5 == "PASS" {
        printf "| %d | %d | %d | %.1f%% |\n", $3, $2, $7, 100*base/$7
    }
' "$input"
