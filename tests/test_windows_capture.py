import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

try:
    from PIL import Image, ImageGrab
except ImportError:
    Image = ImageGrab = None

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "packaging/windows"))
import capture_windows


class WindowsShutterTests(unittest.TestCase):
    def test_foreground_owner_must_be_halo(self):
        for name in ("HaloCampaignEvolved.exe", "steam.exe"):
            user, kernel = Mock(), Mock()
            user.GetForegroundWindow.return_value = 450
            user.GetWindowThreadProcessId.return_value = 99
            kernel.OpenProcess.return_value = 140

            def fill_name(handle, flags, buffer, size):
                buffer.value = "C:\\Games\\" + name
                return True

            kernel.QueryFullProcessImageNameW.side_effect = fill_name
            with self.subTest(name=name), patch.object(capture_windows.ctypes, "WinDLL",
                                                       side_effect=[user, kernel], create=True):
                if name == "steam.exe":
                    with self.assertRaisesRegex(ValueError, "foreground"):
                        capture_windows.game_window()
                else:
                    self.assertEqual(capture_windows.game_window(), 450)
                kernel.CloseHandle.assert_called_once_with(140)

    @unittest.skipUnless(Image, "Pillow is required for host capture")
    def test_crops_pixels_from_the_identified_window(self):
        image = Image.new("RGB", (8, 6))
        image.putpixel((3, 2), (10, 20, 30))
        with patch.object(capture_windows, "game_window", return_value=456), \
                patch.object(ImageGrab, "grab", return_value=image) as grab:
            output = io.BytesIO()
            capture_windows.capture_window((8, 6), (3, 2, 7, 4), output)
        grab.assert_called_once_with(window=456)
        output.seek(0)
        with Image.open(output) as photo:
            self.assertEqual(photo.size, (4, 2))
            self.assertEqual(photo.getpixel((0, 0)), (10, 20, 30))

    @unittest.skipUnless(Image, "Pillow is required for host capture")
    def test_changed_focus_or_viewport_does_not_write(self):
        for handles, size in [([1, 2], (8, 6)), ([1, 1], (7, 6))]:
            with self.subTest(handles=handles, size=size), \
                    patch.object(capture_windows, "game_window", side_effect=handles), \
                    patch.object(ImageGrab, "grab", return_value=Image.new("RGB", size)):
                output = io.BytesIO()
                with self.assertRaises(ValueError):
                    capture_windows.capture_window((8, 6), (3, 2, 7, 4), output)
                self.assertEqual(output.getvalue(), b"")

    def test_protocol_stages_once_and_respects_cancellation(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory) / ".Halo_20261123_151500_0001_aabbccdd.pending.png"
            request = stage.with_name(stage.name + ".request")
            payload = f"HALO-PNG-1\n{stage.name}\n8 6 3 2 4 2\n"
            request.write_text(payload, encoding="ascii")

            def capture(viewport, crop, output):
                self.assertEqual(viewport, (8, 6))
                self.assertEqual(crop, (3, 2, 7, 4))
                output.write(b"staged")

            with patch.object(capture_windows, "capture_window", side_effect=capture) as grab:
                capture_windows.stage_request(request)
                capture_windows.stage_request(request)
                grab.assert_called_once()
                self.assertEqual(stage.read_bytes(), b"staged")
            stage.unlink()
            with patch.object(capture_windows, "capture_window", side_effect=lambda *args: request.unlink()):
                with self.assertRaises(FileNotFoundError):
                    capture_windows.stage_request(request)
            self.assertEqual(list(Path(directory).iterdir()), [])
