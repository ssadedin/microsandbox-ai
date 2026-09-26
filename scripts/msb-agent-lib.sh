# ----------------------------------------------------------------
# Shared machinery for running a coding agent inside a microsandbox.
#
# Sourced by the per-agent entry scripts (pi-msb.sh, claude-msb.sh).
# Each entry script defines three hooks and then calls
#
#     msb_agent_run AGENT "$@"
#
# Hooks (AGENT is e.g. "pi" or "claude"):
#
#   AGENT_msb_credentials
#       Resolve credentials on the host. Register each one with
#       msb_agent_add_secret (the real value never enters the
#       sandbox) and append any non-secret env to agent_env_args.
#
#   AGENT_msb_install
#       Install / update the agent in the sandbox. May use $name,
#       $guest_user and $guest_home.
#
#   AGENT_msb_args ARGS...
#       Set agent_cmd (the guest command) and agent_args from the
#       user's passthrough ARGS. If $extra_system_prompt is non-empty
#       it must be appended to the agent's system prompt.
#
# Hooks communicate with the core via these (dynamically scoped)
# variables of msb_agent_run: secret_args, secret_specs,
# agent_env_args, agent_cmd, agent_args, extra_system_prompt,
# name, dir, guest_user, guest_home.
#
# Entry scripts may set sandbox_prefix before calling msb_agent_run.
# Sandboxes are named "<sandbox_prefix><project>", so agents with
# different prefixes get separate sandboxes (and separate secrets).
# ----------------------------------------------------------------

# Directory containing this library (used to locate capture_screenshots.py).
_MSB_AGENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Always appended to the agent's system prompt.
_MSB_AGENT_ENV_PROMPT="$(cat <<'EOF_PROMPT'
You are running inside a microsandbox VM (Debian, passwordless sudo). The project is mounted at /workspace. API credentials are placeholders that are replaced with real values by a proxy on the host; they are not usable secrets.

Outbound HTTPS is intercepted by that proxy (TLS interception), so servers present certificates signed by the microsandbox CA at /.msb/tls/ca.pem. It is already in the system bundle /etc/ssl/certs/ca-certificates.crt, and SSL_CERT_FILE, REQUESTS_CA_BUNDLE, CURL_CA_BUNDLE and NODE_EXTRA_CA_CERTS point at it, so curl, git, Python, Node and Go work as usual. If a tool fails with a certificate error (PKIX path building failed, unable to get local issuer certificate, self-signed certificate in chain), make that tool trust the CA rather than giving up:
- Java (Gradle, Maven, sbt, etc.): run `msb-trust-java`, which adds the CA to every JDK it finds. It runs automatically after apt installs; run it yourself after installing a JDK any other way (SDKMAN, tarballs, Gradle toolchains), then stop any running Gradle daemons (`./gradlew --stop`) and retry.
- Other tools with their own CA list: point them at /etc/ssl/certs/ca-certificates.crt (e.g. `pip config set global.cert`, `npm config set cafile`, `DENO_CERT`, `GIT_SSL_CAINFO`, `AWS_CA_BUNDLE`) or add /.msb/tls/ca.pem to their trust store.
Never disable certificate verification. If you still cannot get a tool to connect, stop and report the exact error and command instead of skipping the step.
EOF_PROMPT
)"

