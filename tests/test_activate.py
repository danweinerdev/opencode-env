import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[1] / "scripts" / "activate.py"
SPEC = importlib.util.spec_from_file_location("activate", SOURCE)
activate = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = activate
SPEC.loader.exec_module(activate)


class ActivateTests(unittest.TestCase):
    def plugin(self, root: Path, module: str = "opencode/plugin.js") -> Path:
        plugin = root / "plugins" / "example"
        (plugin / ".agents-plugin").mkdir(parents=True)
        (plugin / "opencode").mkdir()
        (plugin / "opencode" / "plugin.js").write_text("export default async () => ({})\n")
        (plugin / ".agents-plugin" / "plugin.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "name": "example",
                    "opencode": {"plugin": module},
                }
            )
        )
        (root / ".gitmodules").write_text(
            '[submodule "plugins/example"]\n\tpath = plugins/example\n\turl = example.invalid/repo.git\n'
        )
        return plugin

    def test_loads_registered_declarative_plugin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugin = self.plugin(root)
            loaded = activate.load_runtime_plugins(root)
            self.assertEqual(loaded, [activate.RuntimePlugin("example", plugin / "opencode" / "plugin.js")])

    def test_rejects_module_path_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.plugin(root, "../../outside.js")
            (root / "outside.js").write_text("export default async () => ({})\n")
            with self.assertRaisesRegex(activate.ManifestError, "escapes the plugin root"):
                activate.load_runtime_plugins(root)

    def test_generated_loader_imports_plugin_uri(self):
        with tempfile.TemporaryDirectory() as directory:
            module = Path(directory) / "plugin.js"
            module.write_text("export default async () => ({})\n")
            output = activate.render_loader([activate.RuntimePlugin("example", module)])
            self.assertIn(module.as_uri(), output)
            self.assertIn("Duplicate plugin tool", output)


if __name__ == "__main__":
    unittest.main()
