#!/usr/bin/env bash
# Run Claude Code inside a microsandbox, authenticated with the user's
# Claude subscription. See msb-agent-lib.sh for the shared sandbox/
# worktree/screenshot machinery.
#
# Auth: a long-lived token from `claude setup-token` is kept on the host
# (macOS Keychain, or a 0600 file elsewhere) and given to msb as a
# secret, so the sandbox only ever sees a placeholder.
#
# With CLAUDE_MSB_BEDROCK=1 Claude uses Amazon Bedrock instead: a
# short-term Bedrock API key is minted on the host from a dedicated AWS
# profile (the same mechanism as pi-msb) and passed the same way.
#
# Environment:
#   CLAUDE_MSB_OAUTH_TOKEN      use this token instead of the stored one
#   CLAUDE_MSB_SECRET_OPTS      msb secret options (default: passthrough
#                               for api.anthropic.com, see
#                               msb_agent_add_secret)
#   CLAUDE_MSB_BEDROCK=1        use Amazon Bedrock instead of a subscription
#   CLAUDE_MSB_AWS_PROFILE      AWS profile that signs the key (default
#                               PI_MSB_AWS_PROFILE, else pi-msb)
#   CLAUDE_MSB_AWS_REGION       default ap-southeast-2
#   CLAUDE_MSB_BEDROCK_TOKEN_EXPIRY   seconds, default 43200 (max 12h)
#   CLAUDE_MSB_BEDROCK_MODEL    Bedrock model / inference profile ID
#                               (default au.anthropic.claude-opus-5-5;
#                               "" leaves Claude's default)
#   CLAUDE_MSB_BEDROCK_SMALL_MODEL   model for background tasks (default:
#                               the main model)
#   CLAUDE_MSB_SKIP_PERMISSIONS=0   don't pass --dangerously-skip-permissions
#   CLAUDE_MSB_SYNC             space separated ~/.claude entries to copy
#                               into the sandbox on each launch
#   CLAUDE_MSB_MOUNT            space separated ~/.claude directories
#                               (skills agents commands output-styles) to
#                               mount read-only instead of copying, so
#                               host edits show up immediately; needs a
#                               new sandbox (see README)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/msb-agent-lib.sh"

_CLAUDE_MSB_KEYCHAIN_SERVICE="claude-msb"
_CLAUDE_MSB_TOKEN_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-msb/oauth-token"

claude-msb() {

    # Exported by claude_msb_credentials; must outlive it so that msb can
    # read it when creating/modifying the sandbox.
    local CLAUDE_CODE_OAUTH_TOKEN=""
    local AWS_BEARER_TOKEN_BEDROCK=""

    # Entries of ~/.claude mounted read-only (see claude_msb_mounts); the
    # config sync skips them.
    local claude_mounted=""

    # Separate from pi-msb's sandbox (named after the project alone):
    # msb re-resolves every secret on modify, so a shared sandbox needs
    # every agent's host credentials. Bedrock mode has its own too, so
    # a sandbox never mixes subscription and Bedrock secrets.
    local sandbox_prefix="claude-"
    [[ "${CLAUDE_MSB_BEDROCK:-0}" == 1 ]] && sandbox_prefix="claude-bedrock-"

    msb_agent_run claude "$@"
}

# ----------------------------------------------------------------
# Resolve the subscription token on the host.
# ----------------------------------------------------------------
claude_msb_credentials() {

    if [[ "${CLAUDE_MSB_BEDROCK:-0}" == 1 ]]; then
        _claude_msb_bedrock || return 1
    else
        _claude_msb_credentials_subscription || return 1
    fi

    # Installer and auto-updater downloads.
    msb_agent_allow_host claude.ai downloads.claude.ai storage.googleapis.com

    # Telemetry and error reporting hosts are not on the allowlist.
    agent_env_args+=(
        --env DISABLE_TELEMETRY=1
        --env DISABLE_ERROR_REPORTING=1
    )
}

