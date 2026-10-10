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

    if [[ "${PI_MSB_BEDROCK:-1}" != "0" ]]; then
        credential="$(_pi_msb_bedrock_token \
            "$bedrock_profile" "$bedrock_region" "$bedrock_expiry")"

        if [[ -n "$credential" ]]; then
            AWS_BEARER_TOKEN_BEDROCK="$credential"
            export AWS_BEARER_TOKEN_BEDROCK
            bedrock_enabled=1

            msb_agent_add_secret AWS_BEARER_TOKEN_BEDROCK \
                "bedrock-runtime.${bedrock_region}.amazonaws.com"

            # Non-secret config only. Token is region-bound, so the guest
            # region must match the signing region.
            agent_env_args+=(
                --env "AWS_REGION=$bedrock_region"
                --env "AWS_DEFAULT_REGION=$bedrock_region"
            )

            # The AWS SDK uses HTTP/2 for bedrock-runtime by default, which
            # fails through msb's secret-substituting TLS proxy with
            # "Protocol error". Force HTTP/1.1 unless explicitly disabled.
            if [[ "${PI_MSB_BEDROCK_FORCE_HTTP1:-1}" == "1" ]]; then
                agent_env_args+=( --env "AWS_BEDROCK_FORCE_HTTP1=1" )
            fi

            echo "Bedrock: short-term token minted from profile '$bedrock_profile' ($bedrock_region, ${bedrock_expiry}s)"
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
            echo "       Bedrock: configure AWS profile '$bedrock_profile' (PI_MSB_AWS_PROFILE)" >&2
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
