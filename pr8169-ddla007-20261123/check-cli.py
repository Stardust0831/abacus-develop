from pathlib import Path
import json
import os
import shutil
import subprocess

root=Path(__file__).resolve().parent
repo=root/'abacus'
binary=root/'build/abacus/abacus_std_gpu'
group=root/'cli-checks/08_RI'
group.mkdir(parents=True,exist_ok=False)
(group.parent/'PP_ORB').symlink_to(repo/'tests/PP_ORB',target_is_directory=True)
specs=[('gpu_default',{}),('gpu_symmetry1',{'symmetry':'1'}),
       ('gpu_realspace0',{'symmetry':'1','exx_symmetry_realspace':'0'}),
       ('gpu_realspace1',{'symmetry':'1','exx_symmetry_realspace':'1'}),
       ('gpu_symmetry0',{'symmetry':'0'}),('gpu_symmetry_minus1',{'symmetry':'-1'}),
       ('cpu_symmetry1',{'device_exx':'cpu','symmetry':'1'}),
       ('gpu_md_reset',{'symmetry':'1','calculation':'md','md_type':'nve','md_tfirst':'300','md_nstep':'1'})]
results=[]
for name,changes in specs:
    case=group/name
    shutil.copytree(repo/'tests/08_RI/scf_hse_symm_multik',case)
    settings={'device':'gpu','device_exx':'gpu','ks_solver':'cusolver',**changes}
    inp=case/'INPUT'
    lines=[line for line in inp.read_text().splitlines() if not line.split() or line.split()[0] not in
           set(settings)|{'symmetry','exx_symmetry_realspace'}]
    lines.extend(f'{k} {v}' for k,v in settings.items())
    inp.write_text('\n'.join(lines)+'\n')
    command=[str(binary),'--check-input']
    with (case/'check.log').open('w') as log:
        completed=subprocess.run(command,cwd=case,stdout=log,stderr=subprocess.STDOUT,timeout=90)
    success='INPUT parameters have been successfully checked!' in (case/'check.log').read_text()
    results.append({'case':name,'exit_code':completed.returncode,'success_message':success,'passed':completed.returncode==0 and success})
report={'passed':all(x['passed'] for x in results),'cases':results}
(root/'cli-results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
raise SystemExit(not report['passed'])
