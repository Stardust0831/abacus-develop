"""Repeat the identical CLI inputs without mpirun's finalize requirement."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess

root = Path(__file__).resolve().parent
initial = json.loads((root / 'cli-results.json').read_text())
group = root / 'cli-singleton/08_RI'
group.mkdir(parents=True, exist_ok=False)
(group.parent / 'PP_ORB').symlink_to(root / 'abacus/tests/PP_ORB', target_is_directory=True)
results = []
for entry in initial['cases']:
    name = entry['case']
    source = root / 'cli-checks/08_RI' / name
    case = group / name
    shutil.copytree(source, case, ignore=shutil.ignore_patterns('OUT.*', 'check.log', 'INPUT.info'))
    hashes = {}
    for filename in ('INPUT', 'STRU', 'KPT'):
        assert (case / filename).read_bytes() == (source / filename).read_bytes()
        hashes[filename] = hashlib.sha256((case / filename).read_bytes()).hexdigest()
    command = [str(root / 'build/abacus/abacus_std_gpu'), '--check-input']
    with (case / 'check.log').open('w') as log:
        result = subprocess.run(command, cwd=case, stdout=log, stderr=subprocess.STDOUT, timeout=90)
    text = (case / 'check.log').read_text()
    success = 'INPUT parameters have been successfully checked!' in text
    results.append({'case': name, 'exit_code': result.returncode, 'success_message': success,
                    'passed': result.returncode == 0 and success, 'input_hashes': hashes,
                    'command': command})
report = {'passed': all(x['passed'] for x in results), 'cases': results,
          'mode': 'single-process direct invocation',
          'initial_mpirun_result_preserved': 'cli-results.json'}
(root / 'cli-singleton-results.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
raise SystemExit(not report['passed'])
