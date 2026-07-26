import argparse
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import local
from bootstrap import prepare as bootstrap_prepare  # noqa: E402


class LocalConfigTests(unittest.TestCase):
    def _write_config(self, directory, body):
        root = Path(directory)
        ssh = root / "ssh.config"
        ssh.write_text("Host test\n", encoding="utf-8")
        path = root / "local.ini"
        path.write_text(body.replace("SSH_CONFIG", str(ssh)), encoding="utf-8")
        return path

    def test_strict_config_and_local_path_expansion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "artifacts"
            config = self._write_config(
                root,
                """[local]\nssh_config = SSH_CONFIG\nssh_target = test\nproject_root = /home/user/project\nrun_namespace = local\nartifact_root = $SAI_TEST_ARTIFACT\n""",
            )
            old = os.environ.get("SAI_TEST_ARTIFACT")
            os.environ["SAI_TEST_ARTIFACT"] = str(artifact)
            try:
                parsed = local.load_config(config)
            finally:
                if old is None:
                    os.environ.pop("SAI_TEST_ARTIFACT", None)
                else:
                    os.environ["SAI_TEST_ARTIFACT"] = old
            self.assertEqual(parsed.ssh_config, root / "ssh.config")
            self.assertEqual(parsed.artifact_root, artifact)
            self.assertEqual(parsed.project_root, "/home/user/project")

    def test_unknown_default_multiline_and_unsafe_values_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cases = [
                "[local]\nssh_config = SSH_CONFIG\nssh_target = test\nproject_root = relative\nrun_namespace = local\nartifact_root = out\n",
                "[DEFAULT]\nfoo = bar\n[local]\nssh_config = SSH_CONFIG\nssh_target = test\nproject_root = /home/u/p\nrun_namespace = local\nartifact_root = out\n",
                "[local]\nssh_config = SSH_CONFIG\nssh_target = test\nproject_root = /home/u/p\nrun_namespace = local\nartifact_root = out\nunknown = x\n",
                "[local]\nssh_config = SSH_CONFIG\nssh_target = test\nproject_root = /home/u/p\nrun_namespace = local\nartifact_root = out\n  continued\n",
            ]
            for body in cases:
                with self.subTest(body=body):
                    with self.assertRaises(local.LocalError):
                        local.load_config(self._write_config(root, body))

    def test_parser_requires_source_selection_and_execute_rejects_mismatch(self):
        parser = argparse.ArgumentParser()
        local.configure_parser(parser)
        with self.assertRaises(SystemExit):
            parser.parse_args(["run", "--config", "config.ini"])
        args = parser.parse_args(
            ["run", "--config", "config.ini", "--source-ref", "HEAD", "--include-untracked"]
        )
        with self.assertRaises(local.LocalError):
            local.execute(args, Path.cwd())

    def test_parser_accepts_explicit_ci_run_identity(self):
        parser = argparse.ArgumentParser()
        local.configure_parser(parser)
        args = parser.parse_args([
            "run", "--config", "config.ini", "--source-ref", "a" * 40,
            "--run-id", "123", "--run-attempt", "2",
            "--cache-role", "baseline", "--defer-archive",
        ])
        self.assertEqual(args.run_id, "123")
        self.assertEqual(args.run_attempt, "2")
        self.assertEqual(args.cache_role, "baseline")
        self.assertTrue(args.defer_archive)

    def test_local_run_requires_committed_control_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            control = repository / "ci" / "sai"
            control.mkdir(parents=True)
            (control / "sai.py").write_text("# committed\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repository), "init", "-q"], check=True)
            subprocess.run(["git", "-C", str(repository), "config", "user.name", "test"], check=True)
            subprocess.run(["git", "-C", str(repository), "config", "user.email", "test@example.invalid"], check=True)
            subprocess.run(["git", "-C", str(repository), "add", "ci/sai"], check=True)
            subprocess.run(["git", "-C", str(repository), "commit", "-qm", "control"], check=True)

            self.assertRegex(local._verify_control_current(repository, control), r"^[0-9a-f]{40}$")
            (control / "sai.py").write_text("# dirty\n", encoding="utf-8")
            with self.assertRaises(local.LocalError):
                local._verify_control_current(repository, control)
            (control / "sai.py").write_text("# committed\n", encoding="utf-8")
            (control / "untracked.ini").write_text("[test]\n", encoding="utf-8")
            with self.assertRaises(local.LocalError):
                local._verify_control_current(repository, control)


class BootstrapTests(unittest.TestCase):
    def test_prepare_creates_one_contained_run(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            project, run = bootstrap_prepare(
                str(home / "project"), "manual", "10-1", "a" * 40, "b" * 40,
                home=home,
            )
            self.assertEqual(project, (home / "project").resolve())
            self.assertEqual(run, project / "runs" / "manual" / "10-1")
            marker = json.loads((run / ".ci-created").read_text(encoding="utf-8"))
            self.assertEqual(marker["source_sha"], "a" * 40)
            with self.assertRaises(ValueError):
                bootstrap_prepare(
                    str(home / "project"), "manual", "10-1", "a" * 40,
                    "b" * 40, home=home,
                )

    def test_prepare_rejects_symlinked_runs_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            project = home / "project"
            project.mkdir()
            outside = home / "outside"
            outside.mkdir()
            (project / "runs").symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValueError):
                bootstrap_prepare(
                    str(project), "manual", "10-1", "a" * 40, "b" * 40,
                    home=home,
                )
            self.assertEqual(list(outside.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
