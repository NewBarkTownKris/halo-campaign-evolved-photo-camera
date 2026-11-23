"""Install the camera and configure the pinned Halo Steam profile on a fresh UE4SS v4 loader."""

import argparse
import hashlib
import io
import os
from pathlib import Path
import sys
import tempfile
from zipfile import BadZipFile, ZipFile

import doctor


ROOT = Path(__file__).resolve().parents[1]
MOD = "HaloPhotoMode"
CORE = "UE4SS_v4.0.0.zip"
CONFIGS = "zCustomGameConfigs.zip"
DIGESTS = {
    CORE: "251ad0d1381a241750e036f5918cbf2b5d7ec58ebc608cb2dd09d459d0c81e45",
    CONFIGS: "1fd90a875138534cc11a7aee802bfb4b4f08e8614ff1709796fb363e2dab9c2d",
}
PROXY_DIGEST = "21fafb3e49958e2b16721d57d5c1af3efcaaae6d91a430bb6124a67e80f5fb42"
PROFILE = "Halo Campaign Evolved/steam/"
PENDING = ".HaloPhotoMode-dwmapi.pending"


def game_binary_dir(game):
    if game:
        for layout in (game, game / "Content"):
            exe = layout / doctor.EXE
            if exe.is_file():
                return exe.resolve().parent
        raise ValueError("Point --game at the Halo installation from Steam's Browse local files.")
    for library in doctor.library_paths(doctor.default_roots()):
        try:
            result = doctor.locate(library)
        except (ValueError, OSError) as error:
            print(f"Skipping {library}: {error}", file=sys.stderr)
            continue
        if result:
            return result[1].resolve().parent
    raise ValueError("Halo Steam app 2806050 was not found. Pass --game and its installation folder.")


def verified_zip(folder, name):
    data = (folder / name).read_bytes()
    if hashlib.sha256(data).hexdigest() != DIGESTS[name]:
        raise ValueError(f"{name} differs from the pinned v4.0.0 release. Check the download.")
    return ZipFile(io.BytesIO(data))


def stage_loader(tree, archives):
    with verified_zip(archives, CORE) as core, verified_zip(archives, CONFIGS) as configs:
        tree.mkdir()
        (tree / PENDING).write_bytes(core.read("dwmapi.dll"))
        for name in ("UE4SS.dll", "LICENSE", "UE4SS_SDK_Backends/UE4SS.json"):
            target = tree / name
            target.parent.mkdir(exist_ok=True)
            target.write_bytes(core.read("ue4ss/" + name))
        ini = configs.read(PROFILE + "UE4SS-settings.ini")
        old = b"bForceGUObjectArrayForIteration = false"
        if ini.count(old) != 1:
            raise ValueError("Expected Halo profile setting was missing.")
        (tree / "UE4SS-settings.ini").write_bytes(ini.replace(old, b"bForceGUObjectArrayForIteration = true"))
        signatures = tree / "UE4SS_Signatures"
        signatures.mkdir()
        for name in ("FName_Constructor.lua", "GUObjectArray.lua", "ProcessLocalScriptFunction.lua"):
            (signatures / name).write_bytes(configs.read(PROFILE + "UE4SS_Signatures/" + name))
        (tree / "Mods").mkdir()
        (tree / "Mods/mods.txt").write_bytes(b"HaloPhotoMode : 1\r\n")


def activate(tree):
    pending = tree / PENDING
    proxy = tree.parent / "dwmapi.dll"
    if pending.is_symlink() or hashlib.sha256(pending.read_bytes()).hexdigest() != PROXY_DIGEST:
        raise ValueError(f"Unrecognized pending loader at {pending}")
    if os.path.lexists(proxy):
        if proxy.is_symlink() or hashlib.sha256(proxy.read_bytes()).hexdigest() != PROXY_DIGEST:
            raise ValueError(f"Another dwmapi.dll occupies {proxy}. Move the conflicting loader aside first.")
    elif os.name == "nt":
        pending.rename(proxy)  # On Windows rename refuses an existing destination.
        return
    else:
        os.link(pending, proxy)
    pending.unlink()


