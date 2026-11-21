import pathlib, tarfile, os, hashlib, json, datetime
root=pathlib.Path("/org/org-open-sai/proj-sai-hpc-software/runtime-tests/abacus-libri-minimal-reader-20261121")
os.chdir(root)
print("update_utc",datetime.datetime.now(datetime.timezone.utc).isoformat())
assert not (root / "build/after-cpu").exists(), "after-cpu already started; use a separate final snapshot"
with tarfile.open("reader-final-overlay.tar.gz","r:gz") as tf:
    for member in tf:
        path=root/"source-after"/member.name
        tmp=path.with_name(path.name+".reader-update")
        tmp.write_bytes(tf.extractfile(member).read())
        os.replace(tmp,path)
manifest=json.loads(pathlib.Path("source-final-sha256.json").read_text())
mismatches=[name for name,digest in manifest.items() if hashlib.sha256((root/"source-after"/name).read_bytes()).hexdigest()!=digest]
print("final_after_files",len(manifest),"mismatches",mismatches)
assert not mismatches
print("source_after_update_complete_before_after_cpu_configuration",not (root/"build/after-cpu").exists())
