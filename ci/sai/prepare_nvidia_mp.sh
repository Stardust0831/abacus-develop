#!/usr/bin/env bash

set -euo pipefail

: "${SAI_PROJECT_ROOT:?SAI_PROJECT_ROOT must be set}"

vendor_root=${SAI_NVIDIA_MP_ROOT:-$SAI_PROJECT_ROOT/vendor/nvidia-mp-0.9-archive}
download_root=$SAI_PROJECT_ROOT/vendor/downloads

cusolver_archive=libcusolvermp-linux-x86_64-0.9.0.6427_cuda12-archive
cublas_archive=libcublasmp-linux-x86_64-0.9.1.3056_cuda12-archive
cusolver_tar=${cusolver_archive}.tar.xz
cublas_tar=${cublas_archive}.tar.xz
cusolver_sha=3b071ce69c6a6a6bb7add8784e6a3fc54e9a64a8f2c1c7da40b03bcde39eb57c
cublas_sha=35fea4df2bb08a496981f34c0d486f0753d3766a31d60dbe6daa6f16673cd1cc

[[ "$SAI_PROJECT_ROOT" == /* ]]
[[ "$vendor_root" == "$SAI_PROJECT_ROOT/"* ]]
mkdir -p "$vendor_root" "$download_root"
exec 9>"$download_root/.nvidia-mp-download.lock"
flock 9
cleanup() {
    rm -f "$download_root"/*.tmp."$$"
    rm -rf "$vendor_root"/*.tmp."$$"
}
trap cleanup EXIT

fetch_archive() {
    local product=$1
    local package=$2
    local archive=$3
    local expected_sha=$4
    local tarball=$5
    local destination=$6

    local temporary_tarball="${tarball}.tmp.$$"
    local temporary_destination="${destination}.tmp.$$"

    [[ "$destination" == "$vendor_root/"* ]]

    if [[ -f "$tarball" ]] && ! printf '%s  %s\n' "$expected_sha" "$tarball" | sha256sum --check --status; then
        rm -f "$tarball"
    fi
    if [[ ! -f "$tarball" ]]; then
        rm -f "$temporary_tarball"
        curl --fail --location --retry 3 --connect-timeout 20 \
            --max-time 1200 \
            --output "$temporary_tarball" \
            "https://developer.download.nvidia.com/compute/${product}/redist/${package}/linux-x86_64/${archive}.tar.xz"
        printf '%s  %s\n' "$expected_sha" "$temporary_tarball" | sha256sum --check -
        mv "$temporary_tarball" "$tarball"
    fi
    printf '%s  %s\n' "$expected_sha" "$tarball" | sha256sum --check -
    rm -rf "$temporary_destination"
    mkdir -p "$temporary_destination"
    tar -xJf "$tarball" -C "$temporary_destination" --strip-components=1
    printf '%s\n' "$expected_sha" > "$temporary_destination/.archive-sha256"
    [[ ! -e "$destination" ]]
    mv "$temporary_destination" "$destination"
}

fetch_archive cusolvermp libcusolvermp "$cusolver_archive" "$cusolver_sha" \
    "$download_root/$cusolver_tar" "$vendor_root/$cusolver_archive"
fetch_archive cublasmp libcublasmp "$cublas_archive" "$cublas_sha" \
    "$download_root/$cublas_tar" "$vendor_root/$cublas_archive"

for path in \
    "$vendor_root/$cusolver_archive/include/cusolverMp.h" \
    "$vendor_root/$cusolver_archive/lib/libcusolverMp.so.0" \
    "$vendor_root/$cublas_archive/include/cublasmp.h" \
    "$vendor_root/$cublas_archive/lib/libcublasmp.so.0"; do
    [[ -e "$path" ]] || {
        echo "NVIDIA archive is incomplete: $path" >&2
        exit 1
    }
done
trap - EXIT

if [[ -n ${GITHUB_ENV:-} ]]; then
    {
        echo "SAI_CUSOLVERMP_ROOT=$vendor_root/$cusolver_archive"
        echo "SAI_CUBLASMP_ROOT=$vendor_root/$cublas_archive"
    } >> "$GITHUB_ENV"
fi

echo "NVIDIA_MP_ARCHIVES_READY root=$vendor_root"
