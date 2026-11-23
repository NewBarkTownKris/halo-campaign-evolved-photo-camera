"""Develop Halo scene-linear EXRs into full-range 16-bit LogC3 and F-Log TIFFs."""

import argparse
import math
import os
from pathlib import Path
import sys
import tempfile


# Gamut transforms and log curves adapted from Denshattack! Photo Camera (MIT).
D65 = (0.3127, 0.3290)
REC709 = (0.640, 0.330, 0.300, 0.600, 0.150, 0.060, *D65)
AWG3 = (0.684, 0.313, 0.221, 0.848, 0.0861, -0.102, *D65)
F_GAMUT = (0.708, 0.292, 0.170, 0.797, 0.131, 0.046, *D65)
PROFILES = {"logc3": "ARRI Wide Gamut 3 / LogC3 EI 800", "flog": "Fujifilm F-Gamut / F-Log"}


def read_linear_exr(path, assume_rec709=False):
    import numpy as np
    import OpenEXR

    with OpenEXR.File(str(path), separate_channels=True) as image:
        if len(image.parts) != 1:
            raise ValueError("Expected a single-part scene-linear RGB EXR")
        header = image.header()
        space = header.get("colorInteropID", "unknown")
        if space not in ("lin_rec709_scene", "unknown") or header.get("acesImageContainerFlag", 0):
            raise ValueError("EXR declares a different color space. Expected scene-linear Rec.709/D65")
        chroma = header.get("chromaticities")
        if chroma is not None:
            if not np.allclose(chroma, REC709, rtol=0, atol=0.0001):
                raise ValueError("EXR chromaticities differ from Rec.709/D65")
        elif space == "unknown" and not assume_rec709:
            raise ValueError("Untagged EXR. Use --assume-rec709 only for known scene-linear Rec.709/D65")
        planes = []
        channels = image.channels()
        for name in "RGB":
            channel = channels.get(name)
            if channel is None or channel.xSampling != 1 or channel.ySampling != 1:
                raise ValueError("Expected full-resolution R, G and B channels")
            plane = channel.pixels
            if plane.ndim != 2 or plane.dtype not in (np.float16, np.float32):
                raise ValueError("Expected flat half- or single-precision RGB samples")
            if not np.isfinite(plane).all():
                raise ValueError(f"Non-finite samples in channel {name}")
            planes.append(plane)
        return np.stack(planes, axis=-1, dtype=np.float32)


def rgb_to_xyz(primaries):
    import numpy as np

    xy = np.asarray(primaries).reshape(4, 2)
    xyz = np.column_stack((xy, 1 - xy.sum(axis=1))) / xy[:, 1:2]
    axes = xyz[:3].T
    return axes * np.linalg.solve(axes, xyz[3])


def encode(linear, profile):
    import numpy as np

    # ARRI ALEXA Log C Curve – Usage in VFX, 2017, exposure domain (SUP 3.x).
    # https://www.arri.com/resource/blob/31918/66f56e6abb6e5b6553929edf9aa7483e/2017-03-alexa-logc-curve-in-vfx-data.pdf
    # Fujifilm F-Log Data Sheet v1.2 (original F-Log).
    # https://dl.fujifilm-x.com/technical-data/F-Log_DataSheet_E_Ver.1.2.pdf
    if profile == "logc3":
        a, b, c, d, e, f = 5.555556, 0.052272, 0.247190, 0.385537, 5.367655, 0.092809
        use_log = linear > 0.010591
    elif profile == "flog":
        a, b, c, d, e, f = 0.555556, 0.009468, 0.344676, 0.790453, 8.735631, 0.092864
        use_log = linear >= 0.00089
    else:
        raise ValueError(f"Unknown log profile {profile}")
    encoded = e * linear + f
    encoded[use_log] = c * np.log10(a * linear[use_log] + b) + d
    return encoded


