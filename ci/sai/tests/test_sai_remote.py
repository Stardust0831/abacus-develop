import io
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock
import sys


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = ROOT.parents[1]
sys.path.insert(0, str(ROOT))

from config import load_config  # noqa: E402
from remote import (  # noqa: E402
    RemoteCoordinator, archive_run, cleanup_archives, collect_artifacts,
    validate_cases,
)


class FakeSlurm:
    def __init__(self, run_root):
        self.run_root = run_root
        self.jobs = {}
        self.submissions = []
        self.next_job = 100
        self.cancelled = False

    def install_signal_handlers(self):
        pass

    def restore_signal_handlers(self):
        pass

    def submit(self, **arguments):
        self.next_job += 1
        job = str(self.next_job)
        self.submissions.append(arguments)
        self.jobs[job] = {
            "job_id": job, "array_count": arguments.get("array_count"),
            "submission": arguments,
        }
        return job

    def wait(self, jobs):
        if len(jobs) == 1 and self.jobs[jobs[0]]["array_count"] is None:
            return {jobs[0]: ("COMPLETED", "0:0")}
        result = {}
        for job in jobs:
            submission = self.jobs[job]["submission"]
            manifest = Path(submission["script_args"][-1])
            rows = manifest.read_text(encoding="utf-8").splitlines()[1:]
            status_root = self.run_root / "results" / "case-matrix" / "status"
            status_root.mkdir(parents=True, exist_ok=True)
            for index, line in enumerate(rows):
                case_id, suite, name, resource, runner, _retries = line.split("\t")
                key = case_id.replace("/", "__")
                (status_root / (key + ".tsv")).write_text(
                    "\t".join((case_id, suite, name, resource, runner, "PASS", "0", "3", job, str(index))) + "\n",
                    encoding="utf-8",
                )
                result["%s_%d" % (job, index)] = ("COMPLETED", "0:0")
        return result

    def save_jobs(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("{}\n", encoding="utf-8")

    def cancel(self):
        self.cancelled = True


class RemoteTests(unittest.TestCase):
    @staticmethod
    def _run_tree(root):
        run = root / "project" / "runs" / "daily" / "1-1"
        (run / "results").mkdir(parents=True)
        (run / ".ci-created").write_text("created\n", encoding="utf-8")
        return run

    def test_repository_inventory_and_cusolvermp_case(self):
        config = load_config(ROOT / "gpu-matrix.ini")
        rows = validate_cases(REPOSITORY, config.cases)
        self.assertEqual(len(rows), 49)
        self.assertEqual(sum(row["runner"] == "cusolvermp" for row in rows), 1)

    def test_artifact_collection_and_remote_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            run = self._run_tree(home)
            (run / "results" / "result.json").write_text("{}\n", encoding="utf-8")
            (run / "results" / "ignored.bin").write_bytes(b"ignored")
            output = io.BytesIO()
            collect_artifacts(run, output, home=home)
            with tarfile.open(fileobj=io.BytesIO(output.getvalue()), mode="r:gz") as archive:
                self.assertEqual(
                    sorted(archive.getnames()),
                    [".ci-created", "results/result.json"],
                )
            saved = archive_run(run, home=home)
            self.assertFalse(run.exists())
            self.assertEqual(saved, home / "project" / "archives" / "daily" / "1-1.tar.gz")
            with tarfile.open(saved, mode="r:gz") as archive:
                self.assertEqual(
                    sorted(archive.getnames()),
                    [".ci-created", "results/result.json"],
                )

    def test_cleanup_removes_only_expired_archives(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            run = self._run_tree(home)
            saved = archive_run(run, home=home)
            os.utime(saved, (1, 1))
            self.assertEqual(cleanup_archives(
                home / "project", now=72 * 3600 + 2, home=home,
            ), 1)
            self.assertFalse(saved.exists())

    def test_build_then_four_resource_arrays_and_structured_result(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project"
            run = project / "runs" / "manual" / "1-1"
            source = run / "source"
            control = run / "control"
            source.mkdir(parents=True)
            control.mkdir()
            (control / "gpu-matrix.ini").write_text((ROOT / "gpu-matrix.ini").read_text(encoding="utf-8"), encoding="utf-8")
            toolchain = control / "toolchain.env"
            toolchain.write_text("# test\n", encoding="utf-8")
            fake = FakeSlurm(run)
            config = load_config(control / "gpu-matrix.ini", control)
            rows = [
                {
                    "case_id": case.case_id, "suite": case.suite, "name": case.name,
                    "resource": case.resource, "runner": case.runner,
                    "task_key": case.case_id.replace("/", "__"),
                }
                for case in config.cases
            ]
            coordinator = RemoteCoordinator(
                project_root=project, run_root=run, source_sha="a" * 40,
                control_sha="b" * 40, run_id="1", run_attempt="1",
                control_root=control, slurm=fake, home=Path(directory),
            )
            with mock.patch("remote.validate_cases", return_value=rows):
                self.assertEqual(coordinator.execute(), 0)

            self.assertEqual([item["label"] for item in fake.submissions], [
                "build", "array-gpu1", "array-gpu2", "array-gpu4", "array-gpu8x2",
            ])
            arrays = fake.submissions[1:]
            self.assertEqual([item["array_count"] for item in arrays], [1, 7, 40, 1])
            self.assertEqual([item["profile"].total_tasks for item in arrays], [1, 2, 4, 16])
            result = run / "results" / "case-matrix" / "result.json"
            self.assertIn('"passed": 49', result.read_text(encoding="utf-8"))
            self.assertIn('"label": "Compile"', result.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
