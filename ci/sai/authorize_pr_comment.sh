#!/usr/bin/env bash

set -euo pipefail

: "${GITHUB_EVENT_NAME:?}"
: "${GITHUB_OUTPUT:?}"
: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_STEP_SUMMARY:?}"

accepted=false
check_run_id=
pr_number=
source_repository=$GITHUB_REPOSITORY

case "$GITHUB_EVENT_NAME" in
    schedule)
        : "${GITHUB_SHA:?}"
        source_sha=$GITHUB_SHA
        run_namespace=daily
        accepted=true
        ;;
    workflow_dispatch)
        : "${MANUAL_RUN_NAMESPACE:?}"
        : "${MANUAL_SOURCE_SHA:?}"
        source_sha=$MANUAL_SOURCE_SHA
        run_namespace=$MANUAL_RUN_NAMESPACE
        accepted=true
        ;;
    issue_comment)
        : "${GITHUB_EVENT_PATH:?}"
        : "${GITHUB_RUN_ID:?}"
        : "${GITHUB_SERVER_URL:?}"
        readarray -d '' -t event_fields < <(
            python3 - "$GITHUB_EVENT_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    event = json.load(handle)
values = (
    event["comment"]["body"],
    event["comment"]["user"]["login"],
    event["issue"]["number"],
    event["repository"]["default_branch"],
)
for value in values:
    sys.stdout.write(f"{value}\0")
PY
        )
        [[ ${#event_fields[@]} -eq 4 ]]
        command=${event_fields[0]}
        commenter=${event_fields[1]}
        pr_number=${event_fields[2]}
        default_branch=${event_fields[3]}
        [[ "$command" == '/abacus-ci sai-gpu' ]]
        [[ "$commenter" =~ ^[A-Za-z0-9-]{1,39}$ ]]
        [[ "$pr_number" =~ ^[1-9][0-9]*$ ]]

        permission_json=$(gh api \
            "repos/$GITHUB_REPOSITORY/collaborators/$commenter/permission" \
            2>/dev/null || true)
        readarray -d '' -t permission_fields < <(
            python3 - "$permission_json" <<'PY'
import json
import sys

try:
    response = json.loads(sys.argv[1])
except json.JSONDecodeError:
    response = {}
for value in (response.get("permission", "none"), response.get("role_name", "none")):
    sys.stdout.write(f"{value}\0")
PY
        )
        [[ ${#permission_fields[@]} -eq 2 ]]
        permission=${permission_fields[0]}
        role=${permission_fields[1]}
        if [[ "$permission" != admin && "$permission" != write && \
              "$role" != admin && "$role" != maintain && "$role" != write ]]; then
            echo "Ignoring SAI request from $commenter: repository role is $role ($permission)." >&2
            source_sha=0000000000000000000000000000000000000000
            run_namespace=unauthorized
        else
            pr_json=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$pr_number")
            readarray -d '' -t pr_fields < <(
                python3 - "$pr_json" <<'PY'
import json
import sys

pull = json.loads(sys.argv[1])
values = (
    pull["state"],
    pull["base"]["repo"]["full_name"],
    pull["base"]["ref"],
    pull["head"]["repo"]["full_name"],
    pull["head"]["sha"],
)
for value in values:
    sys.stdout.write(f"{value}\0")
PY
            )
            [[ ${#pr_fields[@]} -eq 5 ]]
            state=${pr_fields[0]}
            base_repository=${pr_fields[1]}
            base_branch=${pr_fields[2]}
            source_repository=${pr_fields[3]}
            source_sha=${pr_fields[4]}
            [[ "$state" == open ]]
            [[ "$base_repository" == "$GITHUB_REPOSITORY" ]]
            [[ "$base_branch" == "$default_branch" ]]
            [[ "$source_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
            [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]]
            run_namespace=pr-$pr_number

            details_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
            check_json=$(python3 - "$source_sha" "$details_url" "$commenter" <<'PY'
import json
import sys

source_sha, details_url, commenter = sys.argv[1:]
print(json.dumps({
    "name": "SAI GPU Case Matrix",
    "head_sha": source_sha,
    "details_url": details_url,
    "status": "queued",
    "output": {
        "title": "Awaiting protected SAI Environment approval",
        "summary": (
            f"Requested by @{commenter} with `/abacus-ci sai-gpu`. "
            f"Candidate code at `{source_sha}` will execute as "
            "`abacususer01` after approval."
        ),
    },
}))
PY
            )
            check_run_id=$(gh api --method POST \
                "repos/$GITHUB_REPOSITORY/check-runs" \
                --input - --jq '.id' <<< "$check_json")
            [[ "$check_run_id" =~ ^[1-9][0-9]*$ ]]
            accepted=true
        fi
        ;;
    *)
        echo "Unsupported event: $GITHUB_EVENT_NAME" >&2
        exit 2
        ;;
esac

[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]]
[[ "$run_namespace" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
{
    echo "accepted=$accepted"
    echo "check_run_id=$check_run_id"
    echo "pr_number=$pr_number"
    echo "run_namespace=$run_namespace"
    echo "source_repository=$source_repository"
    echo "source_sha=$source_sha"
} >> "$GITHUB_OUTPUT"

if [[ "$accepted" == true ]]; then
    {
        echo "### Accepted SAI GPU request"
        echo
        echo "- Source: \`$source_repository@$source_sha\`"
        [[ -z "$pr_number" ]] || echo "- Pull request: #$pr_number"
        echo "- Namespace: \`$run_namespace\`"
    } >> "$GITHUB_STEP_SUMMARY"
fi