def write_tiff(output, rgb, profile, exposure):
    import numpy as np
    import OpenImageIO as oiio

    transform = np.linalg.solve(rgb_to_xyz({"logc3": AWG3, "flog": F_GAMUT}[profile]), rgb_to_xyz(REC709))
    height, width = rgb.shape[:2]

    def blocks():
        # Bound temporary float64 arrays even for 4K landscape and portrait shots.
        for start in range(0, height, 64):
            yield start, rgb[start:start + 64] @ transform.T

    if exposure is None:
        peak = np.array([max(float(block.max()) for _, block in blocks())])
        exposure = 0
        while encode(peak, profile)[0] > 1:
            peak *= 0.5
            exposure -= 1
    gain = 2.0 ** exposure
    if not math.isfinite(gain) or gain == 0:
        raise ValueError("Exposure offset is outside the representable range")
    spec = oiio.ImageSpec(width, height, 3, oiio.UINT16)
    spec.attribute("compression", "zip")
    spec.attribute("Software", "Halo: Campaign Evolved Photo Mode")
    spec.attribute("ImageDescription", f"{PROFILES[profile]}. Full range 0-65535. "
                   f"Source scene-linear Rec.709/D65. Exposure offset {exposure:g} stops.")
    low = high = 0
    with tempfile.TemporaryDirectory(prefix=".halo-grade-", dir=output.parent) as folder:
        stage = Path(folder) / "photo.tiff"
        writer = oiio.ImageOutput.create(str(stage))
        if writer is None or not writer.open(str(stage), spec):
            raise OSError(oiio.geterror() if writer is None else writer.geterror())
        try:
            for start, block in blocks():
                scaled = block * gain
                if not np.isfinite(scaled).all():
                    raise ValueError("Exposure offset produced non-finite samples")
                encoded = encode(scaled, profile)
                low += int(np.count_nonzero(encoded < 0))
                high += int(np.count_nonzero(encoded > 1))
                codes = np.rint(np.clip(encoded, 0, 1) * 65535).astype(np.uint16)
                if not writer.write_scanlines(start, start + len(codes), 0, codes):
                    raise OSError(writer.geterror())
        finally:
            if not writer.close():
                raise OSError(writer.geterror())
        # Publish complete strips without replacing a peer's output or an existing grade.
        if os.name == "nt":
            stage.rename(output)
        else:
            os.link(stage, output)
    return exposure, low, high


def default_directory():
    if os.name == "nt":
        return Path(os.environ["LOCALAPPDATA"]) / "Meteorite/Saved/Screenshots/Windows"
    if __package__:
        from . import capture
    else:
        import capture
    return capture.default_directory()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path, help="EXR or folder (default: Halo screenshot folder)")
    parser.add_argument("--format", choices=("all", *PROFILES), default="all")
    parser.add_argument("--ev", type=float, help="Exposure offset in stops (default: fit highlights)")
    parser.add_argument("--assume-rec709", action="store_true", help="Accept untagged known scene-linear Rec.709/D65 EXRs")
    args = parser.parse_args(argv)
    if args.ev is not None and not math.isfinite(args.ev):
        parser.error("--ev must be finite")
    try:
        source = args.source or default_directory()
        if source.is_dir():
            shots = sorted(p for p in source.iterdir() if p.is_file() and p.suffix.lower() == ".exr"
                           and not p.name.startswith(".") and not p.name.lower().endswith(".source.exr"))
        elif source.is_file() and source.suffix.lower() == ".exr":
            shots = [source]
        else:
            parser.error(f"Choose an existing EXR or screenshot folder: {source}")
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")

    saved = kept = failed = 0
    profiles = PROFILES if args.format == "all" else [args.format]
    for shot in shots:
        rgb = None
        for profile in profiles:
            output = shot.with_name(f"{shot.stem}_{profile}.tiff")
            if output.is_file():
                kept += 1
                continue
            try:
                if rgb is None:
                    rgb = read_linear_exr(shot, args.assume_rec709)
                exposure, low, high = write_tiff(output, rgb, profile, args.ev)
                print(f"Saved {output} ({exposure:+g} EV, {low} low and {high} high channel samples clipped)")
                saved += 1
            except ImportError as error:
                parser.exit(1, f"Missing photo developer dependency: {error}. "
                               "Install requirements-develop.txt with this Python.\n")
            except (OSError, ValueError, RuntimeError, OverflowError) as error:
                if isinstance(error, FileExistsError) and output.is_file():
                    kept += 1
                else:
                    print(f"{shot} ({profile}): {error}", file=sys.stderr)
                    failed += 1
                if rgb is None:
                    break
    print(f"Checked {len(shots)} EXR(s). Saved {saved} TIFF(s), kept {kept} existing.")
    return int(failed > 0)


if __name__ == "__main__":
    sys.exit(main())
