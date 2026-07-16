defmodule CymphonyElixir.Cymphony.ConfigTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.WorkflowGenerator
  alias CymphonyElixir.Workflow

  describe "to_schema_map/1" do
    test "builds a Schema-parseable map with generation defaults applied" do
      map = CymphonyConfig.to_schema_map(%{"linear_api_key" => "k", "linear_project_slug" => "slug"})

      assert {:ok, %Schema{} = parsed} = Schema.parse(map)
      assert parsed.tracker.kind == "linear"
      assert parsed.tracker.api_key == "k"
      assert parsed.tracker.project_slug == "slug"
      assert parsed.tracker.active_states == ["Todo", "In Progress", "Merging", "Rework"]
      assert parsed.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
      assert parsed.polling.interval_ms == 5000
      assert parsed.agent.max_concurrent_agents == 10
      assert parsed.agent.max_turns == 20
      assert parsed.claude.command == "claude"
      assert parsed.claude.output_format == "stream-json"
    end

    test "explicit values override defaults" do
      map =
        CymphonyConfig.to_schema_map(%{
          "polling_interval_ms" => 1234,
          "max_concurrent_agents" => 7,
          "workspace_root" => "/custom/root"
        })

      assert map["polling"]["interval_ms"] == 1234
      assert map["agent"]["max_concurrent_agents"] == 7
      assert map["workspace"]["root"] == "/custom/root"
    end

    test "provider list sets providers + head; single provider sets provider; none omits both" do
      list_map = CymphonyConfig.to_schema_map(%{"providers" => ["cv1", "cz2"]})
      assert list_map["claude"]["providers"] == ["cv1", "cz2"]
      assert list_map["claude"]["provider"] == "cv1"

      single_map = CymphonyConfig.to_schema_map(%{"provider" => "ck1"})
      assert single_map["claude"]["provider"] == "ck1"
      refute Map.has_key?(single_map["claude"], "providers")

      none_map = CymphonyConfig.to_schema_map(%{})
      refute Map.has_key?(none_map["claude"], "provider")
      refute Map.has_key?(none_map["claude"], "providers")
    end

    test "github_repo_url adds an after_create clone hook; absence omits hooks" do
      with_repo = CymphonyConfig.to_schema_map(%{"github_repo_url" => "git@github.com:me/repo.git"})
      assert with_repo["hooks"]["after_create"] =~ "git clone --depth 1 git@github.com:me/repo.git"

      refute Map.has_key?(CymphonyConfig.to_schema_map(%{}), "hooks")
    end
  end

  describe "to_schema_map/1 agent shape" do
    test "maps agent/model/effort project keys and routes providers to the active kind section" do
      config = %{
        "name" => "P",
        "agent" => "codex",
        "model" => "gpt-5.2-codex",
        "effort" => "high",
        "providers" => ["oa1", "oa2"]
      }

      schema_map = CymphonyConfig.to_schema_map(config)

      assert schema_map["agent"]["kind"] == "codex"
      assert schema_map["agent"]["model"] == "gpt-5.2-codex"
      assert schema_map["agent"]["effort"] == "high"
      assert schema_map["codex"]["providers"] == ["oa1", "oa2"]
      assert schema_map["codex"]["provider"] == "oa1"
      refute Map.has_key?(schema_map["claude"], "providers")
      refute Map.has_key?(schema_map["claude"], "approval_policy")
    end

    test "defaults to claude kind and routes providers to claude section" do
      schema_map = CymphonyConfig.to_schema_map(%{"provider" => "cz"})
      assert schema_map["agent"]["kind"] == "claude"
      assert schema_map["claude"]["provider"] == "cz"
      assert schema_map["claude"]["command"] == "claude"
      assert schema_map["codex"]["command"] == "codex"
      refute Map.has_key?(schema_map["codex"], "provider")
    end

    test "unknown agent kind falls back to claude" do
      schema_map = CymphonyConfig.to_schema_map(%{"agent" => "gemini"})
      assert schema_map["agent"]["kind"] == "claude"
    end
  end

  describe "generated WORKFLOW.md front matter round-trips safely" do
    test "values with YAML metacharacters survive generation and parsing" do
      # The old hand-built-YAML path would corrupt these (`:`, `#`, quotes);
      # JSON front matter round-trips them losslessly.
      config = %{
        "linear_api_key" => "lin_api_3:foo#bar \"quoted\"",
        "linear_project_slug" => "team/sub: project # hash",
        "workspace_root" => "/tmp/weird: path #1",
        "model" => "model: 'single' \"double\" #tag"
      }

      {:ok, path} = WorkflowGenerator.write_temp(config)
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{config: parsed_map}} = Workflow.load(path)
      assert parsed_map["tracker"]["api_key"] == "lin_api_3:foo#bar \"quoted\""
      assert parsed_map["tracker"]["project_slug"] == "team/sub: project # hash"
      assert parsed_map["workspace"]["root"] == "/tmp/weird: path #1"
      assert parsed_map["agent"]["model"] == "model: 'single' \"double\" #tag"

      assert {:ok, %Schema{}} = Schema.parse(parsed_map)
    end
  end
end
