"""GitHub event admission for protected SAI execution."""

import argparse
import json
import os
import re
import shutil
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional


_SHA = re.compile(r"[0-9a-f]{40}\Z")
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
_LOGIN = re.compile(r"[A-Za-z0-9-]{1,39}\Z")
_REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
_ROLES = {"triage", "write", "maintain", "admin"}
_HOST = re.compile(r"[A-Za-z0-9.-]+\Z")
_USER = re.compile(r"[A-Za-z0-9._-]+\Z")


def _api(path: str, *, method: str = "GET", body: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        raise ValueError("GH_TOKEN is required")
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        "https://api.github.com/" + path.lstrip("/"), data=data, method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + token,
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "abacus-sai-ci",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            value = json.load(response)
    except (OSError, urllib.error.HTTPError, json.JSONDecodeError) as error:
        raise RuntimeError("GitHub API request failed: {}".format(path)) from error
    if not isinstance(value, dict):
        raise RuntimeError("GitHub API returned a non-object")
    return value


def configure_ssh(output_dir: Path, known_hosts_source: Path) -> Path:
    host = os.environ.get("SAI_SSH_HOST", "")
    port = os.environ.get("SAI_SSH_PORT", "")
    user = os.environ.get("SAI_SSH_USER", "")
    private_key = os.environ.get("SAI_SSH_PRIVATE_KEY", "")
    if not _HOST.fullmatch(host) or not port.isdigit() or not 1 <= int(port) <= 65535:
        raise ValueError("invalid SAI SSH host or port")
    if not _USER.fullmatch(user) or not private_key:
        raise ValueError("invalid SAI SSH user or empty private key")
    source = known_hosts_source.resolve(strict=True)
    if not source.is_file() or source.is_symlink():
        raise ValueError("known_hosts must be a regular file")
    if "[{}]:{} ".format(host, port) not in source.read_text(encoding="utf-8"):
        raise ValueError("known_hosts has no pinned SAI endpoint")

    root = output_dir.resolve(strict=False)
    root.mkdir(parents=True, exist_ok=False)
    os.chmod(str(root), 0o700)
    key_file = root / "id_ed25519"
    known_hosts = root / "known_hosts"
    config = root / "config"
    key_file.write_text(private_key.rstrip("\n") + "\n", encoding="utf-8")
    os.chmod(str(key_file), 0o600)
    checked = subprocess.run(
        ["ssh-keygen", "-y", "-f", str(key_file)],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=False,
    )
    if checked.returncode != 0:
        raise ValueError("SAI SSH private key is invalid")
    shutil.copyfile(str(source), str(known_hosts))
    config.write_text(
        "Host sai-ci\n"
        "    HostName {host}\n"
        "    Port {port}\n"
        "    User {user}\n"
        "    IdentityFile {key}\n"
        "    IdentitiesOnly yes\n"
        "    BatchMode yes\n"
        "    StrictHostKeyChecking yes\n"
        "    UserKnownHostsFile {known}\n"
        "    ForwardAgent no\n"
        "    ClearAllForwardings yes\n"
        "    RequestTTY no\n"
        "    Compression yes\n"
        "    ConnectionAttempts 4\n"
        "    ConnectTimeout 30\n"
        "    ControlMaster auto\n"
        "    ControlPath {root}/control-%C\n"
        "    ControlPersist 15m\n"
        "    ServerAliveInterval 30\n"
        "    ServerAliveCountMax 4\n".format(
            host=host, port=port, user=user, key=key_file,
            known=known_hosts, root=root,
        ),
        encoding="utf-8",
    )
    os.chmod(str(known_hosts), 0o600)
    os.chmod(str(config), 0o600)
    print("SAI_SSH_CLIENT_READY host={} port={} user={}".format(host, port, user))
    return config


def _write_outputs(values: Dict[str, str], accepted: bool) -> None:
    output_path = Path(os.environ["GITHUB_OUTPUT"])
    summary_path = Path(os.environ["GITHUB_STEP_SUMMARY"])
    with output_path.open("a", encoding="utf-8") as output:
        for name in (
            "accepted", "check_run_id", "pr_number", "run_namespace",
            "source_repository", "source_sha",
        ):
            output.write("{}={}\n".format(name, values[name]))
    if accepted:
        with summary_path.open("a", encoding="utf-8") as summary:
            summary.write("### Accepted SAI GPU request\n\n")
            summary.write("- Source: `{}@{}`\n".format(
                values["source_repository"], values["source_sha"]
            ))
            if values["pr_number"]:
                summary.write("- Pull request: #{}\n".format(values["pr_number"]))
            summary.write("- Namespace: `{}`\n".format(values["run_namespace"]))


def authorize() -> Dict[str, str]:
    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not _REPOSITORY.fullmatch(repository):
        raise ValueError("invalid GitHub repository")
    values = {
        "accepted": "false", "check_run_id": "", "pr_number": "",
        "run_namespace": "", "source_repository": repository, "source_sha": "",
    }
    if event_name == "schedule":
        values.update(accepted="true", source_sha=os.environ.get("GITHUB_SHA", ""), run_namespace="daily")
    elif event_name == "workflow_dispatch":
        values.update(
            accepted="true",
            source_sha=os.environ.get("MANUAL_SOURCE_SHA", ""),
            run_namespace=os.environ.get("MANUAL_RUN_NAMESPACE", ""),
        )
    elif event_name == "issue_comment":
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
        command = event["comment"]["body"]
        commenter = event["comment"]["user"]["login"]
        pr_number = event["issue"]["number"]
        default_branch = event["repository"]["default_branch"]
        if command != "/abacus-ci sai-gpu" or not _LOGIN.fullmatch(commenter):
            raise ValueError("invalid SAI comment request")
        if not isinstance(pr_number, int) or isinstance(pr_number, bool) or pr_number < 1:
            raise ValueError("invalid pull request number")
        values["pr_number"] = str(pr_number)
        encoded = urllib.parse.quote(commenter, safe="")
        permission = _api("repos/{}/collaborators/{}/permission".format(repository, encoded))
        if permission.get("permission") not in _ROLES and permission.get("role_name") not in _ROLES:
            values.update(source_sha="0" * 40, run_namespace="unauthorized")
        else:
            pull = _api("repos/{}/pulls/{}".format(repository, pr_number))
            state = pull["state"]
            base_repository = pull["base"]["repo"]["full_name"]
            base_branch = pull["base"]["ref"]
            source_repository = pull["head"]["repo"]["full_name"]
            source_sha = pull["head"]["sha"]
            if state != "open" or base_repository != repository or base_branch != default_branch:
                raise ValueError("pull request is not open against the default branch")
            if not _REPOSITORY.fullmatch(source_repository) or not _SHA.fullmatch(source_sha):
                raise ValueError("pull request head identity is invalid")
            details_url = "{}/{}/actions/runs/{}".format(
                os.environ["GITHUB_SERVER_URL"], repository, os.environ["GITHUB_RUN_ID"]
            )
            check = _api(
                "repos/{}/check-runs".format(repository), method="POST", body={
                    "name": "SAI GPU Case Matrix",
                    "head_sha": source_sha,
                    "details_url": details_url,
                    "status": "queued",
                    "output": {
                        "title": "Awaiting protected SAI Environment approval",
                        "summary": (
                            "Requested by @{} with `/abacus-ci sai-gpu`. Candidate "
                            "code at `{}` will execute as the configured SAI account after approval."
                        ).format(commenter, source_sha),
                    },
                },
            )
            check_id = check.get("id")
            if not isinstance(check_id, int) or isinstance(check_id, bool) or check_id < 1:
                raise RuntimeError("GitHub returned an invalid Check Run ID")
            values.update(
                accepted="true", check_run_id=str(check_id),
                run_namespace="pr-{}".format(pr_number),
                source_repository=source_repository, source_sha=source_sha,
            )
    else:
        raise ValueError("unsupported GitHub event")
    if not _SHA.fullmatch(values["source_sha"]) or not _NAME.fullmatch(values["run_namespace"]):
        raise ValueError("invalid source SHA or run namespace")
    _write_outputs(values, values["accepted"] == "true")
    return values


def _required(name: str, pattern: re.Pattern) -> str:
    value = os.environ.get(name, "")
    if not pattern.fullmatch(value):
        raise ValueError("invalid {}".format(name))
    return value


def _timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def start_check() -> None:
    repository = _required("GITHUB_REPOSITORY", _REPOSITORY)
    check_id = _required("CHECK_RUN_ID", re.compile(r"[1-9][0-9]*\Z"))
    _api(
        "repos/{}/check-runs/{}".format(repository, check_id),
        method="PATCH", body={"status": "in_progress", "started_at": _timestamp()},
    )


def complete_check() -> None:
    repository = _required("GITHUB_REPOSITORY", _REPOSITORY)
    check_id = _required("CHECK_RUN_ID", re.compile(r"[1-9][0-9]*\Z"))
    pr_number = _required("PR_NUMBER", re.compile(r"[1-9][0-9]*\Z"))
    source_sha = _required("SOURCE_SHA", _SHA)
    run_id = _required("GITHUB_RUN_ID", re.compile(r"[1-9][0-9]*\Z"))
    result = os.environ.get("SAI_RESULT", "")
    conclusions = {
        "success": "success", "cancelled": "cancelled",
        "failure": "failure", "skipped": "failure",
    }
    if result not in conclusions:
        raise ValueError("invalid SAI_RESULT")
    details_url = "{}/{}/actions/runs/{}".format(
        os.environ.get("GITHUB_SERVER_URL", ""), repository, run_id
    )
    if not details_url.startswith("https://github.com/"):
        raise ValueError("invalid GitHub server URL")
    summary = (
        "SAI GPU validation for PR #{} at `{}` completed with workflow result "
        "**{}**. [Open the Actions run]({}) for the case summary and retained logs."
    ).format(pr_number, source_sha, result, details_url)
    _api(
        "repos/{}/check-runs/{}".format(repository, check_id),
        method="PATCH", body={
            "status": "completed", "conclusion": conclusions[result],
            "completed_at": _timestamp(),
            "output": {"title": "SAI GPU validation: " + result, "summary": summary},
        },
    )

    case_summary = "GPU case summary unavailable."
    if os.environ.get("CASE_SUMMARY_AVAILABLE") == "true":
        counts = [
            int(_required(name, re.compile(r"[0-9]+\Z")))
            for name in ("GPU_PASSED", "GPU_FAILED", "GPU_INFRASTRUCTURE")
        ]
        total = int(_required("GPU_TOTAL", re.compile(r"[1-9][0-9]*\Z")))
        if sum(counts) != total:
            raise ValueError("GPU case counts do not add up")
        case_summary = "GPU cases: **{} passed, {} failed, {} infrastructure**.".format(
            *counts
        )
    artifact_summary = "Raw test files were not uploaded."
    artifact_url = os.environ.get("ARTIFACT_URL", "")
    if artifact_url:
        expected = re.compile(
            r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/"
            r"actions/runs/[0-9]+/artifacts/[0-9]+\Z"
        )
        if not expected.fullmatch(artifact_url):
            raise ValueError("invalid artifact URL")
        artifact_summary = "[Download raw test files]({}) (retained for 30 days).".format(
            artifact_url
        )
    comment = "\n\n".join((
        "## SAI GPU validation: " + result,
        case_summary,
        "[Open the Actions run]({}) | {}".format(details_url, artifact_summary),
        "Candidate: `{}`".format(source_sha),
    ))
    _api(
        "repos/{}/issues/{}/comments".format(repository, pr_number),
        method="POST", body={"body": comment},
    )


def configure_parser(parser: argparse.ArgumentParser) -> None:
    parser.set_defaults(handler=lambda _args: authorize() and 0)
