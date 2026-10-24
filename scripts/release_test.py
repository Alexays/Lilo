"""Exercise release preparation with the pinned Changie binary and temporary app files."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
CHANGIE = os.environ.get("CHANGIE", "")
CONFIG = Path("Xcode/Configs/Base.xcconfig")
DIRECTORIES = [Path("lilo-ui"), Path("Lilo/Extensions/bridge-src")]
BASE = "SWIFT_VERSION = 6.0\nCURRENT_PROJECT_VERSION = 5\nMARKETING_VERSION = 0.1.4\n"
HISTORY = "## [0.1.4] - 2026-10-24\n\n- Existing release.\n"
SITE_PAGES = [Path("site/public/index.html"), Path("site/public/fr/index.html")]
PAGE = '<script type="application/ld+json">{"@type":"SoftwareApplication","softwareVersion":"0.1.4"}</script>\n'


def setUpModule():
    if not CHANGIE:
        raise RuntimeError("Set CHANGIE to the Changie binary, as make release-test does")


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lilo-release-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        shutil.copy(ROOT / ".changie.yaml", self.root)
        self.write(".changes/header.md", "# Changelog\n")
        self.write(".changes/v0.1.4.md", HISTORY)
        self.write(".changes/unreleased/.gitkeep", "")
        self.write("CHANGELOG.md", "# Changelog\n\n" + HISTORY)
        self.write(CONFIG, BASE)
        for page in SITE_PAGES:
            self.write(page, PAGE)
        for directory in DIRECTORIES:
            package = {"name": directory.name, "private": True, "version": "0.1.4"}
            self.write(directory / "package.json", json.dumps(package, indent=2) + "\n")
            lock = dict(package, lockfileVersion=3, packages={
                "": package,
                "node_modules/example": {"version": "1.2.3"},
            })
            self.write(directory / "package-lock.json", json.dumps(lock, indent=2) + "\n")

    def write(self, file, content):
        path = self.root / file
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def read(self, file):
        return (self.root / file).read_text()

    def snapshot(self):
        return {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}

    def run_release(self, command, success=True):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/release.py"), command, "--changie", CHANGIE],
            cwd=self.root, capture_output=True, text=True, check=False,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def note(self, kind):
        result = subprocess.run(
            [CHANGIE, "new", "--kind", kind, "--body", "Fix tab switching.", "--interactive=false"],
            cwd=self.root, capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_versions(self, version, build=6):
        self.assertEqual(self.read(CONFIG), BASE.replace("= 5", f"= {build}").replace("0.1.4", version))
        for directory in DIRECTORIES:
            self.assertEqual(json.loads(self.read(directory / "package.json"))["version"], version)
            lock = json.loads(self.read(directory / "package-lock.json"))
            self.assertEqual(lock["version"], version)
            self.assertEqual(lock["packages"][""]["version"], version)
            self.assertEqual(lock["packages"]["node_modules/example"]["version"], "1.2.3")
        for page in SITE_PAGES:
            self.assertEqual(self.read(page), PAGE.replace("0.1.4", version))
        self.assertFalse((self.root / "package.json").exists())
        self.assertFalse((self.root / "package-lock.json").exists())
        self.assertFalse((self.root / "node_modules").exists())

    def test_empty_release_is_read_only_and_does_not_bump(self):
        before = self.snapshot()
        self.run_release("status")
        self.assertEqual(self.snapshot(), before)
        self.run_release("version")
        self.assertEqual(self.snapshot(), before)
        self.assert_versions("0.1.4", build=5)

    def test_patch_release(self):
        self.check_release("Fixed", "0.1.5")

    def test_minor_release(self):
        self.check_release("Added", "0.2.0")

    def test_major_release(self):
        self.check_release("Breaking", "1.0.0")

    def check_release(self, kind, version):
        self.note(kind)
        before = self.snapshot()
        self.run_release("status")
        self.assertEqual(self.snapshot(), before)
        self.run_release("version")
        self.assert_versions(version)
        self.assertIn("Fix tab switching.", self.read("CHANGELOG.md"))
        self.assertTrue(self.read("CHANGELOG.md").endswith(HISTORY))
        self.assertEqual(self.read(".changes/v0.1.4.md"), HISTORY)
        self.assertFalse(list((self.root / ".changes/unreleased").glob("*.yaml")))
        released = self.snapshot()
        self.run_release("version")
        self.run_release("status")
        self.assertEqual(self.snapshot(), released)

    def test_highest_pending_bump_wins(self):
        for kind in ["Fixed", "Breaking", "Added"]:
            self.note(kind)
        self.run_release("version")
        self.assert_versions("1.0.0")
        self.assertEqual(self.read("CHANGELOG.md").count("Fix tab switching."), 3)

    def test_notes_of_one_kind_written_within_a_second_are_all_kept(self):
        for _ in range(3):
            self.note("Fixed")
        self.assertEqual(len(list((self.root / ".changes/unreleased").glob("*.yaml"))), 3)

    def test_invalid_notes_leave_release_files_alone(self):
        for content in ["kind: Unknown\nbody: Invalid note\n", "kind: [\n"]:
            with self.subTest(content=content):
                self.write(".changes/unreleased/invalid.yaml", content)
                before = self.snapshot()
                self.run_release("status", success=False)
                self.run_release("version", success=False)
                self.assertEqual(self.snapshot(), before)

    def test_unreadable_app_files_keep_the_notes(self):
        self.note("Fixed")
        self.write(DIRECTORIES[0] / "package.json", "{}\n")
        before = self.snapshot()
        self.run_release("version", success=False)
        self.assertEqual(self.snapshot(), before)

    def test_a_release_bumps_the_build_even_when_the_app_version_was_set_by_hand(self):
        self.write(CONFIG, BASE.replace("0.1.4", "0.1.5"))
        self.note("Fixed")
        self.run_release("version")
        self.assertEqual(self.read(CONFIG), BASE.replace("= 5", "= 6").replace("0.1.4", "0.1.5"))

    def test_status_ignores_package_formatting(self):
        for directory in DIRECTORIES:
            path = directory / "package.json"
            self.write(path, json.dumps(json.loads(self.read(path)), indent="\t"))
        before = self.snapshot()
        self.run_release("status")
        self.run_release("version")
        self.assertEqual(self.snapshot(), before)

    def test_stale_versions_are_checked_without_writing_and_repaired_once(self):
        self.write(".changes/v0.1.5.md", "## [0.1.5]\n\n- New release.\n")
        before = self.snapshot()
        self.run_release("status", success=False)
        self.assertEqual(self.snapshot(), before)
        self.run_release("version")
        self.assert_versions("0.1.5")
        lock_path = DIRECTORIES[0] / "package-lock.json"
        stale = self.read(lock_path).replace("0.1.5", "0.1.4")
        self.write(lock_path, stale)
        before = self.snapshot()
        self.run_release("status", success=False)
        self.assertEqual(self.snapshot(), before)
        self.run_release("version")
        self.assert_versions("0.1.5")
        self.run_release("status")

    def test_status_checks_the_generated_changelog(self):
        self.write("CHANGELOG.md", "Out of date.\n")
        before = self.snapshot()
        self.run_release("status", success=False)
        self.assertEqual(self.snapshot(), before)
        self.run_release("version")
        self.run_release("status")
        self.assertEqual(self.read("CHANGELOG.md"), "# Changelog\n\n" + HISTORY)


if __name__ == "__main__":
    unittest.main()
