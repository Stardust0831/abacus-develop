import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from cache import CacheError, finalize, prepare, receive, verify_tree  # noqa: E402
from source import build_payload  # noqa: E402


class CacheTests(unittest.TestCase):
    def _run(self, home):
        project = home / "project"
        run = project / "runs" / "manual" / "1-1"
        (run / "source").mkdir(parents=True)
        (run / ".ci-created").write_text("created\n", encoding="utf-8")
        return project, run

    def test_cache_root_symlink_is_rejected_before_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            project, run = self._run(home)
            outside = home / "outside"
            outside.mkdir()
            (project / "cache").symlink_to(outside, target_is_directory=True)
            with self.assertRaises(CacheError):
                prepare(project, run, "a" * 40, "candidate", home=home)
            self.assertFalse((outside / "source-transfers").exists())

    def test_verify_tree_rejects_symlink_root(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            target = home / "target"
            target.mkdir()
            linked = home / "linked"
            linked.symlink_to(target, target_is_directory=True)
            with self.assertRaises(CacheError):
                verify_tree(linked, home / "missing.manifest.gz")

    def test_full_snapshot_then_delta_base_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            repository = home / "repository"
            repository.mkdir()
            subprocess.run(["git", "-C", str(repository), "init", "-q"], check=True)
            subprocess.run(["git", "-C", str(repository), "config", "user.name", "test"], check=True)
            subprocess.run(["git", "-C", str(repository), "config", "user.email", "test@example.invalid"], check=True)
            (repository / "file.txt").write_text("source\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repository), "add", "file.txt"], check=True)
            subprocess.run(["git", "-C", str(repository), "commit", "-qm", "source"], check=True)
            source_sha = subprocess.check_output(
                ["git", "-C", str(repository), "rev-parse", "HEAD"], text=True
            ).strip()

            project = home / "project"
            run = project / "runs" / "manual" / "1-1"
            (run / "source").mkdir(parents=True)
            (run / ".ci-created").write_text("created\n", encoding="utf-8")
            transfer, base = prepare(project, run, source_sha, "candidate", home=home)
            self.assertEqual(base, "none")
            payload = home / "payload.gz"
            manifest = home / "manifest.gz"
            info = build_payload(repository, source_sha, base, payload, manifest)
            shutil.copyfile(payload, transfer / "source-payload.gz")
            shutil.copyfile(manifest, transfer / "source-manifest.gz")
            receive(project, run, transfer, info.mode, source_sha, home=home)
            snapshot = finalize(project, run, transfer, source_sha, home=home)
            self.assertIsNotNone(snapshot)
            self.assertEqual((run / "source" / "file.txt").read_text(encoding="utf-8"), "source\n")

            second = project / "runs" / "manual" / "2-1"
            (second / "source").mkdir(parents=True)
            (second / ".ci-created").write_text("created\n", encoding="utf-8")
            second_transfer, second_base = prepare(
                project, second, source_sha, "candidate", home=home
            )
            self.assertEqual(second_base, source_sha)
            self.assertEqual(
                (second_transfer / "source" / "file.txt").read_text(encoding="utf-8"),
                "source\n",
            )


if __name__ == "__main__":
    unittest.main()