# Hosts the sandbox may reach when MSB_AGENT_NET=allowlist (the
# default). Each secret's host is added automatically, agents add their
# own with msb_agent_allow_host, and MSB_AGENT_NET_ALLOW adds more.
#
# msb can't change the policy of an existing sandbox, so this errs on
# the side of covering routine package, toolchain and image downloads.
# "*.example.com" matches example.com and all of its subdomains; it is
# preferred so new download/CDN subdomains keep working.
#
# Deliberately excluded: general-purpose storage and file hosts (S3,
# storage.googleapis.com, pastebins, ...), which accept anonymous
# uploads to attacker-controlled buckets. Everything below only serves
# downloads to a sandbox without credentials.
_MSB_AGENT_NET_ALLOW_DEFAULT=(
    # Debian packages
    "*.debian.org"

    # Git hosting. The sandbox has no credentials for these, so they
    # are effectively read-only (clone, fetch, API reads, downloads).
    "*.github.com" "*.githubusercontent.com" "*.github.io"
    "*.gitlab.com" bitbucket.org

    # Container registries (for docker/podman inside the sandbox; msb
    # pulls the sandbox image itself on the host).
    "*.docker.io" "*.docker.com"            # Docker Hub (incl. its blob CDN), download.docker.com
    ghcr.io                                 # GitHub (blobs: *.githubusercontent.com)
    "*.quay.io"                             # Quay (blobs: cdn*.quay.io)
    "*.mcr.microsoft.com"                   # Microsoft (blobs: *.data.mcr.microsoft.com)
    public.ecr.aws                          # AWS public gallery
    gcr.io "*.gcr.io" "*.pkg.dev"           # Google / Artifact Registry
    "*.k8s.io"                              # registry.k8s.io, dl.k8s.io

    # Node / JavaScript
    nodejs.org "*.npmjs.org" "*.npmjs.com" "*.yarnpkg.com"
    get.pnpm.io bun.sh "*.jsr.io" deno.land dl.deno.land

    # Python
    pypi.org "*.python.org" "*.pythonhosted.org" bootstrap.pypa.io astral.sh
    "*.anaconda.org" "*.anaconda.com"

    # Java / JVM
    "*.gradle.org"                          # services, downloads, plugins, plugins-artifacts
    "*.maven.org" "*.apache.org"            # repo1.maven.org, repo.maven.apache.org, archive/downloads
    maven.google.com dl.google.com          # Android / Google Maven, Go downloads
    "*.adoptium.net" api.foojay.io          # Temurin JDKs, Gradle toolchain resolution
    cdn.azul.com corretto.aws "*.sdkman.io"
    repo.scala-sbt.org

    # Go
    go.dev "*.golang.org"                   # proxy / sum / index

    # Rust
    "*.rust-lang.org" "*.rustup.rs" "*.crates.io"

    # Ruby, PHP, .NET
    "*.rubygems.org"
    getcomposer.org "*.packagist.org"
    "*.nuget.org" dot.net builds.dotnet.microsoft.com

    # Other routine tooling
    cdn.playwright.dev playwright.download.prss.microsoft.com
    releases.hashicorp.com registry.terraform.io get.helm.sh
)

# ----------------------------------------------------------------
# Allow the sandbox to reach HOST... (see _MSB_AGENT_NET_ALLOW_DEFAULT).
# ----------------------------------------------------------------
msb_agent_allow_host() {
    net_allow+=( "$@" )
}

# ----------------------------------------------------------------
# Print the msb-agent-net label of sandbox NAME: the network policy it
# was created with. Sandboxes from before this label existed were
# always created with an open network, so an unlabelled one is "open".
# Prints nothing if it can't be determined (no jq, unknown format).
# ----------------------------------------------------------------
_msb_agent_net_label() {
    command -v jq >/dev/null 2>&1 || return 0

    msb inspect "$1" --format json 2>/dev/null \
    | jq -r '
        ( [.. | objects | select(has("msb-agent-net")) | .["msb-agent-net"]]
          + [.. | strings | select(startswith("msb-agent-net="))
                | ltrimstr("msb-agent-net=")] )[0]
        // "open"' 2>/dev/null
}

# ----------------------------------------------------------------
# Register a host env var as an msb secret for HOST.
#
# The variable must be exported on the host. The guest only ever sees
# a placeholder, which msb substitutes on requests to HOST.
#
# Usage: msb_agent_add_secret VAR HOST [OPTS]
#   OPTS: msb secret options, e.g. "body". Defaults to
#         "passthrough=HOST", which works around an msb 0.7.3 bug where
#         any '%' in a request body drops the connection when a header
#         secret is substituted (microsandbox#1664). Headers are still
#         substituted and the body is passed through unchanged, so the
#         real secret can never be echoed back into the sandbox. Pass ""
#         for msb's default once a fixed msb is released.
# ----------------------------------------------------------------
msb_agent_add_secret() {
    local var="$1" host="$2" opts="${3-passthrough=$2}"

    secret_args+=( --secret "${var}${opts:+:$opts}@${host}" )
    secret_specs+=( "$var|$opts" )
    net_allow+=( "$host" )
}

