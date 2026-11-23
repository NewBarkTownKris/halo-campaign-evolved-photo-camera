import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

from tools import capture


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux display helper")
class CaptureTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.directory = Path(tmp.name)
        self.fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, self.fd)
        self.stage = self.directory / ".Halo_20261123_170000_0001_0123abcd.pending.png"
        self.request = self.directory / (self.stage.name + ".request")
        self.content = f"HALO-PNG-1\n{self.stage.name}\n5 3 1 1 3 2\n"
        self.request.write_text(self.content, encoding="utf-8")

    def test_display_crop_and_window_identity(self):
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow is required for host capture")
        source = Image.new("RGB", (5, 3))
        for y in range(3):
            for x in range(5):
                source.putpixel((x, y), (x * 17, y * 19, x + y))

        def run(argv, **kwargs):
            if argv[:2] == ["xdotool", "search"]:
                self.assertIn("--onlyvisible", argv)
                return subprocess.CompletedProcess(argv, 0, "121\n300")
            if argv[:2] == ["xdotool", "getwindowname"]:
                return subprocess.CompletedProcess(argv, 0, "Halo: Campaign Evolved  \n")
            if argv[0] == "xprop":
                classes = '"other"' if argv[2] == "121" else '"exe", "steam_app_2806050"'
                return subprocess.CompletedProcess(argv, 0, "WM_CLASS(STRING) = " + classes)
            self.assertEqual(argv[0], "import")
            self.assertEqual(argv[argv.index("-window") + 1], "300")
            source.save(kwargs["stdout"], format="PNG")
            return subprocess.CompletedProcess(argv, 0)

        with patch.object(capture.subprocess, "run", side_effect=run):
            self.assertTrue(capture.stage_request(self.fd, self.request.name))
            self.assertFalse(capture.stage_request(self.fd, self.request.name))
        with Image.open(self.stage) as result:
            self.assertEqual(result.size, (3, 2))
            self.assertEqual(result.tobytes(), source.crop((1, 1, 4, 3)).tobytes())
        self.assertTrue(self.request.is_file())  # The Lua shutter owns request cancellation.

    def test_wrong_raster_size_is_rejected(self):
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow is required for host capture")
        def wrong_size(argv, **kwargs):
            Image.new("RGB", (4, 4)).save(kwargs["stdout"], format="PNG")
        with patch.object(capture, "window_id", return_value="32"), \
                patch.object(capture.subprocess, "run", side_effect=wrong_size):
            with self.assertRaisesRegex(ValueError, "expected"):
                capture.stage_request(self.fd, self.request.name)
        self.assertEqual(list(self.directory.iterdir()), [self.request])

    def test_cancellation_and_symlinks_do_not_publish(self):
        def cancel(viewport, box, stream):
            stream.write(b"partial")
            self.request.unlink()
        self.assertFalse(capture.stage_request(self.fd, self.request.name, cancel))
        self.assertEqual(list(self.directory.iterdir()), [])
        target = self.directory / "unrelated"
        target.write_text(self.content)
        self.request.symlink_to(target)
        self.assertFalse(capture.stage_request(self.fd, self.request.name))
        self.request.unlink()
        self.request.write_text(self.content)
        self.stage.symlink_to(target)
        self.assertFalse(capture.stage_request(self.fd, self.request.name))
        self.assertEqual(target.read_text(), self.content)
        self.assertFalse(capture.stage_request(self.fd, "../" + self.request.name))
        self.stage.unlink()
        def racing_destination(viewport, box, stream):
            self.stage.write_bytes(b"native")
            stream.write(b"helper")
        self.assertFalse(capture.stage_request(self.fd, self.request.name, racing_destination))
        self.assertEqual(self.stage.read_bytes(), b"native")

    def test_malformed_out_of_bounds_and_stale_requests(self):
        for text in (self.content.replace(self.stage.name, "../bad.png"),
                     self.content.replace("3 2\n", "5 2\n"),
                     self.content.replace("5 3 1 1", "16000 16000 1 1")):
            self.request.write_text(text)
            with self.assertRaises(ValueError):
                capture.stage_request(self.fd, self.request.name)
        self.request.write_text(self.content)
        old = time.time() - 120
        os.utime(self.request, (old, old))
        self.assertFalse(capture.stage_request(self.fd, self.request.name))
        self.assertFalse(self.stage.exists())

    def test_once_refreshes_and_removes_owned_heartbeat(self):
        def staged(directory, name):
            ready = self.directory / capture.READY
            self.assertLessEqual(abs(int(ready.read_text()) - time.time()), 2)
            return True
        with patch.object(capture, "stage_request", side_effect=staged):
            self.assertEqual(capture.watch(self.fd, True, None), 0)
        self.assertFalse((self.directory / capture.READY).exists())
        self.request.unlink()
        self.assertEqual(capture.watch(self.fd, True, None), 1)
        target = self.directory / "keep"
        target.write_text("keep")
        (self.directory / capture.READY).symlink_to(target)
        with self.assertRaises(ValueError):
            capture.watch(self.fd, True, None)
        self.assertEqual(target.read_text(), "keep")

    def run_launcher(self, directory, code=7, argv=None):
        if argv is None:
            argv = ["/path with spaces/proton", "run", "Game.exe"]
        child = Mock(poll=Mock(return_value=None), wait=Mock(return_value=code))
        errors = io.StringIO()
        with patch.object(capture.subprocess, "Popen", return_value=child) as start, \
                contextlib.redirect_stderr(errors), patch.dict(os.environ, {"DISPLAY": ":mock"}):
            status = capture.main(["--directory", str(directory), "--run", *argv])
        self.assertEqual(status, code)
        start.assert_called_once_with(argv)
        child.wait.assert_called_once_with()
        child.terminate.assert_not_called()
        return errors.getvalue()

    def test_steam_command_with_multiple_option_terminators_passes_verbatim(self):
        steam = "/home/tester/.local/share/Steam"
        command = [steam + "/ubuntu12_32/steam-launch-wrapper", "--",
                   steam + "/steamrt64/reaper", "SteamLaunch", "AppId=2806050", "--",
                   "/test-library/steamapps/common/SteamLinuxRuntime_sniper/_v2-entry-point",
                   "--verb=waitforexitandrun", "--", "/path with spaces/proton", "waitforexitandrun",
                   "/path with spaces/Meteorite/Binaries/Win64/HaloCampaignEvolved.exe"]
        with patch.object(capture, "run_helper", return_value=0):
            self.assertEqual(self.run_launcher(self.directory, argv=command), "")

    def test_missing_tools_or_directory_still_launch_the_game_once(self):
        with patch.dict(sys.modules, {"PIL": Mock()}), patch.object(capture.shutil, "which", return_value=None):
            self.assertIn("Missing required executable", self.run_launcher(self.directory))
        with patch.dict(sys.modules, {"PIL": None}):
            self.assertIn("Halo capture disabled", self.run_launcher(self.directory))
        with patch.dict(sys.modules, {"PIL": Mock()}), patch.object(capture.shutil, "which", return_value="installed"):
            self.assertIn("Halo capture disabled", self.run_launcher(self.request))

    def test_locked_directory_preserves_game_and_other_helpers_marker(self):
        import fcntl
        fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        marker = self.directory / capture.READY
        marker.write_text("owned by existing helper")
        with patch.dict(sys.modules, {"PIL": Mock()}), patch.object(capture.shutil, "which", return_value="installed"):
            self.assertIn("Halo capture disabled", self.run_launcher(self.directory))
        self.assertEqual(marker.read_text(), "owned by existing helper")

    def test_runtime_heartbeat_failure_keeps_running_child(self):
        self.request.unlink()
        beat = capture.heartbeat
        def fail_second_beat(fd):
            if (self.directory / capture.READY).exists():
                raise OSError("heartbeat failed after startup")
            beat(fd)
        with patch.dict(sys.modules, {"PIL": Mock()}), patch.object(capture, "heartbeat", side_effect=fail_second_beat), \
                patch.object(capture.shutil, "which", return_value="installed"):
            self.assertIn("heartbeat failed after startup", self.run_launcher(self.directory))
        self.assertFalse((self.directory / capture.READY).exists())


if __name__ == "__main__":
    unittest.main()
