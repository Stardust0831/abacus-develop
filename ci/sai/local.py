"""Direct local SAI client using an existing OpenSSH configuration.

Only the OpenSSH configuration path is consumed locally.  Identity files and
their contents remain under OpenSSH's control.  Remote setup and cache
operations are delegated to the committed helper scripts shipped in the
control snapshot.
"""

from __future__ import annotations

import argparse
import configparser
import io
import os
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Mapping, Optional, Sequence, Tuple, Union

import source


_SSH_ALIAS = re.compile(r"[A-Za-z0-9._-]+\Z")
_NAMESPACE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
_REMOTE_PATH = re.compile(r"/(?:[A-Za-z0-9._-]+)(?:/[A-Za-z0-9._-]+)*\Z")
_SHA = re.compile(r"[0-9a-f]{40}\Z")


class LocalError(RuntimeError):
    """Raised for invalid local configuration or transport failures."""


@dataclass(frozen=True)
class LocalConfig:
    ssh_config: Path
    ssh_target: str
    project_root: str
    run_namespace: str
    artifact_root: Path


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise LocalError("Unable to read local configuration %s: %s" % (path, exc)) from exc
    except UnicodeError as exc:
        raise LocalError("Local configuration is not UTF-8: %s" % path) from exc


def _reject_multiline(text: str) -> None:
    # ConfigParser accepts indented continuation lines.  They make strict
    # configuration review ambiguous, so reject every non-empty indented line.
    for number, line in enumerate(text.splitlines(), 1):
        if line.strip() and line[:1] in (" ", "\t"):
            raise LocalError("Multiline/indented INI values are not allowed (line %d)" % number)


def _expanded_local_path(value: str, field: str, *, must_exist: bool) -> Path:
    expanded = os.path.expandvars(os.path.expanduser(value))
    if not expanded or "\x00" in expanded:
        raise LocalError("%s must be a non-empty local path" % field)
    path = Path(expanded)
    try:
        result = path.resolve(strict=must_exist)
    except OSError as exc:
        raise LocalError("Invalid %s path: %s" % (field, value)) from exc
    if not result.is_absolute():
        raise LocalError("%s must resolve to an absolute path" % field)
    if must_exist and not result.is_file():
        raise LocalError("%s must reference a regular file: %s" % (field, result))
    return result


def _validate_project_root(value: str) -> str:
    if not value or "\x00" in value or not _REMOTE_PATH.fullmatch(value):
        raise LocalError("project_root must be an absolute safe remote path")
    components = value.split("/")[1:]
    if any(component in (".", "..") for component in components):
        raise LocalError("project_root cannot contain '.' or '..' path components")
    return value


def load_config(path: Union[os.PathLike, str]) -> LocalConfig:
    """Read and strictly validate a ``[local]`` INI configuration."""

    config_path = Path(path).expanduser()
    try:
        config_path = config_path.resolve(strict=True)
    except OSError as exc:
        raise LocalError("Configuration file does not exist: %s" % path) from exc
    if not config_path.is_file():
        raise LocalError("Configuration path is not a regular file: %s" % config_path)
    text = _read_text(config_path)
    _reject_multiline(text)
    parser = configparser.ConfigParser(
        interpolation=None,
        strict=True,
        allow_no_value=False,
        empty_lines_in_values=False,
        delimiters=("=",),
        comment_prefixes=("#", ";"),
        inline_comment_prefixes=None,
    )
    try:
        parser.read_file(io.StringIO(text), source=str(config_path))
    except (configparser.Error, ValueError) as exc:
        raise LocalError("Invalid local INI configuration: %s" % exc) from exc
    if parser.defaults():
        raise LocalError("INI DEFAULT values are not allowed")
    if parser.sections() != ["local"]:
        raise LocalError("Configuration must contain exactly one [local] section")
    values = dict(parser.items("local", raw=True))
    expected = {"ssh_config", "ssh_target", "project_root", "run_namespace", "artifact_root"}
    unknown = sorted(set(values) - expected)
    missing = sorted(expected - set(values))
    if unknown:
        raise LocalError("Unknown [local] key(s): %s" % ", ".join(unknown))
    if missing:
        raise LocalError("Missing [local] key(s): %s" % ", ".join(missing))
    if any("\n" in value or "\r" in value for value in values.values()):
        raise LocalError("Multiline INI values are not allowed")

    ssh_target = values["ssh_target"].strip()
    if not _SSH_ALIAS.fullmatch(ssh_target):
        raise LocalError("ssh_target must be a safe OpenSSH Host alias")
    project_root = _validate_project_root(values["project_root"].strip())
    run_namespace = values["run_namespace"].strip()
    if not _NAMESPACE.fullmatch(run_namespace):
        raise LocalError("run_namespace must match [A-Za-z0-9][A-Za-z0-9._-]{0,63}")
    return LocalConfig(
        ssh_config=_expanded_local_path(values["ssh_config"].strip(), "ssh_config", must_exist=True),
        ssh_target=ssh_target,
        project_root=project_root,
        run_namespace=run_namespace,
        artifact_root=_expanded_local_path(values["artifact_root"].strip(), "artifact_root", must_exist=False),
    )


