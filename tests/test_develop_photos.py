import contextlib
import io
from pathlib import Path
import tempfile
import unittest

from tools import develop_photos as develop

try:
    import numpy as np
    import OpenEXR
    import OpenImageIO as oiio
except ImportError:
    oiio = None


@unittest.skipUnless(oiio, "optional photo development dependencies")
class DevelopPhotosTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name)

    def master(self, name, pixels, **header):
        source = self.folder / name
        OpenEXR.File(header, {"RGB": pixels}).write(str(source))
        return source

    def cli(self, *args):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return develop.main([str(arg) for arg in args])

    def read_tiff(self, name):
        reader = oiio.ImageInput.open(str(self.folder / name))
        self.assertIsNotNone(reader)
        try:
            spec = reader.spec()
            self.assertEqual(spec.format, oiio.UINT16)
            self.assertEqual(spec.nchannels, 3)
            self.assertEqual(spec.get_int_attribute("tiff:PhotometricInterpretation"), 2)
            return reader.read_image(oiio.UINT16), spec.get_string_attribute("ImageDescription")
        finally:
            reader.close()

    def test_published_chart_and_hdr_samples_reach_tiff(self):
        gray = np.array([0, .18, .9, 2, 4], dtype=np.float32)
        pixels = np.repeat(gray[:, None], 3, axis=1)[None, ...]
        source = self.master("Halo photo.exr", pixels, chromaticities=develop.REC709)
        self.assertEqual(self.cli(source), 0)
        # Published chart levels and additional neutral highlights using the vendor curves.
        for profile, expected in [("logc3", [95, 400, 572, 659, 735]), ("flog", [95, 470, 705, 826, 932])]:
            image, desc = self.read_tiff(f"Halo photo_{profile}.tiff")
            self.assertIn(develop.PROFILES[profile], desc)
            self.assertIn("Exposure offset 0 stops", desc)
            np.testing.assert_array_equal(image[0, :, 0], image[0, :, 1])
            np.testing.assert_array_equal(image[0, :, 0], image[0, :, 2])
            np.testing.assert_array_equal(np.rint(image[0, :, 0].astype(float) * 1023 / 65535), expected)

    def test_primary_response_and_highlight_offset(self):
        # Standard Rec.709 red, transformed into each destination RGB via XYZ/D65.
        red = np.array([[[1, 0, 0]]], dtype=np.float32)
        self.master("red.exr", red, colorInteropID="lin_rec709_scene")
        white = np.full((3, 2, 3), 64, dtype=np.float16)
        self.master("white.exr", white, colorInteropID="lin_rec709_scene")
        self.assertEqual(self.cli(self.folder), 0)
        for profile, red_primary, stops in [
            ("logc3", [.631321, .036820, .017370], -1),
            ("flog", [.627404, .069097, .016391], -4),
        ]:
            primary, _ = self.read_tiff(f"red_{profile}.tiff")
            expected = develop.encode(np.array(red_primary), profile) * 65535
            np.testing.assert_allclose(primary[0, 0], expected, atol=1)
            highlight, desc = self.read_tiff(f"white_{profile}.tiff")
            self.assertIn(f"Exposure offset {stops} stops", desc)
            self.assertGreater(highlight.max(), 50_000)
            self.assertLess(highlight.max(), 65_535)

    def test_existing_outputs_are_independent_and_failures_leave_good_shots(self):
        pixels = np.ones((2, 3, 3), dtype=np.float16)
        source = self.master("réseau.EXR", pixels, chromaticities=develop.REC709)
        original = source.read_bytes()
        kept = self.folder / "réseau_logc3.tiff"
        kept.write_bytes(b"existing photo")
        (self.folder / "bad.exr").write_bytes(b"invalid file")
        self.master(".Halo_staged.source.exr", pixels, chromaticities=develop.REC709)
        self.assertEqual(self.cli(self.folder), 1)
        self.assertEqual(kept.read_bytes(), b"existing photo")
        self.assertEqual(source.read_bytes(), original)
        self.assertTrue((self.folder / "réseau_flog.tiff").is_file())
        self.assertEqual(len(list(self.folder.glob("*.tiff"))), 2)
        self.assertEqual(self.cli(source), 0)

    def test_rejects_untagged_conflicting_nonfloat_and_missing_channels(self):
        pixels = np.ones((2, 3, 3), dtype=np.float16)
        source = self.master("scene.exr", pixels)
        self.assertEqual(self.cli(source), 1)
        # Even an explicit override for *untagged* linear masters cannot bypass conflicting tags.
        for hdr in [
            {"chromaticities": develop.F_GAMUT},
            {"colorInteropID": "srgb_rec709_scene", "chromaticities": develop.REC709},
        ]:
            self.master(source.name, pixels, **hdr)
            self.assertEqual(self.cli(source, "--assume-rec709"), 1)
        self.master(source.name, pixels.astype(np.uint32), chromaticities=develop.REC709)
        self.assertEqual(self.cli(source), 1)
        OpenEXR.File({"chromaticities": develop.REC709}, {"R": pixels[..., 0].copy()}).write(str(source))
        self.assertEqual(self.cli(source), 1)
        pixels[0, 0, 1] = np.inf
        self.master(source.name, pixels, chromaticities=develop.REC709)
        self.assertEqual(self.cli(source), 1)
        self.assertFalse(list(self.folder.glob("*.tiff")))


if __name__ == "__main__":
    unittest.main()
