import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = ROOT.parents[1]
WORKFLOW = REPOSITORY / ".github" / "workflows" / "sai-gpu-full.yml"


class PolicyTests(unittest.TestCase):
    def test_control_surface_is_small_and_explicit(self):
        scripts = {path.name for path in ROOT.glob("*.sh")}
        self.assertEqual(scripts, {
            "build_gpu.sh",
            "mpirun_with_mapping.sh",
        })
        self.assertEqual(
            {path.name for path in ROOT.glob("*.sbatch")},
            {"gpu_case.sbatch"},
        )
        self.assertEqual(
            {
                path.name for path in ROOT.iterdir()
                if path.is_dir() and path.name != "__pycache__"
                and any(child.is_file() for child in path.rglob("*"))
            },
            {"tests"},
        )

    def test_workflow_uses_trusted_control_shared_client_and_component_jobs(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        required = (
            "ref: ${{ github.event.repository.default_branch }}",
            "environment:",
            "sai-ssh-scheduled",
            "sai-ssh-manual",
            "fetch-depth: 0",
            "local run",
            "--source-repository \"$GITHUB_WORKSPACE/source\"",
            "--cache-role \"$SOURCE_CACHE_ROLE\"",
            "--defer-archive",
            "component-status:",
            "name: SAI / ${{ matrix.component.label }}",
            "fromJSON(needs.rebuild-and-test.outputs.components",
        )
        for value in required:
            self.assertIn(value, text)
        for obsolete in (
            "blob.core.windows.net",
            "download_source_artifact.sh",
            "sai-source-${{ github.run_id }}",
            "toolchains/abacus-develop-git-079fd0c",
            "python3 control/ci/sai/sai.py source payload",
            "python3 \"$REMOTE_RUN_ROOT/control/sai.py\" cache",
        ):
            self.assertNotIn(obsolete, text)
        action_lines = [
            line.strip() for line in text.splitlines() if "uses: actions/" in line
        ]
        self.assertTrue(action_lines)
        for line in action_lines:
            self.assertRegex(
                line,
                r"uses: actions/[A-Za-z0-9_.-]+@[0-9a-f]{40}(?: # v[0-9]+)?$",
            )

    def test_slurm_policy_and_shell_syntax(self):
        control = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (*ROOT.glob("*.sh"), *ROOT.glob("*.sbatch"))
        )
        for forbidden in (
            "--cpus-per-task", "--mem=", "--mem-per-cpu", "--nodelist",
            "--constraint", "--wrap",
        ):
            self.assertNotIn(forbidden, control)
        self.assertNotIn("build_gpu.sbatch", control)
        gpu_case = (ROOT / "gpu_case.sbatch").read_text(encoding="utf-8")
        self.assertIn("python3 \"$CONTROL_ROOT/sai.py\" worker case", gpu_case)
        self.assertNotIn("sed -n", gpu_case)
        self.assertNotIn("rsync -a", gpu_case)
        self.assertIn("--export=NIL", (ROOT / "slurm.py").read_text(encoding="utf-8"))
        files = [
            *sorted(ROOT.glob("*.sh")), *sorted(ROOT.glob("*.sbatch")),
            ROOT / "toolchain.env",
        ]
        result = subprocess.run(
            ["bash", "-n", *map(str, files)], capture_output=True, text=True, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
