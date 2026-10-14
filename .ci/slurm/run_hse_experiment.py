#!/usr/bin/env python3
"""Run the fork-only HSE matrix using the existing Slurm client."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--artifacts', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    control = args.artifacts.resolve() / 'control'
    if control.exists():
        parser.error('Use a fresh artifacts directory for each attempt')
    shutil.copytree(root, control, ignore=shutil.ignore_patterns('__pycache__'))
    shutil.copyfile(root / 'hse-config.ini', control / 'config.ini')
    command = [sys.executable, str(control / 'runner.py'), 'run',
               '--target', args.target, '--run-id', args.run_id,
               '--namespace', 'hse-experiment',
               '--source-repository', str(root.parent.parent),
               '--artifacts', str(args.artifacts.resolve())]
    with (args.artifacts / 'client.log').open('w') as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, bufsize=1)
        for line in process.stdout:
            print(line, end='', flush=True)
            log.write(line)
            log.flush()
        return process.wait()


if __name__ == '__main__':
    sys.exit(main())
