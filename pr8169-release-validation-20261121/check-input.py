#!/usr/bin/env python3
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent
test_root = root / "cli"
group = test_root / "08_RI"
group.mkdir(parents=True, exist_ok=True)
(test_root / "PP_ORB").symlink_to(root / "abacus/tests/PP_ORB", target_is_directory=True)
cases = [
    ("gpu_realspace_on", "gpu", "1", "1", 1),
    ("gpu_default_realspace", "gpu", "1", None, 1),
    ("gpu_default_symmetry", "gpu", None, None, 1),
    ("gpu_kpoint_symmetry", "gpu", "1", "0", 0),
    ("cpu_realspace_on", "cpu", "1", "1", 0),
    ("gpu_time_reversal", "gpu", "0", None, 0),
]
report = []
for name, backend, symmetry, realspace, expected in cases:
    destination = group / name
    shutil.copytree(root / "abacus/tests/08_RI/scf_hse_symm_multik", destination)
    settings = {"device": "gpu", "device_exx": backend, "ks_solver": "cusolver",
                "symmetry": symmetry, "exx_symmetry_realspace": realspace}
    inp = destination / "INPUT"
    lines = [line for line in inp.read_text().splitlines()
             if not line.split() or line.split()[0] not in settings]
    lines.extend(f"{key} {value}" for key, value in settings.items() if value is not None)
    inp.write_text("\n".join(lines) + "\n")
    result = subprocess.run([str(root / "build/abacus-gpu/abacus_std_gpu"), "--check-input"],
                            cwd=destination, capture_output=True, text=True)
    (destination / "check-input.log").write_text(result.stdout + result.stderr)
    assert result.returncode == expected, (name, result.returncode, result.stdout, result.stderr)
    if expected:
        assert "LibRI GPU real-space symmetry fails numerical validation" in result.stdout + result.stderr
    report.append({"case": name, "exit_code": result.returncode, "passed": True})
(root / "cli-validation.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
