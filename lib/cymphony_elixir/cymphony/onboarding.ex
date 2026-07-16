defmodule CymphonyElixir.Cymphony.Onboarding do
  @moduledoc false

  alias CymphonyElixir.Cymphony.Config

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

    case collect_project([]) do
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

  defp collect_project(existing_names, providers \\ %{}) do
    with {:ok, name} <- ask_project_name(existing_names),
         {:ok, github_repo} <- ask_required("GitHub repo URL (e.g. git@github.com:user/repo.git): "),
         {:ok, project_slug} <- ask_required("Linear project slug (e.g. myteam-ab12cd34ef56): "),
         {:ok, api_key} <- ask_linear_api_key(),
         {:ok, workspace_root} <- ask_optional("Workspace root [~/.cymphony/workspaces/#{name}]: ", "~/.cymphony/workspaces/#{name}"),
         {:ok, polling_interval} <- ask_optional("Polling interval in seconds [5]: ", "5"),
         {:ok, agent_kind} <- ask_agent_kind(),
         {:ok, provider} <- ask_provider(providers) do
      polling_ms =
        case Integer.parse(polling_interval) do
          {secs, _} -> secs * 1000
          :error -> 5000
        end

      project =
        %{
          "name" => name,
          "github_repo_url" => github_repo,
          "linear_project_slug" => project_slug,
          "linear_api_key" => api_key,
          "workspace_root" => workspace_root,
          "polling_interval_ms" => polling_ms,
          "agent" => agent_kind
        }

      project =
        if provider != nil and provider != "", do: Map.put(project, "provider", provider), else: project

      {:ok, project}
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

  defp collect_additional_projects(projects, providers \\ %{}) do
    case IO.gets("Add another project? [y/N]: ") do
      :eof ->
        projects

      {:error, _} ->
        projects

      input ->
        if String.trim(String.downcase(input)) == "y" do
          case collect_project(Enum.map(projects, & &1["name"]), providers) do
            {:ok, project} ->
              collect_additional_projects(projects ++ [project], providers)

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

  defp ask_linear_api_key do
    env_key = System.get_env("LINEAR_API_KEY")

    prompt =
      if env_key do
        masked = String.slice(env_key, -4, 4) |> String.pad_leading(String.length(env_key), "*")
        "Linear API key [#{masked} from env]: "
      else
        "Linear API key: "
      end

    case IO.gets(prompt) do
      :eof ->
        {:error, "Unexpected end of input"}

      {:error, reason} ->
        {:error, "Input error: #{inspect(reason)}"}

      input ->
        value = String.trim(input)

        cond do
          value != "" ->
            {:ok, value}

          env_key != nil ->
            {:ok, env_key}

          true ->
            IO.puts("  This field is required. Set LINEAR_API_KEY or enter a key.")
            ask_linear_api_key()
        end
    end
  end

  defp ask_agent_kind do
    case IO.gets("Coding agent (claude/codex) [claude]: ") do
      :eof ->
        {:ok, "claude"}

      {:error, _} ->
        {:ok, "claude"}

      input ->
        case input |> String.trim() |> String.downcase() do
          "" ->
            {:ok, "claude"}

          kind when kind in ["claude", "codex"] ->
            {:ok, kind}

          other ->
            IO.puts("  Unknown agent '#{other}'. Choose claude or codex.")
            ask_agent_kind()
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

  defp ask_provider(providers) do
    provider_names = Map.keys(providers)

    if provider_names == [] do
      {:ok, nil}
    else
      names_str = Enum.join(provider_names, ", ")
      prompt = "Provider (#{names_str}) [none]: "

      case IO.gets(prompt) do
        :eof ->
          {:ok, nil}

        {:error, _} ->
          {:ok, nil}

        input ->
          value = String.trim(input)

          if value == "" do
            {:ok, nil}
          else
            string_names = Enum.map(provider_names, &to_string/1)

            if value in string_names do
              {:ok, value}
            else
              IO.puts("  Unknown provider '#{value}'. Available: #{names_str}")
              ask_provider(providers)
            end
          end
      end
    end
  end
end
