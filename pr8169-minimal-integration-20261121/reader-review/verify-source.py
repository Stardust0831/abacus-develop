import hashlib, json
from pathlib import Path
for phase in ("before", "after"):
    manifest = json.loads(Path("source-" + phase + "-sha256.json").read_text())
    root = Path("source-" + phase)
    mismatches = []
    for name, digest in manifest.items():
        path = root / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            mismatches.append(name)
    print(phase, "files", len(manifest), "mismatches", mismatches)
    if mismatches:
        raise SystemExit(1)
