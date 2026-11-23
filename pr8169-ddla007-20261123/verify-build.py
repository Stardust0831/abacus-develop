from pathlib import Path
import hashlib
import json
import re
import subprocess

root = Path(__file__).resolve().parent
report = {'compilation': {}, 'links': {}}
for name, standard in (('ddla-consumer', 11), ('consumer-cpu', 14),
                       ('consumer-gpu', 14), ('libri14', 14), ('abacus', 14), ('debug', 14)):
    commands = json.loads((root / 'build' / name / 'compile_commands.json').read_text())
    actual = set()
    private_definitions = []
    for entry in commands:
        text = entry['command']
        actual.update(re.findall(r'-std=(?:gnu|c)\+\+(\d+)', text))
        if re.search(r'-D(?:DDLA_USE_CUDA|DDLA_USE_HIP|DDLA_USE_CPU)(?:[ =]|$)', text):
            private_definitions.append(entry['file'])
    assert actual == {str(standard)}, (name, actual)
    assert not private_definitions, (name, private_definitions)
    report['compilation'][name] = {'entries': len(commands), 'standards': sorted(actual),
                                   'private_backend_macros': private_definitions}
for name in ('build/abacus/abacus_std_gpu', 'build/libri14/test_lri_gpu_symmetry',
             'build/debug/source/source_lcao/module_ri/unittests/MODULE_RI_exx_workspace'):
    path = root / name
    text = subprocess.check_output(['ldd', str(path)], text=True)
    lines = [line.strip() for line in text.splitlines() if 'libddla' in line]
    assert len(lines) == 1 and str(root / 'install/ddla/lib') in lines[0], (name, lines)
    report['links'][name] = {'ddla': lines[0], 'binary_sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
report['ddla_sha256'] = hashlib.sha256((root / 'install/ddla/lib/libddla.so').read_bytes()).hexdigest()
report['passed'] = True
(root / 'logs/build-audit.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
