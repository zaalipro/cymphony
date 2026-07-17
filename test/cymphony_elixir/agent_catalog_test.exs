defmodule CymphonyElixir.AgentCatalogTest do
  # async: false — mutates the :codex_catalog_fetcher app env + persistent_term cache.
  use ExUnit.Case, async: false

  alias CymphonyElixir.AgentCatalog

  @catalog_json """
  {"models": [
    {"slug": "gpt-9-frontier", "display_name": "GPT-9 Frontier", "description": "Latest frontier model.",
     "default_reasoning_level": "low",
     "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "ultra"}],
     "visibility": "list", "priority": 1},
    {"slug": "gpt-9-mini", "display_name": "GPT-9 Mini", "description": "Small and fast.",
     "default_reasoning_level": "medium",
     "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}],
     "visibility": "list", "priority": 5},
    {"slug": "internal-review", "display_name": "Internal", "description": "Hidden model.",
     "default_reasoning_level": "medium",
     "supported_reasoning_levels": [{"effort": "medium"}],
     "visibility": "hide", "priority": 9}
  ]}
  """

  setup do
    AgentCatalog.clear_cache()

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :codex_catalog_fetcher)
      AgentCatalog.clear_cache()
    end)

    :ok
  end

  defp stub_fetcher(result) do
    Application.put_env(:cymphony_elixir, :codex_catalog_fetcher, fn -> result end)
  end

  test "codex models come from the live catalog: visible only, priority order, efforts + default attached" do
    stub_fetcher({:ok, @catalog_json})

    assert [frontier, mini] = AgentCatalog.models("codex")

    assert frontier.value == "gpt-9-frontier"
    assert frontier.label == "gpt-9-frontier"
    assert frontier.description == "Latest frontier model."
    assert frontier.efforts == ["low", "medium", "high", "ultra"]
    assert frontier.default_effort == "low"

    assert mini.value == "gpt-9-mini"
    assert mini.efforts == ["low", "medium"]
  end

  test "efforts/2 returns the selected model's levels; union of visible models when no model given" do
    stub_fetcher({:ok, @catalog_json})

    assert AgentCatalog.efforts("codex", "gpt-9-mini") == ["low", "medium"]
    assert AgentCatalog.efforts("codex", nil) == ["low", "medium", "high", "ultra"]
    # unknown model → falls back to the union too
    assert AgentCatalog.efforts("codex", "not-in-catalog") == ["low", "medium", "high", "ultra"]
  end

  test "fetch failure falls back to the static codex lists" do
    stub_fetcher({:error, :not_found})

    models = AgentCatalog.models("codex")
    assert Enum.any?(models, &(&1.value == "gpt-5.2-codex"))
    assert AgentCatalog.efforts("codex", nil) == ["minimal", "low", "medium", "high", "xhigh"]
  end

  test "malformed JSON falls back to the static codex lists" do
    stub_fetcher({:ok, "not json at all"})
    assert Enum.any?(AgentCatalog.models("codex"), &(&1.value == "gpt-5.2-codex"))
  end

  test "the catalog is fetched once and cached" do
    parent = self()

    Application.put_env(:cymphony_elixir, :codex_catalog_fetcher, fn ->
      send(parent, :fetched)
      {:ok, @catalog_json}
    end)

    AgentCatalog.models("codex")
    AgentCatalog.models("codex")
    AgentCatalog.efforts("codex", nil)

    assert_received :fetched
    refute_received :fetched
  end

  test "claude uses the static alias vocabulary" do
    models = AgentCatalog.models("claude")
    assert Enum.map(models, & &1.value) == ["sonnet", "opus", "haiku"]
    assert AgentCatalog.efforts("claude", nil) == ["low", "medium", "high", "xhigh", "max"]
    assert AgentCatalog.efforts("claude", "opus") == ["low", "medium", "high", "xhigh", "max"]
  end
end
