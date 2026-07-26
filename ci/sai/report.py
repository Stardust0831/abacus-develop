"""Validate and publish the structured SAI GPU result."""

import json
import re
from pathlib import Path
from typing import Any, Dict, Mapping

from config import SaiConfig, load_config


class ResultError(ValueError):
    """Raised when a remote result does not satisfy the public protocol."""


_IDENTIFIER = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*\Z")
_CASE_FIELDS = {
    "case_id", "suite", "name", "resource", "runner", "state", "exit_code",
    "slurm_state", "job_id", "elapsed_seconds", "artifact_dir",
}
_COMPONENT_FIELDS = {"name", "label", "state", "job_id", "slurm_state", "exit_code"}


def _components(config: SaiConfig) -> Dict[str, str]:
    return {
        "build": config.build.label,
        **{name: profile.label for name, profile in config.resources.items()},
    }


def unavailable_components(components: Mapping[str, str]) -> list:
    return [
        {"name": name, "label": label, "state": "INFRA"}
        for name, label in components.items()
    ]


def load_result(path: Path, config: SaiConfig) -> Dict[str, Any]:
    try:
        result = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ResultError("unable to read SAI result: {}".format(error)) from error

    required = {
        "protocol",
        "total",
        "passed",
        "failed",
        "infrastructure",
        "components",
        "cases",
    }
    if not isinstance(result, dict) or set(result) != required:
        raise ResultError("unexpected result fields")
    if result["protocol"] != 2 or not isinstance(result["total"], int) or \
            isinstance(result["total"], bool) or result["total"] != len(config.cases):
        raise ResultError("unsupported result protocol or case count")
    counts = [result[name] for name in ("passed", "failed", "infrastructure")]
    if any(not isinstance(value, int) or isinstance(value, bool) or value < 0
           for value in counts):
        raise ResultError("invalid result count")
    if sum(counts) != result["total"]:
        raise ResultError("result counts do not add up")
    expected_components = _components(config)
    components = result["components"]
    if not isinstance(components, list) or len(components) != len(expected_components):
        raise ResultError("invalid component result list")
    for component, (name, label) in zip(components, expected_components.items()):
        if not isinstance(component, dict) or set(component) != _COMPONENT_FIELDS:
            raise ResultError("invalid component result")
        if component["name"] != name or component["label"] != label or \
                component["state"] not in ("PASS", "FAIL", "INFRA", "SKIPPED"):
            raise ResultError("invalid component identity or state")
        if not isinstance(component["job_id"], str) or not re.fullmatch(r"[0-9]*", component["job_id"]):
            raise ResultError("invalid component job ID")
        if not isinstance(component["slurm_state"], str) or not re.fullmatch(r"[A-Z_]*", component["slurm_state"]):
            raise ResultError("invalid component Slurm state")
        if not isinstance(component["exit_code"], str) or not re.fullmatch(r"(?:[0-9]+:[0-9]+)?", component["exit_code"]):
            raise ResultError("invalid component exit code")
    cases = result["cases"]
    if not isinstance(cases, list) or len(cases) != result["total"]:
        raise ResultError("invalid case result list")
    case_ids = []
    states = []
    for case in cases:
        if not isinstance(case, dict) or set(case) != _CASE_FIELDS:
            raise ResultError("invalid case result")
        if not all(isinstance(case[name], str) and _IDENTIFIER.fullmatch(case[name])
                   for name in ("suite", "name", "resource", "runner")):
            raise ResultError("invalid case identity")
        if case["case_id"] != case["suite"] + "/" + case["name"]:
            raise ResultError("inconsistent case identity")
        if case["runner"] not in ("autotest", "cusolvermp") or \
                case["state"] not in ("PASS", "FAIL", "TIMEOUT", "INFRA"):
            raise ResultError("invalid runner or state")
        exit_code = case["exit_code"]
        if not (
            exit_code is None
            or (isinstance(exit_code, int) and not isinstance(exit_code, bool) and exit_code >= 0)
            or (isinstance(exit_code, str) and re.fullmatch(r"[0-9]+:[0-9]+", exit_code))
        ):
            raise ResultError("invalid case exit code")
        if not isinstance(case["slurm_state"], str) or not re.fullmatch(r"[A-Z_]*", case["slurm_state"]):
            raise ResultError("invalid Slurm state")
        if not isinstance(case["job_id"], str) or not re.fullmatch(r"(?:[0-9]+(?:_[0-9]+)?)?", case["job_id"]):
            raise ResultError("invalid Slurm job ID")
        if not isinstance(case["elapsed_seconds"], int) or isinstance(case["elapsed_seconds"], bool) \
                or case["elapsed_seconds"] < 0:
            raise ResultError("invalid elapsed time")
        if not isinstance(case["artifact_dir"], str):
            raise ResultError("invalid artifact directory")
        case_ids.append(case["case_id"])
        states.append(case["state"])
    if len(set(case_ids)) != len(case_ids):
        raise ResultError("duplicate case result")
    expected_counts = (
        states.count("PASS"), states.count("FAIL") + states.count("TIMEOUT"),
        states.count("INFRA"),
    )
    if expected_counts != tuple(counts):
        raise ResultError("case states do not match result counts")
    if any(case["resource"] not in config.resources
           for case in cases):
        raise ResultError("unknown case resource")
    build_state = components[0]["state"]
    if build_state == "PASS":
        for component in components[1:]:
            group_states = [
                case["state"] for case in cases
                if case["resource"] == component["name"]
            ]
            if group_states and all(state == "PASS" for state in group_states):
                expected = "PASS"
            elif any(state in ("FAIL", "TIMEOUT") for state in group_states):
                expected = "FAIL"
            else:
                expected = "INFRA"
            if component["state"] != expected:
                raise ResultError("component state does not match its cases")
    elif build_state in ("FAIL", "INFRA"):
        expected = "SKIPPED" if build_state == "FAIL" else "INFRA"
        if any(case["state"] != "INFRA" for case in cases) or \
                any(component["state"] != expected for component in components[1:]):
            raise ResultError("build failure is inconsistent with case components")
    else:
        raise ResultError("invalid build component state")
    return result


