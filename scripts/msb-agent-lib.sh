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
#   AGENT_msb_mcp_config   (optional; needed for --gitlab-issue)
#       Set mcp_file (the agent's user-level MCP config, relative to
#       the guest home) and mcp_extra (JSON merged into each server
#       entry, "{}" if none).
#
# Hooks communicate with the core via these (dynamically scoped)
# variables of msb_agent_run: secret_args, secret_specs,
# agent_env_args, agent_cmd, agent_args, extra_system_prompt,
# name, dir, guest_user, guest_home, mcp_file, mcp_extra.
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

You have full administrator rights here: sudo needs no password, and the VM is disposable, so nothing you install can affect the user's machine. If building, running or testing needs a tool, runtime, database or library that is missing, install it instead of working around it (do not mock or stub it out, skip tests, or rewrite code to avoid a dependency). Use `sudo apt-get update && sudo apt-get install -y <package>` for system packages and toolchains (the Debian mirrors are reachable), and the normal package managers for language dependencies (npm, pnpm, yarn, pip, uv, cargo, go, Maven, Gradle, gem, composer, NuGet and similar), whose upstream registries are reachable too. JDK and toolchain managers (SDKMAN, Adoptium, rustup) and Playwright browser downloads work as well. Installs persist in this sandbox across sessions of this project, so mention anything the project's own setup docs or scripts should also install. If something you need is blocked, see the note on network access.

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
    pypi.org "*.python.org" "*.pythonhosted.org" bootstrap.pypa.io "*.astral.sh"    # uv: installer, releases.astral.sh
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

_MSB_AGENT_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/msb-agent"