msb_agent_run() {

    local agent="$1"
    shift

    local tool="${agent}-msb"

    local dir name
    local git_dir="" git_common="" primary="" source_name=""
    local linked_worktree=0
    local host_uid host_gid
    local guest_user guest_home

    local -a secret_args secret_specs net_allow
    local -a agent_env_args agent_args
    local -a create_mounts
    local agent_cmd="$agent"
    local extra_system_prompt="$_MSB_AGENT_ENV_PROMPT"

    # ------------------------------------------------------------
    # Parse common options; everything else goes to the agent.
    #
    #   --with-screenshots [WINDOW]
    #       Continuously capture a host (macOS) window into
    #       /workspace/.<tool>/screenshot.png so the agent can see it.
    #       WINDOW is a window id or name substring; if omitted, the
    #       user is asked to pick from a list of open windows.
    # ------------------------------------------------------------

    local screenshots=0
    local screenshot_window="${MSB_AGENT_SCREENSHOT_WINDOW:-${PI_MSB_SCREENSHOT_WINDOW:-}}"
    local screenshot_interval="${MSB_AGENT_SCREENSHOT_INTERVAL:-${PI_MSB_SCREENSHOT_INTERVAL:-2}}"
    local screenshot_max_size="${MSB_AGENT_SCREENSHOT_MAX_SIZE:-${PI_MSB_SCREENSHOT_MAX_SIZE:-1600}}"
    local -a passthrough_args

    [[ -n "$screenshot_window" ]] && screenshots=1

    while (( $# > 0 )); do
        case "$1" in
            --with-screenshots=*)
                screenshots=1
                screenshot_window="${1#*=}"
                shift
                ;;
            --with-screenshots)
                screenshots=1
                shift
                if (( $# > 0 )) && [[ "$1" != -* ]]; then
                    screenshot_window="$1"
                    shift
                fi
                ;;
            --)
                passthrough_args+=( "$@" )
                break
                ;;
            *)
                passthrough_args+=( "$1" )
                shift
                ;;
        esac
    done

    set -- "${passthrough_args[@]}"

    if (( screenshots )); then
        if [[ "$(uname -s)" != "Darwin" ]]; then
            echo "error: --with-screenshots is only supported on macOS hosts" >&2
            return 1
        fi
        command -v uv >/dev/null 2>&1 || {
            echo "error: --with-screenshots requires uv on the host" >&2
            return 1
        }
        [[ -f "$_MSB_AGENT_LIB_DIR/capture_screenshots.py" ]] || {
            echo "error: $_MSB_AGENT_LIB_DIR/capture_screenshots.py not found" >&2
            return 1
        }

        # Ask the user now, before the (slow) sandbox setup.
        if [[ -z "$screenshot_window" ]]; then
            screenshot_window="$(_msb_agent_choose_window)" || return 1
        fi
    fi

    host_uid="$(id -u)"
    host_gid="$(id -g)"

    command -v msb >/dev/null 2>&1 || {
        echo "error: msb not found" >&2
        return 1
    }

    local git_user_name=""
    local git_user_email=""

    # ------------------------------------------------------------
    # Determine project/worktree root.
    # ------------------------------------------------------------

    if dir="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        dir="$(cd "$dir" && pwd -P)"
    else
        dir="$(pwd -P)"
    fi

    name="${sandbox_prefix:-}$(basename "$dir")"

    # Resolve the effective Git identity for this repository on the host.
    # This respects global config, repo-local overrides and includeIf rules
    # without exposing ~/.gitconfig or any credential configuration.
    git_user_name="$(
        git -C "$dir" config --get user.name 2>/dev/null
    )" || true

    git_user_email="$(
        git -C "$dir" config --get user.email 2>/dev/null
    )" || true

    # ------------------------------------------------------------
    # Always hide the real .env.
    #
    # If .env.agent is absent, create an empty file and mount that
    # over /workspace/.env.
    # ------------------------------------------------------------

    if [[ ! -e "$dir/.env.agent" ]]; then
        touch "$dir/.env.agent" || return 1
        echo "Created empty .env.agent"
    fi

    # ------------------------------------------------------------
    # Resolve credentials on the host (agent specific).
    # ------------------------------------------------------------

    "${agent}_msb_credentials" || return 1

    # ------------------------------------------------------------
    # Network policy. msb can't change it on an existing sandbox, so
    # it is applied at create/restore and recorded in a label; a
    # sandbox with a different policy gets a warning instead.
    #
    #   MSB_AGENT_NET=allowlist (default)  deny all but the allowlist
    #   MSB_AGENT_NET=open                 unrestricted public network
    #   MSB_AGENT_NET_ALLOW="a.com,*.b.com"  extra allowed hosts
    # ------------------------------------------------------------

    local net_mode="${MSB_AGENT_NET:-allowlist}"
    local net_rules="" net_label net_hosts=""
    local -a net_create_args net_restore_args

    case "$net_mode" in
        open)
            net_label=open
            net_create_args=( --net public )
            ;;
        allowlist)
            local -a net_extra
            local h

            IFS=', ' read -r -a net_extra <<< "${MSB_AGENT_NET_ALLOW:-}"
            net_hosts="$(
                printf '%s\n' "${_MSB_AGENT_NET_ALLOW_DEFAULT[@]}" \
                    "${net_allow[@]}" "${net_extra[@]}" \
                | sed '/^$/d' | sort -u
            )"

            net_rules="allow@dns"
            while IFS= read -r h; do
                net_rules+=",allow@$h"
            done <<< "$net_hosts"

            net_label="allowlist-$(printf '%s' "$net_rules" | cksum | cut -d' ' -f1)"

            # In strict mode (msb's default), hostname rules only admit
            # HTTPS that msb can intercept, so interception must be on
            # even when there are no secrets.
            net_create_args=( --net-default deny --net-rule "$net_rules" --tls-intercept )
            net_restore_args=( --net-default deny --net-rule "$net_rules" )
            ;;
        *)
            echo "error: MSB_AGENT_NET must be 'allowlist' or 'open' (got '$net_mode')" >&2
            return 1
            ;;
    esac

    local net_policy_current=1

    # ------------------------------------------------------------
    # Discover Git worktree layout.
    # ------------------------------------------------------------

    if git -C "$dir" rev-parse \
        --is-inside-work-tree >/dev/null 2>&1
    then
        git_dir="$(
            git -C "$dir" rev-parse \
                --path-format=absolute \
                --git-dir
        )" || return 1

        git_common="$(
            git -C "$dir" rev-parse \
                --path-format=absolute \
                --git-common-dir
        )" || return 1

        if [[ "$git_dir" != "$git_common" ]]; then
            linked_worktree=1

            primary="$(
                git -C "$dir" worktree list --porcelain |
                    sed -n "s/^worktree //p" |
                    head -1
            )"

            if [[ -n "$primary" ]]; then
                primary="$(cd "$primary" && pwd -P)"
                source_name="${sandbox_prefix:-}$(basename "$primary")"
            fi
        fi
    fi

    # ------------------------------------------------------------
    # Reuse an existing sandbox, clone the primary worktree VM disk
    # into a fresh sandbox for linked worktrees, or create from scratch.
    #
    # The sandbox is per project and sandbox_prefix: agents that share a
    # prefix share it.
    # ------------------------------------------------------------

    if msb inspect "$name" >/dev/null 2>&1; then

        echo "Using existing sandbox: $name"

        local have_label
        have_label="$(_msb_agent_net_label "$name")"

        if [[ -n "$have_label" && "$have_label" != "$net_label" ]]; then
            net_policy_current=0
            {
                echo "warning: sandbox $name has a different network policy ($have_label)"
                echo "         than requested ($net_label). msb can't change it in place;"
                echo "         to apply it, remove the sandbox (installed packages are lost):"
                echo "             msb rm $name"
                echo "         or set MSB_AGENT_NET=open to use an unrestricted network."
            } >&2
        fi

    elif (( linked_worktree )) && \
         [[ -n "$source_name" ]] && \
         msb inspect "$source_name" >/dev/null 2>&1
    then

        echo "Cloning sandbox environment: $source_name -> $name"

        local tmpdir snap

        tmpdir="$(
            mktemp -d \
                "${TMPDIR:-/tmp}/${tool}-${source_name}.XXXXXX"
        )" || return 1

        snap="$tmpdir/${source_name}.msb"

        echo "Snapshotting configured environment..."

        if ! msb snap create \
            --sandbox "$source_name" \
            -o "$snap"
        then
            rm -rf "$tmpdir"
            return 1
        fi

        echo "Restoring environment for worktree..."

        if ! msb snap restore \
            "$snap" \
            --name "$name" \
            --cpus 4 \
            --memory 8G \
            -v "$dir:/workspace:uid=$host_uid,gid=$host_gid,host-perms=private" \
            -v "$git_common:$git_common:uid=$host_uid,gid=$host_gid,host-perms=private" \
            -v "$dir/.env.agent:/workspace/.env:ro,uid=$host_uid,gid=$host_gid,host-perms=private" \
            "${net_restore_args[@]}"
        then
            rm -rf "$tmpdir"
            return 1
        fi

        rm -rf "$tmpdir"

        msb modify "$name" --label "msb-agent-net=$net_label" >/dev/null \
        || echo "warning: could not label sandbox $name with its network policy" >&2

    else

        echo "Creating new sandbox: $name"

        create_mounts=(
            --mount-dir
            "$dir:/workspace:uid=$host_uid,gid=$host_gid,host-perms=private"
        )

        if (( linked_worktree )); then
            echo "Git common dir: $git_common"

            create_mounts+=(
                --mount-dir
                "$git_common:$git_common:uid=$host_uid,gid=$host_gid,host-perms=private"
            )
        fi

        create_mounts+=(
            --mount-file
            "$dir/.env.agent:/workspace/.env:ro,uid=$host_uid,gid=$host_gid,host-perms=private"
        )

        msb create \
            --name "$name" \
            --cpus 4 \
            --memory 8G \
            --root-disk 20G \
            --workdir /workspace \
            "${net_create_args[@]}" \
            --label "msb-agent-net=$net_label" \
            --trust-host-cas \
            "${secret_args[@]}" \
            "${create_mounts[@]}" \
            node:22-bookworm \
        || return 1
    fi

    # ------------------------------------------------------------
    # Refresh/add secrets every time we run.
    # ------------------------------------------------------------

    # Changing secret options (e.g. body substitution or passthrough) is
    # reported by msb as a "live" change, but the proxy only picks it up
    # after a full restart (`msb modify --restart` is not enough). Detect
    # a mismatch now, before modifying, so we know whether to restart
    # afterwards.
    local needs_restart=0

    if (( ${#secret_specs[@]} > 0 )) && command -v jq >/dev/null 2>&1; then
        local spec var opts opt want_body sandbox_json
        local -a opt_list want_passthrough

        sandbox_json="$(msb inspect "$name" --format json 2>/dev/null)"

        for spec in "${secret_specs[@]}"; do
            var="${spec%%|*}"
            opts="${spec#*|}"

            want_body=false
            want_passthrough=()
            IFS=, read -r -a opt_list <<< "$opts"
            for opt in "${opt_list[@]}"; do
                case "$opt" in
                    body) want_body=true ;;
                    passthrough=*) want_passthrough+=( "${opt#passthrough=}" ) ;;
                esac
            done

            # Only compare fields present in the inspect output; a secret
            # that isn't there yet is added by the restart-backed modify.
            if [[ "$(
                printf '%s\n' "${want_passthrough[@]}" \
                | jq -R -s -r \
                    --arg var "$var" \
                    --argjson body "$want_body" \
                    --argjson sandbox "${sandbox_json:-null}" \
                    '(split("\n") | map(select(. != "")) | sort) as $passthrough
                     | [$sandbox | .. | objects | select(.env_var? == $var)][0] as $cur
                     | if $cur == null then "same"
                       elif ($cur.substitution.body != null
                             and $cur.substitution.body != $body) then "changed"
                       elif ($cur | has("passthrough"))
                             and (($cur.passthrough // []) | sort) != $passthrough then "changed"
                       else "same" end' \
                    2>/dev/null
            )" == changed ]]; then
                needs_restart=1
            fi
        done
    fi

    if (( ${#secret_args[@]} > 0 )); then
        msb modify \
            "$name" \
            "${secret_args[@]}" \
            --restart \
            >/dev/null \
        || return 1
    fi

    if (( needs_restart )); then
        echo "Secret options changed; restarting sandbox $name to apply"
        echo "  (this terminates any other agent sessions running in it)"
        msb restart "$name" >/dev/null || return 1
    fi

    # ------------------------------------------------------------
    # Create a matching guest user if needed.
    #
    # Do NOT capture the output of useradd/groupadd: tools may emit
    # warnings which Microsandbox can merge into stdout.
    # ------------------------------------------------------------

    msb exec "$name" -- \
        bash -c '
            set -euo pipefail

            uid="$1"
            gid="$2"

            # Already have an account with this UID: nothing to do.
            if getent passwd "$uid" >/dev/null; then
                exit 0
            fi

            # Ensure the host numeric GID exists.
            if ! getent group "$gid" >/dev/null; then
                group_name="agent-host-$gid"

                if getent group "$group_name" >/dev/null; then
                    group_name="agent-host-$gid-$uid"
                fi

                groupadd \
                    --gid "$gid" \
                    "$group_name"
            fi

            user_name="agent"

            if getent passwd "$user_name" >/dev/null; then
                user_name="agent-$uid"
            fi

            # macOS UIDs such as 501 are below Debian UID_MIN=1000.
            # Override UID_MIN for this invocation so it is accepted
            # without the misleading warning.
            useradd \
                -K UID_MIN=0 \
                -K UID_MAX=4294967294 \
                --create-home \
                --uid "$uid" \
                --gid "$gid" \
                --shell /bin/bash \
                "$user_name"
        ' \
        msb-agent-create-user \
        "$host_uid" \
        "$host_gid" \
    || return 1

    # Now determine the username in a separate, clean query.
    guest_user="$(
        msb exec -q "$name" -- \
            getent passwd "$host_uid" |
            cut -d: -f1
    )" || return 1

    if [[ -z "$guest_user" ]]; then
        echo "error: failed to determine/create sandbox user" >&2
        return 1
    fi

    echo "Sandbox user: $guest_user ($host_uid:$host_gid)"

    # ------------------------------------------------------------
    # Ensure its primary numeric GID matches the host.
    # ------------------------------------------------------------

    msb exec -q "$name" -- \
        bash -c '
            set -euo pipefail

            user="$1"
            gid="$2"

            if ! getent group "$gid" >/dev/null; then
                groupadd \
                    --gid "$gid" \
                    "agent-host-$gid"
            fi

            current_gid="$(id -g "$user")"

            if [[ "$current_gid" != "$gid" ]]; then
                usermod \
                    --gid "$gid" \
                    "$user"
            fi
        ' \
        msb-agent-fix-group \
        "$guest_user" \
        "$host_gid" \
    || return 1

    # ------------------------------------------------------------
    # Determine guest home.
    # ------------------------------------------------------------

    guest_home="$(
        msb exec -q "$name" -- \
            getent passwd "$guest_user" |
            cut -d: -f6
    )" || return 1

    if [[ -z "$guest_home" ]]; then
        echo "error: unable to determine guest home directory" >&2
        return 1
    fi

    # ------------------------------------------------------------
    # Install sudo and passwordless sudo. Safe to run repeatedly.
    # ------------------------------------------------------------

    msb exec -q "$name" -- \
        bash -c '
            set -euo pipefail

            guest_user="$1"

            if ! command -v sudo >/dev/null 2>&1; then
                echo "Installing sudo..."

                export DEBIAN_FRONTEND=noninteractive

                apt-get update
                apt-get install -y sudo
            fi

            printf "%s ALL=(ALL) NOPASSWD:ALL\n" "$guest_user" \
                > /etc/sudoers.d/pi-agent

            chmod 0440 /etc/sudoers.d/pi-agent
        ' \
        msb-agent-bootstrap \
        "$guest_user" \
    || return 1

    # ------------------------------------------------------------
    # Make Java trust the TLS interception CA (msb already covers the
    # system store, curl, Python, Node etc.). Re-run after every apt
    # install so JDKs installed by the agent are covered too.
    # ------------------------------------------------------------

    msb exec -q "$name" -- \
        bash -c '
            set -euo pipefail

            printf "%s" "$1" > /usr/local/bin/msb-trust-java
            chmod 0755 /usr/local/bin/msb-trust-java

            printf "%s\n" \
                "DPkg::Post-Invoke { \"/usr/local/bin/msb-trust-java -q || true\"; };" \
                > /etc/apt/apt.conf.d/99msb-trust-java

            /usr/local/bin/msb-trust-java
        ' \
        msb-trust-java-setup \
        "$(< "$_MSB_AGENT_LIB_DIR/msb-trust-java.sh")" \
    || echo "warning: could not set up Java trust for the TLS interception CA" >&2

    # ------------------------------------------------------------
    # Install the agent (agent specific).
    # ------------------------------------------------------------

    "${agent}_msb_install" || return 1

    # ------------------------------------------------------------
    # Verify that our normal user can actually modify the worktree.
    #
    # Deliberately do NOT chown the repository if this fails.
    # ------------------------------------------------------------

    if ! msb exec \
        -q \
        --user "$guest_user" \
        "$name" \
        -- test -w /workspace
    then
        echo "error: /workspace is not writable as $guest_user" >&2
        echo "       the sandbox mounts may have been created by an older $tool version" >&2
        return 1
    fi

    # ------------------------------------------------------------
    # Screenshot proxy: capture on the host into the mounted
    # workspace, where the guest sees it at /workspace/.<tool>/.
    # ------------------------------------------------------------

    local screenshot_pid=""

    if (( screenshots )); then
        local shot_dir="$dir/.$tool"
        local shot_file="$shot_dir/screenshot.png"
        local shot_log="$shot_dir/screenshots.log"
        local guest_shot="/workspace/.$tool/screenshot.png"

        mkdir -p "$shot_dir" || return 1
        # Keep the capture directory out of git.
        [[ -f "$shot_dir/.gitignore" ]] || printf '*\n' > "$shot_dir/.gitignore"
        rm -f "$shot_file"

        echo "Starting screenshot capture for window: $screenshot_window"

        uv run --quiet --no-project --with pyobjc-framework-Quartz \
            python3 "$_MSB_AGENT_LIB_DIR/capture_screenshots.py" \
            --output "$shot_file" \
            --interval "$screenshot_interval" \
            --max-size "$screenshot_max_size" \
            --parent-pid "$$" \
            "$screenshot_window" \
            > "$shot_log" 2>&1 &
        screenshot_pid=$!

        # Wait briefly for the first frame so failures are visible now.
        local i
        for (( i = 0; i < 50; i++ )); do
            [[ -s "$shot_file" ]] && break
            kill -0 "$screenshot_pid" 2>/dev/null || break
            sleep 0.2
        done

        if [[ ! -s "$shot_file" ]]; then
            echo "error: screenshot capture failed; see $shot_log" >&2
            echo "       (if window titles are missing from the list, the terminal needs" >&2
            echo "        Screen Recording permission: System Settings -> Privacy & Security)" >&2
            sed 's/^/       /' "$shot_log" >&2
            kill "$screenshot_pid" 2>/dev/null
            return 1
        fi

        echo "Screenshot capture started (PID: $screenshot_pid, log: $shot_log)"

        extra_system_prompt+=$'\n\n'"A live screenshot of the user's application window ($screenshot_window) is available at $guest_shot. It is refreshed every $screenshot_interval seconds from the host. Use the read tool on that file whenever you need to see the current state of the UI (e.g. after making a change, wait a few seconds and read it again)."
    fi

    if [[ "$net_mode" == allowlist ]] && (( net_policy_current )); then
        extra_system_prompt+=$'\n\n'"Outbound network access is restricted to these hosts (\"*.x\" includes x and its subdomains): $(printf '%s\n' "$net_hosts" | paste -sd, - | sed 's/,/, /g'). Connections to anything else are refused. GitHub has no credentials here, so it is read-only (clone, fetch, downloads). If a task needs another host, do not try to work around the restriction: tell the user which host is needed and why, so they can add it with MSB_AGENT_NET_ALLOW (which requires recreating the sandbox)."
    fi

    # ------------------------------------------------------------
    # Launch the agent.
    # ------------------------------------------------------------

    "${agent}_msb_args" "$@" || {
        [[ -n "$screenshot_pid" ]] && kill "$screenshot_pid" 2>/dev/null
        return 1
    }

    echo "Starting $agent_cmd in sandbox $name as $guest_user ($host_uid:$host_gid)"

    local rc=0

    msb exec \
        -t \
        --user "$guest_user" \
        --env "HOME=$guest_home" \
        --env "USER=$guest_user" \
        --env "LOGNAME=$guest_user" \
        --env "GIT_AUTHOR_NAME=$git_user_name" \
        --env "GIT_AUTHOR_EMAIL=$git_user_email" \
        --env "GIT_COMMITTER_NAME=$git_user_name" \
        --env "GIT_COMMITTER_EMAIL=$git_user_email" \
        "${agent_env_args[@]}" \
        --workdir /workspace \
        "$name" \
        -- bash -lc 'cmd="$1"; shift; exec "$cmd" "$@"' "$tool" "$agent_cmd" "${agent_args[@]}" \
    || rc=$?

    if [[ -n "$screenshot_pid" ]]; then
        kill "$screenshot_pid" 2>/dev/null
        wait "$screenshot_pid" 2>/dev/null
    fi

    return "$rc"
}

# ----------------------------------------------------------------
# Interactively choose a host window to capture. The menu goes to
# stderr; the chosen window id is printed on stdout.
# ----------------------------------------------------------------
_msb_agent_choose_window() {
    local listing choice id owner title size
    local -a ids labels

    listing="$(
        uv run --quiet --no-project --with pyobjc-framework-Quartz \
            python3 "$_MSB_AGENT_LIB_DIR/capture_screenshots.py" --list
    )" || {
        echo "error: unable to list windows" >&2
        return 1
    }

    while IFS=$'\t' read -r id owner title size; do
        [[ -z "$id" ]] && continue
        ids+=( "$id" )
        labels+=( "$owner${title:+ - $title} ($size)" )
    done <<< "$listing"

    if (( ${#ids[@]} == 0 )); then
        echo "error: no capturable windows found" >&2
        echo "       (the terminal may need Screen Recording permission)" >&2
        return 1
    fi

    echo "Select a window to share with the sandbox:" >&2
    local i
    for (( i = 0; i < ${#ids[@]}; i++ )); do
        printf '  %2d) %s\n' "$(( i + 1 ))" "${labels[$i]}" >&2
    done

    while true; do
        read -r -p "Window number (q to cancel): " choice < /dev/tty >&2 || return 1
        [[ "$choice" == q ]] && return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ids[@]} )); then
            echo "Sharing: ${labels[$(( choice - 1 ))]}" >&2
            printf '%s\n' "${ids[$(( choice - 1 ))]}"
            return 0
        fi
        echo "Invalid choice" >&2
    done
}
