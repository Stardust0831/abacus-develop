#!/usr/bin/env python3
"""ABACUS SAI CI command line interface."""

import argparse
import json
import sys
from pathlib import Path


MINIMUM_PYTHON = (3, 8)
PROTOCOL_VERSION = 1


def _validate_config(args: argparse.Namespace) -> int:
    from sai_ci.config import load_config

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
    from sai_ci.report import publish_github

    publish_github(args.result, args.github_output, args.github_summary)
    return 0


def build_parser() -> argparse.ArgumentParser:
    from sai_ci import local, remote, source

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

    remote_parser = commands.add_parser("remote", help="run inside a prepared SAI directory")
    remote_commands = remote_parser.add_subparsers(dest="remote_command", required=True)
    remote_run = remote_commands.add_parser("run", help="build and execute the GPU matrix")
    remote.configure_parser(remote_run)

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
    report_github.set_defaults(handler=_publish_result)
    return parser


def main() -> int:
    if sys.version_info < MINIMUM_PYTHON:
        print("SAI CI requires Python 3.8 or newer", file=sys.stderr)
        return 2
    parser = build_parser()
    args = parser.parse_args()
    control_root = Path(__file__).resolve().parent
    try:
        if args.command in ("local", "remote"):
            return int(args.handler(args, control_root))
        return int(args.handler(args))
    except (OSError, RuntimeError, ValueError) as error:
        print("sai: {}".format(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
