from pathlib import Path
import sys, json, xml.etree.ElementTree as ET
root=Path(sys.argv[1])
results={}
for phase in ("final-cpu", "final-gpu", "final-gpu-no-visible"):
    tests=[]
    for file in sorted((root/(phase+"-xml")).glob("*.xml")):
        tree=ET.parse(file)
        for test in tree.iter("testcase"):
            tests.append({"name": test.attrib["classname"]+"."+test.attrib["name"], "skipped": test.find("skipped") is not None, "failed": test.find("failure") is not None})
    results[phase]={"tests":len(tests),"passed":sum(not t["skipped"] and not t["failed"] for t in tests),"skipped":[t["name"] for t in tests if t["skipped"]],"failures":[t["name"] for t in tests if t["failed"]]}
    assert tests, phase
    assert not results[phase]["failures"], phase
    if phase != "final-gpu-no-visible":
        assert not results[phase]["skipped"], phase
    names={t["name"] for t in tests}
    assert "InputTest.DeviceExxCpuSymmetry" in names, phase
    if phase == "final-gpu":
        assert {"InputTest.DeviceExxGpuScfSymmetry","InputTest.DeviceExxGpuMdEffectiveSymmetry"} <= names
    if phase == "final-gpu-no-visible":
        assert len(tests)==3
        assert set(results[phase]["skipped"])=={"InputTest.DeviceExxGpuScfSymmetry","InputTest.DeviceExxGpuMdEffectiveSymmetry"}
        assert results[phase]["passed"]==1
print(json.dumps(results,indent=2))
(root/"test-counts.json").write_text(json.dumps(results,indent=2)+"\n")
