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
