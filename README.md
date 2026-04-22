# Cymphony

> A rewrite of [openai/symphony](https://github.com/openai/symphony) that uses **Claude Code** instead of Codex as the underlying coding agent.

Cymphony turns project work into isolated, autonomous implementation runs, allowing teams to manage work instead of supervising coding agents.

## Background

Cymphony is a reimagining of the original Cymphony project from OpenAI. Where Cymphony was built around OpenAI's Codex agent, Cymphony leverages Anthropic's Claude Code — offering a modern, production-ready foundation for orchestrating autonomous coding agents against your issue tracker.

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

### Install the CLI (Ubuntu / Debian)

#### Prerequisites

Cymphony requires the `claude` CLI from Anthropic. Install it first if you haven't already:

```bash
# Via npm (requires Node.js 18+)
npm install -g @anthropic-ai/claude-code

# Or follow the latest instructions at:
# https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview
```

#### Install

Download the latest `.deb` from [GitHub Releases](https://github.com/zaalipro/cymphony/releases) and install it:

```bash
# Download the latest release (amd64 only)
wget https://github.com/zaalipro/cymphony/releases/download/v0.4.2/cymphony_0.4.2_amd64.deb

# Install
sudo dpkg -i cymphony_0.4.2_amd64.deb

# Run setup
cymphony
```

First run triggers an interactive setup (GitHub repo URL, Linear project slug, API key).

#### Upgrade

```bash
wget https://github.com/zaalipro/cymphony/releases/download/v0.4.2/cymphony_0.4.2_amd64.deb
sudo dpkg -i cymphony_0.4.2_amd64.deb
```

#### Uninstall

```bash
sudo dpkg -r cymphony
```

> **Note:** The `.deb` bundles the Erlang VM, so no separate Erlang/Elixir installation is required.

### Run Commands

```bash
cymphony                       # Run with saved config
cymphony p frontend            # Run only the "frontend" project
cymphony c cz                  # Run with a different Claude provider (e.g. cz, ck, cm)
cymphony s                     # Re-run setup
cymphony a                     # Add a project
cymphony l                     # List projects
cymphony v                     # Show version
cymphony h                     # Show help
```

### Provider Configuration

Cymphony supports **providers** — named environment variable sets that let you switch between Claude backends (e.g., Anthropic, Kimi, OpenRouter) without shell functions.

Providers are stored in `~/.cymphony/config.json` under the top-level `providers` key. Each provider is a name mapped to a set of environment variables that Cymphony injects when spawning Claude Code.

**Example `config.json`:**

```json
{
  "projects": [
    {
      "name": "myproject",
      "github_repo_url": "git@github.com:your-org/repo.git",
      "linear_project_slug": "yourteam-ab12cd34ef56",
      "linear_api_key": "lin_api_...",
      "claude_command": "claude",
      "provider": "cz"
    }
  ],
  "providers": {
    "cz": {
      "ANTHROPIC_BASE_URL": "https://api.z.ai/coding/v4",
      "ANTHROPIC_API_KEY": "sk-zai-...",
      "ANTHROPIC_MODEL": "glm5-.1",
      "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
    },
    "ck": {
      "ANTHROPIC_BASE_URL": "https://api.kimi.com/coding",
      "ANTHROPIC_API_KEY": "sk-kimi-...",
      "ANTHROPIC_MODEL": "kimi-k2.6"
    }
  }
}
```

- Set `provider` on a project to use that provider by default.
- Override per-run with `cymphony c <provider>` or `cymphony --provider <name>`.
- If a provider is not found, `cymphony c <cmd>` falls back to treating it as a raw Claude command override.

Providers are configured interactively during `cymphony s` setup, or you can edit `config.json` directly.

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