def mod_files(extras):
    source = ROOT / "mod" / MOD
    files = {p.relative_to(source): p.read_bytes() for p in (source / "Scripts").glob("*.lua")}
    if Path("Scripts/main.lua") not in files:
        raise ValueError("The release is missing the camera scripts. Extract the complete archive.")
    for name in ("LICENSE", "enabled.txt"):
        files[Path(name)] = (source / name).read_bytes()
    for relative, src in extras.items():
        files[relative] = src.read_bytes()
    return files


def publish_mod(target, files, temp, bin_dir):
    if target.is_symlink() or (target.exists() and not target.is_dir()):
        raise ValueError(f"Move the existing non-directory or symlink at {target} before installation.")
    if target.is_dir() and all((target / p).is_file() and (target / p).read_bytes() == data
                               for p, data in files.items()):
        print(f"Camera already installed: {target}")
        return
    staged = temp / MOD
    staged.mkdir()
    for relative, data in files.items():
        dest = staged / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
    previous = None
    if target.exists():
        backups = Path(tempfile.mkdtemp(prefix="HaloPhotoMode-backup-", dir=bin_dir))
        previous = backups / MOD
        target.rename(previous)
        print(f"Previous camera preserved at {previous}")
    try:
        staged.rename(target)
    except OSError:
        if previous:
            previous.rename(target)
        raise


def install(bin_dir, archives, extras):
    tree = bin_dir / "ue4ss"
    target = tree / "Mods" / MOD
    files = mod_files(extras)
    if os.path.lexists(bin_dir / "override.txt"):
        raise ValueError("This installation uses a custom UE4SS location. Copy mod/HaloPhotoMode to that loader's Mods folder manually.")
    lock = bin_dir / ".HaloPhotoMode-installing"
    try:
        lock.mkdir()
    except FileExistsError:
        raise ValueError(f"An installation is in progress. If it was interrupted, close the installer and remove the empty {lock} folder.")
    try:
        with tempfile.TemporaryDirectory(prefix=".HaloPhotoMode-", dir=bin_dir) as work:
            temp = Path(work)
            if (tree / "UE4SS.dll").is_file() and (tree / "Mods").is_dir():
                if os.path.lexists(tree / PENDING):
                    activate(tree)
                publish_mod(target, files, temp, bin_dir)
            else:
                conflicts = [p.name for p in bin_dir.iterdir() if p.name.lower() in
                             {"ue4ss", "ue4ss.dll", "ue4ss-settings.ini", "mods", "dwmapi.dll"}]
                if conflicts:
                    raise ValueError("Partial or alternate UE4SS installation found. Preserve it and install manually: " + ", ".join(conflicts))
                if not archives:
                    raise ValueError("A fresh install needs --archives pointing to the folder containing UE4SS_v4.0.0.zip and zCustomGameConfigs.zip.")
                staged = temp / "ue4ss"
                stage_loader(staged, archives)
                publish_mod(staged / "Mods" / MOD, files, temp, bin_dir)
                staged.rename(tree)
                # The verified pending proxy stays inside the published tree if activation is interrupted.
                activate(tree)
                print("Installed UE4SS v4.0.0 with the Halo Steam profile.")
        print(f"Camera location: {target}")
        return target
    finally:
        lock.rmdir()


def options():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, help="Steam game root (defaults to Steam library discovery)")
    parser.add_argument("--archives", type=Path, help="folder with the two upstream v4.0.0 ZIPs for a fresh loader")
    return parser.parse_args()


if __name__ == "__main__":
    args = options()
    try:
        install(game_binary_dir(args.game), args.archives, {})
    except (OSError, ValueError, BadZipFile, KeyError) as error:
        sys.exit(f"Installation failed: {error}")
