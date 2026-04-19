defmodule SymphonyElixir.Cymphony.Onboarding do
  @moduledoc false

  alias SymphonyElixir.Cymphony.Config

  @spec run() :: {:ok, map()} | {:error, term()}
  def run do
    IO.puts("""
    \n
    ╭──────────────────────────────────────────────────────────╮
    │  Welcome to Cymphony!                                    │
    │                                                          │
    │  Let's set up your configuration.                        │
    │  This will be saved to ~/.cymphony/config.json           │
    ╰──────────────────────────────────────────────────────────╯
    """)

    with {:ok, github_repo} <- ask_required("GitHub repo URL (e.g. git@github.com:user/repo.git): "),
         {:ok, project_slug} <- ask_required("Linear project slug (e.g. myteam-ab12cd34ef56): "),
         {:ok, api_key} <- ask_required("Linear API key: "),
         {:ok, workspace_root} <- ask_optional("Workspace root [~/cymphony-workspaces]: ", "~/cymphony-workspaces"),
         {:ok, polling_interval} <- ask_optional("Polling interval in seconds [5]: ", "5") do
      polling_ms =
        case Integer.parse(polling_interval) do
          {secs, _} -> secs * 1000
          :error -> 5000
        end

      config = %{
        "github_repo_url" => github_repo,
        "linear_project_slug" => project_slug,
        "linear_api_key" => api_key,
        "workspace_root" => workspace_root,
        "polling_interval_ms" => polling_ms
      }

      case Config.save(config) do
        :ok ->
          IO.puts("\nConfiguration saved to #{Config.config_path()}")
          {:ok, config}

        {:error, reason} ->
          {:error, "Failed to save configuration: #{inspect(reason)}"}
      end
    end
  end

  defp ask_required(prompt) do
    case IO.gets(prompt) do
      :eof ->
        {:error, "Unexpected end of input"}

      {:error, reason} ->
        {:error, "Input error: #{inspect(reason)}"}

      input ->
        value = String.trim(input)

        if value == "" do
          IO.puts("  This field is required.")
          ask_required(prompt)
        else
          {:ok, value}
        end
    end
  end

  defp ask_optional(prompt, default) do
    case IO.gets(prompt) do
      :eof -> {:ok, default}
      {:error, _} -> {:ok, default}
      input ->
        value = String.trim(input)
        {:ok, if(value == "", do: default, else: value)}
    end
  end
end
