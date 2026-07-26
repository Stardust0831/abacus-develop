import json
import sys
import tempfile
import unittest
from pathlib import Path


SAI_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SAI_ROOT))

from config import load_config  # noqa: E402
from report import ResultError, load_result, publish_github  # noqa: E402


CONFIG_PATH = SAI_ROOT / "gpu-matrix.ini"
CONFIG = load_config(CONFIG_PATH, SAI_ROOT)


def valid_result():
    cases = []
    resources = ["gpu1"] + ["gpu2"] * 7 + ["gpu4"] * 40 + ["gpu8x2"]
    failed_resource = resources[0]
    for index, resource in enumerate(resources, 1):
        suite = "suite"
        name = "case-{:03d}".format(index)
        runner = "autotest"
        if resource == "gpu8x2":
            suite = "15_rtTDDFT_GPU"
            name = "19_NO_Si48_CUSOLVERMP_TDDFT_GPU"
            runner = "cusolvermp"
        cases.append({
            "case_id": suite + "/" + name,
            "suite": suite,
            "name": name,
            "resource": resource,
            "runner": runner,
            "state": "FAIL" if index == 1 else "PASS",
            "exit_code": 1 if index == 1 else 0,
            "slurm_state": "FAILED" if index == 1 else "COMPLETED",
            "job_id": "100_{}".format(index - 1),
            "elapsed_seconds": 3,
            "artifact_dir": "/tmp/case-{:03d}".format(index),
        })
    return {
        "protocol": 2,
        "total": 49,
        "passed": 48,
        "failed": 1,
        "infrastructure": 0,
        "components": [
            {
                "name": name,
                "label": label,
                "state": "FAIL" if name == failed_resource else "PASS",
                "job_id": str(100 + index),
                "slurm_state": "COMPLETED",
                "exit_code": "0:0",
            }
            for index, (name, label) in enumerate((
                ("build", "Compile"),
                ("gpu1", "1 GPU"),
                ("gpu2", "2 GPUs"),
                ("gpu4", "4 GPUs"),
                ("gpu8x2", "2 nodes / 16 GPUs (Si48)"),
            ))
        ],
        "cases": cases,
    }


class ResultTest(unittest.TestCase):
    def test_loads_exact_protocol(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            path.write_text(json.dumps(valid_result()), encoding="utf-8")
            self.assertEqual(load_result(path, CONFIG)["passed"], 48)

    def test_rejects_inconsistent_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            result = valid_result()
            result["passed"] = 49
            path.write_text(json.dumps(result), encoding="utf-8")
            with self.assertRaises(ResultError):
                load_result(path, CONFIG)

    def test_rejects_case_count_that_differs_from_the_ini(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            result = valid_result()
            result["cases"].pop()
            result["total"] = 48
            result["passed"] = 47
            result["components"].pop()
            path.write_text(json.dumps(result), encoding="utf-8")
            with self.assertRaises(ResultError):
                load_result(path, CONFIG)

    def test_rejects_component_state_inconsistent_with_its_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            result = valid_result()
            failed_resource = result["cases"][0]["resource"]
            next(
                component for component in result["components"]
                if component["name"] == failed_resource
            )["state"] = "PASS"
            path.write_text(json.dumps(result), encoding="utf-8")
            with self.assertRaises(ResultError):
                load_result(path, CONFIG)

    def test_rejects_extra_fields_and_duplicate_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            result = valid_result()
            result["extra"] = True
            path.write_text(json.dumps(result), encoding="utf-8")
            with self.assertRaises(ResultError):
                load_result(path, CONFIG)
            result.pop("extra")
            result["cases"][1]["case_id"] = result["cases"][0]["case_id"]
            path.write_text(json.dumps(result), encoding="utf-8")
            with self.assertRaises(ResultError):
                load_result(path, CONFIG)

    def test_publishes_outputs_and_markdown(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result_path = root / "result.json"
            output = root / "output"
            summary = root / "summary"
            result_path.write_text(json.dumps(valid_result()), encoding="utf-8")
            result_path.with_name("gpu-case-summary.md").write_text(
                "## Matrix\n", encoding="utf-8"
            )
            publish_github(result_path, output, summary, CONFIG_PATH)
            self.assertIn("available=true", output.read_text(encoding="utf-8"))
            self.assertIn("total=49", output.read_text(encoding="utf-8"))
            self.assertIn('"label":"Compile"', output.read_text(encoding="utf-8"))
            self.assertEqual(summary.read_text(encoding="utf-8"), "## Matrix\n")

    def test_missing_result_is_explicitly_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "output"
            summary = root / "summary"
            publish_github(root / "missing.json", output, summary, CONFIG_PATH)
            self.assertIn("available=false", output.read_text(encoding="utf-8"))
            self.assertIn('"state":"INFRA"', output.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
