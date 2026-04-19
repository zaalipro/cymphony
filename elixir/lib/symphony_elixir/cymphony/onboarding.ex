defmodule SymphonyElixir.Cymphony.Onboarding do
  @moduledoc false

  alias SymphonyElixir.Cymphony.Config

  @spec run() :: {:ok, map()} | {:error, term()}
  def run do
    IO.puts("""

    ╭──────────────────────────────────────────────────────────╮
    │  Welcome to Cymphony!                                    │
    │                                                          │
    │  Let's set up your configuration.                        │
    │  This will be saved to ~/.cymphony/config.json           │
    ╰──────────────────────────────────────────────────────────╯
    """)

    case collect_project(nil) do
      {:ok, first_project} ->
        projects = collect_additional_projects([first_project])
        config = %{"projects" => projects}

        case Config.save(config) do
          :ok ->
            IO.puts("\nConfiguration saved to #{Config.config_path()}")
            {:ok, config}

          {:error, reason} ->
            {:error, "Failed to save configuration: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Adds a single project to an existing config file.
  """
  @spec add_project() :: {:ok, map()} | {:error, term()}
  def add_project do
    case Config.load() do
      {:ok, config} ->
        IO.puts("""

        ╭──────────────────────────────────────────────────────────╮
        │  Add a new project to your Cymphony configuration.      │
        ╰──────────────────────────────────────────────────────────╯
        """)

        existing_names = Config.projects(config) |> Enum.map(& &1["name"])

        case collect_project(existing_names) do
          {:ok, project} ->
            updated_projects = Config.projects(config) ++ [project]
            updated_config = Map.put(config, "projects", updated_projects)

            case Config.save(updated_config) do
              :ok ->
                IO.puts("\nProject '#{project["name"]}' added to #{Config.config_path()}")
                {:ok, updated_config}

              {:error, reason} ->
                {:error, "Failed to save configuration: #{inspect(reason)}"}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "Configuration error: #{inspect(reason)}"}
    end
  end

  @doc """
  Lists configured projects.
  """
  @spec list_projects() :: {:ok, [map()]} | {:error, term()}
  def list_projects do
    case Config.load() do
      {:ok, config} ->
        {:ok, Config.projects(config)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_project(existing_names) do
    with {:ok, name} <- ask_project_name(existing_names),
         {:ok, github_repo} <- ask_required("GitHub repo URL (e.g. git@github.com:user/repo.git): "),
         {:ok, project_slug} <- ask_required("Linear project slug (e.g. myteam-ab12cd34ef56): "),
         {:ok, api_key} <- ask_required("Linear API key: "),
         {:ok, workspace_root} <- ask_optional("Workspace root [~/cymphony-workspaces/#{name}]: ", "~/cymphony-workspaces/#{name}"),
         {:ok, polling_interval} <- ask_optional("Polling interval in seconds [5]: ", "5") do
      polling_ms =
        case Integer.parse(polling_interval) do
          {secs, _} -> secs * 1000
          :error -> 5000
        end

      {:ok,
       %{
         "name" => name,
         "github_repo_url" => github_repo,
         "linear_project_slug" => project_slug,
         "linear_api_key" => api_key,
         "workspace_root" => workspace_root,
         "polling_interval_ms" => polling_ms
       }}
    end
  end

  defp ask_project_name(existing_names) do
    case ask_required("Project name: ") do
      {:ok, name} ->
        if name in existing_names do
          IO.puts("  A project named '#{name}' already exists. Choose a different name.")
          ask_project_name(existing_names)
        else
          {:ok, name}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_additional_projects(projects) do
    case IO.gets("Add another project? [y/N]: ") do
      :eof ->
        projects

      {:error, _} ->
        projects

      input ->
        if String.trim(String.downcase(input)) == "y" do
          case collect_project(Enum.map(projects, & &1["name"])) do
            {:ok, project} ->
              collect_additional_projects(projects ++ [project])

            {:error, _reason} ->
              projects
          end
        else
          projects
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
      :eof ->
        {:ok, default}

      {:error, _} ->
        {:ok, default}

      input ->
        value = String.trim(input)
        {:ok, if(value == "", do: default, else: value)}
    end
  end
end
