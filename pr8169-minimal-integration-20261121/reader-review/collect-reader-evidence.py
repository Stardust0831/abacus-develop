from pathlib import Path
import hashlib, json, os, shutil, subprocess, sys, xml.etree.ElementTree as ET
root=Path("/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-reader-20261121")
job=sys.argv[1]
phases=sys.argv[2:]
logroot=root/"logs"/("job-"+job)
summary={}
for phase in phases:
    summary[phase]={}
    for f in sorted((logroot/(phase+"-xml")).glob("*.xml")):
        tree=ET.parse(f)
        tests=list(tree.iter("testcase"))
        summary[phase][f.name]={"tests":len(tests),"failed":sum(t.find("failure") is not None for t in tests),"skipped":sum(t.find("skipped") is not None for t in tests),"device_exx_tests":[t.attrib for t in tests if "DeviceExx" in t.attrib["name"] or "DeviceExx" in t.attrib["classname"]]}
    build=root/"build"/phase
    if not build.is_dir():
        continue
    commands=json.loads((build/"compile_commands.json").read_text())
    selected=[c for c in commands if "MODULE_IO_read_input_serial.dir/" in c["command"] or ("io_input_serial.dir/" in c["command"] and Path(c["file"]).name in ("read_input.cpp","read_inp_sys.cpp","read_inp_exx_dftu.cpp")) or ("MODULE_IO_read_item_serial.dir/" in c["command"] and Path(c["file"]).name == "test_read_inp_exx_dftu.cpp")]
    flags=[]
    for c in selected:
        flags.append({"file":c["file"],"cuda":"-D__CUDA " in c["command"],"mpi":"-D__MPI " in c["command"],"gpu_ri":"-D__GPU_RI " in c["command"]})
    summary[phase]["feature_flags"]=flags
    (logroot/(phase+"-compile-commands.json")).write_text(json.dumps(selected,indent=2)+"\n")
    shutil.copyfile(build/"CMakeCache.txt",logroot/(phase+"-CMakeCache.txt"))
    for target in ("MODULE_IO_read_input_serial", "MODULE_IO_read_item_serial"):
        path=build/"source/source_io/test_serial/CMakeFiles"/(target+".dir")/"link.txt"
        shutil.copyfile(path,logroot/(phase+"-"+target+"-link.txt"))
    if phase == "final-gpu":
        for f in flags:
            assert not f["mpi"], f
            assert f["gpu_ri"], f
            if Path(f["file"]).name == "device.cpp":
                assert f["cuda"], f
            else:
                assert not f["cuda"], f
(logroot/"evidence-summary.json").write_text(json.dumps(summary,indent=2)+"\n")
print(json.dumps(summary,indent=2))
