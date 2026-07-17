defmodule CymphonyElixir.AgentCatalog do
  @moduledoc """
  Model and reasoning-effort choices per agent kind, for pickers (onboarding
  wizard, dashboard suggestions).

  Codex ships a machine-readable catalog (`codex debug models` → JSON with
  slugs, descriptions, and per-model `supported_reasoning_levels`), so codex
  choices are fetched live and cached for the process lifetime; the static
  list is only a fallback when the binary is missing or the output doesn't
  parse. Claude Code has no equivalent listing command — its stable alias
  vocabulary (sonnet/opus/haiku) and effort levels are kept statically.

  Everything here is advisory: model/effort values remain pass-through free
  text end to end.
  """

  require Logger

  @type model_choice :: %{
          value: String.t(),
          label: String.t(),
          description: String.t() | nil,
          efforts: [String.t()],
          default_effort: String.t() | nil
        }

  @claude_models [
    %{value: "sonnet", label: "sonnet", description: "Balanced speed and capability", efforts: nil, default_effort: nil},
    %{value: "opus", label: "opus", description: "Most capable", efforts: nil, default_effort: nil},
    %{value: "haiku", label: "haiku", description: "Fastest", efforts: nil, default_effort: nil}
  ]

  @claude_efforts ["low", "medium", "high", "xhigh", "max"]

  @codex_fallback_models [
    %{value: "gpt-5.2-codex", label: "gpt-5.2-codex", description: nil, efforts: nil, default_effort: nil},
    %{value: "gpt-5.2", label: "gpt-5.2", description: nil, efforts: nil, default_effort: nil},
    %{value: "o4-mini", label: "o4-mini", description: nil, efforts: nil, default_effort: nil}
  ]

  @codex_fallback_efforts ["minimal", "low", "medium", "high", "xhigh"]

  @cache_key {__MODULE__, :codex_catalog}
  @fetch_timeout_ms 5_000

  @doc "Model choices for an agent kind, best first. Never empty."
  @spec models(String.t()) :: [model_choice()]
  def models("codex") do
    case codex_catalog() do
      {:ok, models} -> models
      :error -> @codex_fallback_models
    end
  end

  def models(_claude), do: @claude_models

  @doc """
  Reasoning-effort levels for an agent kind, optionally narrowed to a model.

  For codex the levels come from the model's catalog entry; with no model (or
  an unknown one) the union across visible models is returned so no valid
  level is hidden. Claude levels are model-independent.
  """
  @spec efforts(String.t(), String.t() | nil) :: [String.t()]
  def efforts("codex", model) do
    case codex_catalog() do
      {:ok, models} ->
        case Enum.find(models, &(&1.value == model)) do
          %{efforts: efforts} when is_list(efforts) and efforts != [] -> efforts
          _ -> effort_union(models)
        end

      :error ->
        @codex_fallback_efforts
    end
  end

  def efforts(_claude, _model), do: @claude_efforts

  @doc false
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp effort_union(models) do
    models
    |> Enum.flat_map(& &1.efforts)
    |> Enum.uniq()
  end

  defp codex_catalog do
    case :persistent_term.get(@cache_key, :miss) do
      :miss ->
        result = fetch_and_parse()
        :persistent_term.put(@cache_key, result)
        result

      cached ->
        cached
    end
  end

  defp fetch_and_parse do
    with {:ok, json} <- fetcher().(),
         {:ok, %{"models" => models}} when is_list(models) <- Jason.decode(json),
         parsed when parsed != [] <- parse_models(models) do
      {:ok, parsed}
    else
      other ->
        Logger.debug("AgentCatalog: codex catalog unavailable (#{inspect(other)}); using fallback list")
        :error
    end
  end

  defp parse_models(models) do
    models
    |> Enum.filter(fn m -> Map.get(m, "visibility", "list") == "list" and is_binary(m["slug"]) end)
    |> Enum.sort_by(fn m -> Map.get(m, "priority", 999) end)
    |> Enum.map(fn m ->
      %{
        value: m["slug"],
        label: m["slug"],
        description: m["description"],
        efforts: reasoning_levels(m),
        default_effort: m["default_reasoning_level"]
      }
    end)
  end

  defp reasoning_levels(model) do
    model
    |> Map.get("supported_reasoning_levels", [])
    |> Enum.map(fn
      %{"effort" => effort} when is_binary(effort) -> effort
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp fetcher do
    Application.get_env(:cymphony_elixir, :codex_catalog_fetcher, &default_fetcher/0)
  end

  # Shells out to `codex debug models` (measured ~60ms). The task wrapper
  # bounds the wait so a hung binary can't stall the wizard or dashboard.
  defp default_fetcher do
    task =
      Task.async(fn ->
        System.cmd("codex", ["debug", "models"], stderr_to_stdout: false)
      end)

    case Task.yield(task, @fetch_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {_output, code}} -> {:error, {:exit, code}}
      _ -> {:error, :timeout}
    end
  rescue
    error -> {:error, error}
  end
end
