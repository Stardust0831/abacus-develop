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


if __name__ == "__main__":
    unittest.main()
