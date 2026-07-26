#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 PROJECT_ROOT RUN_ROOT SOURCE_TRANSFER_ROOT ARCHIVE_SIZE" >&2
    exit 2
fi

canonical_home=$(cd "$HOME" && pwd -P)
project_root=$(realpath -e "$1")
run_root=$(realpath -e "$2")
transfer_root=$(realpath -e "$3")
archive_size=$4
run_name=${run_root##*/}
[[ $project_root == "$canonical_home/"* ]]
[[ $run_root == "$project_root/runs/"* ]]
[[ $run_name =~ ^[0-9]+-[0-9]+$ ]]
[[ $transfer_root == "$project_root/cache/source-transfers/$run_name" ]]
[[ -d $transfer_root && ! -L $transfer_root ]]
marker=$transfer_root/.ci-source-transfer
[[ -f $marker && ! -L $marker ]]
grep -Fxq "run_root=$run_root" "$marker"
[[ $archive_size =~ ^[0-9]+$ ]]
(( archive_size > 0 && archive_size <= 134217728 ))

IFS= read -r download_url
blob_url_pattern='^https://[A-Za-z0-9.-]+\.blob\.core\.windows\.net/[^[:space:]"\\]+$'
[[ $download_url =~ $blob_url_pattern ]]
if IFS= read -r _extra; then
    echo "Artifact URL input must contain exactly one line" >&2
    exit 1
fi

umask 077
for name in source-manifest.gz source-payload.gz; do
    [[ ! -e $transfer_root/$name && ! -L $transfer_root/$name ]]
done
archive=$(mktemp "$transfer_root/.source-artifact.XXXXXX.zip")
extract_root=$(mktemp -d "$transfer_root/.source-artifact.XXXXXX")
parts=()
committed=0
cleanup() {
    rm -f "$archive"
    for part in "${parts[@]}"; do
        rm -f -- "$part"
    done
    rm -rf --one-file-system -- "$extract_root"
    if [[ $committed -eq 0 ]]; then
        rm -f -- "$transfer_root/source-manifest.gz" \
            "$transfer_root/source-payload.gz"
    fi
}
trap cleanup EXIT

started=$(date +%s)
part_count=8
part_size=$(( (archive_size + part_count - 1) / part_count ))
pids=()
expected_sizes=()
for ((index=0; index<part_count; index++)); do
    first=$((index * part_size))
    (( first < archive_size )) || break
    last=$((first + part_size - 1))
    (( last < archive_size )) || last=$((archive_size - 1))
    expected_size=$((last - first + 1))
    part=$(mktemp "$transfer_root/.source-artifact.part.$index.XXXXXX")
    parts+=("$part")
    expected_sizes+=("$expected_size")
    (
        printf 'url = "%s"\n' "$download_url" \
            | curl --fail --silent --show-error --connect-timeout 30 \
                --max-time 1800 --retry 2 --retry-delay 2 \
                --retry-max-time 1800 --proto '=https' \
                --max-filesize "$expected_size" --config - \
                --range "$first-$last" --output "$part"
    ) &
    pids+=("$!")
done
download_failed=0
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        download_failed=1
    fi
done
unset download_url
[[ $download_failed -eq 0 ]]
for ((index=0; index<${#parts[@]}; index++)); do
    [[ $(stat -c %s "${parts[$index]}") == "${expected_sizes[$index]}" ]]
    cat -- "${parts[$index]}" >> "$archive"
done
[[ $(stat -c %s "$archive") == "$archive_size" ]]
for part in "${parts[@]}"; do
    rm -f -- "$part"
done
parts=()
elapsed=$(( $(date +%s) - started ))
archive_bytes=$(stat -c %s "$archive")

expected_entries=$'source-manifest.gz\nsource-payload.gz'
archive_entries=$(unzip -Z1 "$archive" | LC_ALL=C sort)
[[ $archive_entries == "$expected_entries" ]]
unzip -q "$archive" -d "$extract_root"
for name in source-manifest.gz source-payload.gz; do
    [[ -f $extract_root/$name && ! -L $extract_root/$name ]]
    gzip -t -- "$extract_root/$name"
done
for name in source-manifest.gz source-payload.gz; do
    mv -T -- "$extract_root/$name" "$transfer_root/$name"
done
committed=1
rm -f "$archive"
rmdir "$extract_root"
trap - EXIT
echo 'SOURCE_ARTIFACT_DOWNLOADED=1'
printf 'SOURCE_ARTIFACT_BYTES=%s\n' "$archive_bytes"
printf 'SOURCE_ARTIFACT_DOWNLOAD_SECONDS=%s\n' "$elapsed"
