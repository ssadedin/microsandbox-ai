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


    local -a secret_args
    local -a create_mounts

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

    if (( ${#secret_args[@]} > 0 )); then
        msb modify \
            "$name" \
            "${secret_args[@]}" \
            --restart \
            >/dev/null \
        || return 1
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

    echo "Starting Pi in sandbox $name as $guest_user ($host_uid:$host_gid)"

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
        --workdir /workspace \
        "$name" \
        -- bash -lc "exec pi"
}
