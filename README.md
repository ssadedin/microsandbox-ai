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
      "ca_file": "/path/to/internal-ca.pem"
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
  token. `url` defaults to `https://<instance name>`; `ca_file` is for
  internal CAs. Everything is assumed to live on one instance.
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
