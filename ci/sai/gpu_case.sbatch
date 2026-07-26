#!/usr/bin/env bash

# Resource flags are supplied by the Python coordinator. Keeping this file
# free of scheduler directives prevents a stale header from overriding a
# validated profile.
set -euo pipefail

if [[ $# -ne 10 ]]; then
    echo "Usage: $0 HOME SOURCE CONTROL INSTALL RESULTS TOOLCHAIN MAPPING_ROOT DISABLE_IB PROFILE MANIFEST" >&2
    exit 2
fi
export HOME=$1
export USER=${SLURM_JOB_USER:?}
export LOGNAME=$USER
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CI_SOURCE=$2
CONTROL_ROOT=$3
INSTALL_ROOT=$4
RESULT_ROOT=$5
TOOLCHAIN_FILE=$6
MPS_MAPPING_ROOT=$7
SAI_DISABLE_NCCL_IB=$8
expected_profile=$9
GPU_CASE_MANIFEST=${10}
export CI_SOURCE CONTROL_ROOT INSTALL_ROOT RESULT_ROOT TOOLCHAIN_FILE
: "${SLURM_ARRAY_TASK_ID:?}"
: "${SLURM_ARRAY_JOB_ID:?}"
: "${SLURM_JOB_ID:?}"

[[ $SLURM_ARRAY_TASK_ID =~ ^[0-9]+$ ]]
[[ -f $GPU_CASE_MANIFEST && ! -L $GPU_CASE_MANIFEST ]]
manifest_real=$(realpath -e "$GPU_CASE_MANIFEST")
matrix_real=$(realpath -e "$RESULT_ROOT/case-matrix")
[[ $manifest_real == "$matrix_real/"* ]]
manifest_line=$((SLURM_ARRAY_TASK_ID + 2))
line=$(sed -n "${manifest_line}p" "$GPU_CASE_MANIFEST")
[[ -n $line ]] || {
    echo "No manifest row for array task $SLURM_ARRAY_TASK_ID" >&2
    exit 2
}
IFS=$'\t' read -r case_id suite case_name resource runner retries extra <<< "$line"
[[ -z ${extra:-} ]]
[[ $case_id =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?$ ]]
[[ $suite =~ ^[A-Za-z0-9_.-]+$ ]]
[[ $case_name =~ ^[A-Za-z0-9_.-]+$ ]]
[[ $case_id == "$suite/$case_name" ]]
[[ $resource =~ ^[A-Za-z0-9_.-]+$ ]]
[[ $runner == autotest || $runner == cusolvermp ]]
[[ $retries =~ ^[1-9][0-9]*$ ]]
task_key=${case_id//\//__}

matrix_root="$RESULT_ROOT/case-matrix"
task_root="$matrix_root/tasks/$task_key"
status_root="$matrix_root/status"
status_file="$status_root/$task_key.tsv"
work_root="$task_root/work"
mkdir -p "$work_root/tests/$suite" "$status_root" "$task_root/launcher" "$task_root/artifacts"

start_epoch=$(date +%s)
status_written=0
write_status() {
    local state=$1
    local rc=$2
    local elapsed=$(( $(date +%s) - start_epoch ))
    local temporary
    temporary=$(mktemp "$status_root/.$task_key.XXXXXX")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$case_id" "$suite" "$case_name" "$resource" "$runner" "$state" "$rc" \
        "$elapsed" "$SLURM_ARRAY_JOB_ID" "$SLURM_ARRAY_TASK_ID" > "$temporary"
    mv -T "$temporary" "$status_file"
    status_written=1
}
on_exit() {
    local rc=$?
    if [[ $status_written -eq 0 ]]; then
        write_status INFRA "$rc"
    fi
    exit "$rc"
}
trap on_exit EXIT

source_tests=$(realpath -e "$CI_SOURCE/tests")
source_case=$(realpath -e "$source_tests/$suite/$case_name")
[[ $source_case == "$source_tests/$suite/$case_name" && -d $source_case && ! -L $source_case ]]
if find "$source_case" -type l -print -quit | grep -q .; then
    echo "GPU case contains a symbolic link: $suite/$case_name" >&2
    exit 2
fi
if [[ $runner == cusolvermp ]]; then
    declare -A expected_hashes=(
        [INPUT]=1285180c32058368699e0ec8c0b50d73f6a8af3e89aabe2791c91a210ed57c54
        [KPT]=91042b39ee493cb5c1bee648adc865a2e5935a29278eb405dc009f994db55ece
        [README]=19a018be686ce24a5e43684cac588e10cf72ade391fd08a6f600e316cfe48ce7
        [STRU]=8da05442b1f70f79b3decd603c94bd7d650b5f31df166db2916e981b61294760
    )
    for filename in INPUT KPT README STRU; do
        [[ $(sha256sum "$source_case/$filename" | awk '{print $1}') == \
           "${expected_hashes[$filename]}" ]]
    done
fi

ln -s "$CI_SOURCE/tests/integrate" "$work_root/tests/integrate"
ln -s "$CI_SOURCE/tests/PP_ORB" "$work_root/tests/PP_ORB"
rsync -a "$source_case" "$work_root/tests/$suite/"
printf '%s\n' "$case_name" > "$work_root/tests/$suite/CASES.task.txt"
work_case="$work_root/tests/$suite/$case_name"

# shellcheck source=/dev/null
source "$TOOLCHAIN_FILE"
declare -F sai_load_toolchain >/dev/null || {
    echo "Missing sai_load_toolchain() in $TOOLCHAIN_FILE" >&2
    exit 2
}
sai_load_toolchain
[[ ${SAI_PROFILE_NAME:-} == "$expected_profile" ]]
# shellcheck source=/dev/null
source "$MPS_MAPPING_ROOT/${SLURM_JOB_PARTITION}.bash"
case "$SAI_DISABLE_NCCL_IB" in
    true) export NCCL_IB_DISABLE=1 ;;
    false) unset NCCL_IB_DISABLE ;;
    *) echo "Invalid SAI_DISABLE_NCCL_IB=$SAI_DISABLE_NCCL_IB" >&2; exit 2 ;;
