"""Strict Slurm submission and accounting for the SAI coordinator."""

from __future__ import annotations

import hashlib
import json
import os
import re
import signal
import subprocess
import time
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


class SlurmError(RuntimeError):
    """Raised when a Slurm operation cannot be completed or verified."""


class SlurmSubmissionError(SlurmError):
    pass


class SlurmAccountingError(SlurmError):
    pass


CommandRunner = Callable[[Sequence[str]], Any]
TerminalState = Tuple[str, str]
TERMINAL_STATES = frozenset(
    {
        "BOOT_FAIL", "CANCELLED", "COMPLETED", "DEADLINE", "FAILED",
        "NODE_FAIL", "OUT_OF_MEMORY", "PREEMPTED", "REVOKED",
        "SPECIAL_EXIT", "TIMEOUT",
    }
)


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(".%s.%s.tmp" % (path.name, os.getpid()))
    temporary.write_text(text, encoding="utf-8")
    os.replace(str(temporary), str(path))


def _result(value: Any) -> Tuple[int, str, str]:
    if isinstance(value, str):
        return 0, value, ""
    if isinstance(value, bytes):
        return 0, value.decode("utf-8", "replace"), ""
    if isinstance(value, tuple):
        if len(value) == 2:
            return int(value[0]), str(value[1]), ""
        if len(value) == 3:
            return int(value[0]), str(value[1]), str(value[2])
    return (
        int(getattr(value, "returncode")),
        str(getattr(value, "stdout", "")),
        str(getattr(value, "stderr", "")),
    )


def _slurm_time(seconds: int) -> str:
    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return "%02d:%02d:%02d" % (hours, minutes, seconds)


