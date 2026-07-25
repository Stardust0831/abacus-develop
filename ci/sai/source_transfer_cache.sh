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
CACHE_ROLE=
CACHE_POINTER_NAME=
CACHE_POINTER_ROLE=

resolve_run() {
    local canonical_home requested_project=$1 requested_run=$2 run_parent
    canonical_home=$(cd "$HOME" && pwd -P)
    PROJECT_ROOT=$(realpath -e "$requested_project")
    RUN_ROOT=$(realpath -e "$requested_run")
    [[ $PROJECT_ROOT == "$canonical_home/"* ]]
    [[ $RUN_ROOT == "$PROJECT_ROOT/runs/"* ]]
    run_parent=$(dirname "$RUN_ROOT")
    if [[ $run_parent != "$PROJECT_ROOT/runs" ]]; then
        [[ $(dirname "$run_parent") == "$PROJECT_ROOT/runs" ]]
        [[ ${run_parent##*/} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
    fi
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
    local source_sha=$1 role
    grep -Fxq "run_root=$RUN_ROOT" "$TRANSFER_MARKER"
    grep -Fxq "source_sha=$source_sha" "$TRANSFER_MARKER"
    role=$(awk -F= '$1 == "cache_role" {print $2}' "$TRANSFER_MARKER")
    [[ $role == baseline || $role == candidate ]]
    CACHE_ROLE=$role
}

lock_cache() {
    exec 8<"$CACHE_ROOT"
    flock 8
}

read_cache_pointer() {
    local pointer=$1 name=''
    CACHE_POINTER_NAME=
    CACHE_POINTER_ROLE=
    [[ -f $pointer && ! -L $pointer ]] || return 1
    IFS= read -r name < "$pointer" || true
    [[ $name =~ ^[0-9a-f]{40}\.[0-9]+-[0-9]+$ ]] || return 1
    if printf '%s\n' "$name" | cmp -s - "$pointer"; then
        CACHE_POINTER_ROLE=baseline
    elif printf '%s\nrole=baseline\n' "$name" | cmp -s - "$pointer"; then
        CACHE_POINTER_ROLE=baseline
    elif printf '%s\nrole=candidate\n' "$name" | cmp -s - "$pointer"; then
        CACHE_POINTER_ROLE=candidate
    else
        return 1
    fi
    CACHE_POINTER_NAME=$name
}

verify_tree() {
    local tree_root=$1 manifest=$2 record metadata path mode type object
    local parent relative actual permission hash_output offset batch_count index
    declare -A expected_mode=()
    declare -A expected_object=()
    declare -A expected_dir=()
    declare -A actual_permission=()
    local -a regular_paths=()
    local -a regular_files=()
    local -a batch_hashes=()

    [[ -d $tree_root && ! -L $tree_root ]] || return 1
    [[ -f $manifest && ! -L $manifest ]] || return 1
    gzip -t -- "$manifest" || return 1

    while IFS= read -r -d '' record; do
        [[ $record == *$'\t'* ]] || return 1
        metadata=${record%%$'\t'*}
        path=${record#*$'\t'}
        [[ $metadata =~ ^([0-9]{6})\ ([a-z]+)\ ([0-9a-f]{40})$ ]] || return 1
        mode=${BASH_REMATCH[1]}
        type=${BASH_REMATCH[2]}
        object=${BASH_REMATCH[3]}
        [[ $type == blob ]] || return 1
        [[ $mode == 100644 || $mode == 100755 || $mode == 120000 ]] || return 1
        [[ -n $path && $path != /* ]] || return 1
        case "/$path/" in
            */./*|*/../*|*//*) return 1 ;;
        esac
        [[ -z ${expected_mode["$path"]+present} ]] || return 1
        [[ -z ${expected_dir["$path"]+present} ]] || return 1
        expected_mode["$path"]=$mode
        expected_object["$path"]=$object

        parent=$path
        while [[ $parent == */* ]]; do
            parent=${parent%/*}
            [[ -z ${expected_mode["$parent"]+present} ]] || return 1
            expected_dir["$parent"]=1
        done
        record=
    done < <(gzip -cd -- "$manifest")
    [[ -z $record ]] || return 1

    while IFS= read -r -d '' permission && IFS= read -r -d '' actual; do
        relative=${actual#"$tree_root"/}
        if [[ -d $actual && ! -L $actual ]]; then
            [[ -n ${expected_dir["$relative"]+present} ]] || return 1
        elif [[ -f $actual && ! -L $actual ]] || [[ -L $actual ]]; then
            [[ -n ${expected_mode["$relative"]+present} ]] || return 1
            actual_permission["$relative"]=$permission
        else
            echo "Unsupported source-cache filesystem entry: $relative" >&2
            return 1
        fi
    done < <(find "$tree_root" -mindepth 1 -printf '%m\0%p\0')

    for path in "${!expected_mode[@]}"; do
        actual="$tree_root/$path"
        mode=${expected_mode["$path"]}
        if [[ $mode == 120000 ]]; then
            [[ -L $actual ]] || return 1
            object=$(readlink -n -- "$actual" | git hash-object --stdin) || return 1
            [[ $object == "${expected_object["$path"]}" ]] || return 1
        else
            [[ -f $actual && ! -L $actual ]] || return 1
            permission=${actual_permission["$path"]}
            if [[ $mode == 100755 ]]; then
                (( (8#$permission & 8#111) != 0 )) || return 1
            else
                (( (8#$permission & 8#111) == 0 )) || return 1
            fi
            regular_paths+=("$path")
            regular_files+=("$actual")
        fi
    done

    for ((offset = 0; offset < ${#regular_files[@]}; offset += 256)); do
        batch_count=$((${#regular_files[@]} - offset))
        (( batch_count > 256 )) && batch_count=256
        hash_output=$(git hash-object --no-filters -- \
            "${regular_files[@]:offset:batch_count}") || return 1
        mapfile -t batch_hashes <<< "$hash_output"
        [[ ${#batch_hashes[@]} -eq $batch_count ]] || return 1
        for ((index = 0; index < batch_count; index++)); do
            path=${regular_paths[offset + index]}
            [[ ${batch_hashes[index]} == "${expected_object["$path"]}" ]] || return 1
        done
    done
}

quarantine_latest() {
    local latest=$1 reason=$2 quarantine
    quarantine="$CACHE_ROOT/.source-latest.invalid.$RUN_NAME"
    [[ ! -e $quarantine && ! -L $quarantine ]]
    mv -T -- "$latest" "$quarantine"
    printf 'SOURCE_CACHE_INVALID reason=%s quarantined=%s\n' \
        "$reason" "$quarantine" >&2
}

cleanup_orphan_snapshots() {
    local current_name=$1 candidate name manifest
    while IFS= read -r -d '' candidate; do
        name=${candidate##*/}
        [[ $name =~ ^[0-9a-f]{40}\.[0-9]+-[0-9]+$ ]] || continue
        [[ $name == "$current_name" ]] && continue
        candidate=$(realpath -e "$candidate")
        [[ $candidate == "$SNAPSHOT_ROOT/$name" ]]
        rm -rf --one-file-system -- "$candidate"
        manifest="$SNAPSHOT_ROOT/$name.manifest.gz"
        if [[ -f $manifest && ! -L $manifest ]]; then
            rm -f -- "$manifest"
        fi
    done < <(find "$SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -type d -print0)

    while IFS= read -r -d '' manifest; do
        name=${manifest##*/}
        [[ $name =~ ^([0-9a-f]{40}\.[0-9]+-[0-9]+)\.manifest\.gz$ ]] || continue
        [[ ${BASH_REMATCH[1]} == "$current_name" ]] && continue
        [[ -f $manifest && ! -L $manifest ]]
        rm -f -- "$manifest"
    done < <(find "$SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 \
        -type f -name '*.manifest.gz' -print0)
}

prepare_transfer() {
    local requested_project=$1 requested_run=$2 source_sha=$3
    local cache_role=$4
    local base_sha=none latest latest_name='' base_snapshot manifest cache_missing
    local latest_valid=0 cache_invalid=0
    [[ $source_sha =~ ^[0-9a-f]{40}$ ]]
    [[ $cache_role == baseline || $cache_role == candidate ]]
    resolve_run "$requested_project" "$requested_run"
    [[ -z $(find "$RUN_SOURCE" -mindepth 1 -maxdepth 1 -print -quit) ]]

    cache_missing=$(realpath --canonicalize-missing "$PROJECT_ROOT/cache")
    [[ $cache_missing == "$PROJECT_ROOT/cache" ]]
    mkdir -p "$cache_missing/source-snapshots" "$cache_missing/source-transfers"
    resolve_cache
    lock_cache

    TRANSFER_ROOT="$TRANSFER_PARENT/$RUN_NAME"
    [[ ! -e $TRANSFER_ROOT && ! -L $TRANSFER_ROOT ]] || {
        echo "Refusing to reuse source transfer: $TRANSFER_ROOT" >&2
        exit 1
    }
    mkdir -p "$TRANSFER_ROOT/source"
    {
        printf 'run_root=%s\n' "$RUN_ROOT"
        printf 'source_sha=%s\n' "$source_sha"
        printf 'cache_role=%s\n' "$cache_role"
    } > "$TRANSFER_ROOT/.ci-source-transfer"

    latest="$CACHE_ROOT/source-latest"
    if [[ -e $latest || -L $latest ]]; then
        if [[ -f $latest && ! -L $latest ]]; then
            if read_cache_pointer "$latest"; then
                latest_name=$CACHE_POINTER_NAME
                [[ $latest_name =~ ^([0-9a-f]{40})\.([0-9]+-[0-9]+)$ ]]
                base_sha=${BASH_REMATCH[1]}
                base_snapshot="$SNAPSHOT_ROOT/$latest_name"
                manifest="$SNAPSHOT_ROOT/$latest_name.manifest.gz"
                if [[ -d $base_snapshot && ! -L $base_snapshot &&
                      -f $manifest && ! -L $manifest ]] &&
                    verify_tree "$base_snapshot" "$manifest"; then
                    base_snapshot=$(realpath -e "$base_snapshot")
                    [[ $base_snapshot == "$SNAPSHOT_ROOT/$latest_name" ]]
                    latest_valid=1
                else
                    base_sha=none
                    cache_invalid=1
                    if [[ $cache_role == baseline ]]; then
                        quarantine_latest "$latest" content_or_manifest_mismatch
                    else
                        echo "SOURCE_CACHE_INVALID reason=content_or_manifest_mismatch role=candidate" >&2
                    fi
                fi
            else
                cache_invalid=1
                if [[ $cache_role == baseline ]]; then
                    quarantine_latest "$latest" malformed_pointer
                else
                    echo "SOURCE_CACHE_INVALID reason=malformed_pointer role=candidate" >&2
                fi
            fi
        else
            cache_invalid=1
            if [[ $cache_role == baseline ]]; then
                quarantine_latest "$latest" unsafe_pointer_type
            else
                echo "SOURCE_CACHE_INVALID reason=unsafe_pointer_type role=candidate" >&2
            fi
        fi
    fi

    if [[ $latest_valid -eq 1 ]]; then
        if [[ $cache_role == baseline ]]; then
            cleanup_orphan_snapshots "$latest_name"
        fi
        cp -a "$base_snapshot/." "$TRANSFER_ROOT/source/"
    elif [[ $cache_invalid -eq 0 && $cache_role == baseline ]]; then
        cleanup_orphan_snapshots ""
    fi
    printf 'SOURCE_TRANSFER_ROOT=%s\n' "$TRANSFER_ROOT"
    printf 'SOURCE_CACHE_BASE_SHA=%s\n' "$base_sha"
    printf 'SOURCE_CACHE_ROLE=%s\n' "$cache_role"
}

receive_payload() {
    local requested_project=$1 requested_run=$2 requested_transfer=$3
    local mode=$4 source_sha=$5 payload manifest patch_file
    [[ $source_sha =~ ^[0-9a-f]{40}$ ]]
    [[ $mode == full || $mode == delta ]]
    resolve_run "$requested_project" "$requested_run"
    resolve_transfer "$requested_transfer"
    verify_marker "$source_sha"
    payload="$TRANSFER_ROOT/source-payload.gz"
    manifest="$TRANSFER_ROOT/source-manifest.gz"
    [[ -f $payload && ! -L $payload ]]
    [[ -f $manifest && ! -L $manifest ]]
    gzip -t -- "$manifest"

    if [[ $mode == full ]]; then
        find "$TRANSFER_SOURCE" -mindepth 1 -maxdepth 1 \
            -exec rm -rf --one-file-system -- {} +
    fi
    patch_file="$TRANSFER_ROOT/source.patch"
    gzip -cd "$payload" > "$patch_file"
    if [[ -s $patch_file ]]; then
        (cd "$TRANSFER_SOURCE" && git apply --check --binary \
            --whitespace=nowarn "$patch_file")
        (cd "$TRANSFER_SOURCE" && git apply --binary \
            --whitespace=nowarn "$patch_file")
    fi
    rm -f "$patch_file"
    rm -f "$payload"
    printf 'SOURCE_PAYLOAD_APPLIED mode=%s sha=%s\n' "$mode" "$source_sha"
}

finalize_transfer() {
    local requested_project=$1 requested_run=$2 requested_transfer=$3
    local source_sha=$4 snapshot_name snapshot manifest snapshot_manifest
    local latest latest_tmp promotion=baseline
    [[ $source_sha =~ ^[0-9a-f]{40}$ ]]
    resolve_run "$requested_project" "$requested_run"
    resolve_transfer "$requested_transfer"
    verify_marker "$source_sha"
    lock_cache
    [[ ! -e $TRANSFER_ROOT/source-payload.gz ]]
    [[ -z $(find "$RUN_SOURCE" -mindepth 1 -maxdepth 1 -print -quit) ]]
    manifest="$TRANSFER_ROOT/source-manifest.gz"
    verify_tree "$TRANSFER_SOURCE" "$manifest"
    cp -a "$TRANSFER_SOURCE/." "$RUN_SOURCE/"

    if [[ $CACHE_ROLE == candidate ]]; then
        latest="$CACHE_ROOT/source-latest"
        if [[ -e $latest || -L $latest ]]; then
            if ! read_cache_pointer "$latest" ||
                [[ $CACHE_POINTER_ROLE != candidate ]]; then
                rm -rf --one-file-system -- "$TRANSFER_SOURCE"
                rm -f "$manifest" "$TRANSFER_MARKER"
                rmdir "$TRANSFER_ROOT"
                printf 'SOURCE_CACHE_PROMOTION=skipped role=candidate source_sha=%s\n' \
                    "$source_sha"
                return
            fi
            promotion=refresh
        else
            promotion=bootstrap
        fi
    fi

    snapshot_name="$source_sha.$RUN_NAME"
    snapshot="$SNAPSHOT_ROOT/$snapshot_name"
    snapshot_manifest="$SNAPSHOT_ROOT/$snapshot_name.manifest.gz"
    [[ ! -e $snapshot && ! -L $snapshot ]]
    [[ ! -e $snapshot_manifest && ! -L $snapshot_manifest ]]
    mv -T "$TRANSFER_SOURCE" "$snapshot"
    mv -T "$manifest" "$snapshot_manifest"
    latest_tmp=$(mktemp "$CACHE_ROOT/.source-latest.XXXXXX")
    printf '%s\nrole=%s\n' "$snapshot_name" "$CACHE_ROLE" > "$latest_tmp"
    mv -T "$latest_tmp" "$CACHE_ROOT/source-latest"
    rm -f "$TRANSFER_MARKER"
    rmdir "$TRANSFER_ROOT"

    cleanup_orphan_snapshots "$snapshot_name"
    if [[ $promotion == bootstrap || $promotion == refresh ]]; then
        printf 'SOURCE_CACHE_PROMOTION=%s role=candidate source_sha=%s\n' \
            "$promotion" "$source_sha"
    else
        printf 'SOURCE_CACHE_PROMOTED_SHA=%s\n' "$source_sha"
    fi
    printf 'SOURCE_CACHE_SNAPSHOT=%s\n' "$snapshot"
}

command=${1:-}
case $command in
    prepare)
        [[ $# -eq 5 ]] || { echo "Usage: $0 prepare PROJECT_ROOT RUN_ROOT SOURCE_SHA baseline|candidate" >&2; exit 2; }
        prepare_transfer "$2" "$3" "$4" "$5"
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
