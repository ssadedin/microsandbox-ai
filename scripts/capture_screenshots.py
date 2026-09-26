#!/usr/bin/env python3
"""
Capture screenshots of a single, pre-approved macOS window on request.

Usage:
    capture_screenshots.py --list
    capture_screenshots.py [options] --dir DIR WINDOW

WINDOW is either a numeric CoreGraphics window id, or a case-insensitive
substring matched against "<owner app> - <window title>". The first
(front-most) matching on-screen window is used.

Requests arrive as files: a client creates DIR/screenshot-requests/ID.req
and waits. The window is captured to DIR/screenshot.png (written
atomically), then ID.done is written containing the image file name, or
ID.err containing an error message. Request contents are ignored: the
client cannot choose what is captured. Captures are rate limited, and the
window must still belong to the app that owned it at startup; if it
disappears, only a window of the same app matching WINDOW is re-attached.

Requires pyobjc-framework-Quartz, e.g.:
    uv run --with pyobjc-framework-Quartz capture_screenshots.py --list

The terminal running this needs the macOS "Screen Recording" permission
(System Settings -> Privacy & Security -> Screen Recording).
"""

import argparse
import os
import re
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
            "pid": int(w.get(Quartz.kCGWindowOwnerPID) or 0),
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


REQUEST_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}\.req$")
MAX_REQUESTS = 20


def resolve(spec, window):
    """Return the approved window's current info, or None.

    Accepts the same window id if it still belongs to the same app;
    otherwise re-resolves spec, but only to a window of the same app.
    """
    windows = list_windows()
    same = next((w for w in windows if w["id"] == window["id"]), None)
    if same is not None and same["owner"] == window["owner"]:
        return same
    if spec.isdigit():
        return None
    needle = spec.lower()
    return next((w for w in windows
                 if w["owner"] == window["owner"]
                 and needle in describe(w).lower()), None)


def reply(req_dir, req, suffix, text):
    """Answer request file req with ID.done / ID.err, then remove it."""
    base = req[:-len(".req")]
    tmp = os.path.join(req_dir, f".{base}{suffix}.tmp")
    with open(tmp, "w") as f:
        f.write(text + "\n")
    os.replace(tmp, os.path.join(req_dir, base + suffix))
    try:
        os.unlink(os.path.join(req_dir, req))
    except FileNotFoundError:
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("window", nargs="?", help="window id or name substring")
    ap.add_argument("--list", action="store_true",
                    help="list capturable windows as TSV: id, owner, title, WxH")
    ap.add_argument("-d", "--dir",
                    help="directory for screenshot.png and screenshot-requests/")
    ap.add_argument("--min-interval", type=float, default=1.0,
                    help="minimum seconds between captures (default 1)")
    ap.add_argument("--poll", type=float, default=0.2,
                    help="seconds between checks for requests (default 0.2)")
    ap.add_argument("--max-size", type=int, default=1600,
                    help="max width/height in pixels, 0 = no scaling (default 1600)")
    ap.add_argument("--parent-pid", type=int, default=0,
                    help="exit when this process no longer exists")
    args = ap.parse_args()

    if args.list:
        for w in list_windows():
            print(f"{w['id']}\t{w['owner']}\t{w['title']}\t{w['width']}x{w['height']}")
        return 0

    if not args.window or not args.dir:
        ap.error("WINDOW and --dir are required unless --list is given")

    window = find_window(args.window)
    if window is None:
        print(f"error: no on-screen window matching '{args.window}'", file=sys.stderr)
        return 1

    output = os.path.join(args.dir, "screenshot.png")
    req_dir = os.path.join(args.dir, "screenshot-requests")
    os.makedirs(req_dir, exist_ok=True)

    # Check permissions etc. now, without publishing anything.
    with tempfile.TemporaryDirectory(prefix="msb-shot-check-") as tmp:
        try:
            capture(window["id"], os.path.join(tmp, "check.png"), args.max_size)
        except Exception as e:
            print(f"error: test capture failed: {e}", file=sys.stderr)
            return 1

    print(f"Ready: capturing window {window['id']} ({describe(window)}) "
          f"on request -> {output}", flush=True)

    last_capture = 0.0
    while parent_alive(args.parent_pid):
        try:
            reqs = sorted(f for f in os.listdir(req_dir) if REQUEST_RE.match(f))
        except OSError:
            reqs = []

        if not reqs:
            time.sleep(args.poll)
            continue

        # One capture answers every pending request; excess requests are
        # refused rather than queued.
        for req in reqs[MAX_REQUESTS:]:
            reply(req_dir, req, ".err", "too many pending requests")
        reqs = reqs[:MAX_REQUESTS]

        wait = last_capture + args.min_interval - time.monotonic()
        if wait > 0:
            time.sleep(wait)

        current = resolve(args.window, window)
        if current is None:
            msg = (f"the approved window ({describe(window)}) is not on screen; "
                   "ask the user to show it")
            print(f"capture refused: {msg}", file=sys.stderr, flush=True)
            for req in reqs:
                reply(req_dir, req, ".err", msg)
            continue

        if current["id"] != window["id"]:
            print(f"Re-attached to window {current['id']}: {describe(current)}",
                  flush=True)
        window = current

        try:
            capture(window["id"], output, args.max_size)
            result = (".done", os.path.basename(output))
            print(f"captured for {len(reqs)} request(s)", flush=True)
        except Exception as e:  # window minimised etc.
            result = (".err", f"capture failed: {e}")
            print(f"capture failed: {e}", file=sys.stderr, flush=True)
        last_capture = time.monotonic()

        for req in reqs:
            reply(req_dir, req, *result)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