# ----------------------------------------------------------------
# Amazon Bedrock: mint a short-term key and tell Claude to use it. The
# model must be an ID or inference profile available in the region,
# since Claude's own defaults are for other regions.
# ----------------------------------------------------------------
_claude_msb_bedrock() {

    local profile="${CLAUDE_MSB_AWS_PROFILE:-${PI_MSB_AWS_PROFILE:-pi-msb}}"
    local region="${CLAUDE_MSB_AWS_REGION:-ap-southeast-2}"
    local expiry="${CLAUDE_MSB_BEDROCK_TOKEN_EXPIRY:-43200}"
    local model="${CLAUDE_MSB_BEDROCK_MODEL-au.anthropic.claude-opus-5-5}"
    local small="${CLAUDE_MSB_BEDROCK_SMALL_MODEL:-}"
    local var

    # Claude also uses the control-plane host for model checks.
    if ! msb_agent_bedrock "$profile" "$region" "$expiry" control-plane; then
        {
            echo "error: could not mint a Bedrock key for Claude."
            echo "       It needs uv on the host and an AWS profile named '$profile'"
            echo "       (or CLAUDE_MSB_AWS_PROFILE=<profile>); see the message above."
        } >&2
        return 1
    fi

    agent_env_args+=( --env CLAUDE_CODE_USE_BEDROCK=1 )

    [[ -n "$model" ]] && agent_env_args+=( --env "ANTHROPIC_MODEL=$model" )
    [[ -n "$small" ]] && agent_env_args+=( --env "ANTHROPIC_SMALL_FAST_MODEL=$small" )
    [[ -n "$model" ]] && echo "Default model: $model"

    # Non-secret model settings from the host environment.
    for var in ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
               ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_BEDROCK_REGION_PREFIX; do
        [[ -n "${!var:-}" ]] && agent_env_args+=( --env "$var=${!var}" )
    done

    return 0
}

_claude_msb_credentials_subscription() {

    # Not run in $(...): setup may launch `claude setup-token`, which needs
    # the real terminal on stdin/stdout.
    _claude_msb_token || return 1

    export CLAUDE_CODE_OAUTH_TOKEN

    if [[ -n "${CLAUDE_MSB_SECRET_OPTS+set}" ]]; then
        msb_agent_add_secret CLAUDE_CODE_OAUTH_TOKEN api.anthropic.com "$CLAUDE_MSB_SECRET_OPTS"
    else
        msb_agent_add_secret CLAUDE_CODE_OAUTH_TOKEN api.anthropic.com
    fi
}

# ----------------------------------------------------------------
# Install Claude Code (native installer, per user) and copy in the
# user's host configuration. Safe to run repeatedly.
# ----------------------------------------------------------------
claude_msb_install() {

    msb exec -q --user "$guest_user" --env "HOME=$guest_home" "$name" -- \
        bash -c '
            set -euo pipefail

            if [[ ! -x "$HOME/.local/bin/claude" ]]; then
                echo "Installing Claude Code..."
                curl -fsSL https://claude.ai/install.sh | bash
            fi
        ' \
        claude-msb-install \
    || return 1

    _claude_msb_sync_config || return 1

    # Skip first-run onboarding, and trust /workspace (and the directory
    # the agent starts in, which is deeper for a submodule) so the trust
    # and bypass-permissions dialogs are not shown on every new sandbox.
    msb exec -q --user "$guest_user" --env "HOME=$guest_home" "$name" -- \
        node -e '
            const fs = require("fs");
            const path = process.env.HOME + "/.claude.json";
            let cfg = {};
            try { cfg = JSON.parse(fs.readFileSync(path, "utf8")); } catch {}
            cfg.hasCompletedOnboarding = true;
            cfg.bypassPermissionsModeAccepted = true;
            cfg.projects = cfg.projects || {};
            for (const dir of new Set(["/workspace", process.argv[1]])) {
                cfg.projects[dir] = Object.assign(
                    cfg.projects[dir] || {},
                    { hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true });
            }
            fs.writeFileSync(path, JSON.stringify(cfg, null, 2));

            // Current Claude Code reads the bypass-permissions acceptance
            // from user settings. Set after the config sync, which
            // replaces settings.json with the host copy on each launch.
            const settingsPath = process.env.HOME + "/.claude/settings.json";
            let settings = {};
            try { settings = JSON.parse(fs.readFileSync(settingsPath, "utf8")); } catch {}
            settings.skipDangerousModePermissionPrompt = true;
            fs.mkdirSync(process.env.HOME + "/.claude", { recursive: true });
            fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2));
        ' "$guest_dir"
}

