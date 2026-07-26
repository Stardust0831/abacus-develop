"""Minimal SAI bootstrap that can be streamed to ``python3 -`` over SSH."""

import argparse
import fcntl
import getpass
import json
import os
import re
import shutil
import socket
import time
from pathlib import Path
from typing import Optional, Tuple


_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
_USER = re.compile(r"[A-Za-z0-9._-]+\Z")
_RUN_KEY = re.compile(r"[0-9]+-[0-9]+\Z")
_SHA = re.compile(r"[0-9a-f]{40}\Z")
_REMOTE_PATH = re.compile(r"/(?:[A-Za-z0-9._-]+)(?:/[A-Za-z0-9._-]+)*\Z")


def _ensure_directory(path: Path, parent: Path, label: str) -> None:
    """Create a directory one component at a time without following links."""
    try:
        relative = path.relative_to(parent)
    except ValueError as error:
        raise ValueError("{} escapes its parent".format(label)) from error
    current = parent
    for component in relative.parts:
        current = current / component
        if current.is_symlink():
            raise ValueError("{} is symbolic".format(label))
        if current.exists():
            if not current.is_dir():
                raise ValueError("{} is not a directory".format(label))
        else:
            current.mkdir()


def probe(expected_user: str, *, home: Optional[Path] = None) -> str:
    if not _USER.fullmatch(expected_user) or getpass.getuser() != expected_user:
        raise ValueError("unexpected remote account")
    logical_home = Path.home() if home is None else Path(home)
    canonical_home = logical_home.resolve(strict=True)
    required = ("sbatch", "sacct", "squeue", "scancel", "rsync", "git", "gzip", "tar")
    missing = [name for name in required if shutil.which(name) is None]
    if missing:
        raise ValueError("missing SAI commands: {}".format(", ".join(missing)))
    return "SAI_SSH_PROBE_OK user={} home={} host={}".format(
        expected_user, canonical_home, socket.gethostname()
    )


def prepare(
    requested_root: str, namespace: str, run_key: str, source_sha: str,
    control_sha: str, *, home: Optional[Path] = None,
) -> Tuple[Path, Path]:
    if not _REMOTE_PATH.fullmatch(requested_root) or not _NAME.fullmatch(namespace):
        raise ValueError("invalid project root or namespace")
    if not _RUN_KEY.fullmatch(run_key) or not _SHA.fullmatch(source_sha) or not _SHA.fullmatch(control_sha):
        raise ValueError("invalid run key or commit SHA")
    account_home = (home or Path.home()).resolve(strict=True)
    project = Path(requested_root).resolve(strict=False)
    try:
        project.relative_to(account_home)
    except ValueError as error:
        raise ValueError("project root escapes HOME") from error
    namespace_root = project / "runs" / namespace
    config_root = account_home / ".config" / "abacus-sai-ci"
    _ensure_directory(project, account_home, "project root")
    _ensure_directory(config_root, account_home, "SAI configuration root")
    registry = config_root / "project-roots"
    if registry.is_symlink() or registry.exists() and not registry.is_file():
        raise ValueError("project-root registry is unsafe")
    lock_path = config_root / ".lock"
    if lock_path.is_symlink() or lock_path.exists() and not lock_path.is_file():
        raise ValueError("SAI configuration lock is unsafe")
    _ensure_directory(namespace_root, project, "run namespace")
    project = project.resolve(strict=True)
    namespace_root = namespace_root.resolve(strict=True)
    run = namespace_root / run_key
    if run.exists() or run.is_symlink():
        raise ValueError("remote run already exists")
    for name in ("source", "control", "build", "install", "results"):
        (run / name).mkdir(parents=True, exist_ok=False)
    marker = {
        "protocol": 1,
        "created_epoch": int(time.time()),
        "source_sha": source_sha,
        "control_sha": control_sha,
    }
    (run / ".ci-created").write_text(json.dumps(marker, sort_keys=True) + "\n", encoding="utf-8")
    if lock_path.is_symlink() or lock_path.exists() and not lock_path.is_file():
        raise ValueError("SAI configuration lock is unsafe")
    with lock_path.open("a+b") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        if registry.is_symlink() or registry.exists() and not registry.is_file():
            raise ValueError("project-root registry is unsafe")
        roots = registry.read_text(encoding="utf-8").splitlines() if registry.exists() else []
        if str(project) not in roots:
            with registry.open("a", encoding="utf-8") as output:
                output.write(str(project) + "\n")
    return project, run


def main() -> int:
    parser = argparse.ArgumentParser(description="Bootstrap a trusted SAI CI run.")
    commands = parser.add_subparsers(dest="command", required=True)
    probe_parser = commands.add_parser("probe")
    probe_parser.add_argument("expected_user")
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("project_root")
    prepare_parser.add_argument("namespace")
    prepare_parser.add_argument("run_key")
    prepare_parser.add_argument("source_sha")
    prepare_parser.add_argument("control_sha")
    args = parser.parse_args()
    if args.command == "probe":
        print(probe(args.expected_user))
    else:
        project, run = prepare(
            args.project_root, args.namespace, args.run_key,
            args.source_sha, args.control_sha,
        )
        print("SAI_PROJECT_ROOT={}".format(project))
        print("RUN_ROOT={}".format(run))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
