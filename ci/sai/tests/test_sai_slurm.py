import os
import signal
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from config import ResourceProfile  # noqa: E402
from slurm import SlurmAccountingError, SlurmClient, SlurmSubmissionError  # noqa: E402


class FakeCommands:
    def __init__(self, responses):
        self.responses = list(responses)
        self.commands = []

    def __call__(self, argv):
        self.commands.append(tuple(argv))
        if not self.responses:
            raise AssertionError("unexpected command: %r" % (argv,))
        return self.responses.pop(0)


class SlurmTests(unittest.TestCase):
    def test_array_count_is_separate_from_per_task_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = FakeCommands(["12345\n"])
            client = SlurmClient(Path(directory), command_runner=fake)
            profile = ResourceProfile("flood-gpu", 1, 4, 4, 900, 16)
            job_id = client.submit(
                script=Path("/control/gpu_case.sbatch"), partition="16V100",
                profile=profile, label="array-gpu4", chdir=Path("/source"),
                output=Path("/results/gpu4-%A_%a.out"),
                script_args=("/source", "/control"), array_count=40,
            )
            self.assertEqual(job_id, "12345")
            argv = fake.commands[0]
            self.assertIn("--ntasks=4", argv)
            self.assertIn("--array=0-39%16", argv)
            self.assertNotIn("--ntasks=40", argv)
            self.assertFalse(any(value.startswith("--cpus-per-task") for value in argv))
            self.assertFalse(any(value.startswith("--mem") for value in argv))
            self.assertIn("--export=NIL", argv)
            self.assertEqual(argv[-2:], ("/source", "/control"))

    def test_queue_time_is_unbounded_but_query_failures_are_limited(self):
        with tempfile.TemporaryDirectory() as directory:
            responses = ["1\n"] * 8 + ["", "100|COMPLETED|0:0\n"]
            fake = FakeCommands(responses)
            client = SlurmClient(
                Path(directory), command_runner=fake, sleeper=lambda _seconds: None,
                queue_failure_limit=2,
            )
            client.jobs["100"] = {"array_count": None}
            self.assertEqual(client.wait(("100",)), {"100": ("COMPLETED", "0:0")})
            self.assertEqual(sum(command[0] == "squeue" for command in fake.commands), 9)

            failed = FakeCommands([(1, "", "down"), (1, "", "down")])
            client = SlurmClient(
                Path(directory), command_runner=failed, sleeper=lambda _seconds: None,
                queue_failure_limit=2,
            )
            client.jobs["101"] = {"array_count": None}
            with self.assertRaises(SlurmAccountingError):
                client.wait(("101",))

    def test_array_accounting_requires_every_task(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = FakeCommands(["", "200_0|COMPLETED|0:0\n200_1|FAILED|1:0\n"])
            client = SlurmClient(
                Path(directory), command_runner=fake, sleeper=lambda _seconds: None,
            )
            client.jobs["200"] = {"array_count": 2}
            self.assertEqual(
                client.wait(("200",)),
                {"200_0": ("COMPLETED", "0:0"), "200_1": ("FAILED", "1:0")},
            )

    def test_malformed_submission_can_be_cancelled_by_stable_name(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = FakeCommands(["accepted without an id\n", ""])
            client = SlurmClient(Path(directory), command_runner=fake, user="testuser")
            with self.assertRaises(SlurmSubmissionError):
                client.submit(
                    script=Path("/control/build_gpu.sh"), partition="16V100",
                    profile=ResourceProfile("huge-gpu", 1, 4, 4, 3600),
                    label="build", chdir=Path("/source"), output=Path("/result.out"),
                    script_args=(),
                )
            client.cancel()
            self.assertEqual(fake.commands[-1][0], "scancel")
            self.assertIn("--user=testuser", fake.commands[-1])
            self.assertTrue(any(value.startswith("--name=sai-") for value in fake.commands[-1]))

    def test_signal_during_sbatch_cancels_after_submission_returns(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = []

            def runner(argv):
                commands.append(tuple(argv))
                if argv[0] == "sbatch":
                    os.kill(os.getpid(), signal.SIGTERM)
                    return "300\n"
                if argv[0] == "scancel":
                    return ""
                raise AssertionError(argv)

            client = SlurmClient(Path(directory), command_runner=runner, user="testuser")
            client.install_signal_handlers()
            try:
                with self.assertRaises(KeyboardInterrupt):
                    client.submit(
                    script=Path("/control/build_gpu.sh"), partition="16V100",
                        profile=ResourceProfile("huge-gpu", 1, 4, 4, 3600),
                        label="build", chdir=Path("/source"), output=Path("/result.out"),
                        script_args=(),
                    )
            finally:
                client.restore_signal_handlers()
            cancel = [command for command in commands if command[0] == "scancel"]
            self.assertTrue(cancel)
            self.assertTrue(any(value.startswith("--name=sai-") for value in cancel[-1]))


if __name__ == "__main__":
    unittest.main()
