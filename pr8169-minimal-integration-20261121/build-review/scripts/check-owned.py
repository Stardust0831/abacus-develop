#!/usr/bin/env python3
"""Run the repository governance rules against only this worker's working diff.

The repository CLI requires staged or two-commit input. This adapter supplies
working-tree diff/file readers without writing the shared index or committing.
All governance checks are the unchanged repository implementation.
"""
import argparse
import importlib.util
import pathlib
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('repository', type=pathlib.Path)
parser.add_argument('--base', default='HEAD')
args = parser.parse_args()
root = args.repository.resolve()
owned = [
    'source/source_lcao/module_ri/unittests/CMakeLists.txt',
    'tests/lcao_hse_gpu/cmake/CMakeLists.txt',
    'tests/lcao_hse_gpu/cmake/test_libri_gpu_accumulation.cpp',
    'docs/advanced/install.md',
]
spec = importlib.util.spec_from_file_location(
    'abacus_governance', root / 'tools/03_code_analysis/agent_governance_check.py')
governance = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = governance
spec.loader.exec_module(governance)

def diff(*options):
    return subprocess.check_output(
        ['git', 'diff', *options, args.base, '--', *owned], cwd=root, text=True)

statuses = governance.parse_name_status(diff('--name-status'))
lines = governance.parse_changed_lines(diff('--ignore-cr-at-eol', '-U0'))
governance.changed_paths = lambda _root, _args: statuses
governance.changed_lines = lambda _root, _args: lines
check_args = argparse.Namespace(staged=False, base=None, head=None, event_path=None)
findings = governance.collect_findings(root, check_args)
print(f'Owned working-tree diff against {args.base}; {len(statuses[1])} changed files')
print(governance.render_text(findings))
raise SystemExit(1 if any(f.severity == 'error' for f in findings) else 0)
