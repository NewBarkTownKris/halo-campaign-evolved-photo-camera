"""Build reproducible Halo Photo Mode archives and their SHA-256 manifest."""

import argparse
import hashlib
from pathlib import Path
import re
import tempfile
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.1.0"
MOD = "mod/HaloPhotoMode/"
PLATFORMS = ("windows", "linux-proton")
SCRIPTS = ("finder", "focus", "gamepad", "main", "mouselook", "optics", "session", "shutter")


def members(platform):
    files = {path: path for path in (
        "README.md", "IMPLEMENTATION_PLAN.md", MOD + "LICENSE", MOD + "enabled.txt",
        "tools/install_runtime.py", "tools/doctor.py", "tools/capture.py",
        *(MOD + "Scripts/" + name + ".lua" for name in SCRIPTS),
    )}
    files["LICENSE"] = MOD + "LICENSE"
    if platform == "windows":
        for name in ("Install-Windows.cmd", "Start-Windows-Capture.cmd", "capture_windows.py", "WINDOWS.md"):
            files[name] = "packaging/windows/" + name
    else:
        for name in ("install.py", "INSTALL-Linux.md"):
            relative = "packaging/linux/" + name
            files[relative] = relative
        files["INSTALL-Linux.md"] = "packaging/linux/INSTALL-Linux.md"
    return files


def build_archive(path, platform):
    with ZipFile(path, "w") as archive:
        for dest, src in sorted(members(platform).items()):
            source = ROOT / src
            if source.is_symlink() or not source.is_file():
                raise ValueError(f"Missing or invalid release input: {src}")
            # All entries are text; keep their bytes stable with either Git checkout line ending.
            data = source.read_bytes().replace(b"\r\n", b"\n")
            if dest.endswith(".cmd"):
                data = data.replace(b"\n", b"\r\n")
            entry = ZipInfo(dest, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, data, compress_type=ZIP_DEFLATED, compresslevel=9)


def build(output, version):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?", version):
        raise ValueError("Pass the version without its v prefix, for example 0.1.0.")
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".release-", dir=output) as temp:
        work = Path(temp)
        products = []
        hashes = []
        for platform in PLATFORMS:
            name = f"HaloPhotoMode-{version}-{platform}.zip"
            package = work / name
            build_archive(package, platform)
            hashes.append(f"{hashlib.sha256(package.read_bytes()).hexdigest()}  {name}\n")
            products.append(package)
        manifest = work / "SHA256SUMS.txt"
        manifest.write_bytes("".join(hashes).encode("ascii"))
        for product in [*products, manifest]:
            product.replace(output / product.name)
            print(output / product.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=VERSION, help="version without the v prefix (default: %(default)s)")
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    try:
        build(args.output, args.version)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")
