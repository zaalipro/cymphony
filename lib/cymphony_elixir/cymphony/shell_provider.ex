defmodule CymphonyElixir.Cymphony.ShellProvider do
  @moduledoc false

  @env_prefix ~w(ANTHROPIC_ API_TIMEOUT CLAUDE_CODE_)

  @spec load_env(String.t()) :: {:ok, map()} | {:error, :not_found}
  def load_env(provider_name) when is_binary(provider_name) do
    case cached(provider_name) do
      {:ok, _} = result -> result
      :miss -> fetch_and_cache(provider_name)
    end
  end

  @spec known_providers() :: [String.t()]
  def known_providers do
    script = """
    claude() { :; }
    for f in "$HOME/.cld" "$HOME/.zshrc" "$HOME/.bashrc"; do
      [ -f "$f" ] && source "$f" 2>/dev/null || true
    done
    for name in $(functions | grep "^[a-z][a-z0-9]* ()" | sed 's/ ()//' | sort -u); do
      if [[ "$name" == c* ]] && [[ "$name" != claude ]] && [[ "$name" != _* ]]; then
        echo "$name"
      fi
    done
    """

    case System.cmd("zsh", ["-c", script], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp fetch_and_cache(provider_name) do
    script = """
    claude() { :; }
    for f in "$HOME/.cld" "$HOME/.zshrc" "$HOME/.bashrc"; do
      [ -f "$f" ] && source "$f" 2>/dev/null || true
    done
    type #{provider_name} >/dev/null 2>&1 || exit 1
    _unset 2>/dev/null || true
    #{provider_name}
    env
    """

    case System.cmd("zsh", ["-c", script], stderr_to_stdout: true) do
      {output, 0} ->
        env_map = parse_env_output(output)
        put_cached(provider_name, env_map)
        {:ok, env_map}

      {_output, 1} ->
        {:error, :not_found}

      {output, code} ->
        require Logger
        Logger.warning("ShellProvider exited #{code} for #{provider_name}: #{String.slice(output, 0, 200)}")
        {:error, :not_found}
    end
  end

  defp parse_env_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&env_var?/1)
    |> Enum.into(%{}, fn line ->
      [k | rest] = String.split(line, "=", parts: 2)
      {k, Enum.join(rest, "=")}
    end)
  end

  defp env_var?(line) do
    String.contains?(line, "=") and
      Enum.any?(@env_prefix, &String.starts_with?(line, &1))
  end

  defp cached(key) do
    case :persistent_term.get({__MODULE__, key}, :miss) do
      :miss -> :miss
      env_map -> {:ok, env_map}
    end
  end

  defp put_cached(key, env_map) do
    :persistent_term.put({__MODULE__, key}, env_map)
  end
end
