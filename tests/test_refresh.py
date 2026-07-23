import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[1] / "refresh.sh"


class RefreshTests(unittest.TestCase):
    def setup_root(self, root: Path, disabled: str, inventory: str = "disabled disabled\n") -> None:
        subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
        shutil.copy2(SOURCE, root / "refresh.sh")
        (root / "refresh.sh").chmod((root / "refresh.sh").stat().st_mode | stat.S_IXUSR)
        (root / "activate.sh").write_text("#!/usr/bin/env bash\nexit 0\n")
        (root / "activate.sh").chmod((root / "activate.sh").stat().st_mode | stat.S_IXUSR)
        (root / ".gitmodules").write_text(
            '[submodule "plugins/enabled"]\n\tpath = plugins/enabled\n\turl = enabled.invalid/repo.git\n'
            '[submodule "plugins/disabled"]\n\tpath = plugins/disabled\n\turl = disabled.invalid/repo.git\n'
        )
        (root / "disabled-plugins.txt").write_text(disabled)
        (root / "disabled-plugin-skills.txt").write_text(inventory)
        for name in ("enabled", "disabled"):
            plugin = root / "plugins" / name
            (plugin / "skills" / name).mkdir(parents=True)
            (plugin / "skills" / name / "SKILL.md").write_text(name)
            subprocess.run(["git", "init", "--quiet"], cwd=plugin, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=plugin, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=plugin, check=True)
            subprocess.run(["git", "add", "."], cwd=plugin, check=True)
            subprocess.run(["git", "commit", "--quiet", "-m", "initial"], cwd=plugin, check=True)
            oid = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=plugin, check=True, text=True, capture_output=True
            ).stdout.strip()
            subprocess.run(
                ["git", "update-index", "--add", "--cacheinfo", f"160000,{oid},plugins/{name}"],
                cwd=root,
                check=True,
            )

    def test_prunes_disabled_skill_link_and_links_enabled_skill(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.setup_root(root, "\n# disabled plugin\n disabled \n")
            (root / "skills").mkdir()
            os.symlink("../plugins/disabled/skills/disabled", root / "skills" / "disabled")

            result = subprocess.run(["bash", "refresh.sh"], cwd=root, text=True, capture_output=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / "skills" / "disabled").is_symlink())
            enabled = root / "skills" / "enabled"
            self.assertTrue(enabled.is_symlink())
            self.assertEqual(os.readlink(enabled), "../plugins/enabled/skills/enabled")

    def test_prunes_listed_disabled_link_when_source_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.setup_root(root, "disabled\n")
            shutil.rmtree(root / "plugins" / "disabled")
            (root / "skills").mkdir()
            os.symlink("../plugins/disabled/skills/disabled", root / "skills" / "disabled")

            result = subprocess.run(["bash", "refresh.sh"], cwd=root, text=True, capture_output=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(os.path.lexists(root / "skills" / "disabled"))

    def test_prunes_listed_disabled_link_when_source_is_uninitialized(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.setup_root(root, "disabled\n")
            shutil.rmtree(root / "plugins" / "disabled" / "skills")
            (root / "skills").mkdir()
            os.symlink("../plugins/disabled/skills/disabled", root / "skills" / "disabled")

            result = subprocess.run(["bash", "refresh.sh"], cwd=root, text=True, capture_output=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(os.path.lexists(root / "skills" / "disabled"))

    def test_quarantines_copied_disabled_skill_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.setup_root(root, "disabled\n")
            shutil.copytree(
                root / "plugins" / "disabled" / "skills" / "disabled",
                root / "skills" / "disabled",
            )

            result = subprocess.run(["bash", "refresh.sh"], cwd=root, text=True, capture_output=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / "skills" / "disabled").exists())
            preserved = root / ".disabled-skills" / "disabled" / "disabled"
            self.assertTrue(preserved.is_dir())
            self.assertEqual((preserved / "SKILL.md").read_text(), "disabled")

    def test_refuses_differing_copied_disabled_skill(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.setup_root(root, "disabled\n")
            shutil.copytree(
                root / "plugins" / "disabled" / "skills" / "disabled",
                root / "skills" / "disabled",
            )
            (root / "skills" / "disabled" / "SKILL.md").write_text("unrelated")
            (root / "activate.sh").write_text("#!/usr/bin/env bash\ntouch activated\n")
            (root / "activate.sh").chmod((root / "activate.sh").stat().st_mode | stat.S_IXUSR)

            result = subprocess.run(["bash", "refresh.sh"], cwd=root, text=True, capture_output=True)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("content differs from disabled source", result.stderr)
            self.assertEqual((root / "skills" / "disabled" / "SKILL.md").read_text(), "unrelated")
            self.assertFalse((root / ".disabled-skills" / "disabled" / "disabled").exists())
            self.assertFalse((root / "activated").exists())

    def test_rejects_unknown_disabled_plugin_before_refresh(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.setup_root(root, "unknown\n")

            result = subprocess.run(["bash", "refresh.sh"], cwd=root, text=True, capture_output=True)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unknown disabled plugin basename: unknown", result.stderr)

    def test_rejects_invalid_disabled_skill_inventory_before_refresh(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.setup_root(root, "disabled\n", "disabled unsafe/name\n")

            result = subprocess.run(["bash", "refresh.sh"], cwd=root, text=True, capture_output=True)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid disabled plugin skill inventory entry", result.stderr)

    def test_rejects_available_disabled_source_skill_omitted_from_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.setup_root(root, "disabled\n", "")

            result = subprocess.run(["bash", "refresh.sh"], cwd=root, text=True, capture_output=True)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("disabled source skill is missing from trusted inventory", result.stderr)

    def test_rejects_malformed_updated_gitlink_allowance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.setup_root(root, "disabled\n")

            result = subprocess.run(
                ["bash", "refresh.sh"],
                cwd=root,
                text=True,
                capture_output=True,
                env={**os.environ, "REFRESH_ALLOWED_UPDATED_GITLINKS": "plugins/enabled=not-an-oid"},
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("invalid REFRESH_ALLOWED_UPDATED_GITLINKS entry", result.stderr)

    def test_rejects_updated_gitlink_allowance_with_wrong_checkout_oid(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.setup_root(root, "disabled\n")

            result = subprocess.run(
                ["bash", "refresh.sh"],
                cwd=root,
                text=True,
                capture_output=True,
                env={
                    **os.environ,
                    "REFRESH_ALLOWED_UPDATED_GITLINKS": "plugins/enabled=" + "0" * 40,
                },
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("OID does not match checkout HEAD", result.stderr)

    def test_allows_only_exact_advanced_gitlink_pair(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.setup_root(root, "disabled\n")
            plugin = root / "plugins" / "enabled"
            subprocess.run(["git", "add", ".gitmodules"], cwd=root, check=True)
            subprocess.run(["git", "commit", "--quiet", "-m", "record gitlink"], cwd=root, check=True)
            (plugin / "advanced").write_text("advanced")
            subprocess.run(["git", "add", "advanced"], cwd=plugin, check=True)
            subprocess.run(["git", "commit", "--quiet", "-m", "advance"], cwd=plugin, check=True)
            oid = subprocess.run(
                ["git", "rev-parse", "HEAD"], cwd=plugin, check=True, text=True, capture_output=True
            ).stdout.strip()

            result = subprocess.run(
                ["bash", "refresh.sh"],
                cwd=root,
                text=True,
                capture_output=True,
                env={**os.environ, "REFRESH_ALLOWED_UPDATED_GITLINKS": f"plugins/enabled={oid}"},
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            subprocess.run(["git", "add", "plugins/enabled"], cwd=root, check=True)
            extraneous = subprocess.run(
                ["bash", "refresh.sh"],
                cwd=root,
                text=True,
                capture_output=True,
                env={**os.environ, "REFRESH_ALLOWED_UPDATED_GITLINKS": f"plugins/enabled={oid}"},
            )

            self.assertNotEqual(extraneous.returncode, 0)


if __name__ == "__main__":
    unittest.main()
