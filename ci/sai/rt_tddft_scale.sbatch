#!/usr/bin/env bash

set -euo pipefail

: "${SLURM_SUBMIT_DIR:?}"
: "${SLURM_ARRAY_JOB_ID:?}"
: "${SLURM_ARRAY_TASK_ID:?}"
: "${SLURM_NTASKS:?}"
[[ $SLURM_NTASKS -eq 4 ]]
[[ ${SLURM_GPUS_ON_NODE:-} == 4 ]]

RUN_ROOT=$(realpath -e "$SLURM_SUBMIT_DIR")
[[ $RUN_ROOT == "$HOME/"* ]]
[[ $RUN_ROOT == */benchmarks/rt-tddft-4gpu/* ]]
[[ -f $RUN_ROOT/metadata.tsv && -f $RUN_ROOT/manifest.tsv ]]

entry_root=$RUN_ROOT/results/tasks/$SLURM_ARRAY_TASK_ID
mkdir -p "$entry_root"
{
    printf 'entered_utc\t%s\n' "$(date -u +%FT%TZ)"
    printf 'hostname\t%s\n' "$(hostname)"
    printf 'slurm_job_id\t%s\n' "${SLURM_JOB_ID:?}"
    printf 'slurm_array_job_id\t%s\n' "$SLURM_ARRAY_JOB_ID"
    printf 'slurm_array_task_id\t%s\n' "$SLURM_ARRAY_TASK_ID"
} > "$entry_root/task-entered.tsv"

metadata=$RUN_ROOT/metadata.tsv
manifest=$RUN_ROOT/manifest.tsv
install_run_root=$(awk -F'\t' '$1 == "install_run_root" {print $2}' "$metadata")
project_root=$(awk -F'\t' '$1 == "project_root" {print $2}' "$metadata")
expected_abacus_sha256=$(awk -F'\t' '$1 == "expected_abacus_sha256" {print $2}' "$metadata")
[[ $install_run_root == "$project_root/runs/"* ]]
abacus=$install_run_root/install/bin/abacus
pp_orb=$install_run_root/source/tests/PP_ORB
[[ -x $abacus && -d $pp_orb ]]
[[ $(sha256sum "$abacus" | awk '{print $1}') == "$expected_abacus_sha256" ]]

line=$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" "$manifest")
IFS=$'\t' read -r index cell nx ny nz atoms <<< "$line"
[[ $index == "$SLURM_ARRAY_TASK_ID" ]]
basis=$((atoms * 13))
task_root=$RUN_ROOT/results/tasks/$index
case_root=$task_root/case
mkdir -p "$case_root"
cp "$RUN_ROOT/template/KPT" "$case_root/KPT"
awk -v pp="$pp_orb" -v suffix="si${atoms}_4gpu" '
    $1 == "suffix" {printf "%-18s%s\n", "suffix", suffix; next}
    $1 == "pseudo_dir" {printf "%-18s%s\n", "pseudo_dir", pp; next}
    $1 == "orbital_dir" {printf "%-18s%s\n", "orbital_dir", pp; next}
    {print}
' "$RUN_ROOT/template/INPUT" > "$case_root/INPUT"

awk -v nx="$nx" -v ny="$ny" -v nz="$nz" -v atoms="$atoms" 'BEGIN {
    px[0]=0.00; py[0]=0.00; pz[0]=0.00
    px[1]=0.25; py[1]=0.25; pz[1]=0.25
    px[2]=0.00; py[2]=0.50; pz[2]=0.50
    px[3]=0.25; py[3]=0.75; pz[3]=0.75
    px[4]=0.50; py[4]=0.00; pz[4]=0.50
    px[5]=0.75; py[5]=0.25; pz[5]=0.75
    px[6]=0.50; py[6]=0.50; pz[6]=0.00
    px[7]=0.75; py[7]=0.75; pz[7]=0.25
    print "ATOMIC_SPECIES"
    print "Si 28.085 Si_ONCV_PBE-1.0.upf"
    print ""
    print "NUMERICAL_ORBITAL"
    print "Si_gga_6au_100Ry_2s2p1d.orb"
    print ""
    print "LATTICE_CONSTANT"
    print "10.2"
    print ""
    print "LATTICE_VECTORS"
    printf "%d 0.0 0.0\n0.0 %d 0.0\n0.0 0.0 %d\n", nx, ny, nz
    print ""
    print "ATOMIC_POSITIONS"
    print "Cartesian"
    print ""
    print "Si"
    print "0.0"
    print atoms
    for (ix=0; ix<nx; ix++)
        for (iy=0; iy<ny; iy++)
            for (iz=0; iz<nz; iz++)
                for (p=0; p<8; p++)
                    printf "%.2f %.2f %.2f 0 0 0\n", ix+px[p], iy+py[p], iz+pz[p]
}' > "$case_root/STRU"

export SAI_PROJECT_ROOT=$project_root
unset SAI_CUSOLVERMP_ROOT SAI_CUBLASMP_ROOT
# shellcheck source=/dev/null
source "$RUN_ROOT/control/toolchain.env"
[[ $SAI_PROFILE_NAME == archive-mp09-sai-nccl2293 ]]
sai_load_toolchain
[[ ${NCCL_SAI_RAIL_BY_CHANNEL:-} == 1 ]]
[[ -z ${LD_PRELOAD:-} ]]
# shellcheck source=/dev/null
source "/opt/sai_config/mps_mapping.d/${SLURM_JOB_PARTITION}.bash"
unset NCCL_IB_DISABLE
SAI_SYSTEM_MPIRUN=$(command -v mpirun)
export SAI_SYSTEM_MPIRUN MAP_OPT
mkdir -p "$task_root/launcher"
ln -s "$RUN_ROOT/control/mpirun_with_mapping.sh" "$task_root/launcher/mpirun"
export PATH="$task_root/launcher:$PATH"
export LD_LIBRARY_PATH="$SAI_MPI_ROOT/lib:$SAI_CUDA_ROOT/lib64:$SAI_CUSOLVERMP_ROOT/lib:$SAI_CUBLASMP_ROOT/lib:$SAI_NCCL_ROOT/lib:$SAI_NVHPC_ROOT/math_libs/12.9/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

ldd "$abacus" > "$task_root/ldd.txt"
if grep -q 'not found' "$task_root/ldd.txt"; then
    echo "ABACUS has unresolved runtime dependencies" >&2
    exit 1
fi
loaded_cusolvermp=$(awk '$1 == "libcusolverMp.so.0" {print $3; exit}' "$task_root/ldd.txt")
loaded_cublasmp=$(awk '$1 == "libcublasmp.so.0" {print $3; exit}' "$task_root/ldd.txt")
loaded_nccl=$(awk '$1 == "libnccl.so.2" {print $3; exit}' "$task_root/ldd.txt")
[[ -n $loaded_cusolvermp && -n $loaded_cublasmp && -n $loaded_nccl ]]
expected_cusolvermp=$(readlink -f "$SAI_CUSOLVERMP_ROOT/lib/libcusolverMp.so.0")
expected_cublasmp=$(readlink -f "$SAI_CUBLASMP_ROOT/lib/libcublasmp.so.0")
expected_nccl=$(readlink -f "$SAI_NCCL_ROOT/lib/libnccl.so.2")
loaded_cusolvermp=$(readlink -f "$loaded_cusolvermp")
loaded_cublasmp=$(readlink -f "$loaded_cublasmp")
loaded_nccl=$(readlink -f "$loaded_nccl")
[[ $loaded_cusolvermp == "$expected_cusolvermp" ]]
[[ $loaded_cublasmp == "$expected_cublasmp" ]]
[[ $loaded_nccl == "$expected_nccl" ]]
[[ $SAI_CUSOLVERMP_ROOT == *libcusolvermp-linux-x86_64-0.9.0.6427_cuda12-archive ]]
[[ $SAI_CUBLASMP_ROOT == *libcublasmp-linux-x86_64-0.9.1.3056_cuda12-archive ]]
[[ $SAI_NCCL_ROOT == *nccl_2.29.3_cuda12.9_sai_v2.29.3-1-sai.1 ]]
{
    printf 'libcusolverMp.so.0\t%s\n' "$loaded_cusolvermp"
    printf 'libcublasmp.so.0\t%s\n' "$loaded_cublasmp"
    printf 'libnccl.so.2\t%s\n' "$loaded_nccl"
} > "$task_root/runtime-libraries.tsv"
"$abacus" --info > "$task_root/abacus-info.txt"
env | grep -E '^(CUDA_VISIBLE_DEVICES|LD_LIBRARY_PATH|NCCL_|OMPI_|OMP_|PATH=|PRTE_|SAI_|SLURM_(ARRAY|GPUS|JOB|NODE|NTASKS|PARTITION|STEP)|UCX_)' \
    | sort > "$task_root/environment.txt"
: "${CUDA_VISIBLE_DEVICES:?Slurm did not expose the allocated GPUs}"
gpu_selector=${SLURM_JOB_GPUS:-$CUDA_VISIBLE_DEVICES}
IFS=',' read -r -a allocated_gpus <<< "$gpu_selector"
[[ ${#allocated_gpus[@]} -eq 4 ]]
nvidia_smi=(nvidia-smi -i "$gpu_selector")
"${nvidia_smi[@]}" -q > "$task_root/nvidia-smi-before.txt"

monitor_file=$task_root/gpu-samples.csv
monitor_flag=$task_root/.monitor
touch "$monitor_flag"
monitor_pid=
stop_monitor() {
    rm -f "$monitor_flag"
    if [[ -n ${monitor_pid:-} ]]; then
        wait "$monitor_pid" 2>/dev/null || true
    fi
}
trap stop_monitor EXIT HUP INT TERM
(
    echo "timestamp,index,uuid,memory.used,memory.total,utilization.gpu,power.draw,power.limit"
    while [[ -e $monitor_flag ]]; do
        "${nvidia_smi[@]}" --query-gpu=timestamp,index,uuid,memory.used,memory.total,utilization.gpu,power.draw,power.limit \
            --format=csv,noheader,nounits || true
        sleep 5
    done
) > "$monitor_file" &
monitor_pid=$!

start_epoch=$(date +%s)
cd "$case_root"
attempt=1
retried=0
while true; do
    attempt_log=$task_root/abacus-attempt-${attempt}.log
    set +e
    /usr/bin/time -v -o "$task_root/time-attempt-${attempt}.txt" \
        timeout --signal=TERM --kill-after=30s 55m \
        mpirun -np 4 "$abacus" > "$attempt_log" 2>&1
    rc=$?
    set -e
    if [[ $attempt -eq 1 && $rc -ne 0 && $rc -ne 124 && $rc -ne 137 && $rc -ne 143 ]] && \
        grep -aEq 'PMIX_ERR_(FILE_OPEN_FAILURE|OUT_OF_RESOURCE)' "$attempt_log" && \
        grep -aFq 'MPI_Init_thread' "$attempt_log" && \
        grep -aFq 'PMIx_Init failed' "$attempt_log"; then
        retried=1
        attempt=2
        sleep 10
        rm -rf "$case_root/OUT.ABACUS"
        continue
    fi
    break
done
{
    for ((i=1; i<=attempt; i++)); do
        printf '===== ATTEMPT %s/%s =====\n' "$i" "$attempt"
        cat "$task_root/abacus-attempt-${i}.log"
    done
} > "$task_root/abacus.log"
{
    printf 'attempts\t%s\n' "$attempt"
    printf 'retried\t%s\n' "$retried"
    printf 'final_rc\t%s\n' "$rc"
} > "$task_root/pmix-retry.tsv"
elapsed=$(( $(date +%s) - start_epoch ))
stop_monitor
monitor_pid=
trap - EXIT HUP INT TERM
"${nvidia_smi[@]}" -q > "$task_root/nvidia-smi-after.txt"

awk -F',' '
    NR == 1 {next}
    {
        for (i=1; i<=NF; i++) {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)}
        stamp=$1; uuid=$3; used=$4+0; total=$5+0; util=$6+0; power=$7+0
        if (used > peak[uuid]) peak[uuid]=used
        if (power > peak_power[uuid]) peak_power[uuid]=power
        if (util > peak_util[uuid]) peak_util[uuid]=util
        capacity[uuid]=total
        sum[stamp]+=used
    }
    END {
        print "uuid\tpeak_memory_mib\tmemory_capacity_mib\tpeak_utilization_pct\tpeak_power_w"
        for (uuid in peak) printf "%s\t%d\t%d\t%d\t%.2f\n", uuid, peak[uuid], capacity[uuid], peak_util[uuid], peak_power[uuid]
    }
' "$monitor_file" > "$task_root/gpu-peaks.tsv"

read -r peak_gpu peak_sum capacity peak_util peak_power < <(awk -F',' '
    NR == 1 {next}
    {
        for (i=1; i<=NF; i++) {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)}
        used=$4+0; total=$5+0; util=$6+0; power=$7+0
        if (used > peak_gpu) peak_gpu=used
        sum[$1]+=used
        if (total > capacity) capacity=total
        if (util > peak_util) peak_util=util
        if (power > peak_power) peak_power=power
    }
    END {
        for (stamp in sum) if (sum[stamp] > peak_sum) peak_sum=sum[stamp]
        printf "%d %d %d %d %.2f\n", peak_gpu, peak_sum, capacity, peak_util, peak_power
    }
' "$monitor_file")

result=FAIL
if [[ $rc -eq 0 ]]; then
    result=PASS
elif [[ $rc -eq 124 ]]; then
    result=TIMEOUT
elif grep -aEqi 'CUDA_ERROR_OUT_OF_MEMORY|cudaErrorMemoryAllocation|CUDA error[^[:cntrl:]]*out of memory|cudaMalloc[^[:cntrl:]]*(out of memory|failed)' "$task_root/abacus.log"; then
    result=GPU_OOM
elif grep -aEqi 'std::bad_alloc|cannot allocate memory' "$task_root/abacus.log"; then
    result=HOST_OOM
elif grep -aEqi 'out of memory|bad_alloc|memory allocation' "$task_root/abacus.log"; then
    result=MEMORY_ERROR
fi
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$result" "$rc" "$elapsed" "$basis" "$peak_gpu" "$peak_sum" "$capacity" "$peak_util" "$peak_power" \
    > "$task_root/result.tsv"
printf 'RESULT=%s RC=%s SUPERCELL=%s ATOMS=%s BASIS=%s ELAPSED=%s PEAK_GPU_MIB=%s PEAK_SUM_MIB=%s\n' \
    "$result" "$rc" "$cell" "$atoms" "$basis" "$elapsed" "$peak_gpu" "$peak_sum"
exit "$rc"
