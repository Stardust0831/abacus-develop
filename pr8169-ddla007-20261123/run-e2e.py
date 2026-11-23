#!/usr/bin/env python3
"""Validate DDLA v0.0.7 with unchanged ABACUS reference checks and tolerances."""
from pathlib import Path
import hashlib
import json
import math
import re
import shutil
import subprocess
import time

root = Path(__file__).resolve().parent
repo = root / 'abacus'
binary = root / 'build/abacus/abacus_std_gpu'
number = r'[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?'
limits = {'energy_ev': 1e-7, 'force_ev_angstrom': 1e-6, 'stress_kbar': 1e-5}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse(path):
    text = (path / 'OUT.autotest/running_scf.log').read_text()
    energy = re.findall(r'!FINAL_ETOT_IS\s+(' + number + ')', text)
    if not energy or '#SCF IS CONVERGED#' not in text or 'Total  Time' not in text:
        raise ValueError('Missing final energy/convergence/normal completion')
    tail = text.rsplit('TOTAL-FORCE (eV/Angstrom)', 1)
    if len(tail) != 2:
        raise ValueError('Missing force block')
    forces = [float(x) for row in re.findall(
        r'^\s*[A-Za-z]+\d+\s+(' + number + r')\s+(' + number + r')\s+(' + number + r')\s*$',
        tail[1], re.M) for x in row]
    stress_tail = re.split(r'TOTAL-STRESS\s*\(kbar\)', text)[-1]
    stress_rows = re.findall(r'^\s*(' + number + r')\s+(' + number + r')\s+(' + number + r')\s*$',
                             stress_tail, re.M)[:3]
    stresses = [float(x) for row in stress_rows for x in row]
    if not forces or len(stresses) != 9:
        raise ValueError('Incomplete forces/stress')
    values = [float(energy[-1])] + forces + stresses
    if not all(math.isfinite(x) for x in values):
        raise ValueError('Non-finite energy/force/stress')
    inp = (path/'OUT.autotest/INPUT').read_text() if (path/'OUT.autotest/INPUT').exists() else ''
    input_info = path/'OUT.autotest/INPUT.info'
    if not input_info.exists():
        input_info = path/'INPUT.info'
    if input_info.exists():
        inp = input_info.read_text()
    settings = {}
    for line in inp.splitlines():
        fields = line.split()
        if len(fields) > 1 and fields[0] in ['device', 'device_exx', 'ks_solver', 'symmetry',
                                            'exx_real_number', 'exx_symmetry_realspace', 'nspin']:
            settings[fields[0]] = fields[1]
    requested = {}
    for line in (path/'INPUT').read_text().splitlines():
        fields = line.split()
        if len(fields) > 1 and fields[0] in ['device','device_exx','ks_solver','symmetry',
                                            'exx_real_number','exx_symmetry_realspace','nspin']:
            requested[fields[0]] = fields[1]
    for key, value in requested.items():
        if settings.get(key) != value:
            raise ValueError(f'Effective {key}={settings.get(key)} does not match requested {value}')
    expected_atoms = 2 if path.name.startswith('si2') else 3
    if len(forces) != 3*expected_atoms:
        raise ValueError('Wrong number of force components')
    symmetry_lines = [line.strip() for line in text.splitlines()
                      if any(k in line.lower() for k in ['point group', 'space group', 'symmetry operations',
                                                          'irreducible', 'nks_ibz'])]
    return {'energy_ev': values[0], 'forces_ev_angstrom': forces, 'stress_kbar': stresses,
            'effective_settings': settings, 'symmetry_lines': symmetry_lines,
            'input_sha256': digest(path/'INPUT'), 'structure_sha256': digest(path/'STRU')}


specs = [('hse_gamma', 'scf_hse_gamma', {}), ('hse_spin2', 'scf_hse_spin2_gamma', {})]
for real in (0, 1):
    for symmetry in (0, 1):
        specs.append((f'si2_real{real}_filter{symmetry}', 'scf_hse_symm_multik',
                      {'exx_real_number': str(real), 'exx_symmetry_realspace': str(symmetry)}))
report = {'libri_head': '589f6f8c6df3916575a1ba41e840de919d40d345',
          'abacus_base': 'fa1c75dcce0df12fe37267aed5ed2deef3fcaef0',
          'abacus_test_patch': 'ddla007-integration.patch', 'ddla_head': '0a65e570d3d3bc70e4d53a7e992b2de60abc884c', 'limits': limits,
          'binary_sha256': digest(binary), 'runs': {}, 'reference_checks': [], 'comparisons': []}


def save():
    (root/'e2e-results.json').write_text(json.dumps(report, indent=2)+'\n')


def prepare(case, source, overrides, displaced=False):
    shutil.copytree(repo/'tests/08_RI'/source, case)
    inp = case/'INPUT'
    lines = [line for line in inp.read_text().splitlines()
             if not line.split() or line.split()[0] not in overrides]
    lines.extend(f'{k} {v}' for k, v in overrides.items())
    inp.write_text('\n'.join(lines)+'\n')
    if displaced:
        p = case/'STRU'
        text = p.read_text()
        old = '0.125\t0.125\t0.125\t1 1 1'
        if text.count(old) != 1:
            raise ValueError('Displacement source atom not unique')
        p.write_text(text.replace(old, '0.135\t0.125\t0.125\t1 1 1'))
    return case