def publish_github(
    result_path: Path, output_path: Path, summary_path: Path, config_path: Path,
) -> None:
    """Write stable GitHub outputs; absence remains an explicit unavailable result."""
    config = load_config(config_path, config_path.parent)
    components = _components(config)
    if not result_path.is_file():
        with output_path.open("a", encoding="utf-8") as output:
            output.write("available=false\n")
            output.write("passed=\nfailed=\ninfrastructure=\ntotal=\n")
            output.write("components={}\n".format(json.dumps(unavailable_components(components), separators=(",", ":"))))
        with summary_path.open("a", encoding="utf-8") as summary:
            summary.write("## SAI GPU validation produced no structured result\n")
        return

    result = load_result(result_path, config)
    with output_path.open("a", encoding="utf-8") as output:
        output.write("available=true\n")
        for name in ("passed", "failed", "infrastructure", "total"):
            output.write("{}={}\n".format(name, result[name]))
        matrix = [
            {"name": item["name"], "label": item["label"], "state": item["state"]}
            for item in result["components"]
        ]
        output.write("components={}\n".format(json.dumps(matrix, separators=(",", ":"))))

    markdown = result_path.with_name("gpu-case-summary.md")
    with summary_path.open("a", encoding="utf-8") as summary:
        if markdown.is_file():
            summary.write(markdown.read_text(encoding="utf-8"))
        else:
            summary.write(
                "## SAI GPU validation\n\n"
                "Passed: **{}**; Failed: **{}**; Infrastructure: **{}**\n".format(
                    result["passed"], result["failed"], result["infrastructure"]
                )
            )