# ----------------------------------------------------------------
# Where Claude keeps user-level MCP servers (for --gitlab-issue).
# ----------------------------------------------------------------
claude_msb_mcp_config() {
    mcp_file=".claude.json"
    mcp_extra="{}"
}

# ----------------------------------------------------------------
# Read-only mounts of ~/.claude directories (CLAUDE_MSB_MOUNT). Only
# these four leaf directories can be named: ~/.claude itself holds
# credentials, history and projects.
# ----------------------------------------------------------------
claude_msb_mounts() {

    local entry

    claude_mounted=""

    for entry in ${CLAUDE_MSB_MOUNT:-}; do
        case "$entry" in
            skills|agents|commands|output-styles) ;;
            *)
                echo "error: CLAUDE_MSB_MOUNT: '$entry' is not one of: skills agents commands output-styles" >&2
                return 1
                ;;
        esac

        if msb_agent_add_ro_mount "$HOME/.claude/$entry" ".claude/$entry" "claude-$entry"; then
            claude_mounted+=" $entry"
        fi
    done
}

# ----------------------------------------------------------------
# Build the Claude command line.
# ----------------------------------------------------------------
claude_msb_args() {

    local arg skip="${CLAUDE_MSB_SKIP_PERMISSIONS:-1}"

    # Full path: the native installer puts it in ~/.local/bin, which may
    # not be on PATH yet in a fresh account.
    agent_cmd="$guest_home/.local/bin/claude"
    agent_args=()

    # Subcommands (claude mcp, claude update, ...) take no session options.
    case "${1:-}" in
        agents|auth|config|doctor|install|mcp|plugin|setup-token|update)
            agent_args=( "$@" )
            return 0
            ;;
    esac

    for arg in "$@"; do
        case "$arg" in
            --permission-mode|--permission-mode=*|--dangerously-skip-permissions)
                skip=0
                ;;
        esac
    done

    if [[ "$skip" != "0" ]]; then
        agent_args+=( --dangerously-skip-permissions )
    fi

    if [[ -n "$extra_system_prompt" ]]; then
        agent_args+=( --append-system-prompt "$extra_system_prompt" )
    fi

    agent_args+=( "$@" )
}

# ----------------------------------------------------------------
# Copy the user's personal Claude configuration (instructions, skills,
# agents, commands, settings) into the sandbox. Credentials, history
# and plugins (which hold host paths) are never copied.
#
# Files are staged in the mounted workspace, copied (merged) into the
# guest ~/.claude, then removed.
# ----------------------------------------------------------------
_claude_msb_sync_config() {

    local host_claude="$HOME/.claude"
    local stage_rel=".claude-msb/config-sync"
    local stage="$dir/$stage_rel"
    local item copied=0

    [[ -d "$host_claude" ]] || return 0

    rm -rf "$stage"
    mkdir -p "$stage" || return 1
    [[ -f "$dir/.claude-msb/.gitignore" ]] || printf '*\n' > "$dir/.claude-msb/.gitignore"

    for item in ${CLAUDE_MSB_SYNC:-CLAUDE.md settings.json skills agents commands output-styles}; do
        [[ -e "$host_claude/$item" ]] || continue

        # Mounted read-only instead; copying into it would fail.
        case " $claude_mounted " in
            *" $item "*) continue ;;
        esac

        if [[ "$item" == settings.json ]]; then
            # Drop settings that run host commands or override auth; their
            # host paths don't exist in the sandbox.
            if command -v jq >/dev/null 2>&1; then
                jq 'del(.hooks, .statusLine, .apiKeyHelper, .awsAuthRefresh,
                        .awsCredentialExport, .otelHeadersHelper)' \
                    "$host_claude/settings.json" > "$stage/settings.json" \
                || return 1
            else
                echo "warning: jq not found; not copying ~/.claude/settings.json" >&2
                continue
            fi
        else
            # -L: skills are often symlinks into other directories.
            cp -RL "$host_claude/$item" "$stage/" || return 1
        fi

        copied=1
    done

    if (( copied )); then
        msb exec -q --user "$guest_user" --env "HOME=$guest_home" "$name" -- \
            bash -c 'mkdir -p "$HOME/.claude" && cp -R "$1"/. "$HOME/.claude/"' \
            claude-msb-sync "$guest_dir/$stage_rel" \
        || { rm -rf "$stage"; return 1; }
    fi

    rm -rf "$stage"
}

