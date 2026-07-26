"""Compute-node helpers used by the fixed Slurm workers.

The shell workers only establish the module environment.  Everything that
depends on an array task belongs here so that it can be tested without a
shell, and so that failure status is written consistently.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import BinaryIO, Dict, Mapping, Optional, Sequence, Tuple


_NAME = re.compile(r"[A-Za-z0-9_.-]+\Z")
_CASE_ID = re.compile(r"[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?\Z")
_RESOURCE = re.compile(r"[A-Za-z0-9_.-]+\Z")
_PMIX = re.compile(br"PMIX_ERR_(?:FILE_OPEN_FAILURE|OUT_OF_RESOURCE)")


def is_pmix_startup_failure(log: bytes) -> bool:
    """Return true only for the known PMIx startup failure signature."""
    return bool(_PMIX.search(log)) and b"MPI_Init_thread" in log and b"PMIx_Init failed" in log


def _contained(path: Path, parent: Path) -> bool:
    return path == parent or parent in path.parents


def _stream(command: Sequence[str], cwd: Path, outputs: Sequence[BinaryIO], env: Optional[Mapping[str, str]] = None) -> int:
    process = subprocess.Popen(
        list(command), cwd=str(cwd), env=dict(env) if env is not None else None,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert process.stdout is not None
    while True:
        block = process.stdout.read(64 * 1024)
        if not block:
            break
        for output in outputs:
            output.write(block)
            output.flush()
    process.stdout.close()
    return process.wait()


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=".%s." % path.name, dir=str(path.parent))
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        temporary.write_text(text, encoding="utf-8")
        os.replace(str(temporary), str(path))
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _array_id(name: str) -> int:
    value = os.environ.get(name, "")
    if not re.fullmatch(r"[0-9]+", value):
        raise ValueError("{} must be a numeric Slurm value".format(name))
    return int(value)


def _manifest_row(manifest: Path, task_id: int, result_root: Path) -> Dict[str, str]:
    path = manifest.expanduser()
    if path.is_symlink() or not path.is_file():
        raise ValueError("GPU case manifest is unavailable")
    manifest_real = path.resolve(strict=True)
    matrix_root = (result_root / "case-matrix").resolve(strict=True)
    if not _contained(manifest_real, matrix_root):
        raise ValueError("GPU case manifest is outside the case matrix")
    lines = manifest_real.read_text(encoding="utf-8").splitlines()
    index = task_id + 1
    if index >= len(lines):
        raise ValueError("No manifest row for array task {}".format(task_id))
    fields = lines[index].split("\t")
    if len(fields) != 6 or any(field == "" for field in fields):
        raise ValueError("Malformed GPU case manifest row")
    case_id, suite, case_name, resource, runner, retries = fields
    if not _CASE_ID.fullmatch(case_id) or not _NAME.fullmatch(suite) or not _NAME.fullmatch(case_name):
        raise ValueError("Invalid GPU case manifest name")
    if case_id != suite + "/" + case_name or not _RESOURCE.fullmatch(resource):
        raise ValueError("Invalid GPU case manifest identity")
    if runner not in ("autotest", "cusolvermp") or not re.fullmatch(r"[1-9][0-9]*", retries):
        raise ValueError("Invalid GPU case manifest runner")
    return {
        "case_id": case_id, "suite": suite, "case_name": case_name,
        "resource": resource, "runner": runner, "retries": retries,
    }


def _validate_case_source(source_root: Path, row: Mapping[str, str]) -> Path:
    source = source_root.resolve(strict=True)
    source_tests = (source / "tests").resolve(strict=True)
    source_case = (source_tests / row["suite"] / row["case_name"]).resolve(strict=True)
    expected = source_tests / row["suite"] / row["case_name"]
    if source_case != expected or not source_case.is_dir() or source_case.is_symlink():
        raise ValueError("GPU case path is invalid")
    return source_case


def _stage_case(source_root: Path, source_case: Path, row: Mapping[str, str], task_root: Path) -> Path:
    work_root = task_root / "work"
    tests_root = work_root / "tests"
    suite_root = tests_root / row["suite"]
    suite_root.mkdir(parents=True, exist_ok=True)
    for name in ("integrate", "PP_ORB"):
        os.symlink(str(source_root / "tests" / name), str(tests_root / name))
    shutil.copytree(str(source_case), str(suite_root / row["case_name"]))
    (suite_root / "CASES.task.txt").write_text(row["case_name"] + "\n", encoding="utf-8")
    return suite_root / row["case_name"]


def run_autotest(
    suite_dir: Path, case_dir: Path, case_name: str, abacus: Path,
    ranks: int, omp_threads: int, task_root: Path, max_attempts: int,
) -> int:
    suite = suite_dir.resolve(strict=True)
    case = case_dir.resolve(strict=True)
    binary = abacus.resolve(strict=True)
    task = task_root.resolve(strict=True)
    result_root = Path(os.environ["RESULT_ROOT"]).resolve(strict=True)
    if not _NAME.fullmatch(case_name) or case != suite / case_name:
        raise ValueError("invalid autotest case path")
    if not os.access(str(binary), os.X_OK) or not 1 <= ranks or not 1 <= omp_threads:
        raise ValueError("invalid autotest executable or topology")
    if not 1 <= max_attempts <= 2 or task == result_root or result_root not in task.parents:
        raise ValueError("invalid autotest attempt count or result path")
    autotest = (suite.parent / "integrate" / "Autotest.sh").resolve(strict=True)
    if not autotest.is_file():
        raise ValueError("Autotest.sh is unavailable")

    combined_path = task / "case.log"
    metadata = task / "pmix-retry.tsv"
    retried = False
    final_pmix = False
    returncode = 2
    attempt = 1
    with combined_path.open("wb") as combined:
        while attempt <= max_attempts:
            shutil.rmtree(str(case / "OUT.autotest"), ignore_errors=True)
            for name in ("log.txt", "result.out"):
                try:
                    (case / name).unlink()
                except FileNotFoundError:
                    pass
            header = "SAI_GPU_CASE_ATTEMPT attempt={} max={}\n".format(attempt, max_attempts).encode()
            combined.write(header)
            sys.stdout.buffer.write(header)
            attempt_log = task / "case-attempt-{}.log".format(attempt)
            command = [
                "timeout", "--signal=TERM", "--kill-after=30s", "10m",
                "bash", str(autotest), "-a", str(binary), "-n", str(ranks),
                "-o", str(omp_threads), "-f", "CASES.task.txt", "-r",
                "^{}$".format(case_name),
            ]
            with attempt_log.open("wb") as log:
                returncode = _stream(command, suite, (log, combined, sys.stdout.buffer))
            data = attempt_log.read_bytes()
            final_pmix = returncode not in (0, 124, 137, 143) and is_pmix_startup_failure(data)
            if attempt < max_attempts and final_pmix:
                retried = True
                message = b"SAI_PMIX_STARTUP_RETRY delay_seconds=10\n"
                combined.write(message)
                sys.stdout.buffer.write(message)
                sys.stdout.buffer.flush()
                time.sleep(10)
                attempt += 1
                continue
            break

    _atomic_write(
        metadata,
        "attempts\t{}\nmax_attempts\t{}\nretried\t{}\nretry_reason\t{}\n"
        "final_pmix\t{}\nfinal_rc\t{}\n".format(
            attempt, max_attempts, int(retried), "pmix_startup" if retried else "none",
            int(final_pmix), returncode,
        ),
    )
    print(
        "SAI_GPU_CASE_ATTEMPTS attempts={} retried={} final_pmix={} rc={}".format(
            attempt, int(retried), int(final_pmix), returncode
        )
    )
    return returncode


def classify_result(returncode: int, runner: str, metadata: Path) -> str:
    if returncode == 0:
        return "PASS"
    if returncode in (124, 137, 143):
        return "TIMEOUT"
    final_pmix = not metadata.is_file()
    if metadata.is_file():
        final_pmix = any(line.strip() == "final_pmix\t1" for line in metadata.read_text(encoding="utf-8").splitlines())
    if runner == "autotest" and final_pmix:
        return "INFRA"
    return "FAIL"


def _verify_linkage(abacus: Path, task_root: Path) -> None:
    result = subprocess.run(["ldd", str(abacus)], capture_output=True, text=True, check=False)
    listing = result.stdout + (result.stderr if result.stderr else "")
    (task_root / "artifacts" / "abacus-ldd.txt").write_text(listing, encoding="utf-8")
    if result.returncode or "not found" in listing:
        raise RuntimeError("ABACUS has unresolved runtime dependencies")
    loaded = {}
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) >= 3 and fields[1] == "=>":
            loaded[fields[0]] = fields[2]
    for library, root_variable in (
        ("libcusolverMp.so.0", "SAI_CUSOLVERMP_ROOT"),
        ("libcublasmp.so.0", "SAI_CUBLASMP_ROOT"),
        ("libnccl.so.2", "SAI_NCCL_ROOT"),
    ):
        expected_root = os.environ.get(root_variable)
        if library not in loaded or not expected_root:
            raise RuntimeError("ABACUS is not linked to the validated {} runtime".format(library))
        if Path(loaded[library]).resolve() != (Path(expected_root) / "lib" / library).resolve():
            raise RuntimeError("ABACUS is not linked to the validated {} runtime".format(library))


def run_case(
    source_root: Path, control_root: Path, install_root: Path, result_root: Path,
    toolchain_file: Path, mapping_root: Path, disable_ib: str, expected_profile: str,
    manifest: Path,
) -> int:
    del toolchain_file, mapping_root  # The shell bridge loads these environments.
    array_id = _array_id("SLURM_ARRAY_TASK_ID")
    array_job_id = _array_id("SLURM_ARRAY_JOB_ID")
    _array_id("SLURM_JOB_ID")
    result_root = result_root.resolve(strict=True)
    row = _manifest_row(manifest, array_id, result_root)
    task_key = row["case_id"].replace("/", "__")
    matrix_root = result_root / "case-matrix"
    task_root = matrix_root / "tasks" / task_key
    status_root = matrix_root / "status"
    status_file = status_root / (task_key + ".tsv")
    task_root.mkdir(parents=True, exist_ok=True)
    (task_root / "launcher").mkdir(exist_ok=True)
    (task_root / "artifacts").mkdir(exist_ok=True)
    start_epoch = int(time.time())
    status_written = False

    def write_status(state: str, returncode: int) -> None:
        nonlocal status_written
        elapsed = int(time.time()) - start_epoch
        _atomic_write(
            status_file,
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n".format(
                row["case_id"], row["suite"], row["case_name"], row["resource"], row["runner"],
                state, returncode, elapsed, os.environ["SLURM_ARRAY_JOB_ID"], array_id,
            ),
        )
        status_written = True

    try:
        if expected_profile != os.environ.get("SAI_PROFILE_NAME"):
            raise ValueError("unexpected SAI module profile")
        source_case = _validate_case_source(source_root, row)
        work_case = _stage_case(source_root.resolve(strict=True), source_case, row, task_root)
        os.environ["RESULT_ROOT"] = str(result_root)
        os.environ["SAI_SYSTEM_MPIRUN"] = shutil.which("mpirun") or ""
        if not os.environ["SAI_SYSTEM_MPIRUN"]:
            raise ValueError("mpirun is unavailable")
        launcher = task_root / "launcher" / "mpirun"
        os.symlink(str(control_root.resolve(strict=True) / "mpirun_with_mapping.sh"), str(launcher))
        os.environ["PATH"] = str(task_root / "launcher") + os.pathsep + os.environ.get("PATH", "")
        runtime_paths = []
        for variable, suffix in (
            ("SAI_MPI_ROOT", "lib"), ("SAI_CUDA_ROOT", "lib64"),
            ("SAI_CUSOLVERMP_ROOT", "lib"), ("SAI_CUBLASMP_ROOT", "lib"),
            ("SAI_NCCL_ROOT", "lib"), ("SAI_NVHPC_ROOT", "math_libs/12.9/lib64"),
        ):
            root = os.environ.get(variable)
            if root:
                runtime_paths.append(str(Path(root) / suffix))
        if os.environ.get("LD_LIBRARY_PATH"):
            runtime_paths.append(os.environ["LD_LIBRARY_PATH"])
        os.environ["LD_LIBRARY_PATH"] = os.pathsep.join(runtime_paths)
        if disable_ib == "true":
            os.environ["NCCL_IB_DISABLE"] = "1"
        elif disable_ib == "false":
            os.environ.pop("NCCL_IB_DISABLE", None)
        else:
            raise ValueError("invalid SAI_DISABLE_NCCL_IB={}".format(disable_ib))
        abacus = install_root.resolve(strict=True) / "bin" / "abacus"
        if not abacus.is_file() or not os.access(str(abacus), os.X_OK):
            raise ValueError("ABACUS binary is unavailable")
        _verify_linkage(abacus, task_root)
        ranks = int(os.environ.get("SLURM_NTASKS", "0"))
        omp_threads = int(os.environ.get("OMP_NUM_THREADS", "1"))
        if ranks < 1 or omp_threads < 1:
            raise ValueError("invalid Slurm topology")
        if row["runner"] == "autotest":
            test_rc = run_autotest(
                work_case.parent, work_case, row["case_name"], abacus,
                ranks, omp_threads, task_root, int(row["retries"]),
            )
        else:
            with (task_root / "artifacts" / "cusolvermp.log").open("wb") as output:
                test_rc = _stream(
                    ["timeout", "--signal=TERM", "--kill-after=30s", "35m", "mpirun", "-np", str(ranks), str(abacus)],
                    work_case, (output, sys.stdout.buffer), os.environ,
                )
        state = classify_result(test_rc, row["runner"], task_root / "pmix-retry.tsv")
        write_status(state, test_rc)
        print("SAI_GPU_CASE_RESULT case={} suite={} name={} state={} rc={}".format(
            row["case_id"], row["suite"], row["case_name"], state, test_rc,
        ))
        return test_rc
    except Exception:
        if not status_written:
            try:
                write_status("INFRA", 2)
            except (OSError, KeyError):
                pass
        raise


def configure_parser(worker_commands: argparse._SubParsersAction) -> None:
    worker_autotest = worker_commands.add_parser("autotest", help="run one autotest with PMIx retry")
    worker_autotest.add_argument("suite_dir", type=Path)
    worker_autotest.add_argument("case_dir", type=Path)
    worker_autotest.add_argument("case_name")
    worker_autotest.add_argument("abacus", type=Path)
    worker_autotest.add_argument("ranks", type=int)
    worker_autotest.add_argument("omp_threads", type=int)
    worker_autotest.add_argument("task_root", type=Path)
    worker_autotest.add_argument("max_attempts", type=int)
    worker_autotest.set_defaults(handler=lambda args: run_autotest(
        args.suite_dir, args.case_dir, args.case_name, args.abacus, args.ranks,
        args.omp_threads, args.task_root, args.max_attempts,
    ))
    worker_case = worker_commands.add_parser("case", help="run one GPU case array task")
    for name in ("source_root", "control_root", "install_root", "result_root", "toolchain_file", "mapping_root", "manifest"):
        worker_case.add_argument(name, type=Path)
    worker_case.add_argument("disable_ib")
    worker_case.add_argument("expected_profile")
    worker_case.set_defaults(handler=lambda args: run_case(
        args.source_root, args.control_root, args.install_root, args.result_root,
        args.toolchain_file, args.mapping_root, args.disable_ib, args.expected_profile,
        args.manifest,
    ))
