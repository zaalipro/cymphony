# Cymphony

> A rewrite of [openai/symphony](https://github.com/openai/symphony) that uses **Claude Code** instead of Codex as the underlying coding agent.

Cymphony turns project work into isolated, autonomous implementation runs, allowing teams to manage work instead of supervising coding agents.

## Background

Cymphony is a reimagining of the original Symphony project from OpenAI. Where Symphony was built around OpenAI's Codex agent, Cymphony leverages Anthropic's Claude Code — offering a modern, production-ready foundation for orchestrating autonomous coding agents against your issue tracker.

## Requirements

Cymphony works best in codebases that have adopted [harness engineering](https://openai.com/index/harness-engineering/). Cymphony is the next step — moving from managing coding agents to managing work that needs to get done.

## Quick Start

### Install the CLI (macOS)

```bash
brew tap zaalipro/cymphony
brew install cymphony
cymphony
```

First run triggers an interactive setup (GitHub repo URL, Linear project slug, API key).

### Run Commands

```bash
cymphony                       # Run with saved config
cymphony p frontend            # Run only the "frontend" project
cymphony s                     # Re-run setup
cymphony a                     # Add a project
cymphony l                     # List projects
cymphony v                     # Show version
cymphony h                     # Show help
```

### Run from Source

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment and run the Elixir-based Cymphony implementation from source. You can also ask your favorite coding agent to help with the setup:

> Set up Cymphony for my repository based on
> https://github.com/zaalipro/cymphony/blob/main/elixir/README.md

### Build Your Own

Tell your favorite coding agent to build Cymphony in a programming language of your choice:

> Implement Cymphony according to the following spec:
> https://github.com/zaalipro/cymphony/blob/main/SPEC.md

## Architecture

Cymphony is composed of several key layers:

- **Workflow Loader** — Reads `WORKFLOW.md` and parses YAML front matter + prompt body
- **Config Layer** — Typed getters for workflow config with environment variable indirection
- **Orchestrator** — Poll tick, in-memory runtime state, dispatch/retry/reconciliation logic
- **Workspace Manager** — Per-issue isolated workspaces with lifecycle hooks
- **Agent Runner** — Launches Claude Code via app-server protocol over stdio
- **Issue Tracker Client** — Fetches candidates, refreshes states, normalizes payloads (Linear in this version)

## Key Features

- **Poll-based dispatch** with bounded concurrency and exponential backoff retries
- **Per-issue workspaces** that persist across runs for deterministic behavior
- **In-repo workflow control** via `WORKFLOW.md` — version your agent prompt with your code
- **Tracker reconciliation** — stops runs when issues transition to terminal states
- **Observability** — structured logs with issue/session context

## Status

> [!WARNING]
> Cymphony is a low-key engineering preview for testing in trusted environments.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
