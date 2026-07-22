#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && $2 != --probe-only ) ]]; then
    echo "Usage: $0 CONFIG_FILE [--probe-only]" >&2
    exit 2
fi

config_file=$(realpath -e "$1")
[[ -f $config_file ]]
# shellcheck source=/dev/null
source "$config_file"

: "${SAI_SSH_CONFIG:?Set SAI_SSH_CONFIG in the local configuration}"
: "${SAI_SSH_TARGET:?Set SAI_SSH_TARGET in the local configuration}"
[[ $SAI_SSH_TARGET =~ ^[A-Za-z0-9._-]+$ ]]
ssh_config=$(realpath -e "$SAI_SSH_CONFIG")
[[ -f $ssh_config ]]
[[ $ssh_config =~ ^/[A-Za-z0-9._/-]+$ ]] || {
    echo "SAI_SSH_CONFIG contains unsupported characters: $ssh_config" >&2
    exit 2
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repository=$(cd "$script_dir/../.." && pwd -P)
for command_name in ssh rsync git gzip tar realpath awk; do
    command -v "$command_name" >/dev/null
done

client_root=$(mktemp -d)
control_path="$client_root/control-%C"
ssh_options=(
    -F "$ssh_config"
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
    -o ForwardAgent=no
    -o ClearAllForwardings=yes
    -o RequestTTY=no
    -o Compression=yes
    -o ControlMaster=auto
    -o ControlPath="$control_path"
    -o ControlPersist=15m
)
rsync_rsh="ssh -F $ssh_config -o BatchMode=yes -o StrictHostKeyChecking=yes -o ForwardAgent=no -o ClearAllForwardings=yes -o RequestTTY=no -o Compression=yes -o ControlMaster=auto -o ControlPath=$control_path -o ControlPersist=15m"

cleanup() {
    ssh "${ssh_options[@]}" -O exit "$SAI_SSH_TARGET" >/dev/null 2>&1 || true
    rm -rf "$client_root"
}
trap cleanup EXIT

if [[ ${2:-} != --probe-only ]] &&
    [[ -n $(git -C "$repository" status --porcelain --untracked-files=all) ]]; then
    echo "The local control checkout must be clean, including untracked files" >&2
    exit 1
fi
control_sha=$(git -C "$repository" rev-parse --verify "HEAD^{commit}")
[[ $control_sha =~ ^[0-9a-f]{40}$ ]]
snapshot_output=$(bash "$script_dir/prepare_control_snapshot.sh" \
    "$repository" "$control_sha" "$client_root/control-snapshot")
control_root=$(awk -F= '$1 == "CONTROL_ROOT" {print $2}' <<< "$snapshot_output")
[[ $control_root == "$client_root/control-snapshot/ci/sai" ]]

ssh_expanded=$(ssh -G "${ssh_options[@]}" "$SAI_SSH_TARGET")
remote_user=$(awk '$1 == "user" {print $2; exit}' <<< "$ssh_expanded")
[[ $remote_user =~ ^[A-Za-z0-9._-]+$ ]]

connected=0
for attempt in {1..4}; do
    if ssh "${ssh_options[@]}" -o ConnectionAttempts=1 -MNf \
        "$SAI_SSH_TARGET"; then
        connected=1
        break
    fi
    echo "SAI SSH master connection failed (attempt $attempt/4)" >&2
    if [[ $attempt -lt 4 ]]; then
        sleep $((attempt * 5))
    fi
done
[[ $connected -eq 1 ]]
ssh "${ssh_options[@]}" "$SAI_SSH_TARGET" bash -s -- "$remote_user" \
    < "$control_root/probe_remote_sai.sh"

if [[ ${2:-} == --probe-only ]]; then
    echo "SAI_LOCAL_PROBE_OK target=$SAI_SSH_TARGET user=$remote_user"
    exit 0
fi

: "${SAI_PROJECT_ROOT:?Set SAI_PROJECT_ROOT in the local configuration}"
SAI_RUN_NAMESPACE=${SAI_RUN_NAMESPACE:-local}
SAI_ARTIFACT_ROOT=${SAI_ARTIFACT_ROOT:-$PWD/sai-local-artifacts}
SAI_SOURCE_SHA=${SAI_SOURCE_SHA:-HEAD}

[[ $SAI_PROJECT_ROOT =~ ^(/[A-Za-z0-9._-]+)+$ ]]
case "/$SAI_PROJECT_ROOT/" in
    */./*|*/../*)
        echo "SAI_PROJECT_ROOT contains a dot path component" >&2
        exit 2
        ;;
esac
[[ $SAI_RUN_NAMESPACE =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]

source_sha=$(git -C "$repository" rev-parse --verify "$SAI_SOURCE_SHA^{commit}")
[[ $source_sha =~ ^[0-9a-f]{40}$ ]]

run_id=$(date +%s)
run_attempt=$$
run_key="$run_id-$run_attempt"
artifact_parent=$SAI_ARTIFACT_ROOT
if [[ $artifact_parent != /* ]]; then
    artifact_parent=$PWD/$artifact_parent
fi
artifact_parent=$(realpath --canonicalize-missing "$artifact_parent")
artifact_root="$artifact_parent/$run_key"
[[ ! -e $artifact_root && ! -L $artifact_root ]]
mkdir -p "$artifact_root"
artifact_root=$(cd "$artifact_root" && pwd -P)

run_remote_script() {
    local script=$1
    shift
    ssh "${ssh_options[@]}" "$SAI_SSH_TARGET" bash -s -- "$@" < "$script"
}

output=$(run_remote_script "$control_root/prepare_remote_run.sh" \
    "$SAI_PROJECT_ROOT" "$SAI_RUN_NAMESPACE" "$run_key" \
    "$source_sha" "$control_sha")
printf '%s\n' "$output"
remote_project_root=$(awk -F= '$1 == "SAI_PROJECT_ROOT" {print $2}' <<< "$output")
remote_run_root=$(awk -F= '$1 == "RUN_ROOT" {print $2}' <<< "$output")
[[ $remote_project_root == "$SAI_PROJECT_ROOT" ]]
[[ $remote_run_root == "$remote_project_root/runs/$SAI_RUN_NAMESPACE/$run_key" ]]

RSYNC_RSH=$rsync_rsh rsync -az --delete --timeout=600 --stats \
    "$control_root/" "$SAI_SSH_TARGET:$remote_run_root/control/"

output=$(run_remote_script "$control_root/source_transfer_cache.sh" \
    prepare "$remote_project_root" "$remote_run_root" "$source_sha" candidate)
printf '%s\n' "$output"
transfer_root=$(awk -F= '$1 == "SOURCE_TRANSFER_ROOT" {print $2}' <<< "$output")
base_sha=$(awk -F= '$1 == "SOURCE_CACHE_BASE_SHA" {print $2}' <<< "$output")
[[ $transfer_root == "$remote_project_root/cache/source-transfers/$run_key" ]]
[[ $base_sha == none || $base_sha =~ ^[0-9a-f]{40}$ ]]

payload="$client_root/source-payload.gz"
manifest="$client_root/source-manifest.gz"
payload_output=$(bash "$control_root/build_source_payload.sh" \
    "$repository" "$source_sha" "$base_sha" "$payload" "$manifest")
printf '%s\n' "$payload_output"
payload_mode=$(awk -F= '$1 == "SOURCE_PAYLOAD_MODE" {print $2}' \
    <<< "$payload_output")
[[ $payload_mode == full || $payload_mode == delta ]]

RSYNC_RSH=$rsync_rsh rsync -a --partial --timeout=600 --stats \
    "$payload" "$manifest" "$SAI_SSH_TARGET:$transfer_root/"
run_remote_script "$control_root/source_transfer_cache.sh" \
    receive "$remote_project_root" "$remote_run_root" "$transfer_root" \
    "$payload_mode" "$source_sha"
run_remote_script "$control_root/source_transfer_cache.sh" \
    finalize "$remote_project_root" "$remote_run_root" "$transfer_root" \
    "$source_sha"

{
    printf 'source_sha=%s\n' "$source_sha"
    printf 'control_sha=%s\n' "$control_sha"
    printf 'remote_user=%s\n' "$remote_user"
    printf 'remote_run_root=%s\n' "$remote_run_root"
} > "$artifact_root/local-run-context.txt"

set +e
run_remote_script "$control_root/run_remote_ci.sh" \
    "$remote_project_root" "$remote_run_root" "$source_sha" "$control_sha" \
    "$run_id" "$run_attempt" 2>&1 | tee "$artifact_root/sai-remote-driver.log"
validation_rc=${PIPESTATUS[0]}
set -e

set +e
run_remote_script "$control_root/collect_remote_artifacts.sh" "$remote_run_root" \
    | tar -xzf - -C "$artifact_root"
collection_status=("${PIPESTATUS[@]}")
set -e
collection_rc=0
for status in "${collection_status[@]}"; do
    if [[ $status -ne 0 ]]; then
        collection_rc=$status
        break
    fi
done
if [[ $collection_rc -eq 0 ]]; then
    run_remote_script "$control_root/mark_artifacts_uploaded.sh" "$remote_run_root"
fi

echo "SAI_LOCAL_RUN_RESULT validation_rc=$validation_rc collection_rc=$collection_rc"
echo "SAI_LOCAL_ARTIFACT_ROOT=$artifact_root"
echo "SAI_REMOTE_RUN_ROOT=$remote_run_root"
[[ $collection_rc -eq 0 ]]
exit "$validation_rc"
