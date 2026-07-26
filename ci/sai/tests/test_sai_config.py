import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from config import ConfigError, load_config  # noqa: E402


class SaiConfigTests(unittest.TestCase):
    def setUp(self):
        self.matrix = ROOT / "gpu-matrix.ini"
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def config_text(self):
        return self.matrix.read_text(encoding="utf-8")

    def load_text(self, text):
        path = pathlib.Path(self.tmp.name) / "matrix.ini"
        path.write_text(text, encoding="utf-8")
        return load_config(path)

    def test_valid_inventory_and_distribution(self):
        config = load_config(self.matrix)
        self.assertEqual(len(config.cases), 49)
        self.assertEqual([c.resource for c in config.cases].count("gpu1"), 1)
        self.assertEqual([c.resource for c in config.cases].count("gpu2"), 7)
        self.assertEqual([c.resource for c in config.cases].count("gpu4"), 40)
        self.assertEqual([c.resource for c in config.cases].count("gpu8x2"), 1)
        self.assertEqual(config.cases[-1].runner, "cusolvermp")
        self.assertEqual(config.resources["gpu8x2"].total_tasks, 16)

    def test_unknown_missing_duplicate_and_default_sections(self):
        text = self.config_text() + "\n[unknown]\nx = y\n"
        with self.assertRaises(ConfigError):
            self.load_text(text)
        text = text.replace("[coordinator]\n", "", 1)
        with self.assertRaises(ConfigError):
            self.load_text(text)
        with self.assertRaises(ConfigError):
            self.load_text(self.config_text() + "\n[DEFAULT]\n")
        with self.assertRaises(ConfigError):
            self.load_text(self.config_text() + "\n[cluster]\nname = duplicate\n")

    def test_interpolation_multiline_and_empty_values(self):
        for old, new in (
            ("name = sai", "name = %(bad)s"),
            ("name = sai", "name = sai\n  continuation"),
            ("name = sai", "name = "),
        ):
            with self.assertRaises(ConfigError):
                self.load_text(self.config_text().replace(old, new, 1))

    def test_bounds_and_topology(self):
        for old, new in (
            ("poll_seconds = 10", "poll_seconds = 0"),
            ("tasks_per_node = 1\ngpus_per_node = 1", "tasks_per_node = 2\ngpus_per_node = 1"),
            ("nodes = 2\ntasks_per_node = 8", "nodes = 2\ntasks_per_node = 9"),
        ):
            with self.assertRaises(ConfigError):
                self.load_text(self.config_text().replace(old, new, 1))

    def test_unsafe_identifier_and_case_reference(self):
        for old, new in (
            ("name = sai", "name = -unsafe"),
            ("resource = gpu1\nrunner = autotest", "resource = missing\nrunner = autotest"),
            ("runner = cusolvermp", "runner = unknown"),
        ):
            with self.assertRaises(ConfigError):
                self.load_text(self.config_text().replace(old, new, 1))

    def test_resource_names_come_from_the_ini(self):
        text = self.config_text().replace(
            "[resource.gpu1]", "[resource.single_gpu]", 1
        ).replace("resource = gpu1", "resource = single_gpu", 1)
        config = self.load_text(text)
        self.assertIn("single_gpu", config.resources)
        self.assertNotIn("gpu1", config.resources)
        self.assertEqual(config.cases[5].resource, "single_gpu")

    def test_control_root_resolves_regular_toolchain(self):
        root = pathlib.Path(self.tmp.name) / "control"
        toolchain = root / "toolchain.env"
        toolchain.parent.mkdir(parents=True)
        toolchain.write_text("# test\n", encoding="utf-8")
        config = load_config(self.matrix, root)
        self.assertEqual(config.cluster.toolchain, toolchain.resolve())
        toolchain.unlink()
        toolchain.symlink_to(pathlib.Path(self.tmp.name) / "outside")
        with self.assertRaises(ConfigError):
            load_config(self.matrix, root)


if __name__ == "__main__":
    unittest.main()
