import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("package_windows", ROOT / "windows/packaging/package_windows.py")
package_windows = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package_windows)

TERMS = "MICROSOFT SOFTWARE LICENSE TERMS\nsynthetic Windows App SDK terms line\n"


class BuildLicenseTests(unittest.TestCase):
    def make_snapshot(self, root, with_terms=True):
        snapshot = root / "snapshot"
        (snapshot / "windows/packaging").mkdir(parents=True)
        (snapshot / "windows/packaging/license-intro-ko.txt").write_text(
            (ROOT / "windows/packaging/license-intro-ko.txt").read_text(encoding="utf-8"), encoding="utf-8")
        (snapshot / "LICENSE").write_text("MIT License\n\nsynthetic copyright\n", encoding="utf-8")
        obj = snapshot / "windows/DoIt.Windows/obj"
        obj.mkdir(parents=True)
        packages = root / "packages"
        package = packages / "microsoft.windowsappsdk.foundation/2.6.5"
        package.mkdir(parents=True)
        if with_terms:
            (package / "license.txt").write_text(TERMS, encoding="utf-8")
        assets = {
            "libraries": {"Microsoft.WindowsAppSDK.Foundation/2.6.5": {
                "type": "package", "path": "microsoft.windowsappsdk.foundation/2.6.5"}},
            "packageFolders": {str(packages): {}},
        }
        (obj / "project.assets.json").write_text(json.dumps(assets), encoding="utf-8")
        return snapshot, snapshot / "windows/DoIt.Windows/DoIt.Windows.csproj"

    def test_agreement_has_bom_notice_mit_and_terms_verbatim(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot, project = self.make_snapshot(root)
            output = package_windows.build_license(snapshot, project, root / "license.txt")
            data = output.read_bytes()
            self.assertTrue(data.startswith(b"\xef\xbb\xbf"))
            text = data[3:].decode("utf-8")
            self.assertIn("DoIt 사용권 안내", text)
            self.assertIn("MIT License", text)
            self.assertIn("synthetic Windows App SDK terms line", text)
            self.assertLess(text.index("사용권 안내"), text.index("MIT License"))
            self.assertLess(text.index("MIT License"), text.index("MICROSOFT SOFTWARE LICENSE TERMS"))
            self.assertNotIn("\n", text.replace("\r\n", ""))

    def test_missing_windows_app_sdk_terms_stops_packaging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot, project = self.make_snapshot(root, with_terms=False)
            with self.assertRaises(ValueError):
                package_windows.build_license(snapshot, project, root / "license.txt")


if __name__ == "__main__":
    unittest.main()
