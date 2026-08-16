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
      Application.delete_env(:cymphony_elixir, :codex_catalog_cmd)
      Application.delete_env(:cymphony_elixir, :codex_catalog_timeout_ms)
      AgentCatalog.clear_cache()
    end)

    :ok
  end

  defp stub_fetcher(result) do
    Application.put_env(:cymphony_elixir, :codex_catalog_fetcher, fn -> result end)
  end

  defp use_default_fetcher do
    Application.delete_env(:cymphony_elixir, :codex_catalog_fetcher)
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

  test "antigravity uses the static Gemini/Claude slug list and low/medium/high efforts" do
    models = AgentCatalog.models("antigravity")
    slugs = Enum.map(models, & &1.value)

    assert slugs == [
             "gemini-3.7-flash-high",
             "gemini-3.7-flash-medium",
             "gemini-3.6-flash-high",
             "gemini-3.6-flash-medium",
             "gemini-3.5-flash-medium",
             "gemini-3.1-pro-high",
             "claude-sonnet-4-6"
           ]

    assert slugs != []
    refute Enum.any?(slugs, &(&1 in ["sonnet", "opus", "haiku"]))

    for model <- models do
      assert model.label == model.value
      assert model.description == nil
      assert model.efforts == nil
      assert model.default_effort == nil
    end

    assert AgentCatalog.efforts("antigravity", nil) == ["low", "medium", "high"]
    assert AgentCatalog.efforts("antigravity", "gemini-3.7-flash-high") == ["low", "medium", "high"]
    assert AgentCatalog.efforts("antigravity", "unknown-slug") == ["low", "medium", "high"]
  end

  test "unknown kinds still fall through to Claude aliases; antigravity does not" do
    claude_slugs = Enum.map(AgentCatalog.models("claude"), & &1.value)
    assert Enum.map(AgentCatalog.models("nope"), & &1.value) == claude_slugs
    assert AgentCatalog.efforts("nope", nil) == AgentCatalog.efforts("claude", nil)

    antigravity_slugs = Enum.map(AgentCatalog.models("antigravity"), & &1.value)
    refute antigravity_slugs == claude_slugs
    refute AgentCatalog.efforts("antigravity", nil) == AgentCatalog.efforts("claude", nil)
  end

  test "empty or unlisted catalogs fall back; malformed reasoning entries are dropped" do
    stub_fetcher({:ok, ~s({"models": []})})
    assert Enum.any?(AgentCatalog.models("codex"), &(&1.value == "gpt-5.2-codex"))

    AgentCatalog.clear_cache()

    stub_fetcher({:ok, ~s({"models": "not-a-list"})})
    assert Enum.any?(AgentCatalog.models("codex"), &(&1.value == "gpt-5.2-codex"))

    AgentCatalog.clear_cache()

    stub_fetcher(
      {:ok,
       ~s({"models": [{"slug": "hidden-only", "visibility": "hide"}, {"priority": 1}, {"slug": "ok", "supported_reasoning_levels": [{"effort": "high"}, {"effort": 1}, "low", {}], "visibility": "list"}]})}
    )

    assert [ok] = AgentCatalog.models("codex")
    assert ok.value == "ok"
    assert ok.efforts == ["high"]
    assert ok.default_effort == nil
    assert AgentCatalog.efforts("codex", "ok") == ["high"]
  end

  test "a visible model with no usable efforts falls through to the union of other models" do
    stub_fetcher(
      {:ok,
       ~s({"models": [{"slug": "empty", "supported_reasoning_levels": [], "visibility": "list", "priority": 1}, {"slug": "other", "supported_reasoning_levels": [{"effort": "xhigh"}], "visibility": "list", "priority": 2}]})}
    )

    assert AgentCatalog.efforts("codex", "empty") == ["xhigh"]
  end

  test "default_fetcher uses a successful `codex debug models` command" do
    use_default_fetcher()

    Application.put_env(:cymphony_elixir, :codex_catalog_cmd, fn "codex", ["debug", "models"], opts ->
      assert opts[:stderr_to_stdout] == false
      {@catalog_json, 0}
    end)

    assert [frontier, _mini] = AgentCatalog.models("codex")
    assert frontier.value == "gpt-9-frontier"
  end

  test "default_fetcher falls back when the command exits non-zero" do
    use_default_fetcher()

    Application.put_env(:cymphony_elixir, :codex_catalog_cmd, fn _, _, _ ->
      {"nope", 1}
    end)

    assert Enum.any?(AgentCatalog.models("codex"), &(&1.value == "gpt-5.2-codex"))
  end

  test "default_fetcher falls back when the command exceeds the timeout" do
    use_default_fetcher()
    Application.put_env(:cymphony_elixir, :codex_catalog_timeout_ms, 20)

    Application.put_env(:cymphony_elixir, :codex_catalog_cmd, fn _, _, _ ->
      Process.sleep(200)
      {@catalog_json, 0}
    end)

    assert Enum.any?(AgentCatalog.models("codex"), &(&1.value == "gpt-5.2-codex"))
  end

  test "default_fetcher rescues unexpected errors from the wait path" do
    use_default_fetcher()
    Application.put_env(:cymphony_elixir, :codex_catalog_timeout_ms, -1)

    Application.put_env(:cymphony_elixir, :codex_catalog_cmd, fn _, _, _ ->
      {@catalog_json, 0}
    end)

    assert Enum.any?(AgentCatalog.models("codex"), &(&1.value == "gpt-5.2-codex"))
  end

  test "a crashing catalog command does not take down the caller" do
    use_default_fetcher()

    Application.put_env(:cymphony_elixir, :codex_catalog_cmd, fn _, _, _ ->
      :erlang.error(:enoent)
    end)

    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        send(parent, {:models, AgentCatalog.models("codex")})
      end)

    ref = Process.monitor(pid)

    assert_receive {:models, models}, 1_000
    assert Enum.any?(models, &(&1.value == "gpt-5.2-codex"))
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end
end
