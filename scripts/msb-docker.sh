#!/bin/bash
# ----------------------------------------------------------------
# Install (if needed) and start Docker in the sandbox.
#
# The sandbox has no init system to start dockerd, and its root
# filesystem is itself an overlay, which Docker's overlay2 storage
# can't be stacked on. So Docker's data lives on an ext4 image
# (/var/lib/msb-docker.img, sparse) loop-mounted at /var/lib/docker.
#
# Installed in the guest as /usr/local/bin/msb-docker. Safe to run
# repeatedly; rerun after a sandbox restart, which drops the mount
# and the daemon.
#
# Usage: msb-docker [-s SIZE]
#   SIZE: size of a new storage image in GB (default: 60% of the
#         free space on /, so a full image can't fill the root disk)
# ----------------------------------------------------------------

set -euo pipefail

image=/var/lib/msb-docker.img
data=/var/lib/docker
log=/var/log/msb-docker.log
size=""

if [[ "${1:-}" == "-s" ]]; then
    size="${2:?usage: msb-docker [-s SIZE_GB]}"
    shift 2
fi

if (( EUID != 0 )); then
    exec sudo -n "$0" ${size:+-s "$size"}
fi

PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"

say() {
    echo "msb-docker: $*" >&2
}

# ------------------------------------------------------------
# Install Docker CE (current engine, compose and buildx plugins)
# from Docker's repository; Debian's docker.io lags far behind.
# ------------------------------------------------------------

if ! command -v dockerd >/dev/null 2>&1; then
    say "installing Docker CE..."

    export DEBIAN_FRONTEND=noninteractive
    . /etc/os-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$ID/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc]" \
         "https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
        > /etc/apt/sources.list.d/docker.list

    # Keep package scripts from trying to start services (there is
    # no init system); the daemon is started below.
    policy_rc=""
    if [[ ! -e /usr/sbin/policy-rc.d ]]; then
        printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
        chmod 0755 /usr/sbin/policy-rc.d
        policy_rc=1
    fi

    # Retry in a new apt run: apt reuses its DNS lookup within a run,
    # and msb stops allowing the IPs once the (short) TTL lapses.
    for attempt in 1 2 3; do
        apt-get update -q \
            && apt-get install -y -q docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin \
            && break
        (( attempt < 3 )) || exit 1
        sleep 3
    done

    [[ -n "$policy_rc" ]] && rm -f /usr/sbin/policy-rc.d
fi

# ------------------------------------------------------------
# Storage on a loop-mounted ext4 image.
# ------------------------------------------------------------

if [[ ! -f "$image" ]]; then
    if [[ -z "$size" ]]; then
        free_gb=$(( $(df --output=avail -k / | tail -1) / 1024 / 1024 ))
        size=$(( free_gb * 6 / 10 ))
    fi
    (( size >= 2 )) || { say "only ${size}G available for storage; need at least 2G"; exit 1; }

    say "creating ${size}G storage image at $image"
    truncate -s "${size}G" "$image"
    mkfs.ext4 -q -F "$image"
fi

mkdir -p "$data"
if ! mountpoint -q "$data"; then
    mount -o loop "$image" "$data"
fi

# ------------------------------------------------------------
# Start the daemon.
# ------------------------------------------------------------

if ! docker info >/dev/null 2>&1; then
    say "starting dockerd (log: $log)"
    nohup dockerd >>"$log" 2>&1 </dev/null &

    for _ in $(seq 1 30); do
        docker info >/dev/null 2>&1 && break
        sleep 1
    done

    if ! docker info >/dev/null 2>&1; then
        say "dockerd did not start; last log lines:"
        tail -n 20 "$log" >&2
        exit 1
    fi
fi

# Let the invoking user use docker without sudo. Group membership only
# applies to new logins, so also hand them the socket for the running
# daemon (they have passwordless sudo anyway).
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    usermod -aG docker "$SUDO_USER"
    chown "$SUDO_USER" /var/run/docker.sock
fi

say "docker is running"
