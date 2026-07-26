import json
import sys
import tempfile
import unittest
from pathlib import Path


SAI_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SAI_ROOT))

from sai_ci.report import ResultError, load_result, publish_github  # noqa: E402


def valid_result():
    cases = []
    resources = ["gpu1"] + ["gpu2"] * 7 + ["gpu4"] * 40 + ["gpu8x2"]
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
        "protocol": 1,
        "total": 49,
        "passed": 48,
        "failed": 1,
        "infrastructure": 0,
        "cases": cases,
    }


class ResultTest(unittest.TestCase):
    def test_loads_exact_protocol(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            path.write_text(json.dumps(valid_result()), encoding="utf-8")
            self.assertEqual(load_result(path)["passed"], 48)

    def test_rejects_inconsistent_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            result = valid_result()
            result["passed"] = 49
            path.write_text(json.dumps(result), encoding="utf-8")
            with self.assertRaises(ResultError):
                load_result(path)

    def test_rejects_extra_fields_and_duplicate_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            result = valid_result()
            result["extra"] = True
            path.write_text(json.dumps(result), encoding="utf-8")
            with self.assertRaises(ResultError):
                load_result(path)
            result.pop("extra")
            result["cases"][1]["case_id"] = result["cases"][0]["case_id"]
            path.write_text(json.dumps(result), encoding="utf-8")
            with self.assertRaises(ResultError):
                load_result(path)

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
            publish_github(result_path, output, summary)
            self.assertIn("available=true", output.read_text(encoding="utf-8"))
            self.assertIn("total=49", output.read_text(encoding="utf-8"))
            self.assertEqual(summary.read_text(encoding="utf-8"), "## Matrix\n")

    def test_missing_result_is_explicitly_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "output"
            summary = root / "summary"
            publish_github(root / "missing.json", output, summary)
            self.assertIn("available=false", output.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
