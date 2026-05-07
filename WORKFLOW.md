---
# Default WORKFLOW.md used only for `mix test` / running cymphony from this repo
# during development. In production, cymphony reads ~/.cymphony/config.json and
# generates a per-project WORKFLOW.md at runtime — this file is NOT consulted.
# Do NOT add personal project info here (Linear slugs, repo URLs, API keys).
tracker:
  kind: linear
  project_slug: example-00000000
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: ~/.cymphony/workspaces
agent:
  max_concurrent_agents: 10
  max_turns: 20
claude:
  command: claude
  output_format: stream-json
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---


