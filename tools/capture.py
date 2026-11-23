"""Stage display PNGs for Halo Photo Mode on Linux/Proton with XWayland."""

import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time

if __package__:
    from . import doctor
else:
    import doctor


READY = "HaloPhotoHelper.ready"
REQUEST = re.compile(r"(\.Halo_[0-9]{8}_[0-9]{6}_[0-9]{4,12}_[0-9a-f]{8}\.pending\.png)\.request")
TITLE = r"^Halo: Campaign Evolved *$"
MAX_AXIS = 16384
MAX_PIXELS = 40_000_000


def default_directory():
    prefix = Path("steamapps/compatdata") / doctor.APP_ID / "pfx/drive_c/users/steamuser/AppData/Local"
    libraries = dict.fromkeys(p.resolve() for p in doctor.library_paths(doctor.default_roots()))
    installed = [p for p in libraries if (p / "steamapps" / f"appmanifest_{doctor.APP_ID}.acf").is_file()]
    for library in installed + list(libraries):
        saved = library / prefix / "Meteorite/Saved"
        if saved.is_dir():
            return saved / "Screenshots/Windows"
    raise ValueError("Could not locate the game's Proton profile. Supply --directory.")


def window_id():
    search = subprocess.run(["xdotool", "search", "--onlyvisible", "--name", TITLE],
                            capture_output=True, text=True, timeout=3)
    matches = []
    for xid in search.stdout.split():
        if not xid.isdecimal():
            continue
        title = subprocess.run(["xdotool", "getwindowname", xid], capture_output=True,
                               text=True, timeout=3)
        if title.returncode or not re.fullmatch(TITLE, title.stdout.rstrip("\r\n")):
            continue
        props = subprocess.run(["xprop", "-id", xid, "WM_CLASS"], capture_output=True,
                               text=True, timeout=3)
        classes = re.findall(r'"([^"]*)"', props.stdout)
        if not props.returncode and f"steam_app_{doctor.APP_ID}" in classes:
            matches.append(xid)
    if len(matches) != 1:
        raise RuntimeError(f"Expected one visible Halo game window, found {len(matches)}")
    return matches[0]


def capture_window(viewport, box, output):
    from PIL import Image

    xid = window_id()
    with tempfile.TemporaryFile() as raw:
        # Fixed argv, numeric XID, and a private file avoid shell expansion
        # and buffering an unbounded subprocess stream in memory.
        subprocess.run(["import", "-silent", "-window", xid, "-depth", "8", "png24:-"],
                       stdout=raw, stderr=subprocess.PIPE, check=True, timeout=15)
        if raw.tell() > MAX_PIXELS * 4 + 1_048_576:
            raise ValueError("Window PNG exceeds the supported size")
        raw.seek(0)
        with Image.open(raw, formats=["PNG"]) as window:
            if window.size != viewport:
                raise ValueError(f"Window is {window.size}, expected {viewport}")
            with window.crop(box) as cropped:
                cropped.save(output, format="PNG", compress_level=3)


