"""Service Halo's F9 photo requests from the foreground game window on Windows."""

import argparse
import ctypes
from ctypes import wintypes
from contextlib import contextmanager
import os
from pathlib import Path, PureWindowsPath
import stat
import sys
import tempfile
import time

# The release places this file at its root. Source checkouts keep it in packaging/windows.
here = Path(__file__).resolve().parent
tools_folder = here / "tools" if (here / "tools").is_dir() else here.parents[1] / "tools"
sys.path.insert(0, str(tools_folder))
from capture import READY, REQUEST, parse_request, signature


def game_window():
    user = ctypes.WinDLL("user32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    user.GetForegroundWindow.argtypes = []
    user.GetForegroundWindow.restype = wintypes.HWND
    user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user.GetWindowThreadProcessId.restype = wintypes.DWORD
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.QueryFullProcessImageNameW.argtypes = [
        wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    kernel.QueryFullProcessImageNameW.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.CloseHandle.restype = wintypes.BOOL
    hwnd = user.GetForegroundWindow()
    pid = wintypes.DWORD()
    if not hwnd or not user.GetWindowThreadProcessId(hwnd, ctypes.byref(pid)):
        raise ValueError("Bring the Halo game window to the foreground")
    handle = kernel.OpenProcess(0x1000, False, pid.value)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        raise ValueError("Could not identify the foreground game window")
    try:
        size = wintypes.DWORD(32768)
        path = ctypes.create_unicode_buffer(size.value)
        if not kernel.QueryFullProcessImageNameW(handle, 0, path, ctypes.byref(size)):
            raise ctypes.WinError(ctypes.get_last_error())
        if PureWindowsPath(path.value).name.casefold() != "halocampaignevolved.exe":
            raise ValueError("Bring the Halo game window to the foreground")
    finally:
        kernel.CloseHandle(handle)
    return hwnd


def capture_window(viewport, crop, output):
    from PIL import ImageGrab

    hwnd = game_window()
    with ImageGrab.grab(window=hwnd) as frame:
        if hwnd != game_window():
            raise ValueError("Game window lost focus during capture")
        if frame.size != viewport:
            raise ValueError(f"Game client is {frame.size}, expected {viewport}")
        with frame.crop(crop) as photo:
            photo.save(output, format="PNG", compress_level=3)


def ordinary_file(info):
    return (stat.S_ISREG(info.st_mode) and info.st_nlink == 1
            and not getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def stage_request(path):
    match = REQUEST.fullmatch(path.name)
    if not match:
        return
    stage = path.with_name(match[1])
    info = path.lstat()
    if (not ordinary_file(info) or info.st_size > 256 or stage.exists()
            or not -2 <= time.time() - info.st_mtime <= 30):
        return
    with path.open("rb") as request:
        if signature(os.fstat(request.fileno())) != signature(info):
            return
        viewport, crop = parse_request(request.read(257), stage.name)
    temp = tempfile.NamedTemporaryFile(dir=path.parent, prefix=".HaloPhotoHelper-", delete=False)
    temp_path = Path(temp.name)
    try:
        with temp:
            capture_window(viewport, crop, temp)
        if signature(path.lstat()) == signature(info):
            # Windows rename is atomic and refuses to replace an existing stage.
            temp_path.rename(stage)
    finally:
        temp_path.unlink(missing_ok=True)


@contextmanager
def single_helper(directory):
    import msvcrt

    with (directory / ".HaloPhotoHelper.lock").open("a+b") as lock:
        lock.seek(0)
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as error:
            raise ValueError("Another helper is active, or the screenshot folder cannot be locked") from error
        yield  # Closing the file releases the lock, including after an exception.


def watch(directory):
    directory.mkdir(parents=True, exist_ok=True)
    ready = directory / READY
    print(f"Watching {directory}\nStart Halo in Steam. Press Ctrl+C here to stop.", flush=True)
    with single_helper(directory):
        heartbeat_at = 0
        previous_errors = {}
        try:
            while True:
                if time.monotonic() >= heartbeat_at:
                    # The game only reads while taking a shot. A transient sharing
                    # violation leaves the previous heartbeat valid for six seconds.
                    with tempfile.NamedTemporaryFile(dir=directory, prefix=".HaloPhotoHelper-", delete=False) as temp:
                        temp_path = Path(temp.name)
                        temp.write(f"{int(time.time())}\n".encode("ascii"))
                    try:
                        temp_path.replace(ready)
                    except PermissionError:
                        if not ready.is_file() or time.time() - ready.stat().st_mtime > 5:
                            raise
                    finally:
                        temp_path.unlink(missing_ok=True)
                    heartbeat_at = time.monotonic() + 1
                errors = {}
                for path in directory.glob(".Halo_*.pending.png.request"):
                    try:
                        stage_request(path)
                    except FileNotFoundError:
                        pass  # Game canceled or completed the shot.
                    except (ValueError, OSError) as error:
                        errors[path] = str(error)
                        if previous_errors.get(path) != errors[path]:
                            print(f"{path.name}: {error}", file=sys.stderr, flush=True)
                previous_errors = errors
                time.sleep(0.2)
        finally:
            ready.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, help="Override the game's screenshot folder")
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.exit(1, "Use this helper on native Windows. For Linux/Proton, see the Linux package.\n")
    try:
        # HWND capture was added in Pillow 11.2.1. Refuse to signal readiness
        # if the installed version can only capture the desktop.
        from PIL import ImageGrab
        import inspect
        if "window" not in inspect.signature(ImageGrab.grab).parameters:
            raise ValueError("The shutter requires Pillow 11.2.1 or newer")
        directory = args.directory or Path(os.environ["LOCALAPPDATA"]) / "Meteorite/Saved/Screenshots/Windows"
        watch(directory)
    except KeyboardInterrupt:
        return 0
    except (ImportError, OSError, ValueError) as error:
        parser.exit(1, f"Halo capture: {error}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
