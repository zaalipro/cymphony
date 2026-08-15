defmodule CymphonyElixir.RunSpecResolver do
  @moduledoc """
  Resolves the per-issue run spec (agent kind, model, effort, provider) from,
  in descending precedence per field:

  1. Linear labels — `agent:<kind>`, `model:<name>`, `effort:<level>`,
     `provider:<alias>`
  2. A `cymphony:` directive line in the issue description —
     `cymphony: agent=codex model=gpt-5.2 effort=high`
  3. Project config (`agent.kind` / `agent.model` / `agent.effort`)

  Pure functions only; the orchestrator calls `resolve/2` at dispatch time and
  pins the result for the whole run attempt.
  """

  require Logger

  alias CymphonyElixir.Agent
  alias CymphonyElixir.Linear.Issue

  @override_keys %{
    "agent" => :agent_kind,
    "model" => :model,
    "effort" => :effort,
    "provider" => :provider
  }

  @type overrides :: %{
          optional(:agent_kind) => String.t(),
          optional(:model) => String.t(),
          optional(:effort) => String.t(),
          optional(:provider) => String.t()
        }

  @type resolved :: %{
          agent_kind: String.t(),
          model: String.t() | nil,
          effort: String.t() | nil,
          provider: String.t() | nil,
          source: :labels | :directive | :config
        }

  @doc """
  Resolve the effective run spec for an issue against the project config.
  Field-level precedence: labels > description directive > config defaults.
  `source` reports the highest source that contributed any field (for logs).
  """
  @spec resolve(Issue.t(), term()) :: resolved()
  def resolve(%Issue{} = issue, config) do
    label_overrides = from_labels(issue.labels || [])
    directive_overrides = from_description(issue.description)

    merged = Map.merge(directive_overrides, label_overrides)

    %{
      agent_kind: merged[:agent_kind] || config.agent.kind,
      model: merged[:model] || config.agent.model,
      effort: merged[:effort] || config.agent.effort,
      provider: merged[:provider],
      source: source_of(label_overrides, directive_overrides)
    }
  end

  defp source_of(labels, _directive) when map_size(labels) > 0, do: :labels
  defp source_of(_labels, directive) when map_size(directive) > 0, do: :directive
  defp source_of(_labels, _directive), do: :config

  @doc "Extract overrides from Linear labels (already downcased by the adapter)."
  @spec from_labels([String.t()]) :: overrides()
  def from_labels(labels) when is_list(labels) do
    labels
    |> Enum.flat_map(&parse_label/1)
    |> Enum.group_by(fn {key, _value} -> key end, fn {_key, value} -> value end)
    |> Enum.reduce(%{}, fn {key, values}, acc ->
      value =
        case Enum.sort(values) do
          [single] ->
            single

          [first | _] = all ->
            Logger.warning("run_spec: duplicate #{key} labels #{inspect(all)} — using #{inspect(first)}")
            first
        end

      put_validated(acc, key, value)
    end)
  end

  @doc """
  Extract overrides from the first `cymphony:` directive line in the issue
  description. Keys: agent|model|effort|provider as `key=value` pairs.
  `agent` and `effort` values are lowercased; `model`/`provider` preserved.
  """
  @spec from_description(String.t() | nil) :: overrides()
  def from_description(description) when is_binary(description) do
    description
    |> String.split(["\n", "\r\n"], trim: true)
    |> Enum.find_value(%{}, fn line ->
      case parse_directive_line(String.trim(line)) do
        overrides when map_size(overrides) > 0 -> overrides
        _ -> nil
      end
    end)
  end

  def from_description(_description), do: %{}

  defp parse_directive_line("cymphony:" <> rest), do: parse_directive_pairs(rest)
  defp parse_directive_line("Cymphony:" <> rest), do: parse_directive_pairs(rest)
  defp parse_directive_line("CYMPHONY:" <> rest), do: parse_directive_pairs(rest)
  defp parse_directive_line(_line), do: %{}

  defp parse_directive_pairs(rest) do
    pair_pattern = Regex.compile!("^([A-Za-z]+)=([A-Za-z0-9._/-]+)$")
    whitespace = Regex.compile!("\\s+")

    rest
    |> String.split(whitespace, trim: true)
    |> Enum.reduce(%{}, fn token, acc -> apply_directive_token(acc, token, pair_pattern) end)
  end

  defp apply_directive_token(acc, token, pair_pattern) do
    case Regex.run(pair_pattern, token) do
      [_, raw_key, raw_value] -> put_directive_pair(acc, raw_key, raw_value)
      nil -> acc
    end
  end

  defp put_directive_pair(acc, raw_key, raw_value) do
    key = String.downcase(raw_key)

    case Map.fetch(@override_keys, key) do
      {:ok, field} ->
        put_validated(acc, field, normalize_directive_value(field, raw_value))

      :error ->
        Logger.debug("run_spec: unknown directive key #{inspect(raw_key)} — ignored")
        acc
    end
  end

  defp normalize_directive_value(field, raw_value) when field in [:agent_kind, :effort] do
    String.downcase(raw_value)
  end

  defp normalize_directive_value(_field, raw_value), do: raw_value

  defp parse_label(label) when is_binary(label) do
    case String.split(label, ":", parts: 2) do
      [prefix, value] when is_map_key(@override_keys, prefix) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          Logger.warning("run_spec: label #{inspect(label)} has an empty value — ignored")
          []
        else
          [{Map.fetch!(@override_keys, prefix), trimmed}]
        end

      _ ->
        []
    end
  end

  defp parse_label(_label), do: []

  defp put_validated(acc, :agent_kind, value) do
    if value in Agent.known_kinds() do
      Map.put(acc, :agent_kind, value)
    else
      Logger.warning("run_spec: unknown agent kind #{inspect(value)} — falling back to next source")
      acc
    end
  end

  defp put_validated(acc, key, value), do: Map.put(acc, key, value)
end