def signature(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def regular(info):
    return stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1


def current_request(directory, name, original):
    try:
        info = os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return regular(info) and signature(info) == signature(original)


def parse_request(content, stage):
    lines = content.decode("utf-8").splitlines()
    if len(lines) != 3 or lines[:2] != ["HALO-PNG-1", stage]:
        raise ValueError("Invalid capture request header or stage name")
    if not re.fullmatch(r"[0-9]{1,5}( [0-9]{1,5}){5}", lines[2]):
        raise ValueError("Invalid capture dimensions")
    width, height, x, y, w, h = map(int, lines[2].split())
    if (not 0 < width <= MAX_AXIS or not 0 < height <= MAX_AXIS or width * height > MAX_PIXELS
            or not 0 < w <= width - x or not 0 < h <= height - y):
        raise ValueError("Crop or viewport is outside the supported dimensions")
    return (width, height), (x, y, x + w, y + h)


@contextmanager
def temporary(directory):
    name = ".HaloPhotoHelper-" + secrets.token_hex(12) + ".tmp"
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
    try:
        with os.fdopen(fd, "wb") as stream:
            yield name, stream
    finally:
        try:
            os.unlink(name, dir_fd=directory)
        except FileNotFoundError:
            pass


def stage_request(directory, name, capture=capture_window):
    match = REQUEST.fullmatch(name)
    if not match:
        return False
    stage = match[1]
    info = os.stat(name, dir_fd=directory, follow_symlinks=False)
    if not regular(info) or info.st_size > 256 or not -2 <= time.time() - info.st_mtime <= 30:
        return False
    try:
        os.stat(stage, dir_fd=directory, follow_symlinks=False)
        return False
    except FileNotFoundError:
        pass
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    with os.fdopen(os.open(name, flags, dir_fd=directory), "rb") as request:
        opened = os.fstat(request.fileno())
        if not regular(opened) or signature(opened) != signature(info):
            return False
        viewport, box = parse_request(request.read(257), stage)
        with temporary(directory) as (temp, output):
            capture(viewport, box, output)
            output.flush()
            if not current_request(directory, name, opened):
                return False
            # Publish without replacing a native PNG, symlink or competing stage.
            try:
                os.link(temp, stage, src_dir_fd=directory, dst_dir_fd=directory, follow_symlinks=False)
            except FileExistsError:
                return False
    return True


def heartbeat(directory):
    try:
        existing = os.stat(READY, dir_fd=directory, follow_symlinks=False)
        if not regular(existing):
            raise ValueError("Heartbeat is not an owned regular file")
    except FileNotFoundError:
        pass
    with temporary(directory) as (temp, stream):
        stream.write(f"{int(time.time())}\n".encode("ascii"))
        stream.flush()
        os.replace(temp, READY, src_dir_fd=directory, dst_dir_fd=directory)


def watch(directory, once, child):
    import fcntl

    # The directory lock survives atomic heartbeat replacements and avoids
    # concurrent helpers removing each other's readiness signal.
    fcntl.flock(directory, fcntl.LOCK_EX | fcntl.LOCK_NB)
    stop = threading.Event()
    def refresh():
        while not stop.wait(1):
            try:
                heartbeat(directory)
            except (OSError, ValueError) as error:
                print(f"Halo capture heartbeat: {error}", file=sys.stderr, flush=True)
                stop.set()

    heartbeat(directory)
    worker = threading.Thread(target=refresh, daemon=True)
    handled = set()
    errors = {}
    try:
        worker.start()
        while not stop.is_set() and (child is None or child.poll() is None):
            names = {n for n in os.listdir(directory) if REQUEST.fullmatch(n)}
            handled.intersection_update(names)
            errors = {name: result for name, result in errors.items() if name in names}
            completed = 0
            for name in sorted(names - handled):
                previous, retry = errors.get(name, (None, 0))
                if time.monotonic() < retry:
                    continue
                try:
                    if stage_request(directory, name):
                        print(f"Halo capture staged {name[:-8]}", flush=True)
                        handled.add(name)
                        completed += 1
                except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
                    message = str(error)
                    if message != previous:
                        print(f"Halo capture {name}: {message}", file=sys.stderr, flush=True)
                    errors[name] = (message, time.monotonic() + 1)
            if once:
                return 0 if completed else 1
            stop.wait(0.20)
        return 1 if stop.is_set() else 0
    finally:
        stop.set()
        if worker.ident is not None:
            worker.join()
        try:
            info = os.stat(READY, dir_fd=directory, follow_symlinks=False)
            if regular(info):
                os.unlink(READY, dir_fd=directory)
        except FileNotFoundError:
            pass


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, help="Halo Saved/Screenshots/Windows folder")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--once", action="store_true", help="service already pending requests once")
    mode.add_argument("--run", nargs=argparse.REMAINDER, help="launch Steam's game command and watch until exit")
    raw = list(sys.argv[1:] if argv is None else argv)
    if "--run" in raw:
        boundary = raw.index("--run") + 1
        # Steam's command contains its own option terminators. argparse
        # interprets those even inside REMAINDER, so only parse our prefix.
        args = parser.parse_args(raw[:boundary])
        args.run = raw[boundary:]
    else:
        args = parser.parse_args(raw)
    if args.run == []:
        parser.error("--run requires a game command")
    child = None
    if args.run:
        try:
            child = subprocess.Popen(args.run)
        except OSError as error:
            print(f"Could not start the Steam game command: {error}", file=sys.stderr)
            return 1
    try:
        try:
            result = run_helper(args, child)
        except Exception as error:
            # Capture is optional. Even an unexpected helper fault must not
            # end Steam's launcher early or cause a second game launch.
            print(f"Halo capture disabled: {error}", file=sys.stderr, flush=True)
            result = 1
        if child is None:
            return result
        code = child.wait()
        return code if code >= 0 else 128 - code
    except KeyboardInterrupt:
        if child and child.poll() is None:
            child.terminate()
        return 130


def run_helper(args, child):
    if not sys.platform.startswith("linux"):
        raise ValueError("This display helper requires Linux with X11 or XWayland")
    from PIL import Image  # noqa: F401

    if not os.environ.get("DISPLAY"):
        raise ValueError("X11/XWayland DISPLAY is unavailable")
    for program in ("xdotool", "xprop", "import"):
        if not shutil.which(program):
            raise ValueError(f"Missing required executable: {program}")
    directory = args.directory or default_directory()
    directory.mkdir(parents=True, exist_ok=True)
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        print(f"Halo capture watching {directory}", flush=True)
        return watch(fd, args.once, child)
    finally:
        os.close(fd)


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