esac

SAI_SYSTEM_MPIRUN=$(command -v mpirun)
export SAI_SYSTEM_MPIRUN MAP_OPT
ln -s "$CONTROL_ROOT/mpirun_with_mapping.sh" "$task_root/launcher/mpirun"
export PATH="$task_root/launcher:$PATH"
export LD_LIBRARY_PATH="$SAI_MPI_ROOT/lib:$SAI_CUDA_ROOT/lib64:$SAI_CUSOLVERMP_ROOT/lib:$SAI_CUBLASMP_ROOT/lib:$SAI_NCCL_ROOT/lib:$SAI_NVHPC_ROOT/math_libs/12.9/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

ABACUS="$INSTALL_ROOT/bin/abacus"
[[ -x $ABACUS ]]
ABACUS_LDD=$(ldd "$ABACUS")
printf '%s\n' "$ABACUS_LDD" > "$task_root/artifacts/abacus-ldd.txt"
if grep -q 'not found' <<< "$ABACUS_LDD"; then
    echo "ABACUS has unresolved runtime dependencies" >&2
    exit 1
fi
NCCL_LOADED=$(awk '$1 == "libnccl.so.2" {print $3; exit}' <<< "$ABACUS_LDD")
[[ -n $NCCL_LOADED ]]
NCCL_EXPECTED=$(readlink -f "$SAI_NCCL_ROOT/lib/libnccl.so.2")
[[ $(readlink -f "$NCCL_LOADED") == "$NCCL_EXPECTED" ]]

set +e
if [[ $runner == autotest ]]; then
    bash "$CONTROL_ROOT/run_gpu_case_attempts.sh" \
        "$work_root/tests/$suite" "$work_root/tests/$suite/$case_name" \
        "$case_name" "$ABACUS" "$SLURM_NTASKS" "${OMP_NUM_THREADS:-1}" \
        "$task_root" "$retries"
    test_rc=$?
else
    cd "$work_case"
    timeout --signal=TERM --kill-after=30s 35m \
        mpirun -np "$SLURM_NTASKS" "$ABACUS" \
        2>&1 | tee "$task_root/artifacts/cusolvermp.log"
    test_rc=${PIPESTATUS[0]}
fi
set -e

pmix_metadata="$task_root/pmix-retry.tsv"
if [[ $test_rc -eq 0 ]]; then
    state=PASS
elif [[ $test_rc -eq 124 || $test_rc -eq 137 || $test_rc -eq 143 ]]; then
    state=TIMEOUT
elif [[ $runner == autotest ]] && \
     { [[ ! -f $pmix_metadata ]] || grep -Fxq $'final_pmix\t1' "$pmix_metadata"; }; then
    state=INFRA
else
    state=FAIL
fi
write_status "$state" "$test_rc"
echo "SAI_GPU_CASE_RESULT case=$case_id suite=$suite name=$case_name state=$state rc=$test_rc"
exit "$test_rc"
