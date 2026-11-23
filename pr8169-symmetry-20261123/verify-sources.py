from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parent
manifest=json.loads((root/'source-manifest.json').read_text())
bad=[]
for name,wanted in manifest.items():
 path=root/name
 actual=hashlib.sha256(path.read_bytes()).hexdigest()
 if actual!=wanted:bad.append(name)
print(json.dumps({'files':len(manifest),'mismatches':bad,'passed':not bad},indent=2))
raise SystemExit(bool(bad))
