defmodule CymphonyElixir.AgentCatalog do
  @moduledoc """
  Model and reasoning-effort choices per agent kind, for pickers (onboarding
  wizard, dashboard suggestions).

  Codex ships a machine-readable catalog (`codex debug models` → JSON with
  slugs, descriptions, and per-model `supported_reasoning_levels`), so codex
  choices are fetched live and cached for the process lifetime; the static
  list is only a fallback when the binary is missing or the output doesn't
  parse. The fetch looks up `codex` on PATH and in well-known install dirs
  (`$HOME/.local/bin`, `/usr/local/bin`, Homebrew) because burrito/systemd
  PATH is often just `/usr/bin:/bin`. Failed fetches are retried after a
  short TTL so a missing binary at boot does not pin the fallback forever.
  If the live catalog command fails, `codex debug models --bundled` is tried
  before the static list. Claude Code has no equivalent listing command —
  its stable alias vocabulary (sonnet/opus/haiku) and effort levels are kept
  statically.
  Antigravity is also static: Gemini/Claude slugs plus low/medium/high
  efforts. There is no `agy models` fetch in v1.

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

  @antigravity_models [
    %{value: "gemini-3.7-flash-high", label: "gemini-3.7-flash-high", description: nil, efforts: nil, default_effort: nil},
    %{value: "gemini-3.7-flash-medium", label: "gemini-3.7-flash-medium", description: nil, efforts: nil, default_effort: nil},
    %{value: "gemini-3.6-flash-high", label: "gemini-3.6-flash-high", description: nil, efforts: nil, default_effort: nil},
    %{value: "gemini-3.6-flash-medium", label: "gemini-3.6-flash-medium", description: nil, efforts: nil, default_effort: nil},
    %{value: "gemini-3.5-flash-medium", label: "gemini-3.5-flash-medium", description: nil, efforts: nil, default_effort: nil},
    %{value: "gemini-3.1-pro-high", label: "gemini-3.1-pro-high", description: nil, efforts: nil, default_effort: nil},
    %{value: "claude-sonnet-4-6", label: "claude-sonnet-4-6", description: nil, efforts: nil, default_effort: nil}
  ]

  @antigravity_efforts ["low", "medium", "high"]

  @cache_key {__MODULE__, :codex_catalog}
  @fetch_timeout_ms 15_000
  @error_ttl_ms 30_000

  @doc "Model choices for an agent kind, best first. Never empty."
  @spec models(String.t()) :: [model_choice()]
  def models("codex") do
    case codex_catalog() do
      {:ok, models} -> models
      :error -> @codex_fallback_models
    end
  catch
    :exit, _reason -> @codex_fallback_models
  end

  def models("antigravity"), do: @antigravity_models

  def models(_claude), do: @claude_models

  @doc """
  Reasoning-effort levels for an agent kind, optionally narrowed to a model.

  For codex the levels come from the model's catalog entry; with no model (or
  an unknown one) the union across visible models is returned so no valid
  level is hidden. Claude and Antigravity levels are model-independent.
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
  catch
    :exit, _reason -> @codex_fallback_efforts
  end

  def efforts("antigravity", _model), do: @antigravity_efforts

  def efforts(_claude, _model), do: @claude_efforts

  @doc false
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp effort_union(models) do
    models
    |> Enum.flat_map(& &1.efforts)
    |> Enum.uniq()
  end

  defp codex_catalog do
    now = System.monotonic_time(:millisecond)
    ttl = error_ttl_ms()

    case :persistent_term.get(@cache_key, :miss) do
      {:ok, _models} = ok ->
        ok

      {:error, cached_at} when is_integer(cached_at) ->
        if now - cached_at < ttl, do: :error, else: refresh_catalog()

      _stale_or_miss ->
        refresh_catalog()
    end
  end

  defp refresh_catalog do
    result = fetch_and_parse()

    stored =
      case result do
        {:ok, _models} = ok -> ok
        :error -> {:error, System.monotonic_time(:millisecond)}
      end

    :persistent_term.put(@cache_key, stored)
    result
  end

  defp fetch_and_parse do
    with {:ok, json} <- fetcher().(),
         {:ok, %{"models" => models}} when is_list(models) <- Jason.decode(json),
         parsed when parsed != [] <- parse_models(models) do
      {:ok, parsed}
    else
      reason ->
        Logger.warning("AgentCatalog: codex catalog unavailable (#{format_catalog_reason(reason)}); using fallback list")

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
        label: model_label(m),
        description: m["description"],
        efforts: reasoning_levels(m),
        default_effort: m["default_reasoning_level"]
      }
    end)
  end

  defp model_label(model) do
    case model do
      %{"display_name" => name} when is_binary(name) and name != "" -> name
      %{"slug" => slug} when is_binary(slug) -> slug
    end
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

  # Shells out to `codex debug models` (live catalog can be several MB).
  # The worker is *unlinked* (`spawn_monitor`, not `Task.async`) so a
  # missing binary (`:enoent`) or a crashing `System.cmd/3` cannot take
  # down the LiveView that asked for suggestions.
  defp default_fetcher do
    fun = catalog_cmd()
    timeout = fetch_timeout_ms()
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(parent, {:codex_catalog, self(), catalog_cmd_result(fun)})
      end)

    receive do
      {:codex_catalog, ^pid, {:ok, output}} ->
        Process.demonitor(ref, [:flush])
        {:ok, output}

      {:codex_catalog, ^pid, {:error, reason}} ->
        Process.demonitor(ref, [:flush])
        {:error, reason}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:exit, reason}}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  rescue
    error -> {:error, error}
  end

  defp catalog_cmd_result(fun) do
    case invoke_catalog_cmd(fun, ["debug", "models"]) do
      {:ok, output} ->
        {:ok, output}

      {:error, _reason} ->
        invoke_catalog_cmd(fun, ["debug", "models", "--bundled"])
    end
  end

  defp invoke_catalog_cmd(fun, args) do
    case fun.("codex", args, stderr_to_stdout: false) do
      {output, 0} -> {:ok, output}
      {_output, code} -> {:error, {:exit, code}}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp catalog_cmd do
    Application.get_env(:cymphony_elixir, :codex_catalog_cmd, &default_cmd/3)
  end

  defp default_cmd(bin, args, opts) do
    case resolve_bin(bin) do
      nil ->
        :erlang.error(:enoent)

      path ->
        System.cmd(path, args, Keyword.put(opts, :env, catalog_child_env(path)))
    end
  end

  defp resolve_bin(name) do
    name
    |> bin_candidates()
    |> Enum.find(&usable_bin?/1)
  end

  defp bin_candidates(name) do
    home = catalog_home()

    extra =
      extra_bin_dirs()
      |> Enum.map(&Path.join(&1, name))

    [
      path_lookup(name),
      join_home(home, [".local", "bin", name])
      | extra
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp path_lookup(name) do
    fun = Application.get_env(:cymphony_elixir, :codex_catalog_which, &System.find_executable/1)
    fun.(name)
  end

  defp join_home("", _segments), do: nil
  defp join_home(home, segments), do: Path.join([home | segments])

  defp usable_bin?(path) when is_binary(path), do: File.regular?(path)
  defp usable_bin?(_), do: false

  defp catalog_child_env(path) do
    home = catalog_home()
    dir = Path.dirname(path)

    path_var =
      ([dir, join_home(home, [".local", "bin"])] ++ extra_bin_dirs() ++ [System.get_env("PATH")])
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(":")

    env = [{"PATH", path_var}]
    if home == "", do: env, else: [{"HOME", home} | env]
  end

  defp catalog_home do
    Application.get_env(:cymphony_elixir, :codex_catalog_home) || System.get_env("HOME") || ""
  end

  defp extra_bin_dirs do
    Application.get_env(:cymphony_elixir, :codex_catalog_extra_dirs) ||
      ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"]
  end

  defp fetch_timeout_ms do
    Application.get_env(:cymphony_elixir, :codex_catalog_timeout_ms, @fetch_timeout_ms)
  end

  defp error_ttl_ms do
    Application.get_env(:cymphony_elixir, :codex_catalog_error_ttl_ms, @error_ttl_ms)
  end

  defp format_catalog_reason(reason), do: inspect(reason)
end
