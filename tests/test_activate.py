import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[1] / "scripts" / "activate.py"
WRAPPER = Path(__file__).resolve().parents[1] / "activate.sh"
SPEC = importlib.util.spec_from_file_location("activate", SOURCE)
activate = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = activate
SPEC.loader.exec_module(activate)


class ActivateTests(unittest.TestCase):
    def test_wrapper_rejects_invalid_arguments_before_reconciliation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copy(WRAPPER, root / "activate.sh")
            (root / "refresh.sh").write_text("#!/usr/bin/env bash\ntouch refreshed\n")
            (root / "scripts").mkdir()
            (root / "scripts" / "activate.py").write_text(
                "from pathlib import Path\nPath('activated').touch()\n"
            )
            (root / "refresh.sh").chmod(0o755)

            result = subprocess.run(
                ["bash", "activate.sh", "--unexpected"],
                cwd=root,
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("usage: activate.sh [--check]", result.stderr)
            self.assertFalse((root / "refreshed").exists())
            self.assertFalse((root / "activated").exists())

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

    def test_parses_disabled_plugins_with_comments_and_blank_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "disabled-plugins.txt").write_text("\n# disabled\n example \n\nother\n")
            self.assertEqual(activate.disabled_plugin_names(root), {"example", "other"})

    def test_excludes_disabled_registered_plugin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.plugin(root)
            (root / "disabled-plugins.txt").write_text("example\n")
            self.assertEqual(activate.load_runtime_plugins(root), [])

    def test_check_reports_listed_disabled_skill_that_remains(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.plugin(root)
            (root / "disabled-plugins.txt").write_text("example\n")
            (root / "disabled-plugin-skills.txt").write_text("example old-skill\n")
            (root / "skills" / "old-skill").mkdir(parents=True)

            owners = activate.disabled_skill_owners(
                root, {"example"}, activate.registered_plugins(root)
            )

            self.assertEqual(
                activate.disabled_skills_remaining(root, owners),
                ["disabled skill remains under skills/: old-skill (owned by example)"],
            )

    def test_activation_refuses_listed_disabled_skill_before_writing_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.plugin(root)
            (root / "disabled-plugins.txt").write_text("example\n")
            (root / "disabled-plugin-skills.txt").write_text("example old-skill\n")
            (root / "skills" / "old-skill").mkdir(parents=True)

            with self.assertRaisesRegex(activate.ManifestError, "disabled skill remains"):
                activate.activate(root, {"opencode/plugin.js": "new runtime"})

            self.assertFalse((root / "runtime").exists())

    def test_rejects_unknown_disabled_plugin_before_loading(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.plugin(root)
            (root / "disabled-plugins.txt").write_text("unknown\n")
            with self.assertRaisesRegex(activate.ManifestError, "unknown disabled plugin basename"):
                activate.load_runtime_plugins(root)

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
