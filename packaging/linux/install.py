"""Install Halo Photo Mode and the Linux/Proton display capture helper."""

from pathlib import Path
import shlex
import shutil
import sys
from zipfile import BadZipFile

TOOLS = Path(__file__).resolve().parents[2] / "tools"
sys.path.insert(0, str(TOOLS))
import install_runtime


def main():
    args = install_runtime.options()
    helpers = {Path("Proton") / name: TOOLS / name for name in ("capture.py", "doctor.py")}
    folder = install_runtime.install(install_runtime.game_binary_dir(args.game), args.archives, helpers)
    wrapper = shlex.quote(str(folder / "Proton/capture.py"))
    # Keep an existing loader's custom proxy selection in place.
    dll_override = 'WINEDLLOVERRIDES="dwmapi=n,b" ' if (folder.parents[2] / "dwmapi.dll").is_file() else ""
    print("\nSteam launch options (merge any existing options around %command%):")
    print(f"{dll_override}python3 -B {wrapper} --run %command%")
    missing = [name for name in ("xdotool", "xprop", "import") if not shutil.which(name)]
    try:
        from PIL import Image  # noqa: F401
    except ImportError:
        missing.append("Python Pillow")
    if missing:
        print("The F9 shutter requires: " + ", ".join(missing), file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, BadZipFile, KeyError) as error:
        sys.exit(f"Installation failed: {error}")
