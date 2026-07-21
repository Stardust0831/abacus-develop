#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT=
RUN_ROOT=
RUN_NAME=
RUN_SOURCE=
CACHE_ROOT=
SNAPSHOT_ROOT=
TRANSFER_PARENT=
TRANSFER_ROOT=
TRANSFER_SOURCE=
TRANSFER_MARKER=

resolve_run() {
    local canonical_home requested_project=$1 requested_run=$2
    canonical_home=$(cd "$HOME" && pwd -P)
    PROJECT_ROOT=$(realpath -e "$requested_project")
    RUN_ROOT=$(realpath -e "$requested_run")
    [[ $PROJECT_ROOT == "$canonical_home/"* ]]
    [[ $RUN_ROOT == "$PROJECT_ROOT/runs/"* ]]
    RUN_NAME=${RUN_ROOT##*/}
    [[ $RUN_NAME =~ ^[0-9]+-[0-9]+$ ]]
    [[ -f $RUN_ROOT/.ci-created && ! -L $RUN_ROOT/.ci-created ]]
    RUN_SOURCE=$(realpath -e "$RUN_ROOT/source")
    [[ $RUN_SOURCE == "$RUN_ROOT/source" ]]
}

resolve_cache() {
    CACHE_ROOT=$(realpath -e "$PROJECT_ROOT/cache")
    SNAPSHOT_ROOT=$(realpath -e "$CACHE_ROOT/source-snapshots")
    TRANSFER_PARENT=$(realpath -e "$CACHE_ROOT/source-transfers")
    [[ $CACHE_ROOT == "$PROJECT_ROOT/cache" ]]
    [[ $SNAPSHOT_ROOT == "$CACHE_ROOT/source-snapshots" ]]
    [[ $TRANSFER_PARENT == "$CACHE_ROOT/source-transfers" ]]
}

resolve_transfer() {
    local requested_transfer=$1
    resolve_cache
    TRANSFER_ROOT=$(realpath -e "$requested_transfer")
    [[ $TRANSFER_ROOT == "$TRANSFER_PARENT/$RUN_NAME" ]]
    [[ -d $TRANSFER_ROOT && ! -L $TRANSFER_ROOT ]]
    TRANSFER_SOURCE=$(realpath -e "$TRANSFER_ROOT/source")
    [[ $TRANSFER_SOURCE == "$TRANSFER_ROOT/source" ]]
    [[ -d $TRANSFER_SOURCE && ! -L $TRANSFER_SOURCE ]]
    TRANSFER_MARKER="$TRANSFER_ROOT/.ci-source-transfer"
    [[ -f $TRANSFER_MARKER && ! -L $TRANSFER_MARKER ]]
}

verify_marker() {
    local source_sha=$1
    grep -Fxq "run_root=$RUN_ROOT" "$TRANSFER_MARKER"
    grep -Fxq "source_sha=$source_sha" "$TRANSFER_MARKER"
}

prepare_transfer() {
    local requested_project=$1 requested_run=$2 source_sha=$3
    local base_sha=none latest latest_name base_snapshot cache_missing
    [[ $source_sha =~ ^[0-9a-f]{40}$ ]]
    resolve_run "$requested_project" "$requested_run"
    [[ -z $(find "$RUN_SOURCE" -mindepth 1 -maxdepth 1 -print -quit) ]]

    cache_missing=$(realpath --canonicalize-missing "$PROJECT_ROOT/cache")
    [[ $cache_missing == "$PROJECT_ROOT/cache" ]]
    mkdir -p "$cache_missing/source-snapshots" "$cache_missing/source-transfers"
    resolve_cache

    TRANSFER_ROOT="$TRANSFER_PARENT/$RUN_NAME"
    [[ ! -e $TRANSFER_ROOT && ! -L $TRANSFER_ROOT ]] || {
        echo "Refusing to reuse source transfer: $TRANSFER_ROOT" >&2
        exit 1
    }
    mkdir -p "$TRANSFER_ROOT/source"
    {
        printf 'run_root=%s\n' "$RUN_ROOT"
        printf 'source_sha=%s\n' "$source_sha"
    } > "$TRANSFER_ROOT/.ci-source-transfer"

    latest="$CACHE_ROOT/source-latest"
    if [[ -e $latest || -L $latest ]]; then
        [[ -f $latest && ! -L $latest ]]
        latest_name=$(<"$latest")
        [[ $latest_name =~ ^([0-9a-f]{40})\.([0-9]+-[0-9]+)$ ]]
        base_sha=${BASH_REMATCH[1]}
        base_snapshot=$(realpath -e "$SNAPSHOT_ROOT/$latest_name")
        [[ $base_snapshot == "$SNAPSHOT_ROOT/$latest_name" ]]
        [[ -d $base_snapshot && ! -L $base_snapshot ]]
        cp -a "$base_snapshot/." "$TRANSFER_ROOT/source/"
    fi
    printf 'SOURCE_TRANSFER_ROOT=%s\n' "$TRANSFER_ROOT"
    printf 'SOURCE_CACHE_BASE_SHA=%s\n' "$base_sha"
}

receive_payload() {
    local requested_project=$1 requested_run=$2 requested_transfer=$3
    local mode=$4 source_sha=$5 payload patch_file
    [[ $source_sha =~ ^[0-9a-f]{40}$ ]]
    [[ $mode == full || $mode == delta ]]
    resolve_run "$requested_project" "$requested_run"
    resolve_transfer "$requested_transfer"
    verify_marker "$source_sha"
    payload="$TRANSFER_ROOT/source-payload.gz"
    [[ -f $payload && ! -L $payload ]]

    case $mode in
        full)
            find "$TRANSFER_SOURCE" -mindepth 1 -maxdepth 1 \
                -exec rm -rf --one-file-system -- {} +
            tar -xzf "$payload" -C "$TRANSFER_SOURCE" --no-same-owner
            ;;
        delta)
            patch_file="$TRANSFER_ROOT/source.patch"
            gzip -cd "$payload" > "$patch_file"
            if [[ -s $patch_file ]]; then
                (cd "$TRANSFER_SOURCE" && git apply --check --binary "$patch_file")
                (cd "$TRANSFER_SOURCE" && git apply --binary "$patch_file")
            fi
            rm -f "$patch_file"
            ;;
    esac
    rm -f "$payload"
    printf 'SOURCE_PAYLOAD_APPLIED mode=%s sha=%s\n' "$mode" "$source_sha"
}

