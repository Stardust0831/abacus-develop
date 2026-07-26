import argparse
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sai_ci import local


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


if __name__ == "__main__":
    unittest.main()
