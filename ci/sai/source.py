"""Git source selection and compressed payload construction for local SAI runs.

The functions in this module deliberately use Git's plumbing commands instead
of walking the work tree.  That keeps source selection faithful to Git's index
semantics (including executable bits, symlinks, and ignored paths) while the
temporary-index path makes working-tree selection non-mutating.
"""

from __future__ import annotations

import gzip
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional, Sequence, Union


PathLike = Union[str, os.PathLike, Path]


@dataclass(frozen=True)
class SourceSelection:
    """The immutable identity of a source selected for an SAI run."""

    mode: str
    source_id: str
    base_commit: str
    tree_sha: str
    dirty: bool
    include_untracked: bool


@dataclass(frozen=True)
class PayloadInfo:
    """Metadata for a generated compressed source payload."""

    mode: str
    payload_bytes: int


class SourceError(RuntimeError):
    """Raised when Git cannot resolve or materialize a source selection."""


def _repository_path(repository: PathLike) -> Path:
    """Return the canonical work-tree root for *repository*."""

    requested = Path(repository).expanduser()
    try:
        requested = requested.resolve(strict=True)
    except OSError as exc:
        raise SourceError("Repository does not exist: %s" % repository) from exc
    try:
        top = _run_git(requested, ("rev-parse", "--show-toplevel"), check=True)
    except SourceError:
        raise
    result = Path(top.decode("utf-8", "surrogateescape").strip())
    try:
        result = result.resolve(strict=True)
    except OSError as exc:
        raise SourceError("Git work-tree root is unavailable: %s" % result) from exc
    return result


def _git_environment(index: Optional[Path] = None) -> Optional[dict]:
    if index is None:
        return None
    environment = os.environ.copy()
    environment["GIT_INDEX_FILE"] = str(index)
    return environment


def _run_git(
    repository: Path,
    arguments: Sequence[str],
    *,
    index: Optional[Path] = None,
    check: bool = True,
    input_data: Optional[bytes] = None,
) -> bytes:
    command = ["git", "-C", str(repository)] + list(arguments)
    try:
        completed = subprocess.run(
            command,
            input=input_data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_git_environment(index),
            check=False,
        )
    except OSError as exc:
        raise SourceError("Unable to execute Git: %s" % exc) from exc
    if check and completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip()
        suffix = ": %s" % detail if detail else ""
        raise SourceError("Git command failed (%s)%s" % (" ".join(command), suffix))
    return completed.stdout


def _object_id(repository: Path, expression: str) -> str:
    if not expression or "\x00" in expression:
        raise SourceError("Invalid Git revision")
    # --end-of-options prevents a revision beginning with '-' from becoming a
    # rev-parse option.  It is supported by the Git versions used by SAI.
    output = _run_git(
        repository,
        ("rev-parse", "--verify", "--end-of-options", expression),
    )
    value = output.decode("ascii", "strict").strip()
    if len(value) != 40 or any(character not in "0123456789abcdef" for character in value):
        raise SourceError("Git returned an invalid object ID for %r" % expression)
    return value


def _split_nul_records(data: bytes) -> Iterable[bytes]:
    for record in data.split(b"\0"):
        if record:
            yield record


def _path_for_git(path_bytes: bytes) -> str:
    return path_bytes.decode("utf-8", "surrogateescape")


def _report_excluded(path_bytes: bytes, label: str) -> None:
    # shlex.quote is close to Bash's %q for ordinary paths and, importantly,
    # leaves the path opaque rather than interpreting it as an option.
    import shlex

    path = _path_for_git(path_bytes)
    print("%s=%s" % (label, shlex.quote(path)), file=sys.stderr)


def _clear_assume_unchanged(repository: Path, index: Path) -> None:
    records = _run_git(repository, ("ls-files", "-v", "-z"), index=index)
    for record in _split_nul_records(records):
        if len(record) < 2 or record[1:2] != b" ":
            continue
        tag = record[:1]
        if tag.islower():
            path = _path_for_git(record[2:])
            _run_git(repository, ("update-index", "--no-assume-unchanged", "--", path), index=index)


