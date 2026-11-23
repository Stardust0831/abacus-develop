#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,re,shlex
root=Path(__file__).resolve().parent
commands=json.loads((root/'build/abacus/compile_commands.json').read_text())
ri_compile=[x for x in commands if '__GPU_RI' in x.get('command','')]
by_object={}
for x in commands:
 parts=shlex.split(x['command'])
 if '-o' in parts:
  obj=(Path(x['directory'])/parts[parts.index('-o')+1]).resolve()
  by_object[str(obj)]=x
roots=set()
users=[]
bad=[]
for p in (root/'build/abacus').rglob('*.o.d'):
 text=p.read_text()
 hits=re.findall(r'(/[^\s\\]*?/include)/RI/',text)
 if hits:
  roots.update(hits)
  users.append(str(p.relative_to(root)))
  command=by_object.get(str(p.with_suffix('').resolve()))
  if command is None or '__GPU_RI' not in command['command'] or str(root/'libri/include') not in command['command']:
   bad.append(str(p.relative_to(root)))
result={'gpu_ri_compile_entries':len(ri_compile),'incorrect_compile_paths':bad,
        'audit_rule':'Check all actual RI consumers and their compilation commands; __GPU_RI is also globally defined on unrelated CUDA units that do not include RI.',
        'actual_dependency_include_roots':sorted(roots),'translation_units_with_ri_dependencies':users,
        'libri_sha256':{str(p.relative_to(root/'libri')):hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in sorted((root/'libri/include').rglob('*')) if p.is_file()},
        'passed':bool(ri_compile) and bool(users) and not bad and roots=={str(root/'libri/include')}}
(root/'logs/build-dependency-audit.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ['libri_sha256','translation_units_with_ri_dependencies']},indent=2))
raise SystemExit(not result['passed'])
