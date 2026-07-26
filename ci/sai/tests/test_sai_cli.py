import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "sai.py"


class CliTest(unittest.TestCase):
    def run_cli(self, *arguments):
        return subprocess.run(
            [sys.executable, str(CLI), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_root_and_command_help(self):
        commands = [
            (),
            ("local", "--help"),
            ("local", "run", "--help"),
            ("source", "payload", "--help"),
            ("remote", "run", "--help"),
            ("config", "validate", "--help"),
            ("report", "github", "--help"),
            ("worker", "autotest", "--help"),
            ("worker", "case", "--help"),
            ("cache", "prepare", "--help"),
            ("github", "authorize", "--help"),
            ("github", "start-check", "--help"),
            ("github", "complete-check", "--help"),
            ("github", "configure-ssh", "--help"),
        ]
        for arguments in commands:
            with self.subTest(arguments=arguments):
                result = self.run_cli(*arguments)
                if not arguments:
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("usage:", result.stderr)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("usage:", result.stdout)

    def test_version(self):
        result = self.run_cli("--version")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "SAI CI protocol 1")

    def test_remote_maintenance_commands_use_the_public_dispatch_contract(self):
        for command in ("cleanup", "collect", "archive"):
            with self.subTest(command=command):
                result = self.run_cli("remote", command, "/definitely/not/a/sai/run")
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("Traceback", result.stderr)
                self.assertIn("sai:", result.stderr)


if __name__ == "__main__":
    unittest.main()
