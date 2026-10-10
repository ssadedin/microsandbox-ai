#!/bin/bash
# ----------------------------------------------------------------
# Make every JDK in the sandbox trust the microsandbox TLS
# interception CA.
#
# msb installs its CA into the system trust store and sets
# SSL_CERT_FILE / NODE_EXTRA_CA_CERTS etc., which covers curl, git,
# Python, Node and Go. Java ignores all of that and only trusts its
# own cacerts keystore, so Gradle, Maven, sbt etc. fail with PKIX
# errors. This imports the CA into each JDK's cacerts.
#
# Installed in the guest as /usr/local/bin/msb-trust-java. Runs at
# each launch and after apt installs a package; run it by hand after
# installing a JDK any other way (SDKMAN, tarball, toolchains).
#
# Usage: msb-trust-java [-q] [DIR...]
#   DIR: extra directories to search for JDKs
# ----------------------------------------------------------------

set -uo pipefail

ca=/.msb/tls/ca.pem
quiet=0

if [[ "${1:-}" == "-q" ]]; then
    quiet=1
    shift
fi

say() {
    (( quiet )) || echo "msb-trust-java: $*" >&2
}

if [[ ! -s "$ca" ]]; then
    say "no interception CA at $ca; nothing to do"
    exit 0
fi

if (( EUID != 0 )); then
    exec sudo -n "$0" "$@"
fi

# The CA is reused across sandboxes but can be regenerated on the host,
# so name the entry after its content.
alias="microsandbox-ca-$(sha256sum "$ca" | cut -c1-16)"

declare -A seen=()
status=0

while IFS= read -r -d '' cacerts; do

    real="$(readlink -f "$cacerts")" || continue
    [[ -n "${seen[$real]:-}" ]] && continue
    seen[$real]=1

    # <jdk>/lib/security/cacerts or <jdk>/jre/lib/security/cacerts
    keytool="$(dirname "$(dirname "$(dirname "$cacerts")")")/bin/keytool"
    if [[ ! -x "$keytool" ]]; then
        keytool="$(command -v keytool 2>/dev/null)" || continue
    fi

    if "$keytool" -list -keystore "$real" -storepass changeit \
            -alias "$alias" >/dev/null 2>&1; then
        continue
    fi

    if "$keytool" -importcert -noprompt -trustcacerts \
            -alias "$alias" -file "$ca" \
            -keystore "$real" -storepass changeit >/dev/null 2>&1; then
        say "trusted microsandbox CA in $real"
    else
        say "failed to update $real"
        status=1
    fi

done < <(
    find /usr/lib/jvm /usr/local /opt /root /home "$@" \
        -xdev \
        \( -name node_modules -o -name caches -o -name .git \) -prune \
        -o -path '*/lib/security/cacerts' -print0 \
        2>/dev/null
)

exit $status