class SlurmClient:
    """Submit fixed scripts and prove every allocation's terminal state."""

    def __init__(
        self,
        run_root: Path,
        *,
        command_runner: Optional[CommandRunner] = None,
        sleeper: Callable[[float], None] = time.sleep,
        poll_seconds: int = 10,
        queue_failure_limit: int = 6,
        accounting_attempts: int = 30,
        user: Optional[str] = None,
    ) -> None:
        self.run_root = Path(run_root)
        self.command_runner = command_runner or self._run_subprocess
        self.sleeper = sleeper
        self.poll_seconds = poll_seconds
        self.queue_failure_limit = queue_failure_limit
        self.accounting_attempts = accounting_attempts
        self.user = user or os.environ.get("USER") or os.environ.get("LOGNAME") or ""
        self.jobs: Dict[str, Dict[str, Any]] = {}
        self._names: Dict[str, str] = {}
        self._pending_names = set()
        self._signal_handlers: Dict[int, Any] = {}
        self._termination_requested = False

    @staticmethod
    def _run_subprocess(argv: Sequence[str]) -> subprocess.CompletedProcess:
        return subprocess.run(list(argv), check=False, capture_output=True, text=True)

    def _run(self, argv: Sequence[str]) -> str:
        if self._termination_requested and argv[0] != "scancel":
            self.cancel()
            raise KeyboardInterrupt
        returncode, stdout, stderr = _result(self.command_runner(tuple(argv)))
        if self._termination_requested and argv[0] != "scancel":
            self.cancel()
            raise KeyboardInterrupt
        if returncode:
            detail = stderr.strip() or stdout.strip()
            raise SlurmError("%s failed (%d)%s" % (argv[0], returncode, ": " + detail if detail else ""))
        return stdout

    def _job_name(self, label: str) -> str:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", label):
            raise ValueError("invalid Slurm job label")
        if label not in self._names:
            run_hash = hashlib.sha256(str(self.run_root).encode("utf-8")).hexdigest()[:10]
            self._names[label] = "sai-%s-%s" % (run_hash, label)
        return self._names[label]

    @staticmethod
    def _job_id(output: str) -> str:
        lines = [line.strip() for line in output.splitlines() if line.strip()]
        if len(lines) != 1:
            raise SlurmSubmissionError("sbatch --parsable returned malformed output")
        match = re.fullmatch(r"([0-9]+)(?:;[A-Za-z0-9_.-]+)?", lines[0])
        if not match:
            raise SlurmSubmissionError("invalid Slurm job ID: %r" % lines[0])
        return match.group(1)

    @staticmethod
    def _resource_args(partition: str, profile: Any) -> List[str]:
        return [
            "--partition=%s" % partition,
            "--qos=%s" % profile.qos,
            "--nodes=%d" % profile.nodes,
            "--ntasks=%d" % profile.total_tasks,
            "--ntasks-per-node=%d" % profile.tasks_per_node,
            "--gpus-per-node=%d" % profile.gpus_per_node,
            "--time=%s" % _slurm_time(profile.time_seconds),
        ]

    def submit(
        self,
        *,
        script: Path,
        partition: str,
        profile: Any,
        label: str,
        chdir: Path,
        output: Path,
        script_args: Sequence[str],
        array_count: Optional[int] = None,
    ) -> str:
        name = self._job_name(label)
        argv = ["sbatch", "--parsable", "--export=NIL", "--job-name=%s" % name]
        argv.extend(self._resource_args(partition, profile))
        if array_count is not None:
            if profile.parallelism is None or not 1 <= array_count:
                raise ValueError("invalid array configuration")
            argv.append("--array=0-%d%%%d" % (array_count - 1, min(profile.parallelism, array_count)))
        argv.extend(("--chdir=%s" % chdir, "--output=%s" % output, str(script)))
        argv.extend(str(argument) for argument in script_args)
        self._pending_names.add(name)
        try:
            job_id = self._job_id(self._run(argv))
        except SlurmError as error:
            raise SlurmSubmissionError(str(error)) from error
        self.jobs[job_id] = {
            "job_id": job_id,
            "name": name,
            "label": label,
            "array_count": array_count,
            "argv": argv,
        }
        self._pending_names.remove(name)
        return job_id

    @staticmethod
    def _job_list(job_ids: Iterable[str]) -> str:
        ids = [str(job_id) for job_id in job_ids]
        if not ids or any(not re.fullmatch(r"[0-9]+", job_id) for job_id in ids):
            raise ValueError("job IDs must be numeric")
        return ",".join(ids)

    def _queue_has_jobs(self, job_ids: Sequence[str]) -> bool:
        output = self._run(("squeue", "--noheader", "--jobs=%s" % self._job_list(job_ids)))
        return bool(output.strip())

    @staticmethod
    def _state(value: str) -> str:
        return value.strip().split()[0].rstrip("+") if value.strip() else ""

    def _parse_accounting(
        self, output: str, expected: Mapping[str, Optional[int]]
    ) -> Dict[str, TerminalState]:
        rows: Dict[str, TerminalState] = {}
        for raw in output.splitlines():
            if not raw.strip():
                continue
            fields = raw.strip().split("|")
            if len(fields) != 3:
                raise SlurmAccountingError("malformed sacct row: %r" % raw)
            job_id, state, exit_code = (field.strip() for field in fields)
            if "." in job_id:
                continue
            if not re.fullmatch(r"[0-9]+(?:_[0-9]+)?", job_id):
                raise SlurmAccountingError("malformed sacct job ID: %r" % job_id)
            state = self._state(state)
            if state not in TERMINAL_STATES:
                continue
            if not re.fullmatch(r"[0-9]+:[0-9]+", exit_code):
                raise SlurmAccountingError("malformed sacct exit code: %r" % exit_code)
            rows[job_id] = (state, exit_code)
        required: List[str] = []
        for parent, count in expected.items():
            if count is None:
                required.append(parent)
            else:
                required.extend("%s_%d" % (parent, index) for index in range(count))
        missing = [job_id for job_id in required if job_id not in rows]
        if missing:
            raise SlurmAccountingError("sacct has not reported terminal jobs: %s" % ",".join(missing))
        return {job_id: rows[job_id] for job_id in required}

    def wait(self, job_ids: Sequence[str]) -> Dict[str, TerminalState]:
        ids = list(job_ids)
        expected = {job_id: self.jobs[job_id]["array_count"] for job_id in ids}
        failures = 0
        while True:
            try:
                if not self._queue_has_jobs(ids):
                    break
                failures = 0
            except SlurmError as error:
                failures += 1
                if failures >= self.queue_failure_limit:
                    raise SlurmAccountingError("unable to query squeue") from error
            self.sleeper(self.poll_seconds)

        job_list = self._job_list(ids)
        last_error: Optional[Exception] = None
        for _ in range(self.accounting_attempts):
            try:
                output = self._run(
                    (
                        "sacct", "--noheader", "--allocations",
                        "--jobs=%s" % job_list, "--parsable2",
                        "--format=JobID,State,ExitCode",
                    )
                )
                return self._parse_accounting(output, expected)
            except (SlurmError, SlurmAccountingError) as error:
                last_error = error
                self.sleeper(self.poll_seconds)
        raise SlurmAccountingError(str(last_error or "accounting did not become available"))

    def cancel(self) -> None:
        for job_id, details in self.jobs.items():
            try:
                self._run(("scancel", job_id))
            except SlurmError:
                if not self.user:
                    continue
                try:
                    self._run(("scancel", "--user=%s" % self.user, "--name=%s" % details["name"]))
                except SlurmError:
                    pass
        if self.user:
            for name in self._pending_names:
                try:
                    self._run(("scancel", "--user=%s" % self.user, "--name=%s" % name))
                except SlurmError:
                    pass

    def install_signal_handlers(self) -> None:
        def handle(_signum: int, _frame: Any) -> None:
            self._termination_requested = True

        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            self._signal_handlers[signum] = signal.getsignal(signum)
            signal.signal(signum, handle)

    def restore_signal_handlers(self) -> None:
        for signum, handler in self._signal_handlers.items():
            signal.signal(signum, handler)
        self._signal_handlers.clear()

    def save_jobs(self, path: Path) -> None:
        _atomic_write(path, json.dumps({"protocol": 1, "jobs": list(self.jobs.values())}, indent=2, sort_keys=True) + "\n")

    @staticmethod
    def save_result(path: Path, result: Mapping[str, Any]) -> None:
        _atomic_write(path, json.dumps(dict(result), indent=2, sort_keys=True) + "\n")

    @staticmethod
    def save_markdown(path: Path, result: Mapping[str, Any]) -> None:
        lines = [
            "# SAI GPU result", "",
            "Passed: **%s**; Failed: **%s**; Infrastructure: **%s**"
            % (result["passed"], result["failed"], result["infrastructure"]),
            "", "## Components", "",
            "| Component | State | Slurm job | Slurm state | Exit |",
            "| --- | --- | --- | --- | --- |",
        ]
        for component in result["components"]:
            lines.append(
                "| %s | %s | %s | %s | %s |"
                % (
                    component["label"], component["state"], component["job_id"],
                    component["slurm_state"], component["exit_code"],
                )
            )
        lines.extend([
            "", "## Case matrix", "",
            "| Case | Resource | State | Exit | Slurm | Elapsed |",
            "| --- | --- | --- | ---: | --- | ---: |",
        ])
        for row in result["cases"]:
            lines.append(
                "| %s | %s | %s | %s | %s | %ss |"
                % (
                    row["case_id"], row["resource"], row["state"],
                    row["exit_code"], row["slurm_state"], row["elapsed_seconds"],
                )
            )
        _atomic_write(path, "\n".join(lines) + "\n")


__all__ = [
    "SlurmAccountingError", "SlurmClient", "SlurmError",
    "SlurmSubmissionError", "TERMINAL_STATES",
]
