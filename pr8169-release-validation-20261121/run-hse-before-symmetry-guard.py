#!/usr/bin/env python3
"""Run existing HSE references and compare complete force/stress arrays."""
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess

root = Path(__file__).resolve().parent
repo = root / "abacus"
binary = root / "build/abacus-gpu/abacus_std_gpu"
number = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"
cases = [
    ("hse_gamma", "scf_hse_gamma", {}),
    ("hse_spin2", "scf_hse_spin2_gamma", {}),
]
for real in (0, 1):
    for symm in (0, 1):
        cases.append((f"symm_real{real}_filter{symm}", "scf_hse_symm_multik",
                      {"exx_real_number": str(real), "exx_symmetry_realspace": str(symm)}))


def parse(path):
    text = (path / "OUT.autotest/running_scf.log").read_text()
    energy = re.findall(r"!FINAL_ETOT_IS\s+(" + number + ")", text)
    assert energy and "#SCF IS CONVERGED#" in text and "Total  Time" in text, path
    force_tail = text.rsplit("TOTAL-FORCE (eV/Angstrom)", 1)
    assert len(force_tail) == 2, path
    forces = [float(x) for row in re.findall(
        r"^\s*[A-Za-z]+\d+\s+(" + number + r")\s+(" + number + r")\s+(" + number + r")\s*$",
        force_tail[1], re.M) for x in row]
    stress_tail = re.split(r"TOTAL-STRESS\s*\(kbar\)", text)[-1]
    stress_rows = re.findall(r"^\s*(" + number + r")\s+(" + number + r")\s+(" + number + r")\s*$",
                             stress_tail, re.M)[:3]
    stresses = [float(x) for row in stress_rows for x in row]
    assert forces and len(stresses) == 9, path
    values = [float(energy[-1])] + forces + stresses
    assert all(math.isfinite(x) for x in values), path
    return {"energy_ev": values[0], "forces_ev_angstrom": forces, "stress_kbar": stresses}


results = {}
for ranks in (1, 2):
    selected = cases if ranks == 1 else [case for case in cases if case[0] == "symm_real0_filter1"]
    for backend in ("cpu", "gpu"):
        test_root = root / "hse" / f"np{ranks}-{backend}"
        group = test_root / "08_RI"
        group.mkdir(parents=True, exist_ok=True)
        for name in ("PP_ORB", "integrate"):
            (test_root / name).symlink_to(repo / "tests" / name, target_is_directory=True)
        for name, original, settings in selected:
            destination = group / name
            shutil.copytree(repo / "tests/08_RI" / original, destination)
            settings = {**settings, "device": "gpu", "device_exx": backend, "ks_solver": "cusolver"}
            inp = destination / "INPUT"
            lines = [line for line in inp.read_text().splitlines()
                     if not line.split() or line.split()[0] not in settings]
            lines.extend(f"{key} {value}" for key, value in settings.items())
            inp.write_text("\n".join(lines) + "\n")
        (group / "CASES.task.txt").write_text("\n".join(case[0] for case in selected) + "\n")
        command = ["bash", "../integrate/Autotest.sh", "-a", str(binary), "-n", str(ranks),
                   "-o", "1", "-f", "CASES.task.txt"]
        with (test_root / "autotest.log").open("w") as log:
            run = subprocess.run(command, cwd=group, stdout=log, stderr=subprocess.STDOUT)
        assert run.returncode == 0, (test_root, run.returncode)
        for name, _, _ in selected:
            key = f"np{ranks}/{name}/{backend}"
            results[key] = parse(group / name)
            results[key]["input_sha256"] = hashlib.sha256((group / name / "INPUT").read_bytes()).hexdigest()

comparisons = []
for key, cpu in results.items():
    if not key.endswith("/cpu"):
        continue
    gpu = results[key[:-3] + "gpu"]
    assert len(cpu["forces_ev_angstrom"]) == len(gpu["forces_ev_angstrom"])
    delta_e = abs(cpu["energy_ev"] - gpu["energy_ev"])
    delta_f = max(abs(a - b) for a, b in zip(cpu["forces_ev_angstrom"], gpu["forces_ev_angstrom"]))
    delta_s = max(abs(a - b) for a, b in zip(cpu["stress_kbar"], gpu["stress_kbar"]))
    comparisons.append({"case": key[:-4], "energy_delta_ev": delta_e,
                        "max_force_delta_ev_angstrom": delta_f, "max_stress_delta_kbar": delta_s})
    assert delta_e <= 1e-7 and delta_f <= 1e-6 and delta_s <= 1e-5, comparisons[-1]
report = {"passed": True, "runs": results, "comparisons": comparisons,
          "executable_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
(root / "hse-validation.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"passed": True, "runs": len(results), "comparisons": comparisons}, indent=2))
