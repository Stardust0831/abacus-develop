#!/usr/bin/env python3
"""Audit the pre-guard, completed CPU/GPU HSE runs without rerunning them."""
import ast
import json
import math
from pathlib import Path
import re

root = Path(__file__).resolve().parent
# Reuse the original run driver's parser without executing its calculations.
tree = ast.parse((root / "run-hse-before-symmetry-guard.py").read_text())
parser = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "parse")
number = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"
exec(compile(ast.Module(body=[parser], type_ignores=[]), "hse_parser", "exec"))
rows = {}
for backend in ("cpu", "gpu"):
    group = root / "hse" / ("np1-" + backend) / "08_RI"
    for case in sorted(group.iterdir()):
        if (case / "OUT.autotest/running_scf.log").is_file():
            rows[case.name + "/" + backend] = parse(case)
comparisons = []
for key, cpu in rows.items():
    if not key.endswith("/cpu"):
        continue
    gpu = rows[key[:-3] + "gpu"]
    assert len(cpu["forces_ev_angstrom"]) == len(gpu["forces_ev_angstrom"])
    delta_e = abs(cpu["energy_ev"] - gpu["energy_ev"])
    delta_f = max(abs(a - b) for a, b in zip(cpu["forces_ev_angstrom"], gpu["forces_ev_angstrom"]))
    delta_s = max(abs(a - b) for a, b in zip(cpu["stress_kbar"], gpu["stress_kbar"]))
    comparisons.append({"case": key[:-4], "energy_delta_ev": delta_e,
                        "max_force_delta_ev_angstrom": delta_f, "max_stress_delta_kbar": delta_s,
                        "passed": delta_e <= 1e-7 and delta_f <= 1e-6 and delta_s <= 1e-5})
report = {"abacus_head": "c1d3b81e97f7fcd4d4fafd0d65416fa227151a81",
          "passed": all(c["passed"] for c in comparisons), "runs": rows, "comparisons": comparisons}
(root / "symmetry-regression.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"completed_runs": len(rows), "comparisons": comparisons}, indent=2))
