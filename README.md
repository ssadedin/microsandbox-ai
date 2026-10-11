# Microsandbox Wrappers for AI Tools

This repository provides some simple wrappers for AI tools including:

- Claude Code
- Pi

These tools are best run within sandboxes, however doing so can be
cumbersome. These scripts facilitate some niceties including:

- setup of secrets for OpenRouter, Bedrock and Anthropic
  automatically with passthrough
- add pass through of common networking requirements so that
  sandboxes can install tools, language SDKs and other
  resources
- addition of live capture screenshot tool to enable
  models to request and receive screenshots of a host
  window
- GitLab access without credentials in the sandbox: the agent gets MCP
  tools bound to one issue and the current branch, and a host process
  does the work (see below)

## Pi credentials

`pi-msb` resolves model credentials on the host, so the sandbox only ever holds
placeholders:

- **OpenRouter, OpenAI, Anthropic:** read from a host `pi` install if there is
  one (`pi auth print-api-key`). Without host pi these are skipped.
- **Amazon Bedrock:** a short-lived Bedrock API key is minted from a dedicated
  AWS profile named `pi-msb` in `~/.aws/credentials` or `~/.aws/config` (or the
  profile named by `PI_MSB_AWS_PROFILE`; `PI_MSB_AWS_REGION` defaults to
  `ap-southeast-2`). It needs `uv` on the host to sign the token. A dedicated,
  narrowly scoped profile is deliberate: the key carries that identity's
  permissions, so your admin profile is never used implicitly.

If neither works the launcher says why ("Bedrock: skipped: ..." before the
sandbox starts) and pi will ask you to log in inside the sandbox instead.

## Behind a TLS-intercepting network

If your network re-signs HTTPS with a company root (Zscaler and similar),
install that root on the host the normal way (device management, so it is in
the OS trust store). Then:

- **Inside the sandbox** this is already handled: sandboxes are created with
  `--trust-host-cas`, and the sandbox's proxy checks upstream certificates
  against the host's root store.
- **The base image pull** is done by `msb` on the host and needs the root in
  msb's own config: set `registries.ca_certs` in `~/.microsandbox/config.json`
  (see the microsandbox docs, "Configure company networking"). A cached image
  is not affected.
- **`uv` on the host** (screenshots, pi's Bedrock login) does not use the OS
  store by default; export `UV_NATIVE_TLS=1` or `SSL_CERT_FILE=<bundle>`.
- **The GitLab bridge** keeps `GIT_SSL_CAINFO`, `SSL_CERT_FILE`,
  `SSL_CERT_DIR` and the usual proxy variables (`HTTPS_PROXY`, `NO_PROXY`, ...)
  from your environment for its git calls, and your global git config is not
  read. For an intercepted GitLab host set `ca_file` on the instance (or export
  `SSL_CERT_FILE`) to a bundle containing the company root *and* the public
  roots: `ca_file` replaces the default trust, it does not add to it. On macOS:

  ```
  security find-certificate -a -p \
      /Library/Keychains/System.keychain \
      /System/Library/Keychains/SystemRootCertificates.keychain \
      > ~/.config/msb-agent/ca-bundle.pem
  ```

  An internal GitLab that the proxy does not inspect needs none of this.

## Launching inside a submodule

Running a wrapper from inside a submodule scopes the agent to that source
tree. A submodule's `.git` is a pointer into the superproject, so the sandbox
mounts just two things, keeping their positions below their nearest common
parent directory so every relative pointer (including nested submodules')
still resolves:

```
<superproject>/libs/a                -> /workspace/libs/a                  (working directory)
<superproject>/.git/modules/libs/a   -> /workspace/.git/modules/libs/a
```

The rest of the superproject is not visible. This also covers a superproject
that is a linked worktree. The layout is fixed when the sandbox is created
(recorded in the `msb-agent-layout` label), so a sandbox made for another
layout is refused with a hint to `msb rm` it.

## GitLab integration

```
claude-msb --gitlab-issue 32          # or group/project#32, or an issue URL
pi-msb --gitlab-issue 32 --branch 32-reset-cache-dump
```

then prompt "Work on issue 32". The agent gets MCP tools (server
`msb-gitlab`) to read the issue, comment on it, see where its work stands,
submit merge requests, and read and comment on them. None takes a ticket,
project or branch argument, so the agent can only act on the issue you named
and one branch name; a repo is chosen only from the list built at startup. A
host process does the work, so the sandbox holds no GitLab credentials.

### Submodules

The work can span the checkout and its (nested) submodules, all on the same
branch name, which is `--branch`, else the branch the checkout is already on,
else `<issue>-<title slug>` (`32-reset-cache-dump`). Before the sandbox
starts, the launcher creates that branch in each repo and, when the agent
ends, removes the ones that were never used and puts everything back as it
was. Only repos that end up with commits get a remote branch and a merge
request, and `gitlab_submit_merge_requests` handles all of them in one call.
Merge requests link to the issue ("Related to"), to each other, and, where
the agent reports a real functional dependency, "Requires <MR>: <reason>".

Commits that change a submodule pointer are refused: pointers are updated
after merge, not in merge requests.

How each repo is prepared at launch:

| State of the repo | What happens |
|---|---|
| on its default branch | branch from there |
| already on the session branch | continue |
| detached on the commit its parent records, project in `working_set` | fetch, check out and fast-forward the default branch, branch from it |
| detached on the commit its parent records, not in `working_set` | skipped silently |
| anything else (other branch, detached elsewhere, uncommitted changes, local default branch ahead of origin, odd git config) | you are asked: check out and pull, skip, skip and don't ask again, or abort |

Without a terminal the launcher aborts on that last case; add
`--gitlab-skip-unprepared` to skip those repos instead. The fetch uses the
group token over HTTPS, never your SSH keys or the repo's own remote
configuration.

### Configuration

Instance, token and project mapping live on the host in
`~/.config/msb-agent/gitlab.json`, which the sandbox cannot see:

```json
{
  "instances": {
    "git.example.com": {
      "url": "https://git.example.com",
      "token_file": "~/.config/msb-agent/example.token",
      "ca_file": "/path/to/ca-bundle.pem"
    }
  },
  "repos": {
    "/path/to/checkout": {
      "instance": "git.example.com",
      "project": "group/app",
      "issue_project": "group/tracker",
      "working_set": ["group/ui-*", "group/api"],
      "submodules": {"libs/odd": "group/odd-name"}
    }
  }
}
```

- `token_file` (mode 600), `token_env` or `token_keychain` (macOS) supply the
  token. It needs the `api` and `write_repository` scopes and must reach every
  project involved, so use a group access token (Developer role) or a personal
  token. `url` defaults to `https://<instance name>`; `ca_file` is a
  complete CA bundle for internal or intercepted hosts (see above). Everything is assumed to live on one instance.
- `repos` is optional and matches the checkout or, for a linked worktree, its
  primary checkout. Without an entry the project comes from the `origin` remote
  (whose host must be a configured instance) and issues are looked up in the
  same project. Submodule projects are worked out from their URLs (relative
  ones such as `../x.git` resolve against the parent's remote); `submodules`
  overrides that per path.
- `working_set` lists the projects (globs allowed) that are checked out to
  their default branch automatically when a submodule is detached, as after a
  fresh clone or in a new worktree. Without it, detached submodules are
  skipped. "Skip and don't ask again" answers are remembered in
  `~/.local/state/msb-agent/gitlab/`.

Only submodules that are initialised at launch take part. Pushes are never
forced and never target a default or protected branch.
