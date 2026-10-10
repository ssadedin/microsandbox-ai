#!/bin/bash
# ----------------------------------------------------------------
# Ask the host for a fresh screenshot of the user's approved
# application window and print the path of the image.
#
# Installed in the guest as /usr/local/bin/msb-screenshot. The host
# side is capture_screenshots.py, started by --with-screenshots; it
# decides which window is captured, so this takes no window argument.
#
# Usage: msb-screenshot [TIMEOUT_SECONDS]   (default 20)
# ----------------------------------------------------------------

set -uo pipefail

dir="${MSB_SCREENSHOT_DIR:-}"
timeout="${1:-20}"

if [[ -z "$dir" || ! -d "$dir/screenshot-requests" ]]; then
    echo "msb-screenshot: screenshots are not enabled for this session" \
         "(the user starts the agent with --with-screenshots)" >&2
    exit 2
fi

req="$dir/screenshot-requests/$(date +%s)-$$-$RANDOM"

: > "$req.req" || exit 1

deadline=$(( SECONDS + timeout ))

while (( SECONDS < deadline )); do
    if [[ -e "$req.done" ]]; then
        echo "$dir/$(< "$req.done")"
        rm -f "$req.done"
        exit 0
    fi

    if [[ -e "$req.err" ]]; then
        echo "msb-screenshot: $(< "$req.err")" >&2
        rm -f "$req.err"
        exit 1
    fi

    sleep 0.2
done

rm -f "$req.req"
echo "msb-screenshot: timed out after ${timeout}s waiting for the host" \
     "(has the user's screenshot helper stopped?)" >&2
exit 1
