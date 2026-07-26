"""Validate and publish the structured SAI GPU result."""

import json
import re
from pathlib import Path
from typing import Any, Dict


class ResultError(ValueError):
    """Raised when a remote result does not satisfy the public protocol."""


_IDENTIFIER = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*\Z")
_CASE_FIELDS = {
    "case_id", "suite", "name", "resource", "runner", "state", "exit_code",
    "slurm_state", "job_id", "elapsed_seconds", "artifact_dir",
}


def load_result(path: Path) -> Dict[str, Any]:
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
        "cases",
    }
    if not isinstance(result, dict) or set(result) != required:
        raise ResultError("unexpected result fields")
    if result["protocol"] != 1 or result["total"] != 49:
        raise ResultError("unsupported result protocol or case count")
    counts = [result[name] for name in ("passed", "failed", "infrastructure")]
    if any(not isinstance(value, int) or isinstance(value, bool) or value < 0
           for value in counts):
        raise ResultError("invalid result count")
    if sum(counts) != result["total"]:
        raise ResultError("result counts do not add up")
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
    resources = {name: sum(case["resource"] == name for case in cases)
                 for name in ("gpu1", "gpu2", "gpu4", "gpu8x2")}
    if resources != {"gpu1": 1, "gpu2": 7, "gpu4": 40, "gpu8x2": 1}:
        raise ResultError("invalid resource distribution")
    smoke = [case for case in cases if case["runner"] == "cusolvermp"]
    if len(smoke) != 1 or smoke[0]["case_id"] != \
            "15_rtTDDFT_GPU/19_NO_Si48_CUSOLVERMP_TDDFT_GPU":
        raise ResultError("invalid cuSolverMp smoke result")
    return result


def publish_github(result_path: Path, output_path: Path, summary_path: Path) -> None:
    """Write stable GitHub outputs; absence remains an explicit unavailable result."""
    if not result_path.is_file():
        with output_path.open("a", encoding="utf-8") as output:
            output.write("available=false\n")
            output.write("passed=\nfailed=\ninfrastructure=\ntotal=\n")
        with summary_path.open("a", encoding="utf-8") as summary:
            summary.write("## SAI GPU validation produced no structured result\n")
        return

    result = load_result(result_path)
    with output_path.open("a", encoding="utf-8") as output:
        output.write("available=true\n")
        for name in ("passed", "failed", "infrastructure", "total"):
            output.write("{}={}\n".format(name, result[name]))

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
