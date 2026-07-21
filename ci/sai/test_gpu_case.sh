#!/usr/bin/env bash

set -euo pipefail

: "${CI_SOURCE:?}"
: "${INSTALL_ROOT:?}"
: "${RESULT_ROOT:?}"
: "${TOOLCHAIN_FILE:?}"
: "${MP_PROFILE:?}"
: "${GPU_CASE_CLASS:?}"
: "${GPU_CASE_RANKS:?}"
: "${GPU_CASE_MANIFEST:?}"
: "${SLURM_ARRAY_JOB_ID:?}"
: "${SLURM_ARRAY_TASK_ID:?}"

[[ "$SLURM_NTASKS" == "$GPU_CASE_RANKS" ]]
[[ "$SLURM_GPUS_ON_NODE" == "$GPU_CASE_RANKS" ]]

line_number=$((SLURM_ARRAY_TASK_ID + 1))
line=$(sed -n "${line_number}p" "$GPU_CASE_MANIFEST")
[[ -n $line ]] || {
    echo "No manifest row $line_number in $GPU_CASE_MANIFEST" >&2
    exit 2
}
IFS=$'\t' read -r suite case_name extra <<< "$line"
[[ -z ${extra:-} ]]
[[ $suite =~ ^[A-Za-z0-9_.-]+$ ]]
[[ $case_name =~ ^[A-Za-z0-9_.-]+$ ]]

matrix_root="$RESULT_ROOT/case-matrix"
task_key="${GPU_CASE_CLASS}-${SLURM_ARRAY_TASK_ID}"
task_root="$matrix_root/tasks/$task_key"
work_root="$task_root/work"
status_root="$matrix_root/status"
status_file="$status_root/$task_key.tsv"
[[ ! -e "$task_root" ]]
mkdir -p "$work_root/tests/$suite" "$status_root" "$task_root/launcher"

start_epoch=$(date +%s)
echo "SAI_GPU_CASE_START class=$GPU_CASE_CLASS task=$SLURM_ARRAY_TASK_ID suite=$suite case=$case_name ranks=$GPU_CASE_RANKS"

ln -s "$CI_SOURCE/tests/integrate" "$work_root/tests/integrate"
ln -s "$CI_SOURCE/tests/PP_ORB" "$work_root/tests/PP_ORB"
rsync -a "$CI_SOURCE/tests/$suite/$case_name" "$work_root/tests/$suite/"
rm -rf "$work_root/tests/$suite/$case_name/OUT.autotest"
rm -f "$work_root/tests/$suite/$case_name/log.txt" \
    "$work_root/tests/$suite/$case_name/result.out"
printf '%s\n' "$case_name" > "$work_root/tests/$suite/CASES.task.txt"

source "$TOOLCHAIN_FILE"
declare -F sai_load_toolchain >/dev/null
sai_load_toolchain
source "/opt/sai_config/mps_mapping.d/${SLURM_JOB_PARTITION}.bash"
unset NCCL_IB_DISABLE

SAI_SYSTEM_MPIRUN=$(command -v mpirun)
export SAI_SYSTEM_MPIRUN MAP_OPT
ln -s "$CI_SOURCE/ci/sai/mpirun_with_mapping.sh" "$task_root/launcher/mpirun"
export PATH="$task_root/launcher:$PATH"
export LD_LIBRARY_PATH="$SAI_MPI_ROOT/lib:$SAI_CUDA_ROOT/lib64:$SAI_CUSOLVERMP_ROOT/lib:$SAI_CUBLASMP_ROOT/lib:$SAI_NVHPC_ROOT/math_libs/12.9/lib64:$SAI_NCCL_ROOT/lib:${LD_LIBRARY_PATH:-}"

ABACUS="$INSTALL_ROOT/bin/abacus"
[[ -x "$ABACUS" ]]
ABACUS_LDD=$(ldd "$ABACUS")
! grep -q 'not found' <<< "$ABACUS_LDD"
NCCL_LOADED=$(awk '$1 == "libnccl.so.2" {print $3; exit}' <<< "$ABACUS_LDD")
NCCL_EXPECTED=$(readlink -f "$SAI_NCCL_ROOT/lib/libnccl.so.2")
[[ $(readlink -f "$NCCL_LOADED") == "$NCCL_EXPECTED" ]]

set +e
(cd "$work_root/tests/$suite" &&
 timeout --signal=TERM --kill-after=30s 10m \
     bash ../integrate/Autotest.sh -a "$ABACUS" -n "$GPU_CASE_RANKS" \
         -o "$OMP_NUM_THREADS" -f CASES.task.txt -r "^${case_name}$") \
    2>&1 | tee "$task_root/case.log"
test_rc=${PIPESTATUS[0]}
set -e

case $test_rc in
    0) state=PASS ;;
    124|137|143) state=TIMEOUT ;;
    *) state=FAIL ;;
esac
elapsed=$(( $(date +%s) - start_epoch ))
status_tmp="$status_file.tmp.$$"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$GPU_CASE_CLASS" "$SLURM_ARRAY_TASK_ID" "$suite" "$case_name" \
    "$GPU_CASE_RANKS" "$state" "$test_rc" "$elapsed" "$SLURM_ARRAY_JOB_ID" \
    > "$status_tmp"
mv "$status_tmp" "$status_file"

echo "SAI_GPU_CASE_RESULT class=$GPU_CASE_CLASS task=$SLURM_ARRAY_TASK_ID suite=$suite case=$case_name state=$state rc=$test_rc elapsed=$elapsed"
exit "$test_rc"
