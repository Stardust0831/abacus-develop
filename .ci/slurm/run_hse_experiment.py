#!/usr/bin/env python3
"""Run the fork-only HSE matrix using the existing Slurm client."""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--source-repository', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    control = args.artifacts.resolve() / 'control'
    if control.exists():
        parser.error('Use a fresh artifacts directory for each attempt')
    shutil.copytree(root, control, ignore=shutil.ignore_patterns('__pycache__'))
    shutil.copyfile(root / 'hse-config.ini', control / 'config.ini')
    # Compute nodes cannot reach codeload. Stage exactly the dependencies and
    # checksums maintained by ABACUS's existing toolchain, without site paths.
    versions = (root.parent.parent / 'toolchain/scripts/package_versions.sh').read_text()
    for package, repository in [('libri', 'abacusmodeling/LibRI'),
                                ('libcomm', 'abacusmodeling/LibComm'),
                                ('cereal', 'USCiLab/cereal')]:
        version = re.search(r'^' + package + r'_ver="([^"]+)"', versions, re.M).group(1)
        digest = re.search(r'^' + package + r'_sha256="([^"]+)"', versions, re.M).group(1)
        archive = control / (package + '.tar.gz')
        url = 'https://codeload.github.com/%s/tar.gz/%s' % (repository, version)
        subprocess.run(['curl', '-fLsS', '--max-time', '60', '--retry', '2', url, '-o', str(archive)], check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise RuntimeError('Toolchain checksum mismatch: ' + package)
    template = control / 'build.sbatch.in'
    bootstrap = (root / 'hse-deps.sh.in').read_text()
    text = template.read_text().replace('cmake -S @SOURCE@', bootstrap + '\ncmake -S @SOURCE@')
    text = text.replace('-DENABLE_LIBXC=ON', '''-DENABLE_LIBXC=ON -DENABLE_LIBRI=ON \\
    -DLIBRI_DIR=@BUILD@/hse-deps/libri \\
    -DLIBCOMM_DIR=@BUILD@/hse-deps/libcomm \\
    -Dcereal_DIR=@BUILD@/hse-deps/cereal-install/lib/cmake/cereal''')
    template.write_text(text)
    source = args.source_repository.resolve() if args.source_repository else root.parent.parent
    command = [sys.executable, str(control / 'runner.py'), 'run',
               '--target', args.target, '--run-id', args.run_id,
               '--namespace', 'hse-experiment',
               '--source-repository', str(source),
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
