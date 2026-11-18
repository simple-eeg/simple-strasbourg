"""Exercise the Windows command used by MATLAB's file-link safeguard."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name == "nt", "Windows fsutil check")
class WindowsHardLinks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.environ.get("SIMPLE_TEST_REQUIRE_NONADMIN") == "1":
            import ctypes

            if ctypes.windll.shell32.IsUserAnAdmin():
                raise AssertionError("The standard-user check still has administrator access.")

    def test_link_list_matches_filesystem_count(self):
        with tempfile.TemporaryDirectory(prefix="simple links ") as directory:
            target = Path(directory) / "recording é.set"
            target.write_bytes(b"synthetic fixture")
            self.assertEqual(self.link_count(target), target.stat().st_nlink)
            alias = Path(directory) / "second name.set"
            os.link(target, alias)
            self.assertEqual(self.link_count(target), 2)
            self.assertEqual(self.link_count(alias), target.stat().st_nlink)

    def test_missing_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(AssertionError):
                self.link_count(Path(directory) / "missing.set")

    def link_count(self, path):
        executable = Path(os.environ["SystemRoot"]) / "System32" / "fsutil.exe"
        result = subprocess.run(
            [str(executable), "hardlink", "list", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue(lines and all(line.startswith("\\") for line in lines))
        return len(lines)


if __name__ == "__main__":
    unittest.main(verbosity=2)