# ----------------------------------------------------------------
# Set CLAUDE_CODE_OAUTH_TOKEN to the stored `claude setup-token` token.
# If none is stored, walk the user through creating one and store it.
# ----------------------------------------------------------------
_claude_msb_token() {

    local token=""

    if [[ -n "${CLAUDE_MSB_OAUTH_TOKEN:-}" ]]; then
        CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_MSB_OAUTH_TOKEN"
        return 0
    fi

    if [[ "$(uname -s)" == "Darwin" ]]; then
        token="$(
            security find-generic-password \
                -s "$_CLAUDE_MSB_KEYCHAIN_SERVICE" \
                -a "$USER" \
                -w 2>/dev/null
        )" || token=""
    elif [[ -r "$_CLAUDE_MSB_TOKEN_FILE" ]]; then
        token="$(< "$_CLAUDE_MSB_TOKEN_FILE")"
    fi

    if [[ -n "$token" ]]; then
        CLAUDE_CODE_OAUTH_TOKEN="$token"
        return 0
    fi

    {
        echo "No Claude subscription token stored for claude-msb."
        echo
        echo "Create one with 'claude setup-token' on this host (it opens a browser"
        echo "to authorise, then prints a token starting with sk-ant-oat)."
        echo
    } >&2

    if command -v claude >/dev/null 2>&1; then
        local answer
        read -r -p "Run 'claude setup-token' now? [Y/n] " answer || return 1
        if [[ ! "$answer" =~ ^[Nn] ]]; then
            claude setup-token || return 1
            echo >&2
        fi
    fi

    local line token_re='^sk-ant-[A-Za-z0-9_-]+$'

    # Full-screen apps (like claude setup-token) can leave bracketed
    # paste on, which wraps pasted text in ESC[200~ ... ESC[201~.
    printf '\033[?2004l' > /dev/tty 2>/dev/null

    read -r -s -p "Paste the token (input hidden): " token || return 1

    # A token copied from a wrapped terminal line can arrive as several
    # lines; collect the rest of the paste.
    while IFS= read -r -s -t 1 line; do
        token+="$line"
    done
    echo >&2

    # Drop any paste markers and whitespace.
    token="$(printf '%s' "$token" | tr -d '\033' | sed 's/\[20[01]~//g' | tr -d '[:space:]')"

    if [[ ! "$token" =~ $token_re ]]; then
        echo "error: that doesn't look like a Claude token (expected sk-ant-...)" >&2
        echo "       received ${#token} characters starting with: $(printf '%s' "${token:0:12}" | cat -v)" >&2
        return 1
    fi

    if [[ "$(uname -s)" == "Darwin" ]]; then
        security add-generic-password \
            -U \
            -s "$_CLAUDE_MSB_KEYCHAIN_SERVICE" \
            -a "$USER" \
            -l "claude-msb subscription token" \
            -w "$token" \
        || return 1
        echo "Token stored in Keychain (service '$_CLAUDE_MSB_KEYCHAIN_SERVICE')" >&2
    else
        mkdir -p "$(dirname "$_CLAUDE_MSB_TOKEN_FILE")" || return 1
        ( umask 077 && printf '%s\n' "$token" > "$_CLAUDE_MSB_TOKEN_FILE" ) || return 1
        echo "Token stored in $_CLAUDE_MSB_TOKEN_FILE" >&2
    fi

    CLAUDE_CODE_OAUTH_TOKEN="$token"
}

claude-msb "$@"
