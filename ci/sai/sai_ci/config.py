"""Strict, stdlib-only configuration model for the SAI GPU CI."""

from __future__ import annotations

import configparser
import os
import re
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Mapping, Optional, Tuple


class ConfigError(ValueError):
    """Raised when a SAI configuration is malformed or unsafe."""


_IDENTIFIER = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$")
_INTEGER = re.compile(r"^[0-9]+$")


@dataclass(frozen=True)
class ClusterConfig:
    name: str
    partition: str
    toolchain: Path
    mp_profile: str
    mps_mapping_root: Path
    disable_nccl_ib: bool


@dataclass(frozen=True)
class CoordinatorConfig:
    poll_seconds: int
    queue_failure_limit: int
    accounting_attempts: int


@dataclass(frozen=True)
class ResourceProfile:
    qos: str
    nodes: int
    tasks_per_node: int
    gpus_per_node: int
    time_seconds: int
    parallelism: Optional[int] = None

    @property
    def total_tasks(self) -> int:
        return self.nodes * self.tasks_per_node


@dataclass(frozen=True)
class CaseSpec:
    suite: str
    name: str
    resource: str
    runner: str

    @property
    def case_id(self) -> str:
        return f"{self.suite}/{self.name}"


@dataclass(frozen=True)
class SaiConfig:
    cluster: ClusterConfig
    coordinator: CoordinatorConfig
    build: ResourceProfile
    resources: Mapping[str, ResourceProfile]
    cases: Tuple[CaseSpec, ...]


_SCHEMA = {
    "cluster": ("name", "partition", "toolchain", "mp_profile", "mps_mapping_root", "disable_nccl_ib"),
    "coordinator": ("poll_seconds", "queue_failure_limit", "accounting_attempts"),
    "build": ("qos", "nodes", "tasks_per_node", "gpus_per_node", "time_seconds"),
}
_RESOURCE_KEYS = ("qos", "nodes", "tasks_per_node", "gpus_per_node", "time_seconds", "parallelism")
_CASE_KEYS = ("suite", "name", "resource", "runner")


def _error(message: str) -> ConfigError:
    return ConfigError(message)


def _identifier(value: str, field: str) -> str:
    if not _IDENTIFIER.fullmatch(value):
        raise _error(f"invalid {field}: {value!r}")
    return value


def _integer(value: str, field: str, low: int, high: int) -> int:
    if not _INTEGER.fullmatch(value):
        raise _error(f"invalid integer for {field}: {value!r}")
    result = int(value)
    if not low <= result <= high:
        raise _error(f"{field} out of bounds: {result}")
    return result


def _boolean(value: str, field: str) -> bool:
    if value == "true":
        return True
    if value == "false":
        return False
    raise _error(f"invalid boolean for {field}: {value!r}")


def _read_parser(path: Path) -> configparser.ConfigParser:
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise _error(f"cannot read configuration: {path}") from exc
    # Reject continuation lines, empty values, and interpolation markers before
    # ConfigParser can normalize them away.
    for number, line in enumerate(raw.splitlines(), 1):
        if line.startswith((" ", "\t")) and line.strip() and not line.lstrip().startswith(("#", ";")):
            raise _error(f"multiline/indented value at line {number}")
        if not line.strip() or line.lstrip().startswith(("#", ";")) or line.lstrip().startswith("["):
            continue
        if "=" not in line:
            raise _error(f"malformed line {number}")
        value = line.split("=", 1)[1].strip()
        if not value:
            raise _error(f"empty value at line {number}")
        if "%" in value:
            raise _error(f"interpolation is forbidden at line {number}")
    for number, line in enumerate(raw.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]") and stripped[1:-1].strip().upper() == "DEFAULT":
            raise _error(f"DEFAULT section is forbidden at line {number}")
    parser = configparser.ConfigParser(
        interpolation=None, strict=True, empty_lines_in_values=False,
        allow_no_value=False, delimiters=("=",), comment_prefixes=("#", ";"),
    )
    try:
        parser.read_string(raw, source=str(path))
    except (configparser.Error, ValueError) as exc:
        raise _error(f"invalid configuration: {exc}") from exc
    if parser.defaults():
        raise _error("DEFAULT section is forbidden")
    return parser


def _resolve_toolchain(root: Optional[Path], relative: str) -> Path:
    path = Path(relative)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise _error("toolchain must be a safe relative path")
    if root is None:
        return path
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise _error("control_root must be a regular directory")
    try:
        resolved_root = root.resolve(strict=True)
        candidate = root / path
        if candidate.is_symlink() or not candidate.is_file():
            raise _error("toolchain is missing or symlinked")
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(resolved_root)
    except (OSError, ValueError) as exc:
        if isinstance(exc, ConfigError):
            raise
        raise _error("toolchain is outside control_root") from exc
    return resolved