finalize_transfer() {
    local requested_project=$1 requested_run=$2 requested_transfer=$3
    local source_sha=$4 snapshot_name snapshot latest_tmp old_snapshot old_name
    [[ $source_sha =~ ^[0-9a-f]{40}$ ]]
    resolve_run "$requested_project" "$requested_run"
    resolve_transfer "$requested_transfer"
    verify_marker "$source_sha"
    [[ ! -e $TRANSFER_ROOT/source-payload.gz ]]
    [[ -z $(find "$RUN_SOURCE" -mindepth 1 -maxdepth 1 -print -quit) ]]
    cp -a "$TRANSFER_SOURCE/." "$RUN_SOURCE/"

    snapshot_name="$source_sha.$RUN_NAME"
    snapshot="$SNAPSHOT_ROOT/$snapshot_name"
    [[ ! -e $snapshot && ! -L $snapshot ]]
    mv -T "$TRANSFER_SOURCE" "$snapshot"
    latest_tmp=$(mktemp "$CACHE_ROOT/.source-latest.XXXXXX")
    printf '%s\n' "$snapshot_name" > "$latest_tmp"
    mv -T "$latest_tmp" "$CACHE_ROOT/source-latest"
    rm -f "$TRANSFER_MARKER"
    rmdir "$TRANSFER_ROOT"

    while IFS= read -r -d '' old_snapshot; do
        old_name=${old_snapshot##*/}
        [[ $old_name =~ ^[0-9a-f]{40}\.[0-9]+-[0-9]+$ ]] || continue
        [[ $old_name == "$snapshot_name" ]] && continue
        old_snapshot=$(realpath -e "$old_snapshot")
        [[ $old_snapshot == "$SNAPSHOT_ROOT/$old_name" ]]
        rm -rf --one-file-system -- "$old_snapshot"
    done < <(find "$SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -type d -print0)
    printf 'SOURCE_CACHE_PROMOTED_SHA=%s\n' "$source_sha"
    printf 'SOURCE_CACHE_SNAPSHOT=%s\n' "$snapshot"
}

command=${1:-}
case $command in
    prepare)
        [[ $# -eq 4 ]] || { echo "Usage: $0 prepare PROJECT_ROOT RUN_ROOT SOURCE_SHA" >&2; exit 2; }
        prepare_transfer "$2" "$3" "$4"
        ;;
    receive)
        [[ $# -eq 6 ]] || { echo "Usage: $0 receive PROJECT_ROOT RUN_ROOT TRANSFER_ROOT MODE SOURCE_SHA" >&2; exit 2; }
        receive_payload "$2" "$3" "$4" "$5" "$6"
        ;;
    finalize)
        [[ $# -eq 5 ]] || { echo "Usage: $0 finalize PROJECT_ROOT RUN_ROOT TRANSFER_ROOT SOURCE_SHA" >&2; exit 2; }
        finalize_transfer "$2" "$3" "$4" "$5"
        ;;
    *)
        echo "Usage: $0 {prepare|receive|finalize} ..." >&2
        exit 2
        ;;
esac