def _run(
    command: Sequence[str],
    *,
    input_data: Optional[bytes] = None,
    env: Optional[Mapping[str, str]] = None,
    check: bool = True,
) -> subprocess.CompletedProcess:
    try:
        result = subprocess.run(
            list(command),
            input=input_data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=dict(env) if env is not None else None,
            check=False,
        )
    except OSError as exc:
        raise LocalError("Unable to execute %s: %s" % (command[0], exc)) from exc
    if check and result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise LocalError("Command failed (%s)%s" % (" ".join(command), ": " + detail if detail else ""))
    return result


def _git(repository: Path, arguments: Sequence[str], *, check: bool = True) -> subprocess.CompletedProcess:
    return _run(["git", "-C", str(repository)] + list(arguments), check=check)


def _git_text(repository: Path, arguments: Sequence[str]) -> str:
    return _git(repository, arguments).stdout.decode("utf-8", "replace").strip()


def _repository(requested: Optional[Path], fallback: Path) -> Path:
    candidate = Path(requested).expanduser() if requested else fallback
    try:
        candidate = candidate.resolve(strict=True)
    except OSError as exc:
        raise LocalError("Repository does not exist: %s" % candidate) from exc
    top = _git_text(candidate, ("rev-parse", "--show-toplevel"))
    try:
        return Path(top).resolve(strict=True)
    except OSError as exc:
        raise LocalError("Git work-tree root is unavailable: %s" % top) from exc


def _verify_control_current(repository: Path, control_root: Path) -> str:
    control_sha = _git_text(repository, ("rev-parse", "--verify", "HEAD^{commit}"))
    if not _SHA.fullmatch(control_sha):
        raise LocalError("HEAD is not a full commit object")
    try:
        relative = control_root.relative_to(repository).as_posix()
    except ValueError as exc:
        raise LocalError("SAI control directory is outside the repository") from exc
    if relative != "ci/sai":
        raise LocalError("SAI control directory must be ci/sai")
    tracked = _git(repository, ("diff", "--quiet", "HEAD", "--", relative), check=False)
    untracked = _git_text(repository, ("ls-files", "--others", "--exclude-standard", "--", relative))
    if tracked.returncode != 0 or untracked:
        raise LocalError("Commit all ci/sai control changes before starting a remote run")
    return control_sha


def _ssh_options(config: LocalConfig, control_path: Path) -> List[str]:
    return [
        "-F",
        str(config.ssh_config),
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "ForwardAgent=no",
        "-o",
        "ClearAllForwardings=yes",
        "-o",
        "RequestTTY=no",
        "-o",
        "Compression=yes",
        "-o",
        "ControlMaster=auto",
        "-o",
        "ControlPath=" + str(control_path),
        "-o",
        "ControlPersist=15m",
    ]


def _remote_user(config: LocalConfig, options: Sequence[str]) -> str:
    result = _run(["ssh", *options, "-G", config.ssh_target])
    for line in result.stdout.decode("utf-8", "replace").splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0] == "user":
            user = fields[1]
            if _SSH_ALIAS.fullmatch(user):
                return user
            break
    raise LocalError("OpenSSH did not provide a safe remote username for %s" % config.ssh_target)


