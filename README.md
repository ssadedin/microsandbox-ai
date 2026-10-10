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
pi-msb --gitlab-issue 32
```

then prompt "Work on issue 32". The agent gets five tools (MCP server
`msb-gitlab`): read the issue, comment on it, submit a merge request
(the host pushes the current branch and opens the MR, or updates the open
one), read the MR, and comment on it. None takes a ticket, project or
branch argument, so the agent can only act on the issue you named and the
branch checked out at startup. The default and protected branches are
never pushed, and there is no force push. Start the agent on a feature
branch: the launcher refuses the default branch, and the session stays bound
to the branch checked out at startup (restart it after switching branches).

The instance and token live on the host in
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
      "issue_project": "group/tracker"
    }
  }
}
```

`token_file` (mode 600), `token_env` or `token_keychain` (macOS) supply the
token, which needs the `api` and `write_repository` scopes; a project
access token with the Developer role is enough. `url` defaults to
`https://<instance name>` and `ca_file` is for internal CAs. `repos` is
optional: without an entry, the project is taken from the `origin` remote
(whose host must be a configured instance) and the issue is looked up in
the same project. It matches the checkout or, for a linked worktree, its
primary checkout.
