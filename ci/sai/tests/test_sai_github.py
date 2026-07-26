import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import github  # noqa: E402


class GitHubTests(unittest.TestCase):
    def _environment(self, root, event):
        return {
            "GITHUB_EVENT_NAME": event,
            "GITHUB_REPOSITORY": "owner/repository",
            "GITHUB_OUTPUT": str(root / "output"),
            "GITHUB_STEP_SUMMARY": str(root / "summary"),
            "GITHUB_SERVER_URL": "https://github.com",
            "GITHUB_RUN_ID": "42",
            "GH_TOKEN": "test-token",
        }

    def test_manual_admission_is_exact(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = self._environment(root, "workflow_dispatch")
            environment.update(
                MANUAL_SOURCE_SHA="a" * 40, MANUAL_RUN_NAMESPACE="manual"
            )
            with mock.patch.dict(os.environ, environment, clear=True):
                values = github.authorize()
            self.assertEqual(values["accepted"], "true")
            self.assertIn("source_sha={}".format("a" * 40), (root / "output").read_text())

    def test_comment_resolves_authorized_immutable_head(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event = root / "event.json"
            event.write_text(json.dumps({
                "comment": {"body": "/abacus-ci sai-gpu", "user": {"login": "maintainer"}},
                "issue": {"number": 17},
                "repository": {"default_branch": "develop"},
            }), encoding="utf-8")
            environment = self._environment(root, "issue_comment")
            environment["GITHUB_EVENT_PATH"] = str(event)
            responses = [
                {"permission": "triage", "role_name": "triage"},
                {
                    "state": "open",
                    "base": {"repo": {"full_name": "owner/repository"}, "ref": "develop"},
                    "head": {"repo": {"full_name": "contributor/fork"}, "sha": "b" * 40},
                },
                {"id": 123},
            ]
            with mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch("github._api", side_effect=responses) as api:
                values = github.authorize()
            self.assertEqual(values["source_sha"], "b" * 40)
            self.assertEqual(values["check_run_id"], "123")
            self.assertEqual(api.call_count, 3)

    def test_check_lifecycle_is_reported_by_the_trusted_adapter(self):
        environment = {
            "ARTIFACT_URL": (
                "https://github.com/owner/repository/actions/runs/42/artifacts/9"
            ),
            "CASE_SUMMARY_AVAILABLE": "true",
            "CHECK_RUN_ID": "123",
            "GH_TOKEN": "test-token",
            "GITHUB_REPOSITORY": "owner/repository",
            "GITHUB_RUN_ID": "42",
            "GITHUB_SERVER_URL": "https://github.com",
            "GPU_FAILED": "1",
            "GPU_INFRASTRUCTURE": "0",
            "GPU_PASSED": "48",
            "GPU_TOTAL": "49",
            "PR_NUMBER": "17",
            "SAI_RESULT": "failure",
            "SOURCE_SHA": "b" * 40,
        }
        with mock.patch.dict(os.environ, environment, clear=True), \
                mock.patch("github._api", side_effect=[{}, {}, {}]) as api:
            github.start_check()
            github.complete_check()
        self.assertEqual(api.call_count, 3)
        self.assertEqual(api.call_args_list[0].kwargs["body"]["status"], "in_progress")
        completed = api.call_args_list[1].kwargs["body"]
        self.assertEqual(completed["conclusion"], "failure")
        self.assertIn("48 passed", api.call_args_list[2].kwargs["body"]["body"])

    def test_configure_ssh_writes_pinned_private_client(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            known = root / "known_hosts"
            known.write_text("[host.example]:12022 ssh-ed25519 AAAA\n", encoding="utf-8")
            environment = {
                "SAI_SSH_HOST": "host.example",
                "SAI_SSH_PORT": "12022",
                "SAI_SSH_USER": "user",
                "SAI_SSH_PRIVATE_KEY": "private-key",
            }
            completed = mock.Mock(returncode=0, stderr=b"")
            with mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch("github.subprocess.run", return_value=completed):
                config = github.configure_ssh(root / "client", known)
            text = config.read_text(encoding="utf-8")
            self.assertIn("StrictHostKeyChecking yes", text)
            self.assertIn("ForwardAgent no", text)
            self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
            self.assertEqual(
                stat.S_IMODE((config.parent / "id_ed25519").stat().st_mode), 0o600
            )


if __name__ == "__main__":
    unittest.main()