def _remove_ignored_staged_additions(repository: Path, index: Path, base_commit: str) -> None:
    added = _run_git(
        repository,
        (
            "diff",
            "--cached",
            "--diff-filter=A",
            "--no-renames",
            "--name-only",
            "-z",
            base_commit,
            "--",
        ),
        index=index,
    )
    if not added:
        return
    # check-ignore --stdin is used exactly as in the shell resolver, so a
    # tracked path that merely matches a later ignore rule is never removed:
    # only paths newly added relative to base_commit reach this check.
    checked = subprocess.run(
        ["git", "-C", str(repository), "check-ignore", "--no-index", "-z", "--stdin"],
        input=added,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=_git_environment(index),
        check=False,
    )
    if checked.returncode not in (0, 1):
        detail = checked.stderr.decode("utf-8", "replace").strip()
        raise SourceError("Git check-ignore failed%s" % (": " + detail if detail else ""))
    for path_bytes in _split_nul_records(checked.stdout):
        _report_excluded(path_bytes, "LOCAL_SOURCE_IGNORED_ADDITION_EXCLUDED")
        _run_git(
            repository,
            ("update-index", "--force-remove", "--", _path_for_git(path_bytes)),
            index=index,
        )


def _working_tree_selection(
    repository: Path,
    base_commit: str,
    base_tree: str,
    include_untracked: bool,
) -> SourceSelection:
    index_name = _run_git(repository, ("rev-parse", "--git-path", "index"))
    index_path = Path(index_name.decode("utf-8", "surrogateescape").strip())
    if not index_path.is_absolute():
        index_path = repository / index_path
    try:
        index_path = index_path.resolve(strict=True)
    except OSError as exc:
        raise SourceError("Git index does not exist: %s" % index_path) from exc

    temporary_name: Optional[str] = None
    try:
        with tempfile.NamedTemporaryFile(
            prefix=".abacus-ci-index.",
            dir=str(index_path.parent),
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
        temporary_index = Path(temporary_name)
        shutil.copyfile(index_path, temporary_index)

        _clear_assume_unchanged(repository, temporary_index)
        if include_untracked:
            _run_git(repository, ("add", "-A", "--", "."), index=temporary_index)
        else:
            records = _run_git(
                repository,
                ("ls-files", "--others", "--exclude-standard", "-z"),
            )
            for path_bytes in _split_nul_records(records):
                _report_excluded(path_bytes, "LOCAL_SOURCE_UNTRACKED_EXCLUDED")
            _run_git(repository, ("add", "-u", "--", "."), index=temporary_index)
        _remove_ignored_staged_additions(repository, temporary_index, base_commit)
        tree_sha = _run_git(repository, ("write-tree",), index=temporary_index).decode("ascii", "strict").strip()
        if len(tree_sha) != 40 or any(character not in "0123456789abcdef" for character in tree_sha):
            raise SourceError("Git returned an invalid working-tree object ID")
    finally:
        if temporary_name:
            try:
                Path(temporary_name).unlink()
            except FileNotFoundError:
                pass

    return SourceSelection(
        mode="working-tree",
        source_id=tree_sha,
        base_commit=base_commit,
        tree_sha=tree_sha,
        dirty=tree_sha != base_tree,
        include_untracked=include_untracked,
    )


def resolve_source(
    repository: PathLike,
    source_ref: Optional[str] = None,
    working_tree: bool = False,
    include_untracked: bool = False,
) -> SourceSelection:
    """Resolve a commit or deterministic working-tree source.

    Exactly one source mode is required.  The CLI enforces this through its
    mutually-exclusive argument group; the API repeats the check so callers
    cannot accidentally send an implicit or stale HEAD snapshot.
    """

    if not isinstance(working_tree, bool) or not isinstance(include_untracked, bool):
        raise TypeError("working_tree and include_untracked must be bool values")
    if not working_tree and source_ref is None:
        raise ValueError("one of source_ref or working_tree is required")
    if working_tree and source_ref is not None:
        raise ValueError("source_ref and working_tree are mutually exclusive")
    if not working_tree and include_untracked:
        raise ValueError("include_untracked requires working_tree")

    root = _repository_path(repository)
    base_commit = _object_id(root, "HEAD^{commit}")
    base_tree = _object_id(root, base_commit + "^{tree}")
    if working_tree:
        return _working_tree_selection(root, base_commit, base_tree, include_untracked)

    revision = source_ref
    if not isinstance(revision, str) or not revision or "\x00" in revision:
        raise ValueError("source_ref must be a non-empty Git revision")
    source_id = _object_id(root, revision + "^{commit}")
    tree_sha = _object_id(root, source_id + "^{tree}")
    return SourceSelection(
        mode="commit",
        source_id=source_id,
        base_commit=base_commit,
        tree_sha=tree_sha,
        dirty=False,
        include_untracked=False,
    )


def _gzip_bytes(data: bytes) -> bytes:
    # A fixed mtime makes payloads reproducible, while level 1 preserves the
    # transfer characteristics of the original gzip -1 helper.
    return gzip.compress(data, compresslevel=1, mtime=0)


def _object_exists(repository: Path, object_id: str) -> bool:
    if not re.fullmatch(r"[0-9a-f]{40}", object_id or ""):
        return False
    command = ["git", "-C", str(repository), "cat-file", "-e", object_id + "^{tree}"]
    try:
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError:
        return False
    return completed.returncode == 0


def build_payload(
    repository: PathLike,
    source_id: str,
    base_sha: str,
    payload: PathLike,
    manifest: PathLike,
) -> PayloadInfo:
    """Build a canonical compressed tree manifest and full-index diff payload."""

    root = _repository_path(repository)
    if not isinstance(source_id, str) or not re.fullmatch(r"[0-9a-f]{40}", source_id):
        raise ValueError("source_id must be a 40-character hexadecimal object name")
    if not isinstance(base_sha, str) or (base_sha != "none" and not re.fullmatch(r"[0-9a-f]{40}", base_sha)):
        raise ValueError("base_sha must be a 40-character hexadecimal object name or 'none'")
    payload_path = Path(payload).expanduser().resolve(strict=False)
    manifest_path = Path(manifest).expanduser().resolve(strict=False)
    if payload_path == manifest_path:
        raise ValueError("payload and manifest must be different paths")
    if not _object_exists(root, source_id):
        raise SourceError("Source tree is unavailable: %s" % source_id)

    manifest_data = _run_git(root, ("ls-tree", "-r", "-z", "--full-tree", source_id))
    manifest_bytes = _gzip_bytes(manifest_data)

    mode = "full"
    if base_sha != "none" and _object_exists(root, base_sha):
        diff_base = base_sha
        mode = "delta"
    else:
        diff_base = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    diff_data = _run_git(
        root,
        ("diff", "--binary", "--full-index", "--no-renames", diff_base, source_id),
    )
    payload_bytes = _gzip_bytes(diff_data)

    try:
        payload_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        payload_path.write_bytes(payload_bytes)
        manifest_path.write_bytes(manifest_bytes)
    except OSError as exc:
        raise SourceError("Unable to write source payload: %s" % exc) from exc
    if not payload_bytes or not manifest_bytes:
        raise SourceError("Generated source payload or manifest is empty")
    return PayloadInfo(mode=mode, payload_bytes=len(payload_bytes))


def configure_parser(parser: argparse.ArgumentParser) -> None:
    """Add the source payload command to the top-level SAI parser."""

    subparsers = parser.add_subparsers(dest="source_command", required=True)
    payload_parser = subparsers.add_parser("payload", help="build a compressed Git source payload")
    payload_parser.add_argument("--repository", required=True, type=Path)
    payload_parser.add_argument("--source-id", required=True)
    payload_parser.add_argument("--base-sha", required=True)
    payload_parser.add_argument("--payload", required=True, type=Path)
    payload_parser.add_argument("--manifest", required=True, type=Path)
    payload_parser.set_defaults(handler=execute)


def execute(args: argparse.Namespace) -> int:
    """Execute the source subcommand and emit machine-readable metadata."""

    if getattr(args, "source_command", None) != "payload":
        raise ValueError("unknown source command")
    info = build_payload(
        args.repository,
        args.source_id,
        args.base_sha,
        args.payload,
        args.manifest,
    )
    print(json.dumps({"mode": info.mode, "payload_bytes": info.payload_bytes}, separators=(",", ":")))
    return 0
