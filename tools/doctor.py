"""Locate the Steam edition of Halo: Campaign Evolved without modifying its files."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import sys


APP_ID = "2806050"
EXE = Path("Meteorite/Binaries/Win64/HaloCampaignEvolved.exe")
SETTINGS = ("FieldOfView", "FieldOfView3rdPerson", "bHUDVisible")
VDF_TOKEN = re.compile(r'\s+|//[^\n]*|"(?:\\.|[^"\\])*"|[{}]|[^\s"{}]+')


def read_vdf(path):
    """Read Steam's text KeyValues format, keeping nested blocks separate."""
    source = path.read_text(encoding="utf-8-sig")
    stack = [{}]
    key = None
    offset = 0
    for match in VDF_TOKEN.finditer(source):
        token = match.group()
        if match.start() != offset:
            raise ValueError("invalid VDF token")
        offset = match.end()
        if token.isspace() or token.startswith("//"):
            continue
        if token == "{":
            if key is None:
                raise ValueError("missing VDF block key")
            child = {}
            stack[-1][key] = child
            stack.append(child)
            key = None
        elif token == "}":
            if len(stack) == 1 or key is not None:
                raise ValueError("unexpected VDF closing brace")
            stack.pop()
        else:
            if token.startswith('"'):
                token = re.sub(r'\\(["\\])', r'\1', token[1:-1])
            if key is None:
                key = token.lower()
            else:
                stack[-1][key] = token
                key = None
    if offset != len(source) or key is not None or len(stack) != 1:
        raise ValueError("incomplete VDF")
    return stack[0]


def default_roots():
    if os.name == "nt":
        import winreg

        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
                yield Path(winreg.QueryValueEx(key, "SteamPath")[0])
        except OSError:
            pass
        for var in ("ProgramFiles(x86)", "ProgramFiles"):
            if os.environ.get(var):
                yield Path(os.environ[var]) / "Steam"
    else:
        for folder in (".local/share/Steam", ".steam/steam", ".var/app/com.valvesoftware.Steam/.local/share/Steam"):
            yield Path.home() / folder


def library_paths(roots):
    for root in roots:
        yield root
        index = root / "steamapps/libraryfolders.vdf"
        if index.is_file():
            try:
                entries = read_vdf(index).get("libraryfolders")
                if not isinstance(entries, dict):
                    raise ValueError("missing libraryfolders block")
                for key, entry in entries.items():
                    # Older Steam versions stored paths directly under numbered keys.
                    value = entry.get("path") if isinstance(entry, dict) else entry
                    if key.isdigit() and isinstance(value, str) and Path(value).is_absolute():
                        yield Path(value)
            except (OSError, ValueError) as error:
                print(f"Could not read {index}: {error}", file=sys.stderr)


def locate(root):
    steamapps = root / "steamapps"
    manifest = steamapps / f"appmanifest_{APP_ID}.acf"
    if not manifest.is_file():
        return None
    state = read_vdf(manifest).get("appstate")
    if not isinstance(state, dict) or state.get("appid") != APP_ID:
        raise ValueError("manifest has the wrong app ID")
    folder = state.get("installdir")
    if not isinstance(folder, str) or folder in ("", ".", "..") or re.search(r"[/\\:]", folder):
        raise ValueError("manifest has an invalid installation folder")
    install = steamapps / "common" / folder
    for exe in (install / EXE, install / "Content" / EXE):
        if exe.is_file():
            return state.get("buildid", "unknown"), exe
    raise ValueError(f"manifest points to a missing executable under {install} (checked both Win64 layouts)")


def settings_files(libraries):
    if os.name == "nt":
        bases = [Path(os.environ["LOCALAPPDATA"])] if os.environ.get("LOCALAPPDATA") else []
    else:
        proton = Path("steamapps/compatdata") / APP_ID / "pfx/drive_c/users/steamuser/AppData/Local"
        bases = [library / proton for library in libraries]
    for base in bases:
        yield from sorted((base / "Meteorite/Saved/Config").glob("*/HaloGlobalGameUserSettings.ini"))


def read_settings(path):
    values = {}
    in_section = False
    with path.open(encoding="utf-8-sig") as stream:
        for line in stream:
            line = line.strip()
            if line.startswith("["):
                in_section = line == "[HaloUserSettings]"
            elif in_section:
                key, separator, value = line.partition("=")
                if separator and key.strip() in SETTINGS:
                    values[key.strip()] = value.strip()
    return values


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--steam-root", type=Path, help="Steam library root containing steamapps")
    parser.add_argument("--sha256", action="store_true", help="also hash the entire game executable")
    parser.add_argument("--settings", action="store_true", help="also read saved FOV and HUD settings")
    args = parser.parse_args(argv)
    roots = [args.steam_root.expanduser()] if args.steam_root else default_roots()
    libraries = list(dict.fromkeys(path.resolve() for path in library_paths(roots)))
    found = False
    hash_failed = False
    for library in libraries:
        try:
            result = locate(library)
        except (OSError, ValueError) as error:
            print(f"Skipping {library}: {error}", file=sys.stderr)
            continue
        if result is None:
            continue
        found = True
        build, exe = result
        print(f"Halo: Campaign Evolved (Steam {APP_ID}), build {build}")
        print(f"Executable: {exe}")
        modern, legacy = exe.parent / "ue4ss", exe.parent
        cores = [directory / "UE4SS.dll" for directory in (modern, legacy)]
        print("UE4SS core DLL:", ", ".join(str(path) for path in cores if path.is_file()) or "not found")
        # A bare legacy Mods directory can belong to another loader.
        mods = [modern / "Mods"]
        if (legacy / "UE4SS.dll").is_file():
            mods.append(legacy / "Mods")
        print("UE4SS Mods directory:", ", ".join(str(path) for path in mods if path.is_dir()) or "not found")
        if args.sha256:
            try:
                digest = hashlib.sha256()
                with exe.open("rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
                print(f"SHA-256: {digest.hexdigest()}")
            except OSError as error:
                print(f"Could not hash {exe}: {error}", file=sys.stderr)
                hash_failed = True
    if not found:
        print(f"No verified Halo: Campaign Evolved installation (Steam {APP_ID}) found.", file=sys.stderr)
        return 1
    if args.settings:
        profiles = list(settings_files(libraries))
        if not profiles:
            print("Saved Halo FOV/HUD settings file not found.")
        for number, profile in enumerate(profiles, 1):
            try:
                settings = read_settings(profile)
                fields = [f"{key}={settings[key]}" for key in SETTINGS if key in settings]
                print(f"Saved profile {number}: {', '.join(fields) or 'no recorded FOV/HUD settings'}")
            except (OSError, ValueError) as error:
                print(f"Could not read saved profile {number}: {error}", file=sys.stderr)
    return int(hash_failed)


if __name__ == "__main__":
    sys.exit(main())
