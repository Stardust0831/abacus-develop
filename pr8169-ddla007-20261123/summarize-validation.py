from pathlib import Path
from decimal import Decimal
import json
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent
evidence = root / 'evidence'
baseline = root.parent / 'pr8169-maintenance-20261123/evidence'
e2e = json.loads((evidence / 'e2e-results.json').read_text())
old_e2e = json.loads((baseline / 'e2e-results.json').read_text())
cli = json.loads((evidence / 'cli-results.json').read_text())
audit = json.loads((evidence / 'logs/build-audit-final.json').read_text())
independent = json.loads((root / 'independent-audit.json').read_text())
exits = {p.name: int(p.read_text()) for p in (evidence / 'logs').glob('*.exit')}
required = ('ddla-build', 'ddla-install', 'ddla-consumer-test', 'consumer-cpu-test',
            'consumer-gpu-test', 'libri14-numerical', 'gpu-build', 'gpu-tests',
            'debug-build', 'debug-tests', 'build-audit-final', 'e2e', 'cli')
assert all(exits.get(name + '.exit') == 0 for name in required), exits
assert exits['baseline-consumer-configure.exit'] == 1, exits
assert exits['build-audit.exit'] == 1, exits
assert "AssertionError: ('abacus', {'17', '14'})" in (evidence / 'logs/build-audit.log').read_text()
assert all(value == 0 for name, value in exits.items()
           if name not in ('baseline-consumer-configure.exit', 'build-audit.exit')), exits
assert e2e['passed'] and cli['passed'] and audit['passed'] and independent['passed']
assert len(cli['cases']) == 8 and all(x['success_message'] for x in cli['cases'])
text = (evidence / 'logs/libri14-numerical.log').read_text().splitlines()
numerical = {'checks': sum(x.startswith('CHECK ') for x in text),
             'passes': sum(x.startswith('PASS ') for x in text)}
assert numerical == {'checks': 456, 'passes': 38}, numerical
units = {}
for variant, total, files in (('gpu', 52, 3), ('debug', 2, 1)):
    entries = []
    for path in sorted((evidence / 'logs' / (variant + '-xml')).glob('*.xml')):
        node = ET.parse(path).getroot()
        entries.append({'file': path.name, **{k: int(node.attrib.get(k, 0)) for k in
                       ('tests', 'failures', 'errors', 'skipped', 'disabled')}})
    assert len(entries) == files and sum(x['tests'] for x in entries) == total
    assert all(x[k] == 0 for x in entries for k in ('failures', 'errors', 'skipped', 'disabled'))
    units[variant] = entries

def raw_values(path):
    text = path.read_text()
    energy = Decimal(next(x.split()[1] for x in text.splitlines() if '!FINAL_ETOT_IS' in x))
    force = []
    for line in text.split('#TOTAL-FORCE (eV/Angstrom)#')[-1].splitlines():
        fields = line.split()
        if len(fields) == 4 and re.fullmatch(r'[A-Za-z]+[0-9]+', fields[0]):
            force.extend(Decimal(x) for x in fields[1:])
    stress = []
    for line in text.split('#TOTAL-STRESS (kbar)#')[-1].splitlines():
        fields = line.split()
        if len(fields) != 3:
            continue
        try:
            row = [Decimal(x) for x in fields]
        except Exception:
            continue
        stress.extend(row)
        if len(stress) == 9:
            break
    assert force and len(stress) == 9
    return {'energy_ev': [energy], 'force_ev_angstrom': force, 'stress_kbar': stress}

assert set(e2e['runs']) == set(old_e2e['runs']) and len(e2e['runs']) == 20
comparisons = []
for key in sorted(e2e['runs']):
    case, backend = key.split('/')
    relative = Path('runs') / backend / '08_RI' / case
    old, new = baseline / relative, evidence / relative
    for filename in ('INPUT', 'STRU', 'KPT', 'result.ref', 'threshold'):
        a, b = old / filename, new / filename
        assert a.exists() == b.exists()
        if a.exists():
            assert a.read_bytes() == b.read_bytes(), (key, filename)
    a, b = (raw_values(path / 'OUT.autotest/running_scf.log') for path in (old, new))
    assert all(len(a[k]) == len(b[k]) for k in a)
    delta = {k: max(abs(x - y) for x, y in zip(a[k], b[k])) for k in a}
    passed = all(delta[k] <= Decimal(str(e2e['limits'][k])) for k in delta)
    assert passed, (key, delta)
    comparisons.append({'case': key, 'passed': passed, 'max_deltas': {k: str(v) for k, v in delta.items()}})
cross = {'passed': True, 'comparisons': comparisons,
         'maxima': {k: str(max(Decimal(row['max_deltas'][k]) for row in comparisons)) for k in e2e['limits']},
         'baseline': {'abacus': old_e2e['abacus_base'], 'ddla': '7c0ca08b4349a527cec2a0c0af7d1a1082bd38c7', 'cxx': 17},
         'candidate': {'abacus_base': e2e['abacus_base'], 'patch': e2e['abacus_test_patch'],
                       'ddla': e2e['ddla_head'], 'cxx': 14}}
(root / 'cross-version-comparison.json').write_text(json.dumps(cross, indent=2) + '\n')
summary = {'passed': True, 'libri_numerical': numerical, 'unit_tests': units, 'cli_cases': 8,
           'scf_runs': 20, 'cpu_gpu_and_symmetry_comparisons': 18, 'cross_version_comparisons': 20,
           'all_exit_codes': exits, 'compilation_audit': audit,
           'numerical_maxima': independent['raw_decimal_maxima'],
           'cross_version_maxima': cross['maxima'],
           'expected_baseline_failure': 'Existing ABACUS configuration tests DDLA_USE_CUDA, which v0.0.7 no longer exports.',
           'initial_audit_failure': audit['audit_correction']}
(root / 'validation-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps({k: summary[k] for k in ('passed', 'libri_numerical', 'scf_runs',
      'cpu_gpu_and_symmetry_comparisons', 'cross_version_comparisons', 'numerical_maxima', 'cross_version_maxima')}, indent=2))