for backend in ('cpu', 'gpu'):
    group_root = root/'runs'/backend
    group = group_root/'08_RI'
    group.mkdir(parents=True, exist_ok=False)
    for name in ('PP_ORB', 'integrate'):
        (group_root/name).symlink_to(repo/'tests'/name, target_is_directory=True)
    for name, source, extra in specs:
        prepare(group/name, source, {**extra, 'device':'gpu', 'device_exx':backend, 'ks_solver':'cusolver'})
    (group/'CASES.task.txt').write_text('\n'.join(s[0] for s in specs)+'\n')
    command = ['bash', '../integrate/Autotest.sh', '-a', str(binary), '-n', '1', '-o', '1', '-f', 'CASES.task.txt']
    with (group_root/'autotest.log').open('w') as log:
        proc = subprocess.run(command, cwd=group, stdout=log, stderr=subprocess.STDOUT, timeout=600)
    ref_result = {'backend':backend, 'exit_code':proc.returncode, 'command':command,
                  'reference_hashes': {name:digest(group/name/'result.ref') for name,_,_ in specs}}
    report['reference_checks'].append(ref_result)
    for name, source, extra in specs:
        key = f'{name}/{backend}'
        try:
            report['runs'][key] = {'completed':True, **parse(group/name)}
        except Exception as error:
            report['runs'][key] = {'completed':False, 'error':str(error)}
    save()
    for real in (0,1):
        for symmetry in (0,1):
            name = f'si2_displaced_real{real}_filter{symmetry}'
            case = prepare(group/name, 'scf_hse_symm_multik',
                           {'device':'gpu','device_exx':backend,'ks_solver':'cusolver',
                            'exx_real_number':str(real),'exx_symmetry_realspace':str(symmetry)}, True)
            command = ['mpirun','-np','1','--map-by','ppr:1:node:pe=1','--bind-to','core',str(binary)]
            start = time.monotonic()
            with (case/'log.txt').open('w') as log:
                try:
                    proc = subprocess.run(command, cwd=case, stdout=log, stderr=subprocess.STDOUT, timeout=180)
                    code = proc.returncode
                except subprocess.TimeoutExpired:
                    code = 124
            key = f'{name}/{backend}'
            try:
                report['runs'][key] = {'completed':code == 0, 'exit_code':code,
                                       'elapsed_s':time.monotonic()-start, **parse(case)}
            except Exception as error:
                report['runs'][key] = {'completed':False,'exit_code':code,'error':str(error)}
            save()


def compare(key_a, key_b, kind):
    a = report['runs'][key_a]
    b = report['runs'][key_b]
    row = {'kind':kind,'a':key_a,'b':key_b,'passed':False}
    if a['completed'] and b['completed']:
        if len(a['forces_ev_angstrom']) != len(b['forces_ev_angstrom']):
            row['error'] = 'Different force array lengths'
        else:
            row['energy_delta_ev'] = abs(a['energy_ev']-b['energy_ev'])
            row['max_force_delta_ev_angstrom'] = max(abs(x-y) for x,y in zip(a['forces_ev_angstrom'],b['forces_ev_angstrom']))
            row['max_stress_delta_kbar'] = max(abs(x-y) for x,y in zip(a['stress_kbar'],b['stress_kbar']))
            row['passed'] = (row['energy_delta_ev'] <= limits['energy_ev']
                             and row['max_force_delta_ev_angstrom'] <= limits['force_ev_angstrom']
                             and row['max_stress_delta_kbar'] <= limits['stress_kbar'])
    report['comparisons'].append(row)


for key in list(report['runs']):
    if key.endswith('/cpu'):
        compare(key,key[:-3]+'gpu','CPU/GPU RI')
for geometry in ('si2','si2_displaced'):
    for real in (0,1):
        for backend in ('cpu','gpu'):
            compare(f'{geometry}_real{real}_filter0/{backend}',f'{geometry}_real{real}_filter1/{backend}',
                    'real-space symmetry off/on')
nonzero = {k:max(abs(x) for x in v['forces_ev_angstrom']) for k,v in report['runs'].items()
           if 'displaced' in k and v['completed']}
report['nonzero_force_max_components'] = nonzero
report['nonzero_force_covered'] = len(nonzero)==8 and all(x>1e-5 for x in nonzero.values())
report['passed'] = (all(v['completed'] for v in report['runs'].values())
                    and all(v['exit_code']==0 for v in report['reference_checks'])
                    and all(v['passed'] for v in report['comparisons']) and report['nonzero_force_covered'])
save()
print(json.dumps({'passed':report['passed'],'runs':len(report['runs']),
                  'reference_checks':report['reference_checks'],'comparisons':report['comparisons'],
                  'nonzero_force_covered':report['nonzero_force_covered']},indent=2))
raise SystemExit(0 if report['passed'] else 1)
