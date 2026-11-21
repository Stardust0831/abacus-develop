#!/usr/bin/env python3
"""Check captured build evidence and extract the original unresolved symbols."""
import csv
import hashlib
import json
from pathlib import Path
import re
import shlex

root = Path(__file__).resolve().parent.parent
logs = root / 'remote-results/logs'
repo = root.parents[1] / 'abacus-libri-pr-ready-20261121/abacus'
statuses = list(csv.DictReader((logs / 'status.tsv').open(), delimiter='\t'))
results = {row['step']: int(row['exit_code']) for row in statuses}
expected_steps = [
    'gpu-before-configure', 'gpu-after-configure', 'gpu-after-build', 'gpu-after-test',
    'cpu-configure', 'cpu-build', 'cpu-test',
    'consumer-cpu-configure', 'consumer-cpu-build', 'consumer-cpu-test',
    'consumer-gpu-configure', 'consumer-gpu-build', 'consumer-gpu-test',
]
assert all(results[s] == 0 for s in expected_steps)
assert results['gpu-before-build'] != 0
symbols = sorted(set(re.findall(r"undefined reference to `(.+)'", (logs / 'gpu-before-build.log').read_text())))
assert symbols and all('ddla::' in s for s in symbols)
(root / 'logs/original-unresolved-symbols.txt').write_text('\n'.join(symbols) + '\n')
source_verified = {}
for line in (logs / 'compiled-source.sha256').read_text().splitlines():
    expected, relative = line.split(None, 1)
    relative = relative.removeprefix('abacus/')
    actual = hashlib.sha256((repo / relative).read_bytes()).hexdigest()
    assert actual == expected, relative
    source_verified[relative] = actual
input_hashes = dict(line.split(None, 1)[::-1] for line in (logs / 'run-inputs.sha256').read_text().splitlines())
assert input_hashes['provenance/abacus-head.tar.gz'] == hashlib.sha256((root / 'provenance/abacus-head.tar.gz').read_bytes()).hexdigest()
assert input_hashes['scripts/validate-debug.sbatch'] == hashlib.sha256((root / 'scripts/validate-debug.sbatch').read_bytes()).hexdigest()

def cxx_flags(variant):
    text = (logs / f'{variant}-flags.make').read_text()
    flags = next(line.split(' = ', 1)[1] for line in text.splitlines() if line.startswith('CXX_FLAGS = '))
    return text, shlex.split(flags)

for variant in ('gpu-before', 'gpu-after', 'cpu'):
    text, flags = cxx_flags(variant)
    assert '-g' in flags and not any(f.startswith('-O') and f != '-O0' for f in flags)
    if variant.startswith('gpu'):
        assert all(m in text for m in ('-D__GPU_RI', '-D__DDLA_RI', '-DDDLA_USE_CUDA'))
    else:
        assert all(m not in text for m in ('-D__GPU_RI', '-D__DDLA_RI', '-DDDLA_USE_CUDA'))
assert 'libddla' not in (logs / 'gpu-before-link.txt').read_text()
assert 'libddla.so' in (logs / 'gpu-after-link.txt').read_text()
assert 'libddla.so' in (logs / 'gpu-after-ldd.log').read_text()
assert 'libddla' not in (logs / 'cpu-link.txt').read_text()
assert 'libddla' not in (logs / 'cpu-ldd.log').read_text()
for variant in ('cpu', 'gpu'):
    text = (logs / f'consumer-{variant}-CTestTestfile.cmake').read_text()
    assert len(re.findall(r'^add_test\(', text, flags=re.M)) == 1
    assert 'libri_gpu_accumulation' not in text
assert not (repo / 'tests/lcao_hse_gpu/cmake/test_libri_gpu_accumulation.cpp').exists()
summary = {
    'passed': True,
    'job_id': '2672287',
    'original_build_exit_code': results['gpu-before-build'],
    'original_unresolved_symbol_count': len(symbols),
    'all_original_unresolved_symbols_are_ddla': True,
    'debug_flags_verified': ['gpu-before', 'gpu-after', 'cpu'],
    'post_fix_ctest_results': {s: results[s] for s in expected_steps if s.endswith('-test')},
    'consumer_registered_tests': {'cpu': 1, 'gpu': 1},
    'compiled_source_matches_shared_checkout': source_verified,
    'input_archive_and_script_hashes_match': True,
}
(root / 'provenance/evidence-audit.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
