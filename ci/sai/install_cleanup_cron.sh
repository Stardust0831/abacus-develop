#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 PROJECT_ROOT STAGED_CLEANUP" >&2
    exit 2
fi

requested_root=$1
requested_cleanup=$2
canonical_home=$(cd "$HOME" && pwd -P)
project_root=$(realpath --canonicalize-missing "$requested_root")
[[ $project_root == "$canonical_home/"* ]]
mkdir -p "$project_root"
project_root=$(cd "$project_root" && pwd -P)
[[ $project_root == "$canonical_home/"* ]]

staged_cleanup=$(realpath -e "$requested_cleanup")
[[ -f $staged_cleanup && ! -L $requested_cleanup ]]
staging_root=$(dirname "$staged_cleanup")
staging_name=${staging_root##*/}
[[ $staged_cleanup == "$staging_root/cleanup_sai_runs.sh" ]]
[[ $(dirname "$staging_root") == "$project_root/diagnostics" ]]
[[ $staging_name =~ ^cleanup-[0-9]+-[0-9]+$ ]]
[[ -f $staging_root/.ci-diagnostic ]]

canonical_user_dir() {
    local requested=$1 canonical
    canonical=$(realpath --canonicalize-missing "$requested")
    if [[ $canonical != "$canonical_home/"* ]]; then
        echo "User state directory escapes HOME: $canonical" >&2
        return 1
    fi
    mkdir -p "$canonical"
    canonical=$(cd "$canonical" && pwd -P)
    if [[ $canonical != "$canonical_home/"* ]]; then
        echo "Created user state directory escapes HOME: $canonical" >&2
        return 1
    fi
    printf '%s\n' "$canonical"
}

config_root=$(canonical_user_dir "$HOME/.config/abacus-sai-ci")
state_root=$(canonical_user_dir "$HOME/.local/state/abacus-sai-ci")
libexec_root=$(canonical_user_dir "$HOME/.local/libexec/abacus-sai-ci")
: "$state_root"

cleanup="$libexec_root/cleanup_sai_runs.sh"
registry="$config_root/project-roots"
exec 9<"$config_root"
flock 9
if [[ -L $registry || ( -e $registry && ! -f $registry ) ]]; then
    echo "Refusing unsafe project-root registry: $registry" >&2
    exit 1
fi
if [[ -L $cleanup || ( -e $cleanup && ! -f $cleanup ) ]]; then
    echo "Refusing unsafe cleanup installation target: $cleanup" >&2
    exit 1
fi

begin='# BEGIN ABACUS_SAI_CI_CLEANUP'
end='# END ABACUS_SAI_CI_CLEANUP'
current=$(mktemp "$state_root/cron-current.XXXXXX")
updated=$(mktemp "$state_root/cron-updated.XXXXXX")
crontab_error=$(mktemp "$state_root/cron-error.XXXXXX")
cleanup_tmp=
trap 'rm -f "$current" "$updated" "$crontab_error" ${cleanup_tmp:-}' EXIT
if ! LC_ALL=C crontab -l > "$current" 2> "$crontab_error"; then
    if grep -Eq '^no crontab for ' "$crontab_error"; then
        : > "$current"
    else
        echo "Unable to read the existing user crontab; refusing replacement" >&2
        cat "$crontab_error" >&2
        exit 1
    fi
fi
begin_count=$(grep -Fxc "$begin" "$current" || true)
end_count=$(grep -Fxc "$end" "$current" || true)
if [[ $begin_count -ne $end_count || $begin_count -gt 1 ]]; then
    echo "Refusing to replace an invalid ABACUS SAI cleanup cron block" >&2
    exit 1
fi
if [[ $begin_count -eq 1 ]]; then
    begin_line=$(grep -Fn "$begin" "$current" | cut -d: -f1)
    end_line=$(grep -Fn "$end" "$current" | cut -d: -f1)
    if [[ $begin_line -ge $end_line ]]; then
        echo "Refusing to replace an out-of-order ABACUS SAI cleanup cron block" >&2
        exit 1
    fi
fi
awk -v begin="$begin" -v end="$end" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
' "$current" > "$updated"
{
    echo "$begin"
    echo '15 7 * * * $HOME/.local/libexec/abacus-sai-ci/cleanup_sai_runs.sh --cron'
    echo "$end"
} >> "$updated"

cleanup_tmp=$(mktemp "$libexec_root/.cleanup_sai_runs.XXXXXX")
cp "$staged_cleanup" "$cleanup_tmp"
chmod 700 "$cleanup_tmp"
mv -T "$cleanup_tmp" "$cleanup"
cleanup_tmp=
touch "$registry"
if ! grep -Fxq "$project_root" "$registry"; then
    printf '%s\n' "$project_root" >> "$registry"
fi
crontab "$updated"
rm -f "$staged_cleanup" "$staging_root/.ci-diagnostic"
rmdir "$staging_root"

echo "SAI_CLEANUP_INSTALLED project_root=$project_root schedule=07:15"
