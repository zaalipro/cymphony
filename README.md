# Cymphony

Cymphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

> [!WARNING]
> Cymphony is a low-key engineering preview for testing in trusted environments.

## Running Cymphony

### Requirements

Cymphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Cymphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Cymphony in a programming language of your choice:

> Implement Cymphony according to the following spec:
> https://github.com/zaalipro/cymphony/blob/main/SPEC.md

### Option 2. Install the CLI (macOS)

```bash
brew tap zaalipro/cymphony
brew install cymphony
cymphony
```

First run triggers an interactive setup (GitHub repo URL, Linear project slug, API key).

```bash
cymphony                       # Run with saved config
cymphony s                     # Re-run setup
cymphony l <path>              # Override log directory
cymphony p <port>              # Enable web dashboard (e.g. p 4040)
cymphony h                     # Show help
```

### Option 3. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Cymphony implementation from source. You can also ask your favorite coding agent to
help with the setup:

> Set up Cymphony for my repository based on
> https://github.com/zaalipro/cymphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
