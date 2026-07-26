"""Validated, concurrent source snapshots for compressed SAI transfers."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import Dict, Iterator, Optional, Tuple


_SHA = re.compile(r"[0-9a-f]{40}\Z")
_RUN_KEY = re.compile(r"[0-9]+-[0-9]+\Z")
_NAMESPACE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
_ROLE = {"baseline", "candidate", "ephemeral"}


class CacheError(RuntimeError):
    pass


def _inside(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _atomic_json(path: Path, value: Dict[str, object]) -> None:
    temporary = path.with_name(".{}.{}.tmp".format(path.name, os.getpid()))
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(str(temporary), str(path))


@contextlib.contextmanager
def _lock(cache_root: Path) -> Iterator[None]:
    lock = cache_root / ".lock"
    if lock.is_symlink() or lock.exists() and not lock.is_file():
        raise CacheError("source cache lock is unsafe")
    with lock.open("a+b") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield


def _validate_cache_root(project: Path, cache_root: Path) -> None:
    """Reject cache paths that could redirect writes outside the project."""
    if cache_root.is_symlink():
        raise CacheError("source cache root is symbolic")
    if cache_root.exists() and not cache_root.is_dir():
        raise CacheError("source cache root is not a directory")
    if cache_root.exists():
        try:
            canonical = cache_root.resolve(strict=True)
        except OSError as error:
            raise CacheError("source cache root is unavailable") from error
        if canonical != cache_root or not _inside(canonical, project):
            raise CacheError("source cache root escapes the project")


def _validate_cache_directory(cache_root: Path, name: str) -> Path:
    directory = cache_root / name
    if directory.is_symlink():
        raise CacheError("source cache directory is symbolic")
    if directory.exists() and not directory.is_dir():
        raise CacheError("source cache directory is not a directory")
    if directory.exists() and directory.resolve(strict=True) != directory:
        raise CacheError("source cache directory escapes the cache root")
    return directory


def _context(project_root: Path, run_root: Path, home: Optional[Path] = None) -> Tuple[Path, Path, Path, str]:
    account_home = (home or Path.home()).resolve(strict=True)
    project_input = Path(project_root).expanduser()
    run_input = Path(run_root).expanduser()
    if project_input.is_symlink() or run_input.is_symlink():
        raise CacheError("project or run root is symbolic")
    project = project_input.resolve(strict=True)
    run = run_input.resolve(strict=True)
    if not _inside(project, account_home) or not _inside(run, project / "runs"):
        raise CacheError("project or run root escapes the SAI account")
    relative = run.relative_to(project / "runs")
    if len(relative.parts) != 2 or not _NAMESPACE.fullmatch(relative.parts[0]) or \
            not _RUN_KEY.fullmatch(relative.parts[1]):
        raise CacheError("run root has an invalid layout")
    marker = run / ".ci-created"
    source = run / "source"
    if not marker.is_file() or marker.is_symlink() or not source.is_dir() or source.is_symlink():
        raise CacheError("run root is not a prepared CI directory")
    cache_root = project / "cache"
    _validate_cache_root(project, cache_root)
    return project, run, cache_root, relative.parts[-1]


def _pointer(cache_root: Path) -> Optional[Dict[str, str]]:
    path = cache_root / "source-current.json"
    if not path.exists():
        return None
    if not path.is_file() or path.is_symlink():
        raise CacheError("source cache pointer is unsafe")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CacheError("source cache pointer is invalid") from error
    if not isinstance(value, dict) or set(value) != {"protocol", "sha", "snapshot", "role"}:
        raise CacheError("source cache pointer has unexpected fields")
    if value["protocol"] != 1 or not isinstance(value["sha"], str) or \
            not isinstance(value["snapshot"], str) or not isinstance(value["role"], str):
        raise CacheError("source cache pointer has invalid types")
    if not _SHA.fullmatch(value["sha"]) or value["role"] not in {"baseline", "candidate"}:
        raise CacheError("source cache pointer has invalid values")
    if value["snapshot"] != "{}.{}".format(value["sha"], value["snapshot"].split(".")[-1]) or \
            not _RUN_KEY.fullmatch(value["snapshot"].split(".")[-1]):
        raise CacheError("source cache snapshot name is invalid")
    return value


def _manifest(path: Path) -> Dict[str, Tuple[str, str]]:
    if not path.is_file() or path.is_symlink():
        raise CacheError("source manifest is unavailable")
    records: Dict[str, Tuple[str, str]] = {}
    try:
        data = gzip.decompress(path.read_bytes())
    except (OSError, gzip.BadGzipFile) as error:
        raise CacheError("source manifest is not valid gzip") from error
    for record in data.split(b"\0"):
        if not record:
            continue
        try:
            metadata, raw_path = record.split(b"\t", 1)
            mode, kind, object_id = metadata.decode("ascii").split(" ")
            relative = raw_path.decode("utf-8", "surrogateescape")
        except (ValueError, UnicodeError) as error:
            raise CacheError("source manifest record is malformed") from error
        if mode not in {"100644", "100755", "120000"} or kind != "blob" or not _SHA.fullmatch(object_id):
            raise CacheError("source manifest metadata is unsupported")
        path_parts = Path(relative).parts
        if not relative or "//" in relative or Path(relative).is_absolute() or \
                any(part in ("", ".", "..") for part in path_parts):
            raise CacheError("source manifest path is unsafe")
        if relative in records:
            raise CacheError("source manifest contains a duplicate path")
        records[relative] = (mode, object_id)
    if not records:
        raise CacheError("source manifest is empty")
    return records


def _git_hash(data: bytes) -> str:
    header = "blob {}\0".format(len(data)).encode("ascii")
    return hashlib.sha1(header + data).hexdigest()


def verify_tree(root: Path, manifest: Path) -> None:
    source_root = Path(root).expanduser()
    if source_root.is_symlink():
        raise CacheError("source tree is symbolic")
    try:
        tree = source_root.resolve(strict=True)
    except OSError as error:
        raise CacheError("source tree is unavailable") from error
    lexical_root = Path(os.path.abspath(str(source_root)))
    if not tree.is_dir() or tree.is_symlink() or tree != lexical_root:
        raise CacheError("source tree is unavailable")
    expected = _manifest(manifest)
    actual = set()
    for path in tree.rglob("*"):
        if path.is_dir() and not path.is_symlink():
            continue
        relative = path.relative_to(tree).as_posix()
        if relative not in expected:
            raise CacheError("source tree contains an unexpected path")
        mode, object_id = expected[relative]
        if mode == "120000":
            if not path.is_symlink():
                raise CacheError("source symlink mode mismatch")
            data = os.readlink(str(path)).encode("utf-8", "surrogateescape")
        else:
            if not path.is_file() or path.is_symlink():
                raise CacheError("source file mode mismatch")
            executable = bool(path.stat().st_mode & 0o111)
            if executable != (mode == "100755"):
                raise CacheError("source executable mode mismatch")
            data = path.read_bytes()
        if _git_hash(data) != object_id:
            raise CacheError("source object hash mismatch")
        actual.add(relative)
    if actual != set(expected):
        raise CacheError("source tree is incomplete")


def _clear(directory: Path) -> None:
    for path in directory.iterdir():
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(str(path))
        else:
            path.unlink()


def prepare(
    project_root: Path, run_root: Path, source_sha: str, role: str,
    *, home: Optional[Path] = None,
) -> Tuple[Path, str]:
    if not _SHA.fullmatch(source_sha) or role not in _ROLE:
        raise CacheError("invalid source SHA or cache role")
    _project, run, cache_root, run_key = _context(project_root, run_root, home)
    if any((run / "source").iterdir()):
        raise CacheError("run source directory is not empty")
    cache_root.mkdir(parents=False, exist_ok=True)
    _validate_cache_root(_project, cache_root)
    snapshots = _validate_cache_directory(cache_root, "source-snapshots")
    transfers = _validate_cache_directory(cache_root, "source-transfers")
    with _lock(cache_root):
        snapshots = _validate_cache_directory(cache_root, "source-snapshots")
        transfers = _validate_cache_directory(cache_root, "source-transfers")
        snapshots.mkdir(parents=False, exist_ok=True)
        transfers.mkdir(parents=False, exist_ok=True)
        _validate_cache_directory(cache_root, "source-snapshots")
        _validate_cache_directory(cache_root, "source-transfers")
        transfer = transfers / run_key
        if transfer.exists() or transfer.is_symlink():
            raise CacheError("source transfer already exists")
        pointer = _pointer(cache_root)
        base_sha = "none"
        transfer_source = transfer / "source"
        transfer_source.mkdir(parents=True)
        if pointer is not None:
            snapshot = snapshots / pointer["snapshot"]
            manifest = snapshots / (pointer["snapshot"] + ".manifest.gz")
            verify_tree(snapshot, manifest)
            shutil.copytree(str(snapshot), str(transfer_source), symlinks=True, dirs_exist_ok=True)
            base_sha = pointer["sha"]
        _atomic_json(transfer / ".ci-source-transfer", {
            "protocol": 1, "run_root": str(run), "source_sha": source_sha,
            "role": role,
        })
    return transfer, base_sha


def _transfer(
    project_root: Path, run_root: Path, transfer_root: Path, source_sha: str,
    *, home: Optional[Path] = None,
) -> Tuple[Path, Path, Dict[str, object], Path, str]:
    _project, run, cache_root, run_key = _context(project_root, run_root, home)
    transfers = _validate_cache_directory(cache_root, "source-transfers")
    transfer_input = Path(transfer_root).expanduser()
    if transfer_input.is_symlink():
        raise CacheError("source transfer path is symbolic")
    transfer = transfer_input.resolve(strict=True)
    expected = transfers / run_key
    if transfer != expected or transfer.is_symlink():
        raise CacheError("source transfer path is invalid")
    marker_path = transfer / ".ci-source-transfer"
    try:
        marker = json.loads(marker_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CacheError("source transfer marker is invalid") from error
    role = marker.get("role") if isinstance(marker, dict) else None
    expected = {"protocol": 1, "run_root": str(run), "source_sha": source_sha, "role": role}
    if marker != expected or not isinstance(role, str) or role not in _ROLE:
        raise CacheError("source transfer marker does not match the run")
    return run, cache_root, marker, transfer, run_key


def receive(
    project_root: Path, run_root: Path, transfer_root: Path, mode: str,
    source_sha: str, *, home: Optional[Path] = None,
) -> None:
    if mode not in {"full", "delta"} or not _SHA.fullmatch(source_sha):
        raise CacheError("invalid source payload mode or SHA")
    _run, _cache, _marker, transfer, _key = _transfer(
        project_root, run_root, transfer_root, source_sha, home=home
    )
    payload = transfer / "source-payload.gz"
    manifest = transfer / "source-manifest.gz"
    _manifest(manifest)
    try:
        patch = gzip.decompress(payload.read_bytes())
    except (OSError, gzip.BadGzipFile) as error:
        raise CacheError("source payload is not valid gzip") from error
    source = transfer / "source"
    if mode == "full":
        _clear(source)
    if patch:
        for arguments in (("apply", "--check"), ("apply",)):
            result = subprocess.run(
                ["git", *arguments, "--binary", "--whitespace=nowarn", "-"],
                cwd=str(source), input=patch, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, check=False,
            )
            if result.returncode != 0:
                raise CacheError("git apply failed: {}".format(
                    result.stderr.decode("utf-8", "replace").strip()
                ))
    payload.unlink()


def finalize(
    project_root: Path, run_root: Path, transfer_root: Path, source_sha: str,
    *, home: Optional[Path] = None,
) -> Optional[Path]:
    if not _SHA.fullmatch(source_sha):
        raise CacheError("invalid source SHA")
    run, cache_root, marker, transfer, run_key = _transfer(
        project_root, run_root, transfer_root, source_sha, home=home
    )
    source = transfer / "source"
    manifest = transfer / "source-manifest.gz"
    verify_tree(source, manifest)
    run_source = run / "source"
    if any(run_source.iterdir()):
        raise CacheError("run source directory is not empty")
    shutil.copytree(str(source), str(run_source), symlinks=True, dirs_exist_ok=True)
    role = str(marker["role"])
    if role == "ephemeral":
        shutil.rmtree(str(transfer))
        return None
    snapshots = cache_root / "source-snapshots"
    snapshot_name = "{}.{}".format(source_sha, run_key)
    snapshot = snapshots / snapshot_name
    with _lock(cache_root):
        pointer = _pointer(cache_root)
        if role == "candidate" and pointer is not None and pointer["role"] == "baseline":
            shutil.rmtree(str(transfer))
            return None
        if snapshot.exists() or (snapshots / (snapshot_name + ".manifest.gz")).exists():
            raise CacheError("source snapshot already exists")
        os.replace(str(source), str(snapshot))
        os.replace(str(manifest), str(snapshots / (snapshot_name + ".manifest.gz")))
        _atomic_json(cache_root / "source-current.json", {
            "protocol": 1, "sha": source_sha, "snapshot": snapshot_name,
            "role": role,
        })
        (transfer / ".ci-source-transfer").unlink()
        transfer.rmdir()
        for path in snapshots.iterdir():
            if path.name not in {snapshot_name, snapshot_name + ".manifest.gz"}:
                if path.is_dir() and not path.is_symlink():
                    shutil.rmtree(str(path))
                elif path.is_file() and not path.is_symlink():
                    path.unlink()
    return snapshot


def configure_parser(parser: argparse.ArgumentParser) -> None:
    commands = parser.add_subparsers(dest="cache_command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("project_root", type=Path)
    prepare_parser.add_argument("run_root", type=Path)
    prepare_parser.add_argument("source_sha")
    prepare_parser.add_argument("role", choices=sorted(_ROLE))
    prepare_parser.set_defaults(handler=_execute_prepare)
    receive_parser = commands.add_parser("receive")
    receive_parser.add_argument("project_root", type=Path)
    receive_parser.add_argument("run_root", type=Path)
    receive_parser.add_argument("transfer_root", type=Path)
    receive_parser.add_argument("mode", choices=("full", "delta"))
    receive_parser.add_argument("source_sha")
    receive_parser.set_defaults(handler=_execute_receive)
    finalize_parser = commands.add_parser("finalize")
    finalize_parser.add_argument("project_root", type=Path)
    finalize_parser.add_argument("run_root", type=Path)
    finalize_parser.add_argument("transfer_root", type=Path)
    finalize_parser.add_argument("source_sha")
    finalize_parser.set_defaults(handler=_execute_finalize)


def _execute_prepare(args: argparse.Namespace) -> int:
    transfer, base = prepare(args.project_root, args.run_root, args.source_sha, args.role)
    print("SOURCE_TRANSFER_ROOT={}".format(transfer))
    print("SOURCE_CACHE_BASE_SHA={}".format(base))
    print("SOURCE_CACHE_ROLE={}".format(args.role))
    return 0


def _execute_receive(args: argparse.Namespace) -> int:
    receive(args.project_root, args.run_root, args.transfer_root, args.mode, args.source_sha)
    print("SOURCE_PAYLOAD_APPLIED mode={} sha={}".format(args.mode, args.source_sha))
    return 0


def _execute_finalize(args: argparse.Namespace) -> int:
    snapshot = finalize(args.project_root, args.run_root, args.transfer_root, args.source_sha)
    print("SOURCE_CACHE_SNAPSHOT={}".format(snapshot or "skipped"))
    return 0