def _connect(config: LocalConfig, options: Sequence[str]) -> None:
    for attempt in range(1, 5):
        result = _run(
            ["ssh", *options, "-o", "ConnectionAttempts=1", "-MNf", config.ssh_target],
            check=False,
        )
        if result.returncode == 0:
            return
        print("SAI SSH master connection failed (attempt %d/4)" % attempt, file=sys.stderr)
        if attempt < 4:
            time.sleep(attempt * 5)
    raise LocalError("Unable to establish the SAI SSH master connection")


def _disconnect(config: LocalConfig, options: Sequence[str]) -> None:
    _run(["ssh", *options, "-O", "exit", config.ssh_target], check=False)


def _ssh_python(
    config: LocalConfig, options: Sequence[str], script: Path,
    arguments: Sequence[str], *, check: bool = True,
) -> subprocess.CompletedProcess:
    return _run(
        ["ssh", *options, config.ssh_target, "python3", "-", *arguments],
        input_data=script.read_bytes(), check=check,
    )


def _parse_key_values(data: bytes) -> dict:
    values = {}
    for line in data.decode("utf-8", "replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def _safe_remote_project(config: LocalConfig, remote: str) -> bool:
    suffix = config.project_root[6:] if config.project_root.startswith("/home/") else config.project_root
    expected = "/org/" + suffix
    return remote == config.project_root or remote == expected


def _rsync_environment(config: LocalConfig, options: Sequence[str]) -> Mapping[str, str]:
    environment = os.environ.copy()
    ssh_command = " ".join(shlex.quote(value) for value in ("ssh", *options))
    environment["RSYNC_RSH"] = ssh_command
    return environment


def _rsync(
    config: LocalConfig,
    options: Sequence[str],
    sources: Sequence[Path],
    destination: str,
    *,
    delete: bool = False,
    directory_contents: bool = False,
) -> None:
    flags = ["-az" if delete else "-a", "--partial", "--timeout=600", "--stats"]
    if delete:
        flags.insert(1, "--delete")
    source_args = [str(path) + ("/" if directory_contents else "") for path in sources]
    command = ["rsync", *flags, *source_args, "%s:%s" % (config.ssh_target, destination)]
    environment = _rsync_environment(config, options)
    for attempt in range(1, 4):
        result = _run(command, env=environment, check=False)
        if result.returncode == 0:
            return
        if attempt < 3:
            print("SAI rsync failed (attempt %d/3)" % attempt, file=sys.stderr)
            time.sleep(attempt * 5)
    detail = result.stderr.decode("utf-8", "replace").strip()
    raise LocalError("rsync failed after three attempts%s" % (": " + detail if detail else ""))


def _extract_artifacts(data: bytes, artifact_root: Path) -> None:
    try:
        archive = tarfile.open(fileobj=io.BytesIO(data), mode="r:gz")
    except (tarfile.TarError, OSError) as exc:
        raise LocalError("Remote artifact bundle is not a valid gzip tar archive") from exc
    with archive:
        for member in archive.getmembers():
            if member.name.startswith("/"):
                raise LocalError("Remote artifact contains an absolute path")
            destination = (artifact_root / member.name).resolve(strict=False)
            try:
                destination.relative_to(artifact_root)
            except ValueError as exc:
                raise LocalError("Remote artifact escapes artifact root: %s" % member.name) from exc
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isreg():
                raise LocalError("Unsupported remote artifact entry: %s" % member.name)
            destination.parent.mkdir(parents=True, exist_ok=True)
            fileobj = archive.extractfile(member)
            if fileobj is None:
                raise LocalError("Unable to read remote artifact: %s" % member.name)
            with destination.open("wb") as output:
                shutil.copyfileobj(fileobj, output)
            try:
                destination.chmod(member.mode & 0o777)
            except OSError:
                pass


def _prepare_snapshot(repository: Path, control_sha: str, control_root: Path, destination: Path) -> Path:
    del control_root  # Snapshot contents are selected from the committed tree.
    if not _SHA.fullmatch(control_sha):
        raise LocalError("Control SHA must be a 40-character hexadecimal commit")
    destination = destination.resolve(strict=False)
    if destination.exists() or destination.is_symlink():
        raise LocalError("Control snapshot destination already exists: %s" % destination)
    destination.mkdir(parents=True)
    archive = _git(repository, ("archive", "--format=tar", control_sha, "--", "ci/sai"))
    try:
        tar = tarfile.open(fileobj=io.BytesIO(archive.stdout), mode="r:")
    except (tarfile.TarError, OSError) as exc:
        raise LocalError("Committed control snapshot is not a valid tar archive") from exc
    with tar:
        expected_root = (destination / "ci" / "sai").resolve(strict=False)
        for member in tar.getmembers():
            name = member.name
            if name != "ci/sai" and not name.startswith("ci/sai/"):
                raise LocalError("Control snapshot contains an out-of-scope path: %s" % name)
            if name.startswith("/") or "\x00" in name:
                raise LocalError("Control snapshot contains an unsafe path")
            target = (destination / name).resolve(strict=False)
            try:
                target.relative_to(destination)
            except ValueError as exc:
                raise LocalError("Control snapshot contains a traversal path: %s" % name) from exc
            if not (member.isdir() or member.isreg()):
                raise LocalError("Control snapshot contains a special file: %s" % name)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            fileobj = tar.extractfile(member)
            if fileobj is None:
                raise LocalError("Unable to read control snapshot file: %s" % name)
            with target.open("wb") as output:
                shutil.copyfileobj(fileobj, output)
            target.chmod(member.mode & 0o777)
    if not expected_root.is_dir() or expected_root.is_symlink():
        raise LocalError("Committed control snapshot has no ci/sai root")
    if not (expected_root / "sai.py").is_file():
        raise LocalError("Committed control snapshot has no sai.py entrypoint")
    return expected_root


def _run_remote_entrypoint(
    config: LocalConfig,
    options: Sequence[str],
    remote_project_root: str,
    remote_run_root: str,
    source_id: str,
    control_sha: str,
    run_id: str,
    run_attempt: str,
    log_path: Path,
) -> int:
    command = [
        "ssh",
        *options,
        config.ssh_target,
        "python3",
        remote_run_root + "/control/sai.py",
        "remote",
        "run",
        remote_project_root,
        remote_run_root,
        source_id,
        control_sha,
        run_id,
        run_attempt,
    ]
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except OSError as exc:
        raise LocalError("Unable to execute remote SAI entrypoint: %s" % exc) from exc
    terminal = getattr(sys.stdout, "buffer", None)
    try:
        with log_path.open("wb") as log:
            assert process.stdout is not None
            while True:
                chunk = process.stdout.read(64 * 1024)
                if not chunk:
                    break
                log.write(chunk)
                log.flush()
                if terminal is not None:
                    terminal.write(chunk)
                    terminal.flush()
                else:
                    sys.stdout.write(chunk.decode("utf-8", "replace"))
                    sys.stdout.flush()
        return process.wait()
    except KeyboardInterrupt:
        process.terminate()
        process.wait()
        raise
    finally:
        if process.stdout is not None:
            process.stdout.close()


def _run_probe(config: LocalConfig, options: Sequence[str], control_root: Path, remote_user: str) -> None:
    result = _ssh_python(config, options, control_root / "bootstrap.py", ["probe", remote_user])
    output = result.stdout.decode("utf-8", "replace").strip()
    print("SAI_LOCAL_PROBE_OK target=%s user=%s" % (config.ssh_target, remote_user))
    if output:
        print(output)


def _execute_probe(args: argparse.Namespace, config: LocalConfig, control_root: Path) -> int:
    del args
    repository = _repository(None, control_root.parent.parent)
    client_root = Path(tempfile.mkdtemp(prefix="abacus-sai-local-"))
    options = _ssh_options(config, client_root / "control-%C")
    try:
        control_sha = _git_text(repository, ("rev-parse", "--verify", "HEAD^{commit}"))
        snapshot = _prepare_snapshot(
            repository, control_sha, control_root, client_root / "control-snapshot"
        )
        remote_user = _remote_user(config, options)
        _connect(config, options)
        _run_probe(config, options, snapshot, remote_user)
        return 0
    finally:
        _disconnect(config, options)
        shutil.rmtree(client_root, ignore_errors=True)


def _execute_run(args: argparse.Namespace, config: LocalConfig, control_root: Path) -> int:
    if getattr(args, "include_untracked", False) and not getattr(args, "working_tree", False):
        raise LocalError("--include-untracked is valid only with --working-tree")
    control_repository = _repository(None, control_root.parent.parent)
    control_sha = _verify_control_current(control_repository, control_root)
    repository = _repository(
        getattr(args, "source_repository", None), control_repository
    )
    selection = source.resolve_source(
        repository,
        source_ref=getattr(args, "source_ref", None),
        working_tree=bool(getattr(args, "working_tree", False)),
        include_untracked=bool(getattr(args, "include_untracked", False)),
    )
    requested_role = getattr(args, "cache_role", None)
    cache_role = requested_role or (
        "ephemeral" if selection.mode == "working-tree" else "candidate"
    )
    if cache_role not in ("baseline", "candidate", "ephemeral") or \
            (selection.mode == "working-tree") != (cache_role == "ephemeral"):
        raise LocalError("cache role does not match the selected source mode")

    client_root = Path(tempfile.mkdtemp(prefix="abacus-sai-local-"))
    options = _ssh_options(config, client_root / "control-%C")
    artifact_parent = config.artifact_root
    artifact_parent.mkdir(parents=True, exist_ok=True)
    run_id = getattr(args, "run_id", None) or str(int(time.time()))
    run_attempt = getattr(args, "run_attempt", None) or str(os.getpid())
    if not run_id.isdigit() or not run_attempt.isdigit():
        raise LocalError("run ID and attempt must be decimal integers")
    run_key = run_id + "-" + run_attempt
    artifact_root = artifact_parent / run_key
    try:
        artifact_root.mkdir(parents=False, exist_ok=False)
    except OSError as exc:
        shutil.rmtree(client_root, ignore_errors=True)
        raise LocalError("Unable to create artifact root %s: %s" % (artifact_root, exc)) from exc

    validation_rc = 1
    collection_rc = 1
    remote_run_root = ""
    try:
        snapshot = _prepare_snapshot(
            control_repository, control_sha, control_root,
            client_root / "control-snapshot",
        )
        remote_user = _remote_user(config, options)
        _connect(config, options)
        probe = _ssh_python(config, options, snapshot / "bootstrap.py", ["probe", remote_user])
        if probe.stdout:
            print(probe.stdout.decode("utf-8", "replace"), end="")

        prepare = _ssh_python(
            config,
            options,
            snapshot / "bootstrap.py",
            ["prepare", config.project_root, config.run_namespace, run_key, selection.source_id, control_sha],
        )
        values = _parse_key_values(prepare.stdout)
        remote_project_root = values.get("SAI_PROJECT_ROOT", "")
        remote_run_root = values.get("RUN_ROOT", "")
        expected_run = "%s/runs/%s/%s" % (remote_project_root, config.run_namespace, run_key)
        if not _safe_remote_project(config, remote_project_root) or remote_run_root != expected_run:
            raise LocalError("Remote prepare helper returned unexpected project/run paths")

        _rsync(
            config,
            options,
            [snapshot],
            remote_run_root + "/control/",
            delete=True,
            directory_contents=True,
        )
        _run([
            "ssh", *options, config.ssh_target, "python3",
            remote_run_root + "/control/sai.py", "remote", "cleanup",
            remote_project_root,
        ])
        transfer = _run([
            "ssh", *options, config.ssh_target, "python3",
            remote_run_root + "/control/sai.py", "cache", "prepare",
            remote_project_root, remote_run_root, selection.source_id, cache_role,
        ])
        transfer_values = _parse_key_values(transfer.stdout)
        transfer_root = transfer_values.get("SOURCE_TRANSFER_ROOT", "")
        base_sha = transfer_values.get("SOURCE_CACHE_BASE_SHA", "")
        expected_transfer = remote_project_root + "/cache/source-transfers/" + run_key
        if transfer_root != expected_transfer or (base_sha != "none" and not _SHA.fullmatch(base_sha)):
            raise LocalError("Remote source cache helper returned unexpected paths or base SHA")

        payload = client_root / "source-payload.gz"
        manifest = client_root / "source-manifest.gz"
        payload_info = source.build_payload(repository, selection.source_id, base_sha, payload, manifest)
        _rsync(config, options, [payload, manifest], transfer_root + "/")
        _run([
            "ssh", *options, config.ssh_target, "python3",
            remote_run_root + "/control/sai.py", "cache", "receive",
            remote_project_root, remote_run_root, transfer_root,
            payload_info.mode, selection.source_id,
        ])
        _run([
            "ssh", *options, config.ssh_target, "python3",
            remote_run_root + "/control/sai.py", "cache", "finalize",
            remote_project_root, remote_run_root, transfer_root, selection.source_id,
        ])

        context = {
            "source_mode": selection.mode,
            "source_sha": selection.source_id,
            "source_tree_sha": selection.tree_sha,
            "source_base_commit": selection.base_commit,
            "source_dirty": str(selection.dirty).lower(),
            "source_include_untracked": str(selection.include_untracked).lower(),
            "source_cache_role": cache_role,
            "control_sha": control_sha,
            "remote_user": remote_user,
            "remote_run_root": remote_run_root,
        }
        (artifact_root / "local-run-context.txt").write_text(
            "".join("%s=%s\n" % (key, value) for key, value in context.items()), encoding="utf-8"
        )

        validation_rc = _run_remote_entrypoint(
            config,
            options,
            remote_project_root,
            remote_run_root,
            selection.source_id,
            control_sha,
            run_id,
            run_attempt,
            artifact_root / "sai-remote-driver.log",
        )

        collection = _run(
            [
                "ssh", *options, config.ssh_target, "python3",
                remote_run_root + "/control/sai.py", "remote", "collect",
                remote_run_root,
            ],
            check=False,
        )
        if collection.returncode == 0:
            try:
                _extract_artifacts(collection.stdout, artifact_root)
                collection_rc = 0
            except LocalError as exc:
                print(str(exc), file=sys.stderr)
        if collection_rc == 0 and not getattr(args, "defer_archive", False):
            _run([
                "ssh", *options, config.ssh_target, "python3",
                remote_run_root + "/control/sai.py", "remote", "archive",
                remote_run_root,
            ])
        print("SAI_LOCAL_RUN_RESULT validation_rc=%d collection_rc=%d" % (validation_rc, collection_rc))
        print("SAI_LOCAL_ARTIFACT_ROOT=%s" % artifact_root)
        print("SAI_REMOTE_RUN_ROOT=%s" % remote_run_root)
        return validation_rc if collection_rc == 0 else collection_rc
    finally:
        _disconnect(config, options)
        shutil.rmtree(client_root, ignore_errors=True)


def configure_parser(parser: argparse.ArgumentParser) -> None:
    """Add the ``probe`` and ``run`` local commands to an argparse parser."""

    subparsers = parser.add_subparsers(dest="local_command", required=True)
    probe = subparsers.add_parser("probe", help="probe the configured SAI account")
    probe.add_argument("--config", required=True, type=Path)
    probe.set_defaults(handler=execute)

    run = subparsers.add_parser("run", help="run SAI validation through SSH")
    run.add_argument("--config", required=True, type=Path)
    run.add_argument("--source-repository", type=Path, help=argparse.SUPPRESS)
    selection = run.add_mutually_exclusive_group(required=True)
    selection.add_argument("--source-ref")
    selection.add_argument("--working-tree", action="store_true")
    run.add_argument("--include-untracked", action="store_true")
    run.add_argument("--run-id", help=argparse.SUPPRESS)
    run.add_argument("--run-attempt", help=argparse.SUPPRESS)
    run.add_argument(
        "--cache-role", choices=("baseline", "candidate", "ephemeral"),
        help=argparse.SUPPRESS,
    )
    run.add_argument("--defer-archive", action="store_true", help=argparse.SUPPRESS)
    run.set_defaults(handler=execute)


def execute(args: argparse.Namespace, control_root: Path) -> int:
    """Dispatch a parsed local command."""

    config = load_config(args.config)
    command = getattr(args, "local_command", None)
    if command == "probe":
        return _execute_probe(args, config, Path(control_root).resolve(strict=True))
    if command == "run":
        return _execute_run(args, config, Path(control_root).resolve(strict=True))
    raise LocalError("unknown local command")
