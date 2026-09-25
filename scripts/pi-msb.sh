# Directory containing this script (used to locate capture_screenshots.py).
_PI_MSB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

pi-msb() {

    local dir name
    local git_dir="" git_common="" primary="" source_name=""
    local linked_worktree=0
    local host_uid host_gid
    local guest_user guest_home
    local credential

    local OPENROUTER_API_KEY=""
    local OPENAI_API_KEY=""
    local ANTHROPIC_API_KEY=""
    local ANTHROPIC_OAUTH_TOKEN=""
    local AWS_BEARER_TOKEN_BEDROCK=""

    # Bedrock settings (host side). The profile is used ONLY on the host
    # to sign a short-term Bedrock API key; it never enters the sandbox.
    local bedrock_profile="${PI_MSB_AWS_PROFILE:-pi-msb}"
    local bedrock_region="${PI_MSB_AWS_REGION:-ap-southeast-2}"
    local bedrock_expiry="${PI_MSB_BEDROCK_TOKEN_EXPIRY:-43200}"   # seconds, max 12h
    local bedrock_enabled=0

    # msb secret options for the Bedrock token. "body" works around an msb
    # 0.7.3 bug where any '%' in a request body drops the connection when a
    # header secret is substituted. Trade-off: placeholders in the body are
    # also substituted, so the token could be echoed back into the sandbox.
    # Acceptable here because the token is short-lived and Bedrock-scoped.
    # Set PI_MSB_BEDROCK_SECRET_OPTS="" to use msb's default (headers only).
    local bedrock_secret_opts="${PI_MSB_BEDROCK_SECRET_OPTS-body}"
    local -a bedrock_env_args


    local -a secret_args
    local -a create_mounts

    # ------------------------------------------------------------
    # Parse pi-msb specific options; everything else goes to Pi.
    #
    #   --with-screenshots [WINDOW]
    #       Continuously capture a host (macOS) window into
    #       /workspace/.pi-msb/screenshot.png so the agent can see it.
    #       WINDOW is a window id or name substring; if omitted, the
    #       user is asked to pick from a list of open windows.
    # ------------------------------------------------------------

    local screenshots=0
    local screenshot_window="${PI_MSB_SCREENSHOT_WINDOW:-}"
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
        [[ -f "$_PI_MSB_SCRIPT_DIR/capture_screenshots.py" ]] || {
            echo "error: $_PI_MSB_SCRIPT_DIR/capture_screenshots.py not found" >&2
            return 1
        }

        # Ask the user now, before the (slow) sandbox setup.
        if [[ -z "$screenshot_window" ]]; then
            screenshot_window="$(_pi_msb_choose_window)" || return 1
        fi
    fi

    host_uid="$(id -u)"
    host_gid="$(id -g)"

    command -v msb >/dev/null 2>&1 || {
        echo "error: msb not found" >&2
        return 1
    }

    command -v pi >/dev/null 2>&1 || {
        echo "error: host pi not found" >&2
        echo "       host Pi is used to resolve/refresh credentials" >&2
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

    name="$(basename "$dir")"

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
    # Resolve credentials using Pi on the host.
    #
    # ~/.pi is never mounted into the sandbox.
    # ------------------------------------------------------------

    credential="$(
        pi auth print-api-key \
            --provider openrouter \
            2>/dev/null
    )"

    if [[ -n "$credential" ]]; then
        OPENROUTER_API_KEY="$credential"
        export OPENROUTER_API_KEY

        secret_args+=(
            --secret "OPENROUTER_API_KEY@openrouter.ai"
        )
    fi

    credential="$(
        pi auth print-api-key \
            --provider openai \
            2>/dev/null
    )"

    if [[ -n "$credential" ]]; then
        OPENAI_API_KEY="$credential"
        export OPENAI_API_KEY

        secret_args+=(
            --secret "OPENAI_API_KEY@api.openai.com"
        )
    fi

    credential="$(
        pi auth print-api-key \
            --provider anthropic \
            2>/dev/null
    )"

    if [[ -n "$credential" ]]; then
        ANTHROPIC_API_KEY="$credential"
        export ANTHROPIC_API_KEY

        secret_args+=(
            --secret "ANTHROPIC_API_KEY@api.anthropic.com"
        )
    else
        credential="$(
            pi auth print-bearer-token \
                --provider anthropic \
                --min-expiry 30m \
                2>/dev/null
        )"

        if [[ -n "$credential" ]]; then
            ANTHROPIC_OAUTH_TOKEN="$credential"
            export ANTHROPIC_OAUTH_TOKEN

            secret_args+=(
                --secret "ANTHROPIC_OAUTH_TOKEN@api.anthropic.com"
            )
        fi
    fi

    # ------------------------------------------------------------
    # Amazon Bedrock: mint a short-term bearer token (Bedrock API key)
    # on the host from a dedicated AWS profile.
    #
    # SigV4 credentials cannot be used with msb secret placeholders
    # (signing happens inside the guest), but a bearer token is sent
    # verbatim in the Authorization header, so msb can substitute it.
    # ------------------------------------------------------------

    if [[ "${PI_MSB_BEDROCK:-1}" != "0" ]]; then
        credential="$(_pi_msb_bedrock_token \
            "$bedrock_profile" "$bedrock_region" "$bedrock_expiry")"

        if [[ -n "$credential" ]]; then
            AWS_BEARER_TOKEN_BEDROCK="$credential"
            export AWS_BEARER_TOKEN_BEDROCK
            bedrock_enabled=1

            secret_args+=(
                --secret "AWS_BEARER_TOKEN_BEDROCK${bedrock_secret_opts:+:$bedrock_secret_opts}@bedrock-runtime.${bedrock_region}.amazonaws.com"
            )

            # Non-secret config only. Token is region-bound, so the guest
            # region must match the signing region.
            bedrock_env_args+=(
                --env "AWS_REGION=$bedrock_region"
                --env "AWS_DEFAULT_REGION=$bedrock_region"
            )

            # The AWS SDK uses HTTP/2 for bedrock-runtime by default, which
            # fails through msb's secret-substituting TLS proxy with
            # "Protocol error". Force HTTP/1.1 unless explicitly disabled.
            if [[ "${PI_MSB_BEDROCK_FORCE_HTTP1:-1}" == "1" ]]; then
                bedrock_env_args+=( --env "AWS_BEDROCK_FORCE_HTTP1=1" )
            fi

            echo "Bedrock: short-term token minted from profile '$bedrock_profile' ($bedrock_region, ${bedrock_expiry}s)"
        fi
    fi

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
                source_name="$(basename "$primary")"
            fi
        fi
    fi

    # ------------------------------------------------------------
    # Reuse an existing sandbox, clone the primary worktree VM disk
    # into a fresh sandbox for linked worktrees, or create from scratch.
    # ------------------------------------------------------------

    if msb inspect "$name" >/dev/null 2>&1; then

        echo "Using existing sandbox: $name"

    elif (( linked_worktree )) && \
         [[ -n "$source_name" ]] && \
         msb inspect "$source_name" >/dev/null 2>&1
    then

        echo "Cloning sandbox environment: $source_name -> $name"

        local tmpdir snap

        tmpdir="$(
            mktemp -d \
                "${TMPDIR:-/tmp}/pi-msb-${source_name}.XXXXXX"
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
            -v "$dir/.env.agent:/workspace/.env:ro,uid=$host_uid,gid=$host_gid,host-perms=private"
        then
            rm -rf "$tmpdir"
            return 1
        fi

        rm -rf "$tmpdir"

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
            --net public \
            --trust-host-cas \
            "${secret_args[@]}" \
            "${create_mounts[@]}" \
            node:22-bookworm \
        || return 1
    fi

    # ------------------------------------------------------------
    # Refresh/add secrets every time pi-msb runs.
    # ------------------------------------------------------------

    # Changing secret substitution options (e.g. adding :body) is reported
    # by msb as a "live" change, but the proxy only picks it up after a full
    # restart (`msb modify --restart` is not enough). Detect a mismatch now,
    # before modifying, so we know whether to restart afterwards.
    local bedrock_needs_restart=0

    if (( bedrock_enabled )) && command -v jq >/dev/null 2>&1; then
        local want_body=false current_body
        [[ ",$bedrock_secret_opts," == *",body,"* ]] && want_body=true

        current_body="$(
            msb inspect "$name" --format json 2>/dev/null |
                jq -r '[.. | objects
                        | select(.env_var? == "AWS_BEARER_TOKEN_BEDROCK")
                        | .substitution.body][0]
                       | if . == null then "absent" else tostring end'
        )"

        if [[ "$current_body" != "absent" && "$current_body" != "$want_body" ]]; then
            bedrock_needs_restart=1
        fi
    fi

    if (( ${#secret_args[@]} > 0 )); then
        msb modify \
            "$name" \
            "${secret_args[@]}" \
            --restart \
            >/dev/null \
        || return 1
    fi

    if (( bedrock_needs_restart )); then
        echo "Bedrock secret options changed; restarting sandbox $name to apply"
        echo "  (this terminates any other Pi sessions running in it)"
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
        pi-msb-create-user \
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
        pi-msb-fix-group \
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
    # Automatically install:
    #
    #   sudo
    #   passwordless sudo
    #   Pi coding agent
    #
    # Safe to run repeatedly.
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

            if ! command -v pi >/dev/null 2>&1; then
                echo "Installing Pi coding agent..."

                npm install -g \
                    --ignore-scripts \
                    @earendil-works/pi-coding-agent
            fi
        ' \
        pi-msb-bootstrap \
        "$guest_user" \
    || return 1

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
        echo "       the sandbox mounts may have been created by an older pi-msb version" >&2
        return 1
    fi

    # ------------------------------------------------------------
    # Launch Pi.
    # ------------------------------------------------------------

    # Default to a Bedrock model when Bedrock is enabled and the caller
    # did not choose a provider/model. AU inference profiles are not in
    # Pi's catalog, so they must be passed explicitly.
    #   PI_MSB_BEDROCK_MODEL=""  -> don't inject a default model
    local -a pi_args
    local arg model_chosen=0
    local bedrock_model="${PI_MSB_BEDROCK_MODEL-au.anthropic.claude-opus-5-5}"

    for arg in "$@"; do
        case "$arg" in
            --provider|--provider=*|--model|--model=*|--models|--models=*)
                model_chosen=1
                ;;
        esac
    done

    if (( bedrock_enabled )) && (( ! model_chosen )) && [[ -n "$bedrock_model" ]]; then
        pi_args+=( --provider amazon-bedrock --model "$bedrock_model" )
        echo "Default model: amazon-bedrock/$bedrock_model"
    fi

    pi_args+=( "$@" )

    # ------------------------------------------------------------
    # Screenshot proxy: capture on the host into the mounted
    # workspace, where the guest sees it at /workspace/.pi-msb/.
    # ------------------------------------------------------------

    local screenshot_pid=""

    if (( screenshots )); then
        local shot_dir="$dir/.pi-msb"
        local shot_file="$shot_dir/screenshot.png"
        local shot_log="$shot_dir/screenshots.log"
        local guest_shot="/workspace/.pi-msb/screenshot.png"

        mkdir -p "$shot_dir" || return 1
        # Keep the capture directory out of git.
        [[ -f "$shot_dir/.gitignore" ]] || printf '*\n' > "$shot_dir/.gitignore"
        rm -f "$shot_file"

        echo "Starting screenshot capture for window: $screenshot_window"

        uv run --quiet --no-project --with pyobjc-framework-Quartz \
            python3 "$_PI_MSB_SCRIPT_DIR/capture_screenshots.py" \
            --output "$shot_file" \
            --interval "${PI_MSB_SCREENSHOT_INTERVAL:-2}" \
            --max-size "${PI_MSB_SCREENSHOT_MAX_SIZE:-1600}" \
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

        pi_args=(
            --append-system-prompt "A live screenshot of the user's application window ($screenshot_window) is available at $guest_shot. It is refreshed every ${PI_MSB_SCREENSHOT_INTERVAL:-2} seconds from the host. Use the read tool on that file whenever you need to see the current state of the UI (e.g. after making a change, wait a few seconds and read it again)."
            "${pi_args[@]}"
        )
    fi

    echo "Starting Pi in sandbox $name as $guest_user ($host_uid:$host_gid)"

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
        "${bedrock_env_args[@]}" \
        --workdir /workspace \
        "$name" \
        -- bash -lc 'exec pi "$@"' pi "${pi_args[@]}" \
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
_pi_msb_choose_window() {
    local listing choice id owner title size
    local -a ids labels

    listing="$(
        uv run --quiet --no-project --with pyobjc-framework-Quartz \
            python3 "$_PI_MSB_SCRIPT_DIR/capture_screenshots.py" --list
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

# ----------------------------------------------------------------
# Print a short-term Amazon Bedrock API key (bearer token) signed with
# credentials from the given AWS profile. Prints nothing on failure
# (e.g. profile missing), so Bedrock is simply not enabled.
#
# Equivalent to AWS's aws-bedrock-token-generator: a SigV4 presigned
# CallWithBearerToken URL, base64 encoded, prefixed "bedrock-api-key-".
# Lifetime is min(expiry, remaining lifetime of the signing creds).
#
# Usage: _pi_msb_bedrock_token PROFILE REGION EXPIRY_SECONDS
# ----------------------------------------------------------------
_pi_msb_bedrock_token() {
    local profile="$1" region="$2" expiry="$3"

    command -v uv >/dev/null 2>&1 || {
        echo "Bedrock: skipped (uv not found; needed to sign token)" >&2
        return 0
    }

    # Run in a clean-ish env: ignore ambient AWS credentials so only the
    # dedicated profile is ever used.
    env -u AWS_ACCESS_KEY_ID \
        -u AWS_SECRET_ACCESS_KEY \
        -u AWS_SESSION_TOKEN \
        -u AWS_BEARER_TOKEN_BEDROCK \
        AWS_PROFILE="$profile" \
        uv run --quiet --no-project --with botocore python3 - \
            "$profile" "$region" "$expiry" <<'PY'
import base64, sys
from botocore.session import Session
from botocore.exceptions import ProfileNotFound, BotoCoreError
from botocore.auth import SigV4QueryAuth
from botocore.awsrequest import AWSRequest

profile, region, expiry = sys.argv[1], sys.argv[2], int(sys.argv[3])

try:
    creds = Session(profile=profile).get_credentials()
except ProfileNotFound:
    print(f"Bedrock: skipped (AWS profile '{profile}' not found)", file=sys.stderr)
    sys.exit(0)
except BotoCoreError as e:
    print(f"Bedrock: skipped ({e})", file=sys.stderr)
    sys.exit(0)

if creds is None:
    print(f"Bedrock: skipped (no credentials for profile '{profile}')", file=sys.stderr)
    sys.exit(0)

try:
    creds = creds.get_frozen_credentials()
except BotoCoreError as e:   # e.g. expired SSO session
    print(f"Bedrock: skipped ({e})", file=sys.stderr)
    sys.exit(0)

req = AWSRequest(
    method="POST",
    url="https://bedrock.amazonaws.com/",
    headers={"host": "bedrock.amazonaws.com"},
    params={"Action": "CallWithBearerToken"},
)
SigV4QueryAuth(creds, "bedrock", region, expires=expiry).add_auth(req)

url = req.url.replace("https://", "", 1) + "&Version=1"
print("bedrock-api-key-" + base64.b64encode(url.encode()).decode())
PY
}

pi-msb "$@"
