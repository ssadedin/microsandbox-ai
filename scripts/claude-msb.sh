# Run Claude Code inside a microsandbox, authenticated with the user's
# Claude subscription. See msb-agent-lib.sh for the shared sandbox/
# worktree/screenshot machinery.
#
# Auth: a long-lived token from `claude setup-token` is kept on the host
# (macOS Keychain, or a 0600 file elsewhere) and given to msb as a
# secret, so the sandbox only ever sees a placeholder.
#
# Environment:
#   CLAUDE_MSB_OAUTH_TOKEN      use this token instead of the stored one
#   CLAUDE_MSB_SECRET_OPTS      msb secret options (default: passthrough
#                               for api.anthropic.com, see
#                               msb_agent_add_secret)
#   CLAUDE_MSB_SKIP_PERMISSIONS=0   don't pass --dangerously-skip-permissions
#   CLAUDE_MSB_SYNC             space separated ~/.claude entries to copy
#                               into the sandbox on each launch

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/msb-agent-lib.sh"

_CLAUDE_MSB_KEYCHAIN_SERVICE="claude-msb"
_CLAUDE_MSB_TOKEN_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/claude-msb/oauth-token"

claude-msb() {

    # Exported by claude_msb_credentials; must outlive it so that msb can
    # read it when creating/modifying the sandbox.
    local CLAUDE_CODE_OAUTH_TOKEN=""

    # Separate from pi-msb's sandbox (named after the project alone):
    # msb re-resolves every secret on modify, so a shared sandbox needs
    # every agent's host credentials.
    local sandbox_prefix="claude-"

    msb_agent_run claude "$@"
}

# ----------------------------------------------------------------
# Resolve the subscription token on the host.
# ----------------------------------------------------------------
claude_msb_credentials() {

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

    # Skip first-run onboarding, and trust /workspace so the trust and
    # bypass-permissions dialogs are not shown on every new sandbox.
    msb exec -q --user "$guest_user" --env "HOME=$guest_home" "$name" -- \
        node -e '
            const fs = require("fs");
            const path = process.env.HOME + "/.claude.json";
            let cfg = {};
            try { cfg = JSON.parse(fs.readFileSync(path, "utf8")); } catch {}
            cfg.hasCompletedOnboarding = true;
            cfg.bypassPermissionsModeAccepted = true;
            cfg.projects = cfg.projects || {};
            cfg.projects["/workspace"] = Object.assign(
                cfg.projects["/workspace"] || {},
                { hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true });
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
        '
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
            claude-msb-sync "/workspace/$stage_rel" \
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

    read -r -s -p "Paste the token (input hidden): " token || return 1
    echo >&2

    token="${token//[[:space:]]/}"

    if [[ "$token" != sk-ant-* ]]; then
        echo "error: that doesn't look like a Claude token (expected sk-ant-...)" >&2
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
