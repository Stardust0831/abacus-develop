#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 OUTPUT_DIRECTORY KNOWN_HOSTS_FILE" >&2
    exit 2
fi

output_dir=$1
known_hosts_source=$2
: "${SAI_SSH_PRIVATE_KEY:?}"
: "${SAI_SSH_HOST:?}"
: "${SAI_SSH_PORT:?}"
: "${SAI_SSH_USER:?}"

[[ $SAI_SSH_HOST =~ ^[A-Za-z0-9.-]+$ ]]
[[ $SAI_SSH_PORT =~ ^[0-9]+$ ]]
[[ $SAI_SSH_USER =~ ^[A-Za-z0-9._-]+$ ]]
[[ -f $known_hosts_source ]]
grep -Fq "[$SAI_SSH_HOST]:$SAI_SSH_PORT " "$known_hosts_source"

umask 077
mkdir -p "$output_dir"
key_file="$output_dir/id_ed25519"
known_hosts="$output_dir/known_hosts"
config="$output_dir/config"
printf '%s\n' "$SAI_SSH_PRIVATE_KEY" > "$key_file"
ssh-keygen -y -f "$key_file" >/dev/null
cp "$known_hosts_source" "$known_hosts"

cat > "$config" <<EOF
Host sai-ci
    HostName $SAI_SSH_HOST
    Port $SAI_SSH_PORT
    User $SAI_SSH_USER
    IdentityFile $key_file
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking yes
    UserKnownHostsFile $known_hosts
    ForwardAgent no
    ClearAllForwardings yes
    RequestTTY no
    ServerAliveInterval 30
    ServerAliveCountMax 4
EOF
chmod 600 "$key_file" "$known_hosts" "$config"
echo "SAI_SSH_CLIENT_READY host=$SAI_SSH_HOST port=$SAI_SSH_PORT user=$SAI_SSH_USER"
