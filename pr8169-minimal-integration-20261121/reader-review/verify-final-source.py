import hashlib, json
from pathlib import Path
manifest = json.loads(Path("source-final-sha256.json").read_text())
root = Path("source-final")
mismatches = [name for name,digest in manifest.items() if not (root/name).is_file() or hashlib.sha256((root/name).read_bytes()).hexdigest() != digest]
print("final files", len(manifest), "mismatches", mismatches)
if mismatches:
    raise SystemExit(1)
