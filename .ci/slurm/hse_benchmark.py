#!/usr/bin/env python3
"""Fork-only serial HSE experiments; retain inputs, logs and timings per run."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--abacus', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    metadata = {'job': os.environ.get('SLURM_JOB_ID'), 'hostname': os.uname().nodename}
    for name, command in [('version', [str(args.abacus), '--version']),
                          ('gpu', ['nvidia-smi', '--query-gpu=name,uuid,memory.total,driver_version', '--format=csv'])]:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        metadata[name] = result.stdout
    (args.output / 'metadata.json').write_text(json.dumps(metadata, indent=2))
    variants = [('cpu_full', 'cpu', 0, 120, True),
                ('cpu_chunk6', 'cpu', 6, 120, True),
                ('gpu_full', 'gpu', 0, 120, True),
                ('gpu_chunk5', 'gpu', 5, 120, True),
                ('gpu_chunk6', 'gpu', 6, 120, True),
                ('gpu_chunk19', 'gpu', 19, 120, True),
                ('gpu_small', 'gpu', 0, 60, True),
                ('gpu_noace', 'gpu', 0, 120, False)]
    rows = []
    for repeat in range(2):
        # Reverse second pass to reduce ordering bias. Each process starts fresh.
        for name, device, chunk, cutoff, ace in (variants if repeat == 0 else variants[::-1]):
            work = args.output / ('%s_%d' % (name, repeat))
            work.mkdir()
            (work / 'STRU').write_text('''ATOMIC_SPECIES
Si 28.0855 Si_ONCV_PBE-1.0.upf
LATTICE_CONSTANT
10.26
LATTICE_VECTORS
1 0 0
0 1 0
0 0 1
ATOMIC_POSITIONS
Direct
Si
0
8
0 0 0 0 0 0
0 0.5 0.5 0 0 0
0.5 0 0.5 0 0 0
0.5 0.5 0 0 0 0
0.25 0.25 0.25 0 0 0
0.25 0.75 0.75 0 0 0
0.75 0.25 0.75 0 0 0
0.75 0.75 0.25 0 0 0
''')
            (work / 'KPT').write_text('K_POINTS\n0\nGamma\n1 1 1 0 0 0\n')
            parameters = dict(suffix='bench', calculation='scf', basis_type='pw',
                              device=device, ks_solver='cg', ntype=1, nbands=20,
                              pseudo_dir=str(args.source / 'tests/PP_ORB'),
                              ecutwfc=30, ecutrho=120, ecutexx=cutoff,
                              dft_functional='hse', exx_separate_loop=1,
                              exxace=int(ace), exx_batch_size=chunk, exx_hybrid_step=50,
                              scf_thr='1e-10', pw_diag_thr='1e-12', scf_nmax=100, symmetry=-1,
                              smearing_method='fixed', init_wfc='random', pw_seed=1,
                              mixing_beta=0.4, cal_force=0, cal_stress=0)
            (work / 'INPUT').write_text('INPUT_PARAMETERS\n' + ''.join('%s %s\n' % item for item in parameters.items()))
            start = time.monotonic()
            with (work / 'stdout.log').open('w') as stream:
                result = subprocess.run(['timeout', '--kill-after=30s', '600s',
                                         'mpirun', '-np', '1', str(args.abacus)],
                                        cwd=work, stdout=stream, stderr=subprocess.STDOUT)
            elapsed = time.monotonic() - start
            log = work / 'OUT.bench/running_scf.log'
            data = log.read_text(errors='replace') if log.exists() else ''
            stdout = (work / 'stdout.log').read_text(errors='replace')
            energy = re.findall(r'!FINAL_ETOT_IS\s+([-+\d.eE]+)', data + '\n' + stdout)
            valid = result.returncode == 0 and bool(energy) and 'EXX IS NOT CONVERGED' not in data + stdout
            valid = valid and '#SCF IS CONVERGED#' in data and '!!SCF IS NOT CONVERGED!!' not in data
            row = dict(name=name, repeat=repeat, device=device, batch=chunk, ecutexx=cutoff,
                       ace=ace, seconds=elapsed, exit_code=result.returncode, valid=valid,
                       energy_ev=float(energy[-1]) if energy else None)
            rows.append(row)
            (args.output / 'measurements.json').write_text(json.dumps(rows, indent=2))
            print(json.dumps(row), flush=True)
            if not valid:
                raise RuntimeError('Failed or unconverged benchmark: ' + str(work))
    reference = rows[0]['energy_ev']
    for row in rows:
        row['delta_ev_per_atom'] = (row['energy_ev'] - reference) / 8
        # Small FFT grid is an accuracy study, not an exact-parity variant.
        if row['ecutexx'] == 120 and abs(row['delta_ev_per_atom']) > 1e-6:
            raise RuntimeError('Full-grid energy parity exceeded 1e-6 eV/atom: ' + row['name'])
    (args.output / 'measurements.json').write_text(json.dumps(rows, indent=2))


if __name__ == '__main__':
    main()
