#!/usr/bin/env python3
"""Archive numerical outputs and exact build provenance, excluding object files."""
from pathlib import Path
import hashlib
import json
import tarfile

root = Path(__file__).resolve().parent
paths = set()
for name in ('logs', 'runs', 'cli-checks', 'cli-singleton', 'github'):
    paths.update(p for p in (root / name).rglob('*') if p.is_file() and not p.is_symlink())
for pattern in ('*.py', '*.sbatch', '*.patch', '*.json', '*.md', 'build-*.log', 'run-*.log'):
    paths.update(root.glob(pattern))
for relative in (
        'build/abacus/CMakeCache.txt', 'build/abacus/compile_commands.json',
        'build/abacus/CMakeFiles/CMakeConfigureLog.yaml',
        'build/abacus/source/CMakeFiles/abacus_std_gpu.dir/link.txt',
        'build/cpu/CMakeCache.txt', 'build/cpu/Testing/Temporary/LastTest.log',
        'build/consumer-cpu/CMakeCache.txt', 'build/consumer-gpu/CMakeCache.txt',
        'build/consumer-cpu/Testing/Temporary/LastTest.log',
        'build/consumer-gpu/Testing/Temporary/LastTest.log',
        'build/libri/CMakeCache.txt', 'build/libri/CMakeFiles/CMakeConfigureLog.yaml',
        'build/libri/CMakeFiles/test_lri_gpu_symmetry.dir/link.txt',
        'build/libri/CMakeFiles/test_lri_gpu_symmetry.dir/flags.make',
        'build/libri/CMakeFiles/test_lri_gpu_symmetry.dir/test_lri_gpu_symmetry.cpp.o.d'):
    p = root / relative
    if p.is_file():
        paths.add(p)
audit = json.loads((root / 'logs/build-dependency-audit.json').read_text())
paths.update(root / name for name in audit['translation_units_with_ri_dependencies'])

def digest(p):
    result = hashlib.sha256()
    with p.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()

binary_info = root / 'logs/final-binary-hashes.json'
binary_info.write_text(json.dumps({str(p.relative_to(root)): digest(p) for p in (
    root / 'build/abacus/abacus_std_gpu', root / 'build/libri/test_lri_gpu_symmetry')}, indent=2) + '\n')
paths.add(binary_info)
manifest_path = root / 'logs/evidence-manifest.json'
paths.discard(manifest_path)
manifest = {str(p.relative_to(root)): {'size': p.stat().st_size, 'sha256': digest(p)}
            for p in sorted(paths)}
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
paths.add(manifest_path)
archive = root / 'e2e-evidence.tar.gz'
with tarfile.open(archive, 'w:gz') as tar:
    for p in sorted(paths):
        tar.add(p, arcname=str(p.relative_to(root)), recursive=False)
sha = digest(archive)
(root / 'e2e-evidence.tar.gz.sha256').write_text(f'{sha}  {archive.name}\n')
print(json.dumps({'files':len(paths), 'bytes':archive.stat().st_size, 'sha256':sha}, indent=2))
