"""Audit production C++14 separately from GoogleTest's C++17 requirement.

The original verify-build.py and logs/build-audit.* are retained unchanged.
Every C++17 command must include GoogleTest, and no such object may be linked
into the production executable. This audit changes no numerical checks.
"""
from pathlib import Path
from collections import Counter
import hashlib
import json
import re
import shlex
import subprocess

root = Path(__file__).resolve().parent
report = {'compilation': {}, 'links': {}}
for name, standard in (('ddla-consumer', 11), ('consumer-cpu', 14),
                       ('consumer-gpu', 14), ('libri14', 14), ('abacus', 14), ('debug', 14)):
    build = root / 'build' / name
    commands = json.loads((build / 'compile_commands.json').read_text())
    standards = Counter()
    google_test = Counter()
    object_standards = {}
    for entry in commands:
        command = entry['command']
        actual = re.findall(r'-std=(?:gnu|c)\+\+(\d+)', command)
        assert len(actual) == 1, (name, entry)
        assert not re.search(r'-D(?:DDLA_USE_CUDA|DDLA_USE_HIP|DDLA_USE_CPU)(?:[ =]|$)', command), entry
        tokens = shlex.split(command)
        output = (Path(entry['directory']) / tokens[tokens.index('-o') + 1]).resolve()
        object_standards[output] = actual[0]
        if name in ('abacus', 'debug') and '/googletest' in command:
            assert actual[0] == '17', (name, entry)
            google_test[actual[0]] += 1
        else:
            assert actual == [str(standard)], (name, entry)
            standards[actual[0]] += 1
    row = {'generated_commands': len(commands),
           'without_googletest': dict(standards),
           'with_googletest': dict(google_test),
           'private_backend_macros': []}
    if name in ('abacus', 'debug'):
        link_text = (build / 'source/CMakeFiles/abacus_std_gpu.dir/link.txt').read_text()
        link_tokens = shlex.split(link_text)
        expanded = []
        for token in link_tokens:
            if token.startswith('@'):
                expanded.extend(shlex.split((build / 'source' / token[1:]).read_text()))
            else:
                expanded.append(token)
        objects = [(build / 'source' / token).resolve()
                   for token in expanded if token.endswith('.o')]
        assert objects and all(object_standards.get(obj) == '14' for obj in objects), name
        assert 'gtest' not in link_text and 'gmock' not in link_text, name
        row['main_executable_link_objects'] = len(objects)
        row['main_executable_object_standard'] = '14'
        row['main_executable_objects_built'] = sum(obj.is_file() for obj in objects)
        if name == 'abacus':
            assert all(obj.is_file() for obj in objects), name
    report['compilation'][name] = row

for name in ('build/abacus/abacus_std_gpu', 'build/libri14/test_lri_gpu_symmetry',
             'build/debug/source/source_lcao/module_ri/unittests/MODULE_RI_exx_workspace'):
    path = root / name
    output = subprocess.check_output(['ldd', str(path)], text=True)
    lines = [line.strip() for line in output.splitlines() if 'libddla' in line]
    assert 'not found' not in output, (name, output)
    assert len(lines) == 1 and str(root / 'install/ddla/lib') in lines[0], (name, lines)
    report['links'][name] = {'ddla': lines[0], 'binary_sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
report['ddla_sha256'] = hashlib.sha256((root / 'install/ddla/lib/libddla.so').read_bytes()).hexdigest()
report['audit_correction'] = 'The first audit required C++14 for GoogleTest targets; GoogleTest publicly requires C++17. Original failure retained in logs/build-audit.*.'
report['passed'] = True
(root / 'logs/build-audit-final.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
