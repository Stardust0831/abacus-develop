#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 PROJECT_ROOT RUN_ROOT SOURCE_TRANSFER_ROOT" >&2
    exit 2
fi

canonical_home=$(cd "$HOME" && pwd -P)
project_root=$(realpath -e "$1")
run_root=$(realpath -e "$2")
transfer_root=$(realpath -e "$3")
run_name=${run_root##*/}
[[ $project_root == "$canonical_home/"* ]]
[[ $run_root == "$project_root/runs/"* ]]
[[ $run_name =~ ^[0-9]+-[0-9]+$ ]]
[[ $transfer_root == "$project_root/cache/source-transfers/$run_name" ]]
[[ -d $transfer_root && ! -L $transfer_root ]]
marker=$transfer_root/.ci-source-transfer
[[ -f $marker && ! -L $marker ]]
grep -Fxq "run_root=$run_root" "$marker"

IFS= read -r download_url
blob_url_pattern='^https://[A-Za-z0-9.-]+\.blob\.core\.windows\.net/[^[:space:]"\\]+$'
[[ $download_url =~ $blob_url_pattern ]]
if IFS= read -r extra; then
    echo "Artifact URL input must contain exactly one line" >&2
    exit 1
fi

umask 077
for name in source-manifest.gz source-payload.gz; do
    [[ ! -e $transfer_root/$name && ! -L $transfer_root/$name ]]
done
archive=$(mktemp "$transfer_root/.source-artifact.XXXXXX.zip")
extract_root=$(mktemp -d "$transfer_root/.source-artifact.XXXXXX")
committed=0
cleanup() {
    rm -f "$archive"
    rm -rf --one-file-system -- "$extract_root"
    if [[ $committed -eq 0 ]]; then
        rm -f -- "$transfer_root/source-manifest.gz" \
            "$transfer_root/source-payload.gz"
    fi
}
trap cleanup EXIT

started=$(date +%s)
printf 'url = "%s"\n' "$download_url" \
    | curl --fail --silent --show-error --max-time 600 --proto '=https' \
        --max-filesize 134217728 --config - --output "$archive"
unset download_url
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
