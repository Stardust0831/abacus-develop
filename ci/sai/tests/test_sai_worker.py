import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from worker import (  # noqa: E402
    _manifest_row,
    classify_result,
    is_pmix_startup_failure,
)


class WorkerTests(unittest.TestCase):
    def test_pmix_signature_requires_all_markers(self):
        complete = (
            b"PMIX_ERR_FILE_OPEN_FAILURE\nMPI_Init_thread\nPMIx_Init failed\n"
        )
        self.assertTrue(is_pmix_startup_failure(complete))
        self.assertTrue(is_pmix_startup_failure(complete.replace(
            b"FILE_OPEN_FAILURE", b"OUT_OF_RESOURCE"
        )))
        for marker in (
            b"PMIX_ERR_FILE_OPEN_FAILURE", b"MPI_Init_thread", b"PMIx_Init failed"
        ):
            self.assertFalse(is_pmix_startup_failure(complete.replace(marker, b"missing")))

    def test_manifest_selection_is_array_indexed_and_validated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = root / "results"
            manifest = result / "case-matrix" / "manifests" / "gpu1.tsv"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(
                "case_id\tsuite\tname\tresource\trunner\tretries\n"
                "suite/case\tsuite\tcase\tgpu1\tautotest\t2\n",
                encoding="utf-8",
            )
            self.assertEqual(
                _manifest_row(manifest, 0, result),
                {
                    "case_id": "suite/case", "suite": "suite", "case_name": "case",
                    "resource": "gpu1", "runner": "autotest", "retries": "2",
                },
            )
            with self.assertRaises(ValueError):
                _manifest_row(manifest, 1, result)
            outside = root / "outside.tsv"
            outside.write_text(manifest.read_text(encoding="utf-8"), encoding="utf-8")
            with self.assertRaises(ValueError):
                _manifest_row(outside, 0, result)

    def test_status_classification_preserves_timeout_and_pmix_protocol(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata = Path(directory) / "pmix-retry.tsv"
            self.assertEqual(classify_result(0, "autotest", metadata), "PASS")
            self.assertEqual(classify_result(124, "autotest", metadata), "TIMEOUT")
            self.assertEqual(classify_result(1, "autotest", metadata), "INFRA")
            metadata.write_text("final_pmix\t0\n", encoding="utf-8")
            self.assertEqual(classify_result(1, "autotest", metadata), "FAIL")
            self.assertEqual(classify_result(1, "cusolvermp", metadata), "FAIL")


if __name__ == "__main__":
    unittest.main()
