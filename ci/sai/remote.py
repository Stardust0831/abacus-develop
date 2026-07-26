"""Build ABACUS and run the trusted SAI GPU matrix."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import sys
import tarfile
import time
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from config import CaseSpec, SaiConfig, load_config
from slurm import SlurmClient, SlurmError


_CUSOLVER_LINE = re.compile(r"^[ \t]*ks_solver[ \t]+cusolvermp[ \t]*$", re.MULTILINE)
_HEX40 = re.compile(r"[0-9a-f]{40}\Z")
_RUN_PART = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\Z")


class RemoteValidationError(ValueError):
    pass


def _canonical_run(path: Path, home: Optional[Path] = None) -> Path:
    candidate = Path(path).expanduser()
    if candidate.is_symlink():
        raise RemoteValidationError("run root is symbolic")
    root = candidate.resolve(strict=True)
    account_home = (home or Path.home()).resolve(strict=True)
    if not _contained(root, account_home):
        raise RemoteValidationError("run root is outside HOME")
    parts = root.parts
    if len(parts) < 3 or parts[-3] != "runs" or \
            not all(_RUN_PART.fullmatch(part) for part in parts[-2:]):
        raise RemoteValidationError("run root must end in runs/NAMESPACE/RUN_KEY")
    marker = root / ".ci-created"
    if not marker.is_file() or marker.is_symlink():
        raise RemoteValidationError("run root has no regular creation marker")
    return root


def collect_artifacts(
    run_root: Path, output: Any, *, home: Optional[Path] = None,
) -> None:
    root = _canonical_run(run_root, home)
    with tarfile.open(fileobj=output, mode="w|gz") as archive:
        _add_artifacts(archive, root)


def _add_artifacts(archive: tarfile.TarFile, root: Path) -> None:
    selected = []
    for relative in (
        ".ci-created", "build/toolchain-summary.txt",
        "build/CMakeCache.txt", "install/abacus-info.txt", "install/ldd.txt",
        "install/abacus.sha256",
    ):
        path = root / relative
        if path.is_file() and not path.is_symlink():
            selected.append(path)
    for directory in (root / "results", root / "source" / "tests"):
        if not directory.is_dir() or directory.is_symlink():
            continue
        for path in directory.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            if directory == root / "results":
                allowed = path.suffix in {".log", ".out", ".txt", ".tsv", ".md", ".json", ".sha256"}
            else:
                allowed = path.name in {"log.txt", "result.out", "warning.log"} or path.name.startswith("running") and path.suffix == ".log"
            if allowed:
                selected.append(path)
    for path in sorted(set(selected)):
        archive.add(str(path), arcname=path.relative_to(root).as_posix(), recursive=False)


def archive_run(run_root: Path, *, home: Optional[Path] = None) -> Path:
    root = _canonical_run(run_root, home)
    project = root.parents[2]
    archive_root = project / "archives" / root.parent.name
    if (project / "archives").is_symlink() or archive_root.is_symlink():
        raise RemoteValidationError("archive root is symbolic")
    archive_root.mkdir(parents=True, exist_ok=True)
    destination = archive_root / (root.name + ".tar.gz")
    if destination.exists() or destination.is_symlink():
        raise RemoteValidationError("run archive already exists")
    temporary = destination.with_name(".%s.%d.tmp" % (destination.name, os.getpid()))
    try:
        with tarfile.open(str(temporary), mode="w:gz") as archive:
            _add_artifacts(archive, root)
        os.replace(str(temporary), str(destination))
        shutil.rmtree(str(root))
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return destination


def cleanup_archives(
    project_root: Path, *, now: Optional[int] = None, home: Optional[Path] = None,
) -> int:
    project = Path(project_root).expanduser().resolve(strict=True)
    account_home = (home or Path.home()).resolve(strict=True)
    if not _contained(project, account_home):
        raise RemoteValidationError("project root is outside HOME")
    archives = project / "archives"
    if archives.is_symlink() or not archives.is_dir():
        return 0
    removed = 0
    current = int(time.time()) if now is None else now
    for path in sorted(archives.glob("*/*.tar.gz")):
        if path.is_symlink() or not path.is_file() or \
                not _RUN_PART.fullmatch(path.parent.name) or \
                not _RUN_PART.fullmatch(path.name[:-7]):
            continue
        if current - int(path.stat().st_mtime) < 72 * 3600:
            continue
        path.unlink()
        removed += 1
    return removed


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(".%s.%s.tmp" % (path.name, os.getpid()))
    temporary.write_text(text, encoding="utf-8")
    os.replace(str(temporary), str(path))


def _contained(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _validate_directory(path: Path, label: str) -> None:
    if not path.is_dir() or path.is_symlink():
        raise RemoteValidationError("%s is missing or symbolic" % label)


def validate_cases(source_root: Path, cases: Sequence[CaseSpec]) -> List[Dict[str, str]]:
    if not cases:
        raise RemoteValidationError("GPU matrix has no cases")
    tests_root = source_root / "tests"
    if not tests_root.is_dir() or tests_root.is_symlink():
        raise RemoteValidationError("source tests tree is missing or symbolic")
    for shared in ("integrate", "PP_ORB"):
        _validate_directory(tests_root / shared, "tests/%s" % shared)

    rows: List[Dict[str, str]] = []
    for case in cases:
        case_dir = tests_root / case.suite / case.name
        _validate_directory(case_dir, case.case_id)
        if case.runner == "autotest":
            reference = case_dir / "result.ref"
            if not reference.is_file() or reference.is_symlink():
                raise RemoteValidationError("%s has no regular result.ref" % case.case_id)
        else:
            for filename in ("INPUT", "KPT", "STRU"):
                path = case_dir / filename
                if not path.is_file() or path.is_symlink():
                    raise RemoteValidationError("missing %s in %s" % (filename, case.case_id))
            text = (case_dir / "INPUT").read_text(encoding="utf-8")
            if len(_CUSOLVER_LINE.findall(text)) != 1:
                raise RemoteValidationError("%s must select cusolvermp exactly once" % case.case_id)
        rows.append(
            {
                "case_id": case.case_id,
                "suite": case.suite,
                "name": case.name,
                "resource": case.resource,
                "runner": case.runner,
                "task_key": case.case_id.replace("/", "__"),
            }
        )
    return rows


def _result_row(
    row: Mapping[str, str], *, state: str, exit_code: Any = None,
    slurm_state: str = "", job_id: str = "", elapsed_seconds: int = 0,
    artifact_dir: str = "",
) -> Dict[str, Any]:
    return {
        "case_id": row["case_id"], "suite": row["suite"], "name": row["name"],
        "resource": row["resource"], "runner": row["runner"], "state": state,
        "exit_code": exit_code, "slurm_state": slurm_state, "job_id": job_id,
        "elapsed_seconds": elapsed_seconds, "artifact_dir": artifact_dir,
    }


def _component(
    name: str, label: str, state: str, *, job_id: str = "", slurm_state: str = "",
    exit_code: str = "",
) -> Dict[str, str]:
    return {
        "name": name,
        "label": label,
        "state": state,
        "job_id": job_id,
        "slurm_state": slurm_state,
        "exit_code": exit_code,
    }


class RemoteCoordinator:
    def __init__(
        self, *, project_root: Path, run_root: Path, source_sha: str,
        control_sha: str, run_id: str, run_attempt: str, control_root: Path,
        config_path: Optional[Path] = None, slurm: Optional[SlurmClient] = None,
        home: Optional[Path] = None,
    ) -> None:
        self.project_root = Path(project_root).expanduser().resolve(strict=True)
        self.home = (home or Path.home()).resolve(strict=True)
        self.run_root = Path(run_root).expanduser().resolve(strict=True)
        self.control_root = Path(control_root).expanduser().resolve(strict=True)
        self.source_root = (self.run_root / "source").resolve(strict=True)
        self.source_sha = source_sha
        self.control_sha = control_sha
        self.run_id = str(run_id)
        self.run_attempt = str(run_attempt)
        self.config_path = (config_path or self.control_root / "gpu-matrix.ini").resolve(strict=True)
        self.results_root = self.run_root / "results"
        self.matrix_root = self.results_root / "case-matrix"
        self.client = slurm
        self.config: Optional[SaiConfig] = None
        self.rows: List[Dict[str, str]] = []

    def load(self) -> None:
        if not _HEX40.fullmatch(self.source_sha) or not _HEX40.fullmatch(self.control_sha):
            raise RemoteValidationError("source and control SHA must be lowercase 40-character IDs")
        if not _contained(self.run_root, self.project_root):
            raise RemoteValidationError("run root is outside project root")
        if not _contained(self.project_root, self.home):
            raise RemoteValidationError("project root is outside the account HOME")
        relative_run = self.run_root.relative_to(self.project_root)
        if len(relative_run.parts) != 3 or relative_run.parts[0] != "runs" or \
                not all(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", part)
                        for part in relative_run.parts[1:]):
            raise RemoteValidationError("run root must be runs/NAMESPACE/RUN_KEY")
        if not self.run_id.isdigit() or not self.run_attempt.isdigit():
            raise RemoteValidationError("run ID and attempt must be numeric")
        if self.control_root != self.run_root / "control" or self.source_root != self.run_root / "source":
            raise RemoteValidationError("source or control root is not canonical")
        if not _contained(self.config_path, self.control_root):
            raise RemoteValidationError("configuration is outside control root")
        self.config = load_config(self.config_path, self.control_root)
        self.rows = validate_cases(self.source_root, self.config.cases)

    def _write_metadata(self) -> None:
        metadata = {
            "protocol": 1, "source_sha": self.source_sha, "control_sha": self.control_sha,
            "run_id": self.run_id, "run_attempt": self.run_attempt,
            "project_root": str(self.project_root), "run_root": str(self.run_root),
            "host": socket.gethostname(),
            "cases": self.rows,
        }
        _atomic_write(
            self.results_root / "remote-run-metadata.json",
            json.dumps(metadata, indent=2, sort_keys=True) + "\n",
        )

    def _manifests(self) -> Dict[str, Path]:
        manifests: Dict[str, Path] = {}
        root = self.matrix_root / "manifests"
        for resource in self.config.resources:  # type: ignore[union-attr]
            rows = [row for row in self.rows if row["resource"] == resource]
            path = root / (resource + ".tsv")
            lines = ["case_id\tsuite\tname\tresource\trunner\tretries"]
            for row in rows:
                retries = "2" if row["runner"] == "autotest" else "1"
                lines.append("\t".join((row["case_id"], row["suite"], row["name"], resource, row["runner"], retries)))
            _atomic_write(path, "\n".join(lines) + "\n")
            manifests[resource] = path
        return manifests

    def _make_client(self) -> SlurmClient:
        if self.client is None:
            coordinator = self.config.coordinator  # type: ignore[union-attr]
            self.client = SlurmClient(
                self.run_root, poll_seconds=coordinator.poll_seconds,
                queue_failure_limit=coordinator.queue_failure_limit,
                accounting_attempts=coordinator.accounting_attempts,
            )
        return self.client

    def _common_script_args(self) -> List[str]:
        cluster = self.config.cluster  # type: ignore[union-attr]
        return [
            str(self.home), str(self.source_root), str(self.control_root), str(self.run_root / "install"),
            str(self.results_root), str(cluster.toolchain), str(cluster.mps_mapping_root),
            "true" if cluster.disable_nccl_ib else "false", cluster.mp_profile,
        ]

    def execute(self) -> int:
        try:
            self.load()
            self.results_root.mkdir(parents=True, exist_ok=True)
            self.matrix_root.mkdir(parents=True, exist_ok=True)
            self._write_metadata()
            manifests = self._manifests()
            client = self._make_client()
            client.install_signal_handlers()
            cluster = self.config.cluster
            build_job = client.submit(
                script=self.control_root / "build_gpu.sh",
                partition=cluster.partition,
                profile=self.config.build,
                label="build",
                chdir=self.source_root,
                output=self.results_root / "build-%j.out",
                script_args=(
                    str(self.home), str(self.source_root), str(self.control_root), str(self.run_root / "build"),
                    str(self.run_root / "install"), str(cluster.toolchain), cluster.mp_profile,
                ),
            )
            client.save_jobs(self.results_root / "jobs.json")
            build_state, build_exit = client.wait((build_job,))[build_job]
            build_component = _component(
                "build", self.config.build.label,
                "PASS" if (build_state, build_exit) == ("COMPLETED", "0:0") else "FAIL",
                job_id=build_job, slurm_state=build_state, exit_code=build_exit,
            )
            if (build_state, build_exit) != ("COMPLETED", "0:0"):
                rows = [
                    _result_row(row, state="INFRA", exit_code=build_exit,
                                slurm_state=build_state, job_id=build_job)
                    for row in self.rows
                ]
                components = [build_component] + [
                    _component(resource, profile.label, "SKIPPED")
                    for resource, profile in self.config.resources.items()
                ]
                return self._finish(rows, components)

            grouped = {
                resource: [row for row in self.rows if row["resource"] == resource]
                for resource in self.config.resources
            }
            arrays: Dict[str, str] = {}
            for resource, rows in grouped.items():
                arrays[resource] = client.submit(
                    script=self.control_root / "gpu_case.sbatch",
                    partition=cluster.partition,
                    profile=self.config.resources[resource],
                    label="array-%s" % resource,
                    chdir=self.source_root,
                    output=self.matrix_root / (resource + "-%A_%a.out"),
                    script_args=(*self._common_script_args(), str(manifests[resource])),
                    array_count=len(rows),
                )
            client.save_jobs(self.results_root / "jobs.json")
            accounting = client.wait(tuple(arrays.values()))

            results = []
            for row in self.rows:
                parent = arrays[row["resource"]]
                task_id = grouped[row["resource"]].index(row)
                task_job = "%s_%d" % (parent, task_id)
                slurm_state, slurm_exit = accounting[task_job]
                artifact_dir = self.matrix_root / "tasks" / row["task_key"]
                parsed = self._read_status(
                    self.matrix_root / "status" / (row["task_key"] + ".tsv"),
                    row, parent, task_id,
                )
                valid_pair = parsed is not None and (
                    (parsed[0] == "PASS" and (slurm_state, slurm_exit) == ("COMPLETED", "0:0"))
                    or (parsed[0] in ("FAIL", "TIMEOUT") and slurm_state in ("FAILED", "TIMEOUT"))
                    or (parsed[0] == "INFRA" and slurm_state != "COMPLETED")
                )
                if not valid_pair:
                    results.append(
                        _result_row(
                            row, state="INFRA", exit_code=slurm_exit,
                            slurm_state=slurm_state, job_id=task_job,
                            elapsed_seconds=parsed[2] if parsed else 0,
                            artifact_dir=str(artifact_dir),
                        )
                    )
                else:
                    state, returncode, elapsed = parsed
                    results.append(
                        _result_row(
                            row, state=state, exit_code=returncode,
                            slurm_state=slurm_state, job_id=task_job,
                            elapsed_seconds=elapsed, artifact_dir=str(artifact_dir),
                        )
                    )
            components = [build_component]
            for resource, group_rows in grouped.items():
                states = [row["state"] for row in results if row["resource"] == resource]
                if states and all(state == "PASS" for state in states):
                    state = "PASS"
                elif any(state in ("FAIL", "TIMEOUT") for state in states):
                    state = "FAIL"
                else:
                    state = "INFRA"
                job = arrays[resource]
                task_states = [
                    accounting["%s_%d" % (job, index)]
                    for index in range(len(group_rows))
                ]
                if all(item == ("COMPLETED", "0:0") for item in task_states):
                    slurm_state, slurm_exit = "COMPLETED", "0:0"
                else:
                    slurm_state, slurm_exit = next(
                        item for item in task_states if item != ("COMPLETED", "0:0")
                    )
                components.append(
                    _component(
                        resource, self.config.resources[resource].label, state, job_id=job,
                        slurm_state=slurm_state, exit_code=slurm_exit,
                    )
                )
            return self._finish(results, components)
        except (OSError, SlurmError, ValueError) as error:
            try:
                self.results_root.mkdir(parents=True, exist_ok=True)
                _atomic_write(self.results_root / "coordinator-error.txt", str(error) + "\n")
                if self.client is not None:
                    self.client.cancel()
                if self.rows:
                    assert self.config is not None
                    self._finish(
                        [_result_row(row, state="INFRA") for row in self.rows],
                        [_component("build", self.config.build.label, "INFRA")] + [
                            _component(name, profile.label, "INFRA")
                            for name, profile in self.config.resources.items()
                        ],
                    )
            except OSError:
                pass
            return 2
        finally:
            if self.client is not None:
                self.client.restore_signal_handlers()

    @staticmethod
    def _read_status(
        path: Path, row: Mapping[str, str], parent_job: str, task_id: int,
    ) -> Optional[Tuple[str, int, int]]:
        try:
            fields = path.read_text(encoding="utf-8").strip().split("\t")
        except OSError:
            return None
        if len(fields) != 10 or fields[:5] != [
            row["case_id"], row["suite"], row["name"], row["resource"], row["runner"],
        ]:
            return None
        state = fields[5].upper()
        if state not in ("PASS", "FAIL", "INFRA", "TIMEOUT"):
            return None
        try:
            returncode, elapsed = int(fields[6]), int(fields[7])
            if elapsed < 0 or fields[8] != parent_job or int(fields[9]) != task_id:
                return None
        except ValueError:
            return None
        if (state == "PASS") != (returncode == 0):
            return None
        return state, returncode, elapsed

    def _finish(
        self, rows: Sequence[Mapping[str, Any]],
        components: Sequence[Mapping[str, str]],
    ) -> int:
        passed = sum(row["state"] == "PASS" for row in rows)
        infrastructure = sum(row["state"] == "INFRA" for row in rows)
        result = {
            "protocol": 2, "total": len(rows), "passed": passed,
            "failed": len(rows) - passed - infrastructure,
            "infrastructure": infrastructure, "components": list(components),
            "cases": list(rows),
        }
        SlurmClient.save_result(self.matrix_root / "result.json", result)
        SlurmClient.save_markdown(self.matrix_root / "gpu-case-summary.md", result)
        return 0 if rows and passed == len(rows) else 1


def configure_parser(parser: argparse.ArgumentParser) -> argparse.ArgumentParser:
    parser.add_argument("project_root", metavar="PROJECT_ROOT")
    parser.add_argument("run_root", metavar="RUN_ROOT")
    parser.add_argument("source_sha", metavar="SOURCE_SHA")
    parser.add_argument("control_sha", metavar="CONTROL_SHA")
    parser.add_argument("run_id", metavar="RUN_ID")
    parser.add_argument("run_attempt", metavar="RUN_ATTEMPT")
    parser.add_argument("--config", type=Path)
    parser.set_defaults(handler=execute)
    return parser


def execute(args: Any, control_root: Path) -> int:
    return RemoteCoordinator(
        project_root=args.project_root, run_root=args.run_root,
        source_sha=args.source_sha, control_sha=args.control_sha,
        run_id=args.run_id, run_attempt=args.run_attempt,
        control_root=control_root, config_path=args.config,
    ).execute()


__all__ = [
    "RemoteCoordinator", "RemoteValidationError",
    "configure_parser", "execute", "validate_cases",
]
