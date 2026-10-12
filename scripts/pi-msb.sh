# Run the Pi coding agent inside a microsandbox. See msb-agent-lib.sh for
# the shared sandbox/worktree/screenshot machinery.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/msb-agent-lib.sh"

pi-msb() {

    # Exported by pi_msb_credentials; must outlive it so that msb can
    # read them when creating/modifying the sandbox.
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


    msb_agent_run pi "$@"
}

# ----------------------------------------------------------------
# Resolve credentials using Pi on the host (~/.pi is never mounted
# into the sandbox), plus a short-term Bedrock token.
# ----------------------------------------------------------------
pi_msb_credentials() {

    local credential

    # Host Pi is optional: it is only used to resolve OpenRouter/OpenAI/
    # Anthropic credentials. Bedrock tokens are minted independently.
    local host_pi=0
    command -v pi >/dev/null 2>&1 && host_pi=1

    if (( host_pi )); then

        credential="$(
            pi auth print-api-key \
                --provider openrouter \
                2>/dev/null
        )"

        if [[ -n "$credential" ]]; then
            OPENROUTER_API_KEY="$credential"
            export OPENROUTER_API_KEY

            msb_agent_add_secret OPENROUTER_API_KEY openrouter.ai
        fi

        credential="$(
            pi auth print-api-key \
                --provider openai \
                2>/dev/null
        )"

        if [[ -n "$credential" ]]; then
            OPENAI_API_KEY="$credential"
            export OPENAI_API_KEY

            msb_agent_add_secret OPENAI_API_KEY api.openai.com
        fi

        credential="$(
            pi auth print-api-key \
                --provider anthropic \
                2>/dev/null
        )"

        if [[ -n "$credential" ]]; then
            ANTHROPIC_API_KEY="$credential"
            export ANTHROPIC_API_KEY

            msb_agent_add_secret ANTHROPIC_API_KEY api.anthropic.com
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

                msb_agent_add_secret ANTHROPIC_OAUTH_TOKEN api.anthropic.com
            fi
        fi
    else
        echo "Host pi not found: skipping OpenRouter/OpenAI/Anthropic credentials"
    fi

    # ------------------------------------------------------------
    # Amazon Bedrock: mint a short-term bearer token (Bedrock API key)
    # on the host from a dedicated AWS profile.
    #
    # SigV4 credentials cannot be used with msb secret placeholders
    # (signing happens inside the guest), but a bearer token is sent
    # verbatim in the Authorization header, so msb can substitute it.
    # ------------------------------------------------------------

    if [[ "${PI_MSB_BEDROCK:-1}" != "0" ]] && \
       msb_agent_bedrock "$bedrock_profile" "$bedrock_region" "$bedrock_expiry"
    then
        bedrock_enabled=1

        # The AWS SDK uses HTTP/2 for bedrock-runtime by default, which
        # fails through msb's secret-substituting TLS proxy with
        # "Protocol error". Force HTTP/1.1 unless explicitly disabled.
        if [[ "${PI_MSB_BEDROCK_FORCE_HTTP1:-1}" == "1" ]]; then
            agent_env_args+=( --env "AWS_BEDROCK_FORCE_HTTP1=1" )
        fi
    fi

    if (( ${#secret_args[@]} == 0 )); then
        echo "warning: no model credentials resolved on the host" >&2
        if (( ! host_pi )); then
            echo "       host pi not found (used for OpenRouter/OpenAI/Anthropic)" >&2
        fi
        if [[ "${PI_MSB_BEDROCK:-1}" == "0" ]]; then
            echo "       Bedrock disabled (PI_MSB_BEDROCK=0)" >&2
        else
            echo "       Bedrock needs uv on the host and an AWS profile named '$bedrock_profile'" >&2
            echo "       (or PI_MSB_AWS_PROFILE=<profile>); see the 'Bedrock: skipped' message above." >&2
            echo "       Without credentials pi will ask you to log in inside the sandbox." >&2
        fi
    fi
}

# ----------------------------------------------------------------
# Install the Pi coding agent. Safe to run repeatedly.
# ----------------------------------------------------------------
pi_msb_install() {
    msb exec -q "$name" -- \
        bash -c '
            set -euo pipefail

            if ! command -v pi >/dev/null 2>&1; then
                echo "Installing Pi coding agent..."

                npm install -g \
                    --ignore-scripts \
                    @earendil-works/pi-coding-agent
            fi
        ' \
        pi-msb-install
}

# ----------------------------------------------------------------
# Build the Pi command line.
# ----------------------------------------------------------------
# Read-only mounts of Pi's user-level resource directories
# (PI_MSB_MOUNT). Only these leaf directories can be named: the agent
# directory itself holds auth.json and MCP tokens, and sessions.
pi_msb_mounts() {

    local base="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}" entry

    for entry in ${PI_MSB_MOUNT:-}; do
        case "$entry" in
            skills|extensions|prompts|themes) ;;
            *)
                echo "error: PI_MSB_MOUNT: '$entry' is not one of: skills extensions prompts themes" >&2
                return 1
                ;;
        esac

        msb_agent_add_ro_mount "$base/$entry" ".pi/agent/$entry" "pi-$entry"
    done

    return 0
}

# Where Pi keeps user-level MCP servers (for --gitlab-issue). The
# user-level file avoids Pi's project trust prompt, and "direct" puts
# the few tools in front of the model instead of behind codemode search.
pi_msb_mcp_config() {
    mcp_file=".pi/agent/mcp.json"
    mcp_extra='{"exposure":"direct","description":"GitLab: read/comment on the assigned ticket, submit and comment on a merge request"}'
}

pi_msb_args() {

    # Default to a Bedrock model when Bedrock is enabled and the caller
    # did not choose a provider/model. AU inference profiles are not in
    # Pi's catalog, so they must be passed explicitly.
    #   PI_MSB_BEDROCK_MODEL=""  -> don't inject a default model
    local arg model_chosen=0
    local bedrock_model="${PI_MSB_BEDROCK_MODEL-au.anthropic.claude-opus-5-5}"

    agent_cmd=pi
    agent_args=()

    if [[ -n "$extra_system_prompt" ]]; then
        agent_args+=( --append-system-prompt "$extra_system_prompt" )
    fi

    for arg in "$@"; do
        case "$arg" in
            --provider|--provider=*|--model|--model=*|--models|--models=*)
                model_chosen=1
                ;;
        esac
    done

    if (( bedrock_enabled )) && (( ! model_chosen )) && [[ -n "$bedrock_model" ]]; then
        agent_args+=( --provider amazon-bedrock --model "$bedrock_model" )
        echo "Default model: amazon-bedrock/$bedrock_model"
    fi

    agent_args+=( "$@" )
}

pi-msb "$@"