def _resource(section: str, values: Mapping[str, str], include_parallelism: bool) -> ResourceProfile:
    expected = _RESOURCE_KEYS if include_parallelism else _RESOURCE_KEYS[:-1]
    if set(values) != set(expected):
        raise _error(f"invalid keys in [{section}]")
    qos = _identifier(values["qos"], f"{section}.qos")
    nodes = _integer(values["nodes"], f"{section}.nodes", 1, 2)
    tasks = _integer(values["tasks_per_node"], f"{section}.tasks_per_node", 1, 8)
    gpus = _integer(values["gpus_per_node"], f"{section}.gpus_per_node", 1, 8)
    seconds = _integer(values["time_seconds"], f"{section}.time_seconds", 1, 3600)
    parallelism = _integer(values["parallelism"], f"{section}.parallelism", 1, 16) if include_parallelism else None
    if tasks != gpus:
        raise _error(f"{section}: tasks_per_node must equal gpus_per_node")
    profile = ResourceProfile(qos, nodes, tasks, gpus, seconds, parallelism)
    if profile.total_tasks > 16:
        raise _error(f"{section}: total tasks exceed 16")
    return profile


def load_config(path: Path, control_root: Optional[Path] = None) -> SaiConfig:
    parser = _read_parser(Path(path))
    expected_sections = set(_SCHEMA) | {f"resource.{name}" for name in ("gpu1", "gpu2", "gpu4", "gpu8x2")} | {f"case.{i:03d}" for i in range(1, 50)}
    actual_sections = set(parser.sections())
    if actual_sections != expected_sections:
        missing = sorted(expected_sections - actual_sections)
        unknown = sorted(actual_sections - expected_sections)
        raise _error(f"section mismatch; missing={missing}, unknown={unknown}")
    for section, keys in _SCHEMA.items():
        if set(parser[section]) != set(keys):
            raise _error(f"invalid keys in [{section}]")
    cluster = ClusterConfig(
        _identifier(parser["cluster"]["name"], "cluster.name"),
        _identifier(parser["cluster"]["partition"], "cluster.partition"),
        _resolve_toolchain(control_root, parser["cluster"]["toolchain"]),
        _identifier(parser["cluster"]["mp_profile"], "cluster.mp_profile"),
        _normalized_absolute(parser["cluster"]["mps_mapping_root"], "cluster.mps_mapping_root"),
        _boolean(parser["cluster"]["disable_nccl_ib"], "cluster.disable_nccl_ib"),
    )
    coordinator = CoordinatorConfig(
        _integer(parser["coordinator"]["poll_seconds"], "coordinator.poll_seconds", 1, 300),
        _integer(parser["coordinator"]["queue_failure_limit"], "coordinator.queue_failure_limit", 1, 10),
        _integer(parser["coordinator"]["accounting_attempts"], "coordinator.accounting_attempts", 1, 60),
    )
    build = _resource("build", parser["build"], False)
    resources_data = OrderedDict()
    for name in ("gpu1", "gpu2", "gpu4", "gpu8x2"):
        resources_data[name] = _resource(f"resource.{name}", parser[f"resource.{name}"], True)
    cases = []
    for index in range(1, 50):
        section = parser[f"case.{index:03d}"]
        if set(section) != set(_CASE_KEYS):
            raise _error(f"invalid keys in [case.{index:03d}]")
        suite = _identifier(section["suite"], f"case.{index:03d}.suite")
        name = _identifier(section["name"], f"case.{index:03d}.name")
        resource = _identifier(section["resource"], f"case.{index:03d}.resource")
        runner = _identifier(section["runner"], f"case.{index:03d}.runner")
        if resource not in resources_data or runner not in ("autotest", "cusolvermp"):
            raise _error(f"invalid case resource/runner in case.{index:03d}")
        case = CaseSpec(suite, name, resource, runner)
        cases.append(case)
    if len({case.case_id for case in cases}) != 49:
        raise _error("duplicate case identity")
    distribution = {name: sum(case.resource == name for case in cases) for name in resources_data}
    if distribution != {"gpu1": 1, "gpu2": 7, "gpu4": 40, "gpu8x2": 1}:
        raise _error("unexpected case resource distribution")
    smoke = [case for case in cases if case.runner == "cusolvermp"]
    if len(smoke) != 1 or smoke[0].case_id != \
            "15_rtTDDFT_GPU/19_NO_Si48_CUSOLVERMP_TDDFT_GPU" or smoke[0].resource != "gpu8x2":
        raise _error("unexpected cuSolverMp smoke assignment")
    return SaiConfig(cluster, coordinator, build, MappingProxyType(resources_data), tuple(cases))


def _normalized_absolute(value: str, field: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise _error(f"{field} must be absolute")
    return Path(os.path.normpath(str(path)))
