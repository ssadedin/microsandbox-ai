#!/usr/bin/env python3
"""
Continuously capture a screenshot of a single macOS window.

Usage:
    capture_screenshots.py --list
    capture_screenshots.py [options] WINDOW

WINDOW is either a numeric CoreGraphics window id, or a case-insensitive
substring matched against "<owner app> - <window title>". The first
(front-most) matching on-screen window is used.

The screenshot is written atomically (temp file + rename) so a reader
never sees a partially written image.

Requires pyobjc-framework-Quartz, e.g.:
    uv run --with pyobjc-framework-Quartz capture_screenshots.py --list

The terminal running this needs the macOS "Screen Recording" permission
(System Settings -> Privacy & Security -> Screen Recording).
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time

import Quartz


def list_windows():
    """Return on-screen, normal-layer windows as dicts (front-most first)."""
    opts = (Quartz.kCGWindowListOptionOnScreenOnly
            | Quartz.kCGWindowListExcludeDesktopElements)
    infos = Quartz.CGWindowListCopyWindowInfo(opts, Quartz.kCGNullWindowID) or []

    windows = []
    for w in infos:
        if w.get(Quartz.kCGWindowLayer, 0) != 0:
            continue  # menu bar, dock, overlays etc.
        bounds = w.get(Quartz.kCGWindowBounds) or {}
        width, height = int(bounds.get("Width", 0)), int(bounds.get("Height", 0))
        if width < 50 or height < 50:
            continue
        windows.append({
            "id": int(w[Quartz.kCGWindowNumber]),
            "owner": str(w.get(Quartz.kCGWindowOwnerName) or ""),
            "title": str(w.get(Quartz.kCGWindowName) or ""),
            "width": width,
            "height": height,
        })
    return windows


def describe(w):
    return f"{w['owner']} - {w['title']}" if w["title"] else w["owner"]


def find_window(spec):
    windows = list_windows()
    if spec.isdigit():
        wid = int(spec)
        return next((w for w in windows if w["id"] == wid), None)
    needle = spec.lower()
    return next((w for w in windows if needle in describe(w).lower()), None)


def _capture_quartz(window_id, path):
    """Capture in-process via CoreGraphics. Raises on failure."""
    fn = getattr(Quartz, "CGWindowListCreateImage", None)
    if fn is None:
        raise RuntimeError("CGWindowListCreateImage unavailable")
    image = fn(Quartz.CGRectNull,
               Quartz.kCGWindowListOptionIncludingWindow,
               window_id,
               Quartz.kCGWindowImageBoundsIgnoreFraming
               | Quartz.kCGWindowImageBestResolution)
    if image is None or Quartz.CGImageGetWidth(image) == 0:
        raise RuntimeError("CGWindowListCreateImage returned no image")
    url = Quartz.CFURLCreateWithFileSystemPath(
        None, path, Quartz.kCFURLPOSIXPathStyle, False)
    dest = Quartz.CGImageDestinationCreateWithURL(url, "public.png", 1, None)
    if dest is None:
        raise RuntimeError("CGImageDestinationCreateWithURL failed")
    Quartz.CGImageDestinationAddImage(dest, image, None)
    if not Quartz.CGImageDestinationFinalize(dest):
        raise RuntimeError("CGImageDestinationFinalize failed")


def _capture_screencapture(window_id, path):
    """Capture via the screencapture CLI. Raises on failure."""
    # -l: window id, -o: no window shadow, -x: no sound
    r = subprocess.run(
        ["screencapture", "-x", "-o", "-t", "png", "-l", str(window_id), path],
        capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(path) or os.path.getsize(path) == 0:
        detail = (r.stderr.strip() or r.stdout.strip()
                  or "no output file written")
        raise RuntimeError(f"screencapture exit {r.returncode}: {detail}")


# Backend preference; a backend that fails is demoted so we don't keep
# retrying a broken one every frame.
_backends = [("quartz", _capture_quartz), ("screencapture", _capture_screencapture)]


def capture(window_id, output, max_size):
    output = os.path.abspath(output)
    # Capture into a private temp dir (not the shared workspace), with a
    # plain, non-hidden file name.
    with tempfile.TemporaryDirectory(prefix="pi-msb-shot-") as tmpdir:
        shot = os.path.join(tmpdir, "capture.png")

        errors = []
        for i, (name, fn) in enumerate(list(_backends)):
            try:
                if os.path.exists(shot):
                    os.unlink(shot)
                fn(window_id, shot)
                if i > 0:
                    _backends.insert(0, _backends.pop(i))
                    print(f"using {name} capture backend", flush=True)
                break
            except Exception as e:
                errors.append(f"{name}: {e}")
        else:
            raise RuntimeError("; ".join(errors))

        if max_size > 0:
            # Downscale (keeping aspect ratio) so Retina captures stay a
            # reasonable size for the model.
            subprocess.run(["sips", "-Z", str(max_size), shot],
                           capture_output=True, check=False)

        # Atomic publish: copy next to the target, then rename over it.
        staging = output + ".tmp"
        shutil.copyfile(shot, staging)
        os.replace(staging, output)


def parent_alive(pid):
    if not pid:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("window", nargs="?", help="window id or name substring")
    ap.add_argument("--list", action="store_true",
                    help="list capturable windows as TSV: id, owner, title, WxH")
    ap.add_argument("-o", "--output", default="screenshot.png")
    ap.add_argument("-i", "--interval", type=float, default=2.0,
                    help="seconds between captures (default 2)")
    ap.add_argument("--max-size", type=int, default=1600,
                    help="max width/height in pixels, 0 = no scaling (default 1600)")
    ap.add_argument("--parent-pid", type=int, default=0,
                    help="exit when this process no longer exists")
    args = ap.parse_args()

    if args.list:
        for w in list_windows():
            print(f"{w['id']}\t{w['owner']}\t{w['title']}\t{w['width']}x{w['height']}")
        return 0

    if not args.window:
        ap.error("WINDOW is required unless --list is given")

    window = find_window(args.window)
    if window is None:
        print(f"error: no on-screen window matching '{args.window}'", file=sys.stderr)
        return 1

    print(f"Capturing window {window['id']}: {describe(window)} -> {args.output}",
          flush=True)

    last_error = None
    while parent_alive(args.parent_pid):
        try:
            capture(window["id"], args.output, args.max_size)
            if last_error:
                print("capture recovered", flush=True)
            last_error = None
        except Exception as e:  # keep going: window may be minimised etc.
            msg = str(e)
            if msg != last_error:
                print(f"capture failed: {msg}", file=sys.stderr, flush=True)
            last_error = msg
            # Window may have been closed and reopened: try to re-resolve.
            if not args.window.isdigit():
                w = find_window(args.window)
                if w is not None and w["id"] != window["id"]:
                    window = w
                    print(f"Re-attached to window {window['id']}: {describe(window)}",
                          flush=True)
        time.sleep(args.interval)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
