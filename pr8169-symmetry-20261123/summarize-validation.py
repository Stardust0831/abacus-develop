from pathlib import Path
import json
import xml.etree.ElementTree as ET

root=Path(__file__).resolve().parent
evidence=root/'evidence'
e2e=json.loads((evidence/'e2e-results.json').read_text())
initial_cli=json.loads((evidence/'cli-results.json').read_text())
cli=json.loads((evidence/'cli-singleton-results.json').read_text())
numerical=(evidence/'logs/libri-numerical.log').read_text().splitlines()
units={}
for variant in ('cpu','gpu'):
    entries=[]
    for path in sorted((evidence/'logs'/f'{variant}-xml').glob('*.xml')):
        node=ET.parse(path).getroot()
        entries.append({'file':path.name,**{k:int(node.attrib.get(k,0)) for k in
                       ('tests','failures','disabled','errors','skipped')}})
    assert len(entries)==3,entries
    assert all(x['failures']==0 and x['errors']==0 and x['skipped']==0 and x['disabled']==0 for x in entries),entries
    units[variant]=entries
exits={p.name:p.read_text().strip() for p in sorted((evidence/'logs').glob('*.exit'))}
assert exits['cli-driver.exit']=='1',exits
assert all(v=='0' for k,v in exits.items() if k!='cli-driver.exit'),exits
assert len(initial_cli['cases'])==8 and not initial_cli['passed']
for item in initial_cli['cases']:
    initial_log=(evidence/'cli-checks/08_RI'/item['case']/'check.log').read_text()
    assert item['exit_code']==1
    assert 'INPUT parameters have been successfully checked!' in initial_log
    assert 'exiting\nimproperly' in initial_log
assert len(cli['cases'])==8 and all(x['exit_code']==0 and x['success_message'] for x in cli['cases'])
assert e2e['passed'] and cli['passed']
consumers={}
for variant in ('cpu','gpu'):
    log=(evidence/'logs'/f'consumer-{variant}-test.log').read_text()
    cache=(evidence/'build'/f'consumer-{variant}'/'CMakeCache.txt').read_text()
    assert '100% tests passed, 0 tests failed out of 1' in log
    assert 'CMAKE_BUILD_TYPE:STRING=Debug' in cache
    consumers[variant]={'build_type':'Debug','ctest_passed':1}
report={'candidate_head':json.loads((root/'provenance.json').read_text())['candidate_head'],
        'libri_release':'589f6f8c6df3916575a1ba41e840de919d40d345',
        'libri_numerical':{'checks':sum(x.startswith('CHECK ') for x in numerical),
                           'passes':sum(x.startswith('PASS ') for x in numerical)},
        'libri_callback':(evidence/'logs/libri-callback.log').read_text().strip(),
        'unit_tests':units,'cmake_consumers':consumers,'cli_cases':len(cli['cases']),
        'scf_runs':len(e2e['runs']),'comparisons':len(e2e['comparisons']),
        'all_exit_codes':exits,
        'initial_cli_mpirun':{'passed':False,'cases':8,'exit_code':1,
            'reason':'Existing --check-input exit(0) skips MPI_Finalize; mpirun reports improper exit after successful INPUT checks.',
            'recheck':'Identical INPUT/STRU/KPT files passed direct single-process invocation; original failed launcher results are preserved.'},
        'passed':True}
(root/'validation-summary.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
