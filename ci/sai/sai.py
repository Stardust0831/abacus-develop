#!/usr/bin/env python3
"""ABACUS SAI CI command line interface."""

import argparse
import json
import sys
from pathlib import Path


MINIMUM_PYTHON = (3, 8)
PROTOCOL_VERSION = 1


def _validate_config(args: argparse.Namespace) -> int:
    from config import load_config

    config = load_config(args.file, args.control_root)
    print(
        json.dumps(
            {
                "cluster": config.cluster.name,
                "partition": config.cluster.partition,
                "resources": list(config.resources),
                "cases": len(config.cases),
            },
            separators=(",", ":"),
        )
    )
    return 0


def _publish_result(args: argparse.Namespace) -> int:
    from report import publish_github

    publish_github(args.result, args.github_output, args.github_summary, args.config)
    return 0


def build_parser() -> argparse.ArgumentParser:
    import cache
    import github
    import local
    import remote
    import source
    import worker

    parser = argparse.ArgumentParser(
        description="Run and report ABACUS GPU validation on SAI."
    )
    parser.add_argument(
        "--version", action="version", version="SAI CI protocol {}".format(PROTOCOL_VERSION)
    )
    commands = parser.add_subparsers(dest="command", required=True)

    local_parser = commands.add_parser("local", help="run from a developer workstation")
    local.configure_parser(local_parser)

    source_parser = commands.add_parser("source", help="build a Git source payload")
    source.configure_parser(source_parser)

    remote_parser = commands.add_parser("remote", help="operate inside a prepared SAI directory")
    remote_commands = remote_parser.add_subparsers(dest="remote_command", required=True)
    remote_run = remote_commands.add_parser("run", help="build and execute the GPU matrix")
    remote.configure_parser(remote_run)
    remote_collect = remote_commands.add_parser("collect", help="stream a validated artifact archive")
    remote_collect.add_argument("run_root", type=Path)
    remote_collect.set_defaults(handler=lambda args: remote.collect_artifacts(args.run_root, sys.stdout.buffer) or 0)
    remote_archive = remote_commands.add_parser("archive", help="archive an uploaded run")
    remote_archive.add_argument("run_root", type=Path)
    remote_archive.set_defaults(handler=lambda args: print(remote.archive_run(args.run_root)) or 0)
    remote_cleanup = remote_commands.add_parser("cleanup", help="remove expired run archives")
    remote_cleanup.add_argument("project_root", type=Path)
    remote_cleanup.set_defaults(handler=lambda args: print("REMOVED_ARCHIVES={}".format(remote.cleanup_archives(args.project_root))) or 0)

    config_parser = commands.add_parser("config", help="validate trusted CI configuration")
    config_commands = config_parser.add_subparsers(dest="config_command", required=True)
    config_validate = config_commands.add_parser("validate", help="validate an INI file")
    config_validate.add_argument("--file", required=True, type=Path)
    config_validate.add_argument("--control-root", type=Path)
    config_validate.set_defaults(handler=_validate_config)

    report_parser = commands.add_parser("report", help="publish a structured result")
    report_commands = report_parser.add_subparsers(dest="report_command", required=True)
    report_github = report_commands.add_parser("github", help="write GitHub outputs and summary")
    report_github.add_argument("--result", required=True, type=Path)
    report_github.add_argument("--github-output", required=True, type=Path)
    report_github.add_argument("--github-summary", required=True, type=Path)
    report_github.add_argument(
        "--config", type=Path,
        default=Path(__file__).resolve().parent / "gpu-matrix.ini",
    )
    report_github.set_defaults(handler=_publish_result)

    worker_parser = commands.add_parser("worker", help="run a fixed compute-node helper")
    worker_commands = worker_parser.add_subparsers(dest="worker_command", required=True)
    worker.configure_parser(worker_commands)

    cache_parser = commands.add_parser("cache", help="manage validated remote source snapshots")
    cache.configure_parser(cache_parser)

    github_parser = commands.add_parser("github", help="authorize a GitHub SAI request")
    github_commands = github_parser.add_subparsers(dest="github_command", required=True)
    github_authorize = github_commands.add_parser("authorize", help="resolve the trusted candidate SHA")
    github.configure_parser(github_authorize)
    github_start = github_commands.add_parser("start-check", help="mark a requested PR check in progress")
    github_start.set_defaults(handler=lambda _args: github.start_check() or 0)
    github_complete = github_commands.add_parser("complete-check", help="complete a requested PR check")
    github_complete.set_defaults(handler=lambda _args: github.complete_check() or 0)
    github_ssh = github_commands.add_parser("configure-ssh", help="write a temporary OpenSSH config")
    github_ssh.add_argument("output_dir", type=Path)
    github_ssh.add_argument("known_hosts", type=Path)
    github_ssh.set_defaults(handler=lambda args: github.configure_ssh(
        args.output_dir, args.known_hosts,
    ) and 0)
    return parser


def main() -> int:
    if sys.version_info < MINIMUM_PYTHON:
        print("SAI CI requires Python 3.8 or newer", file=sys.stderr)
        return 2
    parser = build_parser()
    args = parser.parse_args()
    control_root = Path(__file__).resolve().parent
    try:
        if args.command == "local" or (
            args.command == "remote" and args.remote_command == "run"
        ):
            return int(args.handler(args, control_root))
        return int(args.handler(args))
    except (OSError, RuntimeError, ValueError) as error:
        print("sai: {}".format(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
