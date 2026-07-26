import gzip
import os
import sys
import subprocess
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from source import PayloadInfo, SourceSelection, build_payload, resolve_source


class GitRepository:
    def __init__(self, root):
        self.root = Path(root)
        self._git("init", "-q")
        self._git("config", "user.email", "sai-tests@example.invalid")
        self._git("config", "user.name", "SAI tests")

    def _git(self, *args, **kwargs):
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, **kwargs)

    def commit(self, message="commit"):
        self._git("add", "-A")
        self._git("commit", "-qm", message)


class SourceTests(unittest.TestCase):
    def test_working_tree_is_deterministic_and_does_not_mutate_index(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = GitRepository(directory)
            root = repo.root
            (root / "tracked.txt").write_text("base", encoding="utf-8")
            repo.commit()
            index_before = (root / ".git/index").read_bytes()
            (root / "tracked.txt").write_text("changed", encoding="utf-8")
            (root / "untracked.txt").write_text("excluded", encoding="utf-8")

            first = resolve_source(root, working_tree=True)
            second = resolve_source(root, working_tree=True)

            self.assertIsInstance(first, SourceSelection)
            self.assertEqual(first, second)
            self.assertTrue(first.dirty)
            self.assertFalse(first.include_untracked)
            self.assertEqual(index_before, (root / ".git/index").read_bytes())

            included = resolve_source(root, working_tree=True, include_untracked=True)
            self.assertNotEqual(first.tree_sha, included.tree_sha)
            self.assertEqual(index_before, (root / ".git/index").read_bytes())

    def test_ignored_staged_addition_is_removed_but_tracked_ignore_match_remains(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = GitRepository(directory)
            root = repo.root
            (root / ".gitignore").write_text("ignored.txt\nnew.txt\n", encoding="utf-8")
            (root / "ignored.txt").write_text("tracked first", encoding="utf-8")
            (root / "kept.txt").write_text("tracked", encoding="utf-8")
            repo._git("add", ".gitignore", "kept.txt")
            repo._git("add", "-f", "ignored.txt")
            repo._git("commit", "-qm", "commit")
            (root / "ignored.txt").write_text("tracked changed", encoding="utf-8")
            repo._git("add", "-u", "--", "ignored.txt")
            (root / "new.txt").write_text("new", encoding="utf-8")
            repo._git("add", "-f", "new.txt")

            selection = resolve_source(root, working_tree=True, include_untracked=True)
            manifest = root / "manifest.gz"
            payload = root / "payload.gz"
            build_payload(root, selection.source_id, "none", payload, manifest)
            records = gzip.decompress(manifest.read_bytes()).split(b"\0")
            paths = [record.split(b"\t", 1)[1] for record in records if record]
            self.assertIn(b"ignored.txt", paths)
            self.assertNotIn(b"new.txt", paths)

    def test_payload_full_and_delta_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = GitRepository(directory)
            root = repo.root
            (root / "file.txt").write_text("one", encoding="utf-8")
            repo.commit()
            base = resolve_source(root, source_ref="HEAD").base_commit
            (root / "file.txt").write_text("two", encoding="utf-8")
            repo.commit("second")
            current = resolve_source(root, source_ref="HEAD")
            payload = root / "payload.gz"
            manifest = root / "manifest.gz"
            info = build_payload(root, current.source_id, base, payload, manifest)
            self.assertEqual(info, PayloadInfo("delta", payload.stat().st_size))
            self.assertGreater(info.payload_bytes, 0)
            self.assertTrue(gzip.decompress(payload.read_bytes()).startswith(b"diff --git"))

            full = build_payload(root, current.source_id, "none", root / "full.gz", root / "full-manifest.gz")
            self.assertEqual(full.mode, "full")
            self.assertEqual(full.payload_bytes, (root / "full.gz").stat().st_size)


if __name__ == "__main__":
    unittest.main()
