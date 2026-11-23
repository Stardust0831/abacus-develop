#!/usr/bin/env python3
"""Recalculate comparisons from raw text with Decimal, and audit input provenance."""
from pathlib import Path
from decimal import Decimal
import json
import re

root = Path(__file__).resolve().parent
evidence = root / 'evidence'
driver = json.loads((evidence / 'e2e-results.json').read_text())
cases = {}
provenance = []
symmetry = {}

def matrix_rows(lines, count, atom_labels=False):
    rows = []
    for line in lines:
        fields = line.split()
        if atom_labels:
            if len(fields) != 4 or not re.fullmatch(r'[A-Za-z]+[0-9]+', fields[0]):
                continue
            fields = fields[1:]
        elif len(fields) != 3:
            continue
        try:
            values = [Decimal(x) for x in fields]
        except Exception:
            continue
        assert all(x.is_finite() for x in values)
        rows.extend(values)
        if len(rows) == count:
            return rows
    raise ValueError('Incomplete raw force/stress array')

for key in driver['runs']:
    name, backend = key.split('/')
    case = evidence / 'runs' / backend / '08_RI' / name
    text = (case / 'OUT.autotest/running_scf.log').read_text()
    assert '#SCF IS CONVERGED#' in text and 'Total  Time' in text
    energy = Decimal(next(x.split()[1] for x in text.splitlines() if '!FINAL_ETOT_IS' in x))
    force_lines = text.split('#TOTAL-FORCE (eV/Angstrom)#')[-1].splitlines()
    stress_lines = text.split('#TOTAL-STRESS (kbar)#')[-1].splitlines()
    cases[key] = {'energy_ev': [energy],
                  'force_ev_angstrom': matrix_rows(force_lines, 6 if name.startswith('si2') else 9, True),
                  'stress_kbar': matrix_rows(stress_lines, 9)}
    original = root / 'abacus/tests/08_RI' / (
        'scf_hse_symm_multik' if name.startswith('si2') else
        'scf_hse_spin2_gamma' if name == 'hse_spin2' else 'scf_hse_gamma')
    for filename in ('result.ref', 'threshold', 'KPT'):
        src, got = original / filename, case / filename
        assert src.exists() == got.exists(), (key, filename)
        if src.exists():
            assert src.read_bytes() == got.read_bytes(), (key, filename)
    expected_structure = (original / 'STRU').read_text()
    if 'displaced' in name:
        expected_structure = expected_structure.replace(
            '0.125\t0.125\t0.125\t1 1 1', '0.135\t0.125\t0.125\t1 1 1')
        assert max(abs(x) for x in cases[key]['force_ev_angstrom']) > Decimal('1e-5')
    assert (case / 'STRU').read_text() == expected_structure, key
    provenance.append(key)
    if name.startswith('si2'):
        ops = int(re.search(r'SPACE GROUP OPERATIONS\s*=\s*(\d+)', text)[1])
        nk = int(re.search(r'Number of irreducible k-points\s*=\s*(\d+)', text)[1])
        sectors = (case / 'OUT.autotest/irreducible_sector.txt').read_text().splitlines()
        assert ops == (4 if 'displaced' in name else 48)
        assert nk == (6 if 'displaced' in name else 3)
        assert len(sectors) == (22 if 'displaced' in name else 12)
        symmetry[key] = {'space_group_operations': ops, 'irreducible_kpoints': nk,
                         'irreducible_pair_cell_entries': len(sectors)}

rows = []
for comparison in driver['comparisons']:
    a, b = (cases[comparison[k]] for k in ('a', 'b'))
    deltas = {k: max(abs(x-y) for x,y in zip(a[k], b[k])) for k in a}
    passed = all(deltas[k] <= Decimal(str(driver['limits'][k])) for k in deltas)
    assert passed == comparison['passed']
    rows.append({'kind': comparison['kind'], 'a': comparison['a'], 'b': comparison['b'],
                 'passed': passed, 'max_deltas': {k:str(v) for k,v in deltas.items()}})
maxima = {}
for kind in sorted({x['kind'] for x in rows}):
    selected = [x for x in rows if x['kind']==kind]
    maxima[kind] = {k:str(max(Decimal(x['max_deltas'][k]) for x in selected))
                    for k in driver['limits']}
assert len(cases) == 20 and len(rows) == 18 and all(x['passed'] for x in rows)
report = {'passed':True, 'raw_runs_parsed':len(cases), 'comparisons_recomputed':len(rows),
          'unchanged_references_thresholds_kpoints_and_expected_structures':provenance,
          'raw_decimal_maxima':maxima, 'symmetry':symmetry, 'comparisons':rows,
          'precision_note':'Differences use printed raw values; forces and stresses are printed to 10 decimal places.'}
(root / 'independent-audit.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:report[k] for k in ('passed','raw_runs_parsed','comparisons_recomputed','raw_decimal_maxima')},indent=2))