# ----------------------------------------------------------------
# Print the hosts listed in FILE (or, with -s, in the string STRING),
# one per line, sorted and de-duplicated. Entries are separated by
# whitespace or commas; "#" starts a comment. Each entry must be a
# hostname or "*.suffix" with at least two labels, so a file can't
# inject other msb rule syntax (groups such as "any", IPs, ports).
# Invalid entries are reported on stderr and skipped.
# ----------------------------------------------------------------
_msb_agent_parse_hosts() {
    local source text entry
    local re='^(\*\.)?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'

    if [[ "$1" == -s ]]; then
        text="$2"
        source="MSB_AGENT_NET_ALLOW"
    else
        [[ -r "$1" ]] || return 0
        text="$(< "$1")"
        source="$1"
    fi

    printf '%s\n' "$text" \
    | sed 's/#.*//' \
    | tr ', \t' '\n\n\n' \
    | sed '/^$/d' \
    | while IFS= read -r entry; do
        # The last label must not be numeric: no IP addresses.
        if [[ "$entry" =~ $re && ! "${entry##*.}" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$entry" | tr 'A-Z' 'a-z'
        else
            echo "warning: ignoring invalid host '$entry' in $source" >&2
        fi
    done \
    | sort -u
}

_msb_agent_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

# ----------------------------------------------------------------
# Print the hosts from the repo's .msb-agent/allowed-hosts if the user
# has approved them. The file is committed and can be changed by
# anyone who can change the repo (including the agent, via git), so
# its host list is approved on the host, direnv-style: approvals are
# stored by content hash, and any change asks again. Without a
# terminal, unapproved hosts are left out.
# ----------------------------------------------------------------
_msb_agent_repo_hosts() {
    local file="$1/.msb-agent/allowed-hosts"
    local hosts hash approved answer

    hosts="$(_msb_agent_parse_hosts "$file")"
    [[ -n "$hosts" ]] || return 0

    hash="$(printf '%s\n' "$hosts" | _msb_agent_sha256)"
    approved="$_MSB_AGENT_CONFIG_DIR/approved-hosts/$hash"

    if [[ -f "$approved" ]]; then
        printf '%s\n' "$hosts"
        return 0
    fi

    {
        echo "This repository's .msb-agent/allowed-hosts asks for network access to:"
        printf '%s\n' "$hosts" | sed 's/^/    /'
    } >&2

    if [[ ! -t 0 ]]; then
        echo "Not approved (no terminal to ask); using the default allowlist only." >&2
        return 0
    fi

    read -r -p "Allow the sandbox to reach these hosts? [y/N] " answer || answer=""

    if [[ ! "$answer" =~ ^[Yy] ]]; then
        echo "Not approved; using the default allowlist only." >&2
        return 0
    fi

    mkdir -p "$(dirname "$approved")" \
    && { echo "# approved for $1 on $(date)"; printf '%s\n' "$hosts"; } > "$approved" \
    || echo "warning: could not record approval in $approved" >&2

    printf '%s\n' "$hosts"
}

# ----------------------------------------------------------------
# Print label KEY of sandbox NAME, or DEFAULT if it has none (it was
# created before the label existed). Prints nothing if it can't be
# determined (no jq, unknown format).
#
# Usage: _msb_agent_label NAME KEY DEFAULT
# ----------------------------------------------------------------
_msb_agent_label() {
    command -v jq >/dev/null 2>&1 || return 0

    msb inspect "$1" --format json 2>/dev/null \
    | jq -r --arg key "$2" --arg default "$3" '
        ( [.. | objects | select(has($key)) | .[$key]]
          + [.. | strings | select(startswith($key + "="))
                | ltrimstr($key + "=")] )[0]
        // $default' 2>/dev/null
}

# ----------------------------------------------------------------
# .env files created by seeding (see msb_agent_run) are recorded by
# inode in a host-only state directory the sandbox can't reach, so a
# later sandbox for the same checkout can tell the agent's own .env
# from a real one. Anything else, including a .env the agent replaced
# rather than edited, counts as real (fail closed).
# ----------------------------------------------------------------
_msb_agent_env_marker() {
    printf '%s/seeded-env/%s' \
        "${XDG_STATE_HOME:-$HOME/.local/state}/msb-agent" \
        "$(printf '%s' "$1" | _msb_agent_sha256)"
}

_msb_agent_inode() {
    ls -di "$1" 2>/dev/null | awk '{print $1}'
}

# True if DIR/.env exists and was not created by seeding.
_msb_agent_has_real_env() {
    local env="$1/.env" marker

    [[ -e "$env" || -L "$env" ]] || return 1
    [[ -L "$env" ]] && return 0

    marker="$(_msb_agent_env_marker "$1")"
    [[ -f "$marker" && "$(< "$marker")" == "$(_msb_agent_inode "$env")" ]] && return 1

    return 0
}

# Create DIR/.env from the first existing SEED file and record it.
# Usage: _msb_agent_seed_env DIR SEED...
_msb_agent_seed_env() {
    local dir="$1" seed marker
    shift

    [[ -e "$dir/.env" || -L "$dir/.env" ]] && return 0

    for seed in "$@"; do
        [[ -f "$seed" ]] || continue

        ( umask 077 && cp "$seed" "$dir/.env" ) || return 1

        marker="$(_msb_agent_env_marker "$dir")"
        mkdir -p "$(dirname "$marker")" \
        && _msb_agent_inode "$dir/.env" > "$marker" \
        || return 1

        echo "Created .env from $seed"
        return 0
    done
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

# ----------------------------------------------------------------
# Prepare .env for a sandbox about to be created, per env_mode (see
# msb_agent_run): seed a writable .env, or make sure .env.agent exists
# and set env_mount_spec to mount it read-only over the real one.
# ----------------------------------------------------------------
_msb_agent_prepare_env() {
    env_mount_spec=""

    if [[ "$env_mode" == writable ]]; then
        _msb_agent_seed_env "$dir" "${env_seeds[@]}"
        return
    fi

    if [[ ! -e "$dir/.env.agent" ]]; then
        touch "$dir/.env.agent" || return 1
        echo "Created empty .env.agent"
    fi

    env_mount_spec="$dir/.env.agent:$guest_dir/.env:ro,uid=$host_uid,gid=$host_gid,host-perms=private"
}

# ----------------------------------------------------------------
# Print the deepest directory that contains both absolute paths.
# ----------------------------------------------------------------
_msb_agent_common_dir() {
    local common="" i
    local -a pa pb

    IFS=/ read -ra pa <<< "$1"
    IFS=/ read -ra pb <<< "$2"

    for (( i = 1; i < ${#pa[@]} && i < ${#pb[@]}; i++ )); do
        [[ "${pa[i]}" == "${pb[i]}" ]] || break
        common+="/${pa[i]}"
    done

    printf '%s' "${common:-/}"
}

msb_agent_run() {

    local agent="$1"
    shift

    local tool="${agent}-msb"

    local dir name
    # Where the checkout appears in the sandbox, and (when it is a
    # submodule, whose git data lives in the superproject) where its git
    # directory is mounted; see "Submodule layout" below.
    local guest_dir="/workspace" guest_gitdir=""
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
    #       Let the agent capture a single host (macOS) window on
    #       demand with the msb-screenshot guest command.
    #       WINDOW is a window id or name substring; if omitted, the
    #       user is asked to pick from a list of open windows.
    #
    #   --gitlab-issue ISSUE
    #       Give the agent GitLab tools bound to this one issue
    #       (32, group/project#32 or an issue URL): read/comment on
    #       the issue, and submit and comment on merge requests. The
    #       work may span the checkout and its submodules, all on one
    #       branch. The host does the work (see gitlab_bridge.py), so
    #       the sandbox gets no credentials.
    #
    #   --branch NAME
    #       The branch to use in every repo (default: the checkout's
    #       feature branch if it is on one, else <issue>-<title>).
    #       It is created up front where needed and removed again if
    #       unused. Needs --gitlab-issue.
    #
    #   --gitlab-skip-unprepared
    #       Without a terminal, skip repos that need a decision
    #       instead of aborting.
    # ------------------------------------------------------------

    local screenshots=0
    local screenshot_window="${MSB_AGENT_SCREENSHOT_WINDOW:-${PI_MSB_SCREENSHOT_WINDOW:-}}"
    local screenshot_min_interval="${MSB_AGENT_SCREENSHOT_MIN_INTERVAL:-1}"
    local screenshot_max_size="${MSB_AGENT_SCREENSHOT_MAX_SIZE:-${PI_MSB_SCREENSHOT_MAX_SIZE:-1600}}"
    local gitlab_issue="${MSB_AGENT_GITLAB_ISSUE:-}" gitlab_branch=""
    local gitlab_skip_unprepared="${MSB_AGENT_GITLAB_SKIP_UNPREPARED:-0}"
    local gitlab_state="" gitlab_pid=""
    local mcp_file="" mcp_extra="{}"
    local -a passthrough_args gitlab_args

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
            --gitlab-issue=*)
                gitlab_issue="${1#*=}"
                shift
                ;;
            --branch=*)
                gitlab_branch="${1#*=}"
                shift
                ;;
            --branch)
                if (( $# < 2 )); then
                    echo "error: --branch needs a branch name" >&2
                    return 1
                fi
                gitlab_branch="$2"
                shift 2
                ;;
            --gitlab-skip-unprepared)
                gitlab_skip_unprepared=1
                shift
                ;;
            --gitlab-issue)
                if (( $# < 2 )); then
                    echo "error: --gitlab-issue needs an issue (32, group/project#32 or a URL)" >&2
                    return 1
                fi
                gitlab_issue="$2"
                shift 2
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
    #
    # The allowlist is the defaults plus hosts from:
    #   ~/.config/msb-agent/allowed-hosts   personal, always trusted
    #   MSB_AGENT_NET_ALLOW="a.com,*.b.com"
    #   <repo>/.msb-agent/allowed-hosts     committed; needs approval
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
            local h repo_hosts

            repo_hosts="$(_msb_agent_repo_hosts "$dir")"

            net_hosts="$(
                {
                    printf '%s\n' "${_MSB_AGENT_NET_ALLOW_DEFAULT[@]}" "${net_allow[@]}"
                    _msb_agent_parse_hosts "$_MSB_AGENT_CONFIG_DIR/allowed-hosts"
                    _msb_agent_parse_hosts -s "${MSB_AGENT_NET_ALLOW:-}"
                    printf '%s\n' "$repo_hosts"
                } | sed '/^$/d' | sort -u
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

        # ------------------------------------------------------------
        # Submodule layout. A submodule's .git is a pointer file with a
        # path relative to the superproject, where the git data lives
        # (.git/modules/..., or under .git/worktrees/... for a linked
        # worktree), so mounting only the submodule at /workspace leaves
        # the pointer, and those of any nested submodules, dangling.
        # Those pointers never climb above the nearest directory
        # containing both the submodule and its git data, so mount just
        # the two, keeping their positions below that directory:
        #
        #   <ancestor>/libs/a                  -> /workspace/libs/a
        #   <ancestor>/.git/modules/libs/a     -> /workspace/.git/modules/libs/a
        #
        # and run the agent in /workspace/libs/a. Nothing else from the
        # superproject is visible.
        # ------------------------------------------------------------

        if (( ! linked_worktree )) && \
           [[ -n "$(git -C "$dir" rev-parse --show-superproject-working-tree 2>/dev/null)" ]]
        then
            local real_git_dir ancestor rel_dir rel_git
            real_git_dir="$(cd "$git_dir" && pwd -P)" || return 1

            if [[ "$real_git_dir" != "$dir"/* ]]; then
                ancestor="$(_msb_agent_common_dir "$dir" "$real_git_dir")"
                rel_dir="${dir#"$ancestor"}"
                rel_git="${real_git_dir#"$ancestor"}"

                guest_dir="/workspace${rel_dir%/}"
                guest_gitdir="/workspace${rel_git%/}"
                git_dir="$real_git_dir"

                echo "Submodule: mounting only $dir and its git data ($real_git_dir)"
                echo "           under /workspace; working in $guest_dir"
            fi
        fi
    fi

    # ------------------------------------------------------------
    # GitLab: before the (slow) sandbox setup, check the config, token
    # and issue, work out the repos and create the branch in each, and
    # ask about any repo that needs a decision (this needs the
    # terminal, so it runs in the foreground). However this function
    # returns, the bridge is stopped and unused branches are tidied.
    # ------------------------------------------------------------

    if [[ -n "$gitlab_branch" && -z "$gitlab_issue" ]]; then
        echo "error: --branch requires --gitlab-issue" >&2
        return 1
    fi

    if [[ -n "$gitlab_issue" ]]; then
        command -v python3 >/dev/null 2>&1 || {
            echo "error: --gitlab-issue requires python3 on the host" >&2
            return 1
        }
        [[ -f "$_MSB_AGENT_LIB_DIR/gitlab_bridge.py" ]] || {
            echo "error: $_MSB_AGENT_LIB_DIR/gitlab_bridge.py not found" >&2
            return 1
        }
        [[ -n "$git_dir" ]] || {
            echo "error: --gitlab-issue requires a git repository" >&2
            return 1
        }
        if ! declare -F "${agent}_msb_mcp_config" >/dev/null; then
            echo "error: $agent does not support --gitlab-issue" >&2
            return 1
        fi

        gitlab_state="${XDG_STATE_HOME:-$HOME/.local/state}/msb-agent/gitlab/session-$$-$RANDOM.json"
        mkdir -p "$(dirname "$gitlab_state")" || return 1

        trap '_msb_agent_gitlab_stop; trap - RETURN' RETURN

        gitlab_args=(
            --repo "$dir" --primary "$primary"
            --git-dir "$git_dir" --git-common "$git_common"
            --state "$gitlab_state"
        )
        [[ -n "$gitlab_branch" ]] && gitlab_args+=( --branch "$gitlab_branch" )
        [[ "$gitlab_skip_unprepared" == 1 ]] && gitlab_args+=( --skip-unprepared )

        # stdout is the normalised issue ("project#iid"); the prompts
        # and progress go to the terminal on stderr.
        gitlab_issue="$(
            python3 "$_MSB_AGENT_LIB_DIR/gitlab_bridge.py" prepare \
                --issue "$gitlab_issue" "${gitlab_args[@]}"
        )" || return 1
    fi

    # ------------------------------------------------------------
    # .env handling. Decided when a sandbox is created (mounts can't
    # change later) and recorded in the msb-agent-env label:
    #
    #   writable  No real .env in the checkout (e.g. a linked worktree):
    #             .env is seeded from .env.agent (this checkout's, else
    #             the primary checkout's) and the agent may edit it.
    #   squashed  A real .env exists: .env.agent is mounted read-only
    #             over it. The real file is still inside the mounted
    #             checkout, where root in the guest can reach it.
    # ------------------------------------------------------------

    local env_mode=writable
    local -a env_seeds=( "$dir/.env.agent" )
    local env_mount_spec=""

    [[ -n "$primary" ]] && env_seeds+=( "$primary/.env.agent" )

    if _msb_agent_has_real_env "$dir"; then
        env_mode=squashed
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

        local have_label have_layout
        have_label="$(_msb_agent_label "$name" msb-agent-net open)"

        # Mounts can't change later, so a sandbox created for a different
        # layout (a submodule launched normally, or the reverse) is wrong
        # for this launch. Older sandboxes have no label: /workspace.
        have_layout="$(_msb_agent_label "$name" msb-agent-layout /workspace)"
        if [[ -n "$have_layout" && "$have_layout" != "$guest_dir" ]]; then
            {
                echo "error: sandbox $name was created with the checkout at $have_layout,"
                echo "       but this launch needs it at $guest_dir. msb can't change mounts"
                echo "       in place; remove the sandbox (installed packages are lost):"
                echo "           msb rm $name"
            } >&2
            return 1
        fi

        # Sandboxes from before the label always squashed .env.
        env_mode="$(_msb_agent_label "$name" msb-agent-env squashed)"
        env_mode="${env_mode:-squashed}"

        if [[ "$env_mode" == squashed && ! -e "$dir/.env.agent" ]]; then
            touch "$dir/.env.agent" || return 1
            echo "Created empty .env.agent"
        fi

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

        _msb_agent_prepare_env || return 1

        local -a restore_mounts=()
        if [[ -d "$dir/.msb-agent" ]]; then
            restore_mounts=(
                -v "$dir/.msb-agent:$guest_dir/.msb-agent:ro,uid=$host_uid,gid=$host_gid,host-perms=private"
            )
        fi

        if ! msb snap restore \
            "$snap" \
            --name "$name" \
            --cpus 4 \
            --memory 8G \
            -v "$dir:$guest_dir:uid=$host_uid,gid=$host_gid,host-perms=private" \
            -v "$git_common:$git_common:uid=$host_uid,gid=$host_gid,host-perms=private" \
            ${env_mount_spec:+-v "$env_mount_spec"} \
            "${restore_mounts[@]}" \
            "${net_restore_args[@]}"
        then
            rm -rf "$tmpdir"
            return 1
        fi

        rm -rf "$tmpdir"

        msb modify "$name" \
            --label "msb-agent-net=$net_label" \
            --label "msb-agent-env=$env_mode" \
            --label "msb-agent-layout=$guest_dir" \
            >/dev/null \
        || echo "warning: could not label sandbox $name" >&2

    else

        echo "Creating new sandbox: $name"

        create_mounts=(
            --mount-dir
            "$dir:$guest_dir:uid=$host_uid,gid=$host_gid,host-perms=private"
        )

        if [[ -n "$guest_gitdir" ]]; then
            create_mounts+=(
                --mount-dir
                "$git_dir:$guest_gitdir:uid=$host_uid,gid=$host_gid,host-perms=private"
            )
        fi

        if (( linked_worktree )); then
            echo "Git common dir: $git_common"

            create_mounts+=(
                --mount-dir
                "$git_common:$git_common:uid=$host_uid,gid=$host_gid,host-perms=private"
            )
        fi

        _msb_agent_prepare_env || return 1

        if [[ -n "$env_mount_spec" ]]; then
            create_mounts+=( --mount-file "$env_mount_spec" )
        fi

        if [[ -d "$dir/.msb-agent" ]]; then
            create_mounts+=(
                --mount-dir
                "$dir/.msb-agent:$guest_dir/.msb-agent:ro,uid=$host_uid,gid=$host_gid,host-perms=private"
            )
        fi

        msb create \
            --name "$name" \
            --cpus 4 \
            --memory 8G \
            --root-disk 20G \
            --workdir "$guest_dir" \
            "${net_create_args[@]}" \
            --label "msb-agent-net=$net_label" \
            --label "msb-agent-env=$env_mode" \
            --label "msb-agent-layout=$guest_dir" \
            --trust-host-cas \
            "${secret_args[@]}" \
            "${create_mounts[@]}" \
            node:22-bookworm \
        || return 1
    fi

    if _msb_agent_has_real_env "$dir"; then
        if [[ "$env_mode" == squashed ]]; then
            {
                echo "warning: $dir/.env exists. The agent sees .env.agent (read-only)"
                echo "         at $guest_dir/.env instead, but the real file is still in the"
                echo "         mounted checkout, where root in the sandbox (the agent has sudo)"
                echo "         can reach it. To keep it out of reach, run agents in a linked"
                echo "         worktree (git worktree add), which gets its own writable .env"
                echo "         seeded from .env.agent."
            } >&2
        else
            {
                echo "warning: $dir/.env was not created by this tool, and this sandbox"
                echo "         doesn't hide .env: the agent can read it. Remove it, or recreate"
                echo "         the sandbox (msb rm $name) to mount .env.agent over it."
            } >&2
        fi
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
    # Wait for outbound networking. For a few seconds after msb creates
    # or restarts a sandbox, connections to allowlisted hosts can be
    # refused even though DNS works, which breaks the installs below.
    # ------------------------------------------------------------

    local probe_url="${MSB_AGENT_NET_PROBE:-http://deb.debian.org/}"

    msb exec -q "$name" -- \
        bash -c '
            for i in $(seq 1 30); do
                curl -fsS -o /dev/null --max-time 5 "$1" 2>/dev/null && exit 0
                sleep 1
            done
            exit 1
        ' \
        msb-agent-net-wait \
        "$probe_url" \
    || echo "warning: sandbox can't reach $probe_url after 30s; continuing anyway" >&2

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

                # --error-on=any: fail (and retry) on fetch errors,
                # which apt otherwise only warns about.
                for attempt in 1 2 3; do
                    apt-get update --error-on=any && break
                    (( attempt < 3 )) || exit 1
                    sleep 3
                done

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
    # Install guest helpers:
    #
    #   msb-trust-java  Make Java trust the TLS interception CA (msb
    #                   already covers the system store, curl, Python,
    #                   Node etc.). Re-run after every apt install so
    #                   JDKs installed by the agent are covered too.
    #   msb-screenshot  Request a screenshot from the host (see
    #                   --with-screenshots).
    #   msb-gitlab-mcp  MCP server for the host's GitLab bridge (see
    #                   --gitlab-issue).
    # ------------------------------------------------------------

    msb exec -q "$name" -- \
        bash -c '
            set -euo pipefail

            printf "%s" "$1" > /usr/local/bin/msb-trust-java
            printf "%s" "$2" > /usr/local/bin/msb-screenshot
            printf "%s" "$3" > /usr/local/bin/msb-gitlab-mcp
            chmod 0755 /usr/local/bin/msb-trust-java /usr/local/bin/msb-screenshot \
                /usr/local/bin/msb-gitlab-mcp

            printf "%s\n" \
                "DPkg::Post-Invoke { \"/usr/local/bin/msb-trust-java -q || true\"; };" \
                > /etc/apt/apt.conf.d/99msb-trust-java

            /usr/local/bin/msb-trust-java
        ' \
        msb-agent-helpers-setup \
        "$(< "$_MSB_AGENT_LIB_DIR/msb-trust-java.sh")" \
        "$(< "$_MSB_AGENT_LIB_DIR/msb-screenshot.sh")" \
        "$(< "$_MSB_AGENT_LIB_DIR/msb-gitlab-mcp.js")" \
    || echo "warning: could not install guest helpers (Java CA trust, screenshots, GitLab)" >&2

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
        -- test -w "$guest_dir"
    then
        echo "error: $guest_dir is not writable as $guest_user" >&2
        echo "       the sandbox mounts may have been created by an older $tool version" >&2
        return 1
    fi

    # ------------------------------------------------------------
    # Screenshots: a host helper watches /workspace/.<tool>/ (via the
    # mounted workspace) for requests from msb-screenshot and answers
    # each with a fresh capture of the approved window.
    # ------------------------------------------------------------

    local screenshot_pid=""

    if (( screenshots )); then
        local shot_dir="$dir/.$tool"
        local shot_log="$shot_dir/screenshots.log"

        mkdir -p "$shot_dir" || return 1
        # Keep the capture directory out of git.
        [[ -f "$shot_dir/.gitignore" ]] || printf '*\n' > "$shot_dir/.gitignore"
        rm -rf "$shot_dir/screenshot.png" "$shot_dir/screenshot-requests"

        echo "Starting on-demand screenshot helper for window: $screenshot_window"

        uv run --quiet --no-project --with pyobjc-framework-Quartz \
            python3 "$_MSB_AGENT_LIB_DIR/capture_screenshots.py" \
            --dir "$shot_dir" \
            --min-interval "$screenshot_min_interval" \
            --max-size "$screenshot_max_size" \
            --parent-pid "$$" \
            "$screenshot_window" \
            > "$shot_log" 2>&1 &
        screenshot_pid=$!

        # Wait for its test capture so failures (e.g. missing Screen
        # Recording permission) are visible now.
        local i
        for (( i = 0; i < 100; i++ )); do
            grep -q '^Ready:' "$shot_log" 2>/dev/null && break
            kill -0 "$screenshot_pid" 2>/dev/null || break
            sleep 0.2
        done

        if ! grep -q '^Ready:' "$shot_log" 2>/dev/null; then
            echo "error: screenshot helper failed to start; see $shot_log" >&2
            echo "       (if window titles are missing from the list, the terminal needs" >&2
            echo "        Screen Recording permission: System Settings -> Privacy & Security)" >&2
            sed 's/^/       /' "$shot_log" >&2
            kill "$screenshot_pid" 2>/dev/null
            return 1
        fi

        echo "Screenshot helper started (PID: $screenshot_pid, log: $shot_log)"

        agent_env_args+=( --env "MSB_SCREENSHOT_DIR=$guest_dir/.$tool" )

        extra_system_prompt+=$'\n\n'"You can see the user's application window ($screenshot_window), and only that window: run \`msb-screenshot\`, which asks the host for a fresh capture and prints the path of the PNG, then view that file with your read tool. Use it to check UI changes; after a change, allow time for the app to reload before capturing. If it reports the window is not on screen, ask the user to show it."
    fi

    # ------------------------------------------------------------
    # GitLab: a host bridge answers requests from the msb-gitlab-mcp
    # guest server, which is registered with the agent. Without
    # --gitlab-issue any registration left by a previous session is
    # removed.
    # ------------------------------------------------------------

    if declare -F "${agent}_msb_mcp_config" >/dev/null; then
        "${agent}_msb_mcp_config"
    fi

    if [[ -n "$gitlab_issue" ]]; then
        local gl_dir="$dir/.$tool"
        local gl_log="$gl_dir/gitlab.log"

        mkdir -p "$gl_dir" || return 1
        [[ -f "$gl_dir/.gitignore" ]] || printf '*\n' > "$gl_dir/.gitignore"
        rm -rf "$gl_dir/gitlab-requests"

        echo "Starting GitLab bridge for issue $gitlab_issue"

        python3 "$_MSB_AGENT_LIB_DIR/gitlab_bridge.py" serve \
            --state "$gitlab_state" \
            --dir "$gl_dir/gitlab-requests" \
            --parent-pid "$$" \
            > "$gl_log" 2>&1 &
        gitlab_pid=$!

        local i
        for (( i = 0; i < 100; i++ )); do
            grep -q '^Ready:' "$gl_log" 2>/dev/null && break
            kill -0 "$gitlab_pid" 2>/dev/null || break
            sleep 0.2
        done

        if ! grep -q '^Ready:' "$gl_log" 2>/dev/null; then
            echo "error: GitLab bridge failed to start; see $gl_log" >&2
            sed 's/^/       /' "$gl_log" >&2
            [[ -n "$screenshot_pid" ]] && kill "$screenshot_pid" 2>/dev/null
            return 1
        fi

        echo "GitLab bridge started (PID: $gitlab_pid, log: $gl_log)"

        extra_system_prompt+=$'\n\n'"$(< "$gitlab_state.briefing")"
    fi

    _msb_agent_mcp_register "$gitlab_issue" || {
        [[ -n "$screenshot_pid" ]] && kill "$screenshot_pid" 2>/dev/null
        return 1
    }

    if [[ -n "$guest_gitdir" ]]; then
        extra_system_prompt+=$'\n\n'"The project you were started in is a git submodule, and you are working in $guest_dir. Only this submodule's working tree and its own git data are present under /workspace; the rest of the superproject is deliberately not available, so keep your changes within this directory."
    fi

    if [[ "$env_mode" == squashed ]]; then
        extra_system_prompt+=$'\n\n'"$guest_dir/.env is a read-only stand-in for the project's real .env (the host's .env.agent). If it needs changes, tell the user what to change rather than working around it."
    else
        extra_system_prompt+=$'\n\n'"$guest_dir/.env (if present) is this sandbox's own copy, seeded from .env.agent; you may edit it. Edit it in place rather than replacing it with a new file."
    fi

    if [[ "$net_mode" == allowlist ]] && (( net_policy_current )); then
        extra_system_prompt+=$'\n\n'"Outbound network access is restricted to these hosts (\"*.x\" includes x and its subdomains): $(printf '%s\n' "$net_hosts" | paste -sd, - | sed 's/,/, /g'). Connections to anything else are refused. GitHub has no credentials here, so it is read-only (clone, fetch, downloads). If a task needs another host, do not try to work around the restriction or edit the allowlist yourself (it is read-only and changes need the user's approval): tell the user which host is needed and why, and suggest the exact line to add to .msb-agent/allowed-hosts in the repository (one host or \"*.domain\" per line). The change takes effect when the sandbox is recreated."
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
        --workdir "$guest_dir" \
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
# Stop the GitLab bridge, then let the host tidy up: remove branches the
# session created but never used, restore what was there before, and
# report anything left behind. Runs when msb_agent_run returns (it uses
# that function's gitlab_pid and gitlab_state).
# ----------------------------------------------------------------
_msb_agent_gitlab_stop() {
    if [[ -n "$gitlab_pid" ]]; then
        kill "$gitlab_pid" 2>/dev/null
        wait "$gitlab_pid" 2>/dev/null
        gitlab_pid=""
    fi

    if [[ -n "$gitlab_state" && -f "$gitlab_state" ]]; then
        python3 "$_MSB_AGENT_LIB_DIR/gitlab_bridge.py" finish --state "$gitlab_state"
    fi
}

# ----------------------------------------------------------------
# Register (ISSUE non-empty) or remove (ISSUE empty) the msb-gitlab MCP
# server in the agent's user-level MCP config in the guest. Uses
# mcp_file and mcp_extra from AGENT_msb_mcp_config; nothing to do for
# agents without it. Run as the guest user; the file is edited in
# place, keeping everything else in it.
# ----------------------------------------------------------------
_msb_agent_mcp_register() {
    local issue="$1"

    [[ -n "$mcp_file" ]] || return 0

    msb exec -q --user "$guest_user" --env "HOME=$guest_home" "$name" -- \
        node -e '
            const fs = require("fs");
            const path = require("path");
            const [file, issue, extra, dir] = process.argv.slice(1);
            const full = path.join(process.env.HOME, file);

            let cfg = {};
            try { cfg = JSON.parse(fs.readFileSync(full, "utf8")); }
            catch (e) { if (e.code !== "ENOENT") throw e; }

            const servers = cfg.mcpServers = cfg.mcpServers || {};
            if (issue) {
                servers["msb-gitlab"] = Object.assign({
                    type: "stdio",
                    command: "/usr/local/bin/msb-gitlab-mcp",
                    args: [],
                    env: { MSB_GITLAB_DIR: dir, MSB_GITLAB_ISSUE: issue },
                }, JSON.parse(extra));
            } else if (servers["msb-gitlab"]) {
                delete servers["msb-gitlab"];
            } else {
                process.exit(0);
            }

            fs.mkdirSync(path.dirname(full), { recursive: true });
            fs.writeFileSync(full, JSON.stringify(cfg, null, 2));
        ' \
        "$mcp_file" "$issue" "$mcp_extra" "$guest_dir/.$tool/gitlab-requests" \
    || {
        echo "error: could not register the GitLab MCP server in the sandbox" >&2
        return 1
    }
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
