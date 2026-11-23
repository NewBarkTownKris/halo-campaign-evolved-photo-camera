import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import doctor


class SteamDoctorTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / "Steam"
        (self.root / "steamapps").mkdir(parents=True)

    def manifest(self, root, app_id=doctor.APP_ID, content=False):
        steamapps = root / "steamapps"
        steamapps.mkdir(parents=True, exist_ok=True)
        (steamapps / f"appmanifest_{doctor.APP_ID}.acf").write_text(
            '"AppState" { "appid" "' + app_id + '" "buildid" "9781" '
            '"installdir" "Halo Campaign Evolved" }', encoding="utf-8"
        )
        install = steamapps / "common/Halo Campaign Evolved"
        return (install / "Content" if content else install) / doctor.EXE

    def run_doctor(self, *args):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = doctor.main(["--steam-root", str(self.root), *args])
        return code, output.getvalue(), errors.getvalue()

    def test_primary_stale_copy_and_secondary_library(self):
        stale = self.manifest(self.root)
        stale.parent.mkdir(parents=True)
        (stale.parent / "vkd3d-proton.cache").touch()
        other = self.root.parent / "Other Games"
        quoted_path = json.dumps(str(other), ensure_ascii=False)
        (self.root / "steamapps/libraryfolders.vdf").write_text(
            f'"libraryfolders" {{ "1" {{ "path" {quoted_path} }} }}', encoding="utf-8"
        )
        exe = self.manifest(other)
        mods = exe.parent / "ue4ss/Mods"
        mods.mkdir(parents=True)
        exe.write_bytes(b"fixture")
        code, output, errors = self.run_doctor("--sha256")
        self.assertEqual(code, 0)
        self.assertIn("UE4SS core DLL: not found", output)
        self.assertIn("missing executable", errors)
        for field in (str(exe), str(mods), "build 9781", hashlib.sha256(b"fixture").hexdigest()):
            self.assertIn(field, output)
        self.assertEqual(output.count("Executable:"), 1)

    def test_content_layout_with_modern_or_legacy_loader(self):
        exe = self.manifest(self.root, content=True)
        exe.parent.mkdir(parents=True)
        exe.touch()
        for layout in (exe.parent / "ue4ss", exe.parent):
            with self.subTest(layout=layout.name):
                mods = layout / "Mods"
                mods.mkdir(parents=True)
                core = layout / "UE4SS.dll"
                core.touch()
                code, output, errors = self.run_doctor()
                self.assertEqual((code, errors), (0, ""))
                self.assertIn(f"Executable: {exe}", output)
                self.assertIn(f"UE4SS core DLL: {core}", output)
                self.assertIn(f"UE4SS Mods directory: {mods}", output)
                core.unlink()
                mods.rmdir()

    def test_wrong_app_and_untracked_executable_are_ignored(self):
        exe = self.manifest(self.root, app_id="976730")
        exe.parent.mkdir(parents=True)
        exe.touch()
        self.assertEqual(self.run_doctor()[0], 1)
        (self.root / "steamapps" / f"appmanifest_{doctor.APP_ID}.acf").unlink()
        self.assertEqual(self.run_doctor()[0], 1)

    def test_saved_profile_scopes_and_optional_hash(self):
        exe = self.manifest(self.root)
        exe.parent.mkdir(parents=True)
        exe.touch()
        appdata = self.root / "steamapps/compatdata/2806050/pfx/drive_c/users/steamuser/AppData/Local"
        settings = appdata / "Meteorite/Saved/Config/123/HaloGlobalGameUserSettings.ini"
        settings.parent.mkdir(parents=True)
        settings.write_text(
            "[HaloUserSettings]\nFieldOfView=105\nFieldOfView3rdPerson=100\nbHUDVisible=False\n"
            "AccountName=private\n[Other]\nFieldOfView=200\n", encoding="utf-8-sig"
        )
        with patch.dict(os.environ, {"LOCALAPPDATA": str(appdata)}):
            code, output, errors = self.run_doctor("--settings")
            _, plain_output, _ = self.run_doctor()
        self.assertEqual((code, errors), (0, ""))
        for key in ("FieldOfView=105", "FieldOfView3rdPerson=100", "bHUDVisible=False"):
            self.assertIn(key, output)
        for key in ("private", "FieldOfView=200", "SHA-256"):
            self.assertNotIn(key, output)
        self.assertNotIn("FieldOfView", plain_output)

    def test_invalid_manifest_reports_diagnostic(self):
        path = self.root / "steamapps" / f"appmanifest_{doctor.APP_ID}.acf"
        path.write_text('"AppState" {', encoding="utf-8")
        code, _, errors = self.run_doctor()
        self.assertEqual(code, 1)
        self.assertIn("incomplete VDF", errors)


if __name__ == "__main__":
    unittest.main()
